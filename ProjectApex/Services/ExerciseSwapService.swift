// Services/ExerciseSwapService.swift
// ProjectApex
//
// Actor-isolated service that drives the multi-turn exercise swap chat.
// Each call to sendMessage() appends to a conversation history and sends the
// full context + history to the LLM in a single turn (LLMProvider is single-turn).
//
// Usage:
//   1. Call startConversation(context:) to build the opening message.
//   2. Call sendMessage(_:isChip:) for each user turn.
//   3. Read messages for display; check the latest message's suggestion field.
//   4. Call reset() when the sheet is dismissed.

import Foundation

// MARK: - ExerciseSwapService

actor ExerciseSwapService {

    // MARK: - Public types

    /// Snapshot of the workout state needed to drive the swap conversation.
    struct SwapContext: Codable, Sendable {
        /// Current exercise being replaced.
        let exerciseName: String
        /// Snake-case equipment key of the current exercise.
        let equipmentTypeKey: String
        /// Primary muscle of the current exercise.
        let primaryMuscle: String
        /// Number of sets completed before requesting swap.
        let setsCompleted: Int
        /// Total sets planned for this exercise.
        let totalSets: Int
        /// Equipment type keys currently in the user's gym.
        let availableEquipment: [String]
        /// Exercise IDs already completed this session (to avoid re-suggesting them).
        let completedExerciseIds: [String]
        /// Optional RAG memory snippets for the current exercise.
        let ragMemory: [String]
    }

    /// Structured suggestion returned by the LLM.
    struct ExerciseSuggestion: Codable, Sendable {
        let exerciseId: String
        let name: String
        let equipmentRequired: String
        let suggestedWeightKg: Double
        let suggestedReps: Int
        let reasoning: String

        enum CodingKeys: String, CodingKey {
            case exerciseId       = "exercise_id"
            case name
            case equipmentRequired = "equipment_required"
            case suggestedWeightKg = "suggested_weight_kg"
            case suggestedReps    = "suggested_reps"
            case reasoning
        }
    }

    // MARK: - Chat message model

    enum MessageRole: Sendable {
        case assistant
        case user
        case chip
    }

    struct ChatMessage: Identifiable, Sendable {
        let id: UUID
        let role: MessageRole
        /// Text shown in the chat bubble.
        let displayText: String
        /// Populated on assistant messages that contain a swap suggestion.
        let suggestion: ExerciseSuggestion?
        let timestamp: Date

        init(
            role: MessageRole,
            displayText: String,
            suggestion: ExerciseSuggestion? = nil
        ) {
            self.id = UUID()
            self.role = role
            self.displayText = displayText
            self.suggestion = suggestion
            self.timestamp = Date()
        }
    }

    // MARK: - State

    private(set) var messages: [ChatMessage] = []
    private(set) var isProcessing: Bool = false

    private var swapContext: SwapContext?
    /// Conversation history in the format expected for the LLM payload.
    private var conversationHistory: [(role: String, text: String)] = []

    private let provider: any LLMProvider

    private static let systemPrompt: String = {
        guard let url = Bundle.main.url(forResource: "SystemPrompt_ExerciseSwap", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return "You are an exercise swap assistant. Return JSON with display_message and optional suggestion."
        }
        // Strip comment lines, then append the canonical exercise library block
        let base = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base + ExerciseLibrary.promptReferenceBlock()
    }()

    // MARK: - Init

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Starts a fresh conversation with the opener message.
    func startConversation(context: SwapContext) async {
        reset()
        swapContext = context

        let setsLabel = context.setsCompleted == 1 ? "1 set" : "\(context.setsCompleted) sets"
        let opener = "I see you're on \(context.exerciseName) — \(setsLabel) done. What's the issue?"

        messages.append(ChatMessage(role: .assistant, displayText: opener))
        conversationHistory.append((role: "assistant", text: opener))
    }

    /// Sends a user message (typed or chip) and appends the assistant reply.
    func sendMessage(_ text: String, isChip: Bool = false) async {
        guard !isProcessing else { return }
        isProcessing = true

        let userRole: MessageRole = isChip ? .chip : .user
        messages.append(ChatMessage(role: userRole, displayText: text))
        conversationHistory.append((role: "user", text: text))

        do {
            let payload = buildPayload(userMessage: text)
            let raw = try await TransientRetryPolicy.execute {
                try await self.provider.complete(
                    systemPrompt: Self.systemPrompt,
                    userPayload: payload
                )
            }
            let (displayMessage, suggestion) = parseResponse(raw)
            let assistantMessage = ChatMessage(
                role: .assistant,
                displayText: displayMessage,
                suggestion: suggestion
            )
            messages.append(assistantMessage)
            conversationHistory.append((role: "assistant", text: displayMessage))
        } catch let urlError as URLError
          where urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
            let msg = "You appear to be offline. Please check your connection and try again."
            appendAssistantError(msg)
            FallbackLogRecord(
                callSite: FallbackLogRecord.exerciseSwapCallSite,
                reason: "offline: \(urlError.code.rawValue)"
            ).emit()
        } catch let llmError as LLMProviderError {
            let msg: String
            switch llmError {
            case .httpError(let status, _) where TransientRetryPolicy.transientCodes.contains(status):
                msg = "The AI service is temporarily busy. Please try again in a moment."
            default:
                msg = "Something went wrong. Please try again later."
            }
            appendAssistantError(msg)
            FallbackLogRecord.from(
                callSite: FallbackLogRecord.exerciseSwapCallSite,
                error: llmError
            ).emit()
        } catch {
            appendAssistantError("Something went wrong. Please try again later.")
            FallbackLogRecord(
                callSite: FallbackLogRecord.exerciseSwapCallSite,
                reason: error.localizedDescription
            ).emit()
        }

        isProcessing = false
    }

    /// Resets all state — call when the swap sheet is dismissed.
    func reset() {
        messages = []
        conversationHistory = []
        swapContext = nil
        isProcessing = false
    }

    // MARK: - Private: error helper

    private func appendAssistantError(_ text: String) {
        let msg = ChatMessage(role: .assistant, displayText: text)
        messages.append(msg)
        conversationHistory.append((role: "assistant", text: text))
    }

    // MARK: - Private: payload builder

    private func buildPayload(userMessage: String) -> String {
        var parts: [String] = []

        // Context block
        if let ctx = swapContext {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(ctx),
               let json = String(data: data, encoding: .utf8) {
                parts.append("SWAP_CONTEXT:\n\(json)")
            }
        }

        // Conversation history (all turns so far, excluding the current user message
        // since the LLM sees it as the latest user turn)
        let historyLines = conversationHistory.dropLast().map { "\($0.role.uppercased()): \($0.text)" }
        if !historyLines.isEmpty {
            parts.append("CONVERSATION_HISTORY:\n" + historyLines.joined(separator: "\n"))
        }

        parts.append("USER: \(userMessage)")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private: response parser

    private func parseResponse(_ raw: String) -> (String, ExerciseSuggestion?) {
        // Clean markdown fences
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let newline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: newline)...])
            }
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            return (raw, nil)
        }

        struct LLMResponse: Codable {
            let displayMessage: String
            let suggestion: ExerciseSuggestion?

            enum CodingKeys: String, CodingKey {
                case displayMessage = "display_message"
                case suggestion
            }
        }

        if let response = try? JSONDecoder().decode(LLMResponse.self, from: data) {
            return (response.displayMessage, response.suggestion)
        }

        // Fallback: return raw text, no suggestion
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}
