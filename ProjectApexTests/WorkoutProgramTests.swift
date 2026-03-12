// WorkoutProgramTests.swift
// ProjectApexTests — P2-T01
//
// Unit tests for all WorkoutProgram data models.
//
// Covers:
//   • All types are Codable, Identifiable (where applicable), Sendable, value types
//   • MesocyclePhase raw values match the spec
//   • TrainingWeek.isDeload derived correctly from phase == .deload
//   • Mesocycle.mockMesocycle() structure: 1 week, 2 days, 3 exercises each
//   • Encode → decode round-trip passes for a full Mesocycle
//   • PlannedExercise.equipmentRequired round-trips through EquipmentType Codable

import XCTest
@testable import ProjectApex

final class WorkoutProgramTests: XCTestCase {

    // MARK: - Helpers

    private let encoder = JSONEncoder.workoutProgram
    private let decoder = JSONDecoder.workoutProgram

    // MARK: ─── MesocyclePhase ─────────────────────────────────────────────────

    func test_mesocyclePhase_rawValues() {
        XCTAssertEqual(MesocyclePhase.accumulation.rawValue,    "accumulation")
        XCTAssertEqual(MesocyclePhase.intensification.rawValue, "intensification")
        XCTAssertEqual(MesocyclePhase.peaking.rawValue,         "peaking")
        XCTAssertEqual(MesocyclePhase.deload.rawValue,          "deload")
    }

    func test_mesocyclePhase_codableRoundTrip() throws {
        for phase in [MesocyclePhase.accumulation, .intensification, .peaking, .deload] {
            let data = try encoder.encode(phase)
            let decoded = try decoder.decode(MesocyclePhase.self, from: data)
            XCTAssertEqual(decoded, phase, "Phase \(phase) must survive encode/decode round-trip")
        }
    }

    // MARK: ─── TrainingWeek.isDeload ─────────────────────────────────────────

    func test_trainingWeek_isDeload_trueForDeloadPhase() {
        let week = TrainingWeek(
            id: UUID(),
            weekNumber: 12,
            phase: .deload,
            trainingDays: []
        )
        XCTAssertTrue(week.isDeload, "isDeload must be true when phase == .deload")
    }

    func test_trainingWeek_isDeload_falseForOtherPhases() {
        let phases: [MesocyclePhase] = [.accumulation, .intensification, .peaking]
        for phase in phases {
            let week = TrainingWeek(
                id: UUID(),
                weekNumber: 1,
                phase: phase,
                trainingDays: []
            )
            XCTAssertFalse(week.isDeload,
                           "isDeload must be false for phase \(phase.rawValue)")
        }
    }

    func test_trainingWeek_isDeload_notEncodedNotDecoded() throws {
        // isDeload is a computed property and must NOT appear in the JSON envelope
        let week = TrainingWeek(
            id: UUID(),
            weekNumber: 12,
            phase: .deload,
            trainingDays: []
        )
        let data = try encoder.encode(week)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["isDeload"],
                     "isDeload is computed — it must not appear in JSON output")
        XCTAssertNil(json["is_deload"],
                     "isDeload is computed — it must not appear in JSON output (snake_case)")
    }

    // MARK: ─── RepRange ───────────────────────────────────────────────────────

    func test_repRange_codableRoundTrip() throws {
        let range = RepRange(min: 6, max: 10)
        let data = try encoder.encode(range)
        let decoded = try decoder.decode(RepRange.self, from: data)
        XCTAssertEqual(decoded.min, 6)
        XCTAssertEqual(decoded.max, 10)
    }

    // MARK: ─── PlannedExercise ────────────────────────────────────────────────

    func test_plannedExercise_equipmentRequired_usesEquipmentType() throws {
        let exercise = PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: ["anterior_deltoid"],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 8),
            tempo: "3-1-1-0",
            restSeconds: 150,
            rirTarget: 2,
            coachingCues: ["Arch back"]
        )
        XCTAssertEqual(exercise.equipmentRequired, .barbell)

        let data = try encoder.encode(exercise)
        let decoded = try decoder.decode(PlannedExercise.self, from: data)
        XCTAssertEqual(decoded.equipmentRequired, .barbell,
                       "equipmentRequired must round-trip through EquipmentType Codable")
    }

    func test_plannedExercise_unknownEquipment_codableRoundTrip() throws {
        let exercise = PlannedExercise(
            id: UUID(),
            exerciseId: "some_future_machine",
            name: "Some Future Machine",
            primaryMuscle: "lats",
            synergists: [],
            equipmentRequired: .unknown("future_machine"),
            sets: 3,
            repRange: RepRange(min: 8, max: 12),
            tempo: "2-0-1-0",
            restSeconds: 90,
            rirTarget: 3,
            coachingCues: []
        )
        let data = try encoder.encode(exercise)
        let decoded = try decoder.decode(PlannedExercise.self, from: data)
        XCTAssertEqual(decoded.equipmentRequired, .unknown("future_machine"))
    }

    // MARK: ─── mockMesocycle() structure ─────────────────────────────────────

    func test_mockMesocycle_hasOneWeek() {
        let mock = Mesocycle.mockMesocycle()
        XCTAssertEqual(mock.weeks.count, 1,
                       "mockMesocycle must have exactly 1 week")
    }

    func test_mockMesocycle_hasTwoTrainingDays() {
        let mock = Mesocycle.mockMesocycle()
        XCTAssertEqual(mock.weeks[0].trainingDays.count, 2,
                       "mockMesocycle week must have exactly 2 training days")
    }

    func test_mockMesocycle_eachDayHasThreeExercises() {
        let mock = Mesocycle.mockMesocycle()
        for day in mock.weeks[0].trainingDays {
            XCTAssertEqual(day.exercises.count, 3,
                           "Each training day in mockMesocycle must have exactly 3 exercises")
        }
    }

    func test_mockMesocycle_weekOneIsAccumulation() {
        let mock = Mesocycle.mockMesocycle()
        XCTAssertEqual(mock.weeks[0].phase, .accumulation,
                       "mockMesocycle week 1 must be accumulation phase")
        XCTAssertFalse(mock.weeks[0].isDeload,
                       "mockMesocycle week 1 must not be a deload week")
    }

    func test_mockMesocycle_totalWeeksIs12() {
        let mock = Mesocycle.mockMesocycle()
        XCTAssertEqual(mock.totalWeeks, 12,
                       "mockMesocycle.totalWeeks must be 12 per the program spec")
    }

    func test_mockMesocycle_isActive() {
        let mock = Mesocycle.mockMesocycle()
        XCTAssertTrue(mock.isActive)
    }

    // MARK: ─── Full Mesocycle encode → decode round-trip ─────────────────────

    func test_mesocycle_fullRoundTrip_encodeDecode() throws {
        let original = Mesocycle.mockMesocycle()

        // Encode
        let data = try encoder.encode(original)
        XCTAssertGreaterThan(data.count, 0, "Encoded data must not be empty")

        // Decode
        let decoded = try decoder.decode(Mesocycle.self, from: data)

        // Top-level identity
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.userId, original.userId)
        XCTAssertEqual(decoded.isActive, original.isActive)
        XCTAssertEqual(decoded.totalWeeks, original.totalWeeks)
        XCTAssertEqual(decoded.periodizationModel, original.periodizationModel)

        // Date round-trip (ISO8601 is second-precision)
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970.rounded(),
            original.createdAt.timeIntervalSince1970.rounded(),
            "createdAt must survive ISO8601 encode/decode"
        )

        // Weeks
        XCTAssertEqual(decoded.weeks.count, original.weeks.count)
        let dWeek = decoded.weeks[0]
        let oWeek = original.weeks[0]
        XCTAssertEqual(dWeek.id, oWeek.id)
        XCTAssertEqual(dWeek.weekNumber, oWeek.weekNumber)
        XCTAssertEqual(dWeek.phase, oWeek.phase)
        XCTAssertEqual(dWeek.isDeload, oWeek.isDeload)

        // Training days
        XCTAssertEqual(dWeek.trainingDays.count, oWeek.trainingDays.count)
        let dDay = dWeek.trainingDays[0]
        let oDay = oWeek.trainingDays[0]
        XCTAssertEqual(dDay.id, oDay.id)
        XCTAssertEqual(dDay.dayOfWeek, oDay.dayOfWeek)
        XCTAssertEqual(dDay.dayLabel, oDay.dayLabel)
        XCTAssertEqual(dDay.sessionNotes, oDay.sessionNotes)

        // Exercises
        XCTAssertEqual(dDay.exercises.count, oDay.exercises.count)
        let dEx = dDay.exercises[0]
        let oEx = oDay.exercises[0]
        XCTAssertEqual(dEx.id, oEx.id)
        XCTAssertEqual(dEx.exerciseId, oEx.exerciseId)
        XCTAssertEqual(dEx.name, oEx.name)
        XCTAssertEqual(dEx.primaryMuscle, oEx.primaryMuscle)
        XCTAssertEqual(dEx.synergists, oEx.synergists)
        XCTAssertEqual(dEx.equipmentRequired, oEx.equipmentRequired)
        XCTAssertEqual(dEx.sets, oEx.sets)
        XCTAssertEqual(dEx.repRange.min, oEx.repRange.min)
        XCTAssertEqual(dEx.repRange.max, oEx.repRange.max)
        XCTAssertEqual(dEx.tempo, oEx.tempo)
        XCTAssertEqual(dEx.restSeconds, oEx.restSeconds)
        XCTAssertEqual(dEx.rirTarget, oEx.rirTarget)
        XCTAssertEqual(dEx.coachingCues, oEx.coachingCues)
    }

    func test_mesocycle_decodedIsDeload_derivedCorrectly() throws {
        // Build a mesocycle with a deload week, encode it, decode it,
        // and verify isDeload is re-derived correctly (not stored).
        let deloadWeek = TrainingWeek(
            id: UUID(),
            weekNumber: 12,
            phase: .deload,
            trainingDays: []
        )
        var mock = Mesocycle.mockMesocycle()
        mock.weeks.append(deloadWeek)

        let data = try encoder.encode(mock)
        let decoded = try decoder.decode(Mesocycle.self, from: data)

        let lastWeek = try XCTUnwrap(decoded.weeks.last)
        XCTAssertEqual(lastWeek.phase, .deload)
        XCTAssertTrue(lastWeek.isDeload,
                      "isDeload must be re-derived as true after decoding a deload week")
    }
}
