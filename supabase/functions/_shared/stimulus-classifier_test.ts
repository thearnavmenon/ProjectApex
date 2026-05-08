// Project Apex — Phase 2 stimulus-classifier tests.
//
// Per Q3 PRD-internal (lock-in 2026-05-07) and ADR-0005 (two-dimensional
// recovery via Optional return for low-stimulus sets), this module
// classifies (intent, reps, rpeFelt) → StimulusDimension | null. Each
// test name pins the originating decision (Q3 row or ADR clause) so a
// failure surfaces the rule the change touches.
//
// Run locally:
//   deno test supabase/functions/_shared/stimulus-classifier_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { classifyStimulus } from "./stimulus-classifier.ts";

Deno.test("Q3 / ADR-0005: warmup intent honoured even with high-load rep shape → null", () => {
  assertEquals(classifyStimulus("warmup", 5, 8), null);
  // Spans rep/RPE space so the "regardless of reps/RPE" claim has breadth:
  // a different rep band + the null-RPE path. Implementation is intent-first,
  // so any one point is sufficient evidence; broader assertions guard against
  // a future refactor that reorders rep/RPE checks ahead of intent on some path.
  assertEquals(classifyStimulus("warmup", 12, null), null);
});

Deno.test("Q3 / ADR-0005: technique intent → null regardless of reps/RPE", () => {
  assertEquals(classifyStimulus("technique", 5, 8), null);
  // Different rep band + a high-RPE point — same breadth rationale as above.
  assertEquals(classifyStimulus("technique", 3, 10), null);
});

Deno.test("Q3: top set in 3–5 rep band → neuromuscular", () => {
  assertEquals(classifyStimulus("top", 3, 7), "neuromuscular");
  assertEquals(classifyStimulus("top", 5, 7), "neuromuscular");
});

Deno.test("Q3: top set in 6–8 rep band → both", () => {
  assertEquals(classifyStimulus("top", 6, 7), "both");
  assertEquals(classifyStimulus("top", 8, 7), "both");
});

Deno.test("Q3: top set in 9–10 rep band with RPE < 9 → metabolic", () => {
  assertEquals(classifyStimulus("top", 9, 7), "metabolic");
  assertEquals(classifyStimulus("top", 10, 8.5), "metabolic");
});

Deno.test("Q3: top set in 9–10 rep band with RPE ≥ 9 → both (RPE bump)", () => {
  assertEquals(classifyStimulus("top", 9, 9), "both");
  assertEquals(classifyStimulus("top", 10, 10), "both");
});

Deno.test("Q3: RPE-bump boundary is strict — RPE = 8.99 → metabolic (not both)", () => {
  // RPE bump fires at rpeFelt >= 9 (STIMULUS_RPE_BUMP_TRIGGER); strict-less-than at boundary.
  assertEquals(classifyStimulus("top", 9, 8.99), "metabolic");
  assertEquals(classifyStimulus("top", 10, 8.99), "metabolic");
});

Deno.test("Q3: top 9–10 with nil RPE → metabolic (bump requires RPE ≥ 9; null is not ≥)", () => {
  assertEquals(classifyStimulus("top", 9, null), "metabolic");
  assertEquals(classifyStimulus("top", 10, null), "metabolic");
});

Deno.test("Q3: top rep-band boundaries — 5→NM, 6→both, 8→both, 9→metabolic", () => {
  assertEquals(classifyStimulus("top", 5, 7), "neuromuscular");
  assertEquals(classifyStimulus("top", 6, 7), "both");
  assertEquals(classifyStimulus("top", 8, 7), "both");
  assertEquals(classifyStimulus("top", 9, 7), "metabolic");
});

Deno.test("Q3: backoff in 3–5 rep band → neuromuscular", () => {
  assertEquals(classifyStimulus("backoff", 3, 8), "neuromuscular");
  assertEquals(classifyStimulus("backoff", 5, 8), "neuromuscular");
});

Deno.test("Q3: backoff in 6–8 rep band → both", () => {
  assertEquals(classifyStimulus("backoff", 6, 8), "both");
  assertEquals(classifyStimulus("backoff", 8, 8), "both");
});

Deno.test("Q3: backoff at 9+ reps → metabolic (no upper bound, no RPE bump)", () => {
  assertEquals(classifyStimulus("backoff", 9, 8), "metabolic");
  assertEquals(classifyStimulus("backoff", 12, 8), "metabolic");
  assertEquals(classifyStimulus("backoff", 20, 10), "metabolic");
});

Deno.test("Q3: backoff rep-band boundaries — 5→NM, 6→both, 8→both, 9→metabolic", () => {
  assertEquals(classifyStimulus("backoff", 5, 8), "neuromuscular");
  assertEquals(classifyStimulus("backoff", 6, 8), "both");
  assertEquals(classifyStimulus("backoff", 8, 8), "both");
  assertEquals(classifyStimulus("backoff", 9, 8), "metabolic");
});

Deno.test("Q3: amrap → both regardless of reps/RPE (max-effort final-set; intent dominates)", () => {
  // Q3 PRD-internal lock-in (2026-05-07): AMRAP is a max-effort final set;
  // the asymmetric-error logic of the top 9–10 RPE-bump applies — AMRAP-to-
  // failure crosses NM-driving territory in addition to metabolic. Issue
  // #76 body's "metabolic" cell is a transcription error against the
  // grilling lock-in; flagged in PR description.
  assertEquals(classifyStimulus("amrap", 12, 10), "both");
  assertEquals(classifyStimulus("amrap", 8, 9), "both");
});

Deno.test("Q3: amrap at low reps still → both (intent dominates over rep shape)", () => {
  assertEquals(classifyStimulus("amrap", 5, 9), "both");
  assertEquals(classifyStimulus("amrap", 3, 8), "both");
});

Deno.test("Q3 / #76 item-11: top reps > 10 (outside e1RM validity) → metabolic", () => {
  // Issue #76 edge case: "Top set at 11+ reps — outside the 3-10 validity
  // range; classify as if 9-10 row applies (most permissive metabolic-
  // shaped result). The 3..10 validity gate is for e1RM contribution,
  // not stimulus classification." Flagged in PR description for reviewer
  // confirmation; if reviewer disagrees, the row is amendable in a
  // follow-up patch.
  assertEquals(classifyStimulus("top", 11, 7), "metabolic");
  assertEquals(classifyStimulus("top", 15, 8), "metabolic");
});
