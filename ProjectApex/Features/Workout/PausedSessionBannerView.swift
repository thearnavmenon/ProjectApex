// Features/Workout/PausedSessionBannerView.swift
// ProjectApex
//
// Amber banner shown on the Workout tab when a paused session exists for a
// training day that is not the current next incomplete day.
// Tapping "Resume" navigates to ProgramDayDetailView for the paused day.

import SwiftUI

struct PausedSessionBannerView: View {

    let dayLabel: String
    let weekNumber: Int
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Apex.amber)

            VStack(alignment: .leading, spacing: 3) {
                Text("Workout paused")
                    .font(.system(size: 14, weight: .heavy))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(Apex.amber)
                HStack(spacing: 4) {
                    Text(dayLabel.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textDim)
                    Text("· WEEK")
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textFaint)
                    Text("\(weekNumber)")
                        .font(Apex.numeral(12, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.textDim)
                }
            }

            Spacer()

            Button(action: onResume) {
                Text("Resume")
                    .font(.system(size: 13, weight: .bold))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Apex.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Apex.amber, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Apex.surface,
            in: RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                .stroke(Apex.amber.opacity(0.45), lineWidth: 1)
        )
    }
}

#Preview {
    ZStack {
        Apex.bg.ignoresSafeArea()
        PausedSessionBannerView(
            dayLabel: "upper_body_a",
            weekNumber: 2,
            onResume: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}
