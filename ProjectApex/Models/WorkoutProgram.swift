// WorkoutProgram.swift
// ProjectApex — Models
//
// All program-related data models for the macro-program generation engine.
// These types form the stable schema that ProgramGenerationService decodes into.
//
// ISOLATION NOTE — SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor:
// All types are `nonisolated` to opt their synthesised Codable conformances
// out of @MainActor, allowing decoding from any actor context.
//
// Dependency: import Foundation only.

import Foundation

// MARK: - MesocyclePhase

/// The periodization phase of a training week.
nonisolated enum MesocyclePhase: String, Codable, Sendable {
    case accumulation    // Weeks 1–4: building volume
    case intensification // Weeks 5–8: raising intensity
    case peaking         // Weeks 9–11: peak performance
    case deload          // Week 12: recovery
}

// MARK: - RepRange

/// A closed rep range prescription (e.g. 6–10 reps).
nonisolated struct RepRange: Codable, Sendable, Equatable {
    let min: Int
    let max: Int
}

// MARK: - PlannedExercise

/// A single exercise slot in a training day, fully prescribed by the AI.
nonisolated struct PlannedExercise: Codable, Identifiable, Sendable {
    let id: UUID
    /// Canonical exercise identifier (e.g. "barbell_bench_press").
    let exerciseId: String
    /// Human-readable exercise name (e.g. "Barbell Bench Press").
    let name: String
    /// Primary muscle group (e.g. "pectoralis_major").
    let primaryMuscle: String
    /// Supporting muscle groups.
    let synergists: [String]
    /// Equipment required — uses the shared EquipmentType enum from GymProfile.
    let equipmentRequired: EquipmentType
    let sets: Int
    let repRange: RepRange
    /// Eccentric-Pause-Concentric-Hold tempo, e.g. "3-1-1-0".
    let tempo: String
    let restSeconds: Int
    let rirTarget: Int
    let coachingCues: [String]

    // Explicit memberwise init (required because custom Decodable init suppresses synthesis).
    nonisolated init(
        id: UUID,
        exerciseId: String,
        name: String,
        primaryMuscle: String,
        synergists: [String],
        equipmentRequired: EquipmentType,
        sets: Int,
        repRange: RepRange,
        tempo: String,
        restSeconds: Int,
        rirTarget: Int,
        coachingCues: [String]
    ) {
        self.id = id
        self.exerciseId = exerciseId
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.synergists = synergists
        self.equipmentRequired = equipmentRequired
        self.sets = sets
        self.repRange = repRange
        self.tempo = tempo
        self.restSeconds = restSeconds
        self.rirTarget = rirTarget
        self.coachingCues = coachingCues
    }

    enum CodingKeys: String, CodingKey {
        case id
        case exerciseId        = "exercise_id"
        case name
        case primaryMuscle     = "primary_muscle"
        case synergists
        case equipmentRequired = "equipment_required"
        case sets
        case repRange          = "rep_range"
        case tempo
        case restSeconds       = "rest_seconds"
        case rirTarget         = "rir_target"
        case coachingCues      = "coaching_cues"
    }

    // Custom decoder: `equipment_required` in LLM output is a plain string
    // (e.g. "dumbbell_set"), but EquipmentType.Codable normally expects an
    // object form {"type": "..."}. We handle both so round-trip encoding still works.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,   forKey: .id)
        exerciseId     = try c.decode(String.self, forKey: .exerciseId)
        name           = try c.decode(String.self, forKey: .name)
        primaryMuscle  = try c.decode(String.self, forKey: .primaryMuscle)
        synergists     = try c.decode([String].self, forKey: .synergists)
        sets           = try c.decode(Int.self,    forKey: .sets)
        repRange       = try c.decode(RepRange.self, forKey: .repRange)
        tempo          = try c.decode(String.self, forKey: .tempo)
        restSeconds    = try c.decode(Int.self,    forKey: .restSeconds)
        rirTarget      = try c.decode(Int.self,    forKey: .rirTarget)
        coachingCues   = try c.decode([String].self, forKey: .coachingCues)

        // Try plain-string form first (LLM output), fall back to object form (round-trip).
        if let typeKey = try? c.decode(String.self, forKey: .equipmentRequired) {
            equipmentRequired = EquipmentType(typeKey: typeKey)
        } else {
            equipmentRequired = try c.decode(EquipmentType.self, forKey: .equipmentRequired)
        }
    }
}

// MARK: - TrainingDay

/// A single day within a training week.
nonisolated struct TrainingDay: Codable, Identifiable, Sendable {
    let id: UUID
    /// 1 = Monday, 7 = Sunday (ISO-8601 weekday convention).
    let dayOfWeek: Int
    /// Short label for the day, e.g. "Upper_A", "Lower_B", "Push_A".
    let dayLabel: String
    var exercises: [PlannedExercise]
    let sessionNotes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case dayOfWeek    = "day_of_week"
        case dayLabel     = "day_label"
        case exercises
        case sessionNotes = "session_notes"
    }
}

// MARK: - TrainingWeek

/// One week within a 12-week mesocycle.
nonisolated struct TrainingWeek: Codable, Identifiable, Sendable {
    let id: UUID
    /// 1-based week number within the mesocycle (1–12).
    let weekNumber: Int
    let phase: MesocyclePhase
    var trainingDays: [TrainingDay]

    /// Derived: true when the phase is `.deload`.
    var isDeload: Bool { phase == .deload }

    enum CodingKeys: String, CodingKey {
        case id
        case weekNumber  = "week_number"
        case phase
        case trainingDays = "training_days"
    }
}

// MARK: - Mesocycle

/// The top-level container for a 12-week periodized training program.
///
/// Decoded from the AI response by `ProgramGenerationService`.
nonisolated struct Mesocycle: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let createdAt: Date
    var isActive: Bool
    var weeks: [TrainingWeek]
    let totalWeeks: Int
    let periodizationModel: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId            = "user_id"
        case createdAt         = "created_at"
        case isActive          = "is_active"
        case weeks
        case totalWeeks        = "total_weeks"
        case periodizationModel = "periodization_model"
    }
}

// MARK: - Mesocycle Mock Data

extension Mesocycle {

    /// Factory method that returns a minimal but complete `Mesocycle` for
    /// unit tests, SwiftUI previews, and ProgramGenerationService integration tests.
    ///
    /// Structure:
    ///   - 1 week (accumulation phase)
    ///   - 2 training days per week
    ///   - 3 exercises per training day
    static func mockMesocycle() -> Mesocycle {
        let fixedDate = Date(timeIntervalSince1970: 1_741_996_800) // 2025-03-15T00:00:00Z
        let userId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001") ?? UUID()

        let exercise = { (n: Int, name: String, equipment: EquipmentType) in
            PlannedExercise(
                id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-\(String(format: "%012d", n))") ?? UUID(),
                exerciseId: name.lowercased().replacingOccurrences(of: " ", with: "_"),
                name: name,
                primaryMuscle: "pectoralis_major",
                synergists: ["anterior_deltoid", "triceps_brachii"],
                equipmentRequired: equipment,
                sets: 4,
                repRange: RepRange(min: 6, max: 10),
                tempo: "3-1-1-0",
                restSeconds: 150,
                rirTarget: 2,
                coachingCues: ["Retract scapula", "Drive through the bar"]
            )
        }

        let day1 = TrainingDay(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001") ?? UUID(),
            dayOfWeek: 1,
            dayLabel: "Push_A",
            exercises: [
                exercise(1, "Barbell Bench Press", .barbell),
                exercise(2, "Overhead Press", .barbell),
                exercise(3, "Cable Fly", .cableMachine)
            ],
            sessionNotes: nil
        )

        let day2 = TrainingDay(
            id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002") ?? UUID(),
            dayOfWeek: 3,
            dayLabel: "Pull_A",
            exercises: [
                exercise(4, "Barbell Row", .barbell),
                exercise(5, "Lat Pulldown", .latPulldown),
                exercise(6, "Cable Row", .seatedRow)
            ],
            sessionNotes: "Focus on full ROM"
        )

        let week1 = TrainingWeek(
            id: UUID(uuidString: "AAAAAAAA-1111-0000-0000-000000000001") ?? UUID(),
            weekNumber: 1,
            phase: .accumulation,
            trainingDays: [day1, day2]
        )

        return Mesocycle(
            id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001") ?? UUID(),
            userId: userId,
            createdAt: fixedDate,
            isActive: true,
            weeks: [week1],
            totalWeeks: 12,
            periodizationModel: "linear_periodization"
        )
    }
}

// MARK: - JSON Encoder/Decoder factories

extension JSONEncoder {
    /// Shared encoder for WorkoutProgram types.
    /// ISO8601 dates, pretty-printed for readability.
    static var workoutProgram: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    /// Shared decoder for WorkoutProgram types.
    static var workoutProgram: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
