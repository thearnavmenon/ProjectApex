// TokenGallery.swift
// ProjectApex — DesignSystem
//
// Dev-only gallery: renders the full palette, type scale, and data-viz tokens so
// the foundation is visually verifiable in light and dim (DESIGN.md). Not shipped
// — gated behind `#if DEBUG`. Reachable in-app from Developer Settings, and via
// the two #Previews below.

#if DEBUG
import SwiftUI

struct TokenGallery: View {
    var theme: Theme = .light

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                colorsSection
                typeSection
                dataVizSection
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.paper.color.ignoresSafeArea())
        .environment(\.apexTheme, theme)
    }

    private var header: some View {
        InkPencil.run(ink: "Apex tokens", pencil: "  \(theme.appearance.rawValue)", theme: theme)
            .apexFont(.display)
    }

    // MARK: Colours

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionTitle("Colour")
            swatch("paper", theme.paper.color)
            swatch("surface", theme.surface.color)
            swatch("well", theme.well.color)
            swatch("hairline", theme.hairline.color)
            swatch("ink", theme.ink.color)
            swatch("ink-muted", theme.inkMuted.color)
            swatch("accent-ink", theme.accentInk.color)
            fillSwatch("accent (fill)", theme.accentFill)
            fillSwatch("accent-press", theme.accentPress)
            fillSwatch("alert-fill", theme.alertFill)
            swatch("alert", theme.alert.color)
            // on-accent shown on an accent field.
            HStack(spacing: Spacing.md) {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(theme.accentFill)
                    .frame(width: 56, height: 36)
                    .overlay(Text("Aa").foregroundStyle(theme.onAccent.color))
                Text("on-accent").apexFont(.body).foregroundStyle(theme.ink.color)
                Spacer()
            }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        HStack(spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(color)
                .frame(width: 56, height: 36)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(theme.hairline.color, lineWidth: 1))
            Text(name).apexFont(.body).foregroundStyle(theme.ink.color)
            Spacer()
        }
    }

    private func fillSwatch(_ name: String, _ fill: FillToken) -> some View {
        HStack(spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(fill)
                .frame(width: 56, height: 36)
            Text(name).apexFont(.body).foregroundStyle(theme.ink.color)
            Spacer()
        }
    }

    // MARK: Type

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Type")
            Text("100").apexFont(.heroNum).foregroundStyle(theme.ink.color)
            Text("The coach's read").apexFont(.display).foregroundStyle(theme.ink.color)
            Text("Horizontal Press").apexFont(.title).foregroundStyle(theme.ink.color)
            Text("You moved 12% more weight than last week — same effort.")
                .apexFont(.body).foregroundStyle(theme.ink.color)
            Text("LAST TIME").apexFont(.label).foregroundStyle(theme.inkMuted.color)
            // work-is-ink / time-is-pencil + plan-is-pencil
            InkPencil.actualVersusPlan(actual: "100 kg × 6", plan: "5", theme: theme)
                .apexFont(.title)
        }
    }

    // MARK: Data-viz

    private var dataVizSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Data-viz")
            Canvas { ctx, size in
                let midY = size.height / 2
                // capability band fill + hairline edges
                let band = CGRect(x: 0, y: midY - 24, width: size.width, height: 48)
                ctx.fill(Path(band), with: .color(theme.bandFill.color))
                ctx.stroke(Path(CGRect(x: 0, y: band.minY, width: size.width, height: 0)),
                           with: .color(theme.bandEdge.color), lineWidth: DesignGeometry.stretchTick)
                ctx.stroke(Path(CGRect(x: 0, y: band.maxY, width: size.width, height: 0)),
                           with: .color(theme.bandEdge.color), lineWidth: DesignGeometry.floorTick)
                // series-primary line
                var line = Path()
                line.move(to: CGPoint(x: 0, y: midY + 12))
                line.addLine(to: CGPoint(x: size.width * 0.6, y: midY - 8))
                ctx.stroke(line, with: .color(theme.seriesPrimary.color), lineWidth: DesignGeometry.seriesLineWidth)
                // projection (dashed) continuation
                var proj = Path()
                proj.move(to: CGPoint(x: size.width * 0.6, y: midY - 8))
                proj.addLine(to: CGPoint(x: size.width, y: midY - 18))
                ctx.stroke(proj, with: .color(theme.seriesPrimary.color),
                           style: StrokeStyle(lineWidth: DesignGeometry.seriesLineWidth, dash: DesignGeometry.projectionDash))
                // measured dot (solid) + estimated dot (hollow)
                let r = DesignGeometry.listScaleDot
                let measured = CGRect(x: size.width * 0.3 - r, y: midY - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: measured), with: .color(theme.pointMeasured.color))
                let estimated = CGRect(x: size.width * 0.85 - r, y: midY - 14 - r, width: r * 2, height: r * 2)
                ctx.stroke(Path(ellipseIn: estimated), with: .color(theme.pointEstimatedStroke.color), lineWidth: 1.5)
            }
            .frame(height: 80)
            .overlay(alignment: .bottomLeading) {
                Text("band · series · projection · measured/estimated")
                    .apexFont(.label).foregroundStyle(theme.axis.color)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).apexFont(.title).foregroundStyle(theme.inkMuted.color)
    }
}

#Preview("Tokens — Light") {
    TokenGallery(theme: .light)
}

#Preview("Tokens — Dim") {
    TokenGallery(theme: .dim)
}
#endif
