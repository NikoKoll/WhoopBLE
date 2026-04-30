import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: WhoopBLEManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusCard
                    .padding()
                Divider().background(Color.white.opacity(0.1))
                eventLog
            }
            .navigationTitle("WhoopBLE")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(ble.connectionState.displayText)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }

            connectButton
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch ble.connectionState {
        case .connected:    return .green
        case .scanning:     return .yellow
        case .disconnected: return .red
        }
    }

    private var connectButton: some View {
        let isConnected: Bool
        if case .connected = ble.connectionState { isConnected = true } else { isConnected = false }

        return Button {
            if isConnected {
                ble.disconnect()
            } else {
                ble.startScanning()
            }
        } label: {
            Text(isConnected ? "Disconnect" : "Connect")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(isConnected ? Color.red.opacity(0.7) : Color.cyan)
    }

    // MARK: - Event log

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Raw BLE Events (last 50)")
                .font(.caption)
                .foregroundStyle(.gray)
                .padding(.horizontal)
                .padding(.vertical, 8)

            if ble.rawEventLog.isEmpty {
                Text("No events yet")
                    .font(.caption)
                    .foregroundStyle(.gray.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(ble.rawEventLog) { event in
                        EventRow(event: event)
                            .id(event.id)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparatorTint(Color.white.opacity(0.08))
                    }
                    .listStyle(.plain)
                    .onChange(of: ble.rawEventLog.count) { _ in
                        if let last = ble.rawEventLog.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Event row

private struct EventRow: View {
    let event: BLERawEvent

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Self.timeFmt.string(from: event.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.gray)
                Text(event.characteristicName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(charColor)
            }
            Text(event.hexString)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.gray.opacity(0.7))
                .lineLimit(2)
        }
    }

    private var charColor: Color {
        switch event.characteristicName {
        case "EVENTS_FROM_STRAP": return .cyan
        case "DATA_FROM_STRAP":   return .green
        case "CMD_FROM_STRAP":    return .yellow
        case "STANDARD_HR":       return .red
        default:                  return .white
        }
    }
}
