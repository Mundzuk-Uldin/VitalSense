import SwiftUI

/// Three vertical pages: the answer, the vitals behind it, and the controls.
///
/// The screen is too small for a chart, so the result page is a hero readout
/// rather than a plot -- the level, its icon and its name, and the single
/// biggest driver. Everything finer belongs on the iPhone.
struct WatchContentView: View {
    @EnvironmentObject private var collector: VitalsCollector
    @EnvironmentObject private var connectivity: WatchSessionManager

    var body: some View {
        TabView {
            ResultPage()
            VitalsPage()
            ControlsPage()
        }
        .tabViewStyle(.verticalPage)
    }
}

// MARK: - Result

private struct ResultPage: View {
    @EnvironmentObject private var collector: VitalsCollector
    @EnvironmentObject private var connectivity: WatchSessionManager

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let prediction = connectivity.prediction {
                    RiskHero(prediction: prediction)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No score yet")
                            .font(.headline)
                        Text("Take a reading to get a risk level.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 12)
                }

                Button {
                    Task {
                        await collector.refreshPassiveVitals()
                        await connectivity.send(collector.reading)
                    }
                } label: {
                    if connectivity.isSending {
                        ProgressView()
                    } else {
                        Label("Read & Score", systemImage: "arrow.clockwise.heart")
                    }
                }
                .disabled(connectivity.isSending)

                if let error = connectivity.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if !connectivity.statusMessage.isEmpty {
                    Text(connectivity.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Risk")
    }
}

private struct RiskHero: View {
    let prediction: RiskPrediction

    var body: some View {
        VStack(spacing: 8) {
            // Icon and written name always travel with the colour, so the
            // band never depends on colour alone to be read.
            Image(systemName: prediction.riskLevel.symbolName)
                .font(.system(size: 34))
                .foregroundStyle(prediction.riskLevel.tint)

            Text(prediction.riskLevel.headline)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("NEWS2 \(prediction.news2Total)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let driver = prediction.topFactors.first {
                Text(driver)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(prediction.riskLevel.wash, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Vitals

private struct VitalsPage: View {
    @EnvironmentObject private var collector: VitalsCollector

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                VitalRow(
                    symbol: "heart.fill",
                    title: "Heart rate",
                    value: collector.reading.heartRate,
                    format: "%.0f bpm"
                )
                VitalRow(
                    symbol: "lungs.fill",
                    title: "Blood oxygen",
                    value: collector.reading.oxygenSaturation,
                    format: "%.0f%%"
                )
                VitalRow(
                    symbol: "wind",
                    title: "Respiratory",
                    value: collector.reading.respiratoryRate,
                    format: "%.0f /min"
                )
                VitalRow(
                    symbol: "thermometer.medium",
                    title: "Temperature",
                    value: collector.reading.temperature,
                    format: "%.1f °C"
                )

                Text("\(collector.reading.measuredVitals.count) of 4 sensors reporting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Vitals")
    }
}

private struct VitalRow: View {
    let symbol: String
    let title: String
    let value: Vital
    let format: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(value.provenance.isMeasured ? .primary : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: format, value.value))
                    .font(.body)
                    .monospacedDigit()
            }
            Spacer()
            if !value.provenance.isMeasured {
                Text(value.provenance.shortLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Controls

private struct ControlsPage: View {
    @EnvironmentObject private var collector: VitalsCollector
    @EnvironmentObject private var connectivity: WatchSessionManager

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button {
                    if collector.isMonitoring {
                        collector.stopMonitoring()
                    } else {
                        collector.startMonitoring()
                    }
                } label: {
                    Label(
                        collector.isMonitoring ? "Stop monitoring" : "Start monitoring",
                        systemImage: collector.isMonitoring ? "stop.circle" : "play.circle"
                    )
                }
                .tint(collector.isMonitoring ? .red : .accentColor)

                Text(collector.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Label(
                    connectivity.isPhoneReachable ? "iPhone connected" : "iPhone out of range",
                    systemImage: connectivity.isPhoneReachable ? "iphone.radiowaves.left.and.right" : "iphone.slash"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                Divider()

                Text("Demo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(["Normal", "Medium", "High"], id: \.self) { risk in
                    Button(risk) {
                        collector.loadDemoReading(risk: risk)
                        Task { await connectivity.send(collector.reading) }
                    }
                    .font(.caption)
                }

                if let error = collector.errorMessage {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Controls")
    }
}
