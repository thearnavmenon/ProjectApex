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
// Onboarding") replays the write, overwriting any prior goal. When the goal
// genuinely changes and projections already exist, this is a goal
// RENEGOTIATION (#304, ADR-0022): each projection's stretch is silently
// re-derived upward-only and `goalLastRenegotiatedAt` is stamped, atomic with
// the goal write (see applyGoalWrite + renegotiation.ts). The goal-AWARE
// version — where the new goal itself moves targets — is deferred to #305.
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
import { MAJOR_PATTERNS } from "../_shared/constants.ts";
import type { PatternProjection } from "../_shared/calibration-projection.ts";
import {
  isRenegotiation,
  rederiveStretchOnRenegotiation,
  type RenegotiableGoal,
} from "./renegotiation.ts";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Membership set for validating `stretch_edits[].pattern` (#296, #269). */
const MAJOR_PATTERN_SET: ReadonlySet<string> = new Set(MAJOR_PATTERNS);

/** A single edit raising one major pattern's stretch target (#296, #269). */
export interface StretchEdit {
  pattern: string;
  stretch: number;
}

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
  // P5-D06 Slice B (#258): OPTIONAL. When present, the EF idempotently
  // appends this triggering-session count to
  // `model_json.acknowledgedTriggeringSessionCounts` (the Slice-A camelCase
  // key). Absent for onboarding (a brand-new user cannot have a GPA fire);
  // sent only by the goal-review screen's Save (a later slice).
  acknowledge_triggering_session_count?: number;
  // #296 (#269): OPTIONAL. Athlete-raised stretch targets from the
  // calibration-review screen. Each entry raises ONE major pattern's stretch;
  // the server clamps upward-only (never below the stored value) and never
  // accepts a floor. Absent for onboarding / heavy-reassessment saves.
  stretch_edits?: StretchEdit[];
  // #269 S4: OPTIONAL. When true, the EF durably records that the athlete has
  // seen the one-time calibration-review screen by setting
  // `model_json.calibrationReviewAcknowledged = true`, so the pre-workout
  // calibration banner does not reappear after a session sync rehydrates the
  // local cache. Absent for onboarding / goal-review saves.
  acknowledge_calibration_review?: boolean;
}

const ISO_DATE_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;

export function validateRequest(
  body: unknown,
): UpdateTraineeGoalRequest | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "request body must be a JSON object" };
  }
  const {
    user_id,
    goal,
    acknowledge_triggering_session_count,
    stretch_edits,
    acknowledge_calibration_review,
  } = body as Record<string, unknown>;
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
  // P5-D06 Slice B (#258): OPTIONAL ack. Absent → valid exactly as before
  // (back-compat: onboarding never sends it). Present → must be a
  // non-negative integer.
  if (
    acknowledge_triggering_session_count !== undefined &&
    !(
      typeof acknowledge_triggering_session_count === "number" &&
      Number.isInteger(acknowledge_triggering_session_count) &&
      acknowledge_triggering_session_count >= 0
    )
  ) {
    return {
      error:
        "acknowledge_triggering_session_count must be a non-negative integer",
    };
  }
  // #296 (#269): OPTIONAL stretch_edits. Absent → valid exactly as before.
  // Present → an array of { pattern (a major movement pattern), stretch
  // (a positive number) }. Upward-only clamping is enforced server-side at
  // write time, not here.
  let validatedEdits: StretchEdit[] | undefined;
  if (stretch_edits !== undefined) {
    if (!Array.isArray(stretch_edits)) {
      return { error: "stretch_edits must be an array" };
    }
    validatedEdits = [];
    for (let i = 0; i < stretch_edits.length; i++) {
      const e = stretch_edits[i];
      if (typeof e !== "object" || e === null || Array.isArray(e)) {
        return { error: `stretch_edits[${i}] must be an object` };
      }
      const er = e as Record<string, unknown>;
      if (typeof er.pattern !== "string" || !MAJOR_PATTERN_SET.has(er.pattern)) {
        return { error: `stretch_edits[${i}].pattern must be a major movement pattern` };
      }
      if (
        typeof er.stretch !== "number" || !Number.isFinite(er.stretch) ||
        er.stretch <= 0
      ) {
        return { error: `stretch_edits[${i}].stretch must be a positive number` };
      }
      validatedEdits.push({ pattern: er.pattern, stretch: er.stretch });
    }
  }
  // #269 S4: OPTIONAL calibration-review ack. Absent → valid exactly as before.
  // Present → must be a boolean.
  if (
    acknowledge_calibration_review !== undefined &&
    typeof acknowledge_calibration_review !== "boolean"
  ) {
    return { error: "acknowledge_calibration_review must be a boolean" };
  }
  const validated: UpdateTraineeGoalRequest = {
    user_id,
    goal: {
      statement: g.statement,
      focusAreas: g.focusAreas as string[],
      updatedAt: g.updatedAt,
    },
  };
  if (acknowledge_triggering_session_count !== undefined) {
    validated.acknowledge_triggering_session_count =
      acknowledge_triggering_session_count as number;
  }
  if (validatedEdits !== undefined) {
    validated.stretch_edits = validatedEdits;
  }
  if (acknowledge_calibration_review !== undefined) {
    validated.acknowledge_calibration_review =
      acknowledge_calibration_review as boolean;
  }
  return validated;
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
 * different `goal` overwrites the prior value — and, when projections exist,
 * triggers the silent renegotiation stretch re-derivation in `applyGoalWrite`
 * (#304, ADR-0022).
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
  await applyGoalWrite(req, sql);

  // P5-D06 Slice B (#258): when the goal-review Save acknowledges a
  // heavy-reassessment trigger, idempotently array-append the triggering
  // session count to the Slice-A camelCase key. Separate statement, same
  // connection — the goal write above stays byte-for-byte unchanged.
  //
  // The COALESCE(..., '[]') on BOTH the read and the @> containment guard is
  // load-bearing: a bare `model_json->'key' @> x` is NULL (not false) when
  // the key is absent, and `NOT NULL` is NULL — so without the COALESCE the
  // first-ever ack would silently never append. The `NOT @>` guard makes
  // re-acking an already-present count a no-op.
  if (req.acknowledge_triggering_session_count !== undefined) {
    const ack = req.acknowledge_triggering_session_count;
    await sql`
      UPDATE public.trainee_models
      SET model_json = jsonb_set(
        COALESCE(model_json, '{}'::jsonb),
        '{acknowledgedTriggeringSessionCounts}',
        COALESCE(model_json -> 'acknowledgedTriggeringSessionCounts', '[]'::jsonb)
          || to_jsonb(${ack}::int),
        true
      )
      WHERE user_id = ${req.user_id}
        AND NOT (
          COALESCE(model_json -> 'acknowledgedTriggeringSessionCounts', '[]'::jsonb)
            @> to_jsonb(${ack}::int)
        )
    `;
  }

  // #296 (#269): apply athlete-raised stretch targets (upward-only clamp).
  if (req.stretch_edits !== undefined && req.stretch_edits.length > 0) {
    await applyStretchEdits(req.user_id, req.stretch_edits, sql);
  }

  // #269 S4: durably record that the athlete has seen the one-time
  // calibration-review screen so the pre-workout banner does not reappear after
  // a session sync rehydrates the local cache. Separate statement, same
  // connection — like the ack-append block above. Idempotent: re-running with
  // the flag set leaves the value at `true`. The goal write above stays
  // byte-for-byte unchanged.
  if (req.acknowledge_calibration_review === true) {
    await sql`
      UPDATE public.trainee_models
      SET model_json = jsonb_set(
        COALESCE(model_json, '{}'::jsonb),
        '{calibrationReviewAcknowledged}',
        'true'::jsonb,
        true
      )
      WHERE user_id = ${req.user_id}
    `;
  }

  return { ok: true, goal: req.goal };
}

/**
 * Goal write + (when the goal genuinely changed) silent renegotiation stretch
 * re-derivation, in ONE `FOR UPDATE` transaction so the new goal, the
 * re-derived stretch, and `goalLastRenegotiatedAt` commit atomically (#304,
 * ADR-0022). The prior goal is read BEFORE the overwrite — this is the only
 * writer that sees old + new goal together, which is what makes
 * "the goal actually changed" detectable (a later session-apply has already
 * lost the prior goal).
 *
 * Renegotiation re-derivation is skipped (and the timestamp NOT stamped) unless
 * a prior non-placeholder goal existed, it differs from the incoming goal, and
 * projections already exist. So onboarding's first goal-set (no prior goal) and
 * the calibration-review save (goal byte-identical) never trigger it. The
 * re-derive is computed from the locked prior snapshot and is upward-only
 * (floor immovable); progress is left for the next session-apply to refresh,
 * matching the #296 manual-edit path.
 */
async function applyGoalWrite(
  req: UpdateTraineeGoalRequest,
  sql: Sql,
): Promise<void> {
  await sql.begin(async (tx: Sql) => {
    const rows = await tx`
      SELECT model_json FROM public.trainee_models
      WHERE user_id = ${req.user_id}
      FOR UPDATE
    `;
    const priorJson =
      (rows[0]?.model_json ?? null) as Record<string, unknown> | null;

    // Goal write — same jsonb_set merge / COALESCE-NULL defense as before,
    // now inside the transaction so it commits atomically with the re-derive.
    await tx`
      INSERT INTO public.trainee_models (user_id, model_json, updated_at)
      VALUES (
        ${req.user_id},
        ${tx.json({ goal: req.goal })},
        NOW()
      )
      ON CONFLICT (user_id) DO UPDATE SET
        model_json = jsonb_set(
          COALESCE(public.trainee_models.model_json, '{}'::jsonb),
          '{goal}',
          ${tx.json(req.goal)},
          true
        ),
        updated_at = NOW()
    `;

    // Silent renegotiation re-derivation (computed from the LOCKED prior
    // snapshot, so a concurrent session-apply cannot clobber it).
    if (priorJson === null) return; // brand-new user → nothing to renegotiate
    const priorGoal = priorJson.goal as RenegotiableGoal | undefined;
    if (!isRenegotiation(priorGoal, req.goal)) return;

    const projections = (priorJson.projections as {
      patternProjections?: PatternProjection[];
    } | undefined)?.patternProjections;
    if (!Array.isArray(projections) || projections.length === 0) return;

    const patterns =
      (priorJson.patterns ?? {}) as Record<string, Record<string, unknown>>;
    const trendByPattern: Record<string, string | undefined> = {};
    for (const [pattern, profile] of Object.entries(patterns)) {
      trendByPattern[pattern] = profile.trend as string | undefined;
    }

    const rederived = rederiveStretchOnRenegotiation(projections, trendByPattern);
    const renegotiatedAt = new Date().toISOString();
    await tx`
      UPDATE public.trainee_models
      SET model_json = jsonb_set(
        jsonb_set(
          model_json,
          '{projections,patternProjections}',
          ${tx.json(rederived)},
          true
        ),
        '{projections,goalLastRenegotiatedAt}',
        ${tx.json(renegotiatedAt)},
        true
      ),
      updated_at = NOW()
      WHERE user_id = ${req.user_id}
    `;
  });
}

/**
 * Apply athlete-raised stretch targets to `model_json.projections.
 * patternProjections` (#296, #269). Upward-only: each edit is clamped to
 * `max(stored_stretch, edited)` — a lower (or below-floor) value is a no-op,
 * and the immovable `floor` is never touched (the client cannot lower a target
 * or misstate capability). Runs in a `FOR UPDATE` transaction so a concurrent
 * session-apply (which also writes `projections`) cannot clobber the edit, and
 * vice-versa. Writes only the `projections.patternProjections` leaf.
 *
 * Progress is intentionally NOT recomputed here (it needs the live per-pattern
 * e1RM history the session-apply pipeline owns); the next session-apply's
 * progress-recompute arm refreshes it. Patterns with no existing projection,
 * or a model with no projections yet, are no-ops.
 */
export async function applyStretchEdits(
  userId: string,
  edits: StretchEdit[],
  sql: Sql,
): Promise<void> {
  if (edits.length === 0) return;
  const editMap = new Map(edits.map((e) => [e.pattern, e.stretch]));
  await sql.begin(async (tx: Sql) => {
    const rows = await tx`
      SELECT model_json FROM public.trainee_models
      WHERE user_id = ${userId}
      FOR UPDATE
    `;
    if (rows.length === 0) return;
    const modelJson = (rows[0].model_json ?? {}) as Record<string, unknown>;
    const projections = modelJson.projections as {
      patternProjections?: Array<Record<string, unknown>>;
    } | undefined;
    const list = projections?.patternProjections;
    if (!Array.isArray(list) || list.length === 0) return;

    let changed = false;
    const updated = list.map((p) => {
      const edited = editMap.get(p.pattern as string);
      if (edited === undefined) return p;
      const stored = p.stretch as number;
      const accepted = Math.max(stored, edited); // upward-only clamp
      if (accepted !== stored) {
        changed = true;
        return { ...p, stretch: accepted };
      }
      return p;
    });
    if (!changed) return;

    await tx`
      UPDATE public.trainee_models
      SET model_json = jsonb_set(
        COALESCE(model_json, '{}'::jsonb),
        '{projections,patternProjections}',
        ${tx.json(updated)},
        true
      ),
      updated_at = NOW()
      WHERE user_id = ${userId}
    `;
  });
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
