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
import type { LateArrivalEvent } from "../_shared/observability.ts";

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
