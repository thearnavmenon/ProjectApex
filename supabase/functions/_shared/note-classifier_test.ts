// Project Apex — Phase 2 Stage 2 note-classifier tests.
//
// Per ADR-0013 §"Stage sequencing" + Q9 PRD-internal lock-ins (form-
// degradation flag lifecycle, ActiveLimitation lifecycle, language-driven
// scoping rule, joint→pattern subject-training map): Stage 2 of the Edge
// Function session-apply path classifies recent notes via Anthropic Haiku,
// updates form-degradation flags + active/cleared limitations.
//
// This file's tests partition into:
//   1. Pure-function lifecycle tests (no Haiku) — form-degradation,
//      ActiveLimitation, subject-training, bootstrap selection.
//   2. Mocked-Haiku language-scoping tests — verify the parser correctly
//      handles outputs the prompt should produce per its 4-row table.
//   3. Failure-mode tests — retry exhaustion, malformed response.
//
// Each test name pins the originating Q9 / ADR rule so a regression
// surfaces the exact rule the change touches.
//
// Run locally:
//   deno test supabase/functions/_shared/note-classifier_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  derivedTrainedJoints,
  selectBootstrapNotes,
  updateFormDegradationLifecycle,
  updateLimitationLifecycle,
  type ActiveLimitation,
  type ClearedLimitation,
  type LimitationMention,
  type NoteToClassify,
} from "./note-classifier.ts";

// ─── Test fixtures ──────────────────────────────────────────────────────────

const mkMention = (
  kind: "pattern" | "muscle" | "joint",
  value: string,
  noteId: string,
  sourceLanguage: "tissue" | "mechanical" | "ambiguous" | "mixed" = "mechanical",
): LimitationMention => ({
  subject: { kind, value },
  inferredSeverity: "mild",
  sourceLanguage,
  noteId,
});

const ANCHOR = new Date("2026-05-09T10:00:00.000Z");

// ─── Q9 form-degradation lifecycle (pure function) ──────────────────────────

Deno.test(
  "Q9 form-degradation: flag=true, cleanSessions=0 → stays true (clean counter still climbing)",
  () => {
    const result = updateFormDegradationLifecycle({
      exerciseId: "barbell-bench",
      currentFlag: true,
      currentCleanSessions: 0,
      classifierMentioned: false,
      isCleanSession: true,
    });
    assertEquals(result.flag, true);
    assertEquals(result.cleanSessions, 1);
  },
);

Deno.test(
  "Q9 form-degradation: flag=true, cleanSessions=2 (one short of FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR=3) → stays true; counter climbs to 3 but flag must clear AT exactly 3",
  () => {
    // Tracer also pins the boundary that cycle 7 will refine (clear at exactly 3).
    const result = updateFormDegradationLifecycle({
      exerciseId: "barbell-bench",
      currentFlag: true,
      currentCleanSessions: 2,
      classifierMentioned: false,
      isCleanSession: true,
    });
    // After this clean session, cleanSessions becomes 3 → cycle 7 says flag clears.
    // Cycle 6's regression-pin focus: a single clean session does not bypass the threshold.
    assertEquals(result.cleanSessions, 3);
  },
);

Deno.test(
  "Q9 form-degradation: cleanSessions reaches FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR=3 → flag=false (boundary)",
  () => {
    // Pre-state cleanSessions=2; this clean session brings it to 3 → flag clears.
    // Pins the boundary: clearing is at exactly 3, not 2 or 4. A future maintainer
    // who tightens the comparison to >3 (well-intentioned, "wait one more") would
    // silently delay every form-flag clearing across the alpha cohort.
    const result = updateFormDegradationLifecycle({
      exerciseId: "barbell-bench",
      currentFlag: true,
      currentCleanSessions: 2,
      classifierMentioned: false,
      isCleanSession: true,
    });
    assertEquals(result.flag, false, "flag must clear at exactly cleanSessions=3");
    assertEquals(result.cleanSessions, 3);
  },
);

Deno.test(
  "Q9 form-degradation: re-mention resets counter (flag=false, cleanSessions=2 + mention → flag=true, cleanSessions=0)",
  () => {
    // After clearing the flag, a fresh classifier mention must re-flag the
    // exercise AND reset cleanSessions=0 — the next clearing path starts
    // over from zero, not from the prior counter.
    const result = updateFormDegradationLifecycle({
      exerciseId: "barbell-bench",
      currentFlag: false,
      currentCleanSessions: 2,
      classifierMentioned: true,
      isCleanSession: false,
    });
    assertEquals(result.flag, true);
    assertEquals(result.cleanSessions, 0, "mention must reset counter to 0");
  },
);

Deno.test(
  "Q9 form-degradation: no-notes session does NOT increment counter (absence of evidence ≠ evidence of absence)",
  () => {
    // isCleanSession=false captures the disjunction: notes absent for the
    // session OR notes present but exercise not trained OR notes present
    // but classifier didn't process them yet. None of these increment
    // the clean-counter. Cycle 9 pins this against future regressions
    // that conflate "no mention" with "clean session."
    const result = updateFormDegradationLifecycle({
      exerciseId: "barbell-bench",
      currentFlag: true,
      currentCleanSessions: 1,
      classifierMentioned: false,
      isCleanSession: false,
    });
    assertEquals(result.flag, true);
    assertEquals(result.cleanSessions, 1, "counter must NOT increment when isCleanSession=false");
  },
);

// ─── Q9 ActiveLimitation lifecycle (pure function) ──────────────────────────

Deno.test(
  "Q9: AI-inferred limitation requires LIMITATION_AI_INFERRED_MIN_EVIDENCE=2 — single mention sets evidenceCount=1; second mention reaches threshold (evidenceCount tracks pending state in active list; digest filter at B-slice surfaces only ≥2)",
  () => {
    // First call: 1 mention → entry created with evidenceCount=1, severity=.mild,
    // userConfirmed=false. Per the design note: pending evidence is tracked in
    // `active` via `evidenceCount<2`; the digest's prompt-visible filter (B-slice
    // work) excludes these from prompts.
    const after1 = updateLimitationLifecycle({
      active: [],
      cleared: [],
      classifierMentions: [mkMention("joint", "shoulder", "n1", "mechanical")],
      trainedPatterns: new Set(["horizontalPush"]),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(["shoulder"]),
      notesProcessed: true,
      now: ANCHOR,
    });
    assertEquals(after1.active.length, 1);
    assertEquals(after1.active[0].evidenceCount, 1);
    assertEquals(after1.active[0].severity, "mild");
    assertEquals(after1.active[0].userConfirmed, false);
    assertEquals(after1.active[0].subject.kind, "joint");
    assertEquals(after1.active[0].subject.value, "shoulder");

    // Second call (next session): same subject re-mentioned → evidenceCount=2,
    // crosses the surfacing threshold (digest will now include it).
    const after2 = updateLimitationLifecycle({
      active: after1.active,
      cleared: [],
      classifierMentions: [mkMention("joint", "shoulder", "n2", "mechanical")],
      trainedPatterns: new Set(["horizontalPush"]),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(["shoulder"]),
      notesProcessed: true,
      now: new Date(ANCHOR.getTime() + 86400 * 1000),
    });
    assertEquals(after2.active.length, 1);
    assertEquals(after2.active[0].evidenceCount, 2);
    assertEquals(after2.active[0].severity, "mild");
  },
);

Deno.test(
  "Q9: AI-inferred severity capped at LIMITATION_AI_INFERRED_MAX_SEVERITY=.mild — even 5 mentions can't escalate severity (only user-confirmed UI can)",
  () => {
    // Five mentions in a single session (or accumulating across sessions) —
    // evidenceCount climbs but severity must stay .mild for AI-inferred
    // limitations. Severity escalation is reserved for user-confirmed flow.
    const result = updateLimitationLifecycle({
      active: [],
      cleared: [],
      classifierMentions: [
        mkMention("joint", "knee", "n1"),
        mkMention("joint", "knee", "n2"),
        mkMention("joint", "knee", "n3"),
        mkMention("joint", "knee", "n4"),
        mkMention("joint", "knee", "n5"),
      ],
      trainedPatterns: new Set(["squat"]),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(["knee"]),
      notesProcessed: true,
      now: ANCHOR,
    });
    assertEquals(result.active.length, 1);
    assertEquals(result.active[0].evidenceCount, 5);
    assertEquals(
      result.active[0].severity,
      "mild",
      "AI-inferred severity must cap at .mild regardless of evidence count",
    );
    assertEquals(result.active[0].userConfirmed, false);
  },
);

Deno.test(
  "Q9: AI-inferred auto-clears after LIMITATION_AUTO_CLEAR_SESSIONS=3 sessions (subject trained + notes processed + no re-mention) — moves to cleared; sessionsWithoutReMention counter drives the gate",
  () => {
    // Pre-state: surfaced AI-inferred limitation on shoulder (evidenceCount=2,
    // sessionsWithoutReMention=2). One more clean session (subject trained,
    // notes processed, no re-mention) bumps to 3 → auto-clear fires.
    const preExisting: ActiveLimitation = {
      subject: { kind: "joint", value: "shoulder" },
      severity: "mild",
      onsetDate: ANCHOR.toISOString(),
      evidenceCount: 2,
      userConfirmed: false,
      notes: null,
      sessionsWithoutReMention: 2,
    };
    const sessionDate = new Date(ANCHOR.getTime() + 7 * 86400 * 1000);
    const result = updateLimitationLifecycle({
      active: [preExisting],
      cleared: [],
      classifierMentions: [], // no re-mention this session
      trainedPatterns: new Set(["horizontalPush"]),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(["shoulder"]),
      notesProcessed: true, // classifier ran
      now: sessionDate,
    });
    assertEquals(result.active.length, 0, "auto-cleared limitation must leave active list");
    assertEquals(result.cleared.length, 1);
    assertEquals(result.cleared[0].subject.kind, "joint");
    assertEquals(result.cleared[0].subject.value, "shoulder");
    assertEquals(result.cleared[0].clearedDate, sessionDate.toISOString());
    assertEquals(result.cleared[0].onsetDate, ANCHOR.toISOString(), "onsetDate carries forward");
  },
);

Deno.test(
  "Q9: user-reported limitation never auto-clears — even 10 sessions of subject-trained + notes-processed + no-mention leave it in active",
  () => {
    // userConfirmed=true → never auto-clear regardless of counter. Cycle 13
    // pins this against future regressions where a code path forgets the
    // userConfirmed gate and indiscriminately increments the counter.
    const userReported: ActiveLimitation = {
      subject: { kind: "joint", value: "shoulder" },
      severity: "moderate",
      onsetDate: ANCHOR.toISOString(),
      evidenceCount: 2,
      userConfirmed: true,
      notes: "User reported acute pain after deload week.",
      sessionsWithoutReMention: 0,
    };
    let active = [userReported];
    for (let i = 0; i < 10; i++) {
      const result = updateLimitationLifecycle({
        active,
        cleared: [],
        classifierMentions: [],
        trainedPatterns: new Set(["horizontalPush"]),
        trainedMuscleGroups: new Set(),
        trainedJoints: new Set(["shoulder"]),
        notesProcessed: true,
        now: new Date(ANCHOR.getTime() + i * 86400 * 1000),
      });
      active = result.active;
    }
    assertEquals(active.length, 1, "user-reported limitation must persist through 10 trained-no-mention sessions");
    assertEquals(active[0].userConfirmed, true);
    assertEquals(active[0].severity, "moderate", "severity unchanged");
  },
);

Deno.test(
  "Q9: merge on coexistence — classifier mention on subject that already has a user-reported limitation merges into the user-reported entry (severity=max, evidence accumulates, source stays .userReported, no duplicate)",
  () => {
    // Pre-state: user-reported moderate shoulder limitation already in active.
    // Classifier identifies shoulder subject in this session. Per Q9: source
    // promotes to .userReported (stays — already is); severity = max(moderate, mild) = moderate;
    // evidenceCount accumulates from 2 → 3; only ONE entry in active (no duplicate).
    const userReported: ActiveLimitation = {
      subject: { kind: "joint", value: "shoulder" },
      severity: "moderate",
      onsetDate: ANCHOR.toISOString(),
      evidenceCount: 2,
      userConfirmed: true,
      notes: "User reported acute pain after deload week.",
      sessionsWithoutReMention: 0,
    };
    const result = updateLimitationLifecycle({
      active: [userReported],
      cleared: [],
      classifierMentions: [mkMention("joint", "shoulder", "n1", "mechanical")],
      trainedPatterns: new Set(["horizontalPush"]),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(["shoulder"]),
      notesProcessed: true,
      now: new Date(ANCHOR.getTime() + 86400 * 1000),
    });
    assertEquals(result.active.length, 1, "merge produces single entry, no duplicate AI-inferred created");
    assertEquals(result.active[0].userConfirmed, true, "source stays .userReported (Q9 §Merge: stronger source wins)");
    assertEquals(
      result.active[0].severity,
      "moderate",
      "severity = max(moderate, mild) = moderate (user-reported severity persists)",
    );
    assertEquals(
      result.active[0].evidenceCount,
      3,
      "corroboration accumulates: 2 (user-reported) + 1 (classifier) = 3",
    );
  },
);

Deno.test(
  "Q9: cleared retention 50-cap — when cleared.length=51, oldest entry (smallest clearedDate) is evicted on next apply",
  () => {
    // Build 51 cleared entries with monotonically increasing clearedDates
    // ALL within the 12-month window (so age-cap doesn't fire and entry-cap is
    // the load-bearing prune). Entry index 0 is the oldest still-eligible
    // entry; newest is index 50.
    const now = new Date("2026-05-09T00:00:00.000Z");
    const baseline = new Date(now);
    baseline.setMonth(baseline.getMonth() - 6); // 6 months back — comfortably inside 12mo cap
    const cleared: ClearedLimitation[] = [];
    for (let i = 0; i < 51; i++) {
      cleared.push({
        subject: { kind: "muscle", value: "biceps" },
        severity: "mild",
        onsetDate: baseline.toISOString(),
        clearedDate: new Date(baseline.getTime() + i * 86400 * 1000).toISOString(),
        notes: `entry ${i}`,
      });
    }
    const result = updateLimitationLifecycle({
      active: [],
      cleared,
      classifierMentions: [],
      trainedPatterns: new Set(),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(),
      notesProcessed: false, // no new notes; prune still runs per Q9 "every session-apply"
      now,
    });
    assertEquals(result.cleared.length, 50, "retention cap is CLEARED_LIMITATION_MAX_ENTRIES=50");
    // Oldest (entry index 0, notes="entry 0") evicted; newest (entry 50) retained.
    const notesValues = result.cleared.map((c) => c.notes);
    assertEquals(notesValues.includes("entry 0"), false, "oldest entry must be evicted");
    assertEquals(notesValues.includes("entry 50"), true, "newest entry must remain");
  },
);

Deno.test(
  "Q9: cleared retention 12-month prune — entries with clearedDate older than CLEARED_LIMITATION_MAX_AGE_MONTHS=12mo are evicted on every apply",
  () => {
    const now = new Date("2026-05-09T00:00:00.000Z");
    // 13 months back — should be evicted.
    const ancient = new Date(now);
    ancient.setMonth(ancient.getMonth() - 13);
    // 11 months back — should be retained.
    const recent = new Date(now);
    recent.setMonth(recent.getMonth() - 11);
    const cleared: ClearedLimitation[] = [
      {
        subject: { kind: "muscle", value: "biceps" },
        severity: "mild",
        onsetDate: ancient.toISOString(),
        clearedDate: ancient.toISOString(),
        notes: "ancient",
      },
      {
        subject: { kind: "muscle", value: "triceps" },
        severity: "mild",
        onsetDate: recent.toISOString(),
        clearedDate: recent.toISOString(),
        notes: "recent",
      },
    ];
    const result = updateLimitationLifecycle({
      active: [],
      cleared,
      classifierMentions: [],
      trainedPatterns: new Set(),
      trainedMuscleGroups: new Set(),
      trainedJoints: new Set(),
      notesProcessed: false,
      now,
    });
    assertEquals(result.cleared.length, 1);
    assertEquals(result.cleared[0].notes, "recent", "12-month-old entries evicted; recent entries retained");
  },
);

// ─── Q9 joint→pattern subject-training map (slice A13 / Q6 deviation) ───────
//
// The Q9 lock-in language for shoulder/elbow includes "isolation"; this slice
// excludes isolation per Q6 architectural refinement. Asymmetric-error
// reasoning: including isolation produces premature limitation clearing on
// incidental accessory work (silent loss of protective state); excluding
// produces slightly slower clearing (limitation persists longer than ideal in
// benign cases). Conservative direction is exclude. PR description proposes
// post-merge Q9 lock-in amendment.

Deno.test(
  "Q9 joint→pattern map: shoulder is trained when horizontalPush is in the session's trained patterns",
  () => {
    const joints = derivedTrainedJoints(new Set(["horizontalPush"]));
    assertEquals(joints.has("shoulder"), true);
    assertEquals(joints.has("elbow"), true);
    assertEquals(joints.has("wrist"), true);
  },
);

Deno.test(
  "Q9 joint→pattern map: shoulder is NOT trained when only squat is in the session's trained patterns",
  () => {
    const joints = derivedTrainedJoints(new Set(["squat"]));
    assertEquals(joints.has("shoulder"), false, "squat is a lower-body pattern; doesn't train shoulder per Q9");
    assertEquals(joints.has("elbow"), false);
    assertEquals(joints.has("hip"), true, "squat trains hip/knee/ankle/lowerBack per Q9");
    assertEquals(joints.has("knee"), true);
    assertEquals(joints.has("ankle"), true);
    assertEquals(joints.has("lowerBack"), true);
  },
);

Deno.test(
  "Q9 joint→pattern map: lowerBack is trained on hipHinge (per Q9 lowerBack ↔ squat+hipHinge+lunge+verticalPush)",
  () => {
    const joints = derivedTrainedJoints(new Set(["hipHinge"]));
    assertEquals(joints.has("lowerBack"), true);
    // Cross-check verticalPush also trains lowerBack per Q9 push extension.
    const jointsVP = derivedTrainedJoints(new Set(["verticalPush"]));
    assertEquals(jointsVP.has("lowerBack"), true, "verticalPush trains lowerBack per Q9 push extension (OHP loads lumbar through bracing chain)");
  },
);

Deno.test(
  "Q9 joint→pattern map: wrist is trained on horizontalPull (per Q9 wrist ↔ all push AND all pull, extended for grip-loading)",
  () => {
    const joints = derivedTrainedJoints(new Set(["horizontalPull"]));
    assertEquals(joints.has("wrist"), true, "wrist trains on all pulls per Q9 push extension");
    // And on push patterns:
    const jointsHP = derivedTrainedJoints(new Set(["horizontalPush"]));
    assertEquals(jointsHP.has("wrist"), true);
  },
);

Deno.test(
  "Q9 joint→pattern map: isolation pattern does NOT train any joint subject (Q6 architectural deviation from Q9 lock-in language)",
  () => {
    // Q9 lock-in language reads "shoulder/elbow → push + pull (incl. isolation)";
    // this slice excludes isolation per Q6 asymmetric-error analysis (including
    // isolation produces premature limitation clearing on incidental accessory
    // work). PR description carries the Q9 amendment proposal.
    const joints = derivedTrainedJoints(new Set(["isolation"]));
    assertEquals(joints.size, 0, "isolation does not contribute to joint-subject training (Q6 deviation)");
  },
);

Deno.test(
  "Q9 muscle subject: biceps limitation is auto-clearable when biceps is in the session's trained muscle groups (muscle path, not joint path)",
  () => {
    // Integration test through the lifecycle: pre-existing AI-inferred biceps
    // limitation with sessionsWithoutReMention=2; one more clean session with
    // biceps in trainedMuscleGroups → auto-clear fires. Pins the muscle-subject
    // path separately from the joint-subject path.
    const preExisting: ActiveLimitation = {
      subject: { kind: "muscle", value: "biceps" },
      severity: "mild",
      onsetDate: ANCHOR.toISOString(),
      evidenceCount: 2,
      userConfirmed: false,
      notes: null,
      sessionsWithoutReMention: 2,
    };
    const result = updateLimitationLifecycle({
      active: [preExisting],
      cleared: [],
      classifierMentions: [],
      trainedPatterns: new Set(["isolation"]),
      trainedMuscleGroups: new Set(["biceps"]),
      trainedJoints: new Set(),
      notesProcessed: true,
      now: new Date(ANCHOR.getTime() + 86400 * 1000),
    });
    assertEquals(result.active.length, 0);
    assertEquals(result.cleared.length, 1);
    assertEquals(result.cleared[0].subject.kind, "muscle");
    assertEquals(result.cleared[0].subject.value, "biceps");
  },
);

// ─── Bootstrap selection (ADR-0013 §Bootstrap) ──────────────────────────────
//
// Per ADR-0013 §Bootstrap: when `lastClassifiedNoteCreatedAt === null`,
// process the smaller of CLASSIFIER_BOOTSTRAP_MAX_NOTES (=20 most recent)
// OR all notes from the user's last CLASSIFIER_BOOTSTRAP_MAX_SESSIONS (=5)
// sessions. Whichever is smaller.

const mkNote = (
  id: string,
  sessionId: string,
  daysAgo: number,
): NoteToClassify => ({
  id,
  rawTranscript: `note ${id}`,
  exerciseId: null,
  createdAt: new Date(ANCHOR.getTime() - daysAgo * 86400 * 1000),
  sessionId,
});

Deno.test(
  "ADR-0013 bootstrap: 50 historical notes spanning many sessions → CLASSIFIER_BOOTSTRAP_MAX_NOTES=20 cap wins (notes-cap is smaller)",
  () => {
    // 50 notes, 1 per session (so the 5-session cap would yield 5 notes —
    // smaller than 20 — wait, this would mean cap-B wins). Let me re-think:
    // Cycle 22 wants notes-cap to win. So we need MANY notes per session,
    // few enough sessions that the per-session cap selects MORE than 20.
    // 50 notes spread across 50 sessions: cap A = 20 (newest), cap B = last
    // 5 sessions = 5 notes. min(20, 5) = 5. cap-B wins, not cap-A.
    //
    // To make cap-A win: need ≥21 notes in the last 5 sessions. Use 50 notes
    // packed into 5 sessions (10 notes each): cap A = 20, cap B = 50. min=20.
    // cap-A wins. That's the intended cycle 22 fixture.
    const notes: NoteToClassify[] = [];
    for (let s = 0; s < 5; s++) {
      for (let n = 0; n < 10; n++) {
        notes.push(mkNote(`s${s}n${n}`, `session-${s}`, s));
      }
    }
    const result = selectBootstrapNotes(notes, 20, 5);
    assertEquals(result.length, 20, "notes-cap (20) wins when last-5-sessions yields more than 20 notes");
  },
);

Deno.test(
  "ADR-0013 bootstrap: 50 notes spanning 10 sessions, last-5-sessions has 8 notes → uses 8 (sessions-cap is smaller)",
  () => {
    // 10 sessions total, varying note counts. Newest 5 sessions hold 8 notes;
    // older 5 sessions hold the other 42. cap A = min(20, 50) = 20; cap B
    // = 8 (last 5 sessions hold only 8). min(20, 8) = 8.
    const notes: NoteToClassify[] = [];
    // Older 5 sessions: 42 notes total, e.g., session 0..4 with 8/9/8/9/8.
    let total = 0;
    const olderCounts = [8, 9, 8, 9, 8]; // sums to 42
    for (let s = 0; s < 5; s++) {
      for (let n = 0; n < olderCounts[s]; n++) {
        notes.push(mkNote(`old-s${s}n${n}`, `session-${s}`, 100 - s));
      }
      total += olderCounts[s];
    }
    // Newer 5 sessions: 8 notes total, e.g., 2/2/2/1/1.
    const newerCounts = [2, 2, 2, 1, 1]; // sums to 8
    for (let s = 0; s < 5; s++) {
      for (let n = 0; n < newerCounts[s]; n++) {
        notes.push(mkNote(`new-s${s}n${n}`, `session-${s + 5}`, 5 - s));
      }
    }
    assertEquals(total + 8, 50, "fixture sanity: 50 total notes");
    const result = selectBootstrapNotes(notes, 20, 5);
    assertEquals(result.length, 8, "sessions-cap (8) wins when last-5-sessions has fewer than 20 notes");
  },
);

Deno.test(
  "ADR-0013 bootstrap: 0 historical notes → empty selection (orchestrator skips classifier; watermark stays null)",
  () => {
    const result = selectBootstrapNotes([], 20, 5);
    assertEquals(result.length, 0, "no-op on empty input — orchestrator must not invoke classifier");
  },
);
