// Project Apex — Phase 2 named-constants module — tested-defaults pattern.
//
// Per the Phase 2 PRD's Testing Decisions §"Constants-as-tested-defaults
// pattern": each load-bearing constant gets a dedicated test that hard-codes
// the expected value separately from the implementation, with the test name
// referencing the originating ADR. The redundancy is the point — drift
// detection. If a future engineer changes a constant without amending the
// ADR, the test fails with a name pointing at the rule the change touches.
//
// Run locally:
//   deno test supabase/functions/_shared/constants_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  // EWMA / e1RM
  EWMA_ALPHA,
  EWMA_WINDOW_N,
  TRANSITION_MODE_WINDOW_N,
  TOP_SET_REP_VALIDITY_MIN,
  TOP_SET_REP_VALIDITY_MAX,
  TOP_SET_RETENTION_COUNT,
  // Recovery
  RECOVERY_TAU_NM_HOURS,
  RECOVERY_TAU_METABOLIC_HOURS,
  RECOVERY_RESIDUAL_FLOOR,
  // Plateau verdict
  PLATEAU_E1RM_SPREAD_THRESHOLD,
  PLATEAU_VOLUME_LOAD_SPREAD_THRESHOLD,
  DECLINE_E1RM_DROP_THRESHOLD,
  DECLINE_VOLUME_DROP_THRESHOLD,
  OVERREACH_VOLUME_LOAD_RATIO,
  FREQUENCY_SCALED_WINDOW_CADENCE_THRESHOLD_DAYS,
  PLATEAU_EFFORT_GATE_RPE,
  DECLINE_EFFORT_GATE_RPE,
  // Phase advance
  FORCE_DELOAD_THRESHOLD_MULTIPLIER,
  CONSECUTIVE_FORCE_DELOAD_SURFACE_THRESHOLD,
  GLOBAL_PHASE_ADVANCE_MAJOR_PATTERN_THRESHOLD,
  GLOBAL_PHASE_ADVANCE_SESSION_WINDOW,
  GLOBAL_PHASE_ADVANCE_COOLDOWN_SESSIONS,
  GLOBAL_PHASE_ADVANCE_BOOTSTRAP_GUARD,
  // Major patterns
  MAJOR_PATTERNS,
  // Cadence-aware translation
  TRANSITION_MODE_FLOOR_DAYS,
  TRANSITION_MODE_CADENCE_MULTIPLIER,
  TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS,
  DISRUPTED_PATTERN_CADENCE_MULTIPLIER,
  // Stimulus classifier
  STIMULUS_RPE_BUMP_TRIGGER,
  STIMULUS_RPE_BUMP_REP_MIN,
  STIMULUS_RPE_BUMP_REP_MAX,
  BACKOFF_NM_REP_MAX,
  BACKOFF_BOTH_REP_MAX,
  // Prescription accuracy
  PRESCRIPTION_ACCURACY_WINDOW_SIZE,
  PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES,
  PRESCRIPTION_ACCURACY_BIAS_SURFACE_THRESHOLD,
  PRESCRIPTION_ACCURACY_RMSE_SURFACE_THRESHOLD,
  PRESCRIPTION_ACCURACY_GAP_BUCKET_DIVERGENCE_THRESHOLD,
  PRESCRIPTION_ACCURACY_GAP_BUCKET_MIN_SAMPLES,
  GAP_BUCKET_BOUNDARY_LOW_HOURS,
  GAP_BUCKET_BOUNDARY_HIGH_HOURS,
  // Transfer regression
  TRANSFER_R_SQUARED_FLOOR,
  TRANSFER_MIN_PAIRED_OBSERVATIONS,
  TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS,
  TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD,
  TRANSFER_SPEARMAN_SE_WIDENING_FACTOR,
  // Fatigue interaction
  FATIGUE_INTERACTION_OBSERVATION_WINDOW,
  FATIGUE_INTERACTION_MEAN_GUARD,
  FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS,
  FATIGUE_INTERACTION_HARD_CAP_VALUE,
  FATIGUE_INTERACTION_SURFACE_THRESHOLD,
  // Form / limitation lifecycles
  FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR,
  LIMITATION_AI_INFERRED_MIN_EVIDENCE,
  LIMITATION_AI_INFERRED_MAX_SEVERITY,
  LIMITATION_AUTO_CLEAR_SESSIONS,
  // Cleared retention
  CLEARED_LIMITATION_MAX_ENTRIES,
  CLEARED_LIMITATION_MAX_AGE_MONTHS,
  // Classifier bootstrap
  CLASSIFIER_BOOTSTRAP_MAX_NOTES,
  CLASSIFIER_BOOTSTRAP_MAX_SESSIONS,
} from "./constants.ts";

// ─── EWMA / e1RM (ADR-0005) ──────────────────────────────────────────────────

Deno.test("ADR-0005: EWMA α is 0.333 not 0.30 or 0.40", () => {
  assertEquals(EWMA_ALPHA, 0.333);
});

Deno.test("ADR-0005: EWMA window is 5 valid top sets not 3 or 7", () => {
  assertEquals(EWMA_WINDOW_N, 5);
});

Deno.test("ADR-0005: transition-mode window is 3 sessions not 5", () => {
  assertEquals(TRANSITION_MODE_WINDOW_N, 3);
});

Deno.test("ADR-0005: top-set rep validity min is 3 not 1 or 4", () => {
  assertEquals(TOP_SET_REP_VALIDITY_MIN, 3);
});

Deno.test("ADR-0005: top-set rep validity max is 10 not 8 or 12", () => {
  assertEquals(TOP_SET_REP_VALIDITY_MAX, 10);
});

Deno.test("ADR-0005: top-set retention count is 10 (upper end of typical 7..10)", () => {
  assertEquals(TOP_SET_RETENTION_COUNT, 10);
});

// ─── Recovery curves (ADR-0010) ──────────────────────────────────────────────

Deno.test("ADR-0010: NM tau is 30h not 24h or 36h", () => {
  assertEquals(RECOVERY_TAU_NM_HOURS, 30);
});

Deno.test("ADR-0010: metabolic tau is 12h not 8h or 16h", () => {
  assertEquals(RECOVERY_TAU_METABOLIC_HOURS, 12);
});

Deno.test("ADR-0010: residual recovery floor is 0.3 not 0 or 0.5", () => {
  assertEquals(RECOVERY_RESIDUAL_FLOOR, 0.3);
});

// ─── Plateau verdict (ADR-0009) ──────────────────────────────────────────────

Deno.test("ADR-0009: plateau e1RM spread threshold is 2.5% not 2% or 3%", () => {
  assertEquals(PLATEAU_E1RM_SPREAD_THRESHOLD, 0.025);
});

Deno.test("ADR-0009: plateau volume-load spread threshold is 5% not 3% or 7%", () => {
  assertEquals(PLATEAU_VOLUME_LOAD_SPREAD_THRESHOLD, 0.05);
});

Deno.test("ADR-0009: decline e1RM drop threshold is 5% not 3% or 7%", () => {
  assertEquals(DECLINE_E1RM_DROP_THRESHOLD, 0.05);
});

Deno.test("ADR-0009: decline volume drop threshold is 10% not 5% or 15%", () => {
  assertEquals(DECLINE_VOLUME_DROP_THRESHOLD, 0.10);
});

Deno.test("ADR-0009: overreach volume-load ratio is 1.15 not 1.10 or 1.20", () => {
  assertEquals(OVERREACH_VOLUME_LOAD_RATIO, 1.15);
});

Deno.test("ADR-0009: frequency-scaled window cadence threshold is 3.5 days not 3 or 4", () => {
  assertEquals(FREQUENCY_SCALED_WINDOW_CADENCE_THRESHOLD_DAYS, 3.5);
});

Deno.test("ADR-0009: plateau effort gate is RPE 8.0 not 7.5 or 8.5", () => {
  assertEquals(PLATEAU_EFFORT_GATE_RPE, 8.0);
});

Deno.test("ADR-0009: decline effort gate is RPE 7.0 not 6 or 8", () => {
  assertEquals(DECLINE_EFFORT_GATE_RPE, 7.0);
});

// ─── Phase advance (ADR-0011, ADR-0012) ──────────────────────────────────────

Deno.test("ADR-0011: force-deload threshold multiplier is 2× not 1.5× or 3×", () => {
  assertEquals(FORCE_DELOAD_THRESHOLD_MULTIPLIER, 2);
});

Deno.test("ADR-0011: consecutive force-deload surface threshold is 2 not 1 or 3", () => {
  assertEquals(CONSECUTIVE_FORCE_DELOAD_SURFACE_THRESHOLD, 2);
});

Deno.test("ADR-0012: global phase-advance major-pattern threshold is 4 of 6 not 3 or 5", () => {
  assertEquals(GLOBAL_PHASE_ADVANCE_MAJOR_PATTERN_THRESHOLD, 4);
});

Deno.test("ADR-0012: global phase-advance session window is last 6 sessions not 4 or 8", () => {
  assertEquals(GLOBAL_PHASE_ADVANCE_SESSION_WINDOW, 6);
});

Deno.test("ADR-0012: global phase-advance cooldown is 6 sessions not 4 or 8", () => {
  assertEquals(GLOBAL_PHASE_ADVANCE_COOLDOWN_SESSIONS, 6);
});

Deno.test("ADR-0012: global phase-advance bootstrap guard is sessionCount ≥ 6 not 4 or 8", () => {
  assertEquals(GLOBAL_PHASE_ADVANCE_BOOTSTRAP_GUARD, 6);
});

// ─── Major patterns (ADR-0012) ───────────────────────────────────────────────

Deno.test(
  "ADR-0012: major patterns are exactly the 6 push/pull/squat/hinge axes (lunge + isolation excluded)",
  () => {
    assertEquals(MAJOR_PATTERNS, [
      "horizontal_push",
      "vertical_push",
      "horizontal_pull",
      "vertical_pull",
      "squat",
      "hip_hinge",
    ]);
  },
);

// ─── Cadence-aware translation (ADR-0015, Q5) ────────────────────────────────

Deno.test("ADR-0015 / Q5: transition-mode floor is 14 days not 7 or 21", () => {
  assertEquals(TRANSITION_MODE_FLOOR_DAYS, 14);
});

Deno.test("Q5: transition-mode cadence multiplier is 3 not 2 or 4", () => {
  assertEquals(TRANSITION_MODE_CADENCE_MULTIPLIER, 3);
});

Deno.test("Q5: nil-cadence transition-mode fallback is 21 days not 14 or 28", () => {
  assertEquals(TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS, 21);
});

Deno.test("ADR-0005: disrupted-pattern cadence multiplier is 2 not 1.5 or 3", () => {
  assertEquals(DISRUPTED_PATTERN_CADENCE_MULTIPLIER, 2);
});

// ─── Stimulus classifier (Q3 PRD-internal) ───────────────────────────────────

Deno.test("Q3: stimulus RPE-bump trigger is RPE 9 not 8 or 9.5", () => {
  assertEquals(STIMULUS_RPE_BUMP_TRIGGER, 9);
});

Deno.test("Q3: stimulus RPE-bump rep-band min is 9 not 8 or 10", () => {
  assertEquals(STIMULUS_RPE_BUMP_REP_MIN, 9);
});

Deno.test("Q3: stimulus RPE-bump rep-band max is 10 not 9 or 12", () => {
  assertEquals(STIMULUS_RPE_BUMP_REP_MAX, 10);
});

Deno.test("Q3: backoff NM rep-band max is 5 not 4 or 6", () => {
  assertEquals(BACKOFF_NM_REP_MAX, 5);
});

Deno.test("Q3: backoff both-stimulus rep-band max is 8 not 7 or 9", () => {
  assertEquals(BACKOFF_BOTH_REP_MAX, 8);
});

// ─── Prescription accuracy (ADR-0014) ────────────────────────────────────────

Deno.test("ADR-0014: prescription-accuracy sliding window is 30 obs not 20 or 50", () => {
  assertEquals(PRESCRIPTION_ACCURACY_WINDOW_SIZE, 30);
});

Deno.test("ADR-0014: prescription-accuracy digest min samples is 5 not 3 or 10", () => {
  assertEquals(PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES, 5);
});

Deno.test("ADR-0014: prescription-accuracy bias surface threshold is 0.05 not 0.03 or 0.10", () => {
  assertEquals(PRESCRIPTION_ACCURACY_BIAS_SURFACE_THRESHOLD, 0.05);
});

Deno.test("ADR-0014: prescription-accuracy rmse surface threshold is 0.10 not 0.05 or 0.15", () => {
  assertEquals(PRESCRIPTION_ACCURACY_RMSE_SURFACE_THRESHOLD, 0.10);
});

Deno.test("ADR-0014: gap-bucket divergence threshold is 0.05 not 0.03 or 0.10", () => {
  assertEquals(PRESCRIPTION_ACCURACY_GAP_BUCKET_DIVERGENCE_THRESHOLD, 0.05);
});

Deno.test("ADR-0014: gap-bucket min samples is 3 not 2 or 5", () => {
  assertEquals(PRESCRIPTION_ACCURACY_GAP_BUCKET_MIN_SAMPLES, 3);
});

Deno.test("ADR-0014: gap-bucket low boundary is 48h not 36h or 60h", () => {
  assertEquals(GAP_BUCKET_BOUNDARY_LOW_HOURS, 48);
});

Deno.test("ADR-0014: gap-bucket high boundary is 72h not 60h or 96h", () => {
  assertEquals(GAP_BUCKET_BOUNDARY_HIGH_HOURS, 72);
});

// ─── Transfer regression (Q10, ADR-0005) ─────────────────────────────────────

Deno.test("Q10: transfer R² floor is 0.4 not 0.3 or 0.5", () => {
  assertEquals(TRANSFER_R_SQUARED_FLOOR, 0.4);
});

Deno.test("Q10 / ADR-0005: transfer min paired observations is 5 not 3 or 10", () => {
  assertEquals(TRANSFER_MIN_PAIRED_OBSERVATIONS, 5);
});

Deno.test("Q10: Spearman flag min observations is 10 not 5 or 15", () => {
  assertEquals(TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS, 10);
});

Deno.test("Q10: Spearman divergence threshold is 0.15 not 0.10 or 0.20", () => {
  assertEquals(TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD, 0.15);
});

Deno.test(
  "Q10 / 2026-05-07 resolution: Spearman SE-widening factor is 1.0 (literal proportionality)",
  () => {
    assertEquals(TRANSFER_SPEARMAN_SE_WIDENING_FACTOR, 1.0);
  },
);

// ─── Fatigue interaction (ADR-0005) ──────────────────────────────────────────

Deno.test("ADR-0005: fatigue-interaction observation window is 10 obs not 5 or 15", () => {
  assertEquals(FATIGUE_INTERACTION_OBSERVATION_WINDOW, 10);
});

Deno.test("ADR-0005: fatigue-interaction mean-guard is 0.001 not 0.01 or 0.0001", () => {
  assertEquals(FATIGUE_INTERACTION_MEAN_GUARD, 0.001);
});

Deno.test("ADR-0005: fatigue-interaction hard-cap observations is 15 not 10 or 20", () => {
  assertEquals(FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS, 15);
});

Deno.test("ADR-0005: fatigue-interaction hard-cap value is 0.5 not 0.3 or 0.7", () => {
  assertEquals(FATIGUE_INTERACTION_HARD_CAP_VALUE, 0.5);
});

Deno.test("ADR-0005: fatigue-interaction surface threshold is 0.7 not 0.6 or 0.8", () => {
  assertEquals(FATIGUE_INTERACTION_SURFACE_THRESHOLD, 0.7);
});

// ─── Form-degradation / limitation lifecycles (Q9 PRD-internal) ──────────────

Deno.test("Q9: form-degradation clean sessions to clear is 3 not 2 or 4", () => {
  assertEquals(FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR, 3);
});

Deno.test("Q9: AI-inferred limitation min evidence is 2 not 1 or 3", () => {
  assertEquals(LIMITATION_AI_INFERRED_MIN_EVIDENCE, 2);
});

Deno.test("Q9 / ADR-0005: AI-inferred limitation max severity is 'mild' not 'moderate' or 'severe'", () => {
  assertEquals(LIMITATION_AI_INFERRED_MAX_SEVERITY, "mild");
});

Deno.test("Q9: limitation auto-clear sessions is 3 not 2 or 4", () => {
  assertEquals(LIMITATION_AUTO_CLEAR_SESSIONS, 3);
});

// ─── Cleared limitation retention (ADR-0005) ─────────────────────────────────

Deno.test("ADR-0005: cleared limitation max entries is 50 not 25 or 100", () => {
  assertEquals(CLEARED_LIMITATION_MAX_ENTRIES, 50);
});

Deno.test("ADR-0005: cleared limitation max age is 12 months not 6 or 24", () => {
  assertEquals(CLEARED_LIMITATION_MAX_AGE_MONTHS, 12);
});

// ─── Classifier bootstrap (ADR-0013) ─────────────────────────────────────────

Deno.test("ADR-0013: classifier bootstrap max notes is 20 not 10 or 30", () => {
  assertEquals(CLASSIFIER_BOOTSTRAP_MAX_NOTES, 20);
});

Deno.test("ADR-0013: classifier bootstrap max sessions is 5 not 3 or 7", () => {
  assertEquals(CLASSIFIER_BOOTSTRAP_MAX_SESSIONS, 5);
});
