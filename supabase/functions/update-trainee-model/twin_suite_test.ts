// Athlete-Twin test-suite shim (ADR-0031, Phase 1).
//
// CI's Edge-Function job runs `deno test` with THIS directory as the
// working directory, so test files under ../_shared/ are never discovered
// directly (a pre-existing gap: _shared/*_test.ts run only via local
// invocation). Importing the twin test modules here registers their
// Deno.test() cases with this suite's runner, putting the twin's
// numerics under CI without touching the workflow file.
//
// Pure-function tests only — no DB, no served function required.

import "../_shared/twin/linalg_test.ts";
import "../_shared/twin/ukf_test.ts";
import "../_shared/twin/engine_test.ts";
import "../_shared/twin/shadow_test.ts";
import "../_shared/twin/backtest/scoring_test.ts";
import "../_shared/twin/backtest/incumbent_test.ts";
import "../_shared/twin/backtest/run_test.ts";
