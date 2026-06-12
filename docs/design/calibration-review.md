# Calibration review — the amendment ledger (#361, Train-hosted)

**DRAFT for product-owner review — NOT locked, do not merge without ratification.** Suggested location when ratified: `/Users/arnav/Desktop/ProjectApex/docs/design/calibration-review.md`.

**The surface in five lines:** the screen where the athlete reviews and signs the model's amendments to their targets — per-pattern floor/stretch/progress (#269), the capability-driven floor ratchet (#305), and the goal renegotiation / goal-review flows (#304/#258). It is drawn as a **provenance ledger of amendments** (band-reduction rows on a fused floor spine; raised floors dimensioned struck-not-erased), not a settings form. Its hardest job is honesty: by ADR-0022 the renegotiation re-derivation is **inert by design** — changing the goal text moves no number in the default case — and the surface must never claim otherwise. The commit is an assembled crossfade, never a celebration (milestone quarantine). All instrument grammar is reused from `progress.md`/`post-workout.md`; **no new tokens**.

**The 3–4 decisions you must ratify (§12 has the full list):**
1. **The inert-renegotiation honesty contract (the headline, convergent P0 across all three lenses).** On a goal save that moved no numbers (the *default* case), the commit renders the **goal** as the amendment and states plainly: *"Your targets are unchanged — they track what you lift, not your goal wording."* No "targets updated" claim, ever. Ratify the voice (teach-the-mechanic vs. quiet-annotation).
2. **IA: one ledger root with the goal editor as a push and two separate commits** (stretch-save vs. goal-save) — chosen over one-scroll-one-Save because the two transactions carry opposite honesty contracts and different ack watermarks. All three lenses flagged this as your structure call.
3. **`LEVELLED UP` — plain tag (draft default) or the inverted notary stamp?** Inversion is currently the PR stamp's exclusive treatment; a floor ratchet is its nearest kin. The exclusivity is yours to spend.
4. **Entry scope:** v1 opens **armed-only** (banner / Today alert rows / Progress provenance pointer — the current contract), with the resting un-armed ledger designed but unreachable. Ratify whether Train gains a persistent "Your targets / Change goal" entry.

---

**Status: DRAFT 2026-06-12 — three-agent panel synthesis (UI-craft, UX/product, visual/art-direction) for #361; awaiting product-owner ratification of §12 (HITL). Not locked; not buildable until ratified.** The sixth per-screen spec of the Phase 3 UI overhaul. Visual tokens are `DESIGN.md`; behavior law is `ui-overhaul-spec.md`; the hosting contract is `train.md` §9 (Train hosts; Progress's provenance sheet and Today's alert rows link in; the commit hard-swaps the plan assembled). The panel's headline: *the existing screens are a different design system entirely (dark chrome, purple capsules — every token is a deletion) and a different epistemics entirely: the most dangerous render on this surface is structurally guaranteed to trigger — the goal-blind re-derivation (ADR-0022) means the common renegotiation moves nothing, and a "targets updated" confirmation would ship audit-F8 reborn at the calibration moment. The draft re-draws the review as a band-ledger of amendments, separates the two commits, and makes the no-op honest.*

---

## 1. Job

The athlete's review-and-sign surface for re-calibration: **what the model now holds you at (floor), what you're reaching for (stretch), and what just changed — with the source named.** Three flows, per `train.md` §9:

1. **Review (#269/ADR-0021)** — read the per-pattern floor/stretch/progress targets; raise a stretch (upward-only, athlete-authored).
2. **Renegotiation (#304/ADR-0022)** — change the goal statement/focus; the server re-derives stretches (goal-text-blind, usually inert).
3. **Goal-review (#258)** — the heavy-reassessment flow: capability leveled up, revise what you're working toward.

Train hosts it because re-calibration changes the program (`train.md` §1/§9); this spec is the missing *internals* that §9 deliberately did not design. In craft terms the surface is **a provenance ledger of amendments to the plan** — a raised floor (#305), a raised stretch (#269 S4), a changed goal — rendered in the amendment vocabulary of `post-workout.md` §8 (struck-not-erased, old in pencil, new in ink, source named) and the dimension vocabulary of `progress.md` §5. If it reads as a band-relative ledger that happens to be editable, it is ours; if it reads as a form with steppers, it is the Yazio "My Goals" list (§10).

**What this surface is not:** a celebration (the milestone quarantine — any party owed already fired in the loop or the post-workout reveal), a history chart (no time series, no slope — it renders *now* plus one dimensioned before/after), or a place where the floor can be touched (the floor is monotonic non-decreasing, server-derived, never client-supplied — ADR-0023).

## 2. Structure & layout — one ledger root, the goal editor a push

**One spine, one back-stack, two separate commits.** *(Ratify — §12 Q2.)* The current IA — two competing `.sheet` modals off `WorkoutView` — collapses into:

1. **The ledger root** — the per-pattern target review, Save = the stretch-edit commit.
2. **The goal editor** — a push from the ledger's foot ("Change goal", `accent-ink` row), Save = the goal commit. Its Save returns to the *same* ledger, now showing the honestly-re-rendered (or honestly-unchanged — §6) targets.

Two commits because the two transactions carry **opposite honesty contracts**: a stretch raise is athlete-authored and locally clamped (safe to render as "you raised this"); a goal change is a model-hygiene event whose number-consequence is server-computed and usually nil. One merged Save would make it impossible to say which edit moved which number — the condition under which the #304 hazard becomes unmanageable.

**Ledger root composition (top to bottom, on paper):**

- **Margin row** (on the top rule): "Your targets" in `title`; when the entry is an armed event, a margin annotation in the drafting register names it — "RE-CALIBRATED · 12 JUN" / "FIRST CALIBRATION" (tracked caps `label`, digits ink tnum, words pencil). No annotation when un-armed.
- **The intro line** (`body`, two-tone): register varies by armed event (§3). It carries the floor's one positive why, stated once: *"The floor only moves up, and only when your lifts earn it."* Warm words are allowed (ADR-0023's celebratory-copy decision stands); motion is not. Every claim cites the real patterns/facts (`ui-overhaul-spec.md` §8.3 — grounded or absent).
- **The pattern ledger** — one row per projection, **fixed canonical pattern order, forever** (position never encodes the event; treatment does — `progress.md` §3 law; re-calibrated patterns do *not* float to the top, the tag and expanded drawing differentiate them).
- **Save targets** — the only accent fill on the screen; relabels "Saving…" in-flight; even with zero edits Save acknowledges (review-and-accept-as-is hides the banner durably — keep, F7).
- **"Change goal"** — the foot row, pushes the goal editor.

**Row anatomy — two densities, both already specced:**

- **Resting row** (un-amended, not being edited): the **sanctioned list-scale band reduction** (`progress.md` §3, verbatim): unlabeled drawing — floor tick 2px full strip height, stretch 1px, dot 5pt (solid measured / hollow estimated), no bracket — rendered **band-relative so the floor ticks fuse into one continuous 2px ink spine** down the ledger (the identity move; without it this is a settings list). Numbers live in the **annotation line only** (numbers-never-twice): "Floor **100** · Stretch **107.5** · on track", digits ink tnum, words pencil — annotation grammar reuses the Progress root rules wholesale (movement / forward hook "2 of 3 sessions above 102" / holding / calibrating count).
- **Amended or editing row** (a #305-ratcheted pattern; a row whose stretch the athlete is raising): expands to the **detail-scale band anatomy** (`post-workout.md` §6): labeled ticks ("FLOOR 105" / "STRETCH 112.5", `label` muted tnum), `band` fill (accent 8%), dot plotted as a fraction of its own band — **never clamped**; a dot above stretch is the pre-ratchet state and must plot outside (that is the whole #305 story made visible). Ghost ticks and dimension brackets per §4. The annotation line then carries provenance words and dates only (numbers moved to the ticks, not duplicated). The expansion is a hard re-render — no geometry tween.
- The stretch stepper (§5) sits at the row's trailing edge, ≥44pt, `accent-ink`.

**The floor is drawn immovable.** 2px full ink, the heaviest line in each row, fused into the spine — and it carries **no affordance whatsoever**: no stepper, no chevron, no `accent-ink`. The squint-test of the screen is the contrast between the heavy fixed datum (the floor you can't touch) and the 1px reach with a control beside it (the stretch you can raise). A grayed-out floor control would read "broken/coming soon"; the read-only-ness is stated positively in the intro instead.

## 3. State machine

| State | Treatment |
|---|---|
| **Armed — first calibration** (#269: `calibrationReviewFiredAt` set, unacked; `recalibratedPatterns` empty) | Intro frames "starting targets" (neutral register). **No riser dimensions anywhere** — the floor was just *born*, not raised; there is no old floor to strike. Dots hollow where capability is still estimated (`point-estimated`). |
| **Armed — re-calibration** (#305: watermark > ack) | Intro names the outgrown patterns and the mechanic, grounded ("You've consistently climbed past your squat target — so the floor moved up"). Ratcheted rows render expanded with the riser dimension (§4) + `LEVELLED UP` tag **instead of** the just-reset progress word — hitting the old target must read as a win, never a demotion to "on track" (the #305 demotion trap; semantic kept from the live screen, styling migrated). |
| **Armed — goal-review** (#258: heavy-reassessment signal) | Entry lands **on the goal editor** (pushed; back = the ledger). Editor intro: "Your training leveled up. Revise what you're working toward." Save acks via `acknowledgeReassessment(triggeringSessionCount:)`. |
| **Resting (un-armed)** | The calm ledger: reduction rows, stretch editable, no margin annotation, no dimensions. **Designed but reachable only if §12 Q4 ratifies a persistent entry** — today every entry is armed (banner / alert rows / armed provenance pointer). |
| **Editing (uncommitted stretch raise)** | The edited row expands: original stretch stays as a **pencil ghost tick** where it was; the live 1px ink tick steps up per increment (hard-swap per step, no tween); a dimension bracket "+2.5" (tnum ink) spans ghost→new. This render is **preview, not stored provenance** — the model keeps no stretch-edit history, so after commit the row renders the new stretch plain (we never draw provenance we don't store). |
| **Commit — stretch save** | Local-first is correct here (the local clamp + ack is the source of truth; server write best-effort mirrors the server's own clamp — preserve `makeCalibrationStretchPayload` + `applyStretchEdits` + `acknowledgeCalibrationReview()`, which already advances both the #269 boolean and the #305 watermark). Render: assembled crossfade ≤150ms, silent, dismiss/return per entry. |
| **Commit — goal save** | **Render-after-verify — never local-first** (§6, P0). In-flight: the honest-checklist register, never a bare spinner. |
| **Goal write failed** | `alert` register inline ("Couldn't save your goal — try again"), the goal **un-amended**, the ledger untouched. No struck-old/ink-new render until the server confirmed (an amendment the server never recorded is audit-F8 at the commit). |
| **Calibrating pattern** (no projection yet for a pattern) | Named count-to-ready ("still calibrating — **2** more sessions", the #166 actual rule). **No band is drawn** — no ticks, no "STRETCH —" placeholder (the Tempo/Gymshark fabricated-instrument tell, banned by name). |
| **Empty (no projections at all)** | The named-absence card: "Log a few sessions and your targets will appear." Never band chrome. |
| **Degraded / offline** | The ledger reads local model state in full. Stretch edits work (local-first). The goal editor's Save requires the network (its consequence is server-computed); offline it states so honestly and does not pretend to commit. |

## 4. The instruments — reused wholesale, nothing minted

`train.md` §9's own closing law governs: **no new tokens; Train reuses existing instruments wholesale.** Everything below is a named reuse:

- **The band** — this surface uses the two *existing* sanctioned renders: the list-scale reduction (`progress.md` §3) for resting rows and the detail-scale anatomy (`post-workout.md` §6) for amended/editing rows. **This is reuse of sanctioned renders, not a fourth context** — stated out loud here the way `train.md` §7 named the leaf micro-mark, so the next agent doesn't flag it as a law violation. *(Cross-doc flag, grep-and-report: `DESIGN.md`'s "one component, three contexts" paragraph should name calibration review among the reduction's users at next amendment.)*
- **The riser dimension** (`progress.md` §5, applied to a single before/after instead of a time series): a ratcheted floor renders the **old floor as a ghost tick** (1px hairline at 30% — the `post-workout.md` §7 fossil), the new floor in 2px ink, extension hairlines + a dimension line with terminal ticks spanning them, "**+5**" tnum ink on the line, the date in pencil beneath. Rendered **only on re-calibration** — never on first calibration (§3).
- **Named build dependency (lead-synthesis catch — the panel assumed data that does not exist):** the model stores `lastRecalibratedPatterns` but **not the prior floor value** — after the EF writes, the old floor is gone. Drawing the ghost-and-dimension from current data would *fabricate* the old value. The slice must add a small additive stamp in `update-trainee-model`'s re-calibration path (prior floor/stretch alongside the watermark, JSONB, tolerant-decoded) — or, if declined, v1 renders **words-only provenance** ("floor moved up · 12 Jun") with no drawn dimension. Absence named, never fabricated. *(Ratify — §12 Q5.)*
- **The amendment vocabulary** (`post-workout.md` §8): the changed goal statement renders old-struck-in-pencil → new-in-ink with an `AMENDED` tag at the goal commit (the client holds both strings in-flow; nothing persistent is fabricated — the model keeps no prior goal).
- **Tags:** `AMENDED`, `LEVELLED UP` — tag family (1px ink rectangle, 2pt radius, tracked caps 11pt). Tags state classification facts only; the progress states (behind / on track / ahead / achieved) are **never tags or capsules** — they read as annotation-line words in the instrument register, with the dot's band-relative position carrying the same fact visually. Whether `LEVELLED UP` earns the inverted notary-stamp treatment is §12 Q3.
- **Numbers:** one rounding rule — 0.5 kg / 1 lb display precision, one string everywhere this floor renders (root, Progress, reveal, provenance sheet — the one-fact law). *Build flag:* the current `formatWeight` drops trailing `.0` but does not enforce 0.5 quantization.
- **Token migration (the current screens are deletions, not a re-skin):** dark `#0A0A0F` ZStack → `paper` (+ `colors-dim` remap); `accentPurple`/`accentBlue` → `accent-ink` for all small-scale interactive (never bright `accent` at text scale — the P0-4 contrast failure); white-opacity cards → `surface` + `hairline` borders; SF Rounded `.monospacedDigit()` → Space Grotesk tnum, work-is-ink / time-is-pencil; `.kerning(0.8)` white-40% headers → tag-caps register in `ink-muted`; purple capsules → the tag family and §5's drawn controls. Success is never green and never a hue.

## 5. The review flow — reading and raising targets

- **The stretch edit is upward-only by construction, drawn — not just disabled.** Input mechanism: the `−2.5 / +2.5` stepper pair (matches `PROJECTION_INCREMENT_KG`, plate-loadable, no free-text field — mirroring the loop's no-pre-filled-weights discipline). The *visual result* of a tap is the drawing changing: the stretch tick steps up against the fixed floor datum, the ghost + dimension bracket grow (§3 editing state). The minus control disables (`ink-muted` 40%) exactly at the original stretch — the floor-to-original-stretch span is a wall the tick cannot cross; the affordance *is* the law, visible. A draggable tick was considered and declined (precision + 44pt targets; the stepper is the input, the drawing is the output).
- **Silent.** Train mints no haptic and steals none (`train.md` §2); the stepper fires no `selection` detent (UI-craft's proposal declined — recorded, §11).
- **The commit is plain.** Save → assembled crossfade ≤150ms; the plan the lifter returns to has hard-swapped assembled (`train.md` §2 regeneration-under-the-eye). **No `celebrate-ratchet`, no `notification(.success)`, no flourish, ever, on this surface** — the milestone quarantine is a P0 obedience, not a choice. The floor going up *feels* like a win and the rebuild will be tempted; the win was already celebrated where it was earned (the loop / the post-workout reveal, witness rule).
- **Logic preserved verbatim** (#361 acceptance): `makeCalibrationStretchPayload` (upward-only filter, `acknowledgeCalibrationReview: true` always), the `canLower` clamp, `applyStretchEdits`' client mirror, and the ack writer that advances both watermarks. Snapshot under #342.

## 6. Renegotiation & goal-review — the honesty contract

**6.1 The entry map and the ack wall (F7).** Three armed entries bind three different watermarks; mis-wiring one silently fails to clear its banner and the dismissed alert nags forever (the F7 audit failure):

| Entry | Destination | Ack on Save |
|---|---|---|
| Calibration-review banner / Today alert row (#269) | Ledger root | `acknowledgeCalibrationReview()` (advances #269 boolean **and** #305 watermark — existing behavior, keep) |
| Re-armed re-calibration banner (#305) | Ledger root (amended rows) | same writer |
| Heavy-reassessment row (#258) | Goal editor (pushed) | `acknowledgeReassessment(triggeringSessionCount:)` |
| Progress provenance sheet's armed pointer row | Ledger root; **back returns to the sheet** (entry-conditional back-stack, `train.md` §7) | per the armed event |

Build rule (the cross-cutting-grep form): every alert-row → entry → ack-writer triple is confirmed by grep, not assumed. Cancel/swipe-dismiss never acks (current semantics, keep).

**6.2 The goal editor.** One editor serves both renegotiation and goal-review (the server distinguishes by content-diff — ADR-0022; no client flag). Statement field: a `well`-recessed multiline input. Focus chips: the **States selected treatment** (surface card, 2px ink border, label 500→600) — never an accent fill; selection is structural, the accent stays free to mean "act here." "Where you are now": read-only capability rows, work-is-ink (kg in `ink` SG tnum, names in body, capped list). `makeGoalPayload` preserved verbatim.

**6.3 The commit — render-after-verify (P0).** The renegotiation's consequence is computed **server-side only** (`update-trainee-goal` is the one place that sees old+new goal under `FOR UPDATE` — ADR-0022). Therefore the current `_ = try? await invokeFunction(...)` swallowed write **cannot survive** for this path: the commit awaits the EF; on failure it renders the honest error with the goal un-amended (§3); only on success does it render anything as done. The local-first crossfade is correct only for edits whose source of truth is local (the stretch path).

**6.4 The inert-renegotiation render (P0 — the wall).** Per ADR-0022 the re-derivation reads only `floor + trend`, never goal text; the default goal change moves **zero numbers**. This is not a corner case — it is the *default* case, structurally guaranteed. So:

- The commit renders **only true deltas**. The **goal** is what moved, so the goal renders as the amendment (old struck pencil → new ink, `AMENDED` tag).
- When no target moved (default): one honest line — *"Goal updated. Your targets are unchanged — they track what you lift, not your goal wording."* No dimension brackets, no "targets updated" copy, no animation implying recomputation. *(Voice ratification — §12 Q1.)*
- In the rare case `trend` shifted a stretch: **only that pattern** renders the amendment (ghost + dimension); never a global "targets recalculated" banner over a ledger where five of six rows are identical.
- The *felt* consequence of a goal change is the **plan re-render**: returning to the Train root shows the program hard-swapped assembled (`train.md` §9) — the true consequence of a refocus, honestly delivered. If the owner wants goal changes to move numbers, that is reopening #305-option-B (goal-aware margin — explicitly deferred, no evidence base, needs its own ADR); this surface must not pretend in the meantime.

The named anti-pattern: Yazio's "Recalculate Calorie Goal — your new goal is 2,224 Cal. Update?" confirm dialog (§10). Honest there — Yazio's formula reads the goal. Dishonest here — ours doesn't. Promising movement we won't deliver is audit-F8 reborn at the goal grain.

## 7. Honesty rules (this surface's `ui-overhaul-spec.md` §8 extensions)

1. **Render only true deltas.** A target movement that didn't happen is never drawn, said, or animated — including the structurally-default inert renegotiation (§6.4).
2. **An amendment renders only after its source of truth confirms.** Server-computed consequences are render-after-verify; local-clamped edits may render local-first.
3. **The floor is drawn immovable** — heaviest ink, zero affordance — and its why is stated positively, once.
4. **Provenance is stored or absent, never invented**: the riser dimension draws only from a stamped prior value (§4 dependency); the editing ghost is preview, not history; no band, tick, or labeled placeholder for a pattern without a projection.
5. **The milestone quarantine holds**: this surface renders fossils and never plays them — no `celebrate-ratchet`, no success/impact haptic, no flourish. Words may be warm (ADR-0023); motion may not.
6. **One number, one rounding rule** — the floor reads byte-identical here, in Progress, in the reveal, and in the provenance sheet.

## 8. Accessibility

- **Hit targets:** every stepper and tappable row ≥44pt (the current ~32pt capsule steppers are under the floor). The stepper exposes the **adjustable trait** ("Stretch, 107.5 kilograms, adjustable — swipe up to raise").
- **VoiceOver grammar**, ledger row: "Squat. Floor 105 kilograms — levelled up from 100, 12 June. Stretch 112.5 kilograms, editable. On track." Order: margin row → intro → rows in canonical order → Save → Change goal. The goal editor: intro → statement field → focus chips (selected trait) → capabilities → Save. No announcement fires on the commit (quarantine includes AX celebration).
- **Dynamic Type:** rows self-size; the drawing sheds first (detail band → reduction → no drawing) before the annotation, and the annotation sheds words before numbers; **numbers never ellipsize**. `FLOOR`/`STRETCH` tick labels follow the `post-workout.md` §6 collision rule (shift outboard below 48pt band width). Buttons size to label.
- **Dim variant:** full remap via `colors-dim`. **Named contrast check:** the 1px pencil ghost tick vs the 1px ink live tick is the at-risk pair on near-black; if the muted weight alone misses, the ghost gets a dash pattern (the existing dashed-confidence vocabulary) instead of relying on opacity.
- **Reduce Motion:** nothing changes — every transition here is already a ≤150ms crossfade; there are no haptics to keep.
- **RTL:** layout mirrors; numeric lockups, annotation numbers, and dimension labels are forced-LTR runs.

## 9. Explicitly cut

- **The recalculate-confirm modal** (Yazio's "your new goal is 2,224 — update?") — a yes/no dialog over an opaque recomputed number; the renegotiation commit is a watched, honest re-render, never an alert.
- **Any "targets updated" claim, badge, bracket, or animation on an inert renegotiation** — audit-F8; the single named failure this product has fought hardest never to repeat.
- **`celebrate-ratchet`, `notification(.success)`, `impact` haptics, flourish of any kind** — the milestone quarantine.
- **The entire current chrome**: dark `#0A0A0F`, `accentPurple`/`accentBlue`, white-opacity cards, capsule chips/steppers, 18pt-radius filled buttons, `.preferredColorScheme(.dark)` — deleted, not re-skinned.
- **Status capsules for progress labels** ("On track" pills) — adherence-grading the calibration surface; the dot position + annotation words carry it.
- **Floor editing affordance in any form** (including a disabled control — read-only is stated, not grayed).
- **Downward stretch edits and free-text weight entry** — upward-only, plate increments.
- **A draggable stretch tick** — stepper input, drawn output (declined: precision + targets).
- **Stepper haptics** — Train is silent (`selection` proposal declined; recorded).
- **Any chart, time series, or slope** — this surface renders now-state plus one dimensioned before/after; history is Progress's job.
- **Fabricated instruments for absent data** — no band for a calibrating pattern, no "STRETCH —" slots (Tempo/Gymshark tell).
- **Floating the re-calibrated patterns to the top** — canonical order held; treatment differentiates.

## 10. References (panel-verified Mobbin pulls)

- **Yazio "Recalculate Calorie Goal"** — edit goal field → confirm dialog showing old `1,474` → new `2,224` → list re-renders. The honest preview-before-commit *for a goal-reading formula* — and therefore the exact trap for ours, which is goal-text-blind: copied here, the dialog promises movement that won't come. Also its "My Goals" `Label … value ›` stack: the anonymous settings form this surface must not become.
- **Bevel "Target Strain Calibration"** — "allow up to 2 weeks to learn," hatched arc: the honest calibrating-not-ready state; maps onto our dashed-confidence vocabulary and the named count-to-ready row.
- **Hevy / Tempo / Gymshark frames** — inherited bans by name from `progress.md` §10 / `train.md` §13 (colored win-badges, fabricated empty instruments, adherence grading).

## 11. Review record (2026-06-12, three agents — DRAFT synthesis)

Panel: UI-craft, UX/product, visual/art-direction. Headlines: *all three independently named the inert-renegotiation render as the surface's P0 (audit-F8 structurally guaranteed on the default path); all three demanded the full token redraw (the purple capsule "Levelled up" is the colored-win-badge the system rejects); the visual lens supplied the identity move (band-reduction rows on the fused floor spine — a ledger, not a form); UX supplied the two-commit separation and the three-watermark ack wall (F7); UI-craft supplied the riser-dimension amendment grammar and the render-after-verify split between local-first and server-truth commits. Lead synthesis added one catch the panel missed: the prior floor value is not stored, so the riser dimension needs a model-API stamp or a words-only fallback.*

| # | Finding (agent) | Disposition |
|---|---|---|
| P0 | **Never render a target movement that didn't happen** — the inert renegotiation (ADR-0022) is the default case; honest no-op render required (all three, convergent) | **Accepted** — §6.4, §7.1. Voice → **HITL Q1**. |
| P0 | **Renegotiation commit is render-after-verify** — the swallowed `try?` write cannot show an amendment the server never recorded; stretch path stays local-first (UI-craft) | **Accepted** — §6.3, §3. |
| P0 | **Milestone quarantine** — no flourish/haptic/celebration anywhere on the surface (all three) | **Accepted** — §5, §7.5. |
| P0 | **Full token redraw, not a re-skin** — dark chrome + purple cannot ship inside the 3-tab shell (visual; UX's third-hue concur) | **Accepted** — §4 migration table. |
| P0 | **The ledger identity: band-reduction rows, band-relative, fused 2px floor spine** (visual) | **Accepted** — §2. |
| P0 | **Three watermarks, three ack writers — route each entry to its correct commit+ack pair; Save-with-zero-edits still acks** (UX — F7) | **Accepted** — §6.1. |
| P0 | **Keep the #305 demotion-trap fix** — `LEVELLED UP` replaces the just-reset progress label (UX) | **Accepted** — §3. Inversion → **HITL Q3**. |
| P1 | **IA: ledger root + pushed goal editor, two commits** (UI-craft's push; UX's two-transactions-never-conflated; visual leaned one-scroll-one-commit — reconciled on the opposite-honesty-contracts argument) | **Accepted** — §2; structure → **HITL Q2**. |
| P1 | **Two-density rows**: reduction at rest, detail-scale anatomy when amended/editing (reconciles UI-craft's full-anatomy rows with visual's reduction + the numbers-never-twice law) | **Accepted** — §2, §4. |
| P1 | **Riser-dimension amendment for the ratcheted floor; no dimension on first calibration** (UI-craft + visual) | **Accepted** — §4, §3 — *gated on the prior-floor stamp (lead catch) → HITL Q5*. |
| P1 | **Stretch edit drawn (ghost + bracket), stepper input, upward wall visible; minus disabled at original** (all three) | **Accepted** — §5. Draggable tick **declined**. |
| P1 | **Entry-conditional back-stack** (provenance-sheet entry returns to the sheet) (UX) | **Accepted** — §6.1. |
| P1 | **Progress states as annotation words + dot position, never capsules; Progress-root annotation grammar reused (incl. the forward hook)** (UX + visual) | **Accepted** — §2, §4. |
| P1 | **States parity** — calibrating/empty/degraded/dim/RM/DT/VO specced; ghost-tick dim check with dash fallback (UI-craft + visual) | **Accepted** — §3, §8. |
| P2 | **One rounding rule; 0.5 kg quantization gap in `formatWeight`** (visual) | **Accepted** — §4 build flag. |
| P2 | **Retone the celebratory intro to pure amendment register** (visual) | **Accepted in part** — grounded rewrite yes; de-celebration **declined** (ADR-0023's celebratory-copy decision stands; quarantine governs motion/haptics, not words) — §2, §7.5. |
| P2 | **`selection` haptic on stepper steps** (UI-craft) | **Declined** — Train mints no haptic (`train.md` §2); recorded. |
| — | **Goal-aware re-derivation so renegotiation moves numbers** (raised as an option by all three) | **Out of scope** — #305-option-B stays deferred; needs its own ADR + cohort data. |

Cross-doc flags filed (grep-and-report, not edited here): **`DESIGN.md`** — name calibration review among the band reduction's users at next amendment; **`progress.md` §4** — the provenance sheet's pointer row destination is now this surface (live, no dead pointer); **`splash-today.md` §4** — alert-row destinations bind to the §6.1 entry map; **`update-trainee-model` EF** — the prior-floor stamp (§4 dependency, pending Q5).

## 12. Open questions for the human (HITL)

1. **The inert-renegotiation voice (headline).** The P0 is fixed (never claim movement); the copy direction is yours: **(a)** quiet honest annotation ("your targets already reflect this"), or **(c)** teach the mechanic — *"Goal updated. Your targets are unchanged — they track what you lift, not your goal wording."* Panel recommendation: **(c)** — most honest, teaches the model's actual behavior; risk: "then why did I bother." If you instead want goal changes to move numbers, that reopens #305-option-B (deferred, needs an ADR) and this surface waits.
2. **Ratify the IA:** one ledger root + the goal editor as a push, **two separate commits** (the draft's commitment) — vs. one scroll, two sections, one Save. The draft argues separate commits are what keep the #304 honesty manageable; all three lenses flagged the structure as your call.
3. **`LEVELLED UP` — plain tag or inverted notary stamp?** Inversion is the PR stamp's exclusive treatment today; a floor ratchet is the nearest kin to a PR this surface shows. Draft default: plain tag (the exclusivity is yours to spend, not the panel's). 
4. **Entry scope.** v1 opens armed-only (banner / Today rows / armed provenance pointer — the current contract). Should Train gain a persistent "Your targets / Change goal" entry (the natural home: a pointer row by the program root or the §4 provenance path)? This decides whether the resting un-armed ledger (§3) ships reachable, and whether an athlete can change their goal with no banner armed — today they cannot, anywhere in the app.
5. **The prior-floor stamp (model-API addition).** Approve the small additive EF stamp (prior floor/stretch alongside the #305 watermark) so the riser dimension can draw honestly — or accept the v1 fallback (words-only provenance, no drawn dimension). The panel designed for the dimension; the data doesn't exist yet.
6. **Floor provenance depth inline.** Just the positive why ("set by your lifts"), or the Progress-style count ("Floor 100: **14** measured sessions")? The count is more trust-building but rides the still-open band-center/history model-API dependency; if unwired, prose-only this version.
7. **The `achieved` resting state.** When a pattern has hit its stretch but #305 hasn't fired, the draft renders the calm annotation + the forward hook (distance-to-ratchet) and **no prompt**. Is a "raise your stretch?" affordance owed at the moment of accomplishment, or does the quiet instrument suffice? Draft recommendation: the instrument suffices — the stepper is already in hand on this surface.

---

*Key source files: `/Users/arnav/Desktop/ProjectApex/ProjectApex/Features/Workout/CalibrationReviewView.swift` (logic preserved: payload helper, clamps, dual-watermark ack), `/Users/arnav/Desktop/ProjectApex/ProjectApex/Features/Workout/GoalReviewView.swift` (`makeGoalPayload`; the `try?` write this spec hardens), `/Users/arnav/Desktop/ProjectApex/ProjectApex/Features/Workout/WorkoutView.swift` (~L303–333, the two sheets this IA collapses), `/Users/arnav/Desktop/ProjectApex/ProjectApex/Models/TraineeModelSnapshots.swift` (PatternProjection), `/Users/arnav/Desktop/ProjectApex/ProjectApex/Models/TraineeModelDigest.swift` (`deriveCalibrationReviewSignal` — no prior-floor field, the §12 Q5 gap), `/Users/arnav/Desktop/ProjectApex/ProjectApex/Services/TraineeModelService.swift` (L113–126 ack writer), `/Users/arnav/Desktop/ProjectApex/docs/adr/0022-goal-renegotiation-stretch-rederivation.md`, `/Users/arnav/Desktop/ProjectApex/docs/adr/0023-capability-driven-projection-recalibration.md`, `/Users/arnav/Desktop/ProjectApex/docs/design/train.md` §9, `/Users/arnav/Desktop/ProjectApex/docs/design/progress.md` §3–§5, `/Users/arnav/Desktop/ProjectApex/docs/design/post-workout.md` §6–§8, `/Users/arnav/Desktop/ProjectApex/DESIGN.md`.*
