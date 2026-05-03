import SwiftUI

private struct CapabilityRow: View {
    let label: String
    let available: Bool
    init(_ label: String, available: Bool) { self.label = label; self.available = available }
    var body: some View {
        LabeledContent(label) {
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(available ? .green : .secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.openURL) private var openURL
    @State private var showClearConfirm = false
    @AppStorage("userWeightKg") private var userWeightKg: Double = 78

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

            Section("Profile") {
                HStack {
                    Text("Weight")
                    Spacer()
                    TextField("kg", value: $userWeightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("kg").foregroundStyle(.secondary)
                }
            }

            Section("HealthKit Access") {
                CapabilityRow("Resp. Rate",   available: ble.hkRespRateAvailable)
                CapabilityRow("SpO₂",         available: ble.hkSpO2Available)
                CapabilityRow("Apple Watch",  available: ble.hkAppleWatchPaired)
                Button("Manage in Health App") {
                    if let url = URL(string: "x-apple-health://") { openURL(url) }
                }
                .foregroundStyle(.blue)
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
