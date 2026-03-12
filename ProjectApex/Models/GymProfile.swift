// Models/GymProfile.swift
// ProjectApex
//
// The canonical GymProfile schema. This is the single source of truth for all
// equipment available to the user. The scanner identifies WHAT equipment exists
// (presence only). Weight ranges are NOT stored here — they are provided by
// DefaultWeightIncrements as standard commercial gym defaults, and refined at
// runtime through the GymFactStore weight correction loop.
//
// ISOLATION NOTE — SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor:
// All types here are `nonisolated` to opt their synthesised (or custom) Codable
// conformances out of @MainActor, allowing decoding from any actor context.
//
// Dependency: import Foundation only.

import Foundation

// MARK: - EquipmentType

/// The category of a piece of gym equipment.
///
/// `unknown(String)` handles Vision API detections that don't map to a known
/// category — they are preserved faithfully rather than silently dropped.
nonisolated enum EquipmentType: Hashable, Equatable, Sendable {
    case dumbbellSet
    case barbell
    case ezCurlBar
    case cableMachine          // generic cable machine (single or dual)
    case cableMachineDual
    case smithMachine
    case legPress
    case hackSquat
    case adjustableBench
    case flatBench
    case inclineBench
    case pullUpBar
    case dipStation
    case resistanceBands
    case kettlebellSet
    case powerRack
    case sqatRack
    case latPulldown
    case seatedRow
    case chestPressMachine
    case shoulderPressMachine
    case legExtension
    case legCurl
    case pecDeck
    case preacherCurl
    case cableCrossover
    case unknown(String)

    // ---------------------------------------------------------------------------
    // MARK: String Keys (used in Codable and display)
    // ---------------------------------------------------------------------------

    /// The canonical string key written to JSON for known cases.
    var typeKey: String {
        switch self {
        case .dumbbellSet:            return "dumbbell_set"
        case .barbell:                return "barbell"
        case .ezCurlBar:              return "ez_curl_bar"
        case .cableMachine:           return "cable_machine_single"
        case .cableMachineDual:       return "cable_machine_dual"
        case .smithMachine:           return "smith_machine"
        case .legPress:               return "leg_press"
        case .hackSquat:              return "hack_squat"
        case .adjustableBench:        return "adjustable_bench"
        case .flatBench:              return "flat_bench"
        case .inclineBench:           return "incline_bench"
        case .pullUpBar:              return "pull_up_bar"
        case .dipStation:             return "dip_station"
        case .resistanceBands:        return "resistance_bands"
        case .kettlebellSet:          return "kettlebell_set"
        case .powerRack:              return "power_rack"
        case .sqatRack:               return "squat_rack"
        case .latPulldown:            return "lat_pulldown"
        case .seatedRow:              return "seated_row"
        case .chestPressMachine:      return "chest_press_machine"
        case .shoulderPressMachine:   return "shoulder_press_machine"
        case .legExtension:           return "leg_extension"
        case .legCurl:                return "leg_curl"
        case .pecDeck:                return "pec_deck"
        case .preacherCurl:           return "preacher_curl"
        case .cableCrossover:         return "cable_crossover"
        case .unknown:                return "unknown"
        }
    }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .dumbbellSet:            return "Dumbbell Set"
        case .barbell:                return "Barbell"
        case .ezCurlBar:              return "EZ Curl Bar"
        case .cableMachine:           return "Cable Machine"
        case .cableMachineDual:       return "Cable Machine (Dual)"
        case .smithMachine:           return "Smith Machine"
        case .legPress:               return "Leg Press"
        case .hackSquat:              return "Hack Squat"
        case .adjustableBench:        return "Adjustable Bench"
        case .flatBench:              return "Flat Bench"
        case .inclineBench:           return "Incline Bench"
        case .pullUpBar:              return "Pull-Up Bar"
        case .dipStation:             return "Dip Station"
        case .resistanceBands:        return "Resistance Bands"
        case .kettlebellSet:          return "Kettlebell Set"
        case .powerRack:              return "Power Rack"
        case .sqatRack:               return "Squat Rack"
        case .latPulldown:            return "Lat Pulldown"
        case .seatedRow:              return "Seated Row"
        case .chestPressMachine:      return "Chest Press Machine"
        case .shoulderPressMachine:   return "Shoulder Press Machine"
        case .legExtension:           return "Leg Extension"
        case .legCurl:                return "Leg Curl"
        case .pecDeck:                return "Pec Deck"
        case .preacherCurl:           return "Preacher Curl"
        case .cableCrossover:         return "Cable Crossover"
        case .unknown(let raw):       return raw
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Init from String
    // ---------------------------------------------------------------------------

    /// All known (non-unknown) equipment types, for use in pickers.
    static let knownCases: [EquipmentType] = [
        .dumbbellSet, .barbell, .ezCurlBar, .cableMachine, .cableMachineDual,
        .smithMachine, .legPress, .hackSquat, .adjustableBench, .flatBench,
        .inclineBench, .pullUpBar, .dipStation, .resistanceBands, .kettlebellSet,
        .powerRack, .sqatRack, .latPulldown, .seatedRow, .chestPressMachine,
        .shoulderPressMachine, .legExtension, .legCurl, .pecDeck, .preacherCurl,
        .cableCrossover
    ]

    init(typeKey: String, rawValue: String? = nil) {
        switch typeKey {
        case "dumbbell_set":           self = .dumbbellSet
        case "barbell":                self = .barbell
        case "ez_curl_bar":            self = .ezCurlBar
        case "cable_machine_single",
             "cable_machine":          self = .cableMachine
        case "cable_machine_dual":     self = .cableMachineDual
        case "smith_machine":          self = .smithMachine
        case "leg_press":              self = .legPress
        case "hack_squat":             self = .hackSquat
        case "adjustable_bench":       self = .adjustableBench
        case "flat_bench":             self = .flatBench
        case "incline_bench":          self = .inclineBench
        case "pull_up_bar":            self = .pullUpBar
        case "dip_station":            self = .dipStation
        case "resistance_bands":       self = .resistanceBands
        case "kettlebell_set":         self = .kettlebellSet
        case "power_rack":             self = .powerRack
        case "squat_rack":             self = .sqatRack
        case "lat_pulldown":           self = .latPulldown
        case "seated_row":             self = .seatedRow
        case "chest_press_machine":    self = .chestPressMachine
        case "shoulder_press_machine": self = .shoulderPressMachine
        case "leg_extension":          self = .legExtension
        case "leg_curl":               self = .legCurl
        case "pec_deck":               self = .pecDeck
        case "preacher_curl":          self = .preacherCurl
        case "cable_crossover":        self = .cableCrossover
        case "unknown":                self = .unknown(rawValue ?? typeKey)
        default:                       self = .unknown(typeKey)
        }
    }
}

// MARK: EquipmentType: Codable

extension EquipmentType: Codable {
    // JSON contract for known cases: { "type": "dumbbell_set" }
    // JSON contract for unknown:     { "type": "unknown", "rawValue": "some string" }

    private enum CodingKeys: String, CodingKey {
        case type
        case rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeKey, forKey: .type)
        if case .unknown(let raw) = self {
            try container.encode(raw, forKey: .rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeKey = try container.decode(String.self, forKey: .type)
        let rawValue = try container.decodeIfPresent(String.self, forKey: .rawValue)
        self.init(typeKey: typeKey, rawValue: rawValue)
    }
}

// MARK: - EquipmentItem

/// A single piece of equipment detected in the gym scan.
/// The scanner records presence only — no weight ranges.
/// Weight defaults come from DefaultWeightIncrements; real availability
/// is refined at runtime via GymFactStore.
nonisolated struct EquipmentItem: Codable, Identifiable, Equatable, Hashable, Sendable {

    /// Stable identity for SwiftUI lists and Supabase upserts.
    var id: UUID

    /// The equipment category.
    var equipmentType: EquipmentType

    /// Number of units present in the gym (e.g., 4 squat racks).
    var count: Int

    /// Optional freeform notes (e.g., "left side broken").
    var notes: String?

    /// Whether this item was detected by the Vision API (vs. manually added).
    var detectedByVision: Bool

    init(
        id: UUID = UUID(),
        equipmentType: EquipmentType,
        count: Int = 1,
        notes: String? = nil,
        detectedByVision: Bool
    ) {
        self.id = id
        self.equipmentType = equipmentType
        self.count = count
        self.notes = notes
        self.detectedByVision = detectedByVision
    }

    enum CodingKeys: String, CodingKey {
        case id
        case equipmentType    = "equipment_type"
        case count
        case notes
        case detectedByVision = "detected_by_vision"
    }
}

// MARK: - GymProfile

/// The master equipment profile for the user's gym.
///
/// Built during onboarding, cached locally, and sent as context in every
/// AI inference payload. Records equipment presence only — weight ranges
/// are provided by DefaultWeightIncrements.
nonisolated struct GymProfile: Codable, Equatable, Hashable, Sendable {

    var id: UUID
    var scanSessionId: String
    var createdAt: Date
    var lastUpdatedAt: Date
    var equipment: [EquipmentItem]
    var isActive: Bool

    init(
        id: UUID = UUID(),
        scanSessionId: String,
        createdAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        equipment: [EquipmentItem],
        isActive: Bool = true
    ) {
        self.id = id
        self.scanSessionId = scanSessionId
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.equipment = equipment
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case scanSessionId   = "scan_session_id"
        case createdAt       = "created_at"
        case lastUpdatedAt   = "last_updated_at"
        case equipment
        case isActive        = "is_active"
    }
}

// MARK: - GymProfile: Equipment Helpers

extension GymProfile {

    /// Returns true if the profile contains at least one item of the given type.
    func hasEquipment(_ type: EquipmentType) -> Bool {
        equipment.contains { $0.equipmentType == type }
    }

    /// Returns the count of items of the given type (0 if absent).
    func count(of type: EquipmentType) -> Int {
        equipment.first { $0.equipmentType == type }?.count ?? 0
    }

    /// Returns the first equipment item matching the given type, or nil.
    nonisolated func item(for type: EquipmentType) -> EquipmentItem? {
        equipment.first { $0.equipmentType == type }
    }
}

// MARK: - GymProfile: Mock Data

extension GymProfile {

    /// A realistic sample GymProfile for SwiftUI previews and unit tests.
    static func mockProfile() -> GymProfile {
        GymProfile(
            id: UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890") ?? UUID(),
            scanSessionId: "scan_mock_001",
            createdAt: ISO8601DateFormatter().date(from: "2026-03-11T09:00:00Z") ?? Date(),
            lastUpdatedAt: ISO8601DateFormatter().date(from: "2026-03-11T09:05:00Z") ?? Date(),
            equipment: [
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000001") ?? UUID(),
                    equipmentType: .dumbbellSet,
                    count: 1,
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000002") ?? UUID(),
                    equipmentType: .barbell,
                    count: 3,
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000003") ?? UUID(),
                    equipmentType: .adjustableBench,
                    count: 4,
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000004") ?? UUID(),
                    equipmentType: .cableMachine,
                    count: 2,
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000005") ?? UUID(),
                    equipmentType: .pullUpBar,
                    count: 2,
                    detectedByVision: true
                )
            ],
            isActive: true
        )
    }

    // ---------------------------------------------------------------------------
    // MARK: Canonical JSON string matching mockProfile()
    // ---------------------------------------------------------------------------

    static let mockJSONResponse: String = """
    {
      "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "scan_session_id": "scan_mock_001",
      "created_at": "2026-03-11T09:00:00Z",
      "last_updated_at": "2026-03-11T09:05:00Z",
      "is_active": true,
      "equipment": [
        {
          "id": "11111111-0000-0000-0000-000000000001",
          "equipment_type": { "type": "dumbbell_set" },
          "count": 1,
          "detected_by_vision": true
        },
        {
          "id": "11111111-0000-0000-0000-000000000002",
          "equipment_type": { "type": "barbell" },
          "count": 3,
          "detected_by_vision": true
        },
        {
          "id": "11111111-0000-0000-0000-000000000003",
          "equipment_type": { "type": "adjustable_bench" },
          "count": 4,
          "detected_by_vision": true
        },
        {
          "id": "11111111-0000-0000-0000-000000000004",
          "equipment_type": { "type": "cable_machine_single" },
          "count": 2,
          "detected_by_vision": true
        },
        {
          "id": "11111111-0000-0000-0000-000000000005",
          "equipment_type": { "type": "pull_up_bar" },
          "count": 2,
          "detected_by_vision": true
        }
      ]
    }
    """
}

// MARK: - JSONEncoder / JSONDecoder factories

/// Shared encoder configured for the GymProfile schema contract.
/// ISO8601 dates, pretty-printed for readability in logs and Supabase.
extension JSONEncoder {
    static var gymProfile: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Shared decoder configured for the GymProfile schema contract.
extension JSONDecoder {
    static var gymProfile: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
