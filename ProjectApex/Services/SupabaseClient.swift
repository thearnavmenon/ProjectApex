// SupabaseClient.swift
// ProjectApex — Services
//
// Stub implementation. Full CRUD and RPC wrapper implemented in P1-T01.
// Provides the type so AppDependencies compiles at launch.

import Foundation

/// Thin wrapper around the Supabase PostgREST HTTP API.
/// Fully implemented in P1-T01.
final class SupabaseClient: @unchecked Sendable {

    let anonKey: String

    init(anonKey: String) {
        self.anonKey = anonKey
    }
}
