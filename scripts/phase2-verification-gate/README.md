# Phase 2 verification gate (G1 / #85)

One-shot verification gate for the Phase 2 trainee-model cutover. Block 2B
until this gate's report shows pass.

Single-user-historical-replay shape per the n=1 alpha decision —
see `docs/phase-2-verification-gate-report.md` for verdict + scope notes.
Tooling here is one-shot for Phase 2; v2.x verification cycles are
out-of-scope (re-implement when needed).

## Flow

1. **Produce fixtures** (you, locally):
   - `fixtures/historical-replay.sql` — `pg_dump --data-only` of your
     production Supabase tables (see G1 conversation for the exact command;
     run via `.pgpass` or `PGPASSWORD` env var, not inline).
   - `fixtures/legacy-stagnation-signals.json` /
     `fixtures/legacy-volume-deficits.json` /
     `fixtures/legacy-pattern-phase-states.json` — extracted from your
     iOS device's UserDefaults via `extract-legacy-outputs.py`. Source:
     Xcode → Devices and Simulators → Download Container →
     `<bundle>.xcappdata/AppData/Library/Preferences/<bundle-id>.plist`.
     Python (with stdlib `plistlib`) handles binary/XML plists with
     mixed types; `plutil -convert json` aborts on plists containing
     non-JSON-representable values (e.g. NSDate in unrelated keys).

2. **Bring up local Supabase + Edge Function:**
   - `supabase start` (Docker required).
   - `supabase db push` (apply all migrations — schema baseline + Phase 2).
   - `psql "$LOCAL_DB_URL" -f scripts/phase2-verification-gate/fixtures/historical-replay.sql`
   - `psql "$LOCAL_DB_URL" -c "TRUNCATE public.trainee_models, public.trainee_model_applied_sessions;"`
   - `supabase functions serve update-trainee-model` (separate terminal).
   - Sanity-check the function responds before the replay starts; if it
     errors on env vars, dependencies, or secrets, that's a finding —
     surface it in the report as a blocker rather than working around.

3. **Run replay:**
   ```bash
   deno run --allow-net --allow-read --allow-env \
     scripts/phase2-verification-gate/replay.ts
   ```
   Reads sessions from local DB, POSTs chronologically to the local
   Edge Function. Watermark per ADR-0008 advances naturally; dedupe
   table handles re-replay idempotency.

4. **Run comparisons:**
   ```bash
   deno run --allow-net --allow-read --allow-env --allow-write \
     scripts/phase2-verification-gate/run-comparisons.ts
   ```
   Three end-state agreement-rates (legacy device snapshot vs. replayed
   trainee model) + five manual-item helpers. Writes a JSON summary at
   `fixtures/comparison-output.json` for the report draft to consume.

5. **Draft report.** Update `docs/phase-2-verification-gate-report.md`
   with the comparison output and your sign-off (or fail) per Items
   1 + 5. Items 2/3/4 deferred per composition / demand-side framing
   (see report text).

## Cleanup obligation

After the report is reviewed and the PR merges, **delete the fixtures
directory contents**:

```bash
rm -f scripts/phase2-verification-gate/fixtures/*.sql \
      scripts/phase2-verification-gate/fixtures/*.json
```

The `.gitignore` rule prevents accidental commits, but the files persist
on disk indefinitely otherwise. This contains your full training history
+ device-extracted state — keep its lifetime tight.

## Scope and design choices

- **End-state-only comparison** — legacy outputs are point-in-time
  device snapshots; per-apply temporal agreement-rate is a v2.x
  watch-item if alpha grows beyond n=1.
- **Comparison 1 aggregation** — legacy per-exercise verdicts aggregate
  to per-pattern via worst-of (`declining > plateaued > progressing`),
  mirroring ADR-0009's muscle-level aggregation.
- **Comparison 2 binary threshold** — trainee deficit fires iff
  `MuscleProfile.volumeDeficit > 0` (verify field semantics during
  comparison).
- **Comparison 3 vacuous-pass flag** — fires when <30 (user, pattern,
  session) triples per pattern AND <2 distinct phase states observed.

## Connection-string env

The replay/comparison scripts expect:
```
LOCAL_DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
EDGE_FUNCTION_URL=http://127.0.0.1:54321/functions/v1/update-trainee-model
USER_ID=<your UUID from public.users>
```
Defaults work for stock `supabase start`; export `USER_ID` before running
either script.
