# Project Apex — Architecture Reference
### Combines: Technical Design Document v1.0 + UI/UX Specification v1.0
### Platform: iOS 26+ | Last Updated: 2026-03-25

---

# PART 1: TECHNICAL DESIGN DOCUMENT

## Table of Contents

1. [Document Metadata & Purpose](#1-document-metadata--purpose)
2. [System Architecture Overview](#2-system-architecture-overview)
3. [iOS Application Architecture](#3-ios-application-architecture)
4. [Data Models & Schema Definitions](#4-data-models--schema-definitions)
5. [Feature Module: Gym Scanner](#5-feature-module-gym-scanner)
6. [Feature Module: Macro-Program Generation](#6-feature-module-macro-program-generation)
7. [Feature Module: Active Workout & AI Loop](#7-feature-module-active-workout--ai-loop)
7a. [Feature Module: Progress & Analytics](#7a-feature-module-progress--analytics)
8. [AI & Inference Architecture](#8-ai--inference-architecture)
9. [RAG Memory System](#9-rag-memory-system)
10. [Backend & Database Architecture](#10-backend--database-architecture)
11. [HealthKit Integration](#11-healthkit-integration)
12. [Security & Key Management](#12-security--key-management)
13. [Error Handling & Resilience Patterns](#13-error-handling--resilience-patterns)
14. [Testing Strategy](#14-testing-strategy)
15. [Performance Budgets & Targets](#15-performance-budgets--targets)
16. [Build, Deployment & Configuration](#16-build-deployment--configuration)
17. [Known Risks & Mitigations](#17-known-risks--mitigations)
18. [Appendix: Sequence Diagrams](#18-appendix-sequence-diagrams)

---

## 1. Document Metadata & Purpose

### 1.1 Purpose

This Technical Design Document (TDD) is the authoritative engineering reference for Project Apex. It translates the requirements specified in PRD v1.0 into concrete architectural decisions, data contracts, module interfaces, and implementation patterns. Every engineer contributing to the codebase should read this document before writing a line of production code.

The PRD answers *what* to build and *why*. This TDD answers *how*.

### 1.2 Document Scope

This TDD covers the complete MVP as defined in PRD v1.0, including:

- iOS application architecture (SwiftUI, actor model, state management)
- All five feature modules and their internal designs
- AI inference pipeline end-to-end (context assembly → LLM call → validation → rounding → UI)
- RAG memory system (embedding pipeline, vector store, retrieval)
- Supabase backend schema, RLS policies, and RPC functions
- HealthKit integration and ReadinessScore computation
- Security model (Keychain, API key lifecycle)
- Error handling contracts and fallback chains
- Testing strategy, coverage targets, and CI configuration

### 1.3 Relationship to PRD

All section references in this document (e.g., "per FR-004-D") refer to the functional requirements table in PRD v1.0. If a requirement is not mentioned here, it is implemented straightforwardly with no special architectural consideration.

### 1.4 Versioning Policy

This document is versioned in lockstep with the codebase. Any architectural change that affects a public interface, data contract, or API payload schema must update this document before the corresponding PR is merged.

---

## 2. System Architecture Overview

### 2.1 High-Level Component Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            iOS Application                               │
│                                                                          │
│  ┌──────────┐  ┌──────────┐  ┌─────────────────┐  ┌──────────────────┐ │
│  │ Scanner  │  │ Program  │  │ Workout Session  │  │ Progress &       │ │
│  │ Feature  │  │ Feature  │  │ Feature          │  │ Analytics        │ │
│  │ Module   │  │ Module   │  │ Module           │  │ Feature Module   │ │
│  └────┬─────┘  └────┬─────┘  └────────┬─────────┘  └────────┬─────────┘ │
│       │             │                 │                      │           │
│  ┌────▼─────────────▼─────────────────▼──────────────────────▼─────────┐ │
│  │                          Service Layer                               │ │
│  │  AIInferenceService │ HealthKitService  │ MemoryService              │ │
│  │  SupabaseClient     │ GymFactStore      │ SpeechService              │ │
│  │  GymStreakService   │ StagnationService │ VolumeValidationService    │ │
│  │  SessionPlanService │ MacroPlanService  │ WriteAheadQueue            │ │
│  └────┬────────────────┬─────────────────────────────────────┬──────────┘ │
│       │                │                                     │            │
└───────┼────────────────┼─────────────────────────────────────┼────────────┘
        │                │                                     │
        ▼                ▼                                     ▼
 ┌─────────────┐  ┌──────────┐                    ┌───────────────────┐
 │  OpenAI /   │  │ Apple    │                    │  Supabase          │
 │  Anthropic  │  │ HealthKit│                    │  PostgreSQL        │
 │  APIs       │  │          │                    │  + pgvector        │
 └─────────────┘  └──────────┘                    └───────────────────┘
```

### 2.2 Architectural Principles

**Principle 1 — AI-First, Not AI-Only**: Every AI call has a deterministic local fallback. The app must be usable (degraded but not broken) with zero network connectivity.

**Principle 2 — Actor-Based Concurrency**: All stateful services that manage mutable data shared across async contexts are implemented as Swift `actor` types. `struct` + `Sendable` is used for all data models. No `@unchecked Sendable` in production code.

**Principle 3 — Strict Data Contracts**: All AI input and output is validated against typed Swift `Codable` schemas. The LLM is never trusted to produce safe output without client-side validation.

**Principle 4 — Equipment-Constrained Output**: AI weight prescriptions are always in continuous space; physical rounding to available weights is applied client-side via `DefaultWeightIncrements` (commercial gym defaults) and `GymFactStore` (user-confirmed corrections) before any value is shown to the user or written to the database.

**Principle 5 — Persistent Stateful Memory**: The app is not a stateless LLM chat wrapper. Every workout enriches the vector memory store. The AI is always given historical context; it is never inferring cold.

**Principle 6 — Privacy by Default**: HealthKit data never leaves the device except as aggregated numeric values embedded in the LLM inference payload. Raw biometric time-series are not stored in Supabase.

### 2.3 Technology Decisions Log

| Decision | Chosen Approach | Rejected Alternative | Rationale |
|---|---|---|---|
| Concurrency model | Swift actors + async/await | Combine publishers for services | Actors provide compile-time isolation; Combine adds complexity without benefit in iOS 17+ |
| Vector index type | HNSW (pgvector) | IVFFlat | HNSW has no training phase, better recall at low dataset sizes typical of a single-user MVP |
| STT primary | on-device SFSpeechRecognizer | OpenAI Whisper (primary) | Privacy; latency; no round-trip for short gym notes |
| LLM for set inference | Sonnet/GPT-4o | Opus (for inference) | Latency constraint of <6s; Sonnet quality is sufficient for structured JSON tasks |
| Local persistence | UserDefaults + SwiftData | Core Data | SwiftData is the modern replacement; UserDefaults sufficient for GymProfile cache |
| Backend | Supabase | Firebase | pgvector extension; SQL flexibility; PostgREST for auto-generated endpoints |

---

## 3. iOS Application Architecture

### 3.1 Project Structure

```
ProjectApex/
├── App/
│   ├── ProjectApexApp.swift          # @main entry point, DI container init
│   └── AppDependencies.swift         # Dependency injection container
│
├── Models/
│   ├── GymProfile.swift              # GymProfile, EquipmentItem, EquipmentType (presence-only)
│   ├── DefaultWeightIncrements.swift # Hardcoded commercial gym weight defaults (no scan data)
│   ├── WorkoutProgram.swift          # Mesocycle, Week, TrainingDay, Exercise
│   ├── WorkoutSession.swift          # WorkoutSession, SetLog, SessionNote
│   └── User.swift                    # AppUser model
│
├── Features/
│   ├── Onboarding/
│   ├── Scanner/
│   │   ├── ScannerView.swift         # Guided per-equipment capture UI
│   │   └── ScannerViewModel.swift    # State machine: idle→previewing→analyzing→reviewed→confirming
│   ├── Program/
│   │   ├── ProgramOverviewView.swift # 12-week calendar grid; "Week N of M" phase label per week
│   │   ├── ProgramDayDetailView.swift
│   │   └── ProgramViewModel.swift
│   ├── Progress/
│   │   ├── ProgressView.swift        # 4-section tab: stagnation banners, key lifts, trend chart, volume, heatmap
│   │   ├── ProgressViewModel.swift   # @Observable; two-query pattern (sessions → set_logs); all aggregation client-side
│   │   └── MuscleColorUtility.swift  # nonisolated enum MuscleColor — shared muscle→Color mapping
│   └── Workout/
│       ├── WorkoutView.swift         # ZStack state-machine router (idle/active/resting/complete)
│       ├── PreWorkoutView.swift      # Readiness ring, session info card, Start button
│       ├── ActiveSetView.swift       # P3-T04: Prescription card (weight tappable FB-001), Set Complete, rep/RPE sheet, end-early + pause menus, weight correction (P1-T11)
│       ├── RestTimerView.swift       # P3-T05: Circular ring, haptics, audio tone, skip button, end-early + pause menus
│       ├── InferenceRetrySheet.swift # P3-T07: Modal sheet when AI fails — Retry or Pause Session (no silent fallback)
│       ├── PostWorkoutSummaryView.swift  # P3-T08: Volume, sets ring, PRs, AI adjustments, share, done
│       ├── WeightCorrectionView.swift    # "Weight not available" substitution sheet (P1-T10)
│       ├── WeightOverrideView.swift      # Inline weight override sheet — tappable weight hero (FB-001)
│       └── WorkoutViewModel.swift    # @Observable bridge from actor state to SwiftUI
│
├── AICoach/
│   ├── AIInferenceService.swift      # actor — core inference engine
│   └── LLMProvider.swift             # protocol + AnthropicProvider + OpenAIProvider
│   # NOTE: EquipmentRounder.swift removed — weight snapping handled by
│   #       DefaultWeightIncrements (defaults) + GymFactStore (corrections)
│
├── Services/
│   ├── SupabaseClient.swift          # select: String? param added for narrow-column fetches
│   ├── HealthKitService.swift
│   ├── MemoryService.swift
│   ├── SpeechService.swift
│   ├── GymFactStore.swift            # actor — runtime weight correction persistence
│   ├── GymStreakService.swift        # actor — consecutive training day streak + StreakResult (P4-E1)
│   ├── StagnationService.swift       # nonisolated enum — Epley e1RM trend analysis; plateaued/declining/progressing verdict
│   ├── VolumeValidationService.swift # nonisolated enum — actual vs target sets per muscle; deficit flags
│   ├── SessionPlanService.swift      # includes stagnation_signals + volume_deficits in request payload
│   ├── MacroPlanService.swift
│   ├── WriteAheadQueue.swift         # actor — local FIFO queue for reliable Supabase writes (P3-T06)
│   └── KeychainService.swift
│
├── Extensions/
│   ├── GymProfile+Persistence.swift
│   ├── Date+ISO8601.swift
│   └── JSONEncoder+Apex.swift
│
└── Resources/
    └── Prompts/
        ├── SystemPrompt_Inference.txt
        ├── SystemPrompt_GymScan.txt
        ├── SystemPrompt_MacroGeneration.txt
        ├── SystemPrompt_MacroPlan.txt       # FB-008 two-stage generation
        ├── SystemPrompt_SessionPlan.txt     # includes STAGNATION SIGNALS + VOLUME DEFICIT SIGNALS sections
        └── SystemPrompt_ExerciseSwap.txt
```

### 3.2 Dependency Injection

All services are initialized once at app launch and injected via `@Environment` into the SwiftUI view hierarchy. No singleton anti-pattern outside of `WorkoutSessionManager`.

```swift
@Observable
final class AppDependencies {
    let keychainService: KeychainService
    let supabaseClient: SupabaseClient
    let healthKitService: HealthKitService
    let memoryService: MemoryService
    let speechService: SpeechService
    let gymFactStore: GymFactStore       // runtime weight correction persistence
    let gymStreakService: GymStreakService // training streak for AI intensity modulation (P4-E1)
    var aiInferenceService: AIInferenceService

    init() {
        self.keychainService = KeychainService()
        let anthropicKey = (try? keychainService.retrieve(.anthropicAPIKey)) ?? ""
        self.supabaseClient = SupabaseClient(url: Config.supabaseURL, anonKey: Config.supabaseAnonKey)
        self.healthKitService = HealthKitService()
        self.memoryService = MemoryService(supabase: supabaseClient, embeddingAPIKey: (try? keychainService.retrieve(.openAIAPIKey)) ?? "")
        self.speechService = SpeechService()
        self.gymFactStore = GymFactStore()
        // GymProfile no longer passed to AIInferenceService at init —
        // the profile is assembled per-request from UserDefaults.
        self.aiInferenceService = AIInferenceService(
            provider: AnthropicProvider(apiKey: anthropicKey)
        )
    }

    func reinitialiseAIInference() {
        let key = (try? keychainService.retrieve(.anthropicAPIKey)) ?? ""
        aiInferenceService = AIInferenceService(provider: AnthropicProvider(apiKey: key))
    }
}
```

### 3.3 State Management

| Scope | Mechanism | Examples |
|---|---|---|
| Single view, ephemeral | `@State` | Button press states, animation triggers |
| Single screen, lifecycle-tied | `@Observable` ViewModel | `ScannerViewModel`, `ProgramViewModel` |
| Session-wide, shared across views | `WorkoutSessionManager` (actor, injected) | Current set, rest timer, session log |
| App-wide, persistent | `AppDependencies` (injected at root) | Services, GymProfile |
| Cross-launch persistence | Supabase + UserDefaults | Programs, set logs, GymProfile |

### 3.4 Navigation Architecture

`NavigationStack` used throughout. Three primary tabs:

```
TabView
├── Tab 1: Program (NavigationStack)
│   ├── ProgramOverviewView           # 12-week calendar
│   └── ProgramDayDetailView          # Drill-in to any day
│       └── WorkoutView               # Pushed via NavigationLink (tab bar + back button visible)
│           ├── PreWorkoutView
│           ├── ActiveSetView
│           ├── RestTimerView
│           └── PostWorkoutSummaryView
├── Tab 2: Workout (NavigationStack)
│   └── WorkoutView                   # Root of stack; session started here or continued from Program tab
│       ├── PreWorkoutView
│       ├── ActiveSetView
│       ├── RestTimerView
│       └── PostWorkoutSummaryView
└── Tab 3: Settings (NavigationStack)
    ├── SettingsView
    ├── GymScannerView
    └── DeveloperSettingsView
```

The active workout flow uses a `SessionState` machine rendered via `ZStack` inside `WorkoutView`.
The tab bar and navigation back button are always visible during an active session — navigation away
from `WorkoutView` does not pause or interrupt the session.

### Session Lifecycle & Navigation Invariants

**WorkoutSessionManager is the sole source of truth for session state.**  Views are pure renderers.

- `WorkoutSessionManager` is app-level — instantiated once in `AppDependencies` at launch and
  injected via `@Environment`. Its actor isolation guarantees session state survives any view
  lifecycle event (navigation push/pop, tab switch, backgrounding).
- `WorkoutView` owns `WorkoutViewModel` as `@State`. If the view is popped from the navigation
  stack and re-created, a new viewModel is created. On `.task`, it calls `vm.pullState()` then
  `vm.beginStatePolling()` if the session is live — the session is restored transparently.
- The rest timer is actor-owned: `WorkoutSessionManager.restTimerTask` runs inside the actor,
  anchored to `restExpiresAt` (an absolute `Date`). Navigation events have no effect on it.
- `WorkoutSessionManager.currentTrainingDayId` is exposed so `ProgramDayDetailView` can detect
  an active session for its day without crossing actor boundaries in the render path.

### ProgramDayDetailView — Plan-only vs. Live Session Rendering

When no session is active for a day, `ProgramDayDetailView` renders the planned prescription
(exercise name, sets × reps, tempo, rest, RIR).

When `WorkoutSessionManager.currentTrainingDayId == day.id` and session state is `.active`,
`.resting`, or `.preflight`, `ProgramDayDetailView` enters **live session mode**:
- Each `ExerciseDetailCard` receives the `liveSetLogs` for that exercise (sourced from
  `WorkoutSessionManager.completedSets`).
- Completed sets show weight × reps × RPE. Upcoming sets show the planned prescription.
- The bottom action button changes from "Start Workout" to "Continue Workout".
- Tapping "Continue Workout" pushes `WorkoutView` via NavigationLink, which syncs from the
  actor and renders the live session state immediately.

---

## 4. Data Models & Schema Definitions

### 4.1 GymProfile (Swift)

**Scanner principle: presence-only.** The scanner records *what* equipment exists, not weight ranges. Weight availability is resolved at runtime by two independent sources:
- `DefaultWeightIncrements` — hardcoded commercial gym defaults (e.g. dumbbells 2.5–60 kg in 2.5 kg steps)
- `GymFactStore` — user-confirmed weight corrections persisted to UserDefaults

```swift
// 27 known cases + unknown(String) catch-all.
// All nonisolated to opt out of @MainActor for Codable (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).
nonisolated enum EquipmentType: Codable, Hashable, Sendable {
    case dumbbellSet, barbell, ezCurlBar
    case cableMachine, cableMachineDual   // single-stack and dual-stack
    case smithMachine, legPress, hackSquat
    case adjustableBench, flatBench, inclineBench
    case pullUpBar, dipStation, resistanceBands, kettlebellSet
    case powerRack, sqatRack, latPulldown, seatedRow
    case chestPressMachine, shoulderPressMachine
    case legExtension, legCurl, pecDeck, preacherCurl, cableCrossover
    case unknown(String)                  // always dropped by EquipmentMerger

    var typeKey: String { /* canonical snake_case JSON key */ }
    var displayName: String { /* human-readable */ }
    static let knownCases: [EquipmentType]  // all non-unknown, for pickers
    init(typeKey: String, rawValue: String? = nil)
}

// Presence-only — no weight ranges stored.
nonisolated struct EquipmentItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var equipmentType: EquipmentType
    var count: Int              // number of units present
    var notes: String?          // optional freeform (e.g. "left cable broken")
    var detectedByVision: Bool
}

nonisolated struct GymProfile: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var scanSessionId: String
    var createdAt: Date
    var lastUpdatedAt: Date
    var equipment: [EquipmentItem]
    var isActive: Bool

    func hasEquipment(_ type: EquipmentType) -> Bool
    func count(of type: EquipmentType) -> Int
    func item(for type: EquipmentType) -> EquipmentItem?
}

// Weight availability resolution (replaces the removed WeightIncrement / BarbellConstraint):
struct DefaultWeightIncrements {
    static func defaults(for type: EquipmentType) -> WeightRange?
    // Returns (start: Double, end: Double, step: Double)? for weight-bearing equipment.
    // Returns nil for benches, racks, bars, etc.

    static func nearestWeights(to target: Double, for type: EquipmentType,
                               excluding: Set<Double> = []) -> (lower: Double?, upper: Double?)
}

// Training streak (P4-E1)
nonisolated enum StreakTier: String, Codable, Sendable {
    case cold       = "Cold"
    case warmingUp  = "Warming Up"
    case active     = "Active"
    case onFire     = "On Fire"
}

nonisolated struct StreakResult: Codable, Sendable {
    let currentStreakDays: Int
    let longestStreak: Int
    let streakScore: Int          // min(100, currentStreakDays * 8)
    let streakTier: StreakTier
    let computedAt: Date

    static let neutral = StreakResult(currentStreakDays: 0, longestStreak: 0, streakScore: 50,
                                      streakTier: .warmingUp, computedAt: .distantPast)
    static func compute(currentStreakDays: Int, longestStreak: Int, now: Date = Date()) -> StreakResult
    func isStale(after: TimeInterval = 6 * 3600, relativeTo: Date = Date()) -> Bool
}

actor GymStreakService {
    // Path B (retained — not deleted): used for workout UI tinting (PreWorkoutView gradient,
    // progress ring, start button colour) via streak.tintColor. Also injected into WorkoutContext
    // for AI intensity modulation. Skipped sessions (TrainingDayStatus.skipped) are automatically
    // excluded because they produce no workout_sessions row (Supabase query filters completed=true).
    init(supabase: SupabaseClient, lookbackDays: Int = 90)
    func computeStreak(userId: UUID) async -> StreakResult
    func invalidate(userId: UUID) async
}

actor GymFactStore {
    // Persists user-confirmed weight corrections to UserDefaults.
    func recordCorrection(equipmentType: EquipmentType, availableKg: Double) async
    func knownSubstitution(for type: EquipmentType, target: Double) async -> Double?
    func contextStrings(for type: EquipmentType) async -> [String]
    func allContextStrings() async -> [String]
    func clearAll() async
}
```

### 4.2 WorkoutProgram (Swift)

```swift
struct Mesocycle: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let createdAt: Date
    var isActive: Bool
    var weeks: [TrainingWeek]
    let totalWeeks: Int
    let periodizationModel: String
}

struct TrainingWeek: Codable, Identifiable, Sendable {
    let id: UUID
    let weekNumber: Int          // 1–12
    let phase: MesocyclePhase
    var trainingDays: [TrainingDay]
    let isDeload: Bool
}

enum MesocyclePhase: String, Codable, Sendable {
    case accumulation    // Weeks 1–4
    case intensification // Weeks 5–8
    case peaking         // Weeks 9–11
    case deload          // Week 12
}

nonisolated enum TrainingDayStatus: String, Codable, Sendable {
    case pending    // Skeleton generated but session not yet planned
    case generated  // Session exercises planned (ready to start)
    case completed  // Session completed by user
    case paused     // Session started and paused mid-workout (P3-T11)
    case skipped    // Explicitly skipped by user (Phase-1-Skip); advances programme_day_index
}

// Training-time progression rule (Phase-1-Skip):
//   programme_day_index advances ONLY when status transitions to .completed or .skipped.
//   Calendar time NEVER advances the index. ProgramViewModel.currentWeekIndex(in:) scans
//   weeks in order and returns the index of the first week that still contains a non-terminal
//   day (i.e. not .completed and not .skipped).

struct TrainingDay: Codable, Identifiable, Sendable {
    let id: UUID
    let dayOfWeek: Int
    let dayLabel: String         // e.g. "Upper_A", "Lower_B"
    var exercises: [PlannedExercise]
    let sessionNotes: String?
    var status: TrainingDayStatus  // defaults to .generated for legacy data (custom decoder)
    var skippedAt: Date?           // Phase-1-Skip: non-nil when status == .skipped
}

struct PlannedExercise: Codable, Identifiable, Sendable {
    let id: UUID
    let exerciseId: String
    let name: String
    let primaryMuscle: String
    let synergists: [String]
    let equipmentRequired: EquipmentType
    let sets: Int
    let repRange: RepRange
    let tempo: String            // "E-P-C-H" format
    let restSeconds: Int
    let rirTarget: Int
    let coachingCues: [String]
}

struct RepRange: Codable, Sendable {
    let min: Int
    let max: Int
}
```

### 4.3 WorkoutSession (Swift)

```swift
struct WorkoutSession: Codable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let programId: UUID
    let sessionDate: Date
    let weekNumber: Int
    let dayType: String
    var completed: Bool
    var status: String?        // "active" | "paused" | "completed" | nil (legacy rows) (P3-T11)
    var setLogs: [SetLog]
    var sessionNotes: [SessionNote]
    var summary: SessionSummary?
}

// Lightweight snapshot saved to UserDefaults on pause (P3-T11).
// Not stored in Supabase — only used for local resume handoff.
nonisolated struct PausedSessionState: Codable, Sendable {
    let sessionId: UUID          // Same ID reused on resume
    let trainingDayId: UUID
    let weekId: UUID
    let exerciseIndex: Int       // Which exercise was in progress
    let currentSetNumber: Int    // Which set was next
    let dayType: String
    let programId: UUID
    let userId: UUID
    let pausedAt: Date

    static let persistenceKey = "com.projectapex.pausedSessionState"
    func save()                          // JSONEncoder → UserDefaults
    static func load() -> PausedSessionState?  // JSONDecoder from UserDefaults
    static func clear()                  // removeObject
}

struct SetLog: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let rirEstimated: Int?
    let aiPrescribed: SetPrescription?
    let loggedAt: Date
}

struct SessionNote: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    let exerciseId: String
    let rawTranscript: String
    let tags: [String]
    let loggedAt: Date
}

struct SessionSummary: Codable, Sendable {
    let totalVolumeKg: Double
    let setsCompleted: Int
    let setsPlanned: Int                // Total planned sets for the training day
    let personalRecords: [PersonalRecord]
    let aiAdjustmentCount: Int
    let notableNotes: [String]
    let earlyExitReason: String?        // Non-nil when session ended early (P3-T09)
    let durationSeconds: Int            // Wall-clock session duration
}

struct PersonalRecord: Codable, Sendable {
    let exerciseId: String
    let exerciseName: String
    let previousBest: Double
    let newBest: Double
    let metric: PRMetric
}

enum PRMetric: String, Codable, Sendable {
    case estimatedOneRM, topSetWeight, totalVolume
}
```

### 4.4 Supabase Schema (PostgreSQL)

```sql
-- Extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Users (FB-003: biometric columns added)
CREATE TABLE IF NOT EXISTS public.users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  TEXT,
  bodyweight_kg DOUBLE PRECISION,    -- optional; calibrates AI weight prescriptions
  height_cm     DOUBLE PRECISION,
  age           INTEGER,
  training_age  TEXT,                -- "Beginner (< 1 yr)" | "Intermediate (1–3 yrs)" | "Advanced (3+ yrs)"
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Gym Profiles
CREATE TABLE IF NOT EXISTS public.gym_profiles (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  scan_session_id TEXT NOT NULL,
  equipment       JSONB NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  is_active       BOOLEAN DEFAULT TRUE
);
CREATE INDEX IF NOT EXISTS gym_profiles_user_id_idx ON public.gym_profiles(user_id);

-- Programs (Mesocycles)
CREATE TABLE IF NOT EXISTS public.programs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  mesocycle_json JSONB NOT NULL,
  weeks          INTEGER NOT NULL DEFAULT 12,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  is_active      BOOLEAN DEFAULT TRUE
);
CREATE INDEX IF NOT EXISTS programs_user_id_idx ON public.programs(user_id);

-- Workout Sessions
CREATE TABLE IF NOT EXISTS public.workout_sessions (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  program_id   UUID REFERENCES public.programs(id),
  session_date DATE NOT NULL,
  week_number  INTEGER NOT NULL,
  day_type     TEXT NOT NULL,
  completed    BOOLEAN DEFAULT FALSE,
  status       TEXT DEFAULT NULL,   -- "active" | "paused" | "completed" | NULL (legacy) (P3-T11)
  summary      JSONB
);
-- Migration (run once):
-- ALTER TABLE workout_sessions ADD COLUMN IF NOT EXISTS status TEXT DEFAULT NULL;
CREATE INDEX IF NOT EXISTS sessions_user_date_idx
  ON public.workout_sessions(user_id, session_date DESC);

-- Set Logs
CREATE TABLE IF NOT EXISTS public.set_logs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id     UUID NOT NULL REFERENCES public.workout_sessions(id) ON DELETE CASCADE,
  exercise_id    TEXT NOT NULL,
  set_number     INTEGER NOT NULL,
  weight_kg      DOUBLE PRECISION NOT NULL,
  reps_completed INTEGER NOT NULL,
  rpe_felt       INTEGER,
  rir_estimated  INTEGER,
  ai_prescribed  JSONB,
  logged_at      TIMESTAMPTZ DEFAULT NOW(),
  primary_muscle TEXT          -- Coarse muscle group: chest|back|shoulders|quads|hamstrings|glutes|biceps|triceps|calves|core
                               -- Populated from ExerciseLibrary canonical lookup at write time.
                               -- NULL for rows pre-dating this column or with non-canonical exercise_ids.
                               -- Migration: scripts/migrations/add_primary_muscle_column.sql
                               -- Backfill: scripts/backfill_primary_muscle.mjs
);
CREATE INDEX IF NOT EXISTS set_logs_session_idx ON public.set_logs(session_id);
CREATE INDEX IF NOT EXISTS set_logs_primary_muscle_idx ON public.set_logs(primary_muscle) WHERE primary_muscle IS NOT NULL;

-- Session Notes
CREATE TABLE IF NOT EXISTS public.session_notes (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id     UUID NOT NULL REFERENCES public.workout_sessions(id) ON DELETE CASCADE,
  exercise_id    TEXT,
  raw_transcript TEXT NOT NULL,
  tags           TEXT[],
  logged_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Memory Embeddings (RAG)
CREATE TABLE IF NOT EXISTS public.memory_embeddings (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  session_id    TEXT,
  exercise_id   TEXT,
  muscle_groups TEXT[],
  tags          TEXT[],
  raw_transcript TEXT NOT NULL,
  embedding     VECTOR(1536),
  metadata      JSONB
);

CREATE INDEX IF NOT EXISTS memory_embeddings_user_id_idx
  ON public.memory_embeddings(user_id);
CREATE INDEX IF NOT EXISTS memory_embeddings_embedding_hnsw_idx
  ON public.memory_embeddings
  USING hnsw (embedding vector_cosine_ops);

-- RPC: match_memory_embeddings
CREATE OR REPLACE FUNCTION public.match_memory_embeddings(
  query_embedding  VECTOR(1536),
  p_user_id        UUID,
  match_threshold  DOUBLE PRECISION DEFAULT 0.75,
  match_count      INTEGER          DEFAULT 3
)
RETURNS TABLE(
  id             UUID,
  raw_transcript TEXT,
  tags           TEXT[],
  metadata       JSONB,
  created_at     TIMESTAMPTZ,
  similarity     DOUBLE PRECISION
)
LANGUAGE sql STABLE AS $$
  SELECT me.id, me.raw_transcript, me.tags, me.metadata, me.created_at,
    1 - (me.embedding <=> query_embedding) AS similarity
  FROM public.memory_embeddings me
  WHERE me.user_id = p_user_id
    AND 1 - (me.embedding <=> query_embedding) > match_threshold
  ORDER BY me.embedding <=> query_embedding
  LIMIT match_count;
$$;

-- RLS
ALTER TABLE public.memory_embeddings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gym_profiles        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.programs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_sessions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.set_logs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.session_notes       ENABLE ROW LEVEL SECURITY;
```

### 4.5 SetPrescription (AI Output Schema — Swift)

```swift
struct SetPrescription: Codable, Sendable {
    var weightKg: Double
    var reps: Int
    var tempo: String          // regex: ^\d-\d-\d-\d$
    var rirTarget: Int
    var restSeconds: Int
    var coachingCue: String    // ≤ 100 chars
    var reasoning: String      // ≤ 200 chars
    var safetyFlags: [SafetyFlag]
    var confidence: Double?    // 0.0–1.0
    /// Set to true when the user has manually overridden the AI-suggested weight (FB-001).
    /// Propagated into CompletedSet and WorkoutContext so the AI knows the weight was user-corrected.
    var userCorrectedWeight: Bool?  // "user_corrected_weight"

    // CodingKeys: weight_kg, reps, tempo, rir_target, rest_seconds,
    //             coaching_cue, reasoning, safety_flags, confidence, user_corrected_weight
}

/// Included in CompletedSet for each set so the AI knows which sets had user-corrected weights.
/// Also included in WorkoutContext.currentExerciseSetsToday (FB-001).
// CompletedSet.userCorrectedWeight: Bool? — "user_corrected_weight"

enum SafetyFlag: String, Codable, Hashable, Sendable {
    case shoulderCaution    = "shoulder_caution"
    case jointConcern       = "joint_concern"
    case fatigueHigh        = "fatigue_high"
    case painReported       = "pain_reported"
    case deloadRecommended  = "deload_recommended"
}
```

### 4.6 UserProfileContext (FB-003)

User biometric and training profile included in every `WorkoutContext` payload. Populated from `UserDefaults` (written during onboarding, editable from Settings). Keys shared via `UserProfileConstants`.

```swift
struct UserProfileContext: Codable, Sendable {
    let bodyweightKg: Double?   // "bodyweight_kg" — optional; calibrates relative loading
    let heightCm: Double?       // "height_cm"     — leverage-based adjustments
    let age: Int?               // "age"           — rest targets for older users
    let trainingAge: String?    // "training_age"  — e.g. "Beginner (< 1 yr)"
}

// UserDefaults keys (UserProfileConstants enum):
//   com.projectapex.user.bodyweightKg
//   com.projectapex.user.heightCm
//   com.projectapex.user.age
//   com.projectapex.user.trainingAge

// WorkoutContext.userProfile: UserProfileContext?  ("user_profile")
// WorkoutSessionManager.loadUserProfileFromDefaults() — reads at startSession()
```

**OnboardingProfile extended fields** (FB-003):
- `bodyweightKg: Double?` — stored in kg regardless of display unit
- `heightCm: Double?`
- `age: Int?`
- `bodyweightInKg: Bool` — controls kg/lbs display toggle; storage always in kg

**Supabase `users` table** extended with: `bodyweight_kg DOUBLE PRECISION`, `height_cm DOUBLE PRECISION`, `age INTEGER`, `training_age TEXT`.

---

## 5. Feature Module: Gym Scanner

### 5.1 Component Responsibilities

| Component | Type | Responsibility |
|---|---|---|
| `ScannerView` | SwiftUI View | Guided capture UI: live preview, shutter, result card, confirmation list |
| `ScannerViewModel` | `@Observable` class | State machine; one-shot capture → Vision API → user review → accumulate |
| `CameraManager` | `@Observable` class | AVCaptureSession wrapper; `captureOneFrame()` for guided mode |
| `VisionAPIService` | `actor` | Sends single photo to Vision API, parses one-item JSON response |
| `EquipmentMerger` | `struct` | Deduplicates across multiple captures (same equipment photographed twice) |

### 5.2 Camera Pipeline (Guided Mode)

```
User taps shutter
    │
    └── ScannerViewModel.captureAndIdentify()
            │
            ├── CameraManager.captureOneFrame()   ← awaits CheckedContinuation
            │       │  AVCapturePhotoOutput.capturePhoto (one-shot still)
            │       └── AVCapturePhotoCaptureDelegate → resume continuation
            │
            ├── frame → VisionAPIService.analyseFrame(frame)
            │       └── POST /messages (Anthropic) — single-item prompt
            │
            ├── Result: [EquipmentItem] (0 or 1 items)
            │       ├── 1 item → state = .reviewed(item:)  ← user confirms/discards
            │       └── 0 items → state = .previewing + toast "nothing detected"
            │
            └── User confirms → mergeItems() → state = .previewing (next capture)
                User discards → state = .previewing (try again)
```

### 5.3 Vision API Call Contract

**Request format (single-item mode):**

```json
{
  "model": "claude-sonnet-4-20250514",
  "max_tokens": 1024,
  "messages": [{
    "role": "user",
    "content": [
      { "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "<base64>" } },
      { "type": "text", "text": "You are a gym equipment identifier. This photo shows ONE piece of gym equipment. Return exactly ONE item. confidence >= 0.85 required. Return: [{\"equipment_type\": \"<type>\", \"count\": <int>, \"confidence\": <float>}] or []." }
    ]
  }]
}
```

**Prompt rules:**
- Return exactly ONE item (the primary equipment in the photo)
- Confidence threshold: >= 0.85
- Fixed vocabulary of 26 `equipment_type` values enforced; any other string is forbidden
- If not a gym image or nothing identifiable: return `[]`
- Ignore cardio, furniture, screens, walls, floors

**Response shape** (`VisionDetectedItem`):
```json
[{"equipment_type": "dumbbell_set", "count": 1, "confidence": 0.92}]
```

### 5.4 Equipment Merge Rules (Multi-Capture Deduplication)

```
On each user confirmation, new item is merged into detectedEquipment:
1. If equipmentType already present → count = max(existing, new)
2. If new type → append to list
3. .unknown(_) types are dropped by EquipmentMerger before reaching the view model
   (model returning a string outside the fixed vocabulary = noise)

Cardio blocklist (treadmill, bike, rower, etc.) and junk blocklist
(furniture, screens, etc.) filtered inside EquipmentMerger.merge().
```

### 5.5 Scanner State Machine

```
.idle
  └── startCapture() → .requestingPermission
        └── granted → .previewing  (camera live, shutter available)
              ├── captureAndIdentify() → .analyzing  (API in-flight)
              │     ├── item found → .reviewed(item:)
              │     │     ├── confirmDetection() → mergeItems() → .previewing
              │     │     └── rejectDetection() → .previewing
              │     └── empty result → .previewing + toast
              └── doneCapturing() → .confirming  (editable list)
                    └── confirmProfile() → .completed(profile:)
                          └── reset() → .idle  (re-scan)
```

---

## 6. Feature Module: Macro-Program Generation

### 6.1 Mesocycle Generation Prompt

- **Model**: `claude-opus-4-20250514` (no timeout — one-time op)
- **System prompt**: `Resources/Prompts/SystemPrompt_MacroGeneration.txt`

**Mesocycle Phases:**
- Accumulation (weeks 1–4): 8–15 reps, RIR 3–4, higher volume
- Intensification (weeks 5–8): 5–10 reps, RIR 2–3, moderate volume
- Peaking (weeks 9–11): 3–8 reps, RIR 1–2, lower volume
- Deload (week 12): 50% volume, all rep ranges, RIR 4–5

**Tempo notation**: `E-P-C-H` (Eccentric-Pause-Concentric-Hold in seconds). Example: `3-1-2-0`.

### 6.2 Mesocycle JSON Output Schema

```json
{
  "mesocycle": {
    "id": "uuid-string",
    "total_weeks": 12,
    "periodization_model": "linear_undulating",
    "weeks": [{
      "week_number": 1,
      "phase": "accumulation",
      "is_deload": false,
      "training_days": [{
        "day_of_week": 1,
        "day_label": "Upper_A",
        "exercises": [{
          "exercise_id": "ex_incline_db_press",
          "name": "Incline Dumbbell Press",
          "primary_muscle": "pectoralis_major_upper",
          "synergists": ["anterior_deltoid", "triceps_brachii"],
          "equipment_required": "dumbbell_set",
          "sets": 4,
          "rep_range": { "min": 8, "max": 12 },
          "tempo": "3-1-2-0",
          "rest_seconds": 120,
          "rir_target": 3,
          "coaching_cues": ["Retract scapulae before unracking"]
        }]
      }]
    }]
  }
}
```

### 6.3 Equipment Validation Post-Generation

After LLM output, before persisting, `ProgramGenerationService` validates that every exercise's `equipmentRequired` exists in `gymProfile.equipment`. If violations found: one corrective re-prompt. If violations persist: throw `ProgramGenerationError.equipmentConstraintViolation`.

### 6.4 Persistence Flow

```
1. Assemble MacroProgramRequest
2. Call LLM (no timeout)
3. Decode → Mesocycle struct
4. Equipment validation pass (max 1 corrective retry)
5. POST to Supabase programs table (set is_active = true, deactivate previous)
6. Cache locally via SwiftData
7. Return Mesocycle to caller
```

---

## 7. Feature Module: Active Workout & AI Loop

### 7.1 WorkoutSessionManager Actor Interface

```swift
actor WorkoutSessionManager {
    private(set) var sessionState: SessionState = .idle
    private(set) var currentPrescription: SetPrescription?
    private(set) var currentFallbackReason: FallbackReason?
    private(set) var restSecondsRemaining: Int = 0
    private(set) var completedSets: [SetLog] = []

    // Smart retry state (P3-T07 — replaces silent fallback)
    private(set) var inferenceRetryNeeded: Bool = false
    private(set) var inferenceRetryReason: FallbackReason?

    // Dependencies: AIInferenceService, HealthKitService, MemoryService,
    //               SupabaseClient, GymFactStore, WriteAheadQueue, GymStreakService

    func startSession(trainingDay: TrainingDay, programId: UUID,
                      userId: UUID = UUID(), weekId: UUID = UUID()) async
    func completeSet(actualReps: Int, rpeFelt: Int?) async
    func addVoiceNote(transcript: String, exerciseId: String) async
    func endSessionEarly() async     // Partial session → .sessionComplete (P3-T09)
    func endSession() async
    func resetToIdle()               // Resets all state to .idle after session dismissed
    func skipRest()                  // Advances past rest timer immediately
    func applyWeightCorrection(confirmedWeight: Double, equipmentType: EquipmentType) async
        // Updates current prescription weight + records in GymFactStore (P1-T11)

    // Smart retry — called from InferenceRetrySheet (P3-T07)
    func retryInference() async -> Bool
        // Clears failed state, re-assembles context, calls prescribe().
        // Returns true on success (state → .active), false if failed again.

    // Pause & resume (P3-T11)
    func pauseSession() async
        // 1. Cancel rest timer
        // 2. Flush WAQ
        // 3. PATCH workout_sessions.status = "paused" (blocking)
        // 4. Save PausedSessionState to UserDefaults
        // 5. resetToIdle()

    func resumeSession(pausedState: PausedSessionState,
                       trainingDay: TrainingDay,
                       completedSetLogs: [SetLog]) async
        // 1. Restore all actor state from pausedState
        // 2. Reconstruct WorkoutSession in-memory (same session_id)
        // 3. PATCH status back to "active" (blocking)
        // 4. PausedSessionState.clear()
        // 5. Fetch streak/RAG/fatigue in parallel
        // 6. triggerInference() for current exercise
}

enum SessionState: Sendable {
    case idle
    case preflight
    case active(exercise: PlannedExercise, setNumber: Int)
    case resting(nextExercise: PlannedExercise, setNumber: Int)
    case exerciseComplete(nextExercise: PlannedExercise?)
    case sessionComplete(summary: SessionSummary)
    case error(String)
}
```

### 7.2 Set Completion Loop

```
User taps "Set Complete"
    │
    ├── 1. Write SetLog via WriteAheadQueue.enqueue() (P3-T06)
    │       → persisted locally, then async-POST to Supabase
    │       → exponential backoff retry on failure (1s, 2s, 4s, 8s, 16s)
    ├── 2. state → .resting (rest timer starts immediately)
    ├── 3. [parallel] Assemble WorkoutContext:
    │       - sessionHistoryToday (accumulated sets)
    │       - healthKitContext (cached)
    │       - streakResult (cached from GymStreakService, P4-E1)
    │       - ragMemory (retrieved for next exercise)
    │       - gymConstraints (from GymProfile)
    ├── 4. await aiInferenceService.prescribe(context:)
    │       → .success(prescription) OR .fallback(reason)
    └── 5. When timer expires OR prescription arrives (whichever later):
            state → .active(nextExercise, setNumber + 1)

Session End:
    ├── 1. Build SessionSummary (volume, sets, PRs, notes, duration)
    ├── 2. BLOCKING write: WriteAheadQueue.updateBlocking() patches workout_sessions
    │       → Must complete before PostWorkoutSummaryView is shown
    │       → Fallback: enqueue for retry if blocking write fails
    ├── 3. emitExerciseOutcomeEvents() [Task.detached, non-blocking]
    │       → one RAG memory event per exercise (FB-006)
    │       → outcome: "on_target" | "overloaded" | "underloaded"
    ├── 4. Increment UserDefaults.sessionCountKey (non-early-exit only) (FB-005)
    └── 5. state → .sessionComplete(summary)
```

### 7.3 Voice Note Lifecycle

```
tap mic → SpeechService.startListening() → AsyncStream<String> partial transcripts
→ user taps mic again (or 5s silence) → final transcript
→ WorkoutSessionManager.addVoiceNote(transcript:exerciseId:)
    ├── write to session_notes (Supabase)
    ├── append to WorkoutContext.qualitativeNotesToday (in-memory, all subsequent sets)
    └── MemoryService.embed() [Task.detached, non-blocking]
```

STT fallback: if on-device `SFSpeechRecognizer` confidence < 0.8 → OpenAI Whisper API.

### 7.4 Rest Timer Architecture

- Starts immediately on set completion using plan default rest duration
- Updates target if AI prescription arrives with different `rest_seconds` (only extends, never shortens)
- Survives app backgrounding via `BackgroundTaskIdentifier` (30s extension)

### 7.5 Mid-Session Resilience (Phase 3 — 2026-04-23)

Implemented in response to the 22 Apr 2026 Anthropic 529 outage incident (FB-012).

#### 7.5.1 TransientRetryPolicy

Location: `ProjectApex/AICoach/TransientRetryPolicy.swift`

All LLM `provider.complete()` calls in the mid-session flow are wrapped with `TransientRetryPolicy.execute { }`. Non-transient errors are re-thrown immediately.

| Property | Value |
|---|---|
| Retriable codes | 429, 502, 503, 504, 529 |
| Max retries | 3 (4 total attempts) |
| Backoff schedule | 1 s → 2 s → 4 s → 8 s + up to 0.5 s jitter |
| Retry-After | Encoded in error body by `AnthropicProvider` as `[retry-after:N]` prefix |
| Anthropic request-id | Encoded in error body as `[request-id:xxx]` prefix (for fallback logging) |

The 8-second product timeout in `AIInferenceService` remains the outer boundary — retries happen inside it. For fast-failing 529s (< 1 s), up to 3 retries fit within the window.

The retry sheet (`InferenceRetrySheet`) is only shown after ALL backoff retries are exhausted AND the rest timer has expired.

Applied to:
- `AIInferenceService.prescribe()` — set inference
- `AIInferenceService.prescribeAdaptation()` — weight adaptation
- `SessionPlanService.callAndDecodeSession()` — session plan generation
- `ExerciseSwapService.sendMessage()` — swap chat
- `MemoryService.classifyTags()` — Haiku tag classification (1 retry, fits within 5 s racing timeout)

#### 7.5.2 Resume Routing (Fix 2)

The crash recovery path in `WorkoutView.task` previously failed silently when `saved.trainingDayId != trainingDay.id`. The new 3-case routing:

1. **Match**: `saved.trainingDayId == nextIncompleteDay.id` → ContentView passes `crashResumeToPass` as explicit `resumeState` (Path A, reliable)
2. **Found elsewhere**: `ProgramViewModel.findTrainingDay(byId:in:)` locates the day → ContentView passes explicit `resumeState`, WorkoutView uses Path A
3. **Not found**: Day UUID not in any mesocycle week → ContentView shows "Save to History / Discard" alert; WorkoutView.task shows "Session Mismatch" alert as safety net

`ProgramViewModel.findTrainingDay(byId:in:)` is a pure linear search across all weeks and days in a mesocycle.

#### 7.5.3 WAQ + Supabase Merge on Resume (Fix 3)

`WorkoutViewModel.resumeSession()` now performs a 3-step merge:

1. Flush WAQ (best-effort — items may remain if offline)
2. Fetch Supabase set_logs for the session
3. Read WAQ `pendingSetLogs(forSession:)` — unflushed items
4. Merge: WAQ wins on same `SetLog.id` → sorts by `setNumber`

`WriteAheadQueue.pendingSetLogs(forSession:)` decodes the raw `QueuedWrite.payload` Data as `SetLog` and filters by `session_id`.

#### 7.5.4 RAG Fetch Latency Instrumentation (Fix 4)

`WorkoutSessionManager.completeSet()` instruments the `fetchRAGMemory(for:)` call when moving to a new exercise using:
- `OSSignposter` (`com.projectapex` / `RAGFetch`) — visible in Instruments
- `Logger` (`com.projectapex` / `RAGFetch`) — grep-able in Console

**Decision point:** If p95 latency from production data exceeds 150 ms, the call should be promoted to an async prefetch running during rest time (background Task, not blocking completeSet). See `// MARK: - Fix 4 Decision Point` in WorkoutSessionManager.swift.

#### 7.5.5 FallbackLogRecord (Fix 5)

Location: `ProjectApex/Services/FallbackLogRecord.swift`

Emitted on every LLM fallback. Fields: `callSite`, `httpStatus`, `anthropicRequestId`, `reason`, `sessionId`, `timestamp`.

Emission: `os.Logger` (subsystem: `com.projectapex`, category: `Fallback`). TODO: Supabase `fallback_logs` table via WAQ once services are injected with WAQ.

#### 7.5.6 Swap Chat Error Classification (Fix 6)

`ExerciseSwapService.sendMessage()` now distinguishes:
- `URLError.notConnectedToInternet / .networkConnectionLost` → "You appear to be offline…"
- `LLMProviderError.httpError(status in transientCodes)` → "The AI service is temporarily busy…"
- All others → "Something went wrong…"

---

## 7a. Feature Module: Progress & Analytics

### 7a.1 Overview

The Progress tab is the fourth tab in the main tab bar (`chart.line.uptrend.xyaxis`). It provides four sections of performance analytics computed entirely client-side from historical set_logs, plus stagnation detection and volume validation services that feed back into the AI session planner.

**Tab order:** Program (0) → Workout (1) → Progress (2) → Settings (3)

### 7a.2 Data Loading Strategy

`ProgressViewModel` uses a two-query pattern (set_logs has no user_id column):

```
Step 1: fetch workout_sessions
  → table: workout_sessions
  → filters: user_id=eq.<userId>, completed=is.true, session_date=gte.<90daysAgo>
  → select: "id,session_date"       ← narrow select avoids JSONB columns
  → decode as: ProgressSessionRow   ← session_date as String (DATE column → "yyyy-MM-dd")

Step 2: fetch set_logs
  → table: set_logs
  → filter: session_id=in.(<ids from step 1>)
  → select: "id,session_id,exercise_id,set_number,weight_kg,reps_completed,
             rpe_felt,rir_estimated,logged_at,primary_muscle"

Step 3: all aggregation (key lifts, trend, volume, heatmap) client-side
```

**Critical date-parsing note**: `session_date` is a Postgres `DATE` column. Supabase returns it as a bare string `"2026-03-20"` (not ISO8601). `ProgressSessionRow.date` uses `DateFormatter("yyyy-MM-dd")` as primary parse path, with ISO8601 variants as fallback. Standard `JSONDecoder.dateDecodingStrategy = .iso8601` cannot handle this format.

### 7a.3 ProgressView Sections

| Section | Implementation | Data source |
|---------|---------------|-------------|
| Stagnation banners | Amber (plateaued) / Red (declining) banners at top | UserDefaults via `StagnationService.load()` |
| Key Lifts Summary | Horizontal scroll of cards; exercise name, e1RM, delta badge, trend arrow | Best e1RM per muscle group (chest/back/shoulders/quads/hamstrings) in last 2 weeks vs 4–6 weeks ago |
| Strength Trend Chart | Swift Charts `LineMark`; exercise picker; `RuleMark` for all-time best | Per-session best e1RM per exercise, sorted by date |
| Weekly Volume | Grouped `BarMark` by muscle; 8 most recent ISO calendar weeks | set_logs grouped by `primary_muscle` + `loggedAt` week |
| Consistency Heatmap | 7×12 `RoundedRectangle` grid; green for sessions, accent for PR days | session dates from `ProgressSessionRow` |

**Key Lifts selection**: muscle-group based, not hardcoded exercise IDs. For each target muscle, picks the exercise with the highest recent e1RM (last 2 weeks). Falls back to all-time best if no recent data. This accommodates AI-generated exercise IDs which vary per user and programme.

**e1RM formula**: Epley — `weight × (1 + reps / 30)`

### 7a.4 StagnationService

`nonisolated enum StagnationService` — pure computation, no network calls.

```swift
nonisolated enum StagnationVerdict: String, Codable, Sendable {
    case progressing, plateaued, declining
}

nonisolated struct StagnationSignal: Codable, Sendable, Identifiable {
    let exerciseId: String
    let exerciseName: String
    let sessionsWithoutProgress: Int
    let lastPRDate: Date?
    let avgRPELast3Sessions: Double?
    let verdict: StagnationVerdict
}
```

**Classification rules** (requires 3+ sessions; otherwise always `.progressing`):
- **Declining**: last 3 session e1RMs drop ≥5% total AND inter-session gap < 5 days
- **Plateaued**: max e1RM across last 3 sessions within 2% of min AND avg RPE < 8.0
- **Progressing**: all other cases

**Lifecycle**: computed in a `Task.detached(priority: .utility)` block at the end of `WorkoutSessionManager.finishSession()`. Results persisted to UserDefaults. `SessionPlanService` loads them before each `generateSession()` call and includes them in the `SessionPlanRequest` payload as `stagnation_signals`.

### 7a.5 VolumeValidationService

`nonisolated enum VolumeValidationService` — pure computation.

```swift
nonisolated struct VolumeDeficit: Codable, Sendable, Identifiable {
    let muscleGroup: String
    let targetSets: Int
    let actualSets: Int
    let deficitPercent: Double    // e.g. 0.25 = 25% below target
}
```

**Algorithm**: builds target set counts from the current week's `TrainingDay.exercises` grouped by primary muscle, compares against actual `set_logs` counts for the current calendar week. Emits a deficit for any muscle where `(target - actual) / target > 0.20`.

**Lifecycle**: computed in `ProgressViewModel.loadAll()` when `plannedWeekDays` are provided. Results persisted to UserDefaults. `SessionPlanService` loads them alongside stagnation signals.

### 7a.6 AI Integration — SessionPlanRequest Extensions

`SessionPlanRequest` includes two new fields injected from UserDefaults before each session generation:

```swift
let stagnationSignals: [StagnationSignal]   // CodingKey: "stagnation_signals"
let volumeDeficits:    [VolumeDeficit]       // CodingKey: "volume_deficits"
```

`SystemPrompt_SessionPlan.txt` contains two corresponding directive sections:
- **STAGNATION SIGNALS**: plateaued → vary rep range / swap variation / add intensity techniques; declining → −10% weight, +1 set, form cue
- **VOLUME DEFICIT SIGNALS**: add 1–2 extra sets for flagged muscle groups; cap at +3 sets total above normal day volume

### 7a.7 TemporalContext — Gap-Aware Session Planning (Phase-1-Skip)

`SessionPlanRequest` includes a third field assembled by `ProgramViewModel.generateDaySession()` immediately before each on-demand session generation:

```swift
nonisolated struct TemporalContext: Codable, Sendable {
    let daysSinceLastSession: Int?           // nil = first-ever session
    let daysSinceLastTrainedByPattern: [String: Int]  // e.g. {"horizontal_push": 5, "squat": 12}
    let skippedSessionCountLast30Days: Int
}
```

**Assembly**: computed inside `ProgramViewModel.generateDaySession()` using:
- `recentSessions` (already fetched for the week) to derive `daysSinceLastSession`
- `deepLiftHistory` set logs + `ExerciseLibrary.lookup(exerciseId)?.movementPattern` to derive per-pattern gaps
- `currentMesocycle.weeks.flatMap(\.trainingDays).filter { $0.status == .skipped && skippedAt >= 30d ago }` for the skip count

**Prompt guidance** (`SystemPrompt_SessionPlan.txt` — TEMPORAL CONTEXT section):
- 7-day gap → neutral/deload; raise RIR by 1 on first working set
- 3+ week pattern gap → lighter reintroduction; note in session_notes
- null daysSinceLastSession or > 14 days → conservative on all patterns
- Prompt explicitly forbids hardcoded load reduction percentages

### 7a.8 Mesocycle Phase Label

`ProgramOverviewView.WeekRowView` shows `"Week N of M"` (e.g. `"Week 2 of 4"`) in the week header using hardcoded phase ranges:

| Phase | Week indices (0-based) | Display weeks |
|-------|----------------------|---------------|
| Accumulation | 0–3 | Weeks 1–4 (4 total) |
| Intensification | 4–7 | Weeks 5–8 (4 total) |
| Peaking | 8–10 | Weeks 9–11 (3 total) |
| Deload | 11 | Week 12 (1 total) |

### 7a.9 Per-Pattern Phase Tracking (Phase 2b)

#### Why Global Phase Is Insufficient

The programme's periodization phase (`MesocyclePhase`) was previously global — every session inherited the phase from the programme-level week count via `MacroPlanService.buildPendingMesocycle()`. This is incorrect when a muscle group's training history diverges from the programme as a whole. Example: programme in Week 5 (intensification) but legs trained only twice — intensification prescriptions for legs assume volume tolerance that doesn't exist.

#### `MovementPatternPhaseState` Model

A new per-pattern phase state is persisted to UserDefaults (key `apex.pattern_phase_states`) alongside the global phase. Each entry tracks:

| Field | Type | Description |
|-------|------|-------------|
| `pattern` | `String` | Movement pattern key, e.g. `"horizontal_push"`, `"squat"` |
| `phase` | `MesocyclePhase` | The pattern's own phase (independent of global) |
| `sessionsCompletedInPhase` | `Int` | Sessions completed since last transition |
| `sessionsRequiredForPhase` | `Int` | Threshold to advance; derived at creation |

`PatternPhaseInfo` is a lightweight LLM DTO (snake_case CodingKeys: `current_phase`, `sessions_completed`, `sessions_required`) sent inside `TemporalContext.pattern_phases`.

#### Option B Transition Threshold

`max(3, phaseWeeks × max(1, daysPerWeek / 2))`

| Phase | phaseWeeks | 3 days/week | 4 days/week |
|-------|------------|-------------|-------------|
| Accumulation | 4 | 4 | 8 |
| Intensification | 4 | 4 | 8 |
| Peaking | 3 | 3 | 6 |
| Deload | 1 | 3 (min) | 3 (min) |

The `max(1, daysPerWeek / 2)` inner term estimates how many days per week a given movement pattern is trained (roughly half the training days in a typical push/pull/legs split). The outer `max(3, ...)` floor ensures a minimum of 3 sessions before any transition — this matches `StagnationService`'s 3-session data minimum, prevents zero-session transitions for low-frequency schedules (e.g. 1 day/week), and ensures baseline volume tolerance is established before intensity ramps.

Deload is **terminal** — there is no phase beyond it. `advancePhases()` makes no change when a pattern is already at deload. **Design assumption:** this is valid under the current 12-week periodisation model where deload only appears at Week 12. If intra-programme deload weeks were added (e.g., a dedicated Week 4 deload in a periodised block), this design would need revisiting — those patterns would get permanently stuck at deload after the mid-cycle recovery week.

#### No Phase Regression on Absence

When a pattern hasn't been trained for weeks, the phase **does not regress**. LLM handles reintroduction conservatively via `temporal_context.days_since_last_trained_by_pattern`. Phase state stays at its current level to avoid losing earned adaptation progress. This is a deliberate design choice.

#### Migration Strategy

On the first `generateDaySession()` call after feature deployment:
1. `PatternPhaseService.load()` returns empty (first run).
2. If `deepLiftHistory` is non-empty, `computeInitialPhases(from:daysPerWeek:)` runs once:
   - Groups set_logs by movement pattern via `ExerciseLibrary.lookup(exerciseId)?.movementPattern`.
   - Counts distinct `sessionId` values per pattern.
   - Walks phase thresholds in order, consuming sessions, to derive the current phase.
   - Remaining sessions become `sessionsCompletedInPhase`.
3. Result is persisted; subsequent calls load from UserDefaults (the `load().isEmpty` gate prevents re-running).

**Test coverage note:** The `computeInitialPhases()` function and the migration idempotency invariant are covered by `PatternPhaseServiceTests`. The gate itself (`if load().isEmpty && !deepLiftHistory.isEmpty` in `ProgramViewModel.generateDaySession()`) is not separately unit tested — it's a trivial guard on a tested predicate. The `clear()`-on-new-programme and preserve-on-`regenerateProgram()` behaviors are also at `ProgramViewModel` level and are verified by code review rather than automated tests in the current suite.

#### Service

`nonisolated enum PatternPhaseService` — mirrors `StagnationService`/`VolumeValidationService`. Stateless pure computation functions + UserDefaults persistence. Key functions:
- `sessionsRequired(for:daysPerWeek:) -> Int`
- `advancePhases(current:trainedPatterns:daysPerWeek:) -> [MovementPatternPhaseState]`
- `computeInitialPhases(from:daysPerWeek:) -> [MovementPatternPhaseState]`
- `persist(_:)` / `load()` / `clear()`

#### Lifecycle

- **Per-session (post-finish)**: `WorkoutSessionManager.finishSession()` fires `Task.detached(priority: .utility)` after the stagnation hook. Extracts movement patterns from completed exercises, calls `advancePhases`, persists.
- **New programme**: `PatternPhaseService.clear()` called in `generateProgram()` and `generateMacroSkeleton()`. Not in `regenerateProgram()` — regeneration preserves completed days and their accumulated phases.
- **Session assembly**: `ProgramViewModel.generateDaySession()` loads states, runs migration if needed, maps to `[String: PatternPhaseInfo]`, passes into `TemporalContext` with `globalProgrammePhase` and `globalProgrammeWeek`.

---

## 8. AI & Inference Architecture

### 8.1 Inference Execution Pipeline

```
prescribe(context:)
    │
    └── RETRY LOOP (max 3 total attempts):
            ├── withTimeout(8.0s): provider.complete(systemPrompt, userPayload)
            ├── Strip markdown fences (```json ... ```)
            ├── Decode: { "set_prescription": SetPrescription }
            ├── prescription.validate()
            ├── SUCCESS:
            │   ├── DefaultWeightIncrements.nearestWeights(to: weightKg, for: exerciseType)
            │   │   + GymFactStore.knownSubstitution(for: exerciseType, target: weightKg)
            │   │   → snap to nearest available weight, append note to reasoning if adjusted
            │   ├── Safety gate: painReported → restSeconds = max(restSeconds, 180)
            │   └── return .success(prescription)
            └── FAILURE: append error to prompt, retry (max 2 retries)
                         → .fallback(.maxRetriesExceeded)
```

### 8.2 LLM Provider Protocol

```swift
protocol LLMProvider: Sendable {
    func complete(systemPrompt: String, userPayload: String) async throws -> String
}
```

Implementations: `AnthropicProvider`, `OpenAIProvider`.

**AnthropicProvider request:**
- URL: `https://api.anthropic.com/v1/messages`
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`
- Body: `{ "model": model, "max_tokens": 1024, "system": systemPrompt, "messages": [{"role": "user", "content": userPayload}] }`

### 8.3 System Prompt for Set Inference

Stored in `Resources/Prompts/SystemPrompt_Inference.txt`. Current version: **v3.0** (updated FB-002, FB-003, FB-005, FB-006).

**Output contract:**
1. Return ONLY `{"set_prescription": { ... }}` — no prose
2. `coaching_cue` ≤ 100 chars; `reasoning` ≤ 200 chars
3. `confidence`: 0.0–1.0 (optional)
4. Tempo regex: `^\d-\d-\d-\d$`
5. `rest_seconds` range: 30–600
6. `reps` range: 1–30

**Safety rules (override all loading logic):**
- Safety flags override all other logic
- Pain/joint notes → reduce weight + increase rest + flag `pain_reported`
- HRV delta < -15% → apply -5% to -10% conservative loading

**Equipment-aware weight increment rules (FB-002):**
- Barbell: minimum 5 kg increments (2.5 kg only at natural plate-change boundaries)
- Dumbbell / Kettlebell: minimum 2.5 kg increments
- Cable / Machine: minimum 2.5 kg increments

**Rep-completion bands — replaces percentage formula (FB-002):**
- NEAR MISS (≥ 80% of target reps completed): hold weight, reduce reps by 1
- MODERATE MISS (60–79%): drop one standard increment for equipment type
- SIGNIFICANT MISS (< 60%): drop to estimated full-rep weight; flag for recalibration

**Anti-oscillation rule (FB-002):**
- Do not reverse weight direction within a single exercise unless `user_corrected_weight: true` is present on the most recent set

**Progressive overload / ambition directive (FB-002):**
- Completed all reps at ≥ 2 RIR → increase by one standard increment next set
- Do not be conservative when the athlete is clearly under-loaded

**First-session calibration (FB-005):**
- When `is_first_session: true` (i.e. `total_session_count == 0`), prescribe ~60% estimated 1RM labelled as a calibration set
- Use `user_profile.bodyweight_kg` and `user_profile.training_age` to anchor first-session weights
- `session_count` is persisted in `UserDefaults` via `UserProfileConstants.sessionCountKey`; incremented at session completion (non-early-exit only)
- `PreWorkoutView` shows a "First session — we'll calibrate your starting weights today" banner when `session_count == 0`

**User profile context (FB-003):**
- `bodyweight_kg` — calibrate relative loading for bodyweight-leveraged movements
- `training_age` — scale starting weights ("Beginner" → conservative; "Advanced" → aggressive)
- `age` — extend rest targets for users 45+
- `height_cm` — leverage-based adjustments (deadlift, squat bar path)

**Within-session performance (FB-006):**
- `within_session_performance` field in `WorkoutContext`: all prior `CompletedSet` records for the current exercise in this session
- On SIGNIFICANT MISS (< 60% reps), AI uses this data to triangulate true working weight and anchors all remaining sets to the recalibrated estimate — not a fixed decrement formula
- Coaching cue must acknowledge the miss directly; generic cues are not acceptable

**Session outcome anchor — cross-session learning (FB-006):**
- At session end, `WorkoutSessionManager.emitExerciseOutcomeEvents()` writes one structured RAG memory event per completed exercise:
  - `outcome: "on_target"` (avg reps ≥ 90% of target)
  - `outcome: "overloaded"` (avg reps < 70% of target)
  - `outcome: "underloaded"` (avg reps ≥ 110% of target)
  - Tags: `["exercise_outcome", outcome, primaryMuscle]`
- On subsequent sessions, if RAG returns an `exercise_outcome` event: `overloaded` → open 5–10% below; `on_target` / `underloaded` → open at or above

### 8.4 Model Selection

| Call Type | Model | Timeout |
|---|---|---|
| Gym Vision Scan (per frame) | `claude-sonnet-4-20250514` | 10s |
| Macro Program Generation | `claude-opus-4-20250514` | None |
| Set-by-Set Inference | `claude-sonnet-4-20250514` | 8s |
| Memory Tag Classification | `claude-haiku-4-5-20251001` | 5s |
| Embeddings | `text-embedding-3-small` (OpenAI) | 5s |
| STT Fallback | `whisper-1` (OpenAI) | 15s |

### 8.5 Timeout Utility

```swift
func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMProviderError.timeout
        }
        guard let result = try await group.next() else { throw LLMProviderError.timeout }
        group.cancelAll()
        return result
    }
}
```

---

## 9. RAG Memory System

### 9.1 Write Path

```
Voice Note / Session Event
    → MemoryService.embed(text:metadata:)  [Task.detached, non-blocking]
        ├── 1. Tag Classification (Haiku, async)
        ├── 2. POST https://api.openai.com/v1/embeddings (text-embedding-3-small, 1536-dim)
        └── 3. Upsert to memory_embeddings (Supabase)
```

### 9.2 Read Path

```
Before each set prescription:
    ├── Build query: "\(exercise.name) \(exercise.primaryMuscle) \(synergists.joined)"
    ├── Embed query (same model)
    └── RPC match_memory_embeddings(query_embedding, p_user_id, threshold: 0.75, count: 3)
        → [RAGMemoryItem] sorted by similarity DESC
```

### 9.3 Memory Event Taxonomy (Auto-Generated)

| Trigger | Generated Text | Tags |
|---|---|---|
| Voice note with pain keywords | Verbatim transcript | `["injury_concern", "<muscle>"]` |
| Set ≥2 reps below target | "Performance drop on \(exercise): \(actual)/\(target) reps" | `["performance_drop", "fatigue"]` |
| Personal record | "PR on \(exercise): \(weight)kg × \(reps)" | `["pr_achieved", "<muscle>"]` |
| Session terminated early | "Early session exit: \(reason)" | `["session_incomplete"]` |
| 3+ sessions avg RPE > 8 | "Accumulated fatigue signal: avg RPE \(avgRpe) over 3 sessions" | `["accumulated_fatigue"]` |
| Session end (per exercise) | "Exercise outcome — \(exercise): avg X/Y reps (Z%), avg weight Nkg, avg RPE R, outcome: on_target\|overloaded\|underloaded" | `["exercise_outcome", outcome, primaryMuscle]` |

**Pain keywords (client-side detection):**
```swift
let painKeywords = ["pain", "hurt", "tweaky", "clicking", "popping",
                    "tight", "impinged", "pulling", "straining", "sore"]
```

### 9.4 Performance Targets

| Metric | Target |
|---|---|
| HNSW recall at K=3 | > 95% |
| Retrieval latency p50 | < 200ms |
| Retrieval latency p99 | < 500ms |
| Similarity threshold | 0.75 (tunable) |

---

## 10. Backend & Database Architecture

### 10.1 Supabase Client Design

All communication is raw `URLSession` HTTP calls to PostgREST. No Supabase Swift SDK.

```swift
actor SupabaseClient {
    private let baseURL: URL
    private let anonKey: String
    private var authToken: String?

    func insert<T: Encodable>(_ item: T, table: String) async throws
    func fetch<T: Decodable>(_ type: T.Type, table: String, filters: [Filter]) async throws -> [T]
    func update<T: Encodable>(_ item: T, table: String, id: UUID) async throws
    func rpc<T: Decodable>(_ function: String, params: [String: Any]) async throws -> T
}
```

### 10.2 Data Access Patterns

| Operation | Frequency | Table |
|---|---|---|
| Fetch active program | Once per launch | `programs` |
| Fetch recent performance | Pre-workout | `set_logs` |
| Write set log | Every set | `set_logs` |
| Write session note | As needed | `session_notes` |
| Write session summary | Post-workout | `workout_sessions` |
| Embed + write memory | Async post voice note | `memory_embeddings` |
| Retrieve memory | Per set (parallel) | `memory_embeddings` |

### 10.3 Write Resilience

Local write-ahead queue (`WriteAheadQueue` actor) queues failed writes during network outages. Queue is flushed on network restoration and app foreground. All writes also cached in SwiftData for session recovery.

### 10.4 Auth Architecture (MVP)

- Anonymous single-user: stable UUID in Keychain
- Supabase anonymous sign-in → JWT (1hr expiry, auto-refreshed)
- RLS policies scope all reads/writes via `auth.uid()`
- No sign-in UI in MVP

### 10.5 Database Indexes

| Table | Index | Type |
|---|---|---|
| `memory_embeddings` | `embedding` | HNSW cosine |
| `memory_embeddings` | `user_id` | B-tree |
| `workout_sessions` | `(user_id, session_date DESC)` | B-tree |
| `set_logs` | `session_id` | B-tree |
| `programs` | `user_id` | B-tree |
| `gym_profiles` | `user_id` | B-tree |

---

## 11. HealthKit Integration

### 11.1 HealthKitService Interface

```swift
actor HealthKitService {
    func requestPermissions() async throws  // HRV SDNN, resting HR, active energy, sleep
    func fetchTodayBiometrics() async -> Biometrics?
    func computeReadinessScore(from biometrics: Biometrics) -> ReadinessScore
    func fetchHRVBaseline() async -> Double?  // 30-day rolling mean
    func refreshIfStale() async               // > 12h old
}
```

### 11.2 ReadinessScore Computation

**Scoring (0–100):**

| Component | Max Points | Logic |
|---|---|---|
| HRV delta from baseline | 40 | Maps [-30%, +15%] → [0, 40]. Neutral fallback: 20 |
| Sleep duration | 30 | Target 8h. Linear ratio. Neutral fallback: 15 |
| Sleep quality | 30 | % time deep + REM. Neutral fallback: 15 |

**Labels:**
- 80–100: Optimal → tint `#3A8EFF`
- 60–79: Good → tint `#8A9AAF`
- 40–59: Reduced → tint `#E8A030`
- 0–39: Poor → tint `#E84830`

### 11.3 HRV Baseline

30-day rolling mean of `heartRateVariabilitySDNN` samples via `HKSampleQueryDescriptor`.

### 11.4 Edge Case Handling Matrix

| Scenario | Behaviour |
|---|---|
| HealthKit permission denied | `biometrics = nil`; LLM uses neutral defaults |
| No HRV samples (unworn) | HRV contribution = neutral (20pts) |
| No 30-day baseline (first 30 days) | `hrv_delta_pct = nil`; absolute HRV included with `no_baseline` flag |
| Stale cache (> 12h) | Auto-refresh on workout initiation |
| HRV spike > 200ms | Clamped to 200ms before delta calculation |
| Sleep data missing | Sleep contributions = 15pts each (neutral) |

---

## 12. Security & Key Management

### 12.1 Keychain Keys

```swift
enum KeychainKey: String {
    case anthropicAPIKey  = "com.projectapex.key.anthropic"
    case openAIAPIKey     = "com.projectapex.key.openai"
    case supabaseAnonKey  = "com.projectapex.key.supabase.anon"
    case supabaseJWT      = "com.projectapex.key.supabase.jwt"
    case userId           = "com.projectapex.userid"
}
```

Keys stored in `kSecClassGenericPassword`. Never in `UserDefaults`, `Info.plist`, source code, or build environment variables.

### 12.2 Developer Settings (MVP)

`DeveloperSettingsView` — manual key entry with:
- Masked text fields per key
- Basic format validation (`sk-ant-`, `sk-`, `eyJ` prefix checks)
- Green checkmark on confirmed Keychain presence
- Replaced by backend proxy in any multi-user future version

### 12.3 Data Privacy Model

| Data | Local | Supabase | Sent to LLM |
|---|---|---|---|
| Raw HealthKit time-series | No | No | No |
| ReadinessScore (computed) | Session | No | Yes (score + label) |
| HRV SDNN values | Session | No | Yes (numeric) |
| Voice note transcripts | No | Yes | Yes (in payload) |
| Set logs | SwiftData | Yes | Yes (recent history) |
| GymProfile | UserDefaults | Yes | Yes (constraints) |
| Camera frames | No | No (debug only) | Yes (one-time scan) |

### 12.4 Network Security

- HTTPS only. `NSAllowsArbitraryLoads = false`.
- No certificate pinning in MVP (required before public release).
- Supabase JWT: 1hr expiry, auto-refreshed by `SupabaseClient`.

---

## 13. Error Handling & Resilience Patterns

### 13.1 Error Type Hierarchy

```
AppError
├── ScannerError: cameraPermissionDenied, visionAPIFailed, noEquipmentDetected
├── ProgramGenerationError: llmFailed, decodingFailed, equipmentConstraintViolation, noActiveProgramFound
├── InferenceError: apiTimeout, maxRetriesExceeded, validationFailed, networkUnavailable
├── MemoryError: embeddingFailed, retrievalFailed
├── HealthKitError: notAvailable, permissionDenied, queryFailed
└── PersistenceError: supabaseWriteFailed, localCacheFailed, writeAheadQueueFull
```

### 13.2 Set Prescription Fallback Chain

```
Attempt 1 (8s timeout) → Attempt 2 (modified prompt) → Attempt 3 → FALLBACK:

    If failure occurs during rest timer (timer still running):
        → Silent — inferenceRetryReason recorded, no UI change
        → When timer expires → inferenceRetryNeeded = true → InferenceRetrySheet appears

    If failure occurs during preflight (no rest timer):
        → inferenceRetryNeeded = true immediately → InferenceRetrySheet appears

InferenceRetrySheet (P3-T07):
    → User taps Retry: retryInference() called — single fresh attempt
      ├── Success: sheet dismissed, prescription set, state → .active
      └── Failure: sheet stays, updated error reason shown

    → User taps Pause Session: pauseSession() called → session safely persisted
```

**Note:** `makeFallbackPrescription()` has been removed. There is NO silent auto-fallback.
The user always gets to choose between retrying or pausing.

### 13.3 UI Error Presentation Policy

| Error | Presentation | User Action |
|---|---|---|
| AI inference failure | `InferenceRetrySheet` (modal, dismiss disabled) | Retry or Pause Session |
| HealthKit unavailable | Subtle readiness card indicator | None |
| Network unavailable during workout | Persistent banner; writes queued | None |
| Program generation failed | Full-screen error + Retry | Retry required |
| API key missing | Full-screen setup prompt | Must enter keys |
| Paused session exists on new start | Alert with Discard / Cancel | User choice required |

### 13.4 Retry Policies

| Operation | Max Retries | Backoff | Timeout | Notes |
|---|---|---|---|---|
| LLM set inference (HTTP 429/529/502–504) | 3 (4 total) | Exponential 1s→8s + 0.5s jitter | 8s outer (product) | `TransientRetryPolicy`; non-transient HTTP fails immediately |
| LLM JSON decode / validation failure | 2 (3 total) | None (prompt-modified) | 8s outer | Separate from HTTP retry |
| Session plan generation (HTTP transient) | 3 | Exponential 1s→8s + 0.5s jitter | 120s session (URL) | `TransientRetryPolicy` |
| Exercise swap chat (HTTP transient) | 3 | Exponential 1s→8s + 0.5s jitter | 15s session (URL) | `TransientRetryPolicy` |
| Memory Haiku classification (HTTP transient) | 1 (2 total) | 1s flat | 5s racing timeout | Inline retry in `MemoryService.classifyTags()` |
| Supabase set log write | 5 | Exponential (1s→16s) | 10s | `WriteAheadQueue` |
| Memory embedding upsert | 3 | Linear (2s) | 5s | |
| Program generation | 1 corrective re-prompt | None | None | |
| HRV baseline fetch | 2 | Linear (1s) | 5s | |

---

## 14. Testing Strategy

### 14.1 Test Pyramid

- **Unit (60%)**: `SetPrescription.validate()`, `ReadinessScore`, `EquipmentMerger`, `DefaultWeightIncrements`, `GymFactStore`, `WorkoutContext` assembly
- **Integration (30%)**: Service interactions, Supabase writes, HealthKit queries
- **UI (10%)**: XCUITest end-to-end flows

### 14.2 Current Status

| File | Status | Coverage |
|---|---|---|
| `EquipmentMergerTests.swift` | ✅ Green | Presence-only dedup, cardio/junk blocklists, unknown-always-dropped |
| `GymProfileTests.swift` | ✅ Green | Round-trip Codable, notes, count(of:), item(for:) |
| `DefaultWeightIncrementsTests.swift` | ✅ Green | defaults(for:), nearestWeights, dumbbell/barbell/cable/kettlebell ranges |
| `GymFactStoreTests.swift` | ✅ Green | recordCorrection, knownSubstitution, contextStrings, persistence, clearAll |
| `EquipmentRounderTests.swift` | ✅ Green | Now contains `SetPrescriptionValidationTests` only (EquipmentRounder retired) |
| `KeychainServiceTests.swift` | ✅ Green | Store, retrieve, delete |
| `AIInferenceSpikeTests.swift` | ✅ Green | Live API spike |
| `AIInferenceServiceTests.swift` | ✅ Green | Retry loop, fallback paths |
| `WorkoutContextAssemblyTests.swift` | ✅ Green | Full JSON round-trip |
| `SupabaseClientTests.swift` | ✅ Green | CRUD + RPC |
| `EquipmentConstraintValidationTests.swift` | ✅ Green | Post-generation equipment constraint violations |
| `ProgramPersistenceTests.swift` | ✅ Green | UserDefaults cache round-trip, clearUserDefaults |
| `WorkoutSessionManagerTests.swift` | ✅ Green | Start→active, completeSet→resting, inference failure → `inferenceRetryNeeded=true` (no silent prescription), safety gate, endSessionEarly, reentrancy guard, context assembly |
| `WriteAheadQueueTests.swift` | ✅ Green | FIFO ordering, flush on success, retry with backoff, clearAll, QueuedWrite Codable round-trip |
| `GymStreakServiceTests.swift` | ✅ Green | All 4 tier boundaries, score formula, no sessions, 1-day gap, 2+ day gap, duplicate dates, stale cache, neutral fallback (P4-E1) |

### 14.3 Planned Tests

| File | Priority | Key Scenarios |
|---|---|---|
| `ReadinessScoreTests` | P0 | All Section 11.4 edge cases, boundary scores, nil biometrics |
| `ActiveSetViewTests.swift` | P0 | Rep/RPE auto-dismiss countdown, offline banner 3s dismiss, safety flag colours |
| `RestTimerViewTests.swift` | P0 | Ring progress calculation, haptic firing at 10s/0s, skipRest() transition |
| `MemoryServiceTests.swift` | P1 | Pain keyword detection, event generation, threshold filtering |
| `ScannerViewModelTests.swift` | P1 | State machine transitions, captureAndIdentify happy/empty path |
| `DayStatusTests.swift` | P1 | DayStatus.resolve() — today/future/past boundaries, edge cases |

### 14.4 Coverage Targets

| Module | Target |
|---|---|
| `SetPrescription.validate()` | 100% |
| `DefaultWeightIncrements` | 100% |
| `GymFactStore` | 100% |
| `EquipmentMerger` | 100% |
| `AIInferenceService` (retry/fallback paths) | 90% |
| `HealthKitService.computeReadinessScore` | 100% |
| `MemoryService` (write path) | 80% |
| `WorkoutSessionManager` | 75% |

### 14.5 Mock Architecture

All external services are protocol-backed:

```swift
protocol LLMProvider: Sendable { ... }
protocol HealthKitDataSource: Sendable { ... }
protocol SupabaseDataStore: Sendable { ... }
protocol EmbeddingProvider: Sendable { ... }
```

### 14.6 CI (GitHub Actions)

```yaml
name: ProjectApex CI
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
      - name: Build & Test
        run: |
          xcodebuild test \
            -scheme ProjectApex \
            -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
            -resultBundlePath TestResults.xcresult | xcpretty
```

---

## 15. Performance Budgets & Targets

### 15.1 Latency Budgets

| Operation | P50 | P99 | Hard Limit |
|---|---|---|---|
| App cold launch to Program tab | < 1.2s | < 2.0s | 3.0s |
| Workout session start (pre-flight) | < 2.0s | < 3.5s | 5.0s |
| Set prescription (LLM inference) | < 3.5s | < 6.0s | 8.0s |
| Voice note STT (on-device) | < 0.5s | < 1.0s | 3.0s |
| Memory embedding write | < 1.0s | < 2.0s | 5.0s |
| RAG retrieval | < 300ms | < 600ms | 2.0s |
| Supabase set log write | < 500ms | < 1.5s | 3.0s |

### 15.2 Memory Targets

| Context | Heap Budget |
|---|---|
| Idle / Background | < 30 MB |
| Active Workout | < 80 MB |
| Gym Scanning | < 150 MB |
| Program Overview | < 60 MB |

### 15.3 Network Payload Sizes

| Operation | Approx Size |
|---|---|
| Set inference request (WorkoutContext) | ~3–5 KB JSON |
| Set inference response | ~500 bytes JSON |
| Gym scan frame (Base64 JPEG) | ~80–150 KB |
| Memory embedding response (vector) | ~12 KB |

---

## 16. Build, Deployment & Configuration

### 16.1 Build Configurations

| Config | API Keys | Logging | Assertions |
|---|---|---|---|
| `Debug` | Keychain (dev keys) | Verbose | Enabled |
| `Release` | Keychain (prod keys) | Errors only | Disabled |

### 16.2 Target Deployment

| Field | Value |
|---|---|
| Minimum iOS | iOS 17.0 |
| Development target | iOS 26.2 |
| Devices | iPhone (primary) |
| Distribution | Personal (development profile) |

### 16.3 Confirmed Xcode Settings

- `PRODUCT_NAME = ProjectApex` (app), `ProjectApexTests` (test target)
- `GENERATE_INFOPLIST_FILE = YES` — both targets
- `IPHONEOS_DEPLOYMENT_TARGET = 26.2` — identical across all targets

---

## 17. Known Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| LLM inference latency > 8s | Medium | High | Fallback chain; monitor p99 per model |
| Vision API equipment misidentification | High | Medium | Manual confirmation step post-scan |
| pgvector HNSW degradation | Low (MVP) | Low | Index rebuild if recall drops |
| Actor reentrancy producing stale prescription | Medium | Medium | `inflightRequestCount` guard; serialized set completion |
| Voice note picks up ambient gym noise | High | Low | Min confidence threshold |
| Camera permission denied | Medium | High | Graceful degradation to manual entry |
| LLM model deprecation | Low | High | Model strings in `Config`; swap without architectural change |

---

## 18. Appendix: Sequence Diagrams

### 18.1 Gym Scan (Guided Mode)

```
User → ScannerView → ScannerViewModel → CameraManager → VisionAPIService → EquipmentMerger → Supabase
tap Start → requestPermission → AVCaptureSession start → .previewing
tap Shutter → captureOneFrame() → one-shot AVCapturePhoto
  → analyseFrame(frame) → POST Vision API (single-item prompt)
  → .reviewed(item) → user taps "Add to List"
  → mergeItems() → .previewing (repeat for each equipment)
tap Done → .confirming
tap Save → saveToUserDefaults + POST gym_profiles → .completed
```

### 18.2 Active Workout Set Loop

```
User taps Set Complete
→ WorkoutViewModel.onSetComplete()
→ WorkoutSessionManager.completeSet()
    ├── write SetLog (fire-and-forget)
    ├── state = .resting (rest timer starts)
    ├── [parallel] retrieve RAG memory
    ├── assemble WorkoutContext
    ├── aiInferenceService.prescribe(ctx)
    │   → POST LLM → validate → round → .success(prescription)
    └── [timer expires + prescription ready] → state = .active(nextSet)
```

### 18.3 Voice Note → Memory Embedding

```
tap mic → SpeechService.startListening() → AsyncStream<String> partial transcripts
tap mic → final transcript
→ WorkoutSessionManager.addVoiceNote()
    ├── write session_notes (Supabase)
    ├── append to WorkoutContext (in-memory)
    └── MemoryService.embed() [Task.detached]
        ├── POST /embeddings (OpenAI)
        └── upsert memory_embeddings (Supabase)
```

---

# PART 2: UI/UX SPECIFICATION

## Design Philosophy & Vision

### Core Aesthetic: Liquid Glass Athleticism

iOS 26's Liquid Glass material system applied with an athletic, premium edge. Deep space chromes, translucent depth, surfaces that feel like condensation on cold steel.

**Design Principles:**
1. **Prescription First** — AI prescription is always the largest, most legible element. Everything else is subordinate.
2. **Glass Breathes** — Every glass surface has a specific `blurRadius`, `saturation`, and `opacity` that is intentional.
3. **Data Has Weight** — Numbers (kg, reps, seconds) have more visual mass than interface chrome. SF Pro Rounded for all numerals.
4. **Intelligence is Subtle** — AI presence is felt, not announced. Reasoning is ghost text. Confidence is a barely-visible arc.
5. **Readiness Colours the World** — ReadinessScore bleeds a 15% tint into the entire session.

---

## Liquid Glass Design System

### Glass Material Tiers

| Tier | Name | blurRadius | Use |
|---|---|---|---|
| 1 | `ApexGlass.deepField` | 40 | Primary backgrounds, modal sheets |
| 2 | `ApexGlass.prescription` | 60 | AI prescription card (cornerRadius: 28pt) |
| 3 | `ApexGlass.chromePill` | 20 | Buttons, badges, chips (cornerRadius: 14pt) |
| 4 | `ApexGlass.ghost` | 12 | Secondary labels, inactive states |

### Background System

```swift
struct ApexBackground: View {
    var readinessTint: Color = .apexChrome
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [readinessTint.opacity(0.18), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.15),
                startRadius: 0, endRadius: 400
            ).ignoresSafeArea().blendMode(.plusLighter)
            NoiseTextureView(opacity: 0.025).ignoresSafeArea()
        }
    }
}
```

### Readiness Tint Colours

| Score | Label | Hex |
|---|---|---|
| 80–100 | Optimal | `#3A8EFF` (cool chrome blue) |
| 60–79 | Good | `#8A9AAF` (neutral silver) |
| 40–59 | Reduced | `#E8A030` (warm amber) |
| 0–39 | Poor | `#E84830` (deep red-orange) |

### Elevation & Depth System

| Level | Material | Refraction | Use |
|---|---|---|---|
| L0 | None | None | Background |
| L1 | `ApexGlass.ghost` | Minimal | Section separators |
| L2 | `ApexGlass.deepField` | Standard | Content cards |
| L3 | `ApexGlass.prescription` | High | Primary action cards |
| L4 | `ApexGlass.chromePill` | Very High | Buttons, CTAs |
| L5 | `GlassEffectContainer` | Maximum | Modals, sheets |

---

## Typography System

```swift
extension Font {
    static let apexWeight      = Font.system(size: 72, weight: .black, design: .rounded)
    static let apexWeightUnit  = Font.system(size: 24, weight: .semibold, design: .rounded)
    static let apexReps        = Font.system(size: 56, weight: .bold, design: .rounded)
    static let apexTimer       = Font.system(size: 80, weight: .ultraLight, design: .rounded).monospacedDigit()
    static let apexSetBadge    = Font.system(size: 13, weight: .bold, design: .rounded)
    static let apexExerciseName = Font.system(size: 22, weight: .semibold, design: .default)
    static let apexCoachingCue  = Font.system(size: 15, weight: .regular, design: .default).italic()
    static let apexReasoning    = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let apexSectionHeader = Font.system(size: 13, weight: .semibold, design: .default)
    static let apexBody         = Font.system(size: 17, weight: .regular)
    static let apexCaption      = Font.system(size: 12, weight: .regular)
    static let apexFootnote     = Font.system(size: 13, weight: .regular)
}
```

**Rule**: All numerics use SF Pro Rounded + `monospacedDigit()` when animated.

---

## Color & Material System

```swift
extension Color {
    // Base Field
    static let apexVoid         = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let apexDeepField    = Color(red: 0.07, green: 0.08, blue: 0.10)
    // Chrome
    static let apexChrome       = Color(red: 0.78, green: 0.82, blue: 0.88)
    static let apexWhite        = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let apexGhostWhite   = Color.white.opacity(0.35)
    // Readiness
    static let apexOptimal      = Color(red: 0.23, green: 0.56, blue: 1.00)  // #3A8EFF
    static let apexGood         = Color(red: 0.54, green: 0.60, blue: 0.69)  // #8A9AAF
    static let apexReduced      = Color(red: 0.91, green: 0.63, blue: 0.19)  // #E8A030
    static let apexPoor         = Color(red: 0.91, green: 0.28, blue: 0.19)  // #E84830
    // Safety
    static let apexSafetyAlert  = Color(red: 1.00, green: 0.75, blue: 0.00)
    static let apexSafetyDanger = Color(red: 1.00, green: 0.25, blue: 0.15)
    static let apexSafetyInfo   = Color(red: 0.40, green: 0.80, blue: 1.00)
    // Muscle Groups
    static let apexChest        = Color(red: 0.96, green: 0.42, blue: 0.30)
    static let apexBack         = Color(red: 0.30, green: 0.70, blue: 0.96)
    static let apexShoulders    = Color(red: 0.70, green: 0.50, blue: 0.96)
    static let apexLegs         = Color(red: 0.30, green: 0.96, blue: 0.60)
    static let apexArms         = Color(red: 0.96, green: 0.80, blue: 0.30)
    static let apexCore         = Color(red: 0.96, green: 0.60, blue: 0.30)
    // Glass Edge
    static let apexSpecularLight = Color.white.opacity(0.28)
    static let apexSpecularEdge  = Color.white.opacity(0.08)
}
```

**Dark mode only** for MVP: `.preferredColorScheme(.dark)` applied at scene level.

---

## Motion & Animation

### Animation Spring Tokens

```swift
extension Animation {
    static let apexSnap       = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let apexFloat      = Animation.spring(response: 0.55, dampingFraction: 0.65)
    static let apexSettle     = Animation.spring(response: 0.70, dampingFraction: 0.88)
    static let apexCrystalise = Animation.spring(response: 0.45, dampingFraction: 0.70)
    static let apexTimer      = Animation.linear(duration: 1.0)
    static let apexRipple     = Animation.easeOut(duration: 0.60)
}
```

### Key Transitions

```swift
extension AnyTransition {
    static var apexCrystallise: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.85).combined(with: .opacity).combined(with: .blur(radius: 8)),
            removal: .scale(scale: 1.05).combined(with: .opacity)
        )
    }
    static var apexSetComplete: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
    static var apexPrescriptionReveal: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}
```

### Reduced Motion

All animations respect `@Environment(\.accessibilityReduceMotion)`:
- Crystallisation → `.opacity` crossfade only
- Glass ripple → disabled
- Spring animations → `Animation.linear(duration: 0.2)`

---

## Iconography (SF Symbols 6)

| Context | Symbol |
|---|---|
| Start workout | `figure.strengthtraining.traditional` |
| Set complete | `checkmark.circle.fill` |
| Rest timer | `timer` |
| Voice note | `mic.fill` |
| AI coach active | `brain.head.profile` |
| AI offline | `brain.head.profile.slash` |
| Equipment scan | `camera.viewfinder` |
| Calendar / Program | `calendar` |
| Settings | `gearshape.fill` |
| Personal Record | `trophy.fill` |
| Safety flag | `shield.lefthalf.filled.slash` |
| Tempo | `metronome` |

---

## Core Component Library

### PrescriptionCard Layout

```
╔═══════════════════════════════════════════╗  ← Tier 3 Glass, radius 28pt
║  EXERCISE NAME [MUSCLE CHIP]  SET 3 OF 4  ║  ← Header
║                                           ║
║      32.5 kg              10 reps         ║  ← Weight (72pt) / Reps (56pt)
║                                           ║
║  ── ⏱ 3-1-2-0      🎯 RIR 3 ──          ║
║                                           ║
║  "Control descent, pause at chest"        ║  ← Coaching cue (15pt italic)
║  ░ hrv -18% · anterior fatigue           ║  ← Reasoning ghost (12pt mono)
║  [⚠ shoulder_caution]                    ║  ← Safety flag (conditional)
╚═══════════════════════════════════════════╝
  87% ────────────────                         ← Confidence arc (bottom edge)
```

**Key implementation notes:**
- Weight uses `.contentTransition(.numericText())` with `.id("weight_\(value)")` to force re-render
- Card appears with `.apexCrystalise` animation on `onAppear`
- Specular top-edge highlight via `LinearGradient` stroke overlay

### SafetyFlag Colors

| Flag | Color |
|---|---|
| `painReported` | `apexSafetyDanger` |
| `shoulderCaution`, `jointConcern` | `apexSafetyAlert` |
| `fatigueHigh`, `deloadRecommended` | `apexSafetyInfo` |

### SetCompleteButton

- Height: 72pt, full width capsule
- Haptic: `UIImpactFeedbackGenerator(.heavy)` on tap
- Scales to 0.96 on press (`.apexSnap`)
- `GlassRippleModifier` expands from tap point

### RestTimerView

- Dominant full-screen view between sets
- Timer digit: 80pt ultraLight rounded + `monospacedDigit()`
- Progress ring: 220pt circle, 3pt stroke, `AngularGradient`
- Shows `AIThinkingIndicator` while prescription is pending
- `SKIP REST` ghost button (`.white.opacity(0.30)`)
- Haptic on expiry: `UINotificationFeedbackGenerator(.warning)`

### AIThinkingIndicator

Three dots in liquid wave pattern, `easeInOut(duration: 0.5).repeatForever()` with 0.15s delay between dots.

---

## Screen Specifications

### Gym Scanner (Guided Mode)

- Camera: full-screen live feed (`CameraPreviewView`)
- **Shutter button**: large white circle, bottom-centre
- **Item count badge**: top-left pill showing "N items captured" (hidden when 0)
- **"Done" button**: top-right, visible only when ≥1 item captured
- **Analyzing overlay**: frosted black + spinner + "Identifying equipment…" while API runs
- **Result card**: `regularMaterial` card with detected equipment name, count, "Add to List" / "Discard" / "Edit before adding"
- **Nothing detected toast**: red pill "No gym equipment detected — try again", 2.5s auto-dismiss
- No continuous scan animation; no frame counter HUD

### Equipment Confirmation

- Glass list cards per detected item; tap to edit, swipe to delete
- "Add Equipment Manually" button at bottom
- "Re-scan" (destructive, top-left) and "Save" (top-right) toolbar buttons
- Full-width confirm action saves profile to UserDefaults + Supabase

### Program Overview (12-Week Calendar)

- Phase progress bar
- Day cards: today has "START WORKOUT" CTA; future days are tappable
- Mini week cards for upcoming weeks
- Inline bar chart: sets per muscle group with `apexMuscle*` colors

### Active Set Screen

- Cinematic dark bg + readiness tint
- Session header (ghost): "UPPER A · Exercise 2 of 5"
- Exercise progress dots
- `PrescriptionCard` (hero component)
- Full-width `SetCompleteButton` (72pt)
- Floating `VoiceNoteButton` (bottom-right)

### Set Complete → Rest Transition (Frame-by-Frame)

1. **T=0ms**: heavy haptic + button scale 0.96 + `GlassRippleModifier`
2. **T=80ms**: Rep/RPE confirmation sheet slides up (auto-dismisses in 5s)
3. **T=180ms**: Prescription card animates off top; rest timer animates in from bottom
4. **T=200ms**: Ring begins drawing; `AIThinkingIndicator` shown
5. **Prescription arrives (~3–6s)**: Indicator fades; next exercise preview updates
6. **Timer reaches 0**: Warning haptic + timer transitions out + prescription card crystallises in

### Rep/RPE Confirmation Sheet

- `.medium` detent, 24pt corner radius
- Large stepper (light haptic on each tap)
- 3-option segmented picker: "Too Easy / On Target / Hard"
- Auto-dismiss countdown at 5s

### Post-Workout Summary

- Volume summary (total kg, % change vs last session)
- Personal Records (`.mint` color, `trophy.fill`)
- AI Adjustments made (count + detail)
- Session Notes summary (voice notes flagged)

---

## Navigation & Transition System

| From → To | Transition | Duration |
|---|---|---|
| Welcome → Scanner | `.push(from: .trailing)` | 0.45s |
| Scanner → Confirm | Sheet presentation | 0.4s |
| Program Day → Workout | Hero (day card expands) | 0.55s |
| Active Set → Rest Timer | Vertical momentum | 0.4s |
| Rest Timer → Next Set | Vertical momentum | 0.4s |
| Workout → Summary | Fade through black | 0.6s |

**Tab bar**: Uses iOS 26 glass tab bar via `.tabViewStyle(.sidebarAdaptable)`. No custom implementation needed.

---

## Haptic Feedback Specification

| Event | Generator | Style |
|---|---|---|
| Set Complete tap | `UIImpactFeedbackGenerator` | `.heavy` |
| Rep stepper +/− | `UIImpactFeedbackGenerator` | `.light` |
| Rest timer expires | `UINotificationFeedbackGenerator` | `.warning` |
| Prescription arrived | `UIImpactFeedbackGenerator` | `.soft` |
| Personal record | `UINotificationFeedbackGenerator` | `.success` |
| Safety flag triggered | `UINotificationFeedbackGenerator` | `.warning` |
| Voice note started | `UIImpactFeedbackGenerator` | `.medium` |
| Error / AI offline | `UINotificationFeedbackGenerator` | `.error` |

---

## Accessibility

### VoiceOver — PrescriptionCard

```swift
.accessibilityElement(children: .combine)
.accessibilityLabel("Set \(setNumber) of \(totalSets). \(exercise.name). \(prescription.weightKg) kilograms. \(prescription.reps) reps. Tempo \(prescription.tempo). RIR target \(prescription.rirTarget). Coach says: \(prescription.coachingCue)")
.accessibilityHint("Double tap to mark set as complete")
```

### Dynamic Type

`ViewThatFits` fallback for prescription card at extreme text sizes (stacks weight above reps).

### Contrast Ratios (WCAG)

| Text / Background | Ratio | Passes |
|---|---|---|
| `apexWhite` on Tier 3 glass | 12.1:1 | ✅ AAA |
| `apexChrome` on Tier 3 glass | 5.8:1 | ✅ AA |
| `apexGhostWhite` on Tier 3 glass | 3.2:1 | ✅ AA (large only) |

Ghost text (`apexReasoning` at `.white.opacity(0.22)`) intentionally decorative — carries no critical information.

### Minimum Touch Targets

- `SetCompleteButton`: 72pt height, full width — far exceeds 44pt minimum
- `VoiceNoteButton`: 56pt circle — meets minimum
- Rep stepper buttons: 44×44pt enforced

---

## SwiftUI iOS 26 API Notes

### `.glassBackgroundEffect(displayMode:)`

Available iOS 26+. Applied to `.ultraThinMaterial` or `.thinMaterial` fills.
- `.always` — regardless of system setting
- `.automatic` — respects system material promotion
- `.never` — falls back to standard material

```swift
// Availability guard
if #available(iOS 26.0, *) {
    view.glassBackgroundEffect(displayMode: .always)
} else {
    view.background(.ultraThinMaterial)
}
```

### `GlassEffectContainer`

Groups adjacent glass views to share connected refraction:
```swift
GlassEffectContainer {
    HStack { TempoChip(...); RIRChip(...) }
}
```

### `.contentTransition(.numericText())`

Applied to `Text` views with changing numbers for iOS 26 counting morphs:
```swift
Text("\(reps)")
    .contentTransition(.numericText())
    .animation(.apexCrystalise, value: reps)
```

---

*End of ARCHITECTURE.md — Project Apex v1.0*
