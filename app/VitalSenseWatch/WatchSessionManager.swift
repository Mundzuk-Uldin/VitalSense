import Foundation
import WatchConnectivity

/// Sends a scored reading to the iPhone.
///
/// The watch carries the same Core ML model as the phone, so it scores its
/// own reading and shows the answer immediately — no round trip, and no
/// dependency on the phone being in range or on there being a network at
/// all. The phone is told about it so the history stays complete.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {

    @Published private(set) var isPhoneReachable = false
    @Published private(set) var didSyncLatest = false
    @Published private(set) var errorMessage: String?

    private var session: WCSession?

    func activate() {
        guard WCSession.isSupported() else {
            errorMessage = "This watch cannot talk to an iPhone."
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    /// Hand the reading and its score to the phone.
    ///
    /// `sendMessage` when it is listening, `transferUserInfo` otherwise —
    /// the queued path survives the phone being asleep or out of range and
    /// delivers when it is back. Either way the watch has already shown the
    /// result, so nothing here is on the critical path.
    func sync(reading: VitalsReading, prediction: RiskPrediction?) {
        guard let session else { return }

        var payload: [String: Any] = [:]
        guard let readingPayload = try? ConnectivityPayload.encode(
            reading, key: ConnectivityPayload.readingKey
        ) else { return }
        payload.merge(readingPayload) { current, _ in current }

        if let prediction, let predictionPayload = try? ConnectivityPayload.encode(
            prediction, key: ConnectivityPayload.predictionKey
        ) {
            payload.merge(predictionPayload) { current, _ in current }
        }

        didSyncLatest = false
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { [weak self] _ in
                Task { @MainActor in self?.didSyncLatest = true }
            }, errorHandler: { [weak self] _ in
                // Fall back to the queue rather than losing the reading.
                session.transferUserInfo(payload)
                Task { @MainActor in self?.didSyncLatest = false }
            })
        } else {
            session.transferUserInfo(payload)
        }
    }

    private func refreshReachability(_ session: WCSession) {
        isPhoneReachable = session.isReachable
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isPhoneReachable = reachable
            if let error { self?.errorMessage = error.localizedDescription }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isPhoneReachable = reachable
        }
    }
}
