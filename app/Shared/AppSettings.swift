import Foundation

/// Keys the apps store settings under.
///
/// There is no server address here any more: the model runs on the device,
/// so there is nothing to configure before the app works.
enum AppSettings {
    enum Key {
        static let systolicBP = "manualSystolicBP"
        static let hasManualBP = "hasManualBP"
        static let consciousness = "manualConsciousness"
        static let onOxygen = "manualOnOxygen"
        static let o2Scale = "manualO2Scale"
        static let history = "scoredReadingHistory"
    }

    /// The most readings the iPhone keeps. Enough to show a trend, small
    /// enough that the whole history stays cheap to encode on every change.
    static let historyLimit = 100
}
