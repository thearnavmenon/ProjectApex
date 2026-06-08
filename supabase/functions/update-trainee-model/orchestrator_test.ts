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

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
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
  "#175: model_json.totalSessionCount mirrors session_count column on every apply",
  async () => {
    const userId = await seedFreshUser();

    await applySession(
      {
        user_id: userId,
        session_id: crypto.randomUUID(),
        session_payload: { logged_at: "2026-05-08T10:00:00Z", set_logs: [] },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    let rows = await sql`
      SELECT model_json, session_count FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(rows[0].session_count, 1);
    assertEquals(
      (rows[0].model_json as Record<string, unknown>).totalSessionCount,
      1,
      "first apply must mirror session_count=1 into model_json.totalSessionCount",
    );

    await applySession(
      {
        user_id: userId,
        session_id: crypto.randomUUID(),
        session_payload: { logged_at: "2026-05-09T10:00:00Z", set_logs: [] },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    rows = await sql`
      SELECT model_json, session_count FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(rows[0].session_count, 2);
    assertEquals(
      (rows[0].model_json as Record<string, unknown>).totalSessionCount,
      2,
      "second apply must mirror session_count=2 into model_json.totalSessionCount",
    );
  },
);

orchestratorTest(
  "A17 / #116: ewma-engine wired — first apply with valid top sets bootstraps ExerciseProfile + populates e1rmCurrent via Epley × EWMA",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            // bench: 100kg × 5 reps → e1rm = 100 × (1 + 5/30) = 116.666...
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top" },
            // squat: 130kg × 5 reps → e1rm = 130 × (1 + 5/30) = 151.666...
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top" },
            // row: 70kg × 8 reps → e1rm = 70 × (1 + 8/30) = 88.666...
            { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    assertEquals(result.late_arrival, false);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const exercises = modelJson.exercises as Record<string, Record<string, unknown>>;

    // Three exercises bootstrapped + populated.
    assertEquals(
      Object.keys(exercises).sort(),
      ["barbell_back_squat", "barbell_bench_press", "barbell_row"],
    );

    // EWMA over a single valid top set = the e1rm of that set (no smoothing).
    // Allow small floating-point tolerance via fixed-precision compare.
    const bench = exercises["barbell_bench_press"];
    const squat = exercises["barbell_back_squat"];
    const row = exercises["barbell_row"];

    assertEquals(
      Number((bench.e1rmCurrent as number).toFixed(4)),
      Number((100 * (1 + 5 / 30)).toFixed(4)),
    );
    assertEquals(
      Number((squat.e1rmCurrent as number).toFixed(4)),
      Number((130 * (1 + 5 / 30)).toFixed(4)),
    );
    assertEquals(
      Number((row.e1rmCurrent as number).toFixed(4)),
      Number((70 * (1 + 8 / 30)).toFixed(4)),
    );

    // sessionCount increments by 1 per apply per exercise (counts sessions,
    // not sets — see applyPerExerciseRules comment).
    assertEquals(bench.sessionCount, 1);
    assertEquals(squat.sessionCount, 1);
    assertEquals(row.sessionCount, 1);

    // topSets appended once per valid top-intent set.
    assertEquals((bench.topSets as unknown[]).length, 1);
    assertEquals((squat.topSets as unknown[]).length, 1);
    assertEquals((row.topSets as unknown[]).length, 1);
  },
);

orchestratorTest(
  "A18 / #118 (per-pattern recovery per #146): stimulus-classifier wired — bench top×5 bumps horizontal_push NM; row top×8 bumps horizontal_pull NM+metabolic (top×8 classifies as 'both')",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            // warmup → null dim, no timestamp bump
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 60, reps_completed: 5, intent: "warmup" },
            // top reps=5 → "neuromuscular" → horizontal_push NM only
            { exercise_id: "barbell_bench_press", set_number: 2, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
            // top reps=8 → "both" (BACKOFF_BOTH_REP_MAX=8) → horizontal_pull NM + metabolic
            { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    assertEquals(result.late_arrival, false);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const patterns = modelJson.patterns as Record<string, Record<string, unknown>>;
    const expectedIso = new Date(loggedAt).toISOString();

    // horizontal_push: NM only (bench top×5). metabolic axis untouched.
    const pushRec = patterns.horizontal_push.recovery as Record<string, unknown>;
    assertEquals(pushRec.lastNeuromuscularStimulusAt, expectedIso);
    assertEquals(pushRec.lastMetabolicStimulusAt, null);
    assertEquals(Number((pushRec.neuromuscularReadiness as number).toFixed(4)), 0.3);
    assertEquals(pushRec.metabolicReadiness, 1.0);

    // horizontal_pull: both axes (row top×8 = "both"). NM and metabolic bumped.
    const pullRec = patterns.horizontal_pull.recovery as Record<string, unknown>;
    assertEquals(pullRec.lastNeuromuscularStimulusAt, expectedIso);
    assertEquals(pullRec.lastMetabolicStimulusAt, expectedIso);
    assertEquals(Number((pullRec.neuromuscularReadiness as number).toFixed(4)), 0.3);
    assertEquals(Number((pullRec.metabolicReadiness as number).toFixed(4)), 0.3);

    // No orphan top-level recovery write per #146.
    assertEquals(modelJson.recovery, undefined);
  },
);

orchestratorTest(
  "A20 / #122: plateau-verdict wired — first apply with trained patterns leaves trend='progressing' (insufficient history) and seeds weeklyVolumeLoadHistory with one entry per pattern",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T13:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top", rpe_felt: 8 },
            { exercise_id: "barbell_back_squat", set_number: 2, weight_kg: 110, reps_completed: 8, intent: "backoff", rpe_felt: 7 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const patterns = (rows[0].model_json as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    const squat = patterns["squat"];

    // Single session — no plateau possible. Trend explicitly written by
    // plateau-verdict (rule fired), value = "progressing".
    assertEquals(squat.trend, "progressing");

    // weeklyVolumeLoadHistory seeded with one ISO-week entry. Volume-load
    // = 130×5 + 110×8 = 650 + 880 = 1530. avgRPE = simple mean of
    // rpe_felt across the session's contributing sets = (8 + 7) / 2 = 7.5.
    // (Volume-weighted aggregation kicks in only when rolling new sessions
    // into an existing same-week bucket.)
    const history = squat.weeklyVolumeLoadHistory as Array<Record<string, unknown>>;
    assertEquals(history.length, 1);
    assertEquals(history[0].weeklyVolumeLoad, 1530);
    assertEquals(history[0].avgRPE, 7.5);
  },
);

orchestratorTest(
  "A21 / #124: prescription-accuracy wired — set with valid ai_prescribed accumulates one observation in (pattern, intent) cell with rep-error ≈ 0.0",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T15:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            {
              exercise_id: "barbell_back_squat",
              set_number: 1,
              weight_kg: 130,
              reps_completed: 5,
              intent: "top",
              rpe_felt: 8,
              ai_prescribed: {
                weight_kg: 130,
                reps: 5,
                intent: "top",
                user_corrected_weight: false,
              },
              completion_flags: [],
            },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const acc = (rows[0].model_json as Record<string, unknown>)
      .prescriptionAccuracy as Record<string, Record<string, Record<string, unknown>>>;
    const cell = acc["squat"]["top"];
    const observations = cell.observations as number[];
    assertEquals(observations.length, 1);
    // Prescribed 5, completed 5 → rep-error = 0
    assertEquals(observations[0], 0);
    // First-ever pattern session → priorSessionLoggedAt = null → over72h
    const buckets = cell.observationsByGapBucket as Record<string, number[]>;
    assertEquals(buckets.over72h.length, 1);
    assertEquals(buckets.under48h.length, 0);
    assertEquals(buckets.between48And72h.length, 0);
  },
);

orchestratorTest(
  "A22 / #126: transfer-regression wired — single session with 2 top-intent exercises records both ordered pairs (candidate state, n=1, no NaN)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T17:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
            { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const transfers = (rows[0].model_json as Record<string, unknown>).transfers as Array<Record<string, unknown>>;
    assertEquals(transfers.length, 2);
    const benchToRow = transfers.find(
      (t) => t.fromExerciseId === "barbell_bench_press" && t.toExerciseId === "barbell_row",
    );
    const rowToBench = transfers.find(
      (t) => t.fromExerciseId === "barbell_row" && t.toExerciseId === "barbell_bench_press",
    );
    assertExists(benchToRow);
    assertExists(rowToBench);
    assertEquals((benchToRow.observations as unknown[]).length, 1);
    assertEquals((rowToBench.observations as unknown[]).length, 1);
    assertEquals(benchToRow.state, "candidate");
    // Placeholder fit values — n<2 path returns zeroed coefficients (no NaN).
    assertEquals(benchToRow.coefficient, 0);
    assertEquals(benchToRow.rSquared, 0);
    assertEquals(benchToRow.pairedObservations, 1);
  },
);

orchestratorTest(
  "A23 / #128: fatigue-interaction wired — first session populates lastSessionPatternPerformance; fatigueInteractions stays empty (no prior session to pair against)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T19:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const interactions = modelJson.fatigueInteractions as unknown[];
    const lastPerf = modelJson.lastSessionPatternPerformance as Array<Record<string, unknown>>;
    assertEquals(interactions.length, 0);
    assertEquals(lastPerf.length, 1);
    assertEquals(lastPerf[0].pattern, "horizontal_push");
    // First-ever pattern → priorEwma = 0 → performanceDeltaPct = 0
    assertEquals(lastPerf[0].performanceDeltaPct, 0);
  },
);

orchestratorTest(
  "A23 / #128: fatigue-interaction — second session with different pattern records (prior → current) pair observation; totalCount === 1",
  async () => {
    const userId = await seedFreshUser();
    const sessionId1 = crypto.randomUUID();
    const sessionId2 = crypto.randomUUID();
    const loggedAt1 = "2026-05-09T10:00:00Z";
    const loggedAt2 = "2026-05-10T10:00:00Z";

    // Session 1: bench (horizontal_push)
    await applySession(
      {
        user_id: userId,
        session_id: sessionId1,
        session_payload: {
          logged_at: loggedAt1,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    // Session 2: row (horizontal_pull)
    await applySession(
      {
        user_id: userId,
        session_id: sessionId2,
        session_payload: {
          logged_at: loggedAt2,
          set_logs: [
            { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const interactions = (rows[0].model_json as Record<string, unknown>).fatigueInteractions as Array<Record<string, unknown>>;
    assertEquals(interactions.length, 1);
    assertEquals(interactions[0].fromPattern, "horizontal_push");
    assertEquals(interactions[0].toPattern, "horizontal_pull");
    assertEquals(interactions[0].totalCount, 1);
    assertEquals((interactions[0].observations as number[]).length, 1);
  },
);

orchestratorTest(
  "A22 / #126: transfer-regression — session with one top-intent exercise records no pairs (single-exercise sessions can't pair)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T18:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const transfers = (rows[0].model_json as Record<string, unknown>).transfers as Array<Record<string, unknown>>;
    assertEquals(transfers.length, 0);
  },
);

orchestratorTest(
  "legacy-fallback-removed: row with ONLY legacy `transferRegressions` is NOT auto-migrated — applyTransfers reads only the new `transfers` key (empty); session observations are the sole source of new cells, no legacy carryover",
  async () => {
    // Inverse of the deleted schema-drift-fix test. PR #177 shipped a one-cycle
    // migration shim that hydrated `transferRegressions` (legacy dict) when
    // `transfers` (new list) was absent. This cleanup PR removes that shim
    // after the alpha cohort migration completed (verified 2026-05-17).
    //
    // Seed legacy dict with 2 cells (1 observation each). Apply a session
    // that re-trains the same pair. Pre-fix behavior: legacy obs preserved
    // + new obs appended → 2 obs per cell. Post-fix behavior: legacy obs
    // ignored, only new obs counted → 1 obs per cell.
    const userId = crypto.randomUUID();
    await sql`
      INSERT INTO public.users (id, display_name)
      VALUES (${userId}, ${"orchestrator-test-" + userId.slice(0, 8)})
    `;
    const legacyModel = {
      transferRegressions: {
        "barbell_bench_press": {
          "barbell_back_squat": {
            observations: [{ fromE1RM: 100, toE1RM: 130, observedAt: "2026-05-01T10:00:00Z" }],
            fit: { coefficient: 0, intercept: 0, rSquared: 0, pairedObservations: 1, spearmanFlagged: false, seWidening: 0, state: "candidate" },
          },
        },
        "barbell_back_squat": {
          "barbell_bench_press": {
            observations: [{ fromE1RM: 130, toE1RM: 100, observedAt: "2026-05-01T10:00:00Z" }],
            fit: { coefficient: 0, intercept: 0, rSquared: 0, pairedObservations: 1, spearmanFlagged: false, seWidening: 0, state: "candidate" },
          },
        },
      },
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json)
      VALUES (${userId}, ${sql.json(legacyModel)})
    `;

    await applySession(
      {
        user_id: userId,
        session_id: crypto.randomUUID(),
        session_payload: {
          logged_at: "2026-05-08T10:00:00Z",
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 102.5, reps_completed: 5, intent: "top", rpe_felt: 8 },
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 132.5, reps_completed: 5, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const transfers = modelJson.transfers as Array<Record<string, unknown>>;
    assertExists(transfers, "transfers list must be populated by session observations");
    assertEquals(transfers.length, 2);

    const benchToSquat = transfers.find(
      (t) => t.fromExerciseId === "barbell_bench_press" && t.toExerciseId === "barbell_back_squat",
    );
    const squatToBench = transfers.find(
      (t) => t.fromExerciseId === "barbell_back_squat" && t.toExerciseId === "barbell_bench_press",
    );
    assertExists(benchToSquat, "bench→squat cell must come from this session");
    assertExists(squatToBench, "squat→bench cell must come from this session");

    // Each cell carries exactly 1 observation — the session's new entry.
    // Legacy `transferRegressions` is ignored (no fallback hydration).
    assertEquals((benchToSquat.observations as unknown[]).length, 1);
    assertEquals((squatToBench.observations as unknown[]).length, 1);
    assertEquals(benchToSquat.pairedObservations, 1);
    assertEquals(benchToSquat.state, "candidate");
  },
);

orchestratorTest(
  "A21 / #124: prescription-accuracy filter — user_corrected_weight=true is rejected by shouldContribute; cell stays absent",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T16:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            {
              exercise_id: "barbell_back_squat",
              set_number: 1,
              weight_kg: 130,
              reps_completed: 5,
              intent: "top",
              ai_prescribed: {
                weight_kg: 125,
                reps: 5,
                intent: "top",
                user_corrected_weight: true,
              },
              completion_flags: [],
            },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const acc = (rows[0].model_json as Record<string, unknown>)
      .prescriptionAccuracy as Record<string, unknown>;
    // No cell created — set was filtered out by criterion 4
    assertEquals(Object.keys(acc).length, 0);
  },
);

orchestratorTest(
  "A20 / #122: warmup-only session contributes nothing to weeklyVolumeLoadHistory (warmup excluded, pattern not trained for plateau purposes)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T14:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 40, reps_completed: 5, intent: "warmup" },
            { exercise_id: "barbell_bench_press", set_number: 2, weight_kg: 60, reps_completed: 5, intent: "warmup" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const patterns = (rows[0].model_json as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    const push = patterns["horizontal_push"];
    assertEquals((push.weeklyVolumeLoadHistory as unknown[]).length, 0);
    assertEquals(push.trend, "progressing");
  },
);

orchestratorTest(
  "A19 / #120 (per-pattern recovery per #146): recovery-curve wired — same-instant stimulus on squat NM axis sets squat NM readiness to floor 0.3; squat metabolic axis stays at 1.0 (null timestamp)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T12:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            // top×5 → NM; nothing else → metabolic stays null/1.0
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const patterns = (rows[0].model_json as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    const recovery = patterns.squat.recovery as Record<string, unknown>;

    // NM stimulus at loggedAt, computed at loggedAt → t=0 → readiness = floor 0.3
    assertEquals(
      Number((recovery.neuromuscularReadiness as number).toFixed(4)),
      0.3,
    );
    // Metabolic never stimulated → null timestamp → readiness = 1.0
    assertEquals(recovery.lastMetabolicStimulusAt, null);
    assertEquals(recovery.metabolicReadiness, 1.0);
  },
);

orchestratorTest(
  "A19 / #120 (per-pattern recovery per #146): second session 24h after horizontal_push stimulus produces partially-recovered NM readiness per ADR-0010 curve (~0.7853); metabolic untouched stays 1.0",
  async () => {
    const userId = await seedFreshUser();
    const sessionId1 = crypto.randomUUID();
    const sessionId2 = crypto.randomUUID();
    const loggedAt1 = "2026-05-08T10:00:00Z";
    const loggedAt2 = "2026-05-09T10:00:00Z"; // exactly 24h later

    // Session 1: heavy bench top×5 (NM only) → bootstraps horizontal_push
    await applySession(
      {
        user_id: userId,
        session_id: sessionId1,
        session_payload: {
          logged_at: loggedAt1,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top", rpe_felt: 8 },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    // Session 2: empty (no stimulus). Tests "readiness recomputes from now-loggedAt
    // even when no new stimulus arrives" — readiness decay applies even for
    // patterns not trained this session.
    await applySession(
      {
        user_id: userId,
        session_id: sessionId2,
        session_payload: { logged_at: loggedAt2, set_logs: [] },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const patterns = (rows[0].model_json as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    const recovery = patterns.horizontal_push.recovery as Record<string, unknown>;

    // NM: 24h since stimulus, tau=30h → 0.3 + 0.7 × (1 - exp(-24/30)) ≈ 0.7853
    const expectedNm = 0.3 + 0.7 * (1 - Math.exp(-24 / 30));
    assertEquals(
      Number((recovery.neuromuscularReadiness as number).toFixed(4)),
      Number(expectedNm.toFixed(4)),
    );
    // Metabolic never stimulated → readiness still 1.0
    assertEquals(recovery.metabolicReadiness, 1.0);
  },
);

orchestratorTest(
  "A18 / #118 (per-pattern recovery per #146): warmup-only session bootstraps horizontal_push pattern with default recovery shape — null timestamps + 1.0 readinesses (no stimulus bump from low-stimulus sets)",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T11:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 40, reps_completed: 5, intent: "warmup" },
            { exercise_id: "barbell_bench_press", set_number: 2, weight_kg: 60, reps_completed: 5, intent: "warmup" },
            { exercise_id: "barbell_bench_press", set_number: 3, weight_kg: 70, reps_completed: 8, intent: "technique" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const patterns = (rows[0].model_json as Record<string, unknown>).patterns as Record<string, Record<string, unknown>>;
    const recovery = patterns.horizontal_push.recovery as Record<string, unknown>;

    // Bootstrapped (the field exists)...
    assertEquals(recovery.neuromuscularReadiness, 1.0);
    // ...but no stimulus → both timestamps stay null (ADR-0005 §"low-stimulus exclusion via Optional return")
    assertEquals(recovery.lastNeuromuscularStimulusAt, null);
    assertEquals(recovery.lastMetabolicStimulusAt, null);
  },
);

orchestratorTest(
  "A15 / #110: first apply with set_logs across 3 movement patterns bootstraps each PatternProfile with ADR-0011 defaults + sessionsInPhase=1 + recentSessionDates=[loggedAt]",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top" },
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top" },
            { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    assertEquals(result.late_arrival, false);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const patterns = modelJson.patterns as Record<string, Record<string, unknown>>;

    // Three patterns bootstrapped — server-side derived from exercise_id
    // via the ExerciseLibrary port (#110 / A15).
    assertEquals(
      Object.keys(patterns).sort(),
      ["horizontal_pull", "horizontal_push", "squat"],
    );

    // Each profile carries ADR-0011 defaults + the just-trained-this-session state.
    const expectedLoggedAtIso = new Date(loggedAt).toISOString();
    for (const patternKey of ["horizontal_push", "squat", "horizontal_pull"]) {
      const profile = patterns[patternKey];
      assertEquals(profile.currentPhase, "accumulation");
      assertEquals(profile.sessionsInPhase, 1);
      assertEquals(profile.trend, "progressing");
      assertEquals(profile.consecutiveForceDeloadsOnPattern, 0);
      assertEquals(profile.lastPhaseTransitionAtSessionCount, 0);
      assertEquals(profile.transitionModeUntil, null);
      assertEquals(profile.recentSessionDates, [expectedLoggedAtIso]);
    }
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
      totalSessionCount: 0,
      // Phase 2 additions missing on purpose.
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json)
      VALUES (${userId}, ${sql.json(partialBlob)})
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
      VALUES (${userId}, ${sql.json(seedModel)})
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
      VALUES (${userId}, ${sql.json(seedModel)})
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
    // squat / hip_hinge / horizontal_push / vertical_push; the remaining
    // major patterns (horizontal_pull / vertical_pull) sit outside the
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
        hip_hinge: inWindowProfile("hip_hinge"),
        horizontal_push: inWindowProfile("horizontal_push"),
        vertical_push: inWindowProfile("vertical_push"),
        // horizontal_pull / vertical_pull intentionally absent — they do not
        // contribute to the count, leaving 4-of-6 satisfied.
      },
      lastGlobalPhaseAdvanceFiredAtSessionCount: null,
    };
    await sql`
      INSERT INTO public.trainee_models (user_id, model_json, session_count)
      VALUES (${userId}, ${sql.json(seedModel)}, 6)
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
      VALUES (${userId}, ${sql.json(raw)}, ${futureWatermark}::timestamptz, 24)
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
    // transfers must be a JSON array (not the legacy `transferRegressions`
    // dict-of-dicts shape). Element shape carries the basic 5 fields Swift's
    // ExerciseTransfer struct decodes plus EF-internal rich fields (intercept,
    // spearmanFlagged, seWidening, state, observations) that Swift Codable
    // tolerates by default.
    const transfers = returned.transfers as Array<Record<string, unknown>>;
    assertEquals(Array.isArray(transfers), true, "transfers must be a JSON array, not a dict (cross-platform shape contract)");
    assertEquals(transfers.length, 1);
    const t0 = transfers[0];
    assertEquals(t0.fromExerciseId, "barbell_bench_press");
    assertEquals(t0.toExerciseId, "overhead_press");
    assertEquals(t0.coefficient, 0.83);
    assertEquals(t0.rSquared, 0.62);
    assertEquals(t0.pairedObservations, 8);
    assertEquals(t0.state, "published");
  },
);

// ─── #156: MuscleProfile producer (applyPerMuscleRules) ──────────────────────

orchestratorTest(
  "#156: first apply training quads bootstraps muscles.legs with Q1-locked MEV defaults",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";

    const result = await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            // 1 contributing top set on a quads exercise — bootstraps legs
            // with volumeDeficit = tolerance(18) − 1 = 17.
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    assertEquals(result.late_arrival, false);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const muscles = modelJson.muscles as Record<string, Record<string, unknown>>;

    // Single muscle bootstrapped — quads collapses to legs per ADR-0005's
    // two-level taxonomy; no other muscles touched.
    assertEquals(Object.keys(muscles).sort(), ["legs"]);

    const legs = muscles.legs;
    // muscleGroup-as-field per the #146 pattern (dict key alone is invisible
    // to Swift's inner decoder via decodeEnumKeyedDict).
    assertEquals(legs.muscleGroup, "legs");
    // Q1 lock: MEV midpoint at 4×/week scaled to 7-events = 18 sets.
    assertEquals(legs.volumeTolerance, 18);
    // Q3 lock.
    assertEquals(legs.observedSweetSpot, null);
    // Q4 lock: GoalState.placeholder has empty focusAreas → 0.0.
    assertEquals(legs.focusWeight, 0);
    // ADR-0009 empty-participation default (no patterns at confidence >
    // .bootstrapping yet).
    assertEquals(legs.stagnationStatus, "progressing");
    // Q5 lock: all #156 profiles ship .bootstrapping.
    assertEquals(legs.confidence, "bootstrapping");
    // volumeDeficit = tolerance(18) − sum of this-session sets(1) = 17.
    assertEquals(legs.volumeDeficit, 17);
  },
);

orchestratorTest(
  "#156: per-set attribution — quads + hamstrings collapse to legs; shoulders maps 1:1; unknown exercise IDs silently skipped",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-10T10:00:00Z";

    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            // 2 quads sets → contribute to legs.
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top" },
            { exercise_id: "barbell_back_squat", set_number: 2, weight_kg: 130, reps_completed: 5, intent: "top" },
            // 1 hamstrings set → collapses to legs.
            { exercise_id: "romanian_deadlift", set_number: 1, weight_kg: 110, reps_completed: 8, intent: "backoff" },
            // 1 shoulders set (amrap counts as contributing).
            { exercise_id: "lateral_raise", set_number: 1, weight_kg: 8, reps_completed: 12, intent: "amrap" },
            // Warmup set on quads → excluded from volume aggregation.
            { exercise_id: "barbell_back_squat", set_number: 0, weight_kg: 60, reps_completed: 5, intent: "warmup" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const muscles = modelJson.muscles as Record<string, Record<string, unknown>>;

    // Two muscle groups bootstrapped — legs (collapsed) and shoulders (1:1).
    assertEquals(Object.keys(muscles).sort(), ["legs", "shoulders"]);

    // legs aggregates 2 quads + 1 hamstrings = 3 contributing sets; warmup
    // excluded.
    const legsHistory = muscles.legs.weeklyVolumeHistory as Array<Record<string, unknown>>;
    assertEquals(legsHistory.length, 1);
    assertEquals(legsHistory[0].sets, 3);
    assertEquals(muscles.legs.volumeDeficit, 15); // 18 − 3

    // shoulders 1:1 mapping; 1 contributing set.
    const shouldersHistory = muscles.shoulders.weeklyVolumeHistory as Array<Record<string, unknown>>;
    assertEquals(shouldersHistory.length, 1);
    assertEquals(shouldersHistory[0].sets, 1);
    assertEquals(muscles.shoulders.volumeDeficit, 17); // 18 − 1
  },
);

orchestratorTest(
  "#156: weeklyVolumeHistory accumulates across applies; volumeDeficit converges toward 0 as volume accrues",
  async () => {
    const userId = await seedFreshUser();
    const loggedAtBase = new Date("2026-05-10T10:00:00Z");

    // Three consecutive applies on chest, each contributing 5 sets.
    // Cumulative sets: 5, 10, 15. Deficits: 18−5=13, 18−10=8, 18−15=3.
    for (let i = 0; i < 3; i++) {
      const loggedAt = new Date(loggedAtBase.getTime() + i * 86_400_000).toISOString();
      await applySession(
        {
          user_id: userId,
          session_id: crypto.randomUUID(),
          session_payload: {
            logged_at: loggedAt,
            set_logs: [
              { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 80, reps_completed: 5, intent: "top" },
              { exercise_id: "barbell_bench_press", set_number: 2, weight_kg: 80, reps_completed: 5, intent: "top" },
              { exercise_id: "barbell_bench_press", set_number: 3, weight_kg: 80, reps_completed: 5, intent: "top" },
              { exercise_id: "barbell_bench_press", set_number: 4, weight_kg: 70, reps_completed: 8, intent: "backoff" },
              { exercise_id: "barbell_bench_press", set_number: 5, weight_kg: 70, reps_completed: 8, intent: "backoff" },
            ],
          },
        },
        sql,
        { stage2Hook: noopStage2 },
      );
    }

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    const chest = (modelJson.muscles as Record<string, Record<string, unknown>>).chest;

    // History accumulated three buckets (still within 7-event window).
    const history = chest.weeklyVolumeHistory as Array<Record<string, unknown>>;
    assertEquals(history.length, 3);
    assertEquals(history[0].sets, 5);
    assertEquals(history[1].sets, 5);
    assertEquals(history[2].sets, 5);

    // Cumulative volume = 15 sets; deficit = 18 − 15 = 3.
    assertEquals(chest.volumeDeficit, 3);
  },
);

orchestratorTest(
  "#156: end-to-end snapshot — alpha-shaped session populates all six MuscleGroups with Q1-locked defaults",
  async () => {
    const userId = await seedFreshUser();
    const sessionId = crypto.randomUUID();
    const loggedAt = "2026-05-12T10:00:00Z";

    // One set touching each of the six MuscleGroups (mirrors the alpha
    // cohort's full-coverage shape across back/chest/shoulders/biceps/
    // triceps/legs).
    await applySession(
      {
        user_id: userId,
        session_id: sessionId,
        session_payload: {
          logged_at: loggedAt,
          set_logs: [
            { exercise_id: "barbell_row", set_number: 1, weight_kg: 70, reps_completed: 8, intent: "top" },             // back
            { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 80, reps_completed: 5, intent: "top" },     // chest
            { exercise_id: "overhead_press", set_number: 1, weight_kg: 50, reps_completed: 5, intent: "top" },          // shoulders
            { exercise_id: "barbell_curl", set_number: 1, weight_kg: 30, reps_completed: 10, intent: "top" },           // biceps
            { exercise_id: "cable_tricep_pushdown", set_number: 1, weight_kg: 25, reps_completed: 12, intent: "top" },  // triceps
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 130, reps_completed: 5, intent: "top" },     // legs (quads)
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const muscles = (rows[0].model_json as Record<string, unknown>).muscles as Record<
      string,
      Record<string, unknown>
    >;

    // All six MuscleGroups populated.
    assertEquals(
      Object.keys(muscles).sort(),
      ["back", "biceps", "chest", "legs", "shoulders", "triceps"],
    );

    const expectedTolerances: Record<string, number> = {
      back: 21,
      chest: 18,
      shoulders: 18,
      biceps: 16,
      triceps: 12,
      legs: 18,
    };

    const loggedAtIso = new Date(loggedAt).toISOString();
    for (const [muscleGroup, expectedTolerance] of Object.entries(expectedTolerances)) {
      const profile = muscles[muscleGroup];
      assertEquals(profile.muscleGroup, muscleGroup);
      assertEquals(profile.volumeTolerance, expectedTolerance);
      assertEquals(profile.observedSweetSpot, null);
      assertEquals(profile.focusWeight, 0); // GoalState.placeholder
      assertEquals(profile.stagnationStatus, "progressing"); // empty-participation default
      assertEquals(profile.confidence, "bootstrapping"); // Q5 lock
      // weeklyVolumeHistory has exactly one bucket — this session.
      const history = profile.weeklyVolumeHistory as Array<Record<string, unknown>>;
      assertEquals(history.length, 1);
      assertEquals(history[0].loggedAtIso, loggedAtIso);
      assertEquals(history[0].sets, 1);
      // deficit = tolerance − 1
      assertEquals(profile.volumeDeficit, expectedTolerance - 1);
    }
  },
);

orchestratorTest(
  "#283 (ADR-0020): exercise confidence advances bootstrapping → calibrating → established over repeated stable sessions",
  async () => {
    const userId = await seedFreshUser();

    // Apply `count` sessions of one stable top set (100kg × 5) for bench,
    // starting at `dayOffset` days past a base date. Returns the bench
    // ExerciseProfile after the last apply.
    async function applyStableSessions(
      count: number,
      dayOffset: number,
    ): Promise<Record<string, unknown>> {
      for (let i = 0; i < count; i++) {
        const day = String(8 + dayOffset + i).padStart(2, "0");
        await applySession(
          {
            user_id: userId,
            session_id: crypto.randomUUID(),
            session_payload: {
              logged_at: `2026-05-${day}T10:00:00Z`,
              set_logs: [
                { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top" },
              ],
            },
          },
          sql,
          { stage2Hook: noopStage2 },
        );
      }
      const rows = await sql`
        SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
      `;
      const exercises = (rows[0].model_json as Record<string, unknown>)
        .exercises as Record<string, Record<string, unknown>>;
      return exercises["barbell_bench_press"];
    }

    // After 3 stable sessions: calibrating (sessionCount≥3 AND ≥3 valid top sets).
    const afterThree = await applyStableSessions(3, 0);
    assertEquals(afterThree.sessionCount, 3);
    assertEquals(afterThree.confidence, "calibrating");

    // 5 more (total 8) stable sessions: established (sessionCount≥8 AND e1RM
    // CV ≤ 7.5% over ≥4 distinct sessions). calibrating→established is one
    // monotonicAdvance step, so it lands on the 8th apply.
    const afterEight = await applyStableSessions(5, 3);
    assertEquals(afterEight.sessionCount, 8);
    assertEquals(afterEight.confidence, "established");
  },
);

orchestratorTest(
  "#284 (ADR-0020): per-pattern sessionCount increments once per trained apply; untrained patterns hold",
  async () => {
    const userId = await seedFreshUser();

    async function applyBench(day: string): Promise<void> {
      await applySession(
        {
          user_id: userId,
          session_id: crypto.randomUUID(),
          session_payload: {
            logged_at: `2026-06-${day}T10:00:00Z`,
            set_logs: [
              { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top" },
            ],
          },
        },
        sql,
        { stage2Hook: noopStage2 },
      );
    }

    async function patterns(): Promise<Record<string, Record<string, unknown>>> {
      const rows = await sql`
        SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
      `;
      return (rows[0].model_json as Record<string, unknown>).patterns as Record<
        string,
        Record<string, unknown>
      >;
    }

    await applyBench("01");
    assertEquals((await patterns())["horizontal_push"].sessionCount, 1);

    await applyBench("02");
    assertEquals((await patterns())["horizontal_push"].sessionCount, 2);

    // A squat-only session must not bump the (untrained) horizontal_push counter,
    // while squat's own counter starts at 1.
    await applySession(
      {
        user_id: userId,
        session_id: crypto.randomUUID(),
        session_payload: {
          logged_at: "2026-06-03T10:00:00Z",
          set_logs: [
            { exercise_id: "barbell_back_squat", set_number: 1, weight_kg: 140, reps_completed: 5, intent: "top" },
          ],
        },
      },
      sql,
      { stage2Hook: noopStage2 },
    );
    const after = await patterns();
    assertEquals(after["horizontal_push"].sessionCount, 2);
    assertEquals(after["squat"].sessionCount, 1);
  },
);

orchestratorTest(
  "#285 (ADR-0020): pattern confidence advances to established; feature never writes projections",
  async () => {
    const userId = await seedFreshUser();

    async function applyBench(day: number): Promise<Record<string, unknown>> {
      await applySession(
        {
          user_id: userId,
          session_id: crypto.randomUUID(),
          session_payload: {
            logged_at: `2026-07-${String(day).padStart(2, "0")}T10:00:00Z`,
            set_logs: [
              { exercise_id: "barbell_bench_press", set_number: 1, weight_kg: 100, reps_completed: 5, intent: "top" },
            ],
          },
        },
        sql,
        { stage2Hook: noopStage2 },
      );
      const rows = await sql`
        SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
      `;
      return rows[0].model_json as Record<string, unknown>;
    }

    // 3 sessions → calibrating.
    let modelJson: Record<string, unknown> = {};
    for (let d = 1; d <= 3; d++) modelJson = await applyBench(d);
    let push = (modelJson.patterns as Record<string, Record<string, unknown>>)[
      "horizontal_push"
    ];
    assertEquals(push.confidence, "calibrating");

    // 3 more (total 6) with a data-backed trend → established (calibrating→
    // established is one monotonicAdvance step, landing on the 6th apply).
    for (let d = 4; d <= 6; d++) modelJson = await applyBench(d);
    push = (modelJson.patterns as Record<string, Record<string, unknown>>)[
      "horizontal_push"
    ];
    assertEquals(push.sessionCount, 6);
    assertEquals(push.confidence, "established");

    // Boundary guard (ADR-0020 / #269): advancing confidence must NOT derive
    // projections or set calibrationReviewFiredAt — that is #269's job.
    assertEquals(modelJson.projections, undefined);
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
