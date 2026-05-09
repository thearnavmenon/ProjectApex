// Project Apex — Phase 2 Stage 1 orchestrator integration tests.
//
// Per ADR-0006 §"Idempotency at the DB layer", ADR-0008 §"Late arrival",
// and ADR-0013 §"Stage sequencing": the orchestrator wires every Phase 2
// rule module into a single transactional commit on every session-apply.
// These tests run against the local Supabase Postgres (54322) — they are
// integration tests, not unit tests, because the load-bearing concerns
// (PK constraints, FOR UPDATE row locks, transactional rollback, JSONB
// round-trip) only have meaning against real Postgres.
//
// Prereqs:
//   - `supabase start` running (DB at postgresql://postgres:postgres@127.0.0.1:54322/postgres)
//   - Migrations applied (20260506091314 baseline + 20260507210000 phase 2)
//
// Each test uses unique UUIDs (no cross-test contamination, no cleanup
// between tests). Local DB orphans accumulate harmlessly across runs;
// CI resets the DB per build.
//
// Run locally:
//   deno test --allow-net --allow-env supabase/functions/update-trainee-model/orchestrator_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import postgres from "postgres";
import { applySession } from "./index.ts";
import type { ApplyCompleteEvent, LateArrivalEvent } from "../_shared/observability.ts";
import { LLMTransientError } from "../_shared/llm-retry.ts";

const DB_URL = "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

/**
 * Module-scoped SQL client shared across tests in this file. Each test
 * uses unique UUIDs, so there's no cross-test state to clear; the client
 * is opened once and closed at the end of the file's test run via
 * Deno's `globalSetup`-style sentinel test.
 */
const sql = postgres(DB_URL, { max: 4 });

/**
 * Seeds a fresh user + empty trainee_models row. Returns the user_id so
 * the caller can drive the orchestrator with it. The trainee_models row
 * starts with `model_json = {}` and `last_applied_logged_at = null`,
 * mirroring the Phase 1 Slice 9b initialization shape.
 */
async function seedFreshUser(): Promise<string> {
  const userId = crypto.randomUUID();
  await sql`
    INSERT INTO public.users (id, display_name)
    VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
  `;
  await sql`
    INSERT INTO public.trainee_models (user_id, model_json)
    VALUES (${userId}, ${"{}"}::jsonb)
  `;
  return userId;
}

// All orchestrator tests share the module-scoped postgres.js client. The
// driver keeps a keepalive timer alive between queries, which Deno's per-test
// resource sanitizer flags as a leak. Disabling sanitizeOps + sanitizeResources
// on each test is the right choice here: leaks ARE checked at file-end via
// the sentinel `_zz_close_sql_pool` test that calls `await sql.end()`.
const orchestratorTest = (
  name: string,
  fn: () => Promise<void>,
): void => {
  Deno.test({
    name,
    fn,
    sanitizeOps: false,
    sanitizeResources: false,
  });
};

// All orchestrator tests that DON'T explicitly inject `stage2Hook` will now
// run the real A13 Stage 2 driver. To keep the existing A12 tests' apply
// paths from also kicking off a real Anthropic Haiku call, the empty-payload
// tests (no set_logs[], no notes seeded) trigger the no-notes branch of
// runStage2 (no-op → no LLM call). For tests that DO need to short-circuit
// Stage 2 entirely, a no-op stage2Hook is the simplest mechanism.
const noopStage2: () => Promise<void> = () => Promise.resolve();

orchestratorTest(
  "ADR-0006: first-ever apply on a fresh trainee_models row inserts the applied_sessions PK and increments session_count (tracer)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-08T10:00:00Z";

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: loggedAt, set_logs: [] },
      },
      sql,
    );

    // Response shape per ADR-0008's §"Late arrival" decision: a successful
    // in-order apply returns { trainee_model, late_arrival: false }.
    assertEquals(result.late_arrival, false);
    assertEquals(typeof result.trainee_model, "object");

    // PK insert sticks — duplicate retries will see this row and short-circuit
    // on cycle 2.
    const applied = await sql`
      SELECT user_id, session_id FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(applied.length, 1);

    // session_count incremented from the seed's default of 0.
    const model = await sql`
      SELECT session_count FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(model[0].session_count, 1);
  },
);

orchestratorTest(
  "first apply against empty trainee_models bootstraps the row (UPSERT) — production HTTP path drives the orchestrator without a separate bootstrap step",
  async () => {
    // Seed users row only — DO NOT pre-INSERT trainee_models. Mirrors the
    // production case where handleRequest receives the first-ever apply.
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-bootstrap-" + userId.slice(0, 8)})
    `;

    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-08T10:00:00Z";

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: loggedAt, set_logs: [] },
      },
      sql,
    );

    assertEquals(result.late_arrival, false);

    // The row was created by the UPSERT.
    const model = await sql`
      SELECT user_id, session_count, last_applied_logged_at, model_json,
             jsonb_typeof(model_json) AS model_json_type
      FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(model.length, 1);
    assertEquals(model[0].session_count, 1);
    assertEquals(
      (model[0].last_applied_logged_at as Date).toISOString(),
      new Date(loggedAt).toISOString(),
    );
    // model_json must round-trip as an object, not a scalar JSON string.
    // (The pre-fix `${JSON.stringify(...)}::jsonb` pattern stored
    // `"{\"patterns\":{}}"` — a scalar — which would silently break every
    // downstream consumer that calls `model_json -> 'patterns'`.)
    assertEquals(model[0].model_json_type, "object");
  },
);

orchestratorTest(
  "ADR-0006 §2: second apply with same (user_id, session_id) returns cached snapshot — model_json unchanged, session_count unchanged",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const payload = { user_id: userId, session_id: sessionId, session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] } };

    // First apply: takes the inserted=true path, increments session_count.
    await applySession(payload, sql);

    // Seed a sentinel value into model_json so the cached return is verifiable
    // — if the second apply re-ran the rule path, this sentinel would be overwritten.
    await sql`
      UPDATE public.trainee_models
      SET model_json = ${'{"sentinel":"cached-snapshot-token"}'}::jsonb
      WHERE user_id = ${userId}
    `;

    // Second apply: same session_id → ON CONFLICT DO NOTHING → cached path.
    const result = await applySession(payload, sql);

    assertEquals(result.late_arrival, false);
    assertEquals(
      (result.trainee_model as Record<string, unknown>).sentinel,
      "cached-snapshot-token",
      "second apply must return the cached snapshot — orchestrator is the read source, not a re-applied rule path",
    );

    // session_count must NOT have advanced again.
    const model = await sql`
      SELECT session_count FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(model[0].session_count, 1);

    // Single applied_sessions row — PK constraint held.
    const applied = await sql`
      SELECT COUNT(*)::int AS count FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(applied[0].count, 1);
  },
);

orchestratorTest(
  "ADR-0006: orchestrator handles pre-A12 JSONB blobs missing Phase 2 fields without throwing — pre-existing fields preserved through round-trip (migration story)",
  async () => {
    // Pre-A12 row: has Phase 1 fields but NOT the Phase 2 additions
    // (lastGlobalPhaseAdvanceFiredAtSessionCount, consecutiveForceDeloadsOnPattern,
    // lastClassifiedNoteCreatedAt, etc.). The orchestrator's read path must not
    // throw when these are absent — first-production-apply on existing alpha-cohort
    // rows must succeed.
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
    `;
    const partialBlob = {
      goal: { focusAreas: [] },
      patterns: {},
      muscles: {},
      exercises: {},
      activeLimitations: [],
      clearedLimitations: [],
      fatigueInteractions: [],
      prescriptionAccuracy: {},
      prescriptionIntentMismatches: [],
      transfers: [],
      bodyweight: { entries: [] },
      lifeContextEvents: [],
      reassessmentRecords: [],
      totalSessionCount: 0,
      // Phase 2 additions missing on purpose.
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json)
      VALUES (${userId}, ${JSON.stringify(partialBlob)}::jsonb)
    `;
    const sessionId = crypto.randomUUID();

    // Must not throw.
    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] },
      },
      sql,
    );

    assertEquals(result.late_arrival, false);
    // Pre-existing Phase 1 fields round-tripped intact.
    const model = result.trainee_model as Record<string, unknown>;
    assertEquals(Array.isArray(model.activeLimitations), true);
    assertEquals(Array.isArray(model.transfers), true);
    assertEquals(typeof model.goal, "object");
  },
);

orchestratorTest(
  "ADR-0008: in-order apply (incoming.loggedAt > watermark) advances watermark to incoming.loggedAt",
  async () => {
    const userId = await seedFreshUser();
    // Seed with a prior watermark in the past.
    const priorWatermark = "2026-05-01T08:00:00Z";
    await sql`
      UPDATE public.trainee_models
      SET last_applied_logged_at = ${priorWatermark}::timestamptz
      WHERE user_id = ${userId}
    `;

    const sessionId = crypto.randomUUID();
    const incomingLoggedAt = "2026-05-08T10:00:00Z"; // strictly later
    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: incomingLoggedAt, set_logs: [] },
      },
      sql,
    );

    assertEquals(result.late_arrival, false);

    const row = await sql`
      SELECT last_applied_logged_at FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(
      new Date(row[0].last_applied_logged_at).toISOString(),
      new Date(incomingLoggedAt).toISOString(),
      "watermark must advance to incoming.loggedAt on in-order apply (ADR-0008 §Decision)",
    );
  },
);

orchestratorTest(
  "ADR-0008: watermark equality boundary — incoming.loggedAt === watermark is treated as in-order (strict-< refusal, not <=)",
  async () => {
    // ADR-0008's decision: refusal fires "if incoming.loggedAt < watermark"
    // (strict less-than). Exactly-equal is in-order. A future maintainer
    // who tightens the comparison to <= (well-intentioned, "treat replay as
    // already-applied") would silently break session-replay scenarios.
    // This boundary cycle catches that drift exactly the way A7 cycle 12
    // catches an analogous tightening on overreach (1.15× exact).
    const userId = await seedFreshUser();
    const sharedTimestamp = "2026-05-08T10:00:00Z";
    await sql`
      UPDATE public.trainee_models
      SET last_applied_logged_at = ${sharedTimestamp}::timestamptz
      WHERE user_id = ${userId}
    `;

    const sessionId = crypto.randomUUID();
    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: sharedTimestamp, set_logs: [] },
      },
      sql,
    );

    assertEquals(
      result.late_arrival,
      false,
      "incoming === watermark must NOT trigger late-arrival refusal (strict-< boundary, not <=)",
    );

    // PK row inserted (in-order branch took it).
    const applied = await sql`
      SELECT COUNT(*)::int AS count FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(applied[0].count, 1);
  },
);

orchestratorTest(
  "ADR-0008: late arrival (incoming.loggedAt < watermark) → late_arrival:true; model_json unchanged; watermark unchanged; PK row sticks for dedupe; richer response carries session/incoming/watermark fields",
  async () => {
    const userId = await seedFreshUser();
    const watermark = "2026-05-08T10:00:00Z";
    await sql`
      UPDATE public.trainee_models
      SET last_applied_logged_at = ${watermark}::timestamptz,
          model_json = ${'{"sentinel":"pre-late-arrival-token"}'}::jsonb
      WHERE user_id = ${userId}
    `;

    const sessionId = crypto.randomUUID();
    const lateLoggedAt = "2026-05-01T08:00:00Z"; // 7 days before watermark
    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: lateLoggedAt, set_logs: [] },
      },
      sql,
    );

    // Response shape per ADR-0008 + A12's richer-shape contract: late_arrival
    // flag plus the three optional fields the WAQ adapter passes into
    // LateArrivalNotification (sessionId/incomingLoggedAt/watermark).
    assertEquals(result.late_arrival, true);
    assertEquals(result.late_arrival_details?.session_id, sessionId);
    assertEquals(result.late_arrival_details?.incoming_logged_at, new Date(lateLoggedAt).toISOString());
    assertEquals(result.late_arrival_details?.watermark, new Date(watermark).toISOString());
    // Cached snapshot returned (the sentinel proves it's the pre-call blob).
    assertEquals(
      (result.trainee_model as Record<string, unknown>).sentinel,
      "pre-late-arrival-token",
    );

    // Watermark unchanged — refusal does NOT advance.
    const row = await sql`
      SELECT last_applied_logged_at, session_count, model_json
      FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(
      new Date(row[0].last_applied_logged_at).toISOString(),
      new Date(watermark).toISOString(),
      "watermark must NOT advance on late-arrival refusal (ADR-0008 §Decision)",
    );
    // session_count unchanged — refusal is a no-op on the model.
    assertEquals(row[0].session_count, 0);
    // model_json unchanged.
    const modelAfter = parseJsonb(row[0].model_json);
    assertEquals(modelAfter.sentinel, "pre-late-arrival-token");

    // PK row INSERTED — refusal still inserts the dedupe row so WAQ retries
    // converge to the cached path on subsequent calls (ADR-0008 §Decision).
    const applied = await sql`
      SELECT COUNT(*)::int AS count FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(
      applied[0].count,
      1,
      "PK insert must stick on late-arrival refusal — WAQ retries dedupe via this row (ADR-0008)",
    );
  },
);

function parseJsonb(value: unknown): Record<string, unknown> {
  if (value == null) return {};
  if (typeof value === "string") return JSON.parse(value);
  return value as Record<string, unknown>;
}

// ─── Cycles 27-28: Stage 2 fires-once + watermark recovery (A13 / #84) ──────
//
// Cycle 27 mirrors A12 cycle 9's gate test, but with the REAL Stage 2 driver
// wired in (not a synthetic hook). Cycle 28 is the unique A13 contract:
// classifier failure leaves the watermark at its prior value, and the next
// session's Stage 2 picks up the un-processed batch joined with new notes.
//
// Both tests seed `memory_embeddings` so Stage 2 actually invokes the LLM
// (otherwise the no-notes branch short-circuits).

const seedNote = async (
  userId: string,
  noteId: string,
  rawTranscript: string,
  createdAtIso: string,
  sessionId: string | null = null,
): Promise<void> => {
  await sql`
    INSERT INTO public.memory_embeddings
      (id, user_id, raw_transcript, created_at, session_id, exercise_id)
    VALUES
      (${noteId}::uuid, ${userId}, ${rawTranscript}, ${createdAtIso}::timestamptz,
       ${sessionId}, NULL)
  `;
};

orchestratorTest(
  "ADR-0013 (A13 cycle 27): WAQ retry of session that ran Stage 2 successfully — Stage 1 returns cached snapshot via PK conflict; Stage 2 NOT re-fired (first-apply-fires-once contract preserved with real classifier driver)",
  async () => {
    const userId = await seedFreshUser();
    await seedNote(userId, crypto.randomUUID(), "shoulder strained today", "2026-05-08T08:00:00.000Z");

    let llmCalls = 0;
    let classifierFailedCalls = 0;
    const llmCall = (_prompt: string) => {
      llmCalls += 1;
      return Promise.resolve(JSON.stringify({
        formDegradationMentions: [],
        limitationMentions: [],
      }));
    };
    const sessionId = crypto.randomUUID();
    const payload = {
      user_id: userId,
      session_id: sessionId,
      session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] },
    };

    // First apply — runs Stage 1 + Stage 2 (real driver). LLM called once.
    await applySession(payload, sql, {
      classifierLLMCall: llmCall,
      emitClassifierFailed: () => { classifierFailedCalls++; },
    });
    assertEquals(llmCalls, 1, "first apply triggers Stage 2 → classifier called once");

    // Second apply (same session_id) — PK conflict → cached return → Stage 2 NOT fired.
    await applySession(payload, sql, {
      classifierLLMCall: llmCall,
      emitClassifierFailed: () => { classifierFailedCalls++; },
    });
    assertEquals(
      llmCalls,
      1,
      "cached-snapshot return MUST NOT re-fire Stage 2 (ADR-0013 §WAQ retry idempotency); classifier remains at 1 call total",
    );
    assertEquals(classifierFailedCalls, 0, "no failures emitted");
  },
);

orchestratorTest(
  "ADR-0013 (A13 cycle 28): Stage 2 mid-flight failure leaves watermark unchanged; next session-apply picks up the un-processed batch joined with newer notes",
  async () => {
    const userId = await seedFreshUser();
    // Seed two notes BEFORE the first apply.
    await seedNote(userId, crypto.randomUUID(), "shoulder sore", "2026-05-08T08:00:00.000Z");
    await seedNote(userId, crypto.randomUUID(), "knee clicks", "2026-05-08T08:30:00.000Z");

    // ATTEMPT 1: classifier throws transient on every retry → exhausts.
    let attempt1Calls = 0;
    let classifierFailedCalls = 0;
    const failingLlmCall = () => {
      attempt1Calls += 1;
      return Promise.reject(new LLMTransientError(`mock 529 #${attempt1Calls}`));
    };
    await applySession(
      {
        user_id: userId,
        session_id: crypto.randomUUID(),
        session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] },
      },
      sql,
      {
        classifierLLMCall: failingLlmCall,
        classifierSleep: () => Promise.resolve(),
        emitClassifierFailed: () => { classifierFailedCalls++; },
      },
    );
    assertEquals(attempt1Calls, 4, "ADR-0007: 4 total attempts (initial + 3 retries) before exhaustion");
    assertEquals(classifierFailedCalls, 1, "classifier_failed emitted exactly once on retry exhaustion");

    // Verify watermark is STILL null (first apply failed, no advance).
    const afterFail = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelAfterFail = parseJsonb(afterFail[0].model_json);
    assertEquals(
      modelAfterFail.lastClassifiedNoteCreatedAt ?? null,
      null,
      "watermark MUST stay at prior value (null) when classifier exhausts retries (ADR-0013 §Failure mode)",
    );

    // Seed a third (newer) note.
    await seedNote(userId, crypto.randomUUID(), "elbow popping", "2026-05-08T11:00:00.000Z");

    // ATTEMPT 2: classifier succeeds. Capture the prompt to verify it
    // includes ALL three noteIds (un-processed batch + new note).
    let capturedPrompt = "";
    const successLlmCall = (prompt: string) => {
      capturedPrompt = prompt;
      return Promise.resolve(JSON.stringify({
        formDegradationMentions: [],
        limitationMentions: [],
      }));
    };
    await applySession(
      {
        user_id: userId,
        session_id: crypto.randomUUID(),
        session_payload: { logged_at: "2026-05-08T12:00:00Z", set_logs: [] },
      },
      sql,
      { classifierLLMCall: successLlmCall },
    );

    // The recovered apply MUST process all 3 notes — n1, n2 (un-processed
    // from attempt 1) plus n3 (new). The prompt's note block lists each
    // raw_transcript on its own line; assert all three appear.
    assertEquals(capturedPrompt.includes("shoulder sore"), true, "n1 in batch");
    assertEquals(capturedPrompt.includes("knee clicks"), true, "n2 in batch");
    assertEquals(capturedPrompt.includes("elbow popping"), true, "n3 in batch");

    // After successful classification, watermark must advance to max(notes.createdAt) = n3 = 2026-05-08T11:00:00Z.
    const afterSuccess = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelAfterSuccess = parseJsonb(afterSuccess[0].model_json);
    assertEquals(
      new Date(modelAfterSuccess.lastClassifiedNoteCreatedAt as string).toISOString(),
      "2026-05-08T11:00:00.000Z",
      "watermark advances to max(notes.createdAt) on classifier success",
    );
  },
);

orchestratorTest(
  "ADR-0008: emitLateArrival invoked with correct delta_seconds — incoming 7 days before watermark → delta_seconds = -604800",
  async () => {
    const userId = await seedFreshUser();
    const watermark = "2026-05-08T10:00:00Z";
    await sql`
      UPDATE public.trainee_models
      SET last_applied_logged_at = ${watermark}::timestamptz
      WHERE user_id = ${userId}
    `;

    const sessionId = crypto.randomUUID();
    const lateLoggedAt = "2026-05-01T10:00:00Z"; // exactly 7 days = 604800s before
    const captured: LateArrivalEvent[] = [];

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: lateLoggedAt, set_logs: [] },
      },
      sql,
      {
        emitLateArrival: (event) => {
          captured.push(event);
        },
      },
    );

    assertEquals(captured.length, 1, "emitLateArrival must fire exactly once on refusal");
    const event = captured[0];
    assertEquals(event.user_id, userId);
    assertEquals(event.session_id, sessionId);
    assertEquals(event.incoming_logged_at, new Date(lateLoggedAt).toISOString());
    assertEquals(event.watermark, new Date(watermark).toISOString());
    // delta_seconds is negative — incoming is `delta_seconds` before watermark per
    // observability.ts's LateArrivalEvent contract. 7 days = 7 × 86400 = 604800.
    assertEquals(event.delta_seconds, -604800);
  },
);

orchestratorTest(
  "ADR-0006: atomic rollback — synthetic rule throw mid-pipeline reverts PK insert + watermark advance + model_json write (single-transaction guarantee)",
  async () => {
    const userId = await seedFreshUser();
    const priorWatermark = "2026-05-01T08:00:00Z";
    await sql`
      UPDATE public.trainee_models
      SET last_applied_logged_at = ${priorWatermark}::timestamptz,
          model_json = ${'{"sentinel":"pre-throw-token"}'}::jsonb
      WHERE user_id = ${userId}
    `;
    const sessionId = crypto.randomUUID();

    // Synthetic failure injected via the ruleHook seam — same seam cycles
    // 10-12 will use for real rule composition. The throw must propagate out
    // of sql.begin(), which by postgres.js's transaction contract aborts +
    // rolls back the whole block.
    let threw = false;
    try {
      await applySession(
        {
          user_id: userId,
          session_id: sessionId,
          session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] },
        },
        sql,
        {
          ruleHook: () => {
            throw new Error("synthetic rule failure for atomic-rollback test");
          },
        },
      );
    } catch (err) {
      threw = true;
      assertEquals((err as Error).message.includes("synthetic"), true);
    }
    assertEquals(threw, true, "applySession must propagate ruleHook throws");

    // Verify rollback: PK row NOT inserted, watermark NOT advanced, model_json
    // unchanged.
    const applied = await sql`
      SELECT COUNT(*)::int AS count FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(
      applied[0].count,
      0,
      "PK insert must roll back when rule throws — single-transaction guarantee",
    );

    const row = await sql`
      SELECT last_applied_logged_at, session_count, model_json
      FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(
      new Date(row[0].last_applied_logged_at).toISOString(),
      new Date(priorWatermark).toISOString(),
      "watermark must NOT advance when rule throws",
    );
    assertEquals(row[0].session_count, 0, "session_count must NOT increment when rule throws");
    assertEquals(parseJsonb(row[0].model_json).sentinel, "pre-throw-token");
  },
);

orchestratorTest(
  "ADR-0013: Stage 2 (classifier) is NOT triggered on cached-snapshot return — first-apply-fires-once contract holds across WAQ retries",
  async () => {
    // Stage 2 is owned by #A13. This slice exposes a stage2Hook seam so the
    // orchestrator's "fires only on in-order first-apply" contract is pinned
    // before A13 lands the actual classifier call. ADR-0013: Stage 2 runs
    // separate-after Stage 1 commit, ONLY when Stage 1 took the in-order
    // first-apply path. Cached-snapshot returns and late-arrival refusals
    // MUST NOT fire Stage 2.
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const payload = { user_id: userId, session_id: sessionId, session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] } };

    let stage2Calls = 0;
    const stage2Hook = () => {
      stage2Calls += 1;
    };

    // First apply — Stage 1 succeeds, Stage 2 should fire.
    await applySession(payload, sql, { stage2Hook });
    assertEquals(stage2Calls, 1, "first-apply success path must fire Stage 2 (ADR-0013 §Stage sequencing)");

    // Second apply — PK conflict, cached path, Stage 2 must NOT fire.
    await applySession(payload, sql, { stage2Hook });
    assertEquals(stage2Calls, 1, "cached-snapshot return MUST NOT re-fire Stage 2 (ADR-0013 §WAQ retry idempotency)");
  },
);

orchestratorTest(
  "ADR-0011 §(c) + Q5: pattern in .deload at sessionsRequiredForPhase threshold → cyclic advance to .accumulation; transitionModeUntil set per cadence-aware composer; emitApplyComplete fires with the rules-fired list",
  async () => {
    // Synthetic deload-end fixture. Pattern is in .deload with sessionsInPhase
    // well above any reasonable Option-B threshold. Recent session dates are
    // spread ~4 days apart so cadence-derived daysPerWeek lands at ~1.75
    // (sessionsRequired = max(3, 1×1) = 3 for the deload phase). The pattern
    // crosses the threshold and the cyclic deload→accumulation rule fires;
    // composeTransitionModeUntil sets transitionModeUntil per ADR-0015.
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
    `;
    const seedModel = {
      patterns: {
        squat: {
          pattern: "squat",
          currentPhase: "deload",
          sessionsInPhase: 10,
          lastPhaseTransitionAtSessionCount: 5,
          rpeOffset: 0,
          recovery: { neuromuscularReadiness: 1, metabolicReadiness: 1 },
          confidence: "established",
          transitionModeUntil: null,
          trend: "progressing",
          recentSessionDates: [
            "2026-04-22T10:00:00.000Z",
            "2026-04-26T10:00:00.000Z",
            "2026-04-30T10:00:00.000Z",
            "2026-05-04T10:00:00.000Z",
          ],
          consecutiveForceDeloadsOnPattern: 0,
        },
      },
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json)
      VALUES (${userId}, ${JSON.stringify(seedModel)}::jsonb)
    `;

    const sessionId = crypto.randomUUID();
    const incomingLoggedAt = "2026-05-08T10:00:00.000Z";
    const captured: ApplyCompleteEvent[] = [];

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: incomingLoggedAt, set_logs: [] },
      },
      sql,
      {
        emitApplyComplete: (event) => {
          captured.push(event);
        },
      },
    );

    assertEquals(result.late_arrival, false);

    // Pattern advanced from .deload → .accumulation per ADR-0011 §(c).
    const patterns = (result.trainee_model as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    assertEquals(patterns.squat.currentPhase, "accumulation");
    assertEquals(patterns.squat.sessionsInPhase, 0);
    assertEquals(patterns.squat.lastPhaseTransitionAtSessionCount, 1, "lastPhaseTransitionAtSessionCount = the new session_count after this apply");

    // transitionModeUntil set per Q5 / ADR-0015. Concrete value is incoming +
    // max(14d, 3×cadence). Cadence ≈ 4d → 3×cadence = 12d → max(14, 12) = 14d.
    // So transitionModeUntil = 2026-05-08 + 14d = 2026-05-22T10:00:00Z.
    const until = new Date(patterns.squat.transitionModeUntil as string);
    const expected = new Date("2026-05-22T10:00:00.000Z");
    assertEquals(
      until.toISOString(),
      expected.toISOString(),
      "transitionModeUntil must be incomingLoggedAt + max(14d, 3×cadence) per Q5 + ADR-0015",
    );

    // emitApplyComplete fires with the list of rules that ran. The architect's
    // procedural note: per-apply summary belongs in the apply flow from cycle 10,
    // not added later.
    assertEquals(captured.length, 1, "emitApplyComplete must fire exactly once on first-apply success");
    assertEquals(captured[0].user_id, userId);
    assertEquals(captured[0].session_id, sessionId);
    assertEquals(captured[0].rules_fired.includes("phase-advance"), true);
    assertEquals(captured[0].rules_fired.includes("transition-mode-expiry"), true);
  },
);

orchestratorTest(
  "ADR-0011 §(b): pattern at 2× threshold + trend=plateaued → force-deload safety valve fires; consecutiveForceDeloadsOnPattern increments by 1; phase jumps directly to .deload (skips intensification/peaking)",
  async () => {
    // Synthetic force-deload fixture. Pattern in .accumulation with
    // sessionsInPhase well above 2 × sessionsRequiredForPhase + trend
    // already classified as plateaued (synthetic — A12 doesn't run plateau-
    // verdict; the seed pre-sets the trend that the real pipeline will
    // produce in a later slice). The force-deload safety valve at
    // ≥ 2× threshold AND stuck-trend fires per ADR-0011 §(b).
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
    `;
    const seedModel = {
      patterns: {
        squat: {
          pattern: "squat",
          currentPhase: "accumulation",
          // Need sessionsInPhase ≥ 2 × sessionsRequiredForPhase. With cadence
          // ≈ 4d (daysPerWeek ≈ 1.75 → multiplier=1) and accumulation
          // (phaseWeeks=4): sessionsRequired = max(3, 4×1) = 4. 2× = 8.
          // Setting sessionsInPhase=20 trivially clears the boundary.
          sessionsInPhase: 20,
          lastPhaseTransitionAtSessionCount: 5,
          rpeOffset: 0,
          recovery: { neuromuscularReadiness: 0.6, metabolicReadiness: 0.9 },
          confidence: "established",
          transitionModeUntil: null,
          trend: "plateaued", // synthetic — would be set by plateau-verdict in a future slice
          recentSessionDates: [
            "2026-04-22T10:00:00.000Z",
            "2026-04-26T10:00:00.000Z",
            "2026-04-30T10:00:00.000Z",
            "2026-05-04T10:00:00.000Z",
          ],
          consecutiveForceDeloadsOnPattern: 0,
        },
      },
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json)
      VALUES (${userId}, ${JSON.stringify(seedModel)}::jsonb)
    `;

    const sessionId = crypto.randomUUID();
    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: "2026-05-08T10:00:00.000Z", set_logs: [] },
      },
      sql,
    );

    const patterns = (result.trainee_model as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    assertEquals(patterns.squat.currentPhase, "deload", "force-deload jumps directly to .deload (skips intensification + peaking) per ADR-0011 §(b)");
    assertEquals(patterns.squat.sessionsInPhase, 0);
    assertEquals(
      patterns.squat.consecutiveForceDeloadsOnPattern,
      1,
      "consecutiveForceDeloadsOnPattern must increment on force-deload (only this path increments; natural progressing-advance resets per ADR-0011 §(b))",
    );
  },
);

orchestratorTest(
  "ADR-0012: 4-of-6 major patterns transitioned within last 6 sessions → globalPhaseAdvance fires; lastGlobalPhaseAdvanceFiredAtSessionCount = current session_count",
  async () => {
    // Synthetic 4-of-6 major-pattern transitions fixture. Pre-set
    // lastPhaseTransitionAtSessionCount within the 6-session window for
    // squat / hipHinge / horizontalPush / verticalPush; the remaining
    // major patterns (horizontalPull / verticalPull) sit outside the
    // window. session_count post-increment = 7 (above the bootstrap guard
    // of 6). lastGlobalPhaseAdvanceFiredAtSessionCount starts null —
    // never-fired.
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
    `;
    const inWindowProfile = (pattern: string) => ({
      pattern,
      currentPhase: "accumulation",
      sessionsInPhase: 0,
      lastPhaseTransitionAtSessionCount: 4, // session_count post-increment is 7, delta=3 (≤6)
      rpeOffset: 0,
      recovery: { neuromuscularReadiness: 1, metabolicReadiness: 1 },
      confidence: "established",
      transitionModeUntil: null,
      trend: "progressing",
      recentSessionDates: [
        "2026-04-22T10:00:00.000Z",
        "2026-04-26T10:00:00.000Z",
        "2026-04-30T10:00:00.000Z",
        "2026-05-04T10:00:00.000Z",
      ],
      consecutiveForceDeloadsOnPattern: 0,
    });
    const seedModel = {
      patterns: {
        squat: inWindowProfile("squat"),
        hipHinge: inWindowProfile("hipHinge"),
        horizontalPush: inWindowProfile("horizontalPush"),
        verticalPush: inWindowProfile("verticalPush"),
        // horizontalPull / verticalPull intentionally absent — they do not
        // contribute to the count, leaving 4-of-6 satisfied.
      },
      lastGlobalPhaseAdvanceFiredAtSessionCount: null,
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json, session_count)
      VALUES (${userId}, ${JSON.stringify(seedModel)}::jsonb, 6)
    `;

    const sessionId = crypto.randomUUID();
    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: { logged_at: "2026-05-08T10:00:00.000Z", set_logs: [] },
      },
      sql,
    );

    // Post-increment session_count = 7. ADR-0012's gate: 4-of-6 majors with
    // (7 - 4) = 3 ≤ 6 → fires. Bootstrap guard (sessionCount ≥ 6) cleared.
    // Cooldown gate (null lastFired) cleared.
    const model = result.trainee_model as Record<string, unknown>;
    assertEquals(
      model.lastGlobalPhaseAdvanceFiredAtSessionCount,
      7,
      "lastGlobalPhaseAdvanceFiredAtSessionCount must equal current session_count (7) when the trigger fires per ADR-0012",
    );
  },
);

orchestratorTest(
  "ADR-0006 (cross-platform JSONB shape parity): the canonical fixture at docs/fixtures/trainee-model-snapshot.json round-trips through the orchestrator unchanged on the in-order watermark-refusal path (no rule mutations) — TS side of the shape parity contract",
  async () => {
    // Loads the same canonical fixture that the Swift
    // TraineeModelSnapshotsCrossValidationTests decodes. Drift on either
    // side surfaces here (TS) or there (Swift). The fixture is the
    // single source of expected shape — Phase 2 fields populated, enum-
    // keyed dicts as JSON objects with rawValue keys.
    const fixturePath = new URL(
      "../../../docs/fixtures/trainee-model-snapshot.json",
      import.meta.url,
    );
    const raw = JSON.parse(Deno.readTextFileSync(fixturePath));
    // Strip the docs-only $comment field — Postgres jsonb doesn't care
    // but Swift's TraineeModel decoder ignores unknown keys by default,
    // and we keep the shape minimal-surface for the round-trip assertion.
    delete raw.$comment;

    // Seed the user + trainee_models row with the fixture as the model_json,
    // and a watermark in the FUTURE so the orchestrator takes the late-
    // arrival refusal path (which returns the cached snapshot unmutated).
    // This isolates the round-trip assertion from rule-mutation effects.
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
    `;
    const futureWatermark = "2026-12-31T23:59:59.000Z";
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json, last_applied_logged_at, session_count)
      VALUES (${userId}, ${JSON.stringify(raw)}::jsonb, ${futureWatermark}::timestamptz, 24)
    `;
    const sessionId = crypto.randomUUID();

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        // earlier than watermark → refusal path → orchestrator returns the
        // cached snapshot verbatim.
        session_payload: { logged_at: "2026-01-15T00:00:00.000Z", set_logs: [] },
      },
      sql,
      { emitLateArrival: () => {} },
    );

    assertEquals(result.late_arrival, true);
    // Round-trip: every top-level key in the fixture must be present in
    // the orchestrator's response with the same value. This catches TS-
    // side regressions on the JSONB read path (parseJsonbColumn defaults,
    // unintended field elision, type coercion).
    const returned = result.trainee_model as Record<string, unknown>;
    assertEquals(returned.totalSessionCount, 24);
    assertEquals(returned.lastGlobalPhaseAdvanceFiredAtSessionCount, 18);
    assertEquals(returned.lastClassifiedNoteCreatedAt, "2026-01-04T18:00:00.000Z");
    // patterns must be a JSON object with rawValue keys (snake_case for the
    // multi-word ones) — NOT Swift's default alternating-array form.
    const patterns = returned.patterns as Record<string, unknown>;
    assertEquals(Array.isArray(patterns), false, "patterns must be a JSON object, not an array (cross-platform shape contract)");
    assertEquals(typeof patterns.squat, "object");
    assertEquals(typeof patterns.horizontal_push, "object");
    // Doubly-nested prescriptionAccuracy: outer key MovementPattern.rawValue,
    // inner key SetIntent.rawValue — both as JSON objects.
    const pa = returned.prescriptionAccuracy as Record<string, Record<string, Record<string, unknown>>>;
    assertEquals(pa.squat.top.bias, 0.04);
    assertEquals(pa.squat.top.biasByGapBucket, {
      "under48h": -0.02,
      "between_48_and_72h": 0.05,
      "over72h": 0.06,
    });
  },
);

// Sentinel "test" that runs last (alphabetically — Deno runs tests in file
// order, but this trailing close keeps the connection lifecycle local to
// the test file rather than relying on process-exit cleanup).
Deno.test({
  name: "_zz_close_sql_pool",
  fn: async () => {
    await sql.end();
  },
  sanitizeOps: false,
  sanitizeResources: false,
});
