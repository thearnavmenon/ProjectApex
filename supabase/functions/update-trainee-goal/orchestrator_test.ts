// Project Apex — update-trainee-goal DB integration tests (#155).
//
// The validator (index_test.ts) covers request-shape rejection; this file
// covers the actual DB write behavior of `upsertGoal()` against the local
// Supabase Postgres (54322). The INSERT / ON CONFLICT jsonb_set paths only
// have meaning against real Postgres — PK conflict resolution, the
// COALESCE-NULL defense, and jsonb_set's preserve-siblings semantics are
// load-bearing and untestable with a mock. Ports the
// update-trainee-model/orchestrator_test.ts pattern.
//
// The highest-value scenario is #2: a re-onboarding write must NOT destroy
// the session-apply pipeline's accumulated state (patterns/exercises). The
// jsonb_set('{goal}') merge exists precisely to keep that state intact.
//
// Prereqs:
//   - `supabase start` running (DB at postgresql://postgres:postgres@127.0.0.1:54322/postgres)
//   - Migrations applied (20260506091314 baseline + Phase 2)
//
// Each test uses a unique UUID (no cross-test contamination, no cleanup
// between tests). Local DB orphans accumulate harmlessly across runs; CI
// resets the DB per build.
//
// Run locally:
//   deno test --allow-net --allow-env --allow-read --no-check \
//     supabase/functions/update-trainee-goal/orchestrator_test.ts

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import postgres from "postgres";
import { upsertGoal } from "./index.ts";

const DB_URL = "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

/**
 * Module-scoped SQL client shared across tests in this file. Each test uses
 * a unique UUID, so there's no cross-test state to clear; the client is
 * opened once and closed at the end of the file's run via the trailing
 * `_zz_close_sql_pool` sentinel test.
 */
const sql = postgres(DB_URL, { max: 4 });

const GOAL_A = {
  statement: "Hypertrophy (muscle size)",
  focusAreas: ["chest", "back"],
  updatedAt: "2026-05-12T10:00:00.000Z",
};

const GOAL_B = {
  statement: "Strength (1RM focus)",
  focusAreas: ["legs"],
  updatedAt: "2026-06-01T09:30:00.000Z",
};

/** Seeds the FK-parent `users` row only. */
async function seedUser(userId: string): Promise<void> {
  await sql`
    INSERT INTO public.users (id, display_name)
    VALUES (${userId}, ${"goal-test-" + userId.slice(0, 8)})
  `;
}

/**
 * Fresh user with NO trainee_models row — drives the INSERT path of
 * upsertGoal. Mirrors the production first-ever onboarding write.
 */
async function seedFreshUserWithoutRow(): Promise<string> {
  const userId = crypto.randomUUID();
  await seedUser(userId);
  return userId;
}

/**
 * Fresh user WITH an existing trainee_models row carrying `partialJson` as
 * model_json — drives the ON CONFLICT path of upsertGoal. Used to prove the
 * jsonb_set merge preserves pre-existing model state on re-onboarding.
 */
async function seedFreshUserWithExistingModel(
  partialJson: Record<string, unknown>,
): Promise<string> {
  const userId = crypto.randomUUID();
  await seedUser(userId);
  await sql`
    INSERT INTO public.trainee_models (user_id, model_json)
    VALUES (${userId}, ${sql.json(partialJson)})
  `;
  return userId;
}

// All tests share the module-scoped postgres.js client. The driver keeps a
// keepalive timer alive between queries, which Deno's per-test resource
// sanitizer flags as a leak. Disabling sanitizeOps + sanitizeResources is
// the right choice — the pool IS closed at file-end via the sentinel
// `_zz_close_sql_pool` test. Mirrors update-trainee-model/orchestrator_test.ts.
const goalTest = (name: string, fn: () => Promise<void>): void => {
  Deno.test({ name, fn, sanitizeOps: false, sanitizeResources: false });
};

goalTest(
  "#155 (1): fresh user (no trainee_models row) → INSERT path seeds model_json with ONLY the goal key",
  async () => {
    const userId = await seedFreshUserWithoutRow();

    const result = await upsertGoal({ user_id: userId, goal: GOAL_A }, sql);
    assertEquals(result.ok, true);
    assertEquals(result.goal, GOAL_A);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(rows.length, 1, "INSERT must create exactly one row");
    const modelJson = rows[0].model_json as Record<string, unknown>;

    // Only `goal` is seeded — the session-apply pipeline populates the rest
    // (it tolerates a sparse model_json per the upsertGoal doc-comment).
    assertEquals(Object.keys(modelJson), ["goal"]);
    assertEquals(modelJson.goal, GOAL_A);
  },
);

goalTest(
  "#155 (2): existing row with non-goal state → ON CONFLICT sets goal; every OTHER top-level key byte-identical (re-onboarding must not destroy session state)",
  async () => {
    // Seed the kind of state the session-apply pipeline accumulates — these
    // keys must survive a goal write byte-for-byte.
    const seed = {
      patterns: {
        squat: { currentPhase: "accumulation", sessionsInPhase: 3, trend: "progressing" },
      },
      exercises: {
        barbell_back_squat: { e1rmCurrent: 151.6667, sessionCount: 2 },
      },
      totalSessionCount: 2,
    };
    const userId = await seedFreshUserWithExistingModel(seed);

    await upsertGoal({ user_id: userId, goal: GOAL_A }, sql);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;

    // Goal written...
    assertEquals(modelJson.goal, GOAL_A);

    // ...and the non-goal subtree is jsonb-equal to the seed. `model_json -
    // 'goal'` strips the just-written goal key; Postgres jsonb equality is
    // the strongest "untouched" assertion available (semantic, not textual).
    const cmp = await sql`
      SELECT (model_json - 'goal') = ${sql.json(seed)}::jsonb AS equal
      FROM public.trainee_models WHERE user_id = ${userId}
    `;
    assertEquals(
      cmp[0].equal,
      true,
      "every non-goal top-level key must be untouched by the goal write",
    );
  },
);

goalTest(
  "#155 (3): existing prior goal → overwrite (re-onboarding semantics, permissive per #147)",
  async () => {
    const userId = await seedFreshUserWithExistingModel({ goal: GOAL_A });

    await upsertGoal({ user_id: userId, goal: GOAL_B }, sql);

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;
    assertEquals(modelJson.goal, GOAL_B);
    assertEquals(Object.keys(modelJson), ["goal"]);
  },
);

goalTest(
  "#155 (4): idempotent re-upsert → identical model_json end state across two calls with the same payload",
  async () => {
    const userId = await seedFreshUserWithoutRow();

    await upsertGoal({ user_id: userId, goal: GOAL_A }, sql);
    const after1 = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;

    await upsertGoal({ user_id: userId, goal: GOAL_A }, sql);
    const after2 = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;

    // model_json is identical (updated_at advances via NOW() and is
    // intentionally excluded from the comparison).
    assertEquals(after2[0].model_json, after1[0].model_json);
  },
);

goalTest(
  "#155 (5): goal survives a simulated session-apply spread (jsonb_set into '{patterns,squat}')",
  async () => {
    const userId = await seedFreshUserWithoutRow();
    await upsertGoal({ user_id: userId, goal: GOAL_A }, sql);

    // Simulate the session-apply pipeline writing into a nested path. jsonb_set
    // does NOT create intermediate parents, so the inner call seeds '{patterns}'
    // = {} before the outer call sets '{patterns,squat}' — together this models
    // a session write landing on a goal-only row.
    await sql`
      UPDATE public.trainee_models
      SET model_json = jsonb_set(
        jsonb_set(COALESCE(model_json, '{}'::jsonb), '{patterns}', '{}'::jsonb, true),
        '{patterns,squat}',
        ${sql.json({ currentPhase: "accumulation", sessionsInPhase: 1 })}::jsonb,
        true
      )
      WHERE user_id = ${userId}
    `;

    const rows = await sql`
      SELECT model_json FROM public.trainee_models WHERE user_id = ${userId}
    `;
    const modelJson = rows[0].model_json as Record<string, unknown>;

    // Goal untouched by the nested write.
    assertEquals(modelJson.goal, GOAL_A);
    // ...and the session write actually landed.
    const patterns = modelJson.patterns as Record<string, unknown>;
    assertExists(patterns.squat);
  },
);

// Sentinel "test" that runs last — closes the shared pool so the connection
// lifecycle stays local to this file rather than relying on process-exit.
Deno.test({
  name: "_zz_close_sql_pool",
  fn: async () => {
    await sql.end();
  },
  sanitizeOps: false,
  sanitizeResources: false,
});
