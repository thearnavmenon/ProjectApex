// Project Apex — pattern-confidence-backfill unit tests (#173).
//
// Run locally:
//   deno test supabase/functions/_shared/pattern-confidence-backfill_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { backfillPatternConfidence } from "./pattern-confidence-backfill.ts";

// ─── 1: Null-confidence patterns get "bootstrapping" ─────────────────────────

Deno.test(
  "backfillPatternConfidence_null_confidence_becomes_bootstrapping",
  () => {
    const patterns = {
      isolation: { pattern: "isolation", confidence: null, trend: "declining" },
      vertical_pull: { pattern: "vertical_pull", confidence: null, trend: "declining" },
    };
    const { patterns: result, backfilledCount } = backfillPatternConfidence(patterns);
    assertEquals(result.isolation.confidence, "bootstrapping");
    assertEquals(result.vertical_pull.confidence, "bootstrapping");
    assertEquals(backfilledCount, 2);
  },
);

// ─── 2: Already-bootstrapped patterns are untouched ─────────────────────────

Deno.test(
  "backfillPatternConfidence_bootstrapping_confidence_untouched",
  () => {
    const patterns = {
      squat: { pattern: "squat", confidence: "bootstrapping", trend: "progressing" },
      hip_hinge: { pattern: "hip_hinge", confidence: "bootstrapping", trend: "progressing" },
    };
    const { patterns: result, backfilledCount } = backfillPatternConfidence(patterns);
    assertEquals(result.squat.confidence, "bootstrapping");
    assertEquals(result.hip_hinge.confidence, "bootstrapping");
    assertEquals(backfilledCount, 0);
  },
);

// ─── 3: Mixed — null and non-null — only null entries are written ─────────────

Deno.test(
  "backfillPatternConfidence_mixed_only_null_entries_written",
  () => {
    const patterns = {
      squat: { pattern: "squat", confidence: "bootstrapping", trend: "progressing" },
      isolation: { pattern: "isolation", confidence: null, trend: "declining" },
      vertical_pull: { pattern: "vertical_pull", confidence: "calibrating", trend: "plateaued" },
    };
    const { patterns: result, backfilledCount } = backfillPatternConfidence(patterns);
    assertEquals(result.squat.confidence, "bootstrapping");      // untouched
    assertEquals(result.isolation.confidence, "bootstrapping");  // fixed
    assertEquals(result.vertical_pull.confidence, "calibrating"); // untouched
    assertEquals(backfilledCount, 1);
  },
);

// ─── 4: Idempotency — running twice produces identical output ────────────────

Deno.test(
  "backfillPatternConfidence_idempotent_second_run_no_changes",
  () => {
    const patterns = {
      isolation: { pattern: "isolation", confidence: null, trend: "declining" },
    };
    const { patterns: afterFirst } = backfillPatternConfidence(patterns);
    const { patterns: afterSecond, backfilledCount } = backfillPatternConfidence(afterFirst);
    assertEquals(afterSecond.isolation.confidence, "bootstrapping");
    assertEquals(backfilledCount, 0, "second run must not re-backfill already-set entries");
  },
);

// ─── 5: Empty patterns dict — no-op ─────────────────────────────────────────

Deno.test(
  "backfillPatternConfidence_empty_patterns_returns_empty",
  () => {
    const { patterns: result, backfilledCount } = backfillPatternConfidence({});
    assertEquals(Object.keys(result).length, 0);
    assertEquals(backfilledCount, 0);
  },
);

// ─── 6: Other fields are preserved ───────────────────────────────────────────

Deno.test(
  "backfillPatternConfidence_other_fields_preserved_on_fixed_entry",
  () => {
    const patterns = {
      isolation: {
        pattern: "isolation",
        confidence: null,
        trend: "declining",
        rpeOffset: 2,
        currentPhase: "accumulation",
      },
    };
    const { patterns: result } = backfillPatternConfidence(patterns);
    assertEquals(result.isolation.confidence, "bootstrapping");
    assertEquals(result.isolation.trend, "declining");
    assertEquals(result.isolation.rpeOffset, 2);
    assertEquals(result.isolation.currentPhase, "accumulation");
  },
);
