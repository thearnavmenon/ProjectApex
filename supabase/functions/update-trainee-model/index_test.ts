// Project Apex — update-trainee-model Edge Function — validator tests.
//
// Covers the Slice 6 (issue #10) extension to `validateRequest` that
// descends into `session_payload.set_logs[]` and rejects rows missing
// or carrying an invalid `intent` field. The Edge Function itself remains
// a Phase-1 no-op stub; these tests exercise the validator in isolation.
//
// Run locally:
//   deno test supabase/functions/update-trainee-model/index_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { validateRequest } from "./index.ts";

const VALID_USER_ID = "11111111-1111-4111-8111-111111111111";
const VALID_SESSION_ID = "22222222-2222-4222-8222-222222222222";

function baseRequest(payloadOverrides: Record<string, unknown> = {}) {
  return {
    user_id: VALID_USER_ID,
    session_id: VALID_SESSION_ID,
    session_payload: payloadOverrides,
  };
}

// ─── D1: no set_logs key — passes ────────────────────────────────────────────
Deno.test("validateRequest_no_set_logs_field_returns_ok", () => {
  const result = validateRequest(baseRequest({}));
  assertEquals("error" in result, false);
});

// ─── D2: every valid intent — passes ─────────────────────────────────────────
Deno.test("validateRequest_set_logs_each_with_valid_intent_returns_ok", () => {
  const intents = ["warmup", "top", "backoff", "technique", "amrap"];
  const setLogs = intents.map((intent, i) => ({
    set_number: i + 1,
    weight_kg: 80,
    reps_completed: 8,
    intent,
  }));
  const result = validateRequest(baseRequest({ set_logs: setLogs }));
  assertEquals("error" in result, false);
});

// ─── D3: missing intent — 400 ────────────────────────────────────────────────
Deno.test("validateRequest_set_log_missing_intent_returns_400", () => {
  const setLogs = [
    { set_number: 1, weight_kg: 80, reps_completed: 8, intent: "top" },
    { set_number: 2, weight_kg: 70, reps_completed: 10 }, // intent missing
  ];
  const result = validateRequest(baseRequest({ set_logs: setLogs }));
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  // Error message must name the offending index so an operator debugging
  // the rejection knows which row to fix.
  assertEquals(
    result.error.includes("set_logs[1]") &&
      result.error.includes("missing required field 'intent'"),
    true,
    `unexpected error text: ${result.error}`,
  );
});

// ─── D4: invalid intent string — 400 ─────────────────────────────────────────
Deno.test("validateRequest_set_log_invalid_intent_string_returns_400", () => {
  const setLogs = [
    { set_number: 1, weight_kg: 80, reps_completed: 8, intent: "bogus" },
  ];
  const result = validateRequest(baseRequest({ set_logs: setLogs }));
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  assertEquals(
    result.error.includes("set_logs[0].intent") &&
      result.error.includes("warmup/top/backoff/technique/amrap"),
    true,
    `unexpected error text: ${result.error}`,
  );
});

// ─── D5: set_logs not an array — 400 ─────────────────────────────────────────
Deno.test("validateRequest_set_logs_not_array_returns_400", () => {
  const result = validateRequest(baseRequest({ set_logs: { foo: 1 } }));
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  assertEquals(result.error, "session_payload.set_logs must be an array");
});

// ─── Sanity: still rejects missing user_id (regression cover for the Slice
//     9b validator behaviour) ───────────────────────────────────────────────
Deno.test("validateRequest_invalid_user_id_returns_400", () => {
  const result = validateRequest({
    user_id: "not-a-uuid",
    session_id: VALID_SESSION_ID,
    session_payload: {},
  });
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  assertEquals(result.error, "user_id must be a UUID string");
});

// ─── Edge case: intent set to null (vs missing) — 400 ───────────────────────
Deno.test("validateRequest_set_log_intent_null_returns_400", () => {
  const setLogs = [
    { set_number: 1, weight_kg: 80, reps_completed: 8, intent: null },
  ];
  const result = validateRequest(baseRequest({ set_logs: setLogs }));
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  assertEquals(
    result.error.includes("set_logs[0]") &&
      result.error.includes("missing required field 'intent'"),
    true,
    `unexpected error text: ${result.error}`,
  );
});

// ─── Edge case: intent set to non-string (number) — 400 ─────────────────────
Deno.test("validateRequest_set_log_intent_non_string_returns_400", () => {
  const setLogs = [
    { set_number: 1, weight_kg: 80, reps_completed: 8, intent: 42 },
  ];
  const result = validateRequest(baseRequest({ set_logs: setLogs }));
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  assertEquals(
    result.error.includes("set_logs[0].intent") &&
      result.error.includes("warmup/top/backoff/technique/amrap"),
    true,
    `unexpected error text: ${result.error}`,
  );
});

// ─── Edge case: set_logs entry that is null — 400 ───────────────────────────
Deno.test("validateRequest_set_log_entry_null_returns_400", () => {
  const result = validateRequest(baseRequest({ set_logs: [null] }));
  if (!("error" in result)) {
    throw new Error("expected error response");
  }
  assertEquals(result.error, "session_payload.set_logs[0] must be a JSON object");
});
