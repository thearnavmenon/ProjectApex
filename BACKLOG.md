# Project Apex — Backlog

---

## Phase 0 — Infrastructure & AI Spine

- [x] P0-T01: KeychainService — API key storage & retrieval
- [x] P0-T02: DeveloperSettingsView — manual API key entry UI
- [ ] P0-T03: Wire AnthropicProvider with real API key end-to-end
- [x] P0-T04: GymProfile Codable schema — lock & unit test round-trip
- [ ] P0-T05: AppDependencies DI container — wire all services at launch
- [ ] P0-T06: WorkoutContext assembly — unit test full JSON serialization
- [ ] P0-T07: AIInferenceService integration test — real API, mock context
- [ ] P0-T08: EquipmentRounder — expand unit tests to 100% AC coverage
- [ ] P0-T09: CI pipeline — GitHub Actions, test run on push

---

## Phase 1 — Gym Scanner — Live

- [ ] P1-T01: SupabaseClient — core CRUD and RPC wrapper
- [ ] P1-T02: Live VisionAPIService — replace MockVisionAPIService
- [ ] P1-T03: EquipmentMerger — multi-frame deduplication logic
- [ ] P1-T04: GymProfile → Supabase persist & fetch
- [ ] P1-T05: EquipmentConfirmationView — edit, add, delete items
- [ ] P1-T06: Re-scan flow with confirmation dialog
- [ ] P1-T07: EquipmentMerger unit tests

---

## Phase 2 — Macro-Program Engine

- [ ] P2-T01: WorkoutProgram data models — Mesocycle, Week, TrainingDay, Exercise
- [ ] P2-T02: ProgramGenerationService actor — LLM call, decode, validate
- [ ] P2-T03: Equipment constraint validation — post-generation pass
- [ ] P2-T04: Supabase programs table — persist & fetch mesocycle
- [ ] P2-T05: ProgramOverviewView — 12-week calendar grid
- [ ] P2-T06: ProgramDayDetailView — drill-in exercise list
- [ ] P2-T07: MacroGeneration system prompt — tune and lock
- [ ] P2-T08: Regenerate Program — settings action
- [ ] P2-T09: SwiftData local cache for offline program access

---

## Phase 3 — Active Workout Loop

- [ ] P3-T01: WorkoutSessionManager actor — session lifecycle
- [ ] P3-T02: WorkoutViewModel — bridge actor state to SwiftUI
- [ ] P3-T03: PreWorkoutView — readiness display, session start
- [ ] P3-T04: ActiveSetView — prescription card, Set Complete
- [ ] P3-T05: RestTimerView — countdown, haptics, AI arrival update
- [ ] P3-T06: Set log writes — Supabase + local write-ahead queue
- [ ] P3-T07: Fallback path UI — "Coach offline" banner
- [ ] P3-T08: PostWorkoutSummaryView — volume, PRs, adjustments
- [ ] P3-T09: End session early — partial session logging
- [ ] P3-T10: Exercise swap — manual substitution within session

---

## Phase 4 — Polish & MVP Hardening

- [ ] P4-T01: HealthKitService — permissions, biometrics fetch, ReadinessScore
- [ ] P4-T02: ReadinessScore — edge case handling matrix (TDD 11.4)
- [ ] P4-T03: SpeechService — on-device STT + Whisper fallback
- [ ] P4-T04: MemoryService — embedding pipeline write path
- [ ] P4-T05: MemoryService — RAG retrieval read path + integration
- [ ] P4-T06: Voice note UI — mic button, live transcript modal
- [ ] P4-T07: Memory event taxonomy — auto-generated structured events
- [ ] P4-T08: HRV 30-day baseline computation
- [ ] P4-T09: App launch flow — onboarding → scan → generate → workout
- [ ] P4-T10: 5-session stability run — manual QA pass
