// Features/Workout/InferenceRetrySheet.swift
// ProjectApex
//
// Bottom sheet presented when AI inference fails during a workout.
// Forces the user to choose between retrying or pausing — no silent fallback.
//
// Presented by WorkoutView as a .sheet overlay on .resting and .preflight states.
//
// Visual layer restyled to the Brutalist Athletic identity (#473): pure-black
// surface, an amber "Coach is offline" hero (amber is the offline/paused token),
// the no-silent-guess subtitle, a dominant volt-lime "Try again" (keeping its
// in-flight spinner), a ghost "Use last session's weights" gated on a real seed,
// and a quiet "Pause workout" text action. Behaviour, bindings, state, the
// seed-gated condition, and the no-silent-fallback contract are unchanged.

import SwiftUI

// MARK: - InferenceRetrySheet

struct InferenceRetrySheet: View {

    @Bindable var viewModel: WorkoutViewModel

    var body: some View {
        ZStack {
            // Pure-black Brutalist backdrop.
            Apex.bg.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 8)

                hero

                Spacer()

                actions
            }
            .padding(.horizontal, Apex.pad)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        // Force the user to choose — no swipe-to-dismiss
        .interactiveDismissDisabled()
    }

    // MARK: - Hero (icon + title + subtitle + optional reason)

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Apex.amber.opacity(0.14))
                    .frame(width: 88, height: 88)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(Apex.amber)
                    .symbolEffect(.pulse, isActive: viewModel.isRetrying)
            }

            Text("Coach is offline")
                .font(.system(size: 28, weight: .heavy))
                .fontWidth(.condensed)
                .textCase(.uppercase)
                .foregroundStyle(Apex.amber)

            VStack(spacing: 10) {
                Text("Couldn't reach the AI — and we won't guess your weights for you.")
                    .font(.system(size: 16, weight: .medium))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = viewModel.retryFailureDescription {
                    Text(reason)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Apex.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 14) {
            // Primary — Try again. Dominant volt-lime action. Keeps its in-flight
            // spinner overlaid while a retry is in progress → onRetryInference().
            Button(action: { viewModel.onRetryInference() }) {
                ApexButton(title: "Try again", icon: "arrow.clockwise")
                    .opacity(viewModel.isRetrying ? 0 : 1)
                    .overlay {
                        if viewModel.isRetrying {
                            ProgressView()
                                .tint(Apex.onAccent)
                        }
                    }
                    .background {
                        // Keep the filled accent slab behind the spinner so the
                        // in-flight button still reads as the primary action.
                        if viewModel.isRetrying {
                            RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                                .fill(Apex.accent)
                        }
                    }
            }
            .disabled(viewModel.isRetrying)

            // Use last session's weights — only when a real seed exists
            // (#318 U7 / G-F1): an in-session set, last-session history,
            // or a genuinely bodyweight movement. Offered during rest
            // and (critic amendment 7.6) during preflight, so first-set
            // / post-swap / resume failures get a manual path too.
            if (viewModel.isResting || viewModel.isPreflight) && viewModel.canUseLastWeights {
                Button(action: { viewModel.onUseLastWeights() }) {
                    ApexButton(title: "Use last session's weights", kind: .ghost, icon: "clock.arrow.circlepath")
                }
                .disabled(viewModel.isRetrying)
            }

            // Pause workout — quiet, recessive text action.
            Button(action: { viewModel.onPauseFromRetrySheet() }) {
                Text("Pause workout")
                    .font(.system(size: 13, weight: .semibold))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Apex.textDim)
                    .padding(.vertical, 6)
            }
            .disabled(viewModel.isRetrying)
        }
    }
}
