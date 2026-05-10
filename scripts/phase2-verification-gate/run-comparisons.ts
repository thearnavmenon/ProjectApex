// Comparison driver for the G1 verification gate (#85).
//
// Runs the three end-state agreement-rate comparisons (legacy device
// snapshot vs. replayed trainee model) and produces helper datasets
// for the five manual coaching-judgment items (Items 2/3/4 deferred
// per composition / demand-side framing — see the report).
//
// Outputs JSON summary at fixtures/comparison-output.json for the
// report draft to consume.
//
// Design choices (see README.md "Scope and design choices"):
//   * end-state-only — legacy outputs are point-in-time device snapshots
//   * Comparison 1 aggregation: legacy per-exercise → per-pattern via
//     worst-of (declining > plateaued > progressing)
//   * Comparison 2 binary: trainee deficit fires iff volumeDeficit > 0
//   * Comparison 3 vacuous-pass flag: <30 triples/pattern AND <2 phases

// TODO(scaffold): full implementation lands once both fixtures exist
// (production dump + device-extracted legacy outputs). Skeleton
// documents the inputs, outputs, and aggregation rules.

const LOCAL_DB_URL = Deno.env.get("LOCAL_DB_URL")
  ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const USER_ID = Deno.env.get("USER_ID");
const FIXTURES_DIR = "scripts/phase2-verification-gate/fixtures";

if (!USER_ID) {
  console.error("USER_ID env var required");
  Deno.exit(2);
}

// Inputs:
//   - fixtures/legacy-stagnation-signals.json  (StagnationSignal[])
//   - fixtures/legacy-volume-deficits.json     (VolumeDeficit[])
//   - fixtures/legacy-pattern-phase-states.json (MovementPatternPhaseState[])
//   - local DB: trainee_models row for USER_ID (post-replay model_json)
//   - local DB: workout_sessions + set_logs for sample-size and
//     vacuous-pass detection

// Comparison 1 — Stagnation verdict (per-pattern):
//   1. Group legacy signals by pattern via ExerciseLibrary.primaryPattern(exerciseId).
//      (pattern map lives in Swift; mirror minimal map for the patterns
//      represented in the user's history. Surface mismatches if any
//      exerciseId can't be mapped.)
//   2. Aggregate per-pattern legacy verdict via worst-of.
//   3. Compare against trainee model_json.patternProfiles[pattern].trend.
//   4. Agreement rate = matches / total patterns evaluated.
//   5. Critical disagreements: legacy.declining vs trainee.progressing
//      (or vice versa) → flagged separately.

// Comparison 2 — Volume deficit (per-muscle):
//   1. Legacy: any deficit row → muscle-group is in deficit.
//   2. Trainee: model_json.muscleProfiles[muscle].volumeDeficit > 0
//      → muscle is in deficit.
//   3. Per-muscle binary agreement rate.
//   4. Document semantic divergence (calendar-week vs queue-event-window).

// Comparison 3 — Pattern phase (per-pattern):
//   1. Legacy: phaseState.phase per pattern.
//   2. Trainee: model_json.patternProfiles[pattern].currentPhase.
//   3. Agreement rate = identical-phase / total patterns.
//   4. Vacuous-pass flag: <30 sessions per pattern AND <2 distinct phases
//      observed across the window → pass is reported as vacuous-baseline,
//      not active-confirmation.

// Manual item helpers:
//   * Item 1 (recovery readiness 24/48/72h): sample 10 sessions where
//     a heavy NM-classified session preceded by 24h/48h/72h. Output:
//     [(sessionId, gapHours, neuromuscularReadiness, expectedPerADR0010,
//       deltaWithin0.05?)] for human review.
//   * Item 2: deferred — composition-gated (plateau-verdict unwired).
//   * Item 3: deferred — demand-side redesigned (trigger-driven prompts).
//   * Item 4: deferred — composition-gated + no deload in history.
//   * Item 5 (gap-bucket bucketing): sample 10–20 working sets, output
//     [(setLogId, computedBucket, expectedBucket, gapHours)] for review.

console.error("[run-comparisons] skeleton only — implementation pending fixtures");
Deno.exit(1);
