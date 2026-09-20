import Foundation

// Runtime contract test for the shared networking layer.
//
// The Swift in Shared/ is compiled into two apps that need a simulator, a
// paired watch and a signing identity to run. This compiles the same source
// files for macOS and drives them against a live server, so the JSON
// contract between Swift and FastAPI is checked on every change rather than
// discovered on a wrist.
//
//     cd backend && uvicorn main:app --port 8000 &
//     app/tools/check_client.sh
//
// With `--emit-history <path>` it also writes an encoded history blob, which
// check_client.sh can seed into the Simulator so the results screens render
// with real data.
let arguments = CommandLine.arguments
let baseURL = ProcessInfo.processInfo.environment["RISK_API_URL"] ?? "http://localhost:8000"
let client = RiskAPIClient(rawBaseURL: baseURL)!
var failures = 0

/// Where to write an encoded `[ScoredReading]`, if asked.
let historyPath: String? = arguments.firstIndex(of: "--emit-history").flatMap {
    $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
}

func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "  ok  " : " FAIL ") \(label)")
    if !condition { failures += 1 }
}

/// Build a small history the way `RiskStore` does, so seeding it into the
/// Simulator exercises the app's real decoding path.
func emitHistory(to path: String) async {
    var scored: [ScoredReading] = []
    for risk in ["High", "Medium", "Normal"] {
        var reading = VitalsReading.demo(risk: risk)
        reading.source = "apple_watch"
        if risk == "High" {
            reading.consciousness = .voice
            reading.systolicBP = Vital(85, provenance: .manual)
        }
        let prediction = try? await client.predict(reading)
        scored.append(ScoredReading(reading: reading, prediction: prediction, failure: nil))
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(scored) else {
        check(false, "could not encode history")
        return
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        check(true, "wrote \(scored.count)-reading history to \(path)")
    } catch {
        check(false, "could not write history: \(error.localizedDescription)")
    }
}

let sema = DispatchSemaphore(value: 0)
Task {
    check(await client.ping(), "ping /health")

    // A watch-only reading: four sensor vitals, three left assumed.
    var watchReading = VitalsReading()
    watchReading.heartRate = Vital(68, provenance: .sensor, sampledAt: Date())
    watchReading.oxygenSaturation = Vital(98, provenance: .sensor, sampledAt: Date())
    watchReading.respiratoryRate = Vital(15, provenance: .sensor, sampledAt: Date())
    watchReading.temperature = Vital(36.8, provenance: .sensor, sampledAt: Date())
    check(watchReading.measuredVitals.count == 4, "4 of 4 vitals marked measured")
    check(watchReading.assumedVitalNames == ["blood pressure"], "BP reported as assumed")

    do {
        let p = try await client.predict(watchReading)
        check(p.riskLevel == .normal, "healthy watch reading -> Normal (got \(p.riskLevel.rawValue))")
        check(p.news2Total == 0, "NEWS2 total 0 (got \(p.news2Total))")
        check(p.riskFactors.count == 7, "7 risk factors decoded")
        check(p.orderedProbabilities.map(\.level) == RiskLevel.allCases, "probabilities in clinical order")
        check(abs(p.probabilities.values.reduce(0,+) - 1.0) < 1e-6, "probabilities sum to 1")
        check(p.contributingFactors.isEmpty, "no contributing factors when well")
        check(!p.modelVersion.isEmpty, "model version decoded: \(p.modelVersion)")
        check(p.predictedAt.timeIntervalSinceNow > -60, "predictedAt parsed as a real date")
    } catch {
        check(false, "healthy reading threw: \(error.localizedDescription)")
    }

    // A deteriorating reading, with the manual vitals the iPhone adds.
    var sick = VitalsReading.demo(risk: "High")
    sick.consciousness = .voice
    sick.onOxygen = true
    sick.systolicBP = Vital(85, provenance: .manual)
    do {
        let p = try await client.predict(sick)
        check(p.riskLevel == .high, "deteriorating reading -> High (got \(p.riskLevel.rawValue))")
        check(p.hasRedScore, "red score flagged")
        check(!p.topFactors.isEmpty, "top factors present: \(p.topFactors.first ?? "-")")
        check(p.contributingFactors.allSatisfy { $0.score > 0 }, "contributing factors all score > 0")
        let scores = p.riskFactors.map(\.score)
        check(scores == scores.sorted(by: >), "factors sorted most concerning first")
        check(p.recommendation.contains("Emergency"), "High carries the emergency recommendation")
    } catch {
        check(false, "sick reading threw: \(error.localizedDescription)")
    }

    // Errors must surface as readable text, not silently succeed.
    let deadClient = RiskAPIClient(rawBaseURL: "http://127.0.0.1:9")!
    do {
        _ = try await deadClient.predict(watchReading)
        check(false, "unreachable server should throw")
    } catch {
        check(error.localizedDescription.contains("Could not reach"), "unreachable server -> readable error")
    }
    check(RiskAPIClient(rawBaseURL: "not a url") == nil, "garbage base URL rejected")

    if let historyPath {
        await emitHistory(to: historyPath)
    }

    sema.signal()
}
sema.wait()
print(failures == 0 ? "\nALL SHARED-CODE CHECKS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
