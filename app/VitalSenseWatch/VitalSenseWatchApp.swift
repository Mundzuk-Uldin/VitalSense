import SwiftUI

@main
struct VitalSenseWatchApp: App {
    @StateObject private var collector = VitalsCollector()
    @StateObject private var connectivity = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(collector)
                .environmentObject(connectivity)
                .task {
                    connectivity.activate()
                    await collector.requestAuthorization()
                }
        }
    }
}
