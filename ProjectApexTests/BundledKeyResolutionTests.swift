// BundledKeyResolutionTests.swift
// ProjectApexTests
//
// Covers the fresh-install key path (#329 / O-F1, #369 slice 2):
//   • BundledAPIKey — reads the build-time Info.plist keys; empty / placeholder → nil.
//   • AnthropicKeyResolver — precedence Keychain → bundled (seeded) → nil.
//   • SupabaseAnonKeyResolver — same precedence, mirrored.
//   • Gate predicate — missing either key → gate shown; both present → gate not shown.
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

    // MARK: - BundledAPIKey.supabaseAnon

    func test_bundledSupabaseKey_realValue_returnsTrimmedValue() {
        let key = BundledAPIKey.supabaseAnon(lookup: { _ in "  eyJhbGc.real-anon-key  " })
        XCTAssertEqual(key, "eyJhbGc.real-anon-key")
    }

    func test_bundledSupabaseKey_missingEntry_returnsNil() {
        let key = BundledAPIKey.supabaseAnon(lookup: { _ in nil })
        XCTAssertNil(key)
    }

    func test_bundledSupabaseKey_emptyString_returnsNil() {
        let key = BundledAPIKey.supabaseAnon(lookup: { _ in "" })
        XCTAssertNil(key)
    }

    func test_bundledSupabaseKey_untouchedPlaceholder_returnsNil() {
        let key = BundledAPIKey.supabaseAnon(lookup: { _ in BundledAPIKey.placeholder })
        XCTAssertNil(key)
    }

    func test_bundledSupabaseKey_readsTheExpectedInfoPlistKey() {
        var requestedKey: String?
        _ = BundledAPIKey.supabaseAnon(lookup: { requestedKey = $0; return nil })
        XCTAssertEqual(requestedKey, BundledAPIKey.supabaseAnonInfoPlistKey)
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

    // MARK: - SupabaseAnonKeyResolver precedence

    func test_supabaseResolve_keychainPresent_usesKeychain_andDoesNotSeed() {
        var stored: String?
        let resolved = SupabaseAnonKeyResolver.resolve(
            retrieve: { "eyJhbGc.keychain-anon-key" },
            store: { stored = $0 },
            bundled: { "eyJhbGc.bundled-anon-key" }
        )
        XCTAssertEqual(resolved, "eyJhbGc.keychain-anon-key", "Keychain value must win over bundled.")
        XCTAssertNil(stored, "An existing Keychain key must never be overwritten.")
    }

    func test_supabaseResolve_keychainEmpty_bundledPresent_usesAndSeedsBundled() {
        var stored: String?
        let resolved = SupabaseAnonKeyResolver.resolve(
            retrieve: { nil },
            store: { stored = $0 },
            bundled: { "eyJhbGc.bundled-anon-key" }
        )
        XCTAssertEqual(resolved, "eyJhbGc.bundled-anon-key", "Bundled key must be used when Keychain is empty.")
        XCTAssertEqual(stored, "eyJhbGc.bundled-anon-key", "Bundled key must be seeded into the Keychain.")
    }

    func test_supabaseResolve_keychainEmptyString_bundledPresent_usesAndSeedsBundled() {
        var stored: String?
        let resolved = SupabaseAnonKeyResolver.resolve(
            retrieve: { "" },
            store: { stored = $0 },
            bundled: { "eyJhbGc.bundled-anon-key" }
        )
        XCTAssertEqual(resolved, "eyJhbGc.bundled-anon-key")
        XCTAssertEqual(stored, "eyJhbGc.bundled-anon-key")
    }

    func test_supabaseResolve_bothAbsent_returnsNil_andDoesNotSeed() {
        var stored: String?
        let resolved = SupabaseAnonKeyResolver.resolve(
            retrieve: { nil },
            store: { stored = $0 },
            bundled: { nil }
        )
        XCTAssertNil(resolved, "No key anywhere → nil.")
        XCTAssertNil(stored, "Nothing to seed when there is no bundled key.")
    }

    // MARK: - Gate predicate

    /// The launch gate requires BOTH keys: `hasResolvableAIKey && hasResolvableSupabaseKey`.
    /// These cases pin that combined predicate.

    func test_gatePredicate_bothKeysPresent_gateNotShown() {
        let ai = AnthropicKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { "sk-ant-bundled" })
        let supa = SupabaseAnonKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { "eyJhbGc.bundled" })
        XCTAssertTrue(ai != nil && supa != nil, "Both keys present must NOT trigger the gate.")
    }

    func test_gatePredicate_aiKeyMissing_gateShown() {
        let ai = AnthropicKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { nil })
        let supa = SupabaseAnonKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { "eyJhbGc.bundled" })
        XCTAssertFalse(ai != nil && supa != nil, "Missing AI key MUST trigger the gate.")
    }

    func test_gatePredicate_supabaseKeyMissing_gateShown() {
        let ai = AnthropicKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { "sk-ant-bundled" })
        let supa = SupabaseAnonKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { nil })
        XCTAssertFalse(ai != nil && supa != nil, "Missing Supabase anon key MUST trigger the gate.")
    }

    func test_gatePredicate_bothKeysMissing_gateShown() {
        let ai = AnthropicKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { nil })
        let supa = SupabaseAnonKeyResolver.resolve(retrieve: { nil }, store: { _ in }, bundled: { nil })
        XCTAssertFalse(ai != nil && supa != nil, "Both keys missing MUST trigger the gate.")
    }
}
