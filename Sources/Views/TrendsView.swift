import SwiftUI
import Charts

struct TrendsView: View {
    @ObservedObject var store: MetricsStore
    /// Live CMPedometer step count from BLEManager — always reflects today, never inflated by batch sync.
    var liveSteps: Int

    @State private var range: TrendRange = .today
    @State private var today: Date = Calendar.current.startOfDay(for: Date())

    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var cal: Calendar { Calendar.current }

    enum TrendRange: String, CaseIterable { case today = "Today"; case week = "7 Days" }

    // MARK: - Derived windows

    private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today) ?? today }
    // Extra padding on right so today's bar isn't clipped at its right edge
    private var weekEnd: Date { cal.date(byAdding: .day, value: 2, to: today) ?? tomorrow }
    private var weekStart: Date { cal.date(byAdding: .day, value: -6, to: today) ?? today }

    private var todayEntries: [MetricsStore.Entry] {
        store.entries.filter { $0.timestamp >= today }
    }

    private var weekSummaries: [MetricsStore.DaySummary] {
        store.daySummaries.filter { $0.id >= weekStart && $0.id <= today }
    }

    private var weekSteps: [MetricsStore.DailySteps] {
        var steps = store.dailySteps.filter { $0.id >= weekStart && $0.id <= today }
        // Replace today's stored count with live CMPedometer value so the bar reflects
        // real-time steps, not whatever batch sync may have written for today's key.
        if liveSteps > 0 {
            if let idx = steps.firstIndex(where: { $0.id == today }) {
                steps[idx].steps = liveSteps
            } else {
                steps.append(MetricsStore.DailySteps(id: today, steps: liveSteps))
            }
        }
        return steps
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                    .padding(.horizontal)

                    if range == .today { todayView } else { weekView }
                }
                .padding(.vertical)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(minuteTimer) { _ in
            let newDay = cal.startOfDay(for: Date())
            if newDay != today { today = newDay }
        }
    }

    // MARK: - Today

    private var todayView: some View {
        let entries = todayEntries
        let hrvE    = entries.filter { $0.hrv != nil }
        return VStack(spacing: 16) {
            // Steps tile — liveSteps comes from CMPedometer via BLEManager, never from batch sync
            card {
                VStack(spacing: 4) {
                    label("STEPS TODAY")
                    HStack(spacing: 8) {
                        Image(systemName: "figure.walk")
                            .font(.title2)
                            .foregroundStyle(liveSteps > 0 ? .purple : .purple.opacity(0.3))
                        Text(liveSteps > 0 ? liveSteps.formatted() : "—")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(liveSteps > 0 ? .white : .white.opacity(0.3))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // HR chart — anchored midnight → midnight so empty morning slots show
            card {
                VStack(alignment: .leading, spacing: 10) {
                    label("HEART RATE — TODAY")
                    if entries.count >= 2 {
                        Chart(entries) { e in
                            AreaMark(x: .value("t", e.timestamp),
                                     y: .value("HR", e.heartRate))
                                .foregroundStyle(.linearGradient(
                                    colors: [.cyan.opacity(0.35), .clear],
                                    startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("t", e.timestamp),
                                     y: .value("HR", e.heartRate))
                                .foregroundStyle(.cyan)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        .chartXScale(domain: today...tomorrow)
                        .chartYScale(domain: hrDomain(entries.map(\.heartRate)))
                        .chartXAxis { todayHourAxis }
                        .chartYAxis { hrYAxis }
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 150)
                    } else {
                        empty(height: 150)
                    }
                }
            }

            // HRV chart
            card {
                VStack(alignment: .leading, spacing: 10) {
                    label("HRV RMSSD — TODAY")
                    if hrvE.count >= 2 {
                        Chart(hrvE) { e in
                            LineMark(x: .value("t", e.timestamp),
                                     y: .value("HRV", e.hrv!))
                                .foregroundStyle(.purple)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("t", e.timestamp),
                                      y: .value("HRV", e.hrv!))
                                .foregroundStyle(.purple)
                                .symbolSize(16)
                        }
                        .chartXScale(domain: today...tomorrow)
                        .chartXAxis { todayHourAxis }
                        .chartYAxis { hrvYAxis }
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 110)
                    } else {
                        empty(height: 110)
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
        // Domain: weekStart → weekEnd (2 days past today) so today's bars aren't clipped
        let xDomain = weekStart...weekEnd

        return VStack(spacing: 16) {
            // HR bar chart
            card {
                VStack(alignment: .leading, spacing: 10) {
                    label("DAILY AVG HEART RATE")
                    if !hrS.isEmpty {
                        Chart(hrS) { s in
                            BarMark(x: .value("Day", s.id, unit: .day),
                                    y: .value("HR", s.avgHR))
                                .foregroundStyle(zoneColor(s.avgHR).gradient)
                                .cornerRadius(4)
                        }
                        .chartXScale(domain: xDomain)
                        .chartYScale(domain: hrDomain(hrS.map(\.avgHR)))
                        .chartXAxis { weekDayAxis(for: hrS.map(\.id)) }
                        .chartYAxis { hrYAxis }
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 150)
                    } else {
                        empty(height: 150)
                    }
                }
            }

            // HRV line
            card {
                VStack(alignment: .leading, spacing: 10) {
                    label("DAILY AVG HRV")
                    if hrvS.count >= 2 {
                        Chart(hrvS) { s in
                            AreaMark(x: .value("Day", s.id, unit: .day),
                                     y: .value("HRV", s.avgHRV!))
                                .foregroundStyle(.linearGradient(
                                    colors: [.purple.opacity(0.35), .clear],
                                    startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Day", s.id, unit: .day),
                                     y: .value("HRV", s.avgHRV!))
                                .foregroundStyle(.purple)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("Day", s.id, unit: .day),
                                      y: .value("HRV", s.avgHRV!))
                                .foregroundStyle(.purple)
                                .symbolSize(24)
                        }
                        .chartXScale(domain: xDomain)
                        .chartXAxis { weekDayAxis(for: hrvS.map(\.id)) }
                        .chartYAxis { hrvYAxis }
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 110)
                    } else {
                        empty(height: 110)
                    }
                }
            }

            // Steps bar chart
            card {
                VStack(alignment: .leading, spacing: 10) {
                    label("DAILY STEPS")
                    if !stepS.isEmpty {
                        Chart(stepS) { s in
                            BarMark(x: .value("Day", s.id, unit: .day),
                                    y: .value("Steps", s.steps))
                                .foregroundStyle(.purple.gradient)
                                .cornerRadius(4)
                        }
                        .chartXScale(domain: xDomain)
                        .chartXAxis { weekDayAxis(for: stepS.map(\.id)) }
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                                AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                                AxisValueLabel().foregroundStyle(Color.gray)
                            }
                        }
                        .chartBackground { _ in Color.clear }
                        .chartPlotStyle { $0.background(Color.clear) }
                        .frame(height: 130)
                    } else {
                        empty(height: 130)
                    }
                }
            }

            if !weekSummaries.isEmpty || !stepS.isEmpty {
                weekStats(hrS: hrS, stepS: stepS)
            }
        }
    }

    // MARK: - Week summary

    private func weekStats(hrS: [MetricsStore.DaySummary], stepS: [MetricsStore.DailySteps]) -> some View {
        let avgHR      = hrS.isEmpty ? nil : hrS.map(\.avgHR).reduce(0, +) / hrS.count
        let hrvVals    = hrS.compactMap(\.avgHRV)
        let avgHRV     = hrvVals.isEmpty ? nil : hrvVals.reduce(0, +) / Double(hrvVals.count)
        let totalSteps = stepS.map(\.steps).reduce(0, +)

        return card {
            HStack(spacing: 0) {
                statCell("AVG HR",
                         value: avgHR.map { "\($0) bpm" } ?? "—",
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

    private func statCell(_ label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
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

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.gray)
            .kerning(1.4)
    }

    private func empty(height: CGFloat) -> some View {
        Text("No data yet")
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.25))
            .frame(maxWidth: .infinity, minHeight: height)
    }

    // MARK: - Axis builders

    // Today: 4-hour ticks
    private var todayHourAxis: some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 4)) {
            AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                .foregroundStyle(Color.gray)
        }
    }

    // Marks placed at noon of each data day so labels center under their bars.
    // Auto/stride marks land at midnight (bar left edge) → label drifts to the next bar.
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
}
