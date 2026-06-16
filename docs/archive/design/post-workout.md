# Post-workout summary — design spec (bookend #3, the coach's read)

**Status: locked 2026-06-11** after a four-agent review (UI craft / UX-product /
visual–art-direction / motion-animation). All accepted findings folded in; record
and dispositions in §14. Companion docs: `DESIGN.md` (tokens + motion canon +
the tag family and dim data-viz blocks added this round), `ui-overhaul-spec.md`
(locked behavior — post-workout is §5), `live-loop.md` (§8 Finish is this
screen's entry), `splash-today.md` (hairline/tick systems, Today's state
machine — this screen exits into it), `onboarding-calibration.md` (the model
reveal — context #1 of the band component, §6).

## 1. Job

The expressive half of the principle at its peak: **visibly smart around it.**
The lifter just racked the last set; the screen answers one question — **what
did this session prove about me?** This is the model visibly absorbing the
session — the thing competitors *say* ("it will be tracked to your program",
p21) and never show — and the relationship beat the retention case rests on:
for committed trainees, *being seen doing it well* is the dopamine
(`ui-overhaul-spec.md` §5). Hevy's lifters captioning their own sessions
"Trying to get some exercise 😅" for an audience of peers (p16) is live market
proof of the witness demand; ours routes it to the coach. Three jobs, in order:

1. **The read** — the coach names what the session proved, in two grounded decks.
2. **The evidence** — the numbers underneath, drawn, each verifiable in the ledger.
3. **Closure** — loose ends resolved, the session sealed, the next session named.

**Three laws established here:**

- **One screen, two entries.** This screen is also the permanent session
  record, reached later from history. Post-Finish it plays the bookend; from
  history it renders as a record — no reveal, no flourish replay (return plays
  states, not reruns).
- **One instrument per surface.** The band strip owns this screen (capability,
  backward-proving); the Lens owns Today (readiness, forward-looking). The
  Lens never appears here.
- **One fact, spoken then drawn.** The number the read's claim emphasizes is
  the number the strip dimensions below it. The read and the evidence can
  never be about two different lifts — two competing facts is a hung jury.

## 2. Entry — bookend #3

**The Finish tap is the transaction.** Seal, local model math (bands, ratchet
state), the stored read, and milestone state all commit synchronously before
the first flood frame — ceremony never gates data; force-quit, calls, and dead
batteries lose nothing. The reveal is pure render and is non-resumable: an
interrupted bookend is never resumed mid-flight; the next entry renders the
assembled end-state (unseen milestones: §7).

The motion is **one ballistic arc** — the ink is thrown up and falls back
under gravity; the beat at the top is physics, not a frozen frame:

- **t −100→0ms:** the Finish slab's `log-settle` press; the pressed slab
  **melts into the rising edge** (overlap, never release-then-flood) and
  disables at touch-up — a double-tap cannot re-fire the bookend. No haptic at
  the tap: the reveal carries haptics only when something earned happens.
- **0–250ms:** the edge climbs, decelerating into the apex — ruling-pen edge,
  ~1.5° cant, 1px edge highlight, full coverage. No mark, no wordmark, no
  text: the splash owns the mark, and identity is loudest where content is
  thinnest (p20). The model's update is already done — nothing fake happens.
- **250–350ms:** **apex hang** — the edge at near-zero velocity as the curve
  turns over. The beat exists, and it costs zero dead frames.
- **350–850ms:** the fall, revealing the finished page top-first in reading
  order: margin row ~450ms, **the read readable ≤600ms** (earlier than
  bookend #2 finishes), evidence strip ~700ms, stat line and below last. 8pt
  staggered settle as the edge passes. **The retreating edge prints the bottom
  rule as it passes** — the tide line — then exits fully through the bottom of
  the screen at 850ms with no pooled residue: the slab died with the session,
  and its absence is the closure. The exit control ("Today") fades in on the
  tide line at ~900ms, the reveal's last element.
- **850ms:** scroll and taps live (per-element input never blocked by the
  absorption sequence, §3).

**The finished-page law:** all content — the read, loose-end rows, ledger
summaries, stat line — is committed and fully laid out before fall-start
(t=350ms); the fall only unmasks; zero layout work during or after it. The
read's claim slot reserves 2-line height regardless of actual line count. The
only post-reveal entrances are the dot, the conversion fill, and the ratchet
(§3), none of which change geometry.

Reduce Motion: one 150ms crossfade to the **full end-state** (dot placed,
markers converted, floor at its new position), hold 300ms, then milestone
haptics fire once in sequence (§7) — the haptic confirms a fact already
visible. Re-entry from history: no bookend ever.

## 3. The absorption sequence (after the page lands)

The reveal's meaning-bearing motion, in causal order on a finished, still page:

1. **The dot lands — "the ink leaves one drop behind."** The strip reveals
   *without* today's dot: the band as it stood before today (the prior state
   is real). At strip-settle +150ms (~900ms), today's dot **sets down** at its
   true x-position like a pen touching paper — ~8pt descend + scale to 1.0,
   spring(response 0.35, damping 0.9), ~250ms, settled ~1150ms. No overshoot,
   no path-draw (a trajectory we didn't measure is a fabricated line), **no
   haptic** (the dot lands every session; a dot haptic would thud on flat
   days). On a flat day this is the screen's only post-reveal motion — and
   then the screen is still.
2. **The conversion (conditional).** Estimated→measured plays *after* the dot
   — measurement first, re-grounding second: at dot-settle +250ms, hollow
   markers fill center-out over 220ms ease-out — ink filling a drawn circle.
   No haptic, no scale change. (First-ever session: §10.)
3. **The ratchet (conditional, the milestone):** §7's locked sequence, 200ms
   after dot-settle.

**Idle law:** after the last sequenced beat, the screen is provably static —
no breathing strip, no shimmer, no looping anything. Stat-line numbers render
static, never a count-up (animated suspense over a known number is
fabrication; p11 would have counted up to a lie).

## 4. Composition (top to bottom, on paper)

Hairlines are static datum lines: the top margin rule, the strip's datum, one
rule above the pinned exit zone (the tide line).

- **Margin row — the title block.** Leading: the session tag — the tag-family
  rectangle boxes **only the classification** ("UPPER A"), the date beside it
  in plain `label` muted, unboxed (tags classify; they don't carry metadata).
  The session name is the same string Today's session card used — one name
  everywhere. Trailing: nothing post-Finish (no control competes with the
  read); from history, standard back chrome.
- **The read — two decks (§5):** the claim, then the proof.
- **The evidence strip (§6):** the drawn instrument, with its caption. One tap
  target ≥56pt → the pattern's detail in Progress (build dependency: gated
  non-navigational until Progress ships).
- **The quiet stat line.** One line, 13pt, two-tone per the ink law: digits
  full ink tnum, words `ink-muted` — "**18** working sets · **12,400** kg
  moved" (+ " · **1** PR" when true). Counting law: working sets = logged
  working sets only; struck/skipped sets never count; the stat line and the
  ledger share one counting rule and must be incapable of disagreeing (p11's
  "14/14 · 100%" beside "Volume 0 lbs" is two instruments contradicting each
  other). **The volume term renders only when external load > 0** — a
  bodyweight session never reads "0 kg moved"; with no volume term the line
  is the set count alone.
- **Loose ends (conditional, §8):** the AMRAP fill-in and the pain
  acknowledgment, between stat line and ledger.
- **The ledger — the session record (§9).**
- **The next line.** One quiet line: "Next: Friday — Lower B." Non-interactive
  — stated, not implied. No CTA; the screen doesn't sell.
- **The exit — pinned.** "**Today**" (`accent-ink` text, ≥44pt, centered on
  the tide-line rule, fixed above the home indicator; content scrolls beneath
  the rule). Named for its destination — "Done" meant *commit a set* twenty
  times tonight; the word is spent. Exit is `transition-nav` (150ms; the
  bookend budget is spent — exits are not a fifth moment), the tab bar
  returning in the same fade. **The summary is a navigation root**: back never
  tunnels into the dead loop. Destination: **Today, rendering per its own
  state machine** — usually session-complete, but midnight rollover, a
  pain-triggered back-off, or two-a-day rules may render something else; this
  screen promises nothing. Today's session-complete echo is the stored claim
  line verbatim (latest session wins on two-a-days).

**Scroll, pin, and fold contract.** Post-Finish, nothing pins at top — the
read scrolls away; the record is below. History pins standard nav chrome.
Above the fold at default type on the smallest supported device: margin row,
both read decks, the strip + caption, the stat line — the bookend's entire
choreography, including the dot and any flourish, completes within the
viewport. The next zone peeks above the fold: a loose-end row when one exists
(the AMRAP fill-in must never render fully below the fold), else the ledger's
first row — the peek invites the scroll.

## 5. The read — content law

**Two decks** (the draft's single 34pt paragraph failed its own type math —
140 chars is seven lines of display; all four reviewers caught it):

- **The claim** — one sentence, `display` SG 600 34pt, **≤45 characters**,
  1–2 lines (slot reserves 2), always present, always containing the
  verifiable number. *"Your squat floor just moved: 105 kg."*
- **The proof** — one sentence, `body` Inter 400 17pt full ink, **≤90
  characters**, key numbers SG 600 tnum full ink per the two-tone law,
  connective tissue `ink-muted`, set `sm` (8pt) beneath the claim. *"Third
  session above the old band forced it up — and the 5-rep bench PR came with
  it."*

The claim line is also the **echo artifact**: Today's session-complete state
displays this exact stored string. VoiceOver reads claim + proof as one
element. At AX sizes the proof sheds before the claim wraps past 4 lines.

**Assembled deterministically, always** — from three named sources: today's
sets; model state (including ratchet rationale, band-center history, and
confidence — band-center snapshots are a named model-API requirement); local
program + session history. No network. **v1 ships deterministic-only.** The
AI-phrased upgrade is specced dormant: the request fires when the Finish
composition renders (the lifter dwells there for seconds — that is the honest
prefetch budget; a call started at the Finish tap can never beat the deadline),
validates against the same grounding/split/length laws, and swaps in only if
resolved before **fall-start** (the finished-page law's hard cutoff). **Once
rendered, the read never rewrites.** There is no "AI failed" state — the
deterministic read is the read, with no visual difference.

**Grounding priority (the grammar picks the highest that applies):**

1. **Pain flag** → the claim leads with the acknowledgment (§8); the proof
   carries the session's one number.
2. **Floor ratchet / level-up** → claim: "Your squat floor just moved:
   105 kg." Proof: "Third session above the old band forced it up."
3. **PR** → folded, never trophied: the proof carries it ("…and the 5-rep
   bench PR came with it").
4. **Band movement** (above the noise threshold, §6) → claim: "Bench is
   creeping up: 92 kg." Proof: "The band's center moved 1.5 this week."
5. **Held / flat (the default)** → claim: "All 18 sets in." Proof, with feel:
   "Squat's holding its band — third week it's held. Top set was a grind."
   **Feel-unknown variant (mandatory — the default line must never depend on
   the optional pill):** "Top squat 100 × 5, square in the band."
6. **Partial** → honest, never graded: claim: "3 of 4 lifts in." Proof:
   "Squat's data is solid; rows carry to Friday."

**Guards:** every deck contains or supports ≥1 ledger-verifiable number.
Streak claims ("third week it's held") require consecutive-session continuity
and are suppressed after a gap. Mechanism claims must name mechanisms the
model actually has (no "re-finding your floor" unless a downward mechanism
ships — the gap line claims confidence-widening instead, §10). Tone: terse
honesty, a coach who watched — never a cheerleader (p20/p21).

**The forward hook (the flat day's retention beat):** when the model is
deterministically ≤2 sessions from a ratchet condition, the proof may name it
— *"One more session above 102 and the floor moves."* At most once per pattern
per week. Distance-to-ratchet is a verifiable fact of the watermark mechanism;
this is the moat speaking in its own voice, and it converts the most common
day from a pat on the head into anticipation.

**The read is stored with the session** — what the coach said that day. The
history entry renders it verbatim, forever; it never recomputes against a
later, smarter model. If a later correction (§8) invalidates a number the read
cites, the history render adds one muted annotation line ("a weight was
corrected after this read") — the read and the ledger never silently disagree.

## 6. The evidence strip — a drawn instrument, not a chart

**One band component, three contexts** (the onboarding model reveal, this
screen, Progress's pattern detail): same anatomy — fill, edge ticks, dot,
movement bracket, caption slot — differing only in scale and caption. The
strip and the read obey the one-fact law (§1).

**The drawing** (the plate-callout vocabulary promoted to the model's own
movement): ~64pt tall on a full-bleed datum hairline with the standard 4pt
margin ticks.

- **Floor: a 2px full-ink tick** — the heaviest line on the page; settled
  fact — labeled beneath in `label` muted tnum ("FLOOR 100").
- **Stretch: a 1px hairline tick** ("STRETCH 110").
- **Band:** `band` token fill (accent 8%) between them.
- **X-domain: band ± 20%, expanded to include today's dot if outside.** A dot
  above stretch (the pre-ratchet state) or below floor **plots outside the
  band, never clamps** — a clamped dot fabricates position.
- **Today's dot:** today's best observed e1RM for the pattern — 8pt, solid
  `accent-ink` when measured, hollow ink-stroke when estimated. One dot only;
  history is Progress's job.
- **Movement: a dimension bracket** — short hairline with terminal ticks from
  the previous band center to the new, delta labeled tnum ("+1.5 KG").
  Trigger and delta share one window (the session); rendered only when the
  model actually moved past the noise threshold. **No fabricated movement:**
  the flat dot inside an unmoved band is the default render and must look
  composed — the strip is evidence, not a fireworks launcher.
- **Labels:** numbers live on the drawing's ticks, never twice. Collision
  rule: if band render-width < label widths + 8pt, labels shift outboard of
  the band ends; minimum band render width 48pt.
- **Caption:** pattern name + selection rule only ("Bench press — most worked
  today"); may wrap to 2 lines; never truncates numbers.

**Headline-pattern selection (deterministic; it drives the read AND the
strip):** (1) the pattern with a ratchet/level-up today, else (2) the largest
band-relative movement **above a minimum threshold** (below it, week-to-week
deltas are noise and "most moved" is fabricated precision), else (3) **the
session's planned focus pattern** (from the session title), else (4) most
working sets today. The caption names which rule fired.

**Intent-aware caption:** when today's top set was prescribed below the band's
reference intensity (a volume/light day), the caption carries the intent
("volume day — top set at 85%") so a low dot reads as the plan, not
regression — a true number stripped of intent is the p11 class of failure.

**Unbanded patterns** (a bolted-on novelty movement): no strip renders; the
caption row states why ("New pattern — no band yet"); stat line and ledger
carry the screen.

**Dim variant:** the dim data-viz tokens added to `DESIGN.md` this round
(band = dim accent-ink at 12% fill, hairline edges `#2A2D36`, measured dots
dim `accent-ink`, hollow strokes dim `ink`).

**VoiceOver grammar:** "Bench press. Estimated one-rep max 92 kilograms,
measured. Capability band 88 to 96. Center moved up 1.5 kilograms. Button —
opens bench press detail." Milestones post an announcement: "Milestone —
squat floor moved up to 105 kilograms."

## 7. Milestones — the earned flourish

**The ratchet sequence, locked end-to-end** (the product's owned celebration;
haptic leads motion — the click is the fact, the line moving is the
consequence):

1. Dot settles → **200ms still** (the cause-and-effect gap; <100ms reads
   simultaneous, >400ms reads unrelated).
2. **`impact(.rigid)`** fires ≤40ms before the floor line's first movement
   frame — the pawl clicks.
3. The floor tick travels up one notch on spring(response 0.30, damping
   0.55), the single sanctioned ~10% overshoot; the floor label hard-swaps
   old→new at click onset (tnum holds the frame, no odometer).
4. **`notification(.success)`** at spring-settle (~+250ms) — the mechanism
   seats. Never fired as a simultaneous chord with the rigid impact (mush,
   not a ratchet).

**The fossil:** the old floor tick remains as a **ghost** — 1px hairline at
30% — with a dimension annotation between ghost and new ("+2.5 KG", tnum).
The notch is legible after motion ends, and the history entry renders ghost +
new statically forever: the flourish leaves a fossil the record keeps.

**Stacking:** one flourish per reveal — per **session record**, not per
render. Ratchet > level-up > PR; ratchet and level-up are usually one physical
event (the floor moving is what changed the tier) and share the single click.
The PR yields motion because it already owns a permanent artifact — the ink
stamp set mid-session — and the read names it in words; three channels for two
facts is composition, two bounces is a slot machine. Two patterns ratcheting
the same day: still one flourish — the headline strip plays it, the read names
the second in words; never two animating strips.

**Witness rule: never fired unseen, never replayed.** The flourish arms until
witnessed once: it plays at the strip's first ≥80% visibility — in the live
reveal normally; deferred to first scroll-into-view if AX type pushed the
strip below the fold; deferred to the first view of the session record if the
reveal was never completed (force-quit, phone call). A transition never seen
is not a rerun. After witnessing once: never again — history and all returns
render the new floor (ghost + new) statically. Today's done-state line carries
the milestone in words regardless. A flourish newly earned by a late AMRAP
fill-in fires once at fill-in commit (§8) — the celebration belongs to the
moment the number became known.

**Flat days:** no flourish, no haptic anywhere, full respect — the read
carries the day ("held" is an achievement the grammar knows how to say, with
the forward hook doing the anticipation work).

## 8. Correction & closure

**The amended record replaces "sealed at Finish."** The honest boundary is
the *kind* of edit, not a timestamp — load and reps are externally verifiable
facts (the plates were what they were); feel is a momentary perception. An
uncorrectable wrong number is fabrication by lockout, and its worst case is a
**ratchet celebrated on a weight that was never on the bar** — the §8
data-honesty law cuts against the seal, not for it.

- **Facts are correctable; judgments are sealed.** Weight and reps on any
  logged set are editable **from the history entry only** (never the
  post-Finish reveal — the emotional bookend is not an editing surface),
  until the next session starts or 48h elapse, whichever is first. Feel is
  never editable post-Finish (retroactive feel is fiction with a delay), and
  the pain flag stands as raised.
- **Correction is visible provenance, never silent rewrite** (the drawing
  tradition's revision): the old value struck in pencil (`ink-muted`
  strikethrough), the new value in ink, an **AMENDED tag** from the tag
  family on the corrected row and on the session's eyebrow in history. Never
  erase; always strike.
- **The model re-ingests on commit** — e1RM, band, and ratchet state
  recompute; a ratchet invalidated by correction reverses in state without
  ceremony, and no flourish ever re-arms from a history correction. The
  stored read stands verbatim, gaining the §5 annotation when its grounding
  number changed.
- After the window closes, the record is immutable.

**The AMRAP fill-in** (promised in `live-loop.md` §7): any set logged "reps
unknown" surfaces one quiet row above the ledger — a `well` row, "Bench AMRAP
— how many?", keypad-first inline counter (no anchor), explicit quiet "Skip"
as the one dismissal. **Walking away is not dismissal** — leaving via Today
keeps the row on this session's record (post-Finish and history) until
filled, skipped, or the correction window closes; it never escalates to Today
or notifications. A locker-room exit must not convert an answerable number
into a permanent unknown. **The update pass on commit:** the commit takes
`log-settle` + `impact(.medium)` — filling the count *is* logging set data,
the plate-thud's one honest meaning — then the row collapses (200ms ease-out,
layout shift in the same window) and the ledger digits crossfade (150ms). The
ledger and the model update immediately; the strip and stat line re-render
from live model state (instruments, never stored text); a newly earned
milestone fires once at commit (§7); the read gains an **appended
deterministic coda**, stored alongside the original — "Bench AMRAP: 9 — that
moves the band." The coach speaking again is not the coach rewriting itself.
Skipped → unknown stands forever (low confidence), never re-asked.

**Feel is never re-asked.** Ignored pills logged unknown at the moment that
was true (one tap, forever — `live-loop.md` §12.2). No post-hoc feel survey.

**Pain acknowledgment — render-after-verify.** The acknowledgment always
renders immediately and leads the read ("Shoulder note logged"). The
*consequence* line renders **only after the next-session generation has
verifiably applied the change**, grounded in the actual delta ("Friday's
pressing: 3 sets, down from 5"); if generation is pending at reveal, the row
shows the acknowledgment alone and the consequence surfaces as Today's alert
row once true. "Until it clears" is banned unless a clearance mechanism ships
— name the actual rule ("for the next two pressing sessions"). A promised
consequence the model didn't deliver is the shipped app's audit-F8 failure
reborn at the emotional peak of the product. Treatment: the revision-note row
(hairlines + 2px `accent-ink` tick); red only when invoking an actual
back-off.

**Abandoned-session close:** the next-day "Finish Tuesday's session?" one-tap
close (`live-loop.md` §7) lands here in **history form** — no bookend, no
flourish (the witness rule's words-only path), read computed from what's
there. A day-old celebration is motion dishonesty. *(Cross-doc flag: the
resume card in `splash-today.md` must carry this one-tap honest close —
amendment filed, §14.)*

## 9. The ledger — the session record

- **Collapsed exercise rows use the anchor grammar** — the exact string shape
  the lifter checked against mid-session: **"Squat — 100 kg × 5 · 5 · 4 ·
  Grind"** (exercise Inter 500; numerics SG 600 tnum 15pt full ink; separators
  and feel word muted). Feel = top working set only, rendered **only when
  known** — unknown renders nothing, never a dash (a dash displays absence as
  a value). Mixed loads: lead with the top working weight, deviating sets
  annotated in the reps list ("5 · 5 · 4 @97.5").
- **Set ticks are the expansion affordance** — no chevrons, no disclosure
  chrome: each row carries its set ticks at the left margin, **filled for
  logged, hollow for skipped/partial** ("3 of 5 sets" shows three filled, two
  hollow) — continuous with the loop's tick system; the ticks simultaneously
  *are* the partial-honesty render. Tap anywhere on the row (≥44pt) toggles
  per-set rows: 250ms ease-out height, rows fade in place with ≤30ms offsets,
  no spring, no haptic — disclosure, not ceremony.
- **Expanded rows are the loop's ledger rows** (15pt SG 600 tnum full-ink
  digits, feel tags, the PR stamp, WARM-UP tags — warm-ups excluded from the
  collapsed line, present expanded). **Plan-vs-actual renders in the ink
  law:** actual in full ink, plan in `ink-muted`, only when they differ —
  "100 kg × 6 · plan 5" (Tonal's 23/16 frame in our grammar; done work is
  ink, the plan is not work).
- **Row interactivity by entry:** post-Finish reveal — rows are **inert** (no
  edit affordance at the bookend). History entry — rows open the set-edit
  view (weight/reps only) while the §8 correction window is open; inert after
  it closes. An identical-looking row must never promise a dead edit path.
- Struck sets show with their reason; skipped exercises named plainly ("Cable
  row — skipped"); partials as the Finish guard worded them ("Squat — 3 of 5
  sets") — never "Done — N of N" over a partial, never an adherence
  percentage (a 25% ring is honesty weaponized into shaming, p10).

## 10. States

- **First-ever session:** the estimated→measured conversion owns the
  meaning-slot as the headline — claim: "First measured day: squat 142 kg."
  Proof: "The 135 at setup was an estimate — this one's yours." The (only)
  state where two strips may render; they convert sequentially, 250ms apart,
  statically positioned — conversions, not flourishes; no other flourish that
  day.
- **Flat day:** the default; §3's dot landing is the only motion, the forward
  hook does the anticipation work, no haptic anywhere.
- **Partial / cut short:** Finish-guard wording carries through (§9).
- **Gap return:** claims confidence-widening, not "re-finding" — claim:
  "First session back in 3 weeks." Proof: "Confidence is wider — the bands
  re-tighten as data lands." Streak claims suppressed (§5).
- **All warm-ups / zero working sets:** honest small read ("Logged 3 warm-up
  sets — nothing to update from today"); no strip; the stat line suppresses
  "0 working sets" (renders nothing rather than a zero); ledger renders.
- **Offline:** indistinguishable from online — zero network on this screen.
- **History entry:** stored read verbatim (+ §5 annotation if amended), no
  reveal, end-state strip (ghost + new floor if ratcheted), standard nav,
  correction affordances per §8/§9, AMRAP row if still open.
- **Midnight / two-a-days:** sessions key to their start date (loop law);
  exit promises only "Today renders per its own state machine"; latest
  session wins the echo and the eyebrow.
- **Force-quit mid-reveal:** nothing lost (the Finish transaction, §2);
  next view renders the record; an unwitnessed flourish plays once on first
  view (§7).
- **Dim variant:** token remap + the new dim data-viz block.
- **Dynamic Type / AX:** the claim survives 4-line wrap before the proof
  sheds; strip sheds movement bracket → caption detail → stat line before the
  read sheds anything; numbers never truncate. VoiceOver order = reading
  order: eyebrow → read (claim+proof, one element) → strip → stat line →
  loose ends → ledger → next → Today.

## 11. Explicitly cut

Share (v1 — there is nothing ownable to share until the wordmark exists; a
screenshot of an unfinished identity is brand dilution; the read + strip
block is specced screenshot-clean as the interim mechanism, and the v1.x
return path is milestone-days-only quiet tertiary, never visible until the
reveal's last beat), confetti and trophy modals (p05), badge/medal systems,
duration-as-stat and total-volume-as-hero (locked cuts), muscle body maps
(p11/p12 — we model patterns, not pecs), sets/adherence rings (p10), "AI
adjustments" count, rate-this-workout prompts (p04 — feedback as toll),
streak counters (p03), "Take it again" (p13 — the model already heard it;
the next session is the redo), delete-workout-from-summary (hygiene lives in
history), workout-notes field (per-set notes are a named v1 cut), count-up
number animations (§3 idle law), share-composition pressure on the bookend.

## 12. Mobbin references (verified frames, `tmp/refs4/`)

- **Peloton "Way To Go" (p20)** — praise hero with zero numbers, fired while
  the class timer still runs (celebration before the record exists — the
  flourish outrunning the data; our ratchet plays only after the dot lands).
  Its "Adjust Reps and Weights" *after* the praise concedes the praise was
  computed on unverified data — and the button exists because auto-logging
  over-records: a confession of one-tap logging's failure mode. Our per-set
  edit window (live-loop §6) + the amended record (§8) make the blanket
  button structurally unnecessary.
  [flow](https://mobbin.com/flows/f6bbb2b0-a155-4d8e-912e-8757c9464c20)
- **Peloton summary (p11/p12/p13)** — "Volume 0 lbs" beside "14/14 · 100%
  completed": two instruments contradicting each other on one screen (→ our
  one-counting-rule law); body maps; "Take it again / Delete workout" as the
  closing affordances — a content library's ending, not a coach's.
- **Equinox "Way to go" sheet (p21)** — "it will be tracked to your program":
  the absorption moment as an unverifiable verbal claim — the strongest
  external argument for choreographing the dot. Also a *toast over the dying
  session* vs. our *place* (the permanent record) — the form that makes
  stored-read-verbatim possible.
  [flow](https://mobbin.com/flows/472bf5b7-3baa-4041-9b9d-b3b205a25b59)
- **Equinox recap (p09/p10)** — completion as quiet toast + recap link (the
  right shape for unseen-milestone words, → Today's done-state line); the 25%
  adherence ring rendered in celebratory green — honesty weaponized into
  shaming, register mismatched to content (→ no percentages on partials).
- **Gymshark (p02)** — share-as-primary over a table of dashes; beneath it, a
  buried title block (program/session/timestamp — right anatomy, no
  hierarchy: → our margin row). "DURATION 2 MINS" celebrated with a hero
  share button: no degenerate-session guard (→ our all-warm-up state).
  [flow](https://mobbin.com/flows/f056e8f3-4754-452b-846e-4a8a3c7b948a)
- **Runna (p04/p05/p19)** — stat row under hero (take: shape); "rate to
  unlock insights" (reject: toll); the confetti badge modal — celebration
  *interrupting* the summary, consequence before fact, unbounded ambient
  motion that can't honor "nothing animates at rest"; yet "2:25 Fastest 1K"
  sits *inside* the trophy: the one thing it gets right — the flourish
  carries its number (→ the ratchet is never separable from the value it
  moved to). Save screen: red Discard adjacent to Save (destructive
  adjacency; our discard lives in the pause menu).
  [flow](https://mobbin.com/flows/93a25cbd-72e8-4428-a9c6-00ab6d1fe620)
- **Apple Fitness (p06)** — the data-table pole: every number, no meaning —
  the opposite failure from p21. Its dashes ("--'--"") render absence as
  absence: the system-default honesty floor; our bar is higher — absence is
  *named* ("reps unknown", "skipped"), because tables force a glyph into
  every cell and that is exactly how absence becomes a fake value.
- **Tonal (p15)** — "23/16" actual-vs-target: the honest comparative frame
  (→ §9 plan-vs-actual) — but rendered in green on the *weight* (the
  machine-set value), not the reps the human fought for: miscoded emphasis;
  and a 44% overshoot celebrated without comment is the strongest external
  argument for the read existing at all — tables cannot tell you what
  mattered. Its tracked-caps micro-labels prove our register works; its
  genericness proves register alone isn't identity.
  [flow](https://mobbin.com/flows/0b7f9e89-5714-414b-a1a0-2a02d0854c7e)
- **Hevy (p16/p17/p18)** — lifters captioning sessions "Trying to get some
  exercise 😅" for peer audiences: live demand-side proof of the witness
  need (§1); the muscle-split bars are Progress-tab material at best; "No
  data yet" (p18) is an honest empty state worth keeping for Progress.
- **Ladder (p03)** — streak/cheer counters: the social-accountability pole;
  our accountability is the coach's memory, not an audience.
- **Finish-context (p01 Gymshark, p07/p08 Equinox)** — checklist-then-button
  endings; confirms the slab-relabel (one persistent object) over a button
  appearing at a list's end.

## 13. The six open questions, resolved

1. **Post-Finish edits:** the amended record (§8) — facts correctable from
   history with struck-not-erased provenance and the AMENDED tag until
   next-session-or-48h; feel sealed forever; the stored read never rewrites.
   (4–0 against the draft's seal; the ratchet-on-a-mislog argument was
   decisive.)
2. **Share:** cut entirely for v1 — not even a milestone tertiary
   (conditional chrome for an unproven need before the identity assets
   exist); the read + strip block is specced screenshot-clean as the interim;
   v1.x returns it on milestone days only. (Unanimous.)
3. **AI line:** deterministic-only v1; the dormant upgrade keeps the
   architecture with the deadline corrected to fall-start and the request
   fired at Finish-composition render (the ~650ms post-tap race was
   unbuildable — dead code wearing a spec). (Unanimous.)
4. **The Lens:** absent, as law — one instrument per surface; an honest
   post-session Lens would de-focus (readiness genuinely drops): true,
   useless, and mis-aimed at the proudest moment. Readiness consequences may
   be *spoken* in the proof when a deterministic back-off triggers. (Unanimous.)
5. **Exit:** renamed "Today" (the word "Done" was spent twenty times tonight
   meaning *commit*); pinned on the tide line; navigation root; 150ms
   workhorse; destination renders per Today's own state machine. (Unanimous
   on mechanics; rename proposed by visual, collision independently flagged
   by UI.)
6. **Stacking:** ratchet > level-up > PR confirmed, with level-up sharing the
   ratchet's click (usually one physical event); one flourish per session
   record (not per render — a late AMRAP fill-in's newly-earned milestone
   fires at commit); the witness rule (never unseen, never replayed); two
   same-day ratchets still get one flourish. (Unanimous.)

## 14. Review record (2026-06-11, four agents)

Panel: UI-craft, UX/product, visual/art-direction, motion/animation.
Headlines: *the read's type math was broken in the draft and all four caught
it independently (140 chars cannot fit 2 lines of 34pt display — the hero was
unbuildable); the "sealed at Finish" position was overturned 4–0 (a ratchet
celebrated on a mis-logged weight is the most expensive fabrication the
product can commit); the milestone was gated on a dot-landing the draft never
choreographed (motion); the band strip was a generic chart until it was
redrawn in the app's own dimension vocabulary (visual).*

| # | Finding (agent) | Disposition |
|---|---|---|
| P0 | Two-deck read — claim ≤45 chars `display` + proof ≤90 chars `body`; the claim is Today's echo artifact (all four independently) | **Accepted** — §5. |
| P0 | Amended record replaces sealed-at-Finish: fact-vs-judgment boundary, history-only, struck-not-erased, AMENDED tag, window, model re-ingest, no flourish re-arm (UX lead; UI/visual/motion concur) | **Accepted** — §8, §9. |
| P0 | AMRAP fill-in update pass: instruments re-render, appended coda (never rewrite), milestone fires at commit, walking away ≠ dismissal (UX; UI's exit-as-dismissal overruled — the locker-room argument) | **Accepted** — §8. |
| P0 | Grammar integrity: feel-unknown flat-day variant, streak guard, mechanism-exists guard, first-ever/gap examples rewritten with verifiable numbers, named data dependencies incl. band-center snapshots (UX) | **Accepted** — §5, §10. |
| P0 | Pain consequence is render-after-verify; "until it clears" banned without a clearance mechanism (UX — audit-F8 at the emotional peak) | **Accepted** — §8. |
| P0 | Ballistic arc replaces flood→hold→fall: apex hang as physics, read ≤600ms, edge exits through the bottom, no slab re-pool, tide line prints the bottom rule (motion; visual's tide line merged) | **Accepted** — §2. |
| P0 | The dot landing choreographed: strip reveals dot-less (prior state is real), dot sets down on the finished page ~900ms, no haptic, no path-draw (motion; visual's during-the-fall variant declined on perceptibility — its "one drop left behind" naming kept) | **Accepted** — §3. |
| P0 | Finished-page law: all layout committed by fall-start; reserved claim slot; only the dot/conversion/ratchet enter post-reveal (motion) | **Accepted** — §2. |
| P0 | Ratchet sequence locked: 200ms gap, rigid ≤40ms before first frame, spring 0.30/0.55 single overshoot, success at settle — sequenced, never a chord (motion) | **Accepted** — §7. |
| P0 | Band strip as drawn instrument: 2px ink floor tick (heaviest line), hairline stretch tick, dimension-bracket movement, numbers on the drawing; domain band±20% expanded — out-of-band dots never clamp (visual + UI merged) | **Accepted** — §6. |
| P0 | One-fact law: the claim's number is the strip's dimensioned fact (visual) | **Accepted** — §1, §6. |
| P0 | Collapsed ledger uses the last-time anchor grammar; feel-unknown renders nothing, never a dash; zero-volume guard + one counting rule on the stat line (UI) | **Accepted** — §9, §4. |
| P1 | Scroll/pin/fold contract: pinned exit, nav root, loose-end peek, AX shedding order (UI + UX + visual) | **Accepted** — §4. |
| P1 | Exit renamed "Today"; destination = Today's own state machine; midnight/two-a-day rules (visual + UX; UI flagged the collision) | **Accepted** — §4. |
| P1 | Selection rules: noise threshold, planned-focus tie-break, intent-aware volume-day caption, unbanded state (UX) | **Accepted** — §6. |
| P1 | Forward hook: deterministic distance-to-ratchet in the proof, ≤2 sessions away, once per pattern per week (UX) | **Accepted** — §5. |
| P1 | Conversion beat after the dot on a still screen (220ms center-out fill); first-ever owns the meaning slot, sequential strips (motion + UI) | **Accepted** — §3, §10. |
| P1 | Ratchet fossil: ghost tick + dimension annotation, rendered statically forever in history (visual) | **Accepted** — §7. |
| P1 | Witness rule unifying fold-deferral and force-quit recovery: arms until first ≥80% visibility, once ever (UX's play-once-on-first-view + motion's visibility gate merged; motion's words-only force-quit stance superseded by its own never-fired-unseen principle) | **Accepted** — §7. |
| P1 | Transactional Finish before flood frame 1; double-tap guard; non-resumable bookend (motion + UX) | **Accepted** — §2. |
| P1 | Ledger expansion via set ticks, not chevrons; filled/hollow ticks are the partial render; expansion timing locked (visual; UI's chevron declined; motion's timing kept) | **Accepted** — §9. |
| P1 | Plan-vs-actual on expanded rows in the ink law (actual ink, plan pencil) (UI) | **Accepted** — §9. |
| P1 | One band component, three contexts; dim data-viz tokens added to DESIGN.md; VO grammar + milestone announcement (UI) | **Accepted** — §6 + DESIGN.md. |
| P2 | Idle law (nothing animates at rest), static stat numbers (never count-up), Reduce Motion end-state + haptic order survives (motion) | **Accepted** — §2, §3. |
| P2 | Title-block eyebrow: tag boxes classification only, date unboxed; one session-name string with Today (visual + UI) | **Accepted** — §4. |
| P2 | Stat line two-tone (digits ink, words pencil) (visual) | **Accepted** — §4. |

Cross-doc flags filed (grep-and-report, not edited here): `splash-today.md`'s
resume card needs the one-tap honest close that `live-loop.md` §7 promises;
`onboarding-calibration.md` §3.7's band rows become context #1 of the §6 band
component at their next amendment. Build dependencies named: band-center
history snapshots (model API); Progress detail (gates the strip's tap-through).
Deferred: AI read line (dormant spec, §5); share (v1.x, §11).
