// Project Apex — Athlete Twin backtest runner (ADR-0031, Phase 1 shadow).
//
// Replays each user's full set_logs history chronologically through BOTH
// brains and scores next-session top-set reps-at-load:
//
//   incumbent      — prod-faithful per-exercise EWMA (point forecast;
//                    CRPS = absolute error by the σ→0 limit)
//   incumbent-dressed — same point + Gaussian sd from the expanding-window
//                    RMSE of its OWN past errors on the pattern (fair
//                    distributional null)
//   incumbent-clean — EWMA excluding weight-0 top sets (so the comparison
//                    is not won on prod's bodyweight-at-0kg quirk)
//   twin           — per-pattern UKF posterior predictive (mean + sd)
//
// A transition is scored ONLY when the twin state exists AND the plain
// incumbent can forecast the target exercise (both-must-forecast: no model
// gets credit for transitions the other cannot enter). Twin-only coverage
// is counted separately as the pooling advantage.
//
// The pure core (runBacktest) is deterministic — the CLI runs it TWICE and
// asserts byte-identical reports (the determinism gate).
//
// CLI: deno run --allow-read run.ts <export.json> [--out report.json]

import { buildReplay, type ExportedRow, type ReplayUser } from "./replay.ts";
import {
  incumbentApplySession,
  incumbentE1rm,
  incumbentForecastReps,
  type IncumbentState,
  newIncumbentState,
} from "./incumbent.ts";
import {
  applySessionToPattern,
  forecastPreparedLogE1rm,
  forecastTopSet,
  posteriorSummary,
  TwinNoUsableDataError,
  type TwinPatternState,
} from "../engine.ts";
import {
  censoredGaussianCrps,
  censoredInCentral90,
  gaussianCrps,
  inCentral90,
  mean,
  pairedBootstrapCi,
  type BootstrapCi,
} from "./scoring.ts";
import {
  EXERCISE_OFFSET_INIT_SD,
  REP_SLOPE_PRIOR_LOG_MEAN,
  REP_SLOPE_PRIOR_LOG_SD,
  TREND_PRIOR_SD,
} from "../model.ts";

// ── Per-transition record ────────────────────────────────────────────────────

export interface ScoredTransition {
  userId: string;
  pattern: string;
  sessionIndex: number;
  exerciseId: string;
  weightKg: number;
  actualReps: number;
  ewmaPoint: number;
  ewmaCleanPoint: number | null;
  ewmaDressedSd: number;
  /** Twin point forecast (censored mean). */
  twinMean: number;
  /** Underlying (uncensored) Gaussian mean/sd + rep-habit cap. */
  twinMu: number;
  twinSd: number;
  twinCap: number | null;
  twinExerciseUnseen: boolean;
  /**
   * Rep-habit null: running mean/sd of this pattern's PAST target reps —
   * a load-blind baseline. In a program whose athletes pick loads to land
   * a target rep count, this null is strong by construction; a twin that
   * only matched EWMA but lost to this would have no real edge.
   */
  habitMean: number;
  habitSd: number;
  /**
   * Load stratum: "repeat" (target load within ±5% of this exercise's
   * previous top-set load), "changed" (≥5% move), or "new" (no previous
   * top set on this exercise). The habit null is load-blind, so the
   * "changed" stratum is where a capability model must earn its keep.
   */
  loadStratum: "repeat" | "changed" | "new";
  /**
   * ADDENDUM observable — next-session top-set LOAD (kg), the
   * prescription-shaped forecast (reps-at-load is degenerate under
   * rep-target training; the load trajectory is where capability signal
   * lives). All three forecasters share the SAME rep-target estimate
   * (the pattern's rep-habit mean), isolating the capability model:
   *   lastLoad — carry forward the exercise's previous top-set load
   *   ewmaLoad — invert the EWMA e1RM at the shared rep target
   *   twinLoad — invert the twin's prepared e1RM at the shared rep
   *              target + stopping RIR through the personal rep slope
   * Null when the exercise has no previous top set (lastLoad undefined).
   */
  lastLoadPred: number | null;
  ewmaLoadPred: number | null;
  twinLoadPred: number | null;
}

export interface PatternMetrics {
  pattern: string;
  n: number;
  maeEwma: number;
  maeEwmaClean: number | null;
  maeHabit: number;
  maeTwin: number;
  crpsEwmaPoint: number;
  crpsEwmaDressed: number;
  crpsHabit: number;
  crpsTwin: number;
  coverage90Twin: number;
  coverage90Dressed: number;
  coverage90Habit: number;
  meanTwinSd: number;
  twinCloserCount: number;
  ewmaCloserCount: number;
  tieCount: number;
  maeDeltaCi: BootstrapCi | null; // |ewma err| − |twin err|, + favors twin
  crpsDeltaCi: BootstrapCi | null; // dressed crps − twin crps, + favors twin
  maeDeltaVsHabitCi: BootstrapCi | null; // |habit err| − |twin err|
  crpsDeltaVsHabitCi: BootstrapCi | null; // habit crps − twin crps
}

export interface LoadForecastMetrics {
  pattern: string;
  n: number;
  maeKgLastLoad: number;
  maeKgEwma: number;
  maeKgTwin: number;
  mapeLastLoad: number;
  mapeEwma: number;
  mapeTwin: number;
  /** |lastLoad err| − |twin err| in kg, + favors twin (paired bootstrap). */
  maeDeltaVsLastLoadCi: BootstrapCi | null;
}

export interface IdentifiabilityEntry {
  userId: string;
  pattern: string;
  observationCount: number;
  sessionsSeen: number;
  trend: { mean: number; sd: number; priorSd: number; learned: boolean };
  repSlope: {
    rho: number;
    logSd: number;
    priorLogSd: number;
    movedSds: number;
    learned: boolean;
  };
  offsets: Array<{
    exerciseId: string;
    sd: number;
    priorSd: number;
    learned: boolean;
  }>;
  meanNis: number | null;
  nisCount: number;
  jitterIncidents: number;
}

export interface BacktestReport {
  transitions: ScoredTransition[];
  perPattern: PatternMetrics[];
  overall: PatternMetrics;
  /** Same metrics stratified by load stratum (repeat / changed / new). */
  byLoadStratum: PatternMetrics[];
  /** ADDENDUM: next-session top-set LOAD forecast (kg), three forecasters. */
  loadForecast: LoadForecastMetrics[];
  identifiability: IdentifiabilityEntry[];
  skipped: {
    twinNotBootstrapped: number;
    ewmaNoHistory: number;
    bothUnavailable: number;
    twinOnlyForecastable: number;
  };
  userCount: number;
  sessionCount: number;
}

// ── Core ─────────────────────────────────────────────────────────────────────

interface PatternErrorTrack {
  /** Squared errors of the plain incumbent's past forecasts (this pattern). */
  sqErrors: number[];
}

/** Cold-start sd for the dressed incumbent before 3 observed errors. */
const DRESSED_COLD_SD = 2.5;
const DRESSED_MIN_N = 3;

function dressedSd(track: PatternErrorTrack): number {
  if (track.sqErrors.length < DRESSED_MIN_N) return DRESSED_COLD_SD;
  return Math.sqrt(mean(track.sqErrors));
}

/** Rep-habit null: running mean/sd of past target reps for the pattern. */
interface HabitTrack {
  reps: number[];
}

const HABIT_COLD_MEAN = 9;
const HABIT_COLD_SD = 2.5;
const HABIT_MIN_SD = 1.0;

function habitForecast(track: HabitTrack): { mean: number; sd: number } {
  const n = track.reps.length;
  if (n < 2) return { mean: HABIT_COLD_MEAN, sd: HABIT_COLD_SD };
  const m = mean(track.reps);
  const varB = track.reps.reduce((a, r) => a + (r - m) ** 2, 0) / (n - 1);
  return { mean: m, sd: Math.max(Math.sqrt(varB), HABIT_MIN_SD) };
}

export function runBacktest(rows: ExportedRow[]): BacktestReport {
  const users: ReplayUser[] = buildReplay(rows);
  const transitions: ScoredTransition[] = [];
  const identifiability: IdentifiabilityEntry[] = [];
  const skipped = {
    twinNotBootstrapped: 0,
    ewmaNoHistory: 0,
    bothUnavailable: 0,
    twinOnlyForecastable: 0,
  };
  let sessionCount = 0;

  for (const user of users) {
    const incumbent: IncumbentState = newIncumbentState();
    const incumbentClean: IncumbentState = newIncumbentState();
    const twins = new Map<string, TwinPatternState>();
    const twinSessionsSeen = new Map<string, number>();
    const twinNis = new Map<string, number[]>();
    const errTracks = new Map<string, PatternErrorTrack>();
    const habitTracks = new Map<string, HabitTrack>();
    const lastTopWeight = new Map<string, number>();

    for (let si = 0; si < user.sessions.length; si++) {
      const session = user.sessions[si];
      sessionCount++;

      // ── Forecast phase (state as of BEFORE this session) ──
      for (const [pattern, target] of session.patternTargets) {
        const twinState = twins.get(pattern) ?? null;
        const ewmaPoint = incumbentForecastReps(
          incumbent,
          target.exerciseId,
          target.weightKg,
        );
        if (twinState === null && ewmaPoint === null) {
          skipped.bothUnavailable++;
          continue;
        }
        if (twinState === null) {
          skipped.twinNotBootstrapped++;
          continue;
        }
        if (ewmaPoint === null) {
          // The twin could forecast here via pattern pooling; the incumbent
          // cannot enter. Counted, not scored (both-must-forecast).
          skipped.ewmaNoHistory++;
          skipped.twinOnlyForecastable++;
          continue;
        }
        const twinF = forecastTopSet(
          twinState,
          target.exerciseId,
          target.weightKg,
          target.loggedAt,
        );
        if (twinF === null) continue;
        const track = errTracks.get(pattern) ?? { sqErrors: [] };
        errTracks.set(pattern, track);
        const habitTrack = habitTracks.get(pattern) ?? { reps: [] };
        habitTracks.set(pattern, habitTrack);
        const habit = habitForecast(habitTrack);
        const ewmaCleanPoint = incumbentForecastReps(
          incumbentClean,
          target.exerciseId,
          target.weightKg,
        );
        const prevW = lastTopWeight.get(target.exerciseId);
        const loadStratum: "repeat" | "changed" | "new" = prevW === undefined
          ? "new"
          : Math.abs(target.weightKg - prevW) / prevW >= 0.05
          ? "changed"
          : "repeat";
        // Load-forecast addendum: all three share habit.mean as rep target.
        const ewmaE1 = incumbentE1rm(incumbent, target.exerciseId);
        const ewmaLoadPred = ewmaE1 !== null
          ? ewmaE1 / (1 + habit.mean / 30)
          : null;
        const twinCap = forecastPreparedLogE1rm(
          twinState,
          target.exerciseId,
          target.loggedAt,
        );
        const twinLoadPred = twinCap !== null
          ? Math.exp(twinCap.logMean) /
            (1 + (habit.mean + twinCap.stopRirMean) / twinCap.repSlope)
          : null;
        transitions.push({
          userId: user.userId,
          pattern,
          sessionIndex: si,
          exerciseId: target.exerciseId,
          weightKg: target.weightKg,
          actualReps: target.actualReps,
          ewmaPoint,
          ewmaCleanPoint,
          ewmaDressedSd: dressedSd(track),
          twinMean: twinF.repsMean,
          twinMu: twinF.repsMu,
          twinSd: twinF.repsSd,
          twinCap: twinF.repCap,
          twinExerciseUnseen: twinF.exerciseUnseen,
          habitMean: habit.mean,
          habitSd: habit.sd,
          loadStratum,
          lastLoadPred: prevW ?? null,
          ewmaLoadPred,
          twinLoadPred,
        });
        // Both online baselines' histories grow AFTER forecasting.
        track.sqErrors.push((target.actualReps - ewmaPoint) ** 2);
        habitTrack.reps.push(target.actualReps);
      }

      // Track last top-set weight per exercise for the load stratum of
      // FUTURE transitions (uses every session's targets, scored or not).
      for (const target of session.patternTargets.values()) {
        lastTopWeight.set(target.exerciseId, target.weightKg);
      }

      // ── Apply phase ──
      const incumbentSets = session.allSets.map((s) => ({
        exerciseId: s.exerciseId,
        weightKg: s.weightKg,
        reps: s.reps,
        intent: s.intent,
      }));
      incumbentApplySession(
        incumbent,
        incumbentSets,
        session.endedAt,
        session.sessionId,
        false,
      );
      incumbentApplySession(
        incumbentClean,
        incumbentSets,
        session.endedAt,
        session.sessionId,
        true,
      );
      for (const [pattern, sets] of session.patternSets) {
        const twinInput = sets.map((s) => ({
          exerciseId: s.exerciseId,
          weightKg: s.weightKg,
          reps: s.reps,
          rirEstimated: s.rirEstimated,
          rpeFelt: s.rpeFelt,
          intent: s.intent,
          loggedAt: s.loggedAt,
        }));
        try {
          const res = applySessionToPattern(
            twins.get(pattern) ?? null,
            twinInput,
            session.endedAt,
          );
          twins.set(pattern, res.state);
          twinSessionsSeen.set(
            pattern,
            (twinSessionsSeen.get(pattern) ?? 0) + 1,
          );
          const nis = twinNis.get(pattern) ?? [];
          nis.push(...res.diagnostics.nisValues);
          twinNis.set(pattern, nis);
        } catch (e) {
          if (e instanceof TwinNoUsableDataError) {
            // Pattern still cold — no usable sets yet.
            continue;
          }
          throw e;
        }
      }
    }

    // ── Identifiability audit for this user ──
    for (const [pattern, state] of twins) {
      const summary = posteriorSummary(state);
      const nis = twinNis.get(pattern) ?? [];
      // Trend is a DYNAMIC state (process noise re-inflates it between
      // sessions), so sd-shrinkage is the wrong learning criterion; use
      // signal detection instead: is the posterior decisively away from 0?
      const trendLearned =
        Math.abs(summary.trendPerDay.mean) / summary.trendPerDay.sd > 1.645;
      const rhoMoved = Math.abs(
        Math.log(summary.repSlope.mean) - REP_SLOPE_PRIOR_LOG_MEAN,
      ) / REP_SLOPE_PRIOR_LOG_SD;
      identifiability.push({
        userId: user.userId,
        pattern,
        observationCount: state.observationCount,
        sessionsSeen: twinSessionsSeen.get(pattern) ?? 0,
        trend: {
          mean: summary.trendPerDay.mean,
          sd: summary.trendPerDay.sd,
          priorSd: TREND_PRIOR_SD,
          learned: trendLearned,
        },
        repSlope: {
          rho: summary.repSlope.mean,
          logSd: summary.repSlope.sd,
          priorLogSd: REP_SLOPE_PRIOR_LOG_SD,
          movedSds: rhoMoved,
          learned: summary.repSlope.sd < 0.7 * REP_SLOPE_PRIOR_LOG_SD,
        },
        offsets: summary.offsets.map((o) => ({
          exerciseId: o.exerciseId,
          sd: o.sd,
          priorSd: EXERCISE_OFFSET_INIT_SD,
          learned: o.sd < 0.7 * EXERCISE_OFFSET_INIT_SD,
        })),
        meanNis: nis.length > 0 ? mean(nis) : null,
        nisCount: nis.length,
        jitterIncidents: state.jitterIncidents,
      });
    }
  }

  // ── Aggregate metrics ──
  const patterns = [...new Set(transitions.map((t) => t.pattern))].sort();
  const perPattern = patterns.map((p, i) =>
    metricsFor(p, transitions.filter((t) => t.pattern === p), 9000 + i)
  );
  const overall = metricsFor("ALL", transitions, 8999);
  const byLoadStratum = (["repeat", "changed", "new"] as const).map((s, i) =>
    metricsFor(
      `load-${s}`,
      transitions.filter((t) => t.loadStratum === s),
      9500 + i,
    )
  ).filter((m) => m.n > 0);

  const loadScorable = transitions.filter((t) =>
    t.lastLoadPred !== null && t.ewmaLoadPred !== null &&
    t.twinLoadPred !== null
  );
  const loadForecast = [
    ...patterns.map((p, i) =>
      loadMetricsFor(
        p,
        loadScorable.filter((t) => t.pattern === p),
        9700 + i,
      )
    ),
    loadMetricsFor("ALL", loadScorable, 9699),
  ].filter((m) => m.n > 0);

  identifiability.sort((a, b) =>
    a.userId.localeCompare(b.userId) || a.pattern.localeCompare(b.pattern)
  );

  return {
    transitions,
    perPattern,
    overall,
    byLoadStratum,
    loadForecast,
    identifiability,
    skipped,
    userCount: users.length,
    sessionCount,
  };
}

function loadMetricsFor(
  pattern: string,
  ts: ScoredTransition[],
  seed: number,
): LoadForecastMetrics {
  const errLast = ts.map((t) => Math.abs(t.weightKg - t.lastLoadPred!));
  const errEwma = ts.map((t) => Math.abs(t.weightKg - t.ewmaLoadPred!));
  const errTwin = ts.map((t) => Math.abs(t.weightKg - t.twinLoadPred!));
  const pct = (errs: number[]) =>
    mean(errs.map((e, i) => e / ts[i].weightKg));
  return {
    pattern,
    n: ts.length,
    maeKgLastLoad: mean(errLast),
    maeKgEwma: mean(errEwma),
    maeKgTwin: mean(errTwin),
    mapeLastLoad: pct(errLast),
    mapeEwma: pct(errEwma),
    mapeTwin: pct(errTwin),
    maeDeltaVsLastLoadCi: pairedBootstrapCi(
      ts.map((_, i) => errLast[i] - errTwin[i]),
      seed,
    ),
  };
}

function metricsFor(
  pattern: string,
  ts: ScoredTransition[],
  seed: number,
): PatternMetrics {
  const absErrEwma = ts.map((t) => Math.abs(t.actualReps - t.ewmaPoint));
  const absErrHabit = ts.map((t) => Math.abs(t.actualReps - t.habitMean));
  const absErrTwin = ts.map((t) => Math.abs(t.actualReps - t.twinMean));
  const cleanTs = ts.filter((t) => t.ewmaCleanPoint !== null);
  const crpsDressed = ts.map((t) =>
    gaussianCrps(t.actualReps, t.ewmaPoint, t.ewmaDressedSd)
  );
  const crpsHabit = ts.map((t) =>
    gaussianCrps(t.actualReps, t.habitMean, t.habitSd)
  );
  const crpsTwin = ts.map((t) =>
    censoredGaussianCrps(t.actualReps, t.twinMu, t.twinSd, t.twinCap)
  );
  let twinCloser = 0, ewmaCloser = 0, tie = 0;
  for (let i = 0; i < ts.length; i++) {
    const d = absErrEwma[i] - absErrTwin[i];
    if (Math.abs(d) < 1e-9) tie++;
    else if (d > 0) twinCloser++;
    else ewmaCloser++;
  }
  return {
    pattern,
    n: ts.length,
    maeEwma: mean(absErrEwma),
    maeEwmaClean: cleanTs.length > 0
      ? mean(cleanTs.map((t) => Math.abs(t.actualReps - t.ewmaCleanPoint!)))
      : null,
    maeHabit: mean(absErrHabit),
    maeTwin: mean(absErrTwin),
    crpsEwmaPoint: mean(absErrEwma),
    crpsEwmaDressed: mean(crpsDressed),
    crpsHabit: mean(crpsHabit),
    crpsTwin: mean(crpsTwin),
    coverage90Twin: ts.length > 0
      ? ts.filter((t) =>
        censoredInCentral90(t.actualReps, t.twinMu, t.twinSd, t.twinCap)
      ).length /
        ts.length
      : NaN,
    coverage90Dressed: ts.length > 0
      ? ts.filter((t) =>
        inCentral90(t.actualReps, t.ewmaPoint, t.ewmaDressedSd)
      ).length / ts.length
      : NaN,
    coverage90Habit: ts.length > 0
      ? ts.filter((t) => inCentral90(t.actualReps, t.habitMean, t.habitSd))
        .length / ts.length
      : NaN,
    meanTwinSd: mean(ts.map((t) => t.twinSd)),
    twinCloserCount: twinCloser,
    ewmaCloserCount: ewmaCloser,
    tieCount: tie,
    maeDeltaCi: pairedBootstrapCi(
      ts.map((_, i) => absErrEwma[i] - absErrTwin[i]),
      seed,
    ),
    crpsDeltaCi: pairedBootstrapCi(
      ts.map((_, i) => crpsDressed[i] - crpsTwin[i]),
      seed + 1,
    ),
    maeDeltaVsHabitCi: pairedBootstrapCi(
      ts.map((_, i) => absErrHabit[i] - absErrTwin[i]),
      seed + 2,
    ),
    crpsDeltaVsHabitCi: pairedBootstrapCi(
      ts.map((_, i) => crpsHabit[i] - crpsTwin[i]),
      seed + 3,
    ),
  };
}

// ── Report rendering ─────────────────────────────────────────────────────────

function fmt(x: number | null | undefined, digits = 2): string {
  if (x === null || x === undefined || Number.isNaN(x)) return "—";
  return x.toFixed(digits);
}

export function renderReport(report: BacktestReport): string {
  const lines: string[] = [];
  lines.push(
    `# Twin-vs-EWMA backtest — ${report.userCount} users, ${report.sessionCount} sessions, ${report.transitions.length} scored transitions`,
  );
  lines.push("");
  lines.push(
    "| pattern | n | MAE ewma | MAE habit | MAE twin | ΔMAE v ewma [CI] | ΔMAE v habit [CI] | CRPS dressed | CRPS habit | CRPS twin | ΔCRPS v habit [CI] | cov90 twin | cov90 habit | twin/ewma closer |",
  );
  lines.push("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|");
  for (const m of [...report.perPattern, report.overall]) {
    const ci = (c: BootstrapCi | null) =>
      c ? `${fmt(c.meanDelta)} [${fmt(c.lo95)}, ${fmt(c.hi95)}]` : "—";
    lines.push(
      `| ${m.pattern} | ${m.n} | ${fmt(m.maeEwma)} | ${fmt(m.maeHabit)} | ${
        fmt(m.maeTwin)
      } | ${ci(m.maeDeltaCi)} | ${ci(m.maeDeltaVsHabitCi)} | ${
        fmt(m.crpsEwmaDressed)
      } | ${fmt(m.crpsHabit)} | ${fmt(m.crpsTwin)} | ${
        ci(m.crpsDeltaVsHabitCi)
      } | ${fmt(m.coverage90Twin, 3)} | ${fmt(m.coverage90Habit, 3)} | ${m.twinCloserCount}/${m.ewmaCloserCount} (${m.tieCount} tie) |`,
    );
  }
  lines.push("");
  lines.push(
    "## By load stratum (the habit null is load-blind — 'changed' is where a capability model must earn its keep)",
  );
  lines.push(
    "| stratum | n | MAE ewma | MAE habit | MAE twin | ΔMAE v habit [CI] | CRPS habit | CRPS twin | ΔCRPS v habit [CI] | cov90 twin |",
  );
  lines.push("|---|---|---|---|---|---|---|---|---|---|");
  for (const m of report.byLoadStratum) {
    const ci = (c: BootstrapCi | null) =>
      c ? `${fmt(c.meanDelta)} [${fmt(c.lo95)}, ${fmt(c.hi95)}]` : "—";
    lines.push(
      `| ${m.pattern} | ${m.n} | ${fmt(m.maeEwma)} | ${fmt(m.maeHabit)} | ${
        fmt(m.maeTwin)
      } | ${ci(m.maeDeltaVsHabitCi)} | ${fmt(m.crpsHabit)} | ${
        fmt(m.crpsTwin)
      } | ${ci(m.crpsDeltaVsHabitCi)} | ${fmt(m.coverage90Twin, 3)} |`,
    );
  }
  lines.push("");
  lines.push(
    "## ADDENDUM — next-session top-set LOAD forecast (kg): the prescription-shaped observable",
  );
  lines.push(
    "| pattern | n | MAE last-load | MAE ewma-inv | MAE twin-inv | MAPE last | MAPE ewma | MAPE twin | ΔMAE v last-load [CI] |",
  );
  lines.push("|---|---|---|---|---|---|---|---|---|");
  for (const m of report.loadForecast) {
    const ci = m.maeDeltaVsLastLoadCi;
    lines.push(
      `| ${m.pattern} | ${m.n} | ${fmt(m.maeKgLastLoad)} | ${
        fmt(m.maeKgEwma)
      } | ${fmt(m.maeKgTwin)} | ${fmt(m.mapeLastLoad * 100, 1)}% | ${
        fmt(m.mapeEwma * 100, 1)
      }% | ${fmt(m.mapeTwin * 100, 1)}% | ${
        ci ? `${fmt(ci.meanDelta)} [${fmt(ci.lo95)}, ${fmt(ci.hi95)}]` : "—"
      } |`,
    );
  }
  lines.push("");
  lines.push("## Skips");
  lines.push(
    `- twin not yet bootstrapped: ${report.skipped.twinNotBootstrapped}`,
  );
  lines.push(
    `- incumbent lacked exercise history (twin could pool): ${report.skipped.ewmaNoHistory}`,
  );
  lines.push(`- both unavailable (first touch): ${report.skipped.bothUnavailable}`);
  lines.push("");
  lines.push("## Identifiability (per user × pattern)");
  lines.push(
    "| user | pattern | sess | obs | trend/day (sd) | learned? | ρ (log-sd) | moved σ | learned? | offsets learned | mean NIS | jitter |",
  );
  lines.push("|---|---|---|---|---|---|---|---|---|---|---|---|");
  for (const e of report.identifiability) {
    const offLearned = e.offsets.filter((o) => o.learned).length;
    lines.push(
      `| ${e.userId.slice(0, 8)} | ${e.pattern} | ${e.sessionsSeen} | ${e.observationCount} | ${
        e.trend.mean.toExponential(2)
      } (${e.trend.sd.toExponential(2)}) | ${e.trend.learned ? "YES" : "no"} | ${
        fmt(e.repSlope.rho, 1)
      } (${fmt(e.repSlope.logSd, 3)}) | ${fmt(e.repSlope.movedSds, 2)} | ${
        e.repSlope.learned ? "YES" : "no"
      } | ${offLearned}/${e.offsets.length} | ${fmt(e.meanNis, 2)} | ${e.jitterIncidents} |`,
    );
  }
  return lines.join("\n");
}

// ── CLI ──────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  const [dataPath, ...rest] = Deno.args;
  if (!dataPath) {
    console.error(
      "usage: deno run --allow-read --allow-write run.ts <export.json> [--out report.json]",
    );
    Deno.exit(2);
  }
  const raw = JSON.parse(Deno.readTextFileSync(dataPath));
  const rows: ExportedRow[] = raw.rows ?? raw;

  const report = runBacktest(rows);
  // Determinism gate: a second full run must be byte-identical.
  const second = runBacktest(rows);
  const deterministic = JSON.stringify(report) === JSON.stringify(second);

  console.log(renderReport(report));
  console.log("");
  console.log(
    `## Determinism: same inputs → same report: ${deterministic ? "PASS" : "FAIL"}`,
  );
  if (!deterministic) Deno.exit(1);

  const outIdx = rest.indexOf("--out");
  if (outIdx >= 0 && rest[outIdx + 1]) {
    Deno.writeTextFileSync(
      rest[outIdx + 1],
      JSON.stringify(report, null, 2),
    );
    console.log(`\nreport JSON → ${rest[outIdx + 1]}`);
  }
}
