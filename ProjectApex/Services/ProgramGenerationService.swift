// ProgramGenerationService.swift
// ProjectApex — Services
//
// Generates a 12-week periodized mesocycle using a two-stage pipeline:
//
//   STAGE 1 — LLM (Sonnet, ~8k output tokens, ~15–25s):
//     Generates 4 phase-template training weeks (accumulation, intensification,
//     peaking, deload). One representative week per phase.
//
//   STAGE 2 — Client expansion (instant, deterministic):
//     Expands the 4 templates into all 12 weeks by repeating each template week
//     within its phase and applying progressive overload increments per week.
//
// Progressive overload rules applied client-side:
//   • Accumulation (wks 1–4): sets += floor(weekInPhase/2), rirTarget stays constant
//   • Intensification (wks 5–8): rirTarget decreases by 1 every 2 weeks
//   • Peaking (wks 9–11): rirTarget decreases by 1 per week (min 0)
//   • Deload (wk 12): no changes; template repeated as-is
//
// ISOLATION NOTE:
// All DTO types are `nonisolated` so their Codable conformances work from
// this background actor (target has SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).

import Foundation

// MARK: - EquipmentViolation

/// A single exercise that requires equipment absent from the user's gym profile.
nonisolated struct EquipmentViolation: Sendable, Equatable {
    let exerciseId: String
    let exerciseName: String
    let weekNumber: Int
    let requiredEquipment: EquipmentType
}

// MARK: - ProgramGenerationError

nonisolated enum ProgramGenerationError: LocalizedError {
    case systemPromptNotFound
    case encodingFailed(String)
    case llmProviderError(String)
    case decodingFailed(String)
    case equipmentConstraintViolation([EquipmentViolation])

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
        case .equipmentConstraintViolation(let violations):
            let names = violations.map { "\($0.exerciseName) (week \($0.weekNumber))" }.joined(separator: ", ")
            return "Program contains equipment violations that could not be corrected: \(names)"
        }
    }
}

// MARK: - Request DTOs

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

nonisolated struct UserProfile: Codable, Sendable {
    let userId: String
    let experienceLevel: String
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

nonisolated struct GymProfilePayload: Codable, Sendable {
    let availableEquipment: [String]

    enum CodingKeys: String, CodingKey {
        case availableEquipment = "available_equipment"
    }

    init(from gymProfile: GymProfile) {
        self.availableEquipment = gymProfile.equipment.map { $0.equipmentType.typeKey }
    }
}

nonisolated struct ProgrammingConstraints: Codable, Sendable {
    let trainingDaysPerWeek: Int
    let totalWeeks: Int
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

// MARK: - Template Response DTOs

/// One exercise within a phase template (no UUIDs — client assigns them on expansion).
nonisolated struct TemplateExercise: Codable, Sendable {
    let exerciseId: String
    let name: String
    let primaryMuscle: String
    let synergists: [String]
    let equipmentRequired: EquipmentType
    let sets: Int
    let repRange: RepRange
    let tempo: String
    let restSeconds: Int
    let rirTarget: Int
    let coachingCues: [String]

    enum CodingKeys: String, CodingKey {
        case exerciseId        = "exercise_id"
        case name
        case primaryMuscle     = "primary_muscle"
        case synergists
        case equipmentRequired = "equipment_required"
        case sets
        case repRange          = "rep_range"
        case tempo
        case restSeconds       = "rest_seconds"
        case rirTarget         = "rir_target"
        case coachingCues      = "coaching_cues"
    }

    // Handle plain-string equipment_required from LLM output.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId   = try c.decode(String.self, forKey: .exerciseId)
        name         = try c.decode(String.self, forKey: .name)
        primaryMuscle = try c.decode(String.self, forKey: .primaryMuscle)
        synergists   = try c.decode([String].self, forKey: .synergists)
        sets         = try c.decode(Int.self, forKey: .sets)
        repRange     = try c.decode(RepRange.self, forKey: .repRange)
        tempo        = try c.decode(String.self, forKey: .tempo)
        restSeconds  = try c.decode(Int.self, forKey: .restSeconds)
        rirTarget    = try c.decode(Int.self, forKey: .rirTarget)
        coachingCues = try c.decode([String].self, forKey: .coachingCues)

        if let typeKey = try? c.decode(String.self, forKey: .equipmentRequired) {
            equipmentRequired = EquipmentType(typeKey: typeKey)
        } else {
            equipmentRequired = try c.decode(EquipmentType.self, forKey: .equipmentRequired)
        }
    }
}

nonisolated struct TemplateTrainingDay: Codable, Sendable {
    let dayOfWeek: Int
    let dayLabel: String
    let sessionNotes: String?
    let exercises: [TemplateExercise]

    enum CodingKeys: String, CodingKey {
        case dayOfWeek    = "day_of_week"
        case dayLabel     = "day_label"
        case sessionNotes = "session_notes"
        case exercises
    }
}

nonisolated struct PhaseTemplate: Codable, Sendable {
    let phase: MesocyclePhase
    let trainingDays: [TemplateTrainingDay]

    enum CodingKeys: String, CodingKey {
        case phase
        case trainingDays = "training_days"
    }
}

nonisolated struct MesocycleTemplateWrapper: Codable, Sendable {
    let mesocycleTemplate: MesocycleTemplatePayload

    enum CodingKeys: String, CodingKey {
        case mesocycleTemplate = "mesocycle_template"
    }
}

nonisolated struct MesocycleTemplatePayload: Codable, Sendable {
    let periodizationModel: String
    let phaseTemplates: [PhaseTemplate]

    enum CodingKeys: String, CodingKey {
        case periodizationModel = "periodization_model"
        case phaseTemplates     = "phase_templates"
    }
}

// MARK: - ProgramGenerationService

actor ProgramGenerationService {

    private let provider: any LLMProvider
    private(set) var isGenerating: Bool = false

    init(provider: any LLMProvider) {
        self.provider = provider
    }

    // MARK: Public API

    func generate(
        userProfile: UserProfile,
        gymProfile: GymProfile,
        trainingDaysPerWeek: Int = 4
    ) async throws -> Mesocycle {
        isGenerating = true
        defer { isGenerating = false }

        let systemPrompt = try Self.loadSystemPrompt()

        print("[ProgramGenerationService] Generating programme — training_days_per_week: \(trainingDaysPerWeek)")

        let constraints = ProgrammingConstraints(
            trainingDaysPerWeek: trainingDaysPerWeek,
            totalWeeks: 12,
            periodizationModel: "linear_periodization"
        )
        let request = MacroProgramRequest(
            userProfile: userProfile,
            gymProfile: GymProfilePayload(from: gymProfile),
            programmingConstraints: constraints
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let requestData = try? encoder.encode(request),
              let requestJSON = String(data: requestData, encoding: .utf8)
        else {
            throw ProgramGenerationError.encodingFailed("Failed to encode MacroProgramRequest.")
        }

        // Stage 1: LLM generates 4 phase templates
        let template = try await callAndDecodeTemplate(
            systemPrompt: systemPrompt,
            userPayload: requestJSON
        )

        // Stage 2: Client expands templates into 12 weeks
        let userId = UUID(uuidString: userProfile.userId) ?? UUID()
        let mesocycle = Self.expandTemplate(template, userId: userId)

        // Equipment constraint validation
        let violations = Self.validateEquipmentConstraints(mesocycle: mesocycle, gymProfile: gymProfile)
        if violations.isEmpty { return mesocycle }

        // One corrective re-prompt if violations found
        let correctionPayload = Self.buildCorrectionPayload(
            originalRequest: requestJSON,
            violations: violations,
            gymProfile: gymProfile
        )
        let correctedTemplate = try await callAndDecodeTemplate(
            systemPrompt: systemPrompt,
            userPayload: correctionPayload
        )
        let correctedMesocycle = Self.expandTemplate(correctedTemplate, userId: userId)

        let remainingViolations = Self.validateEquipmentConstraints(
            mesocycle: correctedMesocycle,
            gymProfile: gymProfile
        )
        if !remainingViolations.isEmpty {
            throw ProgramGenerationError.equipmentConstraintViolation(remainingViolations)
        }
        return correctedMesocycle
    }

    // MARK: Equipment Constraint Validation

    static func validateEquipmentConstraints(
        mesocycle: Mesocycle,
        gymProfile: GymProfile
    ) -> [EquipmentViolation] {
        let available = Set(gymProfile.equipment.map { $0.equipmentType })
        var violations: [EquipmentViolation] = []
        for week in mesocycle.weeks {
            for day in week.trainingDays {
                for exercise in day.exercises {
                    if case .unknown = exercise.equipmentRequired { continue }
                    if !available.contains(exercise.equipmentRequired) {
                        violations.append(EquipmentViolation(
                            exerciseId: exercise.exerciseId,
                            exerciseName: exercise.name,
                            weekNumber: week.weekNumber,
                            requiredEquipment: exercise.equipmentRequired
                        ))
                    }
                }
            }
        }
        return violations
    }

    // MARK: - Private: LLM call + template decode

    private func callAndDecodeTemplate(
        systemPrompt: String,
        userPayload: String
    ) async throws -> MesocycleTemplatePayload {
        let rawResponse: String
        do {
            rawResponse = try await provider.complete(
                systemPrompt: systemPrompt,
                userPayload: userPayload
            )
        } catch {
            throw ProgramGenerationError.llmProviderError(error.localizedDescription)
        }

        // Strip markdown fences, then extract the outermost { } block in case the
        // model emits any preamble or postamble text despite being instructed not to.
        let fenceStripped = Self.stripMarkdownFences(rawResponse)
        let extracted = Self.extractOutermostObject(fenceStripped) ?? fenceStripped
        let jsonString = Self.repairLLMJSON(extracted)

        guard let data = jsonString.data(using: .utf8) else {
            throw ProgramGenerationError.decodingFailed("LLM response is not valid UTF-8.")
        }

        do {
            let wrapper = try JSONDecoder().decode(MesocycleTemplateWrapper.self, from: data)
            return wrapper.mesocycleTemplate
        } catch let err {
            // Log the full raw response so decode failures are diagnosable.
            print("[ProgramGenerationService] Decode failure. Full raw response:\n\(rawResponse)")
            let preview = String(jsonString.prefix(600))
            throw ProgramGenerationError.decodingFailed(
                "Template decode failed: \(err.localizedDescription). Raw: \(preview)"
            )
        }
    }

    // MARK: - Private: Template expansion → 12 weeks

    /// Expands 4 phase templates into a full 12-week Mesocycle with progressive overload.
    ///
    /// Week layout:
    ///   Accumulation    — weeks 1, 2, 3, 4   (4 weeks)
    ///   Intensification — weeks 5, 6, 7, 8   (4 weeks)
    ///   Peaking         — weeks 9, 10, 11     (3 weeks)
    ///   Deload          — week 12             (1 week)
    private static func expandTemplate(
        _ template: MesocycleTemplatePayload,
        userId: UUID
    ) -> Mesocycle {
        // Build a lookup from phase → template days
        var phaseMap: [MesocyclePhase: [TemplateTrainingDay]] = [:]
        for pt in template.phaseTemplates {
            phaseMap[pt.phase] = pt.trainingDays
        }

        // Phase schedule: (phase, weekNumbers)
        let schedule: [(MesocyclePhase, [Int])] = [
            (.accumulation,    [1, 2, 3, 4]),
            (.intensification, [5, 6, 7, 8]),
            (.peaking,         [9, 10, 11]),
            (.deload,          [12])
        ]

        var weeks: [TrainingWeek] = []
        for (phase, weekNumbers) in schedule {
            let templateDays = phaseMap[phase] ?? phaseMap[.accumulation] ?? []
            for weekNumber in weekNumbers {
                let weekInPhase = weekNumber - weekNumbers[0]  // 0-based offset within phase
                let trainingDays = templateDays.map { templateDay in
                    buildTrainingDay(
                        from: templateDay,
                        phase: phase,
                        weekInPhase: weekInPhase
                    )
                }
                weeks.append(TrainingWeek(
                    id: UUID(),
                    weekNumber: weekNumber,
                    phase: phase,
                    trainingDays: trainingDays
                ))
            }
        }

        return Mesocycle(
            id: UUID(),
            userId: userId,
            createdAt: Date(),
            isActive: true,
            weeks: weeks,
            totalWeeks: 12,
            periodizationModel: template.periodizationModel
        )
    }

    /// Builds a `TrainingDay` from a template day, applying weekly progressive overload.
    private static func buildTrainingDay(
        from template: TemplateTrainingDay,
        phase: MesocyclePhase,
        weekInPhase: Int
    ) -> TrainingDay {
        // Validate exercise IDs against canonical library — log warnings for non-canonical IDs.
        for ex in template.exercises {
            if ExerciseLibrary.lookup(ex.exerciseId) == nil {
                print("[ProgramGenerationService] ⚠️ Non-canonical exercise_id: '\(ex.exerciseId)' — not in ExerciseLibrary.")
            }
        }

        let exercises = template.exercises.map { ex in
            applyProgressiveOverload(to: ex, phase: phase, weekInPhase: weekInPhase)
        }
        return TrainingDay(
            id: UUID(),
            dayOfWeek: template.dayOfWeek,
            dayLabel: template.dayLabel,
            exercises: exercises,
            sessionNotes: template.sessionNotes
        )
    }

    /// Applies deterministic progressive overload to a template exercise.
    ///
    /// Rules:
    ///   Accumulation:    +1 set every 2 weeks (weeks 3–4 get +1 set)
    ///   Intensification: RIR –1 every 2 weeks (weeks 7–8 get –1 RIR)
    ///   Peaking:         RIR –1 per week (each week gets progressively harder)
    ///   Deload:          no changes
    private static func applyProgressiveOverload(
        to ex: TemplateExercise,
        phase: MesocyclePhase,
        weekInPhase: Int
    ) -> PlannedExercise {
        var sets      = ex.sets
        var rirTarget = ex.rirTarget

        switch phase {
        case .accumulation:
            // Add a set every 2 weeks (week offset 2 and 3 get +1 set each)
            sets = min(ex.sets + weekInPhase / 2, 6)
        case .intensification:
            // Drop RIR by 1 in the second half of the phase (week offset 2+)
            rirTarget = max(ex.rirTarget - weekInPhase / 2, 1)
        case .peaking:
            // Drop RIR by 1 each week (clamped to 0)
            rirTarget = max(ex.rirTarget - weekInPhase, 0)
        case .deload:
            // No progression in deload
            break
        }

        return PlannedExercise(
            id: UUID(),
            exerciseId: ex.exerciseId,
            name: ex.name,
            primaryMuscle: ex.primaryMuscle,
            synergists: ex.synergists,
            equipmentRequired: ex.equipmentRequired,
            sets: sets,
            repRange: ex.repRange,
            tempo: ex.tempo,
            restSeconds: ex.restSeconds,
            rirTarget: rirTarget,
            coachingCues: ex.coachingCues
        )
    }

    // MARK: - Private: Correction payload

    private static func buildCorrectionPayload(
        originalRequest: String,
        violations: [EquipmentViolation],
        gymProfile: GymProfile
    ) -> String {
        let violationLines = violations.map {
            "- exerciseId: \($0.exerciseId) (week \($0.weekNumber)) requires \($0.requiredEquipment.typeKey) which is NOT available"
        }.joined(separator: "\n")

        let availableKeys = gymProfile.equipment
            .map { $0.equipmentType.typeKey }
            .joined(separator: ", ")

        return """
        \(originalRequest)

        --- EQUIPMENT CORRECTION REQUIRED ---
        The following exercises use equipment not present in the gym profile.
        Substitute each violating exercise with one using only available equipment below.
        Return the corrected full mesocycle_template JSON — do NOT return only the changed exercises.

        VIOLATIONS:
        \(violationLines)

        AVAILABLE EQUIPMENT:
        \(availableKeys)
        """
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
            let base = try String(contentsOf: url, encoding: .utf8)
            return base + ExerciseLibrary.promptReferenceBlock()
        }
        throw ProgramGenerationError.systemPromptNotFound
    }

    // MARK: - Private: LLM JSON repair

    /// Best-effort repair of common LLM JSON corruption before decoding.
    ///
    /// Patterns fixed:
    ///   1. `"key". "value"`   -> `"key": "value"`     (period instead of colon separator)
    ///   2. `"key": I[`        -> `"key": [`            (stray uppercase letter before array/object)
    ///   3. `[ "key": value ]` -> `[ {"key": value} ]` (bare object members inside array)
    private static func repairLLMJSON(_ input: String) -> String {
        var s = input

        // Fix 1: `"...". ` -> `"...": `
        if let regex = try? NSRegularExpression(
            pattern: #"("(?:[^"\\]|\\.)*")\s*\.\s*(?=["0-9\[{tfn])"#
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1: ")
        }

        // Fix 2: `": X[` or `": X{` where X is a stray single uppercase letter
        if let regex = try? NSRegularExpression(
            pattern: #"(:\s*)[A-Z]([\[{])"#
        ) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2")
        }

        // Fix 3: bare object members inside arrays — missing { } wrappers
        s = Self.insertMissingObjectBraces(s)

        return s
    }

    /// Wraps bare `"key": value` sequences that appear directly inside a `[…]` array
    /// without a surrounding `{}`. Injects `{` before the first bare key and `}` before
    /// the closing `]` or the comma that separates the next bare sibling.
    private static func insertMissingObjectBraces(_ input: String) -> String {
        let chars = Array(input)
        var result: [Character] = []
        result.reserveCapacity(chars.count + 64)

        var i = 0
        var arrayBareStack: [Bool] = []  // true = this array level uses bare object elements
        var objectDepth = 0              // `{` depth relative to current array level
        var inString = false
        var escaped = false

        func skipWS(from j: Int) -> Int {
            var k = j
            while k < chars.count && (chars[k] == " " || chars[k] == "\n" || chars[k] == "\r" || chars[k] == "\t") { k += 1 }
            return k
        }

        func looksLikeKey(at j: Int) -> Bool {
            guard j < chars.count && chars[j] == "\"" else { return false }
            var k = j + 1
            var esc = false
            while k < chars.count {
                if esc { esc = false; k += 1; continue }
                if chars[k] == "\\" { esc = true; k += 1; continue }
                if chars[k] == "\"" { k += 1; break }
                k += 1
            }
            let afterQuote = skipWS(from: k)
            return afterQuote < chars.count && chars[afterQuote] == ":"
        }

        while i < chars.count {
            let ch = chars[i]

            if escaped { escaped = false; result.append(ch); i += 1; continue }

            if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                result.append(ch); i += 1; continue
            }

            switch ch {
            case "\"":
                inString = true; result.append(ch); i += 1

            case "{":
                objectDepth += 1; result.append(ch); i += 1

            case "}":
                objectDepth -= 1; result.append(ch); i += 1

            case "[":
                result.append(ch); i += 1
                let next = skipWS(from: i)
                if next < chars.count
                    && chars[next] != "{"
                    && chars[next] != "["
                    && chars[next] != "]"
                    && looksLikeKey(at: next)
                {
                    arrayBareStack.append(true)
                    result.append("{")
                } else {
                    arrayBareStack.append(false)
                }

            case "]":
                if arrayBareStack.last == true {
                    result.append("}")
                    arrayBareStack[arrayBareStack.count - 1] = false
                }
                _ = arrayBareStack.popLast()
                result.append(ch); i += 1

            case ",":
                if arrayBareStack.last == true && objectDepth == 0 {
                    let next = skipWS(from: i + 1)
                    if next < chars.count && chars[next] != "{" && looksLikeKey(at: next) {
                        result.append("}")   // close current bare element
                        result.append(ch)    // comma
                        result.append("{")   // open next bare element
                        i += 1; continue
                    }
                }
                result.append(ch); i += 1

            default:
                result.append(ch); i += 1
            }
        }

        return String(result)
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

    /// Extracts the substring from the first `{` to its matching closing `}`.
    /// Guards against the model prepending prose or a preamble before the JSON object.
    private static func extractOutermostObject(_ input: String) -> String? {
        guard let start = input.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < input.endIndex {
            let ch = input[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(input[start...idx])
                    }
                }
            }
            idx = input.index(after: idx)
        }
        return nil
    }
}

// MARK: - AnthropicProvider convenience: program generation

extension AnthropicProvider {
    /// Sonnet model with 16k token budget and 180s timeout.
    /// Template output observed at 10k–14k tokens for a 4-day program; 16k provides headroom.
    static func forProgramGeneration(apiKey: String) -> AnthropicProvider {
        AnthropicProvider(
            apiKey: apiKey,
            model: "claude-sonnet-4-5",
            maxTokens: 16000,
            requestTimeout: 180
        )
    }
}
