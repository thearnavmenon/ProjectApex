// ProgramDayDetailStartGateTests.swift
// ProjectApexTests — #437 / #438 (Programme↔Workout architecture audit, umbrella #435)
//
// #437 (single host, Q1 = CUT non-next starts): only the current pointer day
//   (ProgramViewModel.nextIncompleteDay) is startable from the day-detail view.
//   The "train this day early" / "re-run past session" affordances are removed for
//   non-next days. The DEBUG-only startAnyDayMode override stays.
//
// #438 (live status): the detail view reads the day live from currentMesocycle by id
//   on each render, so a status change (e.g. markDayCompleted) is reflected without a
//   manual refresh. There is no private @State currentDay snapshot to go stale.
//
// These tests drive the two pure seams the view consumes:
//   1. ProgramDayDetailView.isStartableDay(...) — the Q1 start gate.
//   2. The live-read data path — findTrainingDay(byId:) against the mutated
//      currentMesocycle — which is exactly what the view's computed `currentDay` uses.

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Minimal mock LLM provider for service construction

private struct AlwaysThrowingProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
private func makeViewModel() -> ProgramViewModel {
    let fakeURL = URL(string: "https://localhost")!
    let supabase = SupabaseClient(supabaseURL: fakeURL, anonKey: "test")
    let provider: any LLMProvider = AlwaysThrowingProvider()
    let memory = MemoryService(supabase: supabase, embeddingAPIKey: "test")
    return ProgramViewModel(
        supabaseClient: supabase,
        macroPlanService: MacroPlanService(provider: provider),
        sessionPlanService: SessionPlanService(
            provider: provider,
            memoryService: memory,
            supabaseClient: supabase
        ),
        userId: UUID(),
        resolveOwner: { UUID() }
    )
}

private func makeMesocycle(
    week1Statuses: [TrainingDayStatus] = [.generated, .generated, .generated]
) -> Mesocycle {
    let days: [TrainingDay] = week1Statuses.enumerated().map { idx, status in
        TrainingDay(
            id: UUID(),
            dayOfWeek: idx + 1,
            dayLabel: "Day \(idx + 1)",
            exercises: [],
            sessionNotes: nil,
            status: status
        )
    }
    let week1 = TrainingWeek(id: UUID(), weekNumber: 1, phase: .accumulation, trainingDays: days)
    return Mesocycle(
        id: UUID(),
        userId: UUID(),
        createdAt: Date(),
        isActive: true,
        weeks: [week1],
        totalWeeks: 1,
        periodizationModel: "linear_periodization"
    )
}

// MARK: - #437: Q1 start gate

@Suite("ProgramDayDetailView start gate (#437)")
struct ProgramDayDetailStartGateTests {

    @Test("Start is enabled for the current pointer (next-incomplete) day")
    func nextDayIsStartable() {
        let nextId = UUID()
        #expect(ProgramDayDetailView.isStartableDay(
            dayId: nextId,
            nextIncompleteDayId: nextId,
            startAnyDayModeActive: false
        ) == true)
    }

    @Test("Start is DISABLED for a non-next day (cut early/re-run affordances)")
    func nonNextDayIsNotStartable() {
        #expect(ProgramDayDetailView.isStartableDay(
            dayId: UUID(),
            nextIncompleteDayId: UUID(),
            startAnyDayModeActive: false
        ) == false)
    }

    @Test("DEBUG startAnyDayMode override re-enables a non-next day")
    func startAnyDayModeOverridesGate() {
        #expect(ProgramDayDetailView.isStartableDay(
            dayId: UUID(),
            nextIncompleteDayId: UUID(),
            startAnyDayModeActive: true
        ) == true)
    }

    @Test("No pointer (programme complete) → nothing is startable without override")
    func noPointerIsNotStartable() {
        #expect(ProgramDayDetailView.isStartableDay(
            dayId: UUID(),
            nextIncompleteDayId: nil,
            startAnyDayModeActive: false
        ) == false)
    }
}

// MARK: - #446: Skip gate is decoupled from wall-clock DayStatus (Q6)

@Suite("ProgramDayDetailView skip gate (#446)")
struct ProgramDayDetailSkipGateTests {

    @Test("Skip is offered for a generated, unlogged day regardless of calendar position")
    func generatedDayIsSkippable() {
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .generated,
            hasExercises: true
        ) == true)
    }

    @Test("Skip availability does NOT depend on wall-clock DayStatus (past/today/future identical)")
    func skipIsIndependentOfCalendarTime() {
        // The same training-state inputs must yield the same skip availability no matter
        // where the day falls on the calendar — the predicate has no DayStatus parameter,
        // so this is structurally guaranteed: one call covers every calendar position.
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .generated,
            hasExercises: true
        ) == true)
    }

    @Test("Pending days are not skippable (no real session to skip)")
    func pendingDayIsNotSkippable() {
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .pending,
            hasExercises: false
        ) == false)
    }

    @Test("A day with no exercises is not skippable")
    func noExercisesIsNotSkippable() {
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .generated,
            hasExercises: false
        ) == false)
    }

    @Test("Already-skipped days are not re-skippable")
    func skippedDayIsNotSkippable() {
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .skipped,
            hasExercises: true
        ) == false)
    }

    @Test("Completed and paused days are not skippable")
    func completedAndPausedAreNotSkippable() {
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .completed,
            hasExercises: true
        ) == false)
        #expect(ProgramDayDetailView.isSkippableDay(
            status: .paused,
            hasExercises: true
        ) == false)
    }
}

// MARK: - #438: live status read

@Suite("ProgramDayDetailView live status read (#438)")
struct ProgramDayDetailLiveStatusTests {

    @MainActor
    @Test("markDayCompleted is reflected by the live currentMesocycle read")
    func completionIsReflectedLive() {
        let vm = makeViewModel()
        let meso = makeMesocycle()
        vm.currentMesocycle = meso
        let week = meso.weeks[0]
        let day = week.trainingDays[0]

        // Pre-condition: the live read sees the original (.generated) status.
        let before = vm.findTrainingDay(byId: day.id, in: vm.currentMesocycle!)
        #expect(before?.day.status == .generated)

        // The single status writer mutates currentMesocycle.
        vm.markDayCompleted(dayId: day.id, weekId: week.id)

        // The live read (same path the view's computed currentDay uses) now sees .completed
        // without any manual refresh / snapshot copy.
        let after = vm.findTrainingDay(byId: day.id, in: vm.currentMesocycle!)
        #expect(after?.day.status == .completed)
    }
}
