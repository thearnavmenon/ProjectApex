// TraineeModelLocalStoreTests.swift
// ProjectApexTests
//
// Integration tests for TraineeModelLocalStore (Phase 1 / Slice 8, issue #8).
//
// @MainActor is required on this class: TraineeModelLocalStore is
// @MainActor-isolated (ModelContainer has internal main-actor executor
// requirements), so all store interactions must happen on the main actor.
// XCTest fully supports @MainActor test classes.
//
// All tests use an in-memory SwiftData container unless persistence across
// simulated restart is being tested (which requires an on-disk container
// at a temp URL that is cleaned up in tearDown).
//
// Behaviors covered:
//   • Empty store returns nil on load()
//   • save → load round-trips the model faithfully
//   • Second save replaces first (upsert semantics)
//   • clear() empties the store
//   • Persistence survives simulated restart (new container, same SQLite file)
//   • Cold-start hydration from a representative Edge Function payload

import XCTest
import SwiftData
@testable import ProjectApex

@MainActor
final class TraineeModelLocalStoreTests: XCTestCase {

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private func makeStore() throws -> TraineeModelLocalStore {
        try TraineeModelLocalStore.makeInMemory()
    }

    /// Minimal TraineeModel for basic round-trip tests. Uses a fixed Date so
    /// JSON encode → decode produces bit-identical values.
    private func makeMinimalModel() -> TraineeModel {
        TraineeModel(
            goal: GoalState(
                statement: "Build strength",
                focusAreas: [],
                updatedAt: Date(timeIntervalSinceReferenceDate: 0)
            )
        )
    }

    /// Richer model exercising patterns, muscles, exercises, and limitations
    /// to simulate a realistic Edge Function response payload.
    private func makeRepresentativeModel() -> TraineeModel {
        let ref0 = Date(timeIntervalSinceReferenceDate: 0)
        return TraineeModel(
            activeProgramId: UUID(uuidString: "12345678-1234-1234-1234-123456789012"),
            goal: GoalState(
                statement: "Build muscle and strength",
                focusAreas: [.back, .legs],
                updatedAt: ref0
            ),
            patterns: [
                .squat: PatternProfile(
                    pattern: .squat,
                    currentPhase: .accumulation,
                    sessionsInPhase: 3,
                    rpeOffset: -0.5,
                    confidence: .calibrating,
                    recentSessionDates: [ref0]
                ),
                .horizontalPush: PatternProfile(
                    pattern: .horizontalPush,
                    currentPhase: .intensification,
                    sessionsInPhase: 6,
                    rpeOffset: 0,
                    confidence: .established,
                    recentSessionDates: [ref0]
                )
            ],
            muscles: [
                .legs: MuscleProfile(
                    muscleGroup: .legs,
                    volumeTolerance: 14.0,
                    observedSweetSpot: 12,
                    volumeDeficit: 2,
                    focusWeight: 0.6,
                    confidence: .calibrating
                ),
                .chest: MuscleProfile(
                    muscleGroup: .chest,
                    volumeTolerance: 10.0,
                    confidence: .established
                )
            ],
            exercises: [
                "barbell-back-squat": ExerciseProfile(
                    exerciseId: "barbell-back-squat",
                    e1rmCurrent: 120.0,
                    e1rmMedian: 115.0,
                    e1rmPeak: 130.0,
                    sessionCount: 8,
                    confidence: .calibrating
                )
            ],
            totalSessionCount: 8
        )
    }

    // MARK: ─── Cycle 1: empty store → nil ────────────────────────────────────

    func test_load_returnsNil_whenStoreIsEmpty() throws {
        let store = try makeStore()
        XCTAssertNil(store.load())
    }

    // MARK: ─── Cycle 2: save → load round-trip ────────────────────────────────

    func test_saveAndLoad_roundTripsModel() throws {
        let store = try makeStore()
        let model = makeMinimalModel()
        try store.save(model)
        let loaded = store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, model)
    }

    // MARK: ─── Cycle 3: second save replaces first ───────────────────────────

    func test_save_twice_secondValueWins() throws {
        let store = try makeStore()
        let modelA = makeMinimalModel()
        var modelB = makeMinimalModel()
        modelB.goal = GoalState(
            statement: "Lose weight",
            focusAreas: [.chest],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1000)
        )

        try store.save(modelA)
        try store.save(modelB)

        let loaded = store.load()
        XCTAssertEqual(loaded, modelB)
        XCTAssertNotEqual(loaded, modelA)
    }

    // MARK: ─── Cycle 4: clear → nil ─────────────────────────────────────────

    func test_clear_afterSave_returnsNilOnNextLoad() throws {
        let store = try makeStore()
        try store.save(makeMinimalModel())
        XCTAssertNotNil(store.load(), "Precondition: model exists before clear")

        try store.clear()

        XCTAssertNil(store.load())
    }

    func test_clear_onEmptyStore_doesNotThrow() {
        XCTAssertNoThrow(try makeStore().clear())
    }

    // MARK: ─── Cycle 5: persistence across simulated restart ─────────────────

    func test_persistenceAcrossSimulatedRestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = makeMinimalModel()

        // First "launch" — save and release the store
        do {
            let store = try TraineeModelLocalStore.makeOnDisk(at: url)
            try store.save(model)
            // store deallocated here; SQLite file remains on disk
        }

        // Second "launch" — open same file with a fresh container
        let store2 = try TraineeModelLocalStore.makeOnDisk(at: url)
        let loaded = store2.load()

        XCTAssertNotNil(loaded, "Expected persisted model to survive container recreation")
        XCTAssertEqual(loaded, model)
    }

    // MARK: ─── Cycle 6: cold-start from representative payload ───────────────

    func test_coldStart_representativePayload_roundTrips() throws {
        let store = try makeStore()
        let model = makeRepresentativeModel()

        try store.save(model)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.activeProgramId, model.activeProgramId)
        XCTAssertEqual(loaded.goal, model.goal)
        XCTAssertEqual(loaded.patterns.count, model.patterns.count)
        XCTAssertEqual(loaded.muscles.count, model.muscles.count)
        XCTAssertEqual(loaded.exercises.count, model.exercises.count)
        XCTAssertEqual(loaded.totalSessionCount, model.totalSessionCount)
        XCTAssertEqual(loaded, model)
    }
}
