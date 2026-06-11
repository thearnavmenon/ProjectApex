// InkPencil.swift
// ProjectApex — DesignSystem
//
// "Work is ink, time is pencil" (DESIGN.md system law): all work numbers —
// prescriptions, logged sets, evidence — render in `ink`; all time digits and the
// *plan* (where plan and actual differ) render in `ink-muted` — the same cut,
// lighter value. Done work is the most-true data in the app; time and plan are not.
//
// This is the one shared component the foundation builds (ADR-0024): a two-tone
// `Text` run. Callers apply the font (e.g. `.apexFont(.heroNum)`); the helper only
// owns the ink/pencil colour split.

import SwiftUI

enum InkPencil {
    /// A two-tone run: an ink segment followed by a pencil (ink-muted) segment.
    /// Use for work + unit (`"100"` / `" kg"`) or work + time, etc.
    static func run(ink inkText: String, pencil pencilText: String, theme: Theme) -> Text {
        Text(inkText).foregroundStyle(theme.ink.color)
            + Text(pencilText).foregroundStyle(theme.inkMuted.color)
    }

    /// Done work (ink) beside the plan it diverged from (pencil):
    /// `"100 kg × 6 · plan 5"` — actual is ink, plan is pencil.
    static func actualVersusPlan(actual: String, plan: String, theme: Theme) -> Text {
        run(ink: actual, pencil: " · plan \(plan)", theme: theme)
    }
}
