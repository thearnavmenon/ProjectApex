#!/usr/bin/env node
/**
 * seed_historical_memory.mjs
 *
 * Seeds historical workout data directly into memory_embeddings, bypassing
 * workout_sessions / set_logs entirely. The AI learns from RAG retrieval, so
 * embeddings alone are sufficient for it to benefit from this history.
 *
 * Usage:
 *   OPENAI_API_KEY=sk-...  SUPABASE_ANON_KEY=eyJ...  USER_ID=<uuid>  node seed_historical_memory.mjs
 *
 * Optional — pass a Supabase auth JWT instead of anon key for RLS-protected tables:
 *   SUPABASE_AUTH_TOKEN=eyJ...
 *
 * The script will:
 *   1. Build one natural-language memory string per exercise per session.
 *   2. Call OpenAI text-embedding-3-small (1536-dim) for each string.
 *   3. Upsert the resulting row into memory_embeddings via PostgREST.
 *   4. Run test retrievals for "Bench Press" and "Incline Dumbbell Press"
 *      and print the top-3 results with similarity scores.
 */

import https from "https";

// ─── Config ────────────────────────────────────────────────────────────────

const SUPABASE_URL  = "https://hqjgrlzvrttnyfjqjewe.supabase.co";
const OPENAI_MODEL  = "text-embedding-3-small";
const EMBED_DIM     = 1536;
const MATCH_RPC     = "match_memory_embeddings";
const TABLE         = "memory_embeddings";

const OPENAI_KEY       = process.env.OPENAI_API_KEY       ?? "";
const SUPABASE_ANON    = process.env.SUPABASE_ANON_KEY    ?? "";
const SUPABASE_AUTH    = process.env.SUPABASE_AUTH_TOKEN  ?? "";  // optional JWT
const USER_ID          = process.env.USER_ID              ?? "";

if (!OPENAI_KEY)    { console.error("ERROR: OPENAI_API_KEY env var is required.");    process.exit(1); }
if (!SUPABASE_ANON) { console.error("ERROR: SUPABASE_ANON_KEY env var is required."); process.exit(1); }
if (!USER_ID)       { console.error("ERROR: USER_ID env var is required.");           process.exit(1); }

// Bearer token: use the user auth JWT when available, otherwise fall back to
// the anon key (matches SupabaseClient.baseRequest() logic exactly).
const bearerToken = SUPABASE_AUTH || SUPABASE_ANON;

// ─── Muscle group mapping ────────────────────────────────────────────────────

/**
 * Infers muscle groups from an exercise name. Intentionally conservative —
 * only primary movers are listed, matching the snake_case convention used by
 * the Swift MemoryService tag classifier.
 */
function muscleGroups(exercise) {
  const name = exercise.toLowerCase();

  if (name.includes("bench press"))          return ["pectoralis_major", "triceps", "anterior_deltoid"];
  if (name.includes("overhead press") ||
      name.includes("ohp"))                  return ["deltoid", "triceps", "upper_trapezius"];
  if (name.includes("lat pulldown"))         return ["latissimus_dorsi", "biceps", "rear_deltoid"];
  if (name.includes("barbell row"))          return ["latissimus_dorsi", "rear_deltoid", "biceps"];
  if (name.includes("incline") &&
      name.includes("press"))                return ["pectoralis_major", "anterior_deltoid", "triceps"];
  if (name.includes("seated row"))           return ["latissimus_dorsi", "rear_deltoid", "biceps"];
  if (name.includes("lateral raise"))        return ["medial_deltoid"];
  if (name.includes("chest fly") ||
      name.includes("fly"))                  return ["pectoralis_major", "anterior_deltoid"];
  if (name.includes("bicep curl") ||
      name.includes("bicep"))               return ["biceps_brachii"];
  if (name.includes("bulgarian split squat")) return ["quadriceps", "glutes", "hamstrings"];
  if (name.includes("romanian deadlift") ||
      name.includes("rdl"))                  return ["hamstrings", "glutes", "erector_spinae"];
  if (name.includes("pull-up") ||
      name.includes("pullup"))              return ["latissimus_dorsi", "biceps", "rear_deltoid"];

  return ["general"];
}

// ─── Historical data ─────────────────────────────────────────────────────────

/**
 * Each session entry has:
 *   daysAgo   – how many days before today this session occurred
 *   exercises – array of { name, sets, reps, weights[], note? }
 *
 * "weights" is an array, one entry per set. Where the spec gives a single
 * weight (e.g. "1x8 at 12.5kg") the array has one element repeated.
 */
const sessions = [
  {
    daysAgo: 14,
    exercises: [
      { name: "Bench Press",    sets: 3, reps: 5,  weights: [30, 40, 50] },
      { name: "Overhead Press", sets: 3, reps: 6,  weights: [40, 45, 50] },
      { name: "Lat Pulldown",   sets: 1, reps: 8,  weights: [12.5] },
      { name: "Barbell Row",    sets: 1, reps: 5,  weights: [14] },
    ],
  },
  {
    daysAgo: 11,
    exercises: [
      { name: "Incline Dumbbell Press", sets: 3, reps: 9,  weights: [10, 12.5, 15], note: "15kg felt strong and fast." },
      { name: "Seated Row",             sets: 3, reps: 8,  weights: [30, 40, 35] },
      { name: "Lateral Raises",         sets: 3, reps: 12, weights: [4, 5, 7.5] },
      { name: "Chest Fly",              sets: 3, reps: 12, weights: [5, 7.5, 5] },
      { name: "Bicep Curl DB",          sets: 2, reps: 10, weights: [5, 7.5] },
    ],
  },
  {
    daysAgo: 7,
    exercises: [
      { name: "Bench Press",    sets: 3, reps: 5,  weights: [40, 40, 50] },
      { name: "Barbell Row",    sets: 3, reps: 5,  weights: [15, 17.5, 22.5] },
      { name: "Overhead Press", sets: 1, reps: 6,  weights: [12.5] },
    ],
  },
  {
    daysAgo: 6,
    exercises: [
      { name: "Bulgarian Split Squat", sets: 3, reps: 5, weights: [7.5, 7.5, 7.5], note: "7.5kg dumbbells each hand." },
      { name: "Romanian Deadlift",     sets: 3, reps: 6, weights: [12.5, 15, 15] },
    ],
  },
  {
    daysAgo: 4,
    exercises: [
      { name: "Incline Dumbbell Press", sets: 3, reps: 9, weights: [15, 15, 12.5] },
    ],
  },
  {
    daysAgo: 3,
    exercises: [
      { name: "Bench Press",    sets: 3, reps: 5,  weights: [40, 50, 40] },
      { name: "Barbell Row",    sets: 3, reps: 5,  weights: [17.5, 17.5, 22.5] },
      { name: "Overhead Press", sets: 3, reps: 6,  weights: [12.5, 15, 15] },
      { name: "Pull-ups",       sets: 1, reps: 6,  weights: ["bodyweight"] },
    ],
  },
  {
    daysAgo: 1,
    exercises: [
      { name: "Incline Dumbbell Press", sets: 3, reps: 9,  weights: [12.5, 15, 17.5], note: "17.5kg strong set." },
      { name: "Seated Row",             sets: 3, reps: 8,  weights: [40, 40, 45] },
      { name: "Lateral Raises",         sets: 3, reps: 12, weights: [5, 2.5, 2.5] },
      { name: "Chest Fly",              sets: 3, reps: 10, weights: [5, 5, 7.5] },
    ],
  },
];

// ─── Memory string builder ────────────────────────────────────────────────────

/**
 * Builds the natural-language memory event string.
 *
 * Format (matching P4-T07 auto-event format):
 *   "[Exercise] session [N] days ago: [sets]x[reps] at [w1]kg, [w2]kg, [w3]kg.
 *    Outcome: on_target. RPE estimated moderate. [optional note]"
 *
 * For bodyweight sets, weight is omitted from the "at" clause.
 */
function buildMemoryString(exercise, daysAgo) {
  const { name, sets, reps, weights, note } = exercise;

  // Format weight list — filter out "bodyweight" for the weight string
  const numericWeights = weights.filter(w => typeof w === "number");
  const hasBodyweight  = weights.some(w => w === "bodyweight");

  let weightClause;
  if (hasBodyweight && numericWeights.length === 0) {
    // Pure bodyweight exercise
    weightClause = "bodyweight";
  } else if (numericWeights.length === 1) {
    weightClause = `${numericWeights[0]}kg`;
  } else {
    weightClause = numericWeights.map(w => `${w}kg`).join(", ");
  }

  // "session X days ago" vs "session 1 day ago"
  const timeClause = daysAgo === 1
    ? "session 1 day ago"
    : `session ${daysAgo} days ago`;

  let text = `${name} ${timeClause}: ${sets}x${reps} at ${weightClause}. Outcome: on_target. RPE estimated moderate.`;

  if (note) {
    text += ` ${note}`;
  }

  return text;
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

/** Minimal promise-based HTTPS request — avoids external dependencies. */
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

/** Calls OpenAI text-embedding-3-small and returns a Float32Array (1536 dims). */
async function fetchEmbedding(text) {
  const body = JSON.stringify({ model: OPENAI_MODEL, input: text });
  const opts  = {
    hostname: "api.openai.com",
    path:     "/v1/embeddings",
    method:   "POST",
    headers: {
      "Content-Type":  "application/json",
      "Authorization": `Bearer ${OPENAI_KEY}`,
      "Content-Length": Buffer.byteLength(body),
    },
  };
  const res = await httpsRequest(opts, body);
  const vec = res?.data?.[0]?.embedding;
  if (!Array.isArray(vec) || vec.length !== EMBED_DIM) {
    throw new Error(`Unexpected embedding dimension: ${vec?.length}`);
  }
  return vec;   // plain JS number array — Supabase accepts JSON arrays for vector columns
}

/** Upserts a row into memory_embeddings via PostgREST. */
async function upsertRow(row) {
  const body = JSON.stringify(row);
  const url  = new URL(`/rest/v1/${TABLE}`, SUPABASE_URL);
  const opts  = {
    hostname: url.hostname,
    path:     url.pathname,
    method:   "POST",
    headers: {
      "Content-Type":  "application/json",
      "Accept":        "application/json",
      "Prefer":        "return=minimal",   // no echo-back needed for seed
      "Authorization": `Bearer ${bearerToken}`,
      "apikey":        SUPABASE_ANON,
      "Content-Length": Buffer.byteLength(body),
    },
  };
  await httpsRequest(opts, body);
}

/** Calls the match_memory_embeddings RPC and returns the result rows. */
async function matchMemory(queryText, threshold = 0.3, count = 3) {
  const queryEmbedding = await fetchEmbedding(queryText);
  const params = {
    query_embedding: queryEmbedding,
    p_user_id:       USER_ID,
    match_threshold: threshold,
    match_count:     count,
  };
  const body = JSON.stringify(params);
  const url  = new URL(`/rest/v1/rpc/${MATCH_RPC}`, SUPABASE_URL);
  const opts  = {
    hostname: url.hostname,
    path:     url.pathname,
    method:   "POST",
    headers: {
      "Content-Type":  "application/json",
      "Accept":        "application/json",
      "Authorization": `Bearer ${bearerToken}`,
      "apikey":        SUPABASE_ANON,
      "Content-Length": Buffer.byteLength(body),
    },
  };
  return httpsRequest(opts, body);
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log(`\n=== ProjectApex — Historical Memory Seed ===`);
  console.log(`Supabase project : ${SUPABASE_URL}`);
  console.log(`User ID          : ${USER_ID}`);
  console.log(`Auth mode        : ${SUPABASE_AUTH ? "user JWT" : "anon key"}`);
  console.log();

  // Build the flat list of (memoryString, exerciseName, muscleGroups) tuples
  const entries = [];
  for (const session of sessions) {
    for (const exercise of session.exercises) {
      const text    = buildMemoryString(exercise, session.daysAgo);
      const muscles = muscleGroups(exercise.name);
      entries.push({ text, exercise, muscles });
    }
  }

  console.log(`Entries to seed: ${entries.length}`);
  console.log("─".repeat(60));

  let succeeded = 0;
  let failed    = 0;

  for (let i = 0; i < entries.length; i++) {
    const { text, exercise, muscles } = entries[i];
    const label = `[${i + 1}/${entries.length}] ${exercise.name}`;
    process.stdout.write(`${label} … `);

    try {
      const embedding = await fetchEmbedding(text);

      const row = {
        user_id:        USER_ID,
        session_id:     null,
        exercise_id:    null,
        muscle_groups:  muscles,
        tags:           ["manually_seeded", "historical"],
        raw_transcript: text,
        embedding:      embedding,
        // metadata column is nullable text/jsonb — omit to avoid type issues
      };

      await upsertRow(row);
      console.log("✓");
      succeeded++;
    } catch (err) {
      console.log(`✗  ${err.message}`);
      failed++;
    }

    // Gentle rate-limiting: 200 ms between OpenAI calls to avoid 429s on
    // the default tier (3 000 RPM / 500 RPD).
    if (i < entries.length - 1) {
      await new Promise(r => setTimeout(r, 200));
    }
  }

  console.log("─".repeat(60));
  console.log(`Seeding complete: ${succeeded} succeeded, ${failed} failed.\n`);

  // ─── Retrieval smoke test ───────────────────────────────────────────────

  console.log("=== Retrieval smoke test ===\n");

  const queries = [
    "Bench Press",
    "Incline Dumbbell Press",
  ];

  for (const query of queries) {
    console.log(`Query: "${query}"`);
    console.log("─".repeat(60));

    try {
      // Use a low threshold (0.3) so we always see the top-3 even if
      // similarity is lower than the production 0.75 cutoff.
      const rows = await matchMemory(query, 0.3, 3);

      if (!Array.isArray(rows) || rows.length === 0) {
        console.log("  No results returned.\n");
        continue;
      }

      rows.forEach((row, idx) => {
        const sim = typeof row.similarity === "number"
          ? row.similarity.toFixed(4)
          : row.similarity ?? "n/a";
        console.log(`  #${idx + 1}  similarity=${sim}`);
        console.log(`       ${row.raw_transcript ?? row.rawTranscript ?? JSON.stringify(row)}`);
      });
    } catch (err) {
      console.log(`  Retrieval error: ${err.message}`);
    }

    console.log();
  }

  console.log("Done.");
}

main().catch((err) => {
  console.error("\nFatal error:", err.message);
  process.exit(1);
});
