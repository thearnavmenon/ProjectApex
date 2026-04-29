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
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(amberColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Paused Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(dayLabel.replacingOccurrences(of: "_", with: " ").capitalized) · Week \(weekNumber)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.60))
            }

            Spacer()

            Button(action: onResume) {
                Text("Resume")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(amberColor, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            amberColor.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(amberColor.opacity(0.30), lineWidth: 1)
        )
    }

    private var amberColor: Color {
        Color(red: 1.0, green: 0.65, blue: 0.0)
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()
        PausedSessionBannerView(
            dayLabel: "upper_body_a",
            weekNumber: 2,
            onResume: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}
