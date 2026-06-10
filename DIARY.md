# Project Apex — Work Diary

A plain-language diary of work that gets pushed and merged, written in simple words —
like a journal, not a technical log. Newest entries go on top.

Started 2026-06-07.

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
