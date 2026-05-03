# Out-of-order session semantics: untouched queue + dedupe by session ID

**Status**: accepted, 2026-05-01

## Context

The programme is a queue of sessions in fixed order (Push A → Pull A → Legs A → Push B → …) under ADR-0002. FB-009 already lets the user start any generated session out of queue order; the question was what happens to the queue when they do.

## Decision

When a user picks an out-of-order session and completes it (call this **Model E**):

1. The queue pointer **does not advance**. Tomorrow's "Up next" is whatever it would have been.
2. The **next instance of the picked session in the queue** is auto-marked complete (de-dupe), with explicit user confirmation in the post-workout summary screen — not silent.
3. De-dupe matches by **exact session ID/name**, not by movement-pattern family. Legs A done out-of-order consumes the next Legs A in the queue, not the next Legs B.

If the picked session has no future instance in the queue, the session is logged as a free-floating training event and no de-dupe occurs.

## Considered Options

- **Model A — untouched queue, no de-dupe.** Simplest. Out-of-order sessions are free-floating logs. Rejected: feels like the app ignored what the user actually did.
- **Model B — strict skip-ahead.** Picking session at queue position K marks all earlier sessions skipped. Rejected: punishingly loses planned sessions.
- **Model C — slot consumption + de-dupe.** Today's slot consumed by the picked session; original head marked skipped. Rejected: violates "the plan is sacred" — substituting one session for today's slot shouldn't void the planned session entirely.
- **Model D — replace-and-shift.** Picked session replaces queue head; original head goes to back of queue. Rejected: doesn't match user expectation that the queue continues from where it was.
- **Model E (chosen).** Untouched queue, de-dupe future instance, explicit user confirmation. Preserves "the plan is sacred" while honouring substitution intent.

Within Model E, three sub-variants were also weighed (one chosen, two rejected):

- **E1 — silent de-dupe.** The next Legs A in the queue is silently marked complete after today's out-of-order Legs A finishes. Rejected: silent magic is hostile when the user disagrees with the system's inference, and there's no recovery affordance.
- **E2 — explicit confirmation in the post-workout summary (chosen).** Post-workout summary asks: *"This counts as your next Legs A (Week 6) too — mark complete?"* with a default of yes and a "no, keep both" override. Single-screen friction (a screen the user already sees), full agency, undoable.
- **Family-level matching** (e.g., Legs A done out-of-order consumes the next *any-Legs* session). Rejected: Legs A and Legs B are programmed with different exercise selections and volume targets — treating them as fungible defeats the point of the AI's plan structure.

Locked combination: **Model E + E2 (explicit confirmation in post-workout summary) + exact session-ID match** for the de-dupe target.

## Consequences

- The queue can outlast its planned session count if the user repeatedly does sessions out-of-order without de-dupe matches (e.g., freestyle sessions). Acceptable.
- The post-workout summary gains an E2 confirmation card ("This counts as your next Legs A — mark complete?"). Default is yes, undo affordance available.
- Queue-pointer advancement remains tied to in-order completions and explicit skips, never to out-of-order substitutions.
