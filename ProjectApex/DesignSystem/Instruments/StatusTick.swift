// StatusTick.swift
// ProjectApex — DesignSystem/Instruments
//
// Shared drawn instrument for day/set status — the drawn replacement for
// the banned green check (train.md §3, live-loop.md §3, post-workout.md §9).
//
// DORMANT: reusable component, built but not wired into any live screen (#410).
// Consuming screen (#357 Train spine) owns the model→value mapping, because it
// depends on the generation horizon — this instrument is a dumb primitive.
//
// Three values:
//   .filled   — done/logged. Solid ink fill.
//   .hollow   — committed-not-done. Ink stroke ~1.5px, paper interior.
//   .undrawn  — skeleton/below-horizon. Renders nothing (the drafting-rule
//               zone slice #411 is the only mark in this zone).
//
// Today marker: isToday=true layers a quiet 2px ink left-margin rule.
// Static — no pulse/animation (train.md §2 idle-law).
//
// RestWellNode: a sibling view in this file, NOT a tick — a recessed `well`
// row stating what recovery buys, derived from day-of-week gaps (train.md §3).
// The Train spine renders it at rest-day positions on the calendar.
//
// Accessibility: the caller supplies the label (a status phrase). The instrument
// never invents copy; VoiceOver speaks status, not "image".
//
// Honesty: no count, ring, percentage, or numeric content anywhere (guarded by test).

import SwiftUI

// MARK: - StatusTickValue

/// The three display values of the StatusTick instrument.
/// The mapping from model state (completed / generated / skeleton / skipped)
/// to these values is the consuming screen's responsibility (train.md §3).
enum StatusTickValue: Equatable, Sendable {
    /// Done / logged — solid ink fill.
    case filled
    /// Committed-not-done (generated, above horizon) — ink stroke, paper interior.
    case hollow
    /// Skeleton / below-horizon — renders nothing. The drafting-rule zone
    /// (sibling slice #411) is the only mark in this position.
    case undrawn
}

// MARK: - StatusTick

/// A dumb primitive that draws the value it is handed.
///
/// Assembled at frame 1, no entrance or idle animation.
/// The caller supplies an `accessibilityLabel` — the instrument never invents copy.
struct StatusTick: View {

    let value: StatusTickValue
    /// When true, a quiet 2px ink left-margin rule is layered on the tick.
    /// Static — no pulse, no animation.
    var isToday: Bool = false
    /// Status phrase for VoiceOver (e.g. "Squat day — done", "Rest day").
    /// Required: the instrument has no fallback copy.
    var accessibilityLabel: String = ""

    @Environment(\.apexTheme) private var theme

    var body: some View {
        switch value {
        case .undrawn:
            // Renders nothing — EmptyView holds zero size.
            EmptyView()
        case .filled, .hollow:
            tickMark
        }
    }

    // MARK: Tick mark (filled or hollow)

    private var tickMark: some View {
        ZStack(alignment: .leading) {
            // Today left-margin rule (2px, ink, static)
            if isToday {
                Rectangle()
                    .fill(theme.ink.color)
                    .frame(width: 2, height: DesignGeometry.dayStatusTick)
            }

            // The tick shape itself
            tickShape
                .frame(width: DesignGeometry.dayStatusTick, height: DesignGeometry.dayStatusTick)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var tickShape: some View {
        switch value {
        case .filled:
            Circle()
                .fill(theme.ink.color)
        case .hollow:
            Circle()
                .stroke(theme.ink.color, lineWidth: DesignGeometry.dayStatusTickStroke)
                .background(
                    Circle().fill(theme.paper.color)
                )
        case .undrawn:
            EmptyView()
        }
    }
}

// MARK: - RestWellNode

/// A recessed `well` row on the Train spine at rest-day positions.
///
/// NOT a tick — rest is derived from day-of-week gaps, with no model change.
/// The view states what recovery buys; the caller supplies the recovery line
/// (e.g. "Rest — recovery builds the adaptation").
///
/// No tick, no icon, no count: only the `well` token and a single text line.
struct RestWellNode: View {

    /// The recovery line, supplied by the caller.
    /// Example: "Rest day — adaptation happens here."
    let recoveryLine: String

    @Environment(\.apexTheme) private var theme

    var body: some View {
        Text(recoveryLine)
            .apexFont(.label)
            .foregroundStyle(theme.inkMuted.color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.well.color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(recoveryLine)
    }
}
