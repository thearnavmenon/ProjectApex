# Server-side trainee-model update logic via Supabase Edge Function

**Status**: accepted, 2026-05-01

## Context

The trainee model defined in ADR-0005 needs an update routine that runs after every completed session: fits the EWMA, recomputes trends, updates RPE-offsets, recovery rates, fatigue interactions, prescription accuracy, transfer coefficients, and so on. The routine touches every section of the model and contains the most behaviourally significant business logic in v2. Where it runs determines how consistent the logic is across users, how easy it is to fix bugs, and how multi-user-ready the system is when (P-B) lands at end of v2.

Solo v2 doesn't strictly require server-side. But the multi-user pivot is on the immediate roadmap, and the trainee model logic is exactly the kind of per-user computation that must produce identical results for every user regardless of which client version they're running. The user explicitly pushed for "server-side from day 1" rather than retrofitting later.

This ADR is tightly coupled to ADR-0005 (the trainee model itself) — neither makes sense without the other. The decision here determines where the model's update rules live and how they're invoked.

## Decision

Trainee-model update logic runs **server-side, from day 1**, via a Supabase Edge Function calling a Postgres stored procedure within a transaction. Implementation:

1. **Schema:**
   ```sql
   CREATE TABLE trainee_models (
       user_id UUID PRIMARY KEY REFERENCES users(id),
       created_at TIMESTAMPTZ DEFAULT NOW(),
       updated_at TIMESTAMPTZ DEFAULT NOW(),
       session_count INTEGER DEFAULT 0,
       model_json JSONB NOT NULL
       -- No global confidence_level column. Per-axis confidence (per ADR-0005)
       -- lives inside model_json on each PatternProfile / MuscleProfile /
       -- ExerciseProfile. Calibration-review readiness is computed at read time
       -- from those per-axis values, not stored at top level.
   );
   
   CREATE TABLE trainee_model_applied_sessions (
       user_id UUID NOT NULL,
       session_id UUID NOT NULL,
       applied_at TIMESTAMPTZ DEFAULT NOW(),
       PRIMARY KEY (user_id, session_id)
   );
   ```

2. **Idempotency at the DB layer.** The `(user_id, session_id) PRIMARY KEY` on `trainee_model_applied_sessions` is the idempotency mechanism. The stored procedure inserts into this table inside the same transaction as the model update; `ON CONFLICT DO NOTHING` short-circuits duplicate session submissions. Retries from `WriteAheadQueue` replay, network retry, or crash recovery converge to a single applied update.

3. **Client integration via existing rails.** Session completion writes a "trainee_model_update" item to the existing `WriteAheadQueue` (per shipped P3-T06 architecture). On flush, the WAQ posts to the Edge Function. The Edge Function runs the stored procedure and returns the updated model snapshot. The client's local SwiftData cache (per F2) updates from the response. No new failure-mode design needed — reuses crash-sentinel + WAQ rails already shipped.

4. **Single-device-per-user for v2** with a documented optimistic-concurrency migration path for v3+. Multi-device updates for the same user are not in scope; documented in code (`TraineeModel` block comment) and ARCHITECTURE.md.

## Considered Options

Three placement alternatives:

- **Client-side update logic, eventual server move when needed.** All update rules in Swift; Supabase is just persistence. Rejected: when (P-B) lands at end of v2, every alpha-test friend on a slightly different app build runs slightly different update logic — coaching state diverges by client version. Retrofitting later means duplicating logic across Swift and Edge Function for the migration window, which is more work than starting server-side.
- **Hybrid: some logic each side** (e.g., e1RM math client-side because it's hot-path, fatigue interactions server-side because they accumulate). Rejected: split-brain risk. Whichever side computes a field becomes authoritative; mixing means clients can disagree with the server about state and the resolution rule is non-obvious.
- **Server-side from day 1 (chosen).** All update rules in the Edge Function / stored procedure. Client computes nothing authoritative; reads cached snapshot for prompt-digest assembly only.

Sub-variants:

- **Idempotency: in-app dedup vs DB-PK constraint.** Chose DB-PK. In-app dedup would require the Edge Function to query an "already applied" log before mutating, which is racy under concurrent retries. The PK constraint is atomic — `INSERT … ON CONFLICT DO NOTHING` succeeds iff this is the first apply, so the model update only runs once.
- **Edge Function vs separate Node service.** Chose Edge Function. Supabase is already in the stack; deploying a separate Node service adds infrastructure (deployment pipeline, monitoring, secrets management, rollback story) without benefit for v2's scale.
- **Client-side fallback when Edge Function is down.** Rejected. A client-side fallback path would mean two implementations of every update rule — the bug-divergence risk that motivated server-side in the first place. **What does happen when the Edge Function is unreachable**: the WAQ retains the session-completion event and retries on connectivity restoration; the local SwiftData cache continues to show the *last-known* trainee-model snapshot (from the most recent successful update); session-generation prompts and set-by-set inference run against that stale snapshot until connectivity is restored. The trainee model becomes briefly stale (last-completed session not yet reflected in capability estimates, recovery rates, etc.) but never inconsistent. User-visible effect: prescriptions for the next session may not yet reflect the most recent session's gains/fatigue; once connectivity returns and WAQ flushes, the model catches up and subsequent prescriptions adjust. No UI error is shown for routine outages — the WAQ retry is silent.
- **Rule-versioning: forward-only vs auto-recompute.** Chose forward-only. When an update rule changes (e.g., re-tuning EWMA α from 0.333 to 0.30, or adding a new fatigue-interaction trigger), existing trainee-model rows continue from their current state with the new logic applied to subsequent updates. The alternative — auto-recompute from session-1 across the entire `set_logs` history under the new logic — would be the rigorous answer but requires a recompute pipeline (re-run all rules across N sessions of historical data per affected user, atomically, without losing user-visible state) which is non-trivial to build correctly. Auto-recompute is deferred to v2.5 as a backfill mode triggered explicitly per rule change. For v2: rule changes apply forward-only; documented per change in commit messages and ADRs (or supersession ADRs) so trainee-model evolution is auditable.
- **Sync semantics: optimistic concurrency vs single-device-locked.** Chose single-device-locked for v2. Optimistic concurrency requires a `version: Int` column + retry-on-conflict logic; under (P-B) every alpha-test user has a single device, so the scenario doesn't arise. Migration path documented for v3+ (add version column, retry-on-conflict in stored procedure).
- **Update fires from client async vs sync.** Chose async via WAQ. Synchronous "complete session → wait for trainee-model update → unblock UI" would add 200–500ms to the post-set-complete flow; async via WAQ keeps the UI responsive and the model is eventually consistent on the order of seconds.

## Consequences

- The trainee-model update logic — including all the math from ADR-0005 (EWMA, transition mode, two-dimensional recovery classification, fatigue interaction confidence, transfer regression, form-degradation cascade, etc.) — lives in Postgres-flavoured PL/pgSQL or in TypeScript inside the Edge Function. The math is non-trivial; testing strategy must include both Swift-side cache-population tests and server-side update-rule tests, with shared fixtures.
- A deployment pipeline for Edge Functions is required (Supabase CLI, CI integration). The first deployment is the most expensive; subsequent updates ship via the same pipeline.
- A versioning story for the update logic itself: when an update rule changes (e.g., we re-tune the EWMA α from 0.333 to 0.30), existing trainee-model rows don't auto-recompute — they continue from their current state with the new logic applied to subsequent updates. A backfill mode (recompute all sessions from scratch under new logic) is deferred to v2.5; documented as a known limitation.
- Observability: the Edge Function should log structured events on every update (user_id, session_id, applied_at, durations) into a Supabase table or external log sink. Failure cases (validation errors, math edge cases, stored-procedure errors) need explicit logging because they're invisible to the client beyond "the WAQ retries."
- The trainee-model JSONB column is a contract between Edge Function (writer) and client (reader for digest assembly). Schema migrations to the JSONB shape need to be coordinated — adding a new field is safe; renaming or removing requires a migration pass.
- Multi-device support remains explicitly out of scope. If a v3 user wants the app on iPhone + iPad simultaneously, the documented optimistic-concurrency migration is the path: add `version: Int` column to `trainee_models`, change the stored procedure to read+version → mutate → write WHERE version = X with retry on conflict.
