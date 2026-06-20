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

    // MARK: Codable wire-format stability for unknown (Slice 4)

    /// The custom-string `typeKey` change MUST NOT alter the persisted JSON
    /// `type` field — it stays the bare "unknown" with the raw in `rawValue`.
    /// This guards already-stored GymProfiles against the typeKey change.
    func test_unknownCase_persistedTypeField_staysBareUnknown() throws {
        let data = try encoder.encode(EquipmentType.unknown("Belt squat machine"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "unknown",
            "Persisted 'type' field must remain the bare 'unknown' (not the unknown:<raw> LLM key)")
        XCTAssertEqual(json["rawValue"] as? String, "Belt squat machine",
            "Raw custom name must persist in the separate 'rawValue' key")
    }

    /// Old-format JSON ({"type":"unknown","rawValue":"..."}) must still decode.
    func test_unknownCase_legacyWireFormat_stillDecodes() throws {
        let json = """
        {"type":"unknown","rawValue":"atlas_stone"}
        """
        let decoded = try decoder.decode(
            EquipmentType.self,
            from: XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(decoded, .unknown("atlas_stone"))
    }
}

// MARK: ─── Part 1b: EquipmentType.typeKey LLM-serialisation round-trip (Slice 4)

final class EquipmentTypeTypeKeyRoundTripTests: XCTestCase {

    /// Every known case must round-trip through its LLM `typeKey`:
    /// EquipmentType(typeKey: x.typeKey) == x.
    func test_allKnownCases_typeKeyRoundTrips() {
        for equipmentType in EquipmentType.knownCases {
            let key = equipmentType.typeKey
            let rebuilt = EquipmentType(typeKey: key)
            XCTAssertEqual(rebuilt, equipmentType,
                "typeKey round-trip failed for \(equipmentType): key='\(key)' rebuilt=\(rebuilt)")
        }
    }

    /// A custom machine's raw string must survive the typeKey round-trip
    /// (the whole point of Fix 2 — it previously collapsed to "unknown").
    func test_unknownCase_typeKeyPreservesRawString() {
        let custom = EquipmentType.unknown("Belt squat machine")
        XCTAssertEqual(custom.typeKey, "unknown:Belt squat machine",
            "typeKey must embed the raw custom name, not discard it")
        XCTAssertEqual(EquipmentType(typeKey: custom.typeKey), custom,
            "Custom machine must round-trip via typeKey")
    }

    /// Raw strings that themselves contain a colon must round-trip intact
    /// (only the first 'unknown:' prefix is stripped).
    func test_unknownCase_typeKeyWithColonInRaw_roundTrips() {
        let custom = EquipmentType.unknown("Hammer Strength: ISO row")
        XCTAssertEqual(EquipmentType(typeKey: custom.typeKey), custom)
    }

    /// The new first-class machine cases must each map to a category and be in
    /// knownCases (i.e. they appear in the picker), and not be `.unknown`.
    func test_newMachineCases_areKnownAndCategorised() {
        let newCases: [EquipmentType] = [
            .reverseFly, .assistedDipPullUp, .hipThrustMachine,
            .calfRaiseMachine, .tBarRow
        ]
        for equipmentType in newCases {
            XCTAssertTrue(EquipmentType.knownCases.contains(equipmentType),
                "\(equipmentType) must be in knownCases so it shows in the picker")
            if case .unknown = equipmentType {
                XCTFail("\(equipmentType) must not resolve to .unknown")
            }
            // category is non-optional; touching it asserts it is wired.
            _ = equipmentType.category
        }
    }

    /// Assisted dip/pull-up is bodyweight-assisted — no external weight prescribed.
    func test_assistedDipPullUp_isBodyweightOnly() {
        XCTAssertTrue(EquipmentType.assistedDipPullUp.isNaturallyBodyweightOnly)
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

// MARK: ─── Part 5: EquipmentRef — LLM payload {key,name} shape (#527 S5) ──────

final class EquipmentRefTests: XCTestCase {

    /// A known equipment type encodes BOTH the canonical key and the display name.
    func test_knownType_carriesKeyAndName() throws {
        let ref = EquipmentRef(.chestPressMachine)
        XCTAssertEqual(ref.key, "chest_press_machine")
        XCTAssertEqual(ref.name, "Chest Press Machine")

        let data = try JSONEncoder().encode(ref)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["key"] as? String, "chest_press_machine")
        XCTAssertEqual(json["name"] as? String, "Chest Press Machine")
    }

    /// A custom .unknown machine's raw label must survive into the name, and the
    /// key keeps the "unknown:" round-trip prefix (so it never collides with a
    /// real library row).
    func test_customUnknownMachine_nameSurvives() throws {
        let ref = EquipmentRef(.unknown("Belt squat machine"))
        XCTAssertEqual(ref.key, "unknown:Belt squat machine")
        XCTAssertEqual(ref.name, "Belt squat machine")

        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(EquipmentRef.self, from: data)
        XCTAssertEqual(decoded, ref)
        XCTAssertEqual(decoded.name, "Belt squat machine",
            "Custom machine name must survive the LLM payload encode/decode")
    }

    /// GymProfile.equipmentRefs produces one { key, name } ref per item.
    func test_gymProfile_equipmentRefs_oneRefPerItem() {
        let profile = GymProfile.mockProfile()
        let refs = profile.equipmentRefs
        XCTAssertEqual(refs.count, profile.equipment.count)
        // mockProfile has a barbell → its ref carries the display name.
        let barbell = refs.first { $0.key == "barbell" }
        XCTAssertEqual(barbell?.name, "Barbell")
    }

    /// ownedEquipmentKeys is the set of typeKeys used to pre-filter the library.
    func test_gymProfile_ownedEquipmentKeys() {
        let profile = GymProfile.mockProfile()
        let keys = profile.ownedEquipmentKeys
        XCTAssertTrue(keys.contains("barbell"))
        XCTAssertEqual(keys.count, Set(profile.equipment.map { $0.equipmentType.typeKey }).count)
    }
}
