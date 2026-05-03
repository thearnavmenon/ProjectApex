// MuscleTaxonomyTests.swift
// ProjectApexTests
//
// Verifies PrimaryMuscle (9 fine-grained cases) and MuscleGroup
// (locked-six per ADR-0005) plus the PrimaryMuscle.muscleGroup mapping.

import Testing
import Foundation
@testable import ProjectApex

@Suite("PrimaryMuscle")
struct PrimaryMuscleTests {
    @Test("allCases has 9 cases; .core absent")
    func nineCasesNoCore() {
        let expected: Set<String> = [
            "back", "chest", "biceps", "shoulders", "triceps",
            "quads", "hamstrings", "glutes", "calves",
        ]
        let actual = Set(PrimaryMuscle.allCases.map(\.rawValue))
        #expect(actual == expected)
        #expect(PrimaryMuscle.allCases.count == 9)
        #expect(!actual.contains("core"))
    }

    @Test("Codable round-trip uses raw string values")
    func codableRoundTrip() throws {
        for muscle in PrimaryMuscle.allCases {
            let encoded = try JSONEncoder().encode(muscle)
            let decoded = try JSONDecoder().decode(PrimaryMuscle.self, from: encoded)
            #expect(decoded == muscle)
        }
    }
}

@Suite("MuscleGroup")
struct MuscleGroupTests {
    @Test("allCases is the locked-six per ADR-0005")
    func sixCasesLocked() {
        let expected: Set<String> = ["back", "chest", "biceps", "shoulders", "triceps", "legs"]
        let actual = Set(MuscleGroup.allCases.map(\.rawValue))
        #expect(actual == expected)
        #expect(MuscleGroup.allCases.count == 6)
    }

    @Test("Codable round-trip uses raw string values")
    func codableRoundTrip() throws {
        for group in MuscleGroup.allCases {
            let encoded = try JSONEncoder().encode(group)
            let decoded = try JSONDecoder().decode(MuscleGroup.self, from: encoded)
            #expect(decoded == group)
        }
    }
}

@Suite("PrimaryMuscle.muscleGroup")
struct PrimaryMuscleMappingTests {
    @Test("Leg subgroups collapse to .legs")
    func legSubgroupsCollapse() {
        #expect(PrimaryMuscle.quads.muscleGroup == .legs)
        #expect(PrimaryMuscle.hamstrings.muscleGroup == .legs)
        #expect(PrimaryMuscle.glutes.muscleGroup == .legs)
        #expect(PrimaryMuscle.calves.muscleGroup == .legs)
    }

    @Test("Upper-body muscles map 1:1")
    func upperBodyOneToOne() {
        #expect(PrimaryMuscle.back.muscleGroup == .back)
        #expect(PrimaryMuscle.chest.muscleGroup == .chest)
        #expect(PrimaryMuscle.biceps.muscleGroup == .biceps)
        #expect(PrimaryMuscle.shoulders.muscleGroup == .shoulders)
        #expect(PrimaryMuscle.triceps.muscleGroup == .triceps)
    }
}
