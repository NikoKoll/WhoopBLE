import SwiftUI

@main
struct WhoopBLEApp: App {
    @StateObject private var bleManager = WhoopBLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
        }
    }
}
