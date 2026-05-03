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
}
