// Project Apex — Athlete Twin backtest (ADR-0031, Phase 1 shadow).
//
// Replay-stream builder: turns exported set_logs rows (joined with their
// workout_sessions) into per-user chronological session streams with
// per-pattern set groups and per-pattern scoring targets.
//
// Pattern attribution uses the SAME canonicalization + lookup the Edge
// Function uses (exercise-library.ts), so the replay sees exactly what
// production attribution would see.
//
// The scoring target for a (session, pattern) is the session's TOP SET:
// among intent=="top" sets with reps in the 3..10 validity window and
// weight > 0, the one with the highest Epley e1RM. Sessions without such
// a set feed the models but are not scored. Weight-0 "top" sets (bodyweight
// movements logged at 0 kg) are excluded from TARGETS — "reps at load 0"
// is not a well-defined forecast — but still flow into each model's inputs
// per that model's own rules (the incumbent ingests them exactly as prod
// does today; the twin skips them).
//
// Pure: no I/O — callers load the JSON and pass rows in.

import {
  canonicalizeExerciseId,
  lookupPattern,
} from "../../exercise-library.ts";

export interface ExportedRow {
  user_id: string;
  session_id: string;
  session_date: string;
  exercise_id: string;
  set_number: number;
  weight_kg: number;
  reps_completed: number;
  rpe_felt: number | null;
  rir_estimated: number | null;
  logged_at: string;
  intent: string;
}

export interface ReplaySet {
  exerciseId: string; // canonical
  weightKg: number;
  reps: number;
  rpeFelt: number | null;
  rirEstimated: number | null;
  intent: string;
  loggedAt: Date;
}

export interface ReplayTarget {
  exerciseId: string;
  weightKg: number;
  actualReps: number;
  loggedAt: Date;
}

export interface ReplaySession {
  sessionId: string;
  /** First set's loggedAt — session ordering key. */
  startedAt: Date;
  /** Last set's loggedAt — the incumbent's session stamp (prod stamps
   * top sets with the session payload's logged_at ≈ completion time). */
  endedAt: Date;
  /** All sets of the session (across patterns), chronological. */
  allSets: ReplaySet[];
  /** Sets grouped by movement pattern (sets with no pattern mapping are
   * in allSets but no group — exactly the sets prod attribution drops). */
  patternSets: Map<string, ReplaySet[]>;
  /** Scoring target per pattern, where one exists. */
  patternTargets: Map<string, ReplayTarget>;
}

export interface ReplayUser {
  userId: string;
  sessions: ReplaySession[];
}

function epley(weightKg: number, reps: number): number {
  return weightKg * (1 + reps / 30);
}

export function buildReplay(rows: ExportedRow[]): ReplayUser[] {
  const byUser = new Map<string, Map<string, ReplaySet[]>>();
  for (const r of rows) {
    const set: ReplaySet = {
      exerciseId: canonicalizeExerciseId(r.exercise_id),
      weightKg: r.weight_kg,
      reps: r.reps_completed,
      rpeFelt: r.rpe_felt,
      rirEstimated: r.rir_estimated,
      intent: r.intent,
      loggedAt: new Date(r.logged_at),
    };
    let sessions = byUser.get(r.user_id);
    if (!sessions) {
      sessions = new Map();
      byUser.set(r.user_id, sessions);
    }
    const list = sessions.get(r.session_id) ?? [];
    list.push(set);
    sessions.set(r.session_id, list);
  }

  const users: ReplayUser[] = [];
  for (const [userId, sessionMap] of byUser) {
    const sessions: ReplaySession[] = [];
    for (const [sessionId, sets] of sessionMap) {
      const ordered = sets
        .map((s, i) => ({ s, i }))
        .sort((a, b) =>
          a.s.loggedAt.getTime() - b.s.loggedAt.getTime() || a.i - b.i
        )
        .map((x) => x.s);
      const patternSets = new Map<string, ReplaySet[]>();
      for (const s of ordered) {
        const pattern = lookupPattern(s.exerciseId);
        if (!pattern) continue;
        const list = patternSets.get(pattern) ?? [];
        list.push(s);
        patternSets.set(pattern, list);
      }
      const patternTargets = new Map<string, ReplayTarget>();
      for (const [pattern, ps] of patternSets) {
        let best: ReplaySet | null = null;
        for (const s of ps) {
          if (s.intent !== "top") continue;
          if (s.reps < 3 || s.reps > 10) continue;
          if (!(s.weightKg > 0)) continue;
          if (best === null || epley(s.weightKg, s.reps) > epley(best.weightKg, best.reps)) {
            best = s;
          }
        }
        if (best !== null) {
          patternTargets.set(pattern, {
            exerciseId: best.exerciseId,
            weightKg: best.weightKg,
            actualReps: best.reps,
            loggedAt: best.loggedAt,
          });
        }
      }
      sessions.push({
        sessionId,
        startedAt: ordered[0].loggedAt,
        endedAt: ordered[ordered.length - 1].loggedAt,
        allSets: ordered,
        patternSets,
        patternTargets,
      });
    }
    sessions.sort((a, b) => a.startedAt.getTime() - b.startedAt.getTime());
    users.push({ userId, sessions });
  }
  users.sort((a, b) => a.userId.localeCompare(b.userId));
  return users;
}
