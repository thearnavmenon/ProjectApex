// TraineeModelProfilesTests.swift
// ProjectApexTests
//
// Tests for ExerciseProfile, MuscleProfile, PatternProfile (+ derived
// properties), ProjectionState. Round-trip + derived-property correctness
// across empty, single-session, and multi-session fixtures.

import Testing
import Foundation
@testable import ProjectApex

@Suite("ExerciseProfile")
struct ExerciseProfileTests {
    @Test("learningPhase flips to false at sessionCount 10")
    func learningPhaseBoundary() {
        var profile = ExerciseProfile(exerciseId: "barbell_bench_press")
        profile.sessionCount = 0
        #expect(profile.learningPhase == true)
        profile.sessionCount = 9
        #expect(profile.learningPhase == true)
        profile.sessionCount = 10
        #expect(profile.learningPhase == false)
        profile.sessionCount = 50
        #expect(profile.learningPhase == false)
    }

    @Test("Round-trip with top sets")
    func roundTrip() throws {
        let original = ExerciseProfile(
            exerciseId: "barbell_bench_press",
            topSets: [TopSetSnapshot(sessionId: UUID(), localDate: "2026-05-01",
                                     weightKg: 100, reps: 5, e1rm: 116.67)],
            e1rmCurrent: 116.67,
            e1rmMedian: 115,
            e1rmPeak: 120,
            sessionCount: 12,
            formDegradationFlag: false,
            confidence: .established
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ExerciseProfile.self, from: data) == original)
    }
}

@Suite("MuscleProfile")
struct MuscleProfileTests {
    @Test("Default init bootstraps confidence + progressing trend")
    func defaultInit() {
        let profile = MuscleProfile(muscleGroup: .chest)
        #expect(profile.confidence == .bootstrapping)
        #expect(profile.stagnationStatus == .progressing)
        #expect(profile.observedSweetSpot == nil)
    }

    @Test("Round-trip with sweet spot set")
    func roundTrip() throws {
        let original = MuscleProfile(
            muscleGroup: .legs,
            volumeTolerance: 22,
            observedSweetSpot: 14,
            volumeDeficit: 0,
            focusWeight: 1.2,
            stagnationStatus: .plateaued,
            confidence: .established
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MuscleProfile.self, from: data) == original)
    }
}

@Suite("PatternProfile.recentSessionDays")
struct PatternProfileRecentSessionDaysTests {
    @Test("Empty fixture yields empty list")
    func empty() {
        let profile = PatternProfile(pattern: .squat)
        #expect(profile.recentSessionDays == [])
    }

    @Test("Returns yyyy-MM-dd local-date strings sorted ascending")
    func formattedAndSorted() {
        let dates: [Date] = [
            isoDate("2026-05-04"),
            isoDate("2026-05-01"),
            isoDate("2026-04-28"),
        ]
        let profile = PatternProfile(pattern: .squat, recentSessionDates: dates)
        #expect(profile.recentSessionDays == ["2026-04-28", "2026-05-01", "2026-05-04"])
    }
}

@Suite("PatternProfile.sessionsCadenceDays")
struct PatternProfileCadenceTests {
    @Test("Empty / single-session fixture returns nil")
    func tooFew() {
        let empty = PatternProfile(pattern: .squat)
        #expect(empty.sessionsCadenceDays == nil)
        let one = PatternProfile(pattern: .squat, recentSessionDates: [isoDate("2026-05-01")])
        #expect(one.sessionsCadenceDays == nil)
    }

    @Test("Two sessions 3 days apart yields cadence 3.0")
    func twoSessions() {
        let profile = PatternProfile(pattern: .squat, recentSessionDates: [
            isoDate("2026-05-01"), isoDate("2026-05-04"),
        ])
        #expect(profile.sessionsCadenceDays == 3.0)
    }

    @Test("Multiple sessions yield mean delta")
    func multipleSessions() {
        // Deltas: 3, 2, 5 → mean 10/3 ≈ 3.333…
        let profile = PatternProfile(pattern: .squat, recentSessionDates: [
            isoDate("2026-05-01"), isoDate("2026-05-04"),
            isoDate("2026-05-06"), isoDate("2026-05-11"),
        ])
        let cadence = profile.sessionsCadenceDays ?? -1
        #expect(abs(cadence - (10.0 / 3.0)) < 1e-9)
    }
}

@Suite("PatternProfile.daysSinceLastSession")
struct PatternProfileDaysSinceLastTests {
    @Test("Empty fixture yields nil")
    func empty() {
        let profile = PatternProfile(pattern: .squat)
        #expect(profile.daysSinceLastSession(asOf: isoDate("2026-05-04")) == nil)
    }

    @Test("Same-day reference yields 0")
    func sameDay() {
        let profile = PatternProfile(pattern: .squat, recentSessionDates: [isoDate("2026-05-04")])
        #expect(profile.daysSinceLastSession(asOf: isoDate("2026-05-04")) == 0)
    }

    @Test("Reference 5 days after last session yields 5")
    func fiveDaysOut() {
        let profile = PatternProfile(pattern: .squat, recentSessionDates: [isoDate("2026-04-29")])
        #expect(profile.daysSinceLastSession(asOf: isoDate("2026-05-04")) == 5)
    }

    @Test("Future reference (negative delta) clamps to 0")
    func futureReference() {
        let profile = PatternProfile(pattern: .squat, recentSessionDates: [isoDate("2026-05-10")])
        #expect(profile.daysSinceLastSession(asOf: isoDate("2026-05-04")) == 0)
    }
}

@Suite("PatternProfile.inTransitionMode")
struct PatternProfileInTransitionModeTests {
    @Test("Nil transitionModeUntil yields false")
    func nilUntil() {
        let profile = PatternProfile(pattern: .squat)
        #expect(profile.inTransitionMode(asOf: Date()) == false)
    }

    @Test("Future transitionModeUntil yields true")
    func future() {
        let profile = PatternProfile(
            pattern: .squat,
            transitionModeUntil: isoDate("2026-05-10")
        )
        #expect(profile.inTransitionMode(asOf: isoDate("2026-05-04")) == true)
    }

    @Test("Past transitionModeUntil yields false")
    func past() {
        let profile = PatternProfile(
            pattern: .squat,
            transitionModeUntil: isoDate("2026-05-01")
        )
        #expect(profile.inTransitionMode(asOf: isoDate("2026-05-04")) == false)
    }
}

@Suite("PatternProfile Codable")
struct PatternProfileCodableTests {
    @Test("Round-trip preserves all fields")
    func roundTrip() throws {
        let original = PatternProfile(
            pattern: .horizontalPush,
            currentPhase: .intensification,
            sessionsInPhase: 3,
            lastPhaseTransitionAtSessionCount: 22,
            rpeOffset: -0.25,
            recovery: RecoveryProfile(neuromuscularReadiness: 0.7, metabolicReadiness: 0.9),
            confidence: .established,
            transitionModeUntil: isoDate("2026-05-10"),
            trend: .progressing,
            recentSessionDates: [isoDate("2026-04-28"), isoDate("2026-05-01")]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PatternProfile.self, from: data) == original)
    }
}

@Suite("ProjectionState")
struct ProjectionStateTests {
    @Test("Default init: empty + nil timestamps")
    func defaultInit() {
        let state = ProjectionState()
        #expect(state.patternProjections.isEmpty)
        #expect(state.calibrationReviewFiredAt == nil)
        #expect(state.goalLastRenegotiatedAt == nil)
    }

    @Test("Round-trip with multiple pattern projections")
    func roundTrip() throws {
        let original = ProjectionState(
            patternProjections: [
                PatternProjection(pattern: .horizontalPush, floor: 100, stretch: 120, progress: .onTrack),
                PatternProjection(pattern: .squat, floor: 140, stretch: 165, progress: .ahead),
            ],
            calibrationReviewFiredAt: isoDate("2026-04-15"),
            goalLastRenegotiatedAt: nil
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ProjectionState.self, from: data) == original)
    }
}

// MARK: - Helpers

private func isoDate(_ ymd: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: ymd)!
}
