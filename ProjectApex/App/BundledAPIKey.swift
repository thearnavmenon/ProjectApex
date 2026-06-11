// BundledAPIKey.swift
// ProjectApex — App Layer
//
// Resolves build-time keys that ship in the app bundle so a FRESH INSTALL can
// reach external services (#329 / O-F1, #369 slice 2).
//
// Mechanism (no secret in git):
//   APIKeys.local.xcconfig (gitignored) defines the real values; the committed
//   APIKeys.xcconfig optionally includes it and otherwise holds the placeholders.
//   The build expands the variables into Info.plist, and this type reads them
//   back at runtime. When the local file is absent (clean checkout / CI), the
//   values stay at the placeholder and the accessors return nil — never a compile
//   error.

import Foundation

/// Reads build-time bundled API keys from the app's Info dictionary.
///
/// `lookup` is injectable so tests can stand in a fake Info.plist without touching
/// the real bundle. Production callers use the default, which reads `Bundle.main`.
enum BundledAPIKey {

    /// Placeholder shipped in `APIKeys.xcconfig.example`. Treated as "no key" so a
    /// developer who copied the template but never filled it in still hits the gate
    /// rather than sending `REPLACE_ME` to the API.
    static let placeholder = "REPLACE_ME"

    // MARK: - Anthropic

    /// The Info.plist key the build configuration writes `$(ANTHROPIC_API_KEY)` into.
    static let infoPlistKey = "APEXAnthropicAPIKey"

    /// The resolved bundled Anthropic key, or `nil` when none was baked into the build.
    ///
    /// Returns `nil` for an absent entry, an empty/whitespace value (missing xcconfig),
    /// or the untouched placeholder. The key value is never logged.
    static func anthropic(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) -> String? {
        resolve(key: infoPlistKey, lookup: lookup)
    }

    // MARK: - Supabase anon key

    /// The Info.plist key the build configuration writes `$(SUPABASE_ANON_KEY)` into.
    static let supabaseAnonInfoPlistKey = "APEXSupabaseAnonKey"

    /// The resolved bundled Supabase anon key, or `nil` when none was baked into the build.
    ///
    /// The anon key is a public client credential (safe to ship in the bundle), but it
    /// goes through the same placeholder mechanism as the Anthropic key for consistency
    /// so a fresh checkout without a local override never sends a dummy value.
    static func supabaseAnon(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) -> String? {
        resolve(key: supabaseAnonInfoPlistKey, lookup: lookup)
    }

    // MARK: - Private

    private static func resolve(key: String, lookup: (String) -> Any?) -> String? {
        guard let raw = lookup(key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != placeholder else { return nil }
        return trimmed
    }
}
