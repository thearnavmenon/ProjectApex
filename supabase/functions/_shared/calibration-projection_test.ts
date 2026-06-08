// Project Apex — unit tests for calibration-review projection derivation (#294).
//
// Run locally:
//   deno test --allow-all supabase/functions/_shared/calibration-projection_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  deriveFloor,
  deriveProgress,
  deriveProjection,
  deriveStretch,
} from "./calibration-projection.ts";
import type { E1RMSession } from "./plateau-verdict.ts";

function sessions(e1rms: number[]): E1RMSession[] {
  // loggedAt strictly increasing so the "recent window" ordering is well-defined.
  return e1rms.map((e1rm, i) => ({
    loggedAt: new Date(2026, 0, i + 1),
    e1rm,
    avgRPE: 8,
  }));
}

Deno.test("deriveFloor: round-DOWN median of the recent window (fast cadence → 3)", () => {
  // last 3 of [100,102,104,103] = [102,104,103], median 103 → round down 2.5 → 102.5
  assertEquals(deriveFloor(sessions([100, 102, 104, 103]), 1), 102.5);
});

Deno.test("deriveFloor: never overstates — rounds down, not nearest", () => {
  // median 101 → round down to 100 (not 102.5)
  assertEquals(deriveFloor(sessions([101, 101, 101]), 1), 100);
});

Deno.test("deriveFloor: slow cadence widens the window to 4", () => {
  // cadence > 3.5 → window 4. last 4 of [100,200,100,100,100]=[200,100,100,100] median (100+100)/2=100
  assertEquals(deriveFloor(sessions([100, 200, 100, 100, 100]), 7), 100);
});

Deno.test("deriveFloor: no e1RM history → null", () => {
  assertEquals(deriveFloor(sessions([]), 1), null);
});

Deno.test("deriveStretch: progressing adds 7.5% then rounds up", () => {
  // 100 * 1.075 = 107.5 → round up 2.5 → 107.5
  assertEquals(deriveStretch(100, "progressing"), 107.5);
});

Deno.test("deriveStretch: declining adds only 2.5%", () => {
  // 100 * 1.025 = 102.5 → 102.5
  assertEquals(deriveStretch(100, "declining"), 102.5);
});

Deno.test("deriveStretch: never collapses to floor — at least one increment above", () => {
  // tiny floor where margin rounds to floor: 2.5 * 1.025 = 2.5625 → round up → 5.0 ≥ floor+2.5
  assertEquals(deriveStretch(2.5, "declining"), 5.0);
});

Deno.test("deriveProgress: below floor → behind", () => {
  assertEquals(deriveProgress(95, 100, 110), "behind");
});

Deno.test("deriveProgress: at/above stretch → achieved", () => {
  assertEquals(deriveProgress(110, 100, 110), "achieved");
});

Deno.test("deriveProgress: lower half of band → on_track; upper half → ahead", () => {
  assertEquals(deriveProgress(102, 100, 110), "on_track"); // pos 0.2
  assertEquals(deriveProgress(106, 100, 110), "ahead"); // pos 0.6
});

Deno.test("deriveProjection: fresh-from-review pattern starts on_track (current ≈ floor)", () => {
  // stable 100s: capability 100, floor 100, stretch 107.5 (progressing); current 100 → pos 0 → on_track
  const p = deriveProjection("squat", sessions([100, 100, 100]), 1, "progressing");
  assertEquals(p, { pattern: "squat", floor: 100, stretch: 107.5, progress: "on_track" });
});

Deno.test("deriveProjection: no e1RM history → null (no projection this apply)", () => {
  assertEquals(deriveProjection("squat", sessions([]), 1, "progressing"), null);
});
