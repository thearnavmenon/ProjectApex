// Chronological session-replay driver for the G1 verification gate (#85).
//
// Reads workout_sessions + set_logs from the local Supabase DB (already
// restored from production dump per README), POSTs each session in
// chronological order to the locally-served Edge Function. Watermark per
// ADR-0008 advances naturally; the dedupe table handles re-replay
// idempotency (a re-run produces cached returns and is safe).
//
// Preconditions (per README.md):
//   - `supabase start` running
//   - migrations applied (`supabase db push` against local)
//   - production dump restored: `psql -f historical-replay.sql`
//   - `TRUNCATE public.trainee_models, public.trainee_model_applied_sessions`
//   - `supabase functions serve update-trainee-model` running
//
// Env:
//   LOCAL_DB_URL          (default: postgresql://postgres:postgres@127.0.0.1:54322/postgres)
//   EDGE_FUNCTION_URL     (default: http://127.0.0.1:54321/functions/v1/update-trainee-model)
//   EDGE_FUNCTION_AUTH    (optional: Bearer token if the local EF gateway requires JWT)
//   USER_ID               (required: your UUID from public.users)
//
// Output:
//   - per-session log line on stdout
//   - fixtures/replay-summary.json with full run aggregates + per-session
//     status, late_arrival flags, durations
// Exit codes: 0 ok, 1 some sessions failed, 2 missing env, 3 EF unreachable.

import postgres from "postgres";

const LOCAL_DB_URL = Deno.env.get("LOCAL_DB_URL")
  ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
const EDGE_FUNCTION_URL = Deno.env.get("EDGE_FUNCTION_URL")
  ?? "http://127.0.0.1:54321/functions/v1/update-trainee-model";
const EDGE_FUNCTION_AUTH = Deno.env.get("EDGE_FUNCTION_AUTH");
const USER_ID = Deno.env.get("USER_ID");
// Resolved relative to this script so cwd-from-anywhere invocations work.
const SUMMARY_PATH = new URL("./fixtures/replay-summary.json", import.meta.url)
  .pathname;

if (!USER_ID) {
  console.error("USER_ID env var required (your UUID from public.users)");
  Deno.exit(2);
}

interface SessionRow {
  id: string;
  earliest_logged_at: string | null;
  session_date: string;
}

interface SetLogRow {
  id: string;
  session_id: string;
  exercise_id: string;
  set_number: number;
  weight_kg: number;
  reps_completed: number;
  rpe_felt: number | null;
  rir_estimated: number | null;
  logged_at: string | Date;
  primary_muscle: string | null;
  local_date: string;
  intent: string;
}

interface PerSessionResult {
  session_id: string;
  logged_at: string;
  set_log_count: number;
  http_status: number;
  late_arrival: boolean;
  error?: string;
  duration_ms: number;
}

const headers: Record<string, string> = { "Content-Type": "application/json" };
if (EDGE_FUNCTION_AUTH) {
  headers["Authorization"] = `Bearer ${EDGE_FUNCTION_AUTH}`;
}

console.log("[replay] config");
console.log(`  LOCAL_DB_URL=${LOCAL_DB_URL}`);
console.log(`  EDGE_FUNCTION_URL=${EDGE_FUNCTION_URL}`);
console.log(`  USER_ID=${USER_ID}`);
console.log(`  AUTH=${EDGE_FUNCTION_AUTH ? "Bearer <set>" : "(none)"}`);

// EF reachability probe — empty body should yield HTTP 400 from
// validateRequest's "request body must be a JSON object" check, confirming
// the EF process is up and routing. Anything else (connection refused,
// 404, 401) is a deploy-time finding worth surfacing as a blocker.
try {
  const probe = await fetch(EDGE_FUNCTION_URL, { method: "POST", headers });
  if (probe.status === 400) {
    console.log("[replay] EF probe ok (400 on empty body — validateRequest)");
  } else if (probe.status === 401) {
    console.error(
      "[replay] EF probe returned 401 — set EDGE_FUNCTION_AUTH to your local anon key",
    );
    Deno.exit(3);
  } else {
    console.warn(
      `[replay] EF probe returned unexpected status ${probe.status}; continuing`,
    );
  }
  await probe.body?.cancel();
} catch (e) {
  console.error(
    `[replay] EF unreachable at ${EDGE_FUNCTION_URL} — is "supabase functions serve update-trainee-model" running?`,
  );
  console.error(e);
  Deno.exit(3);
}

const sql = postgres(LOCAL_DB_URL);

// Sessions ordered by earliest set_log timestamp. workout_sessions.session_date
// is DATE-typed (no time component), which would tie same-day sessions and
// confuse the ADR-0008 watermark check. Fall back to session_date midnight
// only if a session has no set_logs (shouldn't happen for completed sessions).
const sessions = await sql<SessionRow[]>`
  SELECT
    ws.id,
    (
      SELECT MIN(sl.logged_at)::text
      FROM public.set_logs sl
      WHERE sl.session_id = ws.id
    ) AS earliest_logged_at,
    ws.session_date::text AS session_date
  FROM public.workout_sessions ws
  WHERE ws.user_id = ${USER_ID}
    AND ws.completed = true
  ORDER BY (
    SELECT MIN(sl.logged_at)
    FROM public.set_logs sl
    WHERE sl.session_id = ws.id
  ) ASC NULLS LAST
`;

console.log(`[replay] ${sessions.length} completed sessions to replay`);

const results: PerSessionResult[] = [];

for (const s of sessions) {
  const start = performance.now();

  const setLogs = await sql<SetLogRow[]>`
    SELECT *
    FROM public.set_logs
    WHERE session_id = ${s.id}
    ORDER BY set_number ASC
  `;

  const loggedAtIso = s.earliest_logged_at
    ?? new Date(`${s.session_date}T00:00:00Z`).toISOString();

  const body = {
    user_id: USER_ID,
    session_id: s.id,
    session_payload: {
      logged_at: loggedAtIso,
      set_logs: setLogs.map((sl: SetLogRow) => ({
        ...sl,
        logged_at: typeof sl.logged_at === "string"
          ? sl.logged_at
          : (sl.logged_at as Date).toISOString(),
      })),
    },
  };

  let result: PerSessionResult;
  try {
    const res = await fetch(EDGE_FUNCTION_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    const json = await res.json().catch(() => null) as
      | { late_arrival?: boolean; error?: string }
      | null;
    result = {
      session_id: s.id,
      logged_at: loggedAtIso,
      set_log_count: setLogs.length,
      http_status: res.status,
      late_arrival: json?.late_arrival ?? false,
      error: res.ok ? undefined : (json?.error ?? `HTTP ${res.status}`),
      duration_ms: Math.round(performance.now() - start),
    };
  } catch (e) {
    result = {
      session_id: s.id,
      logged_at: loggedAtIso,
      set_log_count: setLogs.length,
      http_status: 0,
      late_arrival: false,
      error: e instanceof Error ? e.message : String(e),
      duration_ms: Math.round(performance.now() - start),
    };
  }

  results.push(result);
  const tag = result.error
    ? `FAIL(${result.http_status})`
    : (result.late_arrival ? "LATE" : "OK");
  console.log(
    `[replay] ${results.length}/${sessions.length} ${tag} ` +
      `session=${s.id.slice(0, 8)} sets=${result.set_log_count} ` +
      `t=${result.duration_ms}ms`,
  );
}

const ok = results.filter((r) => !r.error && !r.late_arrival).length;
const late = results.filter((r) => r.late_arrival).length;
const failed = results.filter((r) => !!r.error).length;

const summary = {
  user_id: USER_ID,
  ran_at: new Date().toISOString(),
  edge_function_url: EDGE_FUNCTION_URL,
  total_sessions: results.length,
  ok,
  late_arrival: late,
  failed,
  results,
};

await Deno.writeTextFile(SUMMARY_PATH, JSON.stringify(summary, null, 2) + "\n");
await sql.end();

console.log(
  `[replay] done — ok=${ok} late=${late} failed=${failed} → ${SUMMARY_PATH}`,
);

Deno.exit(failed > 0 ? 1 : 0);
