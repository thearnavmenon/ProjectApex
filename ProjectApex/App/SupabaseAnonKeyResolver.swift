// SupabaseAnonKeyResolver.swift
// ProjectApex — App Layer
//
// Single source of truth for "which Supabase anon key does this install use, and
// is there one at all?" (#369 slice 2).
//
// Precedence (mirrors AnthropicKeyResolver, locked by the issue):
//   1. Keychain value      — the dev path (DeveloperSettingsView) stays working untouched.
//   2. Bundled Info.plist  — the alpha key baked into the build; seeded into the
//                            Keychain so the rest of the app reads it the usual way.
//   3. nil                 — no key anywhere → the launch gate (NeedsSetupView).
//
// Factored out of AppDependencies.init so the precedence logic is unit-testable
// with injected Keychain + bundled lookups (no real Keychain, no real bundle).

import Foundation

enum SupabaseAnonKeyResolver {

    /// Resolves the Supabase anon key using the locked precedence, seeding the bundled
    /// key into the Keychain on the fallback path so every existing consumer keeps
    /// reading `.supabaseAnonKey` from the Keychain exactly as before.
    ///
    /// - Parameters:
    ///   - retrieve: Reads the current Keychain value for `.supabaseAnonKey`.
    ///   - store: Writes a value into the Keychain for `.supabaseAnonKey` (used to
    ///            seed the bundled key). Failures are swallowed — a seed failure
    ///            must not crash launch; the caller still receives the resolved key.
    ///   - bundled: Returns the build-time bundled key, or nil when none was baked in.
    /// - Returns: The resolved key, or `nil` when neither source supplies one.
    static func resolve(
        retrieve: () -> String?,
        store: (String) -> Void,
        bundled: () -> String?
    ) -> String? {
        // 1. Existing Keychain value wins — never overwrite the dev-entered key.
        if let existing = retrieve(), !existing.isEmpty {
            return existing
        }
        // 2. Bundled key — seed it into the Keychain, then use it.
        if let bundledKey = bundled(), !bundledKey.isEmpty {
            store(bundledKey)
            return bundledKey
        }
        // 3. Nothing anywhere.
        return nil
    }
}
