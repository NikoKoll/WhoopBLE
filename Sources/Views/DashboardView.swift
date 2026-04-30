import SwiftUI
import Charts

// MARK: - HR Zone

private enum HRZone {
    static func color(for hr: Int) -> Color {
        switch hr {
        case ..<60:  return .blue
        case ..<100: return .green
        case ..<140: return .yellow
        case ..<170: return .orange
        default:     return .red
        }
    }

    static func label(for hr: Int) -> String {
        switch hr {
        case ..<60:  return "Rest"
        case ..<100: return "Easy"
        case ..<140: return "Cardio"
        case ..<170: return "Hard"
        default:     return "Max"
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var now = Date()

    private let stalenessThreshold: TimeInterval = 60

    private var metrics: WhoopMetrics? { ble.latestMetrics }
    // 15-sample (~15 s) smoothed HR for the ring — avoids jitter from single-packet spikes
    private var heartRate: Int { ble.smoothedHR > 0 ? ble.smoothedHR : (metrics?.heartRate ?? 0) }
    private var ringProgress: Double { min(Double(heartRate) / 200.0, 1.0) }
    private var zoneColor: Color { HRZone.color(for: heartRate) }

    private var isStale: Bool {
        guard let ts = metrics?.timestamp else { return false }
        return now.timeIntervalSince(ts) > stalenessThreshold
    }

    private var sessionStats: (min: Int, avg: Int, max: Int)? {
        guard !ble.hrHistory.isEmpty else { return nil }
        let hrs = ble.hrHistory.map(\.heartRate)
        return (min: hrs.min()!, avg: hrs.reduce(0, +) / hrs.count, max: hrs.max()!)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                connectionBanner
                    .padding(.top, 8)
                SyncStatusView(sync: ble.syncManager)

                Spacer()
                heartRateSection

                if let stats = sessionStats {
                    statsBar(stats).padding(.top, 20)
                }
                if ble.hrHistory.count >= 2 {
                    hrSparkline.padding(.top, 14)
                }
                StepsTileView(steps: ble.dailySteps > 0 ? ble.dailySteps : ble.syncManager.totalSteps)
                    .padding(.top, 14)

                Spacer()
                hrvSection
                Spacer()
                timestampFooter
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("WHOOP Live")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { t in now = t }
    }

    // MARK: - Connection Banner

    private var connectionBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(ble.connectionState.displayText)
                .font(.caption)
                .foregroundStyle(.gray)
            if isStale && ble.connectionState.isLive {
                Text("· stale")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let pct = ble.batteryLevel {
                Spacer()
                Image(systemName: batteryIcon(pct))
                    .font(.caption)
                    .foregroundStyle(pct < 20 ? .red : .gray)
                Text("\(pct)%")
                    .font(.caption2)
                    .foregroundStyle(pct < 20 ? .red : .gray)
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut, value: ble.connectionState)
    }

    // MARK: - HR Ring

    private var heartRateSection: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 18)
                .frame(width: 220, height: 220)

            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    AngularGradient(colors: [zoneColor.opacity(0.5), zoneColor],
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round)
                )
                .frame(width: 220, height: 220)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: ringProgress)
                .animation(.easeInOut(duration: 0.6), value: zoneColor)
                .opacity(isStale ? 0.35 : 1.0)
                .animation(.easeInOut(duration: 0.5), value: isStale)

            VStack(spacing: 2) {
                Text(heartRate > 0 ? "\(heartRate)" : "—")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(isStale ? Color.white.opacity(0.35) : .white)
                    .contentTransition(.numericText())
                    .animation(.easeInOut, value: heartRate)
                    .animation(.easeInOut(duration: 0.5), value: isStale)
                Text("BPM")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .kerning(2)
                if heartRate > 0 {
                    Text(HRZone.label(for: heartRate))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(zoneColor.opacity(0.85))
                        .kerning(1)
                        .animation(.easeInOut(duration: 0.6), value: zoneColor)
                }
            }
        }
    }

    // MARK: - Session Stats Bar

    private func statsBar(_ stats: (min: Int, avg: Int, max: Int)) -> some View {
        HStack(spacing: 0) {
            statTile(label: "MIN", value: stats.min)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 28)
            statTile(label: "AVG", value: stats.avg)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 28)
            statTile(label: "MAX", value: stats.max)
        }
        .padding(.horizontal, 48)
    }

    private func statTile(label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(HRZone.color(for: value))
                .contentTransition(.numericText())
                .animation(.easeInOut, value: value)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - HR Sparkline

    private var hrSparkline: some View {
        Chart(ble.hrHistory, id: \.timestamp) { m in
            AreaMark(
                x: .value("Time", m.timestamp),
                y: .value("HR", m.heartRate)
            )
            .foregroundStyle(
                LinearGradient(colors: [zoneColor.opacity(0.22), .clear],
                               startPoint: .top, endPoint: .bottom)
            )
            LineMark(
                x: .value("Time", m.timestamp),
                y: .value("HR", m.heartRate)
            )
            .foregroundStyle(zoneColor)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 40...200)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [60, 100, 140, 170]) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.white.opacity(0.12))
            }
        }
        .frame(height: 60)
        .padding(.horizontal, 28)
    }

    // MARK: - HRV

    private var hrvSection: some View {
        VStack(spacing: 4) {
            Text(hrvText)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                // Dim when stale, but keep showing the last value — it doesn't disappear
                .foregroundStyle(isStale ? Color.cyan.opacity(0.35) : .cyan)
                .contentTransition(.numericText())
                .animation(.easeInOut, value: ble.smoothedHRV)
                .animation(.easeInOut(duration: 0.5), value: isStale)
            Text("HRV (RMSSD)")
                .font(.caption)
                .foregroundStyle(.gray)
                .kerning(1.5)
            if let rr = metrics?.rrIntervals, !rr.isEmpty {
                Text("RR: \(rr.map { String(format: "%.0f", $0 * 1000) }.joined(separator: ", ")) ms")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.top, 2)
            }
        }
    }

    private var hrvText: String {
        if let hrv = ble.smoothedHRV ?? ble.lastHRV { return String(format: "%.1f ms", hrv) }
        return "— ms"
    }

    // MARK: - Footer

    private var timestampFooter: some View {
        Group {
            if let ts = metrics?.timestamp {
                Text("Updated \(ts.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(isStale ? Color.orange.opacity(0.6) : Color.white.opacity(0.25))
            } else {
                Text("Waiting for data…")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.25))
            }
        }
    }

    // MARK: - Helpers

    private var dotColor: Color {
        if ble.connectionState.isLive { return isStale ? .orange : .green }
        if ble.connectionState.isTransitioning { return .yellow }
        return .red
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 11...: return "battery.25"
        default:    return "battery.0"
        }
    }
}

// MARK: - Steps Tile

private struct StepsTileView: View {
    let steps: Int

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 16))
                    .foregroundStyle(steps > 0 ? .purple : .purple.opacity(0.4))
                Group {
                    if steps > 0 {
                        Text(steps.formatted())
                            .contentTransition(.numericText())
                            .animation(.easeInOut, value: steps)
                    } else {
                        Text("—")
                    }
                }
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(steps > 0 ? .white : Color.white.opacity(0.3))
            }
            Text("STEPS TODAY")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray)
                .kerning(1.5)
        }
    }
}

// MARK: - Sync Status
// Separate view so @ObservedObject on SyncManager drives its own re-renders
// without forcing a full DashboardView refresh.
private struct SyncStatusView: View {
    @ObservedObject var sync: SyncManager

    @ViewBuilder
    var body: some View {
        if sync.syncBannerVisible {
            HStack(spacing: 5) {
                if sync.isSyncing {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(.cyan)
                    Text("Syncing history…")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    let n = sync.syncedBatchCount
                    Text("Synced \(n) batch\(n == 1 ? "" : "es")")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .transition(.opacity)
        }
    }
}
