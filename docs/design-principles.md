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
