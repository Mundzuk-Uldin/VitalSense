import SwiftUI

/// The three vitals NEWS2 needs that no Apple Watch can supply.
///
/// Blood pressure in particular swings the score hard -- a systolic under
/// 90 is three points on its own -- so leaving it silently at 120 would
/// flatter every reading. Changing anything here re-scores the most recent
/// reading immediately, and pushes the new result back to the watch.
struct ManualVitalsView: View {
    @EnvironmentObject private var store: RiskStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("I know the blood pressure", isOn: $store.hasManualBP)
                    if store.hasManualBP {
                        Stepper(
                            value: $store.systolicBP, in: 50...240, step: 1
                        ) {
                            HStack {
                                Text("Systolic")
                                Spacer()
                                Text("\(Int(store.systolicBP)) mmHg")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Blood pressure")
                } footer: {
                    Text(store.hasManualBP
                         ? "Used as measured."
                         : "Assumed to be 120 mmHg, which scores zero points.")
                }

                Section {
                    Picker("Consciousness", selection: $store.consciousness) {
                        ForEach(Consciousness.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                } header: {
                    Text("ACVPU")
                } footer: {
                    Text("Anything other than Alert adds three points on its own.")
                }

                Section {
                    Toggle("On supplemental oxygen", isOn: $store.onOxygen)
                    Picker("SpO₂ scale", selection: $store.o2Scale) {
                        Text("Scale 1 — target 94–98%").tag(1)
                        Text("Scale 2 — target 88–92%").tag(2)
                    }
                } header: {
                    Text("Oxygen")
                } footer: {
                    Text("Scale 2 is for people with hypercapnic respiratory failure, whose target saturation is deliberately lower.")
                }
            }
            .navigationTitle("Other vitals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await store.rescoreLatest() }
                        dismiss()
                    }
                }
            }
        }
    }
}
