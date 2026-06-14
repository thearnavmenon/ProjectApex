// AppShell.swift
// ProjectApex
//
// The Phase 3 UI-overhaul shell: the locked 3-tab navigation — Today / Train /
// Progress — with settings in a corner, not a tab (ui-overhaul-spec.md §2).
//
// A strangler-fig sibling root to the frozen `ContentView` (ADR-0026), selected by
// one compile-time constant in `ProjectApexApp`. This slice (#343) lands the shell
// behind `useNewShell = false`: built, wired, and unit-tested, but NOT yet the live
// root — so `ContentView` keeps owning the onboarding gate, crash-recovery, the
// paused-session resume, and the `ProgramViewModel` lifecycle (ADR-0026
// "machinery-last"). Each surface is a code-as-switch `@ViewBuilder`; a per-surface
// slice swaps in its real screen later. The legacy raw-Int `switchToTab` contract
// is preserved by a pure translation layer (`ShellRoute`) so the existing
// feature-view call sites stay byte-identical.
//
// All chrome reads #341 design tokens (ADR-0024) — no hardcoded colors here.

import SwiftUI

// MARK: - Tabs

/// The three locked tabs (ui-overhaul-spec.md §2), in bar order. Settings is
/// deliberately *not* a case — it lives in a corner affordance, not the tab bar.
enum ApexTab: CaseIterable, Identifiable {
    case today, train, progress

    var id: Self { self }

    /// Tab-bar label — also the VoiceOver name.
    var title: String {
        switch self {
        case .today: "Today"
        case .train: "Train"
        case .progress: "Progress"
        }
    }

    /// SF Symbol base name. The bar applies the *filled* variant to the selected
    /// tab (DESIGN.md §Iconography: "Filled variant only for the selected tab").
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .train: "dumbbell"
        case .progress: "chart.line.uptrend.xyaxis"
        }
    }
}

// MARK: - Legacy switchToTab bridge

/// Translation of the frozen `ContentView` raw-Int `switchToTab` contract
/// (0 = Program, 1 = Workout, 2 = Progress, 3 = Settings) into a shell action.
///
/// ADR-0026 keeps the Int contract so the two live feature-view call sites
/// (`switchToTab(1)` "Continue Workout" → live loop, `switchToTab(3)` → Settings)
/// stay byte-identical. The mapping is pure, so a wrong route is a caught test
/// failure, not a silent in-app mis-navigation. (Migrating the callers to a typed
/// `ApexTab` is the close-out move, deferred to #363.)
enum ShellRoute: Equatable {
    /// Switch the bar to a tab.
    case select(ApexTab)
    /// The live-loop entry — a pushed/covered surface, not a tab
    /// (ADR-0026 / splash-today.md: the loop "rises through" Start, off-tab).
    case presentLiveLoop
    /// The settings corner sheet.
    case presentSettings

    static func from(legacyTab index: Int) -> ShellRoute {
        switch index {
        case 0: .select(.train)      // Program → Train owns the program/calendar now
        case 1: .presentLiveLoop     // Workout → the live-loop entry
        case 2: .select(.progress)   // Progress → Progress
        case 3: .presentSettings     // Settings → the corner sheet
        default: .select(.today)     // unknown index → home (the safe no-op-spirited default)
        }
    }
}

// MARK: - Shell

struct AppShell: View {

    @Environment(\.apexTheme) private var theme
    @Environment(AppDependencies.self) private var deps

    @State private var selection: ApexTab = .today
    @State private var showSettings = false

    var body: some View {
        // Active surface — code-as-switch routing (ADR-0026 (a)).
        surface(for: selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.paper.color.ignoresSafeArea())
            // The bar reserves its own space and propagates a bottom inset into
            // child scroll views, so surface content never renders behind it.
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            // Settings leaves the tab bar for a corner gear (ADR-0026 (b)).
            .overlay(alignment: .topTrailing) { settingsButton }
            .sheet(isPresented: $showSettings) { settingsSheet }
            // Preserve the frozen raw-Int `switchToTab` contract via the pure bridge,
            // so the existing feature-view call sites need no edit (ADR-0026 (c)).
            .environment(\.switchToTab) { legacyTab in
                switch ShellRoute.from(legacyTab: legacyTab) {
                case .select(let tab): selection = tab
                // Interim: the live-loop host is lifted in a later, tested slice
                // (machinery-last); route to Today, which owns Start, until then.
                case .presentLiveLoop: selection = .today
                case .presentSettings: showSettings = true
                }
            }
    }

    // MARK: Routing — code-as-switch

    /// "Is this surface built?" is the literal presence of its real view's
    /// constructor here (ADR-0026 (a)). Today (#348), Progress (#354), and Train
    /// (#357) re-home their real roots now — each reads its data through `deps`,
    /// with the `ProgramViewModel` lifecycle still lifted later (#376, machinery-last).
    @ViewBuilder
    private func surface(for tab: ApexTab) -> some View {
        switch tab {
        case .today:
            // #348: new Today root — the coach/home surface (splash-today.md Part 2).
            // ContentView is preserved for the live app; only this dormant AppShell
            // branch changes. The host owns the data boundary; the ProgramViewModel
            // lifecycle + live Start path are lifted here in #376 (machinery-last).
            TodayRootHost()
        case .train:
            // #357: new Train root — the program day-spine (train.md §3).
            // ProgramOverviewView is preserved for the live ContentView; only this
            // dormant AppShell branch changes. The host owns the data boundary; the
            // ProgramViewModel lifecycle is lifted here in #376 (machinery-last).
            TrainProgramRootHost()
        case .progress:
            // #354: new Progress root — the capability ledger (progress.md §3).
            // ProgressTabView is preserved for the live ContentView; only this
            // dormant AppShell branch changes.
            ProgressRootLedgerHost()
        }
    }

    // MARK: Tab bar (DESIGN.md §Iconography — ink default, accent-ink + filled when selected)

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ApexTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(.top, Spacing.sm)
        .background(alignment: .top) {
            theme.surface.color
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    theme.hairline.color.frame(height: 1)   // full-bleed top rule
                }
        }
    }

    private func tabButton(_ tab: ApexTab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            VStack(spacing: Spacing.xs) {
                Image(systemName: tab.symbol)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 22, weight: .medium))   // §Iconography medium weight
                Text(tab.title)
                    .apexFont(.label)
            }
            .foregroundStyle(isSelected ? theme.accentInk.color : theme.ink.color)
            .frame(maxWidth: .infinity)
            .padding(.bottom, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Settings corner

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accentInk.color)   // interactive → accent-ink
                .padding(Spacing.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private var settingsSheet: some View {
        // Interim: the real settings root is a private member of the frozen
        // `ContentView` (no standalone screen to reuse), so it re-homes here in a
        // later slice. The corner affordance + sheet mechanics are wired now.
        InterimSurface(
            title: "Settings",
            note: "The settings surface re-homes here in a later slice."
        )
    }
}

// MARK: - Interim surface

/// An honest interim for a surface whose real screen (and the machinery it needs)
/// lands in a later per-surface slice. The shell is dormant in #343
/// (`useNewShell = false`), so this is compile-time scaffold that no user sees
/// until each surface's slice swaps in its real screen.
private struct InterimSurface: View {
    @Environment(\.apexTheme) private var theme
    let title: String
    let note: String

    var body: some View {
        ZStack {
            theme.paper.color.ignoresSafeArea()
            VStack(spacing: Spacing.sm) {
                Text(title)
                    .apexFont(.display)
                    .foregroundStyle(theme.ink.color)
                Text(note)
                    .apexFont(.body)
                    .foregroundStyle(theme.inkMuted.color)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.lg)
        }
    }
}
