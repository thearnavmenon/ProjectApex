// Project Apex — Phase 2 Stage 2 note-classifier driver.
//
// Per ADR-0013 §"Stage sequencing" + Q9 PRD-internal lock-ins
// (language-driven scoping, form-degradation lifecycle, ActiveLimitation
// lifecycle, joint→pattern subject-training map):
//
//   - Stage 2 runs AFTER Stage 1 commits — the Edge Function's session-apply
//     HTTP response returns after Stage 1, then Stage 2 fires synchronously
//     within the same Edge Function invocation but doesn't gate the response.
//   - Background-tier per ADR-0007 — failures leave the work for the next
//     session-apply, do not surface to the user, do not roll back Stage 1.
//   - Watermark `lastClassifiedNoteCreatedAt` advances ONLY on success.
//
// This module exports the pure-function lifecycle helpers (form-degradation,
// ActiveLimitation, subject-training detection, bootstrap selection) and the
// `runClassifier` driver that wraps the Anthropic Haiku call with bounded
// backoff (via `_shared/llm-retry.ts`). Stage 2's wiring into the Edge
// Function lives in `update-trainee-model/index.ts` (replacing A12's
// `stage2Hook` injection seam with the real classifier call).
//
// Pure throughout — no I/O, no clock reads. Production callers pass `Date`
// values explicitly so tests can pin behavior deterministically.

import {
  CLEARED_LIMITATION_MAX_AGE_MONTHS,
  CLEARED_LIMITATION_MAX_ENTRIES,
  FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR,
  LIMITATION_AI_INFERRED_MAX_SEVERITY,
  LIMITATION_AI_INFERRED_MIN_EVIDENCE,
  LIMITATION_AUTO_CLEAR_SESSIONS,
} from "./constants.ts";
import {
  classifyHttpStatus,
  LLMPermanentError,
  LLMTransientError,
  withLLMRetry,
} from "./llm-retry.ts";

// ─── Shared types (mirror Swift TraineeModelInteractions.swift) ─────────────

export type LimitationSubjectKind = "pattern" | "muscle" | "joint";
export type Severity = "mild" | "moderate" | "severe";

export interface LimitationSubject {
  kind: LimitationSubjectKind;
  /** rawValue of MovementPattern / MuscleGroup / BodyJoint per Swift Codable. */
  value: string;
}

export interface ActiveLimitation {
  subject: LimitationSubject;
  severity: Severity;
  /** ISO 8601 string in JSONB. */
  onsetDate: string;
  evidenceCount: number;
  userConfirmed: boolean;
  notes?: string | null;
  /**
   * Q9 PRD-internal: AI-inferred limitations auto-clear after
   * LIMITATION_AUTO_CLEAR_SESSIONS sessions where the subject was trained
   * AND classifier processed notes AND no re-mention. User-reported
   * (userConfirmed=true) limitations ignore this counter — only user-
   * confirmed UI clear removes them. Defaults to 0 on Phase 1 rows
   * (`decodeIfPresent ?? 0` on the Swift side per slice A13 schema additive).
   */
  sessionsWithoutReMention: number;
}

export interface ClearedLimitation {
  subject: LimitationSubject;
  severity: Severity;
  onsetDate: string;
  clearedDate: string;
  notes?: string | null;
}

export interface LimitationMention {
  subject: LimitationSubject;
  inferredSeverity: "mild";
  sourceLanguage: "tissue" | "mechanical" | "ambiguous" | "mixed";
  noteId: string;
}

export interface NoteToClassify {
  id: string;
  rawTranscript: string;
  exerciseId: string | null;
  createdAt: Date;
  sessionId: string | null;
}

export interface ClassifierOutput {
  formDegradationMentions: Array<{ exerciseId: string; noteId: string }>;
  limitationMentions: LimitationMention[];
}

export interface RunClassifierDeps {
  /** Test seam: returns the raw JSON string Haiku would produce for the prompt+notes.
   *  Production omits → uses the real Anthropic Haiku call.
   *  Throw `LLMTransientError` to exercise retry; throw `LLMPermanentError` for fast-fail. */
  llmCall?: (prompt: string) => Promise<string>;
  /** Test seam for the retry helper's sleep — bypasses real timers. */
  sleep?: (ms: number) => Promise<void>;
}

// ─── Form-degradation lifecycle (Q9 PRD-internal) ───────────────────────────

export interface FormDegradationLifecycleInput {
  exerciseId: string;
  currentFlag: boolean;
  currentCleanSessions: number;
  classifierMentioned: boolean;
  /**
   * True iff the classifier processed notes for this session AND no mention
   * was found AND notes existed AND the exercise was trained. Q9 §"Sessions
   * without notes don't increment" — absence of evidence is not evidence
   * of absence.
   */
  isCleanSession: boolean;
}

export interface FormDegradationLifecycleOutput {
  flag: boolean;
  cleanSessions: number;
}

/**
 * Q9 form-degradation lifecycle:
 *   - classifier mention → reset cleanSessions=0, set flag=true
 *   - clean session → cleanSessions += 1; clear flag at cleanSessions ≥ 3
 *   - sessions without notes don't increment (handled by caller setting
 *     isCleanSession=false)
 */
export function updateFormDegradationLifecycle(
  input: FormDegradationLifecycleInput,
): FormDegradationLifecycleOutput {
  if (input.classifierMentioned) {
    return { flag: true, cleanSessions: 0 };
  }
  if (input.isCleanSession) {
    const newClean = input.currentCleanSessions + 1;
    // Threshold-inclusive: flag clears AT exactly
    // FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR (=3). Cycle 7 pins this
    // boundary — future tightening to `> threshold` would silently delay
    // every form-flag clearing across the alpha cohort.
    if (newClean >= FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR) {
      return { flag: false, cleanSessions: newClean };
    }
    return { flag: input.currentFlag, cleanSessions: newClean };
  }
  // Not mentioned + not a clean session (notes absent OR exercise not trained):
  // pass through unchanged. Counter does NOT increment.
  return { flag: input.currentFlag, cleanSessions: input.currentCleanSessions };
}

// ─── Bootstrap selection (ADR-0013 §Bootstrap) ──────────────────────────────

/**
 * Per ADR-0013 §"Bootstrap": when `lastClassifiedNoteCreatedAt === null`,
 * the classifier processes the smaller of:
 *   - `maxNotes` most recent notes (CLASSIFIER_BOOTSTRAP_MAX_NOTES=20), OR
 *   - all notes from the user's last `maxSessions` sessions
 *     (CLASSIFIER_BOOTSTRAP_MAX_SESSIONS=5)
 * whichever yields fewer notes. Five sessions of training context is sufficient
 * for cold-start; structural patterns invisible from 20+ sessions back aren't
 * acutely actionable.
 */
export function selectBootstrapNotes(
  notes: NoteToClassify[],
  maxNotes: number,
  maxSessions: number,
): NoteToClassify[] {
  if (notes.length === 0) return [];
  // Sort newest-first so "last N sessions" can be derived deterministically.
  const sorted = [...notes].sort(
    (a, b) => b.createdAt.getTime() - a.createdAt.getTime(),
  );
  // Cap A: last `maxNotes` notes regardless of session.
  const capA = sorted.slice(0, maxNotes);
  // Cap B: notes from the last `maxSessions` distinct sessionIds.
  const sessionsSeen = new Set<string>();
  const capB: NoteToClassify[] = [];
  for (const note of sorted) {
    if (note.sessionId !== null) sessionsSeen.add(note.sessionId);
    if (sessionsSeen.size > maxSessions) break;
    capB.push(note);
  }
  return capA.length <= capB.length ? capA : capB;
}

// ─── Q9 joint→pattern subject-training map ──────────────────────────────────
//
// The Q9 lock-in language for shoulder/elbow includes "isolation"; this
// slice excludes isolation per Q6 architectural deviation. Asymmetric-error
// reasoning: including isolation produces premature limitation clearing on
// incidental accessory work (silent loss of protective state for users
// genuinely working around injury); excluding produces slightly slower
// clearing (limitation persists longer than ideal in benign cases).
// Conservative direction is exclude. PR description proposes post-merge
// Q9 lock-in amendment.
//
// Map per Q9:
//   - shoulder, elbow, wrist → all push + all pull (excluding isolation)
//   - hip, knee, ankle, lowerBack → squat + hipHinge + lunge
//   - lowerBack also → verticalPush (per Q9 push extension; OHP loads lumbar
//     through bracing chain)
//   - neck → no patterns (rare in training)
const PATTERN_TRAINS_JOINTS: Record<string, readonly string[]> = {
  horizontalPush: ["shoulder", "elbow", "wrist"],
  verticalPush: ["shoulder", "elbow", "wrist", "lowerBack"],
  horizontalPull: ["shoulder", "elbow", "wrist"],
  verticalPull: ["shoulder", "elbow", "wrist"],
  squat: ["hip", "knee", "ankle", "lowerBack"],
  hipHinge: ["hip", "knee", "ankle", "lowerBack"],
  lunge: ["hip", "knee", "ankle", "lowerBack"],
  isolation: [],
};

/**
 * Derive the set of joints trained this session from the set of patterns
 * trained, per the Q9 joint→pattern map. Subject-training detection for
 * joint-scoped limitations (auto-clear gate) consumes this.
 */
export function derivedTrainedJoints(trainedPatterns: Set<string>): Set<string> {
  const out = new Set<string>();
  for (const pattern of trainedPatterns) {
    const joints = PATTERN_TRAINS_JOINTS[pattern] ?? [];
    for (const j of joints) out.add(j);
  }
  return out;
}

// ─── ActiveLimitation lifecycle (Q9 PRD-internal) ───────────────────────────

export interface LimitationLifecycleInput {
  active: ActiveLimitation[];
  cleared: ClearedLimitation[];
  classifierMentions: LimitationMention[];
  trainedPatterns: Set<string>;
  trainedMuscleGroups: Set<string>;
  /** Joints derived from trainedPatterns via the Q9 joint→pattern map. */
  trainedJoints: Set<string>;
  /** False on classifier failure or no-new-notes; the auto-clear counter
   *  is NOT incremented when notes weren't processed (absence of evidence). */
  notesProcessed: boolean;
  now: Date;
}

export interface LimitationLifecycleOutput {
  active: ActiveLimitation[];
  cleared: ClearedLimitation[];
}

/**
 * Builds a stable string key for `LimitationSubject`. Used to dedupe
 * mentions and look up existing limitations by subject identity.
 */
function subjectKey(s: LimitationSubject): string {
  return `${s.kind}:${s.value}`;
}

/**
 * Q9: a limitation's subject is "trained this session" iff:
 *   - pattern subject: pattern in trainedPatterns
 *   - muscle subject: muscle in trainedMuscleGroups
 *   - joint subject: joint in trainedJoints (caller derives from
 *     trainedPatterns via the joint→pattern map; cycles 17-21 pin the map)
 */
function isSubjectTrained(
  subject: LimitationSubject,
  trainedPatterns: Set<string>,
  trainedMuscleGroups: Set<string>,
  trainedJoints: Set<string>,
): boolean {
  switch (subject.kind) {
    case "pattern":
      return trainedPatterns.has(subject.value);
    case "muscle":
      return trainedMuscleGroups.has(subject.value);
    case "joint":
      return trainedJoints.has(subject.value);
  }
}

/**
 * Q9 ActiveLimitation lifecycle.
 *
 * Pending evidence (1-mention candidates) is tracked in `active` via
 * `evidenceCount<2` per the design note in slice A13's PR description. The
 * digest's prompt-visible filter (B-slice work) excludes these from prompts;
 * this function is concerned only with model-state transitions.
 */
export function updateLimitationLifecycle(
  input: LimitationLifecycleInput,
): LimitationLifecycleOutput {
  // Group mentions by subject. Multiple mentions of the same subject in a
  // single classifier run accumulate evidence in one update.
  const mentionsBySubject = new Map<string, LimitationMention[]>();
  for (const m of input.classifierMentions) {
    const k = subjectKey(m.subject);
    const arr = mentionsBySubject.get(k) ?? [];
    arr.push(m);
    mentionsBySubject.set(k, arr);
  }

  // Update existing limitations + collect ones we've already touched.
  const out: ActiveLimitation[] = [];
  const newlyCleared: ClearedLimitation[] = [];
  const touched = new Set<string>();
  for (const lim of input.active) {
    const k = subjectKey(lim.subject);
    const newMentions = mentionsBySubject.get(k);
    if (newMentions !== undefined) {
      // Re-mention: bump evidenceCount, reset sessionsWithoutReMention.
      out.push({
        ...lim,
        evidenceCount: lim.evidenceCount + newMentions.length,
        sessionsWithoutReMention: 0,
      });
      touched.add(k);
      continue;
    }
    // Not mentioned this session.
    if (lim.userConfirmed) {
      // Q9: user-reported limitations never auto-clear. Pass through unchanged.
      out.push(lim);
      continue;
    }
    // AI-inferred + not mentioned: increment counter only if (a) subject
    // trained AND (b) classifier processed notes. Q9 §"absence of evidence
    // ≠ evidence of absence" — sessions without notes do not count toward
    // auto-clear.
    const subjectTrained = isSubjectTrained(
      lim.subject,
      input.trainedPatterns,
      input.trainedMuscleGroups,
      input.trainedJoints,
    );
    if (input.notesProcessed && subjectTrained) {
      const newCounter = lim.sessionsWithoutReMention + 1;
      if (newCounter >= LIMITATION_AUTO_CLEAR_SESSIONS) {
        // Auto-clear: move to cleared list.
        newlyCleared.push({
          subject: lim.subject,
          severity: lim.severity,
          onsetDate: lim.onsetDate,
          clearedDate: input.now.toISOString(),
          notes: lim.notes ?? null,
        });
      } else {
        out.push({ ...lim, sessionsWithoutReMention: newCounter });
      }
    } else {
      // Not trained or notes not processed: pass through unchanged.
      out.push(lim);
    }
  }

  // Add brand-new candidates (subjects we haven't seen before).
  for (const [k, mentions] of mentionsBySubject) {
    if (touched.has(k)) continue;
    out.push({
      subject: mentions[0].subject,
      severity: LIMITATION_AI_INFERRED_MAX_SEVERITY,
      onsetDate: input.now.toISOString(),
      evidenceCount: mentions.length,
      userConfirmed: false,
      notes: null,
      sessionsWithoutReMention: 0,
    });
  }

  return {
    active: out,
    cleared: pruneClearedLimitations([...input.cleared, ...newlyCleared], input.now),
  };
}

/**
 * Q9: cleared retention pruning runs on every session-apply.
 *   - Age cap: drop entries with clearedDate older than
 *     CLEARED_LIMITATION_MAX_AGE_MONTHS=12 months.
 *   - Entry cap: keep the newest CLEARED_LIMITATION_MAX_ENTRIES=50.
 *
 * Sorted by clearedDate ascending so "newest" is the suffix; the cap drops
 * the prefix (oldest). Both caps composed: age first (cheaper, removes
 * stale fast), then entry-count.
 */
function pruneClearedLimitations(
  cleared: ClearedLimitation[],
  now: Date,
): ClearedLimitation[] {
  const ageThreshold = new Date(now);
  ageThreshold.setMonth(ageThreshold.getMonth() - CLEARED_LIMITATION_MAX_AGE_MONTHS);
  const ageCutoff = ageThreshold.getTime();
  const ageFiltered = cleared.filter(
    (c) => new Date(c.clearedDate).getTime() >= ageCutoff,
  );
  if (ageFiltered.length <= CLEARED_LIMITATION_MAX_ENTRIES) return ageFiltered;
  // Sort ascending by clearedDate, keep the newest N.
  const sorted = [...ageFiltered].sort(
    (a, b) =>
      new Date(a.clearedDate).getTime() - new Date(b.clearedDate).getTime(),
  );
  return sorted.slice(sorted.length - CLEARED_LIMITATION_MAX_ENTRIES);
}

// ─── runClassifier driver (Anthropic Haiku via withLLMRetry) ────────────────

/**
 * Build the Haiku prompt by concatenating the locked prompt asset with the
 * input notes. Production: reads the prompt asset from disk once. Tests
 * inject `llmCall` so the prompt content doesn't have to be valid for the
 * test's mock to ignore it.
 */
function buildPrompt(notes: NoteToClassify[]): string {
  const noteBlock = notes
    .map((n) =>
      `noteId: ${n.id}\nexerciseId: ${n.exerciseId ?? "null"}\nsessionId: ${n.sessionId ?? "null"}\nrawTranscript: ${n.rawTranscript}`
    )
    .join("\n\n---\n\n");
  // The locked prompt asset lives at note-classifier-prompt.txt; in production
  // the Edge Function reads it once at module load. Tests don't depend on the
  // prompt content (mock llmCall returns hand-authored output); this builder
  // just shapes the user-message portion.
  return `INPUT NOTES:\n\n${noteBlock}`;
}

/**
 * Parse Haiku's JSON response into a typed `ClassifierOutput`. Per
 * ADR-0007's permanent-error category, malformed JSON is `LLMPermanentError`
 * (does NOT consume retry budget; orchestrator emits `classifier_failed`
 * and watermark stays unchanged).
 */
function parseClassifierResponse(rawJson: string): ClassifierOutput {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawJson);
  } catch (err) {
    throw new LLMPermanentError(
      `classifier returned non-JSON response: ${err instanceof Error ? err.message : String(err)}`,
      "malformed_response",
      err,
    );
  }
  if (typeof parsed !== "object" || parsed === null) {
    throw new LLMPermanentError(
      "classifier response is not a JSON object",
      "malformed_response",
    );
  }
  const obj = parsed as Record<string, unknown>;
  if (!Array.isArray(obj.formDegradationMentions) || !Array.isArray(obj.limitationMentions)) {
    throw new LLMPermanentError(
      "classifier response missing formDegradationMentions or limitationMentions arrays",
      "malformed_response",
    );
  }
  // Trust the shapes inside the arrays (the prompt locks the structure; if
  // Haiku deviates within an entry, downstream consumers may reject — surface
  // those as permanent errors at the consumer site rather than here).
  return obj as unknown as ClassifierOutput;
}

/**
 * Default LLM call site. Production reads ANTHROPIC_API_KEY from env, builds
 * the prompt, posts to Anthropic's /v1/messages endpoint, and returns the
 * assistant message text. HTTP-status-driven classification per ADR-0007:
 *   transient (429/502/503/504/529)  → LLMTransientError → withLLMRetry retries
 *   permanent (4xx other than 429)   → LLMPermanentError → no retry
 *
 * Tests inject `deps.llmCall` to bypass this entirely.
 */
async function defaultLLMCall(prompt: string): Promise<string> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (apiKey === undefined || apiKey === "") {
    throw new LLMPermanentError(
      "ANTHROPIC_API_KEY env var missing — Stage 2 cannot run",
      "missing_api_key",
    );
  }
  const systemPrompt = await Deno.readTextFile(
    new URL("./note-classifier-prompt.txt", import.meta.url),
  );
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 4096,
      system: systemPrompt,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  const klass = classifyHttpStatus(response.status);
  if (klass === "transient") {
    throw new LLMTransientError(`Anthropic returned ${response.status}`);
  }
  if (klass === "permanent") {
    const body = await response.text().catch(() => "");
    throw new LLMPermanentError(
      `Anthropic returned ${response.status}: ${body}`,
      `http_${response.status}`,
    );
  }
  const json = await response.json() as { content?: Array<{ type: string; text?: string }> };
  const text = json.content?.[0]?.text;
  if (typeof text !== "string") {
    throw new LLMPermanentError(
      "Anthropic response missing content[0].text",
      "malformed_response",
    );
  }
  return text;
}

/**
 * Stage 2 classifier driver per ADR-0013.
 *
 * Empty input → empty output (no LLM call). Caller (orchestrator) is
 * responsible for the bootstrap selection (`selectBootstrapNotes`) and the
 * watermark advance after this returns.
 */
export async function runClassifier(
  notes: NoteToClassify[],
  deps: RunClassifierDeps = {},
): Promise<ClassifierOutput> {
  if (notes.length === 0) {
    return { formDegradationMentions: [], limitationMentions: [] };
  }
  const llmCall = deps.llmCall ?? defaultLLMCall;
  const prompt = buildPrompt(notes);
  const rawJson = await withLLMRetry(() => llmCall(prompt), { sleep: deps.sleep });
  return parseClassifierResponse(rawJson);
}
