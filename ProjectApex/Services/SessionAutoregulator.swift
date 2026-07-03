// SessionAutoregulator.swift — ADR-0030 / #564: deterministic day instantiation.
//
// Instantiates a workout session by pulling the FROZEN day-slot (committed
// exercises + rep-ranges from #563) and applying trainee-model-digest deltas as
// pure arithmetic — NO network, NO LLM. Exercise identity and rep-range stay
// frozen for the block; only set-count and RIR are computed here (they progress
// deterministically against the per-pattern phase). This is the deterministic
// fallback the "Coach is offline" incidents (#555/#556) lacked — a session can
// always be instantiated without a live call.
//
// Why this depends on the goal-branch (#559): the per-pattern phase read here is
// the one #559 made goal-aware, so a hypertrophy user's instantiation is never
// baked into a strength peaking taper.

import Foundation

struct SessionAutoregulator {

    /// Pure prescription rule: base sets/RIR from the pattern's current phase,
    /// then deterministic deltas. Extracted so it is trivially golden-testable
    /// without constructing a full digest.
    ///
    /// - deload phase → ~50% volume, high RIR (recovery week).
    /// - declining trend → back off ~one working set + RIR +1 (regression guard).
    /// - return-to-training → ease back: fewer sets + RIR +1.
    /// - volume-deficit (muscle below MEV) → +1 working set (top-up).
    /// - none of the above → the frozen phase target, verbatim.
    static func prescription(
        phase: MesocyclePhase,
        trend: ProgressionTrend,
        volumeDeficit: Int,
        requiresReturnOverride: Bool
    ) -> (sets: Int, rir: Int) {
        var (sets, rir) = baseSetsRIR(for: phase)

        if requiresReturnOverride {
            sets -= 1
            rir += 1
        }
        if trend == .declining {
            sets -= 1
            rir += 1
        }
        if volumeDeficit > 0 {
            sets += 1
        }

        return (min(6, max(1, sets)), min(5, max(0, rir)))
    }

    /// Base sets/RIR per mesocycle phase. `deload` is the ~50%-volume recovery
    /// week (2 sets vs accumulation's 4); peaking is heaviest (low RIR).
    static func baseSetsRIR(for phase: MesocyclePhase) -> (sets: Int, rir: Int) {
        switch phase {
        case .accumulation:    return (4, 3)
        case .intensification: return (3, 2)
        case .peaking:         return (3, 1)
        case .deload:          return (2, 4)
        }
    }

    /// Instantiate a full session deterministically from a frozen day-slot (its
    /// committed exercises) + the trainee-model digest. Each exercise keeps its
    /// frozen identity and rep-range; set-count and RIR are computed from the
    /// exercise's movement-pattern phase/trend + its muscle's volume deficit.
    /// No digest (first session / cold start) → the accumulation baseline.
    static func instantiate(
        day: TrainingDay,
        digest: TraineeModelDigest?,
        requiresReturnOverride: Bool,
        targetExerciseCount: Int? = nil
    ) -> TrainingDay? {
        // #558 (ADR-0030): the committed exercise pool is the frozen identity the
        // block-commit generator (#563) writes onto each day. An empty pool means the
        // day predates that generator (a stale pre-2026-06-30 program) — there is
        // nothing to instantiate. Refuse rather than fabricate an unstartable
        // `.generated` day with zero exercises (the silent "greyed Start" dead-end).
        guard !day.exercises.isEmpty else { return nil }

        // S2: trim toward the user's target session size (floor-aware selection from
        // the FROZEN committed pool — invents nothing, keeps identity + rep-range).
        // nil target → the full committed slot (back-compat / opted-out).
        let exercises = selectForTarget(day.exercises, target: targetExerciseCount)
            .map { ex -> PlannedExercise in
            let pattern = ExerciseLibrary.lookup(ex.exerciseId)?.movementPattern
            let patternSummary = pattern.flatMap { p in
                digest?.perPatternSummary.first { $0.pattern == p }
            }
            let phase = patternSummary?.currentPhase ?? .accumulation
            let trend = patternSummary?.trend ?? .progressing

            let group = ExerciseLibrary.primaryMuscle(for: ex.exerciseId)?.muscleGroup
            let volumeDeficit = group.flatMap { g in
                digest?.perMuscleSummary.first { $0.muscleGroup == g }?.volumeDeficit
            } ?? 0

            let (sets, rir) = prescription(
                phase: phase,
                trend: trend,
                volumeDeficit: volumeDeficit,
                requiresReturnOverride: requiresReturnOverride
            )

            return PlannedExercise(
                id: ex.id,
                exerciseId: ex.exerciseId,
                name: ex.name,
                primaryMuscle: ex.primaryMuscle,
                synergists: ex.synergists,
                equipmentRequired: ex.equipmentRequired,
                sets: sets,                 // deterministic (#564)
                repRange: ex.repRange,      // FROZEN per slot (#563)
                tempo: ex.tempo,
                restSeconds: ex.restSeconds,
                rirTarget: rir,             // deterministic (#564)
                coachingCues: ex.coachingCues
            )
        }

        return TrainingDay(
            id: day.id,
            dayOfWeek: day.dayOfWeek,
            dayLabel: day.dayLabel,
            exercises: exercises,
            sessionNotes: day.sessionNotes,
            status: .generated
        )
    }

    /// Floor-aware, compound-first selection of `target` exercises from the FROZEN
    /// committed pool (S2). The committed pool is ordered compounds→isolations, so a
    /// naive prefix would starve small muscles whose only direct work is a tail
    /// isolation (side/rear delts, biceps, calves). This keeps the compound-first
    /// prefix but then guarantees ≥1 direct (primary-muscle) exercise for every
    /// primary muscle the day trains — pulling a dropped exercise back if a muscle
    /// would otherwise be zeroed. If coverage requires more than `target`, coverage
    /// wins (never starve a muscle to hit a number). Returns the pool unchanged when
    /// `target` is nil or ≥ the pool size. Committed order is always preserved, so
    /// the result is deterministic.
    static func selectForTarget(_ committed: [PlannedExercise], target: Int?) -> [PlannedExercise] {
        guard let target, target > 0, target < committed.count else { return committed }

        // 1. Compound-first prefix.
        var keptIds = Set(committed.prefix(target).map(\.id))

        // 2. Coverage guard: every primary muscle the day trains keeps ≥1 direct exercise.
        let trainedPrimaries = Set(committed.map(\.primaryMuscle))
        let coveredPrimaries = Set(committed.filter { keptIds.contains($0.id) }.map(\.primaryMuscle))
        for muscle in trainedPrimaries.subtracting(coveredPrimaries) {
            // Pull back the highest-priority (earliest committed) dropped exercise
            // that directly trains this muscle.
            if let rescue = committed.first(where: { $0.primaryMuscle == muscle && !keptIds.contains($0.id) }) {
                keptIds.insert(rescue.id)
            }
        }

        // 3. Preserve committed order (deterministic regardless of set iteration).
        return committed.filter { keptIds.contains($0.id) }
    }
}
