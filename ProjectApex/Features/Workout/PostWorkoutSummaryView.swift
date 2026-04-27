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
    /// Raw set logs from the completed session — used to generate AI insights.
    var completedSets: [SetLog] = []

    @Environment(AppDependencies.self) private var deps

    @State private var showCopiedBanner: Bool = false

    // MARK: - AI Insights State

    enum InsightsState {
        case loading
        case loaded([String])
        case failed([String]) // fallback deterministic insights
    }

    @State private var insightsState: InsightsState = .loading

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

                    // Exercise swaps (P3-T10)
                    if let swaps = summary.swappedExercises, !swaps.isEmpty {
                        exerciseSwapsSection(swaps)
                            .padding(.top, 24)
                            .padding(.horizontal, 24)
                    }

                    // Voice notes
                    if !summary.notableNotes.isEmpty {
                        voiceNotesSection
                            .padding(.top, 24)
                            .padding(.horizontal, 24)
                    }

                    // AI Insights
                    insightsSection
                        .padding(.top, 28)
                        .padding(.horizontal, 24)

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
        .task {
            await loadInsights()
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

    // MARK: - Exercise Swaps (P3-T10)

    private func exerciseSwapsSection(_ swaps: [SwapRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 1.00, green: 0.60, blue: 0.20))
                Text("Exercise Swaps")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
            }

            ForEach(swaps, id: \.newExerciseId) { swap in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(swap.originalExerciseName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .strikethrough(true, color: .white.opacity(0.30))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 1.00, green: 0.60, blue: 0.20))
                        Text(swap.newExerciseName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if !swap.reason.isEmpty {
                        Text(swap.reason)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                            .italic()
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - AI Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(streak.tintColor)
                Text("Session Insights")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
            }

            switch insightsState {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(streak.tintColor)
                        .scaleEffect(0.8)
                    Text("Analysing your session…")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            case .loaded(let insights), .failed(let insights):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(streak.tintColor)
                                .frame(width: 5, height: 5)
                                .padding(.top, 6)
                            Text(insight)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Insights Loading

    private func loadInsights() async {
        // Build context payload from completedSets and summary
        let setsByExercise = Dictionary(grouping: completedSets, by: \.exerciseId)
        var exerciseSummaries: [String] = []
        for (exerciseId, sets) in setsByExercise {
            let displayName = sets.first.map { _ in
                ExerciseLibrary.lookup(exerciseId)?.name ?? exerciseId
                    .split(separator: "_")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            } ?? exerciseId
            let setDescriptions = sets.map { s in
                "\(s.setNumber): \(String(format: "%.1f", s.weightKg))kg × \(s.repsCompleted) reps" +
                (s.rpeFelt.map { " RPE \($0)" } ?? "")
            }
            exerciseSummaries.append("\(displayName): \(setDescriptions.joined(separator: ", "))")
        }

        var prDescriptions: [String] = []
        for pr in summary.personalRecords {
            prDescriptions.append("\(pr.exerciseName): \(String(format: "%.1f", pr.previousBest))kg → \(String(format: "%.1f", pr.newBest))kg (\(prMetricLabel(pr.metric)))")
        }

        let userPayload = """
        Today's session:
        \(exerciseSummaries.joined(separator: "\n"))

        Total volume: \(String(format: "%.0f", summary.totalVolumeKg))kg
        Sets completed: \(summary.setsCompleted)/\(summary.setsPlanned)
        Duration: \(summary.durationSeconds / 60) minutes
        \(prDescriptions.isEmpty ? "" : "\nPersonal records:\n" + prDescriptions.joined(separator: "\n"))
        """

        let systemPrompt = """
        You are summarising a strength training session. Given today's performance and historical comparison data, generate 3–4 concise insights that are genuinely useful to the athlete. Each insight should be specific and data-driven — never generic. Good examples:
        — 'Bench Press up 5kg from last Push A — strongest set this mesocycle'
        — 'Total session volume: 4,200kg — 12% above your Push A average'
        — 'Barbell Row stalled at 22.5kg for 3 sessions — your coach will adjust intensity next time'
        — 'New estimated 1RM on Overhead Press: 32kg — up from 28kg last month'
        Avoid: 'Great session!', 'Keep it up!', 'You worked hard today.' — these are not insights. Every insight must reference a specific number.
        Return a JSON array of strings only. No preamble, no markdown.
        """

        // Get the Anthropic key and make a Haiku call
        guard let apiKey = try? deps.keychainService.retrieve(.anthropicAPIKey), !apiKey.isEmpty else {
            withAnimation { insightsState = .failed(deterministicInsights()) }
            return
        }

        let haikuProvider = AnthropicProvider(
            apiKey: apiKey,
            model: "claude-haiku-4-5",
            maxTokens: 512,
            requestTimeout: 15
        )

        do {
            let raw = try await haikuProvider.complete(systemPrompt: systemPrompt, userPayload: userPayload)
            // Strip markdown fences if present
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = cleaned.data(using: .utf8),
               let insights = try? JSONDecoder().decode([String].self, from: data),
               !insights.isEmpty {
                withAnimation { insightsState = .loaded(insights) }
            } else {
                withAnimation { insightsState = .failed(deterministicInsights()) }
            }
        } catch {
            withAnimation { insightsState = .failed(deterministicInsights()) }
        }
    }

    /// Fallback insights computed client-side when the AI call fails.
    private func deterministicInsights() -> [String] {
        var insights: [String] = []

        // Volume summary
        let volumeStr = String(format: "%.0f", summary.totalVolumeKg)
        insights.append("Total session volume: \(volumeStr)kg across \(summary.setsCompleted) sets.")

        // PR insight
        if let pr = summary.personalRecords.first {
            insights.append("\(pr.exerciseName): new \(prMetricLabel(pr.metric).lowercased()) of \(String(format: "%.1f", pr.newBest))kg (up from \(String(format: "%.1f", pr.previousBest))kg).")
        }

        return insights
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

        if let swaps = summary.swappedExercises, !swaps.isEmpty {
            text += "\nExercise Swaps:\n"
            for swap in swaps {
                text += "  • \(swap.originalExerciseName) → \(swap.newExerciseName) (\(swap.reason))\n"
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
    .environment(AppDependencies())
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
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}
