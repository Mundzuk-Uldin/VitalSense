import Foundation

/// Decoded `/predict` response.
struct RiskPrediction: Codable, Hashable, Identifiable, Sendable {
    var id: UUID { UUID() }

    let riskLevel: RiskLevel
    let confidence: Double
    let probabilities: [String: Double]

    let news2Total: Int
    let news2Band: String
    let hasRedScore: Bool

    let riskFactors: [RiskFactor]
    let topFactors: [String]
    let recommendation: String

    let modelVersion: String
    let predictedAt: Date

    enum CodingKeys: String, CodingKey {
        case riskLevel = "risk_level"
        case confidence
        case probabilities
        case news2Total = "news2_total"
        case news2Band = "news2_band"
        case hasRedScore = "has_red_score"
        case riskFactors = "risk_factors"
        case topFactors = "top_factors"
        case recommendation
        case modelVersion = "model_version"
        case predictedAt = "predicted_at"
    }

    /// Probabilities in clinical order rather than dictionary order, so the
    /// bar chart does not reshuffle itself between readings.
    var orderedProbabilities: [(level: RiskLevel, probability: Double)] {
        RiskLevel.allCases.map { ($0, probabilities[$0.rawValue] ?? 0) }
    }

    /// Only the vitals that actually contributed points.
    var contributingFactors: [RiskFactor] {
        riskFactors.filter { $0.score > 0 }
    }
}

enum RiskLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case normal = "Normal"
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    /// Ascending acuity, used to order the probability chart and to decide
    /// whether a new reading is worse than the last one.
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

struct RiskFactor: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let label: String
    let value: Double
    let displayValue: String
    let score: Int
    let severity: Severity
    let note: String

    enum CodingKeys: String, CodingKey {
        case name, label, value, score, severity, note
        case displayValue = "display_value"
    }

    enum Severity: String, Codable, Hashable, Sendable {
        case normal, mild, moderate, severe
    }

    var symbolName: String {
        switch name {
        case "heart_rate": return "heart.fill"
        case "oxygen_saturation": return "lungs.fill"
        case "respiratory_rate": return "wind"
        case "temperature": return "thermometer.medium"
        case "systolic_bp": return "gauge.with.dots.needle.33percent"
        case "consciousness": return "brain.head.profile"
        case "on_oxygen": return "facemask.fill"
        default: return "waveform.path.ecg"
        }
    }
}

/// A reading paired with whatever the model said about it. This is the unit
/// the iPhone stores and lists.
struct ScoredReading: Codable, Hashable, Identifiable, Sendable {
    var id: UUID { reading.id }
    var reading: VitalsReading
    var prediction: RiskPrediction?
    /// Set when the reading arrived but scoring failed, so the history can
    /// show the reading with an honest error instead of dropping it.
    var failure: String?
}
