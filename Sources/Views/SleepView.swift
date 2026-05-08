import SwiftUI

// MARK: - Animation helper

private extension Animation {
    static func smoothFallback(duration: Double = 0.45) -> Animation {
        if #available(iOS 17.0, *) { return .smooth(duration: duration) }
        return .easeInOut(duration: duration)
    }
}

// MARK: - Card container (mirrors DashboardView.DashCard)

private struct SleepCard<Content: View>: View {
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

// MARK: - Sleep stage colors

private enum StageStyle {
    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .deep:  return Color(red: 0.32, green: 0.20, blue: 0.78)
        case .core:  return Color(red: 0.42, green: 0.45, blue: 0.95)
        case .rem:   return Color(red: 0.55, green: 0.78, blue: 1.00)
        case .awake: return Color.orange.opacity(0.85)
        }
    }
    static func label(_ stage: SleepStage) -> String {
        switch stage {
        case .deep:  return "Deep"
        case .core:  return "Core"
        case .rem:   return "REM"
        case .awake: return "Awake"
        }
    }
}

// MARK: - SleepView

struct SleepView: View {
    @ObservedObject var sync: SyncManager
    @EnvironmentObject var ble: BLEManager

    @State private var needByDate: [String: Int] = [:]
    @State private var showCreateSheet = false
    @State private var editingSession: SleepSession?
    @State private var createStart = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var createEnd = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date().addingTimeInterval(86400)) ?? Date()
    @State private var editStart = Date()
    @State private var editEnd = Date()

    private var sortedSessions: [SleepSession] {
        sync.sleepSessions.sorted { $0.start > $1.start }
    }
    private var lastNight: SleepSession? { sortedSessions.first }

    var body: some View {
        ZStack {
            backgroundLayer
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if sync.isSyncing { syncBanner }

                    if let last = lastNight {
                        SleepCard { lastNightHeader(last) }
                        SleepCard { statsRow(last) }
                    } else {
                        SleepCard { emptyState }
                    }

                    if sortedSessions.count > 1 {
                        SleepCard { historyList }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus.circle").font(.system(size: 16))
                }
                .foregroundStyle(.indigo)
            }
        }
        .task { await loadNeedData() }
        .onChange(of: sync.sleepSessions.count) { _ in
            Task { await loadNeedData() }
        }
        .sheet(isPresented: $showCreateSheet) {
            createSleepSheet
        }
        .sheet(item: $editingSession) { session in
            editSleepSheet(session: session)
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.indigo.opacity(0.28), .clear],
                center: .init(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 380
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }

    // MARK: - Sync banner

    private var syncBanner: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).tint(.cyan)
            Text("Syncing history…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.cyan)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 52))
                .foregroundStyle(.indigo.opacity(0.6))
            Text("No sleep data yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Sleep sessions are detected from synced WHOOP history.\nConnect your strap to start syncing.")
                .font(.caption)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Last night header (big ring + summary)

    @ViewBuilder
    private func lastNightHeader(_ session: SleepSession) -> some View {
        let durSec = Int(session.end.timeIntervalSince(session.start))
        let need   = needByDateKey(for: session)
        let pct    = sleepPercent(durSec: durSec, need: need)
        let color  = qualityColor(durSec: durSec, need: need)

        HStack(spacing: 18) {
            sleepRing(pct: pct, color: color)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Last Night")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .kerning(1.6)
                    Button {
                        editStart = session.start
                        editEnd = session.end
                        editingSession = session
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    if session.source == "manual" {
                        Text("✎")
                            .font(.system(size: 9))
                            .foregroundStyle(.indigo.opacity(0.6))
                    }
                }
                Text(durationText(durSec))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let n = need {
                    Text("of \(durationText(n * 60)) needed")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Text(timeRangeText(session))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)
            }
            Spacer()
        }
    }

    private func sleepRing(pct: Int?, color: Color) -> some View {
        ZStack {
            Circle()
                .fill(color.opacity(pct == nil ? 0 : 0.14))
                .frame(width: 110, height: 110)
                .blur(radius: 18)
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 9)
                .frame(width: 96, height: 96)
            Circle()
                .trim(from: 0, to: min(Double(pct ?? 0) / 100.0, 1.0))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.45), color, color.opacity(0.85)],
                        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 6)
                .animation(.smoothFallback(duration: 0.6), value: pct)

            VStack(spacing: 1) {
                Text(pct.map { "\($0)%" } ?? "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("SLEEP")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(color.opacity(0.8))
                    .kerning(1.2)
            }
        }
    }

    // MARK: - Stats row (last night)

    private func statsRow(_ session: SleepSession) -> some View {
        let durSec = Int(session.end.timeIntervalSince(session.start))
        let wakeSec = session.briefWakeTotalSeconds
        let asleepSec = max(0, durSec - wakeSec)
        let eff = durSec > 0 ? Int(Double(asleepSec) / Double(durSec) * 100) : 0
        let stages = paddedStages(session)

        return VStack(spacing: 12) {
            HStack(spacing: 0) {
                statTile(label: "EFFICIENCY", value: "\(eff)%", color: .green)
                divider
                statTile(label: "WAKES",      value: "\(session.briefWakeCount)", color: .orange)
                divider
                statTile(label: "AWAKE",      value: shortDuration(wakeSec), color: .yellow)
            }
            if !stages.isEmpty {
                stageBar(stages: stages, totalSec: durSec)
                stageLegend(stages: stages, totalSec: durSec)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 32)
    }

    private func statTile(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stage breakdown bar

    private func stageBar(stages: [SleepStageSegment], totalSec: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(stages.enumerated()), id: \.offset) { _, seg in
                    let dur = max(1.0, seg.end.timeIntervalSince(seg.start))
                    let frac = dur / Double(max(totalSec, 1))
                    Rectangle()
                        .fill(StageStyle.color(seg.stage))
                        .frame(width: max(2, geo.size.width * frac))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(height: 14)
    }

    private func stageLegend(stages: [SleepStageSegment], totalSec: Int) -> some View {
        let totals = stageTotals(stages)
        return HStack(spacing: 12) {
            ForEach([SleepStage.deep, .core, .rem, .awake], id: \.self) { stage in
                let secs = totals[stage] ?? 0
                if secs > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(StageStyle.color(stage)).frame(width: 7, height: 7)
                        Text(StageStyle.label(stage))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(shortDuration(secs))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(StageStyle.color(stage))
                    }
                }
            }
            Spacer()
        }
    }

    /// Stages array with leading/trailing gaps filled as `.core` so the bar/legend
    /// reflect the full session window — including hours added by manual edits
    /// that the original detector didn't see.
    private func paddedStages(_ session: SleepSession) -> [SleepStageSegment] {
        let raw = (session.stages ?? []).sorted { $0.start < $1.start }
        guard let first = raw.first, let last = raw.last else {
            // No detected stages — synthesize one Core block spanning whole session.
            guard session.end > session.start else { return [] }
            return [SleepStageSegment(start: session.start, end: session.end, stage: .core)]
        }
        var out: [SleepStageSegment] = []
        if first.start > session.start {
            out.append(SleepStageSegment(start: session.start, end: first.start, stage: .core))
        }
        out.append(contentsOf: raw)
        if last.end < session.end {
            out.append(SleepStageSegment(start: last.end, end: session.end, stage: .core))
        }
        return out
    }

    private func stageTotals(_ stages: [SleepStageSegment]) -> [SleepStage: Int] {
        var out: [SleepStage: Int] = [:]
        for s in stages {
            out[s.stage, default: 0] += Int(s.end.timeIntervalSince(s.start))
        }
        return out
    }

    // MARK: - History list (older sessions)

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HISTORY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(1.6)
            ForEach(Array(sortedSessions.dropFirst()), id: \.start) { session in
                historyRow(session)
                if session.start != sortedSessions.last?.start {
                    Divider().background(Color.white.opacity(0.06))
                }
            }
        }
    }

    private func historyRow(_ session: SleepSession) -> some View {
        let durSec = Int(session.end.timeIntervalSince(session.start))
        let need   = needByDateKey(for: session)
        let color  = qualityColor(durSec: durSec, need: need)

        return HStack(spacing: 12) {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "moon.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(color)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(session.start.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Text(timeRangeText(session))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    if session.source == "manual" {
                        Text("✎")
                            .font(.system(size: 9))
                            .foregroundStyle(.indigo.opacity(0.6))
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText(durSec))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                if let n = need {
                    Text("/ \(durationText(n * 60))")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Button {
                editStart = session.start
                editEnd = session.end
                editingSession = session
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func needByDateKey(for session: SleepSession) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: session.end)
        let key = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return needByDate[key]
    }

    private func sleepPercent(durSec: Int, need: Int?) -> Int? {
        guard let n = need, n > 0 else {
            let hrs = Double(durSec) / 3600
            return Int(min(100, hrs / 8.0 * 100))
        }
        return Int(min(100.0, Double(durSec) / Double(n * 60) * 100.0))
    }

    private func qualityColor(durSec: Int, need: Int?) -> Color {
        if let n = need, n > 0 {
            let ratio = Double(durSec) / Double(n * 60)
            if ratio >= 0.85 { return .green }
            if ratio >= 0.70 { return .yellow }
            return .red
        }
        let hours = Double(durSec) / 3600
        if hours >= 7 { return .green }
        if hours >= 5 { return .yellow }
        return .red
    }

    private func durationText(_ secs: Int) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func shortDuration(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    private func timeRangeText(_ session: SleepSession) -> String {
        "\(session.start.formatted(date: .omitted, time: .shortened)) → \(session.end.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Data

    private func loadNeedData() async {
        let all = await ble.dailyMetrics.loadAll()
        var dict: [String: Int] = [:]
        for m in all {
            if let n = m.sleepNeedMinutes { dict[m.date] = n }
        }
        needByDate = dict
    }

    // MARK: - Create sheet

    private var createSleepSheet: some View {
        NavigationStack {
            Form {
                Section("Bedtime") {
                    DatePicker("Sleep start", selection: $createStart, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Wake time") {
                    DatePicker("Sleep end", selection: $createEnd, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Button("Classify & Save") {
                        Task { await commitCreateSession() }
                    }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .foregroundStyle(.indigo)
                }
            }
            .navigationTitle("New Sleep Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreateSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @MainActor
    private func commitCreateSession() async {
        let classified = await sync.classifyWindow(rawStore: ble.rawDataStore, start: createStart, end: createEnd)
        let session = SleepSession(
            start: createStart,
            end: createEnd,
            stages: classified?.stages,
            briefWakeCount: classified?.briefWakeCount ?? 0,
            briefWakeTotalSeconds: classified?.briefWakeTotalSeconds ?? 0,
            source: "manual"
        )
        sync.addSleepSession(session)
        // Enqueue recompute so recovery/strain/sleep scores update
        let cal = Calendar.current
        var dates: [Date] = []
        var d = cal.startOfDay(for: createStart)
        while d <= createEnd {
            dates.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        await ble.recomputeQueue.enqueue(dates: dates, rawStore: ble.rawDataStore, dailyStore: ble.dailyMetrics) { [weak ble] in
            guard let ble else { return }
            Task { @MainActor in await ble.refreshRecoveryFromStore() }
        }
        showCreateSheet = false
    }

    // MARK: - Edit sheet

    private func editSleepSheet(session: SleepSession) -> some View {
        NavigationStack {
            Form {
                Section("Bedtime") {
                    DatePicker("Sleep start", selection: $editStart, displayedComponents: [.date, .hourAndMinute])
                }
                Section("Wake time") {
                    DatePicker("Sleep end", selection: $editEnd, displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    Button("Reclassify & Save") {
                        Task { await commitEditSession(original: session) }
                    }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .foregroundStyle(.indigo)

                    Button("Delete Session", role: .destructive) {
                        sync.deleteSleepSession(id: session.id)
                        editingSession = nil
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Edit Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingSession = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @MainActor
    private func commitEditSession(original: SleepSession) async {
        let classified = await sync.classifyWindow(rawStore: ble.rawDataStore, start: editStart, end: editEnd)
        let session = SleepSession(
            start: editStart,
            end: editEnd,
            stages: classified?.stages,
            briefWakeCount: classified?.briefWakeCount ?? 0,
            briefWakeTotalSeconds: classified?.briefWakeTotalSeconds ?? 0,
            id: original.id,
            source: "manual"
        )
        sync.updateSleepSession(session)
        editingSession = nil
    }
}
