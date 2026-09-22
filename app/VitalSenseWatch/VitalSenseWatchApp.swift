import SwiftUI

@main
struct VitalSenseWatchApp: App {
    @StateObject private var collector = VitalsCollector()
    @StateObject private var connectivity = WatchSessionManager()
    @StateObject private var scoreModel = WatchScoreModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(collector)
                .environmentObject(connectivity)
                .environmentObject(scoreModel)
                .task {
                    connectivity.activate()
                    await collector.requestAuthorization()
                }
        }
    }
}
