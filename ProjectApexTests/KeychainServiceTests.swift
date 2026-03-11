// KeychainServiceTests.swift
// ProjectApexTests
//
// Unit tests for KeychainService.
//
// Test strategy:
//   • Each test uses a unique `serviceName` derived from the test function name
//     so that no test pollutes another's Keychain namespace.
//   • setUp / tearDown delete all known keys so the host Keychain stays clean.
//   • Tests cover: store→retrieve round-trip, update (store twice), delete→nil,
//     delete idempotency, all four KeychainKey cases, and value integrity.
//
// NOTE: Keychain tests must run on a real device or a simulator signed with a
// valid provisioning profile. They will also pass in an unsigned simulator
// context where Keychain is backed by a per-process store.

import XCTest
@testable import ProjectApex

final class KeychainServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Returns a KeychainService scoped to this specific test so different
    /// tests never share Keychain items.
    private func makeService(function: String = #function) -> KeychainService {
        // Trim "()" from function name to keep the service name a legal string.
        let name = "com.projectapex.tests." + function.replacingOccurrences(of: "()", with: "")
        return KeychainService(serviceName: name)
    }

    /// Deletes every KeychainKey from a service — used for setUp / tearDown cleanup.
    private func deleteAll(from service: KeychainService) {
        for key in KeychainKey.allCases {
            try? service.delete(key)
        }
    }

    // MARK: - Round-trip: store → retrieve

    func test_storeAndRetrieve_returnsStoredValue() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("test-value-abc", for: .anthropicAPIKey)
        let retrieved = try service.retrieve(.anthropicAPIKey)

        XCTAssertEqual(retrieved, "test-value-abc")
    }

    /// Verifies that the value coming back is byte-for-byte identical to what
    /// was stored — including special characters common in API keys.
    func test_storeAndRetrieve_preservesSpecialCharacters() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        // Simulate a realistic Anthropic key format.
        let apiKey = "sk-ant-api03-ABCDEFGHIJ1234567890_-abcdefgh"
        try service.store(apiKey, for: .anthropicAPIKey)
        let retrieved = try service.retrieve(.anthropicAPIKey)

        XCTAssertEqual(retrieved, apiKey)
    }

    // MARK: - Update (store twice on same key)

    func test_storeTwice_secondValueWins() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("first-value", for: .openAIAPIKey)
        try service.store("second-value", for: .openAIAPIKey)
        let retrieved = try service.retrieve(.openAIAPIKey)

        XCTAssertEqual(retrieved, "second-value")
    }

    // MARK: - Delete → retrieve returns nil

    func test_delete_afterStore_retrieveReturnsNil() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("to-be-deleted", for: .supabaseAnonKey)

        // Confirm it's present before deleting.
        let before = try service.retrieve(.supabaseAnonKey)
        XCTAssertEqual(before, "to-be-deleted", "Precondition: item must exist before delete.")

        try service.delete(.supabaseAnonKey)
        let after = try service.retrieve(.supabaseAnonKey)

        XCTAssertNil(after, "retrieve must return nil after delete.")
    }

    // MARK: - Delete idempotency

    func test_delete_nonExistentItem_doesNotThrow() {
        let service = makeService()
        // No prior store — delete on missing item must not throw.
        XCTAssertNoThrow(try service.delete(.userId))
    }

    func test_delete_calledTwice_doesNotThrow() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("ephemeral", for: .userId)
        try service.delete(.userId)
        // Second delete on already-deleted item must not throw.
        XCTAssertNoThrow(try service.delete(.userId))
    }

    // MARK: - Retrieve on missing item

    func test_retrieve_missingItem_returnsNil() throws {
        let service = makeService()
        // Nothing stored — retrieve must return nil, not throw.
        let value = try service.retrieve(.anthropicAPIKey)
        XCTAssertNil(value)
    }

    // MARK: - All four KeychainKey cases

    /// Confirms that every defined KeychainKey has its own independent
    /// storage slot (keys do not alias each other).
    func test_allFourKeys_storeIndependently() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("anthropic-value", for: .anthropicAPIKey)
        try service.store("openai-value",    for: .openAIAPIKey)
        try service.store("supabase-value",  for: .supabaseAnonKey)
        try service.store("user-id-value",   for: .userId)

        XCTAssertEqual(try service.retrieve(.anthropicAPIKey), "anthropic-value")
        XCTAssertEqual(try service.retrieve(.openAIAPIKey),    "openai-value")
        XCTAssertEqual(try service.retrieve(.supabaseAnonKey), "supabase-value")
        XCTAssertEqual(try service.retrieve(.userId),          "user-id-value")
    }

    /// Deleting one key must not disturb the others.
    func test_deleteOneKey_leavesOthersIntact() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("keep-anthropic", for: .anthropicAPIKey)
        try service.store("keep-openai",    for: .openAIAPIKey)
        try service.store("delete-me",      for: .supabaseAnonKey)

        try service.delete(.supabaseAnonKey)

        XCTAssertEqual(try service.retrieve(.anthropicAPIKey), "keep-anthropic")
        XCTAssertEqual(try service.retrieve(.openAIAPIKey),    "keep-openai")
        XCTAssertNil(try service.retrieve(.supabaseAnonKey))
    }

    // MARK: - KeychainKey case exhaustiveness

    /// Ensures that all `KeychainKey.allCases` elements have a non-empty
    /// rawValue — a regression guard against accidental blank case additions.
    func test_allKeychainKeys_haveNonEmptyRawValues() {
        for key in KeychainKey.allCases {
            XCTAssertFalse(key.rawValue.isEmpty,
                           "KeychainKey.\(key) has an empty rawValue.")
        }
    }

    /// Every key's rawValue must be unique to avoid aliasing.
    func test_allKeychainKeys_haveUniqueRawValues() {
        let rawValues = KeychainKey.allCases.map(\.rawValue)
        let unique = Set(rawValues)
        XCTAssertEqual(rawValues.count, unique.count,
                       "KeychainKey rawValues contain duplicates: \(rawValues).")
    }

    // MARK: - Empty string storage

    /// The empty string is a valid value (indicates a key was intentionally
    /// cleared); it must round-trip without error.
    func test_storeEmptyString_roundTrips() throws {
        let service = makeService()
        defer { deleteAll(from: service) }

        try service.store("", for: .userId)
        let retrieved = try service.retrieve(.userId)

        XCTAssertEqual(retrieved, "")
    }

    // MARK: - Service isolation

    /// Two KeychainService instances with different service names must not
    /// share items (namespace isolation).
    func test_differentServiceNames_doNotShareItems() throws {
        let serviceA = KeychainService(serviceName: "com.projectapex.tests.isolation.A")
        let serviceB = KeychainService(serviceName: "com.projectapex.tests.isolation.B")
        defer {
            deleteAll(from: serviceA)
            deleteAll(from: serviceB)
        }

        try serviceA.store("value-in-A", for: .anthropicAPIKey)

        let fromB = try serviceB.retrieve(.anthropicAPIKey)
        XCTAssertNil(fromB, "serviceB must not see items stored by serviceA.")
    }
}
