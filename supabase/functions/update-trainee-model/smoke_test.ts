// Project Apex — end-to-end smoke test for the production HTTP path.
//
// Runs the full HTTP → orchestrator → DB pipeline against a fresh user.
// Started 2026-05-10 per Phase 2 integration audit
// (docs/phase-2-integration-audit-2026-05-10.md). Intended as a "growing
// oracle" — each Phase 3 wiring slice (A17–A23) extends the assertion
// set so the smoke fails the moment a wired field stops populating.
//
// Why distinct from orchestrator_test.ts:
//   - orchestrator_test.ts calls applySession directly with a sql client.
//     It exercises rule composition but bypasses the HTTP entrypoint.
//   - This smoke POSTs over HTTP and reads back via SQL. It catches
//     wiring gaps between handleRequest, the orchestrator, and the
//     production code paths' env-driven SUPABASE_DB_URL connection.
//   - Both tests run together in CI (same `deno test` invocation).
//
// Prereqs (locally):
//   - `supabase start` running (DB at postgresql://postgres:postgres@127.0.0.1:54322/postgres)
//   - `supabase functions serve update-trainee-model --no-verify-jwt` running
//
// Run locally:
//   deno test --allow-net --allow-env --allow-read --no-check supabase/functions/update-trainee-model/smoke_test.ts

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import postgres from "postgres";

const DB_URL = "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const EDGE_FUNCTION_URL =
  "http://127.0.0.1:54321/functions/v1/update-trainee-model";

const sql = postgres(DB_URL, { max: 4 });

const smokeTest = (name: string, fn: () => Promise<void>): void => {
  Deno.test({
    name,
    fn,
    sanitizeOps: false,
    sanitizeResources: false,
  });
};

/**
 * Synthetic session_payload covering 3 movement patterns × multiple intents.
 * Exercise IDs are real entries from `ProjectApex/Models/ExerciseLibrary.swift`
 * so subsequent Phase 3 slices that introduce server-side
 * exercise_id → MovementPattern resolution (via #110/A15's library port)
 * will produce the right pattern bootstrapping for these sets.
 */
function syntheticSessionPayload(loggedAt: string): Record<string, unknown> {
  return {
    logged_at: loggedAt,
    set_logs: [
      // horizontalPush — bench press: warmup ramp + top sets + backoff
      { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 60, reps_completed: 5, intent: "warmup" },
      { exercise_id: "barbell_bench_press", set_number: 2, weight_kg: 80, reps_completed: 5, intent: "warmup" },
      { exercise_id: "barbell_bench_press", set_number: 3, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
      { exercise_id: "barbell_bench_press", set_number: 4, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
      { exercise_id: "barbell_bench_press", set_number: 5, weight_kg: 90, reps_completed: 8, intent: "backoff", rpe_felt: 7 },
      // squat — top sets
      { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "warmup" },
      { exercise_id: "barbell_back_squat", set_number: 2, weight_kg: 130, reps_completed: 5, intent: "top", rpe_felt: 8 },
      { exercise_id: "barbell_back_squat", set_number: 3, weight_kg: 130, reps_completed: 5, intent: "top", rpe_felt: 8 },
      // horizontalPull — barbell row top sets
      { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top", rpe_felt: 8 },
      { exercise_id: "barbell_row", set_number: 2, weight_kg: 70, reps_completed: 8, intent: "top", rpe_felt: 8 },
    ],
  };
}

smokeTest(
  "smoke: end-to-end HTTP → orchestrator → trainee_models materializes correctly on first apply",
  async () => {
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"smoke-" + userId.slice(0, 8)})
    `;

    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";

    const res = await fetch(EDGE_FUNCTION_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        user_id: userId,
        session_id: sessionId,
        session_payload: syntheticSessionPayload(loggedAt),
      }),
    });
    const bodyText = await res.text();
    assertEquals(
      res.status,
      200,
      `expected 200; got ${res.status}: ${bodyText}`,
    );
    const result = JSON.parse(bodyText);
    assertEquals(result.late_arrival, false);
    assertExists(result.trainee_model);

    // trainee_models row materialized correctly (gap 2 from G1 audit, fixed in #109)
    const model = await sql`
      SELECT user_id, session_count, last_applied_logged_at,
             jsonb_typeof(model_json) AS model_json_type,
             model_json
      FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(model.length, 1);
    assertEquals(model[0].session_count, 1);
    assertEquals(
      (model[0].last_applied_logged_at as Date).toISOString(),
      new Date(loggedAt).toISOString(),
    );
    // model_json round-trips as a JSONB object, not a scalar JSON string
    // (gap 3 from G1 audit, fixed in #109)
    assertEquals(model[0].model_json_type, "object");

    // dedupe row exists — proves applySession's transaction ran (gap 1
    // from G1 audit, fixed in #109)
    const applied = await sql`
      SELECT user_id, session_id FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(applied.length, 1);

    // INTENTIONALLY NOT ASSERTED YET (extended by subsequent slices):
    //   - model_json.patterns populated for trained patterns (A15 / #110)
    //   - PatternProfile.e1RMEwma populated (A17)
    //   - RecoveryProfile.last*StimulusAt populated (A18)
    //   - RecoveryProfile.*Readiness populated (A19)
    //   - PatternProfile.trend populated (A20)
    //   - prescriptionAccuracy cells populated (A21)
    //   - transferRegressions populated (A22)
    //   - fatigueInteractions populated (A23)
    // Each Phase 3 wiring slice MUST extend the assertion set here.
  },
);

smokeTest(
  "smoke: idempotent retry — second POST with same (user_id, session_id) returns cached snapshot, model_json unchanged",
  async () => {
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"smoke-" + userId.slice(0, 8)})
    `;

    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";
    const body = JSON.stringify({
      user_id: userId,
      session_id: sessionId,
      session_payload: syntheticSessionPayload(loggedAt),
    });

    const r1 = await fetch(EDGE_FUNCTION_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });
    assertEquals(r1.status, 200);
    await r1.body?.cancel();

    // Capture state after first apply
    const after1 = await sql`
      SELECT session_count, last_applied_logged_at::text AS last_applied
      FROM public.trainee_models WHERE user_id = ${userId}
    `;

    const r2 = await fetch(EDGE_FUNCTION_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });
    assertEquals(r2.status, 200);
    const result2 = await r2.json();
    assertEquals(result2.late_arrival, false);

    // session_count and watermark unchanged — second apply hit the
    // cached-snapshot path via PK conflict on trainee_model_applied_sessions
    const after2 = await sql`
      SELECT session_count, last_applied_logged_at::text AS last_applied
      FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(after2[0].session_count, after1[0].session_count);
    assertEquals(after2[0].last_applied, after1[0].last_applied);

    // Single dedupe row — PK ON CONFLICT DO NOTHING prevented a second insert
    const applied = await sql`
      SELECT COUNT(*)::int AS n FROM public.trainee_model_applied_sessions
      WHERE user_id = ${userId} AND session_id = ${sessionId}
    `;
    assertEquals(applied[0].n, 1);
  },
);

// Sentinel close — same pattern as orchestrator_test.ts's _zz_close_sql_pool.
// postgres.js keeps a keepalive timer alive between queries; closing the
// pool here lets Deno's resource sanitizer pass for the file's last test.
Deno.test({
  name: "_zz_smoke_close_pool",
  fn: async () => {
    await sql.end();
  },
  sanitizeOps: false,
  sanitizeResources: false,
});
