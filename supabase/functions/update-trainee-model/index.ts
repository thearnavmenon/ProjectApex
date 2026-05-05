// Project Apex — update-trainee-model Edge Function.
//
// Phase 1 (Slice 9b, issue #9): no-op stub. Validates request shape,
// returns an empty TraineeModel JSON. No DB writes, no Anthropic calls,
// no rule logic. The structural slots for Phase 2 (idempotency check,
// rule logic, cached-snapshot return) are present but inert so that
// Phase 2 plugs into the same lifecycle without restructuring.
//
// Contract: POST { user_id, session_id, session_payload } → 200
// { trainee_model: {} }. See:
//   - ADR-0005 (TraineeModel shape)
//   - ADR-0006 (server-side placement, idempotency at DB layer)
//   - docs/agents/edge-functions.md (secrets, deploy, local dev)

interface UpdateTraineeModelRequest {
  user_id: string;
  session_id: string;
  session_payload: Record<string, unknown>;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function validateRequest(
  body: unknown,
): UpdateTraineeModelRequest | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { error: "request body must be a JSON object" };
  }
  const { user_id, session_id, session_payload } = body as Record<
    string,
    unknown
  >;
  if (typeof user_id !== "string" || !UUID_RE.test(user_id)) {
    return { error: "user_id must be a UUID string" };
  }
  if (typeof session_id !== "string" || !UUID_RE.test(session_id)) {
    return { error: "session_id must be a UUID string" };
  }
  if (
    typeof session_payload !== "object" ||
    session_payload === null ||
    Array.isArray(session_payload)
  ) {
    return { error: "session_payload must be a JSON object" };
  }
  return {
    user_id,
    session_id,
    session_payload: session_payload as Record<string, unknown>,
  };
}

// Phase 1 stub — always returns false (every apply treated as fresh).
// Phase 2 replaces the body with:
//   INSERT INTO trainee_model_applied_sessions (user_id, session_id)
//   VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING xmax = 0 AS inserted;
// then returns true iff the row already existed (cached-snapshot path).
// Kept as a callable boundary now so Phase 2 only changes the body, not
// the call site or its surrounding control flow. See ADR-0006 §2.
async function checkAlreadyApplied(
  _userId: string,
  _sessionId: string,
): Promise<boolean> {
  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method not allowed" }, 405);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "request body must be valid JSON" }, 400);
  }

  const validated = validateRequest(body);
  if ("error" in validated) {
    return jsonResponse({ error: validated.error }, 400);
  }

  const { user_id, session_id } = validated;

  if (await checkAlreadyApplied(user_id, session_id)) {
    // Phase 2: SELECT model_json FROM trainee_models WHERE user_id = $1
    //          and return that snapshot rather than the empty default.
    return jsonResponse({ trainee_model: {} }, 200);
  }

  // Phase 2: rule logic plugs in here.
  // Reads previous trainee_models.model_json + session_payload, runs the
  // update routine (EWMA, transition mode, two-dimensional recovery,
  // fatigue-interaction confidence, prescription accuracy, transfer
  // regression, etc. — see ADR-0005), writes the updated row + the
  // idempotency record in a single transaction (see ADR-0006 §2),
  // returns the updated snapshot.

  return jsonResponse({ trainee_model: {} }, 200);
});
