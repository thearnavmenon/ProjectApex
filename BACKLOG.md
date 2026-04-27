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
