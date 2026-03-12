# Project Apex — Architecture Reference
### Combines: Technical Design Document v1.0 + UI/UX Specification v1.0
### Platform: iOS 26+ | Last Updated: 2026-03-12

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
┌─────────────────────────────────────────────────────────────────┐
│                        iOS Application                          │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │
│  │  Scanner     │  │  Program     │  │  Workout Session      │ │
│  │  Feature     │  │  Feature     │  │  Feature              │ │
│  │  Module      │  │  Module      │  │  Module               │ │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬────────────┘ │
│         │                 │                      │              │
│  ┌──────▼─────────────────▼──────────────────────▼────────────┐ │
│  │                    Service Layer                            │ │
│  │  AIInferenceService │ HealthKitService │ MemoryService      │ │
│  │  SupabaseClient     │ GymFactStore     │ SpeechService      │ │
│  └──────┬──────────────┬──────────────────┬────────────────────┘ │
│         │              │                  │                      │
└─────────┼──────────────┼──────────────────┼──────────────────────┘
          │              │                  │
          ▼              ▼                  ▼
   ┌─────────────┐ ┌──────────┐    ┌───────────────────┐
   │  OpenAI /   │ │ Apple    │    │  Supabase          │
   │  Anthropic  │ │ HealthKit│    │  PostgreSQL        │
   │  APIs       │ │          │    │  + pgvector        │
   └─────────────┘ └──────────┘    └───────────────────┘
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
│   │   ├── ProgramOverviewView.swift
│   │   ├── ProgramDayDetailView.swift
│   │   └── ProgramViewModel.swift
│   └── Workout/
│       ├── WorkoutView.swift
│       ├── ActiveSetView.swift
│       ├── RestTimerView.swift
│       ├── PostWorkoutSummaryView.swift
│       ├── WeightCorrectionView.swift # User weight substitution sheet
│       └── WorkoutViewModel.swift
│
├── AICoach/
│   ├── AIInferenceService.swift      # actor — core inference engine
│   └── LLMProvider.swift             # protocol + AnthropicProvider + OpenAIProvider
│   # NOTE: EquipmentRounder.swift removed — weight snapping handled by
│   #       DefaultWeightIncrements (defaults) + GymFactStore (corrections)
│
├── Services/
│   ├── SupabaseClient.swift
│   ├── HealthKitService.swift
│   ├── MemoryService.swift
│   ├── SpeechService.swift
│   ├── GymFactStore.swift            # actor — runtime weight correction persistence
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
        └── SystemPrompt_MacroGeneration.txt
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
├── Tab 2: Workout (NavigationStack)
│   ├── PreWorkoutView
│   ├── WorkoutView                   # Active workout loop (state machine, not NavigationStack)
│   │   ├── ActiveSetView
│   │   └── RestTimerView
│   └── PostWorkoutSummaryView
└── Tab 3: Settings (NavigationStack)
    ├── SettingsView
    ├── GymScannerView
    └── DeveloperSettingsView
```

The active workout flow uses a `SessionState` machine rendered via `ZStack` — not `NavigationStack` — to prevent back-gesture interruptions during a set.

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

struct TrainingDay: Codable, Identifiable, Sendable {
    let id: UUID
    let dayOfWeek: Int
    let dayLabel: String         // e.g. "Upper_A", "Lower_B"
    var exercises: [PlannedExercise]
    let sessionNotes: String?
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
    var setLogs: [SetLog]
    var sessionNotes: [SessionNote]
    var summary: SessionSummary?
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
    let personalRecords: [PersonalRecord]
    let aiAdjustmentCount: Int
    let notableNotes: [String]
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

-- Users
CREATE TABLE IF NOT EXISTS public.users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
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
  summary      JSONB
);
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
  logged_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS set_logs_session_idx ON public.set_logs(session_id);

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
    let weightKg: Double
    let reps: Int
    let tempo: String          // regex: ^\d-\d-\d-\d$
    let rirTarget: Int
    let restSeconds: Int
    let coachingCue: String    // ≤ 100 chars
    let reasoning: String      // ≤ 200 chars
    let safetyFlags: [SafetyFlag]
    let confidence: Double?    // 0.0–1.0

    enum CodingKeys: String, CodingKey {
        case weightKg = "weight_kg"
        case reps
        case tempo
        case rirTarget = "rir_target"
        case restSeconds = "rest_seconds"
        case coachingCue = "coaching_cue"
        case reasoning
        case safetyFlags = "safety_flags"
        case confidence
    }
}

enum SafetyFlag: String, Codable, Hashable, Sendable {
    case shoulderCaution    = "shoulder_caution"
    case jointConcern       = "joint_concern"
    case fatigueHigh        = "fatigue_high"
    case painReported       = "pain_reported"
    case deloadRecommended  = "deload_recommended"
}
```

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

    func startSession(trainingDay: TrainingDay, programId: UUID) async
    func completeSet(actualReps: Int, rpeFelt: Int?) async
    func addVoiceNote(transcript: String, exerciseId: String) async
    func endSessionEarly() async
    func endSession() async
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
    ├── 1. Write SetLog to Supabase (fire-and-forget)
    ├── 2. state → .resting (rest timer starts immediately)
    ├── 3. [parallel] Assemble WorkoutContext:
    │       - sessionHistoryToday (accumulated sets)
    │       - healthKitContext (cached)
    │       - ragMemory (retrieved for next exercise)
    │       - gymConstraints (from GymProfile)
    ├── 4. await aiInferenceService.prescribe(context:)
    │       → .success(prescription) OR .fallback(reason)
    └── 5. When timer expires OR prescription arrives (whichever later):
            state → .active(nextExercise, setNumber + 1)
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

Stored in `Resources/Prompts/SystemPrompt_Inference.txt`.

**Key rules:**
1. Return ONLY `{"set_prescription": { ... }}` — no prose
2. Safety flags override all other logic
3. Pain/joint notes → reduce weight + increase rest + flag `pain_reported`
4. HRV delta < -15% → apply -5% to -10% conservative loading
5. `coaching_cue` ≤ 100 chars; `reasoning` ≤ 200 chars
6. `confidence`: 0.0–1.0 (optional)
7. Tempo regex: `^\d-\d-\d-\d$`
8. `rest_seconds` range: 30–600
9. `reps` range: 1–30

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
    weight_kg   = plannedExercise.planTarget.weightKg
    reps        = plannedExercise.repRange.max (conservative)
    tempo/rest  = from exercise definition
    coaching_cue = first cue from exercise definition
    reasoning   = "AI coach offline — using program defaults"
UI: Non-blocking "Coach offline" banner, 3 seconds
```

### 13.3 UI Error Presentation Policy

| Error | Presentation | User Action |
|---|---|---|
| AI inference fallback | Non-blocking banner (3s) | None |
| HealthKit unavailable | Subtle readiness card indicator | None |
| Network unavailable during workout | Persistent banner; writes queued | None |
| Program generation failed | Full-screen error + Retry | Retry required |
| API key missing | Full-screen setup prompt | Must enter keys |

### 13.4 Retry Policies

| Operation | Max Retries | Backoff | Timeout |
|---|---|---|---|
| LLM set inference | 2 (3 total) | None (prompt-modified) | 8s per attempt |
| Supabase set log write | 5 | Exponential (1s→16s) | 10s |
| Memory embedding upsert | 3 | Linear (2s) | 5s |
| Program generation | 1 corrective re-prompt | None | None |
| HRV baseline fetch | 2 | Linear (1s) | 5s |

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

### 14.3 Planned Tests

| File | Priority | Key Scenarios |
|---|---|---|
| `ReadinessScoreTests` | P0 | All Section 11.4 edge cases, boundary scores, nil biometrics |
| `MemoryServiceTests.swift` | P1 | Pain keyword detection, event generation, threshold filtering |
| `ScannerViewModelTests.swift` | P1 | State machine transitions, captureAndIdentify happy/empty path |

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
