// TraineeModelSnapshotsTests.swift
// ProjectApexTests
//
// Codable round-trip tests for snapshot value types.

import Testing
import Foundation
@testable import ProjectApex

@Suite("TopSetSnapshot")
struct TopSetSnapshotTests {
    @Test("Codable round-trip preserves all fields")
    func roundTrip() throws {
        let original = TopSetSnapshot(
            sessionId: UUID(),
            localDate: "2026-05-04",
            weightKg: 100.0,
            reps: 5,
            e1rm: 116.67
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TopSetSnapshot.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("ExerciseSessionSnapshot")
struct ExerciseSessionSnapshotTests {
    @Test("Round-trip with heaviest top set")
    func withTopSet() throws {
        let top = TopSetSnapshot(
            sessionId: UUID(),
            localDate: "2026-05-04",
            weightKg: 120, reps: 4, e1rm: 136
        )
        let original = ExerciseSessionSnapshot(
            sessionId: top.sessionId,
            localDate: top.localDate,
            heaviestTopSet: top,
            topSetCount: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExerciseSessionSnapshot.self, from: data)
        #expect(decoded == original)
        #expect(decoded.heaviestTopSet?.weightKg == 120)
    }

    @Test("Round-trip with no top sets")
    func withoutTopSet() throws {
        let original = ExerciseSessionSnapshot(
            sessionId: UUID(), localDate: "2026-05-04",
            heaviestTopSet: nil, topSetCount: 0
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ExerciseSessionSnapshot.self, from: data) == original)
    }
}

@Suite("BodyweightEntry")
struct BodyweightEntryTests {
    @Test("Codable round-trip")
    func roundTrip() throws {
        let original = BodyweightEntry(localDate: "2026-05-04", weightKg: 82.4)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(BodyweightEntry.self, from: data) == original)
    }
}

@Suite("LifeContextEvent")
struct LifeContextEventTests {
    @Test("Round-trip with notes")
    func withNotes() throws {
        let original = LifeContextEvent(localDate: "2026-05-04", kind: "travel", notes: "10 days abroad")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LifeContextEvent.self, from: data) == original)
    }

    @Test("Round-trip without notes")
    func withoutNotes() throws {
        let original = LifeContextEvent(localDate: "2026-05-04", kind: "illness")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LifeContextEvent.self, from: data) == original)
    }
}

@Suite("ReassessmentRecord")
struct ReassessmentRecordTests {
    @Test("Round-trip preserves advanced-patterns list order")
    func roundTrip() throws {
        let original = ReassessmentRecord(
            triggeredAt: Date(timeIntervalSince1970: 1_750_000_000),
            triggeringSessionCount: 24,
            advancedPatterns: [.horizontalPush, .squat, .verticalPull, .hipHinge]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReassessmentRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.advancedPatterns == [.horizontalPush, .squat, .verticalPull, .hipHinge])
    }
}

@Suite("PatternProjection")
struct PatternProjectionTests {
    @Test("Round-trip preserves floor/stretch/progress")
    func roundTrip() throws {
        let original = PatternProjection(
            pattern: .squat, floor: 140.0, stretch: 165.0, progress: .onTrack
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PatternProjection.self, from: data) == original)
    }
}

@Suite("RecoveryProfile")
struct RecoveryProfileTests {
    @Test("Default init yields full readiness on both axes, no stimulus history")
    func defaultInit() {
        let profile = RecoveryProfile()
        #expect(profile.neuromuscularReadiness == 1.0)
        #expect(profile.metabolicReadiness == 1.0)
        #expect(profile.lastNeuromuscularStimulusAt == nil)
        #expect(profile.lastMetabolicStimulusAt == nil)
    }

    @Test("Round-trip preserves both axes independently")
    func roundTrip() throws {
        let original = RecoveryProfile(
            lastNeuromuscularStimulusAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastMetabolicStimulusAt: Date(timeIntervalSince1970: 1_710_000_000),
            neuromuscularReadiness: 0.4,
            metabolicReadiness: 0.7
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RecoveryProfile.self, from: data) == original)
    }
}

@Suite("GoalState")
struct GoalStateTests {
    @Test("Round-trip with focus areas")
    func roundTripWithFocus() throws {
        let original = GoalState(
            statement: "Get visibly stronger in the upper body",
            focusAreas: [.chest, .back, .shoulders],
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GoalState.self, from: data)
        #expect(decoded == original)
    }

    @Test("Round-trip with empty focus areas")
    func roundTripEmpty() throws {
        let original = GoalState(
            statement: "Maintain general fitness",
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(GoalState.self, from: data) == original)
    }
}
