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
import {
  capTopSets,
  derivedTrainedSets,
  handleRequest,
  validateRequest,
} from "./index.ts";
import { TOP_SET_RETENTION_COUNT } from "../_shared/constants.ts";

const VALID_USER_ID = "11111111-1111-4111-8111-111111111111";
const VALID_SESSION_ID = "22222222-2222-4222-8222-222222222222";
const OTHER_USER_ID = "33333333-3333-4333-8333-333333333333";

function baseRequest(payloadOverrides: Record<string, unknown> = {}) {
  return {
    user_id: VALID_USER_ID,
    session_id: VALID_SESSION_ID,
    session_payload: payloadOverrides,
  };
}

// ─── #167: derivedTrainedSets rejects non-canonical primary_muscle strings ───
// posterior_deltoid is not a canonical MuscleGroup; before the fix the else
// branch added it verbatim, leaking it into trainedMuscleGroups where it could
// falsely satisfy the note-classifier auto-clear gate.
Deno.test("derivedTrainedSets_rejects_unknown_primary_muscle", () => {
  const trained = derivedTrainedSets({
    set_logs: [
      { exercise_id: "ex-1", primary_muscle: "posterior_deltoid", intent: "top" },
    ],
  });
  assertEquals(
    trained.muscleGroups.has("posterior_deltoid"),
    false,
    "unknown primary_muscle must not leak into muscleGroups",
  );
});

// And a canonical primary_muscle still flows through unchanged.
Deno.test("derivedTrainedSets_keeps_canonical_primary_muscle", () => {
  const trained = derivedTrainedSets({
    set_logs: [
      { exercise_id: "ex-1", primary_muscle: "chest", intent: "top" },
      { exercise_id: "ex-2", primary_muscle: "quads", intent: "top" },
    ],
  });
  assertEquals(trained.muscleGroups.has("chest"), true, "canonical group retained");
  assertEquals(trained.muscleGroups.has("legs"), true, "leg subgroup collapses to legs");
});

// ─── #239 (#167 sibling): derivedTrainedSets rejects non-canonical e.pattern ──
// "bench" is not a canonical MovementPattern; before the fix the client-string
// branch added it verbatim, leaking it into trainedPatterns where it could
// falsely satisfy the note-classifier auto-clear gate. With no exercise_id
// there is no library fallback, so a rejected pattern leaves patterns empty.
Deno.test("derivedTrainedSets_rejects_unknown_pattern", () => {
  const trained = derivedTrainedSets({
    set_logs: [
      { pattern: "bench", intent: "top" },
    ],
  });
  assertEquals(
    trained.patterns.has("bench"),
    false,
    "unknown pattern must not leak into patterns",
  );
  assertEquals(trained.patterns.size, 0, "no library fallback without exercise_id");
});

// A canonical client pattern still flows through unchanged.
Deno.test("derivedTrainedSets_keeps_canonical_pattern", () => {
  const trained = derivedTrainedSets({
    set_logs: [
      { pattern: "horizontal_push", intent: "top" },
    ],
  });
  assertEquals(
    trained.patterns.has("horizontal_push"),
    true,
    "canonical pattern retained",
  );
});

// Highest-value assertion: a bogus client pattern must neither leak nor suppress
// the real pattern — it falls through to the trustworthy ExerciseLibrary lookup.
Deno.test("derivedTrainedSets_falls_through_to_library_on_unknown_pattern", () => {
  const trained = derivedTrainedSets({
    set_logs: [
      { exercise_id: "barbell_bench_press", pattern: "bogus", intent: "top" },
    ],
  });
  assertEquals(
    trained.patterns.has("horizontal_push"),
    true,
    "bogus client pattern falls through to lookupPattern",
  );
  assertEquals(
    trained.patterns.has("bogus"),
    false,
    "bogus client pattern must not leak into patterns",
  );
});

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

// ─── #369 [12]: ExerciseProfile.topSets bounded retention (capTopSets) ───────
// Without the cap, topSets grows by one+ append per session-apply and never
// shrinks. capTopSets enforces ADR-0005's TOP_SET_RETENTION_COUNT, keeping the
// most recent N (the tail, since new sets append at the end).

Deno.test("capTopSets_under_count_returns_unchanged", () => {
  // Fewer than the retention count → no truncation, same reference is fine.
  const sets = Array.from({ length: TOP_SET_RETENTION_COUNT - 1 }, (_, i) => i);
  assertEquals(capTopSets(sets), sets);
});

Deno.test("capTopSets_exactly_count_returns_unchanged", () => {
  // Exactly the retention count is at the boundary, NOT over it → unchanged.
  const sets = Array.from({ length: TOP_SET_RETENTION_COUNT }, (_, i) => i);
  assertEquals(capTopSets(sets), sets);
  assertEquals(capTopSets(sets).length, TOP_SET_RETENTION_COUNT);
});

Deno.test("capTopSets_over_count_keeps_newest_N_from_tail", () => {
  // Append-order markers 0..N+4 (oldest..newest). After capping we must keep
  // the NEWEST N — i.e. the last N markers — and drop the oldest 5.
  const extra = 5;
  const sets = Array.from(
    { length: TOP_SET_RETENTION_COUNT + extra },
    (_, i) => i,
  );
  const capped = capTopSets(sets);
  assertEquals(capped.length, TOP_SET_RETENTION_COUNT);
  // Newest N are markers [extra .. N+extra-1]; oldest `extra` are dropped.
  const expected = Array.from(
    { length: TOP_SET_RETENTION_COUNT },
    (_, i) => i + extra,
  );
  assertEquals(capped, expected);
  // Spot-check the ends: oldest dropped, newest retained.
  assertEquals(capped[0], extra);
  assertEquals(capped[capped.length - 1], TOP_SET_RETENTION_COUNT + extra - 1);
});

// ─── #369 slice 4: handleRequest JWT-`sub` ownership check (closes the IDOR) ──
//
// The handler derives the caller from the verified JWT `sub` (decode-only; the
// platform verifies the signature) and rejects when it doesn't match the body
// `user_id`. The reject paths return BEFORE getSql, so no DB is needed. A
// fake-but-well-formed JWT (header.payload.signature; payload base64url-encodes
// the claims; dummy signature) drives every case.

function b64url(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fakeJwt(sub: string): string {
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify({ sub, role: "authenticated" }));
  return `${header}.${payload}.dummy-signature-not-verified`;
}

function postRequest(
  body: Record<string, unknown>,
  authorization?: string,
): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (authorization !== undefined) headers.Authorization = authorization;
  return new Request("https://example.test/update-trainee-model", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function validBody(): Record<string, unknown> {
  return {
    user_id: VALID_USER_ID,
    session_id: VALID_SESSION_ID,
    session_payload: {},
  };
}

Deno.test("handleRequest_sub_mismatch_returns_403", async () => {
  // Authenticated as OTHER, but body claims VALID_USER_ID → IDOR → 403.
  const res = await handleRequest(
    postRequest(validBody(), `Bearer ${fakeJwt(OTHER_USER_ID)}`),
  );
  assertEquals(res.status, 403);
});

Deno.test("handleRequest_missing_authorization_returns_401", async () => {
  const res = await handleRequest(postRequest(validBody()));
  assertEquals(res.status, 401);
});

Deno.test("handleRequest_malformed_jwt_returns_401", async () => {
  const res = await handleRequest(
    postRequest(validBody(), "Bearer garbage-not-a-jwt"),
  );
  assertEquals(res.status, 401);
});

Deno.test("handleRequest_sub_match_passes_ownership_gate", async () => {
  // sub === body.user_id → the gate lets it through. With no SUPABASE_DB_URL
  // set in the unit-test env, getSql throws and the handler returns 500 — which
  // proves the request PASSED the ownership gate (it is neither 403 nor 401).
  // The 200 happy path is covered by the DB-integration tests (orchestrator).
  const prior = Deno.env.get("SUPABASE_DB_URL");
  Deno.env.delete("SUPABASE_DB_URL");
  try {
    const res = await handleRequest(
      postRequest(validBody(), `Bearer ${fakeJwt(VALID_USER_ID)}`),
    );
    await res.body?.cancel();
    assertEquals(res.status !== 403 && res.status !== 401, true);
    assertEquals(res.status, 500);
  } finally {
    if (prior !== undefined) Deno.env.set("SUPABASE_DB_URL", prior);
  }
});
