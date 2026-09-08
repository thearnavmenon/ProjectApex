// AppleSignInStep.swift
// ProjectApex — Onboarding (#597, umbrella #595, ADR-0032)
//
// The required Sign in with Apple onboarding step. The Apple ID is the
// account-recovery anchor: the step calls `SupabaseAuth.signInWithApple`
// (Slice A, #596), which LINKS the Apple identity to the launch-minted
// anonymous `auth.uid()` — preserving the uid — or, for a returning user,
// swaps to the Apple-bound uid so a fresh install recovers its data.
//
// Nonce contract (Step-0-verified, #595): Apple's request carries
// SHA256(rawNonce); the GoTrue exchange carries the RAW nonce (the server
// hashes it to compare with the id_token's `nonce` claim). Getting this
// backwards fails every live exchange with "Nonces mismatch".
//
// Degradation: a canceled or failed sheet leaves the user on this step with a
// fresh nonce; a failed exchange shows a plain-words error. Nothing here can
// brick the anon session (Slice A's contract) or the launch path.

import AuthenticationServices
import CryptoKit
import SwiftUI

// MARK: - Nonce

enum AppleSignInNonce {

    /// 32 cryptographically-secure random bytes, hex-encoded (64 chars).
    /// `SystemRandomNumberGenerator` is the platform CSPRNG on Apple OSes.
    static func generateRaw() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Lowercase-hex SHA-256 of `input` — the value handed to
    /// `ASAuthorizationAppleIDRequest.nonce`.
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Returning-user routing

/// The post-exchange routing rule (deterministic, unit-tested):
///   - a LINK (uid preserved) always continues onboarding — fresh user, no
///     server state to recover;
///   - a session SWAP enters the app directly ONLY when the recovered uid has
///     an active program (the acceptance-criteria recovery path); a recovered
///     uid without one re-onboards under that uid.
enum OnboardingAppleRouting {

    enum Route: Equatable {
        case continueOnboarding
        case enterApp
    }

    static func route(outcome: AppleSignInOutcome, hasActiveProgram: Bool) -> Route {
        switch outcome {
        case .linkedToCurrentUser:
            return .continueOnboarding
        case .signedInAsDifferentUser:
            return hasActiveProgram ? .enterApp : .continueOnboarding
        }
    }
}

// MARK: - Backfill link gate (#598)

/// Launch predicate + local marker for the backfill gate: installs that
/// finished onboarding BEFORE Sign in with Apple existed carry un-anchored
/// data (a reinstall would orphan it), so they are prompted to link on launch.
enum AppleLinkGate {

    /// UserDefaults flag set after any successful link / Apple sign-in on this
    /// install (onboarding step or gate). Cleared by Reset All's domain wipe —
    /// correct, since the reset also clears the session it described.
    static let linkedFlagKey = "com.projectapex.appleIdentityLinked"

    /// Whether launch should even ASK the server about identity state. Only
    /// installs past onboarding (mid-onboarding users get the required #597
    /// step instead) and only until a link is locally recorded.
    static func shouldEvaluate(onboardingComplete: Bool, locallyMarkedLinked: Bool) -> Bool {
        onboardingComplete && !locallyMarkedLinked
    }
}

/// Full-screen prompt the gate presents. Same Slice-A flow as onboarding —
/// linking preserves the install's current uid. Skippable ("Not now"), and it
/// re-arms next launch until linked; a skipped or failed prompt never blocks
/// the app (degradation contract).
struct AppleLinkGateView: View {

    let exchange: (_ idToken: String, _ rawNonce: String) async throws -> AppleSignInOutcome
    let onOutcome: (AppleSignInOutcome) async -> Void
    let onNotNow: () -> Void
    /// DEBUG-only escape, mirrored from the onboarding step: on a free-team
    /// device build the real button can never complete and "Not now" re-arms
    /// the gate every launch, so without this the gate is a dead end.
    var onDebugSkip: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Apex.bg.ignoresSafeArea()
            AppleSignInStepView(
                exchange: exchange,
                onOutcome: onOutcome,
                footer: "One tap — your history stays safe even if this phone doesn't.",
                onNotNow: onNotNow,
                onDebugSkip: onDebugSkip
            )
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Step view

/// The onboarding screen itself. Owns the nonce lifecycle and the Apple sheet;
/// the GoTrue exchange and the routing side-effects are injected so the view
/// stays free of service wiring (and the wiring stays testable upstream).
struct AppleSignInStepView: View {

    /// Performs the GoTrue exchange — `deps.supabaseAuth.signInWithApple`.
    let exchange: (_ idToken: String, _ rawNonce: String) async throws -> AppleSignInOutcome
    /// Invoked after a successful exchange (routing + navigation live here).
    let onOutcome: (AppleSignInOutcome) async -> Void
    /// Back to the previous onboarding beat. nil (the #598 gate) hides the chevron.
    var onBack: (() -> Void)? = nil
    /// Line under the button. Onboarding keeps the "Required" default; the
    /// #598 backfill gate swaps in its own copy.
    var footer: String = "Required — it's how your progress stays yours."
    /// Optional escape hatch — only the #598 backfill gate offers one
    /// ("Not now" → dismiss, re-prompt next launch). Onboarding never does.
    var onNotNow: (() -> Void)? = nil
    /// DEBUG-only escape. Device builds signed by a free Personal Team use
    /// ProjectApexDebug.entitlements, which omits the Sign in with Apple
    /// entitlement, so the real button can never complete. When provided, a
    /// dev-only skip advances past the step with NO link (the user stays on the
    /// anonymous session). Compiled out of Release entirely.
    var onDebugSkip: (() -> Void)? = nil

    @State private var rawNonce = AppleSignInNonce.generateRaw()
    @State private var isExchanging = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Apex.textDim)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 8)
            }

            Spacer()

            ApexSectionLabel(text: "Your account", color: Apex.accent)
            Text("YOURS ON\nEVERY PHONE.")
                .font(.system(size: 44, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .lineSpacing(-2)
                .padding(.top, 12)
            Text("One tap ties your training history to your Apple ID — not to this phone.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Apex.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            VStack(alignment: .leading, spacing: 14) {
                benefit("Lose or replace the phone — sign back in and everything is here.")
                benefit("No email, no password, nothing to remember.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .apexCard()
            .padding(.top, 22)

            if let errorText {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Apex.amber)
                        .padding(.top, 1)
                    Text(errorText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Apex.amber.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            }

            Spacer()

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
                // Apple gets the HASH; GoTrue later gets the RAW nonce.
                request.nonce = AppleSignInNonce.sha256Hex(rawNonce)
            } onCompletion: { result in
                handleAuthorization(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(isExchanging ? 0.4 : 1)
            .disabled(isExchanging)

            Text(isExchanging ? "Securing your account…" : footer)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Apex.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)

            if let onNotNow {
                Button(action: onNotNow) {
                    Text("Not now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Apex.textFaint)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(isExchanging)
                .padding(.top, 16)
            }

            #if DEBUG
            if let onDebugSkip {
                Button(action: onDebugSkip) {
                    Text("Skip — dev build (no Apple entitlement)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Apex.amber.opacity(0.85))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(isExchanging)
                .padding(.top, 12)
            }
            #endif
        }
        .padding(.horizontal, Apex.pad)
        .padding(.bottom, 30)
    }

    private func benefit(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Apex.accent)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Apex.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Authorization → exchange

    private func handleAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                errorText = "Apple didn't return a usable credential. Please try again."
                rawNonce = AppleSignInNonce.generateRaw()
                return
            }
            let nonce = rawNonce
            isExchanging = true
            errorText = nil
            Task {
                do {
                    let outcome = try await exchange(idToken, nonce)
                    await onOutcome(outcome)
                } catch {
                    // Plain words; never surfaces token values (Slice A contract).
                    errorText = "Couldn't reach the account server. Check your connection and try again."
                    rawNonce = AppleSignInNonce.generateRaw()
                }
                isExchanging = false
            }
        case .failure:
            // Canceled or sheet-level failure — stay on the step, fresh nonce.
            rawNonce = AppleSignInNonce.generateRaw()
        }
    }
}
