// TraineeModelServiceTests.swift
// ProjectApexTests
//
// Unit tests for TraineeModelService actor (Phase 1 / Slice 10, issue #11).
//
// The actor is the read-side interface to the trainee model — wraps the
// SwiftData local cache (@MainActor TraineeModelLocalStore) and the
// WriteAheadQueue. Public API is read(), digest(), enqueueUpdate(forSession:setLogs:);
// the WAQ flush handler that routes trainee_model_update items to the
// Edge Function lives in TraineeModelUpdateJob. Producer wiring landed in #135.
//
// The class is @MainActor because TraineeModelLocalStore must be created
// and torn down inside an active Swift Concurrency Task — same constraint
// as TraineeModelLocalStoreTests.
//
// Behaviours covered:
//   • read() returns nil when the local cache is empty (cold-start path)
//   • read() returns the cached snapshot after the store is hydrated
//   • digest() returns nil when the local cache is empty (cold-start path)
//   • digest() returns a TraineeModelDigest assembled from the cached model
//   • enqueueUpdate(forSession:setLogs:) appends one item to the WAQ
//   • enqueueUpdate(forSession:setLogs:) targets the trainee_model_updates table
//   • enqueueUpdate(forSession:setLogs:) emits a payload whose decoded JSON shape
//     matches the Edge Function contract { user_id, session_id, session_payload }
//   • session_payload carries logged_at (ISO 8601) + set_logs[] per #135
//   • set_logs entries map SetLog → exercise_id/set_number/weight_kg/reps_completed/intent/rpe_felt
//   • set_logs without an intent are skipped (Edge Function rejects payloads
//     where any element omits intent)

import XCTest
@testable import ProjectApex

// MARK: - URLProtocol that fails every request
//
// Used so the WAQ's automatic flush attempt does not silently drop the
// enqueued item before the test inspects the queue. A 500 response keeps
// the item in queue (with retryCount incremented) — perfect for the
// shape-only assertions this file makes.

private final class TMSAlwaysFailURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500,
            httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeFailingSupabase() -> SupabaseClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TMSAlwaysFailURLProtocol.self]
    return SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
}

// MARK: - TraineeModelServiceTests

@MainActor
final class TraineeModelServiceTests: XCTestCase {

    // MARK: ─── Lifecycle ─────────────────────────────────────────────────────

    private var store: TraineeModelLocalStore!
    private var waq: WriteAheadQueue!
    private var service: TraineeModelService!

    private let userId    = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let programId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let sessionId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let ref = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
        store   = try TraineeModelLocalStore.makeInMemory()
        waq     = WriteAheadQueue(supabase: makeFailingSupabase())
        service = TraineeModelService(store: store, writeAheadQueue: waq, now: { [ref] in ref })
    }

    override func tearDown() async throws {
        // Do NOT call `await waq.clearAll()` here. WAQ.flush() retries failed
        // writes via `queue[0] = item` after each backoff; if clearAll() runs
        // during that suspension window, the index-set crashes with
        // "Index out of range". The fix is to leave any in-flight flush
        // tasks alone — they will exhaust retries against the failing mock
        // and exit on their own — and rely on setUp's UserDefaults clear
        // to ensure no persisted state leaks into the next test.
        service = nil
        waq = nil
        store = nil
        UserDefaults.standard.removeObject(forKey: "com.projectapex.writeAheadQueue")
    }

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private func makeRichModel() -> TraineeModel {
        TraineeModel(
            goal: GoalState(statement: "Strength + size",
                            focusAreas: [.legs, .back],
                            updatedAt: ref),
            patterns: [
                .squat: PatternProfile(
                    pattern: .squat,
                    currentPhase: .accumulation,
                    sessionsInPhase: 4,
                    rpeOffset: -0.5,
                    confidence: .calibrating,
                    recentSessionDates: [ref.addingTimeInterval(-14 * 86400),
                                         ref.addingTimeInterval(-7 * 86400)]
                ),
                .horizontalPush: PatternProfile(
                    pattern: .horizontalPush,
                    currentPhase: .intensification,
                    sessionsInPhase: 6,
                    rpeOffset: 0,
                    confidence: .established,
                    recentSessionDates: [ref.addingTimeInterval(-10 * 86400),
                                         ref.addingTimeInterval(-3 * 86400)]
                ),
            ],
            muscles: [
                .legs: MuscleProfile(muscleGroup: .legs,
                                     volumeTolerance: 14,
                                     volumeDeficit: 2,
                                     focusWeight: 0.6,
                                     confidence: .calibrating)
            ],
            totalSessionCount: 8
        )
    }

    private func makeSession() -> WorkoutSession {
        WorkoutSession(
            id: sessionId,
            userId: userId,
            programId: programId,
            sessionDate: ref,
            weekNumber: 2,
            dayType: "Push A",
            completed: true,
            status: "completed"
        )
    }

    // MARK: ─── read() — cold start vs hydrated ───────────────────────────────

    func test_read_returnsNil_whenStoreEmpty() async {
        let result = await service.read()
        XCTAssertNil(result)
    }

    func test_read_returnsCachedSnapshot_afterSave() async throws {
        let model = makeRichModel()
        try store.save(model)

        let result = await service.read()

        XCTAssertEqual(result, model)
    }

    // MARK: ─── digest() — cold start vs hydrated ─────────────────────────────

    func test_digest_returnsNil_whenStoreEmpty() async {
        let result = await service.digest()
        XCTAssertNil(result)
    }

    func test_digest_returnsAssembledProjection_afterSave() async throws {
        let model = makeRichModel()
        try store.save(model)

        let maybe = await service.digest()
        let digest = try XCTUnwrap(maybe)

        XCTAssertEqual(digest.goal, model.goal)
        XCTAssertEqual(digest.perPatternSummary.count, 2)
        XCTAssertEqual(digest.perMuscleSummary.count, 1)
        // Confidence states surface verbatim — covers the per-axis
        // assembly path the issue calls out specifically.
        let patternConfidences = Set(digest.perPatternSummary.map { $0.confidence })
        XCTAssertEqual(patternConfidences, [.calibrating, .established])
    }

    // MARK: ─── enqueueUpdate(forSession:setLogs:) — WAQ shape ──────────────

    private func makeSetLog(
        setNumber: Int,
        exerciseId: String = "barbell_bench_press",
        weightKg: Double = 100,
        reps: Int = 5,
        rpe: Int? = 8,
        intent: SetIntent? = .top,
        aiPrescribed: SetPrescription? = nil
    ) -> SetLog {
        SetLog(
            id: UUID(),
            sessionId: sessionId,
            exerciseId: exerciseId,
            setNumber: setNumber,
            weightKg: weightKg,
            repsCompleted: reps,
            rpeFelt: rpe,
            rirEstimated: nil,
            aiPrescribed: aiPrescribed,
            loggedAt: ref,
            primaryMuscle: nil,
            intent: intent,
            completionFlags: []
        )
    }

    private func makeSetPrescription(
        reps: Int = 5,
        intent: SetIntent = .top,
        userCorrectedWeight: Bool? = nil
    ) -> SetPrescription {
        SetPrescription(
            weightKg: 100,
            reps: reps,
            tempo: "3-1-1-0",
            rirTarget: 2,
            restSeconds: 180,
            coachingCue: "Drive through heels",
            reasoning: "Top set for strength",
            safetyFlags: [],
            userCorrectedWeight: userCorrectedWeight,
            intent: intent
        )
    }

    func test_enqueueUpdate_appendsOneItemToQueue() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session, setLogs: [])

        let pending = await waq.queue
        XCTAssertEqual(pending.count, 1, "Expected exactly one queued write")
    }

    func test_enqueueUpdate_targetsTraineeModelUpdatesTable() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session, setLogs: [])

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.table, "trainee_model_updates")
    }

    func test_enqueueUpdate_payloadShape_matchesEdgeFunctionContract() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session, setLogs: [])

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)

        // Edge Function (supabase/functions/update-trainee-model/index.ts)
        // expects exactly { user_id, session_id, session_payload } with
        // user_id and session_id as UUID strings and session_payload as a
        // JSON object carrying logged_at (required) and set_logs (optional).
        let json = try JSONSerialization.jsonObject(with: item.payload) as? [String: Any]
        let body = try XCTUnwrap(json)

        XCTAssertEqual((body["user_id"]    as? String)?.lowercased(), userId.uuidString.lowercased())
        XCTAssertEqual((body["session_id"] as? String)?.lowercased(), sessionId.uuidString.lowercased())
        let payload = try XCTUnwrap(body["session_payload"] as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["user_id", "session_id", "session_payload"],
                       "Top-level keys must match Edge Function contract")
        XCTAssertEqual(Set(payload.keys), ["logged_at", "set_logs"],
                       "session_payload must carry logged_at + set_logs")
    }

    func test_enqueueUpdate_sessionPayload_loggedAtIsIso8601String() async throws {
        let session = makeSession()

        try await service.enqueueUpdate(forSession: session, setLogs: [])

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
        let payload = try XCTUnwrap(body["session_payload"] as? [String: Any])
        let loggedAt = try XCTUnwrap(payload["logged_at"] as? String)

        // Edge Function (applySession line 1262) throws if logged_at is not a
        // string parseable by `new Date()`. ISO8601DateFormatter with
        // .withInternetDateTime emits e.g. "2026-05-12T15:30:00Z" — accepted.
        let parsed = ISO8601DateFormatter().date(from: loggedAt)
        XCTAssertNotNil(parsed, "logged_at must parse as ISO 8601 — got \(loggedAt)")
        XCTAssertEqual(parsed, ref, "logged_at must equal the injected now()")
    }

    func test_enqueueUpdate_setLogs_mapsAllFieldsToSnakeCase() async throws {
        let session = makeSession()
        let sets: [SetLog] = [
            makeSetLog(setNumber: 1, exerciseId: "barbell_back_squat",
                       weightKg: 130, reps: 5, rpe: 8, intent: .top),
            makeSetLog(setNumber: 2, exerciseId: "barbell_back_squat",
                       weightKg: 110, reps: 8, rpe: 7, intent: .backoff),
        ]

        try await service.enqueueUpdate(forSession: session, setLogs: sets)

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
        let payload = try XCTUnwrap(body["session_payload"] as? [String: Any])
        let logs = try XCTUnwrap(payload["set_logs"] as? [[String: Any]])

        XCTAssertEqual(logs.count, 2)

        let first = logs[0]
        XCTAssertEqual(first["exercise_id"]    as? String, "barbell_back_squat")
        XCTAssertEqual(first["set_number"]     as? Int,    1)
        XCTAssertEqual(first["weight_kg"]      as? Double, 130)
        XCTAssertEqual(first["reps_completed"] as? Int,    5)
        XCTAssertEqual(first["rpe_felt"]       as? Int,    8)
        XCTAssertEqual(first["intent"]         as? String, "top")

        let second = logs[1]
        XCTAssertEqual(second["intent"] as? String, "backoff")
    }

    // MARK: ─── acknowledgeReassessment — local banner-hide (#258 Slice F1) ──────
    //
    // The goal-review Save (Slice F2) must hide the heavy-reassessment banner
    // immediately. The update-trainee-goal EF returns no model, so the local
    // cache can't refresh from the server; this method is the client-side write
    // that inserts the acknowledged triggeringSessionCount and persists it, after
    // which deriveHeavyReassessmentSignal returns nil for that trigger (the
    // suppression shipped in Slice A).

    /// Builds a model whose GPA fire is inside the cooldown window, so
    /// deriveHeavyReassessmentSignal is non-nil unless the trigger is acked.
    private func makeReassessmentModel(
        lastFired: Int?,
        totalSessions: Int,
        acked: Set<Int> = []
    ) -> TraineeModel {
        TraineeModel(
            goal: GoalState(statement: "Strength + size",
                            focusAreas: [.legs, .back],
                            updatedAt: ref),
            totalSessionCount: totalSessions,
            lastGlobalPhaseAdvanceFiredAtSessionCount: lastFired,
            acknowledgedTriggeringSessionCounts: acked
        )
    }

    func test_acknowledgeReassessment_recordsTrigger_andHidesSignal() async throws {
        // GPA fired at session 5; total is 8 → delta 3, inside the 6-session
        // cooldown window. Empty ack set → signal must be present first.
        try store.save(makeReassessmentModel(lastFired: 5, totalSessions: 8))

        let beforeRead = await service.read()
        let before = try XCTUnwrap(beforeRead)
        XCTAssertNotNil(
            TraineeModelDigest.deriveHeavyReassessmentSignal(from: before),
            "Pre-ack: signal must be present so the banner shows"
        )

        try await service.acknowledgeReassessment(triggeringSessionCount: 5)

        let afterRead = await service.read()
        let after = try XCTUnwrap(afterRead)
        XCTAssertTrue(after.acknowledgedTriggeringSessionCounts.contains(5),
                      "Ack must persist the triggering session count")
        XCTAssertNil(
            TraineeModelDigest.deriveHeavyReassessmentSignal(from: after),
            "Post-ack: signal must vanish — this is the load-bearing banner-hide invariant"
        )
    }

    func test_acknowledgeReassessment_noModel_isNoOp() async throws {
        // Empty store (setUp leaves it empty). Must not throw, must leave nothing.
        try await service.acknowledgeReassessment(triggeringSessionCount: 1)

        let result = await service.read()
        XCTAssertNil(result, "No cached model → ack is a no-op, store stays empty")
    }

    func test_acknowledgeReassessment_isIdempotent() async throws {
        try store.save(makeReassessmentModel(lastFired: 5, totalSessions: 8))

        try await service.acknowledgeReassessment(triggeringSessionCount: 5)
        try await service.acknowledgeReassessment(triggeringSessionCount: 5)

        let afterRead = await service.read()
        let after = try XCTUnwrap(afterRead)
        XCTAssertEqual(after.acknowledgedTriggeringSessionCounts, [5],
                       "Set insert: acking twice must not duplicate or grow the set")
    }

    func test_acknowledgeReassessment_doesNotSuppressLaterFire() async throws {
        // Ack trigger 5, then a NEW GPA fires at session 11 (total 14 → delta 3,
        // inside the window) which has NOT been acked. The signal must return —
        // ack is per-trigger ("current count, not any-ack"), the Slice A contract.
        try store.save(makeReassessmentModel(lastFired: 5, totalSessions: 8))
        try await service.acknowledgeReassessment(triggeringSessionCount: 5)

        let ackedRead = await service.read()
        var model = try XCTUnwrap(ackedRead)
        model.lastGlobalPhaseAdvanceFiredAtSessionCount = 11
        model.totalSessionCount = 14
        try store.save(model)

        let afterRead = await service.read()
        let after = try XCTUnwrap(afterRead)
        XCTAssertTrue(after.acknowledgedTriggeringSessionCounts.contains(5),
                      "The earlier ack of 5 must still be on record")
        XCTAssertNotNil(
            TraineeModelDigest.deriveHeavyReassessmentSignal(from: after),
            "A later, un-acked fire (11) must still surface despite 5 being acked"
        )
    }

    func test_enqueueUpdate_setLogs_skipsEntriesMissingIntent() async throws {
        let session = makeSession()
        // Mix of valid + nil-intent sets — the latter must be filtered out so
        // the Edge Function does not reject the entire payload at validation.
        let sets: [SetLog] = [
            makeSetLog(setNumber: 1, intent: .top),
            makeSetLog(setNumber: 2, intent: nil),
            makeSetLog(setNumber: 3, intent: .backoff),
        ]

        try await service.enqueueUpdate(forSession: session, setLogs: sets)

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
        let payload = try XCTUnwrap(body["session_payload"] as? [String: Any])
        let logs = try XCTUnwrap(payload["set_logs"] as? [[String: Any]])

        XCTAssertEqual(logs.count, 2, "intent=nil sets must be filtered out")
        XCTAssertEqual(logs.map { $0["intent"] as? String }, ["top", "backoff"])
    }

    // MARK: ─── (A) ai_prescribed payload — #369 ──────────────────────────────
    //
    // The Edge Function's applyPrescriptionAccuracy reads set.ai_prescribed as a
    // nested object with `intent`, `reps`, and `user_corrected_weight` fields. The
    // payload struct must carry `ai_prescribed` for the accuracy-learning loop to
    // run. These tests verify the field is present in the encoded JSON when the
    // source SetLog has aiPrescribed, and absent when it does not.

    func test_enqueueUpdate_setLog_withAiPrescribed_encodesObjectInPayload() async throws {
        let session = makeSession()
        let prescription = makeSetPrescription(reps: 5, intent: .top, userCorrectedWeight: false)
        let sets: [SetLog] = [
            makeSetLog(setNumber: 1, intent: .top, aiPrescribed: prescription),
        ]

        try await service.enqueueUpdate(forSession: session, setLogs: sets)

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
        let payload = try XCTUnwrap(body["session_payload"] as? [String: Any])
        let logs = try XCTUnwrap(payload["set_logs"] as? [[String: Any]])
        let first = try XCTUnwrap(logs.first)

        // Edge Function reads set.ai_prescribed as an object — must not be nil.
        let aiPrescribed = try XCTUnwrap(
            first["ai_prescribed"] as? [String: Any],
            "ai_prescribed must be a JSON object — EF gating in applyPrescriptionAccuracy"
        )
        XCTAssertEqual(aiPrescribed["reps"] as? Int, 5,
                       "ai_prescribed.reps must match the prescription's reps (EF reads this to gate accuracy loop)")
        XCTAssertEqual(aiPrescribed["intent"] as? String, "top",
                       "ai_prescribed.intent must be the snake_case raw value")
        // user_corrected_weight is Bool — false is present in the object.
        XCTAssertEqual(aiPrescribed["user_corrected_weight"] as? Bool, false)
    }

    func test_enqueueUpdate_setLog_withoutAiPrescribed_omitsFieldFromPayload() async throws {
        let session = makeSession()
        let sets: [SetLog] = [
            makeSetLog(setNumber: 1, intent: .top, aiPrescribed: nil),
        ]

        try await service.enqueueUpdate(forSession: session, setLogs: sets)

        let pending = await waq.queue
        let item = try XCTUnwrap(pending.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
        let payload = try XCTUnwrap(body["session_payload"] as? [String: Any])
        let logs = try XCTUnwrap(payload["set_logs"] as? [[String: Any]])
        let first = try XCTUnwrap(logs.first)

        // Sets with no prescription must omit the key (EF tolerates absence and
        // skips those sets — the `continue` on line 1226 of index.ts).
        XCTAssertNil(first["ai_prescribed"], "No prescription → field must be absent")
    }

    // MARK: ─── (B) Deload signals fire when ai_prescribed is present — #369 ──

    func test_weekFatigueSignals_deloadSignals_fireWhenAiPrescribedPresent() {
        // 3 sets: each prescribed for 5 reps but only 2 completed (rate = 40% < 60%).
        // This produces 3 significant misses (≥3) AND a rep rate < 75%.
        // Two deload triggers → deloadTriggered must be true.
        // Without aiPrescribed these signals would be absent (repCompletionRate = nil,
        // significantMissCount = 0), and deloadTriggered would be false.
        let prescription = makeSetPrescription(reps: 5, intent: .top)
        let logs = (1...3).map { i in
            SetLog(
                id: UUID(),
                sessionId: sessionId,
                exerciseId: "barbell_back_squat",
                setNumber: i,
                weightKg: 100,
                repsCompleted: 2,       // << well below prescribed 5 reps
                rpeFelt: nil,
                rirEstimated: nil,
                aiPrescribed: prescription,
                loggedAt: ref,
                primaryMuscle: nil,
                intent: .top
            )
        }

        let signals = WeekFatigueSignals.compute(from: logs, sessionCount: 1)

        XCTAssertNotNil(signals.repCompletionRate,
                        "repCompletionRate must be non-nil when ai_prescribed is present")
        XCTAssertEqual(signals.significantMissCount, 3,
                       "All 3 sets complete <60% reps → 3 significant misses")
        let rate = try! XCTUnwrap(signals.repCompletionRate)
        XCTAssertLessThan(rate, 0.75,
                          "Rep rate (2/5 = 40%) must be below deload threshold of 75%")
        XCTAssertTrue(signals.deloadTriggered,
                      "≥2 deload signals (rep_rate < 75% + 3 misses) → deloadTriggered must be true")
    }

    func test_weekFatigueSignals_deloadSignals_absentWhenNoAiPrescribed() {
        // Same actual reps, but no prescription → can't compute rep rate or misses.
        let logs = (1...3).map { i in
            SetLog(
                id: UUID(),
                sessionId: sessionId,
                exerciseId: "barbell_back_squat",
                setNumber: i,
                weightKg: 100,
                repsCompleted: 2,
                rpeFelt: nil,
                rirEstimated: nil,
                aiPrescribed: nil,      // << no prescription
                loggedAt: ref,
                primaryMuscle: nil,
                intent: .top
            )
        }

        let signals = WeekFatigueSignals.compute(from: logs, sessionCount: 1)

        XCTAssertNil(signals.repCompletionRate,
                     "No prescription → repCompletionRate must be nil")
        XCTAssertEqual(signals.significantMissCount, 0,
                       "No prescription → significantMissCount must be 0")
        XCTAssertFalse(signals.deloadTriggered,
                       "Without rep-rate / miss signals, deloadTriggered must be false")
    }
}
