import Foundation

/// Computes a 0–100 recovery score from z-scored biometrics.
/// Formula: 50 + 0.4·HRV_z·10 − 0.25·RHR_z·10 + 0.25·Sleep_z·10 − 0.1·Strain_z·10
///
/// Falls back to population norms when personal baselines are unavailable (< 3 days of data),
/// so a score is shown from day 1.
struct RecoveryScore {

    // Population norms used until personal 30-day baselines accumulate.
    static let popHRV:    (mean: Double, std: Double) = (mean: 45,  std: 20)  // ms RMSSD
    static let popRHR:    (mean: Double, std: Double) = (mean: 62,  std: 8)   // bpm
    static let popSleep:  (mean: Double, std: Double) = (mean: 420, std: 60)  // minutes (7h)
    static let popStrain: (mean: Double, std: Double) = (mean: 10,  std: 4)   // 0–21 scale

    static func compute(
        hrv: Double?,
        rhr: Double?,
        sleepMinutes: Int?,
        strain: Double?,
        hrvBaseline:   (mean: Double, std: Double)?,
        rhrBaseline:   (mean: Double, std: Double)?,
        sleepBaseline: (mean: Double, std: Double)?,
        strainBaseline:(mean: Double, std: Double)?
    ) -> Double? {
        guard let hrv, let rhr, let strain else { return nil }

        let hb  = hrvBaseline    ?? popHRV
        let rb  = rhrBaseline    ?? popRHR
        let sb  = sleepBaseline  ?? popSleep
        let stb = strainBaseline ?? popStrain

        func z(_ v: Double, _ b: (mean: Double, std: Double)) -> Double {
            guard b.std > 1e-6 else { return 0 }
            return max(-3.0, min(3.0, (v - b.mean) / b.std))  // §9.8 clamp
        }

        // sleepMinutes nil = no sleep detected = neutral (z=0). Distinct from "0 minutes
        // actually slept" which is detected (sleep=0 → z ≈ −3 after clamp). Prevents
        // recovery from being unfairly tanked when overnight sync hasn't run yet.
        let sleepZ: Double = sleepMinutes.map { z(Double($0), sb) } ?? 0

        // Composite z-score (signed: positive = recovered).
        let composite = 0.4  *  z(hrv,    hb)
                      - 0.25 *  z(rhr,    rb)
                      + 0.25 *  sleepZ
                      - 0.1  *  z(strain, stb)

        // tanh maps composite → (-1, 1) smoothly; ×40 spreads range ~10–90 for real-world values.
        // Cannot saturate at 0 or 100 unless metrics are extreme outliers.
        return 50.0 + 40.0 * tanh(composite)
    }
}
