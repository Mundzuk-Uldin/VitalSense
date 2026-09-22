import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RiskStore
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Scoring", value: "On this device")
                    LabeledContent("Model", value: store.modelVersion)
                    if let error = store.modelError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(RiskLevel.high.tint)
                    }
                } header: {
                    Text("Risk model")
                } footer: {
                    Text("The model runs inside the app. There is no server, no network request and no account — readings never leave your devices.")
                }

                Section("Apple Watch") {
                    LabeledContent("Paired", value: store.connectivity.isWatchPaired ? "Yes" : "No")
                    LabeledContent("App installed", value: store.connectivity.isWatchAppInstalled ? "Yes" : "No")
                    LabeledContent("Reachable", value: store.connectivity.isReachable ? "Yes" : "No")
                    if let received = store.connectivity.lastReceivedAt {
                        LabeledContent("Last reading") {
                            Text(received.formatted(date: .omitted, time: .standard))
                        }
                    }
                }

                Section {
                    Button("Score a demo reading") {
                        Task { await store.score(.demo(risk: "High")) }
                    }
                } footer: {
                    Text("Sends a plausible high-risk reading through the same path a watch reading takes. Useful when no watch is paired.")
                }

                Section {
                    Text("VitalSense estimates a NEWS2 early-warning band from Apple Watch vitals. It is a demonstration, not a medical device, and must not be used to make care decisions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
