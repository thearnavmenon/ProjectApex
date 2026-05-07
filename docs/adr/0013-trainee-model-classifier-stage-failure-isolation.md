# Trainee-model classifier stage: failure-isolated background-tier with watermark advance

**Status**: accepted, 2026-05-07

## Context

ADR-0005 specifies that RAG (`MemoryService`) is reframed as a "sensor that feeds structured fields" — a periodic cadence runs a single multi-classification LLM call producing per-exercise form-degradation counts and per-joint limitation evidence; both feed the trainee model as structured updates. ADR-0007 specifies the retry-and-surface policy for LLM calls: foreground-tier surfaces failures via `InferenceRetrySheet`; background-tier leaves WAQ entries in place and logs structured failure.

The classifier described in ADR-0005 is the **first second-stage LLM call on the Edge Function path**. The first stage is the trainee-model rule logic (EWMA, recovery, phase advance, hybrid plateau verdict per ADR-0009/0010/0011) — purely deterministic, no external API. The second stage is the classifier — an Anthropic Haiku call processing recent note transcripts.

The placement of the classifier relative to the trainee-model update determines a coaching-state failure mode: a Haiku outage (per FB-012, the Anthropic 529 outage on 22 Apr 2026) would freeze EWMA, recovery, and phase advance for every alpha user simultaneously if the two were transactionally coupled, or would only delay slow-aggregation updates if they were isolated.

This ADR is tightly coupled to ADR-0005 (the classifier's role), ADR-0006 (Edge Function placement), ADR-0007 (background-tier retry contract), and ADR-0008 (watermark-based idempotency pattern).

## Decision

The classifier runs **separate-after** the trainee-model update commits. The classifier is a **background-tier** call site per ADR-0007 — failures leave the work in place for retry on the next session-apply, do not surface to the user, and do not block the trainee-model update.

### Stage sequencing

Per session-apply on the Edge Function:

1. **Stage 1 (transactional, deterministic):** trainee-model rule logic runs in a single transaction with the watermark advance and `trainee_model_applied_sessions` insert (per ADR-0008). On commit, the new `model_json` snapshot is durable.

2. **Stage 2 (separate, LLM-driven):** if Stage 1 committed AND new notes exist since `lastClassifiedNoteCreatedAt`, the Edge Function invokes the classifier on the new notes. On classifier success, a second stored-procedure call writes form-degradation/limitation deltas onto the same `model_json` and advances the watermark to the max processed `created_at`.

The HTTP response to the WAQ post returns after Stage 1 commits; Stage 2 runs synchronously within the same Edge Function invocation but doesn't gate the response. If Stage 2 is in flight when the Edge Function times out, the next session-apply re-runs Stage 2 against the same un-processed notes (watermark didn't advance).

### Watermark — `lastClassifiedNoteCreatedAt: Date?` on TraineeModel

The classifier processes notes WHERE `created_at > lastClassifiedNoteCreatedAt`. After successful classification the watermark advances to the max `created_at` of the processed batch.

Similar in spirit to ADR-0008's session watermark but simpler — no refusal logic. Notes are append-only on `memory_embeddings`, and the classifier doesn't reprocess already-classified notes regardless of arrival order. A note arriving with `created_at < watermark` (e.g., delayed embedding write after a more recent one) is skipped on the comparison.

**Clock-skew defence:** `memory_embeddings.created_at` is clamped server-side at insert time to `LEAST(client_provided, NOW())`. Prevents future-dated `created_at` advancing the watermark beyond now and silently skipping subsequent notes.

### Bootstrap — first-ever classifier run

When `lastClassifiedNoteCreatedAt` is nil, the classifier processes only the **most recent N notes**, capped at:
- 20 notes total, OR
- All notes from the user's last 5 sessions, whichever is smaller.

Five sessions of training context is sufficient for cold-start: any structural patterns that haven't surfaced in 5 sessions of recent notes aren't urgent to backfill. Subsequent sessions catch them naturally as the watermark advances.

### Failure mode — leave watermark, retry on next session

If the classifier fails for any reason (Haiku unreachable, API error, malformed JSON response, rate-limit exhaustion across the ADR-0007 retry budget):

- Watermark does NOT advance.
- Stage 1's trainee-model update has already succeeded; this session's form-degradation/limitation updates miss the batch.
- Next session-apply re-runs the classifier on the same notes (now joined with newer ones).
- Emit a structured `trainee_model.classifier_failed` log event (`user_id`, `session_id`, `error_class`, `notes_attempted_count`).

There is no separate retry queue. The next session-apply is the natural retry. If the user doesn't complete another session for a week, the classifier doesn't re-fire for that week. Acceptable: notes are still in `memory_embeddings`; the model's form-degradation/limitation state stays slightly stale but not lost.

### WAQ retry idempotency

If WAQ retries a session-completion event after a successful Stage 1, the `trainee_model_applied_sessions` PK returns the cached snapshot per ADR-0006. **The classifier does NOT re-run on cached-snapshot returns.** Stage 2 fires exactly once per session apply; if Stage 2 failed mid-flight on the first apply (after PK insert but before classifier completion), the watermark didn't advance and the next *new* session triggers a classifier run that catches the missed batch.

This means WAQ-retried sessions are idempotent on both stages: Stage 1 via PK constraint, Stage 2 via the implicit "fires-on-new-applies-only" rule.

### Why background-tier (no user-visible failure surface)

Three coaching-relevant arguments for keeping classifier failures invisible to the user:

1. **The acute case is already covered by RAG.** Both the inference path (`AIInferenceService` via `WorkoutSessionManager.fetchRAGMemory`) and the session-plan path (`SessionPlanService`) call `MemoryService.retrieveMemory` before the LLM call. Raw notes mentioning shoulder pain reach the AI regardless of classifier state. The classifier produces *structured aggregation* — slow-evolving state across sessions — not acute prescription signals.

2. **Classifier output is not user-facing.** A notification "we missed processing your notes from Tuesday" gives the user nothing actionable. They might disengage or write fewer notes if they think the system is unreliable, which directly costs the data the classifier needs.

3. **Staleness compounds across sessions, not within them.** Each missed batch costs one session of delayed structural aggregation, which is invisible at the prescription level for any individual session. Only systematic failures across many sessions become visible — and the structured `trainee_model.classifier_failed` log channel catches that without user notification.

Sustained failure (e.g. classifier hasn't successfully advanced the watermark in N sessions) may eventually warrant a meta-coaching surface ("your form patterns aren't being analysed lately"), but that is a v2.x consideration. v2 does not implement automated user-facing classifier-failure surfacing.

## Considered Options

- **Inline transactional**: rejected. A Haiku 529 outage (FB-012, 22 Apr 2026) would freeze EWMA, recovery, and phase advance for every alpha user simultaneously. The trainee-model update's deterministic rules don't depend on Haiku availability; coupling them is the wrong direction. Per ADR-0007 background-tier policy, classifier failure should leave the work in place for retry, not fail the whole transaction.

- **Hybrid: Stage 2 inside the same transaction but allowing partial commit on classifier failure**: equivalent in behavior to the chosen separate-after but more complex transaction semantics. Rejected for clarity.

- **Foreground-tier surfacing for classifier failures**: rejected. Classifier output is not user-facing; surfacing failures gives the user nothing actionable and risks behavioral disengagement (fewer notes written). RAG already covers the acute case.

- **Dedicated retry queue for classifier failures** (e.g. periodic Edge Function cron retries): rejected for v2. Alpha-cohort scale doesn't justify the cron infrastructure. If classifier outages stack up and become a real problem, v2.5 adds the queue.

- **Reprocess all notes on every session-apply** (no watermark): rejected. Quadratic cost in session count; defeats the purpose of incremental classification.

- **Process all notes on bootstrap** (no last-5-sessions cap): rejected. Pathological cold-start cost for users with extensive note history; structural patterns invisible from 20+ sessions back aren't acutely actionable.

## Consequences

- The Edge Function's session-apply path becomes two-staged. Stage 1 (deterministic rule logic) commits first; Stage 2 (classifier + form-degradation/limitation updates) runs after. The HTTP response returns after Stage 1.

- `TraineeModel` gains `lastClassifiedNoteCreatedAt: Date?` field. Codable migration is additive; existing rows decode as nil and trigger bootstrap on next session-apply.

- A new structured log channel `trainee_model.classifier_failed` is required, with fields `user_id`, `session_id`, `error_class`, `notes_attempted_count`. Surfaces in the same observability sink as `trainee_model.late_arrival` (ADR-0008) and `recovery.clock_skew` (ADR-0010).

- `memory_embeddings.created_at` is clamped server-side at insert time to `LEAST(client_provided, NOW())` to defend against client clock skew advancing the watermark beyond now.

- Stage 2 inherits ADR-0007's bounded retry policy on the underlying Haiku call (3 retries, 1s/2s/4s backoff with jitter). On retry exhaustion, Stage 2 fails and the watermark does not advance.

- The cached-snapshot WAQ retry semantics from ADR-0006 are preserved: idempotent retries do not re-run Stage 2. First-apply-fires-once is the contract.

- Sustained classifier failure detection (e.g. "watermark hasn't advanced in N sessions") is deferred to v2.x. v2 relies on the structured log channel + manual monitoring during the alpha cohort.

- This ADR establishes the pattern for future second-stage LLM calls on the Edge Function path. Any future stage that wants foreground surfacing must justify the deviation from this background-tier default.
