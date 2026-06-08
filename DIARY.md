# Project Apex — Work Diary

A plain-language diary of work that gets pushed and merged, written in simple words —
like a journal, not a technical log. Newest entries go on top.

Started 2026-06-07.

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
