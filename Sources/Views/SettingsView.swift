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
    @State private var redetectStatus: String? = nil
    @State private var redetectRunning = false
    @State private var recomputeStatus: String? = nil
    @State private var recomputeRunning = false
    @AppStorage("userWeightKg") private var userWeightKg: Double = 78
    @AppStorage("userAge")      private var userAge: Int        = 35

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
                Stepper(value: $userAge, in: 10...100) {
                    HStack {
                        Text("Age")
                        Spacer()
                        Text("\(userAge)").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Max HR") {
                    Text("\(220 - userAge) bpm").foregroundStyle(.secondary)
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
                Button {
                    redetectRunning = true
                    redetectStatus = nil
                    Task {
                        let n = await ble.redetectSleepFromStoredHR(daysBack: 2)
                        redetectStatus = n > 0 ? "Found \(n) new session(s)" : "No new sessions found"
                        redetectRunning = false
                    }
                } label: {
                    HStack {
                        Text(redetectRunning ? "Re-detecting…" : "Re-detect Sleep from History")
                        Spacer()
                        if redetectRunning { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(redetectRunning)
                if let s = redetectStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    recomputeRunning = true
                    recomputeStatus = nil
                    Task {
                        await ble.forceRecomputeAll()
                        recomputeStatus = "Recompute complete"
                        recomputeRunning = false
                    }
                } label: {
                    HStack {
                        Text(recomputeRunning ? "Recomputing…" : "Recompute Recovery / Strain / HRV")
                        Spacer()
                        if recomputeRunning { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(recomputeRunning)
                if let s = recomputeStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }

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
