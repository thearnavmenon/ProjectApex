// Project Apex — Phase 2 recovery-curve.
//
// Per ADR-0010 (recovery readiness curves and time constants), per-axis
// readiness is a pure function of hours since the last stimulus event:
//
//   readiness(t) = clamp(0, 1, RESIDUAL_FLOOR + (1 - RESIDUAL_FLOOR) × (1 - exp(-t / tau)))
//
// The residual floor (0.3) captures that the lifter is not at zero
// readiness immediately post-stimulus (ADR-0010 §"residual floor").
// NM tau is 30h; metabolic tau is 12h — metabolic clears ~2.5× faster
// (ADR-0010 §"time constants", asymmetric-error preference under-counts
// recovery → loud RPE drift; over-counts → quieter, easier to correct).
//
// Pure: `readinessCurve` has no side effects. The `readiness` wrapper
// invokes #74's `emitClockSkew` helper when given future-dated
// `lastStimulusAt` — clock skew at non-trivial rates is a data-integrity
// signal worth surfacing.

import {
  RECOVERY_RESIDUAL_FLOOR,
  RECOVERY_TAU_METABOLIC_HOURS,
  RECOVERY_TAU_NM_HOURS,
} from "./constants.ts";
import { emitClockSkew } from "./observability.ts";

export type RecoveryAxis = "neuromuscular" | "metabolic";

const MS_PER_HOUR = 60 * 60 * 1000;

const TAU_BY_AXIS: Record<RecoveryAxis, number> = {
  neuromuscular: RECOVERY_TAU_NM_HOURS,
  metabolic: RECOVERY_TAU_METABOLIC_HOURS,
};

/**
 * Pure readiness curve per ADR-0010. No clock-skew detection or logging
 * — see `readiness` for the wrapper that handles those.
 */
export function readinessCurve(tHours: number, tauHours: number): number {
  const t = Math.max(0, tHours);
  const value = RECOVERY_RESIDUAL_FLOOR +
    (1 - RECOVERY_RESIDUAL_FLOOR) * (1 - Math.exp(-t / tauHours));
  return Math.max(0, Math.min(1, value));
}

/**
 * Per-axis recovery readiness. Edge cases (ADR-0010 §"edge cases"):
 *   - lastStimulusAt === null → 1.0 (brand-new user, fully recovered).
 *   - Future-dated lastStimulusAt → t clamps to 0 (readiness = residual
 *     floor) and `recovery.clock_skew` is emitted via #74's helper.
 *     Clock skew at non-trivial rates is a data-integrity signal.
 */
export function readiness(
  axis: RecoveryAxis,
  lastStimulusAt: Date | null,
  now: Date,
  context: { userId: string },
): number {
  if (lastStimulusAt === null) return 1.0;
  const deltaMs = now.getTime() - lastStimulusAt.getTime();
  if (deltaMs < 0) {
    emitClockSkew({
      user_id: context.userId,
      last_stimulus_at: lastStimulusAt.toISOString(),
      now: now.toISOString(),
      delta_seconds: -deltaMs / 1000,
    });
  }
  const tHours = Math.max(0, deltaMs) / MS_PER_HOUR;
  return readinessCurve(tHours, TAU_BY_AXIS[axis]);
}
