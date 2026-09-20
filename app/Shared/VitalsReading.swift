import Foundation

/// Where a single vital's value came from.
///
/// This matters more than it looks. An Apple Watch Series 9 can measure four
/// of the seven vitals NEWS2 wants, and only some of the time -- respiratory
/// rate and wrist temperature are derived overnight, and blood oxygen is
/// switched off on units sold in the US after January 2024. Rather than
/// silently substituting a normal value and showing a confident "Normal", we
/// track how we came by every number and say so in the UI.
enum VitalProvenance: String, Codable, Hashable, Sendable {
    /// Measured by the watch's sensors.
    case sensor
    /// Entered by a human on the iPhone.
    case manual
    /// A clinically normal stand-in, because nothing better was available.
    case assumed

    var isMeasured: Bool { self == .sensor }

    var shortLabel: String {
        switch self {
        case .sensor: return "Watch"
        case .manual: return "Manual"
        case .assumed: return "Assumed"
        }
    }
}

/// One vital sign, carrying its own provenance and sample time.
struct Vital: Codable, Hashable, Sendable {
    var value: Double
    var provenance: VitalProvenance
    var sampledAt: Date?

    init(_ value: Double, provenance: VitalProvenance = .sensor, sampledAt: Date? = nil) {
        self.value = value
        self.provenance = provenance
        self.sampledAt = sampledAt
    }

    static func assumed(_ value: Double) -> Vital {
        Vital(value, provenance: .assumed)
    }
}

/// Level of consciousness on the ACVPU scale.
enum Consciousness: String, Codable, CaseIterable, Hashable, Sendable {
    case alert = "A"
    case confusion = "C"
    case voice = "V"
    case pain = "P"
    case unresponsive = "U"

    var displayName: String {
        switch self {
        case .alert: return "Alert"
        case .confusion: return "New confusion"
        case .voice: return "Responds to voice"
        case .pain: return "Responds to pain"
        case .unresponsive: return "Unresponsive"
        }
    }
}

/// A complete set of vitals, ready to be scored.
///
/// The watch fills in what it can measure and leaves the rest at its assumed
/// default; the iPhone overlays whatever the user has entered by hand before
/// sending the reading to the model.
struct VitalsReading: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var recordedAt: Date = Date()

    // Measurable by an Apple Watch Series 9.
    var heartRate: Vital = .assumed(72)
    var oxygenSaturation: Vital = .assumed(98)
    var respiratoryRate: Vital = .assumed(16)
    var temperature: Vital = .assumed(37.0)

    // Not measurable by any Apple Watch; manual or assumed.
    var systolicBP: Vital = .assumed(120)
    var consciousness: Consciousness = .alert
    var onOxygen: Bool = false
    var o2Scale: Int = 1

    var source: String = "apple_watch"

    /// The vitals we genuinely measured, for the "N of 4 sensors reporting"
    /// line in the UI.
    var measuredVitals: [(name: String, vital: Vital)] {
        [
            ("Heart rate", heartRate),
            ("Oxygen saturation", oxygenSaturation),
            ("Respiratory rate", respiratoryRate),
            ("Temperature", temperature),
        ].filter { $0.vital.provenance.isMeasured }
    }

    var assumedVitalNames: [String] {
        var names: [String] = []
        if heartRate.provenance == .assumed { names.append("heart rate") }
        if oxygenSaturation.provenance == .assumed { names.append("blood oxygen") }
        if respiratoryRate.provenance == .assumed { names.append("respiratory rate") }
        if temperature.provenance == .assumed { names.append("temperature") }
        if systolicBP.provenance == .assumed { names.append("blood pressure") }
        return names
    }

    /// The payload shape the FastAPI `/predict` endpoint expects.
    func apiPayload() -> [String: Any] {
        [
            "respiratory_rate": respiratoryRate.value,
            "oxygen_saturation": oxygenSaturation.value,
            "heart_rate": heartRate.value,
            "temperature": temperature.value,
            "systolic_bp": systolicBP.value,
            "o2_scale": o2Scale,
            "consciousness": consciousness.rawValue,
            "on_oxygen": onOxygen,
            "source": source,
            "recorded_at": ISO8601DateFormatter().string(from: recordedAt),
        ]
    }

    /// A plausible reading, used by the on-watch demo mode and by SwiftUI
    /// previews. The Simulator has no HealthKit data at all, so without this
    /// there is nothing to show until you are on a real wrist.
    static func demo(risk: String = "Medium") -> VitalsReading {
        var reading = VitalsReading(source: "demo")
        switch risk {
        case "Normal":
            reading.heartRate = Vital(68, provenance: .sensor, sampledAt: Date())
            reading.oxygenSaturation = Vital(98, provenance: .sensor, sampledAt: Date())
            reading.respiratoryRate = Vital(15, provenance: .sensor, sampledAt: Date())
            reading.temperature = Vital(36.8, provenance: .sensor, sampledAt: Date())
        case "High":
            reading.heartRate = Vital(134, provenance: .sensor, sampledAt: Date())
            reading.oxygenSaturation = Vital(90, provenance: .sensor, sampledAt: Date())
            reading.respiratoryRate = Vital(27, provenance: .sensor, sampledAt: Date())
            reading.temperature = Vital(39.2, provenance: .sensor, sampledAt: Date())
            reading.systolicBP = Vital(92, provenance: .manual)
        default:
            reading.heartRate = Vital(96, provenance: .sensor, sampledAt: Date())
            reading.oxygenSaturation = Vital(94, provenance: .sensor, sampledAt: Date())
            reading.respiratoryRate = Vital(22, provenance: .sensor, sampledAt: Date())
            reading.temperature = Vital(37.9, provenance: .sensor, sampledAt: Date())
        }
        return reading
    }
}
