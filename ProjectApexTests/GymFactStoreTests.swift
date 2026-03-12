// GymFactStoreTests.swift
// ProjectApexTests
//
// Unit tests for GymFactStore.
//
// Covers:
//   • recordCorrection() creates a new fact
//   • recordCorrection() increments confirmationCount for a duplicate
//   • knownSubstitution() returns nil when no fact exists
//   • knownSubstitution() returns the available weight when fact exists
//   • contextStrings(for:) returns correctly formatted strings
//   • allContextStrings() returns strings for all equipment types
//   • clearAll() removes all facts
//   • Persistence: facts survive across a new instance (UserDefaults round-trip)

import XCTest
@testable import ProjectApex

final class GymFactStoreTests: XCTestCase {

    private var store: GymFactStore!

    override func setUp() async throws {
        try await super.setUp()
        store = GymFactStore()
        await store.clearAll()
    }

    override func tearDown() async throws {
        await store.clearAll()
        try await super.tearDown()
    }

    // MARK: ─── recordCorrection ───────────────────────────────────────────────

    func test_recordCorrection_createsNewFact() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        let facts = await store.facts
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].equipmentType, .dumbbellSet)
        XCTAssertEqual(facts[0].unavailableWeight, 16.0, accuracy: 0.001)
        XCTAssertEqual(facts[0].availableWeight,   15.0, accuracy: 0.001)
        XCTAssertEqual(facts[0].confirmationCount, 1)
    }

    func test_recordCorrection_duplicateFact_incrementsCount() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        let facts = await store.facts
        XCTAssertEqual(facts.count, 1,
            "Duplicate fact must not create a second entry")
        XCTAssertEqual(facts[0].confirmationCount, 2,
            "Duplicate fact must increment confirmation count to 2")
    }

    func test_recordCorrection_differentEquipment_createsSeparateFacts() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        await store.recordCorrection(
            equipmentType: .barbell,
            unavailableWeight: 55.0,
            availableWeight: 57.5
        )
        let facts = await store.facts
        XCTAssertEqual(facts.count, 2)
    }

    // MARK: ─── knownSubstitution ─────────────────────────────────────────────

    func test_knownSubstitution_nilWhenNoFact() async {
        let result = await store.knownSubstitution(
            for: .dumbbellSet,
            prescribedWeight: 16.0
        )
        XCTAssertNil(result, "No fact exists, so substitution must be nil")
    }

    func test_knownSubstitution_returnsAvailableWeightWhenFactExists() async {
        await store.recordCorrection(
            equipmentType: .cableMachine,
            unavailableWeight: 35.0,
            availableWeight: 30.0
        )
        let result = await store.knownSubstitution(
            for: .cableMachine,
            prescribedWeight: 35.0
        )
        XCTAssertEqual(result, 30.0, accuracy: 0.001)
    }

    func test_knownSubstitution_toleratesSmallFloatingPointDifference() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 22.5,
            availableWeight: 20.0
        )
        // Slightly imprecise prescribed weight (22.49999) still matches within 0.1 tolerance
        let result = await store.knownSubstitution(
            for: .dumbbellSet,
            prescribedWeight: 22.499
        )
        XCTAssertEqual(result, 20.0, accuracy: 0.001)
    }

    func test_knownSubstitution_differentEquipment_returnsNil() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        let result = await store.knownSubstitution(
            for: .barbell,
            prescribedWeight: 16.0
        )
        XCTAssertNil(result,
            "Fact for dumbbellSet must not match query for barbell")
    }

    // MARK: ─── contextStrings(for:) ─────────────────────────────────────────

    func test_contextStrings_returnsFormattedString() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        let strings = await store.contextStrings(for: .dumbbellSet)
        XCTAssertEqual(strings.count, 1)
        XCTAssertTrue(strings[0].contains("not available"),
            "Context string must contain 'not available'")
        XCTAssertTrue(strings[0].contains("16"),
            "Context string must mention the unavailable weight")
        XCTAssertTrue(strings[0].contains("15"),
            "Context string must mention the available weight")
    }

    func test_contextStrings_emptyWhenNoFactsForType() async {
        await store.recordCorrection(
            equipmentType: .barbell,
            unavailableWeight: 60.0,
            availableWeight: 57.5
        )
        let strings = await store.contextStrings(for: .dumbbellSet)
        XCTAssertTrue(strings.isEmpty,
            "contextStrings for dumbbellSet must be empty when only barbell facts exist")
    }

    // MARK: ─── allContextStrings ─────────────────────────────────────────────

    func test_allContextStrings_returnsAllFacts() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        await store.recordCorrection(
            equipmentType: .cableMachine,
            unavailableWeight: 35.0,
            availableWeight: 30.0
        )
        let strings = await store.allContextStrings()
        XCTAssertEqual(strings.count, 2)
    }

    func test_allContextStrings_emptyWhenNoFacts() async {
        let strings = await store.allContextStrings()
        XCTAssertTrue(strings.isEmpty)
    }

    // MARK: ─── clearAll ──────────────────────────────────────────────────────

    func test_clearAll_removesAllFacts() async {
        await store.recordCorrection(
            equipmentType: .dumbbellSet,
            unavailableWeight: 16.0,
            availableWeight: 15.0
        )
        await store.clearAll()
        let facts = await store.facts
        XCTAssertTrue(facts.isEmpty, "All facts must be removed after clearAll()")
    }

    // MARK: ─── Persistence ───────────────────────────────────────────────────

    func test_factsPersistedAcrossNewInstance() async {
        await store.recordCorrection(
            equipmentType: .barbell,
            unavailableWeight: 100.0,
            availableWeight: 97.5
        )
        // Create a new store instance — it should load the persisted fact
        let store2 = GymFactStore()
        let facts = await store2.facts
        XCTAssertEqual(facts.count, 1,
            "Facts must be persisted to UserDefaults and reloaded by a new instance")
        XCTAssertEqual(facts[0].equipmentType, .barbell)
        XCTAssertEqual(facts[0].unavailableWeight, 100.0, accuracy: 0.001)
        XCTAssertEqual(facts[0].availableWeight,   97.5,  accuracy: 0.001)
        // Cleanup
        await store2.clearAll()
    }
}
