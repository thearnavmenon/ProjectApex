// Project Apex — JWT-`sub` ownership check (#369, auth/RLS slice 4, ADR-0027).
//
// Both Edge Functions connect via the privileged `SUPABASE_DB_URL` (the
// `postgres` role, which has BYPASSRLS), so RLS does NOT protect the EF write
// path — the function must enforce ownership itself. This is the IDOR fix:
// the handlers trust the caller identity derived HERE (the verified JWT's
// `sub`), not the `user_id` in the request body.
//
// The Supabase platform has ALREADY verified the JWT signature (verify-jwt is
// ON for these functions — we do NOT pass `--no-verify-jwt`). So this helper
// only DECODES the payload to read `sub`; it does NOT re-verify the signature.
//
// Fail closed: a missing Authorization header, a malformed JWT, or a
// missing/empty `sub` all yield a rejection, never a silent pass.

/** Outcome of deriving the caller's `sub` from the request. Discriminated. */
export type OwnerCheck =
  | { ok: true }
  | { ok: false; status: number; error: string };

/**
 * base64url-decode a single JWT segment to its UTF-8 string. base64url uses
 * `-`/`_` for `+`/`/` and may omit `=` padding — normalise both, then `atob`.
 * Throws on invalid base64 (caller treats a throw as "malformed JWT").
 */
function decodeSegment(segment: string): string {
  const b64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const binary = atob(padded);
  // atob yields a Latin-1 string; re-decode the bytes as UTF-8 so non-ASCII
  // claim values survive. `sub` is a UUID (ASCII) here, but decode honestly.
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

/**
 * Extract the `sub` claim from a `Bearer <jwt>` Authorization header value by
 * DECODING (not verifying) the JWT payload. Returns the trimmed `sub`, or
 * `null` when the header is absent/not-Bearer, the JWT is malformed, or `sub`
 * is missing/non-string/empty. A `null` return is the fail-closed signal.
 */
export function subFromAuthorization(
  authorization: string | null,
): string | null {
  if (!authorization) return null;
  const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
  if (!match) return null;
  const parts = match[1].split(".");
  if (parts.length !== 3) return null; // not a header.payload.signature JWT
  let payload: unknown;
  try {
    payload = JSON.parse(decodeSegment(parts[1]));
  } catch {
    return null; // undecodable / non-JSON payload
  }
  if (typeof payload !== "object" || payload === null) return null;
  const sub = (payload as Record<string, unknown>).sub;
  if (typeof sub !== "string" || sub.length === 0) return null;
  return sub;
}

/**
 * Gate a privileged write on caller ownership: the JWT `sub` (verified by the
 * platform, decoded here) MUST equal the body `user_id`. Returns `{ ok: true }`
 * only when they match; otherwise a fail-closed rejection:
 *   - 401 when no usable credential is present (missing header, malformed JWT,
 *     or missing/empty `sub`) — the caller never proved who they are;
 *   - 403 when a `sub` was derived but it does not match the body `user_id`
 *     (the caller is authenticated but is not the resource owner — IDOR).
 */
export function checkOwnership(
  req: Request,
  bodyUserId: string,
): OwnerCheck {
  const sub = subFromAuthorization(req.headers.get("Authorization"));
  if (sub === null) {
    return {
      ok: false,
      status: 401,
      error: "missing or malformed Authorization bearer token",
    };
  }
  if (sub !== bodyUserId) {
    return {
      ok: false,
      status: 403,
      error: "authenticated user is not the owner of this resource",
    };
  }
  return { ok: true };
}
