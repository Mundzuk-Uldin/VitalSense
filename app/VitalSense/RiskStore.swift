import Foundation
import Combine

/// The iPhone's single source of truth.
///
/// It owns two things the watch does not: the vitals a wrist sensor can
/// never measure, and the history. A reading arrives from the watch carrying
/// only what the sensors saw; this is where the rest is filled in and the
/// on-device model is asked for an answer.
@MainActor
final class RiskStore: ObservableObject {

    @Published private(set) var history: [ScoredReading] = []
    @Published private(set) var isScoring = false
    @Published private(set) var modelError: String?

    // Vitals NEWS2 needs but no Apple Watch can measure. They stay at their
    // clinically normal defaults until someone enters something better, and
    // the UI is explicit about which is which.
    @Published var systolicBP: Double { didSet { defaults.set(systolicBP, forKey: AppSettings.Key.systolicBP) } }
    @Published var hasManualBP: Bool { didSet { defaults.set(hasManualBP, forKey: AppSettings.Key.hasManualBP) } }
    @Published var consciousness: Consciousness {
        didSet { defaults.set(consciousness.rawValue, forKey: AppSettings.Key.consciousness) }
    }
    @Published var onOxygen: Bool { didSet { defaults.set(onOxygen, forKey: AppSettings.Key.onOxygen) } }
    @Published var o2Scale: Int { didSet { defaults.set(o2Scale, forKey: AppSettings.Key.o2Scale) } }

    let connectivity = PhoneSessionManager()

    private let defaults = UserDefaults.standard
    private let scorer: RiskScorer?

    var latest: ScoredReading? { history.first }
    var modelVersion: String { scorer?.version ?? "unavailable" }

    init() {
        systolicBP = defaults.object(forKey: AppSettings.Key.systolicBP) as? Double ?? 120
        hasManualBP = defaults.bool(forKey: AppSettings.Key.hasManualBP)
        consciousness = Consciousness(
            rawValue: defaults.string(forKey: AppSettings.Key.consciousness) ?? "A"
        ) ?? .alert
        onOxygen = defaults.bool(forKey: AppSettings.Key.onOxygen)
        o2Scale = defaults.object(forKey: AppSettings.Key.o2Scale) as? Int ?? 1

        // Loading the model is the one thing here that can fail, and it fails
        // at launch rather than mid-demo. If it does, every reading still
        // records with an honest reason attached.
        do {
            scorer = try RiskScorer()
        } catch {
            scorer = nil
            modelError = error.localizedDescription
        }

        loadHistory()

        // The watch scores its own reading so the wrist gets an instant
        // answer, but the phone scores it again before recording: only the
        // phone knows the manually entered blood pressure and ACVPU, and a
        // watch reading carries the assumed defaults for both. Scoring is
        // local and takes about a millisecond, so there is no reason to
        // trust the watch's copy over a fresh one.
        connectivity.onReadingReceived = { [weak self] reading, watchPrediction in
            self?.ingest(reading, watchPrediction: watchPrediction)
        }
        connectivity.activate()
    }

    // MARK: - Scoring

    /// Fill in the vitals the watch could not measure and ask the model,
    /// without recording anything. Kept separate from `score` so a caller
    /// can decide what to do with a failure before it lands in the history.
    private func evaluate(
        _ reading: VitalsReading
    ) -> (reading: VitalsReading, result: Result<RiskPrediction, Error>) {
        let completed = applyManualVitals(to: reading)
        guard let scorer else {
            return (completed, .failure(RiskScorer.Failure.modelMissing))
        }
        return (completed, Result { try scorer.score(completed) })
    }

    /// Score a reading and record it.
    @discardableResult
    func score(_ reading: VitalsReading) -> RiskPrediction? {
        isScoring = true
        defer { isScoring = false }

        let (completed, result) = evaluate(reading)
        switch result {
        case .success(let prediction):
            record(ScoredReading(reading: completed, prediction: prediction, failure: nil))
            return prediction
        case .failure(let error):
            record(ScoredReading(
                reading: completed, prediction: nil, failure: error.localizedDescription
            ))
            return nil
        }
    }

    /// Record a reading that arrived from the watch.
    ///
    /// The phone's own score wins, because it is the only one that accounts
    /// for the manual vitals. The watch's answer is the fallback for the one
    /// case where the phone cannot score at all -- its model failed to load
    /// -- so a reading is never lost just because this device is broken.
    private func ingest(
        _ reading: VitalsReading, watchPrediction: RiskPrediction?
    ) -> RiskPrediction? {
        let (completed, result) = evaluate(reading)

        if case .success(let prediction) = result {
            record(ScoredReading(reading: completed, prediction: prediction, failure: nil))
            return prediction
        }
        if let watchPrediction {
            record(ScoredReading(reading: completed, prediction: watchPrediction, failure: nil))
            return watchPrediction
        }
        if case .failure(let error) = result {
            record(ScoredReading(
                reading: completed, prediction: nil, failure: error.localizedDescription
            ))
        }
        return nil
    }

    /// Re-run the most recent reading. Used after the manual vitals change,
    /// so the displayed risk always matches what is on screen.
    func rescoreLatest() {
        guard let latest else { return }
        var reading = latest.reading
        reading.id = UUID()
        reading.recordedAt = Date()
        if let prediction = score(reading) {
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
