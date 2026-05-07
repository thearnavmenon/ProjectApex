# Recovery readiness curves and time constants

**Status**: accepted, 2026-05-07

## Context

ADR-0005 specifies `RecoveryProfile` with two paired axes (neuromuscular and metabolic), each carrying a `last*StimulusAt: Date?` and a `*Readiness: Double` defaulting to 1.0. The two-dimensional shape is justified by the hybrid hypertrophy/strength positioning — heavy 1–3RM and high-rep moderate work tax different systems with different decay curves.

The ADR does not pin the *curve shape*, *time constants*, or *stacking behaviour*. The choice cascades into prescription: when the digest reports `neuromuscularReadiness: 0.4`, the AI reads that and decides whether to back off intensity. Wrong curves systematically mis-prescribe.

This ADR pins the curve, the constants, and the stacking deferral rationale. Tightly coupled to ADR-0005 (the architectural decision), ADR-0009 (the hybrid plateau verdict that consumes the same trainee-model state), and the Phase 2 stimulus-dimension classifier rule (which updates the timestamps this ADR's curves consume).

## Decision

### Curve shape — exponential approach to 1.0 with a residual floor

For each axis (NM, metabolic), readiness is a pure function of hours since the last stimulus event:

```
readiness(t_hours) = clamp(0, 1, 0.3 + 0.7 × (1 - exp(-t_hours / tau)))
```

The residual floor of 0.3 captures that the lifter is not at zero readiness immediately post-stimulus — they can still train at reduced effort right after a session, just not at peak output. Dropping the floor to 0 would tell the AI "this person cannot train for the next 30 minutes," which contradicts lived experience and forces awkward prescription edge cases for users training same-day after a stimulus event.

### Time constants

| Axis          | tau   | Readiness 24h | Readiness 48h | Readiness 72h |
|---------------|-------|----------------|----------------|----------------|
| Neuromuscular | 30h   | 0.69           | 0.84           | 0.94           |
| Metabolic     | 12h   | 0.90           | 0.99           | 1.00           |

The **NM constant (30h)** sits on the slightly-conservative side of the literature for trained-but-non-elite lifters. CNS recovery markers (force production, twitch potentiation, peak power) typically remain depressed 5–15% at 48 hours after heavy compound work; full restoration is usually 72 hours or longer when volume was high or intent was max-effort. The classic Monday-legs / Thursday-legs split exists because Tuesday and Wednesday legs both feel meaningfully under-baseline.

The **metabolic constant (12h)** matches lactate clearance (30–90 min post-session, fully gone within hours), glycogen partial repletion under normal eating (4–8h for substantial recovery, 24h for full), and the lived experience that high-rep accessory work the day after heavy compound work feels meaningfully easier than the reverse.

The asymmetry (metabolic clears ~2.5× faster than NM under these constants) is consistent with the design rationale for two-dimensional recovery in ADR-0005.

### Stacking — deferred to v2.5 with explicit monitoring

The formula reads only the *most recent* `last*StimulusAt`. Two NM-classified sessions 18h apart both ratchet `lastNeuromuscularStimulusAt` forward; the residual debt from the first session does not compound with the second. Error mode: the model overstates readiness in back-to-back high-NM scenarios.

Real stacking requires a `*ReadinessDebt: Double` field (not on the type), per-axis decay tracking on the debt, and a Codable migration. For alpha scale (3–5 users, P-B), the lossy case is rare enough — most users have enough sense not to self-impose 18h-spaced heavy NM sessions — that deferral is acceptable.

**Monitoring trigger.** The prescription-accuracy meta-coaching field (per ADR-0005) MUST be stratified by inter-session gap on the same pattern. If systematic over-prescription residuals appear on patterns trained at <48h gaps relative to >72h gaps, that's stacking error and v2.5 priority. If residuals look the same across <48h, 48–72h, and >72h buckets, the deferral held and stacking can remain deferred indefinitely.

### Volume-blindness — acknowledged limitation

The model treats all NM-classified sessions as equivalent regardless of session volume. A user doing 3 sets of bench at RPE 8 and a user doing 12 sets of bench at RPE 8 both ratchet `lastNeuromuscularStimulusAt` identically and follow the same readiness curve. In reality the 12-set session generates substantially more residual fatigue.

For alpha scale this is acceptable. Downstream signals — prescription accuracy, RPE drift in the session_log, volume-validation deficits — catch the high-volume case eventually. The likely v2.x fix is `tau` as a function of session intensity-volume product (e.g. `tau_NM = base_tau × (1 + 0.05 × heavy_set_count_above_threshold)`) rather than adding more state.

A future reader landing here from a "why does the model under-recover users on high-volume programmes?" question should know: this was deliberate at v2 scale, not overlooked.

### Edge cases

- **Brand-new user, no stimulus yet** (`last*StimulusAt == nil`): readiness = 1.0 (fully recovered).
- **Watermark refused a session** (per ADR-0008): `last*StimulusAt` does not advance; the late session contributes nothing to recovery decay. Consistent with "model state misses, history persists."
- **Future-dated `last*StimulusAt`** (clock skew): clamp `t = max(0, ...)` so readiness cannot exceed 1.0 from negative t. **Additionally, log a structured `recovery.clock_skew` event** with `user_id`, `last_stimulus_at`, `now`, `delta_seconds`. Clock skew at non-trivial rates is a data-integrity signal, not just a numerical edge case to silently fix.

### Recompute cadence

The `*Readiness` fields are *cached*, recomputed by the Edge Function on every session apply. Between Edge Function calls — i.e., during a session — readiness is stale by however long it has been since the last update. This is acceptable because:

1. Recovery decays slowly relative to session duration. From minute 0 to minute 60 of a workout, readiness changes by less than the digest's reporting precision.
2. Within-session signals (`session_log`, RPE feedback, completion flags) supersede stale readiness for the LLM's prescription decisions.
3. Recomputing on every set-by-set inference call would either duplicate the curve in the client (split-brain risk per ADR-0006) or invoke the Edge Function per set (latency cost). Neither earns its keep at v2 scale.

## Considered Options

- **Linear ramp** (`readiness(t) = 0.3 + 0.7 × t / window`). Rejected: recovery is asymptotic, not linear. A linear formula reaches "fully recovered" at a hard threshold and stays there, losing the gradual-tail signal real CNS recovery shows.

- **Sigmoid** (`1 / (1 + exp(-(t - tau) / k))`). Rejected: implies a recovery threshold the data doesn't support. The LLM consumes a Double in [0,1] and won't behaviorally distinguish between exponential and sigmoid at the digest level. Adds parameters without changing behaviour.

- **NM tau = 24h** (initially proposed): pulled to 30h after sport-science review. The 24h constant placed readiness at 0.74 at the 24h mark — coinciding with the typical "should I repeat this pattern tomorrow" decision window and likely to systematically over-prescribe on tight-spaced same-pattern sessions. Asymmetric error cost: under-counting recovery time → over-prescription → loud RPE drift in the session_log; over-counting recovery time → under-prescription → quieter, easier to correct via user feedback. The tighter 24h constant errs in the direction the system finds harder to detect.

- **NM tau = 36h** (alternative conservative pick): considered. Defensible but slightly over-conservative; the 30h compromise lands between 24h and 36h with a cleaner readiness curve at the 24h mark (0.69 vs 0.64).

- **Drop the residual floor to 0**. Rejected: tells the AI "this person cannot train for the next 30 minutes" which is wrong and forces awkward prescription edge cases.

- **Track per-stimulus debt with stacking** (full implementation): rejected for v2 — schema migration cost outweighs alpha-scale benefit. Deferred to v2.5 with the monitoring trigger above.

## Consequences

- The Edge Function gains the recovery-curve recompute as part of every session apply. Two scalars updated per `RecoveryProfile`; trivial cost on top of the existing rule engine.

- The TraineeModelDigest exposes `neuromuscularReadiness` and `metabolicReadiness` as Doubles in [0,1]. The system prompts gain interpretation guidance: readiness < 0.5 → meaningful fatigue, expect reduced output; readiness ≥ 0.8 → fresh, prescribe at programme intensity; in-between → bias conservative on first working set.

- Prescription-accuracy meta-coaching (ADR-0005) gains an **inter-session-gap dimension**: residuals stratified by gap (<48h, 48–72h, >72h) per pattern. The v2.5 stacking decision is data-driven from this surface.

- Clock-skew logging at `recovery.clock_skew` adds a new observability channel alongside `trainee_model.late_arrival` (ADR-0008).

- Re-tuning the time constants is forward-only per ADR-0006 — no auto-recompute. If 30h proves too conservative or too permissive based on alpha cohort prescription-accuracy data, subsequent updates apply the new tau without rewriting historical readiness values.

- The volume-blindness limitation is documented as a known v2 trade-off. The likely v2.x fix is intensity-volume-product-modulated tau, not additional state.
