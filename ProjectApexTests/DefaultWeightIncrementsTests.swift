// DefaultWeightIncrementsTests.swift
// ProjectApexTests
//
// Unit tests for DefaultWeightIncrements.
//
// Covers:
//   • defaults(for:) returns correct arrays per equipment type
//   • nearestWeights(to:for:excluding:) finds correct lower/upper neighbours
//   • Edge cases: prescribed below min, above max, exactly on value, excluding values

import XCTest
@testable import ProjectApex

final class DefaultWeightIncrementsTests: XCTestCase {

    // MARK: ─── defaults(for:) ─────────────────────────────────────────────────

    func test_defaults_dumbbells_startAt2_5() {
        let weights = DefaultWeightIncrements.defaults(for: .dumbbellSet)
        XCTAssertFalse(weights.isEmpty)
        XCTAssertEqual(weights.first!, 2.5, accuracy: 0.001)
    }

    func test_defaults_dumbbells_endAt60() {
        let weights = DefaultWeightIncrements.defaults(for: .dumbbellSet)
        XCTAssertEqual(weights.last!, 60.0, accuracy: 0.001)
    }

    func test_defaults_barbells_startAt20() {
        let weights = DefaultWeightIncrements.defaults(for: .barbell)
        XCTAssertFalse(weights.isEmpty)
        XCTAssertEqual(weights.first!, 20.0, accuracy: 0.001,
            "Barbell loadings start at 20kg (empty bar)")
    }

    func test_defaults_barbells_endAt200() {
        let weights = DefaultWeightIncrements.defaults(for: .barbell)
        XCTAssertEqual(weights.last!, 200.0, accuracy: 0.001)
    }

    func test_defaults_barbells_in2_5kgSteps() {
        let weights = DefaultWeightIncrements.defaults(for: .barbell)
        for i in 1..<weights.count {
            XCTAssertEqual(weights[i] - weights[i-1], 2.5, accuracy: 0.001,
                "Barbell loadings must increment by 2.5kg between index \(i-1) and \(i)")
        }
    }

    func test_defaults_cableMachine_returnsStack() {
        let weights = DefaultWeightIncrements.defaults(for: .cableMachine)
        XCTAssertFalse(weights.isEmpty)
        XCTAssertEqual(weights.first!, 5.0, accuracy: 0.001)
        XCTAssertEqual(weights.last!, 100.0, accuracy: 0.001)
    }

    func test_defaults_latPulldown_returnsCableStack() {
        // latPulldown maps to cableStack
        XCTAssertEqual(
            DefaultWeightIncrements.defaults(for: .latPulldown),
            DefaultWeightIncrements.cableStack
        )
    }

    func test_defaults_cableMachineDual_returnsCableStack() {
        XCTAssertEqual(
            DefaultWeightIncrements.defaults(for: .cableMachineDual),
            DefaultWeightIncrements.cableStack
        )
    }

    func test_defaults_kettlebellSet_returnsKettlebells() {
        let weights = DefaultWeightIncrements.defaults(for: .kettlebellSet)
        XCTAssertFalse(weights.isEmpty)
        XCTAssertEqual(weights.first!, 4.0, accuracy: 0.001)
        XCTAssertEqual(weights.last!, 40.0, accuracy: 0.001)
    }

    func test_defaults_adjustableBench_returnsEmpty() {
        // Equipment with no weight loading returns []
        let weights = DefaultWeightIncrements.defaults(for: .adjustableBench)
        XCTAssertTrue(weights.isEmpty)
    }

    func test_defaults_pullUpBar_returnsEmpty() {
        let weights = DefaultWeightIncrements.defaults(for: .pullUpBar)
        XCTAssertTrue(weights.isEmpty)
    }

    // MARK: ─── nearestWeights(to:for:excluding:) ─────────────────────────────

    func test_nearestWeights_dumbbells_midRange() throws {
        // Prescribed: 22 kg, nearest lower=20, upper=22.5
        let result = DefaultWeightIncrements.nearestWeights(to: 22.0, for: .dumbbellSet)
        XCTAssertEqual(try XCTUnwrap(result.lower), 20.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.upper), 22.5, accuracy: 0.001)
    }

    func test_nearestWeights_dumbbells_exactMatch_returnsAdjacentNeighbours() throws {
        // Prescribed exactly on a known value (25 kg)
        let result = DefaultWeightIncrements.nearestWeights(to: 25.0, for: .dumbbellSet)
        // lower should be 22.5, upper should be 27.5 (strict < and > comparisons)
        XCTAssertEqual(try XCTUnwrap(result.lower), 22.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.upper), 27.5, accuracy: 0.001)
    }

    func test_nearestWeights_dumbbells_belowMinimum_lowerIsNil() throws {
        // Prescribed below the minimum (e.g. 1 kg)
        let result = DefaultWeightIncrements.nearestWeights(to: 1.0, for: .dumbbellSet)
        XCTAssertNil(result.lower, "No lower neighbour exists below the minimum weight")
        XCTAssertEqual(try XCTUnwrap(result.upper), 2.5, accuracy: 0.001)
    }

    func test_nearestWeights_dumbbells_aboveMaximum_upperIsNil() throws {
        // Prescribed above the maximum (e.g. 100 kg)
        let result = DefaultWeightIncrements.nearestWeights(to: 100.0, for: .dumbbellSet)
        XCTAssertEqual(try XCTUnwrap(result.lower), 60.0, accuracy: 0.001)
        XCTAssertNil(result.upper, "No upper neighbour exists above the maximum weight")
    }

    func test_nearestWeights_withExclusions_skipsExcludedValues() throws {
        // Prescribed: 22 kg, lower=20 is excluded, so lower should fall back to 17.5
        let result = DefaultWeightIncrements.nearestWeights(
            to: 22.0,
            for: .dumbbellSet,
            excluding: [20.0]
        )
        XCTAssertEqual(try XCTUnwrap(result.lower), 17.5, accuracy: 0.001,
            "Excluded value 20 must be skipped; next lower should be 17.5")
        XCTAssertEqual(try XCTUnwrap(result.upper), 22.5, accuracy: 0.001)
    }

    func test_nearestWeights_equipmentWithNoDefaults_returnsNilBoth() {
        let result = DefaultWeightIncrements.nearestWeights(to: 50.0, for: .adjustableBench)
        XCTAssertNil(result.lower)
        XCTAssertNil(result.upper)
    }

    func test_nearestWeights_barbells_midRange() throws {
        // Prescribed: 85 kg. Nearest lower=85 is not strictly <, so lower=82.5, upper=87.5
        let result = DefaultWeightIncrements.nearestWeights(to: 86.0, for: .barbell)
        XCTAssertEqual(try XCTUnwrap(result.lower), 85.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.upper), 87.5, accuracy: 0.001)
    }
}
