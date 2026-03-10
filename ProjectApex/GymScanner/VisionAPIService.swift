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
struct VisionAPIConfiguration {
    enum Provider {
        case openAI   // GPT-4o Vision
        case anthropic // Claude Vision
    }

    let provider: Provider
    let apiKey: String
    let modelID: String
    let timeoutSeconds: TimeInterval

    static let `default` = VisionAPIConfiguration(
        provider: .openAI,
        apiKey: "",  // Populated from Keychain at runtime
        modelID: "gpt-4o",
        timeoutSeconds: 30
    )
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
/// piece of strength training equipment visible. For each item, extract:
/// equipment_type, estimated_weight_range_kg (if applicable),
/// increments_available_kg (if identifiable), and count. Return ONLY valid JSON."
actor VisionAPIService: VisionAPIServiceProtocol {

    // ---------------------------------------------------------------------------
    // MARK: Dependencies
    // ---------------------------------------------------------------------------

    private let configuration: VisionAPIConfiguration
    private let session: URLSession

    // ---------------------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------------------

    init(configuration: VisionAPIConfiguration = .default) {
        self.configuration = configuration
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = configuration.timeoutSeconds
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
            piece of strength training equipment visible. For each item, extract: \
            equipment_type (snake_case identifier), estimated_weight_range_kg \
            (object with min_kg and max_kg, or null), increments_available_kg (number or null), \
            and count (integer). Return ONLY a valid JSON object with a top-level key \
            "equipment" containing an array of items. No prose, no markdown fences.
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
    private func parseResponse(data: Data) throws -> [EquipmentItem] {
        // Step 1: Extract the content string from the provider's chat response envelope.
        // Both OpenAI and Anthropic wrap the model output in nested JSON.
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

        let decoder = JSONDecoder()

        // Attempt primary decode as VisionAPIResponse { "equipment": [...] }
        if let apiResponse = try? decoder.decode(VisionAPIResponse.self, from: contentData) {
            return apiResponse.items
        }

        // Fallback: attempt bare array decode [EquipmentItem]
        if let items = try? decoder.decode([EquipmentItem].self, from: contentData) {
            return items
        }

        // If both fail, the response is malformed — discard per FR-001-D.
        let rawString = String(data: contentData, encoding: .utf8) ?? "<undecodable>"
        throw ScannerError.apiResponseMalformed(rawResponse: rawString)
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
    private let mockBatches: [[EquipmentItem]] = [
        // Frame 0: User points camera at the free weights area
        [
            EquipmentItem(
                equipmentType: "dumbbell_set",
                estimatedWeightRangeKg: WeightRange(minKg: 2.5, maxKg: 45.0),
                incrementsAvailableKg: 2.5,
                count: 1
            ),
            EquipmentItem(
                equipmentType: "adjustable_bench",
                estimatedWeightRangeKg: nil,
                incrementsAvailableKg: nil,
                count: 3
            )
        ],
        // Frame 1: User pans to the barbell racks
        [
            EquipmentItem(
                equipmentType: "barbell",
                estimatedWeightRangeKg: WeightRange(minKg: 20.0, maxKg: 200.0),
                incrementsAvailableKg: 2.5,
                count: 4
            ),
            EquipmentItem(
                equipmentType: "squat_rack",
                estimatedWeightRangeKg: nil,
                incrementsAvailableKg: nil,
                count: 2
            )
        ],
        // Frame 2: User reaches the cable section
        [
            EquipmentItem(
                equipmentType: "cable_machine",
                estimatedWeightRangeKg: WeightRange(minKg: 0.0, maxKg: 90.0),
                incrementsAvailableKg: 2.5,
                count: 2
            ),
            EquipmentItem(
                equipmentType: "lat_pulldown",
                estimatedWeightRangeKg: WeightRange(minKg: 0.0, maxKg: 90.0),
                incrementsAvailableKg: 5.0,
                count: 1
            )
        ],
        // Frame 3: Machine area — plates + more machines detected
        [
            EquipmentItem(
                equipmentType: "leg_press",
                estimatedWeightRangeKg: WeightRange(minKg: 0.0, maxKg: 300.0),
                incrementsAvailableKg: 10.0,
                count: 1
            ),
            EquipmentItem(
                equipmentType: "smith_machine",
                estimatedWeightRangeKg: WeightRange(minKg: 20.0, maxKg: 180.0),
                incrementsAvailableKg: 2.5,
                count: 1
            )
        ],
        // Frame 4: Cardio corner — additional bodyweight equipment
        [
            EquipmentItem(
                equipmentType: "pull_up_bar",
                estimatedWeightRangeKg: nil,
                incrementsAvailableKg: nil,
                count: 2
            ),
            EquipmentItem(
                equipmentType: "kettlebell_set",
                estimatedWeightRangeKg: WeightRange(minKg: 8.0, maxKg: 40.0),
                incrementsAvailableKg: 4.0,
                count: 1
            )
        ],
        // Frame 5: Overlapping frames — re-detects already-known items (tests dedup)
        [
            EquipmentItem(
                equipmentType: "dumbbell_set",
                estimatedWeightRangeKg: WeightRange(minKg: 2.5, maxKg: 45.0),
                incrementsAvailableKg: 2.5,
                count: 1
            ),
            EquipmentItem(
                equipmentType: "cable_machine",
                estimatedWeightRangeKg: WeightRange(minKg: 0.0, maxKg: 90.0),
                incrementsAvailableKg: 2.5,
                count: 2
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
