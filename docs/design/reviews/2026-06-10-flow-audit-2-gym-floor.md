# Flow audit 2 of 3 — gym-floor lens

> Agent persona: design lead from top strength-training/health apps (Strong,
> Fitbod, Whoop class). Focus: mid-workout usability, logging friction, data
> honesty, safety of load prescriptions, habit loop, coaching voice. Read-only
> audit of the shipped code, 2026-06-10. Companion reports:
> `2026-06-10-flow-audit-1-journey.md`, `2026-06-10-flow-audit-3-onboarding.md`.

# Training-App UX Audit — gym-floor lens

Reviewer note: I read the actual SwiftUI source, the actor that runs the session, the AI prompts, and the design docs. Where the in-progress Phase 3 spec (`docs/design/ui-overhaul-spec.md`, locked 2026-06-10) already names a problem, I say so — but the audit is of what ships today. Visual tokens (`DESIGN.md`) are locked and not relitigated here.

## 1. The workout loop as built (what the code actually does)

**Entry.** Four-tab `TabView` (`ProjectApex/ContentView.swift:74-119`); Tab 1 routes to a `ZStack` state machine in `ProjectApex/Features/Workout/WorkoutView.swift:328-398` driven by `SessionState` (`WorkoutSessionManager.swift:31-60`): `idle → preflight → active ⇄ resting → exerciseComplete → sessionComplete`.

**Pre-workout.** `PreWorkoutView` shows a Day-X-of-Y progress ring, banner stack (first-session calibration, welcome-back ≥14 days, heavy-reassessment, calibration-review — with explicit precedence at `PreWorkoutView.swift:91-101`), the session card, and a 60pt Start button. Start fires `startSession` (`WorkoutSessionManager.swift:198-281`): writes a crash sentinel, enqueues the session row to a write-ahead queue, fetches streak/RAG/fatigue/session-count in parallel, then **blocks in `.preflight` on an LLM call** for set 1's prescription (8s timeout, `AIInferenceService.swift:904`).

**The set.** `ActiveSetView` renders the prescription card: 72pt tappable weight (opens override sheet), reps, tempo/RIR/rest chips, italic AI "set framing" + coaching cue, collapsible LLM reasoning, safety-flag badges, confidence arc. A 72pt full-width "Set Complete" button with heavy haptic (`ActiveSetView.swift:583-612`). Logging a set = **2 taps minimum**: Set Complete → sheet (`RepRPEIntentConfirmationSheet`, `ActiveSetView.swift:994+`) → Log Set. The sheet pre-fills reps from the prescription, defaults the RPE segment to "On Target", hides the intent picker behind "Did something different?", and offers pain/form-breakdown flag toggles. Commit maps the 3-way RPE picker to RPE 5/7/9 (`ActiveSetView.swift:959`) and the actor writes the `SetLog` through the WAQ with immediate flush (`WorkoutSessionManager.swift:341-348`).

**Rest.** Rest starts instantly at log time using the *previous* prescription's rest seconds; the next set's prescription is fetched from the LLM *during* rest (`WorkoutSessionManager.swift:392-466`). The timer is actor-owned and anchored to an absolute expiry date (`startRestTimer`, `WorkoutSessionManager.swift:1203-1220`); `RestTimerView` snaps remaining time on foreground, fires haptics at 10s/0s, schedules a local notification on backgrounding (`RestTimerView.swift:497-518`), and auto-advances to `.active` at zero if the prescription has arrived. Manual "NEXT SET" skip exists (`RestTimerView.swift:334-351`).

**Failure path.** Any inference failure surfaces a non-dismissable `InferenceRetrySheet` (Retry / Continue-with-last-weights / Pause); "last weights" is only offered during rest, not preflight (`InferenceRetrySheet.swift:77`).

**Deviation handling.** Weight override (session-only, increment-snapped stepper, `WeightOverrideView`), permanent "my gym doesn't have this weight" corrections persisted to `GymFactStore` and injected into future prompts as "Never prescribe it" strings (`GymFactStore.swift:173-193`), and an LLM-chat exercise swap with quick chips ("Equipment taken", "Too heavy", "Feeling pain") (`ExerciseSwapViewModel.swift:30-36`). Pause/resume and crash recovery are genuinely robust (sentinel written at start and updated per set, `WorkoutSessionManager.swift:363-377`; three-path recovery in `ContentView.swift:200-262`).

**After.** `PostWorkoutSummaryView`: trophy header, total-volume hero, sets ring, "AI coached sets" count, voice notes, and a Haiku-generated insights list with a deterministic fail-loud fallback (`PostWorkoutSummaryView.swift:539-629`). Between workouts: Program calendar, and a Progress tab with e1RM trend charts + PR rule line, weekly sets-per-muscle bars, and a consistency heatmap (`ProgressView.swift`).

This is a real, carefully-built loop — crash recovery, write-ahead logging, absolute-time rest anchoring, and the override paths are above-average. The findings below are where it meets an actual gym.

## 2. Findings

---

**F1 — P0: No network, no workout. The loop hard-gates every set on a live LLM call.**
Evidence: every set's prescription is a blocking inference (`WorkoutSessionManager.swift:279-280, 423-434, 450-462`; 8s timeout at `AIInferenceService.swift:904`). On failure the user gets a modal, swipe-disabled retry sheet *per set* (`InferenceRetrySheet.swift:125`). In `.preflight` (first set of the session, and first set after every exercise swap) the sheet offers only Retry or Pause — no manual path (`InferenceRetrySheet.swift:77` gates "Continue with last weights" on `isResting`). Worse, the manual fallback for a *new* exercise with no sets yet this session builds a prescription of `weightKg: 0` (`WorkoutSessionManager.swift:724`), which `ActiveSetView.swift:361-366` renders as **"BW"** — a bodyweight barbell bench press.
Why it matters: gyms are concrete basements with one bar of signal. A lifter mid-session cannot babysit a retry sheet between every set, and "BW" as the offline answer for squats destroys trust instantly. The spec already codifies the principle for coach *copy* ("deterministic local fallback… rule-based ships first", `ui-overhaul-spec.md` §3 P0-2) but the shipping loop's core dependency violates it.
Recommendation: a deterministic local prescription engine (plan targets + last logged set ± one increment from `DefaultWeightIncrements`) that auto-applies with the existing "Coach offline" banner; AI becomes an upgrade, not a gate. Offer "last weights" in preflight too, seeded from cross-session history, never 0kg.

**F2 — P0: Ignoring the RPE picker silently logs RPE 7.**
Evidence: `SetCompletionFormState.swift:97` seeds `rpeFelt: Int = 1` ("On Target"); the sheet's segmented control has no "skip/unknown" option (`ActiveSetView.swift:1068-1073`); commit always maps to `[5,7,9][state.rpeFelt]` (`ActiveSetView.swift:959`) even though the pipeline accepts `rpeFelt: Int?` (`WorkoutViewModel.swift:118-122`). Every two-tap log writes a fabricated "on target, RPE 7" into `set_logs` — which feeds RIR estimation (`WorkoutSessionManager.swift:323`), the trainee model, and prescription accuracy.
Why it matters: this is the exact failure the team's own review called P0 ("an ignored feel pill does not record an on-target feel… the moat depends on this", `ui-overhaul-spec.md` §4) — but that's a future spec; today's code poisons the model on every lazy log. A lifter who fast-logs 80% of sets makes the AI confidently wrong.
Recommendation: make the RPE picker default to *no selection*; pass `nil` when untouched. The plumbing already supports it — this is nearly a one-line honesty fix and it protects the dataset the entire product is built on.

**F3 — P0: AI load prescriptions have no client-side sanity bound relative to the user.**
Evidence: the only structural validation is `weightKg >= 0 && weightKg <= 500`, reps 1–30, rest 30–600 (`AIInferenceService.swift:632-643`). Everything that actually protects the lifter — anti-oscillation, limitation load caps ("severe → do not prescribe a top set"), deload volume cuts, first-session ~60% 1RM — lives only as prompt text (`SystemPrompt_Inference.txt:65, 170-189, 214`). The single code-level safety gate is "pain → rest ≥ 180s" (`WorkoutSessionManager.swift:1139-1141`). A hallucinated 170kg after last week's 80kg passes validation and renders in 72pt black as the coach's instruction.
Why it matters: this app *prescribes loads to humans under fatigue*. Prompt compliance is probabilistic; the UI grants the output full authority with no "this is a big jump" check. First sessions are worst: bodyweight is optional at onboarding (`OnboardingView.swift:33-35`), so the anchor for the very first prescriptions may be nothing but "Beginner" + a goal.
Recommendation: deterministic post-validation clamp against the user's own history (e.g., reject/flag >10–15% jumps on a pattern outside calibration; cap absolute first-session loads by equipment type). On clamp, show a quiet "adjusted from coach's suggestion" note — the UI affordance for this *already exists but is dead* (see F8).

**F4 — P1: The streak — the app's main habit mechanic — is computed for the wrong user.**
Evidence: `WorkoutView.swift:129` and `:219` (and `ProgramOverviewView.swift:922`) call `computeStreak(userId: AppDependencies.placeholderUserId)`, while sessions are written under `deps.resolvedUserId` — the real Keychain UUID after onboarding (`AppDependencies.swift:65-71`). `GymStreakService` queries history by userId (`GymStreakService.swift:218-221`), so onboarded users permanently see the neutral zero-streak. Ironically the *AI* gets the correct streak (`WorkoutSessionManager.swift:270` uses the session's real userId).
Why it matters: the streak drives the tint identity of every workout screen and is the only week-over-week pull mechanic in the live loop. It is silently dead for every real user — the coach knows your streak but the UI never celebrates it.
Recommendation: pass `deps.resolvedUserId`; add a regression test (this is precisely the cross-cutting-grep class of bug `CLAUDE.md` warns about — three call sites, one pattern).

**F5 — P1: Rest-complete alerts can silently never fire, and promised session reminders don't exist.**
Evidence: notification permission is requested once, in onboarding step 3 (`OnboardingView.swift:842-850`); `RestTimerView.swift:497-518` schedules the expiry notification without ever checking `UNAuthorizationStatus` or surfacing denial; nothing re-prompts. Onboarding's permission screen also promises "Session reminders — train on schedule" (`OnboardingView.swift:446`) — no reminder-scheduling code exists anywhere in the target. There's also no lock-screen presence during rest (no Live Activity), only a single fire-at-expiry notification.
Why it matters: phone-locked-in-pocket is the default between-sets state. A lifter who denied the alert (or skipped onboarding's step) gets a rest timer that ends in silence forever, with no hint why. And with the streak broken (F4) and zero reminders, *nothing* in the product brings a user back on day 3.
Recommendation: check authorization at session start and show an inline "rest alerts are off" nudge; ship a Live Activity rest countdown (Strong/Hevy-class table stakes); either build session reminders or stop promising them in onboarding.

**F6 — P1: The lifter can't see their own history at the moment of truth.**
Evidence: the prescription card shows the AI's number, its prose reasoning, and a confidence arc — but no "last time: 80kg × 8/8/7" line (`ActiveSetView.swift:304-579`). `SessionPlanSheet` shows only today's logs. Historical performance is fetched and serialized *for the LLM* (RAG memory, session log, lift history) but never rendered for the human.
Why it matters: trust in a prescribed weight is earned by letting the lifter verify it against what they did last week. Without that anchor, every prescription is "trust me" — and when the AI is slightly off, the user has no fast way to know whether to override. The spec's own data-honesty rule (§8.3: "every coach utterance grounded in a number the user can verify") fails here because the verifiable number isn't on screen.
Recommendation: one line under the hero numbers: last session's top set for this exercise (data already cached in `cachedRAGMemory` / lift history paths).

**F7 — P1: Failed reps can't be logged honestly, and a single set can't be skipped.**
Evidence: the reps stepper clamps at minimum 1 (`ActiveSetView.swift:1035`) — a 0-rep miss (failed the unrack, bailed on the squat) must be logged as 1 rep, fabricating data the e1RM/EWMA engine consumes. There is no "skip this set" affordance at all: mid-exercise your options are log-something, swap the whole exercise, pause, or end the workout (`ActiveSetView.swift:231-254`). The locked spec lists "failed or missed reps" as first-class edge cases (`ui-overhaul-spec.md` §4).
Why it matters: misses are the most information-dense events in training — exactly what a coaching model needs verbatim. Forcing "1 rep" or a full exercise swap pushes users to either lie or abandon the flow.
Recommendation: allow 0 reps (with the existing flags row capturing why) and a "skip set" action in the ellipsis menu that advances `currentSetNumber` without a `SetLog`.

**F8 — P1: Plate math is delegated entirely to the LLM; the client's own rounding affordance is dead code.**
Evidence: equipment increments are enforced only by prompt text (`SystemPrompt_Inference.txt:57-63`); no code rounds a prescription to `DefaultWeightIncrements` before display. `WorkoutViewModel.weightAdjustmentNote` (`WorkoutViewModel.swift:541-552`) parses the marker `"(adjusted to nearest available:"` from reasoning — but nothing in the codebase ever emits that marker (grep confirms: parser and the P3-T04 acceptance comment at `ActiveSetView.swift:11` are the only references). So a 33.7kg dumbbell or 47.5kg stack-machine prescription renders unchallenged, and the "Adjusted" annotation the spec promised can never appear.
Why it matters: unloadable weights are the fastest way to make a lifter stop trusting the coach ("it doesn't even know dumbbells go in 2.5s"). The correction flows (F9 aside, they're good) only fire *after* the user notices and intervenes.
Recommendation: snap `weightKg` to `DefaultWeightIncrements.defaults(for:)` minus known `GymFactStore` exclusions in `handleInferenceResult`, and emit the marker the UI already knows how to display. The data tables and the annotation UI both exist; they're just not connected.

**F9 — P1: "The machine is taken" costs two LLM round-trips and a chat.**
Evidence: swap = ellipsis menu → "Swap Exercise" → sheet opens → `startConversation` LLM call → tap a chip → second LLM call → review suggestion → "Confirm Swap" → then *another* inference for set 1 of the new exercise (`ActiveSetView.swift:166-181`, `ExerciseSwapView.swift`, `WorkoutSessionManager.swift:917-981`). Five-plus interactions and three network calls for the most common interruption in a commercial gym, with no offline path (F1 applies).
Why it matters: someone is standing on your station; you need an answer in ten seconds, one-handed. A chat assistant is the wrong altitude for a problem the `ExerciseLibrary` + gym profile can answer deterministically.
Recommendation: instant local list of same-primary-muscle alternatives filtered by available equipment (all data is on-device: `ExerciseLibrary`, `GymProfile`, `completedExerciseIds`), with the chat demoted to "something else?".

**F10 — P2: Sub-44pt, low-contrast controls on the two most-used secondary actions.**
Evidence: the "NEXT SET" skip-rest button is ~33pt tall (font 13 + 10pt vertical padding) at 28% white opacity (`RestTimerView.swift:334-351`); "My gym doesn't have this weight" is a bare 12pt text row (`ActiveSetView.swift:448-460`). `DESIGN.md` itself mandates 44pt minimum tap targets.
Why it matters: skipping rest is something experienced lifters do dozens of times a session, with chalked, sweaty thumbs, phone in one hand. The countdown also renders raw seconds ("142 / seconds", `RestTimerView.swift:377-379`) — lifters think in minutes for 2–3 min rests, and `formattedRestTime` (m:ss) already exists unused (`WorkoutViewModel.swift:532-536`).
Recommendation: 44pt+ hit areas (`contentShape`), brighter resting state for skip, and m:ss display above 90s.

**F11 — P2: kg-only in the live loop.**
Evidence: every weight render hardcodes "kg" (`ActiveSetView.swift:380-382`, `RestTimerView.swift:308`, `SessionPlanSheet.swift:164-170`, `WeightOverrideView`); the only lb support in the app is bodyweight entry at onboarding (`OnboardingView.swift:280-334`). The future onboarding spec concedes the need ("unit pill — the unit choice persists app-wide", `docs/design/onboarding-calibration.md` §3.5).
Why it matters: a US user doing mental ×2.205 between sets will mis-load plates; for an alpha cohort this may be acceptable, but it should be a deliberate decision, not an accident of `String(format:)`.
Recommendation: app-wide unit preference applied at the formatting layer (storage stays kg, which the code already does correctly for bodyweight).

**F12 — P2: PRs are computed but never celebrated where they happen.**
Evidence: `SessionSummary.personalRecords` is hardcoded `[]` ("PR detection is a P4 deliverable", `WorkoutSessionManager.swift:1441`), so the summary's gold PR section (`PostWorkoutSummaryView.swift:329-365`) can never render — while the same actor computes `outcomeNote = "pr"` per set *for the AI's session log* (`WorkoutSessionManager.swift:1276-1282`) and the Progress tab independently derives all-time-best points and PR heatmap cells (`ProgressViewModel.swift:371, 450`). Meanwhile the summary's actual heroes are total volume, a sets ring, and an "AI coached sets" count — the exact "vanity scoreboard" the locked spec orders cut (`ui-overhaul-spec.md` §5).
Why it matters: the dopamine moment for a lifter is the PR *in the moment*, not a heatmap dot discovered next Tuesday. The detection logic literally exists in the same file that ships an empty array.
Recommendation: wire the existing per-set e1RM-best check into `SessionSummary.personalRecords` now; it's a smaller change than the comment implies and it converts the summary from a stats receipt into a reason to come back.

**F13 — P2: Voice drift between the coach's surfaces (small, but it reads as multiple coaches).**
Evidence: the inference prompt enforces a terse, anti-platitude voice with explicit bad examples ("You got this!" banned, `SystemPrompt_Inference.txt:35-55`) — genuinely good. But the swap assistant is briefed "conversational, friendly" and emits "Happy to help" (`SystemPrompt_ExerciseSwap.txt:8, 56`); UI fallback strings disagree with each other ("using **program** defaults" `WorkoutViewModel.swift:441` vs "using **plan** defaults" `RestTimerView.swift:256`); and the post-workout insights are a third register again. The manual-fallback framing "Using last session weights. No AI guidance." (`WorkoutSessionManager.swift:740`) is honest but reads as the coach disclaiming responsibility mid-set.
Why it matters: tone consistency is how a synthetic coach becomes *a* coach. The terse register in the inference prompt is the right one — the others should converge on it.
Recommendation: a one-page voice constitution shared by all four prompts + UI strings; unify the offline-fallback copy literal.

**F14 — P2 (hygiene with UX blast radius): a stale duplicate of the workout UI lives at the repo root.**
Evidence: `/Features/Workout/` (repo root) contains older copies of `InferenceRetrySheet.swift` (missing the "Continue with last weights" path entirely), `ExerciseSwapView.swift`, and `ExerciseSwapViewModel.swift`, diverged from `ProjectApex/Features/Workout/` (diff confirms). The task brief even pointed reviewers at both.
Why it matters: the next failure-path edit has a coin-flip chance of landing in the dead copy — and the failure path is exactly where F1's fixes go.
Recommendation: delete or quarantine the root copies (flagging per repo rules — grep-and-report: these are the only duplicated view files I found).

## 3. The three things to fix first

1. **Make the loop survive a dead connection (F1 + F8).** Build the deterministic local prescription path — last logged set, plan targets, increment tables you already ship — and let the AI upgrade it instead of gating it. Connect the existing-but-dead weight-rounding annotation while you're in there. Right now the app's worst-case gym (basement, no signal) is a hard product failure, and the fallback that does exist can tell a lifter to bench "BW".

2. **Stop fabricating data the model eats (F2 + F7).** Default RPE to *unset*, allow 0-rep logs, add skip-set. Your own locked spec calls the first of these a P0 and "the moat depends on this" — the moat is being leaked one lazy two-tap log at a time, today, before the redesign ships.

3. **Bound the AI and show your evidence (F3 + F6).** A clamp against the lifter's own history plus a one-line "last time: 80kg × 8/8/7" on the set card turns the prescription from an oracle's command into a checkable claim. That pairing — safety rail underneath, verifiable number on top — is what makes people load the bar with the weight your app says.

(Quick wins that don't fit the top three but are nearly free: the streak userId one-liner (F4), the notification-authorization check (F5), and wiring `personalRecords` (F12) — together they'd resurrect most of the week-over-week habit loop.)
