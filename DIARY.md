# Project Apex — Work Diary

A plain-language diary of work that gets pushed and merged, written in simple words —
like a journal, not a technical log. Newest entries go on top.

Started 2026-06-07.

---

## 2026-06-29 — The coach can now notice when a muscle is getting *too much*

**The problem (in plain words):**
The coach tracked a *floor* for each muscle — "you're below the amount of work
that grows this muscle, do more." But it had no *ceiling*. So it could never
notice the opposite problem: hammering one muscle past the point where more sets
actually help (and just dig a recovery hole). There was simply no signal for
"this is too much volume."

**What I changed:**
Added a sensible upper limit per muscle (a research-style "you probably shouldn't
exceed this" number, scaled to your training frequency the same way the floor is)
and an "over-volume" reading: how far past that limit your recent sets are, zero
if you're under it. It's **advisory only** — it does NOT cap or cut your sets;
it just gives the coach an honest signal so its advice can reflect reality. The
new numbers also show up in the summary the coach reasons over. Older saved
profiles that don't have these fields yet just read as zero — nothing breaks.

**How it was checked:**
23 server-side tests pass (4 new for the ceiling + over-volume math), an
end-to-end database test proves the signal shows up after a heavy session, and
the iOS app builds clean with two new tests proving old saved data still loads
and the new fields survive a save/load round-trip.

**Heads-up for deploy:** server-side coach change — live only after
`supabase functions deploy update-trainee-model`. (#570, part of #558 / ADR-0030.)

---

## 2026-06-29 — Volume targets now match how often you actually train

**The problem (in plain words):**
The coach has a target for how many hard sets each muscle should get. That
target was baked in assuming everyone trains about 4 times a week. But the way
it's measured is "sets over your last 7 workouts for that muscle" — and 7
workouts is a different amount of time depending on how often you train. If you
train a muscle 6×/week, 7 workouts is barely over a week, so the fixed target was
actually ~145% of what a week should be — too high. If you train it 2×/week, 7
workouts spans 3+ weeks, so the same target was only ~57% of a week — too low. So
high-frequency people looked permanently "under target" and low-frequency people
looked "done" when they weren't.

**What I changed:**
The target now scales to how often you actually train each muscle (read straight
from the timestamps of your own sessions for that muscle). Train it more often →
the per-window target comes down to match a sensible weekly amount; train it less
often → it goes up. At 4×/week nothing changes. I capped the scaling to a sane
range so someone training once a week (or twice a day) doesn't get an absurd
number. Important detail I got right: the target is always recalculated from the
fixed baseline, never from last time's already-scaled number — otherwise it would
quietly drift lower and lower every workout.

**How it was checked:**
19 automated tests on the math (8 new — including one that proves it does NOT
drift when you train at a steady pace), plus a full end-to-end test that runs in
CI against a real database. The existing targets tests still pass (a brand-new
user with one session sees the same baseline as before).

**Heads-up for deploy:** server-side coach change — live only after
`supabase functions deploy update-trainee-model`. (#164, part of #558 / ADR-0030.)

---

## 2026-06-29 — Stop pushing muscle-builders into a powerlifter's "peak"

**The problem (in plain words):**
The app runs a little engine that decides, for each lift you do, what "phase" of
training you're in — building volume, pushing intensity, peaking (going very heavy
for a few reps), or deloading (an easy week). The catch: it cycled *everyone*
through that same loop, including the "peaking" phase, no matter what their actual
goal was. Peaking is a powerlifting idea — very heavy, very few reps. If your goal
is just to build muscle, getting shoved into a heavy low-rep peak is the wrong
training. So a muscle-building user could quietly end up doing a strength-peaking
block they never wanted.

**What I changed:**
The engine now looks at your goal first. If your goal actually says strength (or
"max weight", "powerlifting", "1RM"), nothing changes — you still get the full
loop with peaking. For everyone else — muscle size, endurance, general fitness, or
if no goal is set — the loop now skips peaking entirely and goes building → harder
→ easy week → repeat. I deliberately made "skip the peak" the safe default: if the
app is ever unsure, it will NOT peak you, because wrongly peaking someone is the
bug we're fixing.

**How it was checked:**
Twenty automated tests on the engine pass (the seven new ones cover both the
strength loop staying the same and the new "skip peaking" loop), plus the 38 tests
on the code that feeds the engine. This is the first piece of a larger
program-generation overhaul (decision write-up ADR-0030, now accepted).

**Heads-up for deploy:** this is a server-side coach change — it goes live only
after `supabase functions deploy update-trainee-model` is run. Until then nothing
changes for anyone. (#559, part of #558; ADR-0030 accepted via #557.)

---

## 2026-06-29 — Stop the coach from going "offline" mid-workout

**The problem (in plain words):**
Too many times in the middle of a workout, the app would say "Coach is offline"
and you'd have to tap "Try again" two or three times before your next set finally
came through. Really annoying. I dug in and found two reasons. First, the coach
was talking to the internet using the phone's default settings, which try a newer
fast connection method (called QUIC) that some Wi-Fi and phone networks choke on —
the connection just hangs. We'd already hit this exact thing on the login screen
months ago and fixed it there, but the coach never got the same fix. Second, the
app *was* supposed to quietly retry on its own, but it was wired so all the retries
had to finish inside an 8-second window — and the waiting between tries alone ate
up those 8 seconds, so the automatic retry basically never got a real shot. That's
why *you* ended up doing the retrying by hand: every tap opened a brand-new
connection, and eventually one wasn't stuck.

**What I changed:**
Gave the coach the same reliable connection the login screen already uses — one
that avoids the flaky QUIC method and rides out brief network blips. And I rewired
the timing so the app now gets up to about 30 seconds to quietly retry on its own,
opening a fresh connection each time, before it ever bothers you with the "offline"
message. I picked the patient setting on purpose so it tries hard before giving up.

**How I checked:**
Built the whole app clean (no errors) on the iPhone 17 Pro simulator. I left the
safety net in place: if the network is genuinely dead, it still falls back to your
program's planned weights rather than guessing. I only touched the coach's
connection and its retry timing — nothing about how your sets or weights are
decided changed.

**Status:** Merged to main — PR #555. Note for later: the "Start Workout" screen
and the exercise-swap chat use the same old flaky connection and could stall the
same way; I left those alone for now and flagged them as a follow-up.

---

## 2026-06-29 — New bottom tab bar (the black one with the white block)

**The problem (in plain words):**
The bar at the bottom of the app — the one that switches between Program,
Workout, Progress and Settings — was still Apple's standard bar with a coat of
black paint over it. It couldn't do the look we wanted: a clean white block
sitting over whichever tab you're on. So I built our own bar from scratch to
match the rest of the app's blunt black-and-white style. The white block marks
the active tab; the lime-green colour stays reserved for buttons you press, not
for navigation.

**What I changed:**
Replaced the built-in bar with a custom one. The hard part was a surprise from
the latest iPhone software: the new floating "glass" bar Apple added simply
*won't go away* when you ask the normal way — it just hides behind your own bar
and pops back out the moment the layout shifts. I figured out the trick that
actually banishes it, and a second one so your screen's content always sits
neatly *above* the bar instead of sliding underneath it. I tested both in a
throwaway sandbox app with the real moving parts before touching the actual app,
so I wasn't guessing.

**How I checked:**
Built the whole app clean (no errors) on the iPhone 17 Pro simulator, and proved
the bar behaves — no ghost bar, content sits above it, white block on the right
tab — with real screenshots in the sandbox. Nothing about how the app *works*
changed: tabs switch the same, sessions and the paused banner are untouched.
It's purely how it looks.

**Status:** Merged to main — PR #553, part of #538. This is the first of three
linked pieces; next up are the consistent bottom action button and the
redesigned pre-workout screen.

---

## 2026-06-22 — The app now remembers when a set hurt (groundwork)

**The problem (in plain words):**
During a workout you can tap "something hurt" or "my form broke down" after a
set. Until now the coach only used that in the moment — it was forgotten the
instant the workout ended. So it could never notice "you've flagged your
shoulder on bench three weeks running." Genuinely useful information was being
thrown away.

**What I changed (the groundwork half):**
Gave those flags a permanent home in the database and started saving them
against every set you log. This is deliberately just the plumbing: the flags
are now kept safely, but the coach doesn't yet read your *history* of them or
change its advice because of it. That next step is held back on purpose —
deciding how the coach should react to a run of pain flags is a careful,
safety-related call I want to make properly rather than by default. I also
taught the server to check the flags so only real ones ("pain", "form broke
down") can be stored.

**How I checked:**
Ran the server test suite — 38 checks pass, including five new ones for good
flags, no flags, and bad flags being turned away — and built the whole app
clean (no errors). It's backwards-safe: every set saved before today simply
counts as "no flags".

**Status:** Merged to main — PR #550, part of #43. The "actually use the flag
history to coach" half stays as its own follow-up. (Carried a small live
database change, applied on merge.)

---

## 2026-06-22 — Stopped a test from failing at random

**The problem (in plain words):**
One of our automated checks would sometimes fail for no real reason — a
coin-flip, not a genuine bug. It was the test that makes sure the app handles
"you're offline" gracefully. Behind the scenes, when the internet is down the
app quietly retries a few times (waiting 1, then 2, then 4 seconds) before
giving up, all inside an 8-second budget. The test insisted on one exact
outcome ("gave up with an error message"), but a tiny bit of random timing
meant the app would sometimes hit the 8-second budget first and report "timed
out" instead. Both are perfectly fine ways to say "you're offline" — but the
over-strict test treated the second one as a failure, so it flaked, especially
on the busy build server. That red check kept showing up on unrelated changes.

**What I changed:**
Loosened the test to check what actually matters: when the network fails, the
app never pretends it worked, and it always shows a real message — accepting
either "error" or "timed out" as a valid offline outcome. I changed nothing
about how the app behaves; only the test got more honest. (I left a note that
the deeper question — whether "no internet" should be retried at all — is a
separate decision for another day.)

**How I checked:**
Built and ran the test three times in a row — passed every time, zero failures.

**Status:** Merged to main — PR #548, part of the pre-launch hardening list
(#369). Clears the recurring random red check that had been appearing on
unrelated pull requests.

---

## 2026-06-22 — Two clean-ups: a tidier memory, and choosing how a hand-added set counts

**The problem (in plain words):**
Two unrelated loose ends from a backlog pass. First, behind the scenes the
coach keeps a little list of the dates you trained each movement — and that
list quietly grew forever, one date added every workout, slowly bloating your
saved profile. Second, when you add a set by hand to a finished workout, the
app always filed it as a "backoff" set with no way to say otherwise — even
though that label changes how the coach reads the set.

**What I changed:**
- The coach now keeps only the last 10 training dates per movement instead of
  an ever-growing list. Everything that uses those dates only ever looks at
  the recent ones, so nothing it does changes — the saved data just stops
  bloating. Older extra dates get trimmed the next time that movement is
  trained.
- The "Add Set" sheet now has an intent picker — the same warmup / top /
  backoff / technique / AMRAP chips the live workout uses. It still starts on
  "backoff" (the sensible default for a set added after the fact) but you can
  change it before saving, and your choice is what the coach actually records.
  I also made the sheet scroll so the Add button is always reachable.

**How I checked:**
- The memory trim: ran the server test suite (94 tests green, including new
  ones proving the trim drops the oldest dates, keeps everything when under
  the limit, and never touches the separate session counter the coach learns
  from).
- The intent picker: built the whole app clean (0 errors, iPhone 17 Pro). Not
  yet eyeballed on a real device — reaching that sheet needs a finished
  workout with logged sets — but the chips are a direct reuse of the live
  workout's, so the look should match.

**Status:** Both shipped to main — PR #539 (#292, memory trim, auto-deployed
to the server) and PR #545 (#65, intent picker). Part of an "auto mode"
backlog-cleanup pass.

---

## 2026-06-22 — The last few screens now match the rest of the app

**The problem (in plain words):**
Most of the app already wears the new "Brutalist" look — pure black, bold
condensed type, one lime highlight for the main action. But a handful of smaller
screens never got the makeover and still showed the old dark-navy-and-blue style,
so they stuck out. None of them are screens you see every day, which is why they
were left for last: the "no program yet" and "all done" messages on the Workout
tab, the workout error screen, the little amber "workout paused" banner, the
equipment list you reach from Settings, and the "this build needs setup" notice.

**What I changed:**
Restyled all of them to the shared look and pulled out the leftover blue. The
Workout tab's empty and finished screens, the error screen, and the paused banner
now use the same black background, bold type, and lime/amber accents as everything
else. The equipment screen (where you add or tweak your gym gear) got the same
treatment. The tab bar along the bottom also picked up a black, no-more-blue style.
Nothing about how any of these screens *work* changed — only how they look.

**How I checked:**
Built the whole app cleanly for each change and once more all together at the end —
every build passed. Two notes for me: a couple of system pop-ups (the "session
mismatch" and confirm dialogs) can't be repainted — iOS draws those itself — so
they're left as-is; and the bottom tab bar's exact selected colour is a judgement
call I made (white on black) that's worth an eyeball on a real phone.

**Status:** Shipped — PRs #540, #541, #542, #543, #544. Umbrella #538 stays open
until I've looked at them on a real device. The debug-only developer screen was
deliberately skipped (it never ships to anyone).

---

## 2026-06-21 — The coach now actually uses your gym machines

**The problem (in plain words):**
We'd taught the app to *capture* gym machines (even custom ones), but the coach
still wasn't reliably *using* them. Two gaps: several machines had no matching
exercises in the coach's catalogue, so they were dead weight; and when the coach
occasionally picked an exercise needing gear you don't have, the app just shrugged
and let it through.

**What I changed:**
Added proper exercises for the machines that were missing them (rear-delt /
reverse fly, assisted dip and pull-up, hip-thrust machine, calf-raise machine,
T-bar row), so every machine you can list now maps to at least one real exercise.
And the coach now strictly sticks to your equipment: if it ever prescribes
something you can't do, the app drops that exercise — with a firm safety rule that
it will never hand you an empty workout (bodyweight moves always count). The retry
message the coach sends itself on a slip-up now uses the same clear equipment names.

**How I checked:**
Built the whole app and ran the new tests — 6 of them covering the enforcement,
including the "never empty a session" safety rule and a custom machine being
allowed. (One note for me: the build agent stalled partway, so I finished and
verified this slice by hand, including fixing a Swift concurrency error it left.)

**Status:** Shipped — PR #536, the last slice of the onboarding overhaul (#527).
That completes the whole overhaul: new welcome flow, injuries, manual equipment +
presets, the camera removed, and the coach now reliably using your machines.

---

## 2026-06-20 — Out with the camera, in with smarter equipment

**The problem (in plain words):**
The camera "scan your gym" feature had quietly stopped earning its keep, and the
new setup flow already moved to picking a gym preset and tweaking a list — so the
camera was dead weight. Separately, the coach only ever saw bare code-words for
your gear (like "chest_press_machine") and was handed the *entire* exercise
catalogue on every plan, including exercises you can't even do.

**What I changed:**
First, deleted all the camera / photo-recognition code and pointed the leftover
"set up / edit your equipment" spot in Settings at the same simple list the setup
flow uses. The app no longer asks for camera permission at all. Second, the coach
now gets proper equipment *names* alongside the codes (so even a custom machine you
typed in is understood), and it's only shown exercises you can actually do with
your equipment — bodyweight moves always included. That makes it far more reliable
at choosing machine exercises for people whose gym is mostly machines.

**How I checked:**
Built the app, ran the tests, and swept the whole codebase to confirm nothing still
pointed at the deleted camera code. (Heads-up: removing the camera also removes
"Camera" from the app's store privacy label.)

**Status:** Shipped — PR #533 (camera removal) and PR #534 (smarter equipment),
part of #527. One more piece to come: making sure every machine has matching
exercises and the coach strictly sticks to your equipment.

---

## 2026-06-20 — Saving your injuries, and letting you add any gym machine

**The problem (in plain words):**
Two behind-the-scenes pieces of the setup overhaul. The new "anything to work
around?" question looked nice but didn't actually do anything yet. And gym
machines were a mess: lots of gyms have machines we had no name for, and there
was a hidden bug where even if you added a custom one, its name got thrown away
before the coach ever saw it.

**What I changed:**
First, injuries: if you tap "bad shoulder" or "dodgy knee", the coach now records
it as a confirmed injury and avoids programming straight into it from your very
first session — instead of slowly piecing it together from your workout notes over
weeks. It's saved safely on the server and won't overwrite anything the coach has
already learned. Second, machines: you can now type in any machine we don't list,
its name actually reaches the coach now, and I added several common machines that
were missing (reverse-fly / rear-delt, assisted dip/pull-up, hip-thrust,
calf-raise, T-bar row).

**How I checked:**
Built the app and ran the tests — including new ones proving custom machine names
survive saving and loading without corrupting anyone's existing gym list, and that
re-doing onboarding doesn't duplicate or reset an injury.

**Status:** Shipped — PR #530 (injuries) and PR #531 (machines), part of the
onboarding overhaul (#527). One reminder: the injuries feature needs the
"update-trainee-goal" server function redeployed by hand (this project deploys
those manually, not automatically).

---

## 2026-06-20 — The setup flow starts its big makeover

**The problem (in plain words):**
The very first thing you see after installing — the setup flow — was the last
part of the app still wearing the old blue, rounded look. Worse, it was just a
wall of questions: no welcome, and no explanation of what the app even does or why
it's different from every other gym app.

**What I changed (this first piece):**
Rebuilt the whole setup flow in the app's black-and-lime look, and reshaped it.
Now it opens with a short welcome and a three-card "here's how your coach works"
explainer (it's a real coach, it learns you, it's honest). It asks one thing per
screen instead of one big form. It leads with your bodyweight — the number the
coach actually uses to pick your first weights — while clearly marking height and
age as optional. It adds a quick "anything to work around?" injury question and a
sex question (both help the coach calibrate). And it ends on a "your program is
ready" screen that shows your plan and the loop the coach runs on every set. The
old camera "scan your gym" step is being replaced by picking a gym preset and
tweaking a list — this piece wires that up using the equipment picker we already had.

**How I checked:**
Built the real app and took screenshots of the actual screens (welcome, bodyweight,
injuries, equipment, the finish screen) — they match the mockups we approved. All
the behind-the-scenes saving (your program, your profile, the coach setup) was kept
exactly as before.

**Status:** Shipped as the first slice — PR #528, part of the onboarding overhaul
(#527). Still to come: saving the injury answers, removing the old camera code, and
the bigger backend work to make the coach reliably use gym machines.

---

## 2026-06-19 — The Progress tab now matches the rest of the app

**The problem (in plain words):**
Every screen in the app got the new look months ago — pure black, big bold
condensed numbers, one bright lime colour for the important thing. Every screen
except one: the Progress tab. It was still wearing its own old outfit — a dark
mint-green "dashboard" style from an earlier redesign. So jumping to Progress felt
like walking into a slightly different app.

**What I changed:**
Gave the Progress tab the same look as everywhere else, without changing a single
number it shows:
- The big "strongest lift" number up top is now the giant bold tabular style (the
  whole number counts up when you've gained, with the decimal and "KG" sitting quietly
  beside it).
- The trend chart line, the pulsing "latest" dot, the personal-record dots (gold), and
  the "you're behind on this muscle" warnings (amber) all use the app's shared colours.
- Sharp-cornered cards with thin hairline edges instead of the old rounded mint cards.
- The weekly-volume bar chart keeps a colour per muscle (it's the one place colour
  actually means something), but I retuned them to muted tones and made sure chest is
  no longer lime — lime is reserved for the one accent.
- Deleted the old separate colour file the Progress tab used to carry around.

Nothing about the data or the honesty changed: every insight still hides itself when
there's nothing real to show.

**How I checked it:**
Built mock versions in the prototype playground first and got the look signed off,
then built the whole app clean and took a real screenshot of the live Progress screen
to confirm it looks right in the actual app (using a throwaway hook that I removed).

**Status:** Shipped to main — PR #525, part of #524 (kept open for a final look on a
real phone).

---

## 2026-06-19 — A "how it works" page that explains the coach two ways

**The problem (in plain words):**
The build-log site showed what the app looks like and how I designed it, but never
the actually-interesting part: how the coach thinks. How does it decide what weight
to tell you? How does it learn who you are? People had to take "it's smart" on faith.

**What I changed:**
Added a new page that explains the coach and its "brain" two ways, with a toggle to
flip between them:
- A plain version for anyone: how it learns you instead of using averages, why it
  picks the exact weight it does, how it remembers the notes you leave it, how it
  sharpens every session, and the fact that it won't make a number up.
- A technical version for developers: the real internals. The three-layer memory,
  the actual formulas (how it estimates your strength, smooths it, sets your
  targets), how it grades and corrects its own past advice, the architecture, and a
  "the hard parts" section with the genuine bugs and complications that shaped it.
  The deepest details tuck behind "go deeper" toggles so it isn't a wall of text.
All of it pulled from the real code, including the honest caveats (like which model
it actually runs). I also added my Instagram and LinkedIn to the footer.

**How I checked it:**
Wrote it off three deep reads of the codebase so the technical claims are accurate,
built the site (now 16 pages), opened both versions to check the toggle, the
diagrams, and the formulas all render right, took the em-dashes out to match the
site style, then pushed it live and confirmed both versions and the new links work
on the real site.

**Status:** Shipped and live at thearnavmenon.com/how-it-works.

---

## 2026-06-19 — Tidied the muscle name on the day screen

**The problem (in plain words):**
On a day's exercise screen, the little summary line at the top spelled out the
full muscle name — "3 EXERCISES · PECTORALIS MAJOR" — while the calendar showed
the friendly short version, "CHEST". Small inconsistency, but it looked untidy.

**What I changed:**
Made that summary line use the same short names the calendar uses, so it now
reads "3 EXERCISES · CHEST · TRICEPS." (The detailed name under each individual
exercise is left as-is.)

**How I checked it:**
Built the app clean and confirmed it compiled.

**Status:** Merged (PR #521, under umbrella #507).

---

## 2026-06-19 — The Program top card now knows when a workout is paused

**The problem (in plain words):**
On the new Program screen, the big card at the top always said "NEXT UP — Start
workout." But if I'd already started a session and paused it part-way (say my
Pull day), the card still said "Start workout" — as if nothing was going on. It
ignored the fact that a workout was sitting there paused, waiting to be resumed.

**What I changed:**
The top card now reads the app's live-session tracker and shows the real state:
- If a workout is **paused**, it turns amber and says "PAUSED — Resume workout"
  (taking you straight back into it).
- If a workout is **live right now**, it says "LIVE NOW" and even shows how many
  sets you've done.
- Only when nothing is going on does it fall back to "NEXT UP — Start workout."

**How I checked it:**
Built the app and ran it in the simulator with a fake paused session for the
Pull day — the top card correctly showed the amber "PAUSED — Resume workout" for
Pull A instead of the old "Start workout." Photographed it to confirm.

**Status:** Merged (PR #519, under umbrella #507).

---

## 2026-06-19 — A "how I designed it" page on the build-log site

**The problem (in plain words):**
The build-log site showed the finished app and the finished site, but not the
part I find most interesting: all the options I tried and threw away to get
there. There was nowhere that showed the actual creative process.

**What I changed:**
Added a new page (reachable from the homepage and the footer) that walks through
every design decision as a little "here's what I tried, here's what I kept". For
each one it lays the options out side by side with the version that actually
shipped marked. It covers both the app and this site:
- The workout screens, built three different ways (a data-heavy "instrument"
  one, a stark "brutalist" one, and a calm one). Brutalist won, and then I
  rolled that look across the whole core flow.
- Four ways I tried to put my name on the site's front page, then I cut the name
  entirely and just called it "Build Log".
- The page layout, the diary section, the share card, and the tab icon, each
  with the options I weighed.
I picked the page's own layout the same way I pick everything visual: rendered a
few versions and chose one. The old option images were just scratch files spread
across two folders, so I cleaned up and shrank the good ones into the site.

**How I checked it:**
Built the site (now 15 pages), opened it locally to confirm every image loaded
and the "shipped" picks were marked right, then pushed it live and checked the
new page, its images, and the homepage link all work on the real site.

**Status:** Shipped and live at thearnavmenon.com/design.

---

## 2026-06-19 — The build-log website got a polish pass

**The problem (in plain words):**
The build-log website — the public page where I write up each day's work — had a
pile of small rough edges. The diary titles still showed my internal shorthand,
things like "(#423)" or "(Phase 3 UI, commit 1 of 2)", so it read like a task
tracker instead of a journal. Sharing a link showed no preview card, and there
was no little icon in the browser tab. The phone screenshots on the homepage
were about four times bigger than they needed to be, so the page was heavier
than it should be. And some of the faint grey text was too dim to read.

**What I changed:**
A batch of small fixes, built in parallel by a handful of agents and shipped
together:
- Stripped the internal issue/phase shorthand off the shown titles — but kept
  the real-words asides like "(the real reason saves were failing)", and the
  #123 chips still show on the status line.
- Added a proper share card (a bold "WHAT I'VE BEEN WORKING ON" poster) and a
  tab icon (a lime grid with a little dumbbell cut out of it). I rendered a few
  options for each and picked.
- Made shared day-links friendlier: a real headline, a one-line "what is this
  app" note at the top, and a proper page description.
- Shrank the phone screenshots to a modern format (about 980KB down to ~150KB)
  and told the browser to cache the images for a long time.
- The commit totals on the heatmap now count up when they scroll into view.
- Bumped the faint grey text so it's readable, and put a visible outline back on
  entries when you tab onto them with the keyboard.
- Added a small footer, a robots file, and a sitemap so search engines find it.

**How I checked it:**
Built the site (still 14 pages, no errors) and clicked around a local copy — the
titles are clean, the share card and icon show up, the day pages have headlines,
and the screenshots are sharp but small. Then pushed it live and checked the real
site: the preview card, the icon, the sitemap, and the long-cache headers are all
serving from thearnavmenon.com.

**Status:** Shipped and live at thearnavmenon.com (build-log site repo). No
separate issue tracker for that repo, so it landed straight on its main.

---

## 2026-06-19 — The Program tab got the full redesign

**The problem (in plain words):**
The Program tab — the screen that shows your 12-week plan and the screen that
shows a single day's exercises — was the last part of the app still wearing the
old look. Everything else (workouts, settings) had moved to the clean black
"Brutalist" style, so the Program tab stuck out. It was also a bit dumb: it
listed the plan but never told you what to do next, never showed how you did
last time, and never explained why a deload week was a deload.

**What I changed:**
First I rebuilt both screens in fake-data prototypes so I could see the new look
before touching the real app, and got it signed off. Then a panel of four
reviewers (a product person, a designer, a serious-lifter, and a "keep it
simple" skeptic) suggested upgrades and I picked the good ones. The real work
shipped as six small pieces:
- Both Program screens restyled to the black/condensed/volt-lime identity.
- A "NEXT UP" card at the top of the calendar with a big Start button — the
  screen finally tells you what to train next.
- Each exercise now shows what you lifted last time (with an up arrow if you're
  improving) and your floor/stretch targets.
- Completed days now show the coach's note explaining why it picked each weight
  (we already wrote that note — we were just throwing it away).
- A one-line reason on deload weeks, and the per-lift progress strip now shows
  trend arrows and "transitioning" markers.

Where the data didn't really exist (a fake session-length, a made-up deload
percentage), I deliberately left it out rather than invent numbers.

**How I checked it:**
Each piece built green on its own; I scanned every change to confirm it only
touched the look, not the behaviour, before merging. Then I built the whole app
together (green) and ran it in the simulator with sample data to photograph both
real screens — the new calendar and day view look right in the actual app, not
just the mockups.

**Status:** All six pieces merged (PRs #508, #509, #510, #511, #512, #514) under
umbrella #507. Holding the umbrella open until I sign off on the look on a real
device. One tiny follow-up noted: the day-header focus line shows the long
muscle name instead of the short one.

---

## 2026-06-19 — The build-log site now updates itself

**The problem (in plain words):**
I put the public build-log website online, but it was a frozen snapshot — the
diary and the green commit-graph on it only showed data up to the day I built
it. Every time I shipped something new, the site would quietly fall behind
unless I copied files across by hand.

**What I changed:**
Added a small robot (a GitHub Action) to this repo. Now every time I push my
work, it counts up my commits for each day, grabs the latest diary, and sends
both over to the website's own repo automatically. The website notices and
rebuilds itself a minute later, so it always shows my newest days without me
touching it. I also made the commit-graph stretch to the most recent day with
activity, so brand-new days actually appear instead of stopping at an old date.

**How I checked it:**
Merged it and watched the first run go green, then looked at the website's repo:
the robot had pushed today's diary and a fresh commit count that now includes
today (it didn't a minute before). The whole loop works start to finish.

**Status:** Merged to main (#513). The build-log site lives in its own repo and
went live on Cloudflare earlier today; this is the piece that keeps it fresh.

---

## 2026-06-19 — Two fixes to the mid-workout flow

**The problem (in plain words):**
Two annoyances during a workout. First, when you finished a set and the "How
did that set feel?" popup came up, the "Log set" button was hidden below the
fold — you had to swipe up every single time just to reach it. Second, when you
finished an exercise, a "Set Complete" screen flashed up that still used the old
plain-looking design, out of step with the rest of the app.

**What I changed:**
- The "How did that set feel?" popup now sizes itself to its contents, so the
  Log set button is always on screen — no more swiping up. It grows on its own
  if you open the "Add detail" section.
- The end-of-exercise moment got a fresh look: a volt-lime "done" stamp that
  pops in, the exercise name, and a small "next up" line so it feels like you're
  moving forward instead of hitting a wall. It keeps the same brief timing as
  before (that pause quietly loads the AI's plan for your next exercise), adds a
  little success buzz, and respects the "reduce motion" setting.

**How I checked it:**
Proved the popup-sizing trick in the isolated prototype harness first (the Log
set button sits fully clear of the home bar), got the new "exercise complete"
look signed off from a prototype render, then built the real app clean for both.

**Status:** Both merged to main — popup fix (#504), exercise-complete restyle
(#505). Visual/behaviour only; no workout logic touched.

---

## 2026-06-19 — Redesign playbook now includes a "what can we improve?" step

**The problem (in plain words):**
Our screen-redesign process only covered making a screen *look* right. But a
redesign is also the best moment to ask "what's missing here, or what could be
better?" The Settings redesign proved that out, so I wrote the step down so we
do it every time.

**What I changed:**
Added a step to the redesign playbook: an optional panel of agents that reviews
a screen from different angles — product, visual, an expert user, and a skeptic
who pushes back on adding too much — covering what's missing, what to add, and
how it looks and feels. The panel hands back a short list, the user picks, and
the chosen ideas get prototyped and built like any other change.

**How I checked it:**
Docs-only change to the redesign guide; merged via PR.

**Status:** Merged to main (#502). The how-to lives in
`docs/agents/screen-redesign.md` (Phase 2.5).

---

## 2026-06-18 — Settings tab redesign (part 2): new features

**The problem (in plain words):**
With Settings now looking right, it was missing things people actually need —
and a couple of useful screens were buried. A design panel of agents reviewed the
page and suggested the additions; this delivers the ones we picked.

**What I changed:**
- Training days and your goal can now be changed right from Settings. Before,
  the only way was to redo onboarding. Your change is used the next time you
  regenerate your program (it doesn't regenerate on its own).
- A "Review targets" row reopens the targets screen any time — it used to only
  show up as a one-time banner you couldn't get back to.
- A new "Sex" field (male/female) that the AI coach actually uses, so a first
  workout isn't accidentally weighted for the average man. Leaving it blank keeps
  today's behaviour, so nobody is forced to answer.
- A real "Reset all data" button (red, with an "are you sure?") to start fresh —
  this used to be hidden in the developer-only screen. It runs the exact same
  wipe code as the developer version (one shared function), so the important part
  — clearing your signed-in session — can't drift out of sync.

**How I made sure it works:**
Each feature was built by its own agent in an isolated copy, one pull request
each, and I built every one here before merging — the reset was also built in
Release mode to prove it works outside developer builds. Then I built the whole
app together (BUILD SUCCEEDED, iPhone 17 Pro / iOS 26.5) and took a real
screenshot of the live Settings screen.

**Status:** Merged to main — #498 (program controls), #499 (sex field), #500
(release-safe reset), all part of #494. The umbrella stays open until final
visual sign-off.

---

## 2026-06-18 — Settings tab redesign (part 1): the look

**The problem (in plain words):**
The Settings tab still looked like a plain old iOS list while the rest of the
app had moved to the bold black-and-lime look. This makes Settings match — and
fixes a control that felt clunky.

**What I changed:**
The whole Settings screen was rebuilt in the new look: pure black, big bold
numbers for your bodyweight/height/age, sharp-cornered cards, and the lime
accent used only on the "add" action. The equipment list's old on/off switch
for "bodyweight only" — which was confusing and, being orange, looked like a
warning — is now a clear two-button "LOADABLE | BODYWEIGHT" choice. The
"Add Equipment" sheet got the same treatment. Only the looks changed: editing
your details, swiping to delete equipment, re-scanning, and regenerating your
program all work exactly as before.

**How I made sure it works:**
Two agents rebuilt the two files in isolated copies, one pull request each. I
built the app here (BUILD SUCCEEDED, iPhone 17 Pro / iOS 26.5) and took a real
screenshot of the live Settings screen to confirm it looks finished before
merging — the same "show it for real" check the abandoned redesign skipped. I
also tightened the cards to the app's sharp 4pt corners after a first pass came
out too rounded.

**Status:** Merged to main — #496 (the screen) and #495 (the add-equipment
sheet), both part of #494. Next: a few small new Settings features (training-days
& goal editing, a re-open for the targets review, a sex field, and a release-safe
reset), then final sign-off.

---

## 2026-06-18 — Redesign finished: every workout screen now matches

**The problem (in plain words):**
After the first few screens, the rest of the workout still looked like the old
app. This finishes the job — every remaining workout screen now wears the same
bold black-and-lime design, so the whole workout finally feels like one app
instead of a patchwork.

**What I changed:**
The remaining eleven workout screens were rebuilt in the new look: the paused
screen, the floating "now training" pill, the weight-adjust sheet, the in-workout
plan list, the "swap this exercise" chat, the manual/past-workout log, the
"my gym doesn't have this weight" sheet, the "how did that set feel?" sheet, and
the calibration, goal-review, and "coach is offline" screens. As before, only the
looks changed — every button, timer, save, and safety rule kept working exactly
as it did. Two safety details were specifically protected: the "missing
permanently" weight option stays the quiet, secondary choice (so nobody edits
their gym profile by accident), and the rule that you must pick an intent before
logging a freestyle set is untouched.

**How I made sure it works:**
Each screen was rebuilt by its own agent in an isolated copy, one pull request
each (#480, #481, #483–#491), all checked to build — a few agents' sandboxes
couldn't run the build, so I built those here before merging. Then I built the
whole app together one last time (BUILD SUCCEEDED, iPhone 17 Pro / iOS 26.5) and
took real screenshots of the live tracker, rest timer, and summary screens to
confirm the real app matches the approved design. All fifteen screens plus the
shared design kit are now on main, tracked under #473. A short list of small
look-and-feel judgement calls is noted on that issue for a final eyeball.

---

## 2026-06-18 — The redesign goes live: the workout screens you see most

**The problem (in plain words):**
With the shared look-and-feel kit in place, it was time to actually make the
workout screens wear the new bold black-and-lime design. We started with the
screen you stare at most — the live "tracker" where the app tells you the weight
and reps for the set you're on — then did the next three around a workout: the
rest timer between sets, the screen before you start, and the summary after you
finish.

**What I changed:**
Four screens rebuilt in the new look, one separate change each:
- The live set screen now shows the weight in a big fixed slot, so "17.5" finally
  displays properly instead of getting squished, with one bright lime button to
  log the set. Everything it used to do — tapping to change the weight, "my gym
  doesn't have this", the coach's reasoning, the voice note — still works the same.
- The rest timer is a big number inside a thick lime ring with a "finishes at
  4:32 PM" line.
- The pre-workout screen got a cleaner streak, a tidy list of today's exercises,
  and one Start button (all the welcome-back and review reminders still appear).
- The after-workout summary leads with your total weight lifted, your records in
  gold, and a short note from the coach.
Only the looks changed — none of the buttons, timers, or saving logic was touched.

**How I made sure it works:**
Each screen was built by its own agent in an isolated copy of the project, each
checked that the whole app still builds, and merged separately: tracker (#476),
rest timer (#478), pre-workout (#477), summary (#479) — all part of the redesign
tracker #473. One screen's agent couldn't run the build itself, so I ran it here
and confirmed it passed. I also grabbed a real screenshot of the live tracker
from the actual app to confirm it matches the approved design. Still to come: the
paused screen, the "now training" pill, and the smaller edit/log screens.

---

## 2026-06-18 — Starting the workout-screen redesign (the look-and-feel foundation)

**The problem (in plain words):**
The workout screens never had one clear look — different screens felt like
different apps, so you couldn't really say what "the app" looks like. We explored
a fresh, bold design (nicknamed "Brutalist": pure black, big chunky condensed
lettering, and one bright lime-green colour used only on the button you actually
press), showed it as picture-perfect simulations, and it got the thumbs up. Now
we're putting it into the real app, one screen at a time.

**What I changed:**
This first piece is just the shared foundation — the colours, the fonts, and the
small reusable building blocks (buttons, the number style, cards, labels, the
rest-timer ring) — so every screen can be built from the same kit and finally
look like one app. It also bakes in the fix for the weight number that used to get
squished (like "17.5" collapsing): numbers now sit in fixed-width slots that never
shrink. Nothing you can see changed yet — no existing screen was touched — this is
just the box of parts the screens get rebuilt from next.

**How I made sure it works:**
Built as one small, additive change on its own branch and pull request (#474, part
of the redesign tracker #473), confirmed the whole app still builds clean (BUILD
SUCCEEDED on iPhone 17 Pro, iOS 26.5), then merged. Next up: the live workout
("tracker") screen gets rebuilt first, and we'll double-check it matches the
simulation before doing the rest.

---

## 2026-06-18 — Tidying up what happens when you pause a workout

**The problem (in plain words):**
Pausing a workout mid-set felt messy. Three things were wrong. First, when you
hit "Pause" right there on the screen, the app dropped you back on the "Start
Workout" page — so it looked like your workout had vanished. The proper "Workout
paused" screen only showed up if you left the tab and came back. Second, there
were two separate bits of code that both did "pause," which is the kind of thing
that quietly drifts apart over time. Third, the paused state was announced in six
different places using five different sets of words ("Paused Session", "Session
Paused", "Unfinished Workout", and so on), and several of them had their own
"Resume" button — so being paused felt like it was coming at you from everywhere
at once.

**What I changed:**
Four small, separate changes. (1) Pausing in place now lands you on the same
single "Workout paused" screen every time, whether you stayed put or wandered off
and came back. (2) The two pause code-paths are now one. (3) The little amber
"paused" banner now takes you straight to that one paused screen instead of
detouring through another page (and I deleted the now-unused detour code). (4)
Every place that mentions being paused now uses the exact same words — "Workout
paused", "Resume workout", "Discard workout" — with the word "Resume" kept only
on the one screen that actually resumes. Two pop-ups that mean genuinely different
things ("we couldn't match your session", "session not found") were left alone on
purpose, because making them say "paused" would be a lie.

**How I made sure it works:**
This was designed by a panel of agents (four designs, judged, then merged into one
surgical plan), then built as four bite-sized pieces, each with its own test and an
independent review before it went in. The whole app's test suite passes (TEST
SUCCEEDED on iPhone 17 Pro). A note for next time: the automated build runner kept
stalling on the simulator and one run silently used a simulator version this Mac
doesn't have, so I re-ran the tests by hand against a real one to be sure they
actually passed.

**Status:** Done and merged. Filed as issues #465, #466, #467, #468; shipped in
pull requests #469, #470, #471, #472; all four issues closed.

---

## 2026-06-17 — A clearer "you've got a workout going" badge above the tab bar

**The problem (in plain words).** The little dot on the Workout tab was meant to glow blue
when a workout was live and amber when it was paused. But the iPhone refuses to colour that
kind of dot — it just paints its own red dot for both. So the dot could only tell you "a
workout exists," never which: live or paused. (That's why it "stayed red" after pausing.) The
dot also couldn't be tapped to get back to the workout.

**What changed.** The dot is gone. In its place, a small floating pill sits just above the
tab bar, visible from the Program, Progress, and Settings tabs. When a workout is **live** it
shows a gently pulsing dot and the word "Training" in blue; when **paused** it shows a still
pause icon and "Paused — tap to resume" in amber; when nothing's going on, it's not there.
The movement is the main "this is alive" signal, with colour, the icon, and the words all
backing it up — so it still reads clearly for colourblind users and for anyone who turns off
animations. Tapping the pill jumps you to the Workout tab (it doesn't restart anything — the
paused screen from earlier today handles that). It's hidden while you're already on the
Workout tab, since you can see the workout right there (same way Apple Music hides its mini
bar on the now-playing screen).

**How it was checked.** Added tests for the bit that decides live-vs-paused-vs-nothing,
including that "live" always wins if both signals are set. Built clean on the iPhone 17
simulator; full suite of 633 tests passed, 0 failures. An independent reviewer dug into the
two scariest risks — could the floating pill block taps on the tab bar, and does it update
when the workout state changes — and both came back fine. The exact spacing above the tab bar
still needs a real eyes-on check on a device.

**Status.** Merged to `main` (PR #464; issue #462 closed). This finishes the two-part
workout-status fix — Part 1 was the no-auto-resume paused screen (#461) earlier today.

## 2026-06-17 — Opening the Workout tab no longer secretly restarts a paused workout

**The problem (in plain words).** If you paused a workout and later just tapped back onto the
Workout tab, the app quietly started the workout again — no button, no question. Merely
*looking* at the tab resumed it. That felt jarring: you couldn't peek at where you were, or
sit on a paused workout, without it springing back to life. The same thing happened after the
app was force-closed mid-workout.

**What changed.** Now, opening the tab on a paused workout shows a calm "Workout paused"
screen instead of restarting. It tells you where you left off (which exercise, which set, and
the time you paused), and gives you three clear choices: **Resume**, **View today's plan**
(just look, don't resume), or **Discard**. The workout only starts again when *you* tap
Resume — which runs the exact same resume machinery as before, just triggered by your finger
instead of by the screen appearing. All the existing safety checks (right day, exercises
unchanged, right account) still run, now on the tap. Returning to a workout that's genuinely
still running re-attaches automatically as before — that was never the annoying part.

**How it was checked.** Added a test locking in "a poll or a tab open never auto-resumes —
only a deliberate resume goes live." Built clean on the iPhone 17 simulator; full suite of
631 tests passed, 0 failures. An independent reviewer went through it and flagged two small
edges (a stale screen if the day changed underneath you, and a brief window where a
just-discarded workout could pop back) — both fixed before merge. The look of the new screen
still needs a real eyes-on check on a device.

**Status.** Merged to `main` (PR #463; issue #461 closed). Part 1 of a two-part workout-UX
fix; Part 2 (a "Now Training" bar replacing the broken tab dot, #462) is next.

## 2026-06-17 — Made the "live or paused" brain read its answer in one clean step

**The problem (in plain words).** The single "live or paused" brain we built (#440) asked
the workout engine three separate questions in a row — what state are you in, which day,
which session — to figure out its answer. Because they were three separate questions, the
engine could change its mind in between, so in theory the answers could come from slightly
different moments and not line up. It was safe in practice (a built-in check caught it), but
fragile — exactly the kind of thing that was already fixed everywhere else in the app by
asking for everything in one snapshot.

**What changed.** The brain now grabs the whole answer — state, day, and session together —
in a single snapshot, so the pieces always come from the same instant and can't drift apart.
Nothing about how it behaves changed; it's just sturdier under the hood. (#458)

**How it was checked.** Test-first: added a test that the snapshot now includes the session
id and matches the engine. Built clean, all 39 tests pass (the 8 brain tests unchanged and
still green, confirming behaviour didn't move).

**Status.** Merged to `main` (PR #460; issue #458 closed). This was the last loose end from
the Workout/Programme cure — that whole effort is now fully wrapped, follow-ups and all.

## 2026-06-17 — Removed the old crash-recovery workaround that could mark the wrong day

**The problem (in plain words).** There was a leftover sticky note inside the app called
"crash resume day." When you came back to a workout that lived on a different day than the
next one due, the app stuck a note saying "you're really on day B." That note was only torn
up once you tapped Done. So if you started day B, then wandered off without finishing —
paused it, switched tabs — the note stayed stuck, and the next thing you finished got marked
against day B instead of the day you actually did. Wrong day, silently.

**What changed.** The sticky note is gone entirely. Now the app asks the one "live or paused"
brain (built yesterday, #440) which day you're really on — both for which workout to show AND
for which day to tick off when you finish. Because the same single source answers both
questions, they can't drift apart, so marking the wrong day is no longer even possible (not
just patched — structurally impossible). The two tangled "resume a workout" code paths were
also merged into one. The crash-recovery pop-up on reopening still works exactly as before.
(#441)

**How it was built and checked.** Built test-first in an isolated copy, then independently
and adversarially reviewed by a second agent whose job was to break it — it manually
re-played the exact wrong-day scenario against the new code and confirmed it can't happen
anymore, with no blockers. Verified a third time here: full app builds clean, 46 tests pass
(8 new). One tiny cosmetic edge in the paused banner (pre-existing, not caused by this) was
noted for later.

**Status.** Merged to `main` (PR #459; issue #441 closed). **This was the last piece — the
whole "Workout and Programme jumble/mismatch/wrong-day" problem (umbrella #435) is now fully
fixed end to end.** One small internal robustness follow-up remains (#458, making the new
brain read its values in one atomic step).

## 2026-06-17 — One brain now decides whether a workout is live or paused

**The problem (in plain words).** Different parts of the app each figured out on their own
whether you had a workout in progress or paused — the little dot on the Workout tab, the
"you have a paused workout" banner, the calendar's highlight of today, and the day screen
each asked a different place and checked at a different moment. So they could disagree: the
tab dot still said "live" for a few seconds after you'd paused, while the banner already
said "paused." Confusing, and the root of a lot of the jumble.

**What changed.** There's now a single source of truth — one small "coordinator" that holds
exactly one answer: are you idle, live on day X, or paused on day X. Every part of the
app — the tab dot, the banner, the calendar highlight, the day screen — now reads that one
answer, so they can't disagree anymore. The old separate watcher that each part used to
poll was folded into this and deleted. A live workout always wins over a leftover "paused"
note, and the earlier safety check (#447) still blocks resuming a workout whose exercises
changed. (#440)

**How it was built and checked.** Built test-first by one agent in an isolated copy, then a
second agent reviewed it independently and adversarially (its only job was to find what's
wrong) — it confirmed every rule held and found no blockers. Verified a third time here:
full app builds clean, 38 tests pass (8 new ones for the coordinator). One small fragility
the reviewer spotted (the coordinator reads three values from the workout engine in three
steps instead of one) is harmless today but logged as a follow-up (#458) so it can be made
rock-solid.

**Status.** Merged to `main` (PR #457; issue #440 closed; follow-up #458 filed). One last
piece of the Workout/Programme cure remains: retiring the old crash-recovery workaround and
collapsing the two resume paths into one (#441).

## 2026-06-17 — Resuming a workout now refuses to replay if its exercises changed

**The problem (in plain words).** When you pause a workout and come back later, the app
restores where you left off — which exercise, which set. But if the day's exercise list had
*changed* in the meantime (say the programme was edited), the app still trusted its old
place-markers and quietly logged your sets against the *wrong* exercises. It only checked
that the day was the same day, not that the day's exercises were still the same.

**What changed.** When you pause, the app now saves a small fingerprint of that day's
exercise list. When you resume, it re-checks the fingerprint against the day as it is now.
If they don't match, it stops instead of guessing — it shows the "this workout changed,
start it fresh" recovery screen and keeps your paused session safe so you can still save or
abandon it. Paused sessions from before this change have no fingerprint, and those resume
normally as before, so nothing old breaks. (#447)

**How it was built and checked.** This was finished test-first: built the app clean and ran
the full workout-session test set — 29 tests, all green — covering the changed-list case,
the normal case, the old-no-fingerprint case, and that the fingerprint is stable across app
restarts. (Side note: this fix had been written in an earlier run that was wiped by the
laptop running out of disk; the work was recovered from disk, the one half-finished test was
completed, and then verified.)

**Status.** Merged to `main` (PR #456; issue #447 closed). That clears the last small
safety-check under umbrella #435. What's left there is the big one — the single shared
"who's training what" brain (keystone #440/#441) and retiring the old workaround.

## 2026-06-17 — Gave each workout a stable ID and saved day-status to the server

**The problem (in plain words).** Two deeper data problems from the same audit. First, a
workout's "which day was this" was only a private ID the phone made up — the server never
stored it — so when the app tried to recover an interrupted session it had to *invent* a
new ID, which never matched and produced "Session Not Found." Second, when you finished or
skipped a day, that status was only saved on the phone; the server's copy of your
programme never learned about it, so reinstalling the app could make finished days look
unstarted again.

**What changed.**
- **A real, server-saved day ID.** Each saved workout now carries a durable `training_day_id`
  (a small, safe database change — a new optional column; old rows simply leave it empty).
  Recovery now matches on the real ID instead of guessing. (#443)
- **Day status now lives on the server too.** Finishing, pausing, or skipping a day now
  also saves that status to your programme on the server (only when we're sure it's really
  you), and when the app loads it merges the two, always keeping the more-advanced status
  so real progress is never lost. (#444)

**How it was built and checked.** Two helpers built each piece test-first; #443 got an
extra reviewer whose only job was to audit the database change (it confirmed the column is
optional, reversible, and safe). Both built clean with new tests passing. The database
change is written but applied to the live database by the deploy step, not by hand.

**Status.** Both merged to `main` (PRs #455, #454; issues #443/#444 closed). Remaining
under umbrella #435: a small safety check when resuming a changed session, then the
keystone — one shared "who's training what" brain — and retiring the old workaround.

## 2026-06-17 — Three more cleanups toward the Workout/Programme fix

**The problem (in plain words).** After the first batch of fixes, three smaller-but-real
issues were still open from the same audit: (1) the app counted "how many days you've
finished" in four different places with copy-pasted logic that could drift apart; (2) the
day screen used the wall-clock calendar to decide whether you could *skip* a day, so your
actual next day could be wrongly un-skippable because of its date; and (3) when your
training programme hadn't saved to the server yet, starting a workout would quietly fail a
database check, retry for half a minute, then lose the logged sets with no warning.

**What changed.**
- **One way to count done days.** Replaced the four copies with a single shared helper, so
  the progress bar and "Day X of Y" can't disagree. (#445)
- **The calendar no longer blocks actions.** Skipping a day now depends only on where you
  are in the programme, not on today's date. The date text stays as a hint, but it can't
  gate anything anymore. (#446)
- **No more silent lost workouts.** Starting a session now makes sure your programme is
  saved on the server first; if it can't (e.g. you're offline), it tells you instead of
  pretending and dropping your sets. And the background "save" queue now treats a
  missing-programme database error as something to keep and surface, not bury. (#442)

**How it was built and checked.** Three helpers built each piece test-first in its own
sandbox; an independent reviewer checked each diff against the plan and re-ran the tests.
All built clean (one ran 42 of the data-layer tests green). The three changes touch
completely separate files, so they merged with no conflicts.

**Status.** All three merged to `main` (PRs #451, #452, #453; issues #445/#446/#442
closed). Next up under umbrella #435: giving each saved workout a stable server-side day
id (with a small database change), saving day status to the server, and then the big one —
a single shared "who's training what" brain.

## 2026-06-17 — Stopped the Workout and Programme screens from crossing wires

**The problem (in plain words).** If you opened a session from the Programme screen and
started lifting, the Workout tab and the Programme screen could end up showing *different*
days while secretly sharing one live workout underneath. The worst part: finishing could
mark the **wrong** day as done, so your plan quietly jumped past a day you never trained.
There were knock-on errors too — a "Session Not Found" message after starting a new
programme, and stale buttons offering to "Start" days that were already finished.

**How we made sure what was broken.** We ran a big audit first — a panel of helper agents
read the code, then a second set tried to *disprove* each finding so only real ones
survived. It pointed at one root cause: nothing owned "the workout you're doing right
now," so two screens each guessed the day on their own. We turned that into tracked
tickets, made seven product decisions, and shipped the cheap, high-value fixes first.

**What changed (this first batch).**
- The Workout screen now refuses to "adopt" a live session that isn't for the day it's
  showing, and can only mark *that* day complete — so the plan can't skip ahead silently. (#436)
- There's now only **one** workout screen. The Programme day view no longer spins up its
  own copy; tapping Start just takes you to the Workout tab, and only your current day is
  startable (training a random future/past day is no longer offered). The day view also
  reads its status live, so it stops offering "Start" on a day that's already done. (#437/#438)
- Starting a brand-new programme while a session is paused now politely refuses and asks
  you to finish or drop the paused session first, instead of breaking the saved one. (#439)

**How it was built and checked.** Three focused helpers each built one piece test-first in
its own sandbox, and an independent reviewer checked each against the plan. Each built
clean and its new tests pass (one ran the full 875-test suite). The shared CI "Build &
Test" is red, but it's been red on the main line for many commits on an unrelated test
crash — not caused by this work — so we didn't block on it.

**Status.** All three merged to `main` (PRs #449, #450, #448; issues #436–#439 closed).
The bigger rework — one shared "who's training what" brain, plus the data/sync fixes — is
written up and waiting under umbrella #435, on purpose, for a later, more careful change.

## 2026-06-16 — Rebuilt the Progress tab and made its numbers trustworthy

**The problem (in plain words).** The Progress screen got a fresh, premium look, but
the numbers behind it weren't honest yet. The strength estimate counted *every* set —
warmups, lighter back-off sets, all-out final sets — so it could look like you'd hit a
personal record when you really hadn't, and the big number on screen didn't match the
one the AI coach uses. The volume section just counted sets without saying whether you
were behind on anything, and there was no sign of how confident the app was in a lift.

**What changed.**
- **Strength number you can trust.** It now counts only real "top sets" in a sensible
  rep range, so fake records disappear, and the headline shows the same smoothed number
  the coach reasons from (with a small "smoothed" note so it's clear why it can differ a
  touch from your latest session).
- **Volume vs. target.** The volume card now quietly says which muscles are *behind*
  their target over your last ~7 sessions, worst first — and stays silent when you're on
  track (no empty praise).
- **Confidence note.** Each key lift can show "still learning this lift" or how many
  sessions it's based on — and hides itself when there's nothing solid to say.
- **Plateau help.** When a movement keeps stalling, it now tells you what to *do*
  ("rotate the exercise or rebuild the block") instead of just counting the stalls.

**How it was built and checked.** Built by several focused helpers in stages — one for
the data, two for the screen, and two independent reviewers whose job was to attack it.
The reviewers caught two real problems (a freshly-tracked lift could show "0.0 kg", and
the little up/down number didn't line up with the headline); both were fixed and pinned
with tests. Everything hides gracefully when there's no data. App builds clean and the
6 new tests pass.

**Status.** Shipped to `main`. The look-and-feel landed first (PR #432), then the
trustworthy numbers on top (PR #434, which replaced #433 after a stacked-branch hiccup).

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
