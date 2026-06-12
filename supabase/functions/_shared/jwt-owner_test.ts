// Project Apex — unit tests for the JWT-`sub` ownership check (#369, slice 4).
//
// The helper DECODES (never verifies) the JWT payload, so the tests build
// fake-but-well-formed tokens: header.payload.signature, where the payload
// base64url-encodes the claims and the signature is an arbitrary dummy (the
// code never touches it). The platform owns signature verification (verify-jwt
// is ON); these tests pin the decode + fail-closed contract.
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/jwt-owner_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { checkOwnership, subFromAuthorization } from "./jwt-owner.ts";

const OWNER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

/** base64url-encode a UTF-8 string (no `=` padding, `-`/`_` alphabet). */
function b64url(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Build a fake-but-well-formed JWT carrying `claims` in the payload segment. */
function fakeJwt(claims: Record<string, unknown>): string {
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify(claims));
  return `${header}.${payload}.dummy-signature-not-verified`;
}

function bearer(token: string): Request {
  return new Request("https://example.test/", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
}

// ─── subFromAuthorization: happy decode ──────────────────────────────────────

Deno.test("subFromAuthorization: decodes sub from a well-formed bearer token", () => {
  assertEquals(subFromAuthorization(`Bearer ${fakeJwt({ sub: OWNER })}`), OWNER);
});

Deno.test("subFromAuthorization: ignores other claims, returns only sub", () => {
  const token = fakeJwt({ sub: OWNER, role: "authenticated", exp: 9999999999 });
  assertEquals(subFromAuthorization(`Bearer ${token}`), OWNER);
});

// ─── subFromAuthorization: fail-closed (null) cases ──────────────────────────

Deno.test("subFromAuthorization: null when header absent", () => {
  assertEquals(subFromAuthorization(null), null);
});

Deno.test("subFromAuthorization: null when scheme is not Bearer", () => {
  assertEquals(subFromAuthorization(`Basic ${fakeJwt({ sub: OWNER })}`), null);
});

Deno.test("subFromAuthorization: null when JWT has wrong segment count", () => {
  assertEquals(subFromAuthorization("Bearer not.a.valid.jwt.here"), null);
  assertEquals(subFromAuthorization("Bearer onlyonesegment"), null);
});

Deno.test("subFromAuthorization: null when payload is not valid base64/JSON", () => {
  assertEquals(subFromAuthorization("Bearer aaa.!!!notbase64!!!.bbb"), null);
});

Deno.test("subFromAuthorization: null when sub claim is missing", () => {
  assertEquals(subFromAuthorization(`Bearer ${fakeJwt({ role: "x" })}`), null);
});

Deno.test("subFromAuthorization: null when sub is empty string", () => {
  assertEquals(subFromAuthorization(`Bearer ${fakeJwt({ sub: "" })}`), null);
});

Deno.test("subFromAuthorization: null when sub is non-string", () => {
  assertEquals(subFromAuthorization(`Bearer ${fakeJwt({ sub: 42 })}`), null);
});

// ─── checkOwnership: the gate the handlers call ──────────────────────────────

Deno.test("checkOwnership: ok when sub === body user_id", () => {
  const result = checkOwnership(bearer(fakeJwt({ sub: OWNER })), OWNER);
  assertEquals(result.ok, true);
});

Deno.test("checkOwnership: 403 when sub !== body user_id (IDOR)", () => {
  const result = checkOwnership(bearer(fakeJwt({ sub: OTHER })), OWNER);
  assertEquals(result.ok, false);
  if (result.ok) return;
  assertEquals(result.status, 403);
});

Deno.test("checkOwnership: 401 when Authorization header absent", () => {
  const req = new Request("https://example.test/", { method: "POST" });
  const result = checkOwnership(req, OWNER);
  assertEquals(result.ok, false);
  if (result.ok) return;
  assertEquals(result.status, 401);
});

Deno.test("checkOwnership: 401 when JWT is malformed", () => {
  const req = bearer("garbage-not-a-jwt");
  const result = checkOwnership(req, OWNER);
  assertEquals(result.ok, false);
  if (result.ok) return;
  assertEquals(result.status, 401);
});

Deno.test("checkOwnership: 401 when sub is missing from an otherwise-valid JWT", () => {
  const result = checkOwnership(bearer(fakeJwt({ role: "authenticated" })), OWNER);
  assertEquals(result.ok, false);
  if (result.ok) return;
  assertEquals(result.status, 401);
});
