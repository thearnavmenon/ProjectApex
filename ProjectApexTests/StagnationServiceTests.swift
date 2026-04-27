// StagnationServiceTests.swift
// ProjectApexTests
//
// Verifies StagnationService.computeSignals() for:
//   1. Improving e1RM → .progressing
//   2. Flat e1RM + RPE present and < 8 → .plateaued (3-session window)
//   3. Flat e1RM + RPE present and ≥ 8 → .progressing (working hard)
//   4. Flat e1RM + RPE nil, only 3 sessions → .progressing (insufficient data)
//   5. Flat e1RM + RPE nil, 4+ sessions → .plateaued (longer streak overrides missing RPE)
//   6. Dropping e1RM + tight gap → .declining
//   7. Dropping e1RM + wide gap → .progressing (scheduled deload spacing)
//   8. Fewer than 3 sessions → .progressing
//   9. Mixed exercises: each evaluated independently
//  10. UserDefaults round-trip: persist then load returns identical signals

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Helpers

/// Builds a minimal SetLog for testing. Defaults keep the call sites short.
private func makeLog(
    sessionId: UUID,
    exerciseId: String,
    weightKg: Double,
    reps: Int,
    rpeFelt: Int?,
    loggedAt: Date
) -> SetLog {
    SetLog(
        id: UUID(),
        sessionId: sessionId,
        exerciseId: exerciseId,
        setNumber: 1,
        weightKg: weightKg,
        repsCompleted: reps,
        rpeFelt: rpeFelt,
        rirEstimated: nil,
        aiPrescribed: nil,
        loggedAt: loggedAt,
        primaryMuscle: nil
    )
}

/// Returns a Date that is `days` days before now.
private func daysAgo(_ days: Double) -> Date {
    Date().addingTimeInterval(-days * 86_400)
}

// MARK: - Suite

@Suite("StagnationService")
struct StagnationServiceTests {

    // MARK: 1 — Improving e1RM → progressing

    @Test("Improving e1RM across 3 sessions → progressing")
    func improvingE1RM() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 60, reps: 5, rpeFelt: 7, loggedAt: daysAgo(14)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 65, reps: 5, rpeFelt: 7, loggedAt: daysAgo(7)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        #expect(signal?.verdict == .progressing)
    }

    // MARK: 2 — Flat e1RM + RPE < 8 → plateaued (3 sessions)

    @Test("Flat e1RM (within 2%) + RPE < 8, 3 sessions → plateaued")
    func flatE1RMWithLowRPE() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        // e1RM ≈ 70 × (1 + 5/30) ≈ 81.7 — all within 2%
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 6, loggedAt: daysAgo(14)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(7)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        #expect(signal?.verdict == .plateaued)
        #expect(signal?.avgRPELast3Sessions != nil)
    }

    // MARK: 3 — Flat e1RM + RPE ≥ 8 → progressing (working hard)

    @Test("Flat e1RM but RPE ≥ 8 → progressing (effort is high)")
    func flatE1RMWithHighRPE() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 9, loggedAt: daysAgo(14)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 8, loggedAt: daysAgo(7)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 9, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        #expect(signal?.verdict == .progressing)
    }

    // MARK: 4 — Flat e1RM + RPE nil, only 3 sessions → progressing

    @Test("Flat e1RM + all RPE nil, only 3 sessions → progressing (nil-RPE threshold not met)")
    func flatE1RMNilRPEThreeSessions() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(14)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(7)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        // avgRPE is nil → 3 sessions not enough without RPE confirmation
        #expect(signal?.verdict == .progressing)
        #expect(signal?.avgRPELast3Sessions == nil)
    }

    // MARK: 5 — Flat e1RM + RPE nil, 4+ sessions → plateaued

    @Test("Flat e1RM + all RPE nil, 4 sessions → plateaued (longer streak overrides missing RPE)")
    func flatE1RMNilRPEFourSessions() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID(); let s4 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(21)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(14)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(7)),
            makeLog(sessionId: s4, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: nil, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        #expect(signal?.verdict == .plateaued)
    }

    // MARK: 6 — Dropping e1RM + tight inter-session gap → declining

    @Test("e1RM dropping ≥5% across 3 sessions with gap < 5 days → declining")
    func decliningE1RM() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        // e1RM: s1 ≈ 81.7, s2 ≈ 77.6 (−5%), s3 ≈ 73.5 (−10% from s1)
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(8)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 66.5, reps: 5, rpeFelt: 7, loggedAt: daysAgo(4)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 63, reps: 5, rpeFelt: 7, loggedAt: daysAgo(1)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        #expect(signal?.verdict == .declining)
    }

    // MARK: 7 — Dropping e1RM but wide gap → progressing (deload spacing)

    @Test("e1RM dropping but inter-session gap ≥ 5 days → progressing (normal deload spacing)")
    func droppingE1RMWithWideGap() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(20)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 66.5, reps: 5, rpeFelt: 7, loggedAt: daysAgo(12)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 63, reps: 5, rpeFelt: 7, loggedAt: daysAgo(4)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        // Wide gap (8 days avg) → not declining
        #expect(signal?.verdict != .declining)
    }

    // MARK: 8 — Fewer than 3 sessions → progressing

    @Test("Fewer than 3 sessions → progressing (insufficient data)")
    func tooFewSessions() {
        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(7)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let signal = signals.first { $0.exerciseId == ex }
        #expect(signal?.verdict == .progressing)
    }

    // MARK: 9 — Mixed exercises: each evaluated independently

    @Test("Mixed exercises — each evaluated independently")
    func mixedExercises() {
        let ex1 = "barbell_bench_press"
        let ex2 = "barbell_row"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let t1 = UUID(); let t2 = UUID(); let t3 = UUID()
        let logs = [
            // ex1: improving
            makeLog(sessionId: s1, exerciseId: ex1, weightKg: 60, reps: 5, rpeFelt: 7, loggedAt: daysAgo(14)),
            makeLog(sessionId: s2, exerciseId: ex1, weightKg: 65, reps: 5, rpeFelt: 7, loggedAt: daysAgo(7)),
            makeLog(sessionId: s3, exerciseId: ex1, weightKg: 70, reps: 5, rpeFelt: 7, loggedAt: daysAgo(2)),
            // ex2: flat + low RPE → plateaued
            makeLog(sessionId: t1, exerciseId: ex2, weightKg: 80, reps: 5, rpeFelt: 6, loggedAt: daysAgo(14)),
            makeLog(sessionId: t2, exerciseId: ex2, weightKg: 80, reps: 5, rpeFelt: 6, loggedAt: daysAgo(7)),
            makeLog(sessionId: t3, exerciseId: ex2, weightKg: 80, reps: 5, rpeFelt: 6, loggedAt: daysAgo(2)),
        ]
        let signals = StagnationService.computeSignals(from: logs)
        let bench = signals.first { $0.exerciseId == ex1 }
        let row   = signals.first { $0.exerciseId == ex2 }
        #expect(bench?.verdict == .progressing)
        #expect(row?.verdict == .plateaued)
    }

    // MARK: 10 — UserDefaults round-trip

    @Test("UserDefaults round-trip: persist then load returns identical signals")
    func userDefaultsRoundTrip() {
        let key = "apex.stagnation_signals"
        // Clear before test
        UserDefaults.standard.removeObject(forKey: key)

        let ex = "barbell_bench_press"
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let logs = [
            makeLog(sessionId: s1, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 6, loggedAt: daysAgo(14)),
            makeLog(sessionId: s2, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 6, loggedAt: daysAgo(7)),
            makeLog(sessionId: s3, exerciseId: ex, weightKg: 70, reps: 5, rpeFelt: 6, loggedAt: daysAgo(2)),
        ]
        let computed = StagnationService.computeSignals(from: logs)
        StagnationService.persist(computed)
        let loaded = StagnationService.load()

        #expect(loaded.count == computed.count)
        #expect(loaded.first?.exerciseId == computed.first?.exerciseId)
        #expect(loaded.first?.verdict == computed.first?.verdict)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: key)
    }
}
