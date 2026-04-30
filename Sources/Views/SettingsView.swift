import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section("Bluetooth") {
                LabeledContent("Status", value: ble.connectionState.displayText)
                if let reason = ble.bluetoothUnavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Last Packet") {
                if let m = ble.latestMetrics {
                    LabeledContent("Heart Rate", value: "\(m.heartRate) bpm")
                    if let hrv = m.hrv {
                        LabeledContent("HRV (RMSSD)", value: String(format: "%.1f ms", hrv))
                    }
                    LabeledContent("RR Intervals", value: "\(m.rrIntervals.count) received")
                    LabeledContent("Timestamp", value: m.timestamp.formatted())
                } else {
                    Text("No data yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                Button("Start Scan") {
                    ble.startScanning()
                }
                .disabled(ble.connectionState != .disconnected)

                Button("Disconnect", role: .destructive) {
                    ble.disconnect()
                }
                .disabled(ble.connectionState == .disconnected)
            }

            Section("Data") {
                Button("Clear Sleep Data & Re-sync", role: .destructive) {
                    showClearConfirm = true
                }
            }

            Section("Debug Info") {
                LabeledContent("State", value: ble.connectionState.rawValue)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Delete all sleep sessions from this app and HealthKit? Batches will re-sync on next connect.",
            isPresented: $showClearConfirm, titleVisibility: .visible
        ) {
            Button("Delete & Re-sync", role: .destructive) {
                ble.syncManager.clearAllSleepData()
                ble.healthKit.deleteSleepSamples()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
