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
// FR coverage: FR-001-C (Base64 input), FR-001-D (strict schema parsing + discard),
//              FR-001-E (merge/dedup is handled upstream in ScannerViewModel)

import Foundation

// MARK: - VisionAPIConfiguration

/// Holds the runtime configuration for the Vision API endpoint.
/// In production, the `apiKey` is loaded from the iOS Keychain (Section 6.3.1 of PRD).
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
/// Follows TDD Section 5.3:
///   - Provider: Anthropic Messages API
///   - Model: claude-sonnet-4-20250514
///   - Frame: JPEG 80% quality, Base64-encoded, sent as image/jpeg
///   - Response: flat JSON array of VisionDetectedItem objects
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
    // MARK: Private: Request Construction (TDD Section 5.3)
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
    /// The Anthropic format matches TDD Section 5.3 exactly.
    private func buildRequestBody(base64Image: String) -> [String: Any] {
        // TDD Section 5.3 — exact instruction text in the user message's text field
        let visionInstruction = """
            Identify gym equipment. Return ONLY JSON array: \
            [{"equipment_type": string, "estimated_weight_range_kg": \
            {"min": number, "max": number, "increment": number} | null, "count": number}]. \
            Valid types: dumbbell_set, barbell, ez_curl_bar, cable_machine_single, \
            cable_machine_dual, smith_machine, leg_press, hack_squat, adjustable_bench, \
            flat_bench, incline_bench, pull_up_bar, dip_station, resistance_bands, \
            kettlebell_set. Unknown: 'unknown:<description>'.
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
    // MARK: Private: Response Parsing (FR-001-D, TDD Section 5.3)
    // ---------------------------------------------------------------------------

    /// Parses the raw API response data into [EquipmentItem].
    /// Non-conforming responses are discarded without crashing (FR-001-D).
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

        // Step 3: Attempt to decode as the Section 5.3 flat array format first.
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
/// Rotates through several mock response payloads to simulate progressive scanning,
/// where different equipment is "discovered" across successive frames.
actor MockVisionAPIService: VisionAPIServiceProtocol {

    // Mock response rotation: each call returns the next batch in sequence,
    // cycling back to the start after exhaustion.
    private var callCount: Int = 0

    // A pre-defined sequence of mock detection batches simulating a real gym scan.
    // Uses the new EquipmentType + EquipmentDetails schema.
    private let mockBatches: [[EquipmentItem]] = [
        // Frame 0: User points camera at the free weights area
        [
            EquipmentItem(
                equipmentType: .dumbbellSet,
                count: 1,
                details: .incrementBased(minKg: 2.5, maxKg: 45.0, incrementKg: 2.5),
                detectedByVision: true
            ),
            EquipmentItem(
                equipmentType: .adjustableBench,
                count: 3,
                details: .bodyweightOnly,
                detectedByVision: true
            )
        ],
        // Frame 1: User pans to the barbell racks
        [
            EquipmentItem(
                equipmentType: .barbell,
                count: 4,
                details: .plateBased(
                    barWeightKg: 20.0,
                    availablePlatesKg: [1.25, 2.5, 5.0, 10.0, 20.0, 25.0]
                ),
                detectedByVision: true
            ),
            EquipmentItem(
                equipmentType: .unknown("squat_rack"),
                count: 2,
                details: .bodyweightOnly,
                detectedByVision: true
            )
        ],
        // Frame 2: User reaches the cable section
        [
            EquipmentItem(
                equipmentType: .cableMachine,
                count: 2,
                details: .incrementBased(minKg: 2.5, maxKg: 90.0, incrementKg: 2.5),
                detectedByVision: true
            ),
            EquipmentItem(
                equipmentType: .unknown("lat_pulldown"),
                count: 1,
                details: .incrementBased(minKg: 5.0, maxKg: 90.0, incrementKg: 5.0),
                detectedByVision: true
            )
        ],
        // Frame 3: Machine area — plates + more machines detected
        [
            EquipmentItem(
                equipmentType: .legPress,
                count: 1,
                details: .plateBased(
                    barWeightKg: 0.0,
                    availablePlatesKg: [10.0, 20.0, 25.0]
                ),
                detectedByVision: true
            ),
            EquipmentItem(
                equipmentType: .smithMachine,
                count: 1,
                details: .incrementBased(minKg: 20.0, maxKg: 180.0, incrementKg: 2.5),
                detectedByVision: true
            )
        ],
        // Frame 4: Cardio corner — additional bodyweight equipment
        [
            EquipmentItem(
                equipmentType: .pullUpBar,
                count: 2,
                details: .bodyweightOnly,
                detectedByVision: true
            ),
            EquipmentItem(
                equipmentType: .unknown("kettlebell_set"),
                count: 1,
                details: .incrementBased(minKg: 8.0, maxKg: 40.0, incrementKg: 4.0),
                detectedByVision: true
            )
        ],
        // Frame 5: Overlapping frames — re-detects already-known items (tests dedup)
        [
            EquipmentItem(
                equipmentType: .dumbbellSet,
                count: 1,
                details: .incrementBased(minKg: 2.5, maxKg: 45.0, incrementKg: 2.5),
                detectedByVision: true
            ),
            EquipmentItem(
                equipmentType: .cableMachine,
                count: 2,
                details: .incrementBased(minKg: 2.5, maxKg: 90.0, incrementKg: 2.5),
                detectedByVision: true
            )
        ]
    ]

    func analyseFrame(_ frame: CapturedFrame) async throws -> [EquipmentItem] {
        // Simulate realistic Vision API latency (0.8 – 1.8 seconds)
        let simulatedLatencyMs = UInt64.random(in: 800_000_000...1_800_000_000)
        try await Task.sleep(nanoseconds: simulatedLatencyMs)

        // Occasionally simulate an empty frame (e.g., camera pointed at ceiling)
        if frame.index % 7 == 6 {
            return []
        }

        let batch = mockBatches[callCount % mockBatches.count]
        callCount += 1
        return batch
    }
}
