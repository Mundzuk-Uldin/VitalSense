import Foundation
import WatchConnectivity

/// Gets a reading scored and the answer back onto the wrist.
///
/// The normal path is to hand the reading to the iPhone, which owns the
/// server address and the manually-entered vitals the watch cannot know
/// about. When the phone is out of range the watch calls the API itself, so
/// a demo does not collapse the moment someone walks away from their phone.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {

    @Published private(set) var prediction: RiskPrediction?
    @Published private(set) var isSending = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPhoneReachable = false

    /// Pushed down from the iPhone so the two stay in step, and remembered
    /// across launches for the direct fallback.
    @Published private(set) var apiBaseURL = UserDefaults.standard.string(
        forKey: AppSettings.Key.apiBaseURL
    ) ?? AppSettings.defaultAPIBaseURL

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

    func send(_ reading: VitalsReading) async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        if let session, session.isReachable {
            statusMessage = "Scoring on iPhone…"
            if await sendViaPhone(reading, session: session) { return }
            // Fall through: the phone answered but could not score it, which
            // usually means its server address is wrong. Try ourselves.
        }

        statusMessage = "iPhone unreachable — asking the server directly"
        await sendDirectly(reading)

        // Queue it for the phone regardless, so its history stays complete
        // once the two are back in range.
        if let session, let payload = try? ConnectivityPayload.encode(
            reading, key: ConnectivityPayload.readingKey
        ) {
            session.transferUserInfo(payload)
        }
    }

    private func sendViaPhone(_ reading: VitalsReading, session: WCSession) async -> Bool {
        guard let payload = try? ConnectivityPayload.encode(
            reading, key: ConnectivityPayload.readingKey
        ) else { return false }

        let reply: [String: Any]? = await withCheckedContinuation { continuation in
            var resumed = false
            session.sendMessage(payload) { response in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: response)
            } errorHandler: { _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }

        guard let reply else { return false }

        if let prediction = ConnectivityPayload.decode(
            RiskPrediction.self, from: reply, key: ConnectivityPayload.predictionKey
        ) {
            self.prediction = prediction
            statusMessage = "Scored on iPhone"
            return true
        }

        if let message = reply[ConnectivityPayload.errorKey] as? String {
            errorMessage = message
        }
        return false
    }

    private func sendDirectly(_ reading: VitalsReading) async {
        guard let client = RiskAPIClient(rawBaseURL: apiBaseURL) else {
            errorMessage = "\(apiBaseURL) is not a valid server address."
            return
        }
        do {
            prediction = try await client.predict(reading)
            statusMessage = "Scored on watch"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Not scored"
        }
    }

    private func adopt(_ context: [String: Any]) {
        guard let url = context[AppSettings.Key.apiBaseURL] as? String, !url.isEmpty else { return }
        apiBaseURL = url
        UserDefaults.standard.set(url, forKey: AppSettings.Key.apiBaseURL)
    }
}

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isPhoneReachable = reachable
            self?.adopt(context)
            if let error {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.isPhoneReachable = reachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.adopt(context)
        }
    }

    /// The phone can also push a prediction unprompted -- for instance after
    /// the user edits the manual vitals and the last reading is re-scored.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let prediction = ConnectivityPayload.decode(
            RiskPrediction.self, from: message, key: ConnectivityPayload.predictionKey
        ) else { return }
        Task { @MainActor [weak self] in
            self?.prediction = prediction
            self?.statusMessage = "Updated by iPhone"
        }
    }
}
