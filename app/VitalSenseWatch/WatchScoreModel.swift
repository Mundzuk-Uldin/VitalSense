import Foundation

/// Scores a reading on the watch itself.
///
/// The watch holds the same 17 KB Core ML model as the phone, so the risk
/// band appears as fast as the sensors can produce a reading, with no phone
/// and no network involved. The phone is told afterwards, for its history.
@MainActor
final class WatchScoreModel: ObservableObject {

    @Published private(set) var prediction: RiskPrediction?
    @Published private(set) var isScoring = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private let scorer: RiskScorer?

    init() {
        do {
            scorer = try RiskScorer()
        } catch {
            scorer = nil
            errorMessage = error.localizedDescription
        }
    }

    func score(_ reading: VitalsReading, syncingWith connectivity: WatchSessionManager) {
        guard let scorer else {
            errorMessage = errorMessage ?? "The risk model is unavailable."
            return
        }

        isScoring = true
        defer { isScoring = false }

        do {
            let prediction = try scorer.score(reading)
            self.prediction = prediction
            errorMessage = nil
            statusMessage = "Scored on watch"
            connectivity.sync(reading: reading, prediction: prediction)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Not scored"
            // Send the reading anyway; the phone may still be able to score it.
            connectivity.sync(reading: reading, prediction: nil)
        }
    }
}
