import SwiftUI

struct SleepView: View {
    @ObservedObject var sync: SyncManager
    @EnvironmentObject var ble: BLEManager

    // date key → sleepNeedMinutes loaded from DailyMetricsStore
    @State private var needByDate: [String: Int] = [:]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if sync.sleepSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadNeedData() }
        .onChange(of: sync.sleepSessions.count) { _ in
            Task { await loadNeedData() }
        }
    }

    // MARK: - Data loading

    private func loadNeedData() async {
        let all = await ble.dailyMetrics.loadAll()
        var dict: [String: Int] = [:]
        for m in all {
            if let n = m.sleepNeedMinutes { dict[m.date] = n }
        }
        needByDate = dict
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 52))
                .foregroundStyle(.indigo.opacity(0.55))
            Text("No sleep data yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Sleep sessions are detected from synced WHOOP history.\nConnect your strap to start syncing.")
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if sync.isSyncing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).tint(.cyan)
                    Text("Syncing history…")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 1) {
                if sync.isSyncing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.55).tint(.cyan)
                        Text("Still syncing…")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                ForEach(sync.sleepSessions.reversed(), id: \.start) { session in
                    SleepSessionRow(session: session, needMinutes: needByDateKey(for: session))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()
                        .background(Color.white.opacity(0.07))
                        .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
    }

    // Maps a session's wake date (UTC ISO "yyyy-MM-dd") to its stored sleep need.
    private func needByDateKey(for session: SleepSession) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: session.end)
        let key = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return needByDate[key]
    }
}

// MARK: - Session Row

private struct SleepSessionRow: View {
    let session: SleepSession
    let needMinutes: Int?

    @State private var expanded = false

    private var durationSecs: Int { Int(session.end.timeIntervalSince(session.start)) }

    private var durationText: String {
        let h = durationSecs / 3600
        let m = (durationSecs % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var timeRangeText: String {
        "\(session.start.formatted(date: .omitted, time: .shortened)) → \(session.end.formatted(date: .omitted, time: .shortened))"
    }

    private var badgeText: String {
        var parts: [String] = []
        if let need = needMinutes {
            let nh = need / 60; let nm = need % 60
            let needStr = nh > 0 ? "\(nh)h \(nm)m" : "\(nm)m"
            parts.append("\(durationText) / \(needStr) needed")
        } else {
            parts.append(durationText)
        }
        let w = session.briefWakeCount
        if w > 0 { parts.append("\(w) brief wake\(w == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var qualityColor: Color {
        if let need = needMinutes {
            let ratio = Double(durationSecs) / Double(need * 60)
            switch ratio {
            case 0.9...: return .green
            case 0.75...: return .yellow
            default: return .orange
            }
        }
        let hours = Double(durationSecs) / 3600
        switch hours {
        case 7...: return .green
        case 5...: return .yellow
        default: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(qualityColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "moon.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(qualityColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(timeRangeText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(session.start.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(badgeText)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Circle()
                        .fill(qualityColor)
                        .frame(width: 10, height: 10)
                    if needMinutes != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard needMinutes != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }

            // Expanded breakdown
            if expanded, let need = needMinutes {
                needBreakdown(need: need)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func needBreakdown(need: Int) -> some View {
        // We only have total from DailyMetrics; we can't show component breakdown
        // without re-running the calculator. Show a simple summary row instead.
        let h = need / 60; let m = need % 60
        let needStr = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        let dh = durationSecs / 3600; let dm = (durationSecs % 3600) / 60
        let actualStr = dh > 0 ? "\(dh)h \(dm)m" : "\(dm)m"
        let delta = durationSecs - need * 60
        let absDeltaMin = abs(delta) / 60
        let deltaStr = delta >= 0 ? "+\(absDeltaMin)m" : "-\(absDeltaMin)m"
        let deltaColor: Color = delta >= 0 ? .green : .orange

        VStack(alignment: .leading, spacing: 6) {
            Divider().background(Color.white.opacity(0.08))
            HStack {
                Text("Slept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(actualStr)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            HStack {
                Text("Need")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(needStr)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            HStack {
                Text("Balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(deltaStr)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(deltaColor)
            }
        }
        .padding(.horizontal, 6)
    }
}
