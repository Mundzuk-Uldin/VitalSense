import SwiftUI

/// The answer to "what does the watch say about me right now".
///
/// Three questions in order: what is the verdict, what did the watch
/// actually measure, and which vitals drove it.
struct LatestReadingView: View {
    @EnvironmentObject private var store: RiskStore
    @EnvironmentObject private var health: PhoneVitalsCollector
    @State private var showingManualVitals = false

    var body: some View {
        NavigationStack {
            Group {
                if let latest = store.latest {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let prediction = latest.prediction {
                                RiskVerdictCard(prediction: prediction, recordedAt: latest.reading.recordedAt)
                            } else {
                                FailureCard(message: latest.failure ?? "This reading was not scored.")
                            }

                            MeasurementSourceSection(reading: latest.reading)

                            if let prediction = latest.prediction {
                                Divider()
                                RiskFactorsSection(prediction: prediction)
                                Divider()
                                ProbabilityChart(prediction: prediction)
                                ModelFootnote(prediction: prediction)
                            }
                        }
                        .padding()
                    }
                } else {
                    EmptyStateView()
                }
            }
            .navigationTitle("Now")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { store.score(await health.read()) }
                    } label: {
                        if health.isReading {
                            ProgressView()
                        } else {
                            Label("Read from Health", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(health.isReading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingManualVitals = true
                    } label: {
                        Label("Other vitals", systemImage: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showingManualVitals) {
                ManualVitalsView()
            }
        }
    }
}

// MARK: - Verdict

private struct RiskVerdictCard: View {
    let prediction: RiskPrediction
    let recordedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: prediction.riskLevel.symbolName)
                    .font(.system(size: 40))
                    .foregroundStyle(prediction.riskLevel.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prediction.riskLevel.headline)
                        .font(.title2.weight(.semibold))
                    Text(recordedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(prediction.news2Total)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("NEWS2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if prediction.hasRedScore {
                Label(
                    "One vital is at the top of its range on its own.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(prediction.recommendation)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(prediction.riskLevel.wash, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FailureCard: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not scored", systemImage: "wifi.exclamationmark")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Check the server address in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - What the watch measured

/// Separates measurement from assumption.
///
/// Without this the app would quietly present four assumed-normal vitals as
/// though the watch had taken them, and a "Normal" verdict would mean
/// nothing. Each tile says where its number came from.
struct MeasurementSourceSection: View {
    let reading: VitalsReading

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(reading.source == "health" ? "From Health" : "From your watch")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(reading.measuredVitals.count) of 4 measured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                VitalTile(symbol: "heart.fill", title: "Heart rate",
                          vital: reading.heartRate, unit: "bpm", fractionDigits: 0)
                VitalTile(symbol: "lungs.fill", title: "Blood oxygen",
                          vital: reading.oxygenSaturation, unit: "%", fractionDigits: 0)
                VitalTile(symbol: "wind", title: "Respiratory rate",
                          vital: reading.respiratoryRate, unit: "/min", fractionDigits: 0)
                VitalTile(symbol: "thermometer.medium", title: "Temperature",
                          vital: reading.temperature, unit: "°C", fractionDigits: 1)
            }

            if !reading.assumedVitalNames.isEmpty {
                Label(
                    "Assumed normal: \(reading.assumedVitalNames.joined(separator: ", ")).",
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VitalTile: View {
    let symbol: String
    let title: String
    let vital: Vital
    let unit: String
    let fractionDigits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(vital.value.formatted(.number.precision(.fractionLength(fractionDigits))))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(provenanceNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .opacity(vital.provenance.isMeasured ? 1 : 0.65)
    }

    private var provenanceNote: String {
        switch vital.provenance {
        case .sensor:
            guard let sampledAt = vital.sampledAt else { return "Measured" }
            return "Measured \(sampledAt.formatted(.relative(presentation: .numeric)))"
        case .manual:
            return "Entered by hand"
        case .assumed:
            return "Assumed normal"
        }
    }
}

// MARK: - Why

struct RiskFactorsSection: View {
    let prediction: RiskPrediction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is driving this")
                .font(.subheadline.weight(.semibold))

            if prediction.contributingFactors.isEmpty {
                Text("Every vital is inside its normal range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(prediction.contributingFactors) { factor in
                    RiskFactorRow(factor: factor)
                }
            }
        }
    }
}

struct RiskFactorRow: View {
    let factor: RiskFactor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: factor.symbolName)
                .foregroundStyle(factor.severity.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(factor.label)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(factor.displayValue)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // The severity word carries the meaning; the colour only
                // reinforces it.
                Text("\(factor.severity.label) · \(factor.score) point\(factor.score == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ModelFootnote: View {
    let prediction: RiskPrediction

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model \(prediction.modelVersion)")
            Text("Not a medical device. For demonstration only.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Chrome

private struct EmptyStateView: View {
    @EnvironmentObject private var store: RiskStore
    @EnvironmentObject private var health: PhoneVitalsCollector

    var body: some View {
        ContentUnavailableView {
            Label("No readings yet", systemImage: "heart.text.square")
        } description: {
            Text(
                "Your Apple Watch syncs its measurements to Health, and this app "
                + "reads them from there. No watch app required."
            )
        } actions: {
            Button {
                Task { store.score(await health.read()) }
            } label: {
                if health.isReading {
                    ProgressView()
                } else {
                    Text("Read from Health")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(health.isReading)

            Button("Score a demo reading") {
                store.score(.demo(risk: "Medium"))
            }

            if let error = health.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
