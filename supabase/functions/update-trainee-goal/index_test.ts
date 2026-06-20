// Project Apex — update-trainee-goal Edge Function — validator tests.
//
// #147: validates the request shape before the SQL write runs. Integration
// tests against a real DB are covered separately (the orchestrator_test.ts
// pattern from update-trainee-model could be ported when needed); this
// file exercises the validator in isolation.
//
// Run locally:
//   deno test supabase/functions/update-trainee-goal/index_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { handleRequest, validateRequest } from "./index.ts";

const VALID_USER_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_USER_ID = "22222222-2222-4222-8222-222222222222";
const VALID_GOAL = {
  statement: "Hypertrophy (muscle size)",
  focusAreas: [],
  updatedAt: "2026-05-12T10:00:00.000Z",
};

function baseRequest(overrides: Record<string, unknown> = {}) {
  return { user_id: VALID_USER_ID, goal: VALID_GOAL, ...overrides };
}

Deno.test("validateRequest_happy_path_returns_ok", () => {
  const result = validateRequest(baseRequest());
  assertEquals("error" in result, false);
});

Deno.test("validateRequest_non_object_body_returns_400", () => {
  const r1 = validateRequest(null);
  const r2 = validateRequest([1, 2, 3]);
  const r3 = validateRequest("string");
  assertEquals("error" in r1, true);
  assertEquals("error" in r2, true);
  assertEquals("error" in r3, true);
});

Deno.test("validateRequest_missing_user_id_returns_400", () => {
  const result = validateRequest({ goal: VALID_GOAL });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("user_id"), true);
});

Deno.test("validateRequest_invalid_user_id_uuid_returns_400", () => {
  const result = validateRequest({ user_id: "not-a-uuid", goal: VALID_GOAL });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("user_id"), true);
});

Deno.test("validateRequest_missing_goal_returns_400", () => {
  const result = validateRequest({ user_id: VALID_USER_ID });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("goal"), true);
});

Deno.test("validateRequest_goal_missing_statement_returns_400", () => {
  const result = validateRequest({
    user_id: VALID_USER_ID,
    goal: { focusAreas: [], updatedAt: "2026-05-12T10:00:00Z" },
  });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("statement"), true);
});

Deno.test("validateRequest_goal_focusAreas_not_array_returns_400", () => {
  const result = validateRequest({
    user_id: VALID_USER_ID,
    goal: {
      statement: "x",
      focusAreas: "not-an-array",
      updatedAt: "2026-05-12T10:00:00Z",
    },
  });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("focusAreas"), true);
});

Deno.test("validateRequest_goal_focusAreas_non_string_entry_returns_400", () => {
  const result = validateRequest({
    user_id: VALID_USER_ID,
    goal: {
      statement: "x",
      focusAreas: ["legs", 42, "back"],
      updatedAt: "2026-05-12T10:00:00Z",
    },
  });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("focusAreas[1]"), true);
});

Deno.test("validateRequest_goal_updatedAt_not_iso_returns_400", () => {
  const result = validateRequest({
    user_id: VALID_USER_ID,
    goal: {
      statement: "x",
      focusAreas: [],
      updatedAt: "not-a-date",
    },
  });
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("updatedAt"), true);
});

Deno.test("validateRequest_empty_statement_accepted", () => {
  // GoalState.placeholder shape — empty statement is valid input. The
  // sentinel pattern is used by digest-side cold-start detection, not
  // rejected at the write boundary.
  const result = validateRequest({
    user_id: VALID_USER_ID,
    goal: { statement: "", focusAreas: [], updatedAt: "2026-05-12T10:00:00Z" },
  });
  assertEquals("error" in result, false);
});

Deno.test("validateRequest_focusAreas_with_muscle_groups_accepted", () => {
  const result = validateRequest({
    user_id: VALID_USER_ID,
    goal: {
      statement: "Build broad strength",
      focusAreas: ["legs", "back"],
      updatedAt: "2026-05-12T10:00:00Z",
    },
  });
  assertEquals("error" in result, false);
});

// ─── #258 Slice B: optional acknowledge_triggering_session_count ─────────────

Deno.test("validateRequest_ack_valid_nonNegativeInt_accepted", () => {
  const result = validateRequest(
    baseRequest({ acknowledge_triggering_session_count: 5 }),
  );
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.acknowledge_triggering_session_count, 5);
});

Deno.test("validateRequest_ack_zero_accepted", () => {
  // 0 is a valid session count (>= 0); the lower bound is inclusive.
  const result = validateRequest(
    baseRequest({ acknowledge_triggering_session_count: 0 }),
  );
  assertEquals("error" in result, false);
});

Deno.test("validateRequest_ack_absent_still_valid", () => {
  // Back-compat: onboarding omits the field and must remain valid.
  const result = validateRequest(baseRequest());
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.acknowledge_triggering_session_count, undefined);
});

Deno.test("validateRequest_ack_negative_returns_400", () => {
  const result = validateRequest(
    baseRequest({ acknowledge_triggering_session_count: -1 }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(
    result.error.includes("acknowledge_triggering_session_count"),
    true,
  );
});

Deno.test("validateRequest_ack_nonInteger_returns_400", () => {
  const result = validateRequest(
    baseRequest({ acknowledge_triggering_session_count: 3.5 }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(
    result.error.includes("acknowledge_triggering_session_count"),
    true,
  );
});

Deno.test("validateRequest_ack_nonNumber_returns_400", () => {
  // A numeric-looking string must be rejected (Number.isInteger("5") is false).
  const result = validateRequest(
    baseRequest({ acknowledge_triggering_session_count: "5" }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(
    result.error.includes("acknowledge_triggering_session_count"),
    true,
  );
});

// #296 (#269): stretch_edits validation.

Deno.test("validateRequest_stretch_edits_absent_still_valid", () => {
  const result = validateRequest(baseRequest());
  assertEquals("error" in result, false);
});

Deno.test("validateRequest_stretch_edits_valid_accepted", () => {
  const result = validateRequest(
    baseRequest({ stretch_edits: [{ pattern: "squat", stretch: 150 }] }),
  );
  assertEquals("error" in result, false);
  if (!("error" in result)) {
    assertEquals(result.stretch_edits, [{ pattern: "squat", stretch: 150 }]);
  }
});

Deno.test("validateRequest_stretch_edits_non_array_returns_400", () => {
  const result = validateRequest(baseRequest({ stretch_edits: { pattern: "squat", stretch: 150 } }));
  assertEquals("error" in result, true);
});

Deno.test("validateRequest_stretch_edits_non_major_pattern_returns_400", () => {
  const result = validateRequest(
    baseRequest({ stretch_edits: [{ pattern: "isolation", stretch: 30 }] }),
  );
  assertEquals("error" in result, true);
});

Deno.test("validateRequest_stretch_edits_non_positive_stretch_returns_400", () => {
  const zero = validateRequest(baseRequest({ stretch_edits: [{ pattern: "squat", stretch: 0 }] }));
  const neg = validateRequest(baseRequest({ stretch_edits: [{ pattern: "squat", stretch: -5 }] }));
  assertEquals("error" in zero, true);
  assertEquals("error" in neg, true);
});

Deno.test("validateRequest_stretch_edits_non_object_entry_returns_400", () => {
  const result = validateRequest(baseRequest({ stretch_edits: ["squat"] }));
  assertEquals("error" in result, true);
});

// #269 S4: acknowledge_calibration_review validation.

Deno.test("validateRequest_ack_calibration_review_absent_still_valid", () => {
  // Back-compat: onboarding / goal-review omit the field and must remain valid.
  const result = validateRequest(baseRequest());
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.acknowledge_calibration_review, undefined);
});

Deno.test("validateRequest_ack_calibration_review_true_accepted", () => {
  const result = validateRequest(
    baseRequest({ acknowledge_calibration_review: true }),
  );
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.acknowledge_calibration_review, true);
});

Deno.test("validateRequest_ack_calibration_review_false_accepted", () => {
  // false is a valid boolean; the write only fires on === true.
  const result = validateRequest(
    baseRequest({ acknowledge_calibration_review: false }),
  );
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.acknowledge_calibration_review, false);
});

Deno.test("validateRequest_ack_calibration_review_nonBoolean_returns_400", () => {
  // A truthy string must be rejected (typeof "true" !== "boolean").
  const result = validateRequest(
    baseRequest({ acknowledge_calibration_review: "true" }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("acknowledge_calibration_review"), true);
});

// ─── #527 S2: confirmed_limitations validation ───────────────────────────────

Deno.test("validateRequest_confirmed_limitations_absent_still_valid", () => {
  // Back-compat: goal-review / calibration saves omit the field; valid as before.
  const result = validateRequest(baseRequest());
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.confirmed_limitations, undefined);
});

Deno.test("validateRequest_confirmed_limitations_valid_accepted", () => {
  const result = validateRequest(
    baseRequest({
      confirmed_limitations: [
        { subject: { kind: "joint", value: "shoulder" }, severity: "moderate" },
        { subject: { kind: "joint", value: "lower_back" }, severity: "mild" },
      ],
    }),
  );
  assertEquals("error" in result, false);
  if ("error" in result) return;
  assertEquals(result.confirmed_limitations?.length, 2);
  assertEquals(result.confirmed_limitations?.[0].subject.value, "shoulder");
  assertEquals(result.confirmed_limitations?.[0].severity, "moderate");
});

Deno.test("validateRequest_confirmed_limitations_all_eight_joints_accepted", () => {
  const joints = [
    "shoulder", "elbow", "wrist", "hip", "knee", "ankle", "lower_back", "neck",
  ];
  const result = validateRequest(
    baseRequest({
      confirmed_limitations: joints.map((j) => ({
        subject: { kind: "joint", value: j },
        severity: "moderate",
      })),
    }),
  );
  assertEquals("error" in result, false);
});

Deno.test("validateRequest_confirmed_limitations_non_array_returns_400", () => {
  const result = validateRequest(
    baseRequest({
      confirmed_limitations: { subject: { kind: "joint", value: "knee" }, severity: "mild" },
    }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("confirmed_limitations"), true);
});

Deno.test("validateRequest_confirmed_limitations_non_object_entry_returns_400", () => {
  const result = validateRequest(
    baseRequest({ confirmed_limitations: ["knee"] }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("confirmed_limitations[0]"), true);
});

Deno.test("validateRequest_confirmed_limitations_non_joint_kind_returns_400", () => {
  // Onboarding only declares joint-scoped limitations; pattern/muscle rejected.
  const result = validateRequest(
    baseRequest({
      confirmed_limitations: [
        { subject: { kind: "pattern", value: "squat" }, severity: "mild" },
      ],
    }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("kind"), true);
});

Deno.test("validateRequest_confirmed_limitations_unknown_joint_returns_400", () => {
  const result = validateRequest(
    baseRequest({
      confirmed_limitations: [
        { subject: { kind: "joint", value: "spleen" }, severity: "mild" },
      ],
    }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("value"), true);
});

Deno.test("validateRequest_confirmed_limitations_bad_severity_returns_400", () => {
  const result = validateRequest(
    baseRequest({
      confirmed_limitations: [
        { subject: { kind: "joint", value: "knee" }, severity: "agony" },
      ],
    }),
  );
  if (!("error" in result)) throw new Error("expected error");
  assertEquals(result.error.includes("severity"), true);
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
  return new Request("https://example.test/update-trainee-goal", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function validBody(): Record<string, unknown> {
  return { user_id: VALID_USER_ID, goal: VALID_GOAL };
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
