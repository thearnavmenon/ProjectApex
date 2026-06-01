// KeychainService.swift
// ProjectApex — Security Foundation
//
// Provides type-safe, generic-password Keychain storage for all API secrets.
// No API key string should ever appear in source code, UserDefaults, or the
// compiled binary outside of this file's unit tests.
//
// Design decisions:
//   • `KeychainKey` is a typed enum so callers can never pass an arbitrary string
//     as a key — prevents typos and namespace collisions at compile time.
//   • All operations are synchronous and nonisolated; Keychain calls are already
//     thread-safe at the OS level and complete in microseconds on device.
//   • Returns `KeychainError` rather than raw OSStatus to give callers a stable,
//     documentation-friendly error surface.
//
// Keychain entitlement requirement:
//   The target's .entitlements file must contain the `keychain-access-groups`
//   key. The group string used here is the bundle's default access group
//   (kSecAttrAccessGroupToken / no explicit group), so the existing entitlement
//   already satisfies the requirement without hard-coding a team ID.

import Foundation
import Security

// MARK: - KeychainKey

/// The exhaustive set of secret keys the app stores in the Keychain.
///
/// Add new cases here when new API integrations are introduced so that
/// the compiler enforces awareness at every call site.
enum KeychainKey: String, CaseIterable {
    /// Anthropic Claude API key. Format: "sk-ant-…"
    case anthropicAPIKey  = "com.projectapex.keychain.anthropicAPIKey"
    /// OpenAI GPT-4o API key. Format: "sk-…"
    case openAIAPIKey     = "com.projectapex.keychain.openAIAPIKey"
    /// Supabase anonymous/public key (JWT). Not a secret in the strict sense
    /// but stored here to keep all remote credentials in one place.
    case supabaseAnonKey  = "com.projectapex.keychain.supabaseAnonKey"
    /// Stable user identifier (UUID string) persisted between app reinstalls.
    case userId           = "com.projectapex.keychain.userId"
}

// MARK: - KeychainError

/// Errors returned by `KeychainService` operations.
enum KeychainError: LocalizedError, Equatable {
    /// The item already exists. Only raised by explicit add paths (not used by
    /// `store` which performs upsert semantics).
    case duplicateItem
    /// The requested item was not found.
    case itemNotFound
    /// The raw value stored in the Keychain could not be decoded as a UTF-8 string.
    case invalidData
    /// An unexpected OSStatus was returned.
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "A Keychain item with this key already exists."
        case .itemNotFound:
            return "The requested Keychain item does not exist."
        case .invalidData:
            return "The Keychain item data could not be decoded as a UTF-8 string."
        case .unexpectedStatus(let status):
            return "Unexpected Keychain OSStatus: \(status)."
        }
    }
}

// MARK: - KeychainService

/// Provides store / retrieve / delete operations for `String` secrets
/// backed by the iOS / macOS Keychain using `kSecClassGenericPassword`.
///
/// All methods are `nonisolated` and safe to call from any actor context.
nonisolated struct KeychainService {

    // MARK: - Singleton

    /// Shared instance suitable for production use.
    static let shared = KeychainService()

    // Allow direct init for testing with a custom service name.
    let serviceName: String

    init(serviceName: String = Bundle.main.bundleIdentifier ?? "com.projectapex") {
        self.serviceName = serviceName
    }

    // MARK: - Public API

    /// Stores (or replaces) `value` in the Keychain under `key`.
    ///
    /// Uses upsert semantics: if an item already exists for `key` it is
    /// updated rather than duplicated.
    ///
    /// - Parameters:
    ///   - value: The plaintext string to store (e.g. an API key).
    ///   - key: The `KeychainKey` case that identifies this secret.
    /// - Throws: `KeychainError` on unexpected Keychain failures.
    func store(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // Build the base query that identifies this item.
        let query = baseQuery(for: key)

        // Attempt an add first; if duplicate, fall through to update.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Restrict to when-unlocked accessibility so the item is available
        // during normal app use but protected when the device is locked.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            // New item successfully written.
            return

        case errSecDuplicateItem:
            // Item already exists — update the data in place.
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary,
                                            attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }

        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Retrieves the string value stored under `key`, or `nil` if not found.
    ///
    /// - Parameter key: The `KeychainKey` identifying the secret to retrieve.
    /// - Returns: The stored string, or `nil` if no item exists for `key`.
    /// - Throws: `KeychainError.invalidData` if the stored bytes are not valid UTF-8.
    func retrieve(_ key: KeychainKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecMatchLimit as String]       = kSecMatchLimitOne
        query[kSecReturnData as String]       = true
        query[kSecReturnAttributes as String] = false

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return string

        case errSecItemNotFound:
            return nil

        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Deletes the Keychain item stored under `key`.
    ///
    /// This is a no-op if the item does not exist (idempotent).
    ///
    /// - Parameter key: The `KeychainKey` identifying the secret to delete.
    /// - Throws: `KeychainError` on unexpected Keychain failures.
    func delete(_ key: KeychainKey) throws {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            // Success or already absent — both are acceptable outcomes.
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Private

    /// Builds the minimum attribute dictionary that uniquely identifies one
    /// Keychain item for this app.
    ///
    /// - `kSecClass`:       We use generic passwords (username/password model).
    /// - `kSecAttrService`: The app's bundle ID scopes items to this app.
    /// - `kSecAttrAccount`: The `KeychainKey.rawValue` string distinguishes
    ///                      individual secrets within the service namespace.
    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
