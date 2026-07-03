// AppleSignInStepTests.swift
// ProjectApexTests — #597 (SiWA Slice B, umbrella #595)
//
// Unit tests for the two deterministic pieces of the onboarding Apple step:
//
//   1. `AppleSignInNonce` — the raw-nonce generator + SHA-256 hex digest that
//      binds the ASAuthorization request to the GoTrue exchange. Apple gets
//      SHA256(raw) on the request; GoTrue gets the RAW nonce and hashes it
//      server-side to compare with the token's `nonce` claim (Step 0, #595).
//      A wrong digest here = every live exchange fails with "Nonces mismatch".
//
//   2. `OnboardingAppleRouting` — the returning-user routing rule: after the
//      Slice-A exchange, does onboarding continue (fresh/linked user) or does
//      the app open directly (returning user whose recovered uid already has
//      an active program)?
//
// The ASAuthorizationController flow itself is interactive and not unit-testable;
// it is exercised on-device (see #595's owner checklist).

import XCTest
@testable import ProjectApex

// MARK: - Nonce

final class AppleSignInNonceTests: XCTestCase {

    func test_sha256Hex_knownVector() {
        // FIPS 180-4 test vector: SHA256("abc").
        XCTAssertEqual(
            AppleSignInNonce.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func test_sha256Hex_emptyString() {
        XCTAssertEqual(
            AppleSignInNonce.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_generateRaw_hasEntropyAndUrlSafeCharset() {
        let raw = AppleSignInNonce.generateRaw()
        XCTAssertGreaterThanOrEqual(raw.count, 32, "nonce must carry ≥128 bits of entropy")
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-._~")
        XCTAssertTrue(raw.unicodeScalars.allSatisfy { allowed.contains($0) },
            "nonce must be plain-ASCII safe for JSON + JWT claims")
    }

    func test_generateRaw_isUniquePerCall() {
        let nonces = Set((0..<64).map { _ in AppleSignInNonce.generateRaw() })
        XCTAssertEqual(nonces.count, 64, "nonces must never repeat")
    }
}

// MARK: - Returning-user routing

final class OnboardingAppleRoutingTests: XCTestCase {

    private func makeSession(uid: UUID) -> SupabaseSession {
        SupabaseSession(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), userId: uid
        )
    }

    func test_linked_continuesOnboarding() {
        // A fresh user whose anon uid just got anchored: nothing to recover.
        let route = OnboardingAppleRouting.route(
            outcome: .linkedToCurrentUser(makeSession(uid: UUID())),
            hasActiveProgram: false
        )
        XCTAssertEqual(route, .continueOnboarding)
    }

    func test_linked_continuesOnboarding_evenIfProgramExists() {
        // Same uid → same data → onboarding state is the local truth. (Program
        // presence here would mean a mid-onboarding retry; never skip ahead.)
        let route = OnboardingAppleRouting.route(
            outcome: .linkedToCurrentUser(makeSession(uid: UUID())),
            hasActiveProgram: true
        )
        XCTAssertEqual(route, .continueOnboarding)
    }

    func test_returningUser_withProgram_entersApp() {
        // Recovered an existing uid AND it has an active program → this is the
        // acceptance-criteria recovery path: skip onboarding, land in the app.
        let route = OnboardingAppleRouting.route(
            outcome: .signedInAsDifferentUser(makeSession(uid: UUID()), previousUserId: UUID()),
            hasActiveProgram: true
        )
        XCTAssertEqual(route, .enterApp)
    }

    func test_returningUser_withoutProgram_continuesOnboarding() {
        // The Apple ID owned a uid but that uid has no usable program (e.g. an
        // earlier aborted onboarding) → onboard normally under the recovered uid.
        let route = OnboardingAppleRouting.route(
            outcome: .signedInAsDifferentUser(makeSession(uid: UUID()), previousUserId: nil),
            hasActiveProgram: false
        )
        XCTAssertEqual(route, .continueOnboarding)
    }
}
