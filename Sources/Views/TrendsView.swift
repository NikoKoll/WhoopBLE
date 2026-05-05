import SwiftUI
import Charts

// MARK: - Card container (mirrors DashboardView.DashCard / SleepView.SleepCard)

private struct TrendsCard<Content: View>: View {
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

struct TrendsView: View {
    @ObservedObject var store: MetricsStore
    /// Live CMPedometer step count — always today, never inflated by batch sync.
    var liveSteps: Int

    @State private var range: TrendRange = .today
    @State private var today: Date = Calendar.current.startOfDay(for: Date())

    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var cal: Calendar { Calendar.current }

    enum TrendRange: String, CaseIterable { case today = "Today"; case week = "7 Days" }

    // MARK: - Derived windows

    private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today) ?? today }
    private var weekEnd:  Date { cal.date(byAdding: .day, value: 1, to: today) ?? tomorrow }
    private var weekStart: Date { cal.date(byAdding: .day, value: -6, to: today) ?? today }

    private var todayEntries: [MetricsStore.Entry] {
        store.entries.filter { $0.timestamp >= today }
    }

    private var weekSummaries: [MetricsStore.DaySummary] {
        store.daySummaries.filter { $0.id >= weekStart && $0.id <= today }
    }

    private var weekSteps: [MetricsStore.DailySteps] {
        var steps = store.dailySteps.filter { $0.id >= weekStart && $0.id <= today }
        // Only override an existing stored entry — never insert new today entry with
        // potentially stale liveSteps (CMPedometer may lag behind midnight reset).
        if liveSteps > 0, let idx = steps.firstIndex(where: { $0.id == today }) {
            steps[idx].steps = liveSteps
        }
        return steps
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundLayer
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .environment(\.colorScheme, .dark)

                    if range == .today {
                        todayView
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    } else {
                        weekView
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.easeInOut(duration: 0.22), value: range)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(minuteTimer) { _ in
            let newDay = cal.startOfDay(for: Date())
            if newDay != today { today = newDay }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.cyan.opacity(0.22), .clear],
                center: .init(x: 0.5, y: 0.18),
                startRadius: 0,
                endRadius: 380
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }

    // MARK: - Today

    private var todayView: some View {
        let rawEntries = todayEntries
        let entries = downsample(rawEntries)
        let hrvEntries = entries.compactMap { e -> (entry: MetricsStore.Entry, hrv: Double)? in
            guard let hrv = e.hrv else { return nil }
            return (e, hrv)
        }
        return VStack(spacing: 16) {
            // Steps tile
            TrendsCard {
                HStack(spacing: 14) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(liveSteps > 0 ? .purple : .purple.opacity(0.3))
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liveSteps > 0 ? liveSteps.formatted() : "—")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(liveSteps > 0 ? .white : .white.opacity(0.35))
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: liveSteps)
                        label("STEPS TODAY")
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // HR chart
            TrendsCard {
                VStack(alignment: .leading, spacing: 10) {
                    label("HEART RATE — TODAY")
                    if entries.count >= 2 {
                        Chart(entries) { e in
                            AreaMark(x: .value("Time", e.timestamp),
                                     y: .value("HR", e.heartRate))
                                .foregroundStyle(.linearGradient(
                                    colors: [.cyan.opacity(0.3), .clear],
                                    startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.linear)
                            LineMark(x: .value("Time", e.timestamp),
                                     y: .value("HR", e.heartRate))
                                .foregroundStyle(.cyan)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.linear)
                        }
                        .chartXScale(domain: today...tomorrow)
                        .chartYScale(domain: hrDomain(entries.map(\.heartRate)))
                        .chartXAxis { todayHourAxis }
                        .chartYAxis { hrYAxis }
                        .chartLegend(.hidden)
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 150)
                        .accessibilityLabel("Heart rate chart for today")
                    } else {
                        emptyState(icon: "heart", height: 150)
                    }
                }
            }

            // HRV chart
            TrendsCard {
                VStack(alignment: .leading, spacing: 10) {
                    label("HRV RMSSD — TODAY")
                    if hrvEntries.count >= 2 {
                        Chart(hrvEntries, id: \.entry.id) { item in
                            LineMark(x: .value("Time", item.entry.timestamp),
                                     y: .value("HRV", item.hrv))
                                .foregroundStyle(.purple)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.linear)
                            PointMark(x: .value("Time", item.entry.timestamp),
                                      y: .value("HRV", item.hrv))
                                .foregroundStyle(.purple)
                                .symbolSize(20)
                        }
                        .chartXScale(domain: today...tomorrow)
                        .chartXAxis { todayHourAxis }
                        .chartYAxis { hrvYAxis }
                        .chartLegend(.hidden)
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 110)
                        .accessibilityLabel("HRV chart for today")
                    } else {
                        emptyState(icon: "waveform.path.ecg", height: 110)
                    }
                }
            }
        }
    }

    // MARK: - Week

    private var weekView: some View {
        let hrS   = weekSummaries.filter { $0.avgHR > 0 }
        let hrvS  = weekSummaries.filter { $0.avgHRV != nil }
        let stepS = weekSteps
        let xDomain = weekStart...weekEnd

        return VStack(spacing: 16) {
            // HR rows — one row per day; horizontal bar + label + value.
            // Replaces BarMark chart whose `.annotation(position:.bottom)` weekday
            // labels rendered inside plot and overlapped bars.
            TrendsCard {
                VStack(alignment: .leading, spacing: 10) {
                    label("DAILY AVG HEART RATE")
                    if hrS.isEmpty {
                        emptyState(icon: "heart", height: 150)
                    } else {
                        let maxHR = max(Double(hrS.map(\.avgHR).max() ?? 100), 80)
                        VStack(spacing: 8) {
                            ForEach(weekDayList(), id: \.self) { day in
                                let entry = hrS.first { cal.isDate($0.id, inSameDayAs: day) }
                                hrRow(day: day, hr: entry?.avgHR, maxHR: maxHR)
                            }
                        }
                        .accessibilityLabel("Daily average heart rate for the past 7 days")
                    }
                }
            }

            // HRV area + line chart
            TrendsCard {
                VStack(alignment: .leading, spacing: 10) {
                    label("DAILY AVG HRV")
                    if hrvS.count >= 2 {
                        Chart(hrvS) { s in
                            AreaMark(x: .value("Day", s.id, unit: .day),
                                     y: .value("HRV", s.avgHRV!))
                                .foregroundStyle(.linearGradient(
                                    colors: [.purple.opacity(0.3), .clear],
                                    startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.linear)
                            LineMark(x: .value("Day", s.id, unit: .day),
                                     y: .value("HRV", s.avgHRV!))
                                .foregroundStyle(.purple)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.linear)
                            PointMark(x: .value("Day", s.id, unit: .day),
                                      y: .value("HRV", s.avgHRV!))
                                .foregroundStyle(.purple)
                                .symbolSize(20)
                        }
                        .chartXScale(domain: xDomain)
                        .chartXAxis { weekDayAxis(for: hrvS.map(\.id)) }
                        .chartYAxis { hrvYAxis }
                        .chartLegend(.hidden)
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 110)
                        .accessibilityLabel("Daily average HRV for the past 7 days")
                    } else {
                        emptyState(icon: "waveform.path.ecg", height: 110)
                    }
                }
            }

            // Steps bar chart
            TrendsCard {
                VStack(alignment: .leading, spacing: 10) {
                    label("DAILY STEPS")
                    if !stepS.isEmpty {
                        Chart(stepS) { s in
                            BarMark(x: .value("Day", s.id, unit: .day),
                                    y: .value("Steps", s.steps))
                                .foregroundStyle(.purple.gradient)
                                .cornerRadius(4)
                                .annotation(position: .bottom, alignment: .center, spacing: 4) {
                                    Text(s.id, format: .dateTime.weekday(.abbreviated))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.gray)
                                }
                        }
                        .chartXScale(domain: xDomain)
                        .chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                                AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                                AxisValueLabel().foregroundStyle(Color.gray)
                            }
                        }
                        .chartLegend(.hidden)
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 145)
                        .accessibilityLabel("Daily steps for the past 7 days")
                    } else {
                        emptyState(icon: "figure.walk", height: 130)
                    }
                }
            }

            if !weekSummaries.isEmpty || !stepS.isEmpty {
                weekStats(hrS: hrS, stepS: stepS)
            }
        }
    }

    // MARK: - Week summary stats

    private func weekStats(hrS: [MetricsStore.DaySummary], stepS: [MetricsStore.DailySteps]) -> some View {
        let avgHR: Double? = hrS.isEmpty ? nil : Double(hrS.map(\.avgHR).reduce(0, +)) / Double(hrS.count)
        let hrvVals  = hrS.compactMap(\.avgHRV)
        let avgHRV   = hrvVals.isEmpty ? nil : hrvVals.reduce(0, +) / Double(hrvVals.count)
        let totalSteps = stepS.map(\.steps).reduce(0, +)

        return TrendsCard {
            HStack(spacing: 0) {
                statCell("AVG HR",
                         value: avgHR.map { String(format: "%.0f bpm", $0) } ?? "—",
                         color: .cyan)
                statDivider
                statCell("AVG HRV",
                         value: avgHRV.map { String(format: "%.0f ms", $0) } ?? "—",
                         color: .purple)
                statDivider
                statCell("TOTAL STEPS",
                         value: totalSteps > 0 ? totalSteps.formatted() : "—",
                         color: .purple)
            }
        }
    }

    private func statCell(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.gray)
                .kerning(1.1)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 32)
    }

    // MARK: - Reusable components

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.gray)
            .kerning(1.4)
    }

    private func emptyState(icon: String, height: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.white.opacity(0.15))
            Text("No data yet")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }

    // MARK: - Axis builders

    private var todayHourAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 4)) {
            AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                .foregroundStyle(Color.gray)
        }
    }

    private func weekDayAxis(for days: [Date]) -> some AxisContent {
        AxisMarks(values: days.map { noonOf($0) }) { _ in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                .foregroundStyle(Color.gray)
        }
    }

    private func noonOf(_ day: Date) -> Date {
        cal.date(byAdding: .hour, value: 12, to: day) ?? day
    }

    private var hrYAxis: some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
            AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
            AxisValueLabel().foregroundStyle(Color.gray)
        }
    }

    private var hrvYAxis: some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
            AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
            AxisValueLabel().foregroundStyle(Color.gray)
        }
    }

    // MARK: - Helpers

    private func hrDomain(_ values: [Int]) -> ClosedRange<Int> {
        let lo = max(30, (values.min() ?? 50) - 10)
        let hi = (values.max() ?? 120) + 10
        return lo...max(hi, lo + 40)
    }

    private func zoneColor(_ hr: Int) -> Color {
        switch hr {
        case ..<60:  return .blue
        case ..<100: return .cyan
        case ..<140: return .yellow
        case ..<170: return .orange
        default:     return .red
        }
    }

    // MARK: - Week HR rows

    private func weekDayList() -> [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func hrRow(day: Date, hr: Int?, maxHR: Double) -> some View {
        let isToday = cal.isDate(day, inSameDayAs: today)
        let frac: Double = hr.map { min(1, Double($0) / (maxHR * 1.05)) } ?? 0
        return HStack(spacing: 12) {
            Text(day, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isToday ? .cyan : .gray)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                    if let hr {
                        Capsule()
                            .fill(zoneColor(hr).gradient)
                            .frame(width: max(6, geo.size.width * frac))
                    }
                }
            }
            .frame(height: 10)

            Text(hr.map { "\($0)" } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(hr != nil ? .white : .white.opacity(0.3))
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()
        }
    }

    // MARK: - Downsampling

    // Bucket-average to ≤ targetCount points so Chart doesn't stall on thousands of marks.
    private func downsample(_ entries: [MetricsStore.Entry], max targetCount: Int = 180) -> [MetricsStore.Entry] {
        guard entries.count > targetCount else { return entries }
        let bucket = Int(ceil(Double(entries.count) / Double(targetCount)))
        var out: [MetricsStore.Entry] = []
        out.reserveCapacity(targetCount + 1)
        var i = 0
        while i < entries.count {
            let slice = entries[i..<min(i + bucket, entries.count)]
            let avgHR = slice.map(\.heartRate).reduce(0, +) / slice.count
            let hrvVals = slice.compactMap(\.hrv)
            let avgHRV: Double? = hrvVals.isEmpty ? nil : hrvVals.reduce(0, +) / Double(hrvVals.count)
            let midTs = slice[slice.startIndex.advanced(by: slice.count / 2)].timestamp
            out.append(MetricsStore.Entry(timestamp: midTs, heartRate: avgHR, hrv: avgHRV))
            i += bucket
        }
        return out
    }
}
