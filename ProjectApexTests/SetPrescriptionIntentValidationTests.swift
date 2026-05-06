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
    private func envelope(intent: String?, extras: String = "") -> Data {
        let intentLine = intent.map { ",\n    \"intent\": \"\($0)\"" } ?? ""
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
          "confidence": 0.85\(intentLine)\(extras)
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
          "intent": \(intentFragment)
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
            intent: .backoff
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SetPrescription.self, from: encoded)
        XCTAssertEqual(decoded.intent, .backoff)
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
            intent: nil
        )
        let encoded = try JSONEncoder().encode(p)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"intent\""),
                       "Encoder must omit intent when nil.")
    }
}
