// Config.swift
// ProjectApex — App Layer
//
// Non-secret build-time configuration values.
// API keys and other secrets belong in the Keychain (KeychainService),
// not here. This file only holds values that are safe to check into source
// control (e.g. project URLs, feature flags).
//
// To configure:
//   Replace the placeholder supabaseURL with your project's REST endpoint.
//   Format: "https://<project-ref>.supabase.co"

import Foundation

enum Config {
    /// Base URL for the Supabase project's REST/PostgREST endpoint.
    /// Replace with your project URL — this is not a secret.
    static let supabaseURL = URL(string: "https://your-project-ref.supabase.co")!
}
