# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — ubiquitous-language glossary; terse term definitions with rejected synonyms.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The producer skill (`/grill-with-docs`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo (this is the layout for ProjectApex):

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-out-of-order-session-semantics.md
│   ├── 0002-queue-shape-programme-model.md
│   ├── 0003-three-tab-navigation-today-state-machine.md
│   ├── 0004-drop-gym-scanner-adopt-global-equipment-catalog.md
│   ├── 0005-persistent-structured-trainee-model.md
│   └── 0006-server-side-trainee-model-update-logic.md
└── ProjectApex/      ← Swift sources
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0005 (persistent trainee model) — but worth reopening because…_
