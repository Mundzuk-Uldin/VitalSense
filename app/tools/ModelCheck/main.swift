import Foundation

// Replays the frozen PyTorch predictions in model/artifacts/reference.json
// through the *real* Swift scorer and the *real* exported Core ML model.
//
// This is the one test that can catch the failure mode this design is most
// exposed to: Swift builds the ten-element feature vector by hand, and if its
// order drifts from `model/train.py`, nothing crashes. The model just returns
// confident, wrong answers. Frozen reference cases turn that silent failure
// into a loud one.

struct ReferenceFile: Decodable {
    let classes: [String]
    let cases: [Case]

    struct Case: Decodable {
        let respiratoryRate: Double
        let oxygenSaturation: Double
        let o2Scale: Int
        let systolicBP: Double
        let heartRate: Double
        let temperature: Double
        let onOxygen: Bool
        let consciousness: String
        let expectedLabel: String
        let expectedProbabilities: [String: Double]
        let datasetLabel: String

        enum CodingKeys: String, CodingKey {
            case respiratoryRate = "respiratory_rate"
            case oxygenSaturation = "oxygen_saturation"
            case o2Scale = "o2_scale"
            case systolicBP = "systolic_bp"
            case heartRate = "heart_rate"
            case temperature = "temperature"
            case onOxygen = "on_oxygen"
            case consciousness
            case expectedLabel = "expected_label"
            case expectedProbabilities = "expected_probabilities"
            case datasetLabel = "dataset_label"
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: modelcheck <VitalRisk.mlmodelc> <reference.json>\n".utf8))
    exit(2)
}

let modelURL = URL(fileURLWithPath: arguments[1])
let referenceURL = URL(fileURLWithPath: arguments[2])

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "  ok  " : " FAIL ") \(label)")
    if !condition { failures += 1 }
}

let reference = try JSONDecoder().decode(
    ReferenceFile.self, from: Data(contentsOf: referenceURL)
)
let scorer = try RiskScorer(compiledModelURL: modelURL)

// The class order Swift assumes must be the order the exporter recorded.
check(
    RiskScorer.modelClassOrder.map(\.rawValue) == reference.classes,
    "class order matches the exporter: \(reference.classes)"
)

var worstProbabilityDrift = 0.0
var labelMismatches: [String] = []

for (index, testCase) in reference.cases.enumerated() {
    var reading = VitalsReading()
    reading.respiratoryRate = Vital(testCase.respiratoryRate)
    reading.oxygenSaturation = Vital(testCase.oxygenSaturation)
    reading.heartRate = Vital(testCase.heartRate)
    reading.temperature = Vital(testCase.temperature)
    reading.systolicBP = Vital(testCase.systolicBP)
    reading.o2Scale = testCase.o2Scale
    reading.onOxygen = testCase.onOxygen
    reading.consciousness = Consciousness(rawValue: testCase.consciousness) ?? .alert

    let prediction = try scorer.score(reading)

    if prediction.riskLevel.rawValue != testCase.expectedLabel {
        labelMismatches.append(
            "case \(index): Swift said \(prediction.riskLevel.rawValue), "
                + "PyTorch said \(testCase.expectedLabel)"
        )
    }
    for (name, expected) in testCase.expectedProbabilities {
        guard let level = RiskLevel(rawValue: name) else { continue }
        let actual = prediction.probabilities[level] ?? -1
        worstProbabilityDrift = max(worstProbabilityDrift, abs(actual - expected))
    }
}

check(labelMismatches.isEmpty, "all \(reference.cases.count) labels match PyTorch")
for mismatch in labelMismatches { print("        \(mismatch)") }
check(
    worstProbabilityDrift < 1e-4,
    String(format: "probabilities match PyTorch (worst drift %.2e)", worstProbabilityDrift)
)

// The NEWS2 port is the other half of the contract: it both explains the
// score and supplies three of the model's ten inputs.
var sepsis = VitalsReading()
sepsis.respiratoryRate = Vital(28)
sepsis.oxygenSaturation = Vital(91)
sepsis.heartRate = Vital(132)
sepsis.temperature = Vital(38.9)
sepsis.systolicBP = Vital(88)
sepsis.consciousness = .voice
sepsis.onOxygen = true
let sepsisComponents = NEWS2.components(for: sepsis)
check(NEWS2.aggregate(sepsisComponents) == 18, "NEWS2 aggregate matches the Python port (18)")
check(NEWS2.hasRedScore(sepsisComponents), "red score detected")
check(NEWS2.band(sepsisComponents) == .high, "NEWS2 band is High")

// Scale 2 tolerates a lower saturation than scale 1 for the same patient.
var copd = VitalsReading()
copd.oxygenSaturation = Vital(90)
let scale1 = NEWS2.aggregate(NEWS2.components(for: copd))
copd.o2Scale = 2
let scale2 = NEWS2.aggregate(NEWS2.components(for: copd))
check(scale2 < scale1, "SpO2 scale 2 scores lower than scale 1 at 90% (\(scale2) < \(scale1))")

// Deterioration must never reduce the band.
let ladder = ["Normal", "Medium", "High"].map { VitalsReading.demo(risk: $0) }
let severities = try ladder.map { try scorer.score($0).riskLevel.severity }
check(severities == severities.sorted(), "worse vitals never score lower: \(severities)")

let healthy = try scorer.score(.demo(risk: "Normal"))
check(healthy.riskLevel == .normal, "healthy demo reading scores Normal")
check(healthy.contributingFactors.isEmpty, "healthy reading has no contributing factors")
check(healthy.riskFactors.count == 7, "all seven vitals reported")
check(
    abs(healthy.probabilities.values.reduce(0, +) - 1.0) < 1e-5,
    "probabilities sum to 1"
)

// `--emit-history <path>` writes a history blob the way RiskStore encodes
// one, so it can be seeded into a Simulator to see the results screens with
// genuine on-device predictions rather than a mock.
if let flag = arguments.firstIndex(of: "--emit-history"), flag + 1 < arguments.count {
    var scored: [ScoredReading] = []
    for risk in ["High", "Medium", "Normal"] {
        var reading = VitalsReading.demo(risk: risk)
        reading.source = "apple_watch"
        if risk == "High" {
            reading.consciousness = .voice
            reading.systolicBP = Vital(85, provenance: .manual)
        }
        scored.append(ScoredReading(
            reading: reading, prediction: try scorer.score(reading), failure: nil
        ))
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(scored).write(to: URL(fileURLWithPath: arguments[flag + 1]))
    check(true, "wrote \(scored.count)-reading history")
}

print(failures == 0 ? "\nALL ON-DEVICE MODEL CHECKS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
