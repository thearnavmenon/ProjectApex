// DesignSystem/ApexTabBar.swift
// ProjectApex — #538 Brutalist bottom navigation.
//
// Bespoke Brutalist bottom tab bar replacing the native UITabBar chrome: pure
// black, a hard top hairline, condensed slab labels, and a top-edge WHITE block
// over the active tab. Monochrome by design — volt-lime stays strictly for
// actions (the action dock / primary buttons), never navigation.
//
// Visual only: it binds to ContentView's `selectedTab` index; tab order matches
// the TabView's tags (0 Program · 1 Workout · 2 Progress · 3 Settings).

import SwiftUI

struct ApexTabBar: View {

    @Binding var selection: Int

    /// (title, SF Symbol) per tab — order MUST match ContentView's `.tag` values.
    private let tabs: [(title: String, icon: String)] = [
        ("PROGRAM",  "calendar"),
        ("WORKOUT",  "figure.strengthtraining.traditional"),
        ("PROGRESS", "chart.line.uptrend.xyaxis"),
        ("SETTINGS", "gearshape.fill"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Button {
                    selection = index
                } label: {
                    tabItem(index: index, title: tab.title, icon: tab.icon)
                }
                .buttonStyle(.plain)
            }
        }
        // Bottom padding lifts the labels above the home-indicator zone, which the
        // host's `.ignoresSafeArea(.container, edges: .bottom)` lets this bar's black
        // fill (verified in the prototype harness, OS 26.x).
        .padding(.bottom, 26)
        .background(Apex.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Apex.hairline).frame(height: 1)
        }
    }

    private func tabItem(index: Int, title: String, icon: String) -> some View {
        let isActive = index == selection
        let tint = isActive ? Apex.text : Apex.textFaint
        return VStack(spacing: 6) {
            // Top-edge indicator block — white on the active tab, clear otherwise.
            Rectangle()
                .fill(isActive ? Apex.text : Color.clear)
                .frame(height: 3)
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 22)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .fontWidth(.condensed)
                .tracking(0.8)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
