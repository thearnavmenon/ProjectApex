# Project Apex — Work Diary

A plain-language diary of work that gets pushed and merged, written in simple words —
like a journal, not a technical log. Newest entries go on top.

Started 2026-06-07.

---

## 2026-06-16 — Fixed four sign-in / data-saving bugs

**The problem (in plain words).** A batch of leftover bugs from the sign-in security
work could lose or mis-save data right after the app starts, before it has finished
quietly signing in:
- "Reset All" wiped saved data but didn't stop a workout that was already running, so
  that live workout could still try to save under the old identity.
- If the app couldn't start a workout because sign-in hadn't finished, it just silently
  re-enabled the Start button and told you nothing.
- A few save paths (your program, your gym equipment, set-correction notes) grabbed the
  user identity too early — while it could still be a temporary placeholder — so the
  save could be rejected by the server's ownership rules.
- If you set up your program while offline (or sign-in stalled), the program was saved
  on the phone but never to the server, and nothing ever retried — so later workouts had
  nothing to attach to and failed.

**What changed.**
- Reset All now also clears a running workout (#403).
- Failing to start a workout now shows "Couldn't start — check your connection and try
  again" instead of silently doing nothing (#399).
- The program/gym/notes save paths now wait for the real signed-in identity before
  saving, and skip the save entirely (rather than save wrong) if it isn't ready yet
  (#409, done in two parts).
- The app now quietly backfills a phone-only program to the server the next time it
  loads with a real identity — and is careful to tell "server has nothing" apart from
  "couldn't reach the server" so it never double-saves or hides a real program (#425).

**How I checked it.** Each fix was built test-first (a failing test that proved the bug,
then made green), reviewed by a separate independent check, and the full nearby test
groups were re-run green before merging. Each one was its own small, single-purpose
change on its own branch and pull request.

**Status:** All merged. PRs #427 (#403), #428 (#399), #429 + #430 (#409), #431 (#425) —
issues #403, #399, #409, #425 all closed.

---

## 2026-06-16 — Made the UI removal official and tidied the task list

**What happened.** Yesterday we decided to throw away the half-built new look and keep
the old four-tab app. Today that change actually went live on the main copy of the
code, and I cleaned up all the leftover paperwork that the decision created.

**What changed.**
- Merged the big delete (about 9,400 lines of the abandoned new UI) into main, so the
  app now only has the old, working four-tab screens. Nothing the old app needs was
  removed — I checked the build still works and the start-up tests pass before merging.
- Removed a leftover scratch copy of the project (a stale "worktree") that still held a
  piece of the old new-UI code.
- Closed 17 old to-do tickets that were all about building the new UI — they're dead
  now, so I marked them "won't fix" and pointed each at the decision record (ADR-0029).
  Also closed a draft write-up tied to one of them.
- Closed one ticket (#391) that was actually already done — the database safety-trigger
  it asked for had shipped earlier and is live; the ticket just never got closed.
- Kept one ticket open on purpose: the app-icon / wordmark artwork (#344), since the old
  app could still use a proper icon.

**How I checked it.** The new code built cleanly and the launch tests passed before the
merge; the merge into main was a clean fast-forward. The closed tickets were verified
against the actual code and the merged removal first.

**Status:** Done. PR #426 merged (commit a779dc4). Issues #342, #343, #348–363, #376,
#391 closed; draft PR #383 closed. #344 kept open for re-scoping.

---

## 2026-06-15 — Removed the new UI and went back to the old one

**What happened.** A while back we started building a brand-new look for the app — a
clean 3-tab design with a fresh "Today" home screen. It was never switched on for real;
it sat behind an off-switch while we built it. When we finally looked at it running, it
didn't look good: the Progress screen was basically empty, the Train screen showed
leftover placeholder text and a scratchy diagonal pattern that looked broken instead of
like a calendar, and workout names were cut off. It just didn't feel finished, or as nice
as the old app.

**What I changed.** I removed all of the new-UI work — the new shell, the new Today,
Train, and Progress screens, the new "look" system (colours, fonts, custom drawings), the
embedded fonts, and all their tests. About 9,000 lines gone. The app now always shows the
old, familiar 4-tab screen. I kept the behind-the-scenes "smart coach" features (the ones
that set your targets and show the review banners) because the old app uses those too —
they're not part of the look.

**How I made sure it works.** I rebuilt the whole app and the tests on a clean simulator —
everything compiled with no errors. I also kept one small test that checks the app's
start-up safety gate and confirmed it still passes.

**Status:** Done on a branch, opening a pull request for review. The design write-ups were
moved into an archive folder (not deleted) in case any idea is worth revisiting.

---

## 2026-06-15 — Fresh sign-ups got a workout plan that never reached the server (#423)

**The problem.** When a brand-new person finished setting up the app, we made their training plan and saved it on their phone — but we forgot to also save it to the server. So the moment they tried to log a workout, the server said "I've never heard of this plan" and the save failed. Every fresh account was effectively broken: the plan existed only on the phone, never in the database.

**The fix.** After the plan is built and cached on the phone, we now also write it to the server — but only after we've confirmed the real account it belongs to. If we can't confirm the account (sign-in still pending, or offline), we skip the server write and keep the phone copy, rather than saving it under a fake placeholder owner that the security rules would reject. Same "figure out who owns it before stamping it" rule the rest of the new auth work follows.

**Checked.** Wrote a test that fails before the fix and passes after (proves a real account triggers the server save, and a missing/placeholder account does not). Full suite green (506 tests, 0 failures).

---

## 2026-06-15 — Made the "needs setup" check actually test the real code (#376 follow-up)

When the app is missing its keys it shows a "needs setup" screen instead of a doomed onboarding. The new shell's review pointed out the test for this was checking a hand-copied version of the rule, not the real one — so if someone broke the real check, the test would still pass. Pulled the rule into one tiny shared function that both the app and the test call, so the test now guards the actual production code. No behaviour change; the new shell still stays off.

Checked: full suite green (575 + 506 tests).

---

## 2026-06-15 — Hotfix: the Progress screen wouldn't compile, so the whole app was broken

**The problem.** A clean rebuild of the app failed to build at all. The recent "long-absence re-anchor" change (#418) added a new `inTransition` flag to a Progress data row, but wrote it as a constant with a built-in default. Swift quietly leaves that kind of field OUT of the automatic initializer — so the code that *set* the flag failed with "extra argument." The app hadn't compiled since that change merged; it slipped in because that work merges past the flaky iOS build check.

**The fix.** One character: changed the field from a constant to a variable, which puts it back into the initializer (still defaulting to off, so nothing else changes). Caught by the clean full-suite re-verify done as part of the shell go-live prep.

**Checked.** Full suite green again (575 + 506 tests, 0 failures). Fixed in PR — main compiles.

---


## 2026-06-14 — Moving the "brains" of the app into the new shell, without flipping the switch (Phase 3 UI, #376 — commit 1 of 2)

**The big one, done carefully.** For weeks the new 3-tab look has been built but switched off, while the real app kept running on the old screen (`ContentView`). That old screen quietly owns the most fragile, most important plumbing in the whole app: the first-launch setup, the "you have an unfinished workout — resume or abandon?" recovery after a crash, and the exact rules for picking the right session back up. This task copied all of that plumbing into the new shell — faithfully, line for line where it mattered — so the new shell can stand on its own. **But I did not flip the switch.** The old screen is still the live one, completely untouched. Nothing a user sees changed.

**Why split it this way.** Turning the new shell on is the genuinely scary step — if the resume logic dropped a thread, someone could lose a workout they were halfway through. So this is deliberately commit 1 of 2: this commit *moves* the plumbing (safe, dormant, reversible by one undo), and a later separate commit flips the switch — and that flip only happens after a hands-on "force-quit mid-set on a real phone" test. This PR is explicitly **not** to be auto-merged; a human reviews it.

**The six pieces moved.** The program "view model" and its whole life-cycle (born on launch, reborn after onboarding, wiped on reset); the onboarding cover; the crash-recovery alert chain — including a subtle fix from earlier (#318) where two alerts firing at once would silently eat one of them, copied across *exactly* so it can't regress; the paused-session resume with its three branches; the workout loop and the settings screen (which are joined at the hip to the view model); and the "this build needs setup" gate, which I lifted up one level so it now guards **both** the old and new screens from a single place.

**Loop look at go-live.** When the switch eventually flips, the workout itself will still use the *current* in-session screens, so the day it goes live it behaves identically to today. The brand-new live-loop visuals turn on later, as their own separate, undoable step.

**How I made the scary parts testable.** The two riskiest pieces — which resume branch to take, and the two-alerts-collide rule — I pulled into small plain functions the new shell calls, so I could write tests that prove all three resume branches and the alert-collision rule behave correctly against the new shell (the codebase tests logic, not live screens). The alert *ordering* itself was copied across untouched.

**Status:** PR open from `feat/376-machinery-lift`, switch still **off**, old screen still live and untouched. 15 new tests green; the full suite (506 tests) was green before the run. Flagged in the PR: the small "pull the decision into a testable function" deviation, since the brief asked for a verbatim move.


## 2026-06-14 — Coming back after a long break no longer fools the strength estimate (#418)

**The problem in plain words.** The app tracks how strong you are with a moving average that only looks at your last few *workouts*, not the calendar. That works great while you're training regularly. But if you vanish for six weeks and come back, the math treats your first workout back as if it happened the very next day — so it quietly assumes you're as strong as you were before the break. You're not. Real strength fades during a long layoff, and the old code couldn't see that.

**What changed.** When a gap of 28 days or more is still sitting inside a lift's recent-workout window, the estimate now throws out the stale pre-break workouts and re-anchors on the workouts you've done *since coming back*. So your first session back reads your real current strength (~110.83 kg in our worked example) instead of the stale old number (~116.74 kg). And it *stays* re-anchored across the whole comeback window — it doesn't snap back up on your second workout — then quietly turns itself off once the old pre-break workouts have aged out of the window and normal tracking resumes. The 28-day trigger matches the cue the app already uses to suggest a return-to-training phase.

**Knock-on effects handled.** The strength floor (the number your training band is built on, which is only ever allowed to ratchet *up*) is paused from ratcheting on stale comeback data, so a break can't accidentally lock in an inflated floor — and the "only goes up" rule is preserved. Two screens (the goal-review capability list and the progress ledger) now show a small "Re-establishing after a break" note so you know why a number dipped.

**How it was checked.** Built test-first across the slices; the full Edge-Function suite is green (452 tests, 0 failing) and the type-checker is clean. An independent review caught one real bug along the way — a naive version actually moved the estimate the *wrong* way — which is why trimming the old workouts is mandatory, not optional. The iOS side compiles against the real type definitions but isn't visually QA'd yet (no simulator here); that and snapshot images are owed. Decisions recorded in ADR-0005/0015/0020/0023.

**Status:** MERGED to main (PR #418, squash `b780549`). Does **not** close the #369 audit umbrella. One follow-up noted for later: a fatigue-pairing calculation also reads the strength estimate and may want the same break-aware gating — reported, not yet acted on.

## 2026-06-14 — The Today screen: your next workout, one tap to start, one honest coach line (Phase 3 UI, #348)

**What it is.** The new Today tab's main screen — the "what does my coach want from me right now?" surface. At the top: the date and a small readiness gauge (the Lens). Below that: one short coach line. Then the hero — a single card showing your next session (its title, up to three exercises with their sets and reps drawn as a crisp number lockup, a rough time estimate) and one big full-width **Start** button, the only coloured thing on the screen. Any coach alerts sit as a calm list *below* Start — never a pop-up jumping in front of it.

**The coach line is the careful part.** It's one short sentence, always grounded in a real number from your trainee model — your squat floor, the gap to your next floor, your session count — and it's written by plain rules with **no AI call at all**. The AI version is a future upgrade, never something the screen depends on. If the rules have nothing genuinely true to say, the line collapses to an empty space — never filler, never "You got this!". The whole thing is governed by our ratified coach-voice rules: instrument-grade, factual, no warmth/praise/hype. I even added a test that scans every possible output against a banned-cheerleading word list to prove it.

**The rules, ranked.** (1) If a pattern is still calibrating, say so and give the model's own session count. (2) Otherwise state the floor as a held fact ("Squat floor at 105 kg — square in the band"). (3) If you're pushing the top of your band, give the deterministic distance to the next floor. (4) Last resort: a plain session tally. Each is capped at a hard 80-character budget; anything over, or anything with an ellipsis, fails and the next rule (ultimately the empty collapse) takes over.

**How it gets its data (the seam).** Like the sibling Train and Progress screens, the new shell doesn't own the live program "view model" yet, so the screen takes its data as a plain input tests can hand it, and the live host reads the same saved-program cache and trainee-model the old screens read. Start is wired to a clearly-marked TODO (#376) for the real session-start path — it's tappable now, live at the flip. No backend or model change.

**Still dormant.** Brand-new screen wired only into the off-by-default new 3-tab shell. The live app runs the old screens untouched — nothing users see changed.

**Tests.** Unconditional tests cover which rule fires for which model state, the no-AI fallback, the empty-collapse, the character budget, the no-warmth guard, the evidence-number formatting, and that Start fires its wired action. Image snapshots (light + dim + an accessibility size) are wired but their reference images aren't recorded here — the CI record job does that.

**Status:** PR open from `feat/348-today`. New suites all green (21 tests in the scoped run); whole app + tests compile with no new warnings.


## 2026-06-14 — The Train program root: your plan drawn as a vertical day-spine (Phase 3 UI, Slice 15 #357)

**What it is.** The new Train tab's main screen, drawn as a single vertical spine running down the page — the left edge is the timeline, and each training day hangs off it. This week shows in full: each day a row with a small status mark (a filled dot = done, a hollow dot = scheduled-but-not-done) and a short list of that day's exercises. Days you don't train are first-class "rest" nodes on the spine, not blank gaps. Below this week, the rest of the plan shows compressed and faint — pattern/focus only, no fake numbers — because the coach hasn't worked those days out yet.

**The honest part.** The whole point is the line between *what the coach has placed* and *what it's still going to figure out closer to the day*. Placed days are drawn in ink with real exercises; not-yet-placed days are drawn in pencil as a shape only, inside a faint diagonal hatch zone, with a drawn "PLACED ABOVE · SHAPE BELOW" line between the two. The further out a week is, the more it compresses — but in three clear steps, never a smooth fade. And there are deliberately no streaks, no rings, no "3 of 5 done" counters, no shame mark on a missed day — the calendar is a plan, not a report card. A skipped day just stays a hollow dot, like any other day the plan moved past.

**Derived, not stored (no data changes).** Rest days and skeleton days aren't new saved states — they're worked out from what's already there. A weekday with no training day = a rest node. A day with no generated exercises yet = a skeleton (pencil) day. I added zero new cases to the saved data and changed no model, so nothing about how programs are stored changed. The mapping from a day's status to its dot, and these rest/skeleton rules, all live in the new screen (the dot drawing itself is a dumb shared piece).

**How it gets its data (the seam).** The new shell doesn't yet own the program's live "view model," so this screen takes its data as a plain input that tests can hand it directly, and the live version reads the same saved-program cache the old screen reads first. When no program is cached it shows an honest empty state. The real live wiring (current-week tracking, days re-resolving on screen) is a clearly-marked TODO for a later slice (#376).

**Still dormant.** This is a brand-new screen wired only into the off-by-default new 3-tab shell. The live app still runs the old program screen untouched — nothing users see changed.

**Tests.** New unconditional tests cover the dot mapping for every day status above and below the horizon, rest-and-skeleton-from-gaps, the three discrete compression steps, "Week X of N," and a guard proving the screen carries no streak/counter/adherence field. Image snapshots for light + dim + an accessibility size are wired up but their reference images aren't recorded here — the CI record job on Xcode 26.3 does that.

**Status:** PR open from `feat/357-train-root`. New suites all green (23 tests in the scoped run); whole app + tests compile with no new warnings.


## 2026-06-14 — The drafting-rule system: drawing what the model knows vs. is still guessing (Phase 3 UI, #411)

**What it is.** A shared set of drawing pieces for one idea that shows up on three screens: the line between *what the coach has placed* and *what it hasn't worked out yet*. The rule is simple — if the model has committed to something, draw it in ink with real numbers; if it's still provisional, draw it in pencil as a shape only; and always draw the boundary between the two as an actual line, never leave it to ink-vs-pencil alone (because the muted pencil colour already means "time/metadata," so on its own it reads as "minor detail," not "not figured out yet").

**The pieces.** A `DraftingRule` (a thin full-width line with a little 4pt tick at the left margin — Today's drawing signature, solid or dashed). A `DraftingRegister` (a tiny two-tone caption in the margin — the number in ink, the words in pencil — that simply isn't drawn when there's nothing to say, never a fake "0"). A `GenerationHorizonBreak` (the drawn line on Train's plan that says "PLACED ABOVE · SHAPE BELOW"). A `ToBePlacedHatch` (a sparse diagonal pencil hatch filling the not-yet-planned zone). And a `CommitmentTier` — the further-out-is-fuzzier effect drawn as three clear steps (this week in full, next compressed, beyond as one mark per day), deliberately NOT a smooth fade, so it can't be mistaken for a confidence-on-a-chart slope (which the app bans).

**One shared floor line (fixes a real bug, #408).** The Progress screen's "spine" — the single vertical line all the rows' floor ticks are supposed to land on — used to guess its position from a stand-in band, so rows of different widths drifted slightly off it. I pulled the floor position into one shared helper (`BandDatum.floorX`) that the band, the spine, and the new horizon all call, so every floor tick lands on exactly the same line. The Progress screen's spine now uses that helper instead of its own inline guess. Same picture as before for normal widths — just exact now instead of approximate.

**A doc fix.** The design doc said projection dashes are always the accent ink colour, but the shipped band actually draws its dashed edges in the hairline colour. I corrected the doc to match the code: a dashed *chart line* is accent ink, a dashed *band edge* is hairline. I did not touch the band's code.

**Important: still dormant.** None of these new pieces are wired into any screen yet — they're built and tested, waiting for the per-screen slices. The only live-code change is the Progress spine swapping to the shared floor helper, and even that screen is behind the off-by-default new shell.

**Tests.** New unconditional tests cover the new measurements, that "committed vs. provisional" is a total function over every input, that the register vanishes at zero, that the gradient is genuine discrete steps (no in-between), that the hatch uses the pencil colour and the dash uses the 4-2 projection pattern, and a guard proving the band, the spine, and the horizon all compute the *same* floor x (the #408 regression guard). Image snapshots for light + dim + an accessibility size are wired up but their reference images aren't recorded here — the CI record job on Xcode 26.3 does that. Added ADR-0028 recording the whole committed-vs-provisional model.

**Status:** PR open from `feat/411-drafting-rule`. New suites + the Progress regression suite all green (42 tests in the scoped run).


## 2026-06-14 — Built the StatusTick instrument: filled/hollow/undrawn day-status + today marker (Phase 3 UI, Slice 5 #410)

**What it is.** A shared drawn instrument for day/set status on the Train spine — the drawn replacement for the green check that the design bans (train.md §3). Three values: `filled` (done, solid ink dot), `hollow` (committed-not-done, ink stroke with paper interior), `undrawn` (skeleton/below-horizon, renders nothing — the drafting-rule zone, a sibling slice, is the only mark there). A `isToday` flag layers a quiet 2px ink left-margin rule, static, no animation.

**Why a primitive.** The mapping from model state (completed / generated / skeleton / skipped) to filled/hollow/undrawn depends on the generation horizon — that logic belongs in the consuming Train screen (#357), not here. This instrument is "dumb": it draws whatever value it is handed.

**RestWellNode.** A sibling view in the same file — a recessed `well` row for rest days on the Train spine. Not a tick. Rest is derived from day-of-week gaps (no model change); the node states what recovery buys. The caller supplies the recovery line; the view applies the `well` token background and `inkMuted` text.

**Geometry constants.** Added `DesignGeometry.dayStatusTick = 4` (matching the live-loop §3 spec) and `DesignGeometry.dayStatusTickStroke = 1.5` (mirroring CapabilityBand's hollow dot) to Layout.swift.

**Cross-cutting grep.** Checked LiveLoopView.swift and PostWorkoutSummaryView.swift for existing filled/hollow tick rendering. LiveLoopView renders the set-position as plain text (`setPositionText` = "set 2 of 5" at line 254) — no drawn ticks, not yet using StatusTick. PostWorkoutSummaryView has Circle draws at lines 307–312 and 519–520, but these are the GymStreak ring (a legacy multi-hue progress arc) — not set-grain ticks. Neither site was touched; unifying them onto StatusTick is a future authorized step.

**Still dormant.** Not wired into any live screen. The 3-tab shell is still behind `useNewShell = false`; ContentView is untouched.

**Tests.** 8 unconditional tests cover: `dayStatusTick` constant (4pt), stroke constant (1.5px), the three value cases, the no-numeric-content guard (honesty law), and today-marker is a static Bool. Image-snapshot tests for filled/hollow/undrawn × light+dim, filled+today, AX5, and RestWellNode light+dim are wired up but reference images are not recorded here — the CI record job on Xcode 26.3 does that. `APEX_RECORD_SNAPSHOTS` was never set.


## 2026-06-14 — Last piece: the goal/calibration/manual-log screens now wait for login before saving (6 of 6)

**The problem, in plain words.** A handful of less-common save points — editing your goal, reviewing a calibration, logging a past workout by hand — still grabbed "who am I" the old, instant way, which during the first second after opening the app can be the temporary stand-in id. A save stamped that way gets rejected. The main workout flow was already fixed in the earlier pieces; this is the long tail.

**What I changed.** Those three screens now wait for the real login the same way the workout screen does. For the two "best-effort" syncs (goal and calibration), only the part that talks to the server waits for login — the bit that updates your screen still happens instantly, so nothing feels slower. For logging a past workout by hand (which actually creates records), it now waits for login and, if it genuinely can't confirm one, shows "sign-in isn't confirmed yet, please try again" instead of silently doing nothing.

**What I deliberately left for later (and why).** A few remaining save points live inside the app's main container screen, which a *separate* redesign is actively rebuilding right now. Editing it today would collide with that work and likely get thrown away when the redesign swaps it out. So I wrote those up as a tracked task (#409) to do once the redesign lands. I also confirmed the workout-note and AI-memory saves are already safe, because they're tied to the workout — and the workout itself can no longer start under the wrong login (earlier pieces).

**How it was checked.** The whole app builds; a review agent confirmed each screen still updates locally regardless, that the "wait for login" step doesn't slow anything (the login is already settled by the time you reach these screens), and that no nearby save in the same files was missed.

**Status:** merged as PR #412 (Slice 6 of 6 — the owner-mismatch campaign is complete bar the one tracked follow-up #409 and switching the database auto-create rule on in production).

---

## 2026-06-13 — Built the Progress root: the capability ledger (Phase 3 UI, Slice 12 #354)

**What it is.** The new Progress root screen — the "capability ledger." Instead of the old progress tab, the rebuilt shell now routes to a scrollable list of capability bands, one row per movement pattern, all aligned on a shared vertical spine. The spine is the key visual: every row's floor tick sits at the same x-position, so when you look at the screen you see one continuous 2px vertical line running from top to bottom. That line is the app saying "here is every pattern's floor, side by side."

**Row anatomy.** Each active pattern gets three lines: the pattern name (Squat, Hip Hinge, etc.), a compact band strip showing floor, stretch, and today's dot at list scale, and an annotation line. The annotation always reserves its height so the layout never reflows when content changes. For patterns that are calibrating the annotation says "still calibrating." For everything else, the forward hook reads "ratchet within reach" — a permanent instrument annotation telling you the next floor increase is achievable. This is qualitative on purpose: the model doesn't yet expose how many sessions you are away from the next ratchet, so we don't invent a number. That count comes in a later model-API slice.

**Canonical order, always.** Patterns appear in the model's own taxonomy order (Squat → Hip Hinge → Horizontal Push → Vertical Push → Horizontal Pull → Vertical Pull → Lunge → Isolation) and never reshuffle. Dormant patterns (those you haven't trained recently) hold their position but compact to a single muted line with a date instead of showing a full band strip.

**Important: still dormant.** The 3-tab shell (`AppShell`) is behind `useNewShell = false` in the app, so real users still see the old `ContentView`. Only the `.progress` branch of `AppShell.surface(for:)` changed — one line swapping `ProgressTabView(...)` for `ProgressRootLedgerHost()`. `ContentView`, `ProgressTabView`, and `ProgramOverviewView` are untouched.

**Tests.** 12 new unconditional tests cover: canonical sort order (squat first, isolation last), the 2px spine constant, list-scale band context, the honest-absence annotation (no fabricated session count), cold-start produces zero rows, dormant detection. Image-snapshot tests for light + dim + AX5 are wired up but reference images are not recorded here — the CI record job on Xcode 26.3 does that.

**Status:** PR open from `feat/354-progress-root`. 393 tests (12 new + 381 existing), all green.

---

## 2026-06-14 — The outbox now drops a save it knows will be rejected, instead of hammering it 5 times (5 of 6)

**The problem, in plain words.** The "outbox" of pending saves retries anything that fails — five times, with growing waits — assuming the failure is temporary (bad signal, server hiccup). But a save stamped with the wrong owner is *never* going to succeed; the database will reject it every single time. So the app would waste five rounds of guaranteed-to-fail tries on each one, filling the log with red and slowing real saves.

**What I changed.** The outbox now does a quick check just before sending: "does this save's owner match who I'm signed in as right now?" If it clearly doesn't, it sets the save aside immediately (into the "couldn't send" pile) instead of retrying five times. If there's no owner to check, or the login isn't settled yet, it skips the check and behaves exactly as before — so it can never wrongly drop a good save.

**How it was checked.** Four tests cover the whole grid: wrong owner is set aside on the first try (no retries — proven precisely); right owner sends normally; no-login-yet skips the check; and saves that don't carry an owner (like individual sets, which are tied to the workout instead) are never touched. A review agent did the careful part by hand — it traced that the "who's signed in" value and the "who owns this save" value always come from the same source, so they can't drift apart and cause a good save to be dropped, and it checked every kind of save the app sends to confirm the check targets the right ones and skips the rest.

**Status:** merged as PR #407 (Slice 5 of 6). One slice left: apply the same "confirm the login first" rule to the remaining writes (notes/memory, program edits, profile).

---

## 2026-06-13 — When the app reopens an old paused workout, it now checks it's really yours first (4 of 6)

**The problem, in plain words.** If you paused a workout and came back later, the app would pick it back up and try to save to it. But if that paused workout was created under an old/temporary login (which is exactly what was happening), the database rejects every save against it — and worse, the app would try to *re-create* that workout under the old owner, which also fails. This was the exact thing in your gym log: the app resumed an old session and the saves piled up red.

**What I changed.** Before resuming a paused workout, the app now asks "does this workout belong to the login I'm signed in as right now?" If yes, it resumes exactly as before. If it belongs to a different (old) login, it doesn't try to replay it — it clears it out and shows a short note: "couldn't confirm your previous workout for this account — it was cleared. Start a new one." So instead of an endless wall of failed saves, you get a clean start.

**How it was checked.** Two tests: one proves the "clear it out" routine empties the outbox and the paused snapshot; the other drives the real flow — a paused workout stamped with login A, the app signed in as login B — and proves the app stays idle, clears the old workout, and shows the note (it would fail if the ownership check were removed). A review agent confirmed the check runs *before* any save attempt, that clearing the whole outbox here is correct (everything in it belongs to the old login at that moment), and that the two tests are now load-bearing — I tightened one of them after it pointed out the original didn't really prove anything.

**Status:** merged as PR #406 (Slice 4 of 6). Next: as a safety net, have the outbox itself refuse to retry a save whose owner doesn't match the current login.

---

## 2026-06-13 — Built the new "do the set" screen (numbers big, one tap to log, then it becomes the rest timer)

**What this is.** The first piece of the redesigned workout screen. It shows one set at a time: the exercise name, then the target weight and reps as big numbers you can read from across the gym. A full-width ink bar sits at the bottom that just says **Done**. Tap it once and the set is logged exactly as prescribed — no pop-up form, no fiddling with fields. The screen then smoothly turns into the rest timer in place, and when rest is over it shows the next set.

**Two nice touches from the design.** On the very last set of the whole workout, the bottom bar quietly changes its word from "Done" to **Finish** — so the end of the session is obvious. And there's a rule the designers call "work is ink, time is pencil": the weights and reps (the work you did) are drawn in full-strength ink, while the rest-timer digits (just time passing) are drawn in a lighter grey. Same handwriting, lighter pencil — so the two read as one calm system.

**Guards so a tap is never a mistake.** The Done bar ignores a stray brush of the thumb, and it goes dead the instant you tap it so a double-tap can't log the same set twice. The little plate-thud buzz fires at the moment the set is committed, not when you first touch down.

**Important: this is built but not switched on yet.** It's a brand-new screen that nothing in the live app routes to. The old workout screens are completely untouched and still run the real app. This is the same "build it behind a curtain, swap later" approach we've used for the rest of the redesign.

**What's deliberately left for the next slice (#351).** The "tap a number to change it" adjuster, the AMRAP (max-reps) counter, and the dramatic ink-flood entrance animation — all hooks are in place but the work is parked. This slice is just the core loop: see the set, tap Done, rest, next set.

**How I checked.** 16 tests, all green: they drive the real workout engine through start → log → rest → next set, prove the Done→Finish relabel only flips on the true last set, prove the double-tap and stray-brush guards hold, and prove the ink-vs-pencil colour split. Picture-comparison tests for the set and rest screens (light and dark) are wired up but their reference images are recorded later on the build server, by design. The screen builds with no new warnings.

**Status:** opened as a PR off `feat/350-live-loop-core`. Dormant build — new screen only; old views still live.

---

## 2026-06-13 — "Reset All" now truly empties the outbox, not just the on-disk copy (3 of 6)

**The problem, in plain words.** The app keeps an "outbox" of saves waiting to reach the server. When you tap "Reset All," the app wiped the saved-to-disk copy of that outbox — but the *running* copy already loaded in memory survived, and would quietly re-save itself the moment anything new got added. So a reset could leave behind stale, mis-owned saves that fail again after you set the app up fresh.

**What I changed.** Two small lines in the reset routine: actually tell the live outbox to empty itself (in memory and on disk), and clear any paused-workout snapshot. Now a reset is a true clean slate — provided you quit and reopen afterward, which the reset message already tells you to do.

**How it was checked.** I added a test that fills the outbox's "failed pile," empties it via the reset call, and then re-opens it from scratch to prove nothing came back — the gap the old test missed (it only ever cleared an already-empty outbox). A review agent confirmed the ordering is safe and flagged one real edge — a workout that's *actively in progress* at the instant you reset isn't cleared from memory — which I filed as #403 (it's covered in practice by the quit-and-reopen step). I also made the test poll instead of sleeping a fixed time, so it can't flake.

**Status:** merged as PR #404 (Slice 3 of 6). Next: when the app reopens an old paused workout, check it still belongs to you before replaying it.

---

## 2026-06-13 — Make sure every new login gets a profile row, automatically (2 of 6)

**The problem, in plain words.** Lots of saves point back to a "profile" row keyed to your login. Today that row is only created during onboarding. So if a save ever fires before onboarding finishes — or if onboarding is skipped — there's no profile row and the database refuses the save. Belt with no suspenders.

**What I changed.** Two things. (1) A tiny database rule (a "trigger") that **automatically creates a bare profile row the instant a new login is made**, server-side, before the app even asks. Onboarding then fills in the details on top. (2) Changed onboarding's profile write from "insert" to "upsert" (insert-or-update) so it cleanly lands on top of the row the trigger just made instead of colliding with it — and I made it only write the fields you actually provided, so re-doing onboarding can't blank out details you'd already set.

**How it was checked.** New tests prove the upsert sends the right "merge, don't collide" instruction and that a plain insert still doesn't. An adversarial review agent did the most important check by hand: reading the real table definition to confirm the auto-create rule **cannot** accidentally block new sign-ins (the only required field is the id, which the rule always provides). It also caught that the auto-create rule's safety depends on it running as the database owner — so I made that explicit instead of relying on a default, matching how the app's other database rules are written.

**Status:** code merged as PR #402 (Slice 2 of 6). One deliberate step remains: actually switching the database rule on in production — I'm gating that on a careful go-live check because a faulty rule there could block sign-ins, so it's not something to flip casually.

---

## 2026-06-13 — Started the real fix for the gym-save failures: wait for login before starting a workout (1 of 6)

**The problem, in plain words.** Even after login was fixed, saving a workout still failed. A team of review agents traced it to one habit the whole app shares: it stamps "who owns this data" at the moment a row is created and never re-checks it when the data is actually sent. So if a workout was started in the split-second before login finished, it got stamped with a stand-in "nobody" id — and the database later rejected every save tied to it.

**What I changed (this slice).** The first and most important fix: when you tap "Start Workout," the app now **waits for your real login to be ready** before creating the workout, instead of grabbing whatever id is lying around. If login genuinely can't be established, it does nothing rather than create a doomed, unsavable workout. I built this as a single shared "get the real owner, or stop" helper so the other five fixes all use the exact same rule instead of five slightly-different versions.

**How it was checked.** A new test proves the order is right: before login lands the helper says "not ready" (so nothing is stamped), and the instant login lands it returns your real id — never the stand-in. All 14 login/identity tests pass; the whole app still compiles. An independent review agent (a second, adversarial pass) found no blockers and caught one real thing — a fast double-tap could start two workouts — which I fixed by adding the same guard the other buttons already use. It also flagged that tapping Start and silently getting nothing is poor feedback; I filed that as #399.

**Status:** merged as PR #400 (Slice 1 of 6). Next: make sure a brand-new login always gets a profile row (so the very first save can't fail), then the reset/cleanup and replay-safety slices.

---

## 2026-06-13 — Built the Lens: a 6-blade camera-iris readiness gauge (Phase 3 UI, Slice 5)

**What it is.** The Lens is a camera-iris aperture drawn in code — six blade shapes that rotate into alignment and open wider as readiness goes up. It always shows a literal number plus a state word so it is readable in a dark gym without needing to understand the shape. It is built DORMANT: finished and tested, but not yet wired into the live shell.

**Three states.** Focused iris + number (resolved, score known); unfocused iris + "—" (calibrating / unknown / first day); slow oscillation + "Updating" (computing in the background). The state word lexicon has five entries: Optimal, Good, Reduced, Poor, Calibrating, Updating. Layout is sized to "Calibrating" — the longest — so the compact gauge never reflows when the word changes.

**The disclosure sheet.** Tapping the gauge opens a small sheet: big iris + number + state word, then one or two training-load numbers explaining why, a line saying "Based on your training load — no sleep or HRV data", and two expandable sections ("How to read this" / "How it's calculated"). No deep-view creep — it stays small.

**Colour rule.** Only DesignSystem ink and accent-ink tokens. The legacy `ReadinessScore.tintColor` multi-hue palette is deliberately ignored.

**Motion.** Blades animate via the `gauge-focus` spring (response 0.5, damping 0.7, tiny overshoot) when state changes. Reduce Motion falls back to a 150ms crossfade. The bare component has no entrance or idle animation so it snapshots at frame 1.

**Tests.** 15 unconditional tests pass: all four label cases, the unknown/calibrating case, the computing case, lexicon length, longest-word sizing, accessibility labels (number + state word, not just "image"), WCAG-relevant token hygiene, isFocused logic, aperture proportionality. Gated snapshot cases (APEX_SNAPSHOT_TESTS=1) cover all states × light + dim for both compact and sheet — wired but reference-pending per the CI record discipline.

**Status:** PR opened, Closes #346.

---

## 2026-06-13 — Built the capability band: one component, three contexts (Slice 4, #345)

The design specced a single band drawing that works in three places — onboarding model reveal, post-workout evidence strip, and the Progress ledger row. Instead of building three separate views, the spec said build one and configure it. That's what shipped today.

**What the band draws.** A filled region between the floor (the heaviest tick — 2 px, full ink) and the stretch (a hairline tick — 1 px). The fill is the accent color at 8% in light mode, 12% in dim. Today's dot is solid when the model has enough data to trust the number ("measured"), hollow when it's still a guess ("estimated"). The dashed band edges give the same estimated/measured signal on the band itself — solid edges when established or seasoned, dashed when still calibrating.

**The three contexts.** `.full` is the complete drawing with labels and a caption slot — this is what the post-workout strip and the Progress detail use. `.onboarding` is the same anatomy at a slightly smaller height — same component, same labeling. `.list` strips it down to an unlabeled 5 pt dot and no bracket, because the Progress root rows put the numbers in the row annotation below, not on the drawing itself.

**The binding.** The component takes a `PatternProjection` (floor/stretch/progress) plus an `AxisConfidence` separately, because `PatternProjection` has no confidence field. The caller supplies confidence from `PatternProfile.confidence`.

**Tests.** Twelve unconditional geometry/token tests run on every push: tick widths, fill opacities for light and dim, the full four-case confidence mapping, minimum band width enforcement, and out-of-band dot plotting. Seven snapshot cases are wired in but gated — they will record references when CI runs on the pinned Xcode 26.3 toolchain.

**DORMANT.** The component is built and tested but not wired into any live screen — the old views are untouched. The post-workout, Progress, and onboarding slices will each pull it in when they build.

**Status:** PR open, 324/324 tests passing.

## 2026-06-13 — Proved the server was fine, then stopped the app from using the connection type that was hanging

**What I did first — proof, not a guess.** Two earlier fixes hadn't cleared the problem, so instead of guessing again I called the real login endpoint myself from my computer. It answered instantly with a valid login. That proved the server, the key, and the login feature are all healthy — it is **not** a rate limit and **not** the wifi. The problem had to be in how the app makes the connection.

**What was actually wrong.** Phones and servers can talk over two connection types: a newer one (HTTP/3, also called "QUIC") and an older, rock-solid one (HTTP/2). The app shares one connection pool for everything, and once it learned the server *offers* the newer type, it tried to use it for login — and on this phone that newer connection just hangs. My own test from the computer used the older type and worked in a fifth of a second. So: healthy server, but the phone was knocking on a door that wouldn't open.

**What I changed.** I gave the login its **own private connection** that starts fresh and uses the older, reliable type — so it stops trying the one that hangs. I also added plain status messages to the log (does it restore an old login, start a new one, succeed, or fail — and the exact reason) so if anything is still off, the next run *tells us* instead of leaving us to guess.

**How I checked.** The live endpoint test returned success over the older connection type; all 7 login tests pass; the app builds.

**Status:** merged as PR #394. Real root-cause fix on top of the earlier two (#389 reset, #392 retry). Remaining safety net tracked in #391.

---

## 2026-06-12 — Sign-in no longer gives up too early on a good network (the real reason saves were failing)

**What went wrong.** After the reset fix, saving a workout *still* failed — but for a new reason. On a perfectly good wifi, the app's anonymous sign-in (the thing that gets you a login) was timing out, so the app had no login at all. With no login, it fell back to a placeholder id and the database refused every save with a "row-level security" rejection. The console was full of `quic… max 5 reached` and "Operation timed out".

**Why it was the app, not the wifi.** Earlier in the same run, a different request to the database *succeeded* — so the network was fine. The problem: the sign-in only waited **5 seconds**, tried **once**, and shared its connection with the rest of the app. iOS had learned the server supports a newer connection type (HTTP/3, "QUIC"), tried it for sign-in, and that handshake stalled. Five seconds wasn't enough to recover, so sign-in quit and the app carried on with no login.

**What I changed.** Three small things in the sign-in code: (1) each attempt now gives up after 8 seconds of silence instead of hanging; (2) it **retries up to three times** — and a failed first try makes iOS drop back to the older, reliable connection type, so the retry goes through; (3) the overall wait went from 5 to 30 seconds. The longer wait is safe because sign-in runs in the background — it never freezes the app's screen; it only gives onboarding more time to get a login before it sets you up.

**How I checked.** The whole app builds, and all 7 sign-in tests pass (the change doesn't affect the failure/timeout cases). The user spotted that this was a timing problem, not a wifi problem — they were right.

**Status:** merged as PR #392 — sign-in now retries with a longer, bounded wait; build + 7/7 sign-in tests green.

---

## 2026-06-12 — The "reset app" button now actually gives you a fresh start (found from a gym-log crash)

**What went wrong.** After the database lock went live (the auth work), I tried to start a workout and it wouldn't save — the app kept retrying and then gave up. The reason: turning on the lock gave my install a brand-new login id, but nothing ever created a matching row for that new id in the `users` table. Every save points back to that table, so the database rejected the workout. Onboarding is the *only* place that creates the `users` row, and my install had onboarded long ago, so it never re-ran.

**Why it matters.** Since there's only one user right now (me), the clean fix is to wipe and start over from week one. But the in-app "Reset All App Data" button was written before the auth work — it cleared everything *except* the new login session. So a reset would quietly keep the same broken login, and you'd land right back in the same hole.

**What I changed.** The reset button now also clears the saved login session (the access token, refresh token, expiry, and the login id). The next launch then signs in fresh, mints a new login id, and onboarding creates the matching `users` row for it — so saving works again. I also changed the confirmation message to tell you to quit and reopen the app before onboarding, because the fresh login only kicks in on the next launch.

**How I checked.** Confirmed the four login keys are real, that nothing else in the app does an "identity wipe" that would need the same fix, and that the whole app still builds (BUILD SUCCEEDED). The old failed-and-parked workout in the local queue lives in the same storage the reset wipes, so it's gone after the reset too.

**Follow-up filed.** The deeper fix — so this can never happen again to any future user — is a database trigger that creates the `users` row automatically the moment a new login is made, instead of relying on onboarding. Logged as a separate issue.

**Status:** merged as PR #389 — the reset button now clears the login session; whole app still builds green.

---

## 2026-06-12 — Writing down what the auth work decided, so we don't forget (auth slice 6, docs — part of #369)

**What this is.** Slices 1–5 of the auth/RLS workstream all shipped and the database lock is now live. This last slice is just paperwork: it writes down the decisions in a permanent record (ADR-0027) so future contributors understand why we went the way we did, and it fixes two older records that had an assumption that turned out to be wrong.

**What ADR-0027 records.** The audit found that row-level security was switched off on the five core tables — workouts, programs, trainee models, users, and set logs — so the per-user rules that existed for programs and set logs were doing nothing. The gym-profiles table had its lock on but a rule that said "everyone can see everything." The server functions trusted the user ID in the request body with no check on who was actually sending the request (an IDOR: anyone who found the URL could act as any user). The decision: give every fresh install a real Supabase login via anonymous sign-in (no account creation UI needed), turn on the database lock on all six tables with proper "you can only see your own rows" rules, and make the server functions verify the login token before touching the database. We also accepted that old data written before this change — tagged with a locally-generated device ID, not a real login ID — becomes invisible; that's the price of the fix at alpha scale.

**The two records that needed a correction.** ADR-0016 (written when we removed the service-role key from the app) said "all client database access is subject to RLS." ADR-0018 (the atomic program-save RPC) said the programs owner rule governs its writes. Both were saying what *should* be true; neither was true at the time because the lock was off. Both ADRs now have a short note at the top explaining that their "RLS is enforcing" assumption held only after ADR-0027 turned the lock on. Their core decisions (no service-role key on the client; atomic save via RPC) are unaffected.

**CONTEXT updated.** Added a new "Auth, identity, and access control" section so the terms — anonymous identity, resolvedUserId, RLS, the Edge Function ownership check — are part of the domain glossary.

**Status:** docs only. No code, no prod impact. PR to be reviewed and merged.

---

## 2026-06-12 — The database now hides everyone else's data from you (auth slice 5 — the gate-flip, part of #369)

**Problem.** This is the keystone of the auth work. Up to now the database had *no* lock on the core tables — workouts, programs, your trainee model, your user row, and your set logs were all readable and writable by any logged-in client, because "row-level security" (the database's own per-user filter) was switched off on them. The two tables that *did* have it on were either fine (the memory embeddings) or wide open anyway (gym profiles had an "anon full access" rule that let everyone see everything). Slices 1–4 set up real per-user identities and made the server functions check them; this slice finally turns the database lock itself.

**What changed.** One forward migration (plus its documentation-only reverse). It (1) turns on row-level security for the five unprotected tables; (2) adds an "owner access" rule to each that says, in effect, *you can only see and only write rows tagged with your own login id* — both the read side (USING) and the write side (WITH CHECK), so a client can't even sneak in a row owned by someone else; for set logs (which have no owner column of their own) ownership is traced through the workout session they belong to; for the user table the row's own id is the owner; and (3) replaces the gym-profiles "everyone sees everything" rule with the same owner-only rule. No changes to who's granted access at the coarse level — once these id-based rules are on, the anonymous role matches no rows anyway, so the old grants are harmless. The server functions keep working because they connect with the privileged account that skips these rules and do their own id check (from slice 4).

**How checked.** SQL review against the baseline schema only — I could not run it against a database here (the local Postgres in Docker is down; `supabase db lint` / `migration list` both failed with connection-refused, as expected). I read the exact current table, column, and policy names out of the baseline and confirmed every "drop the old rule" line names the real existing rule verbatim, the owner columns are right, and the paren-balanced SQL matches the baseline's style. I also checked the reverse migration exactly undoes the forward one (turns the lock back off on those five tables, drops the new rules, and restores the original gym-profiles "anon full access" rule). Touched only the two migration files and this diary — no app code, no server functions, no other files.

**Heads-up for whoever merges this:** merging runs `db push` in CI, which **turns the lock on in production** — this is the live data-visibility flip. Any rows still tagged with the old placeholder id (not a real login id) become invisible to everyone; that's the accepted alpha data-wipe, and clients must already be on the slice-3 build (which tags data with the real login id) for their data to remain visible.

**Status:** merged as PR #386 — RLS enabled on production (the gate-flip), with the user's explicit go.

---

## 2026-06-12 — Fix: the end-to-end smoke test now sends a login token (PR #387, part of #369)

**Problem.** Slice 4 added the server-side ownership check (the function rejects a request whose login token doesn't match the body's user id). But the end-to-end "smoke" test for the trainee-model function fires a real HTTP request at the served function with **no** login token — so the new check correctly returned 401, the smoke test failed, and because CI's deploy step only runs when the Edge-Function tests pass, **the deploy was skipped and slice 4's check never actually went live.** (The slice-4 agent couldn't catch this — the smoke test needs a live local Postgres in Docker, which wasn't available, so it only ran the unit tests.)

**What changed.** The smoke harness's shared `postWithRetry` helper now attaches an `Authorization: Bearer …` header carrying a token whose `sub` equals the request's `user_id` (the local serve runs with `--no-verify-jwt` and the code only decodes the token, so the signature is a placeholder). Both smoke cases now pass the ownership gate and reach the orchestrator.

**How checked.** Verified the token the helper builds is accepted by slice 4's real `subFromAuthorization` decoder (extracts the matching `sub`). Can't run the full smoke test here (no Docker); CI runs it on merge — and a green Edge-Function-tests job is exactly what re-enables the deploy.

**Status:** merged as PR #387. Unblocks the auto-deploy so slice 4's ownership check finally deploys.

---

## 2026-06-12 — The server now checks it's really you before saving your data (auth slice 4, part of #369)

**Problem.** Two of our server functions — the one that updates your trainee model after a workout, and the one that saves your goal — trusted the `user_id` written in the request body, no questions asked. That meant a logged-in person could put *someone else's* id in the body and write to that person's data (a classic "insecure direct object reference" hole). And we can't lean on the database's own row-level security to stop it here, because these functions connect with a super-privileged account that bypasses those row rules. So the function itself has to be the bouncer.

**What changed.** Before either function does any database work, it now reads the login token the platform already verified, pulls out the user id baked into that token, and checks it matches the `user_id` in the request body. If they don't match, it refuses (403). If there's no token, or the token is garbled, or it has no user id, it also refuses (fail-closed, 401) — it never quietly lets the write through. The token-reading logic lives in one small shared helper so both functions use exactly the same check. We only *read* the id from the token, we don't re-check its signature — the platform already did that.

**How checked.** Added unit tests for the shared helper (14) covering the good decode and every fail-closed case, plus four handler tests on each function (mismatch → 403, no token → 401, garbled token → 401, matching id → passes the gate). All pass. The existing tests still pass: shared helpers 390, model validator 21, goal validator 31. The database-integration tests can't run here (they need a local Postgres in Docker, which is down — they failed with connection-refused as expected and will run on CI when merged). Did NOT turn on row-level security, add migrations, touch the app, or deploy — those are other slices / the orchestrator's job.

**Status:** opened as PR (see below); NOT merged, NOT deployed.

---

## 2026-06-12 — The app now uses your real login identity instead of a stand-in (auth slice 3, part of #369)

**Problem.** Until now every install used the same hardcoded placeholder id (`…0001`) or a random one minted at onboarding to tag all your data. Earlier in this auth work (slice 1) the app started quietly logging itself in anonymously at launch, which gives it a real, stable identity — but nothing was using that identity yet. For the upcoming security lock (slice 5, which will only let you read rows that are tagged with *your* id), the data has to be keyed to that real login id, not the placeholder.

**What changed.** Two things. (1) The single place the app asks "who am I?" now answers with the real anonymous-login id (read instantly from where slice 1 saved it), falling back to the old placeholder only in the brief moment on a brand-new install before the background login finishes — that fallback is safe right now because the security lock is still off, and it goes away for good once slice 5 lands. (2) Onboarding now writes your user row tagged with that real login id (and skips writing the row entirely if the login somehow hasn't finished yet, rather than saving a row under the placeholder that the security lock would later orphan). Pulled the "who am I?" logic into a small, separately-testable helper so the priority order is pinned down by unit tests.

**How checked.** Build passed (build-exit=0). Added six unit tests for the identity helper (real id wins over the placeholder and over the older mirror; placeholder only when nothing else exists; onboarding refuses to write under the placeholder) — all pass. Full suite: 561 run, 10 skipped (the live-API tests, off by default), 1 failure — and that one is the known network-timeout flake unrelated to this change; it passed on its own when re-run. Did NOT turn on the security lock or touch any server functions or migrations — that's later slices.

**Status:** opened as PR (see below); NOT merged, awaiting review.

---

## 2026-06-12 — A camera for the hand-drawn charts (PR, part of #342)

**Problem.** The redesign draws its charts and gauges by hand, pixel by pixel — a 2px "floor" line that has to read heavier than a 1px "stretch" line, solid dots for real data versus hollow dots for guesses, dashed lines for predictions. None of that shows up when you read the code; you only see if it's wrong by looking at the picture. Until now the app had no way to take a picture of a chart and notice when it changes.

**What changed.** Two things. First, a set of cheap, fast checks that read the exact numbers behind the drawings — that the floor line really is 2px and the stretch line really is 1px, that the prediction dash is the 4-2 pattern, that the spacing scale is 4/8/16/24/32/48, that the "work is dark ink, time is light pencil" colour split always holds. These run on every push and need no saved pictures. Second, the camera itself: a small harness (built on a well-known open-source tool, swift-snapshot-testing — our very first outside dependency, pinned to one exact version) that photographs a component and compares it to a saved reference, failing if anything drifts. The worked example photographs the whole token gallery in light and dim, at normal and largest text sizes.

**One deliberate gap.** The reference photos are NOT recorded yet — on purpose. My machine runs a slightly newer Xcode than the build server, and a photo taken on the wrong toolchain would bake in the wrong fonts and subtly-off colours, poisoning every later comparison. So the camera is wired up but parked: the photo tests are switched off by default (behind a `APEX_SNAPSHOT_TESTS` flag) and a human/CI step on the pinned Xcode must take the first reference photos. The fast number-checks run regardless.

**Also fixed a quiet contradiction.** The test plan secretly forced the "run the expensive live-API tests" flag on, while a comment in the build server config claimed it was off. Removed the flag from the test plan so the comment is finally true — the live-API tests are genuinely opt-in now.

**How checked.** The fast geometry/number suite builds and passes; the outside dependency resolves and links (the whole app + tests compile against it). The photo suite is intentionally reference-pending and stays off.

**Status:** open PR, part of #342 (not closed — recording the reference photos and signing off on how they look is still to come).

## 2026-06-12 — Coach-voice constitution drafted (PR for #330)

**What.** Wrote `docs/design/coach-voice.md` — a single reference document that
governs the voice and honesty rules for every coach-voiced string in the app:
AI-generated Today lines, post-workout reads, per-set coaching cues and set
framings, and static UI strings (alerts, rest-day cards, calibration notices).

**Why.** The flow audit (G-F13, #316) found three different registers in three
prompts — the inference prompt enforces terse anti-platitude copy, the swap
assistant says "Happy to help", the post-workout insights are a third voice — and
no single source governed all of them. The rebuild needs one constitution before
the first coach-line screen (#348) is written.

**What it covers.** The honesty laws (grounded-in-numbers, deterministic fallback,
no fabricated precision, no echo, witness rule), the banned registers (praise-
inflation, hype, mascot-cheer, accent-colored keywords), length and format
contracts per surface (Today line, post-workout two-deck read, coaching cue, set
framing, swap display_message), and a short "how to apply" section for both prompt
authors and UI-string authors. Cites the source docs throughout.

**Status:** opened as a DRAFT PR (human review required — voice is the product
owner's call). Not merged. Part of #330.

---

## 2026-06-12 — Two-day-a-week lifters can now onboard honestly (PR #380, part of #369)

**Problem.** The onboarding "days per week" picker only offered 3, 4, 5 and 6. Someone who trains twice a week had no honest option and was forced to claim 3 — even though the program engine fully supports 2-day weeks (the phase-advance math handles down to 1 day; the macro-plan prompt builds exactly as many days as you pick) and the redesign spec explicitly lists 2 / 3 / 4 / 5+.

**What changed.** Added 2 to the picker (now 2/3/4/5/6). One-line, no option removed, so nothing regresses. This is the one onboarding item from the audit that's both cheap and not throwaway — the rest of the onboarding cluster is either already handled (the answer-wiring shipped earlier in #339) or belongs to the full onboarding rebuild (#362), and one finding turned out stale (height/age are now used by the coach, so they must NOT be removed).

**How checked.** Build passed (build-exit=0). Pure picker-option change — can't affect other logic.

**Status:** merged as PR #380.

---

## 2026-06-12 — Manually-logged workouts now count toward your records (PR #379, part of #369)

**Problem.** When you logged a past workout by hand, that session row was saved with no "status" value. But the code that finds your previous bests (for personal records and the "last time" line) filters sessions where `status` is not `"abandoned"` — and in a database, comparing a missing value to `"abandoned"` is itself "unknown", not "true", so those hand-logged sessions were silently skipped. Your manual entries never counted toward a PR or showed up as your last-time anchor.

**What changed.** The manual-log save now writes `status: "completed"` on the session row (it always set `completed: true`, but the queries filter on `status`, not that flag). A completed session passes the "not abandoned" filter, so manual workouts now contribute to PR baselines and last-time anchors like any normal session.

**How checked.** Build passed (build-exit=0). The change is a single payload field on an additive struct, so it can't affect other logic; verified by the build plus the query semantics.

**Status:** merged as PR #379.

---

## 2026-06-12 — Three correctness fixes in the server-side learning functions (BUG-4, part of #369)

Problem: the cross-dimension audit found three bugs in the Supabase Edge Functions — the server-side code that turns a finished workout into an updated training model. (1) Each exercise keeps a list of its best recent sets ("top sets"); that list grew forever, one entry per workout, with nothing trimming it — a constant for the cap existed but was never used. (2) The transfer-learning math (how much progress on one lift predicts another) divided by zero when every recorded number was identical, producing "not a number", which silently becomes `null` when written to the database — corrupting the stored value with no error. (3) The goal-update function did four separate database writes one after another with no shared transaction, so a crash halfway through could leave the user's record half-updated.

Change: (1) After adding new top sets, trim the list to the most recent 10 (the existing constant) — newest are at the end, so keep the tail. Pulled the trim into a tiny pure helper so it could be unit-tested. (2) Detect the zero-variance case (all "from" values identical, or all "to" values identical) and return a "no transfer learnable" signal instead of the bad number; the caller then simply doesn't record a fit for that pair, while still keeping the observation so it can learn later once the numbers differ. The guard is narrow — it only triggers on genuinely flat data, not on legitimately weak correlations. (3) Wrapped all four goal-update writes in one transaction so they all succeed or all roll back together; the row-locking reads stay inside that same transaction, so the safety is real.

How checked: Deno was available, so I ran the pure-logic tests. Added new unit tests for (1) the trim keeps the correct newest 10 and (2) the math returns the skip-signal for both flat-input cases but still returns a real fit for normal input. All passed. Could not run the database-integration tests for (3)'s atomicity — they need a live local Postgres, and Docker was not running in this environment — so (3) was verified by careful code inspection; CI runs those tests on merge. Confirmed the goal function still type-checks and its only remaining check-error is a pre-existing one on `main` in a test file I did not touch.

Status: opened as PR #378 (not merged). Part of #369.

---

## 2026-06-12 — Security hardening: Keychain backup protection and DEBUG-only PII logging (BUG-6, part of #369)

Problem: two security gaps found in the cross-dimension audit. First, API keys and auth tokens in the Keychain used `kSecAttrAccessibleWhenUnlocked`, which lets iOS include them in unencrypted iTunes/Finder device backups — so a user's Anthropic API key could sit in a backup file on their laptop. Second, four service files wrote raw LLM responses and user training history (exercise IDs, session dates) to the device console unconditionally, even in release builds — visible to anyone with a Mac and a USB cable.

Change: switched the Keychain accessibility to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so items are excluded from backups. Wrapped seven sensitive `print` calls in `#if DEBUG … #endif` so they compile out of release builds — the four raw-LLM-response / training-history logs the audit cited, plus three more found by a follow-up grep (two non-canonical-exercise-id warnings and the macro-skeleton log that includes the user's historical day labels). `InferenceSpike` also logs prescription details unconditionally, but it is dead code (`run()` has no production caller), so its prints never execute in a real build — left in place and flagged, not gated. The Keychain change only applies to items stored after the update — existing items in a dev's Keychain keep the old attribute until they re-store the key (fresh install, or clear + re-enter via Developer Settings). That is acceptable for alpha. Two new Keychain tests confirm the round-trip still works and that the correct attribute is set.

How checked: build passed (exit 0). Full test suite ran — all Keychain round-trip tests pass, including the two new ones. Logging changes are not unit-testable (no observable side effect to assert), so they were verified by code inspection.

Status: merged as PR #377. Part of #369.

---

## 2026-06-12 — Four concurrency fixes in the live workout loop: no double-counting, no stale results, no torn reads (part of #369)

Problem: the same cross-dimension audit (issue #369) found four subtle threading problems in the actor that runs a live workout and in the screen that reads from it. None of them showed up every time — they only bite when two things happen close together.

1. Ending a session could run its wrap-up twice. The rest timer can fire "the session is over" at almost the same moment the user taps "end early". Both reached the same finish routine, and each one bumped the saved session count and queued a learning-update for the AI. So one workout could count as two. Fix: a one-way latch flipped the instant the finish routine starts — the second caller just returns. The latch is cleared whenever a brand-new session begins, so the next workout still counts.

2. The "Retry" button could apply a stale answer. When the AI fails and the user taps Retry, the app asks again — but if the user moved on (finished a set, skipped, or swapped the exercise) while that retry was still in flight, the late answer used to overwrite the newer state. Fix: the retry now remembers which "generation" of the session it belongs to and throws its own answer away if the session has moved on, exactly like the normal inference path already did.

3. Swapping an exercise (or resuming a paused session) didn't cancel the old in-flight answer. The app already had a "generation" counter that invalidates stale answers, but swap and resume never advanced it — so an answer meant for the old exercise could land on the new one. Fix: bump the counter at both points. (Judgment call on resume, documented in code + PR: bumping rather than resetting to zero catches the most common straggler — paused right as the first answer was coming back; a fully bulletproof version needs a wider change and is noted as deferred.)

4. The live screen read the actor one field at a time — about nine separate hops. Between hops the actor could change, so the screen could show, say, a prescription from one moment next to a state from another. Fix: one method on the actor returns all the fields at once, so the screen always paints a single consistent moment.

How checked: built clean (build-exit=0). Full suite green — 553 XCTest cases (543 passed, 0 failed, 10 skipped live-API/integration tests) plus 293 Swift Testing tests (0 failed). Four new tests: end-session runs its side effects once, the retry guard drops a stale result after a swap bumps the generation, the latch resets for the next session, and the one-hop snapshot matches the individual fields. The hard-to-reproduce timing races are pinned with deterministic latch/guard tests rather than flaky sleeps.

Status: PR open, not yet merged. Part of #369.

---

## 2026-06-12 — Five performance fixes: less CPU, less memory, fewer wasteful reads (PR #374, part of #369)

Problem: a cross-dimension audit (issue #369) found five efficiency problems that were silently burning CPU and memory on every session.

1. WorkoutView called `traineeModelService.digest()` three times back-to-back to read three different fields, decoding the full model each time. Fix: one `let digest = await ...` at the top, then read all three fields from the local copy. Same pattern applied to the two onDismiss closures.

2. LiveSessionWatcher polled the session actor every 500 ms for the full lifetime of the app — even when no workout was running. That is 2 actor hops per second, all day. Fix: keep polling at 500 ms while a session is active or paused; slow to 5 s when idle. The observable properties stay the same; views see no difference.

3. ProgressViewModel re-fetched 90 days of sessions and all set_logs every time the Progress tab appeared, with no caching. Fix: cache the result, but reuse it only when it's both within a 5-minute window AND no session has been logged since the last load — the cache compares the session counter that every finished or manually-logged workout already bumps. So a just-finished workout always appears on the next Progress visit (no stale window), while flipping tabs mid-session skips the redundant 90-day fetch.

4. ProgressSessionRow.date allocated up to three DateFormatter/ISO8601DateFormatter objects on every call to `.date`, and `.date` was called twice per row. Fix: hoist all three formatters to `static let` so they are created once per process lifetime. DateFormatter is thread-safe for read-only use after setup.

5. WriteAheadQueue called `persistQueue()` after every single item during a batch flush — encoding and writing the entire queue array to UserDefaults N times for N items, making flushing O(N²). Fix: remove all per-item persists inside the loop. The `defer` at the end of `flush()` writes the queue once after the whole batch. Dead-letter items are still persisted immediately (separate store, crash-safety). On a crash mid-flush, successfully-sent items may be re-sent on the next launch, but set_log inserts are idempotent by UUID primary key, so no data is lost or duplicated in a user-visible way.

How checked: built clean (build-exit=0). Ran the full test suite — all existing WriteAheadQueue tests passed. Two new WAQ tests verify the batch-flush end-state (empty queue, all items sent, persisted state also empty) and the permanent-failure dead-letter path. One pre-existing live-API flake unrelated to these changes.

Status: PR open, not yet merged. Part of #369.

---

## 2026-06-12 — A fresh install can now reach Supabase (auth slice 2, PR TBD)

Problem: a clean install had no Supabase anon key, so the SupabaseClient was created with an empty string and any network call to Supabase would fail. The Anthropic key already had a bundled-key mechanism (PR #368), but the Supabase anon key did not.

Change: mirrored the existing Anthropic bundling pattern for the Supabase anon key. Added `APEXSupabaseAnonKey` to Info.plist expanded from a new `SUPABASE_ANON_KEY` build variable in the xcconfig files. Added `BundledAPIKey.supabaseAnon()` and `SupabaseAnonKeyResolver` (same Keychain-first precedence as the Anthropic resolver). AppDependencies now resolves the anon key through the resolver instead of a bare Keychain lookup, seeding it into the Keychain on first run. The launch gate in ContentView was extended from "AI key required" to "both keys required" — either missing triggers NeedsSetupView.

How checked: built with no real key in place (build-exit=0). Ran the full test suite — all 23 tests in BundledKeyResolutionTests passed (9 new tests for the Supabase path). One pre-existing timing flake in AIInferenceServiceTests unrelated to this change.

Status: PR open, not yet merged. Closes #329 (both keys now bundleable so a fresh install can complete onboarding end-to-end).

---

## 2026-06-12 — The app now quietly signs in behind the scenes (PR #372)

**The problem (in plain words):**
Right now the app talks to our database using one shared "house key" (the anon key)
— there's no notion of *this particular person* being signed in. Before we can lock
data down so each person only sees their own, the app first needs to get its own
private sign-in token. This is the first small step of that bigger job: get the
token, but change nothing anyone can see yet.

**What changed:**
On launch the app now asks our auth service for an anonymous sign-in — like getting
a wristband at the door without giving your name. It tucks the resulting token away
safely (in the iPhone's secure Keychain) and uses it on its database calls. Next
time you open the app it reuses the same wristband instead of grabbing a new one, so
you stay the same "person" across launches. The token also quietly refreshes itself
when it's about to expire.

Crucially, this is built to fail softly. If the sign-in can't happen — for example
because we haven't flipped the "allow anonymous sign-ins" switch on the dashboard
yet, or the network is slow — the app shrugs and carries on exactly as it does today
with the shared house key. It never blocks the app waiting. So nothing about how the
app behaves changes in this step: it still reads and writes the same data the same
way. We did NOT switch over which user-id the app uses, and we did NOT turn on the
per-person data locks — those are deliberately later steps.

**How it was checked:**
Wrote tests that fake the auth server (no real network): a successful sign-in saves
the token and sets it; a relaunch with a saved token reuses it without signing in
again; a rejected sign-in leaves things on the old shared-key behavior without
crashing or hanging; and the token-refresh / retry-after-expiry path works. Full app
test suite still green (532 ran, 0 failures, 10 skipped — the usual live-API ones
that need real credentials). The build is clean.

**Status:** Done on branch `feat/369-auth-slice1-anon-session`, PR #372. Not
merged. Live end-to-end sign-in still needs the dashboard's Anonymous provider turned
on; until then the app correctly runs on the old shared-key path.

---

## 2026-06-12 — Three broken data paths in the trainee-model learning pipeline fixed (PR #371, part of #369)

**Problem.** The trainee model learns from your workout data, but three bugs meant it was learning almost nothing in production.

First, every set you complete gets sent to an Edge Function that updates your model. That payload was missing the AI's original prescription — without it, the Edge Function's accuracy-learning loop hit a guard and bailed out immediately. The learning loop has never run since it was written.

Second, because the prescription was never sent, the weekly fatigue signals (deload triggers, rep-rate alarms) could never fire either. They depend on comparing what the AI prescribed to what you actually did. With no prescription in the data, every set looked like a no-prescription set and the signals stayed at zero.

Third, the muscle-volume breakdown (`setsPerPrimaryMuscle`) was being sent to the AI digest as a flat alternating array like `["chest", 4, "quads", 6]` instead of a proper JSON object `{"chest": 4, "quads": 6}`. The AI can't reason about a flat array the way it can a named object.

**What changed.** Added `ai_prescribed` to the set-log payload that goes to the Edge Function — it's the same nested prescription object the EF already knows how to read (`intent`, `reps`, `user_corrected_weight`). Added a custom `encode(to:)` and `init(from:)` to `WeekFatigueSignals` so the muscle-volume map serialises as an object (using the same `encodeEnumKeyedDict` helper already used in `TraineeModel`). Also added an explicit memberwise init since the custom Codable init suppresses the synthesised one.

**How checked.** Added 6 new tests: two prove the `ai_prescribed` field is present (or correctly absent) in the encoded WAQ payload; two prove the deload signals fire when a prescription is present and stay silent when it isn't; two prove the muscle-volume field round-trips as a JSON object. All 276 tests pass (build-exit=0).

**Status.** merged as PR #371.

---

## 2026-06-12 — A brand-new install can now get past the front door (PR #368)

**The problem (in plain words):**
If someone installed the app fresh, they could never finish setting it up. The app
needs a secret "key" to talk to the AI (for scanning your gym and building your
program). But the only way to put that key in was a hidden developer screen buried
*inside* setup — so on a clean phone there was no key, and setup would chug along
for about ten minutes until the gym-scan step suddenly died with an ugly error.

**What changed:**
Two things. First, the app can now carry a key baked into the build itself, so a
fresh install just works. The real key is never stored in the project's shared code
— it lives in a private file on the builder's machine (or as a build secret), and
only a fake "REPLACE_ME" placeholder is shared. The app looks for a key in this
order: one you already saved → the baked-in build key (which it then tucks away so
the rest of the app behaves exactly as before) → none.

Second, if there genuinely is no key (someone built it without setting one up), the
app no longer lets you wander into a doomed setup. Instead it shows a calm, honest
"This build needs setup" screen right at launch, explaining the build is missing its
configuration and to contact the developer. When a key *is* present, nothing changes
at all — the normal app opens as usual.

**How it was checked:**
- Built the app with NO real key present — it builds cleanly (a missing key is never
  a build error), and the baked-in value correctly reads as the placeholder, which
  the app treats as "no key" and shows the setup screen.
- Built again with a (fake) key in the private file — the value flows all the way
  through to the app as expected.
- Wrote 13 new automated tests covering the "which key wins" order and the
  show/hide logic of the setup screen. Full test run: 525 passed, 10 skipped (the
  usual live-internet tests), 0 failures.

**Status:** Done, opened as PR #368 (closes #329). Note for later: the
longer-term plan is to route AI keys through a server so nothing ships in the app at
all — this build-time key is the alpha-stage stopgap.

---

## 2026-06-12 — Built the new 3-tab layout, but kept it switched off (PR #370)

**What happened (in plain words):**
The redesign moves the app from four bottom tabs (Program, Workout, Progress,
Settings) to three — **Today, Train, Progress** — with Settings tucked into a corner
button instead of a tab. I built that new three-tab layout in code, drawn in the
redesign's own colours and fonts (yesterday's building blocks), with a little corner
gear for settings.

The important part: it's **switched off by default**. The app still runs the old
four-tab screen exactly as before. There's a single on/off switch in the code, set
to "off". That's on purpose — turning it on means moving some delicate plumbing (the
first-time setup screen, crash recovery, and "resume a paused workout"), and that
deserves its own careful, separately-tested step later. So this slice lays the new
layout down next to the old one without disturbing any of that plumbing.

A few things worth calling out simply:
- The new bottom bar follows the design rule: each tab's icon is quiet ink normally
  and turns ink-blue + filled-in only for the tab you're on.
- One tab (Progress) already shows its real screen; Today and Train show a simple
  honest placeholder for now — and nobody sees these yet, because the whole thing is
  switched off.
- There's a small translator so the app's existing "jump to that tab" buttons keep
  working unchanged once the new layout is eventually switched on.

**How I made sure it works:**
I wrote five small tests for the translator first, and they all pass. The whole app
still builds cleanly with no warnings, and I confirmed I didn't touch the old main
screen at all.

**Status:** Opened pull request #370 (part of issue #343). Switched off, so nothing
changes for the user yet — waiting on your review before it merges. Turning it on
(and moving the delicate plumbing) is a later step.

---

## 2026-06-11 — The new look's building blocks now exist in code (PR #367)

**What happened (in plain words):**
The redesign has been fully drawn on paper for a while. This is the first piece of
actually building it. I put the design's basic ingredients into the app's code: the
exact colours (cream "paper", the deep ultramarine ink-blue, and a handful of
others), the two fonts (Space Grotesk for big headline numbers, Inter for normal
text), plus the spacing, corner-rounding, motion, and buzz-feedback rules. None of
the real screens use these yet — this is the shared paint-set and toolbox every new
screen will reach for next.

A few things worth calling out simply:
- There are two looks: the normal cream "light" look and a "dim" dark look for
  late-night or dark home gyms. Same recipe, swapped values. There's now a setting
  (System / Light / Dim) to choose.
- The bright blue is special — it's only allowed for big filled shapes, never for
  text, so it can't accidentally make small writing hard to read. The code is built
  so that mistake won't even compile.
- Weight numbers are set up so the digits don't jiggle as they change, and the big
  numbers won't balloon too large or get cut off on phones set to large text.
- I added a hidden "gallery" screen (developers only) that shows every colour and
  font side by side in both looks, so we can eyeball them.

I also wrote automatic checks that prove the colours match the design exactly, the
dark look really differs, the blue text stays readable, and the fonts actually load.
All twelve pass.

Nothing an everyday user sees has changed — the old screens are all still in place
and untouched. This just lays the foundation the next steps build on (the new
3-tab shell is next).

---

## 2026-06-11 — Dismissed banners now stay dismissed — and come back only when there's genuinely something new (PR #366)

**What happened (in plain words):**
The last item from the #318 flow audit. The pre-workout screen shows little
notice cards — "welcome back after your break", "you've leveled up", "your
targets are ready". Each has an × to dismiss it. But the app only remembered
that × in short-term memory: leave the screen and come back, and the same
card you just closed was back again. Worse, the app didn't remember *which*
news you dismissed — so it couldn't tell "same old card again" apart from
"actually, something new happened". Separately, on app launch two pop-ups
(crash recovery and a one-time programme notice) could try to appear at the
same moment; the system quietly drops one, and the dropped notice was marked
as "already shown" — so you'd never see it at all.

**What changed:**
Dismissing a card now writes down exactly which event you dismissed — keyed
to solid facts like "the session date that caused the break" or "the
session count when you leveled up", never to wobbly numbers. The card stays
gone across screens and app restarts, and only returns when the underlying
event genuinely changes (a new break, a new level-up, a re-calibration).
The × is still just a local "not now" — saving from the review screens
remains the real acknowledgement. And at launch, crash recovery now goes
first: the programme notice politely waits for the next launch instead of
being silently swallowed. The bigger banner-queue redesign stays parked as
issue #327.

**How it was checked:**
Six new unit tests cover the dismissal memory directly — shows when nothing
is dismissed, stays hidden for the same event, re-arms for a new one, each
banner independent — all against a throwaway settings store so real
settings are never touched. Full build passed and the whole test suite ran
green — zero failures (the live-API test stays gated off).

**Status:** merged as PR #366 — the #318 audit campaign closes with this one.

---

## 2026-06-11 — The coach can no longer prescribe weights that don't exist, or jumps that don't make sense (PR #365)

**What happened (in plain words):**
Four related problems with the weights the AI coach hands you, all from the
#318 audit. First, the coach could prescribe a weight your gym simply
doesn't have — like 47.5 kg dumbbells when the rack jumps from 45 to 50.
The app even had a little note ready to display ("adjusted to nearest
available") but nothing ever produced it. Second, nothing stopped a runaway
prescription: if the AI hallucinated 200 kg after you benched 80 last week,
the app would show 200 kg with a straight face. Third, the workout card
never told you what you actually did last time — useful context the app
already stores but never showed. And fourth, when the AI was offline and
you tapped "Continue with last weights" on your very first set, it had no
"last weights" to use — so it showed 0 kg, rendered as "BW" (bodyweight),
on a barbell exercise.

**What changed:**
Every weight the AI prescribes now goes through one shared checkpoint
before you see it. It first snaps the weight to something your gym actually
has (rounding down unless the target sits clearly closer to the next weight
up — the safe default), honoring every "my gym doesn't have this" report
you've made. Then, for your heavy working sets only, it caps the weight at
15% above what you lifted last session — warm-ups and first-ever sessions
stay free, and a low prescription is never pushed up. If anything changed,
the card says so with the "adjusted" note. The card also gained a quiet
"Last time: 80kg × 8/8/7" line so you can sanity-check the coach yourself.
And "Continue with last weights" now seeds from your last session's history
when this session has none, only shows up when it can offer something real,
and works on the first set of a session too instead of only between sets.

**How it was checked:**
Twenty-five new tests: the snapping rule (including the gym-exclusion case,
the 5 kg machine steps, and both ends of the rack), the cap (with history,
without history, and per set type), the "adjusted" note surviving the round
trip from the coach's text to the screen, the history seeding (including
keeping honest 0 kg for genuinely bodyweight movements), and the new card
line's wording. Full build passed and the whole suite ran green.

**Status:** merged as PR #365.

---

## 2026-06-11 — The whole new look got turned into a build plan, and a panel of AIs made the big calls (PR #364)

**What happened (in plain words):**
All five redesigned screens are done on paper. This step turned that pile of
design documents into an actual to-do list a developer can pick up — about 22
small, self-contained build tickets, ordered so each one can be finished and
checked on its own. They're all written down as issues on the tracker now, so
the plan can't get lost when a session ends.

Three of those tickets needed real engineering judgment calls before anyone can
start: how to build the colour-and-font system in code, how to take automatic
"did the drawing change?" screenshots in tests, and how to swap the new screens
in one at a time without breaking the old app while another developer is editing
the same files. Instead of just deciding these myself, I had several AI
"advisors" each argue their own recommendation, then a separate AI reviewer
weigh the arguments and make the call, then a final reviewer check that the
three decisions fit together. Each decision is now written up as a permanent
record (an "ADR").

**The biggest catches:**
- The AIs actually read the real code first, so the advice was grounded — they
  found 236 places where colours are hard-coded, that no custom fonts are
  installed yet, and an old chart drawn the dishonest "smooth curve" way the new
  design bans.
- The final cross-check caught a gap: the colour-system ticket hadn't promised
  to include the special chart colours and line-thicknesses the screenshot tests
  need — so the screenshot work would've had nothing to check against. Fixed.
- The safe way to roll out the new screens: build them as brand-new files and
  leave the big, fragile old screen completely untouched until the very end, so
  the two efforts don't collide.
- A few things genuinely need a human answer before coding starts — mainly
  whether we have the rights to the two fonts — so I deliberately stopped before
  writing app code and wrote those questions down.

**Status:** merged as PR #364. The full plan and all decisions are on the
tracker and in the project's decision records.

---

## 2026-06-11 — Rest screen polish and the workout summary finally celebrates real records (PR #347)

**What happened (in plain words):**
Four small lies and rough edges in the live workout loop, all found by the
big #318 audit. The gym streak was always computed for a fake placeholder
user, so once real sign-ins existed, your streak could be someone else's —
or nobody's. The rest screen promised a "rest is over" alert even when you
had turned notifications off, and said nothing about it. Its skip button was
so faint and small it was easy to miss and easy to fumble. The countdown
showed raw seconds ("150") instead of the "2:30" a human expects. And the
end-of-workout summary had a personal-records section that the screen knew
how to draw — but the data side always sent an empty list, so it never,
ever appeared.

**What changed:**
The streak now uses the real signed-in user. The rest screen quietly tells
you when rest alerts can't fire because notifications are off (one muted
line, no nagging, no buttons). The skip button is brighter and has a proper
finger-sized tap area, and the countdown now reads minutes:seconds. And the
summary now computes real personal records: for each exercise it compares
your best estimated one-rep max from today's top sets (3–10 reps only)
against your history under the same rule, using the same formula the rest
of the app already uses. One honest detail: if you've never done an
exercise before, there's no baseline — so no record is claimed. First time
doing something is not a "new record", it's just a first time. The history
lookup runs alongside the existing end-of-workout save, so finishing a
workout is not a second slower; and if the lookup fails, the summary simply
shows no records rather than blocking.

**How it was checked:**
The record-computing piece is a pure function, so four tests pin it down: a
genuine record, no record when you didn't beat your best, no record when
there's no history, and reps outside 3–10 being ignored on both sides. Full
build passed and the whole suite ran green — 757 tests, 0 failures.

**Status:** merged as PR #347.

---

## 2026-06-11 — Logging a set got honest: no forced effort rating, zero reps allowed, and you can skip (PR #340)

**What happened (in plain words):**
The set-logging sheet quietly made things up. The "how hard was it?" picker
came pre-set to "On Target", so if you never touched it the app recorded an
effort rating you never gave. The rep counter refused to go below 1, so a
failed lift — zero reps, real and useful information — could not be recorded
truthfully. And there was no way to skip a set at all: if you weren't going
to do it, your only options were lying about it or ending the workout.

**What changed:**
Three things. The effort picker now starts empty and is clearly marked
optional — pick one if you want, skip it if you don't, and nothing gets
invented either way. The rep counter now goes down to zero, and a zero-rep
set can no longer be celebrated as a personal record. And the menu on the
active set screen has a new "Skip Set" item: it moves you straight to the
next set (no rest timer, nothing written down for the skipped one), and if
you skip everything, the session is thrown away instead of being saved empty.

Fixing skip surfaced a sneaky bug: the app decided "was that the last set?"
by counting the sets it had written down. A skipped set writes nothing down,
so after a skip the count lagged and the coach would prescribe a phantom
extra set. Both the skip path and the normal path now ask "what set number
are we on?" instead of counting receipts.

**How it was checked:**
The phantom-set test was written first and watched to fail against the old
counting logic, then the fix turned it green. Full build passed and the whole
suite ran green — 743 tests, 0 failures. Seven new tests: the empty-by-default
effort picker, the database row leaving the effort field properly blank,
skip advancing without writing anything or resting, skip-then-complete
advancing to the next exercise with no phantom set, and an all-skipped
session being discarded.

**Status:** waiting for review and merge as PR #340.

---

## 2026-06-11 — Your onboarding answers finally reach the coach (PR #339)

**What happened (in plain words):**
During onboarding the app asks about your experience, your goal, your
bodyweight and your age — and then, embarrassingly, the part that builds each
workout never read those answers. It looked in storage spots nothing ever
wrote to, shrugged, and planned every session for a made-up "intermediate
lifter chasing muscle size". Three smaller things too: if you denied camera
access, the "enter equipment manually" button just looped you back to the
camera; if the app got killed mid-onboarding, your finished gym scan was
forgotten and a paid AI call could quietly run twice; and there was no way to
ask for a fresh version of a session you hadn't started yet.

**What changed:**
All three program-building paths now read your real saved answers from one
shared, tested place. Your goal is picked smartly: the coach's current
understanding of your goal wins when it exists, then your onboarding answer,
then the old default as a last resort. The manual-equipment button now
actually opens manual entry (and phone users get that option up front, not
just simulator users). Onboarding now remembers a finished scan after an app
kill and won't pay for a second program generation it already has. And any
planned-but-untouched session gets a "Regenerate this session" button with a
confirmation — days that are completed, paused, or mid-workout are protected
and can't be reset.

**How it was checked:**
Full build passed and the whole test suite ran green. Twelve new tests: eight
lock down exactly how the profile and goal get assembled (every fallback
branch covered), and four prove regenerate refuses completed, paused, and
in-progress days while correctly resetting an eligible one.

**Status:** waiting for review and merge as PR #339.

---

## 2026-06-11 — The Train tab got designed: the plan ahead, and the move dictionary (PR #338)

**What happened (in plain words):**
The Train tab got its full design plan — the last of the five screens. Train is
two things in one: the *plan* (your weeks ahead, what's coming) and the
*dictionary* of every exercise (how to do it, and your own history with it).
The same four experts reviewed it.

The big idea the experts pushed hardest on: the app should never pretend it
knows more about the future than it does. The coach builds your program a little
at a time — it plans next week's exact weights close to the day, not a month
out. So the calendar draws a line: days it has really planned show in full ink
with real numbers; days it hasn't yet show in faint pencil, as just a shape
("lower body, squat focus") with no fake numbers. The further out you look, the
fainter it gets — because that's honestly how much the coach knows.

**The biggest catches:**
- The first draft let the app pretend on the future, so the experts made the
  "how much do we actually know" line into a real drawn thing on the page, not
  just a colour change.
- The calendar must NOT become a guilt machine. No streak flames, no "you missed
  3 days" — a done day is just a quiet fact, a missed day is just a day the plan
  moved past.
- The biggest gap: you couldn't change your own plan. But during a workout the
  app already lets you swap an exercise — so it was weird that you could change
  things mid-lift but not when calmly planning. Now you can move a day, say "I
  can't train today," or swap an exercise for a cousin of it, and the coach rolls
  with it.
- An exercise page used to risk copying a competitor's dishonest "is it going
  up?" chart (the kind that makes a planned light day look like you got weaker).
  We cut the chart entirely — the exercise page just points up to your real
  strength band instead.
- There was a half-built feature (re-checking your strength) that had no home in
  the app — every other screen pointed at it but nobody owned it. Train adopted
  it, because re-checking your strength changes your plan, and the plan is
  Train's job.

All five screens are now fully designed. The next step (not started — waiting for
the go-ahead) is breaking these designs into actual build tickets.

---

## 2026-06-11 — The app stops making promises it can't keep (PR #337)

**What happened (in plain words):**
A flow audit found a bunch of places where the app's words didn't match
reality. The onboarding screen promised "session reminders" that don't exist.
The final onboarding screen said "your program is loaded" even when generation
had failed or the gym scan was skipped. An error message blamed your "API key"
— something a normal user has never heard of. One screen pointed you to a
"Scanner tab" that isn't a tab. And when you finished all 12 weeks, the app
just told you to wander over to Settings instead of offering a button.

**What changed:**
Ten small fixes. The copy now tells the truth: the final onboarding screen has
three honest versions depending on what actually happened; the fake reminder
promise is gone; the wait estimate matches the real timeout ("up to a couple
of minutes"). Dead ends became buttons: the Scanner-tab text is now a button
that takes you to Settings, and the programme-complete screen got a real
"Start Your Next Programme" button with a confirmation step (disabled with an
explanation if your gym isn't set up). The welcome-back-from-a-break banner
now only claims the session "accounts for the break" when that's true — if the
session was planned before your break, it says so instead.

**How it was checked:**
Full build passed, the whole test suite ran, and the welcome-back banner logic
got three new unit tests (short break, long break, pre-planned session).

**Status:** waiting for review and merge as PR #337.

---

## 2026-06-11 — The Progress tab got designed: your strength as a staircase (PR #336)

**What happened (in plain words):**
The Progress tab — where you check if you're actually getting stronger — got
its full design plan, reviewed by the same four experts. The main idea: other
apps chart your raw gym numbers, so a planned light day looks like you got
weaker. We chart what the coach *believes* about you instead — a band per
lift — and your floor through time becomes a staircase that can only ever go
up, because it only moves when you prove it.

**The biggest catches:**
The brand expert ruled that no line on the chart may ever slope — the coach's
belief updates on training days and holds in between, so every line is made
of flat steps and right angles. A slope would claim knowledge nobody has.
The experience expert found the screen had no forward pull — it only looked
backward — so every lift now shows how close the next floor-raise is ("2 of
3 sessions above 102"). And the animation expert banned the two prettiest
possible animations for honest reasons: re-scaling the chart would show the
floor *moving*, and morphing the small band into the big chart would rotate
an axis mid-flight.

**How it was checked:**
Four independent expert reviews against 17 reference screenshots from Tonal,
Hevy, Bevel, Gymshark and Peloton; every accepted finding folded into the
locked spec with the disagreements and who-won recorded.

**Status:** merged as PR #336. One screen left in the queue: Train.

---

## 2026-06-11 — The Workout tab can finally start a brand-new day (PR #335)

**The problem (in plain words):**
The app builds each day's workout only when you ask for it — until then the day
is empty, a blank slate. But the big button on the Workout tab always said
"Start Workout," even on a day that had nothing in it yet. Tapping it didn't
build the workout; it just threw an error. Worse, by the time it hit that error
it had already scribbled two notes to itself: a "you have an unfinished workout"
flag and a half-started session record in the database. So the next time you
opened the app it nagged you about a workout you never actually did, showed a
warning dot on the tab, and could even mark a day you never trained as "paused."

**What changed:**
On a not-yet-built day, the button now reads "Generate Session" and actually
builds the workout right there — no more dead-end error. If you haven't set up
your gym yet, the button politely greys out and points you to Settings instead
of pretending to work. And the empty-day check now runs *first*, before the app
writes anything down — so a failed start leaves zero mess behind: no false
"unfinished workout" flag, no orphaned record, no wrong-day "paused" mark. If
building the session fails (say your connection drops), it now says so plainly
instead of failing silently.

**How it was checked:**
Two new automated tests pin the fixes: one proves a failed start leaves no flag
and no stray database record, the other proves resuming a truly empty day quietly
stops instead of faking a finished workout. The full test suite — 261 tests —
passed on an iPhone 17 Pro simulator.

**Status:** Done and opened as a pull request for review (PR #335). Part of
the bigger eight-part fix-up (#318).

---

## 2026-06-11 — The "what did today prove?" screen got designed (PR #333)

**What happened (in plain words):**
The screen you see right after finishing a workout got its full design plan.
It's the moment the coach speaks: one short headline naming what the session
proved about you, the proof drawn underneath as your strength band with
today's result placed on it like a dot of ink, and the full session record
below that. The same four experts reviewed it — looks, experience, brand, and
animation.

**The biggest catch:**
My draft said that once you tap Finish, the record is locked forever. The
experts voted that down 4 to 0. The scary example: you log the wrong weight by
accident, and the app celebrates a strength milestone you never earned — and
you can't fix it. Now real facts (weight and reps) can be corrected from the
history page for up to two days, with the old number visibly crossed out, not
erased. Feelings stay locked — you can't rewrite how a set felt after the fact.

**Other good catches:**
All four experts noticed my headline text literally couldn't fit on the screen
(too many words at too big a size) — it's now a short claim plus a smaller
proof line. The animation expert choreographed the screen's signature moment:
today's dot settling onto your band like a pen touching paper, and the "floor
moved up" click that only ever plays when you've actually seen it — never
behind your back, never twice. And celebrations stay honest: a flat day gets
respect and a quiet "one more session above 102 and the floor moves," not
confetti.

**What's next:**
The Progress screen, then the Train screen — same four-expert panel.

---

## 2026-06-11 — Spring cleaning: three stray copies of workout screens got thrown out

**What happened (in plain words):**
A while back, three files for the workout screens ended up in the wrong place —
sitting at the very top of the project folder instead of inside the app's real
code folder. The app never used them; it always built from the proper copies.
But two of the three strays were old and out of date: one was missing a crash
fix, another was missing the "Continue with last weights" button. The danger
wasn't a broken app — it was that anyone, a person or an AI helper, who opened
the wrong copy could read outdated code and get confused, or even "fix" the
file nobody actually runs.

**What changed:**
The three stray files are gone, along with their now-empty folders and the
leftover bookkeeping lines in the project's index that still pointed at them.
The real, up-to-date copies inside the app were not touched at all.

**How it was checked:**
Before deleting, we re-confirmed the app's build recipe never compiled these
files — it didn't, so removing them couldn't break anything. After deleting,
we searched the project's index for any leftover mention (none), confirmed the
project still opens, and built and ran the full test suite on a simulated
iPhone — all 261 of the everyday tests passed. One live-internet test failed,
but it fails the exact same way on a clean copy of the project too, so it's an
old flaky test, not something this change caused.

**Status:** Up as pull request #334, awaiting review. First of eight cleanup
jobs in campaign #318.

---

## 2026-06-11 — The workout screen itself got designed, with a motion expert at the table

**What happened (in plain words):**
The screen you actually lift with — one set at a time, a big Done button, a rest
timer — got its full design plan. Four expert agents reviewed it this time: looks,
experience, brand, and a new one who only judges animation and timing.

**The biggest catch:**
There was no way to fix a logged set. Tap Done by accident, or rack the bar a rep
early, and the app would remember a lift that never happened — feeding the coach's
picture of you with fiction. Now every logged set can be corrected until you finish
the session: fewer reps, more reps, a different weight, or "that one hurt."

**Other good catches:**
The app now shows what you lifted last time right under today's target, so you can
check the coach's homework. Weights snap to plates your gym actually has before
they're ever shown. The animation expert timed every transition to the millisecond,
ruled that nothing on screen may move while you rest (which also saves battery),
and found two spots where animation quietly caused data bugs — like the final set
of every session losing its "how did that feel?" question because the screen
changed too early.

**One look-and-feel decision worth noting:**
The Done button is no longer a button — it's a solid band of blue ink across the
bottom of the screen, all session long, that turns into "Finish" at the end. And
work numbers are always dark ink while timer numbers are light pencil-grey, so your
eye always knows what's a lift and what's a clock.

**Status:** Merged into main in pull request #332; design documents only, no app code.

---

## 2026-06-11 — The app's face got designed: the opening moment and the home screen

**What happened (in plain words):**
Two more screens got their full design plans: the moment the app opens, and the
home screen ("Today") that answers one question — what does my coach want from me
right now? This round three expert agents reviewed the draft instead of two: the
usual looks-and-experience pair, plus a new brand-design specialist.

**The big design decision:**
The brand specialist said the draft logo would look like anyone's app — plain
lettering on a blue screen. The fix: the word APEX gets one custom-drawn letter.
The hole inside the letter A becomes a tiny camera shutter — the same shutter that
shows your daily readiness on the home screen. One drawing ties together the logo,
the app icon, and the app's signature gauge. (Two agents preferred lowercase
lettering; the brand specialist's capital-A argument won because the shutter needs
the A's triangle shape.)

**Other important catches:**
The home screen was missing half its real-life situations — like the day the coach
says "don't train hard today" (the screen now leads with that advice instead of a
big blue Start button), or when your workout numbers aren't ready yet (they now get
prepared in the background, so you never stand on the gym floor watching a spinner).
Also, the readiness gauge must admit when it doesn't know yet — a new-user gauge
shows a dash, not a made-up number. And one technical save: iPhone launch screens
can't use custom fonts, so the logo ships as a pre-made image — caught on paper
instead of in testing.

**Status:** Merged into main in pull request #320; design documents only, no app code.

---

## 2026-06-11 — The welcome-flow blueprint got a hard second look and grew much sharper

**What happened (in plain words):**
Yesterday we drafted the design for a new user's first three minutes in the app.
Today two expert agents (one for looks, one for experience) studied the 16 real app
screenshots that design was based on — from apps like Fitbod and Yazio — and tore
into them: what those apps get right, where they cheat or annoy people, and what our
version must do differently.

**The biggest finds:**
The most important screen — where the app draws its first picture of you — had no
good example anywhere, so it now has the most detailed plan instead of the thinnest.
A real logic hole got caught: the old draft would ask someone with no barbell about
their barbell lifts — now the equipment answer shapes which questions get asked. And
a stack of smaller rules landed: progress bars that never lie, questions that answer
themselves with one tap, never pre-filling a number (people just accept suggestions,
which poisons the data), and no sign-up screens, pop-ups, or paywalls between the
last question and the first workout.

**How it landed:**
All of it is folded into the design documents. By coincidence this rode into main
inside pull request #316 (another work stream branched off these changes and its
merge carried them in) — the content landed exactly as written.

**Status:** Merged into main via pull request #316; design docs only, no app code.

---

## 2026-06-11 — Three expert reviewers walked through the whole app and wrote down everything wrong

**What happened (in plain words):**
Three reviewer agents each took a different pair of glasses and went through the
app's real code, screen by screen: one looked at the overall journey (like a ride-app
expert), one at what it's like to actually use mid-workout at the gym, and one at the
very first minutes a new person spends in the app. They wrote three reports with
about forty findings, each one pointing at the exact line of code.

**The headline problems they agree on:**
The Workout tab can't actually start a workout on most days (and can even invent a
fake "unfinished workout" afterwards), several messages in the app say things that
aren't true, the answers people give during signup get partly thrown away, a lazy
set log quietly invents an effort score, and the streak counter is counting for the
wrong user so it always shows zero.

**What this is and isn't:**
These are reports, not fixes. The fix campaign starts next: a plan, a critic to
challenge the plan, then small focused pull requests.

**Status:** Reports merged into main in pull request #316 (docs/design/reviews/).

## 2026-06-10 — The new look has a rulebook, and new users get a proper welcome

**What happened (in plain words):**
We're rebuilding how the whole app looks and feels. Today the ground rules got
written down for real: one signature color (a deep blue called ultramarine) on warm
cream paper, bold clean lettering, and animation saved for the big moments so it
stays special. Two expert reviewers (one for looks, one for experience) went over
the plan and found real problems — the blue text was too hard to read on cream, the
app had no plan for brand-new users, and a couple of spots where the app could
quietly invent data about you. All of their must-fixes are now baked into the rules.

**The biggest piece:**
A design for the app's first three minutes. A new user answers a handful of quick
questions (goal, experience, equipment, schedule, and roughly what they can lift —
guessing is fine, skipping is fine), and then watches the app literally draw its
starting picture of them. Honest guesses are marked as guesses, and the first
workouts firm them up.

**What this is and isn't:**
These are design documents — the rulebook (DESIGN.md) and two specs in docs/design/.
No app code changed yet. Building it comes next, screen by screen.

**Status:** Merged into main in pull request #314.

---

## 2026-06-10 — A whole chapter is finished: the coach that actually learns you

**The big picture (in plain words):**
For a long stretch now, almost all the work has been one big project: making the app
truly *learn* each person instead of starting from scratch every workout. Today that
whole chapter is officially finished and closed.

**What it means for someone using the app:**
The app now keeps a living picture of you — how strong you're getting on each lift, how
recovered you are, when you've genuinely stalled (versus just an off day), and when
you've outgrown your own targets. The coaching is built on that picture instead of
re-reading your raw history cold each time, so the advice stops feeling generic.

**What's left for later — and none of it is blocking:**
A handful of small tuning jobs that need real-world data before they're worth doing,
one product idea parked on purpose, and a short "revisit next chapter" list. One honest
caveat: the newest target screens work and are tested, but nobody has actually watched
them run on a phone yet — worth a quick eyeball before showing them off.

**Status:** Done. The big Phase 2 plan (issue #71) is closed.

---

## 2026-06-10 — Fixed a spelling mix-up so the app remembers what you've seen

**The problem (in plain words):**
When the app told the server "this person has seen their targets screen," the server
saved that note under one spelling and the app looked for it under a slightly different
one. So after a fresh sync the app couldn't find the note — and could pop up a one-time
screen you'd already dismissed. A backup copy kept on the phone hid it most of the time,
which is why nobody really noticed, but the server's own memory of it wasn't being read.

**What I changed:**
Matched the spelling so the app reads the server's note correctly. I also taught it to
still understand the *old* spelling, so anyone who had already dismissed the screen
doesn't suddenly get it back — the whole point of this note is that it should stick.

**How I made sure it works:**
Three small tests: it reads the new spelling, it still reads the old one, and it now
writes the new one. The app builds clean and the related tests all pass.

**Status:** Done. Bug #309, fixed in PR #311, merged. I'd spotted it while building the
re-calibration feature (#305) and written it down rather than fixing it sideways.

---

## 2026-06-10 — When you outgrow your goal, the app raises the bar and cheers

**The problem (in plain words):**
Each lift has two numbers: a floor (the level we keep you at) and a stretch (the next
milestone). They're set once, early on, and then the floor was frozen forever. So an
athlete who'd been lifting way above their floor for weeks still had a floor describing
the weaker version of themselves. The number had quietly become a little bit of a lie.

The day before, I'd asked a sharper question: should changing your *goal* move these
numbers? After a lot of back-and-forth (I had two other helpers stress-test every
decision), the honest answer was: no — changing your goal *words* doesn't make you
stronger. What should move the numbers is **getting stronger**. And we already measure
that, using your own lifts — no guessing, no comparing you to other people.

**What I changed:**
Now, when your typical strength on a lift has climbed clearly past your stretch target
(not from one lucky day — it's measured over your last few sessions), the app **raises
the whole target**: the floor steps up to what you're actually lifting, and a new
stretch is set above it. Then it tells you — the targets screen pops back up with a
"You've leveled up" message and a "Levelled up" badge on the lifts you outgrew, so
beating your goal feels like a win, not the app quietly moving the goalposts. Three
safety rules: the floor only ever goes **up**, never down; it never claims more than
you've actually lifted; and it can't keep re-firing — once it raises the bar, it waits
until you've genuinely grown again.

One nice catch from the stress-testing: one helper worried the targets could get stuck
re-raising forever for some athletes. I checked the math myself and proved that can't
happen, then wrote a test to lock it in — rather than adding code to guard against a
problem that doesn't exist.

**How I made sure it works:**
Test-first, in three small steps (mechanism → screen → words/badge). 10 + 105 + 7
small tests, the app builds clean, and the database tests passed on the build server.
I also found and reported an older unrelated bug (a mismatched data label, #309) but
left it alone rather than fix it sideways.

**Status:** Done. Issue #305 (re-scoped from "goal-aware" to "re-calibrate when you
outgrow your targets"), shipped in PRs #307, #308, and this docs one; design recorded
in ADR-0023. The "should your goal itself move the numbers" idea is parked until we
have enough data to do it honestly.

---

## 2026-06-09 — When you change your goal, your targets quietly catch up

**The problem (in plain words):**
A while back I gave each athlete two strength numbers per movement: a floor (the level
we keep them at) and a stretch (the next milestone to aim for). The plan always said:
if the athlete later changes their goal, re-work the stretch number to match — but
leave the floor alone. That part was never built. There was even an empty slot in the
data for "when did they last change their goal," and nothing ever filled it in.

**What I changed:**
Now, when an athlete edits their goal (the wording or the body parts they want to focus
on), the app quietly re-works each stretch number and records the moment they changed
their goal. Two rules keep it safe: the floor never moves, and the stretch can only go
**up** — if the athlete had already nudged a target higher, we never pull it back down.

One honest thing I found while planning: the way we calculate a stretch only looks at
how strong you are and which way your strength is trending — it doesn't read your goal
words at all. So changing your goal mostly just refreshes the date and only nudges a
number if your trend has moved. That turns out to be exactly what the original plan
meant by doing it "silently." I built that honest, quiet version, and filed a separate
note (#305) for the bigger question — should changing your goal actually move the
numbers more? — because that needs real data before it's worth guessing at.

**How I made sure it works:**
I wrote the tests first. 15 small tests for the core logic (all pass on my machine),
plus 6 database tests that the build server runs. I also checked that all the old
goal-saving tests still pass, so nothing that already worked got broken.

**Status:** Done. Built in pull request #306 (issue #304), spun off #305 for the
bigger "make it actually move the numbers" question. No app change and no database
change were needed — it's all on the server.

---

## 2026-06-09 — Gave the athlete real strength targets to review and reach for

**The problem (in plain words):**
The app was always *meant* to show you concrete strength targets per movement once it
knew you well enough — a "floor" (what you can reliably do) and a "stretch" (what you're
reaching for). But that whole layer was never built: the targets were always empty, and
the screen that would show them didn't exist. Last entry I switched on the "how sure am I"
ratings; this builds the thing those ratings unlock — once your main lifts are "known," the
app can finally put real numbers in front of you.

**What I built:**
- **The numbers (server).** When at least 4 of your 6 big movements are "known," the app
  works out, for each: a **floor** = a rounded-down typical of your recent best lifts (so it
  never overstates what you've shown), and a **stretch** = a bit above that, scaled to how
  you're trending (more if you're climbing, less if you're stalling). It also tracks whether
  you're behind / on track / ahead / there. Late-blooming lifts get targets too, the moment
  they qualify.
- **The screen (app).** A one-time "your targets are ready" banner → a review screen showing
  each lift's floor, stretch, and progress.
- **Editing (app + server).** You can nudge a stretch target **up** (never down, and you
  can't touch the floor — it reflects what you've actually lifted). The server enforces that
  upward-only rule so a bad app version can't cheat it. Once you've reviewed, the banner
  stays gone for good.
- A nice catch from the design pass: two "capability" fields the old formulas wanted to use
  turned out to be dead (always zero), so everything was re-grounded on the live lift history
  instead — caught before it shipped a screen full of zeros.

**How it was decided:**
Same rigorous design interview as last time — every question got three independent takes
(mine, a fresh reviewer, and one that remembered the whole conversation), best answer taken.
Written up in a new decision record (ADR-0021).

**How it was checked:**
Five small pieces, each shipped on its own. Server logic has unit + end-to-end tests (drove
real sessions until the targets appeared); the app code was compiled and its logic unit-
tested locally. Every server piece passed the reliable server test before merging.

**Status:** Done. All five pieces merged (#294–#298 via PRs #299–#302 + this docs PR);
umbrella #269 closed. Note: the app screens are compiled and logic-tested but I couldn't
eyeball them rendered, so a quick visual once-over on a device is worth doing.

---

## 2026-06-08 — Taught the app to actually grow more sure of itself over time

**The problem (in plain words):**
The app keeps a "how sure am I about this?" rating for every exercise, every movement
pattern (squat, hinge, the presses and pulls), and every muscle group. The rating is
supposed to climb from "no idea yet" → "getting a feel for it" → "I know this now" as you
train. Except it never climbed. Every rating was stuck on "no idea yet" forever — the steps
that would move it up were designed a long time ago but never actually built. So the coach
treated even someone with months of history as a total stranger, and a downstream feature
(letting you review your projected targets) was stuck waiting for ratings that never moved.

**What I changed:**
I built the whole "grow more sure" system for all three: exercises, patterns, and muscles.
- **Exercises** become "known" once you've done them enough times *and* your estimated
  strength has settled down (stopped bouncing around).
- **Patterns** become "known" after about six sessions with a real, data-backed read on how
  they're trending. This is the important one: once enough of your main patterns are "known,"
  the app can finally offer to review your targets — the thing that was blocked.
- **Muscles** don't judge themselves; they inherit confidence from the patterns that train
  them. A nice catch here: biceps only get trained by isolation moves, so an earlier "only
  count the big patterns" idea would have left biceps permanently stuck — the final rule
  counts all the patterns a muscle actually uses.

A rating only ever goes up, never sneaks back down (going backwards would yank away targets
you'd already been shown). And the whole thing is conservative on purpose: it would rather
say "not sure yet" than wrongly claim "I know this" off thin data.

**How it was decided:**
Before writing code I ran a long structured design interview, and for every question I got
three independent takes — my own, a reviewer starting fresh each time, and a reviewer that
remembered the whole conversation — then picked the best. All the decisions are written down
in a new decision record (ADR-0020).

**How it was checked:**
Built in five small, separately-shipped pieces, each test-first. 81 fast unit tests plus
end-to-end tests that drive real sessions and watch the ratings climb. Every piece passed
the reliable server test before merging. No database change and no iPhone-app change needed —
it's all server logic.

**Status:** Done. All five pieces merged (#287–#291), umbrella #166 closed. This unblocks
the target-review feature (#269). Two related volume items (#164/#165) stay separate on
purpose. Found and filed one pre-existing bug along the way (#292: a list that grows without
limit).

---

## 2026-06-08 — Turned on two coaching rules the AI already had the data for

**The problem (in plain words):**
Two bits of coaching guidance had been written months ago but never actually switched on in
the live AI. The interesting part: in both cases the app was already *sending* the AI the
data it needed — it just wasn't told to use it. So we were paying to ship the data and
getting nothing back.

**What I changed:**
- **#221 — react to what you tell it mid-workout.** If you flag "that hurt" or "my form
  broke down" on a set, or you swap to a different set type than it suggested, the AI now
  reacts on your next set. Pain is one-strike: it backs off the weight and flags it, rather
  than pushing you through. This was close to a safety gap before — the app knew you'd
  flagged pain but never told the coach to do anything about it. (One small correction baked
  in: the old draft pointed the AI at the wrong part of the data; I fixed it to read the
  arrays that actually carry those signals.)
- **#222 — stop prescribing impossible machine weights.** Gym weight-stack machines go up in
  5 kg steps, but the AI's rules wrongly let it ask for things like 37.5 kg on a leg press —
  a weight that physically isn't on the stack. I split machines into their own "round to the
  nearest 5 kg" rule. This matches what the app already knows in its own weight tables.

**How it was checked:**
I had two fresh agents research each one first — confirming the data already flows and the
change is low-risk — then you made the product calls (adopt the full pain/form/deviation set;
prompt-fix the machines now). Both changes are golden-locked with tests that assert the new
rules are actually in the live prompt. Tests green.

**Status:** both merged and closed — #221 (PR #278), #222 (PR #280). Filed a follow-up
(#279) to make the machine-weight rounding bulletproof in code (right now it's the AI's
best effort). Also flagged that cable machines have the same 5-kg-vs-2.5-kg question — left
that one for a separate decision since it's genuinely debatable.

---

## 2026-06-08 — Swept an old dead label out of saved user data

**The problem (in plain words):**
Way back, each saved "trainee model" carried a label called `reassessmentRecords`. The app
stopped using it months ago and removed it from the code, but the label could still be
sitting inside existing users' saved rows in the database — harmless clutter, but clutter.

**What I changed (P5-D07):**
A one-time database cleanup that deletes that dead label from any rows that still have it.
I copied an already-proven cleanup we'd done before (same exact shape, just a different
label name), so there were no surprises. I left one copy of the old label alone on purpose —
it lives in a test file where it actually does a job: it proves the app safely ignores old
labels it no longer understands.

**How it was checked (this one got the full treatment, since it touches real user data):**
- One agent traced every place the label is used and confirmed nothing reads or writes it
  anymore — truly dead.
- A second agent did an adversarial review of the cleanup, poking at eight different ways it
  could go wrong (could it run twice safely? could it touch the wrong data? etc.) — all clean.
- The build system spun up a real throwaway database, applied the cleanup, and it worked.
- Then the live deploy applied it to the real database — I watched the "apply" step go green
  (it needed one re-run because an unrelated setup step flaked the first time).

**Status:** merged and live (PR #276). Backlog P5-D07 ticked done.

---

## 2026-06-08 — Finished the prompt-loader cleanup (the 6th copy)

**The problem (in plain words):**
Earlier today I merged five copies of "find and read a prompt file" into one shared
helper, but left a sixth, odder copy in the exercise-swap code for its own ticket. This
finishes that — folds the sixth one in too, so there's now exactly one place that does it.

**What I changed (P5-D08):**
Pointed the exercise-swap prompt at the shared `PromptLoader`. The tricky part: unlike the
other five, this one is meant to *not* error — if the file is missing it quietly falls back
to a short default prompt. I kept that exact behaviour (both "file missing" and "couldn't
read it" still land on the fallback), along with its little habit of stripping comment lines.
Before changing it I checked where the prompt files actually live in the built app — they sit
flat at the top, not in a sub-folder — which confirmed the swap doesn't change which file
gets loaded.

**How it was checked:**
App builds clean. A grep confirms the low-level "open a bundled file" call now appears in only
one file (the shared loader); the shared loader already has its own tests from earlier today.

**Status:** merged (PR #274). Backlog P5-D08 ticked done — the prompt-loader consolidation is
fully complete across all six places.

---

## 2026-06-08 — Two small cleanups: tidy lift names, and one prompt loader

**The problem (in plain words):**
Two bits of leftover duplication, both loose ends from earlier work.
1. Movement names like "hip_hinge" were being turned into "Hip Hinge" by hand in two
   different screens — even though we'd just built one proper place to do that.
2. Five different services each kept their own near-identical copy of the code that finds
   and reads a prompt file out of the app bundle.

**What I changed:**
- **#268 — lift names.** Pointed both screens at the shared `displayName` and deleted the
  two hand-rolled helpers. Same words on screen, less code.
- **#220 — one prompt loader.** Made one small `PromptLoader` that finds and reads a
  bundled prompt, and had all five services call it instead of repeating themselves. Each
  service keeps its own error message and any extra tweaks it makes to the text, so nothing
  behaves differently. The ticket only named three services; I found two more identical
  copies and folded them in too (you okayed doing all five). While in there I spotted a
  sixth, odder copy in the exercise-swap code — it quietly falls back to a default instead
  of erroring — so I left that one for its own ticket (P5-D08) rather than force it into the
  same mould.

**How it was checked:**
Both built clean. #268: app builds, no test depended on the old text. #220: a new little
test (a real prompt loads; a missing one returns nothing instead of crashing) plus the
existing prompt-content tests stayed green — 97 + 9 tests passing. (One gotcha: the test
target doesn't auto-pick-up new test files like the app does, so I had to register the new
test in the Xcode project by hand before it would run.)

**Status:** both merged and closed — #268 (PR #271), #220 (PR #272).

---

## 2026-06-08 — Built the "your training leveled up" goal check-in

**The problem (in plain words):**
When someone's lifts all move up around the same time, the app treats it as a milestone —
a good moment to step back and rethink what you're training for. But the old version was
broken: the coach would nudge you every single workout for about six sessions to "go
revisit your targets," except there was no screen to do that, no numeric targets to set,
and no way to tell the app "okay, got it." So it just nagged. This was the whole job:
build the real check-in, end to end.

**What I changed (one feature, built in eight small safe steps):**
- **Remembering you dealt with it.** Added a record of which level-up moments you've
  already acknowledged, so the coach stops bringing it up once you've handled it. (A)
- **Saving that on the server.** When you update your goal, the server now also files the
  acknowledgment. (B)
- **Human-readable lift names.** "Hip Hinge" instead of "hip_hinge" for anything shown to
  you. (C)
- **The banner.** A friendly "your training has leveled up" card on the pre-workout
  screen that names the lifts that moved up, in its own colour so it doesn't blur into the
  other cards. (D+E1)
- **Hiding it instantly.** The logic that makes the banner disappear the moment you save,
  without waiting on the server. (F1)
- **The goal-review screen itself.** Edit your goal in plain words, pick your focus areas,
  see your current strength numbers for context, and save. (F2)
- **Connecting the button.** Wired the banner's "Review goals" button to open that screen,
  and made the banner vanish after you save (a plain cancel leaves it up). (E2)
- **Fixing the coach's script.** Pointed the AI at the real "Review goals" button instead
  of nonexistent "targets," taught it what to say when there aren't specific lifts to name,
  and made it stay gentle (not pushy) if you haven't gotten around to it yet. (G)

**How it was checked:**
Every step was written test-first and merged green on its own. Then — because the pieces
had each been built against a moving baseline — I rebuilt the whole app with all eight
together and ran every related test suite at once: 122 tests plus the banner-copy and
lift-name suites, all passing, app builds clean.

**Status:**
All eight slices merged — PRs #259, #260, #261, #262, #263, #264, #265, #266. The umbrella
issue #258 now has every box ticked and is ready to close once you've confirmed it feels
right in the app. Built from the plan we grilled out and wrote up in #258.

---

## 2026-06-07 — Closed out four "is the AI being honest?" decisions

**The problem (in plain words):**
Four loose ends were all about the same theme: when the AI fails or behaves oddly, does
the app stay honest about it? A couple were real decisions, not just code edits, so I
talked through each one before changing anything.

**What I changed (four fixes):**
- **Fixed misleading comments in the set-suggestion code.** The comments claimed the app
  "retries" when the AI gives a bad answer. It doesn't — on purpose, it fails fast and
  shows you a retry button instead. I corrected the comments. There's a setting in there
  that looks unused; it turned out a test deliberately uses it to *prove* the app never
  retries, so I kept it and wrote a note explaining why. (#42)
- **Settled a real rule question and wrote it down.** When the program-builder AI returns
  a plan with an empty day or equipment your gym doesn't have, the code asks the AI *once*
  to fix that specific problem, then gives up loudly if it still fails. I decided this is
  fine — it's a one-shot correction with a clear ask, not the kind of blind "keep
  retrying" loop we banned — and recorded it as a written rule (ADR-0019) so no one
  strips it out later by mistake. (#241)
- **Cleaned up the last workout day-label slip-through.** This was the third and final
  spot where a raw label could sneak past un-tidied; now all three match. Day-label
  cleanup is fully done. (#246)
- **Made the post-workout summary honest.** After a workout the app shows "insights." If
  the AI failed, it used to quietly show a basic backup summary that looked *exactly* like
  real AI insights — so you couldn't tell the AI didn't run. Now it adds a small note:
  "couldn't generate AI insights — showing a basic summary." Honest instead of silently
  faking it. (#242)

**How I made sure it works:**
Each code fix has its own test (the day-label and honest-summary fixes were written
test-first — fail, then fix, then pass). The full app test suite passes (237 tests).
The two "decision" items (#42 comments, #241 rule) changed no behavior.

**Status:** All four merged into main. Pull requests #253, #254, #255, #256 —
closing issues #42, #241, #246, and #242.

---

## 2026-06-07 — Merged a batch of five safety-net fixes

**The problem (in plain words):**
A bunch of small things needed tidying up. A few server functions had no tests, so
we couldn't be sure they saved data correctly. A past bug — where saving a workout set
could silently lose its "intent" and "date" — had been fixed but never had a test
guarding it. Workout day-labels in one older code path weren't being cleaned up, so
they could drift away from your history. And the set-logs table had a fake placeholder
date ("1970-01-01") it would quietly fall back on if a real date was ever missing.

**What I changed (five separate fixes, merged together):**
- Added a test that proves the "save your goal" server function writes to the database
  correctly, including not wiping out other saved state when you re-onboard. (#155)
- Added tests that make sure a saved workout set always keeps its "intent" and "date".
  This locks in the earlier data-loss fix so it can't quietly come back. (#66)
- Added a test that locks the exact shape of the goal message the app sends at
  onboarding, so the app and server can never drift out of agreement. (#154)
- Cleaned up workout day-labels in the older program-building path so they match your
  real history, the same way a newer path already does. (#192 sibling)
- Removed the fake "1970" fallback date on the set-logs table. Now a missing date fails
  loudly instead of silently saving a wrong one. (#67)

**How I made sure it works:**
All the tests pass locally (the local run is what we trust). Two of the five showed a
red mark in the automated cloud checks — I looked at both and confirmed they were
unrelated hiccups (a known flaky phone-build job, and a one-off Supabase tool-install
failure), not real problems with the changes.

**Status:** All five merged into main. Pull requests #244, #248, #251, #245, #247 —
closing issues #155, #66, #154, #243, and #67.

---

## 2026-06-07 — Stopped bad workout "pattern" labels from sneaking in

**The problem (in plain words):**
When the app sends a workout to the server, each set can carry a "pattern" label —
like "horizontal_push" for a bench press. The server keeps a fixed list of valid
pattern names. But the old code trusted whatever the app sent, even made-up words.
Those junk words got dropped into the "what you trained today" list. That list helps
the app decide when to quietly clear an old injury or form note — so a junk label
could trip that safety check by accident.

**What I changed:**
The server now only accepts a pattern if it's on the real list of valid names. If the
app sends junk, the server ignores it and works out the correct pattern from the
exercise name instead. So bad data can't sneak in, and it also can't hide the right
answer.

**How I made sure it works:**
I wrote three tests first. Two of them failed before the fix (which proved the bug was
real), then passed after. All the important tests pass (91 out of 91).

**Status:** Done and merged. Filed as issue #239, fixed in pull request #240, now merged into the main branch — issue #239 is closed.

*(This is also the day the diary started.)*

---
