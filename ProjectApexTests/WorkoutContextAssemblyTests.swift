// WorkoutContextAssemblyTests.swift
// ProjectApexTests — P0-T06
//
// Verifies:
//   1. WorkoutContext.mockContext() builds without crash
//   2. All 10 nested struct types are present and populated
//   3. All top-level snake_case CodingKeys round-trip through JSON
//   4. Full encode → decode produces a structurally identical context
//   5. nil biometrics encodes to JSON without a "biometrics" key

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Helpers

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

// MARK: - WorkoutContextAssemblyTests

@Suite("WorkoutContext Assembly")
struct WorkoutContextAssemblyTests {

    // MARK: mockContext factory

    @Test("mockContext() builds without crash and has correct requestType")
    func mockContext_builds() {
        let ctx = WorkoutContext.mockContext()
        #expect(ctx.requestType == "set_prescription")
    }

    // MARK: Nested struct presence

    @Test("mockContext has all 10 nested struct types populated")
    func mockContext_allNestedTypesPopulated() {
        let ctx = WorkoutContext.mockContext()

        // SessionMetadata
        #expect(!ctx.sessionMetadata.sessionId.isEmpty)
        #expect(ctx.sessionMetadata.programName != nil)
        #expect(ctx.sessionMetadata.dayLabel != nil)
        #expect(ctx.sessionMetadata.weekNumber != nil)
        #expect(ctx.sessionMetadata.totalSessionCount > 0)

        // Biometrics
        let bio = try! #require(ctx.biometrics)
        #expect(bio.bodyweightKg != nil)
        #expect(bio.restingHeartRate != nil)
        #expect(bio.readinessScore != nil)
        #expect(bio.sleepHours != nil)

        // CurrentExercise
        #expect(!ctx.currentExercise.name.isEmpty)
        #expect(!ctx.currentExercise.equipmentTypeKey.isEmpty)
        #expect(ctx.currentExercise.setNumber > 0)
        #expect(ctx.currentExercise.plannedSets > 0)
        #expect(!ctx.currentExercise.primaryMuscles.isEmpty)

        // PlanTarget (nested in CurrentExercise)
        let target = try! #require(ctx.currentExercise.planTarget)
        #expect(target.minReps > 0)
        #expect(target.maxReps >= target.minReps)
        #expect(target.rirTarget != nil)
        #expect(target.intensityPercent != nil)

        // ExerciseHistoryItem + CompletedSet
        #expect(!ctx.sessionHistoryToday.isEmpty)
        let historyItem = ctx.sessionHistoryToday[0]
        #expect(!historyItem.exerciseName.isEmpty)
        #expect(!historyItem.sets.isEmpty)

        // CompletedSet (in currentExerciseSetsToday)
        #expect(!ctx.currentExerciseSetsToday.isEmpty)
        let completedSet = ctx.currentExerciseSetsToday[0]
        #expect(completedSet.weightKg > 0)
        #expect(completedSet.reps > 0)

        // HistoricalPerformance
        let hist = try! #require(ctx.historicalPerformance)
        #expect(hist.personalBest != nil)
        #expect(hist.recentAverage != nil)
        #expect(hist.trend != nil)

        // RecentAverage (nested in HistoricalPerformance)
        let avg = try! #require(hist.recentAverage)
        #expect(avg.sessionCount > 0)
        #expect(avg.avgWeightKg > 0)
        #expect(avg.avgReps > 0)

        // QualitativeNote
        #expect(!ctx.qualitativeNotesToday.isEmpty)
        let note = ctx.qualitativeNotesToday[0]
        #expect(!note.category.isEmpty)
        #expect(!note.text.isEmpty)

        // RAGMemoryItem
        #expect(!ctx.ragRetrievedMemory.isEmpty)
        let mem = ctx.ragRetrievedMemory[0]
        #expect(mem.relevanceScore > 0)
        #expect(!mem.summary.isEmpty)
    }

    // MARK: Top-level snake_case CodingKeys

    @Test("Encoded JSON contains all expected top-level snake_case keys")
    func encode_topLevelKeysAreSnakeCase() throws {
        let ctx = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let expectedKeys: Set<String> = [
            "request_type",
            "session_metadata",
            "biometrics",
            "streak_result",
            "is_first_session",
            "current_exercise",
            "session_history_today",
            "current_exercise_sets_today",
            "within_session_performance",
            "historical_performance",
            "qualitative_notes_today",
            "rag_retrieved_memory"
        ]
        let actualKeys = Set(json.keys)
        #expect(expectedKeys.isSubset(of: actualKeys))
    }

    @Test("SessionMetadata encodes with snake_case keys")
    func encode_sessionMetadata_snakeCaseKeys() throws {
        let ctx = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let meta = json["session_metadata"] as! [String: Any]

        #expect(meta["session_id"] is String)
        #expect(meta["started_at"] is String)
        #expect(meta["program_name"] is String)
        #expect(meta["day_label"] is String)
        #expect(meta["week_number"] is Int)
        #expect(meta["total_session_count"] is Int)
    }

    @Test("Biometrics encodes with snake_case keys")
    func encode_biometrics_snakeCaseKeys() throws {
        let ctx = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let bio = json["biometrics"] as! [String: Any]

        #expect(bio["bodyweight_kg"] is Double)
        #expect(bio["resting_heart_rate"] is Int)
        #expect(bio["readiness_score"] is Int)
        #expect(bio["sleep_hours"] is Double)
    }

    @Test("CurrentExercise encodes with snake_case keys")
    func encode_currentExercise_snakeCaseKeys() throws {
        let ctx = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ex = json["current_exercise"] as! [String: Any]

        #expect(ex["name"] is String)
        #expect(ex["equipment_type_key"] is String)
        #expect(ex["set_number"] is Int)
        #expect(ex["planned_sets"] is Int)
        #expect(ex["plan_target"] is [String: Any])
        #expect(ex["primary_muscles"] is [String])
        #expect(ex["secondary_muscles"] is [String])
    }

    @Test("CompletedSet encodes with snake_case keys")
    func encode_completedSet_snakeCaseKeys() throws {
        let ctx = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let sets = json["current_exercise_sets_today"] as! [[String: Any]]
        let set = sets[0]

        #expect(set["set_number"] is Int)
        #expect(set["weight_kg"] is Double)
        #expect(set["reps"] is Int)
        #expect(set["rir_actual"] is Int)
        #expect(set["rpe"] is Double)
        #expect(set["tempo"] is String)
        #expect(set["rest_taken_seconds"] is Int)
        #expect(set["completed_at"] is String)
    }

    @Test("RAGMemoryItem encodes with snake_case keys")
    func encode_ragMemoryItem_snakeCaseKeys() throws {
        let ctx = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let items = json["rag_retrieved_memory"] as! [[String: Any]]
        let item = items[0]

        #expect(item["relevance_score"] is Double)
        #expect(item["summary"] is String)
    }

    // MARK: Full encode → decode round-trip

    @Test("Full encode/decode round-trip preserves all scalar values")
    func roundTrip_preservesScalarValues() throws {
        let original = WorkoutContext.mockContext()
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(WorkoutContext.self, from: data)

        // Top-level
        #expect(decoded.requestType == original.requestType)
        #expect(decoded.isFirstSession == original.isFirstSession)

        // SessionMetadata
        #expect(decoded.sessionMetadata.sessionId == original.sessionMetadata.sessionId)
        #expect(decoded.sessionMetadata.programName == original.sessionMetadata.programName)
        #expect(decoded.sessionMetadata.dayLabel == original.sessionMetadata.dayLabel)
        #expect(decoded.sessionMetadata.weekNumber == original.sessionMetadata.weekNumber)
        #expect(decoded.sessionMetadata.totalSessionCount == original.sessionMetadata.totalSessionCount)

        // Biometrics
        let origBio = try! #require(original.biometrics)
        let decBio  = try! #require(decoded.biometrics)
        #expect(decBio.bodyweightKg == origBio.bodyweightKg)
        #expect(decBio.restingHeartRate == origBio.restingHeartRate)
        #expect(decBio.readinessScore == origBio.readinessScore)
        #expect(decBio.sleepHours == origBio.sleepHours)

        // CurrentExercise
        #expect(decoded.currentExercise.name == original.currentExercise.name)
        #expect(decoded.currentExercise.equipmentTypeKey == original.currentExercise.equipmentTypeKey)
        #expect(decoded.currentExercise.setNumber == original.currentExercise.setNumber)
        #expect(decoded.currentExercise.plannedSets == original.currentExercise.plannedSets)
        #expect(decoded.currentExercise.primaryMuscles == original.currentExercise.primaryMuscles)
        #expect(decoded.currentExercise.secondaryMuscles == original.currentExercise.secondaryMuscles)

        // PlanTarget
        let origTarget = try! #require(original.currentExercise.planTarget)
        let decTarget  = try! #require(decoded.currentExercise.planTarget)
        #expect(decTarget.minReps == origTarget.minReps)
        #expect(decTarget.maxReps == origTarget.maxReps)
        #expect(decTarget.rirTarget == origTarget.rirTarget)
        #expect(decTarget.intensityPercent == origTarget.intensityPercent)

        // CompletedSet
        let origSet = original.currentExerciseSetsToday[0]
        let decSet  = decoded.currentExerciseSetsToday[0]
        #expect(decSet.setNumber == origSet.setNumber)
        #expect(decSet.weightKg == origSet.weightKg)
        #expect(decSet.reps == origSet.reps)
        #expect(decSet.rirActual == origSet.rirActual)
        #expect(decSet.rpe == origSet.rpe)
        #expect(decSet.tempo == origSet.tempo)
        #expect(decSet.restTakenSeconds == origSet.restTakenSeconds)

        // HistoricalPerformance
        let origHist = try! #require(original.historicalPerformance)
        let decHist  = try! #require(decoded.historicalPerformance)
        #expect(decHist.trend == origHist.trend)

        // RecentAverage
        let origAvg = try! #require(origHist.recentAverage)
        let decAvg  = try! #require(decHist.recentAverage)
        #expect(decAvg.sessionCount == origAvg.sessionCount)
        #expect(decAvg.avgWeightKg == origAvg.avgWeightKg)
        #expect(decAvg.avgReps == origAvg.avgReps)
        #expect(decAvg.avgRir == origAvg.avgRir)

        // QualitativeNote
        let origNote = original.qualitativeNotesToday[0]
        let decNote  = decoded.qualitativeNotesToday[0]
        #expect(decNote.category == origNote.category)
        #expect(decNote.text == origNote.text)

        // RAGMemoryItem
        let origMem = original.ragRetrievedMemory[0]
        let decMem  = decoded.ragRetrievedMemory[0]
        #expect(decMem.relevanceScore == origMem.relevanceScore)
        #expect(decMem.summary == origMem.summary)
    }

    // MARK: nil biometrics

    @Test("nil biometrics encodes to JSON without a 'biometrics' key")
    func nilBiometrics_omittedFromJSON() throws {
        // Build a context with no biometrics
        let ctx = WorkoutContext(
            requestType: "set_prescription",
            sessionMetadata: WorkoutContext.mockContext().sessionMetadata,
            biometrics: nil,
            streakResult: nil,
            userProfile: nil,
            isFirstSession: false,
            currentExercise: WorkoutContext.mockContext().currentExercise,
            sessionHistoryToday: [],
            currentExerciseSetsToday: [],
            withinSessionPerformance: [],
            historicalPerformance: nil,
            qualitativeNotesToday: [],
            ragRetrievedMemory: []
        )

        let encoder = makeEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["biometrics"] == nil)
    }

    @Test("nil biometrics decodes back as nil")
    func nilBiometrics_decodesAsNil() throws {
        let ctx = WorkoutContext(
            requestType: "set_prescription",
            sessionMetadata: WorkoutContext.mockContext().sessionMetadata,
            biometrics: nil,
            streakResult: nil,
            userProfile: nil,
            isFirstSession: false,
            currentExercise: WorkoutContext.mockContext().currentExercise,
            sessionHistoryToday: [],
            currentExerciseSetsToday: [],
            withinSessionPerformance: [],
            historicalPerformance: nil,
            qualitativeNotesToday: [],
            ragRetrievedMemory: []
        )

        let data = try makeEncoder().encode(ctx)
        let decoded = try makeDecoder().decode(WorkoutContext.self, from: data)

        #expect(decoded.biometrics == nil)
    }
}
