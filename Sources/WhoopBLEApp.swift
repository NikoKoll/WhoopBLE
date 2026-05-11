import SwiftUI

@main
struct WhoopBLEApp: App {
    @StateObject private var bleManager = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundEngine.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .preferredColorScheme(.dark)
                .task {
                    await bleManager.healthKit.requestAuthorization()
                    await bleManager.refreshCapabilities()
                    await bleManager.checkVersionMismatch()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        bleManager.reEnableIfStreaming()
                        bleManager.refreshPedometer()
                    }
                    if newPhase == .background {
                        BackgroundEngine.shared.scheduleOvernightTask()
                    }
                }
        }
    }
}
