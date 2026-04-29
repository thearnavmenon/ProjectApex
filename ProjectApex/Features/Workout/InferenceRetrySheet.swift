// Features/Workout/InferenceRetrySheet.swift
// ProjectApex
//
// Bottom sheet presented when AI inference fails during a workout.
// Forces the user to choose between retrying or pausing — no silent fallback.
//
// Presented by WorkoutView as a .sheet overlay on .resting and .preflight states.

import SwiftUI

// MARK: - InferenceRetrySheet

struct InferenceRetrySheet: View {

    @Bindable var viewModel: WorkoutViewModel

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.09).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 8)

                // Brain icon
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color(red: 1.00, green: 0.80, blue: 0.20))
                    .symbolEffect(.pulse, isActive: viewModel.isRetrying)

                // Title + subtitle
                VStack(spacing: 10) {
                    Text("Your AI coach is unavailable right now.")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if let reason = viewModel.retryFailureDescription {
                        Text(reason)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    // Retry button
                    Button(action: { viewModel.onRetryInference() }) {
                        ZStack {
                            if viewModel.isRetrying {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(1.1)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Retry")
                                        .font(.system(size: 17, weight: .semibold))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(
                            Color(red: 0.23, green: 0.56, blue: 1.00),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .foregroundStyle(.white)
                    }
                    .disabled(viewModel.isRetrying)

                    // Continue with last weights — only during rest (not preflight)
                    if viewModel.isResting {
                        Button(action: { viewModel.onUseLastWeights() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 16, weight: .medium))
                                Text("Continue with last weights")
                                    .font(.system(size: 17, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .foregroundStyle(.white.opacity(0.70))
                        }
                        .disabled(viewModel.isRetrying)
                    }

                    // Pause Session button
                    Button(action: { viewModel.onPauseFromRetrySheet() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "pause.circle")
                                .font(.system(size: 16, weight: .medium))
                            Text("Pause Session")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .foregroundStyle(.white.opacity(0.70))
                    }
                    .disabled(viewModel.isRetrying)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        // Force the user to choose — no swipe-to-dismiss
        .interactiveDismissDisabled()
    }
}
