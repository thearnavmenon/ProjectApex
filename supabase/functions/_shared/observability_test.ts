// Project Apex — Phase 2 observability emit-helpers tests.
//
// Per ADR-0006 §"Observability", structured events emit to "a Supabase
// table or external log sink." For v2 alpha scale, the emit helpers
// write a JSON envelope `{ channel, event }` to stdout via console.log
// (Supabase Edge Function logs capture stdout). These tests exercise
// each helper's payload shape so downstream rule slices (A5, A12, A13)
// emit consistent envelopes.
//
// Testing approach: stub console.log per-test, capture the envelope,
// assert channel string + every required field.
//
// Run locally:
//   deno test supabase/functions/_shared/observability_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  emitClassifierFailed,
  emitClockSkew,
  emitLateArrival,
  emitTransferNegativeCoefficient,
} from "./observability.ts";

// ─── stdout capture helper ──────────────────────────────────────────────────

/**
 * Calls `fn` with `console.log` replaced by a capture sink. Returns the
 * captured strings (one per call). Restores the original `console.log`
 * unconditionally — including on thrown exceptions — so test failures
 * don't pollute subsequent tests.
 */
function captureConsoleLog(fn: () => void): string[] {
  const captured: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => {
    captured.push(args.map((a) => typeof a === "string" ? a : JSON.stringify(a)).join(" "));
  };
  try {
    fn();
  } finally {
    console.log = original;
  }
  return captured;
}

// ─── emitLateArrival (ADR-0008) ─────────────────────────────────────────────

Deno.test("ADR-0008: emitLateArrival emits JSON envelope on channel trainee_model.late_arrival with all 5 fields", () => {
  const event = {
    user_id: "11111111-1111-1111-1111-111111111111",
    session_id: "22222222-2222-2222-2222-222222222222",
    incoming_logged_at: "2026-05-07T12:00:00.000Z",
    watermark: "2026-05-07T18:00:00.000Z",
    delta_seconds: -21600,
  };

  const lines = captureConsoleLog(() => emitLateArrival(event));

  assertEquals(lines.length, 1, "emitLateArrival must call console.log exactly once");
  const envelope = JSON.parse(lines[0]);
  assertEquals(envelope.channel, "trainee_model.late_arrival");
  assertEquals(envelope.event, event);
});

// ─── emitClassifierFailed (ADR-0013) ────────────────────────────────────────

Deno.test("ADR-0013: emitClassifierFailed emits JSON envelope on channel trainee_model.classifier_failed with all 4 fields", () => {
  const event = {
    user_id: "33333333-3333-3333-3333-333333333333",
    session_id: "44444444-4444-4444-4444-444444444444",
    error_class: "haiku_unreachable",
    notes_attempted_count: 7,
  };

  const lines = captureConsoleLog(() => emitClassifierFailed(event));

  assertEquals(lines.length, 1, "emitClassifierFailed must call console.log exactly once");
  const envelope = JSON.parse(lines[0]);
  assertEquals(envelope.channel, "trainee_model.classifier_failed");
  assertEquals(envelope.event, event);
});

// ─── emitClockSkew (ADR-0010) ───────────────────────────────────────────────

Deno.test("ADR-0010: emitClockSkew emits JSON envelope on channel recovery.clock_skew with all 4 fields", () => {
  const event = {
    user_id: "55555555-5555-5555-5555-555555555555",
    last_stimulus_at: "2026-05-08T03:00:00.000Z",
    now: "2026-05-07T18:00:00.000Z",
    delta_seconds: 32400,
  };

  const lines = captureConsoleLog(() => emitClockSkew(event));

  assertEquals(lines.length, 1, "emitClockSkew must call console.log exactly once");
  const envelope = JSON.parse(lines[0]);
  assertEquals(envelope.channel, "recovery.clock_skew");
  assertEquals(envelope.event, event);
});

// ─── emitTransferNegativeCoefficient (Q10, slice A10) ───────────────────────

Deno.test("Q10 (slice A10): emitTransferNegativeCoefficient emits JSON envelope on channel trainee_model.transfer_negative_coefficient with all 6 fields", () => {
  // Helper added in slice A10 for use by orchestrator A12 — A12 owns
  // pair-detection (fromExerciseId/toExerciseId) and is the natural call
  // site once it wraps fitTransfer with paired-observation orchestration.
  // Required-payload-only typing prevents callers from accidentally
  // dropping the pair identifier and producing un-actionable warnings.
  const event = {
    user_id: "66666666-6666-6666-6666-666666666666",
    from_exercise_id: "77777777-7777-7777-7777-777777777777",
    to_exercise_id: "88888888-8888-8888-8888-888888888888",
    coefficient: -0.42,
    r_squared: 0.55,
    paired_observations: 8,
  };

  const lines = captureConsoleLog(() => emitTransferNegativeCoefficient(event));

  assertEquals(lines.length, 1, "emitTransferNegativeCoefficient must call console.log exactly once");
  const envelope = JSON.parse(lines[0]);
  assertEquals(envelope.channel, "trainee_model.transfer_negative_coefficient");
  assertEquals(envelope.event, event);
});
