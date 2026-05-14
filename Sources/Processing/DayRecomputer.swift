import Foundation
import HealthKit

enum AlgoVersions {
    static let hrv             = 5   // Phase 2: confidence-shrunk z, EWMA baseline
    static let strain          = 4   // Phase 2: logistic (rawAccum→strain) replaces linear
    static let sleep           = 12  // RMSSD-based stage classifier (REM/DEEP confirmed by HRV)
    static let recovery        = 19  // Phase 2: no strain in autonomic; RR + capacity + illness modulation
    static let physiology      = 1   // Phase 2: ATL/CTL/autonomicStress/sleepDebt/capacity hidden state
    static let respiratoryRate = 1   // Phase 2: sleep-window RSA mean RR
}

final class DayRecomputer: @unchecked Sendable {

    // Circadian + classifier retained across recompute calls so baseline accumulates.
    private var circadian = CircadianEngine()
    private var classifier = SleepEpisodeClassifier()

    // MARK: - RHR

    func computeRHR(hrSamples: [RawDataStore.HRSample]) -> Double? {
        guard hrSamples.count >= 5 else { return nil }
        guard let first = hrSamples.first, let last = hrSamples.last else { return nil }
        let windowSecs = 300
        let stepSecs   = 60
        var minAvg: Double = .infinity
        var t = first.timestamp
        while t <= last.timestamp {
            let bucket = hrSamples.filter { $0.timestamp >= t && $0.timestamp < t + windowSecs }
            if bucket.count >= 5 {
                let avg = Double(bucket.map(\.bpm).reduce(0, +)) / Double(bucket.count)
                minAvg = min(minAvg, avg)
            }
            t += stepSecs
        }
        return minAvg == .infinity ? nil : minAvg
    }

    // MARK: - HRV

    func computeHRV(rrSamples: [RawDataStore.RRSample]) -> (rmssd: Double, sdnn: Double)? {
        guard rrSamples.count >= 2 else { return nil }
        let processor = SignalProcessor()
        // Filter with consecutive-pair gap guard (≤10s) preserved from original logic
        var gapFiltered: [Double] = []
        for i in 0..<rrSamples.count {
            let rr = Double(rrSamples[i].intervalMs)
            if i > 0 {
                guard rrSamples[i].timestamp - rrSamples[i-1].timestamp <= 10 else { continue }
            }
            gapFiltered.append(rr)
        }
        let filtered = processor.filterRR(gapFiltered)
        guard filtered.value.count >= 2 else { return nil }
        let rmssdMetric = processor.computeRMSSD(filtered.value)
        let sdnnMetric  = processor.computeSDNN(filtered.value)
        guard let rmssd = rmssdMetric.value, let sdnn = sdnnMetric.value else { return nil }
        return (rmssd, sdnn)
    }

    func computeHRVSleep(
        rrSamples: [RawDataStore.RRSample],
        hrSamples: [RawDataStore.HRSample],
        sleepSessions: [SleepSession],
        date: Date
    ) -> Double? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = cal.startOfDay(for: date)
        let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let prevDay  = cal.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let relevant = sleepSessions.filter { $0.start < dayEnd && $0.end > prevDay }
        guard !relevant.isEmpty else { return nil }
        let sleepRR = rrSamples.filter { s in
            let ts = Date(timeIntervalSince1970: Double(s.timestamp))
            return relevant.contains { $0.start <= ts && ts <= $0.end }
        }
        guard sleepRR.count >= 10 else { return nil }
        let windowSec = 600
        let stepSec   = 60
        var bestHR    = Double.infinity
        var bestRMSSD: Double? = nil
        var t = sleepRR.first!.timestamp
        let last = sleepRR.last!.timestamp
        while t <= last - windowSec {
            let winRR = sleepRR.filter { $0.timestamp >= t && $0.timestamp < t + windowSec }
            let winHR = hrSamples.filter { $0.timestamp >= t && $0.timestamp < t + windowSec }
            guard winRR.count >= 4, !winHR.isEmpty else { t += stepSec; continue }
            let avgHR = Double(winHR.map(\.bpm).reduce(0, +)) / Double(winHR.count)
            if avgHR < bestHR {
                let diffs = zip(winRR, winRR.dropFirst()).compactMap { a, b -> Double? in
                    guard b.timestamp - a.timestamp <= 10 else { return nil }
                    let d = Double(b.intervalMs - a.intervalMs)
                    return d * d
                }
                if !diffs.isEmpty {
                    bestHR    = avgHR
                    bestRMSSD = sqrt(diffs.reduce(0, +) / Double(diffs.count))
                }
            }
            t += stepSec
        }
        return bestRMSSD
    }

    // MARK: - Strain

    func computeStrain(hrSamples: [RawDataStore.HRSample], maxHR: Int) -> Double {
        guard hrSamples.count >= 2 else { return 0 }
        let boundaries = [0.50, 0.60, 0.70, 0.80, 0.90].map { Int(Double(maxHR) * $0) }
        let weights    = [0.10, 0.50, 1.50, 4.00, 8.00]
        let maxGapSec  = 120.0
        var accumulated = 0.0
        let firstZone = zoneIndex(bpm: hrSamples[0].bpm, boundaries: boundaries)
        accumulated += weights[firstZone] * (30.0 / 3600.0)
        for i in 1..<hrSamples.count {
            let gap  = min(Double(hrSamples[i].timestamp - hrSamples[i-1].timestamp), maxGapSec)
            let zone = zoneIndex(bpm: hrSamples[i].bpm, boundaries: boundaries)
            accumulated += weights[zone] * (gap / 3600.0)
        }
        // Phase 2: logistic mapping. Inflection at rawAccum=12 → strain 10.5.
        // Higher strain levels exponentially harder to accumulate at the tail.
        return PhysiologicalDynamics.nonlinearStrain(rawAccum: accumulated)
    }

    private func zoneIndex(bpm: Int, boundaries: [Int]) -> Int {
        for i in (0..<boundaries.count).reversed() {
            if bpm >= boundaries[i] { return i }
        }
        return 0
    }

    // MARK: - Sleep

    func detectSleep(hrSamples: [RawDataStore.HRSample]) -> [SleepSession] {
        let historical = hrSamples.map {
            HistoricalSample(
                timestamp: Date(timeIntervalSince1970: Double($0.timestamp)),
                heartRate: $0.bpm,
                accelerometer: nil
            )
        }
        return SleepDetector().process(historical)
    }

    // MARK: - Sleep stage breakdown

    private func stagePcts(_ session: SleepSession) -> (deep: Double, rem: Double, core: Double) {
        guard let stages = session.stages, !stages.isEmpty else { return (0, 0, 0) }
        let totalSec = stages.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard totalSec > 0 else { return (0, 0, 0) }
        var deep = 0.0, rem = 0.0, core = 0.0
        for seg in stages {
            let dur = seg.end.timeIntervalSince(seg.start)
            switch seg.stage {
            case .deep: deep += dur
            case .rem:  rem  += dur
            case .core: core += dur
            case .awake: break
            }
        }
        return (deep / totalSec, rem / totalSec, core / totalSec)
    }

    // MARK: - Consistency score

    private func computeConsistencyScore(sessions: [SleepSession]) -> Double {
        guard sessions.count >= 3 else { return 50 }
        let recent = sessions.sorted { $0.start > $1.start }.prefix(7)
        guard recent.count >= 2 else { return 50 }
        let bedtimes = recent.map { s -> Double in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: s.start)
            return Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        }
        let mean = bedtimes.reduce(0, +) / Double(bedtimes.count)
        let variance = bedtimes.map { pow($0 - mean, 2) }.reduce(0, +) / Double(bedtimes.count - 1)
        let stdDev = sqrt(variance)
        if stdDev <= 30 { return 90 }
        if stdDev <= 60 { return 70 + 20 * (1.0 - (stdDev - 30) / 30) }
        if stdDev <= 120 { return 40 + 30 * (1.0 - (stdDev - 60) / 60) }
        return 20
    }

    // MARK: - Orchestrator

    /// Optional callback fired once per bio-day with newly computed hidden state.
    /// Used by RecomputeQueue → PhysiologicalStateStore to propagate to @MainActor UI.
    typealias ScoresUpdate = @Sendable (
        _ bioKey: String,
        _ readinessCapacity: Double,
        _ acuteFatigue: Double,
        _ chronicLoad: Double,
        _ sleepDebt: Double,
        _ autonomicStress: Double
    ) async -> Void

    func recomputeDay(date: Date, rawStore: RawDataStore, dailyStore: DailyMetricsStore,
                               healthKit: HealthKitWriter? = nil, featureCache: FeatureCache? = nil,
                               snapshotStore: SnapshotStore? = nil,
                               onScoresUpdated: ScoresUpdate? = nil) async {
        await rawStore.flush()
        let hr = await rawStore.loadHR(for: date)
        let rr = await rawStore.loadRR(for: date)

        let rhr = computeRHR(hrSamples: hr)
        let storedAge = UserDefaults.standard.integer(forKey: "userAge")
        let userAge   = storedAge > 0 ? max(10, min(100, storedAge)) : 35
        let maxHR     = 220 - userAge
        let rawStrain  = computeStrain(hrSamples: hr, maxHR: maxHR)
        // Need ≥ 2h coverage to publish strain — below that, strap mostly off.
        // 2h shows meaningful accumulation by mid-morning (6h was too conservative).
        var minutesWithHR = Set<Int>()
        for s in hr { minutesWithHR.insert(s.timestamp / 60) }
        let coveredMinutes = minutesWithHR.count
        let strain: Double? = (rawStrain.isFinite && rawStrain > 0 && coveredMinutes >= 120) ? rawStrain : nil

        // Feed prev day + current day HR for wider sleep detection (catches post-midnight + daytime)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = cal.startOfDay(for: date)
        let dayEnd   = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let prevDay  = cal.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let hrPrev   = await rawStore.loadHR(for: prevDay)

        // Wider detection window: [prev day 12:00, next day 12:00] to catch all sleep patterns
        let detectStart = cal.date(byAdding: .hour, value: 12, to: prevDay) ?? prevDay
        let detectEnd   = cal.date(byAdding: .hour, value: 12, to: dayEnd) ?? dayEnd
        let allHR = (hrPrev + hr).filter {
            let t = Date(timeIntervalSince1970: Double($0.timestamp))
            return t >= detectStart && t < detectEnd
        }.sorted { $0.timestamp < $1.timestamp }

        // Wider RR/HR union for per-assignment HRV/RHR computation. Bio days
        // span noon UTC → noon UTC, so a session can straddle two calendar days.
        // Need prev + current + next day data to capture full sleep window
        // and to compute RHR over the correct bio-day window.
        let nextDayHR = await rawStore.loadHR(for: dayEnd)
        let rrPrev = await rawStore.loadRR(for: prevDay)
        let rrNext = await rawStore.loadRR(for: dayEnd)
        let rrAll = (rrPrev + rr + rrNext).sorted { $0.timestamp < $1.timestamp }
        let hrAll = (hrPrev + hr + nextDayHR).sorted { $0.timestamp < $1.timestamp }

        let detected = detectSleep(hrSamples: allHR)
        // Remove sessions > 14h (artifact merging) and zero-duration sessions.
        // Afternoon detections pass through — SleepEpisodeClassifier tags them as .nap
        // and recovery weights down-weight nap contribution (qty/eff/stage = 0×).
        let sleep = detected.filter {
            let dur = $0.end.timeIntervalSince($0.start)
            return dur > 60 && dur <= 14 * 3600
        }

        // Load stored sessions from SyncManager (canonical source of truth)
        let storedSessions = loadSleepSessions()
        // Dedup: drop a freshly-detected session if it overlaps any stored session.
        // Without this, the same night gets counted multiple times when the detector
        // re-fires on every recompute, inflating totalSleepMinutes (saw 30h+ in logs).
        let dedupedDetected = sleep.filter { det in
            !storedSessions.contains { stored in
                det.start < stored.end && stored.start < det.end
            }
        }
        let allSessions = (dedupedDetected + storedSessions).sorted { $0.start < $1.start }

        // --- New pipeline: classify + biological day + circadian + enhanced recovery ---

        let bioAssigner = BiologicalDay()
        var classifications: [SleepEpisodeClassification] = []

        for session in allSessions {
            let cls = classifier.classify(session: session, circadian: circadian)
            classifications.append(cls)
            let midMin = midpointMinutes(from: session)
            // Type-gated: only main + delayed-main pollute the circadian baseline.
            circadian.recordSession(session: session, type: cls.type, localMidpointMin: midMin)
        }

        let assignments = bioAssigner.assign(sessions: allSessions, classifications: classifications)

        let calKey = isoDate(for: date)

        // Calendar-day SDNN for the optional hrvSdnn field (for trends only).
        let calDayFullHRV = computeHRV(rrSamples: rr)
        let hrvSdnn = calDayFullHRV?.sdnn

        let allMetrics = await dailyStore.loadAll()
        // Phase 2: EWMA baselines for autonomic metrics replace rolling mean/std.
        // Sleep baseline remains rolling median (compatible with SleepNeedCalculator).
        let hrvBaseRaw    = await dailyStore.ewmaBaseline({ $0.hrvRmssd },        excluding: calKey, alpha: 0.033)
        let rhrBaseRaw    = await dailyStore.ewmaBaseline({ $0.rhr },             excluding: calKey, alpha: 0.022)
        let sleepBaseRaw  = await dailyStore.rollingBaseline({ $0.sleepMinutes.map(Double.init) }, excluding: calKey)
        let strainBaseRaw = await dailyStore.ewmaBaseline({ $0.strainScore },     excluding: calKey, alpha: 0.069)
        let rrBaseRaw     = await dailyStore.ewmaBaseline({ $0.respiratoryRate }, excluding: calKey, alpha: 0.033)

        let hrvBase    = blendBaseline(personal: hrvBaseRaw,    population: EnhancedRecoveryScore.popHRV)
        let rhrBase    = blendBaseline(personal: rhrBaseRaw,    population: EnhancedRecoveryScore.popRHR)
        let sleepBase  = blendBaseline(personal: sleepBaseRaw,  population: EnhancedRecoveryScore.popSleep)
        let strainBase = blendBaseline(personal: strainBaseRaw, population: EnhancedRecoveryScore.popStrain)
        let rrBase     = blendBaseline(personal: rrBaseRaw,     population: EnhancedRecoveryScore.popRR)

        // Phase 2: sleep-window mean respiratory rate via RSA autocorrelation.
        let (dailyRR, rrConfidence) = RespiratoryAggregator.meanRRDuringSleep(
            rrSamples: rrAll,
            sleepSessions: allSessions
        )

        // Phase 2: signal quality from HR/RR sample density + RR availability.
        let hrHistorical = hr.map {
            HistoricalSample(
                timestamp: Date(timeIntervalSince1970: Double($0.timestamp)),
                heartRate: $0.bpm,
                accelerometer: nil,
                rrIntervals: nil
            )
        }
        let signalProcessor = SignalProcessor()
        let sqHR = signalProcessor.signalQuality(hrHistorical)
        // Warmup damp: <14 days of stored history → reduce confidence proportionally.
        let daysObserved = allMetrics.count
        let warmupFactor = min(1.0, Double(daysObserved) / 14.0)
        let baseConf = max(0.2, sqHR) * (0.5 + 0.5 * warmupFactor)

        let need = SleepNeedCalculator().compute(for: date, dailyMetrics: allMetrics, sleepSessions: allSessions)
        print("[SleepNeed] date=\(calKey) baseline=\(need.baselineMinutes) adj=\(need.strainAdjMinutes) debt=\(need.debtMinutes) napcredit=\(need.napCreditMinutes) total=\(need.totalMinutes)")

        let consistencyScore = computeConsistencyScore(sessions: allSessions)

        // Per-assignment HRV/RHR: each bio day computes from RR/HR within its own
        // session window, not from this recompute call's calendar date. Prevents
        // 5/7's HRV from being applied to 5/6 (or vice versa) when one calendar
        // recompute fires. Each bio day's row reflects ITS data only.
        // Filter to bio days within ±1 calendar day of this recompute — sessions
        // outside that window won't have RR/HR data in our load buffer, so
        // writing them with nil HRV would clobber a correct value from another
        // recompute call.
        let prevDC = cal.dateComponents([.year, .month, .day], from: prevDay)
        let prevKey = String(format: "%04d-%02d-%02d", prevDC.year!, prevDC.month!, prevDC.day!)
        let nextDC = cal.dateComponents([.year, .month, .day], from: dayEnd)
        let nextKey = String(format: "%04d-%02d-%02d", nextDC.year!, nextDC.month!, nextDC.day!)
        let relevantKeys: Set<String> = [calKey, prevKey, nextKey]
        let relevantAssignments = assignments.filter { relevantKeys.contains($0.biologicalDateKey) }

        for assignment in relevantAssignments {
            let bioKey = assignment.biologicalDateKey
            let primaryCls = assignment.classifications.first { $0.type == assignment.primaryType }
                ?? assignment.classifications.first

            let totalSleepMin = assignment.totalSleepMinutes

            // Circadian metrics for the primary session
            let primarySession = assignment.episodes.first ?? allSessions.first
            let circadianMetrics: CircadianMetrics
            if let ps = primarySession {
                circadianMetrics = circadian.compute(for: ps)
            } else {
                circadianMetrics = CircadianMetrics(
                    habitualMidpointMin: 0, sessionMidpointMin: 0, deviationMinutes: 0,
                    penalty: 0, isAdapting: false, adaptationDaysRemaining: 0, rollingConsistencyMinutes: 0
                )
            }

            // Sleep efficiency
            let totalBedMin = assignment.episodes.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
            let efficiencyPct = totalBedMin > 0 ? Double(totalSleepMin) / Double(totalBedMin) * 100 : 0

            // Stage breakdown from primary session
            let (deepPct, remPct, _) = primarySession.map { stagePcts($0) } ?? (0, 0, 0)

            // Per-bio-day HRV: from RR within primary session window only.
            // Prefer sleep-windowed RMSSD; if RR data sparse, computeHRV returns nil.
            let bioHRV: Double?
            if let ps = primarySession {
                let sessionStart = ps.start.timeIntervalSince1970
                let sessionEnd   = ps.end.timeIntervalSince1970
                let sessionRR = rrAll.filter {
                    let t = TimeInterval($0.timestamp)
                    return t >= sessionStart && t < sessionEnd
                }
                bioHRV = computeHRV(rrSamples: sessionRR)?.rmssd
            } else {
                bioHRV = nil
            }

            // Per-bio-day RHR: min over the bio day's noon-to-noon window. HK
            // fallback used when WHOOP HR insufficient.
            let bioRHR: Double?
            if let ps = primarySession {
                let bioStart = bioAssigner.biologicalDayStart(for: ps.end)
                let bioEnd = cal.date(byAdding: .day, value: 1, to: bioStart) ?? bioStart
                let bioHRSamples = hrAll.filter {
                    let t = Date(timeIntervalSince1970: TimeInterval($0.timestamp))
                    return t >= bioStart && t < bioEnd
                }
                if let r = computeRHR(hrSamples: bioHRSamples) {
                    bioRHR = r
                } else if let hk = healthKit, let fb = await hk.readLatestRHR(for: ps.end) {
                    bioRHR = fb
                } else {
                    bioRHR = nil
                }
            } else {
                bioRHR = nil
            }

            // Fragmentation: total brief wakes across all episodes
            let totalWakes = assignment.episodes.reduce(0) { $0 + $1.briefWakeCount }
            let totalSleepHours = Double(totalSleepMin) / 60.0

            // Circadian alignment score (inverted penalty)
            let alignmentScore = max(0, 1.0 - circadianMetrics.penalty) * 100

            // Sleep type modifier factor
            let sleepType = assignment.primaryType
            let circadianPenalty = circadianMetrics.penalty

            // sleep baseline mean = personalized need; std from blended history
            let sleepBasePersonalized: (mean: Double, std: Double) =
                (mean: Double(need.totalMinutes), std: sleepBase.std)

            // ---------- Phase 2 hidden-state pipeline ----------
            // Look up previous bio-day's hidden state to seed the EWMA chain.
            let prevBioKey = isoKey(daysBefore: bioKey, by: 1)
            let prevMetrics = allMetrics.first { $0.date == prevBioKey }
            let prev = PhysiologicalDynamics.Prev(
                acuteFatigue:      prevMetrics?.acuteFatigue      ?? PhysiologicalDynamics.seedAcuteFatigue,
                chronicLoad:       prevMetrics?.chronicLoad       ?? PhysiologicalDynamics.seedChronicLoad,
                autonomicStress:   prevMetrics?.autonomicStress   ?? PhysiologicalDynamics.seedAutonomicStress,
                sleepDebt:         prevMetrics?.sleepDebtMinutes ?? PhysiologicalDynamics.seedSleepDebt,
                readinessCapacity: prevMetrics?.readinessCapacity ?? PhysiologicalDynamics.seedReadinessCapacity
            )

            // Confidence per metric. RR confidence comes from RespiratoryAggregator; gated by
            // signal quality + warmup so cold-start days don't move state by full delta.
            let confHRV: Double = bioHRV != nil ? baseConf : 0
            let confRHR: Double = bioRHR != nil ? baseConf : 0
            let confRR:  Double = dailyRR != nil ? baseConf * rrConfidence : 0
            let minConf = min(
                confHRV.isFinite && confHRV > 0 ? confHRV : 1.0,
                confRHR.isFinite && confRHR > 0 ? confRHR : 1.0,
                confRR.isFinite  && confRR  > 0 ? confRR  : 1.0
            )

            // Z-scores for the autonomic chain (consumed by stress + composite alike).
            func zScore(_ v: Double?, _ b: (mean: Double, std: Double)) -> Double {
                guard let v else { return 0 }
                guard b.std > 1e-6 else { return 0 }
                return max(-3.0, min(3.0, (v - b.mean) / b.std))
            }
            let hrvZ = zScore(bioHRV, hrvBase)
            let rhrZ = zScore(bioRHR, rhrBase)
            let rrZ  = zScore(dailyRR, rrBase)

            let hrvZ_eff = hrvZ * confHRV
            let rhrZ_eff = rhrZ * confRHR
            let rrZ_eff  = rrZ  * confRR

            // Illness flag: today RR > +2σ AND yesterday RR > +2σ, both with conf > 0.5.
            // Clears when today rrZ < 1 (single-day clear path — stricter "2 days < 1" handled by
            // the latch only re-arming on the gate above).
            let yesterdayRrZ      = prevMetrics?.respiratoryRate.map { zScore($0, rrBase) } ?? 0
            let yesterdayRrConf   = prevMetrics?.respiratoryConfidence ?? 0
            let yesterdayIllness  = prevMetrics?.illnessFlag ?? false
            let illnessTrigger    = rrZ > 2.0 && confRR > 0.5 && yesterdayRrZ > 2.0 && yesterdayRrConf > 0.5
            let illnessHoldClear  = rrZ < 1.0 && yesterdayRrZ < 1.0
            let illnessFlag       = illnessTrigger || (yesterdayIllness && !illnessHoldClear)

            // Strain → fatigue chain. Logistic strain already produced upstream; tolerance scales.
            let tolerance = PhysiologicalDynamics.strainTolerance(chronicLoad: prev.chronicLoad)
            let strainLoadInput: Double? = strain.map { $0 / tolerance }
            let atlTarget = PhysiologicalDynamics.acuteFatigue(strainLoad: strainLoadInput, prev: prev)
            let ctlTarget = PhysiologicalDynamics.chronicLoad(strainLoad: strainLoadInput, prev: prev)
            let autonomicStressTarget = PhysiologicalDynamics.autonomicStress(
                hrvZ_eff: hrvZ_eff, rhrZ_eff: rhrZ_eff, rrZ_eff: rrZ_eff, prev: prev
            )
            let sleepDebtMinTarget = PhysiologicalDynamics.sleepDebt(
                sleepNeedMin:   need.totalMinutes,
                sleepActualMin: totalSleepMin,
                prev: prev
            )
            let capacityTarget = PhysiologicalDynamics.readinessCapacity(
                acuteFatigue: atlTarget,
                chronicLoad: ctlTarget,
                autonomicStress: autonomicStressTarget,
                sleepDebt: sleepDebtMinTarget,
                illnessFlag: illnessFlag,
                prev: prev
            )

            // Confidence-damp every state delta so noisy days don't lurch state.
            let acuteFatigueNext      = PhysiologicalDynamics.confidenceDamp(prev: prev.acuteFatigue,      next: atlTarget,             minConfidence: minConf)
            let chronicLoadNext       = PhysiologicalDynamics.confidenceDamp(prev: prev.chronicLoad,       next: ctlTarget,             minConfidence: minConf)
            let autonomicStressNext   = PhysiologicalDynamics.confidenceDamp(prev: prev.autonomicStress,   next: autonomicStressTarget, minConfidence: minConf)
            let sleepDebtMinNext      = PhysiologicalDynamics.confidenceDamp(prev: prev.sleepDebt,         next: sleepDebtMinTarget,    minConfidence: minConf)
            let readinessCapacityNext = PhysiologicalDynamics.confidenceDamp(prev: prev.readinessCapacity, next: capacityTarget,        minConfidence: minConf)
            let sleepDebtHoursNext    = sleepDebtMinNext / 60.0

            let breakdown = EnhancedRecoveryScore.compute(
                hrv: bioHRV,
                rhr: bioRHR,
                sleepMinutes: totalSleepMin,
                sleepEfficiencyPct: efficiencyPct,
                briefWakeCount: totalWakes,
                totalSleepHours: totalSleepHours,
                deepPct: deepPct,
                remPct: remPct,
                strain: strain,
                sleepType: sleepType,
                circadianPenalty: circadianPenalty,
                circadianAlignment: alignmentScore / 100.0,
                consistencyScore: consistencyScore,
                hrvBaseline: hrvBase,
                rhrBaseline: rhrBase,
                sleepBaseline: sleepBasePersonalized,
                strainBaseline: strainBase,
                biologicalDateKey: bioKey,
                respiratoryRate: dailyRR,
                respiratoryBaseline: rrBase,
                confHRV: confHRV,
                confRHR: confRHR,
                confRR: confRR,
                readinessCapacity: readinessCapacityNext,
                illnessFlag: illnessFlag
            )

            let sleepMidMin = primarySession.map { midpointMinutes(from: $0) }

            // Write to biological day key (may differ from calendar key)
            await dailyStore.delete(date: bioKey)
            await dailyStore.upsert(DailyMetricsStore.DailyMetrics(
                date:             bioKey,
                rhr:              bioRHR,
                hrvRmssd:         bioHRV,
                hrvSdnn:          hrvSdnn,
                strainScore:      strain,
                sleepMinutes:     totalSleepMin > 0 ? totalSleepMin : nil,
                sleepNeedMinutes: need.totalMinutes,
                recoveryScore:    breakdown.confidence >= 0.5 ? breakdown.overallScore : nil,
                biologicalDate:   bioKey,
                circadianPenalty: circadianPenalty,
                sleepTypeCode:    sleepType.rawValue,
                recoveryConfidence: breakdown.confidence,
                sleepMidpointMin: sleepMidMin,
                recoveryComponents: breakdown,
                respiratoryRate:       dailyRR,
                respiratoryConfidence: rrConfidence,
                acuteFatigue:          acuteFatigueNext,
                chronicLoad:           chronicLoadNext,
                autonomicStress:       autonomicStressNext,
                sleepDebtMinutes:      sleepDebtMinNext,
                readinessCapacity:     readinessCapacityNext,
                strainTolerance:       tolerance,
                illnessFlag:           illnessFlag,
                hrvVersion:            AlgoVersions.hrv,
                strainVersion:         AlgoVersions.strain,
                sleepVersion:          AlgoVersions.sleep,
                recoveryVersion:       AlgoVersions.recovery,
                physiologyVersion:     AlgoVersions.physiology,
                respiratoryRateVersion: AlgoVersions.respiratoryRate
            ))

            // Propagate hidden state to PhysiologicalStateStore → UI.
            if let cb = onScoresUpdated {
                await cb(bioKey, readinessCapacityNext, acuteFatigueNext, chronicLoadNext, sleepDebtHoursNext, autonomicStressNext)
            }

            // Cache derived features so the next recompute for this date can skip clean subsystems.
            if let cache = featureCache {
                let now = Date()
                var features = FeatureCache.CachedFeatures(dirtyFlags: [], computedAt: now)
                features.hrvDeviation         = Metric(value: hrvZ, confidence: confHRV, sampleCount: 1, computedAt: now)
                features.rhrDeviation         = Metric(value: rhrZ, confidence: confRHR, sampleCount: 1, computedAt: now)
                features.respiratoryDeviation = Metric(value: rrZ,  confidence: confRR,  sampleCount: 1, computedAt: now)
                features.acuteFatigue         = Metric(value: acuteFatigueNext,    confidence: minConf, sampleCount: 1, computedAt: now)
                features.chronicLoad          = Metric(value: chronicLoadNext,     confidence: minConf, sampleCount: 1, computedAt: now)
                features.autonomicStress      = Metric(value: autonomicStressNext, confidence: minConf, sampleCount: 1, computedAt: now)
                features.readinessCapacity    = Metric(value: readinessCapacityNext, confidence: minConf, sampleCount: 1, computedAt: now)
                features.strainTolerance      = Metric(value: tolerance,           confidence: 1.0,     sampleCount: 1, computedAt: now)
                features.sleepDebt            = Metric(value: sleepDebtHoursNext,
                                                       confidence: totalSleepMin > 0 ? 1.0 : 0.3,
                                                       sampleCount: 1, computedAt: now)
                features.sleepConsistency     = Metric(value: consistencyScore, confidence: 1.0, sampleCount: 1, computedAt: now)
                features.illnessFlag          = illnessFlag
                await cache.upsert(features, for: bioKey)
            }

            // Write/update snapshot for this bio day.
            if let snapStore = snapshotStore {
                let isTodayBioKey = bioKey == calKey
                let snapshot = DailySnapshot(
                    dateKey:          bioKey,
                    finalizedAt:      Date(),
                    recoveryScore:    breakdown.confidence >= 0.5 ? breakdown.overallScore : nil,
                    strain:           strain,
                    sleepMinutes:     totalSleepMin > 0 ? totalSleepMin : nil,
                    sleepNeedMinutes: need.totalMinutes,
                    sleepDebt:        sleepDebtHoursNext,
                    hrvRMSSD:         bioHRV,
                    rhr:              bioRHR,
                    algorithmVersion: AlgoVersions.recovery,
                    isMutable:        isTodayBioKey
                )
                await snapStore.upsert(snapshot)
            }

            let rhrStr  = bioRHR.map { String(format: "%.1f", $0) } ?? "nil"
            let rmsdStr = bioHRV.map { String(format: "%.1f ms", $0) } ?? "nil"
            let recStr  = String(format: "%.0f", breakdown.overallScore)
            print("[Recompute] \(bioKey) → RHR=\(rhrStr) RMSSD=\(rmsdStr) Sleep=\(totalSleepMin)min Recovery=\(recStr) type=\(sleepType) circadian=\(String(format: "%.2f", circadianPenalty)) conf=\(String(format: "%.2f", breakdown.confidence))")
        }

        // Also write a calendar-day row for non-sleep metrics if different from bio day
        let assignedBioKeys = Set(assignments.map(\.biologicalDateKey))
        if !assignedBioKeys.contains(calKey) {
            let existing = await dailyStore.load(date: calKey)
            if existing == nil {
                // Calendar-day row for non-sleep days: store today's RHR/RMSSD if any.
                let calRHR = computeRHR(hrSamples: hr)
                let calHRV = computeHRVSleep(rrSamples: rr, hrSamples: hr, sleepSessions: allSessions, date: date) ?? calDayFullHRV?.rmssd
                await dailyStore.upsert(DailyMetricsStore.DailyMetrics(
                    date: calKey, rhr: calRHR, hrvRmssd: calHRV,
                    hrvSdnn: hrvSdnn, strainScore: strain,
                    sleepMinutes: nil, sleepNeedMinutes: need.totalMinutes,
                    recoveryScore: nil, biologicalDate: nil, circadianPenalty: nil,
                    sleepTypeCode: nil, recoveryConfidence: nil, sleepMidpointMin: nil,
                    recoveryComponents: nil,
                    respiratoryRate: nil, respiratoryConfidence: nil,
                    acuteFatigue: nil, chronicLoad: nil, autonomicStress: nil,
                    sleepDebtMinutes: nil, readinessCapacity: nil, strainTolerance: nil,
                    illnessFlag: nil,
                    hrvVersion: AlgoVersions.hrv, strainVersion: AlgoVersions.strain,
                    sleepVersion: AlgoVersions.sleep, recoveryVersion: AlgoVersions.recovery,
                    physiologyVersion: AlgoVersions.physiology,
                    respiratoryRateVersion: AlgoVersions.respiratoryRate
                ))
            }
        }
    }

    /// Blend personal baseline toward population during warmup window.
    /// New users with <warmup days of data get a baseline that's part-personal,
    /// part-population, weighted by how many days we've collected.
    /// At warmup days (default 7), shrinkage is 0 — full personal trust.
    private func blendBaseline(
        personal: (mean: Double, std: Double, count: Int)?,
        population: (mean: Double, std: Double),
        warmup: Int = 7
    ) -> (mean: Double, std: Double) {
        guard let p = personal else { return population }
        guard p.count < warmup else { return (p.mean, max(1e-6, p.std)) }
        let w = Double(p.count) / Double(warmup)
        return (
            mean: w * p.mean + (1 - w) * population.mean,
            std:  max(1e-6, w * p.std  + (1 - w) * population.std)
        )
    }

    private func loadSleepSessions() -> [SleepSession] {
        guard let data = UserDefaults.standard.data(forKey: "whoopSleepSessions_v1"),
              let sessions = try? JSONDecoder().decode([SleepSession].self, from: data) else { return [] }
        return sessions
    }

    private func midpointMinutes(from session: SleepSession) -> Int {
        let duration = session.end.timeIntervalSince(session.start)
        let mid = session.start.addingTimeInterval(duration / 2)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: mid)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private func isoDate(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Convert an ISO date key (yyyy-MM-dd) to the key N days earlier, UTC.
    private func isoKey(daysBefore key: String, by days: Int) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var dc = DateComponents()
        dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
        guard let d = cal.date(from: dc),
              let prev = cal.date(byAdding: .day, value: -days, to: d) else { return key }
        let c = cal.dateComponents([.year, .month, .day], from: prev)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
