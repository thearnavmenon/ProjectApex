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
// Lifecycle design: the store is created in setUp() async throws and destroyed
// in tearDown() async throws. Both run inside a Swift Concurrency Task, which
// is required because ModelContainer uses task-local executor storage
// internally — its deallocation must happen while an active Task exists.
// Creating / destroying the store inside synchronous test methods (where no
// Task is active) triggers swift_task_deinitOnExecutorImpl → crash.
//
// The persistence-across-restart test creates its own on-disk stores; it is
// marked async for the same reason (local store variables are released at the
// end of an async function, still within a Task).
//
// Behaviors covered:
//   • Empty store returns nil on load()
//   • save → load round-trips the model faithfully
//   • Second save replaces first (upsert semantics)
//   • clear() empties the store
//   • clear() on empty store does not throw
//   • Persistence survives simulated restart (new container, same SQLite file)
//   • Cold-start hydration from a representative Edge Function payload

import XCTest
import SwiftData
@testable import ProjectApex

@MainActor
final class TraineeModelLocalStoreTests: XCTestCase {

    // MARK: ─── Lifecycle ─────────────────────────────────────────────────────

    private var store: TraineeModelLocalStore!

    override func setUp() async throws {
        store = try TraineeModelLocalStore.makeInMemory()
    }

    override func tearDown() async throws {
        store = nil
    }

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

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
        XCTAssertNil(store.load())
    }

    // MARK: ─── Cycle 2: save → load round-trip ────────────────────────────────

    func test_saveAndLoad_roundTripsModel() throws {
        let model = makeMinimalModel()
        try store.save(model)
        let loaded = store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, model)
    }

    // MARK: ─── Cycle 3: second save replaces first ───────────────────────────

    func test_save_twice_secondValueWins() throws {
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
        try store.save(makeMinimalModel())
        XCTAssertNotNil(store.load(), "Precondition: model exists before clear")

        try store.clear()

        XCTAssertNil(store.load())
    }

    func test_clear_onEmptyStore_doesNotThrow() {
        XCTAssertNoThrow(try store.clear())
    }

    // MARK: ─── Cycle 5: persistence across simulated restart ─────────────────

    func test_persistenceAcrossSimulatedRestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let model = makeMinimalModel()

        // First "launch" — save and release the store (dealloc in async Task)
        do {
            let store1 = try TraineeModelLocalStore.makeOnDisk(at: url)
            try store1.save(model)
            // store1 released here, still inside async Task — safe
        }

        // Second "launch" — open same file with a fresh container
        let store2 = try TraineeModelLocalStore.makeOnDisk(at: url)
        let loaded = store2.load()
        // store2 released at end of async function — safe

        XCTAssertNotNil(loaded, "Expected persisted model to survive container recreation")
        XCTAssertEqual(loaded, model)
    }

    // MARK: ─── Cycle 6: cold-start from representative payload ───────────────

    func test_coldStart_representativePayload_roundTrips() throws {
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
