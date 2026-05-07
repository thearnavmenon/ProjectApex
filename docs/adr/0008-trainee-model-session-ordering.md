# Trainee-model session ordering: chronological loggedAt with watermark-refuse for late arrivals

**Status**: accepted, 2026-05-07

## Context

ADR-0005 specifies that the trainee model is updated server-side after every completed session via the `update-trainee-model` Edge Function (per ADR-0006). ADR-0001 specifies that out-of-order session completion preserves the queue and de-dupes the next future occurrence by exact session-ID match. Neither ADR specifies the order in which the Edge Function should *apply* session-completion events to the trainee model. This matters because the trainee model's update rules — EWMA over the last 5 valid top sets, two-dimensional recovery decay keyed off `lastNeuromuscularStimulusAt` / `lastMetabolicStimulusAt`, prescription-accuracy aggregation, fatigue-interaction confidence × consistency, transfer regression — all consume a temporal stream of sessions where "last" and "decay since" mean wall-clock recency, not queue position.

Three failure modes if the policy is left implicit:

1. **Out-of-order ADR-0001 completion** — user does Legs A on Wednesday after Push A on Tuesday and Pull A on Monday. The queue pointer doesn't advance per ADR-0001, but the Wednesday session reaches the Edge Function with `loggedAt = Wednesday`. Should EWMA append it as the most-recent top set for the squat pattern (chronological), or insert it at the queue position the de-dupe consumed (queue-order)?
2. **WAQ retry after extended outage** — a session-completion event sits in the WriteAheadQueue across a multi-hour outage, then flushes after a later session has already completed and reached the Edge Function. The PK constraint on `trainee_model_applied_sessions` prevents double-application, but the *temporal slotting* of the late event is undefined.
3. **Crash recovery** — the client's local SwiftData cache repopulates from the server snapshot, but if the snapshot was computed from out-of-order events, the recovery decay timestamps and EWMA window are inconsistent.

This ADR is tightly coupled to ADR-0001 (out-of-order semantics, but at the queue layer rather than the trainee-model layer), ADR-0005 (the rules that consume the temporal stream), and ADR-0006 (the Edge Function that runs the update). It does not change any of those — it pins down a hole they collectively left.

## Decision

The Edge Function applies session-completion events **ordered by `session.loggedAt` (wall-clock completion time)**, not by queue position.

A `last_applied_logged_at TIMESTAMPTZ` watermark on `trainee_models` (or implied by `MAX(s.logged_at) FROM trainee_model_applied_sessions a JOIN sessions s USING (session_id) WHERE a.user_id = $1`) gates incoming events. The stored procedure compares the incoming session's `loggedAt` to the watermark inside the same transaction as the model update:

- **In-order or simultaneous** (`incoming.loggedAt >= watermark`): apply the update, advance the watermark, insert into `trainee_model_applied_sessions`, write the new `model_json` snapshot, return the snapshot.
- **Late arrival** (`incoming.loggedAt < watermark`): emit a structured `trainee_model.late_arrival` log event (`user_id`, `session_id`, `incoming_logged_at`, `watermark`, `delta_seconds`), insert into `trainee_model_applied_sessions` for idempotency dedupe (the event is now considered "applied" — no retry), do NOT mutate `model_json`, do NOT advance the watermark, return the cached snapshot with a `late_arrival: true` flag in the JSON body.

The historical `set_logs` and `sessions` rows persist independently of the trainee-model update — a refused event still preserves the underlying training history; only the model state misses.

WAQ does NOT retry refused events. The client's WAQ adapter (`TraineeModelUpdateJob`) dequeues on `late_arrival: true` identically to a successful update, and surfaces a soft post-session notification to the user: *"This session was logged after later sessions and won't update your training profile, but the history is preserved."*

## Considered Options

- **Re-derive from scratch every update**: process all `set_logs` for this user ordered by `loggedAt` from session 1, recomputing EWMA, recovery, transfer regression, fatigue interactions in one pass. Correct under any arrival order. Rejected: cost is O(N × rule_count) per session apply; at 200 sessions × ~10 rule families with regression fits, the Edge Function timeout is tight and grows tighter with N. Also defeats the incremental-EWMA premise of ADR-0005.

- **Delta-compute**: when a late event arrives, compute the difference its insertion would have made and apply that delta to the current snapshot. Rejected: race-prone (two near-simultaneous late arrivals fight over the watermark) and analytically hard for non-linear rules — a Spearman flag fired at ≥10 observations changes SE-widening behaviour depending on insertion position; doable but high implementation cost relative to alpha-cohort scale.

- **Refuse-and-log late arrivals (chosen)**: events with `loggedAt < watermark` are rejected at the Edge Function tier without mutating the model, surfaced to the user as a soft notification. Pragmatic for the alpha-cohort scale (3–5 users, P-B); historical `set_logs` preservation means the missing model update is recoverable later if v2.5 builds backfill.

- **Queue-position ordering**: order events by their queue slot rather than `loggedAt`. Rejected: recovery decay (`lastNeuromuscularStimulusAt`) has no queue-position interpretation; EWMA recency premise breaks; ADR-0001's de-dupe is a queue-bookkeeping concern, orthogonal to the trainee model's temporal stream.

- **Silent refusal (no user notification)**: log the late arrival to observability only, drop the event silently from the user's perspective. Rejected: at alpha scale we want the user to tell us when this happens so we can size whether v2.5 needs real backfill, rather than burying the case in server logs. The notification is also honest — the user did training that the model doesn't reflect, and they should know.

## Consequences

- The Edge Function gains a watermark check before mutating `model_json`. The stored procedure wraps the watermark advance, the `model_json` write, and the `trainee_model_applied_sessions` insert in a single transaction so all three commit atomically.

- A new structured log channel `trainee_model.late_arrival` is required, with fields `user_id`, `session_id`, `incoming_logged_at`, `watermark`, `delta_seconds`. Surfaces in the same observability sink as the other Edge Function structured logs (per ADR-0006).

- The WAQ adapter (`TraineeModelUpdateJob`) gains a single new branch on `late_arrival: true` in the response — same dequeue path, but the client's local store skips updating the cached snapshot and instead enqueues a UI notification to the post-session summary.

- v2.5 may add a backfill mode that re-derives the model from scratch when one or more refused events accumulate above some threshold. The schema choice (`last_applied_logged_at` watermark + dedupe table) supports this without further migration.

- This decision is independent of multi-device support (out of scope for v2 per ADR-0006). When multi-device lands in v3+, optimistic concurrency on `version: Int` composes with the watermark — events from a stale-version client get rejected first by the version check, then evaluated against the watermark.

- The new soft-notification surface on the post-session summary is the alpha cohort's signal channel for whether late-arrival is a real problem. If reports cluster around specific scenarios (e.g. "I lost connectivity for 3 hours and now this session doesn't count"), v2.5's backfill design has the data to size against. If reports are zero, the simplest pragmatic policy held.
