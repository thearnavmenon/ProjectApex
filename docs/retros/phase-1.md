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

- **Q6 (new domain terms in implementation that aren't yet in CONTEXT.md)** — not answered directly by the user. The CONTEXT.md scan in this session surfaced 8 candidates ranked high-to-low: trainee model digest, top set snapshot, two-dimensional recovery, phase advance (top 4); migration dates, equipment catalog, transfer regression, fallback log record (lower 4). User has not yet decided which to add to CONTEXT.md before Phase 2 grilling.
- **Q7 (single most-unexpected thing about implementation)** — not answered directly by the user. The Co-developer Reflections section below contains my answer (Issue #28 turning out not to be about destinations, plus the on-device smoke surfacing three bugs at once).

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

---

# Co-developer reflections (Claude Opus 4.7)

The retrospective above captured the user's perspective. This section is mine — what I observed, what surprised me, where I struggled, and what I learned about this codebase. Added 2026-05-07 after the user pointed out (correctly) that the original retrospective dropped the implementation-side perspective entirely.

## Scope of my window

My direct working window on Phase 1 is narrower than the user's. I did not implement slices 1–10 — those landed before this conversation started, and I read them as as-built state during the post-shipment audit. My direct work in this conversation was:

- Slice 11's rebase + merge (PR #56 onto post-#28 main; clean rebase, no conflicts)
- Issue #28 CI fix (PRs #57, #58)
- This retrospective (PR #59)
- Three bugs surfaced by the on-device smoke (#60, #62, #63) plus their fixes (PRs #64, #68, #69)
- Five follow-up issues filed (#61, #65, #66, #67, plus #62 comment updates)

So these reflections are about **the Phase 1 closing checkpoint and the bug-discovery work**, not the body of slice implementation. Where I make claims about earlier slices, they're inferred from git history and as-built audit, not lived.

## Real surprises from my window

- **Issue #28 was scoped as "fix the destination spec." It wasn't.** The destination pin alone failed CI. The actual fix needed two ingredients: (a) version pin + (b) a `xcrun simctl list` step that initialises CoreSimulator under the non-default Xcode. I discovered this *by accident*: the verbose diagnostic step I added to figure out the runner inventory turned out to be the load-bearing fix. Without the diagnostic, CI failed at destination resolution; with it, CI passed. Three commits to converge: bare pin → verbose diagnostic (passed) → slim warmup (passed). I would not have predicted the CoreSimulator-warmup behaviour from the issue body alone. The user's task framing literally pre-anticipated this in the flag-and-stop tripwires; I almost ignored them.

- **The on-device smoke surfaced three real bugs at once.** I had been about to close issue #1 declaring Phase 1 done. The smoke caught: data loss on every set logged (#60), silent local-date corruption (#63), and a fundamental view-rendering bug hiding 43 real sets (#62). Treating "run the smoke" as a checkbox was wrong. The smoke is the integration test for the entire phase; it should be expected to find bugs, not validate the absence of them.

- **There are three separate `set_logs` payload encoders** (`SetLogPayload`, `ManualSetLogPayload`, inline `NewSetLogPayload`). Slice 6's intent migration required updating all three; only one was the visibly-failing bug, the other two had identical broken-but-silent behaviour because their write paths weren't being exercised by the smoke. I would not have predicted three encoders before the cross-cutting grep. The CLAUDE.md "grep before declaring done" rule isn't an aspiration; it caught the two hidden sites.

- **The `local_date DEFAULT '1970-01-01'` is a deliberate trap that became a real bug.** The schema comment explicitly says *"backfill-only sentinel — new writes populate explicitly."* New writes did not populate explicitly for almost a day after the migration. The default is well-intentioned (allows the column to be added without a complete migration) but it actively masked the missing-encoder bug for as long as no one looked at the actual values. ADR-0007's foreground-tier "no silent fallback" principle has a schema analogue: no silent column defaults that hide writer bugs. The pattern is more general than this one column; #67 is one instance of a class.

- **The "Phase-1+ Swift release will promote" comment at `Models/WorkoutSession.swift:118` was true at the time it was written and false at the time it shipped.** Slice 6 added the schema half. The Swift half was written as a TODO inline comment, never executed, and shipped to production with the comment still in place. **The codebase is an incomplete-migration accumulator** — TODOs about future work don't have a forcing function. Future migrations need a checklist on the issue itself: schema half landed → Swift half landed → on-device verified → comment removed.

- **`TraineeModelDigest` already exists as a Phase 1 deliverable, not a Phase 2 one.** I had been mentally framing it as Phase 2's domain. The as-built audit showed Slice 10 (#11) already shipped the digest skeleton — projection types, filtering rules at confidence ≥ 0.7 + ≥15 observations, factory method. Phase 2 wires it into prompts and adds the *rule logic*. If I had started Phase 2 assuming a clean slate I'd have re-implemented existing code. Reading the as-built before designing is non-negotiable.

## Mistakes I made

1. **PR #68 introduced a regression in 30 seconds that took 30 minutes to surface.** I added `sessionDate: Date?` to `WorkoutSessionRow` as a "diagnostic field." Postgres `date` columns ("yyyy-MM-dd") don't decode as Swift `Date` with the default JSONDecoder. Every fetch failed silently; every detail page returned empty. The user re-smoked, saw the regression, and we shipped PR #69 as a hotfix. **This is the rookie error of this session.** I either should have tested locally, or — better — not added a field I didn't actually need. Both are catchable. The deeper lesson: the same flattened DecodingError shape ("the data couldn't be read because it isn't in the correct format") that's masking #61's stagnation bug masked this one too. **Decode failures need structured error reporting**, not `error.localizedDescription`.

2. **I committed `.claude/settings.json` accidentally** via `git add -A` instead of explicit file names. CLAUDE.md explicitly forbids `-A`. I had to amend and force-push to remove the unrelated file. Caught it because the diff stat showed 5 files when I expected 4 — the only reason I noticed at all. The CLAUDE.md rule isn't paranoia; it's the catch-rate proof. I knew the rule and broke it anyway because `-A` is a habit. The fix: never type `-A` again, even when "it's just a small change."

3. **In `ManualSessionLogView` I made a janky edit that referenced a non-existent helper function** (`setEntry(for: setLog, in: entries)?.intent ?? setLog.intent ?? .top`), then reverted and restructured. This was rushed thinking — I tried to retrofit the call site to "look like" a fix without actually restructuring the data shape that was missing. The right move was changing the tuple to carry intent through; my first attempt was an attempt to avoid that restructure. Cost: one extra edit cycle.

4. **Initial framing of #62 was too narrow.** I hypothesised three scenarios for "session shows fake data," then needed live SQL to disambiguate. The actual bug — every Pull_A page across every week showing the same arbitrary session — had a much bigger blast radius than my framing implied. I should have asked for the SQL output **before** designing the fix shape, not as a tiebreaker between hypotheses. The disambiguator queries themselves took 4 iterations (Q1 errored on `user_id` not existing on `set_logs`; Q2 errored on `completed_at` not existing on `workout_sessions`; Q3 introspected; Q4 got the answer). One schema-introspection query upfront would have saved three iterations.

5. **PR #58's flake cost a CI cycle, and I didn't file a flake-tracking issue.** The `testCompleteSet_fallbackPath_setsFallbackReason` test failed once on identical product code that had passed an hour earlier. I correctly identified it as a flake but only after grepping the previous run's logs for the test name. The async-state assertion has a real timing race. I flagged this in the moment but did not file an issue, because the user prioritised forward motion. **That was wrong of me.** The next time it flakes, the trail is already cold. Filing a 60-second issue would have been free.

## Pace observations on Claude Code in this codebase

- **Mechanical work was fast.** Parallel Bash calls, parallel reads, gh CLI, structured reports. Most of the session's wall clock was CI runs (multiple ~11-minute waits for the iOS test suite). The per-decision-point time was low.

- **Decision points were the actual slowdown.** "Should the diagnostic be load-bearing?" "Should `NewSetLogPayload`'s intent default to `.backoff` or require UI?" "Is this test failure a flake or a regression?" These required surfacing options to the user (correct per CLAUDE.md non-autonomy) but each round-trip added minutes. For Phase 2 I expect this ratio to stay similar; the right move is a parallel-work workflow so I can use the wait time on a sibling slice rather than blocking on round-trips.

- **Cross-checking against existing artefacts paid off.** Re-fetching the `actions/runner-images` manifest when the user pushed back on Xcode 26.4 (it isn't on the runner) saved a wrong direction. Reading PR #32's closure comment before starting #28 saved re-deriving the runner inventory and revealed that #33 was the upstream blocker the prior attempt had hit. **Phase 2 should start every slice by reading the relevant ADR + the prior slice's PR body.** Two reads, ten minutes, saves restructuring later.

- **Background CI watching has rough edges.** I had to load `Monitor` and `TaskStop` tools mid-session, dealt with one SHA-mismatch in my own polling script, killed and restarted a watcher. None of this was load-bearing but it's friction that scales with parallel work. Worth a small ergonomic improvement before Phase 2 leans on watching multiple branches at once.

## Process discipline check (from my side)

The CLAUDE.md rules — branch+commit+PR per logical unit, grep before declaring done, surface ambiguity, worktree-aware git when applicable — held up for me but not perfectly:

- **Cross-cutting grep**: caught the three payload encoders ✓. I *almost* didn't run it for the `workout_sessions` queries during the #62 fix until I pushed myself to. The grep is easy to skip when the local fix feels complete. The audit caught nothing in that case but the discipline was the load-bearing part.
- **Surface ambiguity**: held up well — I asked before each path-A/B/C decision and twice when the user pushed back on my recommendations (Xcode 26.4 / iOS 26.3.1).
- **Branch+commit+PR**: held except the `git add -A` slip.
- **Don't auto-merge**: held — every merge happened on explicit user instruction.

## Inputs to Phase 2 from my perspective

1. **Add a Decodable verification checklist for any new struct that hits Supabase.** PR #68's regression was a 30-second oversight that took the whole detail-view flow down. Phase 2's rule logic will produce many new types crossing the JSON boundary. A trivial encoding/decoding round-trip test on each prevents the class. This overlaps with #66 but is broader: not just the three set_logs payloads, but every Decodable on a Supabase read path.

2. **Replace `error.localizedDescription` with structured error reporting on decode failures.** The same flattened message ("the data couldn't be read because it isn't in the correct format") masked both #61's stagnation bug and PR #68's regression. Knowing *which key* failed and *what type was expected vs. found* would have caught both in seconds. `String(reflecting: error)` for `DecodingError` is one line. Phase 2 should adopt this everywhere.

3. **Audit schema columns whose defaults could mask writer bugs.** `set_logs.local_date '1970-01-01'` is one instance; #67 tracks removing it. Possibly more: any NOT-NULL-with-default added during Phase 1 that a writer might forget to populate. Phase 2 should make this a deliberate review step before any new NOT-NULL-DEFAULT column ships.

4. **The Slice 6 set-intent design-phase error has a Phase 2 analog.** ADR-0005's rule logic *might* assume one-way data flows: "rules read trainee_model and update it in-place." Reality may need bidirectional flows: "rules update trainee_model AND emit signals the prompt or UI must surface." Phase 2 grilling should specifically scrutinise: for each rule, does the rule have a side effect that needs to be visible to a non-rule consumer? If yes, where does that surface live, and is it currently designed?

5. **On-device smoke must run before declaring a slice done, not after the phase.** Phase 1 nearly shipped with three real bugs because the smoke was treated as the closing checkpoint, not a gating one. Phase 2 should make on-device smoke an acceptance criterion on each rule-logic slice's issue, especially because rules execute on the Edge Function (server-side) where simulator-only verification can't catch real-data interactions.

6. **Parallel work probably needs an explicit scaffold before it's tried again.** The user's one Phase 1 attempt had errors. I haven't done parallel-agent work in this codebase. Before Phase 2 leans on it for rule-logic slices, a low-stakes practice run that surfaces and fixes the workflow issues is worth one slice's overhead. Otherwise the first parallel attempt on a real Phase 2 slice will eat the slice's budget on infra, not work.

7. **Track the "incomplete migration" pattern explicitly.** Slice 6's "Phase-1+ Swift release will promote" TODO comment shipped to production unexecuted. The pattern: schema half lands, Swift half is written as a comment-TODO, never gets done, the gap surfaces months later as data loss. Phase 2's prompt rewrites + Edge Function rules will produce many of these multi-component changes. Each one needs a checklist on the issue, not a TODO comment in code.

## Things I will not assume again

- That a "diagnostic-only" field is free.
- That a CI failure described as "destination spec" is only about destinations.
- That the on-device smoke is a checkbox.
- That `git add -A` is fine "this one time."
- That a brief answer to a retrospective question is the complete answer (including from myself).
- That the same flattened decode-error message means the same thing in two different places — **both #61 and PR #68's regression looked identical in the log**.
