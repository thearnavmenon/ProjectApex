# Drop the gym scanner; adopt a global AI-grown equipment catalog

**Status**: accepted, 2026-05-01

## Context

The shipped MVP includes a Vision-API gym scanner (`GymScanner/` directory: `CameraManager`, `ScannerView`, `ScannerViewModel`, `EquipmentMerger`, `VisionAPIService`, `SystemPrompt_GymScan.txt`). It captures equipment via camera and infers presence via Anthropic Vision. P1-T02 already retreated from "Vision returns weight ranges" to presence-only because Vision was unreliable on weight inference; P1-T12 already changed from continuous-pan to single-shot per-equipment. In real-world use at large commercial gyms, the scanner is socially awkward (photographing an unfamiliar gym), incomplete (50+ machines can't be panned in one session), and post-scan cleanup is needed regardless. The structured `EquipmentType` enum has ~26 cases plus a `case unknown(String)` escape hatch, but specialty gear common at large gyms (hip thrust, GHD, T-bar row, trap bar, belt squat, plate-loaded variants, calf raise, abductor/adductor, sissy squat, sled) has no first-class representation.

This ADR is referenced by ADR-0005 (trainee model): equipment data feeds the trainee model's session-generation context via the gym profile, and the multi-gym semantics in ADR-0005 inherit the catalog architecture decided here.

## Decision

Two coupled changes:

1. **Retire the gym scanner entirely.** Delete `GymScanner/` directory and the gym-scan system prompt. Drop AVFoundation usage from onboarding. Drop the camera permission request from the onboarding flow.
2. **Adopt a global, AI-grown equipment catalog (C5).** New `equipment_catalog` Postgres table, scoped *globally* (no `user_id` foreign key), seeded with the existing ~26 structured types plus ~10 specialty additions. The catalog grows organically: when a user types a machine name not present in the catalog, an Anthropic inference call infers structured metadata (category, weight type, default max, default increment, primary muscle groups), the user reviews/edits, and the new entry is written to the global catalog plus referenced by the user's `gym_profiles.equipment` row. Per-gym overrides (this gym's max is 35kg not the default 50kg) live on the user's gym profile, not the catalog. The `case unknown(String)` enum case becomes obsolete and is removed.

Equipment-onboarding flow without scanner: a single scrollable list of equipment items with **most common at top, specialty below**, tap-to-select. A search input at the top handles tail items — types not in the list trigger AI inference → user confirms → catalog grows.

**List sort order**: items are sorted by **frequency of selection across the global catalog** (descending). On cold start (empty global usage data), an initial developer-curated ordering seeds the list — barbell / dumbbell / cable / power rack / adjustable bench / etc. at the top; specialty plate-loaded and machine variants below. Once usage data accrues (≥50 selections per item across all users), frequency replaces the curated ordering. Alphabetical sort is offered as a search-time secondary order; not the default. Documented in code as a single source of truth so the ordering doesn't drift from this commitment.

## Considered Options

Five catalog-growth alternatives:

- **(C1) Static expanded catalog.** Manually expand the structured `EquipmentType` enum with ~30 specialty cases, owned by the developer. Rejected: maintenance treadmill — the long tail is infinite, and someone has to keep adding gear forever.
- **(C2) Keep current catalog, lean on `unknown(String)` heavily.** Surface "Add custom" prominently; AI receives free-text names and reasons about them. Rejected: underuses the structured catalog. Most equipment is well-known and *should* be structured (with proper increments, exercise mapping); custom-as-default loses signal.
- **(C3) Hybrid: moderate static expansion + first-class custom equipment** (~10 specialty additions plus a structured custom-equipment flow). Was the assistant's initial recommendation; rejected in favour of (C5) on user pushback.
- **(C4) Per-user AI inference, no global persistence.** Each user pays the inference cost separately for the same equipment. Rejected: wasteful at multi-user scale (P-B alpha test); each new user re-pays AI for known machines.
- **(C5) Global AI-grown catalog (chosen).** First user to encounter a machine pays the inference cost; the catalog persists globally; subsequent users hit the cache. Self-improving. Aligned with multi-user trajectory (alpha test under (P-B) becomes the seeding cohort).

Two scanner-retirement sub-variants:

- **Keep scanner code dormant** in case we want to revive it later. Rejected: dead code rots; the deferred decision becomes a future cleanup task. If revived later, re-implement against the catalog architecture rather than restoring stale code.
- **Retire entirely (chosen).** `GymScanner/` deleted, dependencies (AVFoundation usage in onboarding, Vision API key path, camera permission prompt) removed.

Two onboarding-flow sub-variants for batch equipment entry:

- **Starter packs ("Commercial Gym Starter Pack" / "Home Gym" / "Hotel Gym" presets, each adds ~30 items in one tap).** Rejected: presets are an extra layer of indirection — the user already has to know which preset matches their gym, at which point they might as well just tap items.
- **Single scrollable list, common at top, search for tail (chosen).** Tap-to-select for known items; search + AI inference for specialty. Simplest direct flow.

One catalog-moderation sub-variant for multi-user scale:

- **Global catalog with no moderation** (any user-created catalog entry becomes immediately authoritative for all future users). Rejected for v3+ scale where adversarial or low-quality entries become a real risk. **Acceptable for v2 alpha-test under (P-B)** because the user cohort is the developer plus ~5 trusted friends — pre-moderation acceptance is fine at this scale. Multi-user post-launch (v3) will need a moderation/report mechanism (community flag, admin review, reputation-weighted edits, or pre-acceptance review for new entries). Documented here so future v3 readers see the alpha-test assumption was deliberate and not an oversight.

## Consequences

- The `case unknown(String)` enum case is removed via a phased migration: **Phase 0** — the v2 release ships with backfill code that reads existing `gym_profiles.equipment` rows referencing `unknown(String)`, runs an Anthropic inference call per unique unknown name, writes catalog entries, and rewrites the gym-profile rows to reference catalog IDs. Phase 0 runs once per user on first launch of the v2 build; failures are logged and the user is prompted to manually add unmatched items at next gym-profile edit. **Phase 1** — once Phase 0 has rolled out and backfill is verified complete, the `unknown(String)` enum case is deleted from the codebase and the migration code is removed in a follow-up release. Rollback: if Phase 0 backfill fails for any user, the `unknown(String)` rows persist in their gym profile and the enum case survives until manual reconciliation; the system never silently loses data.
- API key configuration loses the camera-vision dependency; the only remaining Vision API surface is set-by-set inference and macro/session generation (per ADR-0005's prompt architecture).
- Multi-gym onboarding (under ADR-0005's gym-aware Stage 2 generation) becomes faster: the same catalog seeds every new gym profile, only per-gym overrides differ.
- Cold-start cost for the very first user (empty global catalog) is bounded for a typical commercial gym — most items match the developer-seeded ~36-entry catalog, requiring only a handful of inference calls for genuinely specialty items. **Specialty-heavy gyms (powerlifting, CrossFit, strongman) may require 20+ inference calls during cold-start** because more equipment falls outside the seed; this is mitigated by the catalog growing rapidly across early users (the first powerlifting-gym alpha tester pays the inference cost once, the second hits cache for the same items). Each call produces a permanent catalog entry that benefits all future users.
- The catalog grows monotonically; no per-user pollution of the global record (per-gym corrections live on the user's gym profile). Bad inference results can be edited at the user's gym profile without affecting the global catalog; a moderation/report mechanism for the global catalog is deferred to multi-user post-launch.
