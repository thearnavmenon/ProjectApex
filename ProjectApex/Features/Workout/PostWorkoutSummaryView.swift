// Features/Workout/PostWorkoutSummaryView.swift
// ProjectApex — P3-T08
//
// Full-screen post-workout summary displayed after .sessionComplete.
//
// Acceptance criteria:
//   ✓ Total volume (kg) — large hero number
//   ✓ Sets completed vs planned — progress ring or fraction
//   ✓ Session duration
//   ✓ Personal records section (when present)
//   ✓ AI adjustments count
//   ✓ Voice notes list (scrollable if many)
//   ✓ Share button — copies summary text to clipboard
//   ✓ Done button — resets session to .idle
//   ✓ "Partial Session" label when ended early (P3-T09)
//
// DEPENDS ON: P3-T02 (WorkoutViewModel), P3-T01 (WorkoutSessionManager)

import SwiftUI
import UIKit

// MARK: - PostWorkoutSummaryView

struct PostWorkoutSummaryView: View {

    let summary: SessionSummary
    let streak: StreakResult
    let onDone: () -> Void

    @State private var showCopiedBanner: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            apexBackground

            ScrollView {
                VStack(spacing: 0) {

                    // Partial session badge (P3-T09)
                    if summary.earlyExitReason != nil {
                        partialSessionBadge
                            .padding(.top, 20)
                    }

                    // Trophy header
                    headerSection
                        .padding(.top, summary.earlyExitReason != nil ? 12 : 40)

                    // Hero stats row
                    heroStatsRow
                        .padding(.top, 28)
                        .padding(.horizontal, 24)

                    // Sets progress ring
                    setsProgressSection
                        .padding(.top, 28)

                    // Personal records
                    if !summary.personalRecords.isEmpty {
                        personalRecordsSection
                            .padding(.top, 28)
                            .padding(.horizontal, 24)
                    }

                    // AI adjustments
                    if summary.aiAdjustmentCount > 0 {
                        aiAdjustmentsSection
                            .padding(.top, 24)
                            .padding(.horizontal, 24)
                    }

                    // Voice notes
                    if !summary.notableNotes.isEmpty {
                        voiceNotesSection
                            .padding(.top, 24)
                            .padding(.horizontal, 24)
                    }

                    // Action buttons
                    actionButtons
                        .padding(.top, 36)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 48)
                }
            }

            // "Copied" banner overlay
            if showCopiedBanner {
                VStack {
                    copiedBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Partial Session Badge

    private var partialSessionBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0))
            Text("Partial Session")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0))
                .tracking(0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: summary.earlyExitReason != nil ? "flag.checkered" : "trophy.fill")
                .font(.system(size: 56))
                .foregroundStyle(streak.tintColor)
            Text(summary.earlyExitReason != nil ? "Session Ended" : "Session Complete")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            if summary.durationSeconds > 0 {
                Text(formattedDuration)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: - Hero Stats Row

    private var heroStatsRow: some View {
        HStack(spacing: 0) {
            // Total volume
            statCard(
                value: formattedVolume,
                unit: "kg",
                label: "Total Volume",
                icon: "scalemass.fill"
            )

            Spacer()

            // Sets
            statCard(
                value: "\(summary.setsCompleted)",
                unit: "/ \(summary.setsPlanned)",
                label: "Sets",
                icon: "checkmark.circle.fill"
            )

            Spacer()

            // AI adjustments
            statCard(
                value: "\(summary.aiAdjustmentCount)",
                unit: "",
                label: "AI Coached",
                icon: "brain.head.profile"
            )
        }
    }

    private func statCard(value: String, unit: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(streak.tintColor.opacity(0.70))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.3)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sets Progress Section

    private var setsProgressSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.08), lineWidth: 6)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: setsProgress)
                    .stroke(streak.tintColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(completionPercent)%")
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("complete")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }
        }
    }

    // MARK: - Personal Records

    private var personalRecordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.0))
                Text("Personal Records")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
            }

            ForEach(summary.personalRecords, id: \.exerciseId) { pr in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.exerciseName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.80))
                        Text(prMetricLabel(pr.metric))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f", pr.newBest))
                            .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.0))
                        Text(String(format: "%.1f → %.1f", pr.previousBest, pr.newBest))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - AI Adjustments

    private var aiAdjustmentsSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(streak.tintColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.aiAdjustmentCount) AI-coached sets")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                Text("Real-time prescriptions adapted to your performance")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.38))
            }
            Spacer()
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Voice Notes

    private var voiceNotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Session Notes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
            }

            ForEach(Array(summary.notableNotes.enumerated()), id: \.offset) { index, note in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 18)
                    Text(note)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(3)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 14) {
            // Share button
            Button {
                copyToClipboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 15, weight: .medium))
                    Text("Copy Summary")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.80))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
            }

            // Done button
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDone()
            } label: {
                Text("Done")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(streak.tintColor.opacity(0.88), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
            }
        }
    }

    // MARK: - Copied Banner

    private var copiedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text("Summary copied to clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
    }

    // MARK: - Background

    private var apexBackground: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
            RadialGradient(
                colors: [streak.tintColor.opacity(0.15), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.10),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
        }
    }

    // MARK: - Helpers

    private var formattedVolume: String {
        if summary.totalVolumeKg >= 1000 {
            return String(format: "%.1fk", summary.totalVolumeKg / 1000)
        }
        return String(format: "%.0f", summary.totalVolumeKg)
    }

    private var formattedDuration: String {
        let hours = summary.durationSeconds / 3600
        let minutes = (summary.durationSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }

    private var setsProgress: CGFloat {
        guard summary.setsPlanned > 0 else { return 1.0 }
        return CGFloat(summary.setsCompleted) / CGFloat(summary.setsPlanned)
    }

    private var completionPercent: Int {
        guard summary.setsPlanned > 0 else { return 100 }
        return Int(round(Double(summary.setsCompleted) / Double(summary.setsPlanned) * 100))
    }

    private func prMetricLabel(_ metric: PRMetric) -> String {
        switch metric {
        case .estimatedOneRM: return "Estimated 1RM"
        case .topSetWeight:   return "Top Set Weight"
        case .totalVolume:    return "Total Volume"
        }
    }

    private func copyToClipboard() {
        var text = summary.earlyExitReason != nil
            ? "Workout Summary (Partial)\n"
            : "Workout Summary\n"
        text += "──────────────────\n"
        text += "Volume: \(String(format: "%.0f", summary.totalVolumeKg)) kg\n"
        text += "Sets: \(summary.setsCompleted) / \(summary.setsPlanned)\n"
        text += "Duration: \(formattedDuration)\n"
        text += "AI-Coached Sets: \(summary.aiAdjustmentCount)\n"

        if !summary.personalRecords.isEmpty {
            text += "\nPersonal Records:\n"
            for pr in summary.personalRecords {
                text += "  • \(pr.exerciseName): \(String(format: "%.1f", pr.previousBest)) → \(String(format: "%.1f", pr.newBest))\n"
            }
        }

        if !summary.notableNotes.isEmpty {
            text += "\nNotes:\n"
            for note in summary.notableNotes {
                text += "  • \(note)\n"
            }
        }

        text += "\n— Project Apex"

        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            showCopiedBanner = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                showCopiedBanner = false
            }
        }
    }
}

// MARK: - Previews

#Preview("Full Session Complete") {
    PostWorkoutSummaryView(
        summary: SessionSummary(
            totalVolumeKg: 4520,
            setsCompleted: 18,
            setsPlanned: 20,
            personalRecords: [
                PersonalRecord(
                    exerciseId: "barbell_bench_press",
                    exerciseName: "Barbell Bench Press",
                    previousBest: 95.0,
                    newBest: 100.0,
                    metric: .topSetWeight
                )
            ],
            aiAdjustmentCount: 14,
            notableNotes: ["Left shoulder felt tight on last set", "Energy was good today"],
            earlyExitReason: nil,
            durationSeconds: 3720
        ),
        streak: StreakResult.compute(currentStreakDays: 7, longestStreak: 10),
        onDone: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Partial Session") {
    PostWorkoutSummaryView(
        summary: SessionSummary(
            totalVolumeKg: 1850,
            setsCompleted: 8,
            setsPlanned: 20,
            personalRecords: [],
            aiAdjustmentCount: 6,
            notableNotes: [],
            earlyExitReason: "User ended session early",
            durationSeconds: 1440
        ),
        streak: StreakResult.neutral,
        onDone: {}
    )
    .preferredColorScheme(.dark)
}
