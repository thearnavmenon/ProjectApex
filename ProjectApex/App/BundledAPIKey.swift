// BundledAPIKey.swift
// ProjectApex — App Layer
//
// Resolves the build-time alpha Anthropic key that ships in the app bundle so a
// FRESH INSTALL can complete onboarding (#329 / O-F1). Before this, the only way
// to populate the Anthropic Keychain entry was the DEBUG-only DeveloperSettingsView,
// which sits behind the onboarding gate — so a clean install died with raw HTTP
// errors mid-gym-scan.
//
// Mechanism (no secret in git):
//   APIKeys.local.xcconfig (gitignored) defines ANTHROPIC_API_KEY; the committed
//   APIKeys.xcconfig optionally includes it and otherwise holds the placeholder.
//   The build expands ${ANTHROPIC_API_KEY} into Info.plist (key APEXAnthropicAPIKey),
//   and this type reads it back at runtime. When the local file is absent (clean
//   checkout / CI), the value stays the placeholder and `anthropic` returns nil —
//   never a compile error.
//
// One key, two consumers: the gym scan (VisionAPIService) and program generation
// both read the same `.anthropicAPIKey` Keychain entry, so seeding this one value
// unblocks both failing onboarding steps.

import Foundation

/// Reads the build-time bundled Anthropic key from the app's Info dictionary.
///
/// `lookup` is injectable so tests can stand in a fake Info.plist without touching
/// the real bundle. Production callers use the default, which reads `Bundle.main`.
enum BundledAPIKey {

    /// The Info.plist key the build configuration writes `$(ANTHROPIC_API_KEY)` into.
    static let infoPlistKey = "APEXAnthropicAPIKey"

    /// Placeholder shipped in `APIKeys.xcconfig.example`. Treated as "no key" so a
    /// developer who copied the template but never filled it in still hits the gate
    /// rather than sending `REPLACE_ME` to the API.
    static let placeholder = "REPLACE_ME"

    /// The resolved bundled Anthropic key, or `nil` when none was baked into the build.
    ///
    /// Returns `nil` for an absent entry, an empty/whitespace value (missing xcconfig),
    /// or the untouched placeholder. The key value is never logged.
    static func anthropic(
        lookup: (String) -> Any? = { Bundle.main.object(forInfoDictionaryKey: $0) }
    ) -> String? {
        guard let raw = lookup(infoPlistKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != placeholder else { return nil }
        return trimmed
    }
}
