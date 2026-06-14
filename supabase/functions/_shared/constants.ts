// Project Apex — Phase 2 named-constants module.
//
// Single home for every load-bearing numerical constant in the Phase 2
// trainee-model rule logic. Each constant cites its originating ADR or
// PRD-internal grilling lock-in (Q3, Q5, Q9, Q10, Q12). Subsequent rule
// modules import from this file rather than redefining inline literals;
// drift is detected by the dedicated tested-defaults assertions in
// `constants_test.ts`.
//
// Per ADR-0006 §"Rule-versioning: forward-only vs auto-recompute": rule
// changes (including constant tunings) apply forward-only. Re-tuning a
// constant lands as a code change here + a corresponding ADR amendment;
// existing trainee-model rows continue from their current state with the
// new logic applied to subsequent updates.
//
// See `docs/design-principles.md` (asymmetric-error preference) for the
// load-bearing reasoning behind several tunings.

// ─── EWMA / e1RM (ADR-0005) ──────────────────────────────────────────────────

/** Exponentially weighted moving-average smoothing constant for e1RM. */
export const EWMA_ALPHA = 0.333;

/** Number of valid top sets feeding the EWMA window (standard mode). */
export const EWMA_WINDOW_N = 5;

/**
 * Number of recent SESSIONS (not top sets) that feed the transition-mode
 * plain-mean window. Heaviest top set per session contributes; sample
 * variance with Bessel correction.
 */
export const TRANSITION_MODE_WINDOW_N = 3;

/** Lower bound on reps for a top set to contribute to e1RM. */
export const TOP_SET_REP_VALIDITY_MIN = 3;

/** Upper bound on reps for a top set to contribute to e1RM. */
export const TOP_SET_REP_VALIDITY_MAX = 10;

/**
 * Bounded retention for `ExerciseProfile.topSets`. ADR-0005 specifies
 * "typically the last 7..10"; 10 is the upper end and gives 2× buffer
 * over the EWMA window of 5 to absorb invalid-rep exclusion. Resolved
 * during /to-issues review (2026-05-07).
 */
export const TOP_SET_RETENTION_COUNT = 10;

// ─── Recovery curves (ADR-0010) ──────────────────────────────────────────────

/**
 * Neuromuscular recovery time constant. Sits on the slightly-conservative
 * side of literature for trained-but-non-elite lifters — under-counting
 * recovery → over-prescription → loud RPE drift; over-counting → quieter
 * (asymmetric-error preference).
 */
export const RECOVERY_TAU_NM_HOURS = 30;

/**
 * Metabolic recovery time constant. Matches lactate clearance and glycogen
 * partial repletion timelines — clears ~2.5× faster than NM.
 */
export const RECOVERY_TAU_METABOLIC_HOURS = 12;

/**
 * Residual recovery floor. Captures that the lifter is not at zero
 * readiness immediately post-stimulus (can train at reduced effort).
 * Dropping to 0 would tell the AI "this person cannot train for the next
 * 30 minutes," which contradicts lived experience.
 */
export const RECOVERY_RESIDUAL_FLOOR = 0.3;

// ─── Plateau verdict (ADR-0009) ──────────────────────────────────────────────

/** e1RM EWMA spread ≤ 2.5% across the frequency-scaled window for plateau. */
export const PLATEAU_E1RM_SPREAD_THRESHOLD = 0.025;

/** Weekly volume-load spread ≤ 5% across trailing 4-window comparison for plateau. */
export const PLATEAU_VOLUME_LOAD_SPREAD_THRESHOLD = 0.05;

/** e1RM dropped ≥ 5% from window start to end for declining (with avgRPE ≥ 7). */
export const DECLINE_E1RM_DROP_THRESHOLD = 0.05;

/** Volume-load drop ≥ 10% in most recent window vs prior for declining. */
export const DECLINE_VOLUME_DROP_THRESHOLD = 0.10;

/** Overreach detector: weekly volume-load > 115% of trailing-4-week average. */
export const OVERREACH_VOLUME_LOAD_RATIO = 1.15;

/**
 * Cadence threshold splitting frequency-scaled window: ≤ 3.5d → 3-session
 * window (≥2×/week); > 3.5d → 4-session window (≤1×/week).
 */
export const FREQUENCY_SCALED_WINDOW_CADENCE_THRESHOLD_DAYS = 3.5;

/** Plateau effort gate: avgRPE < 8.0 across the window. */
export const PLATEAU_EFFORT_GATE_RPE = 8.0;

/**
 * Decline effort gate: avgRPE ≥ 7 required for declining verdict (drops
 * on low-RPE sessions are coasting, not decline).
 */
export const DECLINE_EFFORT_GATE_RPE = 7.0;

// ─── Phase advance (ADR-0011, ADR-0012) ──────────────────────────────────────

/**
 * Force-deload threshold: sessionsInPhase >= 2 × sessionsRequiredForPhase
 * AND trend ∈ {plateaued, declining} → force-advance directly to deload.
 */
export const FORCE_DELOAD_THRESHOLD_MULTIPLIER = 2;

/**
 * Per ADR-0011 §(d) watch-item: when consecutiveForceDeloadsOnPattern
 * reaches this threshold, the digest surfaces the signal to the LLM for
 * exercise-rotation/programme-rebuild coaching cues.
 */
export const CONSECUTIVE_FORCE_DELOAD_SURFACE_THRESHOLD = 2;

/** Global phase advance fires when ≥ 4 of 6 major patterns transitioned within window. */
export const GLOBAL_PHASE_ADVANCE_MAJOR_PATTERN_THRESHOLD = 4;

/** Window of last N user sessions for the global phase-advance trigger. */
export const GLOBAL_PHASE_ADVANCE_SESSION_WINDOW = 6;

/** Cooldown: ≥ N sessions since last fire before global phase advance can re-fire. */
export const GLOBAL_PHASE_ADVANCE_COOLDOWN_SESSIONS = 6;

/** Bootstrap guard: sessionCount must be ≥ N for global phase advance to fire. */
export const GLOBAL_PHASE_ADVANCE_BOOTSTRAP_GUARD = 6;

// ─── Major patterns (ADR-0012) ───────────────────────────────────────────────

/**
 * The 6 major patterns shared by calibration review (ADR-0005) and the
 * global phase advance trigger (ADR-0012). Excluded: lunge, isolation
 * (auxiliary patterns whose phase transitions don't reflect macro readiness).
 */
export const MAJOR_PATTERNS = [
  "horizontal_push",
  "vertical_push",
  "horizontal_pull",
  "vertical_pull",
  "squat",
  "hip_hinge",
] as const;

// ─── Cadence-aware translation (ADR-0015, Q5) ────────────────────────────────

/** Calendar-day floor for transition-mode expiry composition. */
export const TRANSITION_MODE_FLOOR_DAYS = 14;

/** Multiplier on cadence for transition-mode expiry: max(14d, 3 × cadence). */
export const TRANSITION_MODE_CADENCE_MULTIPLIER = 3;

/**
 * Conservative fallback when no cadence is recorded (long-absence-returner
 * default). Longer than the floor so the rule covers ~3 sessions even at
 * 1×/week assumed resume.
 */
export const TRANSITION_MODE_NIL_CADENCE_FALLBACK_DAYS = 21;

/** Multiplier on cadence for `disruptedPatterns` derivation per ADR-0005. */
export const DISRUPTED_PATTERN_CADENCE_MULTIPLIER = 2;

/**
 * Long-absence re-anchor TRIGGER: a FLAT >= 28 calendar-day gap since the
 * prior logged session re-anchors a stale, inflated estimate. Matches the
 * client's `requiresReturnPhaseOverride` cue (`daysSinceLastSession >= 28`)
 * in SessionPlanService.swift. This is the flat-28 absence TRIGGER and is
 * deliberately NOT cadence-aware — distinct from the cadence-aware
 * transition-mode DURATION computed in `computeTransitionModeUntil`
 * (max(14d, 3 × cadence), unchanged here).
 */
export const LONG_ABSENCE_DAYS = 28;

// ─── Stimulus classifier (Q3 PRD-internal) ───────────────────────────────────

/**
 * RPE bump trigger on top sets at 9–10 reps: RPE ≥ 9 upgrades the
 * classification from .metabolic to .both (asymmetric-error: under-counting
 * NM stimulus is silent → over-prescription).
 */
export const STIMULUS_RPE_BUMP_TRIGGER = 9;

/** Top-set rep-band lower bound where the RPE bump applies. */
export const STIMULUS_RPE_BUMP_REP_MIN = 9;

/** Top-set rep-band upper bound where the RPE bump applies. */
export const STIMULUS_RPE_BUMP_REP_MAX = 10;

/** Backoff rep-band: 3–5 reps → .neuromuscular. */
export const BACKOFF_NM_REP_MAX = 5;

/** Backoff rep-band: 6–8 reps → .both; 9+ → .metabolic. */
export const BACKOFF_BOTH_REP_MAX = 8;

// ─── Prescription accuracy (ADR-0014) ────────────────────────────────────────

/** Sliding window size per (pattern, intent) cell. */
export const PRESCRIPTION_ACCURACY_WINDOW_SIZE = 30;

/** Minimum sampleCount before a cell is eligible for digest exposure. */
export const PRESCRIPTION_ACCURACY_DIGEST_MIN_SAMPLES = 5;

/** |bias| > threshold surfaces the cell as miscalibrated. */
export const PRESCRIPTION_ACCURACY_BIAS_SURFACE_THRESHOLD = 0.05;

/** rmse > threshold surfaces the cell as high-variance. */
export const PRESCRIPTION_ACCURACY_RMSE_SURFACE_THRESHOLD = 0.10;

/**
 * Gap-bucket divergence threshold: |bias[under48h] - bias[over72h]| >
 * threshold flags fatigue stacking (per ADR-0010 monitoring trigger).
 */
export const PRESCRIPTION_ACCURACY_GAP_BUCKET_DIVERGENCE_THRESHOLD = 0.05;

/** Both gap buckets must have sampleCount ≥ N for the divergence rule to fire. */
export const PRESCRIPTION_ACCURACY_GAP_BUCKET_MIN_SAMPLES = 3;

/** Boundary between under48h and between48And72h gap buckets, in hours. */
export const GAP_BUCKET_BOUNDARY_LOW_HOURS = 48;

/** Boundary between between48And72h and over72h gap buckets, in hours. */
export const GAP_BUCKET_BOUNDARY_HIGH_HOURS = 72;

// ─── Transfer regression (Q10, ADR-0005) ─────────────────────────────────────

/**
 * R² floor for publishing a learned transfer coefficient. Combined gate
 * with paired-observation count. Asymmetric-error: over-publishing surfaces
 * loudly via prescription-accuracy bias; under-publishing is silent.
 */
export const TRANSFER_R_SQUARED_FLOOR = 0.4;

/** Minimum paired observations before a transfer pair can publish. */
export const TRANSFER_MIN_PAIRED_OBSERVATIONS = 5;

/** Minimum paired observations before the Spearman flag can fire. */
export const TRANSFER_SPEARMAN_FLAG_MIN_OBSERVATIONS = 10;

/**
 * |Spearman ρ - linear R| > threshold flags monotonic-but-non-linear
 * relationships and triggers SE widening.
 */
export const TRANSFER_SPEARMAN_DIVERGENCE_THRESHOLD = 0.15;

/**
 * Additive SE-widening proportionality constant when Spearman flag fires:
 * `seWidening = residualStddev × 1.0`. k=1.0 is the literal "proportional"
 * interpretation of Q10; chosen via asymmetric-error preference (under-
 * widening is silent over-prescription on a non-linear transfer; over-
 * widening is loud under-prescription). Resolved 2026-05-07; see Q10 lock-in.
 */
export const TRANSFER_SPEARMAN_SE_WIDENING_FACTOR = 1.0;

// ─── Fatigue interaction (ADR-0005) ──────────────────────────────────────────

/** Last N observations feed `consistencyFactor`. */
export const FATIGUE_INTERACTION_OBSERVATION_WINDOW = 10;

/** Mean-guard for delta-percent values to prevent divide-by-zero on near-zero mean. */
export const FATIGUE_INTERACTION_MEAN_GUARD = 0.001;

/** countFactor caps confidence at the hard-cap value below this observation count. */
export const FATIGUE_INTERACTION_HARD_CAP_OBSERVATIONS = 15;

/** Hard-cap on countFactor when totalCount is below the threshold. */
export const FATIGUE_INTERACTION_HARD_CAP_VALUE = 0.5;

/** Surfacing threshold: confidence ≥ 0.7 to expose fatigue interaction in digest. */
export const FATIGUE_INTERACTION_SURFACE_THRESHOLD = 0.7;

// ─── Form-degradation / limitation lifecycles (Q9 PRD-internal) ──────────────

/** Clean-session counter to clear `formDegradationFlag`. */
export const FORM_DEGRADATION_CLEAN_SESSIONS_TO_CLEAR = 3;

/** AI-inferred limitation requires ≥ N corroborating evidence to surface. */
export const LIMITATION_AI_INFERRED_MIN_EVIDENCE = 2;

/** AI-inferred limitations cap at this severity until user-confirmed. */
export const LIMITATION_AI_INFERRED_MAX_SEVERITY = "mild" as const;

/** Auto-clear AI-inferred limitations after N sessions of subject-trained-without-mention. */
export const LIMITATION_AUTO_CLEAR_SESSIONS = 3;

// ─── Cleared limitation retention (ADR-0005) ─────────────────────────────────

/** Cleared-limitation entry-count cap; oldest evicted on overflow. */
export const CLEARED_LIMITATION_MAX_ENTRIES = 50;

/** Cleared-limitation age cap in months; pruned on every session-apply. */
export const CLEARED_LIMITATION_MAX_AGE_MONTHS = 12;

// ─── Classifier bootstrap (ADR-0013) ─────────────────────────────────────────

/** Bootstrap cap: process at most N most-recent notes on first-ever classifier run. */
export const CLASSIFIER_BOOTSTRAP_MAX_NOTES = 20;

/** Bootstrap cap: alternative — process notes from at most N most-recent sessions. */
export const CLASSIFIER_BOOTSTRAP_MAX_SESSIONS = 5;
