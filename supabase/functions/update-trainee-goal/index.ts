// Project Apex — update-trainee-goal Edge Function.
//
// #147 (spinoff from #146): onboarding-side write path for
// `trainee_models.model_json.goal`. The session-apply pipeline
// (update-trainee-model) has no goal-setter — its rule modules only
// mutate behavioural fields (patterns, exercises, recovery, etc.). This
// function is the goal-only write channel called from iOS onboarding.
//
// Single-writer invariant preserved per ADR-0006: this function is a
// server-side writer of model_json (not a client-side direct UPSERT),
// matching the same writer-class contract as update-trainee-model.
//
// Permissive semantics: re-onboarding (DeveloperSettingsView "Reset
// Onboarding") replays the write, overwriting any prior goal. Goal
// renegotiation lifecycle (ADR-0005 §goalLastRenegotiatedAt) is a
// separate future feature; this slice does not pre-build for it.
//
// Atomic merge: jsonb_set on the existing model_json so the EF
// session-apply pipeline's writes are not stomped if a session has
// already landed before onboarding completes. The COALESCE on the
// ON CONFLICT side handles the (theoretically impossible but
// defensively-safe) NULL-model_json case.
//
// See:
//   - ADR-0005 §"goal" — GoalState shape
//   - ADR-0006 §"writer/reader contract" — single-writer invariant
//   - docs/agents/edge-functions.md — secrets, deploy, local dev

import postgres from "postgres";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export interface UpdateTraineeGoalRequest {
  user_id: string;
  goal: {
    statement: string;
    focusAreas: string[];
    updatedAt: string;
  };
}

const ISO_DATE_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;

export function validateRequest(
  body: unknown,
): UpdateTraineeGoalRequest | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "request body must be a JSON object" };
  }
  const { user_id, goal } = body as Record<string, unknown>;
  if (typeof user_id !== "string" || !UUID_RE.test(user_id)) {
    return { error: "user_id must be a UUID string" };
  }
  if (typeof goal !== "object" || goal === null || Array.isArray(goal)) {
    return { error: "goal must be a JSON object" };
  }
  const g = goal as Record<string, unknown>;
  if (typeof g.statement !== "string") {
    return { error: "goal.statement must be a string" };
  }
  if (!Array.isArray(g.focusAreas)) {
    return { error: "goal.focusAreas must be an array of strings" };
  }
  for (let i = 0; i < g.focusAreas.length; i++) {
    if (typeof g.focusAreas[i] !== "string") {
      return {
        error: `goal.focusAreas[${i}] must be a string`,
      };
    }
  }
  if (typeof g.updatedAt !== "string" || !ISO_DATE_RE.test(g.updatedAt)) {
    return { error: "goal.updatedAt must be an ISO 8601 timestamp string" };
  }
  return {
    user_id,
    goal: {
      statement: g.statement,
      focusAreas: g.focusAreas as string[],
      updatedAt: g.updatedAt,
    },
  };
}

// deno-lint-ignore no-explicit-any
type Sql = any;

export interface UpsertGoalResult {
  ok: true;
  goal: UpdateTraineeGoalRequest["goal"];
}

/**
 * Upserts `model_json.goal` for the user. Idempotent: re-running with the
 * same payload yields the same end state. Permissive: re-running with a
 * different `goal` overwrites the prior value (renegotiation lifecycle is
 * not enforced here per #147 scope).
 *
 * On the INSERT path (no existing trainee_models row), `model_json` is
 * seeded with just `{ "goal": <goal> }`. The session-apply pipeline's
 * rule modules tolerate a sparse model_json (every read falls back to
 * `?? <default>` per A12 conventions), so the first applySession will
 * spread over this minimal row and populate the remaining fields.
 */
export async function upsertGoal(
  req: UpdateTraineeGoalRequest,
  sql: Sql,
): Promise<UpsertGoalResult> {
  await sql`
    INSERT INTO public.trainee_models (user_id, model_json, updated_at)
    VALUES (
      ${req.user_id},
      ${sql.json({ goal: req.goal })},
      NOW()
    )
    ON CONFLICT (user_id) DO UPDATE SET
      model_json = jsonb_set(
        COALESCE(public.trainee_models.model_json, '{}'::jsonb),
        '{goal}',
        ${sql.json(req.goal)},
        true
      ),
      updated_at = NOW()
  `;
  return { ok: true, goal: req.goal };
}

let cachedSql: Sql | undefined;
function getSql(): Sql {
  if (cachedSql) return cachedSql;
  const url = Deno.env.get("SUPABASE_DB_URL");
  if (!url) {
    throw new Error(
      "SUPABASE_DB_URL env var must be set to invoke upsertGoal from " +
        "the HTTP path (see docs/agents/edge-functions.md)",
    );
  }
  cachedSql = postgres(url);
  return cachedSql;
}

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, 405);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "request body must be valid JSON" }, 400);
  }

  const validated = validateRequest(body);
  if ("error" in validated) {
    return jsonResponse({ error: validated.error }, 400);
  }

  let sql: Sql;
  try {
    sql = getSql();
  } catch (e) {
    return jsonResponse(
      { error: e instanceof Error ? e.message : "DB unavailable" },
      500,
    );
  }

  try {
    const result = await upsertGoal(validated, sql);
    return jsonResponse(result, 200);
  } catch (e) {
    console.error("[update-trainee-goal] upsertGoal failed:", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : "internal error" },
      500,
    );
  }
}

if (import.meta.main) {
  Deno.serve(handleRequest);
}
