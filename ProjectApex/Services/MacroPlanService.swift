// MacroPlanService.swift
// ProjectApex — Services
//
// FB-008: Part 1 of the dynamic programme architecture.
//
// MacroPlanService is a one-shot Sonnet call that generates a 12-week
// SKELETON — phase names, weekly intent labels, day-focus strings, and
// volume landmarks. It produces NO individual exercises or weights.
//
// The skeleton is the structural backbone that:
//   • Determines which muscle groups train on which days of the week
//   • Labels each week ("Week 3 — High Volume Accumulation")
//   • Sets volume landmarks that vary across phases (no two consecutive
//     weeks have identical landmarks)
//
// Individual sessions are then generated on-demand by SessionPlanService
// immediately before each workout, using full lift history from RAG memory.
//
// ISOLATION NOTE: All DTO types are `nonisolated` (target: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

import Foundation

// MARK: - MacroPlanError

nonisolated enum MacroPlanError: LocalizedError {
    case systemPromptNotFound
    case encodingFailed(String)
    case llmProviderError(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .systemPromptNotFound:
            return "SystemPrompt_MacroPlan.txt not found in the app bundle."
        case .encodingFailed(let d):
            return "Failed to encode MacroPlan request: \(d)"
        case .llmProviderError(let d):
            return "LLM provider error during macro plan generation: \(d)"
        case .decodingFailed(let d):
            return "Failed to decode macro plan skeleton: \(d)"
        }
    }
}

// MARK: - Request DTOs

nonisolated struct MacroPlanRequest: Codable, Sendable {
    let userProfile: MacroPlanUserProfile
    let gymProfile: MacroPlanGymProfile
    let constraints: MacroPlanConstraints

    enum CodingKeys: String, CodingKey {
        case userProfile  = "user_profile"
        case gymProfile   = "gym_profile"
        case constraints
    }
}

nonisolated struct MacroPlanUserProfile: Codable, Sendable {
    let userId: String
    let experienceLevel: String
    let goals: [String]
    let bodyweightKg: Double?
    let ageYears: Int?
    let trainingAge: String?

    enum CodingKeys: String, CodingKey {
        case userId          = "user_id"
        case experienceLevel = "experience_level"
        case goals
        case bodyweightKg    = "bodyweight_kg"
        case ageYears        = "age_years"
        case trainingAge     = "training_age"
    }
}

nonisolated struct MacroPlanGymProfile: Codable, Sendable {
    let availableEquipment: [String]

    enum CodingKeys: String, CodingKey {
        case availableEquipment = "available_equipment"
    }

    init(from gymProfile: GymProfile) {
        self.availableEquipment = gymProfile.equipment.map { $0.equipmentType.typeKey }
    }
}

nonisolated struct MacroPlanConstraints: Codable, Sendable {
    let trainingDaysPerWeek: Int
    let totalWeeks: Int

    enum CodingKeys: String, CodingKey {
        case trainingDaysPerWeek = "training_days_per_week"
        case totalWeeks          = "total_weeks"
    }

    static let `default` = MacroPlanConstraints(trainingDaysPerWeek: 4, totalWeeks: 12)
}

// MARK: - Response DTOs

/// One week in the skeleton response from the LLM.
nonisolated struct SkeletonWeek: Codable, Sendable {
    let weekNumber: Int
    let phase: MesocyclePhase
    let weekLabel: String
    let dayFocus: [String]
    let volumeLandmark: Double

    enum CodingKeys: String, CodingKey {
        case weekNumber     = "week_number"
        case phase
        case weekLabel      = "week_label"
        case dayFocus       = "day_focus"
        case volumeLandmark = "volume_landmark"
    }
}

nonisolated struct MacroPlanSkeletonWrapper: Codable, Sendable {
    let macroPlan: MacroPlanSkeletonPayload

    enum CodingKeys: String, CodingKey {
        case macroPlan = "macro_plan"
    }
}

nonisolated struct MacroPlanSkeletonPayload: Codable, Sendable {
    let periodizationModel: String
    let trainingDaysPerWeek: Int
    let weeks: [SkeletonWeek]

    enum CodingKeys: String, CodingKey {
        case periodizationModel  = "periodization_model"
        case trainingDaysPerWeek = "training_days_per_week"
        case weeks
    }
}

// MARK: - MacroPlanService

/// Generates a 12-week mesocycle skeleton — phase structure, week intent labels,
/// and day-focus muscle groups — with no exercises or weights.
///
/// Called once at programme start. SessionPlanService generates the actual
/// session content on-demand before each workout.
actor MacroPlanService {

    private let provider: any LLMProvider
    private(set) var isGenerating: Bool = false

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    // MARK: - Public API

    /// Generates a MesocycleSkeleton for the given user and gym profile.
    func generateSkeleton(
        userId: UUID,
        gymProfile: GymProfile,
        experienceLevel: String = "intermediate",
        goals: [String] = ["hypertrophy"],
        bodyweightKg: Double? = nil,
        ageYears: Int? = nil,
        trainingAge: String? = nil,
        trainingDaysPerWeek: Int = 4
    ) async throws -> MesocycleSkeleton {
        isGenerating = true
        defer { isGenerating = false }

        let systemPrompt = try Self.loadSystemPrompt()

        print("[MacroPlanService] Generating macro skeleton — training_days_per_week: \(trainingDaysPerWeek)")

        let request = MacroPlanRequest(
            userProfile: MacroPlanUserProfile(
                userId: userId.uuidString,
                experienceLevel: experienceLevel,
                goals: goals,
                bodyweightKg: bodyweightKg,
                ageYears: ageYears,
                trainingAge: trainingAge
            ),
            gymProfile: MacroPlanGymProfile(from: gymProfile),
            constraints: MacroPlanConstraints(
                trainingDaysPerWeek: trainingDaysPerWeek,
                totalWeeks: 12
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let requestData = try? encoder.encode(request),
              let requestJSON = String(data: requestData, encoding: .utf8)
        else {
            throw MacroPlanError.encodingFailed("Failed to encode MacroPlanRequest.")
        }

        let payload = try await callAndDecodeSkeleton(
            systemPrompt: systemPrompt,
            userPayload: requestJSON
        )

        return buildSkeleton(from: payload, userId: userId)
    }

    // MARK: - Private: LLM call

    private func callAndDecodeSkeleton(
        systemPrompt: String,
        userPayload: String
    ) async throws -> MacroPlanSkeletonPayload {
        let rawResponse: String
        do {
            rawResponse = try await provider.complete(
                systemPrompt: systemPrompt,
                userPayload: userPayload
            )
        } catch {
            throw MacroPlanError.llmProviderError(error.localizedDescription)
        }

        let fenceStripped = Self.stripMarkdownFences(rawResponse)
        let extracted = Self.extractOutermostObject(fenceStripped) ?? fenceStripped

        guard let data = extracted.data(using: .utf8) else {
            throw MacroPlanError.decodingFailed("LLM response is not valid UTF-8.")
        }

        do {
            let wrapper = try JSONDecoder().decode(MacroPlanSkeletonWrapper.self, from: data)
            return wrapper.macroPlan
        } catch let err {
            print("[MacroPlanService] Decode failure. Raw response:\n\(rawResponse)")
            throw MacroPlanError.decodingFailed(
                "Skeleton decode failed: \(err.localizedDescription). Raw: \(String(extracted.prefix(400)))"
            )
        }
    }

    // MARK: - Private: Build MesocycleSkeleton

    private func buildSkeleton(
        from payload: MacroPlanSkeletonPayload,
        userId: UUID
    ) -> MesocycleSkeleton {
        let weekIntents = payload.weeks.map { sw in
            WeekIntent(
                weekLabel: sw.weekLabel,
                dayFocus: sw.dayFocus,
                volumeLandmark: sw.volumeLandmark
            )
        }

        return MesocycleSkeleton(
            id: UUID(),
            userId: userId,
            createdAt: Date(),
            isActive: true,
            trainingDaysPerWeek: payload.trainingDaysPerWeek,
            periodizationModel: payload.periodizationModel,
            weekIntents: weekIntents
        )
    }

    // MARK: - Build Mesocycle from Skeleton

    /// Converts a MesocycleSkeleton into a Mesocycle with TrainingDay stubs
    /// whose status is `.pending` — to be filled in by SessionPlanService.
    ///
    /// Each week gets `trainingDaysPerWeek` placeholder days. The day labels
    /// are derived from the skeleton's dayFocus strings.
    static func buildPendingMesocycle(
        from skeleton: MesocycleSkeleton,
        userId: UUID
    ) -> Mesocycle {
        let phaseMap: [(MesocyclePhase, ClosedRange<Int>)] = [
            (.accumulation,    1...4),
            (.intensification, 5...8),
            (.peaking,         9...11),
            (.deload,          12...12)
        ]

        func phase(for weekNumber: Int) -> MesocyclePhase {
            for (p, range) in phaseMap {
                if range.contains(weekNumber) { return p }
            }
            return .accumulation
        }

        var weeks: [TrainingWeek] = []
        for (index, intent) in skeleton.weekIntents.enumerated() {
            let weekNumber = index + 1
            let currentPhase = phase(for: weekNumber)

            // Build placeholder training days from day-focus strings.
            let days: [TrainingDay] = intent.dayFocus.enumerated().map { dayIndex, focus in
                // Assign standard ISO-weekday slots: Mon=1, Tue=2, Wed=3, Thu=4, ...
                let dayOfWeek = standardDayOfWeek(for: dayIndex, daysPerWeek: skeleton.trainingDaysPerWeek)
                let label = focus.replacingOccurrences(of: " ", with: "_")
                return TrainingDay(
                    id: UUID(),
                    dayOfWeek: dayOfWeek,
                    dayLabel: label,
                    exercises: [],
                    sessionNotes: nil,
                    status: .pending
                )
            }

            weeks.append(TrainingWeek(
                id: UUID(),
                weekNumber: weekNumber,
                phase: currentPhase,
                trainingDays: days,
                weekLabel: intent.weekLabel
            ))
        }

        return Mesocycle(
            id: UUID(),
            userId: userId,
            createdAt: Date(),
            isActive: true,
            weeks: weeks,
            totalWeeks: 12,
            periodizationModel: skeleton.periodizationModel
        )
    }

    /// Maps a 0-based day index to an ISO-8601 weekday integer (Mon=1..Sun=7)
    /// for common training frequencies.
    private static func standardDayOfWeek(for dayIndex: Int, daysPerWeek: Int) -> Int {
        // Common slots: Mon, Wed, Thu, Sat for 4-day; Mon, Wed, Fri for 3-day, etc.
        let slots4: [Int] = [1, 3, 4, 6]   // Mon, Wed, Thu, Sat
        let slots3: [Int] = [1, 3, 5]       // Mon, Wed, Fri
        let slots5: [Int] = [1, 2, 3, 5, 6] // Mon-Wed, Fri, Sat
        let slots6: [Int] = [1, 2, 3, 4, 5, 6]
        let slots2: [Int] = [1, 4]           // Mon, Thu

        let table: [Int: [Int]] = [2: slots2, 3: slots3, 4: slots4, 5: slots5, 6: slots6]
        let slots = table[daysPerWeek] ?? slots4
        guard dayIndex < slots.count else { return dayIndex + 1 }
        return slots[dayIndex]
    }

    // MARK: - Private: Helpers

    private static func loadSystemPrompt() throws -> String {
        if let url = Bundle.main.url(
            forResource: "SystemPrompt_MacroPlan",
            withExtension: "txt",
            subdirectory: "Prompts"
        ) ?? Bundle.main.url(
            forResource: "SystemPrompt_MacroPlan",
            withExtension: "txt"
        ) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw MacroPlanError.systemPromptNotFound
    }

    private static func stripMarkdownFences(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            }
        }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractOutermostObject(_ input: String) -> String? {
        guard let start = input.firstIndex(of: "{") else { return nil }
        var depth = 0; var inStr = false; var escaped = false
        var idx = start
        while idx < input.endIndex {
            let ch = input[idx]
            if escaped { escaped = false }
            else if ch == "\\" && inStr { escaped = true }
            else if ch == "\"" { inStr.toggle() }
            else if !inStr {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(input[start...idx]) }
                }
            }
            idx = input.index(after: idx)
        }
        return nil
    }
}
