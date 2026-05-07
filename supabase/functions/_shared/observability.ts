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
