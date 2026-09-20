import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension RiskLevel {
    /// The reserved status palette: good / warning / serious / critical.
    ///
    /// These four steps are mode-invariant -- they clear 3:1 on a dark
    /// surface, and on a light surface the two middle steps sit below 3:1 by
    /// design. The mitigation, which this app follows everywhere, is that a
    /// risk colour never appears without its SF Symbol and its written name,
    /// so colour alone never carries the meaning.
    var tint: Color {
        switch self {
        case .normal: return Color(hex: 0x0CA30C)
        case .low: return Color(hex: 0xFAB219)
        case .medium: return Color(hex: 0xEC835A)
        case .high: return Color(hex: 0xD03B3B)
        }
    }

    /// A recessive wash for card backgrounds. Kept faint so that text sitting
    /// on it keeps its own ink colour and its own contrast.
    var wash: Color { tint.opacity(0.14) }

    var headline: String {
        switch self {
        case .normal: return "No concern"
        case .low: return "Low risk"
        case .medium: return "Medium risk"
        case .high: return "High risk"
        }
    }
}

extension RiskFactor.Severity {
    /// Per-vital severity reuses the same reserved four steps, so a vital
    /// scoring 3 is the same red as a High reading.
    var tint: Color {
        switch self {
        case .normal: return Color(hex: 0x0CA30C)
        case .mild: return Color(hex: 0xFAB219)
        case .moderate: return Color(hex: 0xEC835A)
        case .severe: return Color(hex: 0xD03B3B)
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .mild: return "Mild"
        case .moderate: return "Moderate"
        case .severe: return "Severe"
        }
    }
}
