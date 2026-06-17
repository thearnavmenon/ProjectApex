// ResolvePausedSentinelTests.swift
// ProjectApexTests
//
// #465 — Pause flow tightening (spine). Tapping "Pause workout" in place used to
// dump the user on PreWorkoutView instead of the deliberate WorkoutPausedView,
// because only WorkoutView's `.task` (runs on appearance) resolved the paused
// sentinel into `pausedForThisDay`; the `.onChange(.idle)` arm never did. The fix
// extracts a pure helper, `WorkoutView.resolvePausedSentinel`, shared by both the
// `.task` block and the `.idle` arm so they converge on the same render decision.
//
// These tests pin the helper's contract: it returns the saved sentinel iff the
// actor is idle AND the sentinel names THIS view's day, else nil.

import XCTest
@testable import ProjectApex

final class ResolvePausedSentinelTests: XCTestCase {

    private func sentinel(for dayId: UUID) -> PausedSessionState {
        PausedSessionState(
            sessionId: UUID(),
            trainingDayId: dayId,
            weekId: UUID(),
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: "push",
            programId: UUID(),
            userId: UUID(),
            pausedAt: Date()
        )
    }

    // The in-place-pause edge: actor went idle and a sentinel for THIS day exists.
    // This is the case that used to resolve to nil (the bug) — it must now return
    // the sentinel so contentForState(.idle) renders WorkoutPausedView.
    func test_idleEdge_sentinelForThisDay_returnsSentinel() {
        let dayId = UUID()
        let saved = sentinel(for: dayId)

        let resolved = WorkoutView.resolvePausedSentinel(
            saved: saved,
            actorIsIdle: true,
            trainingDayId: dayId
        )

        XCTAssertEqual(resolved?.sessionId, saved.sessionId)
    }

    // A sentinel for a DIFFERENT day must not adopt this view's render.
    func test_sentinelForOtherDay_returnsNil() {
        let saved = sentinel(for: UUID())

        let resolved = WorkoutView.resolvePausedSentinel(
            saved: saved,
            actorIsIdle: true,
            trainingDayId: UUID()
        )

        XCTAssertNil(resolved)
    }

    // No saved sentinel → nil regardless of idleness.
    func test_noSentinel_returnsNil() {
        let resolved = WorkoutView.resolvePausedSentinel(
            saved: nil,
            actorIsIdle: true,
            trainingDayId: UUID()
        )

        XCTAssertNil(resolved)
    }

    // Actor not idle (e.g. a live session) → do not surface the paused screen.
    func test_actorNotIdle_returnsNil() {
        let dayId = UUID()
        let saved = sentinel(for: dayId)

        let resolved = WorkoutView.resolvePausedSentinel(
            saved: saved,
            actorIsIdle: false,
            trainingDayId: dayId
        )

        XCTAssertNil(resolved)
    }
}
