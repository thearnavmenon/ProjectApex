# Project Apex — Design Principles

Cross-cutting design heuristics that inform tuning decisions across the trainee-model rule logic. These aren't ADRs — they don't pin a single decision — but they are the load-bearing reasoning under multiple ADRs and PRD-internal tuning choices. Future maintainers tuning constants, thresholds, or classifier boundaries should land here for context.

## Asymmetric-error preference

**When tuning a constant, threshold, or classification boundary, prefer the failure mode the prescription-accuracy meta-coaching loop will catch loudly over the failure mode that is silent.**

The trainee-model rule logic is full of tuning calls — a classifier rep-band threshold, a recovery time constant, a regression R² floor, an evidence count, a window length. Most of these calls are between two defensible alternatives, and the difference between "right" and "wrong" at the v2-alpha scale is bounded. What matters more than the exact number is which failure mode the chosen number produces if it's slightly off.

Two failure modes are not equal:

- **Loud failures** show up as systematic RPE drift in the session log, miss-rate clustering on a particular pattern, prescription-accuracy bias accumulation that crosses the digest exposure threshold, or user behaviour change (the user starts overriding prescriptions, manually correcting weight, etc.). The system has detection mechanisms — chiefly the prescription-accuracy meta-coaching field per ADR-0005 — that surface these loudly enough to trigger correction within a few sessions.

- **Silent failures** don't surface in any of those channels. They're cases where the rule produces "no signal" or "the AI didn't react" or "the user's prescription is slightly conservative" — outcomes that look indistinguishable from the system working correctly.

The design principle is to tune toward loud failures. When in doubt, err in the direction the system can detect.

### Phase 2 commitments leaning on this principle

Each of these decisions had two defensible options; the asymmetric-error analysis was the load-bearing reason for the chosen direction.

- **ADR-0008 (late-arrival refuse + soft notification)**: refuse-and-notify is loud (user sees a notification, can report); silent-drop is invisible.
- **Stimulus classifier RPE bump on top sets at 9–10 reps** (Phase 2 PRD-internal, Q3): under-counting NM stimulus → over-prescription → loud RPE drift; over-counting NM stimulus → under-prescription → quieter, easier to correct.
- **ADR-0010 (NM tau = 30h)**: pulled from initial 24h to the conservative end of the literature range. Under-recovery → over-prescription → loud RPE drift; over-recovery → under-prescription → quieter.
- **ADR-0009 (hybrid plateau verdict, OR-aggregation for `progressing`)** and **ADR-0011 (decline also blocks advance)**: silent regression is the bad failure mode; verdict catches both e1RM and volume-load flatness, and force-deload is the explicit intervention rather than letting a stuck pattern coast.
- **ADR-0015 (cadence-aware nil-fallback at 21d)**: long-absence returners get more transition-mode coverage, not less. Under-counting the transition window on low-frequency users is silent.
- **Q9 limitation classifier — joint-scope as ambiguous default** (Phase 2 PRD-internal): under-flagging injuries is silent and dangerous; wider exercise avoidance is the conservative direction.
- **Q10 transfer R² floor at 0.4** (Phase 2 PRD-internal): leans toward publishing because over-publishing surfaces loudly via prescription-accuracy bias; under-publishing is silent under-utilization.
- **ADR-0014 (deload exclusion from prescription-accuracy bias)**: including deload sets would create false bias that the digest interpretation rule would mistranslate into "increase load" — silent harm during the deload phase. Excluding makes the bias signal phase-independent and the rule trivial.

### How to apply this when tuning

1. Identify the two (or more) defensible options.
2. For each option, ask: "What does the failure mode look like if this number is wrong?"
3. Sort the failure modes by detectability: which one shows up in prescription-accuracy bias, RPE drift, miss-rate clustering, user override behaviour? Which one is invisible?
4. Choose the option whose failure mode is *loud* — even if it's marginally more common. The loud failures get caught and corrected. The silent ones accumulate.

### When this principle does not apply

The asymmetric-error preference is a tie-breaker, not a substitute for evidence. If one option is strictly better on the data — closer to the literature, supported by alpha-cohort observations, demonstrably catches a real failure mode the other misses — choose that one regardless of detectability asymmetry. The principle resolves the case where two options are roughly equivalent on direct evidence and the choice would otherwise be arbitrary.

## Authority hierarchy for spec divergences

When implementation cycles surface a divergence between two artifacts that both purport to specify the same rule — e.g., a worked example in an issue body contradicts a formula stated higher up in the same issue, or an ADR's prose can't be reconciled with the table directly above it — the implementation pins behavior at the **lowest-numbered (highest-authority) artifact** the divergence reaches, and the higher-numbered artifact is amended post-merge.

### The hierarchy (lowest-numbered wins)

1. **Mathematical spec.** The formula or composition rule that is the rule's actual definition. If the formula says `(max − min) / mean ≤ 0.05`, that's what the verdict computes; any prose example computed under a different reading is wrong.
2. **Grilling memory / PRD-internal lock-ins.** Decisions captured during pre-implementation grilling (Q3, Q5, Q9, Q10, Q12, etc.). These are the source of truth for design choices that didn't reach an ADR — typically because they're tactical rather than architectural.
3. **ADR body.** The decision section's prose and tables. The durable governance contract; future maintainers reading the ADR get the rule.
4. **ADR derived presentations.** Tables, code blocks, examples within the ADR. Should agree with the ADR body, but in practice can carry pre-decision drafts that didn't get pruned.
5. **Issue prose.** The slice issue's worked examples and edge-case lists. Authored before the implementation cycle exposes which states are reachable; can carry mathematically unreachable cases or composition states the rule doesn't permit.
6. **Brief / docstring.** Module headers, code comments, slice plan summaries. Lowest authority — rewritten freely as understanding improves.

### Resolution rule

When two artifacts at different levels conflict:
1. The implementation pins behavior at the **lowest-numbered** artifact the divergence reaches. If issue prose (level 5) and a formula (level 1) disagree, the formula wins; the implementation pins to the formula.
2. The test name explicitly cites both rules and the precedence — `[lower-authority]: [behavior]; [higher-authority] would have produced [other-behavior]; [reason precedence picks the lower]` — so a future maintainer reading the failing test sees that the precedence is intentional.
3. The higher-numbered artifact gets a post-merge amendment proposal in the PR description, tracked through to either an ADR amendment, an issue body edit, or a follow-up issue if the amendment is non-trivial.

### Recurring instances across the A-slice arc (Phase 2)

The pattern hit seven distinct instances in seven slices. Listed in order of occurrence as evidence the hierarchy is real:

- **A7 cycles 10/13 — math vs issue prose** ([PR #100/#101](https://github.com/thearnavmenon/ProjectApex/pull/101)). Issue #78's "drop 9.9% → flat" + "volume 114.9% → flat" cases are mathematically unreachable under Q1's `(max − min) / mean` spread formula at the 5% / 10% thresholds. Implementation pinned to the formula (level 1); issue prose flagged for amendment.
- **A7 cycles 17/18 — ADR table conflict resolved by design principle** ([PR #100/#101](https://github.com/thearnavmenon/ProjectApex/pull/101)). ADR-0009's verdict table (level 4) had two cells (`{improving e1RM, declining volume}`, `{declining e1RM, improving volume}`) where multiple rows fire and the prose (level 3) didn't pin precedence. Implementation locked declining-wins per `docs/design-principles.md` (asymmetric-error preference); ADR-0009 amended 2026-05-09.
- **A8 C8 — composition rule vs issue prose** ([PR #102](https://github.com/thearnavmenon/ProjectApex/pull/102)). Issue #79's C8 edge-case described `currentPhase=.deload ∧ sessionsInPhase=2×threshold ∧ trend=plateaued → no-op` as a state the rule had to handle. Under ADR-0011's §(b)+(c) composition (level 3 ADR body), the cyclic-deload-end rule fires first and the force-deload trigger never reaches the in-deload pattern — the state is unreachable. Implementation pinned to the composition rule; issue prose flagged for amendment.
- **A9 C16 — ADR text vs issue prose** ([PR #103](https://github.com/thearnavmenon/ProjectApex/pull/103)). ADR-0014's bucket-boundary text pinned strict-`>` partition (level 3); issue #80's C16 ("72h00m → over72h") parenthesized "verify whether ADR-0014 means strict > or >=" without resolving. Implementation pinned to the strict-`>` partition; issue prose flagged for amendment.
- **A11 cycle 9 — math reality vs issue prose** ([PR #105](https://github.com/thearnavmenon/ProjectApex/pull/105)). Issue #82's cycle 9 claimed `[0.0001, -0.0001]` produces "consistencyFactor near zero." Mean-guard fires (preventing NaN), but the small stddev keeps consistencyFactor at ~0.9 — guard-fires and clamp-to-zero are distinct properties. Implementation split cycle 9 into 9a (guard-fires fixture, consistency=0.9) + 9b (clamp-to-zero fixture, stddev > absMean); issue prose flagged for amendment.
- **A12 cycle 13 — Swift Codable wire-format vs JSONB shape contract** ([PR #106](https://github.com/thearnavmenon/ProjectApex/pull/106)). ADR-0006 (level 3) pinned the JSONB column shape as the contract between Edge Function writer and Swift reader. Swift's synthesized `Dictionary<EnumKey, V>` Codable encodes as a flat alternating array (`["squat", {...}, ...]`), incompatible with the TS-side JSON-object emit. Implementation pinned to ADR-0006's shape contract via custom `init(from:)`/`encode(to:)` on `TraineeModel` + a `JSONBCodable` helper; the Swift default behavior was overridden, not the ADR.
- **A13 Q6 — asymmetric-error analysis vs Q9 lock-in language** ([PR #107](https://github.com/thearnavmenon/ProjectApex/pull/107)). Q9 grilling memory (level 2) pinned the joint→pattern map for shoulder/elbow as "push + pull patterns (incl. isolation)". Asymmetric-error analysis (per the principle above) showed isolation inclusion produces silent premature limitation clearing on incidental accessory work. Implementation excluded isolation per the principle; Q9 lock-in flagged for amendment.

### Issue-authoring discipline

The recurrence of issue-prose-vs-implementation-reality divergences (5 of 7 instances above) suggests the cheapest place to catch them is at issue-creation time, not implementation time. When drafting a slice issue:

- Worked examples should be hand-computed against the formula, not paraphrased from the ADR's intent.
- Edge-case bullets that name a state should be checked against the composition rule that produces it — if no path exists from `currentPhase=accumulation` (initial) to the state described, the bullet is describing an unreachable case.
- ADR table cells where the rule's prose and the table both purport to specify behavior should be cross-checked for internal precedence; mark explicit `(precedence: X wins)` rather than assume top-down reading.

The audit follow-up issue tracking the closed-issue-body amendments from this pattern is [#108](https://github.com/thearnavmenon/ProjectApex/issues/108).
