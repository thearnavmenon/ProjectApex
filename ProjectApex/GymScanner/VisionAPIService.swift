// VisionAPIService.swift
// ProjectApex — GymScanner Feature
//
// Network layer for the Vision API pipeline. Sends a Base64-encoded JPEG frame
// to the configured endpoint and parses the JSON response into [EquipmentItem].
//
// Architecture:
//   • Implemented as a Swift `actor` to serialise concurrent API calls and
//     protect mutable state (request counter, retry bookkeeping) without locks.
//   • The real API path uses the Anthropic Messages API with vision (Claude).
//   • For prototype / simulator use, `MockVisionAPIService` is injected instead,
//     returning deterministic mock data so the full UI pipeline can be exercised
//     without burning API credits or requiring a live network connection.
//
// SCANNER PRINCIPLE: Equipment presence only.
// The Vision API prompt requests equipment_type, count, and confidence.
// No weight ranges — those are handled by DefaultWeightIncrements + GymFactStore.

import Foundation

// MARK: - VisionAPIConfiguration

/// Holds the runtime configuration for the Vision API endpoint.
/// In production, the `apiKey` is loaded from the iOS Keychain.
struct VisionAPIConfiguration: Sendable {
    enum Provider: Sendable {
        case openAI   // GPT-4o Vision
        case anthropic // Claude Vision
    }

    let provider: Provider
    let apiKey: String
    let modelID: String
    let timeoutSeconds: TimeInterval
}

// MARK: - VisionAPIServiceProtocol

/// Abstraction over the Vision API service, enabling mock injection in previews
/// and unit tests without touching networking code.
protocol VisionAPIServiceProtocol: Actor {
    /// Sends `frame` to the Vision API and returns the parsed equipment items.
    /// Returns an empty array (not throws) for frames with no detected equipment.
    /// Throws `ScannerError` for hard failures (network, malformed response).
    func analyseFrame(_ frame: CapturedFrame) async throws -> [EquipmentItem]
}

// MARK: - VisionAPIService (Live)

/// Production implementation. Constructs the multimodal Vision API request,
/// handles HTTP errors, and parses the response against the VisionDetectedItem schema.
///
/// Uses the strength-training-only gym scan prompt that requests:
///   - equipment_type (one of a fixed vocabulary of 25 types)
///   - count (integer number of units visible)
///   - confidence (float 0.0–1.0; items below 0.7 are not returned)
actor VisionAPIService: VisionAPIServiceProtocol {

    // ---------------------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------------------

    private let configuration: VisionAPIConfiguration
    private let session: URLSession

    // ---------------------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------------------

    init(configuration: VisionAPIConfiguration? = nil) {
        // Resolve default outside of any actor isolation boundary
        let resolvedConfig = configuration ?? VisionAPIConfiguration(
            provider: .anthropic,
            apiKey: "",
            modelID: "claude-sonnet-4-20250514",
            timeoutSeconds: 30
        )
        self.configuration = resolvedConfig
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = resolvedConfig.timeoutSeconds
        self.session = URLSession(configuration: urlConfig)
    }

    // ---------------------------------------------------------------------------
    // MARK: VisionAPIServiceProtocol
    // ---------------------------------------------------------------------------

    func analyseFrame(_ frame: CapturedFrame) async throws -> [EquipmentItem] {
        let requestBody = buildRequestBody(base64Image: frame.base64JPEG)
        let endpoint = endpointURL()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Provider-specific auth header
        switch configuration.provider {
        case .anthropic:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[VisionAPIService] HTTP \(statusCode): \(rawBody.prefix(300))")
            throw ScannerError.apiRequestFailed(
                underlying: NSError(
                    domain: "VisionAPIService",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Non-2xx HTTP response (\(statusCode))"]
                )
            )
        }

        return try parseResponse(data: data)
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Request Construction
    // ---------------------------------------------------------------------------

    private func endpointURL() -> URL {
        switch configuration.provider {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1/messages")!
        }
    }

    /// Builds the multimodal JSON request body for the configured provider.
    /// The system prompt is optimised for a single focused equipment photo.
    private func buildRequestBody(base64Image: String) -> [String: Any] {
        let visionInstruction = """
            You are a gym equipment identifier. The user has taken a photo of \
            ONE piece of gym equipment for you to identify.

            STRICT RULES:
            1. If no strength training equipment is clearly visible, \
            you MUST return: []
            2. Return exactly ONE item — the primary piece of equipment \
            in the photo. Do not list secondary objects.
            3. Do NOT guess, hallucinate, or infer equipment that is not \
            clearly visible in the photo.
            4. Ignore ALL cardio equipment (bikes, treadmills, rowers, \
            ellipticals, stair climbers, ski ergs, assault bikes).
            5. Ignore furniture, screens, computers, walls, floors, and \
            any non-equipment objects.
            6. You MUST use ONLY these exact equipment_type values — \
            any other string is forbidden:
            "dumbbell_set" | "barbell" | "ez_curl_bar" | "cable_machine_single" |
            "cable_machine_dual" | "smith_machine" | "leg_press" | "hack_squat" |
            "adjustable_bench" | "flat_bench" | "incline_bench" | "pull_up_bar" |
            "dip_station" | "resistance_bands" | "kettlebell_set" | "power_rack" |
            "squat_rack" | "lat_pulldown" | "seated_row" | "chest_press_machine" |
            "shoulder_press_machine" | "leg_extension" | "leg_curl" | "pec_deck" |
            "preacher_curl" | "cable_crossover"

            Return ONLY a valid JSON array with ONE item. No explanation, \
            no markdown fences.
            Format: [{"equipment_type": "<type>", "count": <integer>, "confidence": <float>}]
            Only include the item if confidence >= 0.85.
            If nothing from the allowed list is visible, return: []
            """

        switch configuration.provider {
        case .anthropic:
            return [
                "model": configuration.modelID,
                "max_tokens": 1024,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": "image/jpeg",
                                    "data": base64Image
                                ]
                            ],
                            [
                                "type": "text",
                                "text": visionInstruction
                            ]
                        ]
                    ]
                ]
            ]

        case .openAI:
            return [
                "model": configuration.modelID,
                "max_tokens": 1024,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:image/jpeg;base64,\(base64Image)",
                                    "detail": "high"
                                ]
                            ],
                            [
                                "type": "text",
                                "text": visionInstruction
                            ]
                        ]
                    ]
                ]
            ]
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Response Parsing
    // ---------------------------------------------------------------------------

    /// Parses the raw API response data into [EquipmentItem].
    /// Non-conforming responses are discarded without crashing.
    private func parseResponse(data: Data) throws -> [EquipmentItem] {
        // Step 1: Extract the content string from the provider's chat response envelope.
        guard
            let topLevel = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentString = extractContentString(from: topLevel)
        else {
            throw ScannerError.apiResponseMalformed(
                rawResponse: String(data: data, encoding: .utf8) ?? "<binary>"
            )
        }

        // Step 2: Strip any accidental markdown code fences the model might have added.
        let cleaned = stripMarkdownFences(from: contentString)

        guard let contentData = cleaned.data(using: .utf8) else {
            throw ScannerError.apiResponseMalformed(rawResponse: contentString)
        }

        // Step 3: Attempt to decode as the flat VisionDetectedItem array.
        if let detectedItems = try? JSONDecoder().decode([VisionDetectedItem].self, from: contentData) {
            return detectedItems.map { $0.toEquipmentItem() }
        }

        // Step 4: Fallback — try legacy wrapped { "equipment": [...] } format.
        let decoder = JSONDecoder.gymProfile
        if let apiResponse = try? decoder.decode(VisionAPIResponse.self, from: contentData) {
            return apiResponse.items
        }

        // Step 5: Fallback — try direct [EquipmentItem] array (legacy).
        if let items = try? decoder.decode([EquipmentItem].self, from: contentData) {
            return items
        }

        // Step 6: If the model returned an empty array literal, that is valid (no equipment).
        if let array = try? JSONSerialization.jsonObject(with: contentData) as? [Any], array.isEmpty {
            return []
        }

        throw ScannerError.apiResponseMalformed(rawResponse: contentString)
    }

    /// Extracts the model's text output from either an OpenAI or Anthropic response envelope.
    private func extractContentString(from json: [String: Any]) -> String? {
        // Anthropic envelope: { "content": [{ "type": "text", "text": "..." }] }
        if let contentArray = json["content"] as? [[String: Any]],
           let firstContent = contentArray.first(where: { $0["type"] as? String == "text" }),
           let text = firstContent["text"] as? String {
            return text
        }

        // OpenAI envelope: { "choices": [{ "message": { "content": "..." } }] }
        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        return nil
    }

    /// Removes leading/trailing markdown code fences (```json ... ```) that some
    /// models include despite being instructed not to.
    private func stripMarkdownFences(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove opening fence variants: ```json, ```JSON, ```
        if result.hasPrefix("```") {
            // Drop everything up to the first newline after the fence marker
            if let newlineRange = result.range(of: "\n") {
                result = String(result[newlineRange.upperBound...])
            }
        }
        // Remove closing fence
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - MockVisionAPIService

/// Prototype-safe mock that returns realistic gym equipment data without any
/// network calls. Simulates variable latency to exercise the loading states in the UI.
///
/// Each call simulates the guided single-photo-per-equipment flow: returns ONE item
/// (or empty for the "nothing detected" toast path) per `analyseFrame` call.
actor MockVisionAPIService: VisionAPIServiceProtocol {

    // Mock response rotation: each call returns the next single item in sequence.
    private var callCount: Int = 0

    // A sequence of single-item detections, each representing one focused equipment photo.
    // Presence only — no weight ranges in mock data.
    private let mockItems: [EquipmentItem] = [
        EquipmentItem(equipmentType: .dumbbellSet, count: 1, detectedByVision: true),
        EquipmentItem(equipmentType: .barbell, count: 4, detectedByVision: true),
        EquipmentItem(equipmentType: .powerRack, count: 2, detectedByVision: true),
        EquipmentItem(equipmentType: .cableMachine, count: 2, detectedByVision: true),
        EquipmentItem(equipmentType: .adjustableBench, count: 3, detectedByVision: true),
        EquipmentItem(equipmentType: .latPulldown, count: 1, detectedByVision: true),
        EquipmentItem(equipmentType: .legPress, count: 1, detectedByVision: true),
        EquipmentItem(equipmentType: .smithMachine, count: 1, detectedByVision: true),
        EquipmentItem(equipmentType: .pullUpBar, count: 2, detectedByVision: true),
        EquipmentItem(equipmentType: .kettlebellSet, count: 1, detectedByVision: true)
    ]

    func analyseFrame(_ frame: CapturedFrame) async throws -> [EquipmentItem] {
        // Simulate realistic Vision API latency (0.8 – 1.8 seconds)
        let simulatedLatencyMs = UInt64.random(in: 800_000_000...1_800_000_000)
        try await Task.sleep(nanoseconds: simulatedLatencyMs)

        // Every 5th call simulates a "nothing detected" result (non-gym image).
        if callCount % 5 == 4 {
            callCount += 1
            return []
        }

        let item = mockItems[callCount % mockItems.count]
        callCount += 1
        return [item]
    }
}
