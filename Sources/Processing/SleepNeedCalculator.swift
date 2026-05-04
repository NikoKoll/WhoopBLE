import Foundation

/// Computes personalized nightly sleep need from rolling history.
/// Formula: baseline + strain_adjustment + sleep_debt - nap_credit
/// All inputs are pure values (no async) — caller loads them before invoking.
struct SleepNeedCalculator {

    struct Breakdown: Sendable {
        let baselineMinutes: Int
        let strainAdjMinutes: Int
        let debtMinutes: Int
        let napCreditMinutes: Int
        let totalMinutes: Int
    }

    func compute(
        for date: Date,
        dailyMetrics: [DailyMetricsStore.DailyMetrics],
        sleepSessions: [SleepSession]
    ) -> Breakdown {
        let key = isoDate(for: date)

        // --- Baseline: rolling 28-day median of sleepMinutes (excluding date itself) ---
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let cutoff28 = utcCal.date(byAdding: .day, value: -28, to: date) ?? date
        let past28 = dailyMetrics.filter {
            $0.date != key && isoToDate($0.date) >= cutoff28 && isoToDate($0.date) < date
        }.compactMap { $0.sleepMinutes }

        let baseline: Int
        if past28.count >= 14 {
            let sorted = past28.sorted()
            let n = sorted.count
            let rawMedian = n % 2 == 0
                ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2
                : sorted[n / 2]
            baseline = max(360, min(600, rawMedian))
        } else {
            baseline = 480
        }

        // --- Strain adjustment: yesterday's strain → 0–60 min extra need ---
        let yesterday = utcCal.date(byAdding: .day, value: -1, to: date) ?? date
        let yesterdayKey = isoDate(for: yesterday)
        let yesterdayStrain = dailyMetrics.first(where: { $0.date == yesterdayKey })?.strainScore ?? 0
        let strainAdj = min(60, Int((yesterdayStrain / 21.0) * 60.0))

        // --- Sleep debt: sum of shortfalls over last 7 days, capped at 120 min ---
        // Each day's recovery is capped at -30 min so one great night can't zero out a week of debt.
        var debtRaw = 0
        for offset in 1...7 {
            let pastDate = utcCal.date(byAdding: .day, value: -offset, to: date) ?? date
            let pastKey = isoDate(for: pastDate)
            if let m = dailyMetrics.first(where: { $0.date == pastKey }) {
                let need = m.sleepNeedMinutes ?? baseline
                let actual = m.sleepMinutes ?? 0
                let delta = need - actual
                debtRaw += max(-30, delta)
            }
        }
        let debt = min(120, max(0, debtRaw))

        // --- Nap credit: daytime sessions (start 10:00–21:00 local) whose end date matches date ---
        // `date` is UTC-keyed (matches dailyMetrics rows), so anchor day comparison in UTC
        // to avoid off-by-one near midnight when user's local TZ is east/west of UTC.
        // Start-hour check stays in local TZ — "daytime nap" is a user-perception window.
        let localCal = Calendar.current
        let targetDayUTC = utcCal.startOfDay(for: date)
        var napMinutes = 0
        for session in sleepSessions {
            let startHour = localCal.component(.hour, from: session.start)
            guard startHour >= 10, startHour < 21 else { continue }
            guard utcCal.startOfDay(for: session.end) == targetDayUTC else { continue }
            napMinutes += Int(session.end.timeIntervalSince(session.start) / 60)
        }
        let napCredit = min(60, napMinutes)

        let total = baseline + strainAdj + debt - napCredit

        return Breakdown(
            baselineMinutes: baseline,
            strainAdjMinutes: strainAdj,
            debtMinutes: debt,
            napCreditMinutes: napCredit,
            totalMinutes: total
        )
    }

    // MARK: - Helpers

    private func isoDate(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func isoToDate(_ s: String) -> Date {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        return cal.date(from: dc) ?? .distantPast
    }
}
