# Flow audit 1 of 3 — consumer-journey lens

> Agent persona: former Head of Rider Experience Design at Uber. Focus: end-to-end
> journey, time-to-value, navigation, dead ends, error/empty states, trust at AI
> handoff moments. Read-only audit of the shipped code, 2026-06-10. Companion
> reports: `2026-06-10-flow-audit-2-gym-floor.md`, `2026-06-10-flow-audit-3-onboarding.md`.

# Journey & Flow Audit — consumer-journey lens

**Reviewer stance:** end-to-end journey, time-to-value, drop-off points, dead ends, trust at AI-handoff moments. Visual token system (DESIGN.md) not relitigated. Where the in-progress spec (`docs/design/ui-overhaul-spec.md`) already fixes something, I say so — the point of this audit is what the *shipped code* does to a user today, and which spec gaps remain.

## 1. The journey as built (what the code actually does)

**First launch.** `ContentView` gates on a UserDefaults flag and presents `OnboardingView` as a full-screen cover (`ProjectApex/ContentView.swift:44,122`). Six steps, all `@State`, swipe-dismiss disabled (`ProjectApex/Features/Onboarding/OnboardingView.swift:66-113`): name → training profile (experience/goal/days + optional biometrics) → notification permission → **gym scanner** (camera walk-around, skippable with warning) → program generation (LLM skeleton call) → "You're Ready to Train." Completion writes the flag and lands the user on Tab 0 (`OnboardingView.swift:960-966`, `ContentView.swift:122-146`).

**The four-tab shell.** Program / Workout / Progress / Settings (`ContentView.swift:74-119`). There is no "Today" home; the default landing is the Program tab — a 12-week grid of ~48 tappable day cards with an auto-scroll to the current week (`ProjectApex/Features/Program/ProgramOverviewView.swift:253-314`). The Phase-3 spec calls for three tabs with a Today hero surface (`docs/design/ui-overhaul-spec.md:21-42`); none of it is implemented yet.

**Sessions are generated lazily.** Onboarding produces only a *skeleton*: every day is `.pending` with `exercises: []` (`ProjectApex/Services/MacroPlanService.swift:321-332`). The **only** place in the entire app that turns a pending day into a real session is the "Generate Session" button inside `ProgramDayDetailView` (`ProjectApex/Features/Program/ProgramDayDetailView.swift:761-792` → `ProgramViewModel.generateDaySession`, `ProgramViewModel.swift:414-625`). So the canonical loop is: Program tab → tap the current day card → "Generate Session" (LLM call, up to 120s timeout, full-screen "Preparing Your Session" — `ProgramDayDetailView.swift:357-385`, `AppDependencies.swift:173`) → "Start Workout" → push `WorkoutView`.

**The live loop.** `WorkoutView` is a ZStack state machine over the `WorkoutSessionManager` actor: `.idle/.preflight` → PreWorkoutView, `.active` → ActiveSetView, `.resting` → RestTimerView, `.sessionComplete` → PostWorkoutSummaryView, `.error` → error screen (`ProjectApex/Features/Workout/WorkoutView.swift:328-398`). A crash sentinel (`PausedSessionState`) is written at session start and updated per set (`WorkoutSessionManager.swift:242-255,363-372`); on relaunch `ContentView` finds it and shows an "Unfinished Workout" Resume/Abandon alert (`ContentView.swift:181-238`). Pause is durable-first (UserDefaults before network — `WorkoutSessionManager.swift:604-649`). AI failure mid-loop raises a non-dismissable `InferenceRetrySheet` with Retry / Continue-with-last-weights (rest only) / Pause (`ProjectApex/Features/Workout/InferenceRetrySheet.swift:51-126`). This part of the app is genuinely well-engineered for interruption.

**Reviews and trust surfaces.** Pre-workout, up to four banners can render: first-session calibration, calibration-review (takes precedence over heavy-reassessment), heavy-reassessment, welcome-back ≥14 days (`ProjectApex/Features/Workout/PreWorkoutView.swift:88-101`), plus a paused-session banner and a resume-repair notice as safe-area insets above them (`ContentView.swift:362-376`, `WorkoutView.swift:230-256`). The calibration and goal review sheets are solid: floor/stretch shown with plain-language explanation, stretch editable upward-only, "Levelled up" badge for re-calibration (`ProjectApex/Features/Workout/CalibrationReviewView.swift:129-228`).

**Escape hatches that exist:** session-only weight override, permanent weight correction (GymFactStore), chat-based exercise swap, pause, skip-with-confirmation, end-early (gated on ≥1 logged set), manual session logging and backfill, post-hoc set-log editing with AI-memory correction (`ProgramDayDetailView.swift:999-1084`), full program regeneration with an honest "history preserved" confirmation sheet (`ProjectApex/Settings/SettingsView.swift:382-462`).

## 2. Findings

---

### F1 · P0 — The Workout tab is a trap between every session: pending days offer "Start Workout" that can only error

**Evidence:** `ContentView.workoutTab` routes `nextIncompleteDay` — which includes `.pending` days — straight into `WorkoutView` (`ContentView.swift:298-314`, `ProgramViewModel.swift:732-747`). `PreWorkoutView` renders the pending day with a "0 exercises" badge and "~0 min estimated" (`PreWorkoutView.swift:261,544-551`) and an always-enabled primary "Start Workout" CTA (`PreWorkoutView.swift:483-515`). `startSession` then hits `guard !trainingDay.exercises.isEmpty else { sessionState = .error("Training day has no exercises.") }` (`WorkoutSessionManager.swift:263-265`). No code path in Tab 1 can generate a session; the only generation entry point is `ProgramDayDetailView.swift:767`.

**Why it matters:** This isn't an edge case — because sessions are generated lazily, *every* day is pending until the user goes through the Program tab. The tab literally labelled "Workout" leads to "Session Error" at the exact moment of highest intent ("I'm at the gym, let's go"). A user who learns "Start workout = the Workout tab" hits this on day one and again every week.

**Recommendation:** On a pending day, Tab 1's primary CTA must *be* "Generate Session" (reuse `generateDaySession` + the existing "Preparing Your Session" loading screen), then flow into Start. At minimum, disable Start and route to the day detail. The Today screen in the spec is the right end-state, but this one-screen fix doesn't need to wait for it.

---

### F2 · P0 — Preflight errors leave a phantom crash sentinel; the phantom "Resume" can silently mark an untrained day complete

**Evidence:** `startSession` writes the `PausedSessionState` sentinel (`WorkoutSessionManager.swift:242-255`) *before* the empty-exercise guard (`:263-265`). The error screen's "Return to Programme" calls `resetSession()` → `resetToIdle()`, which never clears the sentinel (`WorkoutSessionManager.swift:856-887`; the only clears are `finishSession` `:1401-1404` and `abandonSession` `:664`). On next launch, `ContentView` finds the sentinel and shows "Unfinished Workout" (`ContentView.swift:181-198`) for a session that never had a single set. Worse: tapping Resume on a 0-exercise day hits `resumeSession`'s guard `exerciseIndex < trainingDay.exercises.count` → `finishSession(earlyExitReason: nil)` (`WorkoutSessionManager.swift:820-824`) — the day completes, `onSessionCompleted` fires, and `markDayCompleted` records a workout that never happened.

**Why it matters:** Combined with F1, the worst first-week journey is: tap Workout tab → Start → error → relaunch → "Unfinished Workout from 9:41" (confusing, trust-eroding) → "Resume" → day silently marked done and the programme pointer advances past a session the user never trained. The AI's model then learns from an absence it thinks was a completion. This violates the project's own data-honesty law ("never fabricate data," `ui-overhaul-spec.md:115-127`).

**Recommendation:** Move the sentinel write after the exercises guard (or clear it on any transition to `.error` before sets are logged), and make `resumeSession` on an exhausted/empty day route to the mismatch dialog instead of `finishSession`.

---

### F3 · P1 — App killed mid-onboarding restarts the entire flow from step 1 and re-pays the LLM generation

**Evidence:** All onboarding progress is `@State` (`OnboardingView.swift:66-76`); the completion flag is written only in `completeOnboarding()` (`:960-966`). But durable side effects happen mid-flow: userId to Keychain and the `users` row in step 5 (`:898-933`), the scanned `GymProfile` to UserDefaults at scanner confirm (`ScannerViewModel.swift:274`), and the generated mesocycle cached at `:886`. A kill between step 5 and step 6 → relaunch shows step 1 with a blank name, step 4 shows "Open Gym Scanner" as if never scanned (`gymProfile` is seeded `nil`, never rehydrated from the saved profile, `OnboardingView.swift:68`), and step 5 re-runs `generateSkeleton` — a second paid LLM call that overwrites the cached program.

**Why it matters:** The gym scan is the longest, most physical part of onboarding (walking the gym with a camera). Losing it to a phone call or app kill and being asked to redo everything is a classic activation killer — and the program-regeneration is silent double cost.

**Recommendation:** Persist step index + profile answers incrementally (UserDefaults is fine), rehydrate `gymProfile` from `GymProfile.loadFromUserDefaults()`, and skip step 5 when a cached mesocycle already exists for this userId.

---

### F4 · P1 — Onboarding can end on a false success: "Your 12-week program is loaded" when no program exists

**Evidence:** If the scan was skipped, `runProgramGeneration` silently jumps to step 6 without generating anything (`OnboardingView.swift:864-868`). If generation failed and the user taps "Continue without a program" (`:657-665`), same destination. In both cases step 6's headline copy reads "Your 12-week program is loaded. Head to the Program tab to review it, then start your first session" (`:697`). Only the skip branch gets a small orange caveat (`:704-722`); the generation-failure branch gets a flat lie.

**Why it matters:** The very first promise the product makes is broken sixty seconds later when the Program tab shows "No Program Yet." First-session trust is the only trust a coach app has.

**Recommendation:** Branch step 6's copy on actual state: "Almost there — scan your gym to unlock your program" / "Generation didn't finish — we'll retry from the Program tab," with the CTA wired accordingly.

---

### F5 · P1 — The skipped-scan recovery path points at a tab that doesn't exist, and AI-failure copy points at settings users can't reach

**Evidence:** The Program tab's empty state for users without a gym profile says "Scan your gym in the **Scanner tab** to get started" (`ProgramOverviewView.swift:175`) — there is no Scanner tab; scanning lives behind Settings (`ContentView.swift:111-118,480-536`). Separately, session-generation failure tells the user "Check your **API key** and try again" (`ProgramDayDetailView.swift:1225`), but all API keys are entered only in `DeveloperSettingsView`, which is `#if DEBUG` (`SettingsView.swift:464-472`) — in a release build the Developer section renders as an empty header and there is no key entry anywhere, including onboarding (`AppDependencies.swift:96-127` reads keys from Keychain that nothing else populates).

**Why it matters:** These are the two recovery moments for the two most likely first-run failures (skipped scan; missing/invalid key), and both instructions are dead ends. The exact cohort that's already wobbling gets sent to a place that isn't there.

**Recommendation:** Fix the empty-state copy and make it a button (`switchToTab(3)` exists for exactly this, `ContentView.swift:580-589`). Decide where key setup lives for the alpha (onboarding step or a visible Settings row) and make error copy point at a real screen.

---

### F6 · P1 — There is no single "what do I do now" surface; the real next action is two taps deep and duplicated

**Evidence:** Default landing is the 48-card mesocycle grid; the next action (generate/start today's session) requires: find current week (auto-scroll helps, `ProgramOverviewView.swift:305-320`) → tap the right card → "Generate Session". The Workout tab *looks* like the shortcut but can't generate (F1). Two parallel start paths exist with different semantics: Tab 1 uses `nextIncompleteDay`, while the day detail can start any generated/past/future day, including "Scheduled — tap Start Workout to train this day early" and "Past session — re-run or backdate" (`ProgramDayDetailView.swift:482-500`). The day detail's bottom area can show up to three actions (Start / Log Past Session / Skip, `:759-831`).

**Why it matters:** A coach product's core promise is "I tell you what to do today." As built, the user assembles that answer themselves from a calendar. The spec already names the fix — a Today surface with one hero Start (`ui-overhaul-spec.md:32-42`) — but until it ships, the four-tab build has no moment with exactly one obvious action.

**Recommendation:** Treat the Today screen as the highest-priority slice of the overhaul, and in the interim make Tab 1 the de-facto Today (F1 fix gets you 80% there).

---

### F7 · P1 — Banner stacking and dismissal semantics: six possible pre-workout interstitials, X-dismissals that don't stick, and launch alerts that can collide

**Evidence — full inventory of home-surface interstitials:**
- Launch alerts on `ContentView`: "Unfinished Workout" (`:200`), "Session Not Found" (`:239`), "Programme Update" migration notice (`:263`). The migration flag and the crash sentinel are evaluated in the same `.task` (`:169-198`) — an upgrading user with a paused session arms two `.alert`s on the same view simultaneously; SwiftUI will drop or defer one nondeterministically.
- Pre-workout (Tab 1): paused-session banner (safe-area inset, `ContentView.swift:362-376`), resume-repair notice (inset, `WorkoutView.swift:230-256`), then in the scroll stack first-session, calibration-review *or* heavy-reassessment (precedence handled, `PreWorkoutView.swift:94-98`), welcome-back (`:99-101`). Three to four can legitimately co-render above the session card.
- Tab 0: sync-error overlay banner (`ProgramOverviewView.swift:74-78`).
- Tab 2: one undismissable `TrendBannerView` per non-progressing pattern — up to ~8 stacked (`ProgressView.swift:66-81`), with copy like "Programming on this pattern has calcified" (`TrendBannerView.swift:70`).
- Post-workout: late-arrival notices + partial badge + AI-fallback notice (`PostWorkoutSummaryView.swift:60-80`).

Dismissals on the calibration/heavy/welcome-back banners are view-local `@State` (`PreWorkoutView.swift:70-73`) — the X means "hide until this view is rebuilt," and the durable acknowledgment only happens if the user opens the review sheet *and saves* (`CalibrationReviewView.swift:289-297`; swipe-dismiss leaves the signal armed, `WorkoutView.swift:293-300`).

**Why it matters:** The user-visible contract of an X is "I saw this, stop showing it." Here the same banner returns next launch until the user performs a deeper ritual they were never told about. That trains users to ignore the banner channel — which is the channel the AI uses for its most important trust moments (re-calibration, level-up). The spec's "calm list, never pop-ups" rule (`ui-overhaul-spec.md:38-39`) is the right target; today's build is the opposite at launch (two alerts) and pre-workout (a stack).

**Recommendation:** Persist banner dismissals (X = acknowledge for signal-keyed banners, or at minimum a per-watermark snooze); enforce max-one-coach-banner with a queue; serialize launch alerts.

---

### F8 · P1 — The welcome-back banner asserts an adaptation the system may not have made

**Evidence:** At ≥14 days the banner says "We've adjusted today's session to ease back in" (`PreWorkoutView.swift:345-350`). Actual gap-adaptation happens only inside `generateDaySession` via `TemporalContext` at generation time (`ProgramViewModel.swift:540-590`; the hard return-phase override needs ≥28 days, `:588`). If the day's session was generated *before* the layoff — entirely possible since generated days persist — nothing was adjusted, and the banner is fabricating coach behavior.

**Why it matters:** This is precisely the failure the project's own data-honesty rules forbid ("every coach utterance is grounded in a number the user can verify," `ui-overhaul-spec.md:127`). One caught fib ("adjusted how? it's the same session I saw two weeks ago") devalues every future banner.

**Recommendation:** Only show the "we've adjusted" variant when the session was generated post-gap (compare generation timestamp vs last session date); otherwise offer the action instead: "It's been 24 days — regenerate today's session to ease back in?"

---

### F9 · P1 — The end-of-programme moment is a shrug into Settings

**Evidence:** When every day is terminal, Tab 1 shows a trophy and "Head to Settings to regenerate a new programme," CTA = "Go to Settings" (`ContentView.swift:440-476`), where "Regenerate Program" is a mid-form row (`SettingsView.swift:366-376`).

**Why it matters:** Programme completion is the single biggest retention/renewal handoff in the entire journey — twelve weeks of investment culminating in being routed to a settings form. There's also no review of what the cycle achieved at this moment (the data exists — projections, trends).

**Recommendation:** A "Start your next programme" primary CTA right there, which calls the same `regenerateProgram` path; ideally preceded by a cycle recap drawing on the calibration/projection machinery.

---

### F10 · P2 — A generated session can't be rejected or regenerated

**Evidence:** `generateDaySession` guards `day.status == .pending` (`ProgramViewModel.swift:419`); once generated, no UI offers re-generation. The only outs are per-exercise mid-session swap chat (`ActiveSetView.swift:231-236`) or nuking the whole programme from Settings.

**Why it matters:** The first thing the AI hands the user is a full session prescription with no "not this, coach" affordance at the planning moment — disagreement is only expressible set-by-set, mid-workout, when switching costs are highest.

**Recommendation:** Add "Regenerate this session" to the day detail for `.generated` untrained days (resets to `.pending`, reuses the existing path).

---

### F11 · P2 — The Program tab's generation-failure "Try Again" doesn't retry

**Evidence:** `errorView`'s "Try Again" calls `loadProgram()` (`ProgramOverviewView.swift:241-243`), which on an empty cache lands on the empty state (`ProgramViewModel.swift:124-151`) — the user must then find and tap "Generate My Program" again. The button promises a retry of generation but performs a reload.

**Recommendation:** Make it actually re-invoke `generateMacroSkeleton` when a gym profile exists.

---

### F12 · P2 — Stale duplicate `Features/Workout/` at the repo root will eventually bite a maintainer

**Evidence:** `/Features/Workout/{ExerciseSwapView,ExerciseSwapViewModel,InferenceRetrySheet}.swift` are older copies of the files in `/ProjectApex/Features/Workout/` — the root `InferenceRetrySheet` lacks the "Continue with last weights" escape hatch and the root view model lacks the libmalloc deinit fix (verified by diff). The Xcode project references only one set (`ProjectApex.xcodeproj/project.pbxproj:98-100,204-206`).

**Why it matters (journey-adjacent):** the next person who edits the wrong copy ships nothing, and the prompt for this audit itself treated them as a real surface. Flagging per repo rules — report, don't delete.

---

### F13 · P2 — Small trust/polish leaks

- **Empty "Developer" section header in release Settings** (`SettingsView.swift:464-472` — the `Section` is outside the `#if DEBUG`).
- **Unit inconsistency:** onboarding offers a kg/lbs toggle (`OnboardingView.swift:281-296`), Settings bodyweight is kg-only (`SettingsView.swift:284-296`), and all in-session weights render kg — a lbs user converts in their head mid-set forever. The spec's "unit choice persists app-wide" (`onboarding-calibration.md:80-82`) isn't built.
- **Tab-1 "Skip this session" marks the wrong day in the crash-resume case:** `onSkipSession` always uses `day`, ignoring `crashResumeDay`, unlike the completed/paused handlers right above it (`ContentView.swift:346-349` vs `:315-332`).

---

### F14 · P2 — Doc/code gap worth recording: the shipped onboarding contradicts the locked spec on the highest-friction step

**Evidence:** Shipped onboarding requires a physical camera walk-around of the gym at signup time (`OnboardingView.swift:494,547`) — a user signing up from their couch must skip, and the skip path leads into F4/F5. The designed replacement (`onboarding-calibration.md:39-97`) uses a tap-grid equipment select plus capability seeding, explicitly targeting <3 minutes. No implementation slices exist yet (`ui-overhaul-spec.md:7-9`). Time-to-first-value as built is: scan (minutes, gym-located) + skeleton LLM call ("under a minute") + a *second* hidden LLM call (Generate Session, up to 120s) before the first set — three sequential AI waits across two surfaces, only two of which onboarding warns about.

**Recommendation:** When building the new onboarding, also collapse the third wait: pre-generate session 1 during the model-reveal beat so "Start when ready" is genuinely one tap.

## 3. The three things to fix first

1. **Make the Workout tab able to do its one job (F1 + F2).** Today, the tab named "Workout" can't start a workout on any not-yet-generated day — it errors, plants a phantom "Unfinished Workout" alert on the next launch, and that alert's Resume button can mark an untrained day as complete. Put "Generate Session" on the pre-workout screen, and stop writing the crash sentinel before the session is viable. This single fix removes the worst dead end *and* most of the buried-next-action problem while the Today screen is still on the drawing board.

2. **Never claim what didn't happen (F4 + F8).** Two places say something false: "Your 12-week program is loaded" when generation failed or was skipped, and "We've adjusted today's session" when nothing was adjusted. The project's own design law is "every coach utterance is grounded in a verifiable number" — enforce it on these two lines now, not in Phase 3. They're copy-level changes with outsized trust impact.

3. **Make dismissal mean dismissal, and fix the two dead-end instructions (F7 + F5).** Persist banner acknowledgments (X should stick, or visibly snooze), cap the pre-workout stack at one coach banner, and serialize the launch alerts. Fix "Scan your gym in the Scanner tab" (no such tab) and "Check your API key" (no key UI in release) — both currently send your most fragile users to places that don't exist.

The live workout loop itself — pause durability, write-ahead queue, retry sheet with honest fallbacks, set-correction memory — is the strongest part of the product and well ahead of most consumer fitness apps. The journey problems are concentrated *around* it: getting into the loop the first time, getting back into it each week, and what the app says when the AI didn't do the thing.
