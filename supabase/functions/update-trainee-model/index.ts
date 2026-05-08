// Project Apex — update-trainee-model Edge Function.
//
// Phase 2 / Slice A12 (issue #83): Stage 1 orchestrator. Wires every Phase 2
// rule module into a single transactional commit on every session-apply.
// Replaces Phase 1's no-op stub. Per ADR-0006 §"Idempotency at the DB layer",
// ADR-0008 §"Late arrival", and ADR-0013 §"Stage sequencing":
//   1. INSERT into trainee_model_applied_sessions ON CONFLICT DO NOTHING.
//      If row already existed → return cached snapshot (idempotent retry).
//   2. SELECT model_json + watermark FOR UPDATE.
//   3. Watermark check: if incoming.loggedAt < watermark → emit event,
//      do not mutate, return cached snapshot with late_arrival:true.
//   4. Apply rules in dependency order (cycles 8-12 below; cycle 1 is the
//      tracer — increments session_count without rule application).
//   5. Write back model_json + advance watermark.
//
// Stage 2 (classifier per ADR-0013) is owned by issue #A13 and is NOT
// triggered here. Cached-snapshot returns and late-arrival refusals MUST
// NOT fire Stage 2 — first-apply-fires-once is the contract.
//
// Slice 6 (issue #10): payload validator descends into
// session_payload.set_logs[] (when present) and rejects any element
// missing or carrying an invalid `intent` field. See ADR-0005 (no silent
// defaults at any layer).
//
// See:
//   - ADR-0005 (TraineeModel shape, set-intent invariant)
//   - ADR-0006 (server-side placement, idempotency at DB layer)
//   - ADR-0008 (late-arrival watermark)
//   - ADR-0013 (Stage 2 separation)
//   - docs/agents/edge-functions.md (secrets, deploy, local dev)

import {
  emitApplyComplete as defaultEmitApplyComplete,
  emitLateArrival as defaultEmitLateArrival,
  type ApplyCompleteEvent,
  type LateArrivalEvent,
} from "../_shared/observability.ts";
import {
  advancePhase,
  sessionsRequiredFor,
  type MesocyclePhase,
  type PerPatternState,
} from "../_shared/phase-advance.ts";
import { computeTransitionModeUntil } from "../_shared/transition-mode-expiry.ts";
import type { ProgressionTrend } from "../_shared/plateau-verdict.ts";
import {
  shouldFireGlobalPhaseAdvance,
  type PatternTransitionState,
} from "../_shared/global-phase-advance.ts";

export interface UpdateTraineeModelRequest {
  user_id: string;
  session_id: string;
  session_payload: Record<string, unknown>;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// SetIntent — must mirror the Swift `SetIntent` enum (TraineeModelEnums.swift)
// and the eventual `set_logs.intent` CHECK constraint. Any drift breaks the
// no-silent-defaults invariant.
const VALID_INTENTS = new Set([
  "warmup",
  "top",
  "backoff",
  "technique",
  "amrap",
]);

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function validateRequest(
  body: unknown,
): UpdateTraineeModelRequest | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "request body must be a JSON object" };
  }
  const { user_id, session_id, session_payload } = body as Record<
    string,
    unknown
  >;
  if (typeof user_id !== "string" || !UUID_RE.test(user_id)) {
    return { error: "user_id must be a UUID string" };
  }
  if (typeof session_id !== "string" || !UUID_RE.test(session_id)) {
    return { error: "session_id must be a UUID string" };
  }
  if (
    typeof session_payload !== "object" ||
    session_payload === null ||
    Array.isArray(session_payload)
  ) {
    return { error: "session_payload must be a JSON object" };
  }
  const payload = session_payload as Record<string, unknown>;

  // Slice 6 — validate set_logs[] when present. Forward-compatible: when
  // session_payload omits set_logs entirely, the request still passes (the
  // actual call site is wired in Slice 9c+). When the array is present,
  // every element must carry a valid intent — no silent default.
  if ("set_logs" in payload) {
    const setLogs = payload.set_logs;
    if (!Array.isArray(setLogs)) {
      return { error: "session_payload.set_logs must be an array" };
    }
    for (let i = 0; i < setLogs.length; i++) {
      const entry = setLogs[i];
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
        return {
          error: `session_payload.set_logs[${i}] must be a JSON object`,
        };
      }
      const intent = (entry as Record<string, unknown>).intent;
      if (intent === undefined || intent === null) {
        return {
          error: `session_payload.set_logs[${i}] missing required field 'intent'`,
        };
      }
      if (typeof intent !== "string" || !VALID_INTENTS.has(intent)) {
        return {
          error:
            `session_payload.set_logs[${i}].intent must be one of ` +
            `warmup/top/backoff/technique/amrap (got ${JSON.stringify(intent)})`,
        };
      }
    }
  }

  return {
    user_id,
    session_id,
    session_payload: payload,
  };
}

/**
 * Stage 1 orchestrator output. Mirrors the HTTP response body shape: the
 * snapshot returned to the client + the late_arrival flag from ADR-0008.
 *
 * `late_arrival_details` is populated only when `late_arrival === true`,
 * carrying the fields the WAQ adapter passes into LateArrivalNotification
 * (sessionId, incomingLoggedAt, watermark) per A12's richer-response contract.
 */
export interface ApplySessionResult {
  trainee_model: Record<string, unknown>;
  late_arrival: boolean;
  late_arrival_details?: {
    session_id: string;
    incoming_logged_at: string;
    watermark: string;
  };
}

/**
 * Type alias for the postgres.js client. Tests inject a shared client; the
 * production HTTP wrapper opens one per cold start.
 *
 * Production note: when this Edge Function deploys, the connection should
 * use Supabase's pgbouncer endpoint (port 6543) rather than the direct
 * Postgres port (5432) — Edge Functions are stateless with cold-start
 * potential, and pgbouncer handles connection multiplexing across
 * invocations. Tests use the direct port since they're long-running.
 */
// deno-lint-ignore no-explicit-any
type Sql = any;

/**
 * Optional dependency injections for `applySession`. Tests use these to
 * spy on observability emits and inject synthetic rule failures (cycle 8's
 * atomic-rollback test). Production omits them entirely — defaults route
 * to the real observability module.
 *
 * `ruleHook` is the injection seam for cycles 10-12: the orchestrator will
 * thread real rule composition through this hook in the resume session.
 * For cycle 8 (atomic rollback), tests inject a hook that throws so the
 * surrounding sql.begin() rolls back atomically.
 */
export interface ApplySessionDeps {
  emitLateArrival?: (event: LateArrivalEvent) => void;
  /**
   * Per-apply summary observability per slice A12. Called on the in-order
   * first-apply path (after Stage 1 commit, alongside stage2Hook). Cached
   * returns and late-arrival refusals do NOT emit — the envelope describes
   * a mutation, and those paths don't mutate.
   */
  emitApplyComplete?: (event: ApplyCompleteEvent) => void;
  /**
   * Synthetic-failure injection seam used by cycle 8's atomic-rollback test.
   * When provided, runs INSTEAD of the real rule pipeline (so tests can throw
   * without competing with real rule logic). Production omits this; the real
   * pipeline runs unconditionally.
   */
  ruleHook?: (modelJson: Record<string, unknown>) => Record<string, unknown>;
  /**
   * Stage 2 (classifier) seam per ADR-0013. Fires AFTER Stage 1 commits, and
   * ONLY when Stage 1 took the in-order first-apply path — never on cached-
   * snapshot returns (PK conflict) or late-arrival refusals. Issue #A13
   * wires the actual classifier call through this hook; this slice ships
   * the seam + the contract.
   */
  stage2Hook?: () => Promise<void> | void;
}

/**
 * postgres.js returns jsonb columns as parsed JS values most of the time,
 * but `'{}'::jsonb` literals seeded in tests can come back as strings
 * depending on driver-version quirks. Normalize defensively so the
 * orchestrator always works with an object.
 */
function parseJsonbColumn(value: unknown): Record<string, unknown> {
  if (value == null) return {};
  if (typeof value === "string") return JSON.parse(value);
  return value as Record<string, unknown>;
}

/**
 * Mean inter-session delta in days from a list of ISO-8601 session dates,
 * or null when fewer than 2 sessions exist (long-absence-returner case).
 * Mirrors `PatternProfile.sessionsCadenceDays` Swift derived property
 * (TraineeModelProfiles.swift:185).
 */
function sessionsCadenceDays(recentSessionDates: string[]): number | null {
  if (recentSessionDates.length < 2) return null;
  const sorted = [...recentSessionDates].sort();
  const ms = sorted.map((s) => new Date(s).getTime());
  let totalDelta = 0;
  for (let i = 1; i < ms.length; i++) {
    totalDelta += (ms[i] - ms[i - 1]) / (24 * 60 * 60 * 1000);
  }
  return totalDelta / (ms.length - 1);
}

/**
 * Per-pattern rule pipeline. Reads patterns dict from model_json, runs the
 * rules each pattern needs, returns updated patterns dict + rule-fired list +
 * field-change list for the per-apply observability emit.
 *
 * Cycles 10-12 wire only the rules with assertion-cycles in this slice:
 * advancePhase + composeTransitionModeUntil. Other rule modules (EWMA,
 * plateau-verdict, recovery, prescription-accuracy, transfer-regression,
 * fatigue-interaction) ship in follow-up slices because they have no
 * assertion-cycle here. The pipeline framework supports adding them later
 * by extending this loop.
 */
function applyPerPatternRules(
  patterns: Record<string, Record<string, unknown>>,
  incomingLoggedAt: Date,
  newSessionCount: number,
): {
  patterns: Record<string, Record<string, unknown>>;
  rulesFired: Set<string>;
  fieldsChanged: string[];
} {
  const rulesFired = new Set<string>();
  const fieldsChanged: string[] = [];
  const newPatterns: Record<string, Record<string, unknown>> = {};

  for (const [patternKey, raw] of Object.entries(patterns)) {
    const profile = raw;
    const recentDates = (profile.recentSessionDates as string[] | undefined) ?? [];
    const cadenceDays = sessionsCadenceDays(recentDates);
    // ADR-0011 Option-B threshold input: derive daysPerWeek from cadence.
    // Cadence-aware (ADR-0015) — high-frequency cadence → larger daysPerWeek;
    // null cadence (long-absence-returner) defaults to 4 (alpha-cohort
    // typical 4×/week). The orchestrator owns this default; rule modules
    // are pure and trust the input.
    const daysPerWeek = cadenceDays !== null ? 7 / cadenceDays : 4;

    const advanceState: PerPatternState = {
      currentPhase: profile.currentPhase as MesocyclePhase,
      sessionsInPhase: (profile.sessionsInPhase as number) ?? 0,
      sessionsRequiredForPhase: sessionsRequiredFor(
        profile.currentPhase as MesocyclePhase,
        daysPerWeek,
      ),
      trend: ((profile.trend as ProgressionTrend) ?? "progressing"),
      consecutiveForceDeloadsOnPattern:
        (profile.consecutiveForceDeloadsOnPattern as number) ?? 0,
      lastPhaseTransitionAtSessionCount:
        (profile.lastPhaseTransitionAtSessionCount as number) ?? 0,
    };

    const advanced = advancePhase(advanceState, newSessionCount);
    rulesFired.add("phase-advance");

    let newTransitionModeUntil: string | null =
      (profile.transitionModeUntil as string | null) ?? null;

    if (advanced.firesDeloadEndTransitionMode) {
      const currentUntil =
        newTransitionModeUntil !== null ? new Date(newTransitionModeUntil) : null;
      newTransitionModeUntil = computeTransitionModeUntil(
        incomingLoggedAt,
        cadenceDays,
        currentUntil,
      ).toISOString();
      rulesFired.add("transition-mode-expiry");
      fieldsChanged.push(`patterns.${patternKey}.transitionModeUntil`);
    }

    if (advanced.fired !== "no-op") {
      fieldsChanged.push(`patterns.${patternKey}.currentPhase`);
    }

    newPatterns[patternKey] = {
      ...profile,
      currentPhase: advanced.newPhase,
      sessionsInPhase: advanced.newSessionsInPhase,
      consecutiveForceDeloadsOnPattern: advanced.newConsecutiveForceDeloads,
      lastPhaseTransitionAtSessionCount:
        advanced.newLastPhaseTransitionAtSessionCount,
      transitionModeUntil: newTransitionModeUntil,
    };
  }

  return { patterns: newPatterns, rulesFired, fieldsChanged };
}

/**
 * Stage 1 orchestrator core. Pure of HTTP concerns — accepts the validated
 * request shape and a SQL client; returns the response body. Tests bypass
 * the HTTP wrapper and call this directly against the local Supabase DB.
 *
 * Input validation boundary: `applySession` trusts that
 * `validateRequest` has already verified the shape (UUIDs, set_logs[].intent).
 * Rule modules trust `applySession` to feed them well-formed JSONB-derived
 * state. Bad data inside `model_json` (e.g., a wrong-type field from an
 * older Phase 1 row) MUST surface as a clean `applySession` error rather
 * than a runtime exception inside a rule module — the orchestrator is the
 * boundary for upstream-data validation; rule modules are pure.
 */
export async function applySession(
  req: UpdateTraineeModelRequest,
  sql: Sql,
  deps: ApplySessionDeps = {},
): Promise<ApplySessionResult> {
  const applyStartMs = Date.now();
  const emitLateArrival = deps.emitLateArrival ?? defaultEmitLateArrival;
  const emitApplyComplete = deps.emitApplyComplete ?? defaultEmitApplyComplete;
  // Extract logged_at from session_payload — load-bearing for watermark check
  // (ADR-0008). Fail fast at the orchestrator boundary if missing/invalid;
  // rule modules trust this is present.
  const loggedAtRaw = (req.session_payload as Record<string, unknown>).logged_at;
  if (typeof loggedAtRaw !== "string") {
    throw new Error("session_payload.logged_at must be an ISO 8601 string");
  }
  const incomingLoggedAt = new Date(loggedAtRaw);
  if (Number.isNaN(incomingLoggedAt.getTime())) {
    throw new Error(`session_payload.logged_at is not a valid date: ${loggedAtRaw}`);
  }

  // Tracks whether Stage 1 took the in-order first-apply path — the only
  // path that fires Stage 2 per ADR-0013 §"WAQ retry idempotency". Cached
  // returns and late-arrival refusals leave this false; the post-commit
  // stage2Hook + emitApplyComplete calls are gated on it.
  let firedFirstApply = false;
  let rulesFired: string[] = [];
  let fieldsChanged: string[] = [];

  const result: ApplySessionResult = await sql.begin(async (tx: Sql) => {
    // Step 1: idempotency PK insert (ADR-0006 §2). RETURNING xmax=0 returns
    // true when this transaction inserted the row, false when ON CONFLICT
    // matched a prior insert. The PK enforces single-application globally.
    const inserted = await tx`
      INSERT INTO public.trainee_model_applied_sessions (user_id, session_id)
      VALUES (${req.user_id}, ${req.session_id})
      ON CONFLICT DO NOTHING
      RETURNING xmax = 0 AS inserted
    `;

    if (inserted.length === 0) {
      // PK conflict — duplicate session-apply. Return cached snapshot per
      // ADR-0006 §2; ADR-0013 contract: Stage 2 is NOT re-triggered here.
      const cached = await tx`
        SELECT model_json FROM public.trainee_models WHERE user_id = ${req.user_id}
      `;
      return {
        trainee_model: parseJsonbColumn(cached[0]?.model_json),
        late_arrival: false,
      } satisfies ApplySessionResult;
    }

    // Step 2: load current model + watermark + session_count with row lock.
    // session_count is read explicitly so the rule pipeline can pass the
    // post-increment value into rules whose outputs depend on it (e.g.,
    // advancePhase's lastPhaseTransitionAtSessionCount).
    const rows = await tx`
      SELECT model_json, last_applied_logged_at, session_count
      FROM public.trainee_models
      WHERE user_id = ${req.user_id}
      FOR UPDATE
    `;
    const modelJson = parseJsonbColumn(rows[0]?.model_json);
    const watermark: Date | null = rows[0]?.last_applied_logged_at ?? null;
    const newSessionCount = (rows[0]?.session_count ?? 0) + 1;

    // Step 3: watermark check (ADR-0008 §"Late arrival"). Strict less-than:
    // incoming === watermark is in-order (see cycle 5b). The PK insert from
    // step 1 stays committed so WAQ retries dedupe via the cached path on
    // subsequent calls. Watermark + model_json are NOT mutated on refusal.
    if (watermark !== null && incomingLoggedAt < watermark) {
      // delta_seconds is negative — incoming is `delta_seconds` before watermark
      // per the LateArrivalEvent contract (observability.ts).
      const deltaSeconds = Math.round(
        (incomingLoggedAt.getTime() - watermark.getTime()) / 1000,
      );
      emitLateArrival({
        user_id: req.user_id,
        session_id: req.session_id,
        incoming_logged_at: incomingLoggedAt.toISOString(),
        watermark: watermark.toISOString(),
        delta_seconds: deltaSeconds,
      });
      return {
        trainee_model: modelJson,
        late_arrival: true,
        late_arrival_details: {
          session_id: req.session_id,
          incoming_logged_at: incomingLoggedAt.toISOString(),
          watermark: watermark.toISOString(),
        },
      } satisfies ApplySessionResult;
    }

    // Step 4: rule composition. The synthetic ruleHook (cycle 8 atomic-
    // rollback test) overrides the real pipeline when provided so tests can
    // throw without competing with rule logic. A throw here — synthetic or
    // real — aborts sql.begin() and rolls back the whole transaction (PK
    // insert, watermark advance, and model_json write all revert).
    //
    // Rule scope this slice: phase-advance + transition-mode-expiry per the
    // assertion-cycles 10-12. Other rule modules (EWMA, plateau-verdict,
    // recovery, prescription-accuracy, transfer-regression, fatigue-
    // interaction) ship in follow-up slices because they have no assertion-
    // cycle in this slice; the per-pattern loop is the framework they'll
    // extend into.
    let newModelJson: Record<string, unknown>;
    if (deps.ruleHook) {
      newModelJson = deps.ruleHook(modelJson);
    } else {
      const patternsIn = (modelJson.patterns as Record<string, Record<string, unknown>> | undefined) ?? {};
      const ruled = applyPerPatternRules(patternsIn, incomingLoggedAt, newSessionCount);
      newModelJson = { ...modelJson, patterns: ruled.patterns };
      rulesFired = [...ruled.rulesFired];
      fieldsChanged = ruled.fieldsChanged;

      // ADR-0012: global phase-advance trigger. Reads each pattern's
      // post-loop lastPhaseTransitionAtSessionCount (which the per-pattern
      // loop above just updated for any pattern that transitioned this
      // apply). Force-deload-as-transition is feature, not bug — see
      // ADR-0012 §Consequences.
      const patternStates: PatternTransitionState[] = Object.entries(
        ruled.patterns,
      ).map(([pattern, profile]) => ({
        pattern,
        lastPhaseTransitionAtSessionCount:
          (profile.lastPhaseTransitionAtSessionCount as number) ?? 0,
      }));
      const lastFired =
        (modelJson.lastGlobalPhaseAdvanceFiredAtSessionCount as number | null | undefined) ??
        null;
      if (
        shouldFireGlobalPhaseAdvance(patternStates, newSessionCount, lastFired)
      ) {
        newModelJson = {
          ...newModelJson,
          lastGlobalPhaseAdvanceFiredAtSessionCount: newSessionCount,
        };
        rulesFired.push("global-phase-advance");
        fieldsChanged.push("lastGlobalPhaseAdvanceFiredAtSessionCount");
      }
    }

    // Step 5: write back + advance watermark (ADR-0008 §"In-order").
    // session_count drives ADR-0012's 6-session-window cooldown.
    await tx`
      UPDATE public.trainee_models
      SET session_count = ${newSessionCount},
          last_applied_logged_at = ${incomingLoggedAt},
          model_json = ${JSON.stringify(newModelJson)}::jsonb,
          updated_at = NOW()
      WHERE user_id = ${req.user_id}
    `;

    firedFirstApply = true;
    return {
      trainee_model: newModelJson,
      late_arrival: false,
    } satisfies ApplySessionResult;
  });

  // emitApplyComplete + Stage 2 BOTH fire AFTER Stage 1 commits, ONLY on
  // first-apply (per ADR-0013 §"WAQ retry idempotency"). Cached-snapshot
  // returns and late-arrival refusals leave firedFirstApply=false; both
  // emit the structured apply summary and gate Stage 2 here. emitApplyComplete
  // describes a *mutation* — the cached/refusal paths don't mutate, so
  // they're correctly silent on this channel.
  if (firedFirstApply) {
    emitApplyComplete({
      user_id: req.user_id,
      session_id: req.session_id,
      duration_ms: Date.now() - applyStartMs,
      rules_fired: rulesFired,
      fields_changed: fieldsChanged,
    });
  }

  // Stage 2 (classifier) per ADR-0013 — A12 ships the seam + the gating
  // contract; #A13 wires the actual classifier call through this hook.
  if (firedFirstApply && deps.stage2Hook) {
    await deps.stage2Hook();
  }

  return result;
}

// Phase 1 stub — always returns false (every apply treated as fresh).
// Phase 2 (#83 / A12) replaced this with applySession's PK insert above.
// Retained as a callable boundary so handleRequest's existing structure
// can route through applySession without restructuring.
async function checkAlreadyApplied(
  _userId: string,
  _sessionId: string,
): Promise<boolean> {
  return false;
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

  const { user_id, session_id } = validated;

  if (await checkAlreadyApplied(user_id, session_id)) {
    // Phase 2: SELECT model_json FROM trainee_models WHERE user_id = $1
    //          and return that snapshot rather than the empty default.
    return jsonResponse({ trainee_model: {} }, 200);
  }

  // Phase 2: rule logic plugs in here.
  // Reads previous trainee_models.model_json + session_payload, runs the
  // update routine (EWMA, transition mode, two-dimensional recovery,
  // fatigue-interaction confidence, prescription accuracy, transfer
  // regression, etc. — see ADR-0005), writes the updated row + the
  // idempotency record in a single transaction (see ADR-0006 §2),
  // returns the updated snapshot.

  return jsonResponse({ trainee_model: {} }, 200);
}

// Only boot the server when this module is invoked as the entrypoint —
// `deno test` and other importers can pull in `validateRequest` /
// `handleRequest` without binding to a port. Slice 6 (#10) added this
// gate so the validator could be tested in isolation.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
