// Backtest harness tests — the "backtest CI job": a synthetic-cohort
// golden run pinning the full report (regenerate deliberately with
//   UPDATE_TWIN_GOLDEN=1 deno test --allow-read --allow-write --allow-env run_test.ts
// after an intentional model/param change), plus structural invariants
// and the determinism property.
//
// The real-cohort backtest runs locally against a prod export (never
// committed); this synthetic golden keeps the harness itself under CI.

import { assert, assertEquals } from "jsr:@std/assert";
import { runBacktest, type BacktestReport } from "./run.ts";
import type { ExportedRow } from "./replay.ts";

const dir = new URL(".", import.meta.url).pathname;
const fixture = JSON.parse(
  Deno.readTextFileSync(`${dir}testdata/synthetic_cohort.json`),
);
const rows: ExportedRow[] = fixture.rows;

Deno.test("backtest is deterministic: two runs produce identical reports", () => {
  const a = JSON.stringify(runBacktest(rows));
  const b = JSON.stringify(runBacktest(rows));
  assertEquals(a, b);
});

Deno.test("backtest structural invariants on the synthetic cohort", () => {
  const r: BacktestReport = runBacktest(rows);
  assertEquals(r.userCount, 2);
  assertEquals(r.sessionCount, 8);
  assert(r.transitions.length >= 4, `only ${r.transitions.length} scored`);
  // User A's chest press line: 5 scoreable transitions (s2..s6); user B's
  // pulldown: 1 (t2). The 0 kg push_up top must never be a TARGET.
  assert(
    r.transitions.every((t) => t.weightKg > 0),
    "zero-weight target leaked into scoring",
  );
  // The 12-rep incline top (s5) is outside validity → not a target.
  assert(
    r.transitions.every((t) => t.actualReps >= 3 && t.actualReps <= 10),
    "out-of-validity target leaked",
  );
  for (const m of [...r.perPattern, r.overall]) {
    assert(Number.isFinite(m.maeEwma) && m.maeEwma >= 0);
    assert(Number.isFinite(m.maeTwin) && m.maeTwin >= 0);
    assert(Number.isFinite(m.crpsTwin) && m.crpsTwin >= 0);
    assert(m.coverage90Twin >= 0 && m.coverage90Twin <= 1);
  }
  // Identifiability entries exist for both users.
  assert(r.identifiability.some((e) => e.userId.startsWith("aaaaaaaa")));
  assert(r.identifiability.some((e) => e.userId.startsWith("bbbbbbbb")));
  // No covariance-health incidents on clean synthetic data.
  assert(r.identifiability.every((e) => e.jitterIncidents === 0));
});

Deno.test("golden report snapshot (synthetic cohort)", () => {
  const goldenPath = `${dir}testdata/synthetic_cohort_golden.json`;
  const fresh = JSON.stringify(runBacktest(rows), null, 2);
  if (Deno.env.get("UPDATE_TWIN_GOLDEN") === "1") {
    Deno.writeTextFileSync(goldenPath, fresh);
    console.log(`golden regenerated → ${goldenPath}`);
    return;
  }
  let golden: string;
  try {
    golden = Deno.readTextFileSync(goldenPath);
  } catch {
    throw new Error(
      "golden file missing — run UPDATE_TWIN_GOLDEN=1 deno test --allow-read --allow-write --allow-env run_test.ts",
    );
  }
  assertEquals(fresh, golden);
});
