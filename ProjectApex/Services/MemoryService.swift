// MemoryService.swift
// ProjectApex — Services
//
// Stub implementation. Embedding pipeline write path (P4-T04) and
// RAG retrieval read path (P4-T05) are implemented in later phases.

import Foundation

/// Manages the RAG memory embedding pipeline.
/// Fully implemented in P4-T04 / P4-T05.
final class MemoryService: @unchecked Sendable {

    private let supabase: SupabaseClient
    private let embeddingAPIKey: String

    init(supabase: SupabaseClient, embeddingAPIKey: String) {
        self.supabase = supabase
        self.embeddingAPIKey = embeddingAPIKey
    }
}
