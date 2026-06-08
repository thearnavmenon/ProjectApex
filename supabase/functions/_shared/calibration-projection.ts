// Project Apex — calibration-review projection derivation (#294, Part of #269).
//
// Pure helpers that derive per-pattern capability targets at calibration review
// (ADR-0005 §projections; design pinned during the #269 grilling). Floor =
// recent demonstrated capability (immovable); stretch = an upward, trend-scaled
// target (user-adjustable upward only); progress = where current capability
// sits between them.
//
// Uses ONLY live inputs — the per-pattern Epley e1RM session series, the
// pattern's cadence, and its trend. `ExerciseProfile.e1rmMedian`/`e1rmPeak` are
// dead fields (never written) and must not be used.
//
// Pure: no I/O, no clock reads.

import type { E1RMSession, ProgressionTrend } from "./plateau-verdict.ts";
import { windowSize } from "./plateau-verdict.ts";

/** `ProjectionProgress` raw values — must mirror the Swift enum. */
export type ProjectionProgress = "behind" | "on_track" | "ahead" | "achieved";

export interface PatternProjection {
  pattern: string;
  floor: number;
  stretch: number;
  progress: ProjectionProgress;
}

/** Plate increment all projection numbers round to (kg). */
export const PROJECTION_INCREMENT_KG = 2.5;

/** Trend-scaled stretch margin over the floor (ADR-0005 §projections, #269). */
export const STRETCH_MARGIN_BY_TREND: Record<ProgressionTrend, number> = {
  progressing: 0.075,
  plateaued: 0.04,
  declining: 0.025,
};

/** Calibration review fires once ≥ this many of the 6 major patterns establish. */
export const CALIBRATION_REVIEW_MIN_ESTABLISHED_MAJORS = 4;

function roundTo(value: number, increment: number, dir: "down" | "up"): number {
  const q = value / increment;
  return (dir === "down" ? Math.floor(q) : Math.ceil(q)) * increment;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
}

/**
 * Recent demonstrated capability for a pattern: the median of the heaviest-
 * e1RM-per-session over the last `windowSize(cadence)` sessions (the same
 * window the trend engine uses). Returns null when there is no e1RM history.
 */
export function currentCapability(
  e1rmSessions: E1RMSession[],
  cadenceDays: number | null,
): number | null {
  if (e1rmSessions.length === 0) return null;
  const ordered = [...e1rmSessions].sort(
    (a, b) => a.loggedAt.getTime() - b.loggedAt.getTime(),
  );
  const window = ordered.slice(-windowSize(cadenceDays)).map((s) => s.e1rm);
  return median(window);
}

/** Floor = round-down-to-increment of the recent capability (never overstates). */
export function deriveFloor(
  e1rmSessions: E1RMSession[],
  cadenceDays: number | null,
): number | null {
  const capability = currentCapability(e1rmSessions, cadenceDays);
  if (capability === null) return null;
  return roundTo(capability, PROJECTION_INCREMENT_KG, "down");
}

/** Stretch = round-up of floor × (1 + margin(trend)); always ≥ floor + 1 increment. */
export function deriveStretch(floor: number, trend: ProgressionTrend): number {
  const raw = floor * (1 + STRETCH_MARGIN_BY_TREND[trend]);
  const rounded = roundTo(raw, PROJECTION_INCREMENT_KG, "up");
  return Math.max(rounded, floor + PROJECTION_INCREMENT_KG);
}

/** Progress of `current` within the floor→stretch band. */
export function deriveProgress(
  current: number,
  floor: number,
  stretch: number,
): ProjectionProgress {
  if (current < floor) return "behind";
  if (current >= stretch) return "achieved";
  const pos = (current - floor) / (stretch - floor);
  return pos < 0.5 ? "on_track" : "ahead";
}

/**
 * Derive a full projection for one pattern from its live signal. Returns null
 * when there is no e1RM history to anchor the floor (the pattern then simply
 * gets no projection this apply — it is picked up lazily once it has history).
 */
export function deriveProjection(
  pattern: string,
  e1rmSessions: E1RMSession[],
  cadenceDays: number | null,
  trend: ProgressionTrend,
): PatternProjection | null {
  const capability = currentCapability(e1rmSessions, cadenceDays);
  if (capability === null) return null;
  const floor = roundTo(capability, PROJECTION_INCREMENT_KG, "down");
  const stretch = deriveStretch(floor, trend);
  const progress = deriveProgress(capability, floor, stretch);
  return { pattern, floor, stretch, progress };
}
