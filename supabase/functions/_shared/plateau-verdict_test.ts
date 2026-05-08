// Project Apex — Phase 2 plateau-verdict tests.
//
// Per ADR-0009 (hybrid two-track plateau verdict, including the
// 2026-05-07 amendment for muscle-level aggregation), this slice
// computes per-pattern `ProgressionTrend` from e1RM EWMA flatness
// combined with weekly-volume-load flatness, and aggregates upward
// to `MuscleProfile.stagnationStatus` via worst-across-patterns.
//
// Each test name pins the originating ADR (or §amendment) so a
// failure surfaces the rule the change touches.
//
// Run locally:
//   deno test supabase/functions/_shared/plateau-verdict_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  aggregateMuscleStagnationStatus,
  type E1RMSession,
  e1rmTrack,
  type PatternTrendForMuscleAggregation,
  plateauVerdict,
  type VolumeLoadSession,
  volumeLoadTrack,
} from "./plateau-verdict.ts";

const mkE1RM = (
  e1rm: number,
  daysAgo: number,
  avgRPE: number | null = 7,
): E1RMSession => ({
  loggedAt: new Date(2026, 0, 1 + daysAgo),
  e1rm,
  avgRPE,
});

const mkVL = (
  weeklyVolumeLoad: number,
  weekIndex: number,
  avgRPE: number | null = 7,
): VolumeLoadSession => ({
  loggedAt: new Date(2026, 0, 1 + weekIndex * 7),
  weeklyVolumeLoad,
  avgRPE,
});

Deno.test("ADR-0009: e1RM spread boundary at 2.5% — spread 2.4% → flat (plateau-eligible), 2.6% → improving (strict ≤ threshold)", () => {
  // Spread formula: (max − min) / mean (Q1 lock).
  //   [98.8, 100, 101.2] → spread = 2.4 / 100 = 2.4% ≤ 2.5% → flat
  //   [98.7, 100, 101.3] → spread = 2.6 / 100 = 2.6% > 2.5% → improving
  const flat: E1RMSession[] = [mkE1RM(98.8, 0), mkE1RM(100, 1), mkE1RM(101.2, 2)];
  const improving: E1RMSession[] = [
    mkE1RM(98.7, 0),
    mkE1RM(100, 1),
    mkE1RM(101.3, 2),
  ];
  assertEquals(e1rmTrack(flat, 3.4), "flat");
  assertEquals(e1rmTrack(improving, 3.4), "improving");
});

Deno.test("ADR-0009: e1RM nil-RPE manual-log defence — 3 all-nil sessions defer (require window+1); 4 all-nil sessions with low spread fire on spread alone (effort gate suspended when all data is nil)", () => {
  // Cadence 3.4 → window = 3.
  // 3 all-nil sessions: any-nil triggers window+1 requirement; not enough data → improving.
  // 4 all-nil sessions: window+1 satisfied; mean(non-nil) is undefined →
  //   gate is suspended; plateau fires on spread alone (1% ≤ 2.5%).
  const threeAllNil: E1RMSession[] = [
    mkE1RM(99.5, 0, null),
    mkE1RM(100, 1, null),
    mkE1RM(100.5, 2, null),
  ];
  assertEquals(e1rmTrack(threeAllNil, 3.4), "improving");

  const fourAllNil: E1RMSession[] = [
    mkE1RM(99.5, 0, null),
    mkE1RM(100, 1, null),
    mkE1RM(100, 2, null),
    mkE1RM(100.5, 3, null),
  ];
  assertEquals(e1rmTrack(fourAllNil, 3.4), "flat");
});

Deno.test("ADR-0009: e1RM decline boundary at 5% drop — 4.9% drop with avgRPE 7 → improving (under threshold, ≥ 5% required)", () => {
  // (start − end) / start = (100 − 95.1) / 100 = 4.9% < 5% threshold → no decline.
  const sessions: E1RMSession[] = [
    mkE1RM(100, 0, 7),
    mkE1RM(97.55, 1, 7),
    mkE1RM(95.1, 2, 7),
  ];
  assertEquals(e1rmTrack(sessions, 3.4), "improving");
});

Deno.test("ADR-0009: e1RM 5% drop with avgRPE < 7 → improving (coasting, not declining — low-effort drops are deload/recovery, not regression)", () => {
  // Same drop fixture as the high-RPE case but avgRPE = 6.5 < 7.0.
  // The decline gate is the protection against firing on light weeks.
  const sessions: E1RMSession[] = [
    mkE1RM(100, 0, 6.5),
    mkE1RM(97.5, 1, 6.5),
    mkE1RM(95, 2, 6.5),
  ];
  assertEquals(e1rmTrack(sessions, 3.4), "improving");
});

Deno.test("ADR-0009: e1RM 5% drop start→end with avgRPE ≥ 7 → declining", () => {
  // (start − end) / start = (100 − 95) / 100 = 5% ≥ 5% threshold,
  // avgRPE = 7 ≥ 7 → declining fires.
  const sessions: E1RMSession[] = [
    mkE1RM(100, 0, 7),
    mkE1RM(97.5, 1, 7),
    mkE1RM(95, 2, 7),
  ];
  assertEquals(e1rmTrack(sessions, 3.4), "declining");
});

Deno.test("ADR-0009: e1RM partial-nil at window+1 — gate applied to mean(non-nil values), NOT bypassed to spread-alone (Q3 refinement)", () => {
  // 4 sessions at cadence 3.4 (window=3, window+1=4):
  //   - Session 2 has nil avgRPE; the other three are 9.0 (high effort)
  //   - Spread = 1% (well under 2.5%)
  //   - mean(non-nil avgRPE) = 9.0 ≥ 8.0 → gate fails → improving
  // The "fire on spread alone" path is reserved for ALL-nil at window+1.
  // Partial-nil keeps the effort gate active using whatever RPE data exists.
  const partialNil: E1RMSession[] = [
    mkE1RM(99.5, 0, 9.0),
    mkE1RM(100, 1, null),
    mkE1RM(100, 2, 9.0),
    mkE1RM(100.5, 3, 9.0),
  ];
  assertEquals(e1rmTrack(partialNil, 3.4), "improving");
});

Deno.test("ADR-0009: e1RM effort gate at avgRPE 8.0 (strict <) — 7.99 plateau-eligible, 8.0 → improving (high-RPE flatness is grinding, not plateau)", () => {
  const flat: E1RMSession[] = [
    mkE1RM(100, 0, 7.99),
    mkE1RM(100, 1, 7.99),
    mkE1RM(100, 2, 7.99),
  ];
  const improving: E1RMSession[] = [
    mkE1RM(100, 0, 8.0),
    mkE1RM(100, 1, 8.0),
    mkE1RM(100, 2, 8.0),
  ];
  assertEquals(e1rmTrack(flat, 3.4), "flat");
  assertEquals(e1rmTrack(improving, 3.4), "improving");
});

Deno.test("ADR-0009: volume-load drop ≥ 10% prior week → most recent week → declining (no RPE gate on volume-load decline)", () => {
  // Week-over-week drop: prior=10000, current=9000 → 10% drop ≥ threshold.
  const sessions: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(9000, 3),
  ];
  assertEquals(volumeLoadTrack(sessions), "declining");
});

Deno.test("ADR-0009: volume-load overreach boundary — current at 114.9% of trailing-4 mean does NOT fire overreach; fall-through is 'improving' under realistic fixture geometry (Option A applied per cycle 10 reasoning)", () => {
  // Same math constraint as cycle 10: a 14.9% spike above the trailing
  // mean produces suffix-4 spread ~14% — incompatible with the 5%
  // plateau threshold. Per the authority hierarchy (formula > issue prose),
  // the test asserts the actual fall-through verdict 'improving'.
  // The strict ≥ threshold check on overreach is what the test pins.
  const sessions: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10000, 3),
    mkVL(11490, 4),
  ];
  assertEquals(volumeLoadTrack(sessions), "improving");
});

Deno.test("ADR-0009: volume-load overreach boundary at exactly 115% — strict > threshold, so 115.0% itself does NOT fire overreach (boundary lock — flipping to ≥ would regress this test)", () => {
  // Prior 4 mean = 10000; current = 11500 exactly. 11500 > 1.15 × 10000 = 11500
  // is FALSE under strict-greater-than. Drop is negative (volume rose), spread
  // suffix-4 is ~14.5% > 5% → fall-through verdict is 'improving'.
  const sessions: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10000, 3),
    mkVL(11500, 4),
  ];
  assertEquals(volumeLoadTrack(sessions), "improving");
});

Deno.test("ADR-0009: volume-load overreach detector — current week > 115% of mean(prior 4 weeks) → declining", () => {
  // 5 weeks: prior 4 = [10000]×4 (mean 10000); current = 11600.
  // 11600 > 1.15 × 10000 = 11500 → overreach fires → declining.
  const sessions: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10000, 3),
    mkVL(11600, 4),
  ];
  assertEquals(volumeLoadTrack(sessions), "declining");
});

Deno.test("ADR-0009: volume-load drop boundary at 10% — drop 9.9% does NOT fire decline (strict ≥ threshold); fall-through is 'improving' under realistic fixture geometry", () => {
  // Issue #78 describes this case as "drop 9.9% → flat (under threshold)",
  // but that verdict is mathematically unreachable under Q1's (max−min)/mean
  // spread formula: a 9.9% week-over-week drop produces range ≥ 990, and
  // (max−min)/mean ≤ 5% would require mean ≥ 19800 — incompatible with a
  // min of 9010 in any realistic-shape fixture. Per the authority hierarchy
  // (formula > issue prose), the test asserts what the rule actually
  // returns: 'improving' (decline doesn't fire AND spread > plateau gate).
  // The boundary-lock value is preserved: a strict ≥ threshold test would
  // fail if the implementation flipped to >.
  const sessions: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(9010, 3),
  ];
  assertEquals(volumeLoadTrack(sessions), "improving");
});

Deno.test("ADR-0009: volume-load track plateau on 5% spread (trailing 4 weeks) + avgRPE < 8 → flat", () => {
  // Trailing 4 weeks: [9750, 10000, 10000, 10250] → max=10250, min=9750,
  // mean=10000, spread = 500/10000 = 5% ≤ 5% threshold; avgRPE 7 < 8 → flat.
  const sessions: VolumeLoadSession[] = [
    mkVL(9750, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10250, 3),
  ];
  assertEquals(volumeLoadTrack(sessions), "flat");
});

Deno.test("ADR-0009 amendment: muscle aggregation — empty participation (no patterns at all) → muscle progressing (no-signal default; cold-start signal lives in MuscleProfile.confidence)", () => {
  assertEquals(aggregateMuscleStagnationStatus([]), "progressing");
});

Deno.test("ADR-0009 amendment: muscle aggregation — single-pattern muscle (chest with horizontalPush declining) → muscle declining (trivial aggregation; chest/shoulders/biceps/triceps have ≤1 primary pattern)", () => {
  const chestPatterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "horizontalPush", trend: "declining", confidence: "established" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(chestPatterns), "declining");
});

Deno.test("ADR-0009 amendment: muscle aggregation — legs scenario (squat plateaued + hipHinge progressing + lunge progressing, all participating) → legs plateaued (the canonical aggregation-risk concentration cell — see v2.x watch-item #9)", () => {
  // The named scenario from ADR-0009 §"Concentration of aggregation risk".
  // Squat plateaus are common; under worst-across-patterns, one squat plateau
  // forces legs.stagnationStatus = .plateaued even when hipHinge and lunge
  // are progressing. v2.x upgrade-path trigger if this fires >30% of the
  // time across alpha cohort.
  const legsPatterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "plateaued", confidence: "established" },
    { pattern: "hipHinge", trend: "progressing", confidence: "established" },
    { pattern: "lunge", trend: "progressing", confidence: "calibrating" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(legsPatterns), "plateaued");
});

Deno.test("ADR-0009 amendment: muscle aggregation — all patterns declining BUT all bootstrapping → muscle progressing (precondition filters them all out, falling through to no-signal default)", () => {
  // Without the precondition filter, the worst-of rule would return
  // declining. With it, the participating set is empty → progressing.
  const patterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "declining", confidence: "bootstrapping" },
    { pattern: "hipHinge", trend: "declining", confidence: "bootstrapping" },
    { pattern: "lunge", trend: "declining", confidence: "bootstrapping" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(patterns), "progressing");
});

Deno.test("ADR-0009 amendment: muscle aggregation — bootstrapping pattern with declining trend does NOT participate (precondition: confidence > .bootstrapping); rest progressing → muscle progressing", () => {
  // Squat is declining but its confidence is bootstrapping — not enough
  // data to trust the trend. Filtered out per the amendment's
  // participation precondition. Remaining patterns are both progressing.
  const patterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "declining", confidence: "bootstrapping" },
    { pattern: "hipHinge", trend: "progressing", confidence: "established" },
    { pattern: "lunge", trend: "progressing", confidence: "calibrating" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(patterns), "progressing");
});

Deno.test("ADR-0009 amendment: muscle aggregation — one declining + one plateaued + one progressing → muscle declining (declining > plateaued in worst-order)", () => {
  const patterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "declining", confidence: "established" },
    { pattern: "hipHinge", trend: "plateaued", confidence: "established" },
    { pattern: "lunge", trend: "progressing", confidence: "calibrating" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(patterns), "declining");
});

Deno.test("ADR-0009 amendment: muscle aggregation — one pattern plateaued + rest progressing → muscle plateaued", () => {
  const patterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "plateaued", confidence: "established" },
    { pattern: "hipHinge", trend: "progressing", confidence: "established" },
    { pattern: "lunge", trend: "progressing", confidence: "calibrating" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(patterns), "plateaued");
});

Deno.test("ADR-0009 amendment: muscle aggregation — one pattern declining + rest progressing → muscle declining (worst-across-patterns)", () => {
  const patterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "declining", confidence: "established" },
    { pattern: "hipHinge", trend: "progressing", confidence: "established" },
    { pattern: "lunge", trend: "progressing", confidence: "calibrating" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(patterns), "declining");
});

Deno.test("ADR-0009 amendment (2026-05-07): muscle aggregation — all participating patterns progressing → muscle progressing", () => {
  // legs scenario base: 3 patterns all progressing, mixed confidence levels
  // (none bootstrapping → all participate).
  const patterns: PatternTrendForMuscleAggregation[] = [
    { pattern: "squat", trend: "progressing", confidence: "established" },
    { pattern: "hipHinge", trend: "progressing", confidence: "established" },
    { pattern: "lunge", trend: "progressing", confidence: "calibrating" },
  ];
  assertEquals(aggregateMuscleStagnationStatus(patterns), "progressing");
});

Deno.test("ADR-0005 + ADR-0009: architectural commitment — volume-shifted progression must NOT silently plateau (e1RM EWMA spread 1% with avgRPE 7 is flat per the rule, volume-load rising → verdict is 'progressing'; the v1 → v2 hybrid commitment lives or dies on this cell)", () => {
  // The legacy strength-only StagnationService would call this 'plateaued'
  // because the e1RM track is flat. ADR-0009's hybrid two-track verdict
  // exists so volume-shifted progression (e1RM stuck while working sets
  // climb) is correctly read as real progress.
  const e1rmFlatSpread1pct: E1RMSession[] = [
    mkE1RM(99.5, 0, 7),
    mkE1RM(100, 1, 7),
    mkE1RM(100.5, 2, 7),
  ];
  const volumeRising: VolumeLoadSession[] = [
    mkVL(9000, 0),
    mkVL(9500, 1),
    mkVL(10000, 2),
    mkVL(10500, 3),
  ];
  assertEquals(
    plateauVerdict(e1rmFlatSpread1pct, volumeRising, 3.4),
    "progressing",
  );
});

Deno.test("ADR-0009 + design-principles.md: aggregation — any e1RM + volume declining → declining; the {improving e1RM + declining volume} sub-case is the load-bearing Option B precedence lock on the mirror cell (could be peaking phase or overreach precursor; loud-failure preference fires declining either way)", () => {
  const volumeDeclining: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(9000, 3),
  ];
  const e1rmImproving: E1RMSession[] = [
    mkE1RM(95, 0),
    mkE1RM(100, 1),
    mkE1RM(105, 2),
  ];
  const e1rmFlat: E1RMSession[] = [
    mkE1RM(100, 0),
    mkE1RM(100, 1),
    mkE1RM(100, 2),
  ];
  const e1rmDeclining: E1RMSession[] = [
    mkE1RM(100, 0, 7),
    mkE1RM(97.5, 1, 7),
    mkE1RM(95, 2, 7),
  ];
  // Load-bearing precedence lock: peaking-phase or overreach-precursor cell.
  assertEquals(plateauVerdict(e1rmImproving, volumeDeclining, 3.4), "declining");
  assertEquals(plateauVerdict(e1rmFlat, volumeDeclining, 3.4), "declining");
  assertEquals(plateauVerdict(e1rmDeclining, volumeDeclining, 3.4), "declining");
});

Deno.test("ADR-0009 + design-principles.md: aggregation — e1RM declining + any volume → declining; the {declining e1RM + improving volume} sub-case is the load-bearing Option B precedence lock (loud-failure preference resolves the table's conflict cell — silently calling overreach 'progressing' would let fatigue accumulate to crash)", () => {
  const e1rmDeclining: E1RMSession[] = [
    mkE1RM(100, 0, 7),
    mkE1RM(97.5, 1, 7),
    mkE1RM(95, 2, 7),
  ];
  const volumeFlat: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10000, 3),
  ];
  const volumeDeclining: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(9000, 3),
  ];
  const volumeRising: VolumeLoadSession[] = [
    mkVL(9000, 0),
    mkVL(9500, 1),
    mkVL(10000, 2),
    mkVL(10500, 3),
  ];
  assertEquals(plateauVerdict(e1rmDeclining, volumeFlat, 3.4), "declining");
  assertEquals(plateauVerdict(e1rmDeclining, volumeDeclining, 3.4), "declining");
  // Load-bearing precedence lock: the classic overreach signature.
  assertEquals(plateauVerdict(e1rmDeclining, volumeRising, 3.4), "declining");
});

Deno.test("ADR-0009: aggregation — flat + flat → plateaued (the only verdict cell that fires plateau; both tracks must be flat AND-conjunctively)", () => {
  const e1rmFlat: E1RMSession[] = [
    mkE1RM(100, 0),
    mkE1RM(100, 1),
    mkE1RM(100, 2),
  ];
  const volumeFlat: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10000, 3),
  ];
  assertEquals(plateauVerdict(e1rmFlat, volumeFlat, 3.4), "plateaued");
});

Deno.test("ADR-0009: aggregation — flat e1RM + improving volume → progressing (volume-shifted save; the architectural commitment cell is a fixture-of-this-test in cycle 19)", () => {
  // Sub-case: e1RM flat (rep-band stuck) but volume rising — verdict is
  // 'progressing' because volume saves it. Lock for cycle 15.
  // The declining+improving cell of "any e1RM + volume improving" is
  // declining under Option B and is tested in cycle 17.
  const e1rmFlat: E1RMSession[] = [
    mkE1RM(100, 0),
    mkE1RM(100, 1),
    mkE1RM(100, 2),
  ];
  const volumeRising: VolumeLoadSession[] = [
    mkVL(9000, 0),
    mkVL(9500, 1),
    mkVL(10000, 2),
    mkVL(10500, 3),
  ];
  assertEquals(plateauVerdict(e1rmFlat, volumeRising, 3.4), "progressing");
});

Deno.test("ADR-0009: aggregation — e1RM improving + volume {improving | flat} → progressing (rising e1RM is unambiguous progress; volume can be plateau or rising without changing the verdict)", () => {
  // The improving + declining sub-case is locked to 'declining' under Option B
  // (declining-wins precedence per design-principles.md asymmetric-error) and
  // is tested in cycle 18 below — not here.
  const e1rmRising: E1RMSession[] = [
    mkE1RM(95, 0),
    mkE1RM(100, 1),
    mkE1RM(105, 2),
  ];
  const volumeRising: VolumeLoadSession[] = [
    mkVL(9000, 0),
    mkVL(9500, 1),
    mkVL(10000, 2),
    mkVL(10500, 3),
  ];
  const volumeFlat: VolumeLoadSession[] = [
    mkVL(10000, 0),
    mkVL(10000, 1),
    mkVL(10000, 2),
    mkVL(10000, 3),
  ];
  assertEquals(plateauVerdict(e1rmRising, volumeRising, 3.4), "progressing");
  assertEquals(plateauVerdict(e1rmRising, volumeFlat, 3.4), "progressing");
});

Deno.test("ADR-0009: cadence ≤ 3.5d uses 3-session window; > 3.5d uses 4-session window (frequency-scaled)", () => {
  // Fixture distinguishes the two windows by verdict:
  //   suffix-3 = [100, 100, 100] → spread 0%, avgRPE 7 < 8 → flat
  //   suffix-4 = [90, 100, 100, 100] → spread 10/97.5 ≈ 10.26% > 2.5% → improving
  const sessions: E1RMSession[] = [
    mkE1RM(90, 0),
    mkE1RM(100, 1),
    mkE1RM(100, 2),
    mkE1RM(100, 3),
  ];
  assertEquals(e1rmTrack(sessions, 3.4), "flat");
  assertEquals(e1rmTrack(sessions, 3.6), "improving");
});
