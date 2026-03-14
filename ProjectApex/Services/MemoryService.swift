// MemoryService.swift
// ProjectApex — Services
//
// Embedding pipeline write path (P4-T04).
//
// Architecture (TDD §9.1 / §9.2):
//   • Swift actor — actor-isolated state, safe from concurrent writes.
//   • embed() is a fire-and-forget entry point: callers dispatch via
//     Task.detached and do not await the result.
//   • Pipeline:
//       1. Tag classification via Anthropic claude-haiku-4-5-20251001 (5 s timeout)
//          → extracts muscle_groups, tags, sentiment
//          → injects "injury_concern" if pain keywords found
//       2. POST to OpenAI embeddings API (text-embedding-3-small, 1536-dim)
//       3. Upsert to memory_embeddings via SupabaseClient
//
// Pain keywords (from ARCHITECTURE.md):
//   ["pain","hurt","tweaky","clicking","popping","tight","impinged","pulling","straining","sore"]
//
// Performance target (TDD §9.4): p99 embed write < 5 s.
//
// Read path (P4-T05) is a separate task and not implemented here.

import Foundation

// MARK: - MemoryServiceError

enum MemoryServiceError: LocalizedError {
    case missingAPIKey
    case embeddingAPIError(String)
    case tagClassificationError(String)
    case supabaseWriteError(String)
    case unexpectedEmbeddingDimension(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is required for embedding."
        case .embeddingAPIError(let d):
            return "Embedding API error: \(d)"
        case .tagClassificationError(let d):
            return "Tag classification error: \(d)"
        case .supabaseWriteError(let d):
            return "Supabase write error: \(d)"
        case .unexpectedEmbeddingDimension(let n):
            return "Expected 1536-dim embedding, got \(n)."
        }
    }
}

// MARK: - MemoryEmbeddingRow

/// Codable row matching the `memory_embeddings` Supabase table schema.
nonisolated struct MemoryEmbeddingRow: Encodable {
    let userId: String
    let sessionId: String?
    let exerciseId: String?
    let muscleGroups: [String]
    let tags: [String]
    let rawTranscript: String
    let embedding: [Float]
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case userId        = "user_id"
        case sessionId     = "session_id"
        case exerciseId    = "exercise_id"
        case muscleGroups  = "muscle_groups"
        case tags
        case rawTranscript = "raw_transcript"
        case embedding
        case metadata
    }
}

// MARK: - TagClassificationResult

private struct TagClassificationResult {
    let muscleGroups: [String]
    let tags: [String]
    let sentiment: String
}

// MARK: - MemoryService

/// Actor that owns the RAG memory embedding pipeline.
///
/// Usage:
/// ```swift
/// Task.detached {
///     await memoryService.embed(
///         text: transcript,
///         sessionId: session.id.uuidString,
///         exerciseId: exerciseId,
///         muscleGroups: ["pectoralis_major"],
///         userId: userId.uuidString
///     )
/// }
/// ```
actor MemoryService {

    // MARK: - Configuration

    /// Pain keywords (ARCHITECTURE.md §9.3) — if any are present the embed
    /// gains an "injury_concern" tag.
    static let painKeywords: Set<String> = [
        "pain", "hurt", "tweaky", "clicking", "popping",
        "tight", "impinged", "pulling", "straining", "sore"
    ]

    /// Anthropic Haiku model used for tag classification (ARCHITECTURE.md §8.4).
    private static let haikuModel = "claude-haiku-4-5-20251001"

    /// OpenAI embeddings model (ARCHITECTURE.md §9.1).
    private static let embeddingModel = "text-embedding-3-small"

    /// Expected embedding dimensionality.
    private static let embeddingDimension = 1536

    /// Timeout for the tag-classification call.
    private static let classificationTimeoutSeconds: TimeInterval = 5

    // MARK: - Dependencies

    private let supabase: SupabaseClient
    private let embeddingAPIKey: String   // OpenAI key
    private let anthropicAPIKey: String?  // Anthropic key for tag classification
    private let urlSession: URLSession

    // MARK: - Init

    /// - Parameters:
    ///   - supabase: SupabaseClient for writing `memory_embeddings` rows.
    ///   - embeddingAPIKey: OpenAI API key for `text-embedding-3-small`.
    ///   - anthropicAPIKey: Anthropic API key for Haiku tag classification.
    ///     Pass `nil` to skip AI tag classification (pain-keyword detection
    ///     still runs using local heuristics).
    ///   - urlSession: Injected for testing; defaults to `.shared`.
    init(
        supabase: SupabaseClient,
        embeddingAPIKey: String,
        anthropicAPIKey: String? = nil,
        urlSession: URLSession = .shared
    ) {
        self.supabase = supabase
        self.embeddingAPIKey = embeddingAPIKey
        self.anthropicAPIKey = anthropicAPIKey
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Embeds `text` and writes the result to `memory_embeddings`.
    ///
    /// This method is designed to be called from a `Task.detached` context so
    /// it never blocks the workout loop. All errors are swallowed internally;
    /// the caller does not observe failures.
    ///
    /// Pipeline:
    ///   1. Detect pain keywords (local, synchronous)
    ///   2. Tag classification via Haiku (async, 5 s timeout) — skipped when `tags` is non-empty
    ///   3. Embed text via OpenAI (async)
    ///   4. Upsert row to Supabase (async)
    ///
    /// - Parameters:
    ///   - tags: Pre-classified tags (e.g. from auto-event taxonomy). When non-empty,
    ///     the Haiku classification step is skipped and these tags are used directly,
    ///     saving a round-trip. Pain-keyword injection still applies on top.
    func embed(
        text: String,
        sessionId: String? = nil,
        exerciseId: String? = nil,
        tags: [String] = [],
        muscleGroups: [String] = [],
        userId: String
    ) async {
        do {
            try await embedThrowing(
                text: text,
                sessionId: sessionId,
                exerciseId: exerciseId,
                preclassifiedTags: tags,
                muscleGroups: muscleGroups,
                userId: userId
            )
        } catch {
            // Non-blocking: log and discard errors so workout loop is never disrupted
#if DEBUG
            print("[MemoryService] embed failed: \(error.localizedDescription)")
#endif
        }
    }

    /// Overload matching the legacy `embed(text:metadata:)` signature used by
    /// `WorkoutSessionManager.addVoiceNote` before P4-T04.
    ///
    /// Parses known keys from `metadata`:
    ///   - `"session_id"`, `"exercise_id"`, `"user_id"`, `"muscle_groups"` (comma-separated)
    ///   - `"tags"` (comma-separated, treated as pre-classified tags)
    func embed(text: String, metadata: [String: String]) async {
        let preclassifiedTags = (metadata["tags"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        await embed(
            text: text,
            sessionId: metadata["session_id"],
            exerciseId: metadata["exercise_id"],
            tags: preclassifiedTags,
            muscleGroups: (metadata["muscle_groups"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            userId: metadata["user_id"] ?? ""
        )
    }

    // MARK: - Throwing implementation

    func embedThrowing(
        text: String,
        sessionId: String?,
        exerciseId: String?,
        preclassifiedTags: [String] = [],
        muscleGroups: [String],
        userId: String
    ) async throws {
        guard !embeddingAPIKey.isEmpty else {
            throw MemoryServiceError.missingAPIKey
        }

        // 1. Local pain-keyword detection
        let hasPainKeyword = Self.containsPainKeyword(text)

        // 2. Tag classification (Haiku) — skipped when pre-classified tags are provided,
        //    saving a network round-trip for auto-generated taxonomy events.
        var classifiedTags: [String] = preclassifiedTags
        var classifiedMuscles: [String] = muscleGroups

        if preclassifiedTags.isEmpty, let anthropicKey = anthropicAPIKey, !anthropicKey.isEmpty {
            if let result = try? await classifyTagsWithTimeout(text: text, apiKey: anthropicKey) {
                classifiedTags = result.tags
                if !result.muscleGroups.isEmpty {
                    classifiedMuscles = result.muscleGroups
                }
            }
        }

        // Inject injury_concern if pain keyword detected
        if hasPainKeyword && !classifiedTags.contains("injury_concern") {
            classifiedTags.insert("injury_concern", at: 0)
        }

        // 3. Embed text via OpenAI
        let vector = try await fetchEmbedding(text: text, apiKey: embeddingAPIKey)
        guard vector.count == Self.embeddingDimension else {
            throw MemoryServiceError.unexpectedEmbeddingDimension(vector.count)
        }

        // 4. Upsert to memory_embeddings
        let row = MemoryEmbeddingRow(
            userId: userId,
            sessionId: sessionId,
            exerciseId: exerciseId,
            muscleGroups: classifiedMuscles,
            tags: classifiedTags,
            rawTranscript: text,
            embedding: vector,
            metadata: nil
        )

        do {
            try await supabase.insert(row, table: "memory_embeddings")
        } catch {
            throw MemoryServiceError.supabaseWriteError(error.localizedDescription)
        }
    }

    // MARK: - RAG Read Path

    /// Retrieves the top-K memory items most semantically relevant to `queryText`
    /// for the given `userId`.
    ///
    /// Used by `WorkoutSessionManager.fetchRAGMemory` before each set prescription.
    ///
    /// - Parameters:
    ///   - queryText: The query to embed (e.g. "Barbell Bench Press pectoralis_major").
    ///   - userId: The authenticated user's UUID string.
    ///   - threshold: Minimum cosine similarity (default 0.75 per TDD §9.2).
    ///   - count: Maximum items to return (default 3 per TDD §9.2).
    /// - Returns: Array of `RAGMemoryItem` sorted by similarity descending.
    func retrieveMemory(
        queryText: String,
        userId: String,
        threshold: Double = 0.75,
        count: Int = 3
    ) async -> [RAGMemoryItem] {
        guard !embeddingAPIKey.isEmpty else { return [] }
        do {
            let queryVector = try await fetchEmbedding(text: queryText, apiKey: embeddingAPIKey)
            return try await callMatchRPC(
                queryEmbedding: queryVector,
                userId: userId,
                threshold: threshold,
                count: count
            )
        } catch {
#if DEBUG
            print("[MemoryService] retrieveMemory failed: \(error.localizedDescription)")
#endif
            return []
        }
    }

    // MARK: - Private: Tag Classification

    private func classifyTagsWithTimeout(
        text: String,
        apiKey: String
    ) async throws -> TagClassificationResult {
        try await withThrowingTaskGroup(of: TagClassificationResult.self) { group in
            group.addTask {
                try await self.classifyTags(text: text, apiKey: apiKey)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.classificationTimeoutSeconds * 1_000_000_000))
                throw MemoryServiceError.tagClassificationError("Timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func classifyTags(text: String, apiKey: String) async throws -> TagClassificationResult {
        let systemPrompt = """
        You are a sports science tag extractor. Given a gym voice note, return ONLY valid JSON with:
        {
          "muscle_groups": ["snake_case muscle names"],
          "tags": ["relevant_tags"],
          "sentiment": "positive|neutral|negative"
        }
        Tags must be chosen from: injury_concern, fatigue, performance_drop, pr_achieved, motivation_high, motivation_low, energy_high, energy_low, general.
        Never include markdown or explanation — only the JSON object.
        """

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": Self.haikuModel,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MemoryServiceError.tagClassificationError("HTTP \(code): \(bodyStr.prefix(200))")
        }

        // Extract text content from Anthropic envelope
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArray = json["content"] as? [[String: Any]],
            let firstBlock = contentArray.first(where: { $0["type"] as? String == "text" }),
            let rawText = firstBlock["text"] as? String
        else {
            throw MemoryServiceError.tagClassificationError("Unexpected Anthropic response format.")
        }

        // Strip markdown fences
        let stripped = stripMarkdownFences(rawText)

        guard
            let responseData = stripped.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw MemoryServiceError.tagClassificationError("Could not parse tag classification JSON.")
        }

        let muscles = (parsed["muscle_groups"] as? [String]) ?? []
        let tags = (parsed["tags"] as? [String]) ?? []
        let sentiment = (parsed["sentiment"] as? String) ?? "neutral"

        return TagClassificationResult(muscleGroups: muscles, tags: tags, sentiment: sentiment)
    }

    // MARK: - Private: OpenAI Embeddings

    private func fetchEmbedding(text: String, apiKey: String) async throws -> [Float] {
        let url = URL(string: "https://api.openai.com/v1/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": Self.embeddingModel,
            "input": text
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MemoryServiceError.embeddingAPIError("HTTP \(code): \(bodyStr.prefix(200))")
        }

        // OpenAI envelope: {"data": [{"embedding": [float, ...], ...}]}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataArray = json["data"] as? [[String: Any]],
            let firstItem = dataArray.first,
            let embedding = firstItem["embedding"] as? [Double]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw MemoryServiceError.embeddingAPIError("Unexpected response format: \(raw.prefix(200))")
        }

        return embedding.map { Float($0) }
    }

    // MARK: - Private: RAG RPC

    private struct MatchParams: Encodable {
        let queryEmbedding: [Float]
        let pUserId: String
        let matchThreshold: Double
        let matchCount: Int

        enum CodingKeys: String, CodingKey {
            case queryEmbedding = "query_embedding"
            case pUserId        = "p_user_id"
            case matchThreshold = "match_threshold"
            case matchCount     = "match_count"
        }
    }

    private struct MatchRow: Decodable {
        let id: String
        let rawTranscript: String
        let tags: [String]?
        let createdAt: String
        let similarity: Double

        enum CodingKeys: String, CodingKey {
            case id
            case rawTranscript = "raw_transcript"
            case tags
            case createdAt     = "created_at"
            case similarity
        }
    }

    private func callMatchRPC(
        queryEmbedding: [Float],
        userId: String,
        threshold: Double,
        count: Int
    ) async throws -> [RAGMemoryItem] {
        let params = MatchParams(
            queryEmbedding: queryEmbedding,
            pUserId: userId,
            matchThreshold: threshold,
            matchCount: count
        )
        let rows: [MatchRow] = try await supabase.rpc(
            "match_memory_embeddings",
            params: params,
            returning: [MatchRow].self
        )
        return rows.map { row in
            RAGMemoryItem(
                relevanceScore: row.similarity,
                summary: row.rawTranscript,
                sourceDate: ISO8601DateFormatter().date(from: row.createdAt)
            )
        }
    }

    // MARK: - Private: Helpers

    /// Returns `true` if `text` contains any pain keyword (case-insensitive).
    static func containsPainKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return painKeywords.contains { lower.contains($0) }
    }

    private func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            if let newlineRange = result.range(of: "\n") {
                result = String(result[newlineRange.upperBound...])
            }
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
