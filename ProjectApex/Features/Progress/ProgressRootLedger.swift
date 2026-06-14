// ProgressRootLedger.swift
// ProjectApex — Features/Progress
//
// The Phase 3 Progress root: the capability ledger.
// progress.md §3 — band-relative rows fused to one shared 2px floor datum
// (the spine), each pattern in fixed canonical order, list-scale CapabilityBand
// in each row, distance-to-ratchet as honest-absence instrument annotation,
// and a margin totalizer (absent at zero).
//
// DORMANT: built, wired in AppShell.surface(.progress), but the 3-tab shell
// is behind useNewShell = false (ADR-0026). ContentView, ProgressTabView, and
// ProgramOverviewView are untouched.
//
// Q11 amendment (load-bearing):
//   - sessionsAboveFloor does NOT exist in iOS models → distance-to-ratchet is
//     rendered as a QUALITATIVE honest-absence annotation ("ratchet within reach"),
//     never a fabricated numeric count.
//   - Canonical pattern order is a LOCAL sort in this view only — the shared
//     MovementPattern enum is not edited.
//
// Data contract: accepts patterns/projections as injectable inputs so
// unit/snapshot tests can drive the view with fixtures, no live service needed.

import SwiftUI

// MARK: - Canonical pattern order (local to this view — do NOT edit MovementPattern)

/// The model's own taxonomy order (progress.md §3 "fixed canonical pattern order").
/// Squat → Hinge → H-Press → V-Press → H-Pull → V-Pull → Lunge → Isolation.
private let canonicalPatternOrder: [MovementPattern] = [
    .squat,
    .hipHinge,
    .horizontalPush,
    .verticalPush,
    .horizontalPull,
    .verticalPull,
    .lunge,
    .isolation,
]

// MARK: - ProgressRootLedger (the new root view)

/// The Progress root capability ledger (progress.md §3).
/// Injectable inputs: each pattern row needs its PatternProjection and confidence.
struct ProgressRootLedger: View {

    // MARK: Input types

    /// One row's worth of ledger data. Injectable so tests can drive with fixtures.
    struct PatternRow: Identifiable {
        var id: MovementPattern { projection.pattern }
        let projection: PatternProjection
        let confidence: AxisConfidence
        /// True = pattern is currently in the user's program; false = dormant/out-of-program.
        let isActive: Bool
        /// Last trained date for dormant rows (displayed when !isActive). Nil when active.
        let lastTrainedDate: Date?
        /// True iff the pattern is re-anchoring after a long absence
        /// (PatternProfile.inTransitionMode). When true the row carries a small
        /// transition marker so the band's floor/stretch isn't read as settled.
        /// Defaulted so existing fixtures stay valid.
        let inTransition: Bool = false
    }

    // MARK: Inputs

    /// Rows in canonical order — the view re-sorts locally before rendering.
    let rows: [PatternRow]

    // MARK: Private

    @Environment(\.apexTheme) private var theme

    /// Rows sorted into fixed canonical taxonomy order (progress.md §3 ordering law).
    private var sortedRows: [PatternRow] {
        rows.sorted { a, b in
            let ia = canonicalPatternOrder.firstIndex(of: a.id) ?? canonicalPatternOrder.count
            let ib = canonicalPatternOrder.firstIndex(of: b.id) ?? canonicalPatternOrder.count
            return ia < ib
        }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Margin row — "Progress" title
                marginRow

                // The spine + rows.
                // The spine is the aligned floor ticks from each CapabilityBand(.list)
                // fusing into one continuous 2px ink vertical (progress.md §3).
                // We use a ZStack with a GeometryReader to draw the spine behind the rows.
                ZStack(alignment: .topLeading) {
                    spine
                    patternRows
                }
                .padding(.top, Spacing.sm)
            }
            .padding(.horizontal, Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.paper.color.ignoresSafeArea())
    }

    // MARK: Margin row

    private var marginRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Progress")
                .apexFont(.title)
                .foregroundStyle(theme.ink.color)
            Spacer()
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .overlay(alignment: .bottom) {
            theme.hairline.color.frame(height: 1)
        }
    }

    // MARK: Spine

    /// The shared 2px ink vertical running the full strip column (progress.md §3).
    /// Positioned at the floor-tick x-position of the band strip. Since every row
    /// renders CapabilityBand(.list) at 20pt height, and the floor tick is centered
    /// on the band at approximately 10% from the leading edge of the strip inset,
    /// the spine uses a GeometryReader to stretch behind all rows.
    private var spine: some View {
        GeometryReader { geo in
            // The band strip occupies the full row width after the name + annotation.
            // The spine runs behind the entire strip column. progress.md: "floor ticks
            // fuse into one continuous 2px ink vertical."
            // The floor tick x is at ~20% of the strip width (domain margin).
            // Rather than replicating BandLayout math, we place the spine as a full-height
            // vertical at the leading band position — the actual fusing effect comes from
            // every CapabilityBand(.list) rendering its own 2px floor tick aligned here.
            // This spine extends behind all rows as a background element.
            Rectangle()
                .fill(theme.ink.color)
                .frame(width: DesignGeometry.floorTick, height: geo.size.height)
                .offset(x: spineX(totalWidth: geo.size.width))
        }
        .allowsHitTesting(false)
    }

    /// X-position of the spine — the SHARED floor datum (`BandDatum.floorX`), the
    /// same helper the capability band and Train's horizon compute against. Every
    /// row's `CapabilityBand(.list)` plots its own floor tick at this coordinate,
    /// so all the ticks fuse onto one datum instead of drifting under the 48pt
    /// minimum-band-width expansion (the #408 fix — no more inline re-derivation).
    private func spineX(totalWidth: CGFloat) -> CGFloat {
        BandDatum.floorX(width: totalWidth) - DesignGeometry.floorTick / 2
    }

    // MARK: Pattern rows

    private var patternRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sortedRows) { row in
                if row.isActive {
                    ActivePatternRow(row: row)
                } else {
                    DormantPatternRow(row: row)
                }
                Divider()
                    .overlay(theme.hairline.color)
            }
        }
    }
}

// MARK: - ActivePatternRow

/// A full row for an in-program pattern (progress.md §3 row anatomy).
/// Line 1: pattern name. Line 2: list-scale band strip. Line 3: annotation.
private struct ActivePatternRow: View {

    let row: ProgressRootLedger.PatternRow
    @Environment(\.apexTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Line 1 — pattern name, Inter 500 17pt ink, wraps at AX
            Text(row.projection.pattern.displayName)
                .apexFont(.body)
                .fontWeight(.medium)
                .foregroundStyle(theme.ink.color)
                .fixedSize(horizontal: false, vertical: true)

            // Line 2 — list-scale band strip (progress.md §3, #345 component)
            CapabilityBand(
                input: CapabilityBandInput(
                    projection: row.projection,
                    confidence: row.confidence,
                    observedE1RM: nil,
                    movementDeltaKg: nil,
                    caption: nil
                ),
                context: .list
            )

            // Line 3 — annotation (two-tone, reserved line height)
            annotationView
                .frame(minHeight: 16, alignment: .leading)  // reserved line height

            // Long-absence re-anchoring marker — the band is provisional while the
            // pattern re-establishes; surface that rather than read it as settled.
            if row.inTransition {
                Text("Re-establishing after a break")
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Annotation (progress.md §3 annotation priority rules)

    @ViewBuilder
    private var annotationView: some View {
        let floor = row.projection.floor

        if row.confidence == .bootstrapping || row.confidence == .calibrating {
            // Calibrating: "still calibrating — X more sessions" but we have no
            // exact count from the model API, so render the honest state label.
            (Text("still calibrating — ")
                .foregroundStyle(theme.inkMuted.color)
             + Text("establishing band")
                .foregroundStyle(theme.inkMuted.color))
                .apexFont(.label)
        } else {
            // Ratchet-within-reach (Q11: honest-absence, no fabricated count).
            // progress.md §3: "ratchet within reach"-style instrument annotation.
            // The quantitative count (sessions above floor) is a later model-API slice.
            // We render the qualitative annotation always as the forward hook.
            (Text("Floor ")
                .foregroundStyle(theme.inkMuted.color)
             + Text(formatKg(floor))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.ink.color)
             + Text(" · ratchet within reach")
                .foregroundStyle(theme.inkMuted.color))
                .apexFont(.label)
        }
    }

    // MARK: Accessibility

    private var accessibilityLabel: String {
        let patternName = row.projection.pattern.displayName
        let floor = formatKg(row.projection.floor)
        let stretch = formatKg(row.projection.stretch)
        let base = "\(patternName). Capability band, floor \(floor) to stretch \(stretch). Ratchet within reach."
        return row.inTransition ? base + " Re-establishing after a break." : base
    }

    // MARK: Formatting

    private func formatKg(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - DormantPatternRow

/// A compact muted row for a dormant/out-of-program pattern (progress.md §3).
/// "name + Floor X + last trained Date — no strip."
private struct DormantPatternRow: View {

    let row: ProgressRootLedger.PatternRow
    @Environment(\.apexTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(row.projection.pattern.displayName)
                    .apexFont(.body)
                    .foregroundStyle(theme.inkMuted.color)
                Spacer(minLength: 0)
                annotationText
            }

            // Long-absence re-anchoring marker — the floor is provisional while the
            // pattern re-establishes; surface that rather than read it as settled.
            if row.inTransition {
                Text("Re-establishing after a break")
                    .apexFont(.label)
                    .foregroundStyle(theme.inkMuted.color)
            }
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var annotationText: some View {
        let floor = row.projection.floor
        let floorStr = formatKg(floor)

        if let lastDate = row.lastTrainedDate {
            // "Floor 100 · last trained 12 May" (date in pencil)
            (Text("Floor ")
                .foregroundStyle(theme.inkMuted.color)
             + Text(floorStr)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.inkMuted.color)
             + Text(" · last trained ")
                .foregroundStyle(theme.inkMuted.color)
             + Text(formattedDate(lastDate))
                .foregroundStyle(theme.inkMuted.color))
                .apexFont(.label)
        } else {
            (Text("Floor ")
                .foregroundStyle(theme.inkMuted.color)
             + Text(floorStr)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.inkMuted.color))
                .apexFont(.label)
        }
    }

    private func formatKg(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}

// MARK: - ProgressRootLedger + TraineeModelService binding

extension ProgressRootLedger {
    /// Builds rows from a live TraineeModel. Called from the AppShell binding.
    /// Returns nil when no model is available (cold start).
    static func rows(from model: TraineeModel) -> [PatternRow] {
        let projectionsByPattern: [MovementPattern: PatternProjection] = Dictionary(
            uniqueKeysWithValues: (model.projections?.patternProjections ?? [])
                .map { ($0.pattern, $0) }
        )
        return canonicalPatternOrder.compactMap { pattern -> PatternRow? in
            guard let proj = projectionsByPattern[pattern] else { return nil }
            let profile = model.patterns[pattern]
            let confidence = profile?.confidence ?? .bootstrapping
            let lastDate = profile?.recentSessionDates.max()
            // A pattern is considered active if it has had any recent sessions.
            let isActive = !(profile?.recentSessionDates.isEmpty ?? true)
            // Re-anchoring after a long absence: the band is provisional until the
            // transition window expires (inTransitionMode defaults its clock to now).
            let inTransition = profile?.inTransitionMode() ?? false
            return PatternRow(
                projection: proj,
                confidence: confidence,
                isActive: isActive,
                lastTrainedDate: isActive ? nil : lastDate,
                inTransition: inTransition
            )
        }
    }
}

// MARK: - ProgressRootLedgerHost (wired to deps, rendered by AppShell)

/// The live host: reads the trainee model asynchronously and renders the ledger.
/// Injectable-input ProgressRootLedger is the testable core;
/// this host owns the async/service boundary.
struct ProgressRootLedgerHost: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(\.apexTheme) private var theme
    @State private var rows: [ProgressRootLedger.PatternRow] = []

    var body: some View {
        ProgressRootLedger(rows: rows)
            .task {
                if let model = await deps.traineeModelService.read() {
                    rows = ProgressRootLedger.rows(from: model)
                }
            }
    }
}
