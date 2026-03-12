// ProgramGenerationService.swift
// ProjectApex — Services
//
// Generates a fully-structured 12-week periodized mesocycle by sending the
// user profile and gym profile to the Anthropic LLM and decoding the response.
//
// Key design decisions:
//   • Swift actor — safe concurrent state; only one generation runs at a time.
//   • No timeout — the user explicitly waits; generation may take 30–90 seconds.
//     A progress message "Building your 12-week program…" is shown via isGenerating.
//   • Uses claude-opus-4-20250514 per TDD specification (P2-T02).
//   • System prompt loaded from Resources/Prompts/SystemPrompt_MacroGeneration.txt.
//   • Response decoded through MesocycleWrapper: { "mesocycle": Mesocycle }.
//   • Decode failure throws ProgramGenerationError.decodingFailed with detail string.
//
// ISOLATION NOTE:
// All DTO types are `nonisolated` so their Codable conformances work from
// this background actor (target has SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

import Foundation

// MARK: - ProgramGenerationError

nonisolated enum ProgramGenerationError: LocalizedError {
    case systemPromptNotFound
    case encodingFailed(String)
    case llmProviderError(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .systemPromptNotFound:
            return "SystemPrompt_MacroGeneration.txt not found in the app bundle."
        case .encodingFailed(let detail):
            return "Failed to encode the program request: \(detail)"
        case .llmProviderError(let detail):
            return "LLM provider error during program generation: \(detail)"
        case .decodingFailed(let detail):
            return "Failed to decode the generated program: \(detail)"
        }
    }
}

// MARK: - MacroProgramRequest

/// The JSON payload sent to the LLM for program generation.
nonisolated struct MacroProgramRequest: Codable, Sendable {
    let userProfile: UserProfile
    let gymProfile: GymProfilePayload
    let programmingConstraints: ProgrammingConstraints

    enum CodingKeys: String, CodingKey {
        case userProfile            = "user_profile"
        case gymProfile             = "gym_profile"
        case programmingConstraints = "programming_constraints"
    }
}

/// Minimal user profile fields needed by the program generation prompt.
nonisolated struct UserProfile: Codable, Sendable {
    let userId: String
    /// E.g. "beginner", "intermediate", "advanced"
    let experienceLevel: String
    /// E.g. ["hypertrophy", "strength", "fat_loss"]
    let goals: [String]
    let bodyweightKg: Double?
    let ageYears: Int?

    enum CodingKeys: String, CodingKey {
        case userId          = "user_id"
        case experienceLevel = "experience_level"
        case goals
        case bodyweightKg    = "bodyweight_kg"
        case ageYears        = "age_years"
    }
}

/// Slim GymProfile representation used in the macro-program request payload.
/// Lists available equipment type keys so the LLM can constrain exercise selection.
nonisolated struct GymProfilePayload: Codable, Sendable {
    /// Snake-case equipment type keys, e.g. ["barbell", "dumbbell_set", "cable_machine_single"]
    let availableEquipment: [String]

    enum CodingKeys: String, CodingKey {
        case availableEquipment = "available_equipment"
    }

    init(from gymProfile: GymProfile) {
        self.availableEquipment = gymProfile.equipment.map { $0.equipmentType.typeKey }
    }
}

/// Constraints that shape the structure of the generated program.
nonisolated struct ProgrammingConstraints: Codable, Sendable {
    /// Number of training sessions per week (default 4).
    let trainingDaysPerWeek: Int
    /// Total number of weeks in the program (always 12 for a mesocycle).
    let totalWeeks: Int
    /// Periodization model to use, e.g. "linear_periodization".
    let periodizationModel: String

    enum CodingKeys: String, CodingKey {
        case trainingDaysPerWeek = "training_days_per_week"
        case totalWeeks          = "total_weeks"
        case periodizationModel  = "periodization_model"
    }

    static let `default` = ProgrammingConstraints(
        trainingDaysPerWeek: 4,
        totalWeeks: 12,
        periodizationModel: "linear_periodization"
    )
}

// MARK: - MesocycleWrapper

/// Decodes the { "mesocycle": Mesocycle } envelope from the LLM response.
nonisolated struct MesocycleWrapper: Codable {
    let mesocycle: Mesocycle
}

// MARK: - ProgramGenerationService

/// Generates a 12-week periodized training program via the Anthropic LLM.
///
/// Usage:
/// ```swift
/// let service = ProgramGenerationService(provider: AnthropicProvider(apiKey: key))
/// let mesocycle = try await service.generate(userProfile: profile, gymProfile: gymProfile)
/// ```
actor ProgramGenerationService {

    // MARK: Dependencies

    private let provider: any LLMProvider

    // MARK: Observable progress state

    /// True while a generation request is in-flight.
    /// Bind this to a SwiftUI progress indicator: "Building your 12-week program..."
    private(set) var isGenerating: Bool = false

    // MARK: Init

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    // MARK: Public API

    /// Generates and returns a fully-structured `Mesocycle` from the LLM.
    ///
    /// - Parameters:
    ///   - userProfile: The user's training background, goals, and physical stats.
    ///   - gymProfile:  The scanned gym equipment profile.
    /// - Returns: A decoded `Mesocycle` with 12 weeks and the correct phase structure.
    /// - Throws: `ProgramGenerationError` on prompt load failure, encoding failure,
    ///           LLM error, or JSON decode failure.
    func generate(userProfile: UserProfile, gymProfile: GymProfile) async throws -> Mesocycle {
        isGenerating = true
        defer { isGenerating = false }

        // 1. Load system prompt from bundle
        let systemPrompt = try Self.loadSystemPrompt()

        // 2. Build request payload
        let request = MacroProgramRequest(
            userProfile: userProfile,
            gymProfile: GymProfilePayload(from: gymProfile),
            programmingConstraints: .default
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let requestData = try? encoder.encode(request),
              let requestJSON = String(data: requestData, encoding: .utf8)
        else {
            throw ProgramGenerationError.encodingFailed("Failed to encode MacroProgramRequest.")
        }

        // 3. Call LLM — no timeout; user explicitly waits
        let rawResponse: String
        do {
            rawResponse = try await provider.complete(
                systemPrompt: systemPrompt,
                userPayload: requestJSON
            )
        } catch {
            throw ProgramGenerationError.llmProviderError(error.localizedDescription)
        }

        // 4. Strip markdown fences if present
        let stripped = Self.stripMarkdownFences(rawResponse)

        // 5. Decode { "mesocycle": Mesocycle }
        guard let responseData = stripped.data(using: .utf8) else {
            throw ProgramGenerationError.decodingFailed(
                "LLM response could not be converted to UTF-8 data."
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let wrapper = try decoder.decode(MesocycleWrapper.self, from: responseData)
            return wrapper.mesocycle
        } catch let decodingError {
            let raw = stripped.prefix(500)
            throw ProgramGenerationError.decodingFailed(
                "JSON decode failed: \(decodingError.localizedDescription). Raw: \(raw)"
            )
        }
    }

    // MARK: - Private: System Prompt

    private static func loadSystemPrompt() throws -> String {
        if let url = Bundle.main.url(
            forResource: "SystemPrompt_MacroGeneration",
            withExtension: "txt",
            subdirectory: "Prompts"
        ) ?? Bundle.main.url(
            forResource: "SystemPrompt_MacroGeneration",
            withExtension: "txt"
        ) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw ProgramGenerationError.systemPromptNotFound
    }

    // MARK: - Private: Markdown fence stripping

    private static func stripMarkdownFences(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let newline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: newline)...])
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AnthropicProvider convenience: opus model

extension AnthropicProvider {
    /// Convenience initialiser that configures the provider with the
    /// `claude-opus-4-20250514` model required for macro program generation.
    /// The URLSession timeout is left at default (30 s per request cycle)
    /// but the service itself imposes no end-to-end timeout — the user waits.
    static func forProgramGeneration(apiKey: String) -> AnthropicProvider {
        AnthropicProvider(apiKey: apiKey, model: "claude-opus-4-20250514")
    }
}
