import SwiftUI

@main
struct VitalSenseApp: App {
    @StateObject private var store = RiskStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
