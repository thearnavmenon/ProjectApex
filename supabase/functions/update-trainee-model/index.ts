// Project Apex — update-trainee-model Edge Function.
//
// Phase 1 (Slice 9b, issue #9): no-op stub. Validates request shape,
// returns an empty TraineeModel JSON. No DB writes, no Anthropic calls,
// no rule logic. The structural slots for Phase 2 (idempotency check,
// rule logic, cached-snapshot return) are present but inert so that
// Phase 2 plugs into the same lifecycle without restructuring.
//
// Slice 6 (issue #10): payload validator now descends into
// session_payload.set_logs[] (when present) and rejects any element
// missing or carrying an invalid `intent` field. Forward-compatible —
// the actual set_logs[] payload is wired in Slice 9c+; this validator
// is the contract that wiring will satisfy. See ADR-0005 (no silent
// defaults at any layer).
//
// Contract: POST { user_id, session_id, session_payload } → 200
// { trainee_model: {} }. See:
//   - ADR-0005 (TraineeModel shape, set-intent invariant)
//   - ADR-0006 (server-side placement, idempotency at DB layer)
//   - docs/agents/edge-functions.md (secrets, deploy, local dev)

export interface UpdateTraineeModelRequest {
  user_id: string;
  session_id: string;
  session_payload: Record<string, unknown>;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// SetIntent — must mirror the Swift `SetIntent` enum (TraineeModelEnums.swift)
// and the eventual `set_logs.intent` CHECK constraint. Any drift breaks the
// no-silent-defaults invariant.
const VALID_INTENTS = new Set([
  "warmup",
  "top",
  "backoff",
  "technique",
  "amrap",
]);

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function validateRequest(
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
  const payload = session_payload as Record<string, unknown>;

  // Slice 6 — validate set_logs[] when present. Forward-compatible: when
  // session_payload omits set_logs entirely, the request still passes (the
  // actual call site is wired in Slice 9c+). When the array is present,
  // every element must carry a valid intent — no silent default.
  if ("set_logs" in payload) {
    const setLogs = payload.set_logs;
    if (!Array.isArray(setLogs)) {
      return { error: "session_payload.set_logs must be an array" };
    }
    for (let i = 0; i < setLogs.length; i++) {
      const entry = setLogs[i];
      if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
        return {
          error: `session_payload.set_logs[${i}] must be a JSON object`,
        };
      }
      const intent = (entry as Record<string, unknown>).intent;
      if (intent === undefined || intent === null) {
        return {
          error: `session_payload.set_logs[${i}] missing required field 'intent'`,
        };
      }
      if (typeof intent !== "string" || !VALID_INTENTS.has(intent)) {
        return {
          error:
            `session_payload.set_logs[${i}].intent must be one of ` +
            `warmup/top/backoff/technique/amrap (got ${JSON.stringify(intent)})`,
        };
      }
    }
  }

  return {
    user_id,
    session_id,
    session_payload: payload,
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

export async function handleRequest(req: Request): Promise<Response> {
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
}

// Only boot the server when this module is invoked as the entrypoint —
// `deno test` and other importers can pull in `validateRequest` /
// `handleRequest` without binding to a port. Slice 6 (#10) added this
// gate so the validator could be tested in isolation.
if (import.meta.main) {
  Deno.serve(handleRequest);
}
