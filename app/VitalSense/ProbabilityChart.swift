import SwiftUI

/// How confident the model is across all four bands.
///
/// One axis, one bar per band, every bar directly labelled -- so there is no
/// legend to read and no colour-only encoding. Bars sit in clinical order
/// (Normal through High) rather than sorted by value, so the shape of the
/// chart means the same thing from one reading to the next.
struct ProbabilityChart: View {
    let prediction: RiskPrediction

    private let barHeight: CGFloat = 10
    private let cornerRadius: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model confidence")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 8) {
                ForEach(prediction.orderedProbabilities, id: \.level) { entry in
                    row(level: entry.level, probability: entry.probability)
                }
            }
        }
    }

    private func row(level: RiskLevel, probability: Double) -> some View {
        HStack(spacing: 10) {
            Text(level.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Recessive track, so an all-but-zero bar still reads as
                    // "a bar that is nearly empty" rather than as missing.
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: barHeight)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: cornerRadius,
                        topTrailingRadius: cornerRadius
                    )
                    .fill(level.tint)
                    .frame(
                        width: max(geometry.size.width * probability, probability > 0.001 ? 3 : 0),
                        height: barHeight
                    )
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: barHeight)

            Text(probability.formatted(.percent.precision(.fractionLength(0...1))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(level == prediction.riskLevel ? .primary : .secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level.rawValue): \(Int((probability * 100).rounded())) percent")
    }
}
