// RegenerateRefusalTests.swift
// ProjectApexTests — #439 (Programme↔Workout audit, Q3 = refuse-and-prompt)
//
// Root defect (STATE-6 / STATE-5): regenerating the programme while a session is
// paused/live mints a fresh mesocycle with new day UUIDs, orphaning the
// `PausedSessionState` sentinel — its `trainingDayId` then points at a TrainingDay
// that no longer exists, producing "Session Not Found" / "Session Mismatch".
//
// Locked decision Q3 = REFUSE: regenerateProgram must NOT mutate the mesocycle or
// mint new UUIDs while a sentinel exists. It surfaces a refusal the UI can show so
// the user is told to finish or abandon the paused session first.
//
//   1. pausedSessionPresent_regenerateRefuses_doesNotMutateMesocycle — sentinel set
//      → currentMesocycle is untouched (same id), the cache is not cleared, and the
//      refusal flag is set.
//   2. noPausedSession_regenerateProceeds — no sentinel → regeneration runs (cache
//      is cleared) and the refusal flag stays clear.

import XCTest
@testable import ProjectApex

final class RegenerateRefusalTests: XCTestCase {

    private struct RegenThrowingProvider: LLMProvider {
        func complete(systemPrompt: String, userPayload: String) async throws -> String {
            throw URLError(.notConnectedToInternet)
        }
    }

    private func makeClient() -> SupabaseClient {
        let config = URLSessionConfiguration.ephemeral
        return SupabaseClient(
            supabaseURL: URL(string: "https://test.supabase.co")!,
            anonKey: "test-anon-key",
            urlSession: URLSession(configuration: config)
        )
    }

    @MainActor
    private func makeViewModel(client: SupabaseClient) -> ProgramViewModel {
        let provider: any LLMProvider = RegenThrowingProvider()
        let memory = MemoryService(supabase: client, embeddingAPIKey: "test")
        return ProgramViewModel(
            supabaseClient: client,
            macroPlanService: MacroPlanService(provider: provider),
            sessionPlanService: SessionPlanService(
                provider: provider,
                memoryService: memory,
                supabaseClient: client
            ),
            userId: AppDependencies.placeholderUserId,
            resolveOwner: { nil }
        )
    }

    private func seedPausedSession() {
        PausedSessionState(
            sessionId: UUID(),
            trainingDayId: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!,
            weekId: UUID(uuidString: "AAAAAAAA-1111-0000-0000-000000000001")!,
            weekNumber: 1,
            exerciseIndex: 0,
            currentSetNumber: 1,
            dayType: "Push_A",
            programId: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!,
            userId: AppDependencies.placeholderUserId,
            pausedAt: Date()
        ).save()
    }

    private var profile: GymProfile {
        GymProfile(
            scanSessionId: "test",
            equipment: [EquipmentItem(equipmentType: .barbell, count: 1, detectedByVision: false)]
        )
    }

    override func setUp() {
        super.setUp()
        PausedSessionState.clear()
        Mesocycle.clearUserDefaults()
    }

    override func tearDown() {
        PausedSessionState.clear()
        Mesocycle.clearUserDefaults()
        super.tearDown()
    }

    // MARK: 1. paused session present → regenerate refuses, mesocycle untouched

    @MainActor
    func test_pausedSessionPresent_regenerateRefuses_doesNotMutateMesocycle() async {
        let original = Mesocycle.mockMesocycle()
        original.saveToUserDefaults()

        let vm = makeViewModel(client: makeClient())
        vm.currentMesocycle = original
        vm.viewState = .loaded(original)

        seedPausedSession()

        await vm.regenerateProgram(gymProfile: profile)

        // The mesocycle must NOT be replaced or mutated — same id, still cached.
        XCTAssertEqual(
            vm.currentMesocycle?.id, original.id,
            "Refusal must leave the existing mesocycle in place (no new UUIDs)."
        )
        XCTAssertEqual(
            Mesocycle.loadFromUserDefaults()?.id, original.id,
            "Refusal must not clear the local mesocycle cache."
        )
        XCTAssertNotNil(
            PausedSessionState.load(),
            "Refusal must not touch the paused-session sentinel."
        )
        XCTAssertTrue(
            vm.regenerationBlockedBySession,
            "Refusal must set a flag the UI can surface."
        )
    }

    // MARK: 2. no paused session → regeneration proceeds, flag stays clear

    @MainActor
    func test_noPausedSession_regenerateProceeds() async {
        let original = Mesocycle.mockMesocycle()
        original.saveToUserDefaults()

        let vm = makeViewModel(client: makeClient())
        vm.currentMesocycle = original
        vm.viewState = .loaded(original)

        // No sentinel seeded.
        await vm.regenerateProgram(gymProfile: profile)

        XCTAssertFalse(
            vm.regenerationBlockedBySession,
            "With no paused session, regeneration must not be blocked."
        )
        // generateMacroSkeleton clears the cache before generating; with a throwing
        // provider it then ends in an error state, but the refusal guard must NOT
        // have short-circuited it — the cache was cleared, proving it ran.
        XCTAssertNil(
            Mesocycle.loadFromUserDefaults(),
            "Regeneration must proceed past the guard and clear the old cache."
        )
    }
}
