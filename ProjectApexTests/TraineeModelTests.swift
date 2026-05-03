// TraineeModelTests.swift
// ProjectApexTests
//
// Tests for TraineeModel root + derived properties (isReadyForCalibrationReview,
// disruptedPatterns, shouldFireGlobalPhaseAdvance) across empty, single-pattern,
// and fully-populated fixtures + Codable round-trip.

import Testing
import Foundation
@testable import ProjectApex

@Suite("TraineeModel.isReadyForCalibrationReview")
struct TraineeModelCalibrationReadyTests {
    @Test("Empty model: false")
    func empty() {
        let model = TraineeModel(goal: defaultGoal())
        #expect(model.isReadyForCalibrationReview == false)
    }

    @Test("3 major patterns established: false")
    func threeEstablished() {
        var model = TraineeModel(goal: defaultGoal())
        model.patterns = [
            .horizontalPush: PatternProfile(pattern: .horizontalPush, confidence: .established),
            .verticalPush:   PatternProfile(pattern: .verticalPush,   confidence: .established),
            .squat:          PatternProfile(pattern: .squat,          confidence: .established),
        ]
        #expect(model.isReadyForCalibrationReview == false)
    }

    @Test("4 major patterns established + calibration not fired: true")
    func fourEstablishedNotFired() {
        var model = TraineeModel(goal: defaultGoal())
        model.patterns = [
            .horizontalPush:  PatternProfile(pattern: .horizontalPush,  confidence: .established),
            .verticalPush:    PatternProfile(pattern: .verticalPush,    confidence: .established),
            .squat:           PatternProfile(pattern: .squat,           confidence: .established),
            .hipHinge:        PatternProfile(pattern: .hipHinge,        confidence: .established),
        ]
        #expect(model.isReadyForCalibrationReview == true)
    }

    @Test("4 major patterns established but calibration already fired: false")
    func fourEstablishedAlreadyFired() {
        var model = TraineeModel(goal: defaultGoal())
        model.patterns = [
            .horizontalPush:  PatternProfile(pattern: .horizontalPush,  confidence: .established),
            .verticalPush:    PatternProfile(pattern: .verticalPush,    confidence: .established),
            .squat:           PatternProfile(pattern: .squat,           confidence: .established),
            .hipHinge:        PatternProfile(pattern: .hipHinge,        confidence: .established),
        ]
        model.projections = ProjectionState(calibrationReviewFiredAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(model.isReadyForCalibrationReview == false)
    }

    @Test("Established but on auxiliary patterns (lunge, isolation): false")
    func auxiliaryDoesntCount() {
        var model = TraineeModel(goal: defaultGoal())
        model.patterns = [
            .lunge:     PatternProfile(pattern: .lunge,     confidence: .established),
            .isolation: PatternProfile(pattern: .isolation, confidence: .established),
            .squat:     PatternProfile(pattern: .squat,     confidence: .established),
            .hipHinge:  PatternProfile(pattern: .hipHinge,  confidence: .established),
        ]
        // Only 2 of the 6 majors established → false
        #expect(model.isReadyForCalibrationReview == false)
    }
}

@Suite("TraineeModel.disruptedPatterns")
struct TraineeModelDisruptedPatternsTests {
    @Test("Empty model: empty list")
    func empty() {
        let model = TraineeModel(goal: defaultGoal())
        #expect(model.disruptedPatterns(asOf: isoDate("2026-05-04")) == [])
    }

    @Test("Pattern within 2x cadence: not disrupted")
    func withinCadence() {
        var model = TraineeModel(goal: defaultGoal())
        // Cadence ~3 days, last session 4 days ago → 4 < 6 → not disrupted
        model.patterns[.squat] = PatternProfile(pattern: .squat, recentSessionDates: [
            isoDate("2026-04-25"), isoDate("2026-04-28"), isoDate("2026-04-30"),
        ])
        #expect(model.disruptedPatterns(asOf: isoDate("2026-05-04")) == [])
    }

    @Test("Pattern beyond 2x cadence: disrupted")
    func beyondCadence() {
        var model = TraineeModel(goal: defaultGoal())
        // Cadence ~3 days, last session 10 days ago → 10 > 6 → disrupted
        model.patterns[.squat] = PatternProfile(pattern: .squat, recentSessionDates: [
            isoDate("2026-04-18"), isoDate("2026-04-21"), isoDate("2026-04-24"),
        ])
        #expect(model.disruptedPatterns(asOf: isoDate("2026-05-04")) == [.squat])
    }

    @Test("Pattern with insufficient cadence data: not in disrupted list")
    func insufficientData() {
        var model = TraineeModel(goal: defaultGoal())
        // Only one recorded session → no cadence → can't classify as disrupted
        model.patterns[.squat] = PatternProfile(pattern: .squat, recentSessionDates: [
            isoDate("2026-04-01"),
        ])
        #expect(model.disruptedPatterns(asOf: isoDate("2026-05-04")) == [])
    }
}

@Suite("TraineeModel.shouldFireGlobalPhaseAdvance")
struct TraineeModelShouldFireGlobalPhaseAdvanceTests {
    @Test("Empty model: false")
    func empty() {
        let model = TraineeModel(goal: defaultGoal())
        #expect(model.shouldFireGlobalPhaseAdvance == false)
    }

    @Test("3 major patterns transitioned within 6 sessions: false")
    func threeRecent() {
        var model = TraineeModel(goal: defaultGoal())
        model.totalSessionCount = 30
        model.patterns = [
            .horizontalPush: PatternProfile(pattern: .horizontalPush, lastPhaseTransitionAtSessionCount: 28),
            .verticalPush:   PatternProfile(pattern: .verticalPush,   lastPhaseTransitionAtSessionCount: 26),
            .squat:          PatternProfile(pattern: .squat,          lastPhaseTransitionAtSessionCount: 25),
        ]
        #expect(model.shouldFireGlobalPhaseAdvance == false)
    }

    @Test("4 major patterns transitioned within 6 sessions: true")
    func fourRecent() {
        var model = TraineeModel(goal: defaultGoal())
        model.totalSessionCount = 30
        model.patterns = [
            .horizontalPush: PatternProfile(pattern: .horizontalPush, lastPhaseTransitionAtSessionCount: 28),
            .verticalPush:   PatternProfile(pattern: .verticalPush,   lastPhaseTransitionAtSessionCount: 26),
            .squat:          PatternProfile(pattern: .squat,          lastPhaseTransitionAtSessionCount: 25),
            .hipHinge:       PatternProfile(pattern: .hipHinge,       lastPhaseTransitionAtSessionCount: 27),
        ]
        #expect(model.shouldFireGlobalPhaseAdvance == true)
    }

    @Test("4 major patterns transitioned but >6 sessions ago: false")
    func fourTooOld() {
        var model = TraineeModel(goal: defaultGoal())
        model.totalSessionCount = 30
        model.patterns = [
            .horizontalPush: PatternProfile(pattern: .horizontalPush, lastPhaseTransitionAtSessionCount: 20),
            .verticalPush:   PatternProfile(pattern: .verticalPush,   lastPhaseTransitionAtSessionCount: 18),
            .squat:          PatternProfile(pattern: .squat,          lastPhaseTransitionAtSessionCount: 22),
            .hipHinge:       PatternProfile(pattern: .hipHinge,       lastPhaseTransitionAtSessionCount: 21),
        ]
        // All deltas > 6 → none counted
        #expect(model.shouldFireGlobalPhaseAdvance == false)
    }

    @Test("4 major + auxiliary patterns transitioned: only majors count")
    func auxiliaryDoesntCount() {
        var model = TraineeModel(goal: defaultGoal())
        model.totalSessionCount = 30
        model.patterns = [
            .horizontalPush: PatternProfile(pattern: .horizontalPush, lastPhaseTransitionAtSessionCount: 28),
            .verticalPush:   PatternProfile(pattern: .verticalPush,   lastPhaseTransitionAtSessionCount: 26),
            .lunge:          PatternProfile(pattern: .lunge,          lastPhaseTransitionAtSessionCount: 27),
            .isolation:      PatternProfile(pattern: .isolation,      lastPhaseTransitionAtSessionCount: 28),
        ]
        // Only 2 majors recently transitioned → false
        #expect(model.shouldFireGlobalPhaseAdvance == false)
    }
}

@Suite("TraineeModel Codable")
struct TraineeModelCodableTests {
    @Test("Round-trip on a populated fixture preserves all fields")
    func roundTrip() throws {
        var model = TraineeModel(
            goal: GoalState(
                statement: "Get visibly stronger",
                focusAreas: [.chest, .back],
                updatedAt: isoDate("2026-04-01")
            ),
            totalSessionCount: 24
        )
        model.activeProgramId = UUID()
        model.patterns[.squat] = PatternProfile(
            pattern: .squat, currentPhase: .intensification, sessionsInPhase: 4,
            confidence: .established,
            recentSessionDates: [isoDate("2026-04-28"), isoDate("2026-05-01")]
        )
        model.muscles[.legs] = MuscleProfile(muscleGroup: .legs, volumeTolerance: 22)
        model.exercises["barbell_bench_press"] = ExerciseProfile(
            exerciseId: "barbell_bench_press", sessionCount: 12,
            confidence: .established
        )
        model.activeLimitations.append(ActiveLimitation(
            subject: .joint(.shoulder), severity: .mild,
            onsetDate: isoDate("2026-04-15"), evidenceCount: 2, userConfirmed: false
        ))
        model.fatigueInteractions.append(FatigueInteraction(
            fromPattern: .squat, toPattern: .hipHinge,
            observations: [-0.05, -0.06, -0.04], totalCount: 18
        ))
        model.prescriptionAccuracy[.horizontalPush] = [
            .top: PrescriptionAccuracy(
                pattern: .horizontalPush, intent: .top,
                bias: -0.02, rmse: 0.03, sampleCount: 16
            )
        ]
        model.transfers.append(ExerciseTransfer(
            fromExerciseId: "barbell_bench_press", toExerciseId: "overhead_press",
            coefficient: 0.6, rSquared: 0.7, pairedObservations: 8
        ))
        model.bodyweight.entries.append(BodyweightEntry(localDate: "2026-05-04", weightKg: 82))
        model.lifeContextEvents.append(LifeContextEvent(
            localDate: "2026-04-15", kind: "travel", notes: "10 days abroad"
        ))
        model.reassessmentRecords.append(ReassessmentRecord(
            triggeredAt: isoDate("2026-04-20"),
            triggeringSessionCount: 18,
            advancedPatterns: [.horizontalPush, .squat, .verticalPull, .hipHinge]
        ))
        model.projections = ProjectionState(
            patternProjections: [
                PatternProjection(pattern: .squat, floor: 140, stretch: 165, progress: .onTrack),
            ],
            calibrationReviewFiredAt: isoDate("2026-04-15")
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(TraineeModel.self, from: data)
        #expect(decoded == model)
    }

    @Test("Round-trip on an empty-baseline fixture")
    func emptyRoundTrip() throws {
        let model = TraineeModel(goal: defaultGoal())
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(TraineeModel.self, from: data) == model)
    }
}

// MARK: - Helpers

private func defaultGoal() -> GoalState {
    GoalState(statement: "test goal", updatedAt: isoDate("2026-04-01"))
}

private func isoDate(_ ymd: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: ymd)!
}
