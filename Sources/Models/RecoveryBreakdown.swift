import Foundation

struct RecoveryBreakdown: Codable, Sendable {
    let overallScore: Double        // 0–100
    let autonomicRecovery: Double   // 0–100
    let sleepQuantity: Double       // 0–100
    let sleepEfficiency: Double     // 0–100
    let circadianAlignment: Double  // 0–100
    let sleepConsistency: Double    // 0–100
    let sleepFragmentation: Double  // 0–100
    let stageQuality: Double        // 0–100
    let effectiveQuantity: Double   // 0–100 (after timing modifier)
    let effectiveEfficiency: Double // 0–100 (after timing modifier)
    let effectiveStageQuality: Double // 0–100 (after timing modifier)
    let confidence: Double          // 0.0–1.0
    let circadianPenalty: Double    // 0.0–1.0
    let sleepTypeModifier: Double   // 1.0 / 0.85 / 0.50 / 0.0
    let biologicalDateKey: String

    // Component weights for explainability
    static let weightAutonomic: Double         = 0.25
    static let weightQuantity: Double          = 0.20
    static let weightEfficiency: Double        = 0.10
    static let weightCircadian: Double         = 0.20
    static let weightConsistency: Double       = 0.10
    static let weightFragmentation: Double     = 0.10
    static let weightStageQuality: Double      = 0.05

    var componentDetail: [(label: String, score: Double, weight: Double)] {
        [
            ("Autonomic",   autonomicRecovery,   Self.weightAutonomic),
            ("Sleep Qty",   effectiveQuantity,   Self.weightQuantity),
            ("Efficiency",  effectiveEfficiency, Self.weightEfficiency),
            ("Circadian",   circadianAlignment,  Self.weightCircadian),
            ("Consistency", sleepConsistency,    Self.weightConsistency),
            ("Fragmented",  sleepFragmentation,  Self.weightFragmentation),
            ("Stage Qual",  effectiveStageQuality, Self.weightStageQuality),
        ]
    }

    var isFinite: Bool {
        overallScore.isFinite && autonomicRecovery.isFinite
        && sleepQuantity.isFinite && sleepEfficiency.isFinite
        && circadianAlignment.isFinite && sleepConsistency.isFinite
        && sleepFragmentation.isFinite && stageQuality.isFinite
        && effectiveQuantity.isFinite && effectiveEfficiency.isFinite
        && effectiveStageQuality.isFinite && confidence.isFinite
        && circadianPenalty.isFinite && sleepTypeModifier.isFinite
    }

    var weightedSum: Double {
        autonomicRecovery   * Self.weightAutonomic
        + effectiveQuantity   * Self.weightQuantity
        + effectiveEfficiency * Self.weightEfficiency
        + circadianAlignment  * Self.weightCircadian
        + sleepConsistency    * Self.weightConsistency
        + sleepFragmentation  * Self.weightFragmentation
        + effectiveStageQuality * Self.weightStageQuality
    }
}
