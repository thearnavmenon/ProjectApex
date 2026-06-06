// SetLogPayloadEncoderTests.swift
// ProjectApexTests — regression tests for set_logs encoders (#66)
//
// PR #64 fixed a production data-loss bug: the three Encodable payloads that
// INSERT into `set_logs` were silently dropping `intent` and `local_date`,
// producing 23502 NOT NULL violations on the server. The fix shipped WITHOUT
// regression tests; these are them.
//
// Every payload that writes a row into `set_logs` MUST serialise both
// `intent` (SetIntent.rawValue) and `local_date` (yyyy-MM-dd via
// SetLog.formatLocalDate). These tests encode each payload to JSON and assert
// the full snake_case shape, the intent rawValue (two cases), the local_date
// format, and the ABSENCE of `ai_prescribed` (which the schema for these
// insert paths does not carry).
//
// Encoders under test (each maps intent→"intent", localDate→"local_date"):
//   • SetLogPayload      — WorkoutSessionManager.swift  (workout-session flush)
//   • ManualSetLogPayload — ManualSessionLogView.swift  (freestyle manual log)
//   • NewSetLogPayload   — ProgramDayDetailView.swift   (add-set-to-completed)
//
// All three are reachable here because #66 relaxed their visibility to
// internal (and hoisted NewSetLogPayload to file scope) purely for this test.

import XCTest
@testable import ProjectApex

final class SetLogPayloadEncoderTests: XCTestCase {

    // MARK: - Constants

    /// Required snake_case keys every set_logs INSERT payload must serialise.
    private let requiredKeys: Set<String> = [
        "id", "session_id", "exercise_id", "set_number", "weight_kg",
        "reps_completed", "logged_at", "primary_muscle", "local_date", "intent",
    ]

    /// yyyy-MM-dd, timezone-immune shape (the assertion that guards the bug).
    private let localDatePattern = #"^\d{4}-\d{2}-\d{2}$"#

    // MARK: - Helpers

    private func encodeToDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Encoded payload was not a JSON object"
        )
    }

    private func makeSetLog(loggedAt: Date) -> SetLog {
        // intent is NOT read off SetLog by the encoders — it is passed as a
        // separate, required init parameter — so the value carried here is
        // deliberately irrelevant to what the payload serialises.
        SetLog(
            id: UUID(),
            sessionId: UUID(),
            exerciseId: "barbell_bench_press",
            setNumber: 2,
            weightKg: 100.0,
            repsCompleted: 5,
            rpeFelt: 8,
            rirEstimated: 2,
            aiPrescribed: nil,
            loggedAt: loggedAt,
            primaryMuscle: "pectoralis_major",
            intent: nil
        )
    }

    /// Asserts the invariants shared by every set_logs INSERT payload.
    private func assertSetLogRowShape(
        _ dict: [String: Any],
        expectedIntent: SetIntent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 1. All required snake_case keys present (incl. local_date + intent).
        for key in requiredKeys {
            XCTAssertNotNil(dict[key], "missing key '\(key)'", file: file, line: line)
        }

        // 2. intent equals the SetIntent rawValue.
        XCTAssertEqual(
            dict["intent"] as? String, expectedIntent.rawValue,
            "intent should be the SetIntent rawValue", file: file, line: line
        )

        // 3. local_date matches yyyy-MM-dd (timezone-immune shape check).
        let localDate = dict["local_date"] as? String
        XCTAssertNotNil(localDate, "local_date should be a string", file: file, line: line)
        XCTAssertNotNil(
            localDate?.range(of: localDatePattern, options: .regularExpression),
            "local_date '\(localDate ?? "nil")' should match \(localDatePattern)",
            file: file, line: line
        )

        // 4. ai_prescribed is ABSENT — these insert paths do not carry it.
        XCTAssertNil(
            dict["ai_prescribed"], "ai_prescribed must not be serialised on set_logs inserts",
            file: file, line: line
        )
    }

    // MARK: - SetLogPayload (workout-session flush)

    func test_setLogPayload_topIntent_serialisesIntentAndLocalDate() throws {
        let log = makeSetLog(loggedAt: Date(timeIntervalSince1970: 1_781_524_800))
        let dict = try encodeToDict(SetLogPayload(from: log, intent: .top))
        assertSetLogRowShape(dict, expectedIntent: .top)
    }

    func test_setLogPayload_backoffIntent_serialisesIntentAndLocalDate() throws {
        let log = makeSetLog(loggedAt: Date(timeIntervalSince1970: 1_781_524_800))
        let dict = try encodeToDict(SetLogPayload(from: log, intent: .backoff))
        assertSetLogRowShape(dict, expectedIntent: .backoff)
    }

    // MARK: - ManualSetLogPayload (freestyle manual log)

    func test_manualSetLogPayload_topIntent_serialisesIntentAndLocalDate() throws {
        let log = makeSetLog(loggedAt: Date(timeIntervalSince1970: 1_781_524_800))
        let dict = try encodeToDict(ManualSetLogPayload(from: log, intent: .top))
        assertSetLogRowShape(dict, expectedIntent: .top)
    }

    func test_manualSetLogPayload_backoffIntent_serialisesIntentAndLocalDate() throws {
        let log = makeSetLog(loggedAt: Date(timeIntervalSince1970: 1_781_524_800))
        let dict = try encodeToDict(ManualSetLogPayload(from: log, intent: .backoff))
        assertSetLogRowShape(dict, expectedIntent: .backoff)
    }

    // MARK: - NewSetLogPayload (add-set-to-completed)

    /// NewSetLogPayload takes local_date as a constructed argument (unlike the
    /// two `from:` encoders, which compute it internally with the host TZ), so
    /// we build it with an EXPLICIT timezone — no CI-machine TZ flake.
    private func makeNewSetLogPayload(intent: SetIntent) -> NewSetLogPayload {
        let loggedAt = Date(timeIntervalSince1970: 1_781_524_800)
        let tz = TimeZone(identifier: "America/New_York")!
        return NewSetLogPayload(
            id: UUID().uuidString,
            sessionId: UUID().uuidString,
            exerciseId: "barbell_bench_press",
            loggedAt: ISO8601DateFormatter().string(from: loggedAt),
            setNumber: 3,
            repsCompleted: 5,
            weightKg: 100.0,
            rpeFelt: 8,
            rirEstimated: 2,
            primaryMuscle: "pectoralis_major",
            localDate: SetLog.formatLocalDate(loggedAt, in: tz),
            intent: intent.rawValue
        )
    }

    func test_newSetLogPayload_topIntent_serialisesIntentAndLocalDate() throws {
        let dict = try encodeToDict(makeNewSetLogPayload(intent: .top))
        assertSetLogRowShape(dict, expectedIntent: .top)
    }

    func test_newSetLogPayload_backoffIntent_serialisesIntentAndLocalDate() throws {
        let dict = try encodeToDict(makeNewSetLogPayload(intent: .backoff))
        assertSetLogRowShape(dict, expectedIntent: .backoff)
    }

    // MARK: - SetLog.formatLocalDate (explicit timezone → deterministic)

    /// The local_date producer must yield a yyyy-MM-dd string interpreted in the
    /// timezone it is given, regardless of host locale/TZ — the property the
    /// shape checks above rely on. Pinning an explicit TZ makes the exact value
    /// deterministic on any CI machine.
    func test_formatLocalDate_explicitTimeZone_isDeterministic() {
        // 2026-06-15T03:00:00Z — chosen so two zones straddle the day boundary.
        let instant = Date(timeIntervalSince1970: 1_781_492_400)

        // New York (UTC-4 in June) → still the 14th locally.
        XCTAssertEqual(
            SetLog.formatLocalDate(instant, in: TimeZone(identifier: "America/New_York")!),
            "2026-06-14"
        )
        // Tokyo (UTC+9) → already the 15th locally.
        XCTAssertEqual(
            SetLog.formatLocalDate(instant, in: TimeZone(identifier: "Asia/Tokyo")!),
            "2026-06-15"
        )
        // UTC at noon → unambiguously the 15th, and matches the yyyy-MM-dd shape.
        let noon = Date(timeIntervalSince1970: 1_781_524_800)
        XCTAssertEqual(
            SetLog.formatLocalDate(noon, in: TimeZone(identifier: "UTC")!),
            "2026-06-15"
        )
    }
}
