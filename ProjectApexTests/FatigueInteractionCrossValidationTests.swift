// FatigueInteractionCrossValidationTests.swift
// ProjectApexTests
//
// Cross-platform parity tests for `FatigueInteraction.consistencyFactor`,
// `countFactor`, and `confidence` (TraineeModelInteractions.swift:98-117)
// against the shared fixture file at docs/fixtures/fatigue-interaction.json.
//
// Per ADR-0005: the server-side Phase 2 fatigue-interaction aggregator (TS,
// supabase/functions/_shared/fatigue-interaction.ts) and the client-side
// Phase 1 value type (Swift, this file) must produce identical math on the
// same inputs. The fixture file is the single source of expected outputs;
// both sides assert against the same JSON to within 1e-12.
//
// A drift between the two implementations surfaces here on the Swift side or
// on the TS side at supabase/functions/_shared/fatigue-interaction_test.ts —
// whichever regressed.

import XCTest
@testable import ProjectApex

final class FatigueInteractionCrossValidationTests: XCTestCase {

    // MARK: ─── Fixture loading ────────────────────────────────────────────

    private struct ExpectedValues: Decodable {
        let consistencyFactor: Double
        let countFactor: Double
        let confidence: Double
    }

    private struct FixtureRow: Decodable {
        let name: String
        let observations: [Double]
        let totalCount: Int
        let expected: ExpectedValues
    }

    private struct FixtureFile: Decodable {
        let fixtures: [FixtureRow]
    }

    private static let fixtureFileURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()      // ProjectApexTests/
            .deletingLastPathComponent()      // ProjectApex/ (repo root)
            .appendingPathComponent("docs/fixtures/fatigue-interaction.json")
    }()

    private static let rows: [FixtureRow] = {
        let data = try! Data(contentsOf: fixtureFileURL)
        return try! JSONDecoder().decode(FixtureFile.self, from: data).fixtures
    }()

    // MARK: ─── Parity assertion ───────────────────────────────────────────

    /// One XCTest per fixture row. Failure-message includes the row name so
    /// a regression points at the specific behavior that drifted.
    func test_swiftMatchesFixtureExpectedValues() {
        for row in Self.rows {
            let interaction = FatigueInteraction(
                fromPattern: .squat,
                toPattern: .hipHinge,
                observations: row.observations,
                totalCount: row.totalCount
            )
            XCTAssertEqual(
                interaction.consistencyFactor,
                row.expected.consistencyFactor,
                accuracy: 1e-12,
                "consistencyFactor drifted on fixture '\(row.name)'"
            )
            XCTAssertEqual(
                interaction.countFactor,
                row.expected.countFactor,
                accuracy: 1e-12,
                "countFactor drifted on fixture '\(row.name)'"
            )
            XCTAssertEqual(
                interaction.confidence,
                row.expected.confidence,
                accuracy: 1e-12,
                "confidence drifted on fixture '\(row.name)'"
            )
        }
    }
}
