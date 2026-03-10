// VisionAPIService.swift
// ProjectApex — GymScanner Feature
//
// Network layer for the Vision API pipeline. Sends a Base64-encoded JPEG frame
// to the configured endpoint and parses the JSON response into [EquipmentItem].
//
// Architecture:
//   • Implemented as a Swift `actor` to serialise concurrent API calls and
//     protect mutable state (request counter, retry bookkeeping) without locks.
//   • The real API path is wired to OpenAI GPT-4o Vision or Anthropic Claude
//     Vision (configurable via `VisionAPIConfiguration`).
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
/// For the prototype, it defaults to an empty string — the mock service is used instead.
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
/// handles HTTP errors, and parses the response against the EquipmentItem schema.
///
/// The Vision API system prompt is embedded here (Section 3.1.1 of PRD):
/// "You are an expert gym equipment auditor. Analyze this image and identify every
/// piece of strength training equipment visible. Return ONLY valid JSON matching
/// the GymProfile equipment schema with equipment_type, kind, and details fields."
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
            provider: .openAI,
            apiKey: "",
            modelID: "gpt-4o",
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
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ScannerError.apiRequestFailed(
                underlying: NSError(
                    domain: "VisionAPIService",
                    code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: "Non-2xx HTTP response"]
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
    private func buildRequestBody(base64Image: String) -> [String: Any] {
        // --- System prompt (PRD Section 3.1.1) ---
        let systemPrompt = """
            You are an expert gym equipment auditor. Analyze this image and identify every \
            piece of strength training equipment visible. For each item return a JSON object \
            with: equipment_type (snake_case, e.g. "dumbbell_set"), count (integer), \
            detected_by_vision (true), and details (object with "kind" field set to \
            "increment_based", "plate_based", or "bodyweight_only" plus relevant fields). \
            Return ONLY a valid JSON object with a top-level key "equipment" containing \
            an array of items. No prose, no markdown fences.
            """

        switch configuration.provider {
        case .openAI:
            return [
                "model": configuration.modelID,
                "max_tokens": 1024,
                "messages": [
                    [
                        "role": "system",
                        "content": systemPrompt
                    ],
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:image/jpeg;base64,\(base64Image)",
                                    "detail": "high"
                                ]
                            ]
                        ]
                    ]
                ]
            ]

        case .anthropic:
            return [
                "model": configuration.modelID,
                "max_tokens": 1024,
                "system": systemPrompt,
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
                                "text": "Identify all gym equipment in this image."
                            ]
                        ]
                    ]
                ]
            ]
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: Private: Response Parsing (FR-001-D)
    // ---------------------------------------------------------------------------

    /// Parses the raw API response data into [EquipmentItem].
    /// Non-conforming responses are discarded without crashing (FR-001-D).
    /// Runs on the actor's executor — no nonisolated workarounds needed.
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

        // Step 2: Decode the content string as our VisionAPIResponse schema.
        guard let contentData = contentString.data(using: .utf8) else {
            throw ScannerError.apiResponseMalformed(rawResponse: contentString)
        }

        let decoder = JSONDecoder.gymProfile

        // Try to decode the wrapped response first
        if let apiResponse = try? decoder.decode(VisionAPIResponse.self, from: contentData) {
            return apiResponse.items
        }

        // Fallback: Try to decode as a direct array
        if let items = try? decoder.decode([EquipmentItem].self, from: contentData) {
            return items
        }

        throw ScannerError.apiResponseMalformed(rawResponse: contentString)
    }

    /// Extracts the model's text output from either an OpenAI or Anthropic response envelope.
    private func extractContentString(from json: [String: Any]) -> String? {
        // OpenAI envelope: { "choices": [{ "message": { "content": "..." } }] }
        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        // Anthropic envelope: { "content": [{ "type": "text", "text": "..." }] }
        if let contentArray = json["content"] as? [[String: Any]],
           let firstContent = contentArray.first(where: { $0["type"] as? String == "text" }),
           let text = firstContent["text"] as? String {
            return text
        }

        return nil
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
