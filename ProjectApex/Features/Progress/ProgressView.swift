// ProgressView.swift
// ProjectApex — Features/Progress
//
// Four-section progress tab:
//   1. Stagnation banners (amber = plateaued, red = declining)
//   2. Key Lifts Summary — horizontal scroll cards
//   3. Strength Trend Chart — Swift Charts line chart, exercise picker
//   4. Weekly Volume by Muscle Group — stacked bar chart, 8 weeks
//   5. Session Consistency Heatmap — 12-week GitHub-style grid

import SwiftUI
import Charts

struct ProgressTabView: View {

    @State private var vm: ProgressViewModel
    @Environment(AppDependencies.self) private var deps

    init(supabaseClient: SupabaseClient, userId: UUID) {
        _vm = State(initialValue: ProgressViewModel(supabaseClient: supabaseClient, userId: userId))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

                if vm.isLoading {
                    SwiftUI.ProgressView()
                        .tint(.white)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            stagnationBanners
                            keyLiftsSummarySection
                            strengthTrendSection
                            weeklyVolumeSection
                            consistencyHeatmapSection
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                await vm.loadAll()
            }
        }
    }

    // MARK: - Stagnation Banners

    @ViewBuilder
    private var stagnationBanners: some View {
        let alerts = vm.stagnationSignals.filter { $0.verdict != .progressing }
        if !alerts.isEmpty {
            VStack(spacing: 8) {
                ForEach(alerts) { signal in
                    StagnationBannerView(signal: signal)
                }
            }
        }
    }

    // MARK: - Key Lifts Summary

    private var keyLiftsSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Key Lifts")
            if vm.keyLifts.isEmpty {
                emptyDataCard("Complete workouts to see key lift progress")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(vm.keyLifts) { lift in
                            KeyLiftCard(lift: lift)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: - Strength Trend Chart

    private var strengthTrendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Strength Trend")
            let exerciseOptions = vm.trendData.keys.sorted()
            if exerciseOptions.isEmpty {
                emptyDataCard("Train at least 2 sessions per exercise to see trends")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Exercise", selection: Binding(
                        get: { vm.selectedTrendExercise ?? exerciseOptions[0] },
                        set: { vm.selectedTrendExercise = $0 }
                    )) {
                        ForEach(exerciseOptions, id: \.self) { id in
                            Text(exerciseName(for: id)).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color(red: 0.30, green: 0.96, blue: 0.60))

                    if let selectedId = vm.selectedTrendExercise ?? exerciseOptions.first,
                       let points = vm.trendData[selectedId], !points.isEmpty {
                        StrengthTrendChart(points: points)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Weekly Volume Chart

    private var weeklyVolumeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Weekly Volume")
            if vm.weeklyVolume.isEmpty || vm.weeklyVolume.allSatisfy({ $0.setsByMuscle.isEmpty }) {
                emptyDataCard("Log workouts to track weekly volume per muscle group")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    WeeklyVolumeChart(data: vm.weeklyVolume)
                        .frame(height: 200)
                    volumeLegend
                }
                .padding(16)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var volumeLegend: some View {
        let muscles = Array(
            Set(vm.weeklyVolume.flatMap { $0.setsByMuscle.keys })
        ).sorted()
        return FlowLayout(spacing: 8) {
            ForEach(muscles, id: \.self) { muscle in
                HStack(spacing: 4) {
                    Circle()
                        .fill(MuscleColor.color(for: muscle))
                        .frame(width: 8, height: 8)
                    Text(muscle.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.60))
                }
            }
        }
    }

    // MARK: - Consistency Heatmap

    private var consistencyHeatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Consistency")
            if vm.heatmapData.isEmpty {
                emptyDataCard("Log sessions to see your training consistency")
            } else {
                ConsistencyHeatmap(cells: vm.heatmapData)
                    .padding(16)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.white)
    }

    private func emptyDataCard(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.40))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func exerciseName(for id: String) -> String {
        ExerciseLibrary.lookup(id)?.name
            ?? id.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
    }
}

// MARK: - StagnationBannerView

private struct StagnationBannerView: View {
    let signal: StagnationSignal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: signal.verdict == .declining ? "arrow.down.circle.fill" : "minus.circle.fill")
                .foregroundStyle(bannerIconColor)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.exerciseName)
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

    private var bannerIconColor: Color {
        signal.verdict == .declining
            ? Color(red: 0.96, green: 0.36, blue: 0.36)
            : Color(red: 0.96, green: 0.70, blue: 0.20)
    }

    private var bannerBackground: some ShapeStyle {
        signal.verdict == .declining
            ? AnyShapeStyle(Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.12))
            : AnyShapeStyle(Color(red: 0.96, green: 0.70, blue: 0.20).opacity(0.12))
    }

    private var bannerMessage: String {
        switch signal.verdict {
        case .declining:
            return "Performance declining — consider reducing weight 10% and focusing on form."
        case .plateaued:
            return "No new PR in \(signal.sessionsWithoutProgress) sessions — try varying rep ranges or technique."
        case .progressing:
            return ""
        }
    }
}

// MARK: - KeyLiftCard

private struct KeyLiftCard: View {
    let lift: KeyLiftSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lift.name)
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(2)
                .frame(width: 110, alignment: .leading)

            Text(String(format: "%.1f kg", lift.currentE1RM))
                .font(.title3.bold())
                .foregroundStyle(.white)

            HStack(spacing: 4) {
                Image(systemName: trendIcon)
                    .foregroundStyle(trendColor)
                    .font(.caption)
                if let delta = lift.deltaVs4WeeksAgo {
                    Text(deltaLabel(delta))
                        .font(.caption)
                        .foregroundStyle(trendColor)
                }
            }
        }
        .padding(12)
        .frame(width: 134)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var trendIcon: String {
        switch lift.trend {
        case .up:   return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    private var trendColor: Color {
        switch lift.trend {
        case .up:   return Color(red: 0.30, green: 0.96, blue: 0.60)
        case .down: return Color(red: 0.96, green: 0.36, blue: 0.36)
        case .flat: return .white.opacity(0.45)
        }
    }

    private func deltaLabel(_ delta: Double) -> String {
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", delta)) kg"
    }
}

// MARK: - StrengthTrendChart

private struct StrengthTrendChart: View {
    let points: [TrendPoint]

    var body: some View {
        let allTimeBest = points.filter(\.isAllTimeBest).map(\.e1RM).max()

        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("e1RM (kg)", point.e1RM)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color(red: 0.30, green: 0.96, blue: 0.60))
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Date", point.date),
                    y: .value("e1RM (kg)", point.e1RM)
                )
                .foregroundStyle(point.isAllTimeBest
                    ? Color(red: 1.0, green: 0.84, blue: 0.0)
                    : Color(red: 0.30, green: 0.96, blue: 0.60))
                .symbolSize(point.isAllTimeBest ? 80 : 40)
            }

            if let best = allTimeBest {
                RuleMark(y: .value("All-time best", best))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.25))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("PR")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.10))
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.10))
                AxisValueLabel()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .frame(height: 180)
    }
}

// MARK: - WeeklyVolumeChart

private struct WeeklyVolumeChart: View {
    let data: [WeeklyVolumeRow]

    private var muscles: [String] {
        Array(Set(data.flatMap { $0.setsByMuscle.keys })).sorted()
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Target", 10))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.white.opacity(0.20))

            ForEach(data) { row in
                ForEach(muscles, id: \.self) { muscle in
                    let count = row.setsByMuscle[muscle] ?? 0
                    BarMark(
                        x: .value("Week", row.weekLabel),
                        y: .value("Sets", count),
                        stacking: .standard
                    )
                    .foregroundStyle(MuscleColor.color(for: muscle))
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.10))
                AxisValueLabel()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
    }
}

// MARK: - ConsistencyHeatmap

private struct ConsistencyHeatmap: View {
    let cells: [HeatmapCell]

    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    private let cellSize: CGFloat = 14
    private let cellSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: cellSpacing) {
                // Day-of-week row labels
                VStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { dayIdx in
                        Text(dayLabels[dayIdx])
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 12, height: cellSize)
                    }
                }
                // 12 week columns
                HStack(spacing: cellSpacing) {
                    ForEach(0..<12, id: \.self) { weekIdx in
                        VStack(spacing: cellSpacing) {
                            ForEach(0..<7, id: \.self) { dayIdx in
                                let cell = cells.first { $0.weekIndex == weekIdx && $0.dayOfWeek == dayIdx }
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(cellColor(for: cell))
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                legendItem(color: .white.opacity(0.05), label: "None")
                legendItem(color: Color(red: 0.20, green: 0.65, blue: 0.35), label: "Session")
                legendItem(color: Color(red: 1.0, green: 0.84, blue: 0.0), label: "PR")
            }
        }
    }

    private func cellColor(for cell: HeatmapCell?) -> Color {
        guard let cell else { return .white.opacity(0.05) }
        if cell.hasPR          { return Color(red: 1.0, green: 0.84, blue: 0.0) }
        if cell.sessionCount > 0 { return Color(red: 0.20, green: 0.65, blue: 0.35) }
        return .white.opacity(0.05)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for the muscle legend chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    ProgressTabView(
        supabaseClient: SupabaseClient(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "preview"
        ),
        userId: UUID()
    )
    .environment(AppDependencies())
    .preferredColorScheme(.dark)
}
