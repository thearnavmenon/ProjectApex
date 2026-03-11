// GymProfileTests.swift
// ProjectApexTests
//
// P0-T04: Lock GymProfile Codable schema & unit test round-trip
//
// Covers:
//   • EquipmentType.unknown encode/decode contract
//   • GymProfile full encode → JSON → decode round-trip
//   • GymProfile+Persistence: saveToUserDefaults / loadFromUserDefaults / clear
//   • availableWeights(for:), hasEquipment(_:), maxWeightKg(for:)
//   • barbellLoadConstraint computed property
//   • mockProfile() factory returns a valid, Equatable profile

import XCTest
@testable import ProjectApex

// MARK: ─── Part 1: EquipmentType Codable ──────────────────────────────────────

final class EquipmentTypeCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: Known cases

    func test_knownCase_encodesToTypeKey() throws {
        let data = try encoder.encode(EquipmentType.dumbbellSet)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"dumbbell_set\""), "Expected type key 'dumbbell_set' in JSON: \(json)")
        XCTAssertFalse(json.contains("rawValue"), "Known case must not include rawValue")
    }

    func test_knownCase_roundTrips() throws {
        let original = EquipmentType.barbell
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(EquipmentType.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: Unknown case

    func test_unknownCase_encodesWithTypeAndRawValue() throws {
        let original = EquipmentType.unknown("hex_dumbbell_rack")
        let data = try encoder.encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Must contain "type":"unknown" and the rawValue
        XCTAssertTrue(json.contains("\"type\""), "Must contain 'type' key")
        XCTAssertTrue(json.contains("\"unknown\""), "Must contain 'unknown' as type value")
        XCTAssertTrue(json.contains("\"rawValue\""), "Must contain 'rawValue' key for unknown case")
        XCTAssertTrue(json.contains("hex_dumbbell_rack"), "Must embed the raw string")
    }

    func test_unknownCase_roundTrips() throws {
        let original = EquipmentType.unknown("cable_crossover_tower")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(EquipmentType.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_unknownCase_decodesFromExplicitJSON() throws {
        let json = """
        {"type":"unknown","rawValue":"preacher_curl_bench"}
        """
        let decoded = try decoder.decode(
            EquipmentType.self,
            from: XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(decoded, .unknown("preacher_curl_bench"))
    }

    func test_allKnownTypeKeys_roundTrip() throws {
        let cases: [EquipmentType] = [
            .dumbbellSet, .barbell, .ezCurlBar, .cableMachine,
            .smithMachine, .legPress, .adjustableBench, .flatBench, .pullUpBar
        ]
        for equipmentType in cases {
            let data = try encoder.encode(equipmentType)
            let decoded = try decoder.decode(EquipmentType.self, from: data)
            XCTAssertEqual(decoded, equipmentType, "Round-trip failed for \(equipmentType)")
        }
    }
}

// MARK: ─── Part 2: GymProfile Codable Round-Trip ─────────────────────────────

final class GymProfileCodableTests: XCTestCase {

    // MARK: - Full encode → decode round-trip

    func test_mockProfile_encodeDecodeRoundTrip() throws {
        let original = GymProfile.mockProfile()
        let data = try JSONEncoder.gymProfile.encode(original)
        let decoded = try JSONDecoder.gymProfile.decode(GymProfile.self, from: data)
        XCTAssertEqual(original, decoded,
            "Decoded profile must be equal to original after encode/decode round-trip")
    }

    func test_mockProfile_encodedJSON_containsExpectedTopLevelKeys() throws {
        let data = try JSONEncoder.gymProfile.encode(GymProfile.mockProfile())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let expectedKeys = ["id", "scan_session_id", "created_at", "last_updated_at", "equipment", "is_active"]
        for key in expectedKeys {
            XCTAssertNotNil(json[key], "Missing expected top-level key '\(key)'")
        }
    }

    func test_mockProfile_decodesFromReferenceJSON() throws {
        let jsonString = GymProfile.mockJSONResponse
        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder.gymProfile.decode(GymProfile.self, from: data)

        XCTAssertEqual(decoded.scanSessionId, "scan_mock_001")
        XCTAssertEqual(decoded.equipment.count, 5)
        XCTAssertTrue(decoded.isActive)
    }

    func test_profile_withUnknownEquipment_roundTrips() throws {
        let item = EquipmentItem(
            equipmentType: .unknown("atlas_stone"),
            count: 1,
            details: .bodyweightOnly,
            detectedByVision: false
        )
        // Use a fixed whole-second Date so ISO8601 round-trip doesn't lose sub-seconds.
        let fixedDate = Date(timeIntervalSince1970: 1_741_690_011)
        let profile = GymProfile(
            scanSessionId: "test-unknown",
            createdAt: fixedDate,
            lastUpdatedAt: fixedDate,
            equipment: [item]
        )
        let data = try JSONEncoder.gymProfile.encode(profile)
        let decoded = try JSONDecoder.gymProfile.decode(GymProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.equipment.first?.equipmentType, .unknown("atlas_stone"))
    }

    func test_equipmentDetails_incrementBased_roundTrips() throws {
        let item = EquipmentItem(
            equipmentType: .dumbbellSet,
            count: 1,
            details: .incrementBased(minKg: 2.5, maxKg: 45.0, incrementKg: 2.5),
            detectedByVision: true
        )
        let data = try JSONEncoder.gymProfile.encode(item)
        let decoded = try JSONDecoder.gymProfile.decode(EquipmentItem.self, from: data)
        XCTAssertEqual(decoded.details, item.details)
    }

    func test_equipmentDetails_plateBased_roundTrips() throws {
        let item = EquipmentItem(
            equipmentType: .barbell,
            count: 1,
            details: .plateBased(barWeightKg: 20.0, availablePlatesKg: [25.0, 20.0, 10.0, 5.0, 2.5]),
            detectedByVision: true
        )
        let data = try JSONEncoder.gymProfile.encode(item)
        let decoded = try JSONDecoder.gymProfile.decode(EquipmentItem.self, from: data)
        XCTAssertEqual(decoded.details, item.details)
    }

    func test_equipmentDetails_bodyweightOnly_roundTrips() throws {
        let item = EquipmentItem(
            equipmentType: .pullUpBar,
            count: 1,
            details: .bodyweightOnly,
            detectedByVision: true
        )
        let data = try JSONEncoder.gymProfile.encode(item)
        let decoded = try JSONDecoder.gymProfile.decode(EquipmentItem.self, from: data)
        XCTAssertEqual(decoded.details, item.details)
    }
}

// MARK: ─── Part 3: GymProfile+Persistence ────────────────────────────────────

final class GymProfilePersistenceTests: XCTestCase {

    // Use a dedicated UserDefaults suite so tests don't pollute the real suite.
    private let suiteName = "com.projectapex.tests.gymprofile"

    // Before each test: clear out any leftover data.
    override func setUp() async throws {
        try await super.setUp()
        // Clear the standard suite key used by the production code.
        UserDefaults.standard.removeObject(forKey: "com.projectapex.gymProfile")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "com.projectapex.gymProfile")
        try await super.tearDown()
    }

    @MainActor
    func test_saveAndLoad_roundTrip() throws {
        let original = GymProfile.mockProfile()
        original.saveToUserDefaults()
        let loaded = GymProfile.loadFromUserDefaults()
        let unwrapped = try XCTUnwrap(loaded, "loadFromUserDefaults must return non-nil after save")
        XCTAssertEqual(original, unwrapped,
            "Loaded profile must equal the saved profile")
    }

    @MainActor
    func test_loadBeforeSave_returnsNil() {
        let loaded = GymProfile.loadFromUserDefaults()
        XCTAssertNil(loaded, "loadFromUserDefaults must return nil when nothing has been saved")
    }

    @MainActor
    func test_clearUserDefaults_removesProfile() {
        GymProfile.mockProfile().saveToUserDefaults()
        XCTAssertNotNil(GymProfile.loadFromUserDefaults())
        GymProfile.clearUserDefaults()
        XCTAssertNil(GymProfile.loadFromUserDefaults(),
            "loadFromUserDefaults must return nil after clearUserDefaults()")
    }

    @MainActor
    func test_saveOverwrites_previousProfile() throws {
        // Save mock profile, then save a modified profile.
        GymProfile.mockProfile().saveToUserDefaults()

        var modified = GymProfile.mockProfile()
        modified.equipment = []
        modified.saveToUserDefaults()

        let loaded = try XCTUnwrap(GymProfile.loadFromUserDefaults())
        XCTAssertTrue(loaded.equipment.isEmpty,
            "Second save must overwrite the first; equipment must be empty")
    }
}

// MARK: ─── Part 4: GymProfile Equipment Helpers ───────────────────────────────

final class GymProfileEquipmentHelperTests: XCTestCase {

    private let profile = GymProfile.mockProfile()

    // MARK: hasEquipment

    func test_hasEquipment_trueForPresentType() {
        XCTAssertTrue(profile.hasEquipment(.dumbbellSet))
        XCTAssertTrue(profile.hasEquipment(.barbell))
        XCTAssertTrue(profile.hasEquipment(.adjustableBench))
        XCTAssertTrue(profile.hasEquipment(.cableMachine))
        XCTAssertTrue(profile.hasEquipment(.pullUpBar))
    }

    func test_hasEquipment_falseForAbsentType() {
        XCTAssertFalse(profile.hasEquipment(.smithMachine))
        XCTAssertFalse(profile.hasEquipment(.legPress))
        XCTAssertFalse(profile.hasEquipment(.flatBench))
        XCTAssertFalse(profile.hasEquipment(.ezCurlBar))
    }

    // MARK: availableWeights

    func test_availableWeights_dumbbells_startAtMin() {
        let weights = profile.availableWeights(for: .dumbbellSet)
        XCTAssertFalse(weights.isEmpty)
        XCTAssertEqual(weights.first!, 2.5, accuracy: 0.001)
    }

    func test_availableWeights_dumbbells_endAtMax() {
        let weights = profile.availableWeights(for: .dumbbellSet)
        XCTAssertEqual(weights.last!, 45.0, accuracy: 0.001)
    }

    func test_availableWeights_dumbbells_correctIncrement() {
        let weights = profile.availableWeights(for: .dumbbellSet)
        // All consecutive differences should be 2.5 kg
        for i in 1..<weights.count {
            XCTAssertEqual(weights[i] - weights[i-1], 2.5, accuracy: 0.001,
                "Increment between index \(i-1) and \(i) must be 2.5 kg")
        }
    }

    func test_availableWeights_cableMachine_correctRange() {
        let weights = profile.availableWeights(for: .cableMachine)
        XCTAssertEqual(weights.first!, 2.5, accuracy: 0.001)
        XCTAssertEqual(weights.last!, 90.0, accuracy: 0.001)
    }

    func test_availableWeights_barbell_containsBar() {
        // Bar alone (no plates) = 20 kg — must be in the list
        let weights = profile.availableWeights(for: .barbell)
        XCTAssertTrue(weights.contains(where: { abs($0 - 20.0) < 0.001 }),
            "Barbell weights must include bar weight (20 kg)")
    }

    func test_availableWeights_barbell_containsCommonLoad() {
        // 20 kg bar + 2×20 kg plates = 60 kg
        let weights = profile.availableWeights(for: .barbell)
        XCTAssertTrue(weights.contains(where: { abs($0 - 60.0) < 0.001 }),
            "Barbell weights must include 60 kg (bar + 2×20 kg)")
    }

    func test_availableWeights_bodyweightOnly_returnsZeroArray() {
        let weights = profile.availableWeights(for: .pullUpBar)
        XCTAssertEqual(weights, [0.0], "Bodyweight-only equipment must return [0.0]")
    }

    func test_availableWeights_absentEquipment_returnsEmpty() {
        let weights = profile.availableWeights(for: .smithMachine)
        XCTAssertTrue(weights.isEmpty, "Absent equipment must return empty array")
    }

    // MARK: maxWeightKg

    func test_maxWeightKg_dumbbells() {
        let max = profile.maxWeightKg(for: .dumbbellSet)
        XCTAssertEqual(try XCTUnwrap(max), 45.0, accuracy: 0.001)
    }

    func test_maxWeightKg_cableMachine() {
        let max = profile.maxWeightKg(for: .cableMachine)
        XCTAssertEqual(try XCTUnwrap(max), 90.0, accuracy: 0.001)
    }

    func test_maxWeightKg_barbell_equalsBarPlusTwoFullSets() {
        // bar=20, plates=[25,20,15,10,5,2.5,1.25]
        // max = 20 + 2 × (25+20+15+10+5+2.5+1.25) = 20 + 2 × 78.75 = 177.5
        let max = profile.maxWeightKg(for: .barbell)
        XCTAssertEqual(try XCTUnwrap(max), 177.5, accuracy: 0.001)
    }

    func test_maxWeightKg_bodyweightOnly_returnsZero() {
        let max = profile.maxWeightKg(for: .pullUpBar)
        XCTAssertEqual(try XCTUnwrap(max), 0.0, accuracy: 0.001)
    }

    func test_maxWeightKg_absentEquipment_returnsNil() {
        XCTAssertNil(profile.maxWeightKg(for: .smithMachine))
    }

    // MARK: barbellLoadConstraint

    func test_barbellLoadConstraint_presentWhenBarbellExists() {
        let constraint = profile.barbellLoadConstraint
        XCTAssertNotNil(constraint, "barbellLoadConstraint must be non-nil when profile contains a barbell")
    }

    func test_barbellLoadConstraint_correctBarWeight() throws {
        let constraint = try XCTUnwrap(profile.barbellLoadConstraint)
        XCTAssertEqual(constraint.barWeightKg, 20.0, accuracy: 0.001)
    }

    func test_barbellLoadConstraint_correctPlates() throws {
        let constraint = try XCTUnwrap(profile.barbellLoadConstraint)
        XCTAssertEqual(constraint.availablePlatesKg, [25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25])
    }

    func test_barbellLoadConstraint_maxLoadKg() throws {
        // bar=20, plates=[25,20,15,10,5,2.5,1.25] → sum/side=78.75 → max=177.5
        let constraint = try XCTUnwrap(profile.barbellLoadConstraint)
        XCTAssertEqual(constraint.maxLoadKg, 177.5, accuracy: 0.001)
    }

    func test_barbellLoadConstraint_nilWhenNoBarbellInProfile() {
        let noBarbellProfile = GymProfile(
            scanSessionId: "no-barbell",
            equipment: [
                EquipmentItem(
                    equipmentType: .dumbbellSet,
                    count: 1,
                    details: .incrementBased(minKg: 5.0, maxKg: 30.0, incrementKg: 2.5),
                    detectedByVision: false
                )
            ]
        )
        XCTAssertNil(noBarbellProfile.barbellLoadConstraint,
            "barbellLoadConstraint must be nil when profile has no barbell")
    }

    // MARK: mockProfile() factory

    func test_mockProfile_hasExpectedEquipmentCount() {
        XCTAssertEqual(profile.equipment.count, 5)
    }

    func test_mockProfile_isActive() {
        XCTAssertTrue(profile.isActive)
    }

    func test_mockProfile_hasStableId() {
        // Two calls must return the same UUID (fixed seed)
        XCTAssertEqual(GymProfile.mockProfile().id, GymProfile.mockProfile().id)
    }

    func test_mockProfile_isValidForEquipmentRounder() {
        // Smoke test: constructing a rounder from mockProfile must not crash
        let rounder = EquipmentRounder(gymProfile: profile)
        let result = rounder.round(aiPrescribedWeightKg: 30.0, for: .dumbbellSet)
        XCTAssertGreaterThan(result.roundedWeightKg, 0.0)
    }
}
