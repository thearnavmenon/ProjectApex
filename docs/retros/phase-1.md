# Phase 1 retrospective

**Date**: 2026-05-07
**Phase**: 1 — Foundation (schema, migrations, infra)
**Slices shipped**: 11 (issues #2–#12; all merged or in-flight via PR #56)
**Format**: Q&A captured during a single retrospective session; sister artefacts in this turn — `docs/retros/phase-1-as-built.md`-equivalent material lives in the conversation, not yet a file.

## Pace observations

- **Slice 6 (set-intent three-phase migration, #10)** took quite a bit of time. This was expected — three-phase migration shape is inherently more steps than a single-phase change.
- **Supabase migration + ADR recovery (Step D, 2026-05-06 incident)** consumed substantial time outside the planned slice budget. The recovery itself shipped as PRs #48–#52 (drop Pass 1 of 0004, F1 session_notes, F2 profile columns, Step D Supabase CLI baseline, model-cutoff date pinning) and is tracked in `MEMORY.md` as a pending CLAUDE.md amendment.
- All other slices landed within nominal budgets; no hidden surprises in pace.

## Design-phase errors surfaced by implementation

- **Slice 1** — typed-enum migration. The original design specified MovementPattern as strings; implementation revealed it had to be a typed enum. Compounded by a MuscleGroup granularity mismatch (6 cases) vs ExerciseLibrary's PrimaryMuscle (9 cases, leg subgroups). Resolved with the two-level taxonomy amendment to ADR-0005.
- **Slice 6 — set-intent flow**. The design assumed set intent flowed prescription → set → log, with intent always pre-set by the AI prescription before the set was logged. Implementation revealed the user has to be able to select set intent post-completion in cases where the AI didn't pre-prescribe it. The three-phase migration in Slice 6 was driven by this: the rigid "intent required pre-prescription" model from the design was too strict for real flows. The original design's framing of intent as "pre-prescribed input only" is the design-phase error; reality required a more flexible "set during prescribing OR confirmable post-completion" shape. *(Captured verbatim from the retrospective; flagging as a candidate for closer Phase 2 grilling — same shape of error, where the design assumes a one-way data flow that reality requires bidirectional, could recur in Phase 2's rule-logic slices.)*

## ADRs & durable corpus

- **ADR-0005** amended in Slice 1 for the two-level muscle taxonomy. Amendment held up across Phase 1's downstream slices.
- **ADR-0007** created during Slice 7 / #5 work (LLM retry-and-surface policy formalising the no-silent-fallback contract). Accepted 2026-05-04.
- **Set-intent ADRs (within ADR-0005)** held up well as a design — the set-intent flow correction in Slice 6 was a flow/UX issue, not an ADR-content issue. The ADR's specification of intent as a required field on every set, with no silent defaults, remained correct; the change was in *when* intent gets set, not in *whether* it's required.
- No further amendments produced during Phase 1's later slices.
- **Durable-corpus survey result** (separate scan in this retrospective session): no new ADR-0008+ needed from Phase 1's surprises. Slice 9a's secret-management decisions are exhaustively captured in `docs/agents/edge-functions.md`. ADR-0007 already covers the retry-policy decision the original Phase 1 review listed as "the most likely candidate."

## Claude Code's pace on this codebase

About as expected. No tasks where the agent struggled disproportionately. The CLAUDE.md process commitments (branch+commit+PR per logical unit, grep-and-report, surface ambiguity) functioned as designed.

## Parallel work

- **Appetite is there for Phase 2.** Goal: more parallel slices, multiple agents running simultaneously.
- **Tried once during Phase 1**; ran into errors. The single Phase 1 attempt at parallel work surfaced workflow issues that haven't been debugged.
- **Phase 2 action**: trial the parallel-work workflow on a non-load-bearing Phase 2 slice early, before committing to parallel work for the critical rule-logic slices. Debug the workflow on a slice where errors don't block the integration path.

## Process discipline

Held well across Phase 1's later slices. The CLAUDE.md amendments forged in the Slice 5 / #23 / #24 incidents (branch+commit+PR-per-unit, grep-and-report-not-grep-and-rewrite, surface-ambiguity-don't-fill-it) did not have recurrent motivating failures during Phase 1 slices 6–11. The discipline is real, not aspirational.

## Open from this retrospective

- **Q6 (new domain terms in implementation that aren't yet in CONTEXT.md)** — not answered directly. The CONTEXT.md scan in this session surfaced 8 candidates ranked high-to-low: trainee model digest, top set snapshot, two-dimensional recovery, phase advance (top 4); migration dates, equipment catalog, transfer regression, fallback log record (lower 4). User has not yet decided which to add to CONTEXT.md before Phase 2 grilling.
- **Q7 (single most-unexpected thing about implementation)** — not answered directly. Worth surfacing briefly during Phase 2 grilling kickoff.

## Inputs to Phase 2

1. **Trial parallel-work workflow on a low-stakes Phase 2 slice early.** Pre-debug the workflow before applying it to the rule-logic slices. Action item, not aspiration.
2. **Phase 2 grilling should specifically scrutinise data-flow assumptions.** The Slice 6 set-intent error came from a one-way data-flow assumption that reality required to be bidirectional. Phase 2's rule logic (EWMA, recovery, fatigue interactions, transfer regression) has many similar flows where the design might assume a single direction.
3. **CONTEXT.md updates for the 4 high-value gaps** (trainee model digest, top set snapshot, two-dimensional recovery, phase advance) before Phase 2 PRD is written. Phase 2 PRD will reference all four heavily; locking them in CONTEXT.md first avoids term drift in the PRD.
4. **As-built audit and durable-corpus survey** from this same session feed directly into Phase 2 PRD. The audit identified the six places where Phase 1 stopped short ("plumbing without wiring") and Phase 2 must explicitly wire each. The durable-corpus survey confirmed the existing ADR set is sufficient — Phase 2 produces its own ADR-0008+ from rule-logic decisions.

## Sister artefacts from this session

- **As-built audit** — what Phase 1 actually built vs what was designed. (Conversation-only; not yet a file.)
- **Durable-corpus survey** — confirmation that ADR-0001 through ADR-0007 + agent docs cover every Phase 1 architectural decision. (Conversation-only; not yet a file.)
- **CONTEXT.md candidate list** — 8 ranked candidates for new glossary entries. (Conversation-only; not yet a file.)

If any of those three would be useful as standalone files, they're easy to extract from the conversation log on request.
