# Single-shot corrective re-prompt is permitted for content-validation failures

**Status**: accepted, 2026-06-07

**Relates to**: [ADR-0007](0007-llm-retry-and-surface-policy.md) (LLM error semantics: transient/permanent classification and retry-or-surface policy). This ADR does not supersede ADR-0007; it draws the boundary of what ADR-0007 §1's "permanent → no retry" rule actually governs, and carves out a distinct, narrowly-bounded pattern it does not.

## Context

Issue #241 surfaced during the #42 audit of ADR-0007 adherence. `ProgramGenerationService.generateProgram` (the macro-skeleton expansion path) fires **one corrective re-prompt** in two places (`ProgramGenerationService.swift` ~:287–335):

1. **Empty-training-day correction.** The LLM occasionally returns a `training_day` stub with `exercises: []`. `expandTemplate` faithfully propagates that emptiness across the phase, leaving the user with no plan on those days. The service builds a dedicated correction payload (`buildEmptyDayCorrectionPayload`) naming the empty days, re-prompts **once**, and if the days are *still* empty, `throw`s `ProgramGenerationError.emptyTrainingDay`.
2. **Equipment-constraint correction.** If the expanded mesocycle prescribes equipment the user's gym lacks, the service builds a correction payload (`buildCorrectionPayload`) naming the violations, re-prompts **once**, and if violations *persist*, `throw`s `ProgramGenerationError.equipmentConstraintViolation`.

This raised a real question: ADR-0007 §1 classifies `LLMProviderError.malformedResponse` as **permanent** and its "Considered Options" rejects "retry until product timeout." Does that rule forbid the corrective re-prompt above? If so, the code is in violation and should be stripped. If not, the pattern should be ratified so a future auditor doesn't "fix" it back out.

The answer turns on **which error class** each rule governs.

## Decision

A **single-shot corrective re-prompt is permitted for content-validation failures**, and is a distinct pattern from the provider-error retry that ADR-0007 governs. It is allowed **only** under all three of the following conditions:

1. **Single attempt.** Exactly one corrective re-prompt per failure class. No loop, no "retry until it passes," no second corrective attempt.
2. **Different payload.** The corrective prompt must *differ* from the original — it carries the specific, enumerated violation(s) back to the LLM (e.g. "these training days are empty," "these exercises require unavailable equipment"). It is a new, more-constrained request, not a re-run of the identical prompt.
3. **Throw on persistence.** If the validation still fails after the single correction, the service **throws a typed error**. It must **never** synthesize a best-effort / deterministic program to paper over the failure. The no-silent-fallback contract of ADR-0007 is preserved in full.

`ProgramGenerationService`'s empty-training-day and equipment-constraint correction passes already satisfy all three conditions and are ratified as-is.

### Why this does not contradict ADR-0007

ADR-0007 §1 governs **provider transport / parse errors** — HTTP status codes, `URLError`, and `malformedResponse`/`emptyResponse` (the LLM returned *unparseable* content). Its ban on retry for permanent errors targets the **futile same-prompt re-run**: re-sending an identical request that produced a 401, or unparseable JSON, "will not fix the LLM's output" and only burns the user's time budget.

A **content-validation failure is a different class entirely**: the LLM returned *valid, parseable* JSON that conforms to the schema but violates a *domain* rule (an empty day, a disallowed machine). Re-prompting with a *different* payload that names the exact violation is not a futile same-prompt retry — it is a meaningfully different request with a genuinely higher success probability, because the model now has information it lacked. The thing ADR-0007 protects — *never silently substitute a fabricated answer for a failed AI call* — is honored here, because persistence `throw`s rather than degrading.

In short: ADR-0007 §1 = "don't re-run an identical request that can't recover." This ADR = "you may re-run *once* with a *corrected* request for a *semantic* violation, and you must still fail loud if it doesn't take."

## Considered Options

- **Conform — strip the corrective re-prompt, throw on first violation.** Rejected. The correction is cheap (one extra call, bounded) and high-yield: naming a specific empty day or equipment conflict frequently gets a clean result on the second, *different* prompt. Throwing on the first violation would surface a regenerate-from-scratch prompt to the user for a problem the model can usually self-correct in one shot — strictly worse UX for no integrity gain (the integrity gain is already provided by the throw-on-persistence rule).
- **Allow a general corrective retry loop (re-prompt until valid or timeout).** Rejected. That *is* the pattern ADR-0007 forbids — it risks burning the budget on a model that keeps failing, and an unbounded loop invites a future "just synthesize something" silent-degradation shortcut. The single-attempt bound is load-bearing.
- **Ratify the single-shot pattern, narrowly scoped (chosen).** Captures the real value (one cheap self-correction) while keeping every guardrail ADR-0007 cares about (bounded, different payload, fail-loud on persistence).

## Scope guard

This carve-out is **narrow by construction** and must not be stretched. It authorizes *only* a single-shot, different-payload, throw-on-persistence correction of a **content/domain-validation** failure. It must **not** be cited to justify:
- multi-attempt or looped re-prompting,
- same-payload retries of a provider/parse error (still governed by ADR-0007 §1),
- any synthesized or deterministic fallback that hides a failed AI call.

A second corrective attempt, or any softening of the throw-on-persistence rule, requires a new ADR.

## Consequences

- `ProgramGenerationService`'s two correction passes are ratified; no code change to their behavior. A comment at the call site points here so the pattern is traceable to this decision.
- Future content-validation call sites may adopt the same single-shot corrective pattern by construction, provided they meet all three conditions.
- ADR-0007 remains the authority for provider transport/parse error retry. The two ADRs partition the space: ADR-0007 = provider-error retry-or-surface; ADR-0019 = content-validation single correction.
- #242 (PostWorkoutSummaryView silent `deterministicInsights` fallback) is a *separate* matter and is **not** covered here — that site silently substitutes a fabricated answer, which this ADR explicitly does not permit.
