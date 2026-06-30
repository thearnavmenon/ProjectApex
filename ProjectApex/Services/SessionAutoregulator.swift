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
        requiresReturnOverride: Bool
    ) -> TrainingDay {
        let exercises = day.exercises.map { ex -> PlannedExercise in
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
}
