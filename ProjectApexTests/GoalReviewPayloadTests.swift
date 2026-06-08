// GoalReviewPayloadTests.swift
// ProjectApexTests
//
// P5-D06 Slice F2 (#258): unit tests for the pure payload helper behind the
// goal-review screen, `GoalReviewView.makeGoalPayload(...)`. SwiftUI bodies
// aren't unit-testable, so the wire-payload construction lives in a pure
// static function that takes `now: Date` (no hidden `Date()`) — these tests
// pin its behaviour deterministically.
//
// The same drift the #154 / Slice B contract locks apply: the encoded shape
// must match the `update-trainee-goal` Edge Function validator. These tests
// reuse the JSONEncoder-top-level-keys assertion style from
// `OnboardingGoalPayloadTests` to prove the OPTIONAL ack key OMITS when nil
// (so a non-banner Save keeps the wire shape exactly {user_id, goal}) and
// appears as a single snake_case key when present.
//
// `makeGoalPayload` + the two payload structs are `internal`, so `@testable`
// can call/encode them directly.

import XCTest
@testable import ProjectApex

final class GoalReviewPayloadTests: XCTestCase {

    /// Fixed instant for deterministic `updatedAt` assertions.
    private static let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Encodes a `makeGoalPayload` result the way the Save call site does
    /// (bare `JSONEncoder()`, no key strategy) and deserializes to a JSON
    /// object for top-level/sub-object key assertions.
    private func encode(_ payload: TraineeGoalUpsertPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded payload must deserialize to a JSON object"
        )
    }

    // MARK: ─── 1. focusAreas → sorted rawValue strings ─────────────────────────

    func test_makeGoalPayload_focusAreas_areSortedRawValues() {
        let payload = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [.legs, .back, .chest],
            triggeringSessionCount: nil,
            now: Self.fixedNow
        )

        XCTAssertEqual(
            payload.goal.focusAreas, ["back", "chest", "legs"],
            "focusAreas must be the rawValue strings, sorted for deterministic JSONB"
        )
    }

    func test_makeGoalPayload_emptyFocusAreas_encodeAsEmptyArray() throws {
        let payload = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [],
            triggeringSessionCount: nil,
            now: Self.fixedNow
        )

        XCTAssertEqual(payload.goal.focusAreas, [], "empty selection → empty array, no artifacts")

        // And it survives encoding as a JSON array (not null / not absent).
        let json = try encode(payload)
        let goal = try XCTUnwrap(json["goal"] as? [String: Any])
        let focusAreas = try XCTUnwrap(goal["focusAreas"] as? [Any],
            "focusAreas must encode as a JSON array even when empty")
        XCTAssertTrue(focusAreas.isEmpty, "empty focusAreas must encode as []")
    }

    // MARK: ─── 2. ack threaded; OPTIONAL key omits when nil ───────────────────

    func test_makeGoalPayload_ack_threadedThrough() {
        let withAck = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [],
            triggeringSessionCount: 7,
            now: Self.fixedNow
        )
        XCTAssertEqual(withAck.acknowledgeTriggeringSessionCount, 7,
            "non-nil triggeringSessionCount must thread straight through")

        let withoutAck = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [],
            triggeringSessionCount: nil,
            now: Self.fixedNow
        )
        XCTAssertNil(withoutAck.acknowledgeTriggeringSessionCount,
            "nil triggeringSessionCount must stay nil on the payload")
    }

    /// The load-bearing proof: a nil ack OMITS the key entirely (no `null`),
    /// so a Save opened outside the heavy-reassessment flow keeps the wire
    /// shape exactly {user_id, goal} — the same invariant the onboarding write
    /// depends on. (Synthesized `encodeIfPresent` from the Int? optional.)
    func test_makeGoalPayload_nilAck_omitsKey_topLevelIsUserIdAndGoal() throws {
        let payload = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [.chest],
            triggeringSessionCount: nil,
            now: Self.fixedNow
        )
        let json = try encode(payload)

        XCTAssertEqual(
            Set(json.keys), ["user_id", "goal"],
            "nil ack must omit acknowledge_triggering_session_count → wire shape stays {user_id, goal}"
        )
        XCTAssertNil(
            json["acknowledge_triggering_session_count"],
            "nil ack must encode as ABSENT, not `null`"
        )
        XCTAssertNil(json["userId"], "no camelCase `userId` may leak to the wire")
    }

    func test_makeGoalPayload_nonNilAck_addsExactlyOneSnakeCaseKey() throws {
        let payload = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [.chest],
            triggeringSessionCount: 7,
            now: Self.fixedNow
        )
        let json = try encode(payload)

        XCTAssertEqual(
            Set(json.keys), ["user_id", "goal", "acknowledge_triggering_session_count"],
            "non-nil ack adds EXACTLY one top-level snake_case key"
        )
        XCTAssertEqual(
            json["acknowledge_triggering_session_count"] as? Int, 7,
            "ack must encode as the integer value under the snake_case key"
        )
        XCTAssertNil(
            json["acknowledgeTriggeringSessionCount"],
            "no camelCase ack key may leak to the wire"
        )
    }

    // MARK: ─── 3. statement passthrough + updatedAt is ISO8601 round-trips ─────

    func test_makeGoalPayload_statement_passedVerbatim() {
        let statement = "Build a 200kg deadlift while staying injury-free"
        let payload = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: statement,
            focusAreas: [.back, .legs],
            triggeringSessionCount: nil,
            now: Self.fixedNow
        )
        XCTAssertEqual(payload.goal.statement, statement,
            "statement must be copied verbatim into the payload")
    }

    func test_makeGoalPayload_updatedAt_isISO8601_roundTripsToNow() throws {
        let payload = GoalReviewView.makeGoalPayload(
            userId: UUID(),
            statement: "Get stronger",
            focusAreas: [],
            triggeringSessionCount: nil,
            now: Self.fixedNow
        )

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try XCTUnwrap(
            parser.date(from: payload.goal.updatedAt),
            "updatedAt '\(payload.goal.updatedAt)' must parse back via ISO8601 (.withFractionalSeconds)"
        )

        XCTAssertEqual(
            parsed.timeIntervalSinceReferenceDate,
            Self.fixedNow.timeIntervalSinceReferenceDate,
            accuracy: 1.0,
            "updatedAt must round-trip to the `now` passed in (to the second)"
        )
    }
}
