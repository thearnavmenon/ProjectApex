// Program.swift — ADR-0030 / #562: queue-native program model + flatten adapter.
//
// The committed, queue-native program: a frozen ordered queue of day-slots
// (exercise identity + rep-range frozen per slot) with a queue position; length
// is measured in sessions, not weeks (ADR-0002 — no calendar, no dayOfWeek).
//
// This slice is ADDITIVE and behind nothing user-facing: it ships the model and
// a `Mesocycle.flatten()` adapter that reads the live calendar-shaped `Mesocycle`
// into a `Program`. Nothing on the live path reads `Program` yet (the block-commit
// writer is #563; the deterministic instantiator is #564).
//
// Why an adapter over the decoded `Mesocycle` rather than a new JSON decoder: the
// existing `Mesocycle` decoder (JSONDecoder.workoutProgram) already decodes every
// live `mesocycle_json` row today. `flatten()` is a total, pure transformation of
// an already-valid `Mesocycle` object — there is no new JSON-parse path, so this
// slice cannot strand an active program on a decode error (the data-risk the issue
// flags). The on-disk JSONB column shape is unchanged.

import Foundation

// MARK: - SlotTemplate

/// One committed day-slot in the program's queue. Exercise identity and rep-range
/// are frozen for the block; set-count / RIR progress deterministically later
/// (#564), so they are not modeled here.
nonisolated struct SlotTemplate: Identifiable, Sendable {
    let id: UUID
    /// Per-user join key, preserved VERBATIM from the source `TrainingDay`.
    /// ADR-0017: `deepLiftHistory` joins `day_type == dayLabel` — this must never
    /// be rewritten or the lift-history join silently breaks.
    let dayLabel: String
    /// The committed exercise pool for this slot (frozen identity per ADR-0030).
    let exercisePool: [PlannedExercise]
    /// Frozen rep-range for the slot — the primary (first) exercise's rep-range.
    /// `nil` for an empty, not-yet-generated (pending) slot; #563 sets this
    /// explicitly when it commits the pool.
    let repRange: RepRange?
    /// Terminal status carried from the source day — drives `queuePosition`.
    let status: TrainingDayStatus

    /// Mirrors `TrainingDay.isTerminal` (#445): `.completed` / `.skipped` both
    /// advance the queue and count as done.
    var isTerminal: Bool { status == .completed || status == .skipped }
}

// MARK: - Program

/// The committed, queue-native program (ADR-0030). A frozen ordered queue of
/// day-slots plus the queue head (`queuePosition`).
nonisolated struct Program: Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let createdAt: Date
    var isActive: Bool
    /// Ordered queue of day-slots, in source week-then-day order.
    let split: [SlotTemplate]
    /// Index of the queue head — the first non-terminal slot. Equals
    /// `split.count` when every slot is terminal (program complete).
    let queuePosition: Int
    let periodizationModel: String
}

// MARK: - Mesocycle → Program flatten adapter

extension Mesocycle {
    /// Flatten this calendar-shaped `Mesocycle` into a queue-native `Program`
    /// (ADR-0030 / #562). Walks `weeks` in order, concatenates `trainingDays`
    /// into one ordered `split`, preserves each `dayLabel` verbatim (ADR-0017),
    /// freezes each slot's rep-range from its primary exercise, and sets
    /// `queuePosition` to the first non-terminal slot.
    ///
    /// Pure transformation over an already-decoded `Mesocycle` — no JSON re-parse,
    /// so it cannot fail to decode a live row.
    func flatten() -> Program {
        let slots: [SlotTemplate] = weeks
            .flatMap(\.trainingDays)
            .map { day in
                SlotTemplate(
                    id: day.id,
                    dayLabel: day.dayLabel,
                    exercisePool: day.exercises,
                    repRange: day.exercises.first?.repRange,
                    status: day.status
                )
            }
        let queuePosition = slots.firstIndex { !$0.isTerminal } ?? slots.count
        return Program(
            id: id,
            userId: userId,
            createdAt: createdAt,
            isActive: isActive,
            split: slots,
            queuePosition: queuePosition,
            periodizationModel: periodizationModel
        )
    }
}
