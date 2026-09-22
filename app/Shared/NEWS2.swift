import Foundation

/// NEWS2 — the Royal College of Physicians' National Early Warning Score 2.
///
/// This does two jobs.
///
/// It **explains** a prediction. A neural network cannot tell a nurse why
/// someone scored High; NEWS2 decomposes cleanly into one sub-score per
/// vital, which is what the apps put on screen.
///
/// It also **feeds** the model: the aggregate, the worst single component
/// and the count of abnormal vitals are three of the ten inputs. Handing
/// those to the network saves it rediscovering the clinical cut-points from
/// a thousand rows.
///
/// Ported from `model/news2.py`. The two must agree, or the features the app
/// computes will not be the features the model was trained on —
/// `tools/check_model.sh` exists to catch exactly that.
enum NEWS2 {

    /// One vital's contribution to the aggregate score.
    struct Component: Hashable {
        let vital: VitalKind
        let value: Double
        let score: Int
        /// Human-readable value, e.g. "132 bpm".
        let detail: String

        var severity: RiskFactor.Severity {
            switch score {
            case 0: return .normal
            case 1: return .mild
            case 2: return .moderate
            default: return .severe
            }
        }
    }

    enum VitalKind: String, Hashable, CaseIterable {
        case respiratoryRate = "respiratory_rate"
        case oxygenSaturation = "oxygen_saturation"
        case onOxygen = "on_oxygen"
        case systolicBP = "systolic_bp"
        case heartRate = "heart_rate"
        case temperature = "temperature"
        case consciousness = "consciousness"

        var label: String {
            switch self {
            case .respiratoryRate: return "Respiratory rate"
            case .oxygenSaturation: return "Oxygen saturation"
            case .onOxygen: return "Supplemental oxygen"
            case .systolicBP: return "Systolic blood pressure"
            case .heartRate: return "Heart rate"
            case .temperature: return "Temperature"
            case .consciousness: return "Consciousness"
            }
        }

        var symbolName: String {
            switch self {
            case .respiratoryRate: return "wind"
            case .oxygenSaturation: return "lungs.fill"
            case .onOxygen: return "facemask.fill"
            case .systolicBP: return "gauge.with.dots.needle.33percent"
            case .heartRate: return "heart.fill"
            case .temperature: return "thermometer.medium"
            case .consciousness: return "brain.head.profile"
            }
        }
    }

    // MARK: - Per-vital scoring

    private static func respiratoryRateScore(_ rate: Double) -> Int {
        switch rate {
        case ..<8.001: return 3
        case ..<11.001: return 1
        case ..<20.001: return 0
        case ..<24.001: return 2
        default: return 3
        }
    }

    private static func saturationScoreScale1(_ saturation: Double) -> Int {
        switch saturation {
        case ..<91.001: return 3
        case ..<93.001: return 2
        case ..<95.001: return 1
        default: return 0
        }
    }

    /// Scale 2 is for people in hypercapnic respiratory failure, whose target
    /// range is a deliberately lower 88–92%. Above that range they are only
    /// penalised while actually receiving oxygen.
    private static func saturationScoreScale2(_ saturation: Double, onOxygen: Bool) -> Int {
        switch saturation {
        case ..<83.001: return 3
        case ..<85.001: return 2
        case ..<87.001: return 1
        case ..<92.001: return 0
        default:
            guard onOxygen else { return 0 }
            switch saturation {
            case ..<94.001: return 1
            case ..<96.001: return 2
            default: return 3
            }
        }
    }

    private static func systolicScore(_ pressure: Double) -> Int {
        switch pressure {
        case ..<90.001: return 3
        case ..<100.001: return 2
        case ..<110.001: return 1
        case ..<219.001: return 0
        default: return 3
        }
    }

    private static func heartRateScore(_ rate: Double) -> Int {
        switch rate {
        case ..<40.001: return 3
        case ..<50.001: return 1
        case ..<90.001: return 0
        case ..<110.001: return 1
        case ..<130.001: return 2
        default: return 3
        }
    }

    private static func temperatureScore(_ celsius: Double) -> Int {
        switch celsius {
        case ..<35.001: return 3
        case ..<36.001: return 1
        case ..<38.001: return 0
        case ..<39.001: return 1
        default: return 2
        }
    }

    // MARK: - Aggregate

    static func components(for reading: VitalsReading) -> [Component] {
        let saturationScore = reading.o2Scale == 2
            ? saturationScoreScale2(reading.oxygenSaturation.value, onOxygen: reading.onOxygen)
            : saturationScoreScale1(reading.oxygenSaturation.value)

        return [
            Component(
                vital: .respiratoryRate,
                value: reading.respiratoryRate.value,
                score: respiratoryRateScore(reading.respiratoryRate.value),
                detail: "\(Int(reading.respiratoryRate.value.rounded())) breaths/min"
            ),
            Component(
                vital: .oxygenSaturation,
                value: reading.oxygenSaturation.value,
                score: saturationScore,
                detail: "\(Int(reading.oxygenSaturation.value.rounded()))% (scale \(reading.o2Scale))"
            ),
            Component(
                vital: .onOxygen,
                value: reading.onOxygen ? 1 : 0,
                score: reading.onOxygen ? 2 : 0,
                detail: reading.onOxygen ? "supplemental oxygen" : "breathing room air"
            ),
            Component(
                vital: .systolicBP,
                value: reading.systolicBP.value,
                score: systolicScore(reading.systolicBP.value),
                detail: "\(Int(reading.systolicBP.value.rounded())) mmHg"
            ),
            Component(
                vital: .heartRate,
                value: reading.heartRate.value,
                score: heartRateScore(reading.heartRate.value),
                detail: "\(Int(reading.heartRate.value.rounded())) bpm"
            ),
            Component(
                vital: .temperature,
                value: reading.temperature.value,
                score: temperatureScore(reading.temperature.value),
                detail: String(format: "%.1f °C", reading.temperature.value)
            ),
            Component(
                vital: .consciousness,
                value: reading.consciousness == .alert ? 0 : 3,
                score: reading.consciousness == .alert ? 0 : 3,
                detail: reading.consciousness.displayName
            ),
        ]
    }

    static func aggregate(_ components: [Component]) -> Int {
        components.reduce(0) { $0 + $1.score }
    }

    /// A 3 in any single parameter is a "red score" and escalates the
    /// response on its own, however low the aggregate.
    static func hasRedScore(_ components: [Component]) -> Bool {
        components.contains { $0.score >= 3 }
    }

    static func abnormalCount(_ components: [Component]) -> Int {
        components.count { $0.score > 0 }
    }

    static func maxComponent(_ components: [Component]) -> Int {
        components.map(\.score).max() ?? 0
    }

    /// The published banding, used as a sanity check beside the model's own
    /// answer rather than as the answer itself.
    static func band(_ components: [Component]) -> RiskLevel {
        let total = aggregate(components)
        if total == 0 { return .normal }
        if total >= 7 { return .high }
        if total >= 5 { return .medium }
        return hasRedScore(components) ? .medium : .low
    }

    static func recommendation(for level: RiskLevel) -> String {
        switch level {
        case .normal:
            return "All vitals within range. Continue routine monitoring."
        case .low:
            return "Minor deviation. Repeat observations within 4-6 hours."
        case .medium:
            return "Escalate to a registered nurse. Hourly observations; "
                + "urgent review by a clinician competent in acute illness."
        case .high:
            return "Emergency response. Continuous monitoring and immediate "
                + "assessment by a critical-care-capable team."
        }
    }
}
