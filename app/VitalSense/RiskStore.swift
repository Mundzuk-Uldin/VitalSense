import Foundation
import Combine

/// The iPhone's single source of truth.
///
/// It owns three things the watch cannot: the server address, the vitals a
/// wrist sensor can never measure, and the history. A reading arrives from
/// the watch carrying only what the sensors saw; this is where the rest is
/// filled in and the model is asked for an answer.
@MainActor
final class RiskStore: ObservableObject {

    @Published private(set) var history: [ScoredReading] = []
    @Published private(set) var isScoring = false
    @Published var lastError: String?

    @Published var apiBaseURL: String {
        didSet {
            defaults.set(apiBaseURL, forKey: AppSettings.Key.apiBaseURL)
            connectivity.pushSettings(apiBaseURL: apiBaseURL)
        }
    }

    // Vitals NEWS2 needs but no Apple Watch can measure. They stay at their
    // clinically normal defaults until someone enters something better, and
    // the UI is explicit about which is which.
    @Published var systolicBP: Double { didSet { defaults.set(systolicBP, forKey: AppSettings.Key.systolicBP) } }
    @Published var hasManualBP: Bool { didSet { defaults.set(hasManualBP, forKey: "hasManualBP") } }
    @Published var consciousness: Consciousness {
        didSet { defaults.set(consciousness.rawValue, forKey: AppSettings.Key.consciousness) }
    }
    @Published var onOxygen: Bool { didSet { defaults.set(onOxygen, forKey: AppSettings.Key.onOxygen) } }
    @Published var o2Scale: Int { didSet { defaults.set(o2Scale, forKey: AppSettings.Key.o2Scale) } }

    let connectivity = PhoneSessionManager()

    private let defaults = UserDefaults.standard

    var latest: ScoredReading? { history.first }

    init() {
        apiBaseURL = defaults.string(forKey: AppSettings.Key.apiBaseURL) ?? AppSettings.defaultAPIBaseURL
        systolicBP = defaults.object(forKey: AppSettings.Key.systolicBP) as? Double ?? 120
        hasManualBP = defaults.bool(forKey: "hasManualBP")
        consciousness = Consciousness(
            rawValue: defaults.string(forKey: AppSettings.Key.consciousness) ?? "A"
        ) ?? .alert
        onOxygen = defaults.bool(forKey: AppSettings.Key.onOxygen)
        o2Scale = defaults.object(forKey: AppSettings.Key.o2Scale) as? Int ?? 1

        loadHistory()

        // The watch hands us a reading and waits for the answer, so the
        // handler returns the prediction rather than just recording it.
        connectivity.onReadingReceived = { [weak self] reading in
            guard let self else { return nil }
            return await self.score(reading)
        }
        connectivity.activate()
        connectivity.pushSettings(apiBaseURL: apiBaseURL)
    }

    // MARK: - Scoring

    /// Fill in the vitals the watch could not measure, ask the model, and
    /// record the result. Returns the prediction so the watch can show it.
    @discardableResult
    func score(_ reading: VitalsReading) async -> RiskPrediction? {
        isScoring = true
        defer { isScoring = false }

        let completed = applyManualVitals(to: reading)

        guard let client = RiskAPIClient(rawBaseURL: apiBaseURL) else {
            let message = "\(apiBaseURL) is not a valid server address."
            lastError = message
            record(ScoredReading(reading: completed, prediction: nil, failure: message))
            return nil
        }

        do {
            let prediction = try await client.predict(completed)
            lastError = nil
            record(ScoredReading(reading: completed, prediction: prediction, failure: nil))
            return prediction
        } catch {
            let message = error.localizedDescription
            lastError = message
            record(ScoredReading(reading: completed, prediction: nil, failure: message))
            return nil
        }
    }

    /// Re-run the most recent reading. Used after the manual vitals change,
    /// so the displayed risk always matches what is on screen.
    func rescoreLatest() async {
        guard let latest else { return }
        var reading = latest.reading
        reading.id = UUID()
        reading.recordedAt = Date()
        if let prediction = await score(reading) {
            connectivity.push(prediction: prediction)
        }
    }

    private func applyManualVitals(to reading: VitalsReading) -> VitalsReading {
        var reading = reading
        reading.systolicBP = hasManualBP
            ? Vital(systolicBP, provenance: .manual)
            : .assumed(120)
        reading.consciousness = consciousness
        reading.onOxygen = onOxygen
        reading.o2Scale = o2Scale
        return reading
    }

    // MARK: - History

    private func record(_ scored: ScoredReading) {
        history.insert(scored, at: 0)
        if history.count > AppSettings.historyLimit {
            history.removeLast(history.count - AppSettings.historyLimit)
        }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: AppSettings.Key.history) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        history = (try? decoder.decode([ScoredReading].self, from: data)) ?? []
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        defaults.set(data, forKey: AppSettings.Key.history)
    }
}
