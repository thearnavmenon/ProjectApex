// Project Apex — unit tests for capability-driven projection re-calibration
// (#305, ADR-0023). Pure helpers — no DB, no clock.
//
// Run locally:
//   deno test supabase/functions/update-trainee-model/recalibration_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { outgrewBand, rederiveOutgrownProjection } from "./recalibration.ts";
import type { PatternProjection } from "../_shared/calibration-projection.ts";
import type { E1RMSession } from "../_shared/plateau-verdict.ts";

const proj = (
  floor: number,
  stretch: number,
  progress: PatternProjection["progress"] = "on_track",
): PatternProjection => ({ pattern: "squat", floor, stretch, progress });

/** Sessions all at the same e1RM → median == that value for any window. */
function flat(e1rm: number, n = 4): E1RMSession[] {
  return Array.from({ length: n }, (_, i) => ({
    loggedAt: new Date(2026, 0, i + 1),
    e1rm,
    avgRPE: 8,
  }));
}

// ─── outgrewBand ────────────────────────────────────────────────────────────

Deno.test("outgrewBand: below a full band past stretch → false", () => {
  // floor 100, stretch 110, band 10 → threshold 120.
  assertEquals(outgrewBand(proj(100, 110), 119), false);
});

Deno.test("outgrewBand: exactly a full band past stretch → true", () => {
  assertEquals(outgrewBand(proj(100, 110), 120), true);
});

Deno.test("outgrewBand: well past → true", () => {
  assertEquals(outgrewBand(proj(100, 110), 135), true);
});

// ─── rederiveOutgrownProjection ─────────────────────────────────────────────

Deno.test("rederive: capability inside the band → null (not outgrown)", () => {
  assertEquals(
    rederiveOutgrownProjection(proj(100, 110), flat(115), 3, "progressing"),
    null,
  );
});

Deno.test("rederive: no e1RM history → null", () => {
  assertEquals(
    rederiveOutgrownProjection(proj(100, 110), [], 3, "progressing"),
    null,
  );
});

Deno.test("rederive: outgrown (progressing) → floor steps up to demonstrated, stretch + progress re-derive", () => {
  // current 125: newFloor = round-down 125 = 125; stretch = round-up(125×1.075=134.375)=135;
  // progress = deriveProgress(125,125,135) → on_track.
  const out = rederiveOutgrownProjection(proj(100, 110, "achieved"), flat(125), 3, "progressing");
  assertEquals(out, { pattern: "squat", floor: 125, stretch: 135, progress: "on_track" });
});

Deno.test("rederive: floor is monotonic non-decreasing (never below the old floor)", () => {
  const out = rederiveOutgrownProjection(proj(100, 110), flat(125), 3, "progressing")!;
  assertEquals(out.floor >= 100, true);
});

Deno.test("rederive: re-applying the result is a no-op — idempotent (progressing)", () => {
  const first = rederiveOutgrownProjection(proj(100, 110), flat(125), 3, "progressing")!;
  // Same capability, now against the new band → must NOT re-fire.
  assertEquals(
    rederiveOutgrownProjection(first, flat(125), 3, "progressing"),
    null,
  );
});

Deno.test("rederive: idempotent even on a DECLINING trend (the small-margin case)", () => {
  // declining margin is only 2.5%, but newFloor = round-down(current) guarantees
  // stretch ≥ floor+2.5 > current, so it can never stay 'achieved' → no flip-flop.
  const first = rederiveOutgrownProjection(proj(100, 110), flat(125), 3, "declining")!;
  assertEquals(first.stretch > 125, true); // strictly above current
  assertEquals(
    rederiveOutgrownProjection(first, flat(125), 3, "declining"),
    null,
  );
});

Deno.test("rederive: a user-raised stretch above the re-derived value is preserved (upward-only)", () => {
  // floor 100, stretch manually raised to 320; band 220 → threshold 540.
  const out = rederiveOutgrownProjection(proj(100, 320, "achieved"), flat(545), 3, "progressing")!;
  // newFloor = 545; deriveStretch(545,progressing)=round-up(585.875)=587.5; max(320,587.5)=587.5.
  assertEquals(out.floor, 545);
  assertEquals(out.stretch, 587.5);
});
