#!/usr/bin/env node
/**
 * backfill_primary_muscle.mjs
 *
 * Backfills the primary_muscle column in set_logs for rows that pre-date the
 * column being added. Uses the same canonical exercise library and normalization
 * map as ExerciseLibrary.swift.
 *
 * ⚠️  REVIEW BEFORE RUNNING:
 *   1. Run the SQL migration (add_primary_muscle_column.sql) first.
 *   2. Paste the output of the following query to the developer for review:
 *        SELECT DISTINCT exercise_id, COUNT(*) as set_count
 *        FROM set_logs WHERE primary_muscle IS NULL
 *        GROUP BY exercise_id ORDER BY set_count DESC;
 *   3. Review the normalizationMap below against the actual exercise_ids in your data.
 *      A wrong mapping here corrupts historical lift data.
 *   4. Run this script in dry-run mode first (DRY_RUN=true) to see what would change.
 *   5. Only run with DRY_RUN=false when you are satisfied with the mappings.
 *
 * Usage:
 *   SUPABASE_ANON_KEY=eyJ...  USER_ID=<uuid>  node backfill_primary_muscle.mjs
 *
 * Optional:
 *   SUPABASE_AUTH_TOKEN=eyJ...   # Use user JWT instead of anon key for RLS-protected tables
 *   DRY_RUN=true                 # Print what would change without writing to Supabase (default: false)
 *   BATCH_SIZE=50                # Rows to update per PATCH request (default: 50)
 */

import https from "https";

// ─── Config ────────────────────────────────────────────────────────────────

const SUPABASE_URL  = "https://hqjgrlzvrttnyfjqjewe.supabase.co";
const TABLE         = "set_logs";

const SUPABASE_ANON = process.env.SUPABASE_ANON_KEY    ?? "";
const SUPABASE_AUTH = process.env.SUPABASE_AUTH_TOKEN  ?? "";
const USER_ID       = process.env.USER_ID              ?? "";
const DRY_RUN       = (process.env.DRY_RUN ?? "false").toLowerCase() === "true";
const BATCH_SIZE    = parseInt(process.env.BATCH_SIZE ?? "50", 10);

if (!SUPABASE_ANON) { console.error("ERROR: SUPABASE_ANON_KEY env var is required."); process.exit(1); }
if (!USER_ID)       { console.error("ERROR: USER_ID env var is required.");           process.exit(1); }

const bearerToken = SUPABASE_AUTH || SUPABASE_ANON;

// ─── Canonical exercise library ───────────────────────────────────────────
// Must stay in sync with ExerciseLibrary.swift.
// Keys: canonical exercise_id. Values: primary_muscle string.

const exerciseLibrary = {
  // Chest
  "barbell_bench_press":        "chest",
  "dumbbell_bench_press":       "chest",
  "incline_barbell_press":      "chest",
  "incline_dumbbell_press":     "chest",
  "decline_bench_press":        "chest",
  "machine_chest_press":        "chest",
  "cable_chest_fly":            "chest",
  "cable_crossover_chest_fly":  "chest",
  "pec_deck_fly":               "chest",
  "dumbbell_fly":               "chest",
  "push_ups":                   "chest",
  "smith_machine_bench_press":  "chest",
  "smith_machine_incline_press":"chest",

  // Back
  "barbell_row":                "back",
  "dumbbell_row":               "back",
  "dumbbell_single_arm_row":    "back",
  "t_bar_row":                  "back",
  "cable_row":                  "back",
  "seated_cable_row":           "back",
  "lat_pulldown_wide":          "back",
  "lat_pulldown_close":         "back",
  "pull_ups":                   "back",
  "chin_ups":                   "back",
  "assisted_pull_up":           "back",
  "face_pull":                  "back",
  "cable_rear_delt_fly":        "back",
  "cable_straight_arm_pulldown":"back",

  // Shoulders
  "overhead_press":             "shoulders",
  "dumbbell_shoulder_press":    "shoulders",
  "machine_shoulder_press":     "shoulders",
  "lateral_raise":              "shoulders",
  "cable_lateral_raise":        "shoulders",
  "rear_delt_fly":              "shoulders",
  "arnold_press":               "shoulders",
  "upright_row":                "shoulders",

  // Quads
  "barbell_back_squat":         "quads",
  "front_squat":                "quads",
  "leg_press":                  "quads",
  "hack_squat_machine":         "quads",
  "goblet_squat":               "quads",
  "leg_extension":              "quads",
  "bulgarian_split_squat":      "quads",
  "walking_lunge":              "quads",
  "smith_machine_squat":        "quads",

  // Hamstrings
  "conventional_deadlift":      "hamstrings",
  "romanian_deadlift":          "hamstrings",
  "dumbbell_romanian_deadlift": "hamstrings",
  "lying_leg_curl":             "hamstrings",
  "seated_leg_curl":            "hamstrings",
  "stiff_leg_deadlift":         "hamstrings",

  // Glutes
  "hip_thrust":                 "glutes",
  "cable_pull_through":         "glutes",
  "glute_bridge":               "glutes",
  "sumo_deadlift":              "glutes",

  // Biceps
  "barbell_curl":               "biceps",
  "ez_bar_curl":                "biceps",
  "dumbbell_curl":              "biceps",
  "preacher_curl":              "biceps",
  "hammer_curl":                "biceps",
  "cable_curl":                 "biceps",
  "cable_hammer_curl":          "biceps",

  // Triceps
  "cable_tricep_pushdown":              "triceps",
  "overhead_tricep_extension":          "triceps",
  "dumbbell_overhead_tricep_extension": "triceps",
  "skull_crushers":                     "triceps",
  "dips":                               "triceps",
  "close_grip_bench_press":             "triceps",
  "cable_overhead_tricep_extension":    "triceps",

  // Calves
  "standing_calf_raise":        "calves",
  "seated_calf_raise":          "calves",
  "smith_machine_calf_raise":   "calves",

  // Core
  "cable_crunch":               "core",
  "hanging_leg_raise":          "core",
  "ab_wheel_rollout":           "core",
  "plank":                      "core",
};

// ─── Normalization map ────────────────────────────────────────────────────
// Maps known historical LLM-generated variant strings to canonical IDs.
// Must stay in sync with ExerciseLibrary.normalizationMap in ExerciseLibrary.swift.
//
// ⚠️  REVIEW THIS CAREFULLY before running against production data.

const normalizationMap = {
  // Bench press variants
  "bench_press":               "barbell_bench_press",
  "flat_bench_press":          "barbell_bench_press",
  "bb_bench_press":            "barbell_bench_press",
  "db_bench_press":            "dumbbell_bench_press",
  "incline_press":             "incline_dumbbell_press",
  "incline_db_press":          "incline_dumbbell_press",

  // Row variants
  "bent_over_row":             "barbell_row",
  "bent_over_barbell_row":     "barbell_row",
  "bb_row":                    "barbell_row",
  "barbell_bent_over_row":     "barbell_row",
  "db_row":                    "dumbbell_row",
  "one_arm_dumbbell_row":      "dumbbell_row",

  // Lat pulldown — only mapping the clearly wrong spelling.
  // "lat_pulldown" (no suffix) is intentionally NOT mapped (ambiguous width).
  "lat_pull_down":             "lat_pulldown_wide",
  "lat_pulldown_overhand":     "lat_pulldown_wide",

  // Pull-up / chin-up variants
  "pull_up":                   "pull_ups",
  "pullup":                    "pull_ups",
  "pull-up":                   "pull_ups",
  "chin_up":                   "chin_ups",
  "chinup":                    "chin_ups",

  // Squat variants
  "back_squat":                "barbell_back_squat",
  "squat":                     "barbell_back_squat",
  "barbell_squat":             "barbell_back_squat",
  "low_bar_squat":             "barbell_back_squat",

  // Deadlift variants
  "deadlift":                  "conventional_deadlift",
  "barbell_deadlift":          "conventional_deadlift",
  "rdl":                       "romanian_deadlift",
  "barbell_rdl":               "romanian_deadlift",
  "barbell_romanian_deadlift": "romanian_deadlift",
  "stiff_legged_deadlift":     "stiff_leg_deadlift",
  "sldl":                      "stiff_leg_deadlift",

  // OHP variants
  "ohp":                       "overhead_press",
  "barbell_ohp":               "overhead_press",
  "barbell_overhead_press":    "overhead_press",
  "military_press":            "overhead_press",
  "db_shoulder_press":         "dumbbell_shoulder_press",
  "seated_dumbbell_press":     "dumbbell_shoulder_press",

  // Curl variants
  "bicep_curl":                "dumbbell_curl",
  "biceps_curl":               "dumbbell_curl",
  "db_curl":                   "dumbbell_curl",
  "barbell_bicep_curl":        "barbell_curl",
  "ez_curl":                   "ez_bar_curl",

  // Tricep variants
  "tricep_pushdown":           "cable_tricep_pushdown",
  "triceps_pushdown":          "cable_tricep_pushdown",
  "rope_pushdown":             "cable_tricep_pushdown",
  "overhead_extension":        "overhead_tricep_extension",
  "db_overhead_extension":     "overhead_tricep_extension",
  "lying_tricep_extension":    "skull_crushers",

  // Lat pulldown — grip-specific variants seen in live data
  "cable_pulldown_neutral_grip":  "lat_pulldown_close",
  "lat_pulldown_wide_grip":       "lat_pulldown_wide",

  // Dumbbell press variants seen in live data
  "dumbbell_flat_press":          "dumbbell_bench_press",
  "dumbbell_incline_press":       "incline_dumbbell_press",

  // Curl/raise variants seen in live data
  "dumbbell_bicep_curl":          "dumbbell_curl",
  "dumbbell_lateral_raise":       "lateral_raise",

  // Misc
  "split_squat":               "bulgarian_split_squat",
  "lunge":                     "walking_lunge",
  "leg_curl":                  "lying_leg_curl",
  "hamstring_curl":            "lying_leg_curl",
  "calf_raise":                "standing_calf_raise",
  "barbell_hip_thrust":        "hip_thrust",
  "glute_hip_thrust":          "hip_thrust",
  "lateral_raises":            "lateral_raise",
  "side_lateral_raise":        "lateral_raise",
  "reverse_fly":               "rear_delt_fly",
  "rear_delt_raise":           "rear_delt_fly",
};

// ─── Resolve exercise_id → primary_muscle ────────────────────────────────

function resolvePrimaryMuscle(exerciseId) {
  // Direct canonical lookup
  if (exerciseLibrary[exerciseId]) {
    return { muscle: exerciseLibrary[exerciseId], resolvedVia: "canonical" };
  }
  // Normalization map lookup
  const canonical = normalizationMap[exerciseId];
  if (canonical && exerciseLibrary[canonical]) {
    return { muscle: exerciseLibrary[canonical], resolvedVia: `normalization → ${canonical}` };
  }
  // Unresolved
  return { muscle: null, resolvedVia: "unresolved" };
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────

function httpsRequest(options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw  = Buffer.concat(chunks).toString("utf8");
        const code = res.statusCode ?? 0;
        if (code < 200 || code >= 300) {
          reject(new Error(`HTTP ${code}: ${raw.slice(0, 400)}`));
        } else {
          try { resolve(JSON.parse(raw)); }
          catch { resolve(raw); }
        }
      });
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

/** Fetches all set_logs rows with NULL primary_muscle for this user.
 *
 * set_logs has no user_id column — it links to users via session_id.
 * We use PostgREST's embedded resource filter to join through workout_sessions:
 *   /rest/v1/set_logs?select=id,exercise_id,workout_sessions!inner(user_id)
 *   &workout_sessions.user_id=eq.<USER_ID>&primary_muscle=is.null
 */
async function fetchNullRows() {
  const url = new URL(`/rest/v1/${TABLE}`, SUPABASE_URL);
  url.searchParams.set("select", "id,exercise_id,workout_sessions!inner(user_id)");
  url.searchParams.set("workout_sessions.user_id", `eq.${USER_ID}`);
  url.searchParams.set("primary_muscle", "is.null");
  url.searchParams.set("limit", "10000");   // adjust if user has > 10k null rows

  const opts = {
    hostname: url.hostname,
    path:     url.pathname + url.search,
    method:   "GET",
    headers: {
      "Accept":        "application/json",
      "Authorization": `Bearer ${bearerToken}`,
      "apikey":        SUPABASE_ANON,
    },
  };
  return httpsRequest(opts, null);
}

/** PATCHes a single set_log row's primary_muscle column. */
async function patchRow(id, primaryMuscle) {
  const url = new URL(`/rest/v1/${TABLE}`, SUPABASE_URL);
  url.searchParams.set("id", `eq.${id}`);

  const body = JSON.stringify({ primary_muscle: primaryMuscle });
  const opts = {
    hostname: url.hostname,
    path:     url.pathname + url.search,
    method:   "PATCH",
    headers: {
      "Content-Type":   "application/json",
      "Accept":         "application/json",
      "Prefer":         "return=minimal",
      "Authorization":  `Bearer ${bearerToken}`,
      "apikey":         SUPABASE_ANON,
      "Content-Length": Buffer.byteLength(body),
    },
  };
  return httpsRequest(opts, body);
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n=== ProjectApex — Primary Muscle Backfill ===`);
  console.log(`Supabase project : ${SUPABASE_URL}`);
  console.log(`User ID          : ${USER_ID}`);
  console.log(`Auth mode        : ${SUPABASE_AUTH ? "user JWT" : "anon key"}`);
  console.log(`Dry run          : ${DRY_RUN ? "YES — no writes will occur" : "NO — writing to database"}`);
  console.log();

  // 1. Fetch all rows with NULL primary_muscle
  console.log("Fetching rows with NULL primary_muscle…");
  let rows;
  try {
    rows = await fetchNullRows();
  } catch (err) {
    console.error(`Fatal: could not fetch rows: ${err.message}`);
    process.exit(1);
  }

  if (!Array.isArray(rows) || rows.length === 0) {
    console.log("No rows with NULL primary_muscle found. Nothing to do.");
    return;
  }

  console.log(`Found ${rows.length} rows with NULL primary_muscle.\n`);

  // 2. Group by exercise_id for the summary report
  const byExerciseId = {};
  for (const row of rows) {
    byExerciseId[row.exercise_id] = byExerciseId[row.exercise_id] ?? [];
    byExerciseId[row.exercise_id].push(row.id);
  }

  // 3. Resolve primary_muscle for each unique exercise_id
  const resolved   = [];
  const unresolved = [];

  console.log("Resolution summary:");
  console.log("─".repeat(70));

  const sortedIds = Object.keys(byExerciseId).sort();
  for (const exerciseId of sortedIds) {
    const { muscle, resolvedVia } = resolvePrimaryMuscle(exerciseId);
    const count = byExerciseId[exerciseId].length;

    if (muscle) {
      console.log(`  ✓  ${exerciseId.padEnd(40)} → ${muscle.padEnd(12)} (${count} rows, via ${resolvedVia})`);
      resolved.push({ exerciseId, muscle, ids: byExerciseId[exerciseId] });
    } else {
      console.log(`  ✗  ${exerciseId.padEnd(40)} → UNRESOLVED                 (${count} rows)`);
      unresolved.push({ exerciseId, count });
    }
  }

  console.log("─".repeat(70));
  console.log(`  Resolved: ${resolved.length} unique exercise IDs`);
  console.log(`  Unresolved: ${unresolved.length} unique exercise IDs\n`);

  if (unresolved.length > 0) {
    console.log("⚠️  Unresolved exercise IDs (primary_muscle will remain NULL):");
    for (const { exerciseId, count } of unresolved) {
      console.log(`   ${exerciseId} (${count} rows)`);
    }
    console.log();
    console.log("   Action: Add these IDs to normalizationMap in ExerciseLibrary.swift");
    console.log("   and backfill_primary_muscle.mjs, then re-run this script.\n");
  }

  if (DRY_RUN) {
    const totalToUpdate = resolved.reduce((sum, r) => sum + r.ids.length, 0);
    console.log(`DRY RUN complete. Would update ${totalToUpdate} rows across ${resolved.length} exercise IDs.`);
    console.log("Set DRY_RUN=false to apply changes.\n");
    return;
  }

  // 4. Apply updates row-by-row with gentle rate limiting
  console.log("Applying updates…");
  console.log("─".repeat(70));

  let succeeded = 0;
  let failed    = 0;

  for (const { exerciseId, muscle, ids } of resolved) {
    process.stdout.write(`  Updating ${ids.length} rows for '${exerciseId}' → '${muscle}' … `);

    let exSucceeded = 0;
    let exFailed    = 0;

    for (let i = 0; i < ids.length; i++) {
      try {
        await patchRow(ids[i], muscle);
        exSucceeded++;
        succeeded++;
      } catch (err) {
        exFailed++;
        failed++;
        console.error(`\n    ✗ Failed for row ${ids[i]}: ${err.message}`);
      }

      // Gentle rate limiting: 50ms between requests to avoid overloading PostgREST
      if (i < ids.length - 1) {
        await new Promise(r => setTimeout(r, 50));
      }
    }

    if (exFailed === 0) {
      console.log(`✓ (${exSucceeded} updated)`);
    } else {
      console.log(`partial: ${exSucceeded} ok, ${exFailed} failed`);
    }
  }

  console.log("─".repeat(70));
  console.log(`\nBackfill complete:`);
  console.log(`  Updated  : ${succeeded} rows`);
  console.log(`  Failed   : ${failed} rows`);
  console.log(`  Unresolved exercise IDs with NULL primary_muscle: ${unresolved.length > 0 ? unresolved.map(u => u.exerciseId).join(", ") : "none"}`);

  if (failed > 0) {
    console.error("\n⚠️  Some rows failed to update. Re-run the script to retry.");
    process.exit(1);
  }

  console.log("\nDone.\n");
}

main().catch((err) => {
  console.error("\nFatal error:", err.message);
  process.exit(1);
});
