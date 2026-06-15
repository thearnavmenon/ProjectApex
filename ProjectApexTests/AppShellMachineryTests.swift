// AppShellMachineryTests.swift
// ProjectApexTests
//
// #376 commit 1/2 — the machinery-lift. AppShell now carries faithful COPIES of the
// machinery the frozen ContentView still owns (the ProgramViewModel lifecycle, the
// onboarding gate, the crash-recovery alert chain, the paused-session resume, and the
// settings root). `useNewShell` STAYS false in this commit, so the machinery is
// exercised ONLY by these tests until the flip (commit 2/2).
//
// The codebase tests pure reducers, not live SwiftUI view closures (no ViewInspector;
// see TodayViewTests / AppShellRouteTests). So the most regression-critical machinery —
// the crash-resume branch decision and the #318 alert-collision gate — is lifted into
// pure functions (`ResumeOutcome.decide`, `AppShell.migrationNoticeShouldArm`) that the
// verbatim view closures call. These tests pin those functions against AppShell:
//
//   • Crash-resume integration — ALL THREE Resume branches (Path A explicit resume,
//     Path B nextIncompleteDay-elsewhere, the not-found/orphaned case) + the
//     VM-not-loaded fallback. A dropped branch silently loses a user's session.
//   • #318 alert-collision regression — the migration notice arms ONLY when no
//     crash-recovery alert won the same launch pass.
//   • The legacy switchToTab bridge routes the live-loop entry + settings correctly.
//   • The launch/setup gate predicate (hoisted into ProjectApexApp ABOVE the
//     useNewShell switch) shows NeedsSetupView when either key is unresolvable.

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Minimal mock LLM provider for service construction

private struct AlwaysThrowingProvider: LLMProvider {
    func complete(systemPrompt: String, userPayload: String) async throws -> String {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - ProgramViewModel factory (mirrors SkipFeatureTests)

/// A ProgramViewModel backed by no-op services. Only pure computation methods
/// (nextIncompleteDay, findTrainingDay) are exercised — no network calls are made.
@MainActor
private func makeViewModel() -> ProgramViewModel {
    let fakeURL = URL(string: "https://localhost")!
    let supabase = SupabaseClient(supabaseURL: fakeURL, anonKey: "test")
    let provider: any LLMProvider = AlwaysThrowingProvider()
    let memory = MemoryService(supabase: supabase, embeddingAPIKey: "test")
    return ProgramViewModel(
        supabaseClient: supabase,
        programGenerationService: ProgramGenerationService(provider: provider),
        macroPlanService: MacroPlanService(provider: provider),
        sessionPlanService: SessionPlanService(
            provider: provider,
            memoryService: memory,
            supabaseClient: supabase
        ),
        userId: UUID()
    )
}

// MARK: - Mesocycle fixture (mirrors SkipFeatureTests)

/// A minimal 2-week mesocycle with 3 training days per week.
private func makeMesocycle(
    week1Statuses: [TrainingDayStatus] = [.generated, .generated, .generated],
    week2Statuses: [TrainingDayStatus] = [.generated, .generated, .generated]
) -> Mesocycle {
    func makeDays(_ statuses: [TrainingDayStatus]) -> [TrainingDay] {
        statuses.enumerated().map { idx, status in
            TrainingDay(
                id: UUID(),
                dayOfWeek: idx + 1,
                dayLabel: "Day \(idx + 1)",
                exercises: [],
                sessionNotes: nil,
                status: status
            )
        }
    }
    let week1 = TrainingWeek(
        id: UUID(), weekNumber: 1, phase: .accumulation,
        trainingDays: makeDays(week1Statuses)
    )
    let week2 = TrainingWeek(
        id: UUID(), weekNumber: 2, phase: .accumulation,
        trainingDays: makeDays(week2Statuses)
    )
    return Mesocycle(
        id: UUID(), userId: UUID(), createdAt: Date(), isActive: true,
        weeks: [week1, week2], totalWeeks: 2, periodizationModel: "linear_periodization"
    )
}

/// A paused-session sentinel pointing at a given training day in a given mesocycle.
private func makeSentinel(
    for day: TrainingDay, in mesocycle: Mesocycle
) -> PausedSessionState {
    PausedSessionState(
        sessionId: UUID(),
        trainingDayId: day.id,
        weekId: mesocycle.weeks[0].id,
        weekNumber: 1,
        exerciseIndex: 0,
        currentSetNumber: 1,
        dayType: day.dayLabel,
        programId: mesocycle.id,
        userId: mesocycle.userId,
        pausedAt: Date()
    )
}

// MARK: - Crash-resume branch decision (the three Resume branches + fallback)

@Suite("AppShell crash-resume — the three Resume branches (#376)")
struct AppShellCrashResumeTests {

    /// PATH A — the paused day IS nextIncompleteDay → pass it as an explicit
    /// resumeState so WorkoutView's Path A fires reliably.
    @MainActor
    @Test("Path A: paused day == nextIncompleteDay → pathA(saved)")
    func resumePathA() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        // The first non-terminal day IS the paused day.
        let pausedDay = meso.weeks[0].trainingDays[0]
        let saved = makeSentinel(for: pausedDay, in: meso)

        let outcome = ResumeOutcome.decide(
            saved: saved,
            viewState: vm.viewState,
            nextIncompleteDay: { vm.nextIncompleteDay(in: meso) },
            findTrainingDay: { vm.findTrainingDay(byId: $0, in: meso) }
        )

        guard case .pathA(let resumeState) = outcome else {
            Issue.record("Expected .pathA, got \(outcome)")
            return
        }
        #expect(resumeState.trainingDayId == pausedDay.id)
    }

    /// PATH B (elsewhere) — the paused day is found in the mesocycle but is NOT
    /// nextIncompleteDay → pass BOTH the resume state and the correct day so
    /// WorkoutView renders the right exercise list (not nextIncompleteDay's).
    @MainActor
    @Test("Path B: paused day found but != nextIncompleteDay → pathBElsewhere(saved, day)")
    func resumePathBElsewhere() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        // nextIncompleteDay is week0/day0; pause a DIFFERENT, later day (week1/day2).
        let nextDay = vm.nextIncompleteDay(in: meso)?.day
        let pausedDay = meso.weeks[1].trainingDays[2]
        #expect(nextDay?.id != pausedDay.id, "fixture must pause a non-next day")
        let saved = makeSentinel(for: pausedDay, in: meso)

        let outcome = ResumeOutcome.decide(
            saved: saved,
            viewState: vm.viewState,
            nextIncompleteDay: { vm.nextIncompleteDay(in: meso) },
            findTrainingDay: { vm.findTrainingDay(byId: $0, in: meso) }
        )

        guard case .pathBElsewhere(let resumeState, let day) = outcome else {
            Issue.record("Expected .pathBElsewhere, got \(outcome)")
            return
        }
        #expect(resumeState.trainingDayId == pausedDay.id)
        #expect(day.id == pausedDay.id, "must carry the CORRECT day, not nextIncompleteDay's")
    }

    /// ORPHANED — the paused day cannot be found anywhere in the mesocycle → show the
    /// orphaned-recovery dialog instead of entering the loop.
    @MainActor
    @Test("Orphaned: paused day not found in mesocycle → orphaned")
    func resumeOrphaned() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.currentMesocycle = meso
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        // A sentinel whose trainingDayId is in NO week of the mesocycle.
        let orphan = TrainingDay(
            id: UUID(), dayOfWeek: 1, dayLabel: "Ghost",
            exercises: [], sessionNotes: nil, status: .paused
        )
        let saved = makeSentinel(for: orphan, in: meso)

        let outcome = ResumeOutcome.decide(
            saved: saved,
            viewState: vm.viewState,
            nextIncompleteDay: { vm.nextIncompleteDay(in: meso) },
            findTrainingDay: { vm.findTrainingDay(byId: $0, in: meso) }
        )

        guard case .orphaned = outcome else {
            Issue.record("Expected .orphaned, got \(outcome)")
            return
        }
    }

    /// FALLBACK — the programme is not loaded yet → fall through to WorkoutView's own
    /// Path B resume (no explicit state passed). Guards the "VM not ready" race.
    @MainActor
    @Test("Not loaded: viewState != .loaded → fallbackToLoop")
    func resumeFallbackWhenNotLoaded() {
        let meso = makeMesocycle()
        let saved = makeSentinel(for: meso.weeks[0].trainingDays[0], in: meso)

        let outcome = ResumeOutcome.decide(
            saved: saved,
            viewState: .loading,   // programme not loaded yet
            nextIncompleteDay: { nil },
            findTrainingDay: { _ in nil }
        )

        guard case .fallbackToLoop = outcome else {
            Issue.record("Expected .fallbackToLoop, got \(outcome)")
            return
        }
    }

    /// FALLBACK — no sentinel at all → fall through (defensive; the alert only arms
    /// when a sentinel exists, but the decision must be safe regardless).
    @MainActor
    @Test("No sentinel → fallbackToLoop")
    func resumeFallbackWhenNoSentinel() {
        let meso = makeMesocycle()
        let vm = makeViewModel()
        vm.viewState = .loaded(meso)
        defer { Mesocycle.clearUserDefaults() }

        let outcome = ResumeOutcome.decide(
            saved: nil,
            viewState: vm.viewState,
            nextIncompleteDay: { vm.nextIncompleteDay(in: meso) },
            findTrainingDay: { vm.findTrainingDay(byId: $0, in: meso) }
        )

        guard case .fallbackToLoop = outcome else {
            Issue.record("Expected .fallbackToLoop, got \(outcome)")
            return
        }
    }
}

// MARK: - #318 alert-collision regression (the migration-notice gate)

@Suite("AppShell #318 alert-collision gate (#376)")
struct AppShellAlertCollisionTests {

    @Test("Crash alert won this launch → migration notice is SUPPRESSED (#318)")
    func migrationSuppressedWhenCrashAlertArmed() {
        // The collision regression: a crash sentinel armed its alert, so the migration
        // notice must NOT also arm in the same pass (SwiftUI would silently drop one).
        #expect(
            AppShell.migrationNoticeShouldArm(
                showOnboarding: false,
                crashAlertArmed: true,
                migrationAlreadyShown: false
            ) == false
        )
    }

    @Test("No crash alert + not yet shown + past onboarding → migration notice arms")
    func migrationArmsWhenClear() {
        #expect(
            AppShell.migrationNoticeShouldArm(
                showOnboarding: false,
                crashAlertArmed: false,
                migrationAlreadyShown: false
            ) == true
        )
    }

    @Test("During onboarding → migration notice never arms")
    func migrationSuppressedDuringOnboarding() {
        #expect(
            AppShell.migrationNoticeShouldArm(
                showOnboarding: true,
                crashAlertArmed: false,
                migrationAlreadyShown: false
            ) == false
        )
    }

    @Test("Already shown once → migration notice does not re-arm")
    func migrationSuppressedWhenAlreadyShown() {
        #expect(
            AppShell.migrationNoticeShouldArm(
                showOnboarding: false,
                crashAlertArmed: false,
                migrationAlreadyShown: true
            ) == false
        )
    }
}

// MARK: - Live-loop bridge + settings + launch/setup gate

@Suite("AppShell live-loop + settings + launch gate (#376)")
struct AppShellMachineryRouteTests {

    /// `presentLiveLoop` handler — the legacy `switchToTab(1)` "Continue Workout" call
    /// site routes to the off-tab live-loop entry (presented over the current surface).
    @Test("switchToTab(1) → presentLiveLoop (the off-tab live-loop entry)")
    func liveLoopRoute() {
        #expect(ShellRoute.from(legacyTab: 1) == .presentLiveLoop)
    }

    /// Settings opens from the corner — the legacy `switchToTab(3)` call site routes to
    /// the settings sheet (the corner gear's presentation).
    @Test("switchToTab(3) → presentSettings (settings opens from the corner)")
    func settingsCornerRoute() {
        #expect(ShellRoute.from(legacyTab: 3) == .presentSettings)
    }

    /// The launch/setup gate, hoisted into ProjectApexApp.body ABOVE the useNewShell
    /// switch (#329 / #369, lifted in #376): the app shows NeedsSetupView when EITHER
    /// required key is unresolvable, and the real root otherwise. These tests call the
    /// PRODUCTION predicate `AppLaunchGate.isSatisfied` directly — not a local
    /// hand-copy — so a change to the gate condition in ProjectApexApp.body is caught
    /// here automatically (follow-up to PR #419 review nit).
    @Test("Launch gate: missing AI key → NeedsSetupView (gate is false)")
    func launchGateMissingAIKey() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: false, hasSupabaseKey: true) == false)
    }

    @Test("Launch gate: missing Supabase key → NeedsSetupView (gate is false)")
    func launchGateMissingSupabaseKey() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: true, hasSupabaseKey: false) == false)
    }

    @Test("Launch gate: both keys missing → NeedsSetupView (gate is false)")
    func launchGateBothMissing() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: false, hasSupabaseKey: false) == false)
    }

    @Test("Launch gate: both keys present → the real root (gate is true)")
    func launchGateBothPresent() {
        #expect(AppLaunchGate.isSatisfied(hasAIKey: true, hasSupabaseKey: true) == true)
    }
}
