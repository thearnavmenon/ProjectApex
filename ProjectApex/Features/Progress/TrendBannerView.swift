// TrendBannerView.swift
// ProjectApex — Features/Progress
//
// Per-pattern trend banner. Reads PatternSummary from the
// TraineeModelDigest's per_pattern_summary[] entries; renders amber for
// .plateaued, red for .declining, and a rotation-cue variant when
// PatternProfile.consecutiveForceDeloadsOnPattern >= 2.
//
// Replaces the legacy StagnationBannerView (consumed [StagnationSignal]
// from UserDefaults). See ADR-0009 (hybrid plateau verdict) and
// ADR-0011 §(d) (consecutive force-deload surfacing).
//
// Identifiable via pattern's rawValue so ForEach in ProgressView's
// trendBanners section can key on it.

import SwiftUI

struct TrendBannerView: View {
    let summary: PatternSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayPatternName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(bannerMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
        }
        .padding(12)
        .background(bannerBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    // Format snake_case pattern rawValue as "Horizontal Push" etc.
    private var displayPatternName: String {
        summary.pattern.rawValue
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var iconName: String {
        if summary.consecutiveForceDeloadsOnPattern >= 2 {
            return "arrow.triangle.2.circlepath"
        }
        switch summary.trend {
        case .declining:   return "arrow.down.circle.fill"
        case .plateaued:   return "minus.circle.fill"
        case .progressing: return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        if summary.trend == .declining {
            return Color(red: 0.96, green: 0.36, blue: 0.36)
        }
        // Plateaued OR force-deload cue → amber.
        return Color(red: 0.96, green: 0.70, blue: 0.20)
    }

    private var bannerBackground: some ShapeStyle {
        let amber = AnyShapeStyle(Color(red: 0.96, green: 0.70, blue: 0.20).opacity(0.12))
        if summary.trend == .declining {
            return AnyShapeStyle(Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.12))
        }
        return amber
    }

    private var bannerMessage: String {
        // Force-deload counter takes precedence — surfaces rotation/rebuild cue.
        if summary.consecutiveForceDeloadsOnPattern >= 2 {
            return "Programming on this pattern has calcified — consider exercise rotation or programme rebuild."
        }
        switch summary.trend {
        case .declining:
            return "Trend declining — consider reducing weight ~10% and focusing on form."
        case .plateaued:
            return "Plateau detected — try varying rep ranges, swapping variations, or adding intensity techniques."
        case .progressing:
            return ""
        }
    }
}
