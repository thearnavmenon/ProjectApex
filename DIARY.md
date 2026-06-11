# Project Apex — Work Diary

A plain-language diary of work that gets pushed and merged, written in simple words —
like a journal, not a technical log. Newest entries go on top.

Started 2026-06-07.

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
