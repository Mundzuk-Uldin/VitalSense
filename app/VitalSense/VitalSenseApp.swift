import SwiftUI

@main
struct VitalSenseApp: App {
    @StateObject private var store = RiskStore()
    @StateObject private var health = PhoneVitalsCollector()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(health)
                .task { await health.requestAuthorization() }
        }
    }
}
