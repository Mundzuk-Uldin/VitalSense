import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: RiskStore

    var body: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty {
                    ContentUnavailableView(
                        "No history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Scored readings from your watch collect here.")
                    )
                } else {
                    List {
                        ForEach(store.history) { scored in
                            NavigationLink {
                                ReadingDetailView(scored: scored)
                            } label: {
                                HistoryRow(scored: scored)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !store.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { store.clearHistory() }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let scored: ScoredReading

    var body: some View {
        HStack(spacing: 12) {
            if let prediction = scored.prediction {
                Image(systemName: prediction.riskLevel.symbolName)
                    .foregroundStyle(prediction.riskLevel.tint)
                    .frame(width: 24)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(scored.prediction?.riskLevel.rawValue ?? "Not scored")
                    .font(.body.weight(.medium))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(scored.reading.recordedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                if let prediction = scored.prediction {
                    Text("NEWS2 \(prediction.news2Total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        if let driver = scored.prediction?.topFactors.first { return driver }
        if let failure = scored.failure { return failure }
        return "—"
    }
}

struct ReadingDetailView: View {
    let scored: ScoredReading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let prediction = scored.prediction {
                    HStack(spacing: 12) {
                        Image(systemName: prediction.riskLevel.symbolName)
                            .font(.largeTitle)
                            .foregroundStyle(prediction.riskLevel.tint)
                        VStack(alignment: .leading) {
                            Text(prediction.riskLevel.headline)
                                .font(.title2.weight(.semibold))
                            Text(scored.reading.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(prediction.riskLevel.wash, in: RoundedRectangle(cornerRadius: 16))

                    Text(prediction.recommendation)
                        .font(.subheadline)

                    MeasurementSourceSection(reading: scored.reading)
                    Divider()
                    AllFactorsSection(prediction: prediction)
                    Divider()
                    ProbabilityChart(prediction: prediction)
                } else {
                    Label(scored.failure ?? "Not scored", systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                    MeasurementSourceSection(reading: scored.reading)
                }
            }
            .padding()
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The detail screen shows every vital, including the ones that scored zero,
/// so "nothing wrong with your blood pressure" is visible rather than merely
/// absent.
private struct AllFactorsSection: View {
    let prediction: RiskPrediction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All vitals")
                .font(.subheadline.weight(.semibold))
            ForEach(prediction.riskFactors) { factor in
                RiskFactorRow(factor: factor)
            }
        }
    }
}
