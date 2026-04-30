import Foundation

// Detects steps from accelerometer samples using a two-stage IIR filter + peak detection.
// Algorithm: high-pass (remove gravity) → low-pass (smooth) → threshold + timing gate.
final class StepDetector {

    // Tunable parameters
    private let highPassAlpha: Float = 0.94   // ~0.25 Hz cutoff at ~25 Hz sample rate
    private let lowPassBeta: Float   = 0.80   // ~3 Hz cutoff at ~25 Hz sample rate
    private let peakThreshold: Float = 0.15   // g — minimum filtered magnitude for a step
    private let minStepInterval: TimeInterval = 0.30  // 300 ms minimum between steps

    private(set) var stepCount: Int = 0

    private var prevMagnitude: Float = 0
    private var hpState: Float = 0      // high-pass filter memory
    private var lpState: Float = 0      // low-pass filter memory
    private var lastStepTime: Date = .distantPast
    private var prevFiltered: Float = 0
    private var prevWasAbove = false

    func process(_ sample: AccelerometerSample) {
        let raw = sample.magnitude

        // High-pass: removes gravity component (DC offset)
        let hp = highPassAlpha * (hpState + raw - prevMagnitude)
        hpState = hp
        prevMagnitude = raw

        // Low-pass: smooths high-frequency noise
        let lp = lowPassBeta * lpState + (1 - lowPassBeta) * hp
        lpState = lp

        // Peak detection: rising edge crossing threshold with minimum time gate
        let isAbove = lp > peakThreshold
        if isAbove && !prevWasAbove {
            let interval = sample.timestamp.timeIntervalSince(lastStepTime)
            if interval >= minStepInterval {
                stepCount += 1
                lastStepTime = sample.timestamp
            }
        }
        prevWasAbove = isAbove
    }

    func reset() {
        stepCount = 0
        prevMagnitude = 0; hpState = 0; lpState = 0
        lastStepTime = .distantPast; prevWasAbove = false
    }
}
