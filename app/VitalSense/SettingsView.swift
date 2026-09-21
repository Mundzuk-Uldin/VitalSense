import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RiskStore
    @State private var draftURL = ""
    @State private var reachability: Reachability = .unknown

    private enum Reachability {
        case unknown, checking, reachable, unreachable
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:8000", text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(commit)

                    Button("Save and test") { commit() }

                    LabeledContent("Status") {
                        switch reachability {
                        case .unknown: Text("Not tested").foregroundStyle(.secondary)
                        case .checking: ProgressView()
                        case .reachable: Label("Reachable", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(RiskLevel.normal.tint)
                        case .unreachable: Label("No answer", systemImage: "xmark.circle.fill")
                                .foregroundStyle(RiskLevel.high.tint)
                        }
                    }
                } header: {
                    Text("Risk server")
                } footer: {
                    Text("The Simulator can use localhost. A real iPhone needs your Mac's address on the same Wi-Fi — run `ipconfig getifaddr en0` on the Mac to find it.")
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
            .onAppear { draftURL = store.apiBaseURL }
        }
    }

    private func commit() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.apiBaseURL = trimmed
        reachability = .checking
        Task {
            guard let client = RiskAPIClient(rawBaseURL: trimmed) else {
                reachability = .unreachable
                return
            }
            reachability = await client.ping() ? .reachable : .unreachable
        }
    }
}
