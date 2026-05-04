# LLM error semantics: transient/permanent classification and retry-or-surface policy

**Status**: accepted, 2026-05-04

## Context

Phase 3's mid-session resilience work (P3-MR-F01 — `TransientRetryPolicy`, P3-T07 — `InferenceRetrySheet`, P3-MR-F05 — `FallbackLogRecord`) introduced retry behaviour for LLM provider calls in response to FB-012, the Anthropic 529 outage on 22 Apr 2026. The work shipped as a hot-patch and was documented in `ARCHITECTURE.md §7.5` but never formalised as an ADR. As a result the rules were scattered: which HTTP codes count as transient lived in `TransientRetryPolicy.transientCodes`, retry orchestration lived in `AIInferenceService.prescribe`, the foreground UI surface lived in `InferenceRetrySheet`, and what happens to the work-ahead queue on permanent failure was implicit.

Issue #24.2 (a stale `AIInferenceSpikeTests.test_retryPath_providerAlwaysThrows_returnsFallback` assertion) surfaced the gap. The test was written against an earlier "service does NOT retry on provider throws" model; the service in fact retries any transient `LLMProviderError` until the 8 s product timeout fires, then falls back. Neither the test's stated invariant nor the current behaviour is right. The test stays wrong because the rule it was checking against was never crisply defined; the impl is partially right but absorbs transient and permanent errors into one retry loop and produces a `.fallback(.timeout)` even when the underlying error class makes retry meaningless (e.g. a 401 auth failure).

This ADR formalises the retry-and-surface policy so the rule is visible at the type level, the same shape applies to every LLM call site, and the no-silent-fallback principle (already stated obliquely as Principle 1 in `ARCHITECTURE.md §2.2` and explicit in P3-T07's `InferenceRetrySheet`) is the load-bearing contract rather than an aspirational comment.

Scope baseline: solo developer, alpha cohort of 3–5 (P-B). The policy is sized for that scale; the goal is correctness and observability, not enterprise SLOs.

## Decision

### 1. Errors classify as transient or permanent at the type level

`LLMProviderError` carries a `Classification` accessor that returns `.transient` or `.permanent`. Callers branch on `error.classification` rather than re-deriving from raw status codes. The classification is the single source of truth — `TransientRetryPolicy.transientCodes` becomes a private detail backing the property.

| Classification | Causes |
|---|---|
| `.transient` | HTTP 429 (rate limit), 502, 503, 504, 529 (Anthropic overload); `URLError` of `.notConnectedToInternet`, `.networkConnectionLost`, `.timedOut`, `.cannotConnectToHost`, `.dnsLookupFailed` |
| `.permanent` | HTTP 4xx other than 429 (auth failures, bad request, invalid model); `LLMProviderError.malformedResponse` (the LLM returned unparseable content); `LLMProviderError.emptyResponse`; any non-`URLError` non-`LLMProviderError` exception |

The compiler enforces exhaustivity: `switch error.classification` is a 2-arm switch, so callers can't forget to handle both classes.

### 2. Retry shape (transient errors only)

Bounded exponential backoff. Existing `TransientRetryPolicy` parameters retained: 3 retries (4 total attempts), base delay 1 s doubling each attempt (1 s → 2 s → 4 s), random jitter up to 0.5 s. Cooperative `Task.checkCancellation()` between sleeps. Total worst-case retry budget ~7 s + jitter.

Permanent errors throw immediately without consuming retries. The retry policy's responsibility ends at "transient → retry, permanent → throw"; it does not surface to UI and does not log.

### 3. Two flavours of "what happens after retries are exhausted (or a permanent error fires)"

#### Foreground call sites

Call sites running on the workout / interaction loop where the user is waiting for an answer: `AIInferenceService.prescribe`, `AIInferenceService.prescribeAdaptation`, `SessionPlanService.callAndDecodeSession`, `ExerciseSwapService.sendMessage`.

- Wrap the retry block in a product timeout (8 s for set inference; longer for session-plan generation, see `LLMProvider.requestTimeout` per call site).
- On retry-exhausted, permanent error, or product timeout: emit a `FallbackLogRecord`, return `.fallback(reason:)` to the call site, and surface `InferenceRetrySheet` (or call-site-equivalent error UI) with **Retry** and **Pause Session** affordances.
- Never silently degrade the prescription. The user must see that the AI didn't run.

#### Background call sites

Call sites running outside the foreground loop where there is no UI to surface to: `MemoryService.embed` (RAG ingestion via `Task.detached`), future `TraineeModelUpdateJob` (Edge Function post via `WriteAheadQueue`), batch maintenance jobs.

- Same retry shape (transient → retry, permanent → fail fast).
- On retry-exhausted or permanent error: emit a `FallbackLogRecord` (already wired) and **leave the work-ahead-queue entry in place** for the next attempt. Do not write a synthesized result.
- For fire-and-forget calls without a queue (e.g. `MemoryService.embed`), log structured failure and discard. The cost of a missed embed is one absent RAG entry; the cost of a synthesized embed would be a lie in the vector store.

The principle is identical to the foreground case — never produce a fake answer — but the surface differs because there is no real-time user.

## Considered Options

- **Status-code-only classification (current state).** `TransientRetryPolicy.transientCodes` as the single source of truth, callers re-derive. Rejected: invites silent fallback bugs because every consumer must remember to consult the policy, and the type system doesn't catch omissions. The #24.2 test was a direct symptom — the assertion was written against an undefined rule.
- **Restructured `enum LLMProviderError { case transient(...); case permanent(...) }` with nested cause enums.** Rejected for now: every existing pattern-match site (`TransientRetryPolicy.execute`, `ExerciseSwapService` line 171) would need updating, and the current flat structure carries the same information when paired with a `Classification` accessor. Compiler still checks exhaustivity on the 2-case `Classification` enum. Revisit if the flat structure produces ambiguous classification at any future call site.
- **Retry until product timeout (current `AIInferenceService.prescribe` behaviour).** Rejected: absorbs permanent errors into the retry loop and produces a misleading `.timeout` fallback even when the underlying error was instantly diagnosable as permanent. Wastes the user's 8 s budget on errors that won't recover.
- **Immediate fallback on any provider throw (the #24.2 test's stated expectation).** Rejected: violates the existing P3-MR-F01 hot-patch decision — transient errors (Anthropic 529 on 22 Apr 2026) need bounded retry to recover the common-case outage. Removing retries would re-create the FB-012 incident shape.
- **Synthesised "best-effort" prescription on retry-exhaustion (deterministic local fallback).** Rejected at the foreground tier: violates no-silent-fallback. Principle 1 in `ARCHITECTURE.md §2.2` ("AI-First, Not AI-Only — every AI call has a deterministic local fallback") is real but is about *availability* (the app doesn't crash offline), not about *silently substituting* for the AI when it failed. The retry sheet IS the local fallback for the foreground tier — it gives the user agency.

## Consequences

- `LLMProvider.swift` gains a `Classification` enum + `var classification: Classification` on `LLMProviderError`. `TransientRetryPolicy.transientCodes` remains as the backing data but stops being a public dependency for non-retry call sites.
- `TransientRetryPolicy.execute` switches its catch from `case .httpError(let status, _) where transientCodes.contains(status)` to `switch error.classification`. The retry policy also begins catching `URLError` (currently propagates without retry per file comment lines 62–64) and routing it through the same classifier.
- `AIInferenceService.prescribe` keeps its 8 s product timeout but should bail immediately on `.permanent` errors without consuming the timeout budget. Test #24.2's "always throws" mock returns 429 (transient), so the correct expected outcome is `.fallback(.timeout)`. A separate test using a permanent error mock (401 or `.malformedResponse`) verifies the fail-fast path.
- `MemoryService.embed`, `TraineeModelUpdateJob` (Slice 9b territory), and other background call sites adopt the "leave queued + log" rule. The `WriteAheadQueue` already supports leaving entries in place on flush failure (P3-MR-F03); the explicit rule is "do not synthesize a fake result and dequeue."
- `InferenceRetrySheet` remains the foreground UI surface; this ADR canonicalises its role rather than introducing it.
- Future LLM call sites inherit the policy by construction — they pattern-match on `error.classification` and pick the foreground or background tail. The only thing a new call site has to choose is which tail it lives in.

This ADR is tightly coupled to `ARCHITECTURE.md §7.5` (Mid-Session Resilience) and ties together the previously scattered P3-MR-F01, P3-T07, and P3-MR-F05 mechanisms. It does not change the chosen retry parameters; it makes the surface contract explicit and compiler-checked.
