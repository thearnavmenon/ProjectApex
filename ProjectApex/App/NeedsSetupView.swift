// NeedsSetupView.swift
// ProjectApex — App Layer
//
// Honest launch gate for a build that shipped without an API key (#329 / O-F1).
//
// Before this, a fresh install let the user start onboarding and scan a gym for
// ten minutes before the first AI call died with a raw HTTP error. This screen
// is shown INSTEAD of onboarding when no Anthropic key is resolvable (neither in
// the Keychain nor bundled into the build), so the dead end is named up front.
//
// It is a no-op when a key is present — ContentView only renders it when
// `deps.hasResolvableAIKey == false`, so the normal onboarding/app path is untouched.

import SwiftUI

struct NeedsSetupView: View {

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            Text("This build needs setup")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("""
            This build is missing its API configuration, so coaching and gym \
            scanning can't run yet. Nothing is wrong with your device.

            If you're testing an alpha build, contact the developer for a \
            configured build. In a debug build you can add a key under \
            Settings → Developer.
            """)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NeedsSetupView()
        .preferredColorScheme(.dark)
}
