// ProgressView.swift
// ProjectApex — Features/Progress
//
// Redesigned Progress tab — a premium dark "strength instrument".
// Direction decided by an independent multi-agent design panel (lens A,
// double axis-winner on craft + hierarchy), synthesised with grafts from the
// other lenses. Presentation-only: ProgressViewModel is untouched; every value
// shown is derived from its existing published arrays.
//
// Layout, top → bottom:
//   0. Title + (optional) error line
//   1. Hero + trend card — count-up e1RM, signed 4-wk delta, range pills,
//      gradient area trend chart with gold PR markers + pulsing live dot,
//      tappable exercise chip-rail
//   2. Key-lift 2×2 grid — muscle-dot, e1RM, sparkline, delta; taps drive the hero
//   3. Volume — progressive disclosure (total + sparkline → stacked bars + legend)
//   4. Consistency — streak caption + 12-week heatmap
//   5. Coaching signals — calm per-pattern rows
//
// Motion: hero count-up (honestly gated on a real positive delta), staggered
// section entrance, chart left-to-right draw-in, pulsing live dot, pulsing
// streak flame, spring volume disclosure, heatmap cell pop-in, press feedback,
// and earned haptics.

import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif

private typealias DT = ProgressDesignTokens

// MARK: - Authoritative-number presentation helper [Tier-1 #1]

private extension KeyLiftSummary {
    /// The number the coach reasons from — the server EWMA top-set e1RM —
    /// falling back to the client-side computed best when the digest lacks
    /// this exercise.
    var displayE1RM: Double { authoritativeE1RM ?? currentE1RM }
}

// MARK: - Entry point (init signature preserved for ContentView)

struct ProgressTabView: View {

    @State private var vm: ProgressViewModel

    init(
        supabaseClient: SupabaseClient,
        userId: UUID,
        traineeModelService: TraineeModelService? = nil
    ) {
        _vm = State(initialValue: ProgressViewModel(
            supabaseClient: supabaseClient,
            userId: userId,
            traineeModelService: traineeModelService
        ))
    }

    var body: some View {
        NavigationStack {
            ProgressScreenContent(vm: vm)
                .toolbar(.hidden, for: .navigationBar)
                .task { await vm.loadAll() }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Screen content

struct ProgressScreenContent: View {

    @Bindable var vm: ProgressViewModel

    @State private var range: TrendRange = .eightWeeks
    @State private var shownE1RM: Double = 0
    @State private var deltaShown = false
    @State private var volumeExpanded = false
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.sectionGap) {
                titleHeader
                    .modifier(SectionEntrance(index: 0, appeared: appeared))

                if vm.isLoading {
                    HeroSkeleton()
                        .modifier(SectionEntrance(index: 1, appeared: appeared))
                } else if let lift = focus {
                    heroCard(lift)
                        .modifier(SectionEntrance(index: 1, appeared: appeared))
                    keyLiftGrid
                        .modifier(SectionEntrance(index: 2, appeared: appeared))
                    if hasVolume {
                        volumeCard
                            .modifier(SectionEntrance(index: 3, appeared: appeared))
                    }
                    if !vm.heatmapData.isEmpty {
                        consistencyCard
                            .modifier(SectionEntrance(index: 4, appeared: appeared))
                    }
                    if !vm.patternTrends.isEmpty {
                        patternCard
                            .modifier(SectionEntrance(index: 5, appeared: appeared))
                    }
                } else {
                    emptyState
                        .modifier(SectionEntrance(index: 1, appeared: appeared))
                }
            }
            .padding(.horizontal, DT.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 44)
        }
        .scrollIndicators(.hidden)
        .background(DT.bg.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.35), value: vm.isLoading)
        .onAppear {
            // Flip on the next runloop so the false→true change animates the entrance.
            DispatchQueue.main.async { appeared = true }
            if let lift = focus { animateHero(lift) }
        }
        .onChange(of: focus?.exerciseId) { _, _ in
            if let lift = focus { animateHero(lift) }
        }
    }

    // MARK: Title

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Progress")
                .font(DT.screenTitle)
                .foregroundStyle(.white)
            if let err = vm.errorMessage {
                Text(err)
                    .font(DT.caption)
                    .foregroundStyle(DT.down)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 1 — Hero + trend card

    private func heroCard(_ lift: KeyLiftSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(lift.name.uppercased())
                        .font(DT.caption)
                        .tracking(0.6)
                        .foregroundStyle(DT.neutral)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        CountingNumber(value: shownE1RM)
                            .font(DT.hero)
                            .foregroundStyle(.white)
                        Text("kg")
                            .font(DT.heroUnit)
                            .foregroundStyle(DT.neutral)
                        // The authoritative headline is a smoothed average of recent
                        // top sets, so it can sit a touch below the latest chart dot.
                        // Flag it as smoothed — only when we're actually showing the
                        // EWMA (not the client-best fallback). [Tier-1 review]
                        if lift.authoritativeE1RM != nil {
                            Text("· smoothed")
                                .font(DT.caption)
                                .foregroundStyle(DT.neutral)
                        }
                    }

                    deltaOrHolding(lift)
                        .opacity(deltaShown ? 1 : 0)
                        .offset(y: deltaShown ? 0 : 8)

                    confidenceChip(lift)
                }
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()
                rangePills
            }

            StrengthTrendChart(points: windowedPoints(lift))
                .id(lift.exerciseId + range.rawValue)   // re-create → re-run draw-in on focus/range change
                .frame(height: 190)

            chipRail
        }
        .padding(DT.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DT.surface1, in: RoundedRectangle(cornerRadius: DT.cardRadius))
    }

    @ViewBuilder
    private func deltaOrHolding(_ lift: KeyLiftSummary) -> some View {
        if let d = lift.deltaVs4WeeksAgo, abs(d) >= 0.05 {
            let positive = d > 0
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: positive ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                    Text("\(positive ? "+" : "")\(fmt(d)) kg")
                        .font(DT.caption)
                }
                .foregroundStyle(positive ? DT.up : DT.down)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((positive ? DT.up : DT.down).opacity(0.14), in: Capsule())

                Text("vs 4 wks")
                    .font(DT.caption)
                    .foregroundStyle(DT.neutral)
            }
        } else {
            Text("Holding at \(fmt(lift.displayE1RM)) kg")
                .font(DT.caption)
                .foregroundStyle(DT.neutral)
        }
    }

    /// Calm credibility note tied to the focused lift's confidence axis.
    /// Hidden entirely when the digest has no summary for this exercise
    /// (brand-new user / empty digest) — honesty-when-empty. [Tier-1 #2]
    @ViewBuilder
    private func confidenceChip(_ lift: KeyLiftSummary) -> some View {
        if let summary = vm.exerciseSummaries[lift.exerciseId] {
            Text(confidenceChipText(summary))
                .font(DT.caption)
                .foregroundStyle(DT.neutral)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DT.surface2, in: Capsule())
        }
    }

    private func confidenceChipText(_ summary: ExerciseSummary) -> String {
        if summary.learningPhase {
            return "Still learning this lift — the number will firm up"
        }
        let sessions = summary.sessionCount == 1 ? "1 session" : "\(summary.sessionCount) sessions"
        return "\(confidenceLabel(summary.confidence)) · \(sessions)"
    }

    private func confidenceLabel(_ confidence: AxisConfidence) -> String {
        switch confidence {
        case .bootstrapping: "New"
        case .calibrating:   "Calibrating"
        case .established:   "Established"
        case .seasoned:      "Seasoned"
        }
    }

    private var rangePills: some View {
        HStack(spacing: 6) {
            ForEach(TrendRange.allCases) { r in
                Button {
                    withAnimation(.snappy) { range = r }
                } label: {
                    Text(r.rawValue)
                        .font(DT.caption)
                        .foregroundStyle(range == r ? DT.bg : DT.neutral)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(range == r ? DT.accent : DT.surface2, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private var chipRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.keyLifts) { lift in
                    let selected = focus?.exerciseId == lift.exerciseId
                    Button {
                        withAnimation(.snappy) { vm.selectedTrendExercise = lift.exerciseId }
                    } label: {
                        Text(lift.name)
                            .font(DT.caption)
                            .foregroundStyle(selected ? DT.bg : .white.opacity(0.8))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selected ? DT.accent : DT.surface2, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: 2 — Key-lift grid

    private var keyLiftGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(vm.keyLifts) { lift in
                Button {
                    withAnimation(.snappy) { vm.selectedTrendExercise = lift.exerciseId }
                } label: {
                    KeyLiftCard(
                        lift: lift,
                        points: vm.trendData[lift.exerciseId] ?? [],
                        selected: focus?.exerciseId == lift.exerciseId
                    )
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: 3 — Volume (progressive disclosure)

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    volumeExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VOLUME")
                            .font(DT.caption).tracking(0.6)
                            .foregroundStyle(DT.neutral)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(vm.recentSessionsSetCount)")
                                .font(DT.statNumber)
                                .foregroundStyle(.white)
                            Text("sets · last ~7 sessions")
                                .font(.system(size: 12))
                                .foregroundStyle(DT.neutral)
                        }
                    }
                    Spacer()
                    if !volumeExpanded {
                        VolumeSummarySparkline(totals: weeklyTotals)
                            .frame(width: 96, height: 30)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DT.neutral)
                        .rotationEffect(.degrees(volumeExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            // Honest deficit read — muscles below their target over the same
            // "last ~7 sessions" window stated in the header. Hidden entirely when
            // nothing is below target (no vanity "all on track" banner). [Tier-1 #11]
            if !volumeDeficits.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(volumeDeficits, id: \.muscleGroup) { summary in
                        Text("\(summary.muscleGroup.rawValue.capitalized) · \(summary.volumeDeficit) sets below target")
                            .font(DT.caption)
                            .foregroundStyle(DT.amber)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if volumeExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    VolumeBars(data: sortedVolume)
                        .frame(height: 170)
                    MuscleLegend(muscles: presentMuscles)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DT.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DT.surface2, in: RoundedRectangle(cornerRadius: DT.cardRadius))
    }

    // MARK: 4 — Consistency

    private var consistencyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DT.prGold)
                    .symbolEffect(.pulse, options: .repeating)
                Text(streakLabel)
                    .font(DT.cardTitle)
                    .foregroundStyle(.white)
                Spacer()
            }
            HeatmapGrid(cells: vm.heatmapData)
            heatmapLegend
        }
        .padding(DT.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DT.surface2, in: RoundedRectangle(cornerRadius: DT.cardRadius))
    }

    private var heatmapLegend: some View {
        HStack(spacing: 14) {
            legendDot(DT.emptyCell, "None")
            legendDot(DT.accent.opacity(0.7), "Session")
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(DT.prGold, lineWidth: 1)
                    .frame(width: 10, height: 10)
                Text("PR").font(DT.caption).foregroundStyle(DT.neutral)
            }
            Spacer()
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).font(DT.caption).foregroundStyle(DT.neutral)
        }
    }

    // MARK: 5 — Coaching signals

    private var patternCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COACHING SIGNALS")
                .font(DT.caption).tracking(0.6)
                .foregroundStyle(DT.neutral)
                .padding(.bottom, 6)
            ForEach(Array(vm.patternTrends.enumerated()), id: \.element.pattern) { index, summary in
                PatternRow(summary: summary)
                if index < vm.patternTrends.count - 1 {
                    Divider().overlay(Color.white.opacity(0.06))
                }
            }
        }
        .padding(DT.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DT.surface2, in: RoundedRectangle(cornerRadius: DT.cardRadius))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DT.accent)
            Text("Your progress starts here")
                .font(DT.cardTitle)
                .foregroundStyle(.white)
            Text("Complete a few workouts and your strongest lifts, trends, and streak will appear.")
                .font(DT.bodyText)
                .foregroundStyle(DT.neutral)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .background(DT.surface2, in: RoundedRectangle(cornerRadius: DT.cardRadius))
    }

    // MARK: - Derived values (presentation-only; VM untouched)

    /// The lift the hero focuses on. Honours an explicit chip/grid selection,
    /// else auto-picks the biggest *positive* 4-wk gain (never opens on a
    /// decline), then any progressing lift, then the first available.
    private var focus: KeyLiftSummary? {
        if let sel = vm.selectedTrendExercise,
           let match = vm.keyLifts.first(where: { $0.exerciseId == sel }) {
            return match
        }
        let positives = vm.keyLifts.filter { ($0.deltaVs4WeeksAgo ?? 0) > 0 }
        if let best = positives.max(by: { ($0.deltaVs4WeeksAgo ?? 0) < ($1.deltaVs4WeeksAgo ?? 0) }) {
            return best
        }
        if let progressing = vm.keyLifts.first(where: { $0.trend == .up }) {
            return progressing
        }
        return vm.keyLifts.first
    }

    private func windowedPoints(_ lift: KeyLiftSummary) -> [TrendPoint] {
        let pts = vm.trendData[lift.exerciseId] ?? []
        guard let cutoff = range.cutoff else { return pts }
        let filtered = pts.filter { $0.date >= cutoff }
        return filtered.count >= 2 ? filtered : pts
    }

    private func focusHasPR(_ lift: KeyLiftSummary) -> Bool {
        windowedPoints(lift).last?.isAllTimeBest == true
    }

    private var sortedVolume: [WeeklyVolumeRow] {
        vm.weeklyVolume.sorted { $0.weekStart < $1.weekStart }
    }

    private var hasVolume: Bool {
        !vm.weeklyVolume.isEmpty && !vm.weeklyVolume.allSatisfy { $0.setsByMuscle.isEmpty }
    }

    private var weeklyTotals: [WeekTotal] {
        sortedVolume.enumerated().map { idx, row in
            WeekTotal(id: idx, label: row.weekLabel, value: row.setsByMuscle.values.reduce(0, +))
        }
    }

    private var presentMuscles: [String] {
        Array(Set(vm.weeklyVolume.flatMap { $0.setsByMuscle.keys })).sorted()
    }

    /// Muscles below their recent-window volume target, worst first. Empty when
    /// the digest hasn't hydrated or everything is on/above target — the
    /// deficit section then hides (no congratulatory banner). [Tier-1 #11]
    private var volumeDeficits: [MuscleSummary] {
        vm.muscleSummaries
            .filter { $0.volumeDeficit > 0 }
            .sorted { $0.volumeDeficit > $1.volumeDeficit }
    }

    /// Consecutive most-recent weeks (heatmap col 11 → 0) with any session.
    private var currentStreakWeeks: Int {
        var weeksWith = Set<Int>()
        for cell in vm.heatmapData where cell.sessionCount > 0 { weeksWith.insert(cell.weekIndex) }
        var streak = 0
        for week in stride(from: 11, through: 0, by: -1) {
            if weeksWith.contains(week) { streak += 1 } else { break }
        }
        return streak
    }

    private var streakLabel: String {
        let n = currentStreakWeeks
        return n <= 0 ? "Build your streak" : "\(n)-week streak"
    }

    // MARK: - Hero motion

    private func animateHero(_ lift: KeyLiftSummary) {
        let target = lift.displayE1RM
        let delta = lift.deltaVs4WeeksAgo ?? 0
        deltaShown = false

        if delta > 0 {
            // Count up from the real value 4 weeks ago — semantically honest.
            shownE1RM = max(0, target - delta)
            withAnimation(.easeOut(duration: 0.9)) { shownE1RM = target }
            Haptics.impact(.soft)
            if focusHasPR(lift) { Haptics.success() }
        } else {
            // Holding / declining — no count-up, no celebratory haptic.
            shownE1RM = target
        }

        withAnimation(.easeOut(duration: 0.5).delay(0.25)) { deltaShown = true }
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}

// MARK: - Trend range

private enum TrendRange: String, CaseIterable, Identifiable {
    case eightWeeks = "8w"
    case all = "All"

    var id: String { rawValue }

    /// Range floor. `all` = no floor. Capped to what the VM's ~90-day fetch
    /// can actually fill (no empty 6m/1y windows).
    var cutoff: Date? {
        switch self {
        case .eightWeeks: return Calendar.current.date(byAdding: .day, value: -56, to: Date())
        case .all:        return nil
        }
    }
}

// MARK: - Hero strength chart

private struct StrengthTrendChart: View {
    let points: [TrendPoint]
    @State private var reveal: CGFloat = 0

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(
                    x: .value("Date", p.date),
                    y: .value("e1RM", p.e1RM)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [DT.accent.opacity(0.28), DT.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            ForEach(points) { p in
                LineMark(
                    x: .value("Date", p.date),
                    y: .value("e1RM", p.e1RM)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(DT.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(points.filter(\.isAllTimeBest)) { p in
                PointMark(x: .value("Date", p.date), y: .value("e1RM", p.e1RM))
                    .symbolSize(170)
                    .foregroundStyle(DT.prGold.opacity(0.22))
                PointMark(x: .value("Date", p.date), y: .value("e1RM", p.e1RM))
                    .symbolSize(56)
                    .foregroundStyle(DT.prGold)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(DT.gridLine)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .foregroundStyle(DT.neutral)
            }
        }
        .chartPlotStyle { $0.background(Color.clear) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let last = points.last,
                   let anchor = proxy.plotFrame,
                   let px = proxy.position(forX: last.date),
                   let py = proxy.position(forY: last.e1RM) {
                    let rect = geo[anchor]
                    PulsingDot(color: DT.accent)
                        .position(x: rect.minX + px, y: rect.minY + py)
                        .opacity(reveal >= 1 ? 1 : 0)
                }
            }
        }
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().frame(width: geo.size.width * reveal)
            }
        }
        .onAppear {
            reveal = 0
            withAnimation(.easeInOut(duration: 0.85)) { reveal = 1 }
        }
    }
}

// MARK: - Key-lift card

private struct KeyLiftCard: View {
    let lift: KeyLiftSummary
    let points: [TrendPoint]
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(muscleColor).frame(width: 8, height: 8)
                Text(lift.name)
                    .font(DT.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(fmt(lift.displayE1RM))
                    .font(DT.statNumber)
                    .foregroundStyle(.white)
                Text("kg")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DT.neutral)
            }

            if points.count >= 2 {
                LiftSparkline(points: points).frame(height: 26)
            } else {
                Color.clear.frame(height: 26)
            }

            HStack(spacing: 4) {
                Image(systemName: trendIcon).font(.system(size: 11, weight: .bold))
                Text(deltaText).font(DT.caption)
            }
            .foregroundStyle(trendColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DT.surface2, in: RoundedRectangle(cornerRadius: DT.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DT.cardRadius)
                .strokeBorder(selected ? DT.accent : .clear, lineWidth: 1.5)
        }
    }

    private var muscleColor: Color {
        if let muscle = ExerciseLibrary.primaryMuscle(for: lift.exerciseId) {
            return MuscleColor.color(for: muscle)
        }
        return DT.neutral
    }

    private var deltaText: String {
        guard let d = lift.deltaVs4WeeksAgo, abs(d) >= 0.05 else { return "—" }
        return "\(d > 0 ? "+" : "")\(fmt(d)) kg"
    }

    private var trendIcon: String {
        switch lift.trend {
        case .up:   "chevron.up"
        case .down: "chevron.down"
        case .flat: "minus"
        }
    }

    private var trendColor: Color {
        switch lift.trend {
        case .up:   DT.up
        case .down: DT.down
        case .flat: DT.neutral
        }
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}

// MARK: - Sparklines

private struct LiftSparkline: View {
    let points: [TrendPoint]
    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Date", p.date), y: .value("e1RM", p.e1RM))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(DT.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Color.clear) }
    }
}

private struct VolumeSummarySparkline: View {
    let totals: [WeekTotal]
    var body: some View {
        Chart(totals) { t in
            LineMark(x: .value("Week", t.label), y: .value("Sets", t.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(DT.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.background(Color.clear) }
    }
}

// MARK: - Volume bars + legend

private struct VolumeBars: View {
    let data: [WeeklyVolumeRow]

    private var muscles: [String] {
        Array(Set(data.flatMap { $0.setsByMuscle.keys })).sorted()
    }

    var body: some View {
        Chart {
            ForEach(data) { row in
                ForEach(muscles, id: \.self) { muscle in
                    BarMark(
                        x: .value("Week", row.weekLabel),
                        y: .value("Sets", row.setsByMuscle[muscle] ?? 0),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(MuscleColor.color(for: muscle))
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().foregroundStyle(DT.neutral)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(DT.gridLine)
                AxisValueLabel().foregroundStyle(DT.neutral)
            }
        }
        .chartPlotStyle { $0.background(Color.clear) }
    }
}

private struct MuscleLegend: View {
    let muscles: [String]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(muscles, id: \.self) { muscle in
                HStack(spacing: 4) {
                    Circle().fill(MuscleColor.color(for: muscle)).frame(width: 8, height: 8)
                    Text(muscle.capitalized)
                        .font(.caption2)
                        .foregroundStyle(DT.neutral)
                }
            }
        }
    }
}

// MARK: - Consistency heatmap

private struct HeatmapGrid: View {
    let cells: [HeatmapCell]

    @State private var shown = false
    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    private let size: CGFloat = 14
    private let gap: CGFloat = 3

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(spacing: gap) {
                ForEach(0..<7, id: \.self) { day in
                    Text(dayLabels[day])
                        .font(.system(size: 9))
                        .foregroundStyle(DT.neutral)
                        .frame(width: 12, height: size)
                }
            }
            HStack(spacing: gap) {
                ForEach(0..<12, id: \.self) { week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { day in
                            let cell = cells.first { $0.weekIndex == week && $0.dayOfWeek == day }
                            cellView(cell)
                                .opacity(shown ? 1 : 0)
                                .scaleEffect(shown ? 1 : 0.5)
                                .animation(
                                    .spring(response: 0.4, dampingFraction: 0.7)
                                        .delay(Double(week) * 0.025),
                                    value: shown
                                )
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { shown = true }
    }

    @ViewBuilder
    private func cellView(_ cell: HeatmapCell?) -> some View {
        let shape = RoundedRectangle(cornerRadius: DT.cellRadius)
        shape
            .fill(fill(for: cell))
            .frame(width: size, height: size)
            .overlay {
                if cell?.hasPR == true {
                    shape.strokeBorder(DT.prGold, lineWidth: 1)
                }
            }
    }

    private func fill(for cell: HeatmapCell?) -> Color {
        guard let cell, cell.sessionCount > 0 else { return DT.emptyCell }
        switch cell.sessionCount {
        case 1:  return DT.accent.opacity(0.35)
        case 2:  return DT.accent.opacity(0.70)
        default: return DT.accent
        }
    }
}

// MARK: - Pattern row

private struct PatternRow: View {
    let summary: PatternSummary

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.pattern.displayName)
                    .font(DT.bodyText)
                    .foregroundStyle(.white)
                Text(summary.currentPhase.rawValue.capitalized)
                    .font(DT.caption)
                    .foregroundStyle(DT.neutral)
                // Repeated force-deloads → an actionable next move, not just a
                // tally. Replaces the old "Deload ×N" chip. [Tier-1 #19, ADR-0011 §d]
                if summary.consecutiveForceDeloadsOnPattern >= 2 {
                    Text("Keeps stalling — rotate the exercise or rebuild the block")
                        .font(DT.caption)
                        .foregroundStyle(DT.amber)
                }
            }
            Spacer(minLength: 0)

            if summary.inTransitionMode {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(DT.neutral)
            }
            Text(confidenceLabel)
                .font(DT.caption)
                .foregroundStyle(DT.neutral)
            Image(systemName: trendIcon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(trendColor)
        }
        .padding(.vertical, 8)
    }

    private var confidenceLabel: String {
        switch summary.confidence {
        case .bootstrapping: "New"
        case .calibrating:   "Calibrating"
        case .established:   "Established"
        case .seasoned:      "Seasoned"
        }
    }

    private var trendIcon: String {
        switch summary.trend {
        case .progressing: "chevron.up"
        case .plateaued:   "minus"
        case .declining:   "chevron.down"
        }
    }

    private var trendColor: Color {
        switch summary.trend {
        case .progressing: DT.up
        case .plateaued:   DT.neutral
        case .declining:   DT.down
        }
    }
}

// MARK: - Loading skeleton

private struct HeroSkeleton: View {
    @State private var shimmer = false
    var body: some View {
        RoundedRectangle(cornerRadius: DT.cardRadius)
            .fill(DT.surface1)
            .frame(height: 320)
            .overlay {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.06), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 160)
                .offset(x: shimmer ? 280 : -280)
            }
            .clipShape(RoundedRectangle(cornerRadius: DT.cardRadius))
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
    }
}

// MARK: - Motion primitives

/// A `Text` whose value animates digit-by-digit when changed inside an
/// animation transaction (true rolling count-up).
private struct CountingNumber: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(String(format: "%.1f", value))
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 22, height: 22)
                .scaleEffect(pulse ? 1.35 : 0.7)
                .opacity(pulse ? 0 : 0.7)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(DT.bg, lineWidth: 2))
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct SectionEntrance: ViewModifier {
    let index: Int
    let appeared: Bool
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(.easeOut(duration: 0.5).delay(Double(index) * 0.07), value: appeared)
    }
}

private enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

// MARK: - Small value types

private struct WeekTotal: Identifiable {
    let id: Int
    let label: String
    let value: Int
}

/// Left-to-right wrapping layout for the muscle legend chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Previews

#if DEBUG
extension ProgressViewModel {

    /// Populates a view model with realistic mock data for previews — no network.
    static func makeMock(loading: Bool = false, newUser: Bool = false) -> ProgressViewModel {
        let vm = ProgressViewModel(
            supabaseClient: SupabaseClient(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                anonKey: "preview"
            ),
            userId: UUID()
        )
        vm.isLoading = loading
        if loading { return vm }

        // Authoritative (server EWMA) e1RMs — nil for a brand-new user (empty
        // digest) so the headline falls back to the client-side computed best;
        // slightly offset from currentE1RM otherwise so the authoritative source
        // is visibly distinct. [Tier-1 #1]
        vm.keyLifts = [
            KeyLiftSummary(exerciseId: "barbell_bench_press", name: "Bench Press",   currentE1RM: 100.0, deltaVs4WeeksAgo: newUser ? nil : 4.5,  trend: newUser ? .flat : .up,   authoritativeE1RM: newUser ? nil : 98.5),
            KeyLiftSummary(exerciseId: "barbell_back_squat",  name: "Back Squat",    currentE1RM: 142.5, deltaVs4WeeksAgo: newUser ? nil : 7.5,  trend: newUser ? .flat : .up,   authoritativeE1RM: newUser ? nil : 140.0),
            KeyLiftSummary(exerciseId: "barbell_deadlift",    name: "Deadlift",      currentE1RM: 180.0, deltaVs4WeeksAgo: newUser ? nil : 0.0,  trend: .flat,                  authoritativeE1RM: newUser ? nil : 178.5),
            KeyLiftSummary(exerciseId: "overhead_press",      name: "Overhead Press",currentE1RM: 60.0,  deltaVs4WeeksAgo: newUser ? nil : -2.5, trend: newUser ? .flat : .down, authoritativeE1RM: newUser ? nil : 59.0),
            KeyLiftSummary(exerciseId: "romanian_deadlift",   name: "Romanian DL",   currentE1RM: 120.0, deltaVs4WeeksAgo: newUser ? nil : 5.0,  trend: newUser ? .flat : .up,   authoritativeE1RM: newUser ? nil : 118.5),
        ]

        // Per-exercise confidence summaries spanning the states [Tier-1 #2]:
        // one learning-phase lift (sessionCount < 10), and established/seasoned
        // lifts with realistic session counts. Empty for a brand-new user so the
        // chip hides entirely (honesty-when-empty).
        if !newUser {
            let summaries = [
                ExerciseSummary(profile: ExerciseProfile(exerciseId: "barbell_bench_press", e1rmCurrent: 98.5,  sessionCount: 24, confidence: .seasoned)),
                ExerciseSummary(profile: ExerciseProfile(exerciseId: "barbell_back_squat",  e1rmCurrent: 140.0, sessionCount: 18, confidence: .established)),
                ExerciseSummary(profile: ExerciseProfile(exerciseId: "barbell_deadlift",    e1rmCurrent: 178.5, sessionCount: 12, confidence: .established)),
                ExerciseSummary(profile: ExerciseProfile(exerciseId: "overhead_press",      e1rmCurrent: 59.0,  sessionCount: 4,  confidence: .calibrating)),
                ExerciseSummary(profile: ExerciseProfile(exerciseId: "romanian_deadlift",   e1rmCurrent: 118.5, sessionCount: 9,  confidence: .calibrating)),
            ]
            vm.exerciseSummaries = Dictionary(uniqueKeysWithValues: summaries.map { ($0.exerciseId, $0) })

            // Per-muscle deficits [Tier-1 #11]: a few muscles below target with
            // varied deficits (so the worst-first sort is visible) and one on
            // target (volumeDeficit 0) to prove it's filtered out. Empty for a
            // brand-new user so the deficit section hides entirely.
            vm.muscleSummaries = [
                MuscleSummary(profile: MuscleProfile(muscleGroup: .chest,     volumeDeficit: 4,  confidence: .established)),
                MuscleSummary(profile: MuscleProfile(muscleGroup: .back,      volumeDeficit: 2,  confidence: .established)),
                MuscleSummary(profile: MuscleProfile(muscleGroup: .shoulders, volumeDeficit: 6,  confidence: .calibrating)),
                MuscleSummary(profile: MuscleProfile(muscleGroup: .legs,      volumeDeficit: 0,  confidence: .seasoned)),
            ]
        }

        vm.trendData = [
            "barbell_back_squat":  Self.mockTrend(from: 120, to: 142.5, weeks: 12, lastIsPR: true),
            "barbell_bench_press": Self.mockTrend(from: 88,  to: 100,   weeks: 12, lastIsPR: false, midPR: 6),
            "barbell_deadlift":    Self.mockTrend(from: 180, to: 180,   weeks: 10, lastIsPR: false),
            "overhead_press":      Self.mockTrend(from: 64,  to: 60,    weeks: 9,  lastIsPR: false),
            "romanian_deadlift":   Self.mockTrend(from: 108, to: 120,   weeks: 11, lastIsPR: true),
        ]
        vm.selectedTrendExercise = nil

        let cal = Calendar.current
        let muscles = ["chest", "back", "quads", "hamstrings", "shoulders"]
        vm.weeklyVolume = (0..<8).map { i in
            let start = cal.date(byAdding: .weekOfYear, value: -(7 - i), to: Date())!
            var sets: [String: Int] = [:]
            for (m, muscle) in muscles.enumerated() {
                sets[muscle] = 9 + ((i + m) % 4) * 3 + (i == 7 ? 3 : 0)
            }
            return WeeklyVolumeRow(weekLabel: "W\(8 - i)", weekStart: start, setsByMuscle: sets)
        }
        vm.recentSessionsSetCount = 47

        var heat: [HeatmapCell] = []
        let prCells: Set<[Int]> = [[7, 2], [9, 4], [11, 1], [6, 0]]
        for week in 0..<12 {
            for day in 0..<7 {
                let active = week >= 6 ? (day % 2 == 0 || day == 3) : (week % 2 == 0 && day == 2)
                heat.append(HeatmapCell(
                    weekIndex: week, dayOfWeek: day,
                    sessionCount: active ? 1 : 0,
                    hasPR: prCells.contains([week, day])
                ))
            }
        }
        vm.heatmapData = heat

        vm.patternTrends = [
            PatternSummary(mockPattern: .squat,          phase: .accumulation,    confidence: .seasoned,  trend: .progressing, transition: false, forceDeloads: 0),
            PatternSummary(mockPattern: .hipHinge,       phase: .intensification, confidence: .established, trend: .plateaued,  transition: true,  forceDeloads: 0),
            PatternSummary(mockPattern: .verticalPush,   phase: .deload,          confidence: .calibrating, trend: .declining, transition: false, forceDeloads: 2),
        ]
        return vm
    }

    private static func mockTrend(from start: Double, to end: Double, weeks: Int, lastIsPR: Bool, midPR: Int? = nil) -> [TrendPoint] {
        let cal = Calendar.current
        var best = 0.0
        return (0..<weeks).map { i in
            let frac = weeks <= 1 ? 1 : Double(i) / Double(weeks - 1)
            let raw = start + (end - start) * frac
            let value = (raw * 2).rounded() / 2
            let date = cal.date(byAdding: .day, value: -(weeks - 1 - i) * 7, to: Date())!
            var isPR = value > best
            if isPR { best = value }
            if let m = midPR, i == m { isPR = true }
            if i == weeks - 1 { isPR = lastIsPR }
            return TrendPoint(date: date, e1RM: value, isAllTimeBest: isPR)
        }
    }
}

extension PatternSummary {
    /// Preview-only convenience initialiser. Keeps the model file untouched.
    init(mockPattern pattern: MovementPattern, phase: MesocyclePhase, confidence: AxisConfidence, trend: ProgressionTrend, transition: Bool, forceDeloads: Int) {
        self.pattern = pattern
        self.currentPhase = phase
        self.confidence = confidence
        self.rpeOffset = 0
        self.trend = trend
        self.inTransitionMode = transition
        self.consecutiveForceDeloadsOnPattern = forceDeloads
    }
}

#Preview("Progress — populated") {
    ProgressScreenContent(vm: .makeMock())
        .background(DT.bg)
        .preferredColorScheme(.dark)
}

#Preview("Progress — loading") {
    ProgressScreenContent(vm: .makeMock(loading: true))
        .background(DT.bg)
        .preferredColorScheme(.dark)
}

#Preview("Progress — new user") {
    ProgressScreenContent(vm: .makeMock(newUser: true))
        .background(DT.bg)
        .preferredColorScheme(.dark)
}
#endif
