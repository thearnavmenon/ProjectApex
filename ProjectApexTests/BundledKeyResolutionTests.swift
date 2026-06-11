// BundledKeyResolutionTests.swift
// ProjectApexTests
//
// Covers the fresh-install key path (#329 / O-F1):
//   • BundledAPIKey — reads the build-time Info.plist key; empty / placeholder → nil.
//   • AnthropicKeyResolver — precedence Keychain → bundled (seeded) → nil.
//   • Gate predicate — nil key → gate shown; key present → gate not shown.
//
// The Keychain and Info.plist lookups are injected as closures, so no test touches
// the real Keychain or the real app bundle.

import XCTest
@testable import ProjectApex

final class BundledKeyResolutionTests: XCTestCase {

    // MARK: - BundledAPIKey.anthropic

    func test_bundledKey_realValue_returnsTrimmedValue() {
        let key = BundledAPIKey.anthropic(lookup: { _ in "  sk-ant-real-key-123  " })
        XCTAssertEqual(key, "sk-ant-real-key-123")
    }

    func test_bundledKey_missingEntry_returnsNil() {
        // No xcconfig at build time → Info dictionary has no entry.
        let key = BundledAPIKey.anthropic(lookup: { _ in nil })
        XCTAssertNil(key)
    }

    func test_bundledKey_emptyString_returnsNil() {
        // Variable expanded to empty (file present but blank).
        let key = BundledAPIKey.anthropic(lookup: { _ in "" })
        XCTAssertNil(key)
    }

    func test_bundledKey_untouchedPlaceholder_returnsNil() {
        // Developer copied the template but never filled it in.
        let key = BundledAPIKey.anthropic(lookup: { _ in BundledAPIKey.placeholder })
        XCTAssertNil(key)
    }

    func test_bundledKey_readsTheExpectedInfoPlistKey() {
        var requestedKey: String?
        _ = BundledAPIKey.anthropic(lookup: { requestedKey = $0; return nil })
        XCTAssertEqual(requestedKey, BundledAPIKey.infoPlistKey)
    }

    // MARK: - AnthropicKeyResolver precedence

    func test_resolve_keychainPresent_usesKeychain_andDoesNotSeed() {
        var stored: String?
        let resolved = AnthropicKeyResolver.resolve(
            retrieve: { "sk-ant-keychain" },
            store: { stored = $0 },
            bundled: { "sk-ant-bundled" }
        )
        XCTAssertEqual(resolved, "sk-ant-keychain", "Keychain value must win over bundled.")
        XCTAssertNil(stored, "An existing Keychain key must never be overwritten.")
    }

    func test_resolve_keychainEmpty_bundledPresent_usesAndSeedsBundled() {
        var stored: String?
        let resolved = AnthropicKeyResolver.resolve(
            retrieve: { nil },
            store: { stored = $0 },
            bundled: { "sk-ant-bundled" }
        )
        XCTAssertEqual(resolved, "sk-ant-bundled", "Bundled key must be used when Keychain is empty.")
        XCTAssertEqual(stored, "sk-ant-bundled", "Bundled key must be seeded into the Keychain.")
    }

    func test_resolve_keychainEmptyString_bundledPresent_usesAndSeedsBundled() {
        // A stored-but-empty value (e.g. an intentionally cleared key) is treated
        // as "no key" so the bundled fallback still fires.
        var stored: String?
        let resolved = AnthropicKeyResolver.resolve(
            retrieve: { "" },
            store: { stored = $0 },
            bundled: { "sk-ant-bundled" }
        )
        XCTAssertEqual(resolved, "sk-ant-bundled")
        XCTAssertEqual(stored, "sk-ant-bundled")
    }

    func test_resolve_bothAbsent_returnsNil_andDoesNotSeed() {
        var stored: String?
        let resolved = AnthropicKeyResolver.resolve(
            retrieve: { nil },
            store: { stored = $0 },
            bundled: { nil }
        )
        XCTAssertNil(resolved, "No key anywhere → nil.")
        XCTAssertNil(stored, "Nothing to seed when there is no bundled key.")
    }

    // MARK: - Gate predicate

    /// The launch gate keys off the same nil-ness the resolver produces:
    /// `hasResolvableAIKey = resolved != nil`. These two cases pin that mapping.

    func test_gatePredicate_keyPresent_gateNotShown() {
        let resolved = AnthropicKeyResolver.resolve(
            retrieve: { nil },
            store: { _ in },
            bundled: { "sk-ant-bundled" }
        )
        let hasResolvableAIKey = resolved != nil
        XCTAssertTrue(hasResolvableAIKey, "A resolvable key must NOT trigger the needs-setup gate.")
    }

    func test_gatePredicate_noKey_gateShown() {
        let resolved = AnthropicKeyResolver.resolve(
            retrieve: { nil },
            store: { _ in },
            bundled: { nil }
        )
        let hasResolvableAIKey = resolved != nil
        XCTAssertFalse(hasResolvableAIKey, "No resolvable key MUST trigger the needs-setup gate.")
    }
}
