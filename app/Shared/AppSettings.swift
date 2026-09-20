import Foundation

/// Settings that both apps read, and the keys they are stored under.
enum AppSettings {
    /// Where the FastAPI service lives. `localhost` is right for the iOS
    /// Simulator, which shares the Mac's network stack; a real iPhone needs
    /// the Mac's LAN address, which the user sets on the Settings screen.
    static let defaultAPIBaseURL = "http://localhost:8000"

    enum Key {
        static let apiBaseURL = "apiBaseURL"
        static let systolicBP = "manualSystolicBP"
        static let consciousness = "manualConsciousness"
        static let onOxygen = "manualOnOxygen"
        static let o2Scale = "manualO2Scale"
        static let history = "scoredReadingHistory"
    }

    /// The most readings the iPhone keeps. Enough to show a trend, small
    /// enough that the whole history stays cheap to encode on every change.
    static let historyLimit = 100
}
