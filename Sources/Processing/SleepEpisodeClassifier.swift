import Foundation

enum SleepEpisodeType: Int, Sendable, Codable {
    case mainSleep          = 0
    case delayedMainSleep   = 1
    case compensatorySleep  = 2
    case nap                = 3
}

struct SleepEpisodeClassification: Sendable {
    let type: SleepEpisodeType
    let startHour: Int
    let durationMinutes: Int
    let isPostSunrise: Bool
    let precededByFullWake: Bool
}

final class SleepEpisodeClassifier {
    // Fallback windows used when no habitual baseline exists (cold start).
    private let fallbackMainWindowStart = 20     // 8:00 PM
    private let fallbackMainWindowEnd   = 2      // 2:00 AM (next day)
    private let fallbackDelayedStart    = 2      // 2:00 AM
    private let fallbackDelayedEnd      = 6      // 6:00 AM

    // Relative to habitual midpoint: main = midpoint ± 3h, delayed = midpoint+3h to midpoint+7h
    private let mainWindowHalfWidth: Double = 180    // 3h before/after midpoint
    private let delayedStartOffset: Double = 180     // 3h after midpoint
    private let delayedEndOffset: Double = 420       // 7h after midpoint

    private let minMainDurationMinutes: Double = 240
    private let minDelayedDurationMinutes: Double = 180
    private let minCompensatoryDuration: Double = 120
    private let napMaxDurationMinutes: Double = 150
    private let postSunriseThresholdHour = 6
    private let postSunriseEndHour = 18   // upper bound: don't flag evening as post-sunrise
    private let sunriseWindowStart = 5
    private let sunriseWindowEnd = 8

    private var recentSessionEnds: [Date] = []

    init() {}

    func classify(session: SleepSession, circadian: CircadianEngine) -> SleepEpisodeClassification {
        let localStart = session.start
        let startHour = Calendar.current.component(.hour, from: localStart)
        let startMin = Calendar.current.component(.hour, from: localStart) * 60
            + Calendar.current.component(.minute, from: localStart)
        let durationMin = session.end.timeIntervalSince(session.start) / 60.0
        let isSunrise = startHour >= sunriseWindowStart && startHour < sunriseWindowEnd
        let isPostSunrise = startHour >= postSunriseThresholdHour && startHour < postSunriseEndHour

        let precededByWake = !recentSessionEnds.contains {
            abs(session.start.timeIntervalSince($0)) < 18 * 3600
        }

        // Compute habitual-anchored windows when baseline exists
        let useBaseline = circadian.baselineExists
        let habitualMid = useBaseline ? circadian.compute(for: session).habitualMidpointMin : startMin

        let inMainWindow: Bool
        let inDelayedWindow: Bool

        if useBaseline {
            inMainWindow = minutesWithinWindow(
                startMin,
                wrap(habitualMid - Int(mainWindowHalfWidth)),
                wrap(habitualMid + Int(mainWindowHalfWidth))
            )
            inDelayedWindow = minutesWithinWindow(
                startMin,
                wrap(habitualMid + Int(delayedStartOffset)),
                wrap(habitualMid + Int(delayedEndOffset))
            )
        } else {
            inMainWindow = hourWithinWindow(startHour, fallbackMainWindowStart, fallbackMainWindowEnd)
            inDelayedWindow = hourWithinWindow(startHour, fallbackDelayedStart, fallbackDelayedEnd)
        }

        let type: SleepEpisodeType

        if durationMin <= napMaxDurationMinutes {
            type = .nap
        } else if isPostSunrise && precededByWake {
            type = .compensatorySleep
        } else if durationMin >= minMainDurationMinutes && inMainWindow {
            type = .mainSleep
        } else if durationMin >= minDelayedDurationMinutes && inDelayedWindow {
            type = .delayedMainSleep
        } else if durationMin >= minCompensatoryDuration && isPostSunrise {
            type = .compensatorySleep
        } else if durationMin >= minMainDurationMinutes {
            type = .mainSleep
        } else {
            type = .nap
        }

        recentSessionEnds.append(session.end)
        if recentSessionEnds.count > 20 {
            recentSessionEnds.removeFirst(recentSessionEnds.count - 20)
        }

        return SleepEpisodeClassification(
            type: type,
            startHour: startHour,
            durationMinutes: Int(durationMin),
            isPostSunrise: isPostSunrise || isSunrise,
            precededByFullWake: precededByWake
        )
    }

    func clearHistory() {
        recentSessionEnds.removeAll()
    }

    // MARK: - Helpers

    private func hourWithinWindow(_ hour: Int, _ start: Int, _ end: Int) -> Bool {
        if start <= end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    private func minutesWithinWindow(_ min: Int, _ start: Int, _ end: Int) -> Bool {
        if start <= end { return min >= start && min < end }
        return min >= start || min < end
    }

    /// Wrap minutes [0, 1440) so negative values wrap around midnight.
    private func wrap(_ m: Int) -> Int {
        let day = 1440
        return ((m % day) + day) % day
    }
}
