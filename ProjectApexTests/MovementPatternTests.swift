// MovementPatternTests.swift
// ProjectApexTests
//
// Verifies MovementPattern enum (introduced by Phase 1 / Slice 1).
// Schema source: ADR-0005, taxonomy mirrors the 8 existing codebase strings.

import Testing
import Foundation
@testable import ProjectApex

@Suite("MovementPattern")
struct MovementPatternTests {
    @Test("horizontalPush round-trips via Codable as \"horizontal_push\"")
    func codableRoundTripHorizontalPush() throws {
        let original = MovementPattern.horizontalPush
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MovementPattern.self, from: encoded)
        #expect(decoded == original)
        #expect(String(data: encoded, encoding: .utf8) == "\"horizontal_push\"")
    }

    @Test("allCases mirrors the 8 codebase-existing patterns; .calves and .core absent")
    func allCasesMatchCodebaseTaxonomy() {
        let expectedRawValues: Set<String> = [
            "hip_hinge", "horizontal_pull", "horizontal_push", "isolation",
            "lunge", "squat", "vertical_pull", "vertical_push",
        ]
        let actualRawValues = Set(MovementPattern.allCases.map(\.rawValue))
        #expect(actualRawValues == expectedRawValues)
        #expect(MovementPattern.allCases.count == 8)
        #expect(!actualRawValues.contains("calves"))
        #expect(!actualRawValues.contains("core"))
    }

    @Test("displayName humanizes a representative sample (#258)")
    func displayNameRepresentativeSample() {
        #expect(MovementPattern.squat.displayName == "Squat")
        #expect(MovementPattern.horizontalPush.displayName == "Horizontal Push")
        #expect(MovementPattern.hipHinge.displayName == "Hip Hinge")
        #expect(MovementPattern.verticalPull.displayName == "Vertical Pull")
    }

    @Test("every case's displayName is humanized — no underscores, no raw machine token leaks")
    func displayNameExhaustivenessGuard() {
        for pattern in MovementPattern.allCases {
            // No display name should leak the snake_case machine token.
            #expect(
                !pattern.displayName.contains("_"),
                "displayName for \(pattern) contains an underscore: \(pattern.displayName)"
            )
            // Multi-token patterns must not equal their raw value verbatim
            // (i.e. they got humanized rather than falling back to the token).
            if pattern.rawValue.contains("_") {
                #expect(
                    pattern.displayName != pattern.rawValue,
                    "displayName for \(pattern) equals its raw token: \(pattern.rawValue)"
                )
            }
        }
    }
}
