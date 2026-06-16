// ProgressE1RMEligibilityTests.swift
// ProjectApexTests
//
// Tests for the top-set e1RM eligibility filter on ProgressViewModel
// (Tier-1 Progress upgrade — foundation/data layer).
//
// Domain rule (ADR-0005): only intent == .top AND reps in 3...10 contribute
// to e1RM. Warmup/backoff/technique/amrap and out-of-range reps are excluded
// so the trend, PR markers, and headline are honest and agree with the
// server EWMA top-set number. These tests pin that filter so phantom PRs
// (warmup/backoff/out-of-range "PRs") can never resurface.

import Testing
import Foundation
@testable import ProjectApex

@MainActor
private func makeVM() -> ProgressViewModel {
    ProgressViewModel(
        supabaseClient: SupabaseClient(supabaseURL: URL(string: "https://example.invalid")!,
                                       anonKey: "test"),
        userId: UUID()
    )
}

private func makeSetLog(
    sessionId: UUID,
    exerciseId: String = "barbell_bench_press",
    setNumber: Int,
    weightKg: Double,
    reps: Int,
    intent: SetIntent?,
    loggedAt: Date
) -> SetLog {
    SetLog(
        id: UUID(),
        sessionId: sessionId,
        exerciseId: exerciseId,
        setNumber: setNumber,
        weightKg: weightKg,
        repsCompleted: reps,
        rpeFelt: nil,
        rirEstimated: nil,
        aiPrescribed: nil,
        loggedAt: loggedAt,
        primaryMuscle: "chest",
        intent: intent
    )
}

@MainActor
@Suite("Progress e1RM eligibility")
struct ProgressE1RMEligibilityTests {

    // MARK: - Test 1: trend e1RM derives ONLY from eligible top sets

    @Test("Trend e1RM comes only from the eligible top set, not warmup/backoff/out-of-range")
    func trendUsesOnlyEligibleTopSet() {
        let vm = makeVM()
        let sessionId = UUID()
        let date = Date(timeIntervalSince1970: 1_777_818_600)

        // [warmup 60×10, top 100×5, backoff 80×8, top 140×15 (reps out of range)]
        // Only the top 100×5 set is eligible. The heavier 140×15 (reps>10) and
        // the warmup/backoff sets must all be excluded.
        let logs = [
            makeSetLog(sessionId: sessionId, setNumber: 1, weightKg: 60,  reps: 10, intent: .warmup,  loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 2, weightKg: 100, reps: 5,  intent: .top,     loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 3, weightKg: 80,  reps: 8,  intent: .backoff, loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 4, weightKg: 140, reps: 15, intent: .top,     loggedAt: date),
        ]

        let trend = vm.computeTrendData(setLogs: logs, sessionDateMap: [sessionId: date])
        let points = trend["barbell_bench_press"] ?? []

        #expect(points.count == 1)
        // Epley: 100 * (1 + 5/30) ≈ 116.67 — NOT the 140×15 (≈210) phantom.
        let expected = 100.0 * (1.0 + 5.0 / 30.0)
        #expect(abs((points.first?.e1RM ?? 0) - expected) < 0.001)
    }

    @Test("Warmup, backoff, technique, amrap, and reps<3 / reps>10 are all excluded by isE1RMEligible")
    func eligibilityExclusions() {
        let vm = makeVM()
        let sessionId = UUID()
        let date = Date()

        // Eligible: top in 3...10.
        #expect(vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 1, weightKg: 100, reps: 3,  intent: .top, loggedAt: date)))
        #expect(vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 2, weightKg: 100, reps: 10, intent: .top, loggedAt: date)))

        // Excluded intents (even at in-range reps).
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 3, weightKg: 100, reps: 5, intent: .warmup,    loggedAt: date)))
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 4, weightKg: 100, reps: 5, intent: .backoff,   loggedAt: date)))
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 5, weightKg: 100, reps: 5, intent: .technique, loggedAt: date)))
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 6, weightKg: 100, reps: 5, intent: .amrap,     loggedAt: date)))
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 7, weightKg: 100, reps: 5, intent: nil,        loggedAt: date)))

        // Excluded out-of-range reps (even at intent == .top).
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 8, weightKg: 100, reps: 2,  intent: .top, loggedAt: date)))
        #expect(!vm.isE1RMEligible(makeSetLog(sessionId: sessionId, setNumber: 9, weightKg: 100, reps: 11, intent: .top, loggedAt: date)))
    }

    // MARK: - Test 2: a session with no eligible top set produces no trend point

    @Test("A session with no eligible top set produces no trend point")
    func noEligibleSetProducesNoPoint() {
        let vm = makeVM()
        let sessionId = UUID()
        let date = Date(timeIntervalSince1970: 1_777_818_600)

        // Only warmup + backoff + out-of-range — zero eligible top sets.
        let logs = [
            makeSetLog(sessionId: sessionId, setNumber: 1, weightKg: 60,  reps: 10, intent: .warmup,  loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 2, weightKg: 80,  reps: 8,  intent: .backoff, loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 3, weightKg: 140, reps: 15, intent: .top,     loggedAt: date),
        ]

        let trend = vm.computeTrendData(setLogs: logs, sessionDateMap: [sessionId: date])
        // No eligible sets ⇒ the exercise never surfaces a trend point.
        #expect((trend["barbell_bench_press"] ?? []).isEmpty)
    }

    // MARK: - Test 3: computeKeyLifts authoritativeE1RM mapping + filtered currentE1RM

    @Test("computeKeyLifts uses the digest e1rmCurrent for authoritativeE1RM and the top-set-filtered best for currentE1RM")
    func keyLiftsAuthoritativeAndFilteredBest() {
        let vm = makeVM()
        let sessionId = UUID()
        let date = Date()  // recent ⇒ inside the 2-week window

        // chest exercise: warmup 60×10, top 100×5 (eligible), backoff 80×8,
        // top 140×15 (out of range). Filtered best = Epley(100,5) ≈ 116.67.
        let logs = [
            makeSetLog(sessionId: sessionId, setNumber: 1, weightKg: 60,  reps: 10, intent: .warmup,  loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 2, weightKg: 100, reps: 5,  intent: .top,     loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 3, weightKg: 80,  reps: 8,  intent: .backoff, loggedAt: date),
            makeSetLog(sessionId: sessionId, setNumber: 4, weightKg: 140, reps: 15, intent: .top,     loggedAt: date),
        ]

        // ExerciseSummary's only public init projects from an ExerciseProfile,
        // so build one with the digest's authoritative e1rmCurrent.
        let summary = ExerciseSummary(profile: ExerciseProfile(
            exerciseId: "barbell_bench_press",
            e1rmCurrent: 123.45,
            sessionCount: 7,
            confidence: .calibrating
        ))

        // With a matching digest entry → authoritativeE1RM == e1rmCurrent.
        let withSummary = vm.computeKeyLifts(
            setLogs: logs,
            sessionDateMap: [sessionId: date],
            exerciseSummaries: ["barbell_bench_press": summary]
        )
        let benchWith = withSummary.first { $0.exerciseId == "barbell_bench_press" }
        #expect(benchWith != nil)
        #expect(benchWith?.authoritativeE1RM == 123.45)
        // currentE1RM is the top-set-filtered computed best (≈116.67), NOT 140×15.
        let expectedFiltered = 100.0 * (1.0 + 5.0 / 30.0)
        #expect(abs((benchWith?.currentE1RM ?? 0) - expectedFiltered) < 0.001)

        // Without a matching digest entry → authoritativeE1RM == nil.
        let withoutSummary = vm.computeKeyLifts(
            setLogs: logs,
            sessionDateMap: [sessionId: date],
            exerciseSummaries: [:]
        )
        let benchWithout = withoutSummary.first { $0.exerciseId == "barbell_bench_press" }
        #expect(benchWithout != nil)
        #expect(benchWithout?.authoritativeE1RM == nil)
        #expect(abs((benchWithout?.currentE1RM ?? 0) - expectedFiltered) < 0.001)
    }

    // MARK: - Test 4: a bootstrapped summary with e1rmCurrent == 0 is treated as absent

    @Test("A digest summary with e1rmCurrent == 0 does NOT override the client number (no 0.0 headline)")
    func zeroAuthoritativeFallsBackToClientBest() {
        let vm = makeVM()
        let sessionId = UUID()
        let date = Date()

        // Eligible top set ⇒ client computes a real currentE1RM (≈116.67).
        let logs = [
            makeSetLog(sessionId: sessionId, setNumber: 1, weightKg: 100, reps: 5, intent: .top, loggedAt: date),
        ]

        // A freshly-bootstrapped profile: tracked (sessionCount >= 1) but no
        // eligible top set has produced an EWMA yet ⇒ e1rmCurrent == 0.
        let zeroSummary = ExerciseSummary(profile: ExerciseProfile(
            exerciseId: "barbell_bench_press",
            e1rmCurrent: 0,
            sessionCount: 3,
            confidence: .calibrating
        ))

        let lifts = vm.computeKeyLifts(
            setLogs: logs,
            sessionDateMap: [sessionId: date],
            exerciseSummaries: ["barbell_bench_press": zeroSummary]
        )
        let bench = lifts.first { $0.exerciseId == "barbell_bench_press" }
        #expect(bench != nil)
        // Non-positive authoritative is treated as absent → nil, so the view's
        // `authoritativeE1RM ?? currentE1RM` falls back to the real client best.
        #expect(bench?.authoritativeE1RM == nil)
        let expectedFiltered = 100.0 * (1.0 + 5.0 / 30.0)
        #expect(abs((bench?.currentE1RM ?? 0) - expectedFiltered) < 0.001)
    }

    // MARK: - Test 5: the 4-week delta is anchored to the displayed (authoritative) value

    @Test("deltaVs4WeeksAgo is computed from the displayed authoritative value, not the Epley best")
    func deltaAnchoredToDisplayedValue() {
        let vm = makeVM()
        let recentSession = UUID()
        let referenceSession = UUID()
        let now = Date()
        let fiveWeeksAgo = now.addingTimeInterval(-35 * 86_400)  // inside [4wk, 6wk)

        let logs = [
            // recent eligible top set: Epley(100,5) ≈ 116.67 → currentE1RM
            makeSetLog(sessionId: recentSession, setNumber: 1, weightKg: 100, reps: 5, intent: .top, loggedAt: now),
            // 5-weeks-ago eligible top set: Epley(90,5) = 105.0 → referenceBest
            makeSetLog(sessionId: referenceSession, setNumber: 1, weightKg: 90, reps: 5, intent: .top, loggedAt: fiveWeeksAgo),
        ]

        // Authoritative EWMA (110) differs from BOTH the recent Epley best (116.67)
        // and the reference best (105) — so we can tell which "now" the delta uses.
        let summary = ExerciseSummary(profile: ExerciseProfile(
            exerciseId: "barbell_bench_press",
            e1rmCurrent: 110.0,
            sessionCount: 15,
            confidence: .established
        ))

        let lifts = vm.computeKeyLifts(
            setLogs: logs,
            sessionDateMap: [recentSession: now, referenceSession: fiveWeeksAgo],
            exerciseSummaries: ["barbell_bench_press": summary]
        )
        let bench = lifts.first { $0.exerciseId == "barbell_bench_press" }
        #expect(bench != nil)
        #expect(bench?.authoritativeE1RM == 110.0)
        // Delta must be displayValue(110) − referenceBest(105) = 5.0,
        // NOT the Epley recent best(116.67) − 105 = 11.67.
        #expect(abs((bench?.deltaVs4WeeksAgo ?? 0) - 5.0) < 0.001)
    }
}
