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

import postgres from "postgres";
import { lookupPattern } from "../_shared/exercise-library.ts";
import {
  computeE1RM,
  type TopSet as EwmaTopSet,
} from "../_shared/ewma-engine.ts";
import {
  classifyStimulus,
  type SetIntent,
} from "../_shared/stimulus-classifier.ts";
import {
  emitApplyComplete as defaultEmitApplyComplete,
  emitClassifierFailed as defaultEmitClassifierFailed,
  emitLateArrival as defaultEmitLateArrival,
  type ApplyCompleteEvent,
  type ClassifierFailedEvent,
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
import {
  CLASSIFIER_BOOTSTRAP_MAX_NOTES,
  CLASSIFIER_BOOTSTRAP_MAX_SESSIONS,
} from "../_shared/constants.ts";
import {
  derivedTrainedJoints,
  runClassifier,
  selectBootstrapNotes,
  updateFormDegradationLifecycle,
  updateLimitationLifecycle,
  type ActiveLimitation,
  type ClearedLimitation,
  type LimitationMention,
  type NoteToClassify,
} from "../_shared/note-classifier.ts";
import { LLMPermanentError, LLMTransientError } from "../_shared/llm-retry.ts";

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
   * snapshot returns (PK conflict) or late-arrival refusals.
   *
   * A13 wires production behavior: when stage2Hook is unset, the orchestrator
   * runs the real Stage 2 driver (`runStage2`) using the classifier* deps
   * below. Tests that want to spy on the firing pattern (e.g., A12 cycle 9
   * cached-return gate) inject a no-arg stage2Hook to override; tests that
   * want to exercise runStage2 directly omit stage2Hook and inject only the
   * classifier* deps.
   */
  stage2Hook?: () => Promise<void> | void;
  /**
   * A13 — Stage 2 LLM call test seam. When unset, runStage2 invokes the
   * real Anthropic Haiku endpoint via `_shared/note-classifier.ts`'s
   * default. Tests inject a deterministic mock that returns the JSON
   * Haiku would produce (or throws to exercise the failure path).
   */
  classifierLLMCall?: (prompt: string) => Promise<string>;
  /** A13 — retry-helper sleep test seam (skip real timers in unit tests). */
  classifierSleep?: (ms: number) => Promise<void>;
  /** A13 — classifier_failed observability test seam. */
  emitClassifierFailed?: (event: ClassifierFailedEvent) => void;
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
/**
 * Per-exercise rule pipeline per #116 (A17). Each ExerciseProfile carries
 * its own top-set history + EWMA estimate per ADR-0005's ExerciseProfile
 * shape. Production bootstrap (no separate path elsewhere): create a fresh
 * profile when the user trains an exercise for the first time.
 *
 * Slice scope: A17 ships ewma-engine wiring. Other ExerciseProfile fields
 * (e1rmMedian, e1rmPeak, formDegradationFlag, confidence) are owned by
 * subsequent slices that extend this loop.
 */
function applyPerExerciseRules(
  exercises: Record<string, Record<string, unknown>>,
  setLogs: Array<Record<string, unknown>>,
  incomingLoggedAt: Date,
  sessionId: string,
): {
  exercises: Record<string, Record<string, unknown>>;
  rulesFired: Set<string>;
  fieldsChanged: string[];
} {
  const rulesFired = new Set<string>();
  const fieldsChanged: string[] = [];

  // Group sets by exercise_id; keep a single Map<exerciseId, sets> in
  // session_payload order so multi-set sessions (5×5 etc.) iterate the
  // hardest top set last (per ADR-0005's heaviest-per-session convention).
  const setsByExercise = new Map<string, Array<Record<string, unknown>>>();
  for (const entry of setLogs) {
    const exerciseId = entry.exercise_id;
    if (typeof exerciseId !== "string") continue;
    const list = setsByExercise.get(exerciseId) ?? [];
    list.push(entry);
    setsByExercise.set(exerciseId, list);
  }

  const merged: Record<string, Record<string, unknown>> = { ...exercises };

  // Bootstrap any exercise trained this session that doesn't yet have a
  // profile. ADR-0005 ExerciseProfile defaults — only the fields A17 owns
  // are meaningful here; other fields populate as their slices wire.
  for (const exerciseId of setsByExercise.keys()) {
    if (!(exerciseId in merged)) {
      merged[exerciseId] = {
        exerciseId,
        topSets: [],
        sessionSnapshots: [],
        e1rmCurrent: 0,
        e1rmMedian: 0,
        e1rmPeak: 0,
        sessionCount: 0,
        formDegradationFlag: false,
        confidence: "bootstrapping",
        formDegradationCleanSessions: 0,
      };
      fieldsChanged.push(`exercises.${exerciseId}.bootstrapped`);
    }
  }

  const newExercises: Record<string, Record<string, unknown>> = {};

  for (const [exerciseId, profile] of Object.entries(merged)) {
    const newProfile: Record<string, unknown> = { ...profile };
    const trainedSets = setsByExercise.get(exerciseId);

    if (trainedSets && trainedSets.length > 0) {
      // sessionCount increments by 1 per session-apply, regardless of how
      // many sets land — counts sessions, not sets (ADR-0005 ExerciseProfile.sessionCount).
      newProfile.sessionCount = ((profile.sessionCount as number) ?? 0) + 1;

      // Append top-intent sets with reps in the validity range. The
      // ewma-engine's filter would skip out-of-range sets internally, but
      // appending out-of-range to topSets bloats the array uselessly.
      const baseTopSets = (profile.topSets as Array<Record<string, unknown>> | undefined) ?? [];
      const newTopSets = [...baseTopSets];
      for (const set of trainedSets) {
        if (set.intent !== "top") continue;
        const weight = typeof set.weight_kg === "number" ? set.weight_kg : null;
        const reps = typeof set.reps_completed === "number" ? set.reps_completed : null;
        if (weight === null || reps === null) continue;
        // ADR-0005 validity window: 3..10 reps. ewma-engine filters again
        // internally, but skipping at append-time keeps topSets lean.
        if (reps < 3 || reps > 10) continue;
        newTopSets.push({
          weight,
          reps,
          loggedAt: incomingLoggedAt.toISOString(),
          sessionId,
        });
      }

      newProfile.topSets = newTopSets;

      // Compute EWMA over the full topSets list (ewma-engine windows the
      // last 5 valid internally per ADR-0005). Standard branch — transition
      // mode wires when transition triggers ship.
      const ewmaInput: EwmaTopSet[] = newTopSets.map((s) => ({
        weight: s.weight as number,
        reps: s.reps as number,
        loggedAt: new Date(s.loggedAt as string),
        sessionId: s.sessionId as string,
      }));
      const newE1RM = computeE1RM(ewmaInput, false);
      if (newE1RM !== null) {
        newProfile.e1rmCurrent = newE1RM;
        rulesFired.add("ewma");
        fieldsChanged.push(`exercises.${exerciseId}.e1rmCurrent`);
      }
    }

    newExercises[exerciseId] = newProfile;
  }

  return { exercises: newExercises, rulesFired, fieldsChanged };
}

/**
 * Per-set stimulus pipeline per #118 (A18). Each set's (intent, reps, rpeFelt)
 * triple maps to a `StimulusDimension | null` via `classifyStimulus`; sets
 * that drive a dimension bump the corresponding `last*StimulusAt` timestamp
 * to the session's `incomingLoggedAt`.
 *
 * Bootstrap: missing `model_json.recovery` gets ADR-0005 defaults — null
 * timestamps + 1.0 readinesses. Readiness scalars are owned by A19; this
 * slice only updates the timestamps.
 *
 * Monotonicity: the orchestrator's watermark check rejects late arrivals
 * before this helper runs, so `incomingLoggedAt >= last_applied_logged_at >=
 * any prior last*StimulusAt`. The assignment is therefore monotonic — no
 * `max()` guard needed.
 */
function applyPerSetStimulusRules(
  recovery: Record<string, unknown> | undefined,
  setLogs: Array<Record<string, unknown>>,
  incomingLoggedAt: Date,
): {
  recovery: Record<string, unknown>;
  rulesFired: Set<string>;
  fieldsChanged: string[];
} {
  const rulesFired = new Set<string>();
  const fieldsChanged: string[] = [];
  const wasBootstrapped = recovery === undefined;
  const newRecovery: Record<string, unknown> = wasBootstrapped
    ? {
        lastNeuromuscularStimulusAt: null,
        lastMetabolicStimulusAt: null,
        neuromuscularReadiness: 1.0,
        metabolicReadiness: 1.0,
      }
    : { ...recovery };
  if (wasBootstrapped) {
    fieldsChanged.push("recovery.bootstrapped");
  }

  const loggedAtIso = incomingLoggedAt.toISOString();
  let bumpedNm = false;
  let bumpedMet = false;

  for (const set of setLogs) {
    const intent = set.intent;
    if (typeof intent !== "string") continue;
    if (typeof set.reps_completed !== "number") continue;
    const rpeFelt = typeof set.rpe_felt === "number" ? set.rpe_felt : null;
    const dim = classifyStimulus(
      intent as SetIntent,
      set.reps_completed,
      rpeFelt,
    );
    if (dim === null) continue;
    if (dim === "neuromuscular" || dim === "both") bumpedNm = true;
    if (dim === "metabolic" || dim === "both") bumpedMet = true;
  }

  if (bumpedNm) {
    newRecovery.lastNeuromuscularStimulusAt = loggedAtIso;
    rulesFired.add("stimulus-classifier");
    fieldsChanged.push("recovery.lastNeuromuscularStimulusAt");
  }
  if (bumpedMet) {
    newRecovery.lastMetabolicStimulusAt = loggedAtIso;
    rulesFired.add("stimulus-classifier");
    fieldsChanged.push("recovery.lastMetabolicStimulusAt");
  }

  return { recovery: newRecovery, rulesFired, fieldsChanged };
}

function applyPerPatternRules(
  patterns: Record<string, Record<string, unknown>>,
  trainedPatterns: Set<string>,
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

  // Bootstrap missing trained-this-session patterns with ADR-0011 defaults
  // per #110 (A15). The orchestrator owns first-touch profile creation
  // because there is no production bootstrap path elsewhere — production
  // users start with `model_json.patterns = {}` and only get pattern
  // profiles when they actually train a pattern.
  const merged: Record<string, Record<string, unknown>> = { ...patterns };
  for (const pattern of trainedPatterns) {
    if (!(pattern in merged)) {
      merged[pattern] = {
        currentPhase: "accumulation",
        sessionsInPhase: 0,
        consecutiveForceDeloadsOnPattern: 0,
        lastPhaseTransitionAtSessionCount: 0,
        recentSessionDates: [],
        transitionModeUntil: null,
        trend: "progressing",
      };
      fieldsChanged.push(`patterns.${pattern}.bootstrapped`);
    }
  }

  for (const [patternKey, raw] of Object.entries(merged)) {
    const profile = raw;
    const wasTrainedThisSession = trainedPatterns.has(patternKey);

    // Increment sessionsInPhase + append loggedAt for patterns trained
    // this session. Per ADR-0011 §(a) intro: "Caller increments
    // sessionsInPhase before calling advancePhase". Untrained patterns
    // retain their state until their next session-apply.
    const baseSessionsInPhase = (profile.sessionsInPhase as number) ?? 0;
    const sessionsInPhase = wasTrainedThisSession
      ? baseSessionsInPhase + 1
      : baseSessionsInPhase;

    const baseRecentDates =
      (profile.recentSessionDates as string[] | undefined) ?? [];
    const recentDates = wasTrainedThisSession
      ? [...baseRecentDates, incomingLoggedAt.toISOString()]
      : baseRecentDates;

    const cadenceDays = sessionsCadenceDays(recentDates);
    // ADR-0011 Option-B threshold input: derive daysPerWeek from cadence.
    // Cadence-aware (ADR-0015) — high-frequency cadence → larger daysPerWeek;
    // null cadence (long-absence-returner) defaults to 4 (alpha-cohort
    // typical 4×/week). The orchestrator owns this default; rule modules
    // are pure and trust the input.
    const daysPerWeek = cadenceDays !== null ? 7 / cadenceDays : 4;

    const advanceState: PerPatternState = {
      currentPhase: profile.currentPhase as MesocyclePhase,
      sessionsInPhase,
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
      recentSessionDates: recentDates,
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
    // Derive trained-this-session patterns/exercises/muscleGroups from
    // session_payload. Hoisted out of Stage 2 (used to be computed only
    // for the classifier's auto-clear gate) so applyPerPatternRules can
    // bootstrap pattern profiles for first-time-trained patterns per
    // #110 (A15). Stage 2 below reuses the same result.
    const trainedSets = derivedTrainedSets(req.session_payload);

    let newModelJson: Record<string, unknown>;
    if (deps.ruleHook) {
      newModelJson = deps.ruleHook(modelJson);
    } else {
      const patternsIn = (modelJson.patterns as Record<string, Record<string, unknown>> | undefined) ?? {};
      const ruled = applyPerPatternRules(patternsIn, trainedSets.patterns, incomingLoggedAt, newSessionCount);
      newModelJson = { ...modelJson, patterns: ruled.patterns };
      rulesFired = [...ruled.rulesFired];
      fieldsChanged = ruled.fieldsChanged;

      // Per-exercise rule pipeline per #116 (A17). Wires ewma-engine into
      // ExerciseProfile.e1rmCurrent. Other ExerciseProfile fields land
      // with subsequent slices.
      const exercisesIn = (modelJson.exercises as Record<string, Record<string, unknown>> | undefined) ?? {};
      const setLogsArr = ((req.session_payload as Record<string, unknown>).set_logs as Array<Record<string, unknown>> | undefined) ?? [];
      const exerciseRuled = applyPerExerciseRules(
        exercisesIn,
        setLogsArr,
        incomingLoggedAt,
        req.session_id,
      );
      newModelJson = { ...newModelJson, exercises: exerciseRuled.exercises };
      rulesFired.push(...exerciseRuled.rulesFired);
      fieldsChanged.push(...exerciseRuled.fieldsChanged);

      // Per-set stimulus pipeline per #118 (A18). Wires stimulus-classifier
      // into RecoveryProfile.last*StimulusAt. Readiness scalars wire in A19.
      const recoveryIn = modelJson.recovery as
        | Record<string, unknown>
        | undefined;
      const stimulusRuled = applyPerSetStimulusRules(
        recoveryIn,
        setLogsArr,
        incomingLoggedAt,
      );
      newModelJson = { ...newModelJson, recovery: stimulusRuled.recovery };
      rulesFired.push(...stimulusRuled.rulesFired);
      fieldsChanged.push(...stimulusRuled.fieldsChanged);

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
    //
    // UPSERT (not plain UPDATE): a fresh user has no trainee_models row,
    // and there is no separate bootstrap path in production — the row is
    // created on first session-apply. Plain UPDATE would no-op on the
    // first apply and silently leave the model un-persisted (caught by
    // G1 verification gate). ON CONFLICT (user_id) preserves the
    // semantics for the common case (row exists) while letting the
    // first-ever apply create it.
    // Use tx.json(...) — postgres.js's typed JSONB parameter helper. The
    // older `${JSON.stringify(obj)}::jsonb` pattern double-encodes (the
    // driver re-quotes the string as a JSON value), storing the model
    // as a scalar JSON string instead of an object. The bug was latent
    // in this slice's predecessor UPDATE because no production HTTP path
    // exercised the write step until G1.
    await tx`
      INSERT INTO public.trainee_models
        (user_id, session_count, last_applied_logged_at, model_json, updated_at)
      VALUES
        (${req.user_id}, ${newSessionCount}, ${incomingLoggedAt},
         ${tx.json(newModelJson)}, NOW())
      ON CONFLICT (user_id) DO UPDATE
        SET session_count = EXCLUDED.session_count,
            last_applied_logged_at = EXCLUDED.last_applied_logged_at,
            model_json = EXCLUDED.model_json,
            updated_at = EXCLUDED.updated_at
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

  // Stage 2 (classifier) per ADR-0013. Synthetic test seam (stage2Hook) wins
  // when provided — keeps A12 cycle 9's gating-contract spy intact. Otherwise
  // production runs the real Stage 2 driver. Stage 1 has already committed,
  // so a Stage 2 failure does NOT roll back Stage 1 (per ADR-0013 §"Failure
  // mode") — runStage2's catch block emits classifier_failed and swallows.
  if (firedFirstApply) {
    if (deps.stage2Hook) {
      await deps.stage2Hook();
    } else {
      // Re-derive trainedSets here rather than threading it out of
      // sql.begin's closure scope — derivedTrainedSets is pure over
      // session_payload, so two calls produce identical results.
      const trainedSets = derivedTrainedSets(req.session_payload);
      await runStage2({
        sql,
        userId: req.user_id,
        sessionId: req.session_id,
        trainedExercises: trainedSets.exercises,
        trainedPatterns: trainedSets.patterns,
        trainedMuscleGroups: trainedSets.muscleGroups,
        now: incomingLoggedAt,
        classifierLLMCall: deps.classifierLLMCall,
        classifierSleep: deps.classifierSleep,
        emitClassifierFailed: deps.emitClassifierFailed ?? defaultEmitClassifierFailed,
      });
    }
  }

  return result;
}

/**
 * Extract per-session training sets from `session_payload.set_logs[]`.
 *
 * Stage 2's auto-clear gate (Q9 §"3 sessions where (a) subject was trained,
 * (b) classifier processed notes, (c) no re-mention") needs to know which
 * patterns / muscles / exercises were actually trained this session. We
 * derive these from the logged set entries — each set carries `exercise_id`
 * and (optionally) `pattern` and `primary_muscle` per the v2 set-log shape.
 *
 * Pragmatic for v2 alpha: trust the client-supplied per-set fields. Server-
 * side derivation via ExerciseLibrary lookup is a future tightening if the
 * alpha cohort surfaces stale or missing fields. The Q9 lifecycle gates
 * fail-safe in either direction (under-detect → slower auto-clear, silent;
 * over-detect → premature clearing, also silent in the AI-inferred path
 * which caps at .mild).
 */
function derivedTrainedSets(
  sessionPayload: Record<string, unknown>,
): {
  exercises: Set<string>;
  patterns: Set<string>;
  muscleGroups: Set<string>;
} {
  const exercises = new Set<string>();
  const patterns = new Set<string>();
  const muscleGroups = new Set<string>();
  const setLogs = sessionPayload.set_logs;
  if (Array.isArray(setLogs)) {
    for (const entry of setLogs) {
      if (typeof entry !== "object" || entry === null) continue;
      const e = entry as Record<string, unknown>;
      if (typeof e.exercise_id === "string") {
        exercises.add(e.exercise_id);
        // Server-side pattern derivation per #110 (A15). production
        // set_logs has no `pattern` column; client-supplied `e.pattern`
        // (forward-compat seam) takes precedence when present, else
        // fall through to ExerciseLibrary lookup. Unknown exercise IDs
        // produce no pattern — caller skips, matching asymmetric-error
        // preference (under-bootstrap silent; over-bootstrap creates
        // phantom profiles).
        const fromExercise = lookupPattern(e.exercise_id);
        if (typeof e.pattern === "string") {
          patterns.add(e.pattern);
        } else if (fromExercise) {
          patterns.add(fromExercise);
        }
      } else if (typeof e.pattern === "string") {
        patterns.add(e.pattern);
      }
      if (typeof e.primary_muscle === "string") {
        // PrimaryMuscle → MuscleGroup mapping (per CONTEXT.md two-level taxonomy).
        // Quads/hamstrings/glutes/calves all collapse to "legs"; upper-body
        // muscles map 1:1.
        const m = e.primary_muscle;
        if (["quads", "hamstrings", "glutes", "calves"].includes(m)) {
          muscleGroups.add("legs");
        } else {
          muscleGroups.add(m);
        }
      }
    }
  }
  return { exercises, patterns, muscleGroups };
}

/**
 * Stage 2 driver per ADR-0013 + Q9.
 *
 * Runs in a SECOND transaction (separate from Stage 1's). Per ADR-0013:
 * "Stage 2 runs separate-after Stage 1 commit; classifier failure does NOT
 * roll back Stage 1." On any error, emits `trainee_model.classifier_failed`,
 * watermark stays at the prior value (notes remain un-processed for the next
 * session-apply), and the error is swallowed (orchestrator's HTTP response
 * has already returned per ADR-0013's "HTTP returns after Stage 1").
 *
 * Architectural choice (locked at slice plan): a SINGLE second transaction
 * wrapping form-degradation + limitation lifecycle + watermark advance.
 * Atomicity here means the watermark advances iff every output is written;
 * partial-success states (watermark advanced without outputs, or vice versa)
 * are impossible. ADR-0013's Stage 1/Stage 2 isolation is preserved because
 * the boundary is between the two transactions, not within either.
 */
async function runStage2(args: {
  sql: Sql;
  userId: string;
  sessionId: string;
  trainedExercises: Set<string>;
  trainedPatterns: Set<string>;
  trainedMuscleGroups: Set<string>;
  now: Date;
  classifierLLMCall?: (prompt: string) => Promise<string>;
  classifierSleep?: (ms: number) => Promise<void>;
  emitClassifierFailed: (event: ClassifierFailedEvent) => void;
}): Promise<void> {
  let notesAttempted = 0;
  try {
    await args.sql.begin(async (tx: Sql) => {
      // Step 1: read model_json + the classifier watermark.
      const rows = await tx`
        SELECT model_json
        FROM public.trainee_models
        WHERE user_id = ${args.userId}
        FOR UPDATE
      `;
      if (rows.length === 0) return; // user gone — nothing to do
      const modelJson = parseJsonbColumn(rows[0].model_json);
      const watermarkRaw = modelJson.lastClassifiedNoteCreatedAt as string | null | undefined;
      const watermark: Date | null = watermarkRaw ? new Date(watermarkRaw) : null;

      // Step 2: select notes since watermark (or bootstrap on null).
      let notes: NoteToClassify[];
      if (watermark === null) {
        const rows = await tx`
          SELECT id, raw_transcript, exercise_id, created_at, session_id
          FROM public.memory_embeddings
          WHERE user_id = ${args.userId}
          ORDER BY created_at DESC
        `;
        const allNotes = rows.map(mapNoteRow);
        notes = selectBootstrapNotes(
          allNotes,
          CLASSIFIER_BOOTSTRAP_MAX_NOTES,
          CLASSIFIER_BOOTSTRAP_MAX_SESSIONS,
        );
      } else {
        const rows = await tx`
          SELECT id, raw_transcript, exercise_id, created_at, session_id
          FROM public.memory_embeddings
          WHERE user_id = ${args.userId} AND created_at > ${watermark}
          ORDER BY created_at
        `;
        notes = rows.map(mapNoteRow);
      }
      notesAttempted = notes.length;

      // Step 3: no notes → no-op (no Haiku call, no watermark advance).
      if (notes.length === 0) return;

      // Step 4: run classifier. Throws LLMTransientError on retry exhaustion
      // or LLMPermanentError on malformed response — caught below.
      const result = await runClassifier(notes, {
        llmCall: args.classifierLLMCall,
        sleep: args.classifierSleep,
      });

      // Step 5: apply form-degradation lifecycle + limitation lifecycle to
      // the model_json. Both are pure functions from cycles 6-21.
      const newModelJson = applyClassifierOutputs(modelJson, result, args);

      // Step 6: advance the classifier watermark to the max created_at of
      // the processed notes.
      const maxCreatedAt = notes.reduce(
        (m, n) => (n.createdAt.getTime() > m.getTime() ? n.createdAt : m),
        new Date(0),
      );
      newModelJson.lastClassifiedNoteCreatedAt = maxCreatedAt.toISOString();

      // Step 7: write back.
      await tx`
        UPDATE public.trainee_models
        SET model_json = ${JSON.stringify(newModelJson)}::jsonb,
            updated_at = NOW()
        WHERE user_id = ${args.userId}
      `;
    });
  } catch (err) {
    // ADR-0013 §"Failure mode": emit + swallow. Watermark stays at prior
    // value (the Update did not commit). Next session-apply re-runs the
    // classifier on the same un-processed batch + any new notes.
    let errorClass = "unexpected_error";
    if (err instanceof LLMTransientError) {
      errorClass = "transient_retry_exhausted";
    } else if (err instanceof LLMPermanentError) {
      errorClass = err.errorClass;
    }
    args.emitClassifierFailed({
      user_id: args.userId,
      session_id: args.sessionId,
      error_class: errorClass,
      notes_attempted_count: notesAttempted,
    });
    // do NOT re-throw: Stage 1 already committed; orchestrator's caller
    // received its HTTP response after Stage 1.
  }
}

/**
 * Map a `memory_embeddings` row to the classifier's `NoteToClassify` shape.
 * postgres.js gives us `created_at` as a Date already and snake_case column
 * names as object keys; we adapt to camelCase for the TS rule modules.
 */
function mapNoteRow(row: Record<string, unknown>): NoteToClassify {
  return {
    id: row.id as string,
    rawTranscript: (row.raw_transcript as string) ?? "",
    exerciseId: (row.exercise_id as string | null) ?? null,
    createdAt: row.created_at instanceof Date
      ? row.created_at
      : new Date(row.created_at as string),
    sessionId: (row.session_id as string | null) ?? null,
  };
}

/**
 * Apply the classifier's outputs to a model_json snapshot. Combines the Q9
 * form-degradation lifecycle with the ActiveLimitation lifecycle from
 * `note-classifier.ts`. Pure: no I/O. The orchestrator wraps the write-back
 * in the Stage 2 transaction.
 */
function applyClassifierOutputs(
  modelJson: Record<string, unknown>,
  classifierOut: { formDegradationMentions: Array<{ exerciseId: string; noteId: string }>; limitationMentions: LimitationMention[] },
  ctx: {
    trainedExercises: Set<string>;
    trainedPatterns: Set<string>;
    trainedMuscleGroups: Set<string>;
    now: Date;
  },
): Record<string, unknown> {
  // Form-degradation: for each exercise in model_json.exercises, run the
  // lifecycle helper. isCleanSession is true iff classifier processed notes
  // (always true here — we got past the empty-notes guard) AND no mention
  // for this exercise AND exercise was trained this session.
  const exercises = (modelJson.exercises as Record<string, Record<string, unknown>> | undefined) ?? {};
  const mentionedExercises = new Set(
    classifierOut.formDegradationMentions.map((m) => m.exerciseId),
  );
  const updatedExercises: Record<string, Record<string, unknown>> = {};
  for (const [exId, profile] of Object.entries(exercises)) {
    const wasMentioned = mentionedExercises.has(exId);
    const wasTrained = ctx.trainedExercises.has(exId);
    const lifecycleOut = updateFormDegradationLifecycle({
      exerciseId: exId,
      currentFlag: (profile.formDegradationFlag as boolean) ?? false,
      currentCleanSessions: (profile.formDegradationCleanSessions as number) ?? 0,
      classifierMentioned: wasMentioned,
      isCleanSession: !wasMentioned && wasTrained,
    });
    updatedExercises[exId] = {
      ...profile,
      formDegradationFlag: lifecycleOut.flag,
      formDegradationCleanSessions: lifecycleOut.cleanSessions,
    };
  }

  // Limitation lifecycle: build input from current model + classifier output,
  // call the helper, take output. The helper handles evidence accumulation,
  // .mild capping, auto-clear, user-reported persistence, merge-on-coexistence,
  // and cleared retention pruning.
  const trainedJoints = derivedTrainedJoints(ctx.trainedPatterns);
  const limitationOut = updateLimitationLifecycle({
    active: ((modelJson.activeLimitations as ActiveLimitation[]) ?? []),
    cleared: ((modelJson.clearedLimitations as ClearedLimitation[]) ?? []),
    classifierMentions: classifierOut.limitationMentions,
    trainedPatterns: ctx.trainedPatterns,
    trainedMuscleGroups: ctx.trainedMuscleGroups,
    trainedJoints,
    notesProcessed: true,
    now: ctx.now,
  });

  return {
    ...modelJson,
    exercises: updatedExercises,
    activeLimitations: limitationOut.active,
    clearedLimitations: limitationOut.cleared,
  };
}

// Lazy module-level postgres client per ADR-0006. Edge Functions cold-start;
// production deploy uses Supabase's pgbouncer endpoint via SUPABASE_DB_URL
// (see docs/agents/edge-functions.md §Decisions for connection-string
// policy). Tests bypass this by injecting an Sql client directly into
// `applySession` via deps.
let cachedSql: Sql | undefined;
function getSql(): Sql {
  if (cachedSql) return cachedSql;
  const url = Deno.env.get("SUPABASE_DB_URL");
  if (!url) {
    throw new Error(
      "SUPABASE_DB_URL env var must be set to invoke applySession from " +
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
    const result = await applySession(validated, sql, {});
    return jsonResponse(result, 200);
  } catch (e) {
    console.error("[update-trainee-model] applySession failed:", e);
    return jsonResponse(
      { error: e instanceof Error ? e.message : "internal error" },
      500,
    );
  }
}

// Only boot the server when this module is invoked as the entrypoint —
// `deno test` and other importers can pull in `validateRequest` /
// `handleRequest` without binding to a port. Slice 6 (#10) added this
// gate so the validator could be tested in isolation.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
