// Project Apex — Athlete Twin shadow dual-write (ADR-0031, Phase 1).
//
// The one bridge between the twin and the production Stage-1 pipeline.
// Runs inside the same transaction as every other rule stage, but with a
// hard containment guarantee: THE TWIN NEVER TOUCHES A LIVE DECISION AND
// NEVER BREAKS AN APPLY. Per pattern, any twin failure is caught, logged
// via observability, and leaves that pattern's `twin` block unchanged —
// the legacy fields are computed before this stage and are never read or
// written here except to LOG divergence.
//
// What it writes: `patterns.<key>.twin` — the serialized UKF posterior
// (TwinPatternState). Swift's PatternProfile decoder ignores unknown JSON
// keys, and every pattern-rule stage spreads the existing profile, so the
// block survives the pipeline and the client round-trip untouched.
//
// What it logs, not acts on: divergence between the twin's anchor-exercise
// e1RM (true-capability scale) and the legacy per-exercise EWMA
// (performed-rep scale). NOTE these scales differ by construction (the
// twin includes reported RIR; the EWMA doesn't), so nonzero divergence is
// expected — the log tracks its STABILITY, not its size.
//
// Live-payload caveat (flagged in ADR-0031): session_payload.set_logs
// carries rpe_felt but not rir_estimated, so live shadow observations are
// RPE-derived (coarser noise) until the client payload adds RIR. The
// conversion below reads rir_estimated anyway — forward-compatible.

import {
  canonicalizeExerciseId,
  lookupPattern,
} from "../exercise-library.ts";
import {
  applySessionToPattern,
  posteriorSummary,
  TwinNoUsableDataError,
  type TwinPatternState,
  type TwinSetInput,
} from "./engine.ts";
import {
  emitTwinShadowApplied as defaultEmitApplied,
  emitTwinShadowFailed as defaultEmitFailed,
  type TwinShadowAppliedEvent,
  type TwinShadowFailedEvent,
} from "../observability.ts";

export interface TwinShadowDeps {
  emitApplied?: (event: TwinShadowAppliedEvent) => void;
  emitFailed?: (event: TwinShadowFailedEvent) => void;
}

/**
 * Minimal shape validation for a persisted twin block. Anything invalid is
 * treated as absent (the pattern re-bootstraps) rather than trusted.
 */
function readTwinState(raw: unknown): TwinPatternState | null {
  if (typeof raw !== "object" || raw === null) return null;
  const s = raw as Record<string, unknown>;
  if (s.version !== 1) return null;
  if (typeof s.anchorExerciseId !== "string") return null;
  if (!Array.isArray(s.mean) || !Array.isArray(s.covTriangle)) return null;
  if (!Array.isArray(s.offsetExerciseIds)) return null;
  if (typeof s.lastEventAt !== "string") return null;
  return raw as unknown as TwinPatternState;
}

/**
 * Shadow stage: update each trained pattern's twin posterior from this
 * session's set_logs. Returns the new patterns dict (twin blocks updated)
 * plus the usual rule-pipeline bookkeeping. Never throws.
 */
export function applyTwinShadow(
  patterns: Record<string, Record<string, unknown>>,
  exercises: Record<string, Record<string, unknown>>,
  setLogs: Array<Record<string, unknown>>,
  incomingLoggedAt: Date,
  userId: string,
  deps: TwinShadowDeps = {},
): {
  patterns: Record<string, Record<string, unknown>>;
  rulesFired: Set<string>;
  fieldsChanged: string[];
} {
  const emitApplied = deps.emitApplied ?? defaultEmitApplied;
  const emitFailed = deps.emitFailed ?? defaultEmitFailed;
  const rulesFired = new Set<string>();
  const fieldsChanged: string[] = [];

  // Group this session's sets by pattern, prod-attribution rules.
  const byPattern = new Map<string, TwinSetInput[]>();
  for (const entry of setLogs) {
    const rawId = entry.exercise_id;
    if (typeof rawId !== "string") continue;
    const exerciseId = canonicalizeExerciseId(rawId);
    const pattern = lookupPattern(exerciseId);
    if (!pattern) continue;
    const weightKg = typeof entry.weight_kg === "number" ? entry.weight_kg : null;
    const reps = typeof entry.reps_completed === "number"
      ? entry.reps_completed
      : null;
    const intent = typeof entry.intent === "string" ? entry.intent : null;
    if (weightKg === null || reps === null || intent === null) continue;
    const list = byPattern.get(pattern) ?? [];
    list.push({
      exerciseId,
      weightKg,
      reps,
      rirEstimated: typeof entry.rir_estimated === "number"
        ? entry.rir_estimated
        : null,
      rpeFelt: typeof entry.rpe_felt === "number" ? entry.rpe_felt : null,
      intent,
      loggedAt: incomingLoggedAt,
    });
    byPattern.set(pattern, list);
  }

  const newPatterns = { ...patterns };
  for (const [pattern, sets] of byPattern) {
    const profile = newPatterns[pattern];
    if (profile === undefined) {
      // Pattern profile not bootstrapped by the legacy pipeline (shouldn't
      // happen — applyPerPatternRules runs first) — skip rather than
      // invent a profile shape here.
      continue;
    }
    try {
      const prior = readTwinState(profile.twin);
      const { state, diagnostics } = applySessionToPattern(
        prior,
        sets,
        incomingLoggedAt,
      );
      newPatterns[pattern] = { ...profile, twin: state };
      rulesFired.add("twin-shadow");
      fieldsChanged.push(`patterns.${pattern}.twin`);

      // Divergence log (never acted on). Legacy comparator: the anchor
      // exercise's EWMA e1RM, when present.
      const summary = posteriorSummary(state);
      const twinE1rm = Math.exp(summary.logE1rmAnchor.mean);
      const legacyRaw = exercises[state.anchorExerciseId]?.e1rmCurrent;
      const legacyE1rm = typeof legacyRaw === "number" && legacyRaw > 0
        ? legacyRaw
        : null;
      const meanNis = diagnostics.nisValues.length > 0
        ? diagnostics.nisValues.reduce((a, b) => a + b, 0) /
          diagnostics.nisValues.length
        : null;
      emitApplied({
        user_id: userId,
        pattern,
        anchor_exercise_id: state.anchorExerciseId,
        observations_applied: diagnostics.observationsApplied,
        sets_skipped: diagnostics.setsSkipped,
        bootstrapped: diagnostics.bootstrapped,
        twin_anchor_e1rm: round3(twinE1rm),
        legacy_anchor_e1rm: legacyE1rm !== null ? round3(legacyE1rm) : null,
        divergence_pct: legacyE1rm !== null
          ? round3((twinE1rm - legacyE1rm) / legacyE1rm * 100)
          : null,
        mean_nis: meanNis !== null ? round3(meanNis) : null,
        jitter_incidents: state.jitterIncidents,
      });
    } catch (e) {
      emitFailed({
        user_id: userId,
        pattern,
        error_class: e instanceof TwinNoUsableDataError
          ? "no_usable_sets"
          : e instanceof Error
          ? e.message.slice(0, 200)
          : "unknown",
      });
      // Pattern's twin block left exactly as it was.
    }
  }

  return { patterns: newPatterns, rulesFired, fieldsChanged };
}

function round3(x: number): number {
  return Math.round(x * 1000) / 1000;
}
