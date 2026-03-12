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

    /// Stub — embedding write path is implemented in P4-T04.
    /// Queued via Task.detached from WorkoutSessionManager; safe to no-op here.
    func embed(text: String, metadata: [String: String]) async {
        // Full implementation: P4-T04
        // 1. Tag classification (Haiku)
        // 2. POST to OpenAI embeddings API
        // 3. Upsert to memory_embeddings (Supabase)
    }
}
