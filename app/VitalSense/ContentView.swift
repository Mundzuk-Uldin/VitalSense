import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RiskStore

    var body: some View {
        TabView {
            LatestReadingView()
                .tabItem { Label("Now", systemImage: "waveform.path.ecg") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    ContentView().environmentObject(RiskStore())
}
