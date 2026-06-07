# Project Apex — Work Diary

A plain-language diary of work that gets pushed and merged, written in simple words —
like a journal, not a technical log. Newest entries go on top.

Started 2026-06-07.

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
