import Foundation

// Majority-vote smoother for sleep stage sequences.
// Removes single-window noise (e.g., one AWAKE window surrounded by CORE)
// that the per-window classifier produces before session extraction.
struct SleepStageSmoother: Sendable {

    let windowSize: Int  // must be odd; defaults to 3

    init(windowSize: Int = 3) {
        // Enforce odd so majority is unambiguous
        self.windowSize = windowSize % 2 == 1 ? windowSize : windowSize + 1
    }

    /// Returns a smoothed copy of `stages`. AWAKE is never removed at the
    /// boundary (first/last windows keep their original label) to preserve
    /// session onset and offset accuracy.
    func smooth(_ stages: [SleepStage]) -> [SleepStage] {
        guard stages.count >= windowSize else { return stages }
        let half = windowSize / 2
        var result = stages

        for i in half..<(stages.count - half) {
            let slice = stages[(i - half)...(i + half)]
            let votes = Dictionary(grouping: slice, by: { $0 }).mapValues { $0.count }
            guard let winner = votes.max(by: { $0.value < $1.value })?.key else { continue }
            result[i] = winner
        }
        return result
    }
}
