// WeekFatigueSignals.swift
// ProjectApex — Models
//
// Weekly fatigue projection consumed by the trainee-model digest
// (B4 / #89). Previously lived in Services/SessionPlanService.swift;
// relocated to Models/ so that TraineeModelDigest can carry it as
// a structured field. Pure value type — no I/O, no actor dependency.
//
// Fatigue logic (FB-008 ACs):
//   • weekly_avg_rpe > 8.2 across 3+ sessions → reduce next session volume 20%
//   • If any 2 of 3 deload triggers fire across rolling 7-day window → generate deload

import Foundation

/// Aggregated fatigue signals derived from completed sessions in the current 7-day window.
nonisolated struct WeekFatigueSignals: Codable, Sendable {
    /// Number of sessions completed this week (Mon–Sun).
    let sessionsCompletedThisWeek: Int
    /// Average RPE across all sets this week. Nil when no sets logged yet.
    let weeklyAvgRPE: Double?
    /// Rep completion rate across all sets this week (repsCompleted / repsTarget).
    let repCompletionRate: Double?
    /// Number of significant compound lift misses this week (< 60% rep completion).
    let significantMissCount: Int
    /// Total sets per primary muscle this week, e.g.
    /// [.chest: 12, .quads: 6, .hamstrings: 4]. Keyed on PrimaryMuscle so
    /// the LLM sees fine-grained leg-subgroup balance ("user has been
    /// quad-light for 3 sessions" reasoning); collapsing to MuscleGroup
    /// at this stage would erase the very distinction PrimaryMuscle was
    /// introduced to preserve. Core is excluded — the 4 core exercises
    /// were removed from ExerciseLibrary in Slice 1.
    let setsPerPrimaryMuscle: [PrimaryMuscle: Int]
    /// True when cumulative weekly RPE > 8.2 across 3+ sessions.
    let fatigueManagementFlagged: Bool
    /// True when deload triggers fire: ≥2 of [avg_rpe > 8.0, rep_rate < 75%, 3+ misses].
    let deloadTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case sessionsCompletedThisWeek = "sessions_completed_this_week"
        case weeklyAvgRPE              = "weekly_avg_rpe"
        case repCompletionRate         = "rep_completion_rate"
        case significantMissCount      = "significant_miss_count"
        case setsPerPrimaryMuscle      = "sets_per_primary_muscle"
        case fatigueManagementFlagged  = "fatigue_management_flagged"
        case deloadTriggered           = "deload_triggered"
    }

    /// Computes fatigue signals from a list of completed set logs this week.
    static func compute(from setLogs: [SetLog], sessionCount: Int) -> WeekFatigueSignals {
        guard !setLogs.isEmpty else {
            return WeekFatigueSignals(
                sessionsCompletedThisWeek: sessionCount,
                weeklyAvgRPE: nil,
                repCompletionRate: nil,
                significantMissCount: 0,
                setsPerPrimaryMuscle: [:],
                fatigueManagementFlagged: false,
                deloadTriggered: false
            )
        }

        let rpeValues = setLogs.compactMap { $0.rpeFelt.map { Double($0) } }
        let avgRPE = rpeValues.isEmpty ? nil : rpeValues.reduce(0, +) / Double(rpeValues.count)

        // For rep completion rate we look at AI prescribed vs actual.
        // Where we have aiPrescribed data, compare. Otherwise skip.
        var repCompPairs: [(target: Int, actual: Int)] = []
        var sigMisses = 0
        var muscleSetCounts: [PrimaryMuscle: Int] = [:]

        for log in setLogs {
            if let prescribed = log.aiPrescribed {
                let target = prescribed.reps
                let actual = log.repsCompleted
                repCompPairs.append((target: target, actual: actual))
                let rate = Double(actual) / Double(max(target, 1))
                if rate < 0.60 { sigMisses += 1 }
            }
            // Primary muscle from exerciseId — drops core / unknown (no
            // representation in the 9-case PrimaryMuscle taxonomy).
            if let muscle = primaryMuscle(for: log.exerciseId) {
                muscleSetCounts[muscle, default: 0] += 1
            }
        }

        let repRate: Double?
        if !repCompPairs.isEmpty {
            let totalTarget = repCompPairs.map(\.target).reduce(0, +)
            let totalActual = repCompPairs.map(\.actual).reduce(0, +)
            repRate = Double(totalActual) / Double(max(totalTarget, 1))
        } else {
            repRate = nil
        }

        // Fatigue management: avg RPE > 8.2 across 3+ sessions
        let fatigueManagementFlagged = (avgRPE ?? 0) > 8.2 && sessionCount >= 3

        // Deload trigger: ≥2 of the 3 signals
        var deloadSignals = 0
        if (avgRPE ?? 0) > 8.0 { deloadSignals += 1 }
        if (repRate ?? 1.0) < 0.75 { deloadSignals += 1 }
        if sigMisses >= 3 { deloadSignals += 1 }
        let deloadTriggered = deloadSignals >= 2

        return WeekFatigueSignals(
            sessionsCompletedThisWeek: sessionCount,
            weeklyAvgRPE: avgRPE,
            repCompletionRate: repRate,
            significantMissCount: sigMisses,
            setsPerPrimaryMuscle: muscleSetCounts,
            fatigueManagementFlagged: fatigueManagementFlagged,
            deloadTriggered: deloadTriggered
        )
    }

    /// Maps an exerciseId to a PrimaryMuscle. Prefers the canonical
    /// ExerciseLibrary lookup; falls back to string heuristics for
    /// non-canonical IDs. Returns nil for core / unmapped IDs (the 9-case
    /// PrimaryMuscle taxonomy excludes core per ADR-0005).
    private static func primaryMuscle(for exerciseId: String) -> PrimaryMuscle? {
        if let primary = ExerciseLibrary.primaryMuscle(for: exerciseId) {
            return primary
        }
        let lower = exerciseId.lowercased()
        if lower.contains("bench") || lower.contains("chest") || lower.contains("pec") { return .chest }
        if lower.contains("row") || lower.contains("pulldown") || lower.contains("pull_up") || lower.contains("lat") { return .back }
        if lower.contains("squat") || lower.contains("leg_press") || lower.contains("quad") || lower.contains("lunge") { return .quads }
        if lower.contains("deadlift") || lower.contains("rdl") { return .hamstrings }
        if lower.contains("hamstring") { return .hamstrings }
        if lower.contains("glute") || lower.contains("hip_thrust") { return .glutes }
        if lower.contains("press") && lower.contains("shoulder") { return .shoulders }
        if lower.contains("overhead") || lower.contains("ohp") { return .shoulders }
        if lower.contains("curl") && !lower.contains("leg") { return .biceps }
        if lower.contains("tricep") || lower.contains("pushdown") { return .triceps }
        if lower.contains("calf") || lower.contains("raise") { return .calves }
        // "ab"/"core" mappings dropped — core is excluded from the 9-case
        // PrimaryMuscle taxonomy per ADR-0005.
        return nil
    }
}
