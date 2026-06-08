# Project Apex — Backlog

---

## Phase 0 — Infrastructure & AI Spine

- [x] P0-T01: KeychainService — API key storage & retrieval
- [x] P0-T02: DeveloperSettingsView — manual API key entry UI
- [ ] P0-T03: Wire AnthropicProvider with real API key end-to-end
- [x] P0-T04: GymProfile Codable schema — lock & unit test round-trip
- [x] P0-T05: AppDependencies DI container — wire all services at launch
- [x] P0-T06: WorkoutContext assembly — unit test full JSON serialization
- [x] P0-T07: AIInferenceService integration test — real API, mock context
- [x] P0-T08: SetPrescription.validate() — unit tests to 100% AC coverage (EquipmentRounder retired)
- [x] P0-T09: CI pipeline — GitHub Actions, test run on push

---

## Phase 1 — Gym Scanner — Live

- [x] P1-T01: SupabaseClient — core CRUD and RPC wrapper
- [x] P1-T02: Live VisionAPIService — presence-only strength scanner (no weight ranges)
- [x] P1-T03: EquipmentMerger — cardio/junk blocklists, presence-only deduplication
- [x] P1-T04: GymProfile → Supabase persist & fetch
- [x] P1-T05: EquipmentConfirmationView — edit, add, delete items
- [x] P1-T06: Re-scan flow with confirmation dialog
- [x] P1-T07: EquipmentMerger unit tests — rewritten for presence-only API
- [x] P1-T08: DefaultWeightIncrements — hardcoded commercial gym weight defaults
- [x] P1-T09: GymFactStore — runtime weight correction persistence actor
- [x] P1-T10: WeightCorrectionView — user weight substitution sheet
- [x] P1-T11: Wire WeightCorrectionView into ActiveSetView ("Weight not available" button)
- [x] P1-T12: Guided per-equipment photo scanner — single-shot capture, result review card, guided UX replaces continuous frame loop

---

## Phase 2 — Macro-Program Engine

- [x] P2-T01: WorkoutProgram data models — Mesocycle, Week, TrainingDay, Exercise
- [x] P2-T02: ProgramGenerationService actor — LLM call, decode, validate
- [x] P2-T03: Equipment constraint validation — post-generation pass
- [x] P2-T04: Supabase programs table — persist & fetch mesocycle
- [x] P2-T05: ProgramOverviewView — 12-week calendar grid
- [x] P2-T06: ProgramDayDetailView — drill-in exercise list
- [x] P2-T07: MacroGeneration system prompt — tune and lock
- [x] P2-T08: Regenerate Program — settings action
- [ ] P2-T09: SwiftData local cache for offline program access

---

## Phase 3 — Active Workout Loop

- [x] P3-T01: WorkoutSessionManager actor — session lifecycle
- [x] P3-T02: WorkoutViewModel — bridge actor state to SwiftUI
- [x] P3-T03: PreWorkoutView — streak ring display, session start
- [x] P3-T04: ActiveSetView — prescription card, Set Complete
- [x] P3-T05: RestTimerView — countdown, haptics, AI arrival update
- [x] P3-T06: Set log writes — Supabase + local write-ahead queue
- [x] P3-T07: Smart AI retry UX — replaced silent "Coach offline" fallback with user-choice retry sheet (`InferenceRetrySheet`); inference failure during rest stays silent until timer expires then shows sheet; failure during preflight shows sheet immediately; user can Retry or Pause Session; `makeFallbackPrescription()` deleted; offline banner removed from `ActiveSetView`
- [x] P3-T08: PostWorkoutSummaryView — volume, PRs, adjustments
- [x] P3-T09: End session early — partial session logging
- [x] P3-T10: Exercise swap — manual substitution within session
- [x] P3-T11: Session pause & resume — `pauseSession()` flushes WAQ, PATCHes `workout_sessions.status = "paused"`, saves `PausedSessionState` snapshot to UserDefaults; `resumeSession()` restores actor state, re-fetches set logs from Supabase, fires inference immediately; amber "PAUSED" badge in `DayCardView`; "Resume Session" button in `ProgramDayDetailView`; concurrent session guard (Discard alert when a paused session blocks a new start); "Pause Session" in ellipsis menus on `ActiveSetView` and `RestTimerView`; Supabase migration: `ALTER TABLE workout_sessions ADD COLUMN IF NOT EXISTS status TEXT DEFAULT NULL`

---

## Phase 4 — Polish & MVP Hardening

- [ ] P4-T01: HealthKitService — permissions, biometrics fetch, ReadinessScore
- [ ] P4-T02: ReadinessScore — edge case handling matrix (TDD 11.4)
- [x] P4-T03: SpeechService — on-device STT + Whisper fallback
- [x] P4-T04: MemoryService — embedding pipeline write path
- [x] P4-T05: MemoryService — RAG retrieval read path + integration
- [x] P4-T06: Voice note UI — mic button, live transcript modal
- [x] P4-T07: Memory event taxonomy — auto-generated structured events
- ~~[ ] P4-T08: HRV 30-day baseline computation~~ **REMOVED** — Apple Watch support dropped from MVP
- [x] P4-T09: App launch flow — onboarding → scan → generate → workout (Step 3: notification permissions prompt, not HealthKit)
- [ ] P4-T10: 5-session stability run — manual QA pass

---

## Feedback Issues (FB)

- [x] FB-001: Inline weight override on prescription card — tappable weight value opens `WeightOverrideView` (.medium detent); +/− stepper snaps to `DefaultWeightIncrements` for equipment type; confirm saves to `GymFactStore`; "Adjusted" badge shown when overridden; `user_corrected_weight` flag propagated in `CompletedSet` and `WorkoutContext` for AI; "Weight not available" button retained
- [x] FB-002: Equipment-aware weight increments in AI prompt — `SystemPrompt_Inference.txt` v2.0: barbell min 5 kg increments, dumbbell/cable min 2.5 kg; rep-completion bands replace percentage formula (NEAR MISS ≥80%, MODERATE MISS 60–79%, SIGNIFICANT MISS <60%); anti-oscillation rule added; prompt version-bumped with change log header
- [x] FB-003: Onboarding biometrics collection — `OnboardingProfile` extended with `bodyweightKg`, `heightCm`, `age`, `bodyweightInKg`; Step 2 UI extended with all four fields (bodyweight with kg/lbs toggle, height, age); fields persisted to `UserDefaults` via `UserProfileConstants` and to Supabase `users` table; `UserProfileContext` struct added to `WorkoutContext` payload; `WorkoutSessionManager` reads from `UserDefaults` at session start; all four fields editable post-onboarding from Settings → Training Profile section; system prompt updated with first-session calibration block and user profile guidance
- [x] FB-005: First-session cold-start calibration — `WorkoutContext` gains `is_first_session: Bool` field (true when `session_count == 0`); `totalSessionCount` now read from `UserDefaults.sessionCountKey` (incremented at session completion, non-early-exit only); `PreWorkoutView` shows "First session — we'll calibrate your starting weights today" banner when `is_first_session`; `SystemPrompt_Inference.txt` v3.0 references explicit `is_first_session` flag; `WorkoutContextAssemblyTests` updated with new field assertions
- [x] FB-006: Contextual AI coaching — `WorkoutContext` gains `within_session_performance: [CompletedSet]` (all prior sets this session for current exercise); system prompt v3.0: SIGNIFICANT MISS (<60% reps) now uses `within_session_performance` to triangulate true working weight, anchors all remaining sets, requires direct coaching cue acknowledging the miss; `WorkoutSessionManager.emitExerciseOutcomeEvents()` emits one RAG memory event per completed exercise at session end (`outcome: "on_target" | "overloaded" | "underloaded"`); new SESSION OUTCOME ANCHOR prompt section instructs AI to open 5–10% below previous weight if `overloaded`, at/above if `on_target`/`underloaded`; `SystemPrompt_Inference.txt` version-bumped to v3.0 with change log
- [x] FB-007: Reset Onboarding Only — `DeveloperSettingsView` gains a "Reset Onboarding Only" button (DEBUG builds) that clears `onboardingCompletedKey`, `scanSkippedKey`, `daysPerWeekKey`, and the local mesocycle UserDefaults cache while leaving GymProfile and programme rows in Supabase intact; user can re-run onboarding without triggering a new Vision API scan or programme generation call
- [x] FB-008: Programme generation split into two-stage architecture — `MacroPlanService` (one-shot skeleton: phase names, week intent labels, day focus, volume landmarks — no exercises/weights) + `SessionPlanService` (on-demand per-session generation immediately before each workout, informed by full lift history and fatigue signals); new models: `MesocycleSkeleton`, `WeekIntent`, `TrainingDayStatus` (.pending/.generated/.completed); `TrainingDay` gains `status` field (backward-compatible decoder, defaults to `.generated` for legacy data); `TrainingWeek` gains optional `weekLabel` from skeleton; `LiftHistoryEntry` built from `SetLog` array with trend direction (improving/stalling/declining via e1RM proxy), last session outcome, and session count; `WeekFatigueSignals.compute()` derives fatigue management flag (avg RPE > 8.2 across 3+ sessions → 20% volume reduction) and deload trigger (≥2 of 3 signals: avg RPE > 8.0, rep completion < 75%, 3+ significant compound misses → 50% volume at RPE 5–6); RAG memory retrieval integrated into `SessionPlanService` for each session; new system prompts `SystemPrompt_MacroPlan.txt` and `SystemPrompt_SessionPlan.txt`; `ProgramViewModel` updated with `generateMacroSkeleton()` and `generateDaySession()` methods; `AppDependencies` wired with both new services; UI: week intent labels shown in `ProgramOverviewView` week headers, "Session pending" indicator (clock icon) for `.pending` days, "Preparing Your Session" loading screen in `ProgramDayDetailView`, "Generate Session" button on pending days
- [x] FB-009: Free day selection — every generated day in `ProgramDayDetailView` shows "Start Workout" regardless of its scheduled date; starting an off-schedule day does not advance the programme pointer; status banner updated to show "Scheduled — tap Start Workout to train early" / "Past session — tap Start Workout to re-run or Log Past Session to backdate"; DEBUG-only "Start Any Day Mode" toggle in `DeveloperSettingsView` persisted to `UserDefaults` (`dev_start_any_day_mode`) so all days unlock simultaneously for jump-testing
- [x] FB-010: Manual session logging — "Log Past Session" secondary button added to `ProgramDayDetailView` for all generated days; tapping opens `ManualSessionLogView` sheet (date picker + per-exercise weight/reps/RPE entry with add/remove set rows); on confirm: writes `workout_sessions` row with `manually_logged: true`, writes individual `set_logs`, calls `MemoryService.embed()` per set (AI learns from manual sessions); no AI inference calls during entry; Supabase schema requires `manually_logged boolean` column on `workout_sessions` table
- [x] FB-011: Calendar-time programme advancement bug — Original symptom: app showed "Week 5" and generated an Intensification-phase session when the user had only completed 2 training days (legs remained untrained). Root cause: `ProgramViewModel.currentWeekIndex(in:)` computed week position via `Int(Date().timeIntervalSince(mesocycle.createdAt) / 604800)`, advancing the programme pointer every 7 calendar days regardless of actual session completions. Resolution (Phase 1 refactor): `currentWeekIndex` replaced with a training-time scan that returns the index of the first week containing a non-terminal (neither `.completed` nor `.skipped`) day; calendar date is never used for programme progression. `markDaySkipped` added as the persistent skip path so skipped days also advance the pointer.
- [x] FB-012: 22 Apr 2026 Anthropic 529 outage — mid-session resilience incident. Two bugs exposed: (1) `AIInferenceService.prescribe()` had no transient HTTP retry, surfacing the `InferenceRetrySheet` on every single 529/503 response rather than retrying silently; (2) crash-recovery resume in `WorkoutView.task` used `saved.trainingDayId == trainingDay.id` which silently failed when the paused session's day ID diverged from `nextIncompleteDay.id` (e.g. programme regenerated mid-session), dropping the user into a fresh PreWorkoutView with no recovery path. Resolved by Phase 3 Mid-Session Resilience fixes (P3-MR-F01–F06) on 23 Apr 2026.

---

## Phase 4 Extension — Progress Tab & AI-Augmented Coaching (P4-E2)

- [x] P4-E2-T01: SupabaseClient `select:` parameter — optional narrow column fetch to avoid pulling `ai_prescribed` JSONB
- [x] P4-E2-T02: `StagnationService` — Epley e1RM trend analysis; classifies exercises as `progressing | plateaued | declining` from last 3 sessions; UserDefaults persist/load; `StagnationServiceTests.swift` (6 test cases, 100% branch coverage)
- [x] P4-E2-T03: `VolumeValidationService` — actual vs target set counts per muscle for the current calendar week; 20% deficit threshold; UserDefaults persist/load; `VolumeValidationServiceTests.swift` (5 test cases)
- [x] P4-E2-T04: `ProgressViewModel` — `@Observable @MainActor`; two-query pattern (workout_sessions → set_logs); key lifts by muscle group (no hardcoded IDs); Epley trend data; weekly volume (8 weeks); 12-week consistency heatmap; `ProgressSessionRow` DTO decodes `session_date` as `String` (Postgres `DATE` → `"yyyy-MM-dd"`) to avoid ISO8601 parse failure
- [x] P4-E2-T05: `MuscleColorUtility` — shared `nonisolated enum MuscleColor` with `color(for:)` mapping for all 10 muscle groups + other
- [x] P4-E2-T06: `ProgressView` — 4-section Progress tab: stagnation banners (amber/red), key lifts horizontal scroll, Swift Charts strength trend + exercise picker, grouped bar volume chart, 7×12 heatmap grid
- [x] P4-E2-T07: Progress tab wired into `ContentView` (tab 2); Settings shifted to tab 3; `programCompleteView` `selectedTab` updated accordingly
- [x] P4-E2-T08: `WorkoutSessionManager` post-session stagnation hook — `Task.detached(priority: .utility)` after `finishSession()` fetches last 50 sessions' set_logs and persists stagnation signals to UserDefaults
- [x] P4-E2-T09: `SessionPlanService` — `SessionPlanRequest` extended with `stagnation_signals: [StagnationSignal]` and `volume_deficits: [VolumeDeficit]`; loaded from UserDefaults before each `generateSession()` call
- [x] P4-E2-T10: `SystemPrompt_SessionPlan.txt` — added `STAGNATION SIGNALS` and `VOLUME DEFICIT SIGNALS` directive sections; AI adjusts programming for plateaued/declining exercises and volume shortfalls
- [x] P4-E2-T11: `ProgramOverviewView` — `WeekRowView` shows `"Week N of M"` phase-relative label using hardcoded phase ranges (Accumulation 1–4, Intensification 5–8, Peaking 9–11, Deload 12)

---

## Phase 4 Extension — Mid-Workout Navigation + Populated Day Detail

- [x] P4-E3-T01: Remove modal takeover — `ProgramDayDetailView` replaced `.fullScreenCover` with `.navigationDestination(isPresented:)` so `WorkoutView` is pushed onto the Program tab's `NavigationStack`; tab bar and standard back button remain visible throughout the session; no confirmation dialog or pause prompt on navigation events
- [x] P4-E3-T02: `ContentView` Workout tab wrapped in `NavigationStack`; `WorkoutView` no longer owns an inner `NavigationStack` for its `.idle/.preflight` state — toolbar items are provided by the enclosing stack
- [x] P4-E3-T03: Session state survives navigation — `WorkoutSessionManager.currentTrainingDayId` added (set in `startSession`/`resumeSession`, cleared in `resetToIdle`); `WorkoutViewModel.beginStatePolling()` made internal; `syncFromLiveSession()` added; `WorkoutView.task` calls `pullState()` then restarts polling if session is live on every view entry
- [x] P4-E3-T04: Rest timer navigation invariant confirmed — `restTimerTask` runs inside the actor, anchored to `restExpiresAt` (absolute `Date`); navigation events have no effect on countdown
- [x] P4-E3-T05: `ProgramDayDetailView` live session rendering — `refreshLiveSessionState()` reads `currentTrainingDayId` + `completedSets` from actor on every `.onAppear`; `ExerciseDetailCard` gains `liveSetLogs: [SetLog]` parameter that renders a "LOGGED" section (weight × reps × RPE per set) below the planned prescription grid when session is active for this day
- [x] P4-E3-T06: "Continue Workout" button — `bottomActionContent` shows "Continue Workout" (blue, full-width) when `isSessionActiveForThisDay && !isCompleted`; tapping pushes `WorkoutView` via `navigateToWorkout` NavigationLink which syncs from actor and shows live state
- [x] P4-E3-T07: `ARCHITECTURE.md` updated — navigation tree, session lifecycle invariants, and `ProgramDayDetailView` plan-only vs. live session rendering documented

---

## Phase 4 Extension — Gym Streak & Intensity Modulation (P4-E1)

- [x] P4-T01 [E1]: GymStreakService — consecutive training days streak computation
  - actor GymStreakService with computeStreak(userId:) -> StreakResult
  - fetchSessionHistory queries workout_sessions (completed=true, last 90 days)
  - StreakResult: currentStreakDays, longestStreak, streakScore (0–100), streakTier
  - streakScore = min(100, currentStreakDays * 8); tiers: 0–2 Cold, 3–5 Warming Up, 6–9 Active, 10+ On Fire
  - 6-hour cache with isStale(); Supabase unreachable → neutral score 50 (Warming Up)
  - StreakResult included in WorkoutContext payload on every inference call
  - GymStreakServiceTests.swift: 100% branch coverage on all tier boundaries and edge cases
- [x] P4-T02 [E1]: StreakScore edge case matrix — all boundary and interruption scenarios
  - No session history: streak=0, Cold, score=0
  - 1-day gap: rest day allowed, streak continues
  - 2+ day gap: streak resets to 0 / 1
  - Stale cache (>6h): re-fetch triggered
  - Supabase unreachable: last cache / neutral fallback
  - Two sessions same day: counted as 1 streak day
  - All scenarios covered by unit tests in GymStreakServiceTests.swift

---

## Phase 1 — Skip Feature + Training-Time Model Refactor

- [x] P1-Skip-T01: `TrainingDayStatus.skipped` — new case added; `TrainingDay.skippedAt: Date?` field; Codable round-trip preserves timestamp; state machine documented in model file and ARCHITECTURE.md
- [x] P1-Skip-T02: `ProgramViewModel.currentWeekIndex(in:)` — replaced calendar arithmetic (`Date().timeIntervalSince(createdAt)`) with training-time scan: returns index of first week containing a non-terminal (.completed or .skipped) day; never advances on calendar tick
- [x] P1-Skip-T03: `ProgramViewModel.markDaySkipped(dayId:weekId:)` — persistent skip; sets `.skipped` + `skippedAt = Date()`; saves to UserDefaults; updates `viewState`; replaces in-memory-only `skipDay()`
- [x] P1-Skip-T04: `ProgramViewModel.nextIncompleteDay` — updated to treat `.skipped` as terminal (alongside `.completed`); `snapshotCompletedDays` also preserves skipped days during regeneration
- [x] P1-Skip-T05: `TemporalContext` struct in `SessionPlanService` — 3 fields: `daysSinceLastSession`, `daysSinceLastTrainedByPattern`, `skippedSessionCountLast30Days`; `SessionPlanRequest` extended; assembled by `ProgramViewModel.generateDaySession()` from lift history + skipped-day count
- [x] P1-Skip-T06: `SystemPrompt_SessionPlan.txt` — TEMPORAL CONTEXT section added: gap-aware load guidance, per-pattern reintroduction rule, null first-session handling; no hardcoded load percentages
- [x] P1-Skip-T07: `DayCardView` in `ProgramOverviewView` — `.skipped` visual treatment: grey `xmark.circle.fill` icon, "SKIPPED" capsule, grey card background/border; `phaseProgressBar` counts `.skipped` toward `completedCount`
- [x] P1-Skip-T08: `ContentView` — `completedDayCount` includes `.skipped`; `onSkipSession` calls `markDaySkipped` (persistent); one-time migration notice alert (`training_time_migration_v1_shown` UserDefaults flag) shown once to existing users
- [x] P1-Skip-T09: `PreWorkoutView` — skip button now shows confirmation alert before calling `onSkipSession`
- [x] P1-Skip-T10: `ProgramDayDetailView` — "Skip this session" tertiary button for past unlogged days (`.generated`, `dayStatus == .past`); confirmation alert calls `viewModel?.markDaySkipped`; `.skipped` banner ("SESSION SKIPPED — TAP START WORKOUT TO RE-RUN") added; `completedDayCount` in fullScreenCover includes `.skipped`
- [x] P1-Skip-T11: `GymStreakService` Path B documented — service retained for UI tinting + AI context injection; skipped sessions are automatically excluded (no `workout_sessions` row created); comment updated in service file and ARCHITECTURE.md
- [x] P1-Skip-T12: `SkipFeatureTests.swift` — 18 tests: `TrainingDayStatus.skipped` encode/decode, `TrainingDay.skippedAt` round-trip, `TemporalContext` Codable (3 tests), `currentWeekIndex` training-time (4 tests), `nextIncompleteDay` (3 tests), `markDaySkipped` via UserDefaults fast-path (3 tests), golden prompt (1 test)


---

## Phase 2b — Per-Pattern Phase Tracking

- [x] P2b-T01: `PatternPhaseService.swift` — new file; `MovementPatternPhaseState` (persistence model) + `PatternPhaseInfo` (LLM DTO with snake_case CodingKeys) models; `sessionsRequired(for:daysPerWeek:)` uses Option B threshold `max(3, phaseWeeks × max(1, daysPerWeek / 2))`; `advancePhases(current:trainedPatterns:daysPerWeek:)` increments trained patterns, transitions on threshold, creates first-time patterns at accumulation with sessionsCompletedInPhase=1; `computeInitialPhases(from:daysPerWeek:)` migration path from lift history; `persist()/load()/clear()` via UserDefaults key `apex.pattern_phase_states`; deload is terminal (no phase beyond it)
- [x] P2b-T02: `TemporalContext` in `SessionPlanService` extended with 3 optional fields — `globalProgrammePhase: String?` (explicit null when nil, same policy as `daysSinceLastSession`), `globalProgrammeWeek: Int?` (explicit null when nil), `patternPhases: [String: PatternPhaseInfo]?` (absent when nil via `encodeIfPresent` — absent = "fall back to global phase"); custom `init(from:)` using `decodeIfPresent` for backward-compat decoding of pre-Phase-2b serialized data; explicit memberwise `init` added (required since custom `init(from:)` suppresses synthesized init)
- [x] P2b-T03: `ProgramViewModel.generateDaySession()` — migration gate: if `PatternPhaseService.load().isEmpty && !deepLiftHistory.isEmpty`, runs `computeInitialPhases` once on first post-update session and persists; assembles `[String: PatternPhaseInfo]` dict from loaded states; passes `globalProgrammePhase: week.phase.rawValue`, `globalProgrammeWeek: week.weekNumber`, `patternPhases: dict` into `TemporalContext` init call
- [x] P2b-T04: `WorkoutSessionManager.finishSession()` — post-session pattern phase hook: `Task.detached(priority: .utility)` after the stagnation hook; captures `daysPerWeek` on-actor before detach (avoids Swift 6 MainActor isolation warning); extracts trained movement patterns from `trainingDay.exercises` via `ExerciseLibrary.lookup()?.movementPattern`; calls `PatternPhaseService.advancePhases(current:trainedPatterns:daysPerWeek:)` and persists; skipped sessions structurally excluded (go through `markDaySkipped`, not `finishSession`)
- [x] P2b-T05: `ProgramViewModel` — `PatternPhaseService.clear()` added at top of `generateProgram()` and `generateMacroSkeleton()`; NOT added to `regenerateProgram()` (regeneration preserves completed days and their accumulated phases)
- [x] P2b-T06: `SystemPrompt_SessionPlan.txt` — PER-PATTERN PHASE TRACKING section added after TEMPORAL CONTEXT; key directives: use pattern-specific phase for sets/reps/RIR/rest (not global); global phase provides macro context for session structure and recovery bandwidth only; pattern in earlier phase = undertrained, needs more volume before intensity; pattern in later phase = ready for more intensity; absent `pattern_phases` falls back to global phase (backward compat); only note divergence in `session_notes` when a pattern is ≥2 phases behind global (max 20 words)
- [x] P2b-T07: `ProgramOverviewView` — collapsible `PatternProgressSection` inserted between phase progress bar and first week row; `@State private var isPatternProgressExpanded = false` (collapsed by default, not intrusive); header "PATTERN PROGRESS" with animated chevron toggle; each row shows: human-readable pattern name (snake_case → "Horizontal Push"), abbreviated phase badge capsule (`MesocyclePhase.accentColor`), session counter "N/M", 48pt mini progress bar; only renders when `PatternPhaseService.load()` is non-empty
- [x] P2b-T08: Tests — `PatternPhaseServiceTests.swift` (12 tests): `sessionsRequired` thresholds for 4- and 3-day/week schedules, phase transitions (accum→intens, intens→peak, peak→deload, deload terminal), skip safety (untrained patterns not advanced), migration (seeded 9-session history → intensification, empty history → empty), first-time pattern creation, UserDefaults round-trip, `clear()`; `SkipFeatureTests.swift` extended with 3 golden prompt assertions (`PER-PATTERN PHASE TRACKING`, `pattern_phases`, `current_phase`) and 2 TemporalContext Phase 2 Codable tests (round-trip with all fields, nil fields omit `pattern_phases`); all 32 tests pass
- [x] P2b-T09: Documentation — ARCHITECTURE.md §7a.9 "Per-Pattern Phase Tracking": why global phase is insufficient, `MovementPatternPhaseState` model table, Option B threshold table, no-regression-on-absence policy, migration strategy, service lifecycle; BACKLOG.md Phase 2b section with P2b-T01–P2b-T09

---

## Phase 3 — Mid-Session Resilience (23 Apr 2026)

Incident-driven fixes following FB-012 (Anthropic 529 outage, 22 Apr 2026). All fixes shipped in one batch; no regressions in existing test suite.

- [x] P3-MR-F01: `TransientRetryPolicy` — new `nonisolated enum` in `ProjectApex/AICoach/TransientRetryPolicy.swift`; exponential backoff (1s → 2s → 4s + up to 0.5s jitter) for HTTP 429, 502, 503, 504, 529; max 3 retries; non-transient codes propagate immediately; cooperative `Task.checkCancellation()` between attempts; `extractAnthropicRequestId(from:)` and `extractRetryAfter(from:)` parse bracket-prefix metadata encoded by `AnthropicProvider`; deployed to `AIInferenceService.prescribe()` + `prescribeAdaptation()` (inside existing 8s product timeout), `SessionPlanService.callAndDecodeSession()`, and `ExerciseSwapService.sendMessage()`; `MemoryService.classifyTags()` uses an equivalent inline two-attempt loop (raw URLSession call, not `LLMProvider`)
- [x] P3-MR-F02: Robust resume routing — `ProgramViewModel.findTrainingDay(byId:in:)` helper searches all weeks/days for a UUID; `WorkoutView.task` crash-recovery branch (Path B) now 3-case: (1) ID matches current day → silent resume as before; (2) ID found elsewhere in mesocycle → show "Session Mismatch" alert (Start Fresh / Discard); `ContentView` extended with `crashResumeToPass: PausedSessionState?` and `showOrphanedRecoveryAlert` state; "Resume" button now routes: match → pass `crashResumeToPass` to `WorkoutView`; found elsewhere → same; not found anywhere → "Session Not Found" alert (Save to History / Discard); `WorkoutView` receives explicit `resumeState:` parameter (Path A) for reliable crash recovery
- [x] P3-MR-F03: WAQ + Supabase merge on resume — `WriteAheadQueue.pendingSetLogs(forSession:)` filters and decodes in-flight `set_log` queue entries by `sessionId`; `WorkoutSessionManager.pendingSetLogs(forSession:)` exposes them cross-actor; `WorkoutViewModel.resumeSession()` rewritten with 4-step merge: (1) flush WAQ best-effort, (2) fetch remote set_logs from Supabase, (3) read WAQ pending logs, (4) merge by `SetLog.id` with WAQ winning on conflict; result sorted by `setNumber` and passed to manager
- [x] P3-MR-F04: RAG fetch latency instrumentation — `WorkoutSessionManager` gains `ragSignposter: OSSignposter` (subsystem: `com.projectapex`, category: `RAGFetch`) and `ragLogger: Logger`; `fetchRAGMemory(for:)` call in `completeSet()` bracketed with `beginInterval/endInterval` and `ContinuousClock` wall-clock elapsed log; visible in Instruments Time Profiler and Console; `// MARK: - Fix 4 Decision Point` comment documents p95 > 150ms threshold for async-offload promotion
- [x] P3-MR-F05: `FallbackLogRecord` — new `nonisolated struct FallbackLogRecord: Codable, Sendable` in `ProjectApex/Services/FallbackLogRecord.swift`; fields: `callSite`, `httpStatus`, `anthropicRequestId`, `reason`, `sessionId`, `timestamp`; emits via `os.Logger(subsystem: "com.projectapex", category: "Fallback")`; static call-site constants for all 5 LLM entry points; factory methods `from(callSite:error:sessionId:)` and `from(callSite:fallbackReason:sessionId:)` parse bracket-prefix metadata from `LLMProviderError.httpError` body; `AnthropicProvider.complete()` now encodes `[request-id:xxx][retry-after:N]` prefixes on non-2xx error bodies; emitted at every `.fallback` / error path in `AIInferenceService`, `SessionPlanService`, `ExerciseSwapService`, and `MemoryService`
- [x] P3-MR-F06: Swap chat error classification — `ExerciseSwapService.sendMessage()` catch block replaced with three classified branches: `URLError.notConnectedToInternet / .networkConnectionLost` → "You appear to be offline…"; `LLMProviderError.httpError` with transient code → "The AI service is temporarily busy…"; all other errors → "Something went wrong…"; private `appendAssistantError(_:)` helper DRYs the `messages.append` pattern; `FallbackLogRecord` emitted in each branch
- [x] P3-MR-DOC: Documentation — ARCHITECTURE.md §7.5 "Mid-Session Resilience" added (6 subsections: TransientRetryPolicy backoff schedule, 3-case resume routing, WAQ+Supabase merge strategy, RAG latency instrumentation, FallbackLogRecord schema, swap chat error classification); §13.4 Retry Policies table updated with new rows for all LLM retry scenarios

---

## Phase 5 — Trainee Model in Production

[PRD #71](https://github.com/thearnavmenon/ProjectApex/issues/71). Persistent structured behavioural model per user, server-side, consulted on every prescription. Supersedes the Phase 1 service trio (StagnationService, VolumeValidationService, PatternPhaseService) and the per-inference reconstruction of user state from raw set logs. ADR-0005 is the architectural anchor; ADR-0006 (server-side idempotency), ADR-0008 (late-arrival watermark), ADR-0013 (two-stage classifier isolation) are the load-bearing companions.

### 2A — Rule modules + orchestrator (server-side)

- [x] P5-T01: `supabase/functions/_shared/*` — pure rule modules. ewma-engine (Epley × EWMA per exercise, ADR-0005), stimulus-classifier (Q3 intent/reps/rpe → NM/metabolic dimension), recovery-curve (ADR-0010 tau curves with clock-skew clamp), plateau-verdict (hybrid two-track e1RM × volume-load, ADR-0009), prescription-accuracy (rep-error + gap-bucket stratification, ADR-0014), transfer-regression (log-log fit + Spearman flag SE-widening, Q10), fatigue-interaction (cross-pattern session-pair confidence, ADR-0005), phase-advance (per-pattern plateau-aware cyclic advance, ADR-0011), transition-mode-expiry (cadence-aware composition, ADR-0015), global-phase-advance (ADR-0012), note-classifier (ADR-0013 Stage 2 LLM-driven form-degradation + limitation lifecycle). Each module is unit-tested in isolation in its `*_test.ts`
- [x] P5-T02: A12 (#83) — Stage 1 orchestrator — `applySession` in `supabase/functions/update-trainee-model/index.ts`. Single transaction: idempotency PK insert → load + FOR UPDATE → watermark check → rule pipeline → UPSERT. Cached snapshot return on PK conflict; late-arrival refusal with event emit on watermark fail
- [x] P5-T03: A13 (#84) — Stage 2 classifier driver — `runStage2` second transaction. Failure-isolated per ADR-0013 ("HTTP returns after Stage 1 commits; Stage 2 failure emits `classifier_failed` and swallows"). Composes form-degradation lifecycle + limitation lifecycle from `note-classifier`

### 2 wiring — integration audit recovery (2026-05-09 → 2026-05-10)

First end-to-end replay attempt for G1 surfaced 7 unwired rule modules: the HTTP path was a Phase 1 stub, unit tests passed locally, production silently no-op'd. Audit doc + 10 wiring slices closed the gap.

- [x] P5-W01: A14 (#109) — wire `handleRequest` → `applySession`; bootstrap UPSERT on first apply (replaces UPDATE that silently no-op'd on empty `trainee_models`); JSONB encoding via `tx.json()` (replaces `${JSON.stringify(obj)}::jsonb` double-encoding pattern)
- [x] P5-W02: Phase 2 integration audit doc (#112) — `docs/phase-2-integration-audit-2026-05-10.md` cataloguing the 7 cold paths + revised slice plan
- [x] P5-W03: A15 (#110) — pattern profile bootstrap from `session_payload.set_logs[]`; `_shared/exercise-library.ts` port (71-entry exercise_id → MovementPattern mirror of Swift `ExerciseLibrary.swift`)
- [x] P5-W04: A16 (#113) — end-to-end smoke test (`smoke_test.ts` POSTs over HTTP, reads back via SQL) + CI Edge Function Tests (Deno) job in `.github/workflows/ci.yml`. Growing-oracle pattern: each subsequent wiring slice extends the smoke's assertion set
- [x] P5-W05: A17 (#116) — wire `ewma-engine` → `ExerciseProfile.e1rmCurrent`; `applyPerExerciseRules` helper bootstraps missing exercises with ADR-0005 defaults
- [x] P5-W06: A18 (#118) — wire `stimulus-classifier` → `RecoveryProfile.last*StimulusAt`; per-set timestamp bump on neuromuscular / metabolic / both classifications
- [x] P5-W07: A19 (#120) — wire `recovery-curve` → `RecoveryProfile.*Readiness`; reads bumped timestamps, computes curve at `incomingLoggedAt`; null timestamp → readiness 1.0
- [x] P5-W08: A20 (#122) — wire `plateau-verdict` → `PatternProfile.trend`; new `weeklyVolumeLoadHistory: []` bootstrap field; ISO-week bucketing for volume-load track; per-pattern e1rm history derived on-the-fly from post-A17 `topSets`
- [x] P5-W09: A21 (#124) — wire `prescription-accuracy` aggregator → `prescriptionAccuracy[pattern][intent]` per-cell accumulators; `shouldContribute` 6-criteria filter; sliding 30-obs window with per-bucket sub-array sync
- [x] P5-W10: A22 (#126) — wire `transfer-regression` → `transferRegressions[from][to]`; v1 alpha-cohort same-session pair detection; NaN-guard for n<2 placeholder fit
- [x] P5-W11: A23 (#128) — wire `fatigue-interaction` → `fatigueInteractions[]` + `lastSessionPatternPerformance[]`; pre-A17 exercises snapshot preserved for performanceDeltaPct compute

### Verification gate

- [x] P5-G01: G1 verification gate (#85) — replay scaffold preserved at `scripts/phase2-verification-gate/` as v2.x reference artifact (replay.ts, run-comparisons.ts, extract-legacy-outputs.py, README); fixtures gitignored + deleted locally per cleanup obligation. Verdict report at `docs/phase-2-verification-gate-report.md`: **PASS-CONDITIONAL** — Phase 2 production HTTP path wired + smoke-tested end-to-end; the literal cross-cohort comparison gate (3 automated comparisons + 5 manual coaching-judgment items) reframed as 10 v2.x watch-items contingent on alpha cohort growing beyond n=1

### Post-G1 hygiene

- [x] P5-H01: Stage 2 JSONB double-encoding fix (`runStage2` writeback) — same pattern A14 fixed in main UPSERT, still latent in Stage 2; swapped to `tx.json()`; 5 test-seed sites in `orchestrator_test.ts` converted in tandem (were masking the production bug via `parseJsonbColumn` defensive parse)
- [x] P5-H02: Stale "Phase 1 stub returns {}" comments in `TraineeModelUpdateJob.swift` — A14 removed the stub; comments updated to post-A14 behavior
- [x] P5-H03: `FallbackLogRecord` WAQ-enqueue TODO clarified — WAQ now generally available; reframed as a slice candidate when centralised diagnostics surface is needed
- [x] P5-H04: Flaky `test_retryPath_permanentErrors_failsFastWithoutRetry` — wall-clock `elapsed < 0.5s` assertion (flaked at ~1.0s on loaded CI runners) replaced with provider call-count assertion. Mock provider converted to thread-safe class with `callCount: Int`
- [x] P5-H05: ARCHITECTURE.md staleness banner (last reviewed 2026-03-25, pre-Phase-2) — directs readers to current Phase 2 sources (README, ADRs, audit doc, G1 report); old content preserved as Phase 1 reference
- [x] P5-H06: Repo presentation pass — first-time README, charcoal + signal-yellow visual identity, ASCII architecture diagram, ADR-anchored architecture notes, status table; `NOTICE.md` (all rights reserved); `gh repo edit` description + 9 topics; 3 top-level orphan ruby script duplicates removed
- [x] P5-H07: `.DS_Store` removed from disk (gitignored but lingering)

### 2B — Legacy → trainee cutover

Trainee model populates on every session-apply; iOS prompts swapped from legacy services to digest. B1–B4 ran 2026-05-13 → 2026-05-13, interleaved with the MuscleProfile producer slice (#156) between B1 and B2 (`model_json.muscles` was iOS-readable but EF never wrote it; B2 needed it).

- [x] P5-B01: B1 (#86) — stagnation cutover, PR #160 + delete-StagnationService PR (closes #61). `SystemPrompt_Inference.txt` v4.9→v5.0 + `SystemPrompt_SessionPlan.txt` v1.x→v2.0 PER-PATTERN TREND block; `consecutiveForceDeloadsOnPattern≥2` coaching cue surfaced; `StagnationService.swift` + tests deleted; β prompt-anchor test suite added in `TraineeModelDigestTests`
- [x] P5-B02: B2 (#87) — volume cutover, PR #170. `VOLUME DEFICIT` block now reads `per_muscle_summary[].volume_deficit`; `VolumeValidationService.swift` deleted; depended on #156's `MuscleProfile` producer landing first
- [x] P5-B03: B3 (#88) — pattern phase cutover, PR #174. `per_pattern_summary[].current_phase` + `current_phase_session_count` replace `pattern_phase_states`; `PatternPhaseService.swift` deleted; force-deload-as-transition signal preserved per ADR-0011 §(b); `WorkoutSessionManager` PatternPhaseService advance hook removed
- [x] P5-B04: B4 (#89) — full digest collapse, PR #179 + cycles 7-14 (`3cf4f06` Inference rewiring + `WeeklyFatigueSummary` delete; cycles 9b-14 added PRESCRIPTION ACCURACY / CROSS-EXERCISE TRANSFER / CROSS-PATTERN FATIGUE INTERACTIONS / ACTIVE LIMITATIONS / FORM-DEGRADATION FLAG blocks). `WorkoutContext` restructured around `TraineeModelDigest`; `lastGlobalPhaseAdvanceFiredAtSessionCount` surfaced. Calibration-review UI deliberately deferred (separate slice; depends on goal-renegotiation flow).

### 2C — Post-B4 stabilisation + late-May/2026-06-01 dispatch

Cleanup and bug-fix sweeps following B4. The 2026-05-31 operator audit surfaced ~10 issues filed between #185–#212; the 2026-06-01 dispatch closed them in batches.

**EF / digest plumbing fixes:**

- [x] P5-C01: #156 — MuscleProfile producer, PR #168. New `applyPerMuscleRules` + bootstrap + per-set muscle attribution; Q4 focusWeight + worst-across-patterns stagnation aggregation. Substantive slice surfaced as the fourth contract-drift gap during #146 work
- [x] P5-C02: #146 contract-drift coordinated PR series (#149/#150/#152) — EF emits 5 PatternProfile shape-gaps; iOS defensive decode for `goal` with `GoalState.placeholder` sentinel; EF bootstrap now emits `pattern`/`rpeOffset`/`recovery`/`confidence` per-pattern. Sixth gap (casing) closed via separate spinoff
- [x] P5-C03: #161 — canonicalise `exercise_id` at EF boundary + backfill legacy keys
- [x] P5-C04: #169 — EF boot fix post-#156: missing `computeFocusWeight` export
- [x] P5-C05: #175 / #176 — mirror `session_count` column → `model_json.totalSessionCount` JSONB key (cross-platform contract)
- [x] P5-C06: #177 — collapse EF `transferRegressions` dict → `transfers` list to match cross-platform contract
- [x] P5-C07: #194 — cleanup: drop transferRegressions legacy fallback + migration test (post-#177)

**iOS / FK / persistence fixes:**

- [x] P5-C08: #183 — use `mesocycle.id` as `programs.id` to prevent FK violations
- [x] P5-C09: #182 — Clear button for Supabase service key in Developer Settings (precedes #191 deletion)
- [x] P5-C10: #196 (#158) — update stale `XCTAssertNil` to assert placeholder semantics post-#149
- [x] P5-C11: #197 (#173) — backfill null-confidence PatternProfiles to `bootstrapping` (EF)
- [x] P5-C12: #199 (#38) — make `APEX_INTEGRATION_TESTS` opt-in (`isEnabled NO` in shared scheme) + CLAUDE.md doc update
- [x] P5-C13: #200 (#39) — delete `XCTAssertLessThan(elapsed, 8.0)` from live API test (wrong for retry paths)
- [x] P5-C14: #201 (#185) — detect PATCH 200 no-op via `performExpectingRow` + `SupabaseError.patchNoMatch`
- [x] P5-C15: #202 (#188) — surface program-persist failures via non-blocking sync-error banner
- [x] P5-C16: #207 (#205) — wrap integration teardown `deactivatePrograms` in `try?`

**nonisolated-deinit series (#37 cascade — `swift_task_deinitOnExecutorImpl` crash prevention):**

- [x] P5-C17: #198 (#37) — `nonisolated deinit {}` on 4 @MainActor view models (initial batch)
- [x] P5-C18: #208 (#204) — `LiveSessionWatcher` (first wave grep-and-report)
- [x] P5-C19: #209 (#203) — `AppDependencies`
- [x] P5-C20: #214 (#210) — `ProgramViewModel`
- [x] P5-C21: #215 (#212) — `LateArrivalNotificationQueue`
- [x] P5-C22: #216 (#211) — `TraineeModelLocalStore` (closed the cascade; final unpatched site)
- Verified-not-applicable (already patched, closed without PR): #217 `WorkoutViewModel`, #218 `ProgressViewModel`, #219 `ScannerViewModel`

**Architecture / decisions:**

- [x] P5-C23: #206 (#191) — remove `SupabaseClient.serviceKey` entirely — 5-layer architectural deletion of client-side service-role bypass path
- [x] P5-C24: PR #213 — ADR-0016 (client cannot bypass RLS) codifies the invariant that landed in #191
- [x] P5-C25: #223 (#159) — Inference prompt consolidation: `SystemPrompt_Inference.txt` becomes canonical source; loader wired; production callers propagate via new `.systemPromptUnavailable` `FallbackReason` per L6 grilling lock (ADR-0007 no-silent-fallback shape)
- [x] P5-C26: #224 (#178) — HEAVY REASSESSMENT block + iOS `HeavyReassessmentSignal` digest projection derived from the existing server-side `lastGlobalPhaseAdvanceFiredAtSessionCount`; delete vestigial `TraineeModel.reassessmentRecords` field (write-orphan)

### 2D — Open follow-ups (things to do)

Captured here so the BACKLOG sweep on 2026-06-01 has a single landing surface. Each item is filed as a GitHub issue OR explicitly *not yet filed* below with a reason.

**Filed / awaiting product or design direction:**

- [x] P5-D01: #220 — extract `PromptLoader`. **DONE 2026-06-08** (PR #272). Consolidated **5** identical `loadSystemPrompt() throws` loaders (the 3 named + `ProgramGenerationService` + `MacroPlanService`, found by grep) onto `PromptLoader.load(_:)`. Behavior-preserving; each keeps its typed error + post-processing. The 6th site (ExerciseSwapService, P5-D08) is structurally different and left for that ticket.
- [ ] P5-D02: #221 — adopt `USER-REPORTED SIGNALS` section in production Inference prompt? Surfaced by #159 Path A as a .txt-only section that has never run in production. Needs product decision (is this a signal we want, and what's the input shape?).
- [ ] P5-D03: #222 — adopt expanded equipment-aware weight-increment rules in production Inference prompt? Same shape as P5-D02 (.txt-only expansion surfaced by #159).
- [x] P5-D04: Tier 3 needs-triage spinoffs (`#184`, `#186`, `#187`, `#189`, `#190`, `#192`) — all closed in the 2026-06-02 → 2026-06-04 functional-defect sweep (§2E).
- [ ] P5-D05: Phase 2 follow-ups — `#167` and `#151` closed in the functional-defect sweep (§2E); `#164`, `#165`, `#166` (MuscleProfile `volumeTolerance` cadence-scaling / EWMA-update / `confidence` lifecycle) remain open.
- [x] P5-D09: #268 — consolidate the two ad-hoc `MovementPattern` humanizers (`TrendBannerView`, `ProgramOverviewView`) onto `.displayName` (#258 Slice C, #261). **DONE 2026-06-08** (PR #271). Behavior-preserving.
- [ ] P5-D10: #269 — numeric-projection EDITING on the goal-review screen, deferred from #258 Q1. **Blocked on #166** (confidence lifecycle): `patternProjections` never populates until confidence advances past `bootstrapping`, so there is nothing to edit yet.

**Not yet filed — surfaced in 2026-06-01 dispatch, awaiting decision:**

- [x] P5-D06: heavy-reassessment banner + goal-review screen + ack writer — **SHIPPED & CLOSED 2026-06-08** as #258 (8 slices, PRs #259–#266). Full build narrative in §2F. Spinoffs filed: P5-D09 (#268), P5-D10 (#269).
- [x] P5-D07: One-shot DB migration to strip legacy `reassessmentRecords` JSONB key from existing rows. **DONE 2026-06-08** (PR #276, migration `20260608120000_strip_legacy_reassessment_records.sql` + doc-only reverse). Applied to prod (deploy job "Apply migrations" green after an ef-test "Setup Supabase CLI" flake re-run). Verbatim clone of the proven `drop_orphan_top_level_recovery` idiom; adversarially reviewed clean. The fixture `docs/fixtures/trainee-model-snapshot.json` keeps its `reassessmentRecords: []` deliberately — decode-tolerance coverage.
- [x] P5-D08: `ExerciseSwapService` adopted `PromptLoader` (the 6th/last prompt site). **DONE 2026-06-08** (PR #274). Preserved its graceful fallback via `(try? PromptLoader.load(...)) ?? nil` (both read-error throw and not-found collapse to the stub) + comment-stripping. Verified behavior-preserving (all prompt `.txt` ship flat at the bundle root). `Bundle.main.url(forResource:` now lives ONLY in `PromptLoader.swift` — every prompt site consolidated.

**Operator actions (not code changes):**

- [ ] Keychain cleanup: if `.supabaseServiceKey` is present on a user's machine from pre-#191 days, clear via Developer Settings → Clear button or `security delete-generic-password -s com.projectapex.keychain.supabaseServiceKey`. Verified absent on Arnav's machine 2026-06-01 (exit 44 = not found).

### 2E — Functional-defect bug sweep (2026-06-02 → 2026-06-04)

The 12 functional-defect issues from the 2026-05-31 operator audit (carried in §2D as P5-D04/P5-D05), fixed branch-per-issue with PR-before-close. Local test suite is the source of truth — the CI iOS "Build & Test" job is known-flaky and gates nothing. Each issue closed via its PR's `Closes #N` keyword unless noted.

- [x] P5-E01: #151 — EF `PATTERN_TRAINS_JOINTS` joint-key drift → snake_case `lower_back`. PR #227.
- [x] P5-E02: #167 — `derivedTrainedSets` rejects non-canonical `primary_muscle`. PR #228. (Sibling leak ~`update-trainee-model/index.ts:1968` flagged grep-and-report, not fixed.)
- [x] P5-E03: #192 — macro-skeleton `normalizeDayLabel` collapses non-alphanumerics to snake_case. PR #229. (Sibling day-label mint point in `ProgramGenerationService` flagged grep-and-report.)
- [x] P5-E04: #186 — weekly-fatigue fetch queries `set_logs` by `session_id`, not `user_id` (no such column → had been a swallowed HTTP 400). PR #230.
- [x] P5-E05: #55 + #184 — WAQ `clearAll()`/`flush()` mid-retry race + dead-letter store instead of silent drop after retry exhaustion. PR #232.
- [x] P5-E06: #171 — early-exit writes a consistent `(status, completed)` pair (`partial`/`false`, not the hardcoded `completed`) + feeds early-exit sets to the model. PR #233.
- [x] P5-E07: #190 — `pauseSession` is non-blocking: persist `PausedSessionState` first, fire the server sync (flush + status PATCH) in a detached Task, then reset to idle. Regression test proven to fail pre-fix (0.64 s) / pass post-fix. PR #235.
- [x] P5-E08: #172 + #141 — regen feeds the user's historical `day_type` labels into the macro-plan prompt so it reuses their convention instead of inventing a fresh one that detaches lift history. **ADR-0017.** PR #236. (#141 closed as a duplicate — its real cause was this label drift, not `program_id` scoping.)
- [x] P5-E09: #189 — atomic `deactivate_and_insert_program` `SECURITY INVOKER` RPC (one transaction; upsert-idempotent on retry; returns the program id) replaces the non-transactional deactivate-then-insert. Forward migration `20260604061428_…` + doc-only reverse migration; deployed to the linked Supabase (db push + EF tests green). **ADR-0018.** PR #237.
- [x] P5-E10: #187 — closed as **not-a-bug** (wontfix): `mesocycle_json` stores `total_weeks` (snake_case, consistent with the whole blob); the report queried `'totalWeeks'` (camelCase). The model round-trips cleanly and `programs.weeks` is the source of truth. No code change.

Supporting work in the same window:

- [x] Build hotfix: removed 2 illegal `nonisolated deinit`s that had broken `main`. PR #231.
- [x] Greened 2 pre-existing failing tests (#181 stale id, #178 brittle whitespace). PR #234.

Cross-cutting sites surfaced but left **grep-and-report** (awaiting authorization, per CLAUDE.md Process commitment 2): #167 sibling `primary_muscle` leak in `update-trainee-model/index.ts`; #192 sibling day-label mint point in `ProgramGenerationService`; #172 second `generateSkeleton` caller in `OnboardingView` (safe as-is — no history at onboarding); #189 `SupabaseClient.deactivatePrograms` now production-unused but test-covered (retained, not deleted).

### 2F — P5-D06 heavy-reassessment feature (2026-06-08)

The "your training leveled up" goal check-in (#258). The server's global-phase-advance (GPA) signal already fed the SessionPlan LLM prompt (#178), but with no UI surface, no acknowledgment, and no goal-review screen — so the coach nagged "revisit your targets" for ~6 sessions per fire with nowhere to go. Scoped via a 6-question `grill-me` session (each question independently reviewed by a second agent — two recommendations per question, best one taken), locked to a PRD, and built as 8 tracer-bullet slices: branch-per-slice, PR-before-merge, auto-merged on local-green (iOS Build & Test is the known flake; EF deploy is gated only on the reliable `ef-test`).

- [x] A: #259 — `acknowledgedTriggeringSessionCounts: Set<Int>` on `TraineeModel` (camelCase JSONB, `.sorted()` encode, tolerant `decodeIfPresent ?? []`) + suppression in `deriveHeavyReassessmentSignal` (checks the *current* triggering count, so a later GPA fire still surfaces) + fixed the now-false comment at `TraineeModelDigest.swift:96-103`.
- [x] B: #260 — ack write path. `update-trainee-goal` EF gains optional `acknowledge_triggering_session_count`; idempotent `COALESCE(...,'[]') || to_jsonb(ack)` append guarded by `WHERE NOT (... @> ...)` (the COALESCE is load-bearing — bare `->` `@>` returns NULL, a three-valued-logic trap that would silently never append the first ack). iOS top-level snake_case payload field, absent-when-nil. DB integration tests in `orchestrator_test.ts`.
- [x] C: #261 — `MovementPattern.displayName` (exhaustive title-cased map). Grep flagged two ad-hoc humanizers → spinoff #268 (P5-D09).
- [x] D+E1: #262 — pre-workout "leveled up" banner (distinct non-amber accent, names ≤3 patterns + "and more", mandatory empty-list fallback) + tested pure `HeavyReassessmentBannerCopy` helper. Dismiss is transient (no ack).
- [x] F1: #263 — `TraineeModelService.acknowledgeReassessment` — the load-bearing LOCAL-cache banner-hide. The EF returns `{ok, goal}`, not the model, so the server round-trip can't refresh the cache; Save mutates the cached model + `store.save()` so the banner (and the LLM block) vanish immediately.
- [x] F2: #264 — `GoalReviewView` screen (edit goal statement + focus-area multi-select, read-only capability numbers) + tested pure `makeGoalPayload` helper.
- [x] E2: #265 — wire the banner "Review goals" CTA → the screen carrying `triggeringSessionCount`; re-derive the signal on sheet dismiss so a saved goal hides the banner (a cancel leaves it).
- [x] G: #266 — prompt edits: `revisit targets` → the real "Review goals" label, empty-patterns fallback, re-blessed the `sessions_since_triggered` 2+ branch for the ack world, kept the no-numeric-targets guardrail. Golden-locked with anchors.

Verification: each slice TDD-first; final integration build on merged `main` green (122 XCTest + the MovementPattern/HeavyReassessmentBannerCopy Swift-Testing suites, 0 failures). EF live via CI deploy on merge to `main`. Diary entry #267. Slice resequencing vs the locked plan: F split into F1 (logic) + F2 (UI); D folded into D+E1; Q5's false-comment fix landed in A, so G was prompt-text only. Closed after in-app confirmation. Spinoffs filed: #268 (P5-D09, humanizer consolidation, `ready-for-agent`), #269 (P5-D10, numeric-projection editing, blocked on #166).
