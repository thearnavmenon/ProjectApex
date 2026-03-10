# Product Requirements Document
# Project Apex — "Runna for the Gym"
### Status: Draft v1.0 | Classification: Internal / Engineering
### Last Updated: 2026-03-10

---

## Table of Contents

1. [Meta Information](#1-meta-information)
2. [Executive Summary & Product Vision](#2-executive-summary--product-vision)
3. [Core User Journeys](#3-core-user-journeys)
4. [Functional Requirements](#4-functional-requirements)
5. [AI & Data Architecture](#5-ai--data-architecture)
6. [Technical Requirements & Stack](#6-technical-requirements--stack)
7. [Edge Cases & Math Guardrails](#7-edge-cases--math-guardrails)
8. [Out of Scope for MVP](#8-out-of-scope-for-mvp)

---

## 1. Meta Information

| Field | Value |
|---|---|
| **Project Codename** | Project Apex |
| **Target Platform** | iOS 17+ (iPhone primary; iPad adaptive layout) |
| **Build Phase** | MVP — Solo Power-User / Developer |
| **Primary Persona** | "The Quantified Lifter" — a technically sophisticated individual with an advanced training background who demands granular, data-driven feedback and rejects the one-size-fits-all recommendations of consumer fitness apps. |
| **Secondary Persona** | N/A (MVP is explicitly single-user) |
| **API Cost Posture** | Unconstrained. Maximum intelligence is the explicit design goal. |
| **Document Owner** | Product / AI Architecture |
| **Engineering Contact** | iOS Lead / Backend Lead |

### 1.1 Primary Persona Deep-Dive

**"The Quantified Lifter"** is an intermediate-to-advanced trainee (3–8 years consistent training) who:

- Tracks sleep, HRV, and recovery metrics via Apple Watch as standard hygiene.
- Has read the literature on RPE, RIR, progressive overload, and periodization.
- Is frustrated that Fitbod generates workouts algorithmically with no coherent mesocycle structure, and that Strong is nothing more than a glorified logbook.
- Can tolerate and appreciate technical UI — does not need everything abstracted away.
- Trains in a single, fixed gym environment (commercial gym, home gym, or hybrid).
- Primary goal: maximize hypertrophy and functional strength within a 12-week block.

---

## 2. Executive Summary & Product Vision

### 2.1 The Problem

The current fitness app landscape suffers from a fundamental architectural flaw: **they are reactive logbooks, not proactive coaches.**

- **Strong / Hevy**: Pure logging. Zero intelligence. The user does the programming. The app records it.
- **Fitbod**: Algorithmic workout generation using a volume-based fatigue model. Has no concept of a coherent multi-week program. Cannot reason about *why* a muscle is fatigued, only *that* it has been recently worked. Produces no tempo guidance, no cross-day context, and no qualitative feedback loop.
- **AI Coach apps (Future, Ladder)**: Human coaches mediated by apps, or static AI templates. Not truly real-time. Cannot adapt *between sets* in the same workout. Cannot integrate passive physiological data.
- **ChatGPT / Claude (raw)**: Stateless. No HealthKit integration. No equipment awareness. No persistent user memory. Requires the user to manually prompt and provide all context.

### 2.2 The Opportunity

Large Language Models, particularly when given structured context and constrained to JSON output, can function as world-class programming coaches — not just generating workouts, but **reasoning about the human body in real time.** When paired with Apple HealthKit's passive biometric stream and a robust vector-memory backend, the LLM gains the contextual depth previously only available to elite coaches with years of relationship history.

### 2.3 Product Vision Statement

> **Project Apex is the first truly stateful, AI-first hypertrophy coach for iOS.** It combines the structured, periodized macro-programming philosophy of elite strength coaches with the real-time, set-by-set micro-adjustment intelligence that only a large language model — armed with your biometrics, your feedback, and your history — can deliver. It does not suggest. It prescribes.

### 2.4 How It Beats the Competition

| Capability | Strong | Fitbod | Future | **Project Apex** |
|---|---|---|---|---|
| Coherent 12-week program | ❌ | ❌ | ✅ (human-written) | ✅ (AI-generated, periodized) |
| Real-time set-by-set adaptation | ❌ | ❌ | ❌ | ✅ |
| HealthKit biometric integration | ❌ | ❌ | ❌ | ✅ (HRV, Sleep, HR) |
| Qualitative voice feedback loop | ❌ | ❌ | ✅ (text to coach) | ✅ (voice-to-text, inline) |
| Equipment-aware programming | ❌ | Partial | ❌ | ✅ (Vision API scan) |
| Persistent injury/fatigue memory | ❌ | ❌ | ✅ (human recall) | ✅ (RAG vector memory) |
| Physics-constrained AI output | N/A | N/A | N/A | ✅ (rounding guardrails) |

---

## 3. Core User Journeys

### 3.1 Journey 1: Onboarding & Gym Scanning

**Goal**: Build an accurate, structured equipment profile that the AI can reference for all program generation. This is a one-time setup but can be re-run if the user's gym access changes.

#### 3.1.1 Step-by-Step Flow

**Step 1 — Welcome & Account Creation**
The user opens the app. A minimal onboarding screen collects:
- Display name (used in AI prompts for personalization).
- Training age (years of consistent training): entered as a discrete range (e.g., "1–2 years," "3–5 years," "5+ years").
- Primary goal for this 12-week block: Hypertrophy, Strength, or Hypertrophy/Strength blend (determines volume/intensity ratio in macro-programming).
- Days per week available: 3, 4, or 5.
- HealthKit permission prompt: Request read access for Sleep Analysis, Heart Rate Variability (SDNN), Resting Heart Rate, and Active Energy Burned.

**Step 2 — Gym Equipment Scan**
A full-screen camera view is presented with an animated scanning overlay and instructional copy:

> *"Pan your camera slowly around your gym. Capture all machines, free weights, cables, and benches."*

The live camera feed is segmented into overlapping still frames, captured at 2-second intervals while the user pans. The UI shows a progress indicator: a visual checklist of detected equipment categories that populate in real-time (e.g., "✅ Dumbbells detected," "✅ Cable station detected").

**Step 3 — Vision API Processing**
Each captured frame is encoded as Base64 and sent to the OpenAI Vision API (GPT-4o) or Anthropic's Claude Vision with the following system prompt context:

> *"You are an expert gym equipment auditor. Analyze this image and identify every piece of strength training equipment visible. For each item, extract: equipment_type, estimated_weight_range_kg (if applicable), increments_available_kg (if identifiable), and count. Return ONLY valid JSON."*

Responses are parsed and merged into a master `GymProfile` object, deduplicating and resolving conflicts (e.g., multiple frames confirming the same dumbbell rack).

**Step 4 — Equipment Confirmation UI**
The user is presented with a structured, editable list of detected equipment:
- Dumbbell set: 5 lbs – 100 lbs, 5 lb increments.
- Barbell + plates: Estimated 20 kg bar + plates to 200 kg.
- Cable machine: Single stack, estimated 200 lb max, 5 lb increments.
- Adjustable bench, lat pulldown, leg press, smith machine, etc.

The user can manually add, edit, or remove items. This is critical because Vision inference is probabilistic and edge cases exist (poor lighting, unfamiliar equipment brands).

**Step 5 — Profile Persistence**
The confirmed `GymProfile` is serialized to JSON and stored in Supabase under the user's profile row. It is also cached locally in UserDefaults for offline access. The profile is versioned with a `created_at` timestamp and a `scan_session_id`.

---

### 3.2 Journey 2: Weekly Program Generation (The Macro)

**Goal**: Generate a coherent, periodized 12-week hypertrophy/strength program constrained to the user's specific equipment. The user sees their full roadmap before lifting a single rep.

#### 3.2.1 Macro-Program Generation Logic

**Trigger**: Completed immediately after onboarding confirmation, or on demand via "Regenerate Program" in settings.

**Phase 1 — Mesocycle Architecture Prompt**

A structured prompt is sent to the LLM (Claude Opus or GPT-4o) with the following context payload:

```json
{
  "user_profile": {
    "training_age": "3-5 years",
    "primary_goal": "hypertrophy_strength_blend",
    "days_per_week": 4,
    "display_name": "Alex"
  },
  "gym_profile": {
    "equipment": [
      { "type": "dumbbell_set", "min_kg": 2.5, "max_kg": 45, "increment_kg": 2.5 },
      { "type": "barbell", "bar_weight_kg": 20, "max_load_kg": 180 },
      { "type": "cable_machine", "max_kg": 90, "increment_kg": 2.5 },
      { "type": "adjustable_bench" },
      { "type": "pull_up_bar" },
      { "type": "leg_press", "max_kg": 300, "increment_kg": 10 }
    ]
  },
  "programming_constraints": {
    "total_weeks": 12,
    "periodization_model": "linear_undulating",
    "deload_frequency_weeks": 4,
    "output_format": "mesocycle_json"
  }
}
```

The LLM is instructed to return a fully structured 12-week mesocycle defined as a nested JSON object: `Mesocycle → Weeks → Training Days → Exercises → Sets (target ranges)`.

**Phase 2 — Mesocycle Structure**

The 12-week block is divided into three 4-week mesocycles, each with a progressive intent:

- **Weeks 1–4 (Accumulation)**: Higher volume, moderate intensity. Rep ranges 8–15. RIR target 3–4.
- **Weeks 5–8 (Intensification)**: Reduced volume, higher intensity. Rep ranges 5–10. RIR target 2–3.
- **Weeks 9–11 (Peaking)**: Lower volume, highest relative intensity. Rep ranges 3–8. RIR target 1–2.
- **Week 12 (Deload)**: ~50% volume, same movement patterns. Active recovery. RIR target 4–5.

Each training day specifies: primary movement pattern, target exercises (with equipment constraints applied), set/rep targets, and rest intervals.

**Phase 3 — Persistence & UI**

The generated mesocycle JSON is stored in Supabase in the `programs` table with a foreign key to `user_id`. The iOS app fetches and renders it as a scrollable 12-week calendar view. Tapping any training day expands to reveal the planned exercise list with target parameters. Users can see upcoming deload weeks, progressive overload trends, and volume trajectory charts (weekly sets per muscle group).

---

### 3.3 Journey 3: The Active Workout & Set-by-Set AI Loop (The Micro)

**Goal**: Execute the day's planned workout with real-time, LLM-driven prescription for every set. This is the core differentiator and primary daily interaction.

#### 3.3.1 Pre-Workout Context Fetch

When the user initiates a workout session, the app silently performs a pre-flight data pull before the first exercise loads:

1. **HealthKit Query**: Fetch last 24h data for HRV (SDNN), sleep duration, sleep quality score, and resting heart rate. Calculate a composite `ReadinessScore` (0–100) using a weighted formula (HRV delta from 30-day baseline: 40%, sleep duration vs. 8h target: 30%, sleep quality: 30%).
2. **Historical Performance Query**: Fetch the last 2 sessions for each exercise planned today from Supabase. Extract actual sets, reps, weights, and any logged RPE/RIR values.
3. **RAG Memory Query**: Query the pgvector store for the top 3 most semantically similar user notes to today's planned exercises (e.g., past notes about shoulder tightness when today includes overhead pressing).

This pre-flight data forms the `WorkoutContext` object that is attached to every subsequent set-level AI request.

#### 3.3.2 The Active Set UI

The workout screen is structured as a card-based interface. The current exercise is displayed full-screen with:

- Exercise name, muscle group target, and a short coaching cue.
- **The AI Prescription Card**: Displayed prominently before each set. Shows: `Weight: 32.5 kg | Reps: 10 | Tempo: 3-1-2-0 | RIR Target: 3`.
- A large "Set Complete" button.
- A rest timer that auto-starts upon set completion.
- A microphone button labeled "Coach, note this" for qualitative voice input.

#### 3.3.3 The Set Completion Loop

Upon tapping "Set Complete," the user is briefly prompted (optional, 5-second timeout with auto-dismiss):
- Actual reps completed (pre-filled with target; user adjusts via +/- stepper).
- RPE/RIR felt (optional 1-tap slider: "Too easy | On target | Too hard").

This data is immediately written to Supabase (`set_logs` table) and the AI inference call for the *next* set is triggered in parallel.

#### 3.3.4 Voice Feedback Integration

The microphone button is available at any time during a workout. Tapping it opens a live STT (Speech-to-Text) modal using Apple's `SFSpeechRecognizer`. The transcribed text is displayed in real time and, upon completion, is:

1. Appended to the current `WorkoutContext.qualitative_notes` array.
2. Embedded and upserted into the pgvector memory store with metadata tags (exercise name, date, muscle group).
3. Included in the next LLM inference payload.

Example voice notes and their downstream effects:
- *"Left shoulder feels impinged on the way up"* → LLM may reduce weight, add tempo pause at bottom, or note to avoid specific shoulder exercises later in the session.
- *"That felt way too easy, I had 5 reps in the tank"* → LLM increases next set weight and narrows RIR target.
- *"Feeling a pump but my elbow is clicking"* → LLM flags the note in memory with a `joint_concern` tag; reduces weight; adds rest interval.

---

## 4. Functional Requirements

### 4.1 FR-001: Gym Equipment Scanning

| ID | Requirement | Priority |
|---|---|---|
| FR-001-A | App must request and handle `AVCaptureSession` camera access with graceful degradation if denied. | P0 |
| FR-001-B | App must capture still frames from camera at configurable intervals (default: 2s) while user pans. | P0 |
| FR-001-C | Each frame must be compressed to JPEG at 80% quality and Base64-encoded before API transmission. | P0 |
| FR-001-D | Vision API responses must be parsed against a strict `EquipmentItem` schema; non-conforming responses must be discarded without crashing. | P0 |
| FR-001-E | Duplicate equipment items across frames must be merged using equipment_type as primary key and count aggregated. | P1 |
| FR-001-F | User must be able to manually add, edit, or remove any equipment item post-scan. | P0 |
| FR-001-G | Final GymProfile must be persisted to both Supabase (remote) and UserDefaults (local cache). | P0 |
| FR-001-H | App must support re-scanning (overwriting existing profile) with explicit user confirmation dialog. | P1 |

### 4.2 FR-002: Macro-Program Generation

| ID | Requirement | Priority |
|---|---|---|
| FR-002-A | App must generate a full 12-week mesocycle on first launch post-onboarding before allowing access to the workout screen. | P0 |
| FR-002-B | All exercises in the generated program must be physically achievable with at least one item from the user's GymProfile. | P0 |
| FR-002-C | Program must include explicit deload weeks at configurable intervals (default: week 4, 8, 12). | P0 |
| FR-002-D | Each training day must specify: exercise list, target sets, rep range (min–max), rest intervals, and tempo notation. | P0 |
| FR-002-E | The full program JSON must be stored in Supabase and cached locally for offline access. | P0 |
| FR-002-F | App must render a 12-week calendar/roadmap view allowing the user to preview any future training day. | P1 |
| FR-002-G | Weekly volume per muscle group must be surfaced as a chart (sets per muscle group per week). | P2 |
| FR-002-H | User must be able to swap an individual exercise within a session while preserving the muscle group target. | P1 |

### 4.3 FR-003: HealthKit Integration

| ID | Requirement | Priority |
|---|---|---|
| FR-003-A | App must request HealthKit read permissions for: HRV (SDNN), Sleep Analysis, Resting Heart Rate, Active Energy Burned. | P0 |
| FR-003-B | App must handle HealthKit permission denial gracefully — workout proceeds with degraded context (no biometric data in AI payload). | P0 |
| FR-003-C | App must compute a `ReadinessScore` (0–100) from the last night's sleep and HRV delta vs. 30-day rolling baseline. | P0 |
| FR-003-D | `ReadinessScore` must be prominently displayed on the pre-workout screen with a human-readable label (e.g., "Optimal," "Reduced," "Poor"). | P1 |
| FR-003-E | HealthKit data must be fetched async in the background when the app foregrounds each morning; stale data (>12h) triggers a re-fetch on workout initiation. | P1 |

### 4.4 FR-004: Active Workout Session

| ID | Requirement | Priority |
|---|---|---|
| FR-004-A | Workout screen must display one exercise at a time with the AI prescription (weight, reps, tempo, RIR) prominently before each set. | P0 |
| FR-004-B | "Set Complete" interaction must log actual reps and felt RPE/RIR to Supabase within 2 seconds of tap. | P0 |
| FR-004-C | Rest timer must auto-start upon set completion with the AI-prescribed rest duration. | P0 |
| FR-004-D | App must trigger the next-set AI inference call immediately upon set completion, targeting response delivery before rest timer expires. | P0 |
| FR-004-E | If AI inference call fails or times out (>8 seconds), app must fall back to the pre-computed plan target parameters and display a non-blocking "Coach offline" indicator. | P0 |
| FR-004-F | Microphone input must be available at all times during a session; STT must use on-device `SFSpeechRecognizer` with cloud fallback. | P0 |
| FR-004-G | Voice notes must be appended to the session log in Supabase with timestamp, associated exercise, and raw transcript. | P0 |
| FR-004-H | App must support ending a workout early, logging a partial session with a `completed: false` flag. | P1 |
| FR-004-I | App must display a post-workout summary screen showing: volume completed, AI adjustments made vs. plan, personal records achieved, and notable voice notes. | P1 |

### 4.5 FR-005: AI Prescription & Memory

| ID | Requirement | Priority |
|---|---|---|
| FR-005-A | Every LLM inference call must include the full WorkoutContext payload (see Section 5.1). | P0 |
| FR-005-B | LLM response must be validated against the `SetPrescription` JSON schema before being rendered to the UI. | P0 |
| FR-005-C | Invalid or non-conforming LLM responses must trigger a structured retry (max 2 retries) before falling back to plan defaults. | P0 |
| FR-005-D | All voice notes and qualitative feedback must be embedded and stored in pgvector within 5 seconds of transcription completion. | P1 |
| FR-005-E | RAG retrieval must return the top-K (default K=3) most semantically relevant historical notes for each inference call. | P0 |
| FR-005-F | Equipment rounding guardrails must be applied client-side in Swift *after* receiving the AI response and *before* rendering to the user. | P0 |

---

## 5. AI & Data Architecture

### 5.1 Set-by-Set Inference: The WorkoutContext Payload

This is the JSON object sent to the LLM for every between-set inference call. It is assembled in Swift, serialized, and sent to the chosen inference endpoint.

```json
{
  "request_type": "set_prescription",
  "session_metadata": {
    "session_id": "sess_abc123",
    "workout_date": "2026-03-10",
    "week_number": 3,
    "day_type": "Upper_A",
    "readiness_score": 74,
    "readiness_label": "Reduced"
  },
  "biometrics": {
    "hrv_sdnn_last_night": 42.3,
    "hrv_sdnn_30d_baseline": 51.7,
    "hrv_delta_pct": -18.2,
    "sleep_duration_hours": 6.4,
    "sleep_quality_score": 58,
    "resting_hr_bpm": 58
  },
  "current_exercise": {
    "exercise_id": "ex_incline_db_press",
    "name": "Incline Dumbbell Press",
    "primary_muscle": "pectoralis_major_upper",
    "synergists": ["anterior_deltoid", "triceps_brachii"],
    "set_number": 3,
    "total_sets_planned": 4,
    "plan_target": {
      "weight_kg": 30,
      "reps": 10,
      "tempo": "3-1-2-0",
      "rir_target": 3
    }
  },
  "session_history_today": [
    {
      "exercise": "Overhead Press",
      "sets_completed": 4,
      "avg_rpe": 8.2,
      "notes": "Felt anterior delt fatigue on set 3 and 4"
    },
    {
      "exercise": "Pull-Up",
      "sets_completed": 4,
      "avg_rpe": 7.0,
      "notes": null
    }
  ],
  "current_exercise_sets_today": [
    {
      "set_number": 1,
      "weight_kg": 28,
      "reps_completed": 12,
      "rpe_felt": 6,
      "rir_estimated": 4
    },
    {
      "set_number": 2,
      "weight_kg": 30,
      "reps_completed": 10,
      "rpe_felt": 7,
      "rir_estimated": 3
    }
  ],
  "historical_performance": {
    "last_session_date": "2026-03-07",
    "last_session_top_set": { "weight_kg": 30, "reps": 9, "rpe": 8 },
    "3_session_avg_volume_kg": 840
  },
  "qualitative_notes_today": [
    {
      "timestamp": "2026-03-10T10:14:22Z",
      "exercise_context": "Overhead Press",
      "transcript": "Left front delt feels tight and a little tweaky on the lockout"
    }
  ],
  "rag_retrieved_memory": [
    {
      "similarity_score": 0.91,
      "date": "2026-02-15",
      "note": "Left shoulder clicking during incline press, reduced weight by 10%, felt better",
      "tags": ["shoulder", "injury_concern", "incline_press"]
    },
    {
      "similarity_score": 0.84,
      "date": "2026-01-28",
      "note": "Anterior delt fatigue carrying over from OHP to incline on same day",
      "tags": ["crossover_fatigue", "anterior_deltoid", "incline_press"]
    }
  ],
  "gym_profile_constraints": {
    "available_dumbbell_weights_kg": [2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20, 22.5, 25, 27.5, 30, 32.5, 35, 37.5, 40, 42.5, 45]
  }
}
```

#### 5.1.1 The LLM System Prompt (Inference)

```
You are Project Apex, an elite AI strength and hypertrophy coach. You have access to the user's
real-time physiological data, their performance history, and relevant memory of past sessions.

Your task: prescribe the optimal parameters for the user's NEXT SET only.

RULES:
1. You MUST return ONLY a valid JSON object conforming to the SetPrescription schema. No prose, no explanation.
2. Consider HRV delta and sleep data as leading indicators of CNS readiness. A negative HRV delta > 15% warrants conservative loading.
3. Consider crossover fatigue: if synergist muscles were heavily loaded earlier this session, reduce the prescribed weight accordingly.
4. Consider RAG memory: if relevant past injuries or concerns are retrieved, apply appropriate caution.
5. Consider qualitative notes: voice notes override algorithmic suggestions when they indicate pain or joint concerns.
6. Your weight prescription is in KG but will be rounded to available equipment by the client. Prescribe exact optimal weight; rounding is handled downstream.
7. RIR target must be within ±1 of the mesocycle week's programmed RIR target unless a safety concern justifies deviation.
8. Provide a brief coaching_cue (max 15 words) tailored to this specific set and context.
9. Provide a brief reasoning string (max 30 words) explaining the key adjustment driver.
```

#### 5.1.2 The SetPrescription JSON Schema (LLM Output)

```json
{
  "set_prescription": {
    "weight_kg": 28.0,
    "reps": 10,
    "tempo": "3-1-2-0",
    "rir_target": 3,
    "rest_seconds": 120,
    "coaching_cue": "Control the descent, pause at chest, protect the shoulder.",
    "reasoning": "HRV down 18%, anterior delt fatigue from OHP, historical left shoulder concern — reduced 6.7%.",
    "safety_flags": ["shoulder_caution"],
    "confidence": 0.87
  }
}
```

**Schema Validation Rules (enforced client-side in Swift):**
- `weight_kg`: Float, required, > 0, ≤ gym_profile max.
- `reps`: Int, required, 1–30.
- `tempo`: String, required, matches regex `^\d-\d-\d-\d$`.
- `rest_seconds`: Int, required, 30–600.
- `coaching_cue`: String, required, ≤ 100 characters.
- `reasoning`: String, required, ≤ 200 characters.
- `safety_flags`: Array of String, optional, values from enum: `["shoulder_caution", "joint_concern", "fatigue_high", "pain_reported", "deload_recommended"]`.
- `confidence`: Float, optional, 0.0–1.0.

---

### 5.2 RAG Memory Architecture

#### 5.2.1 Overview

Project Apex uses a Retrieval-Augmented Generation (RAG) system to give the LLM persistent, semantically searchable memory of the user's training history. This solves the stateless nature of LLM inference by ensuring that relevant past context (injuries, fatigue patterns, exceptional performances, recurring concerns) is always surfaced.

#### 5.2.2 Vector Store: Supabase + pgvector

The Supabase PostgreSQL instance has the `pgvector` extension enabled. A `memory_embeddings` table stores all embedded user notes:

```sql
CREATE TABLE memory_embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  session_id TEXT,
  exercise_id TEXT,
  muscle_groups TEXT[],
  tags TEXT[],
  raw_transcript TEXT NOT NULL,
  embedding VECTOR(1536), -- OpenAI text-embedding-3-small dimensions
  metadata JSONB
);

CREATE INDEX ON memory_embeddings
  USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);
```

#### 5.2.3 Embedding Pipeline

All text that enters the memory system is processed as follows:

1. **Source text**: Can be a voice note transcript, a manually typed note, an AI-generated session summary, or a structured observation (e.g., "User failed set 3 of Squat due to lower back rounding — session terminated early").
2. **Embedding model**: `text-embedding-3-small` (OpenAI) or equivalent. 1536-dimension vectors.
3. **Metadata tagging**: Before embedding, the text is sent through a lightweight classification call (separate from the main inference path) that extracts structured tags: `muscle_groups`, `injury_type` (if any), `sentiment` (positive/negative/neutral), `exercise_ids`.
4. **Upsert**: The embedding vector, raw text, and metadata are upserted into `memory_embeddings` via Supabase's PostgREST API.

#### 5.2.4 Retrieval Strategy

At inference time, the query vector is constructed from a compound string:

```
"[exercise_name] [primary_muscle] [synergists] [current_session_context_summary]"
```

This compound query is embedded and used for cosine similarity search:

```sql
SELECT raw_transcript, tags, metadata, created_at,
  1 - (embedding <=> $query_vector) AS similarity
FROM memory_embeddings
WHERE user_id = $user_id
ORDER BY embedding <=> $query_vector
LIMIT 5;
```

Results with similarity < 0.75 are filtered out. The top 3 remaining results are included in the `rag_retrieved_memory` array of the WorkoutContext payload.

#### 5.2.5 Memory Categories

The system proactively generates structured memory events (beyond raw voice notes) after key triggers:

| Trigger | Memory Generated |
|---|---|
| User reports pain (voice) | `{type: "injury_concern", severity: "flagged", requires_monitoring: true}` |
| Set completed with >2 reps below target | `{type: "performance_drop", possible_cause: "fatigue"}` |
| Personal record achieved | `{type: "pr_achieved", confidence: "high"}` |
| Workout terminated early | `{type: "session_incomplete", reason: transcript}` |
| Consecutive sessions with elevated RPE | `{type: "accumulated_fatigue_signal"}` |

---

## 6. Technical Requirements & Stack

### 6.1 iOS / Frontend

| Component | Technology | Notes |
|---|---|---|
| UI Framework | SwiftUI (iOS 17+) | Full adoption; no UIKit bridging unless absolutely required. |
| Navigation | NavigationStack + TabView | Standard iOS paradigms. |
| State Management | Combine + `@Observable` (iOS 17) | Reactive updates for real-time workout state. |
| Camera | AVFoundation (`AVCaptureSession`) | Frame capture for gym scanning. |
| Speech-to-Text | `SFSpeechRecognizer` (on-device) | Primary STT. Fallback to OpenAI Whisper API if on-device confidence < 0.8. |
| HealthKit | HealthKit framework | Async queries via `HKHealthStore`. |
| Local Storage | UserDefaults + SwiftData | GymProfile cache; offline session drafts. |
| Networking | `URLSession` async/await | All API calls. |
| JSON | `Codable` + `JSONDecoder` | Strict schema validation on all AI responses. |
| Haptics | `CoreHaptics` | Feedback on set completion, timer events. |

#### 6.1.1 Key Swift Architectural Patterns

- **WorkoutSessionManager**: A singleton `ObservableObject` that owns the active session state, manages the set-completion → inference → UI update loop, and handles fallback logic.
- **AIInferenceService**: An actor that manages the API call queue, handles retries, enforces timeouts, and applies post-processing (equipment rounding, schema validation).
- **HealthKitService**: A service class that abstracts all HealthKit queries, computes the ReadinessScore, and caches results.
- **MemoryService**: Handles embedding generation calls and vector store upsert/retrieval via Supabase PostgREST.

### 6.2 Backend

| Component | Technology | Notes |
|---|---|---|
| Database | Supabase (PostgreSQL) | Managed Postgres; pgvector extension enabled. |
| Vector Search | pgvector | Cosine similarity; IVFFlat index. |
| Auth | Supabase Auth | JWT-based; single user for MVP. |
| API Layer | Supabase PostgREST | Auto-generated REST endpoints for all tables. |
| Real-time | Supabase Realtime | Optional: for future multi-device sync. |
| File Storage | Supabase Storage | Gym scan images (raw frames) archived for debugging. |

#### 6.2.1 Core Database Schema (Simplified)

```sql
-- Users
CREATE TABLE users (id UUID PRIMARY KEY, display_name TEXT, created_at TIMESTAMPTZ);

-- Gym profiles
CREATE TABLE gym_profiles (
  id UUID PRIMARY KEY, user_id UUID REFERENCES users(id),
  scan_session_id TEXT, equipment JSONB, created_at TIMESTAMPTZ, is_active BOOLEAN
);

-- Generated programs
CREATE TABLE programs (
  id UUID PRIMARY KEY, user_id UUID REFERENCES users(id),
  mesocycle_json JSONB, weeks INTEGER DEFAULT 12, created_at TIMESTAMPTZ, is_active BOOLEAN
);

-- Workout sessions
CREATE TABLE workout_sessions (
  id UUID PRIMARY KEY, user_id UUID REFERENCES users(id),
  program_id UUID REFERENCES programs(id), session_date DATE,
  week_number INTEGER, day_type TEXT, completed BOOLEAN, summary JSONB
);

-- Set logs
CREATE TABLE set_logs (
  id UUID PRIMARY KEY, session_id UUID REFERENCES workout_sessions(id),
  exercise_id TEXT, set_number INTEGER, weight_kg FLOAT, reps_completed INTEGER,
  rpe_felt INTEGER, rir_estimated INTEGER, ai_prescribed JSONB, logged_at TIMESTAMPTZ
);

-- Voice/qualitative notes
CREATE TABLE session_notes (
  id UUID PRIMARY KEY, session_id UUID REFERENCES workout_sessions(id),
  exercise_id TEXT, raw_transcript TEXT, tags TEXT[], logged_at TIMESTAMPTZ
);

-- Vector memory (see Section 5.2)
-- memory_embeddings table as defined above
```

### 6.3 AI / External APIs

| Service | Provider | Use Case |
|---|---|---|
| Vision | OpenAI GPT-4o Vision or Anthropic Claude 3.5 Sonnet | Gym equipment scanning during onboarding |
| Macro-Programming | Anthropic Claude Opus 4 or OpenAI GPT-4o | One-shot 12-week mesocycle generation |
| Set-by-Set Inference | Anthropic Claude Sonnet 4 or OpenAI GPT-4o | Real-time between-set prescription (latency-sensitive) |
| Embeddings | OpenAI text-embedding-3-small | RAG memory indexing and retrieval |
| Speech-to-Text (fallback) | OpenAI Whisper API | Low-confidence on-device STT fallback |

#### 6.3.1 API Key Management

All API keys are stored in the iOS Keychain (`SecItemAdd`/`SecItemCopyMatching`). Keys are never embedded in source code or `Info.plist`. For MVP (single user/developer), keys are provisioned manually at first launch via a developer settings screen. A future backend proxy layer will be required before any multi-user deployment.

#### 6.3.2 Model Selection Rationale

- **Macro-generation uses Opus/GPT-4o**: This is a one-time, latency-insensitive call. Maximum reasoning capability is prioritized to produce a coherent, periodized 12-week structure.
- **Set-by-Set uses Sonnet/GPT-4o**: This call happens between sets (60–180 second rest windows). Sonnet provides near-Opus quality reasoning at significantly lower latency. Target: < 6 seconds end-to-end.

---

## 7. Edge Cases & Math Guardrails

### 7.1 Equipment Rounding Guardrail

The LLM is instructed to reason in ideal, continuous weight space and prescribe the theoretically optimal weight. The client-side `EquipmentRounder` Swift struct intercepts the AI's raw `weight_kg` output and snaps it to the nearest physically available increment.

#### 7.1.1 Rounding Algorithm

```swift
struct EquipmentRounder {
    let gymProfile: GymProfile

    func round(aiPrescribed weight: Double, for exerciseType: ExerciseType) -> Double {
        let availableWeights = gymProfile.availableWeights(for: exerciseType)
        guard !availableWeights.isEmpty else { return weight }

        // Find nearest available weight; prefer rounding DOWN for safety
        let sorted = availableWeights.sorted()
        if let exact = sorted.first(where: { $0 == weight }) { return exact }

        let lower = sorted.last(where: { $0 < weight }) ?? sorted.first!
        let upper = sorted.first(where: { $0 > weight }) ?? sorted.last!

        let midpoint = lower + (upper - lower) * 0.6 // Bias toward lower for safety
        return weight >= midpoint ? upper : lower
    }
}
```

**Example**: AI prescribes `47.5 kg` for a dumbbell exercise. Available dumbbells: `[45, 50]`. Midpoint = `45 + (5 * 0.6) = 48`. Since `47.5 < 48`, round DOWN to `45 kg`. The UI displays `45 kg` to the user, not `47.5 kg`. The `reasoning` field from the AI still reflects the AI's logic; a client-side annotation "(adjusted to nearest available: 45 kg)" is appended.

#### 7.1.2 Barbell Plate Math

For barbell exercises, the rounding algorithm accounts for:
- Bar weight (default 20 kg; configurable per gym profile).
- Available plate denominations (e.g., 1.25, 2.5, 5, 10, 15, 20 kg).
- Plate pairs only (you cannot add a single 10 kg plate to one side).

```swift
func roundBarbell(aiPrescribed totalWeight: Double, barWeight: Double, availablePlates: [Double]) -> Double {
    let loadNeeded = (totalWeight - barWeight) / 2  // Per side
    let sorted = availablePlates.sorted(by: >)
    var remaining = loadNeeded
    var selectedPlates: [Double] = []

    for plate in sorted {
        while remaining >= plate {
            selectedPlates.append(plate)
            remaining -= plate
        }
    }

    let perSideLoad = selectedPlates.reduce(0, +)
    return (perSideLoad * 2) + barWeight
}
```

### 7.2 AI Hallucination Prevention

| Failure Mode | Mitigation |
|---|---|
| LLM prescribes exercise not in gym profile | `WorkoutContext` includes `gym_profile_constraints`; system prompt explicitly states all equipment constraints. Client-side validates exercise is achievable with available equipment. |
| LLM returns malformed JSON | `JSONDecoder` wrapped in `do/catch`; schema validation against `SetPrescription` Codable struct; 2 retries before fallback to plan defaults. |
| LLM prescribes weight beyond gym max | `EquipmentRounder` clamps to gym profile max. If AI exceeds max by >20%, a `warning_flag` is logged for debugging. |
| LLM prescribes 0 reps or negative weight | Hard guard: any `reps < 1` or `weight_kg <= 0` triggers immediate fallback to plan defaults. |
| LLM reasoning contradicts safety flags | Safety flags in the response enum are treated as authoritative. If `safety_flags` contains `pain_reported`, rest interval is automatically extended to minimum 180 seconds regardless of LLM `rest_seconds` value. |
| API timeout / network failure | `WorkoutSessionManager` maintains a `fallbackPrescription` (the plan's static target parameters) that is displayed if the inference call has not resolved within 8 seconds. |
| LLM prescribes tempo with invalid notation | Regex validation (`^\d-\d-\d-\d$`) on `tempo` string. Failure triggers fallback to exercise's default tempo from the program template. |
| Contradictory voice notes in same session | All voice notes are included chronologically. System prompt instructs LLM to weight more recent notes more heavily and to flag contradictions in `reasoning`. |

### 7.3 ReadinessScore Edge Cases

| Scenario | Behavior |
|---|---|
| HealthKit permission denied | `ReadinessScore` = `nil`; AI payload includes `"biometrics": null`; system prompt instructs LLM to apply moderate conservative loading in absence of biometric data. |
| User hasn't worn Apple Watch | HRV and HR data unavailable; only sleep data from iPhone (if enabled). Partial score computed. |
| HRV data from previous day only | Staleness flag added to payload; LLM instructed to weight it with lower confidence. |
| First 30 days (no baseline for HRV delta) | HRV delta calculation disabled; absolute HRV value included with a `no_baseline` flag. |

---

## 8. Out of Scope for MVP

The following features are explicitly excluded from the MVP to maintain focus and development velocity. They are documented here to prevent scope creep and to serve as a backlog for future iterations.

### 8.1 Explicitly Not Building

**Multi-user Support**: The app is architected for a single user. No account management, no subscription layer, no onboarding for arbitrary users. The API key management model reflects this (Keychain, no backend proxy).

**Social / Community Features**: No sharing of workouts, no leaderboards, no coach-to-client marketplace, no workout feed.

**Video Exercise Demonstrations**: No exercise video library. Coaching cues are text-only for MVP. A future integration with a video CDN (or on-device ML exercise recognition via CreateML) is deferred.

**Nutrition Tracking**: No food logging, macro tracking, or dietary recommendations. HealthKit dietary data will not be queried.

**Body Composition Tracking**: No weight logging, no progress photo analysis, no DEXA/InBody integration.

**Wearable Integrations Beyond HealthKit**: No direct Garmin, Wahoo, Oura, or WHOOP SDK integrations. All wearable data is consumed passively through HealthKit as the aggregation layer.

**Multi-Gym / Location Switching**: The user has one active GymProfile. The ability to maintain and switch between multiple gym equipment profiles is deferred.

**AI-Generated Exercise Substitutions**: In MVP, if a planned exercise cannot be performed (equipment in use, injury), the user manually selects an alternative from a pre-filtered list. Automatic AI-driven substitution recommendations are a V2 feature.

**Apple Watch Native App**: The workout is run from the iPhone. A companion watchOS app for set logging and rest timer display is explicitly deferred.

**Offline AI Inference**: The AI inference calls require network connectivity. An on-device model for set-by-set prescription (using Core ML / a quantized local model) is a future consideration if latency or API dependency becomes critical.

**Program Export / Import**: No ability to export the generated program to CSV, share it, or import third-party programs. The program lives exclusively within the app's Supabase backend.

**iPad as Primary Platform**: The app will run on iPad (thanks to adaptive SwiftUI layouts) but is not optimized for it. No split-view, no drag-and-drop, no iPadOS-specific features.

**Push Notifications / Reminders**: No scheduled notifications, no rest-day reminders, no streak mechanics.

**Payment / Monetization**: No StoreKit integration, no paywall, no free/paid tier differentiation. The app is a personal tool for its developer.

---

*End of Document — Project Apex PRD v1.0*

---

> **Next Steps for Engineering**:
> 1. Validate Supabase instance setup with pgvector extension.
> 2. Prototype AVCaptureSession frame capture + Vision API pipeline (FR-001).
> 3. Define and lock the `GymProfile` Codable schema in Swift.
> 4. Build `AIInferenceService` actor with retry logic and schema validation.
> 5. Implement `EquipmentRounder` unit tests with edge case coverage.
