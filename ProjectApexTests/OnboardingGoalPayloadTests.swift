// OnboardingGoalPayloadTests.swift
// ProjectApexTests
//
// Contract parity test (#154): the onboarding goal write
// (`OnboardingView.swift` ~:941) builds a `TraineeGoalUpsertPayload`,
// encodes it with a bare `JSONEncoder()`, and POSTs it to the
// `update-trainee-goal` Edge Function. The EF validator
// (`supabase/functions/update-trainee-goal/index.ts`, `validateRequest`)
// enforces an EXACT shape. Nothing currently proves the client payload
// encodes to a shape the validator accepts — a silent client/server schema
// drift here breaks onboarding goal hydration (the iOS side then reads
// `GoalState.placeholder`, the cold-start fallback).
//
// KEY SUBTLETY this test locks: the top-level key is snake_case (`user_id`)
// but the `goal` sub-object keys are CAMEL-CASE (`statement`/`focusAreas`/
// `updatedAt`). A well-meaning "consistency" refactor that snake-cases
// `GoalUpsertBody` (e.g. adding `focusAreas = "focus_areas"` CodingKeys)
// would silently break the EF — these assertions are the drift guard.
//
// The two payload structs are `internal` (not `private`) specifically so
// this test can encode them directly and assert the wire shape.

import XCTest
@testable import ProjectApex

final class OnboardingGoalPayloadTests: XCTestCase {

    // Replicated literally from `supabase/functions/update-trainee-goal/index.ts`.
    // If either regex changes there, this test must change in lockstep — that is
    // the whole point of the parity lock.
    //
    //   UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    private static let efUUIDRegex =
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    //   ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/
    private static let efISODateRegex =
        "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})$"

    /// Builds the payload EXACTLY the way the onboarding call site does
    /// (`OnboardingView.swift` ~:939-948): `updatedAt` via `ISO8601DateFormatter`
    /// with `[.withInternetDateTime, .withFractionalSeconds]`, encoded with a
    /// bare `JSONEncoder()` (no key strategy). The only departure is a fixed
    /// `Date` for determinism.
    private func encodeCallSitePayload(
        userId: UUID,
        at date: Date,
        acknowledge: Int? = nil
    ) throws -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = TraineeGoalUpsertPayload(
            userId: userId,
            goal: GoalUpsertBody(
                statement: "Hypertrophy",
                focusAreas: ["legs", "back"],
                updatedAt: isoFormatter.string(from: date)
            ),
            acknowledgeTriggeringSessionCount: acknowledge,
            stretchEdits: nil,
            acknowledgeCalibrationReview: nil
        )
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded payload must deserialize to a JSON object"
        )
    }

    // MARK: ─── Top-level shape: snake_case `user_id`, no camelCase leak ────────

    func test_payload_topLevelKeys_areExactlyUserIdAndGoal() throws {
        let userId = UUID()
        let json = try encodeCallSitePayload(
            userId: userId,
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )

        XCTAssertEqual(
            Set(json.keys), ["user_id", "goal"],
            "EF reads top-level `user_id` (snake_case) + `goal`; a camelCase " +
            "`userId` leak or any extra key would be rejected by validateRequest"
        )
        XCTAssertNil(json["userId"], "no camelCase `userId` may leak to the wire")
        // #258 Slice B: the new OPTIONAL ack field must encode as ABSENT (not
        // `null`) when nil, or onboarding's wire shape would no longer be
        // exactly {user_id, goal}. The synthesized `encodeIfPresent` omits it.
        XCTAssertNil(
            json["acknowledge_triggering_session_count"],
            "nil ack must omit the key entirely (no `null`) so onboarding stays {user_id, goal}"
        )
    }

    func test_payload_withAck_topLevelKeys_includeSnakeCaseAck() throws {
        let json = try encodeCallSitePayload(
            userId: UUID(),
            at: Date(timeIntervalSinceReferenceDate: 800_000_000),
            acknowledge: 42
        )

        // #258 Slice B: a non-nil ack adds EXACTLY one top-level snake_case key.
        XCTAssertEqual(
            Set(json.keys), ["user_id", "goal", "acknowledge_triggering_session_count"],
            "EF reads top-level `acknowledge_triggering_session_count` (snake_case)"
        )
        XCTAssertNil(
            json["acknowledgeTriggeringSessionCount"],
            "no camelCase `acknowledgeTriggeringSessionCount` may leak to the wire"
        )

        // Value encodes as an Int (JSON number) == 42.
        XCTAssertEqual(
            json["acknowledge_triggering_session_count"] as? Int, 42,
            "ack must encode as the integer value, snake_case key"
        )

        // The goal sub-object is unaffected — still the #154-locked camelCase set.
        let goal = try XCTUnwrap(json["goal"] as? [String: Any])
        XCTAssertEqual(
            Set(goal.keys), ["statement", "focusAreas", "updatedAt"],
            "ack must not perturb the goal sub-object shape"
        )
    }

    func test_payload_userId_matchesEFUUIDRegex() throws {
        let userId = UUID()
        let json = try encodeCallSitePayload(
            userId: userId,
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )

        let userIdString = try XCTUnwrap(json["user_id"] as? String,
            "user_id must encode as a String")
        // EF gate: `typeof user_id === "string" && UUID_RE.test(user_id)`.
        // UUID_RE carries the /i flag, so UUID().uuidString (uppercase) matches.
        XCTAssertNotNil(
            userIdString.range(
                of: Self.efUUIDRegex,
                options: [.regularExpression, .caseInsensitive]
            ),
            "user_id '\(userIdString)' must match the EF UUID_RE"
        )
    }

    // MARK: ─── Goal sub-object: CAMEL-case keys (the drift guard) ──────────────

    func test_goal_subObjectKeys_areExactlyCamelCase() throws {
        let json = try encodeCallSitePayload(
            userId: UUID(),
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let goal = try XCTUnwrap(json["goal"] as? [String: Any],
            "goal must encode as a JSON object")

        // Exact key set — present in camelCase, nothing extra.
        XCTAssertEqual(
            Set(goal.keys), ["statement", "focusAreas", "updatedAt"],
            "EF reads goal.statement / goal.focusAreas / goal.updatedAt verbatim"
        )

        // Explicit camelCase presence + snake_case absence == the drift guard.
        XCTAssertNotNil(goal["focusAreas"], "goal.focusAreas must be camelCase")
        XCTAssertNotNil(goal["updatedAt"], "goal.updatedAt must be camelCase")
        XCTAssertNil(
            goal["focus_areas"],
            "snake_case goal.focus_areas would be invisible to the EF validator"
        )
        XCTAssertNil(
            goal["updated_at"],
            "snake_case goal.updated_at would be invisible to the EF validator"
        )
    }

    func test_goal_statementAndFocusAreas_haveExpectedTypes() throws {
        let json = try encodeCallSitePayload(
            userId: UUID(),
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let goal = try XCTUnwrap(json["goal"] as? [String: Any])

        XCTAssertTrue(goal["statement"] is String,
            "EF gate: typeof g.statement === 'string'")
        XCTAssertTrue(goal["focusAreas"] is [Any],
            "EF gate: Array.isArray(g.focusAreas)")
        let focusAreas = try XCTUnwrap(goal["focusAreas"] as? [Any])
        for element in focusAreas {
            XCTAssertTrue(element is String,
                "EF gate: each goal.focusAreas[i] must be a string")
        }
    }

    // MARK: ─── Highest-value assertion: formatter output ↔ server ISO regex ────

    func test_goal_updatedAt_matchesEFISODateRegex() throws {
        let json = try encodeCallSitePayload(
            userId: UUID(),
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let goal = try XCTUnwrap(json["goal"] as? [String: Any])
        let updatedAt = try XCTUnwrap(goal["updatedAt"] as? String,
            "goal.updatedAt must encode as a String")

        // EF gate: `typeof g.updatedAt === "string" && ISO_DATE_RE.test(g.updatedAt)`.
        // This is the highest-value parity check: the client's
        // ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])
        // output must satisfy the server's ISO_DATE_RE.
        XCTAssertNotNil(
            updatedAt.range(of: Self.efISODateRegex, options: .regularExpression),
            "goal.updatedAt '\(updatedAt)' must match the EF ISO_DATE_RE"
        )
    }
}
