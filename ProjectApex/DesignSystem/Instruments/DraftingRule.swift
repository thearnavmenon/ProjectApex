// DraftingRule.swift
// ProjectApex — DesignSystem/Instruments
//
// The drafting-rule system: the shared committed-vs-provisional drawing vocabulary
// (#411 / ADR-0028). splash-today.md §The drawing (full-bleed hairlines + margin
// ticks), train.md §3 (the generation-horizon datum, the to-be-placed hatch, the
// discrete commitment gradient), progress.md §3 (the drafting register).
//
// The governing rule (ADR-0028): a mark is INK WITH NUMBERS iff the model has
// committed/measured the thing; PENCIL SHAPE-ONLY iff it is provisional/projected;
// and the committed↔provisional boundary is always DRAWN (a rule + a hatch), never
// left to ink-vs-pencil alone — because `ink-muted` already means time/metadata, so
// a lone pencil row reads as "secondary detail," not "the model hasn't placed this."
//
// The capability band (#345) already ships this axis (its dashed estimated-edges
// vs solid measured-edges); these primitives unify around it and the shared floor
// datum (`BandDatum`), they do not reinvent it.
//
// DORMANT: built but not wired into any live screen (the #345/#346 pattern). No
// entrance animation, no idle animation — each primitive renders assembled at
// frame 1; entrance/hard-swap motion lives in the wrappers that consume these.

import SwiftUI

// MARK: - DraftingRuleStyle

/// Whether a drafting rule is drawn solid (a committed/structural datum) or dashed
/// (a projected boundary). The dashed style reuses `DesignGeometry.projectionDash`
/// — the one confidence-dash vocabulary, identical to the band's estimated edges.
enum DraftingRuleStyle: Equatable, Sendable {
    /// A solid structural hairline — the horizon datum, a section rule.
    case solid
    /// A dashed hairline (4-2) — a projected / to-be-confirmed boundary.
    case dashed
}

// MARK: - DraftingRule

/// A full-bleed structural hairline with an optional left-margin tick — Today's
/// drawing signature (splash-today.md §The drawing) and Train's horizon datum
/// (train.md §3). 1px (`draftingRuleWidth`), full width; the tick is a 4pt
/// (`marginTickLength`) downstroke at the leading edge.
struct DraftingRule: View {

    let style: DraftingRuleStyle
    /// Whether to draw the 4pt left-margin tick beneath the leading edge.
    let showsMarginTick: Bool

    @Environment(\.apexTheme) private var theme

    init(style: DraftingRuleStyle = .solid, showsMarginTick: Bool = true) {
        self.style = style
        self.showsMarginTick = showsMarginTick
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let midY = DesignGeometry.draftingRuleWidth / 2

            ZStack(alignment: .topLeading) {
                // The full-bleed hairline.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: midY))
                    p.addLine(to: CGPoint(x: w, y: midY))
                }
                .stroke(style: strokeStyle)
                .foregroundStyle(theme.hairline.color)

                // The 4pt left-margin tick (a downstroke at the leading edge).
                if showsMarginTick {
                    Path { p in
                        p.move(to: CGPoint(x: DesignGeometry.draftingRuleWidth / 2, y: 0))
                        p.addLine(to: CGPoint(x: DesignGeometry.draftingRuleWidth / 2,
                                              y: DesignGeometry.marginTickLength))
                    }
                    .stroke(lineWidth: DesignGeometry.draftingRuleWidth)
                    .foregroundStyle(theme.hairline.color)
                }
            }
        }
        // Reserve the tick's height so the rule never clips its own downstroke.
        .frame(height: showsMarginTick ? DesignGeometry.marginTickLength : DesignGeometry.draftingRuleWidth)
        .accessibilityHidden(true)  // structural furniture; the datum's meaning is spoken by its register
    }

    private var strokeStyle: StrokeStyle {
        switch style {
        case .solid:
            StrokeStyle(lineWidth: DesignGeometry.draftingRuleWidth)
        case .dashed:
            StrokeStyle(lineWidth: DesignGeometry.draftingRuleWidth,
                        dash: DesignGeometry.projectionDash)
        }
    }
}

// MARK: - DraftingRegister

/// A two-tone tracked-caps margin annotation — the drafting register
/// (progress.md §3: "12W · **2** FLOORS UP · **+7.5** KG", digits ink/tnum, words
/// pencil). Built from `InkPencil.run`: the `digits` segment renders in `ink` with
/// tabular figures, the `words` segment in `ink-muted`.
///
/// ABSENT AT ZERO: when there is nothing to annotate, the register renders an
/// `EmptyView` — an empty slot, never "0 floors moved" (the honesty rule).
struct DraftingRegister: View {

    /// The ink (numeric) segment — e.g. "2". Empty/whitespace-only → the register
    /// is absent (EmptyView).
    let digits: String
    /// The pencil (word) segment — e.g. " FLOORS UP". Tracked caps, ink-muted.
    let words: String

    @Environment(\.apexTheme) private var theme

    /// The absent-at-zero predicate (the honesty rule, progress.md §3): a register
    /// with no ink digits to show renders nothing — an empty slot, never "0". A
    /// testable static so the rule is asserted without reflecting on `body`.
    static func isAbsent(digits: String) -> Bool {
        digits.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        if Self.isAbsent(digits: digits) {
            // Absent at zero — an empty slot, never a fabricated "0".
            EmptyView()
        } else {
            InkPencil.run(ink: digits, pencil: words, theme: theme)
                .apexFont(.label)
                .monospacedDigit()
                .tracking(1)  // tracked caps (the margin-annotation register)
                .accessibilityElement()
                .accessibilityLabel("\(digits)\(words)")
        }
    }
}

// MARK: - GenerationHorizonBreak

/// The drawn generation horizon (train.md §3): a solid `DraftingRule` across the
/// spine plus a `DraftingRegister` annotation — "PLACED ABOVE · SHAPE BELOW".
/// This is the datum that disambiguates ink (placed) from pencil (skeleton): the
/// boundary is DRAWN, not left to material alone.
struct GenerationHorizonBreak: View {

    /// The annotation's pencil words. Defaults to the canonical horizon legend.
    let legend: String

    @Environment(\.apexTheme) private var theme

    init(legend: String = "PLACED ABOVE · SHAPE BELOW") {
        self.legend = legend
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            DraftingRule(style: .solid, showsMarginTick: true)
            // The register's ink segment is the datum's marker glyph "—"; the legend
            // is the pencil words. (The marker is non-numeric but ink, so the register
            // renders — the horizon is never absent when drawn.)
            DraftingRegister(digits: "—", words: " \(legend)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generation horizon. \(legend).")
    }
}

// MARK: - ToBePlacedHatch

/// The to-be-placed hatch (train.md §3): a sparse diagonal hairline hatch in
/// `ink-muted` filling the skeleton zone below the horizon. Deliberately distinct
/// from the band's dashed *edges* (which run vertical and carry the estimated-band
/// vocabulary) so the two confidence marks never collide on one drawing.
///
/// "The model is guessing here" — the same read as the dashed band edges, drawn as
/// an area fill rather than an edge so it tiles the whole unplaced zone.
struct ToBePlacedHatch: View {

    @Environment(\.apexTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            HatchShape()
                .stroke(theme.inkMuted.color, lineWidth: DesignGeometry.hatchLineWidth)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)  // the "not yet placed" meaning is spoken by the day-row's status
    }
}

/// The diagonal hatch geometry: parallel lines at `hatchAngleDegrees`, spaced
/// `hatchSpacing` apart, sweeping the full rect. Drawn as a `Shape` so it tiles
/// any zone size deterministically (no per-frame allocation beyond the path).
struct HatchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing = DesignGeometry.hatchSpacing
        let angle = DesignGeometry.hatchAngleDegrees * .pi / 180
        let slope = tan(angle)
        // A 45° (positive-slope, downward-right) family of lines y = slope·x + c.
        // Sweep the intercept range that covers the whole rect, stepping by the
        // perpendicular spacing projected onto the y-axis.
        let yStep = spacing / cos(angle)
        // Cover from above the top-left to below the bottom-right.
        let cStart = rect.minY - slope * rect.maxX
        let cEnd = rect.maxY - slope * rect.minX
        var c = cStart
        while c <= cEnd {
            // Line y = slope·x + c, clipped to the rect.
            let yAtMinX = slope * rect.minX + c
            let yAtMaxX = slope * rect.maxX + c
            path.move(to: CGPoint(x: rect.minX, y: yAtMinX))
            path.addLine(to: CGPoint(x: rect.maxX, y: yAtMaxX))
            c += yStep
        }
        return path
    }
}

// MARK: - CommitmentTier (the discrete gradient)

/// The commitment gradient as DISCRETE tiers, not a continuous fade (train.md §3,
/// ratified ADR-0028). A day's distance-from-now buckets into one of three render
/// tiers — full detail near, one glyph per day far — reinforcing that the model
/// knows less the further out you look.
///
/// THE NO-SLOPE CARVE-OUT: the §8.2 ban on opacity gradients targets *confidence
/// signals on the e1RM chart*, where a gradient would imply a continuous measured
/// signal. This is *calendar furniture compression* — a different object, drawn as
/// discrete steps so it can never be misread as a confidence-on-a-chart gradient.
enum CommitmentTier: Equatable, Sendable, CaseIterable {
    /// This week (≤ `commitmentThisWeekMaxDay` days out) — full row detail.
    case thisWeek
    /// Next week-ish (≤ `commitmentCompressedMaxDay`) — compressed brief shape.
    case compressed
    /// Beyond — one pencil glyph per day.
    case glyphPerDay

    /// Bucket a day's distance-from-now (in days, clamped at 0) into its tier.
    /// A TOTAL function over `Int` (mirrors the band's `isMeasured` totality):
    /// every distance, including negatives (already-past), maps to a tier.
    static func forDistance(days: Int) -> CommitmentTier {
        let d = max(0, days)
        if d <= DesignGeometry.commitmentThisWeekMaxDay {
            return .thisWeek
        } else if d <= DesignGeometry.commitmentCompressedMaxDay {
            return .compressed
        } else {
            return .glyphPerDay
        }
    }
}

// MARK: - CommitmentState (the committed-vs-provisional governing rule)

/// Whether a thing is COMMITTED (the model placed/measured it → ink with numbers)
/// or PROVISIONAL (skeleton/projected → pencil shape-only). The governing axis of
/// the whole drafting-rule system, kept as one enum so callers branch on the rule
/// rather than re-encoding ink-vs-pencil ad hoc.
///
/// Mirrors the band's measured/estimated axis (`AxisConfidence.isMeasured`): a
/// committed mark is the band's measured cue; a provisional one is its estimated
/// (hollow/dashed) cue. `forConfidence` is the TOTAL bridge between the two.
enum CommitmentState: Equatable, Sendable, CaseIterable {
    /// The model has placed it — render in ink with numbers (solid).
    case committed
    /// Still provisional — render pencil shape-only (dashed / hatched).
    case provisional

    /// The drafting rule's render style for this state — committed is the solid
    /// structural datum, provisional carries the projection dash.
    var ruleStyle: DraftingRuleStyle {
        switch self {
        case .committed: .solid
        case .provisional: .dashed
        }
    }

    /// Bridge from the band's confidence axis: measured confidence is committed,
    /// estimated confidence is provisional. A TOTAL function over `AxisConfidence`
    /// (it routes through `isMeasured`, which the band proves exhaustive).
    static func forConfidence(_ confidence: AxisConfidence) -> CommitmentState {
        confidence.isMeasured ? .committed : .provisional
    }
}
