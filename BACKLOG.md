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
- [x] P3-T07: Fallback path UI — "Coach offline" banner
- [x] P3-T08: PostWorkoutSummaryView — volume, PRs, adjustments
- [x] P3-T09: End session early — partial session logging
- [ ] P3-T10: Exercise swap — manual substitution within session

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
