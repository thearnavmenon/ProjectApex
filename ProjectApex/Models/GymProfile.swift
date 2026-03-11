// Models/GymProfile.swift
// ProjectApex
//
// The canonical GymProfile schema. This is the single source of truth for all
// equipment available to the user. Every AI-generated exercise prescription must
// be achievable with equipment described here.
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
    case cableMachine
    case smithMachine
    case legPress
    case adjustableBench
    case flatBench
    case pullUpBar
    case unknown(String)

    // ---------------------------------------------------------------------------
    // MARK: String Keys (used in Codable and display)
    // ---------------------------------------------------------------------------

    /// The canonical string key written to JSON for known cases.
    var typeKey: String {
        switch self {
        case .dumbbellSet:      return "dumbbell_set"
        case .barbell:          return "barbell"
        case .ezCurlBar:        return "ez_curl_bar"
        case .cableMachine:     return "cable_machine"
        case .smithMachine:     return "smith_machine"
        case .legPress:         return "leg_press"
        case .adjustableBench:  return "adjustable_bench"
        case .flatBench:        return "flat_bench"
        case .pullUpBar:        return "pull_up_bar"
        case .unknown:          return "unknown"
        }
    }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .dumbbellSet:      return "Dumbbell Set"
        case .barbell:          return "Barbell"
        case .ezCurlBar:        return "EZ Curl Bar"
        case .cableMachine:     return "Cable Machine"
        case .smithMachine:     return "Smith Machine"
        case .legPress:         return "Leg Press"
        case .adjustableBench:  return "Adjustable Bench"
        case .flatBench:        return "Flat Bench"
        case .pullUpBar:        return "Pull-Up Bar"
        case .unknown(let raw): return raw
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Init from String
    // ---------------------------------------------------------------------------

    init(typeKey: String, rawValue: String? = nil) {
        switch typeKey {
        case "dumbbell_set":    self = .dumbbellSet
        case "barbell":         self = .barbell
        case "ez_curl_bar":     self = .ezCurlBar
        case "cable_machine":   self = .cableMachine
        case "smith_machine":   self = .smithMachine
        case "leg_press":       self = .legPress
        case "adjustable_bench": self = .adjustableBench
        case "flat_bench":      self = .flatBench
        case "pull_up_bar":     self = .pullUpBar
        case "unknown":         self = .unknown(rawValue ?? typeKey)
        default:                self = .unknown(typeKey)
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

// MARK: - EquipmentDetails

/// The physical parameters of a piece of equipment.
///
/// Different equipment categories require fundamentally different arithmetic
/// for computing available weights, so this is an enum with associated values
/// rather than a flat struct with many optionals.
nonisolated enum EquipmentDetails: Equatable, Hashable, Sendable {

    /// Pin-loaded or dumbbell-style equipment: discrete weights from min to max
    /// at a fixed increment. E.g., dumbbells 2.5–45 kg in 2.5 kg steps.
    case incrementBased(minKg: Double, maxKg: Double, incrementKg: Double)

    /// Barbell or plate-loaded equipment. `availablePlatesKg` is the full set of
    /// plates available (listed as single-plate weights; they always come in pairs).
    /// E.g., plates: [25, 20, 15, 10, 5, 2.5, 1.25] on a 20 kg bar.
    case plateBased(barWeightKg: Double, availablePlatesKg: [Double])

    /// Bodyweight-only equipment (pull-up bars, benches used for bodyweight moves).
    case bodyweightOnly
}

// MARK: EquipmentDetails: Codable

extension EquipmentDetails: Codable {
    // Discriminator key: "kind"
    // incrementBased: { "kind": "increment_based", "min_kg": .., "max_kg": .., "increment_kg": .. }
    // plateBased:     { "kind": "plate_based", "bar_weight_kg": .., "available_plates_kg": [..] }
    // bodyweightOnly: { "kind": "bodyweight_only" }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minKg          = "min_kg"
        case maxKg          = "max_kg"
        case incrementKg    = "increment_kg"
        case barWeightKg    = "bar_weight_kg"
        case availablePlatesKg = "available_plates_kg"
    }

    private enum Kind: String {
        case incrementBased  = "increment_based"
        case plateBased      = "plate_based"
        case bodyweightOnly  = "bodyweight_only"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .incrementBased(let min, let max, let increment):
            try container.encode(Kind.incrementBased.rawValue, forKey: .kind)
            try container.encode(min, forKey: .minKg)
            try container.encode(max, forKey: .maxKg)
            try container.encode(increment, forKey: .incrementKg)
        case .plateBased(let barWeight, let plates):
            try container.encode(Kind.plateBased.rawValue, forKey: .kind)
            try container.encode(barWeight, forKey: .barWeightKg)
            try container.encode(plates, forKey: .availablePlatesKg)
        case .bodyweightOnly:
            try container.encode(Kind.bodyweightOnly.rawValue, forKey: .kind)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: kindRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown EquipmentDetails kind: '\(kindRaw)'"
            )
        }
        switch kind {
        case .incrementBased:
            let min = try container.decode(Double.self, forKey: .minKg)
            let max = try container.decode(Double.self, forKey: .maxKg)
            let inc = try container.decode(Double.self, forKey: .incrementKg)
            self = .incrementBased(minKg: min, maxKg: max, incrementKg: inc)
        case .plateBased:
            let bar    = try container.decode(Double.self, forKey: .barWeightKg)
            let plates = try container.decode([Double].self, forKey: .availablePlatesKg)
            self = .plateBased(barWeightKg: bar, availablePlatesKg: plates)
        case .bodyweightOnly:
            self = .bodyweightOnly
        }
    }
}

// MARK: - BarbellConstraint

/// A value-type snapshot of the barbell configuration extracted from a GymProfile.
/// Passed to LLM prompts and used in equipment validation to communicate what
/// barbell loads are physically achievable.
nonisolated struct BarbellConstraint: Codable, Equatable, Hashable, Sendable {
    /// Weight of the barbell itself (bar only, no plates), in kg.
    let barWeightKg: Double
    /// Available plate denominations (single-plate weights in kg).
    /// Each denomination can be loaded on both sides.
    let availablePlatesKg: [Double]

    /// Maximum achievable total load: bar + both sides fully loaded.
    var maxLoadKg: Double {
        barWeightKg + 2.0 * availablePlatesKg.reduce(0, +)
    }
}

// MARK: - EquipmentItem

/// A single piece of equipment detected in the gym scan.
nonisolated struct EquipmentItem: Codable, Identifiable, Equatable, Hashable, Sendable {

    /// Stable identity for SwiftUI lists and Supabase upserts.
    var id: UUID

    /// The equipment category.
    var equipmentType: EquipmentType

    /// Number of units present in the gym (e.g., 4 squat racks).
    var count: Int

    /// Physical parameters used for weight arithmetic.
    var details: EquipmentDetails

    /// Whether this item was added by the Vision API (vs. manually by the user).
    var detectedByVision: Bool

    init(
        id: UUID = UUID(),
        equipmentType: EquipmentType,
        count: Int = 1,
        details: EquipmentDetails,
        detectedByVision: Bool
    ) {
        self.id = id
        self.equipmentType = equipmentType
        self.count = count
        self.details = details
        self.detectedByVision = detectedByVision
    }

    enum CodingKeys: String, CodingKey {
        case id
        case equipmentType   = "equipment_type"
        case count
        case details
        case detectedByVision = "detected_by_vision"
    }
}

// MARK: - GymProfile

/// The master equipment profile for the user's gym.
///
/// Built during onboarding, cached locally, and sent as context in every
/// AI inference payload (PRD Section 5.1). All exercises in the generated
/// 12-week program must be achievable with this equipment.
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

    // ---------------------------------------------------------------------------
    // MARK: Barbell Constraint
    // ---------------------------------------------------------------------------

    /// Returns the barbell load constraint derived from this profile's barbell item,
    /// or nil if no barbell is present.
    ///
    /// Used by `ProgramGenerationService` to pass equipment bounds to the LLM and
    /// by tests to verify the profile's barbell configuration in one call.
    var barbellLoadConstraint: BarbellConstraint? {
        guard let item = item(for: .barbell),
              case .plateBased(let barWeight, let plates) = item.details else {
            return nil
        }
        return BarbellConstraint(barWeightKg: barWeight, availablePlatesKg: plates)
    }

    // ---------------------------------------------------------------------------
    // MARK: Lookup
    // ---------------------------------------------------------------------------

    /// Returns true if the profile contains at least one item of the given type.
    func hasEquipment(_ type: EquipmentType) -> Bool {
        equipment.contains { $0.equipmentType == type }
    }

    /// Returns the first equipment item matching the given type, or nil.
    nonisolated func item(for type: EquipmentType) -> EquipmentItem? {
        equipment.first { $0.equipmentType == type }
    }

    // ---------------------------------------------------------------------------
    // MARK: Weight Arithmetic
    // ---------------------------------------------------------------------------

    /// Returns a sorted array of all physically achievable weights for the
    /// given equipment type. Used by `EquipmentRounder` to snap AI prescriptions
    /// to the nearest real weight.
    ///
    /// - `incrementBased`: steps from `minKg` to `maxKg` at `incrementKg`.
    /// - `plateBased`: all achievable totals using pairs of the available plates
    ///   added to the bar. Plates may be combined in any quantity.
    /// - `bodyweightOnly`: returns `[0.0]` (bodyweight = 0 additional kg).
    /// - No match: returns `[]`.
    func availableWeights(for equipmentType: EquipmentType) -> [Double] {
        guard let item = item(for: equipmentType) else { return [] }

        switch item.details {
        case .incrementBased(let min, let max, let increment):
            guard increment > 0 else { return [min, max] }
            var weights: [Double] = []
            var current = min
            while current <= max + 0.001 {
                weights.append((current * 100).rounded() / 100) // Round to 2dp
                current += increment
            }
            return weights.sorted()

        case .plateBased(let barWeight, let plates):
            return Self.barbellWeights(barWeight: barWeight, plates: plates)

        case .bodyweightOnly:
            return [0.0]
        }
    }

    /// Returns the absolute maximum achievable weight for the given type, or nil
    /// if the type is not in this profile.
    func maxWeightKg(for equipmentType: EquipmentType) -> Double? {
        guard let item = item(for: equipmentType) else { return nil }
        switch item.details {
        case .incrementBased(_, let max, _):
            return max
        case .plateBased(let bar, let plates):
            // Max = bar + 2 × sum of all available plates (one full set per side)
            return bar + 2.0 * plates.reduce(0, +)
        case .bodyweightOnly:
            return 0.0
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Barbell weight set generation
    // ---------------------------------------------------------------------------

    /// Generates every achievable barbell total by exhaustively combining plate pairs.
    ///
    /// Algorithm: dynamic programming on achievable per-side loads.
    /// Each plate denomination can be used multiple times (one pair per addition).
    /// Complexity is bounded in practice because plate sets are small (≤ 10 types).
    private static func barbellWeights(barWeight: Double, plates: [Double]) -> [Double] {
        // We work in integer 0.25 kg units to avoid floating-point accumulation errors.
        // Scale factor: 1 kg = 4 units (handles 0.25 kg micro-plates).
        let scale = 4
        let maxPerSideUnits = plates.reduce(0) { $0 + Int(($1 * Double(scale)).rounded()) }

        // dp[load] = true if `load` units per side is achievable
        var dp = Array(repeating: false, count: maxPerSideUnits + 1)
        dp[0] = true

        let plateUnits = plates.map { Int(($0 * Double(scale)).rounded()) }
        for unit in plateUnits {
            guard unit > 0 else { continue }
            // Unbounded knapsack: iterate forward so a plate can be used multiple times
            for load in unit...maxPerSideUnits {
                if dp[load - unit] { dp[load] = true }
            }
        }

        let barUnits = Int((barWeight * Double(scale)).rounded())
        var result: [Double] = []
        for load in 0...maxPerSideUnits where dp[load] {
            let totalUnits = barUnits + load * 2  // both sides
            let totalKg = Double(totalUnits) / Double(scale)
            result.append(totalKg)
        }
        return result.sorted()
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
                    details: .incrementBased(minKg: 2.5, maxKg: 45.0, incrementKg: 2.5),
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000002") ?? UUID(),
                    equipmentType: .barbell,
                    count: 3,
                    details: .plateBased(
                        barWeightKg: 20.0,
                        availablePlatesKg: [25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25]
                    ),
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000003") ?? UUID(),
                    equipmentType: .adjustableBench,
                    count: 4,
                    details: .bodyweightOnly,
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000004") ?? UUID(),
                    equipmentType: .cableMachine,
                    count: 2,
                    details: .incrementBased(minKg: 2.5, maxKg: 90.0, incrementKg: 2.5),
                    detectedByVision: true
                ),
                EquipmentItem(
                    id: UUID(uuidString: "11111111-0000-0000-0000-000000000005") ?? UUID(),
                    equipmentType: .pullUpBar,
                    count: 2,
                    details: .bodyweightOnly,
                    detectedByVision: true
                )
            ],
            isActive: true
        )
    }

    // ---------------------------------------------------------------------------
    // MARK: Canonical JSON string matching mockProfile()
    // ---------------------------------------------------------------------------
    // Use this as the expected output when prompting the Vision API, and as the
    // reference fixture in unit tests that validate the full encode/decode round-trip.

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
          "detected_by_vision": true,
          "details": {
            "kind": "increment_based",
            "min_kg": 2.5,
            "max_kg": 45.0,
            "increment_kg": 2.5
          }
        },
        {
          "id": "11111111-0000-0000-0000-000000000002",
          "equipment_type": { "type": "barbell" },
          "count": 3,
          "detected_by_vision": true,
          "details": {
            "kind": "plate_based",
            "bar_weight_kg": 20.0,
            "available_plates_kg": [25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25]
          }
        },
        {
          "id": "11111111-0000-0000-0000-000000000003",
          "equipment_type": { "type": "adjustable_bench" },
          "count": 4,
          "detected_by_vision": true,
          "details": { "kind": "bodyweight_only" }
        },
        {
          "id": "11111111-0000-0000-0000-000000000004",
          "equipment_type": { "type": "cable_machine" },
          "count": 2,
          "detected_by_vision": true,
          "details": {
            "kind": "increment_based",
            "min_kg": 2.5,
            "max_kg": 90.0,
            "increment_kg": 2.5
          }
        },
        {
          "id": "11111111-0000-0000-0000-000000000005",
          "equipment_type": { "type": "pull_up_bar" },
          "count": 2,
          "detected_by_vision": true,
          "details": { "kind": "bodyweight_only" }
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
