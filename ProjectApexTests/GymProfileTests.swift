// GymProfileTests.swift
// ProjectApexTests
//
// Unit tests for the GymProfile model (presence-only architecture).
//
// Covers:
//   • EquipmentType.unknown encode/decode contract
//   • GymProfile full encode → JSON → decode round-trip
//   • GymProfile+Persistence: saveToUserDefaults / loadFromUserDefaults / clear
//   • hasEquipment(_:), item(for:), count(of:) helpers
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

    func test_equipmentItem_withNotes_roundTrips() throws {
        let item = EquipmentItem(
            equipmentType: .dumbbellSet,
            count: 1,
            notes: "Fixed dumbbells only, 5–50 kg",
            detectedByVision: true
        )
        let data = try JSONEncoder.gymProfile.encode(item)
        let decoded = try JSONDecoder.gymProfile.decode(EquipmentItem.self, from: data)
        XCTAssertEqual(decoded.notes, item.notes)
    }

    func test_equipmentItem_withoutNotes_roundTrips() throws {
        let item = EquipmentItem(
            equipmentType: .pullUpBar,
            count: 1,
            detectedByVision: true
        )
        let data = try JSONEncoder.gymProfile.encode(item)
        let decoded = try JSONDecoder.gymProfile.decode(EquipmentItem.self, from: data)
        XCTAssertNil(decoded.notes)
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

    // MARK: item(for:)

    func test_itemFor_returnsPresentItem() {
        let item = profile.item(for: .dumbbellSet)
        XCTAssertNotNil(item, "item(for:) must return non-nil for a present equipment type")
        XCTAssertEqual(item?.equipmentType, .dumbbellSet)
    }

    func test_itemFor_returnsNilForAbsentType() {
        XCTAssertNil(profile.item(for: .smithMachine))
    }

    // MARK: count(of:)

    func test_countOf_returnsCorrectCount() {
        // mockProfile has adjustableBench count = 4
        XCTAssertEqual(profile.count(of: .adjustableBench), 4,
            "count(of:) must return the item count from the profile")
    }

    func test_countOf_returnsZeroForAbsentType() {
        XCTAssertEqual(profile.count(of: .smithMachine), 0,
            "count(of:) must return 0 for equipment not in the profile")
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
}
