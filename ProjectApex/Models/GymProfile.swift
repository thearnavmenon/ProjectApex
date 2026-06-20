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

// MARK: - EquipmentCategory

/// High-level groupings used to section the bulk equipment picker.
/// Mirrors how a real commercial gym is physically laid out.
nonisolated enum EquipmentCategory: String, CaseIterable, Identifiable, Sendable {
    case barbell          = "Barbell"
    case dumbbell         = "Dumbbell & Kettlebell"
    case cable            = "Cable"
    case machine          = "Machine"
    case bodyweightAndRig = "Bodyweight & Rig"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .barbell:          return "minus.rectangle.portrait.fill"
        case .dumbbell:         return "dumbbell.fill"
        case .cable:            return "cable.connector"
        case .machine:          return "gearshape.2.fill"
        case .bodyweightAndRig: return "figure.mixed.cardio"
        }
    }
}

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
    case reverseFly            // rear-delt / reverse pec deck
    case assistedDipPullUp     // assisted dip / pull-up machine (bodyweight-assisted)
    case hipThrustMachine
    case calfRaiseMachine
    case tBarRow               // T-bar / chest-supported row
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
        case .reverseFly:             return "reverse_fly"
        case .assistedDipPullUp:      return "assisted_dip_pull_up"
        case .hipThrustMachine:       return "hip_thrust_machine"
        case .calfRaiseMachine:       return "calf_raise_machine"
        case .tBarRow:                return "t_bar_row"
        // Preserve the custom string so it survives LLM serialisation. The
        // Codable persistence path (encode/init(from:)) uses the separate
        // rawValue key, not this — see init(typeKey:) for the round-trip.
        case .unknown(let raw):       return "unknown:\(raw)"
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
        case .reverseFly:             return "Rear-Delt / Reverse Pec Deck"
        case .assistedDipPullUp:      return "Assisted Dip / Pull-Up Machine"
        case .hipThrustMachine:       return "Hip Thrust Machine"
        case .calfRaiseMachine:       return "Calf Raise Machine"
        case .tBarRow:                return "T-Bar / Chest-Supported Row"
        case .unknown(let raw):       return raw
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Init from String
    // ---------------------------------------------------------------------------

    /// The high-level category this equipment type belongs to, used to
    /// group items in the bulk equipment picker.
    var category: EquipmentCategory {
        switch self {
        case .barbell, .ezCurlBar, .powerRack, .sqatRack, .smithMachine:
            return .barbell
        case .dumbbellSet, .kettlebellSet:
            return .dumbbell
        case .cableMachine, .cableMachineDual, .cableCrossover, .latPulldown, .seatedRow:
            return .cable
        case .legPress, .hackSquat, .chestPressMachine, .shoulderPressMachine,
             .legExtension, .legCurl, .pecDeck, .preacherCurl,
             .reverseFly, .hipThrustMachine, .calfRaiseMachine, .tBarRow:
            return .machine
        case .adjustableBench, .flatBench, .inclineBench, .pullUpBar,
             .dipStation, .resistanceBands, .assistedDipPullUp:
            return .bodyweightAndRig
        case .unknown:
            return .machine
        }
    }

    /// True when this equipment type is purely bodyweight — no external weight
    /// is ever prescribed by the AI for this equipment.
    var isNaturallyBodyweightOnly: Bool {
        switch self {
        // Assisted dip/pull-up is bodyweight-assisted: the stack removes load
        // rather than adding it, so the AI must never prescribe external weight.
        case .pullUpBar, .dipStation, .assistedDipPullUp: return true
        default: return false
        }
    }

    /// All known (non-unknown) equipment types, for use in pickers.
    static let knownCases: [EquipmentType] = [
        .dumbbellSet, .barbell, .ezCurlBar, .cableMachine, .cableMachineDual,
        .smithMachine, .legPress, .hackSquat, .adjustableBench, .flatBench,
        .inclineBench, .pullUpBar, .dipStation, .resistanceBands, .kettlebellSet,
        .powerRack, .sqatRack, .latPulldown, .seatedRow, .chestPressMachine,
        .shoulderPressMachine, .legExtension, .legCurl, .pecDeck, .preacherCurl,
        .cableCrossover, .reverseFly, .assistedDipPullUp, .hipThrustMachine,
        .calfRaiseMachine, .tBarRow
    ]

    init(typeKey: String, rawValue: String? = nil) {
        // Custom machines round-trip through the LLM-serialisation key as
        // "unknown:<raw>" (see `typeKey`). Strip the prefix back to the raw
        // string. Codable persistence uses the explicit `rawValue` key instead,
        // and the bare "unknown" case below still handles that decode path.
        if let raw = typeKey.dropPrefixIfPresent("unknown:") {
            self = .unknown(rawValue ?? raw)
            return
        }
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
        case "reverse_fly":            self = .reverseFly
        case "assisted_dip_pull_up":   self = .assistedDipPullUp
        case "hip_thrust_machine":     self = .hipThrustMachine
        case "calf_raise_machine":     self = .calfRaiseMachine
        case "t_bar_row":              self = .tBarRow
        case "unknown":                self = .unknown(rawValue ?? typeKey)
        default:                       self = .unknown(rawValue ?? typeKey)
        }
    }
}

private extension String {
    /// Returns the substring after `prefix` if `self` starts with it, else nil.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
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
        if case .unknown(let raw) = self {
            // Persistence keeps the stable wire format { "type": "unknown",
            // "rawValue": "..." } unchanged. The "unknown:<raw>" form is only
            // for the LLM-serialisation `typeKey`, not for stored JSON.
            try container.encode("unknown", forKey: .type)
            try container.encode(raw, forKey: .rawValue)
        } else {
            try container.encode(typeKey, forKey: .type)
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

    /// True when this is a free-standing bodyweight station (e.g. pull-up bar, dip station)
    /// where no external weight should ever be prescribed by the AI.
    /// Defaults to true for naturally bodyweight-only types; can be toggled in Settings.
    var bodyweightOnly: Bool

    init(
        id: UUID = UUID(),
        equipmentType: EquipmentType,
        count: Int = 1,
        notes: String? = nil,
        detectedByVision: Bool,
        bodyweightOnly: Bool? = nil
    ) {
        self.id = id
        self.equipmentType = equipmentType
        self.count = count
        self.notes = notes
        self.detectedByVision = detectedByVision
        // Default to the type's natural bodyweight-only status if not explicitly provided.
        self.bodyweightOnly = bodyweightOnly ?? equipmentType.isNaturallyBodyweightOnly
    }

    enum CodingKeys: String, CodingKey {
        case id
        case equipmentType    = "equipment_type"
        case count
        case notes
        case detectedByVision = "detected_by_vision"
        case bodyweightOnly   = "bodyweight_only"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        equipmentType   = try c.decode(EquipmentType.self, forKey: .equipmentType)
        count           = try c.decode(Int.self, forKey: .count)
        notes           = try c.decodeIfPresent(String.self, forKey: .notes)
        detectedByVision = try c.decode(Bool.self, forKey: .detectedByVision)
        // Backward-compat: old JSON without this key defaults to type's natural value.
        if let stored = try c.decodeIfPresent(Bool.self, forKey: .bodyweightOnly) {
            bodyweightOnly = stored
        } else {
            let et = equipmentType
            bodyweightOnly = et.isNaturallyBodyweightOnly
        }
    }
}

// MARK: - EquipmentRef

/// The LLM-facing wire shape for one piece of equipment: both the canonical
/// snake_case `key` (matching `EquipmentType.typeKey`) and the human-readable
/// `name` (matching `EquipmentType.displayName`).
///
/// Sending both lets the model reason about machines it has never seen as a
/// bare key — including a custom `.unknown("Belt squat machine")` machine,
/// whose `key` carries `"unknown:Belt squat machine"` and whose `name` is the
/// raw label. Used in every generation payload's `available_equipment` list.
nonisolated struct EquipmentRef: Codable, Equatable, Hashable, Sendable {
    let key: String
    let name: String

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    init(_ type: EquipmentType) {
        self.key = type.typeKey
        self.name = type.displayName
    }
}

extension GymProfile {
    /// The owned equipment as `{ key, name }` refs for LLM payloads.
    var equipmentRefs: [EquipmentRef] {
        equipment.map { EquipmentRef($0.equipmentType) }
    }

    /// The owned equipment `typeKey`s, used to pre-filter the exercise library
    /// to what this gym can actually train.
    var ownedEquipmentKeys: Set<String> {
        Set(equipment.map { $0.equipmentType.typeKey })
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
