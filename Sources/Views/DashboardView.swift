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

// MARK: - Animation helpers

private extension Animation {
    /// Smooth (iOS 17+) when available, falls back to easeInOut.
    static func smoothFallback(duration: Double = 0.45) -> Animation {
        if #available(iOS 17.0, *) { return .smooth(duration: duration) }
        return .easeInOut(duration: duration)
    }
}

// MARK: - Card container

private struct DashCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var now = Date()

    private let stalenessThreshold: TimeInterval = 60

    private var metrics: WhoopMetrics? { ble.latestMetrics }
    // 15-sample (~15 s) smoothed HR — avoids jitter from single-packet spikes
    private var heartRate: Int { ble.smoothedHR > 0 ? ble.smoothedHR : (metrics?.heartRate ?? 0) }
    private var zoneColor: Color { HRZone.color(for: heartRate) }

    private var isStale: Bool {
        guard let ts = metrics?.timestamp else { return false }
        return now.timeIntervalSince(ts) > stalenessThreshold
    }

    // MARK: - Sleep ring computed values
    private var sleepProgress: Double {
        guard let got = ble.todaySleepMinutes,
              let need = ble.todaySleepNeedMinutes, need > 0 else { return 0 }
        return min(Double(got) / Double(need), 1.0)
    }
    private var sleepPct: Int { Int(sleepProgress * 100) }
    private var sleepColor: Color {
        guard ble.todaySleepMinutes != nil else { return .gray.opacity(0.35) }
        if sleepPct >= 85 { return .green }
        if sleepPct >= 70 { return .yellow }
        return .red
    }
    private var sleepSubtitle: String {
        guard let mins = ble.todaySleepMinutes else { return "—" }
        let h = mins / 60, m = mins % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    // MARK: - Strain ring computed values
    private var strainProgress: Double { (ble.todayStrain ?? 0) / 21.0 }
    private var strainTargetBand: (lo: Double, hi: Double) {
        guard let recovery = ble.recoveryScore else { return (10.0, 14.0) }
        if recovery >= 67 { return (14.0, 18.0) }
        if recovery >= 34 { return (10.0, 14.0) }
        return (6.0, 10.0)
    }
    private var strainColor: Color {
        guard let strain = ble.todayStrain else { return .gray.opacity(0.35) }
        let band = strainTargetBand
        if strain < band.lo { return .yellow }
        if strain > band.hi { return .red }
        return .green
    }

    private var sessionStats: (min: Int, avg: Int, max: Int)? {
        guard !ble.hrHistory.isEmpty else { return nil }
        let hrs = ble.hrHistory.map(\.heartRate)
        return (min: hrs.min()!, avg: hrs.reduce(0, +) / hrs.count, max: hrs.max()!)
    }

    var body: some View {
        ZStack {
            backgroundLayer
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    headerStrip
                    SyncStatusView(sync: ble.syncManager)

                    topSection
                        .padding(.top, 4)

                    DashCard { vitalsTileRow }

                    if let stats = sessionStats {
                        DashCard { statsBar(stats) }
                    }
                    if ble.hrHistory.count >= 2 {
                        DashCard { hrSparkline }
                    }

                    DashCard {
                        StepsTileView(steps: ble.dailySteps > 0 ? ble.dailySteps : ble.syncManager.totalSteps)
                    }

                    DashCard { hrvSection }

                    timestampFooter
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("WHOOP Live")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { t in now = t }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [zoneColor.opacity(isStale ? 0.05 : 0.22), .clear],
                center: .init(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 360
            )
            .blendMode(.plusLighter)
            .animation(.smoothFallback(duration: 0.8), value: zoneColor)
            .animation(.smoothFallback(duration: 0.8), value: isStale)
        }
        .ignoresSafeArea()
    }

    // MARK: - Header strip (status pill + battery)

    private var headerStrip: some View {
        HStack(spacing: 8) {
            connectionPill
            Spacer()
            if let pct = ble.batteryLevel { batteryPill(pct) }
        }
        .padding(.top, 4)
    }

    private var connectionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(0.8), radius: 4)
            Text(ble.connectionState.displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            if isStale && ble.connectionState.isLive {
                Text("· stale")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
        .animation(.smoothFallback(), value: ble.connectionState)
    }

    private func batteryPill(_ pct: Int) -> some View {
        let warn = pct < 20
        return HStack(spacing: 4) {
            Image(systemName: batteryIcon(pct))
                .font(.system(size: 11))
                .foregroundStyle(warn ? .red : .white.opacity(0.7))
            Text("\(pct)%")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(warn ? .red : .white.opacity(0.7))
                .contentTransition(.numericText())
                .animation(.smoothFallback(), value: pct)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
    }

    // MARK: - Top Section (Sleep · Strain · Recovery rings)

    private var topSection: some View {
        HStack(alignment: .center, spacing: 0) {
            sleepRing
            strainRing
            recoveryRing
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - BPM + SpO2 tile row

    private var vitalsTileRow: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(heartRate > 0 ? "\(heartRate)" : "—")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(isStale ? zoneColor.opacity(0.4) : zoneColor)
                    .contentTransition(.numericText())
                    .animation(.smoothFallback(duration: 0.35), value: heartRate)
                Text("BPM")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(2.0)
                if heartRate > 0 {
                    Text(HRZone.label(for: heartRate).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(zoneColor)
                        .kerning(1.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(zoneColor.opacity(0.15)))
                        .animation(.smoothFallback(duration: 0.5), value: zoneColor)
                }
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 40)

            VStack(spacing: 4) {
                let spo2Val  = ble.latestSpO2
                let spo2Str  = spo2Val.map { "\(Int($0))%" } ?? "—"
                let spo2Color: Color = (spo2Val ?? 100) < 90 ? .red : .white
                Text(spo2Str)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(spo2Color)
                    .contentTransition(.numericText())
                    .animation(.smoothFallback(), value: ble.latestSpO2)
                Text("SPO₂")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(2.0)
                if let spo2 = spo2Val, spo2 < 90 {
                    Text("LOW O₂")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                        .kerning(1.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sleep Ring

    private var sleepRing: some View {
        ZStack {
            Circle()
                .fill(sleepColor.opacity(ble.todaySleepMinutes == nil ? 0 : 0.14))
                .frame(width: 100, height: 100)
                .blur(radius: 18)
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
                .frame(width: 88, height: 88)
            Circle()
                .trim(from: 0, to: sleepProgress)
                .stroke(
                    AngularGradient(
                        colors: [sleepColor.opacity(0.45), sleepColor, sleepColor.opacity(0.85)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(-90))
                .shadow(color: sleepColor.opacity(0.45), radius: 6)
                .animation(.smoothFallback(duration: 0.6), value: sleepProgress)

            VStack(spacing: 1) {
                Text(ble.todaySleepMinutes != nil ? "\(sleepPct)%" : "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(sleepColor)
                    .contentTransition(.numericText())
                    .animation(.smoothFallback(), value: sleepPct)
                Text(sleepSubtitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Text("SLEEP")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(sleepColor.opacity(0.8))
                    .kerning(1.2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Strain Ring

    private var strainRing: some View {
        let band = strainTargetBand
        let bandLo = band.lo / 21.0
        let bandHi = band.hi / 21.0
        return ZStack {
            Circle()
                .fill(strainColor.opacity(ble.todayStrain == nil ? 0 : 0.14))
                .frame(width: 100, height: 100)
                .blur(radius: 18)
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
                .frame(width: 88, height: 88)
            // Target band arc
            Circle()
                .trim(from: bandLo, to: bandHi)
                .stroke(Color.white.opacity(0.18), lineWidth: 8)
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(-90))
            // Progress arc
            Circle()
                .trim(from: 0, to: strainProgress)
                .stroke(
                    AngularGradient(
                        colors: [strainColor.opacity(0.45), strainColor, strainColor.opacity(0.85)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(-90))
                .shadow(color: strainColor.opacity(0.45), radius: 6)
                .animation(.smoothFallback(duration: 0.6), value: strainProgress)

            VStack(spacing: 1) {
                Text(ble.todayStrain.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(strainColor)
                    .contentTransition(.numericText())
                    .animation(.smoothFallback(), value: ble.todayStrain)
                Text(String(format: "%.0f–%.0f", band.lo, band.hi))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Text("STRAIN")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(strainColor.opacity(0.8))
                    .kerning(1.2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Session Stats Bar

    private func statsBar(_ stats: (min: Int, avg: Int, max: Int)) -> some View {
        HStack(spacing: 0) {
            statTile(label: "MIN", value: stats.min)
            divider
            statTile(label: "AVG", value: stats.avg)
            divider
            statTile(label: "MAX", value: stats.max)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 32)
    }

    private func statTile(label: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(HRZone.color(for: value))
                .contentTransition(.numericText())
                .animation(.smoothFallback(), value: value)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - HR Sparkline

    private var hrSparkline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HEART RATE · LAST 60s")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .kerning(1.5)
            Chart(ble.hrHistory, id: \.timestamp) { m in
                AreaMark(
                    x: .value("Time", m.timestamp),
                    y: .value("HR", m.heartRate)
                )
                .foregroundStyle(
                    LinearGradient(colors: [zoneColor.opacity(0.35), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", m.timestamp),
                    y: .value("HR", m.heartRate)
                )
                .foregroundStyle(zoneColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 40...200)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [60, 100, 140, 170]) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel().foregroundStyle(Color.white.opacity(0.3))
                        .font(.system(size: 9))
                }
            }
            .frame(height: 70)
        }
    }

    // MARK: - HRV

    private var hrvSection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HRV (RMSSD)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.5)
                Text(hrvText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(isStale ? Color.cyan.opacity(0.35) : .cyan)
                    .contentTransition(.numericText())
                    .animation(.smoothFallback(), value: ble.smoothedHRV)
                    .animation(.smoothFallback(duration: 0.5), value: isStale)
            }
            Spacer(minLength: 0)
            if let rr = metrics?.rrIntervals, !rr.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("RR")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .kerning(1.5)
                    Text(rr.prefix(4).map { String(format: "%.0f", $0 * 1000) }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private var hrvText: String {
        if let hrv = ble.smoothedHRV ?? ble.lastHRV { return String(format: "%.1f ms", hrv) }
        return "— ms"
    }

    // MARK: - Recovery Ring

    private var recoveryRing: some View {
        ZStack {
            Circle()
                .fill(recoveryColor.opacity(ble.recoveryScore == nil ? 0 : 0.14))
                .frame(width: 100, height: 100)
                .blur(radius: 18)
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
                .frame(width: 88, height: 88)
            Circle()
                .trim(from: 0, to: recoveryProgress)
                .stroke(
                    AngularGradient(
                        colors: [recoveryColor.opacity(0.45), recoveryColor, recoveryColor.opacity(0.85)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(-90))
                .shadow(color: recoveryColor.opacity(0.5), radius: 6)
                .animation(.smoothFallback(duration: 0.6), value: recoveryProgress)

            VStack(spacing: 1) {
                Text(ble.recoveryScore.map { "\(Int($0))%" } ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(recoveryColor)
                    .contentTransition(.numericText())
                    .animation(.smoothFallback(), value: ble.recoveryScore)
                Text("—")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.clear)
                Text("RECOVERY")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(recoveryColor.opacity(0.8))
                    .kerning(1.2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var recoveryProgress: Double {
        guard let score = ble.recoveryScore else { return 0 }
        return score / 100.0
    }

    private var recoveryColor: Color {
        guard let score = ble.recoveryScore else { return .gray.opacity(0.35) }
        if score >= 67 { return .green }
        if score >= 34 { return .yellow }
        return .red
    }

    // MARK: - Footer

    private var timestampFooter: some View {
        Group {
            if let ts = metrics?.timestamp {
                Text("Updated \(ts.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isStale ? Color.orange.opacity(0.6) : Color.white.opacity(0.3))
            } else {
                Text("Waiting for data…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.3))
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
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(.purple.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "figure.walk")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(steps > 0 ? .purple : .purple.opacity(0.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("STEPS TODAY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.8)
                Group {
                    if steps > 0 {
                        Text(steps.formatted())
                            .contentTransition(.numericText())
                            .animation(.smoothFallback(), value: steps)
                    } else {
                        Text("—")
                    }
                }
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(steps > 0 ? .white : Color.white.opacity(0.3))
            }
            Spacer(minLength: 0)
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
            HStack(spacing: 6) {
                if sync.isSyncing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.cyan)
                    Text("Syncing history…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.cyan)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    let n = sync.syncedBatchCount
                    Text("Synced \(n) batch\(n == 1 ? "" : "es")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}
