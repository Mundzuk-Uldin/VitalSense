import Foundation
import WatchConnectivity

/// The iPhone's half of the watch link.
///
/// Readings arrive here; the store scores them and the answer goes straight
/// back in the reply, so the watch gets its result without a second round
/// trip.
@MainActor
final class PhoneSessionManager: NSObject, ObservableObject {

    @Published private(set) var isWatchPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastReceivedAt: Date?

    /// Set by `RiskStore`. Returns the prediction to send back to the watch.
    var onReadingReceived: ((VitalsReading) async -> RiskPrediction?)?

    private var session: WCSession?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    /// Keep the watch's copy of the server address in step with ours, so its
    /// direct fallback points somewhere real.
    func pushSettings(apiBaseURL: String) {
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext([AppSettings.Key.apiBaseURL: apiBaseURL])
    }

    /// Send a prediction the watch did not ask for -- after a re-score, say.
    func push(prediction: RiskPrediction) {
        guard let session, session.isReachable,
              let payload = try? ConnectivityPayload.encode(
                  prediction, key: ConnectivityPayload.predictionKey
              )
        else { return }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    private func refreshState(_ session: WCSession) {
        isWatchPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    fileprivate func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let reading = ConnectivityPayload.decode(
            VitalsReading.self, from: message, key: ConnectivityPayload.readingKey
        ) else {
            return [ConnectivityPayload.errorKey: "The iPhone could not read that message."]
        }

        lastReceivedAt = Date()

        guard let prediction = await onReadingReceived?(reading) else {
            return [ConnectivityPayload.errorKey: "The iPhone could not reach the risk server."]
        }
        return (try? ConnectivityPayload.encode(
            prediction, key: ConnectivityPayload.predictionKey
        )) ?? [ConnectivityPayload.errorKey: "The iPhone could not encode the result."]
    }
}

extension PhoneSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in self?.refreshState(session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshState(session) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required on iOS so a newly paired watch gets a fresh session.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler([ConnectivityPayload.errorKey: "iPhone is not ready."])
                return
            }
            replyHandler(await self.handle(message))
        }
    }

    /// The queued path, used when the watch scored a reading by itself while
    /// out of range. There is nobody to reply to; we just record it.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor [weak self] in
            _ = await self?.handle(userInfo)
        }
    }
}
