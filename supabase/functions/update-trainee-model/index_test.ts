// Project Apex — update-trainee-model Edge Function — validator tests.
//
// Covers the Slice 6 (issue #10) extension to `validateRequest` that
// descends into `session_payload.set_logs[]` and rejects rows missing
// or carrying an invalid `intent` field. The Edge Function itself remains
// a Phase-1 no-op stub; these tests exercise the validator in isolation.
//
// Run locally:
//   deno test supabase/functions/update-trainee-model/index_test.ts

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyPerExerciseRules,
  applyPerPatternRules,
  capTopSets,
  derivedTrainedSets,
  handleRequest,
  validateRequest,
} from "./index.ts";
import { TOP_SET_RETENTION_COUNT } from "../_shared/constants.ts";
import { e1rm } from "../_shared/ewma-engine.ts";

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
      {
        exercise_id: "ex-1",
        primary_muscle: "posterior_deltoid",
        intent: "top",
      },
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
  assertEquals(
    trained.muscleGroups.has("chest"),
    true,
    "canonical group retained",
  );
  assertEquals(
    trained.muscleGroups.has("legs"),
    true,
    "leg subgroup collapses to legs",
  );
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
  assertEquals(
    trained.patterns.size,
    0,
    "no library fallback without exercise_id",
  );
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
  assertEquals(
    result.error,
    "session_payload.set_logs[0] must be a JSON object",
  );
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
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/,
    "",
  );
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
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
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

// ─── #369 Slice 3: long-absence estimate-layer re-anchor (applyPerExerciseRules)
//
// When the PRE-append last loggedAt for an exercise is >= 28 days before the
// incoming session, the estimate flips into transition mode AND trims pre-gap
// sessions, so e1rmCurrent re-anchors on the measured post-return session
// rather than the stale, inflated EWMA. The trigger is per-exercise (its own
// baseTopSets gap), the trim cutoff is the pre-append max loggedAt.

const EX = "barbell_back_squat"; // canonical → pattern "squat" (used in Slice 4)

// Stored topSet shape: loggedAt is an ISO string (what the orchestrator writes).
const storedTopSet = (
  weight: number,
  reps: number,
  loggedAtIso: string,
  sessionId: string,
) => ({ weight, reps, loggedAt: loggedAtIso, sessionId });

const topSetLog = (weight: number, reps: number) => ({
  exercise_id: EX,
  intent: "top",
  weight_kg: weight,
  reps_completed: reps,
});

// Pre-gap history S1..S5 (consecutive days, ending 2026-01-05) — the 6-week-gap
// worked scenario from Slice 2. Return session is 2026-02-16 (>28d after Jan 5).
const preGapHistory = () => [
  storedTopSet(100, 5, "2026-01-01T10:00:00Z", "S1"),
  storedTopSet(100, 5, "2026-01-02T10:00:00Z", "S2"),
  storedTopSet(102.5, 5, "2026-01-03T10:00:00Z", "S3"),
  storedTopSet(102.5, 5, "2026-01-04T10:00:00Z", "S4"),
  storedTopSet(105, 5, "2026-01-05T10:00:00Z", "S5"),
];
const RETURN_LOGGED_AT = new Date("2026-02-16T10:00:00Z"); // 42 days after S5
const RETURN_SESSION_ID = "S6";

Deno.test("Slice 3 (a): >=28d pre-append gap → e1rmCurrent re-anchors to the TRIMMED post-return mean (110.83), not EWMA, not no-trim", () => {
  const exercises = {
    [EX]: {
      exerciseId: EX,
      topSets: preGapHistory(),
      e1rmCurrent: e1rm(105, 5), // stale inflated estimate before this apply
      sessionCount: 5,
      confidence: "established",
    },
  };
  const result = applyPerExerciseRules(
    exercises,
    [topSetLog(95, 5)], // return session: 95×5 → 110.83
    RETURN_LOGGED_AT,
    RETURN_SESSION_ID,
  );
  const e1rmCurrent = result.exercises[EX].e1rmCurrent as number;
  // Re-anchored to the trimmed transition-mode mean = e1rm(95,5) = 110.833.
  assertAlmostEquals(e1rmCurrent, e1rm(95, 5)!, 1e-9);
  assertAlmostEquals(e1rmCurrent, 110.833, 1e-3);
  // NOT the no-trim last-3 mean {S4,S5,S6} ≈ 117.64.
  const noTrim = (e1rm(102.5, 5)! + e1rm(105, 5)! + e1rm(95, 5)!) / 3;
  assertEquals(Math.abs(e1rmCurrent - noTrim) > 1, true);
  // The long-absence rule is tagged.
  assertEquals(result.rulesFired.has("long-absence-transition"), true);
  assertEquals(
    result.fieldsChanged.includes(`exercises.${EX}.e1rmCurrent`),
    true,
  );
});

Deno.test("Slice 3 (b): no-gap exercise still uses standard EWMA (no re-anchor)", () => {
  // Prior history ends 2026-02-15; incoming 2026-02-16 — a 1-day gap, no
  // absence. e1rmCurrent must equal the standard EWMA over the full window.
  const recent = [
    storedTopSet(100, 5, "2026-02-11T10:00:00Z", "r1"),
    storedTopSet(102, 5, "2026-02-12T10:00:00Z", "r2"),
    storedTopSet(104, 5, "2026-02-13T10:00:00Z", "r3"),
    storedTopSet(106, 5, "2026-02-14T10:00:00Z", "r4"),
    storedTopSet(108, 5, "2026-02-15T10:00:00Z", "r5"),
  ];
  const exercises = {
    [EX]: { exerciseId: EX, topSets: recent, e1rmCurrent: 0, sessionCount: 5 },
  };
  const result = applyPerExerciseRules(
    exercises,
    [topSetLog(110, 5)],
    new Date("2026-02-16T10:00:00Z"),
    "r6",
  );
  // Recompute the expected EWMA over the appended window (last 5 valid).
  const e1rms = [102, 104, 106, 108, 110].map((w) => e1rm(w, 5)!);
  const a = 0.333;
  let ema = e1rms[0];
  for (let i = 1; i < e1rms.length; i++) ema = a * e1rms[i] + (1 - a) * ema;
  assertAlmostEquals(result.exercises[EX].e1rmCurrent as number, ema, 1e-9);
  assertEquals(result.rulesFired.has("long-absence-transition"), false);
  assertEquals(result.rulesFired.has("ewma"), true);
});

Deno.test("Slice 3 (a2): re-anchor PERSISTS on the 2nd post-return session (does not re-inflate to EWMA while the gap is still in the window)", () => {
  // After the return session S6 is stored, the next session S7 (2 days later)
  // has only a small per-apply gap — but the 42d S5→S6 gap is still in the
  // retained window, so the estimate must KEEP re-anchoring on the post-return
  // block {S6, S7}, not bounce back up to the stale-tail EWMA.
  const storedAfterReturn = [
    ...preGapHistory(),
    storedTopSet(95, 5, "2026-02-16T10:00:00Z", "S6"), // the return session
  ];
  const exercises = {
    [EX]: {
      exerciseId: EX,
      topSets: storedAfterReturn,
      e1rmCurrent: e1rm(95, 5), // re-anchored value from the return apply
      sessionCount: 6,
      confidence: "established",
    },
  };
  const result = applyPerExerciseRules(
    exercises,
    [topSetLog(97, 5)], // S7: 97×5 → 113.167
    new Date("2026-02-18T10:00:00Z"), // 2 days after S6 — small per-apply gap
    "S7",
  );
  const e1rmCurrent = result.exercises[EX].e1rmCurrent as number;
  // Trimmed transition-mean over the post-return block {S6, S7}.
  const postReturnMean = (e1rm(95, 5)! + e1rm(97, 5)!) / 2;
  assertAlmostEquals(e1rmCurrent, postReturnMean, 1e-9);
  assertAlmostEquals(e1rmCurrent, 112.0, 1e-3);
  // It must be BELOW the stale-tail EWMA (which carries the pre-gap sessions) —
  // proving it did not re-inflate.
  const e1rms = [
    e1rm(102.5, 5)!,
    e1rm(102.5, 5)!,
    e1rm(105, 5)!,
    e1rm(95, 5)!,
    e1rm(97, 5)!,
  ];
  const a = 0.333;
  let ema = e1rms[0];
  for (let i = 1; i < e1rms.length; i++) ema = a * e1rms[i] + (1 - a) * ema;
  assertEquals(e1rmCurrent < ema, true, "re-anchored estimate must not re-inflate to the stale-tail EWMA");
  assertEquals(result.rulesFired.has("long-absence-transition"), true);
});

Deno.test("Slice 3 (c): first-ever exercise (empty baseTopSets / null prior) uses EWMA, does NOT fire", () => {
  const result = applyPerExerciseRules(
    {}, // no pre-existing profile → bootstrap → empty baseTopSets
    [topSetLog(100, 5)],
    RETURN_LOGGED_AT,
    "first",
  );
  // Single valid set → EWMA degenerates to that set's Epley e1RM.
  assertAlmostEquals(
    result.exercises[EX].e1rmCurrent as number,
    e1rm(100, 5)!,
    1e-9,
  );
  assertEquals(result.rulesFired.has("long-absence-transition"), false);
  assertEquals(result.rulesFired.has("ewma"), true);
});

// ─── #369 Slice 4: long-absence pattern-flag re-anchor (applyPerPatternRules) ─
//
// A sibling branch (gated on wasTrainedThisSession) sets transitionModeUntil
// when the PRE-append last session-date is a flat >= 28 days before incoming.
// It composes with a same-apply deload-end via the function's max-of-untils
// (reads the LOCAL just-mutated newTransitionModeUntil so no clobber).

const SQUAT_PATTERN = "squat";

// A pattern profile in `accumulation` with low sessionsInPhase so phase-advance
// does NOT fire deload-end — isolating the absence branch. recentSessionDates
// is the PRE-append history; its last entry drives the gap.
function squatProfile(
  recentSessionDates: string[],
  overrides: Record<string, unknown> = {},
) {
  return {
    [SQUAT_PATTERN]: {
      pattern: SQUAT_PATTERN,
      currentPhase: "accumulation",
      sessionsInPhase: 1,
      sessionCount: recentSessionDates.length,
      consecutiveForceDeloadsOnPattern: 0,
      lastPhaseTransitionAtSessionCount: 0,
      recentSessionDates,
      transitionModeUntil: null,
      trend: "progressing",
      rpeOffset: 0,
      confidence: "established",
      recovery: {
        lastNeuromuscularStimulusAt: null,
        lastMetabolicStimulusAt: null,
        neuromuscularReadiness: 1.0,
        metabolicReadiness: 1.0,
      },
      weeklyVolumeLoadHistory: [],
      ...overrides,
    },
  };
}

const squatSetLog = () => ({
  exercise_id: "barbell_back_squat", // → pattern "squat"
  intent: "top",
  weight_kg: 100,
  reps_completed: 5,
});

const INCOMING_FEB16 = new Date("2026-02-16T10:00:00Z");

Deno.test("Slice 4 (d): TRAINED pattern with pre-append last date >=28d before incoming sets transitionModeUntil", () => {
  // Last pre-append session 2026-01-05 → 42-day gap to 2026-02-16 → fires.
  const patterns = squatProfile([
    "2026-01-03T10:00:00Z",
    "2026-01-05T10:00:00Z",
  ]);
  const result = applyPerPatternRules(
    patterns,
    new Set([SQUAT_PATTERN]),
    INCOMING_FEB16,
    10,
    {},
    [squatSetLog()],
  );
  const until = result.patterns[SQUAT_PATTERN].transitionModeUntil;
  assertEquals(typeof until, "string", "transitionModeUntil must be set");
  assertEquals(
    new Date(until as string).getTime() > INCOMING_FEB16.getTime(),
    true,
    "until is in the future of the incoming session",
  );
  assertEquals(result.rulesFired.has("transition-mode-expiry"), true);
  assertEquals(
    result.fieldsChanged.includes(
      `patterns.${SQUAT_PATTERN}.transitionModeUntil`,
    ),
    true,
  );
});

Deno.test("Slice 4 (e): UNTRAINED pattern (wasTrainedThisSession=false) with an old recentSessionDates does NOT set transitionModeUntil", () => {
  // The pattern exists with a stale history but is NOT in trainedPatterns this
  // apply → the absence branch is gated off.
  const patterns = squatProfile(["2026-01-05T10:00:00Z"]);
  const result = applyPerPatternRules(
    patterns,
    new Set(), // squat NOT trained this session
    INCOMING_FEB16,
    10,
    {},
    [], // no squat sets
  );
  assertEquals(result.patterns[SQUAT_PATTERN].transitionModeUntil, null);
});

// ─── #292: recentSessionDates is bounded to the last N on write ──────────────
//
// Without a cap the array grew one entry per session-apply forever. The cap
// (RECENT_SESSION_DATES_RETENTION_COUNT = 10) is applied to the final written
// value, so it both bounds new growth and trims any pre-cap historical excess
// the next time a pattern is written — trained or not.

const twelveDates = () =>
  Array.from(
    { length: 12 },
    (_, i) => `2026-01-${String(i + 1).padStart(2, "0")}T10:00:00Z`,
  );

Deno.test("#292: a TRAINED pattern with >N prior dates is trimmed to the last N (newest = incoming, oldest dropped)", () => {
  const result = applyPerPatternRules(
    squatProfile(twelveDates()),
    new Set([SQUAT_PATTERN]),
    INCOMING_FEB16,
    10,
    {},
    [squatSetLog()],
  );
  const dates = result.patterns[SQUAT_PATTERN].recentSessionDates as string[];
  assertEquals(dates.length, 10);
  // newest entry is the incoming session date
  assertEquals(dates[dates.length - 1], INCOMING_FEB16.toISOString());
  // 12 history + 1 incoming = 13 → the three oldest are dropped
  assertEquals(dates.includes("2026-01-03T10:00:00Z"), false);
  assertEquals(dates.includes("2026-01-04T10:00:00Z"), true);
});

Deno.test("#292: a TRAINED pattern at/under N is fully preserved with the incoming date appended", () => {
  const history = [
    "2026-01-05T10:00:00Z",
    "2026-01-08T10:00:00Z",
    "2026-01-12T10:00:00Z",
  ];
  const result = applyPerPatternRules(
    squatProfile(history),
    new Set([SQUAT_PATTERN]),
    INCOMING_FEB16,
    10,
    {},
    [squatSetLog()],
  );
  const dates = result.patterns[SQUAT_PATTERN].recentSessionDates as string[];
  assertEquals(dates, [...history, INCOMING_FEB16.toISOString()]);
});

Deno.test("#292: an UNTRAINED pattern with >N historical dates is trimmed on write without appending", () => {
  const result = applyPerPatternRules(
    squatProfile(twelveDates()),
    new Set(), // not trained this apply
    INCOMING_FEB16,
    10,
    {},
    [],
  );
  const dates = result.patterns[SQUAT_PATTERN].recentSessionDates as string[];
  assertEquals(dates.length, 10);
  // no append: the incoming date is absent and the newest historical is retained
  assertEquals(dates.includes(INCOMING_FEB16.toISOString()), false);
  assertEquals(dates[dates.length - 1], "2026-01-12T10:00:00Z");
  // last 10 of 12 → the two oldest are dropped
  assertEquals(dates.includes("2026-01-02T10:00:00Z"), false);
  assertEquals(dates.includes("2026-01-03T10:00:00Z"), true);
});

Deno.test("Slice 4 (f): deload-end + absence in the SAME apply compose via max-of-untils (absence reads the LOCAL until — no clobber)", () => {
  // currentPhase=deload at/above threshold → phase-advance fires deload-end.
  // PRE-append last date is also >=28d old → absence fires too.
  //
  // Discriminating construction: a pre-existing transitionModeUntil sits FAR
  // in the future (incoming + 200d). The post-append cadence after a 42-day
  // gap is ~42d, so the cadence-aware DURATION is 3×42 = 126d (< 200d). The
  // deload-end branch's max-of-untils therefore preserves the 200d until. The
  // absence branch must then read the LOCAL just-mutated until (200d) and
  // again preserve it. A clobber bug (absence passing currentUntil=null
  // instead of the local until) would recompute the fresh 126d until and
  // OVERWRITE the 200d — shrinking it. So "result == the 200d pre-existing
  // until" fails under clobber and passes under correct composition.
  const farFuture = new Date(INCOMING_FEB16.getTime() + 200 * 86_400_000)
    .toISOString();
  const patterns = squatProfile(["2026-01-05T10:00:00Z"], {
    currentPhase: "deload",
    sessionsInPhase: 99, // >= threshold → deload-end-cycle fires
    transitionModeUntil: farFuture,
  });
  const result = applyPerPatternRules(
    patterns,
    new Set([SQUAT_PATTERN]),
    INCOMING_FEB16,
    10,
    {},
    [squatSetLog()],
  );
  const until = result.patterns[SQUAT_PATTERN].transitionModeUntil as string;
  assertEquals(
    until,
    farFuture,
    "max-of-untils preserves the far-future until across BOTH branches; a " +
      "clobber would shrink it to the fresh ~21d computation",
  );
  // The field is recorded once (deload-end pushed it; absence's idempotent
  // no-change must NOT push a duplicate).
  const pushes = result.fieldsChanged.filter(
    (f) => f === `patterns.${SQUAT_PATTERN}.transitionModeUntil`,
  );
  assertEquals(
    pushes.length,
    1,
    "transitionModeUntil field pushed exactly once",
  );
});

Deno.test("Slice 4 (g): no-gap TRAINED pattern leaves transitionModeUntil untouched", () => {
  // Last pre-append session 2026-02-15 → 1-day gap → absence does not fire,
  // and accumulation/low sessionsInPhase → deload-end does not fire.
  const patterns = squatProfile([
    "2026-02-13T10:00:00Z",
    "2026-02-15T10:00:00Z",
  ]);
  const result = applyPerPatternRules(
    patterns,
    new Set([SQUAT_PATTERN]),
    INCOMING_FEB16,
    10,
    {},
    [squatSetLog()],
  );
  assertEquals(result.patterns[SQUAT_PATTERN].transitionModeUntil, null);
  assertEquals(result.rulesFired.has("transition-mode-expiry"), false);
});

// ─── #369 Slice 5: per-scope coherence (documented, intended disagreement) ────
//
// The estimate trigger is PER-EXERCISE (its own baseTopSets gap) and the flag
// trigger is PER-PATTERN (its own recentSessionDates gap). These two scopes
// can DISAGREE, and that disagreement is INTENDED, not a bug: an exercise can
// sit out >= 28d while its pattern was kept warm by a SIBLING exercise.
//
// Scenario: the `squat` pattern has two exercises —
//   • barbell_back_squat: last logged > 28d ago (sat out), trained THIS session
//   • goblet_squat: trained recently via the sibling, so the pattern's
//     recentSessionDates last entry is recent (no pattern-level absence).
// This session re-touches barbell_back_squat after its long personal gap.
//
// Expected (per-scope, NOT hoisted):
//   • barbell_back_squat.e1rmCurrent RE-ANCHORS (trimmed transition-mode mean)
//     because its OWN pre-append gap is >= 28d.
//   • The squat pattern's transitionModeUntil stays null (in_transition_mode
//     false) because the PATTERN's recentSessionDates gap is small.
Deno.test("Slice 5: per-scope — a sat-out exercise re-anchors its estimate even though its pattern's flag stays false (intended disagreement)", () => {
  const SAT_OUT = "barbell_back_squat"; // → squat
  const SIBLING = "goblet_squat"; // → squat (kept the pattern warm)

  // ── Exercise scope: barbell_back_squat sat out >28d, trained this session ──
  const exercises = {
    [SAT_OUT]: {
      exerciseId: SAT_OUT,
      topSets: [
        storedTopSet(100, 5, "2026-01-01T10:00:00Z", "x1"),
        storedTopSet(100, 5, "2026-01-02T10:00:00Z", "x2"),
        storedTopSet(102.5, 5, "2026-01-03T10:00:00Z", "x3"),
        storedTopSet(102.5, 5, "2026-01-04T10:00:00Z", "x4"),
        storedTopSet(105, 5, "2026-01-05T10:00:00Z", "x5"), // last pre-gap
      ],
      e1rmCurrent: e1rm(105, 5),
      sessionCount: 5,
      confidence: "established",
    },
  };
  const exerciseResult = applyPerExerciseRules(
    exercises,
    [{
      exercise_id: SAT_OUT,
      intent: "top",
      weight_kg: 95,
      reps_completed: 5,
    }],
    INCOMING_FEB16, // 42d after 2026-01-05 → exercise-scope absence fires
    "return-session",
  );
  const reAnchored = exerciseResult.exercises[SAT_OUT].e1rmCurrent as number;
  // The sat-out exercise re-anchors to the trimmed post-return mean (110.83).
  assertAlmostEquals(reAnchored, e1rm(95, 5)!, 1e-9);
  assertEquals(
    exerciseResult.rulesFired.has("long-absence-transition"),
    true,
    "per-exercise estimate re-anchors on its OWN gap",
  );

  // ── Pattern scope: squat kept warm by the sibling → small pattern gap ──
  // The pattern's recentSessionDates last entry is RECENT (the sibling trained
  // it 2026-02-14), so the pattern-level absence does NOT fire even though the
  // back-squat exercise personally sat out.
  const patterns = squatProfile([
    "2026-02-12T10:00:00Z",
    "2026-02-14T10:00:00Z", // sibling kept the pattern warm — small gap
  ]);
  const patternResult = applyPerPatternRules(
    patterns,
    new Set([SQUAT_PATTERN]),
    INCOMING_FEB16,
    10,
    exerciseResult.exercises,
    [
      {
        exercise_id: SAT_OUT,
        intent: "top",
        weight_kg: 95,
        reps_completed: 5,
      },
      {
        exercise_id: SIBLING,
        intent: "top",
        weight_kg: 40,
        reps_completed: 5,
      },
    ],
  );
  assertEquals(
    patternResult.patterns[SQUAT_PATTERN].transitionModeUntil,
    null,
    "pattern flag stays false — the pattern's OWN gap is small (sibling kept it warm)",
  );

  // The two scopes disagree by design: estimate re-anchored, flag did not.
  assertEquals(
    exerciseResult.rulesFired.has("long-absence-transition") &&
      patternResult.patterns[SQUAT_PATTERN].transitionModeUntil === null,
    true,
    "per-scope disagreement is INTENDED — not hoisted to a single trigger",
  );
});
