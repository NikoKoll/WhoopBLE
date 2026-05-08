import Foundation

struct BiologicalDayAssignment: Sendable {
    let biologicalDate: Date          // noon of the biological day start
    let biologicalDateKey: String     // "2025-04-27" UTC — the date that owns the recovery
    let episodes: [SleepSession]
    let classifications: [SleepEpisodeClassification]
    let totalSleepMinutes: Int
    let primaryType: SleepEpisodeType
}

final class BiologicalDay {

    func assign(
        sessions: [SleepSession],
        classifications: [SleepEpisodeClassification]
    ) -> [BiologicalDayAssignment] {
        guard sessions.count == classifications.count else { return [] }

        let zipped = zip(sessions, classifications).sorted { $0.0.start < $1.0.start }
        var groups: [Date: (sessions: [SleepSession], classifications: [SleepEpisodeClassification])] = [:]

        for (session, classification) in zipped {
            let bioDate = biologicalDayStart(for: session.end)
            if groups[bioDate] != nil {
                groups[bioDate]?.sessions.append(session)
                groups[bioDate]?.classifications.append(classification)
            } else {
                groups[bioDate] = (sessions: [session], classifications: [classification])
            }
        }

        return groups.map { date, data in
            let totalMin = data.sessions.reduce(0) {
                $0 + Int($1.end.timeIntervalSince($1.start) / 60) - ($1.briefWakeTotalSeconds / 60)
            }

            let primary: SleepEpisodeType
            let typeOrder: [SleepEpisodeType] = [.mainSleep, .delayedMainSleep, .compensatorySleep, .nap]
            let byType = Dictionary(grouping: data.classifications, by: { $0.type })
            if let best = typeOrder.first(where: { (byType[$0]?.count ?? 0) > 0 }) {
                primary = best
            } else {
                primary = .nap
            }

            return BiologicalDayAssignment(
                biologicalDate: date,
                biologicalDateKey: isoKey(for: date),
                episodes: data.sessions,
                classifications: data.classifications,
                totalSleepMinutes: totalMin,
                primaryType: primary
            )
        }
    }

    /// Bio day = calendar date of wake (UTC). Sleep ending early morning of D
    /// belongs to D — matches user expectation that today's recovery is shown
    /// under today's date.
    func biologicalDayStart(for date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.startOfDay(for: date)
    }

    /// Public helper: ISO date key (UTC) of biological day owning the given moment.
    func biologicalDayKey(for moment: Date) -> String {
        isoKey(for: biologicalDayStart(for: moment))
    }

    private func isoKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
