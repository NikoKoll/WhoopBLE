import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var trackedDay: Date = Calendar.current.startOfDay(for: Date())
    private let dayCheckTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink(destination: SettingsView()) {
                                Image(systemName: "gearshape.fill")
                                    .foregroundStyle(.gray)
                            }
                        }
                    }
            }
            .tabItem { Label("Live", systemImage: "heart.fill") }

            NavigationStack {
                SleepView(sync: ble.syncManager)
            }
            .tabItem { Label("Sleep", systemImage: "moon.fill") }

            NavigationStack {
                TrendsView(store: ble.metricsStore, liveSteps: ble.dailySteps)
            }
            .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }
        }
        .tint(.cyan)
        .onAppear { applyDarkTabBar() }
        .onReceive(dayCheckTimer) { _ in
            let newDay = Calendar.current.startOfDay(for: Date())
            if newDay != trackedDay {
                trackedDay = newDay
                ble.refreshPedometer()
            }
        }
    }

    private func applyDarkTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(white: 0.04, alpha: 1)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
