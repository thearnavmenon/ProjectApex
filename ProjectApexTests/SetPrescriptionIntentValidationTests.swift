// SetPrescriptionIntentValidationTests.swift
// ProjectApexTests — Slice 6 (#10)
//
// Codable + validate() coverage for the new `intent` field on
// SetPrescription per ADR-0005:
//   * each SetIntent case round-trips via JSON
//   * missing intent surfaces typed `.missingIntent` from validate()
//   * invalid intent string is rethrown from init(from:) as `.invalidIntent`
//   * intent type-mismatch (e.g. number) is rethrown as `.invalidIntent`
//   * intent gate has prior precedence over field-level validation
//
// Field-level validation rules are covered by the existing
// SetPrescriptionValidationTests in EquipmentRounderTests.swift; this file
// focuses on the new intent-specific behaviour.

import XCTest
@testable import ProjectApex

final class SetPrescriptionIntentValidationTests: XCTestCase {

    // MARK: - JSON helpers

    /// Builds the JSON envelope shape that the LLM returns. `intent` is
    /// embedded literally so callers can omit / corrupt it in tests.
    private func envelope(
        intent: String?,
        setFraming: String? = "Heaviest work of the day. Brace and grind.",
        extras: String = ""
    ) -> Data {
        let intentLine = intent.map { ",\n    \"intent\": \"\($0)\"" } ?? ""
        let framingLine = setFraming.map { ",\n    \"set_framing\": \"\($0)\"" } ?? ""
        let json = """
        {
          "weight_kg": 80.0,
          "reps": 8,
          "tempo": "3-1-1-0",
          "rir_target": 2,
          "rest_seconds": 120,
          "coaching_cue": "Drive through.",
          "reasoning": "Standard top set.",
          "safety_flags": [],
          "confidence": 0.85\(intentLine)\(framingLine)\(extras)
        }
        """
        return Data(json.utf8)
    }

    /// Same shape as `envelope(intent:)` but with `intent` as a raw JSON
    /// fragment (used for type-mismatch tests where we want `42`, `null`,
    /// etc. rather than a string).
    private func envelopeRaw(intentFragment: String) -> Data {
        let json = """
        {
          "weight_kg": 80.0,
          "reps": 8,
          "tempo": "3-1-1-0",
          "rir_target": 2,
          "rest_seconds": 120,
          "coaching_cue": "Drive through.",
          "reasoning": "Standard top set.",
          "safety_flags": [],
          "confidence": 0.85,
          "intent": \(intentFragment),
          "set_framing": "Heaviest work of the day. Brace and grind."
        }
        """
        return Data(json.utf8)
    }

    /// Envelope with raw `set_framing` fragment for type-mismatch tests.
    private func envelopeRawSetFraming(framingFragment: String) -> Data {
        let json = """
        {
          "weight_kg": 80.0,
          "reps": 8,
          "tempo": "3-1-1-0",
          "rir_target": 2,
          "rest_seconds": 120,
          "coaching_cue": "Drive through.",
          "reasoning": "Standard top set.",
          "safety_flags": [],
          "confidence": 0.85,
          "intent": "top",
          "set_framing": \(framingFragment)
        }
        """
        return Data(json.utf8)
    }

    private func decode(_ data: Data) throws -> SetPrescription {
        try JSONDecoder().decode(SetPrescription.self, from: data)
    }

    // MARK: - A1: every valid intent round-trips

    func test_decode_each_intent_case_round_trips() throws {
        for intent in SetIntent.allCases {
            let p = try decode(envelope(intent: intent.rawValue))
            XCTAssertEqual(p.intent, intent,
                           "Round-trip failed for \(intent.rawValue)")
            XCTAssertNoThrow(try p.validate(),
                             "validate() should accept intent=\(intent.rawValue)")
        }
    }

    // MARK: - A2: missing intent → validate throws .missingIntent

    func test_decode_missing_intent_validate_throws_missingIntent() throws {
        let p = try decode(envelope(intent: nil))
        XCTAssertNil(p.intent,
                     "Missing intent key should decode to nil, not throw at decode time.")
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .missingIntent = error as? PrescriptionValidationError else {
                return XCTFail("Expected .missingIntent, got \(error)")
            }
        }
    }

    // MARK: - A3: invalid intent string → init(from:) throws .invalidIntent

    func test_decode_invalid_intent_string_throws_invalidIntent() {
        let data = envelope(intent: "bogus")
        XCTAssertThrowsError(try decode(data)) { error in
            guard case .invalidIntent(let raw) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidIntent, got \(error)")
            }
            XCTAssertEqual(raw, "bogus",
                           "Error should preserve the offending raw value.")
        }
    }

    // MARK: - A4: intent type-mismatch → init(from:) throws .invalidIntent

    func test_decode_intent_typeMismatch_number_throws_invalidIntent() {
        let data = envelopeRaw(intentFragment: "42")
        XCTAssertThrowsError(try decode(data)) { error in
            guard case .invalidIntent = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidIntent for non-string, got \(error)")
            }
        }
    }

    func test_decode_intent_typeMismatch_array_throws_invalidIntent() {
        let data = envelopeRaw(intentFragment: "[\"top\"]")
        XCTAssertThrowsError(try decode(data)) { error in
            guard case .invalidIntent = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidIntent for array, got \(error)")
            }
        }
    }

    // MARK: - A5: intent gate fires before field-level checks

    func test_intentGate_hasPriorPrecedenceOverInvalidTempo() throws {
        // Build a prescription with both a missing intent AND an invalid
        // tempo. The intent gate should fire first, surfacing
        // `.missingIntent` rather than `.invalidTempo`. This locks the
        // precedence — the no-silent-defaults invariant takes priority over
        // field-format validation.
        let json = """
        {
          "weight_kg": 80.0,
          "reps": 8,
          "tempo": "1-2-3",
          "rir_target": 2,
          "rest_seconds": 120,
          "coaching_cue": "x",
          "reasoning": "y",
          "safety_flags": []
        }
        """
        let p = try decode(Data(json.utf8))
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .missingIntent = error as? PrescriptionValidationError else {
                return XCTFail("Intent gate must fire first, got \(error)")
            }
        }
    }

    // MARK: - Encode round-trip preserves intent

    func test_encode_then_decode_preserves_intent() throws {
        let original = SetPrescription(
            weightKg: 80.0,
            reps: 8,
            tempo: "3-1-1-0",
            rirTarget: 2,
            restSeconds: 120,
            coachingCue: "x",
            reasoning: "y",
            safetyFlags: [],
            confidence: 0.9,
            intent: .backoff,
            setFraming: "Build volume on a manageable load."
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SetPrescription.self, from: encoded)
        XCTAssertEqual(decoded.intent, .backoff)
        XCTAssertEqual(decoded.setFraming, "Build volume on a manageable load.")
        XCTAssertNoThrow(try decoded.validate())
    }

    // MARK: - Intent absent in encode when nil (Codable optional shape)

    func test_encode_nilIntent_omitsKey() throws {
        let p = SetPrescription(
            weightKg: 80.0,
            reps: 8,
            tempo: "3-1-1-0",
            rirTarget: 2,
            restSeconds: 120,
            coachingCue: "x",
            reasoning: "y",
            safetyFlags: [],
            intent: nil,
            setFraming: nil
        )
        let encoded = try JSONEncoder().encode(p)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"intent\""),
                       "Encoder must omit intent when nil.")
        XCTAssertFalse(json.contains("\"set_framing\""),
                       "Encoder must omit set_framing when nil.")
    }

    // MARK: - set_framing required, validated (Slice 6 redesign)

    /// Missing set_framing surfaces .missingSetFraming from validate().
    /// Same regime as intent: typed error, fires after the intent gate.
    func test_decode_missing_setFraming_validate_throws_missingSetFraming() throws {
        let p = try decode(envelope(intent: "top", setFraming: nil))
        XCTAssertEqual(p.intent, .top)
        XCTAssertNil(p.setFraming)
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .missingSetFraming = error as? PrescriptionValidationError else {
                return XCTFail("Expected .missingSetFraming, got \(error)")
            }
        }
    }

    /// set_framing > 80 chars throws .setFramingTooLong with the offending count.
    func test_setFraming_tooLong_throws_setFramingTooLong() throws {
        // 100-char framing — well over the 80 limit.
        let longFraming = String(repeating: "a", count: 100)
        let p = try decode(envelope(intent: "top", setFraming: longFraming))
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .setFramingTooLong(let count) = error as? PrescriptionValidationError else {
                return XCTFail("Expected .setFramingTooLong, got \(error)")
            }
            XCTAssertEqual(count, 100)
        }
    }

    /// set_framing exactly 80 chars is valid (boundary).
    func test_setFraming_at80Chars_valid() throws {
        let framing = String(repeating: "a", count: 80)
        let p = try decode(envelope(intent: "top", setFraming: framing))
        XCTAssertNoThrow(try p.validate())
    }

    /// Type mismatch (e.g. number) → .invalidSetFraming, not raw DecodingError.
    func test_decode_setFraming_typeMismatch_number_throws_invalidSetFraming() {
        let data = envelopeRawSetFraming(framingFragment: "42")
        XCTAssertThrowsError(try decode(data)) { error in
            guard case .invalidSetFraming = error as? PrescriptionValidationError else {
                return XCTFail("Expected .invalidSetFraming for non-string, got \(error)")
            }
        }
    }

    /// Intent gate has prior precedence over set_framing — both missing
    /// surfaces .missingIntent first.
    func test_intentGate_firesBefore_setFramingGate() throws {
        let p = try decode(envelope(intent: nil, setFraming: nil))
        XCTAssertThrowsError(try p.validate()) { error in
            guard case .missingIntent = error as? PrescriptionValidationError else {
                return XCTFail("Expected .missingIntent (gate precedence), got \(error)")
            }
        }
    }
}
