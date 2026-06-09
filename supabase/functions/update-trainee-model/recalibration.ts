// Project Apex — capability-driven projection re-calibration (#305, ADR-0023).
//
// Pure helpers for "re-calibrate when capability outgrows the band": when an
// athlete's demonstrated capability (the same recent-window median the floor was
// derived from) has climbed a FULL band-width past their stretch target, the
// projection is re-derived from current capability.
//
// Refines ADR-0021/0005's "floor immovable" to "floor MONOTONIC non-decreasing":
// the floor steps UP only, never above demonstrated capability (round-down
// median, so it still never overstates), and the stretch + progress re-derive
// on top of it. Uses ONLY the individual's own logged lifts — no cohort number.
//
// Idempotency is structural, not bolted-on: newFloor = round-down(current)
// forces current < newFloor + increment ≤ deriveStretch(newFloor) ≤ newStretch,
// so a re-calibrated pattern can never read "achieved" against its new band on
// the next apply — the trigger cannot re-fire until a fresh band-width of growth.
//
// Pure: no I/O, no clock reads.

import {
  currentCapability,
  deriveProgress,
  deriveStretch,
  type PatternProjection,
  PROJECTION_INCREMENT_KG,
  roundTo,
} from "../_shared/calibration-projection.ts";
import type { E1RMSession, ProgressionTrend } from "../_shared/plateau-verdict.ts";

/**
 * True iff demonstrated capability has climbed a full band-width past stretch —
 * i.e. capability is now as far above stretch as stretch was above floor. The
 * threshold is self-relative (the athlete's own band), never an absolute kg or
 * cross-athlete constant.
 */
export function outgrewBand(
  projection: PatternProjection,
  current: number,
): boolean {
  const band = projection.stretch - projection.floor;
  return current >= projection.stretch + band;
}

/**
 * Re-calibrate a projection whose demonstrated capability has outgrown its band.
 * Returns the new {floor, stretch, progress} — floor monotonic non-decreasing,
 * stretch upward-only, progress recomputed against the new band — or null when
 * there is no e1RM signal or the band has not been outgrown.
 */
export function rederiveOutgrownProjection(
  projection: PatternProjection,
  e1rmSessions: E1RMSession[],
  cadenceDays: number | null,
  trend: ProgressionTrend,
): PatternProjection | null {
  const current = currentCapability(e1rmSessions, cadenceDays);
  if (current === null) return null;
  if (!outgrewBand(projection, current)) return null;

  // Floor steps up to demonstrated capability (round-down median → never
  // overstates); monotonic guard keeps it from ever retreating.
  const newFloor = Math.max(
    projection.floor,
    roundTo(current, PROJECTION_INCREMENT_KG, "down"),
  );
  // Upward-only: never lowers a stretch the athlete deliberately raised (#269).
  const newStretch = Math.max(projection.stretch, deriveStretch(newFloor, trend));
  const newProgress = deriveProgress(current, newFloor, newStretch);
  return {
    pattern: projection.pattern,
    floor: newFloor,
    stretch: newStretch,
    progress: newProgress,
  };
}
