// CapabilityBand.swift
// ProjectApex — DesignSystem/Instruments
//
// The capability band: one component, three contexts.
// DESIGN.md §Data-visualization + post-workout.md §6 + progress.md §3.
//
// Three contexts via `CapabilityBandContext`:
//   .full      — post-workout evidence strip and Progress pattern detail.
//                Full anatomy: 8% band fill, 2px floor tick, 1px stretch tick,
//                measured/estimated dot, dimension-bracket movement, caption slot.
//   .onboarding — same anatomy as .full at a slightly smaller default height,
//                still labeled and captioned — the model-reveal in onboarding.
//   .list       — unlabeled (numbers in the row annotation), 5pt dot, no bracket;
//                used in Progress root rows where the floor ticks fuse into the spine.
//
// Binding amendment (load-bearing): takes a `PatternProjection` (floor/stretch/progress)
// PLUS an `AxisConfidence` for the confidence cue. `PatternProjection` has no confidence
// field, so the caller supplies it separately (typically from `PatternProfile.confidence`).
//
// Confidence → visual cue (ratified honesty rule):
//   .established / .seasoned   → measured: SOLID dot + solid edges
//   .bootstrapping / .calibrating → estimated: HOLLOW dot + dashed edges
//
// DORMANT: built but not wired into the live shell — old views untouched (#345).
// No entrance animation in the bare instrument; no idle animation.

import SwiftUI

// MARK: - CapabilityBandContext

/// Selects the anatomy and labeling level for the band component.
enum CapabilityBandContext: Equatable, Sendable {
    /// Full anatomy: labeled ticks, dot, movement bracket, caption slot.
    /// Used on the post-workout evidence strip and the Progress pattern detail.
    case full
    /// Same anatomy as `.full`. The onboarding model-reveal context — same component,
    /// same labeling, same caption slot — differing only in scale (the caller frames it).
    case onboarding
    /// List-scale reduction: unlabeled, 5pt dot, no bracket.
    /// Used in Progress root rows. Numbers live in the row annotation, not the drawing.
    case list
}

// MARK: - CapabilityBandInput

/// The data contract: the projection plus the axis confidence.
struct CapabilityBandInput: Equatable, Sendable {
    /// The pattern's floor, stretch, and projection progress.
    let projection: PatternProjection
    /// Confidence axis — determines measured (solid) vs estimated (hollow/dashed).
    let confidence: AxisConfidence
    /// Today's best e1RM for the pattern, if any. `nil` = no dot rendered.
    let observedE1RM: Double?
    /// Movement delta for the dimension bracket (post-workout.md §6).
    /// `nil` = no bracket rendered (flat session or below noise threshold).
    let movementDeltaKg: Double?
    /// Caption shown beneath the drawing (e.g. "Bench press — most worked today").
    /// `nil` = no caption slot rendered. `.list` context ignores this.
    let caption: String?

    init(
        projection: PatternProjection,
        confidence: AxisConfidence,
        observedE1RM: Double? = nil,
        movementDeltaKg: Double? = nil,
        caption: String? = nil
    ) {
        self.projection = projection
        self.confidence = confidence
        self.observedE1RM = observedE1RM
        self.movementDeltaKg = movementDeltaKg
        self.caption = caption
    }
}

// MARK: - Confidence helpers (the honesty rule)

extension AxisConfidence {
    /// Whether this confidence level maps to a measured (solid) visual cue.
    /// `.established` and `.seasoned` → solid dot + solid band edges.
    /// `.bootstrapping` and `.calibrating` → hollow dot + dashed edges.
    var isMeasured: Bool {
        switch self {
        case .established, .seasoned: true
        case .bootstrapping, .calibrating: false
        }
    }
}

// MARK: - CapabilityBand

/// The capability band — one component, three contexts.
///
/// Renders assembled at frame 1 (no entrance animation in the bare instrument).
/// No idle animation, no breathing, no looping. Entrance and motion sequences
/// live in separate wrapper views (`post-workout.md` §3, §7).
struct CapabilityBand: View {

    let input: CapabilityBandInput
    let context: CapabilityBandContext

    @Environment(\.apexTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            BandCanvas(input: input, context: context, theme: theme)
            if context != .list, let caption = input.caption {
                Text(caption)
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)  // included in the parent accessibility label
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: VoiceOver grammar (post-workout.md §6)
    // "Bench press. Estimated one-rep max 92 kilograms, measured. Capability band 88 to 96."
    private var accessibilityLabel: String {
        let patternName = input.projection.pattern.displayName
        var parts: [String] = [patternName]
        if let e1rm = input.observedE1RM {
            let qualifier = input.confidence.isMeasured ? "measured" : "estimated"
            parts.append("Estimated one-rep max \(formatKg(e1rm)) kilograms, \(qualifier).")
        }
        parts.append("Capability band \(formatKg(input.projection.floor)) to \(formatKg(input.projection.stretch)).")
        if let delta = input.movementDeltaKg {
            let sign = delta >= 0 ? "+" : ""
            parts.append("Center moved \(sign)\(formatKg(delta)) kilograms.")
        }
        return parts.joined(separator: " ")
    }

    private func formatKg(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2  // 0.5 kg precision per progress.md §5
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - BandCanvas (the drawing)

/// The drawing surface: band fill, floor/stretch ticks, dot, movement bracket.
/// Context determines labeling and dot size.
private struct BandCanvas: View {

    let input: CapabilityBandInput
    let context: CapabilityBandContext
    let theme: Theme

    var body: some View {
        GeometryReader { geo in
            let layout = BandLayout(
                floor: input.projection.floor,
                stretch: input.projection.stretch,
                observedE1RM: input.observedE1RM,
                width: geo.size.width
            )
            let h = geo.size.height
            let isMeasured = input.confidence.isMeasured

            ZStack(alignment: .topLeading) {
                // ── Band fill ──────────────────────────────────────────────
                bandFillShape(layout: layout, height: h)

                // ── Band edges (solid when measured, dashed when estimated) ──
                bandEdges(layout: layout, height: h, isMeasured: isMeasured)

                // ── Floor tick (2px, full ink — the heaviest line) ──────────
                floorTick(layout: layout, height: h)

                // ── Stretch tick (1px hairline) ─────────────────────────────
                stretchTick(layout: layout, height: h)

                // ── Today's dot ─────────────────────────────────────────────
                if let dotX = layout.dotX {
                    dot(x: dotX, height: h, isMeasured: isMeasured)
                }

                // ── Movement bracket (full context only; conditional) ────────
                if context != .list, let delta = input.movementDeltaKg,
                   let (bracketX1, bracketX2) = layout.bracketXRange {
                    movementBracket(x1: bracketX1, x2: bracketX2, delta: delta, height: h)
                }

                // ── Tick labels (full / onboarding contexts) ─────────────────
                if context != .list {
                    tickLabels(layout: layout, height: h)
                }
            }
        }
        .frame(height: bandHeight)
    }

    // MARK: Band height per context

    private var bandHeight: CGFloat {
        switch context {
        case .full: 64
        case .onboarding: 56
        case .list: 20  // compact strip height for Progress rows
        }
    }

    // MARK: Dot size per context

    private var dotDiameter: CGFloat {
        context == .list ? DesignGeometry.listScaleDot : 8
    }

    // MARK: Subviews

    private func bandFillShape(layout: BandLayout, height: CGFloat) -> some View {
        Rectangle()
            .fill(theme.bandFill.color)
            .frame(width: max(0, layout.stretchX - layout.floorX), height: height)
            .offset(x: layout.floorX)
    }

    @ViewBuilder
    private func bandEdges(layout: BandLayout, height: CGFloat, isMeasured: Bool) -> some View {
        if isMeasured {
            // Solid hairline left edge at floor
            Rectangle()
                .fill(theme.bandEdge.color)
                .frame(width: 1, height: height)
                .offset(x: layout.floorX)
            // Solid hairline right edge at stretch
            Rectangle()
                .fill(theme.bandEdge.color)
                .frame(width: 1, height: height)
                .offset(x: layout.stretchX)
        } else {
            // Dashed edges for estimated/projected confidence
            Path { p in
                p.move(to: CGPoint(x: layout.floorX, y: 0))
                p.addLine(to: CGPoint(x: layout.floorX, y: height))
            }
            .stroke(style: StrokeStyle(
                lineWidth: 1,
                dash: DesignGeometry.projectionDash
            ))
            .foregroundStyle(theme.bandEdge.color)

            Path { p in
                p.move(to: CGPoint(x: layout.stretchX, y: 0))
                p.addLine(to: CGPoint(x: layout.stretchX, y: height))
            }
            .stroke(style: StrokeStyle(
                lineWidth: 1,
                dash: DesignGeometry.projectionDash
            ))
            .foregroundStyle(theme.bandEdge.color)
        }
    }

    private func floorTick(layout: BandLayout, height: CGFloat) -> some View {
        Rectangle()
            .fill(theme.ink.color)
            .frame(width: DesignGeometry.floorTick, height: height)
            .offset(x: layout.floorX - DesignGeometry.floorTick / 2)
    }

    private func stretchTick(layout: BandLayout, height: CGFloat) -> some View {
        Rectangle()
            .fill(theme.inkMuted.color)
            .frame(width: DesignGeometry.stretchTick, height: height)
            .offset(x: layout.stretchX - DesignGeometry.stretchTick / 2)
    }

    @ViewBuilder
    private func dot(x: CGFloat, height: CGFloat, isMeasured: Bool) -> some View {
        let d = dotDiameter
        let centerY = height / 2

        if isMeasured {
            // Solid accent-ink dot
            Circle()
                .fill(theme.pointMeasured.color)
                .frame(width: d, height: d)
                .offset(x: x - d / 2, y: centerY - d / 2)
        } else {
            // Hollow ink-stroke dot (estimated)
            Circle()
                .stroke(theme.pointEstimatedStroke.color, lineWidth: 1.5)
                .frame(width: d, height: d)
                .offset(x: x - d / 2, y: centerY - d / 2)
        }
    }

    @ViewBuilder
    private func movementBracket(x1: CGFloat, x2: CGFloat, delta: Double, height: CGFloat) -> some View {
        let topY: CGFloat = 4
        let terminalHeight: CGFloat = 6
        let labelY: CGFloat = topY + terminalHeight + 2
        let sign = delta >= 0 ? "+" : ""
        let deltaStr = "\(sign)\(formatKg(delta)) KG"

        ZStack(alignment: .topLeading) {
            // Dimension line with terminal ticks
            Path { p in
                // Left terminal tick
                p.move(to: CGPoint(x: x1, y: topY))
                p.addLine(to: CGPoint(x: x1, y: topY + terminalHeight))
                // Horizontal dimension line
                p.move(to: CGPoint(x: x1, y: topY + terminalHeight / 2))
                p.addLine(to: CGPoint(x: x2, y: topY + terminalHeight / 2))
                // Right terminal tick
                p.move(to: CGPoint(x: x2, y: topY))
                p.addLine(to: CGPoint(x: x2, y: topY + terminalHeight))
            }
            .stroke(theme.inkMuted.color, lineWidth: DesignGeometry.stretchTick)

            // Delta label centered on the bracket
            Text(deltaStr)
                .apexFont(.label)
                .foregroundStyle(theme.ink.color)
                .monospacedDigit()
                .offset(x: (x1 + x2) / 2 - 20, y: labelY)
        }
    }

    @ViewBuilder
    private func tickLabels(layout: BandLayout, height: CGFloat) -> some View {
        let labelY = height + Spacing.xs

        // Floor label — "FLOOR 100"
        Text("FLOOR \(formatKg(input.projection.floor))")
            .apexFont(.label)
            .foregroundStyle(theme.inkMuted.color)
            .monospacedDigit()
            .offset(x: max(0, layout.floorX - 20), y: labelY)

        // Stretch label — "STRETCH 110"
        Text("STRETCH \(formatKg(input.projection.stretch))")
            .apexFont(.label)
            .foregroundStyle(theme.inkMuted.color)
            .monospacedDigit()
            .offset(x: min(layout.totalWidth - 60, layout.stretchX - 20), y: labelY)
    }

    private func formatKg(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - BandLayout

/// Computes x-positions for the floor tick, stretch tick, and dot within the
/// available width, expanding the domain to include out-of-band dots.
/// Dots plot outside the band, never clamped (post-workout.md §6).
struct BandLayout {
    let floorX: CGFloat
    let stretchX: CGFloat
    let dotX: CGFloat?
    /// The x-range for the movement bracket (previous center → new center).
    /// `nil` when `movementDeltaKg` is absent — set externally by the caller if needed.
    let bracketXRange: (CGFloat, CGFloat)?
    let totalWidth: CGFloat

    /// Minimum band render width (post-workout.md §6: "minimum band render width 48pt").
    static let minimumBandWidth: CGFloat = 48

    init(
        floor: Double,
        stretch: Double,
        observedE1RM: Double?,
        movementDeltaKg: Double? = nil,
        width: CGFloat
    ) {
        totalWidth = width

        // Domain: band ± 20%, expanded to include today's dot if outside.
        let bandWidth = stretch - floor
        let margin = bandWidth * 0.20

        var domainMin = floor - margin
        var domainMax = stretch + margin
        if let e1rm = observedE1RM {
            domainMin = min(domainMin, e1rm - margin * 0.5)
            domainMax = max(domainMax, e1rm + margin * 0.5)
        }
        let domainSpan = domainMax - domainMin

        func xFor(_ value: Double) -> CGFloat {
            guard domainSpan > 0 else { return width / 2 }
            return CGFloat((value - domainMin) / domainSpan) * width
        }

        let rawFloorX = xFor(floor)
        let rawStretchX = xFor(stretch)
        let rawBandWidth = rawStretchX - rawFloorX

        // Enforce minimum band width — shift label positions outboard if needed.
        if rawBandWidth < BandLayout.minimumBandWidth {
            let expansion = (BandLayout.minimumBandWidth - rawBandWidth) / 2
            floorX = rawFloorX - expansion
            stretchX = rawStretchX + expansion
        } else {
            floorX = rawFloorX
            stretchX = rawStretchX
        }

        if let e1rm = observedE1RM {
            dotX = xFor(e1rm)
        } else {
            dotX = nil
        }

        // Movement bracket: spans from bandCenter - delta/2 to bandCenter + delta/2.
        if let delta = movementDeltaKg {
            let center = (floor + stretch) / 2
            let halfDelta = abs(delta) / 2
            let prevCenter = delta >= 0 ? center - halfDelta : center + halfDelta
            let newCenter = delta >= 0 ? center + halfDelta : center - halfDelta
            bracketXRange = (xFor(prevCenter), xFor(newCenter))
        } else {
            bracketXRange = nil
        }
    }
}

// MovementPattern.displayName is defined in MovementPattern.swift — used directly.
