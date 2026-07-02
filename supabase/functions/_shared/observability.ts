// Project Apex — Phase 2 observability emit helpers.
//
// Typed wrappers around structured-log emission so that every rule
// slice (A5/A12/A13) emits envelopes with the same shape. Per ADR-0006
// §"Observability" and #74's implementation note: the alpha-scale sink
// is Supabase Edge Function logs, which capture stdout — every helper
// writes a single `{ channel, event }` JSON line via console.log.
//
// Channel-naming convention is set here (this is the first helper
// module): `<domain>.<event_kind>` lower-snake. Domains in v2:
// `trainee_model` (rule outcomes routed to the model update path) and
// `recovery` (curve-evaluation edge cases per ADR-0010).

/**
 * Single emit primitive. Public typed wrappers below funnel through
 * here so that the envelope shape and sink choice live in one place —
 * future migrations (e.g., routing to a dedicated observability table
 * per ADR-0006's "v2.x may add a table" note) change one function body.
 */
function emit(channel: string, event: unknown): void {
  console.log(JSON.stringify({ channel, event }));
}

// ─── emitLateArrival (ADR-0008) ─────────────────────────────────────────────

export interface LateArrivalEvent {
  user_id: string;
  session_id: string;
  incoming_logged_at: string; // ISO 8601
  watermark: string;          // ISO 8601
  delta_seconds: number;      // negative — incoming is `delta_seconds` before watermark
}

export function emitLateArrival(event: LateArrivalEvent): void {
  emit("trainee_model.late_arrival", event);
}

// ─── emitClassifierFailed (ADR-0013) ────────────────────────────────────────

export interface ClassifierFailedEvent {
  user_id: string;
  session_id: string;
  /** e.g., 'haiku_unreachable', 'malformed_response', 'rate_limit_exhausted'. */
  error_class: string;
  notes_attempted_count: number;
}

export function emitClassifierFailed(event: ClassifierFailedEvent): void {
  emit("trainee_model.classifier_failed", event);
}

// ─── emitClockSkew (ADR-0010) ───────────────────────────────────────────────

export interface ClockSkewEvent {
  user_id: string;
  last_stimulus_at: string;   // ISO 8601 — the future-dated timestamp
  now: string;                // ISO 8601 — server time at evaluation
  delta_seconds: number;      // positive — how far in the future the timestamp was
}

export function emitClockSkew(event: ClockSkewEvent): void {
  emit("recovery.clock_skew", event);
}

// ─── emitTransferNegativeCoefficient (Q10, slice A10) ───────────────────────
//
// Surfaces a published transfer fit whose log-log coefficient is negative —
// possible (rare) physiologically when fromE1RM rises while toE1RM falls,
// often indicative of measurement noise, confounded periodization, or one
// exercise being detrained while the other is being trained. The fit still
// publishes per Q10 (gate is on R² and N only); this signal lets future
// log analysis correlate negative-coefficient occurrences with user-reported
// anomalies.
//
// Call site lives at the orchestrator (A12) tier per the locked slice split:
// pair-detection (fromExerciseId/toExerciseId) is an orchestrator concern,
// and required-payload-only typing prevents accidental loss of the pair
// identifier. fitTransfer itself stays signature-locked + sign-agnostic.

export interface TransferNegativeCoefficientEvent {
  user_id: string;
  from_exercise_id: string;
  to_exercise_id: string;
  coefficient: number;          // negative — surfaced because of the sign
  r_squared: number;            // ≥ TRANSFER_R_SQUARED_FLOOR (else not published)
  paired_observations: number;  // ≥ TRANSFER_MIN_PAIRED_OBSERVATIONS
}

export function emitTransferNegativeCoefficient(
  event: TransferNegativeCoefficientEvent,
): void {
  emit("trainee_model.transfer_negative_coefficient", event);
}

// ─── emitApplyComplete (slice A12 — per-apply summary) ──────────────────────
//
// Per-apply observability scaffolded by A12 so production debugging can
// correlate session-applies with which rules fired, what changed on the
// snapshot, and how long Stage 1 took. Three named-event channels above
// cover specific failure modes (late arrival, classifier fail, clock skew);
// this helper covers normal operations.
//
// Call site: orchestrator's first-apply success path, after Stage 1 commit
// and alongside stage2Hook (ADR-0013 §"Stage sequencing"). Cached-snapshot
// returns and late-arrival refusals do NOT emit — the envelope describes a
// *mutation*, and those paths don't mutate.

export interface ApplyCompleteEvent {
  user_id: string;
  session_id: string;
  /** Wall-clock duration of Stage 1 (PK insert through COMMIT). */
  duration_ms: number;
  /** Names of rules that fired this apply, in invocation order. */
  rules_fired: string[];
  /** Dot-paths into model_json that mutated this apply. */
  fields_changed: string[];
}

export function emitApplyComplete(event: ApplyCompleteEvent): void {
  emit("trainee_model.apply_complete", event);
}

// ─── Twin shadow (ADR-0031, Phase 1) ─────────────────────────────────────────
//
// The Athlete-Twin dual-write is SHADOW-ONLY: these events are its entire
// output surface. `twin_shadow.applied` logs each pattern's posterior
// update + twin-vs-legacy divergence (logged, never acted on);
// `twin_shadow.failed` logs a contained per-pattern failure (the legacy
// pipeline is unaffected by construction — see _shared/twin/shadow.ts).

export interface TwinShadowAppliedEvent {
  user_id: string;
  pattern: string;
  anchor_exercise_id: string;
  observations_applied: number;
  sets_skipped: number;
  /** True when this apply created the pattern's twin state (first touch). */
  bootstrapped: boolean;
  /** Twin anchor e1RM — TRUE-capability scale (includes reported RIR). */
  twin_anchor_e1rm: number;
  /** Legacy EWMA e1RM — performed-rep scale; null when absent. */
  legacy_anchor_e1rm: number | null;
  /** (twin − legacy)/legacy × 100. Nonzero by construction (scales
   * differ); its STABILITY over applies is the signal. Null when no
   * legacy comparator exists. */
  divergence_pct: number | null;
  /** Mean normalized innovation squared this apply (≈1 when calibrated). */
  mean_nis: number | null;
  jitter_incidents: number;
}

export function emitTwinShadowApplied(event: TwinShadowAppliedEvent): void {
  emit("twin_shadow.applied", event);
}

export interface TwinShadowFailedEvent {
  user_id: string;
  pattern: string;
  /** e.g. 'no_usable_sets', or the numerical error message (truncated). */
  error_class: string;
}

export function emitTwinShadowFailed(event: TwinShadowFailedEvent): void {
  emit("twin_shadow.failed", event);
}
