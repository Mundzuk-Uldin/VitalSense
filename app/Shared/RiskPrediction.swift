import Foundation

/// What the on-device model said about one reading.
///
/// Built locally by `RiskScorer`. It stays `Codable` because it is persisted
/// in the iPhone's history and sent from the watch to the phone over
/// WatchConnectivity.
struct RiskPrediction: Codable, Hashable, Sendable {
    let riskLevel: RiskLevel
    let confidence: Double
    let probabilities: [RiskLevel: Double]

    let news2Total: Int
    let news2Band: RiskLevel
    /// True when any single vital scores 3, which escalates on its own.
    let hasRedScore: Bool

    /// All seven vitals, most concerning first.
    let riskFactors: [RiskFactor]
    let topFactors: [String]
    let recommendation: String

    let modelVersion: String
    let predictedAt: Date

    /// Probabilities in clinical order rather than dictionary order, so the
    /// chart does not reshuffle itself between readings.
    var orderedProbabilities: [(level: RiskLevel, probability: Double)] {
        RiskLevel.allCases.map { ($0, probabilities[$0] ?? 0) }
    }

    var contributingFactors: [RiskFactor] {
        riskFactors.filter { $0.score > 0 }
    }

    /// True when the model's answer differs from the published NEWS2
    /// banding. Rare, and worth surfacing rather than hiding: it means the
    /// model learned something the rulebook does not encode.
    var disagreesWithRulebook: Bool {
        riskLevel != news2Band
    }
}

enum RiskLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case normal = "Normal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    /// Ascending acuity.
    var severity: Int {
        switch self {
        case .normal: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .low: return "info.circle.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.octagon.fill"
        }
    }
}

/// Lets `[RiskLevel: Double]` encode as a normal JSON object keyed by name.
/// Without this, Swift falls back to a flat alternating array, which still
/// round-trips but is horrible to read in a stored history.
extension RiskLevel: CodingKeyRepresentable {
    public var codingKey: any CodingKey {
        StringCodingKey(stringValue: rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct RiskFactor: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let label: String
    let value: Double
    let displayValue: String
    let score: Int
    let severity: Severity
    let note: String
    let symbolName: String

    enum Severity: String, Codable, Hashable, Sendable {
        case normal, mild, moderate, severe
    }
}

/// A reading paired with whatever the model said about it. This is the unit
/// the iPhone stores and lists.
struct ScoredReading: Codable, Hashable, Identifiable, Sendable {
    var id: UUID { reading.id }
    var reading: VitalsReading
    var prediction: RiskPrediction?
    /// Set when a reading arrived but scoring failed, so the history can show
    /// it with an honest reason instead of dropping it.
    var failure: String?
}
