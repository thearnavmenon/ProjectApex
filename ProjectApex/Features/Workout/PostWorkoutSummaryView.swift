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

    // `internal` (not `private`) so PostWorkoutSummaryInsightsTests can exercise
    // the fail-loud helper via `@testable import` (#242).
    enum InsightsState {
        case loading
        case loaded([String])
        case failed([String]) // fallback deterministic insights
    }

    @State private var insightsState: InsightsState = .loading

    /// The fail-loud notice shown when AI insights couldn't be generated (#242, ADR-0007 §3).
    /// `nil` when the AI succeeded (or is still loading) — non-nil only for `.failed`.
    /// Single source of truth for the badge copy; the `.failed` render branch reads from here.
    static func insightsFallbackNotice(for state: InsightsState) -> String? {
        switch state {
        case .loading, .loaded:
            return nil
        case .failed:
            return "Couldn't generate AI insights — showing a basic summary."
        }
    }

    // MARK: - Late-Arrival Notifications (Slice A3 / ADR-0008)

    /// Pending late-arrival notifications dequeued from
    /// `AppDependencies.lateArrivalNotificationQueue` on appearance.
    /// Renders a soft banner above the trophy header; dismiss-on-tap.
    /// Preview-friendly: previews can seed this directly to verify the
    /// banner stack without booting the WAQ.
    @State var lateArrivalNotices: [LateArrivalNotification] = []

    // MARK: - Body

    var body: some View {
        ZStack {
            apexBackground

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    // Partial session badge (P3-T09)
                    if summary.earlyExitReason != nil {
                        partialSessionBadge
                    }

                    // Late-arrival notifications (Slice A3 / ADR-0008)
                    if !lateArrivalNotices.isEmpty {
                        lateArrivalNoticesSection
                    }

                    // Header
                    headerSection

                    // Hero volume numeral
                    heroSection

                    // 3-up muted stat row
                    heroStatsRow

                    // Personal records — gold-gated badges
                    if !summary.personalRecords.isEmpty {
                        personalRecordsSection
                    }

                    // AI adjustments
                    if summary.aiAdjustmentCount > 0 {
                        aiAdjustmentsSection
                    }

                    // Exercise swaps (P3-T10)
                    if let swaps = summary.swappedExercises, !swaps.isEmpty {
                        exerciseSwapsSection(swaps)
                    }

                    // Voice notes
                    if !summary.notableNotes.isEmpty {
                        voiceNotesSection
                    }

                    // AI Insights — coach recap card
                    insightsSection

                    // Action buttons
                    actionButtons

                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, Apex.pad)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            // Dequeue any late-arrival notifications enqueued by
            // TraineeModelUpdateJob since this surface was last shown
            // (per ADR-0008). Dequeue is atomic — second appearance
            // shows nothing unless a fresh refusal happened in between.
            lateArrivalNotices = deps.lateArrivalNotificationQueue.dequeueAll()
            await loadInsights()
        }
    }

    // MARK: - Late-Arrival Notices

    private var lateArrivalNoticesSection: some View {
        VStack(spacing: 8) {
            ForEach(lateArrivalNotices) { notice in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.2)) {
                        lateArrivalNotices.removeAll { $0.id == notice.id }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Apex.amber)
                            .padding(.top, 1)
                        Text(notice.message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Apex.text.opacity(0.80))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Apex.textFaint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Apex.amber.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .stroke(Apex.amber.opacity(0.40), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Partial Session Badge

    private var partialSessionBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Apex.amber)
            Text("Partial Session")
                .font(.system(size: 12, weight: .bold))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .tracking(1.1)
                .foregroundStyle(Apex.amber)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Apex.amber.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.amber.opacity(0.40), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ApexSectionLabel(
                text: summary.earlyExitReason != nil ? "Session ended" : "Workout complete",
                color: Apex.accent
            )
            Text(summary.earlyExitReason != nil ? "Session Ended" : "Session Complete")
                .font(.system(size: 26, weight: .bold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hero Volume

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ApexNumeral(text: formattedVolume, size: 76)
                Text("kg")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Apex.textDim)
            }
            Text("Total volume moved")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Apex.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hero Stats Row

    private var heroStatsRow: some View {
        HStack(spacing: 10) {
            statCard(
                label: "Sets",
                value: "\(summary.setsCompleted)",
                sub: "of \(summary.setsPlanned)"
            )
            statCard(
                label: "Time",
                value: summary.durationSeconds > 0 ? formattedDuration : "—",
                sub: "active"
            )
            statCard(
                label: "AI Coached",
                value: "\(summary.aiAdjustmentCount)",
                sub: "sets"
            )
        }
    }

    private func statCard(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ApexSectionLabel(text: label, color: Apex.textFaint)
            ApexNumeral(text: value, size: 28, weight: .bold)
            Text(sub)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Apex.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 15)
        .padding(.horizontal, 15)
        .apexCard()
    }

    // MARK: - Personal Records (gold-gated badges)

    private var personalRecordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApexSectionLabel(text: "Personal records", color: Apex.gold)

            ForEach(summary.personalRecords, id: \.exerciseId) { pr in
                HStack(spacing: 13) {
                    ZStack {
                        Image(systemName: "hexagon.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Apex.gold.opacity(0.18))
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Apex.gold)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pr.exerciseName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Apex.text)
                        Text(prMetricLabel(pr.metric))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Apex.textFaint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ApexNumeral(
                            text: String(format: "%.1f", pr.newBest),
                            size: 18,
                            weight: .bold,
                            color: Apex.gold
                        )
                        Text(String(format: "%.1f → %.1f", pr.previousBest, pr.newBest))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Apex.textFaint)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Exercise Swaps (P3-T10)

    private func exerciseSwapsSection(_ swaps: [SwapRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ApexSectionLabel(text: "Exercise swaps")

            ForEach(swaps, id: \.newExerciseId) { swap in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(swap.originalExerciseName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Apex.textDim)
                            .strikethrough(true, color: Apex.textFaint)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Apex.accent)
                        Text(swap.newExerciseName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Apex.text)
                    }
                    if !swap.reason.isEmpty {
                        Text(swap.reason)
                            .font(.system(size: 11, weight: .medium).italic())
                            .foregroundStyle(Apex.textFaint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - AI Adjustments

    private var aiAdjustmentsSection: some View {
        HStack(spacing: 13) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Apex.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.aiAdjustmentCount) AI-coached sets")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Apex.text)
                Text("Real-time prescriptions adapted to your performance")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Apex.textFaint)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - Voice Notes

    private var voiceNotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ApexSectionLabel(text: "Session notes")

            ForEach(Array(summary.notableNotes.enumerated()), id: \.offset) { index, note in
                HStack(alignment: .top, spacing: 10) {
                    ApexNumeral(text: "\(index + 1)", size: 13, weight: .bold, color: Apex.textFaint)
                        .frame(width: 18, alignment: .leading)
                    Text(note)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Apex.textDim)
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    // MARK: - AI Insights

    private var insightsSection: some View {
        // Coach recap — accent left-rail, matching the prototype's coach
        // treatment. Content varies by insights state; the rail + "Coach"
        // header are constant.
        HStack(alignment: .top, spacing: 13) {
            Capsule()
                .fill(Apex.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Apex.accent)
                    ApexSectionLabel(text: "Coach", color: Apex.accent)
                }

                switch insightsState {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Apex.accent)
                            .scaleEffect(0.8)
                        Text("Analysing your session…")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Apex.textDim)
                    }

                case .loaded(let insights):
                    // AI succeeded — bullet list only, no notice.
                    insightsList(insights, notice: nil)

                case .failed(let insights):
                    // Fail loud (#242, ADR-0007 §3): still show the deterministic
                    // fallback insights, but surface that the AI didn't run.
                    insightsList(insights, notice: Self.insightsFallbackNotice(for: insightsState))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexCard()
    }

    /// Insights bullet list. When `notice` is non-nil (the `.failed` fail-loud
    /// path), a small warning row is prepended above the list (#242).
    @ViewBuilder
    private func insightsList(_ insights: [String], notice: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Apex.amber)
                    Text(notice)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Apex.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 2)
            }
            ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Apex.accent)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(insight)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Apex.text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        HStack(spacing: 12) {
            // Share button (ghost) — copies the summary text to the clipboard.
            Button {
                copyToClipboard()
            } label: {
                ApexButton(title: "Share", kind: .ghost, icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share")
            .accessibilityHint("Copies the workout summary to the clipboard")

            // Done button (filled lime) — resets the session.
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDone()
            } label: {
                ApexButton(title: "Done")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
        .padding(.top, 6)
    }

    // MARK: - Copied Banner

    private var copiedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Apex.accent)
            Text("Summary copied to clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Apex.text.opacity(0.80))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Apex.surface,
                    in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.hairline, lineWidth: 1)
        )
    }

    // MARK: - Background

    private var apexBackground: some View {
        Apex.bg.ignoresSafeArea()
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

#Preview("Late-Arrival Notice") {
    // Slice A3 / ADR-0008: fixture exercises the soft notification banner
    // without needing the WAQ flush path. Use this preview at PR-review
    // time to eyeball the banner's copy + spacing before merge.
    var view = PostWorkoutSummaryView(
        summary: SessionSummary(
            totalVolumeKg: 4520,
            setsCompleted: 18,
            setsPlanned: 20,
            personalRecords: [],
            aiAdjustmentCount: 14,
            notableNotes: [],
            earlyExitReason: nil,
            durationSeconds: 3720
        ),
        streak: StreakResult.compute(currentStreakDays: 7, longestStreak: 10),
        onDone: {}
    )
    view.lateArrivalNotices = [
        LateArrivalNotification(
            id: UUID(),
            message: LateArrivalNotification.lockedMessage,
            receiptDate: Date(),
            sessionId: nil,
            incomingLoggedAt: nil,
            watermark: nil
        )
    ]
    return view
        .environment(AppDependencies())
        .preferredColorScheme(.dark)
}
