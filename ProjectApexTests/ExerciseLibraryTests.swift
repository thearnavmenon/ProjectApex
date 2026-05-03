// ExerciseLibraryTests.swift
// ProjectApexTests
//
// Verifies:
//   1. All exercises have unique IDs
//   2. byId dictionary is complete and correct
//   3. lookup() resolves canonical IDs directly
//   4. lookup() resolves known normalization map variants
//   5. lookup() returns nil for unknown exercise IDs
//   6. primaryMuscle(for:) convenience returns correct PrimaryMuscle cases
//   7. All exercises reference valid EquipmentType typeKey strings
//   8. Synergist values use the broader-than-PrimaryMuscle vocabulary correctly
//   9. promptReferenceBlock() contains every exercise ID
//  10. All normalization map values point to valid canonical IDs
//  11. Slice 1 — no exercise is core-classified (the 4 core entries were removed)
//  12. Slice 1 — every entry's primaryMuscle is a valid PrimaryMuscle case
//      (vacuous via the type system, kept for documentation) and every entry's
//      movementPattern is a valid MovementPattern case (also type-enforced)

import Testing
import Foundation
@testable import ProjectApex

// MARK: - Valid EquipmentType typeKeys

/// The set of valid equipment_type keys from EquipmentType in GymProfile.swift.
/// Must stay in sync with EquipmentType enum cases.
private let validEquipmentTypeKeys: Set<String> = [
    "dumbbell_set", "barbell", "ez_curl_bar",
    "cable_machine_single", "cable_machine_dual",
    "smith_machine", "leg_press", "hack_squat",
    "adjustable_bench", "flat_bench", "incline_bench",
    "pull_up_bar", "dip_station", "resistance_bands",
    "kettlebell_set", "power_rack", "squat_rack",
    "lat_pulldown", "seated_row",
    "chest_press_machine", "shoulder_press_machine",
    "leg_extension", "leg_curl",
    "pec_deck", "preacher_curl", "cable_crossover",
]

/// Synergists use a broader vocabulary than PrimaryMuscle — "forearms" is
/// a valid synergist hint on bicep curls but isn't a first-class trainee-model
/// muscle group. This set is the union of PrimaryMuscle's raw values and the
/// known broader hints.
private let validSynergistMuscles: Set<String> = Set(PrimaryMuscle.allCases.map(\.rawValue))
    .union(["forearms"])

// MARK: - ExerciseLibraryTests

@Suite("ExerciseLibrary")
struct ExerciseLibraryTests {

    // MARK: Basic integrity

    @Test("All exercises have unique IDs")
    func uniqueIds() {
        let ids = ExerciseLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count, "Duplicate exercise IDs found: \(findDuplicates(ids))")
    }

    @Test("byId dictionary count matches all count")
    func byIdComplete() {
        #expect(ExerciseLibrary.byId.count == ExerciseLibrary.all.count)
    }

    @Test("byId maps each ID to the correct definition")
    func byIdCorrectMapping() {
        for ex in ExerciseLibrary.all {
            let looked = ExerciseLibrary.byId[ex.id]
            #expect(looked != nil, "byId missing entry for '\(ex.id)'")
            #expect(looked?.id == ex.id)
            #expect(looked?.name == ex.name)
        }
    }

    // MARK: lookup() — direct resolution

    @Test("lookup returns correct definition for canonical ID")
    func lookupKnownExercise() {
        let def = ExerciseLibrary.lookup("barbell_bench_press")
        #expect(def != nil)
        #expect(def?.primaryMuscle == .chest)
        #expect(def?.equipmentType == "barbell")
        #expect(def?.movementPattern == .horizontalPush)
    }

    @Test("lookup resolves all canonical IDs in all[]")
    func lookupAllCanonical() {
        for ex in ExerciseLibrary.all {
            let result = ExerciseLibrary.lookup(ex.id)
            #expect(result != nil, "lookup() failed for canonical ID '\(ex.id)'")
        }
    }

    @Test("lookup returns nil for unknown exercise ID")
    func lookupUnknownReturnsNil() {
        #expect(ExerciseLibrary.lookup("imaginary_exercise_xyz_999") == nil)
        #expect(ExerciseLibrary.lookup("") == nil)
    }

    // MARK: lookup() — normalization map resolution

    @Test("lookup resolves 'bench_press' variant via normalization map")
    func lookupNormalizedBenchPress() {
        let def = ExerciseLibrary.lookup("bench_press")
        #expect(def?.id == "barbell_bench_press")
    }

    @Test("lookup resolves 'bent_over_row' variant via normalization map")
    func lookupNormalizedBentOverRow() {
        let def = ExerciseLibrary.lookup("bent_over_row")
        #expect(def?.id == "barbell_row")
    }

    @Test("lookup resolves 'squat' variant via normalization map")
    func lookupNormalizedSquat() {
        let def = ExerciseLibrary.lookup("squat")
        #expect(def?.id == "barbell_back_squat")
    }

    @Test("lookup resolves 'deadlift' variant via normalization map")
    func lookupNormalizedDeadlift() {
        let def = ExerciseLibrary.lookup("deadlift")
        #expect(def?.id == "conventional_deadlift")
    }

    @Test("lookup resolves 'rdl' abbreviation via normalization map")
    func lookupNormalizedRDL() {
        let def = ExerciseLibrary.lookup("rdl")
        #expect(def?.id == "romanian_deadlift")
    }

    @Test("lookup resolves 'ohp' abbreviation via normalization map")
    func lookupNormalizedOHP() {
        let def = ExerciseLibrary.lookup("ohp")
        #expect(def?.id == "overhead_press")
    }

    @Test("lookup resolves 'pull_up' variant via normalization map")
    func lookupNormalizedPullUp() {
        let def = ExerciseLibrary.lookup("pull_up")
        #expect(def?.id == "pull_ups")
    }

    @Test("lookup resolves 'barbell_hip_thrust' legacy variant via normalization map")
    func lookupNormalizedHipThrust() {
        let def = ExerciseLibrary.lookup("barbell_hip_thrust")
        #expect(def?.id == "hip_thrust")
    }

    @Test("lookup resolves 'lat_pull_down' typo variant via normalization map")
    func lookupNormalizedLatPullDown() {
        let def = ExerciseLibrary.lookup("lat_pull_down")
        #expect(def?.id == "lat_pulldown_wide")
    }

    @Test("bare 'lat_pulldown' is intentionally NOT normalized (ambiguous width)")
    func lookupBareLatPulldownIsUnresolved() {
        // 'lat_pulldown' without _wide/_close suffix is ambiguous.
        // It is intentionally excluded from the normalization map.
        // The backfill script will surface it as unresolved for human review.
        #expect(ExerciseLibrary.lookup("lat_pulldown") == nil)
    }

    // MARK: primaryMuscle(for:) convenience — typed result per Slice 1

    @Test("primaryMuscle returns correct PrimaryMuscle for canonical ID")
    func primaryMuscleConvenienceCanonical() {
        #expect(ExerciseLibrary.primaryMuscle(for: "barbell_back_squat") == .quads)
        #expect(ExerciseLibrary.primaryMuscle(for: "conventional_deadlift") == .hamstrings)
        #expect(ExerciseLibrary.primaryMuscle(for: "overhead_press") == .shoulders)
        #expect(ExerciseLibrary.primaryMuscle(for: "cable_tricep_pushdown") == .triceps)
        #expect(ExerciseLibrary.primaryMuscle(for: "hip_thrust") == .glutes)
        #expect(ExerciseLibrary.primaryMuscle(for: "standing_calf_raise") == .calves)
    }

    @Test("primaryMuscle returns correct PrimaryMuscle via normalization map")
    func primaryMuscleConvenienceNormalized() {
        #expect(ExerciseLibrary.primaryMuscle(for: "bench_press") == .chest)
        #expect(ExerciseLibrary.primaryMuscle(for: "rdl") == .hamstrings)
    }

    @Test("primaryMuscle returns nil for unknown exercise")
    func primaryMuscleNilForUnknown() {
        #expect(ExerciseLibrary.primaryMuscle(for: "not_a_real_exercise") == nil)
    }

    // MARK: Equipment type validity

    @Test("All exercises reference valid EquipmentType typeKey strings")
    func validEquipmentTypes() {
        var invalid: [String] = []
        for ex in ExerciseLibrary.all {
            if !validEquipmentTypeKeys.contains(ex.equipmentType) {
                invalid.append("\(ex.id): '\(ex.equipmentType)'")
            }
        }
        #expect(invalid.isEmpty, "Exercises with invalid equipment types:\n\(invalid.joined(separator: "\n"))")
    }

    // MARK: Synergist validity (synergists remain [String] for broader vocabulary)

    @Test("All synergist values are valid muscle hint strings")
    func validSynergists() {
        var invalid: [String] = []
        for ex in ExerciseLibrary.all {
            for s in ex.synergists where !validSynergistMuscles.contains(s) {
                invalid.append("\(ex.id): synergist '\(s)'")
            }
        }
        #expect(invalid.isEmpty, "Exercises with invalid synergists:\n\(invalid.joined(separator: "\n"))")
    }

    // MARK: Slice 1 — classification-consistency + content-removal guards

    @Test("No exercise has primaryMuscle outside the 9-case PrimaryMuscle set")
    func primaryMuscleAlwaysInTaxonomy() {
        // Type-system enforced. This test documents the contract and would
        // catch any compile-level regression where ExerciseDefinition.primaryMuscle
        // was widened back to String.
        let valid = Set(PrimaryMuscle.allCases.map(\.rawValue))
        for ex in ExerciseLibrary.all {
            #expect(valid.contains(ex.primaryMuscle.rawValue))
        }
    }

    @Test("No exercise has movementPattern outside the 8-case MovementPattern set")
    func movementPatternAlwaysInTaxonomy() {
        let valid = Set(MovementPattern.allCases.map(\.rawValue))
        for ex in ExerciseLibrary.all {
            #expect(valid.contains(ex.movementPattern.rawValue))
        }
    }

    @Test("No core exercises remain — the 4 core entries were removed in Slice 1")
    func coreExercisesRemoved() {
        let coreIds = ["cable_crunch", "hanging_leg_raise", "ab_wheel_rollout", "plank"]
        for id in coreIds {
            #expect(ExerciseLibrary.byId[id] == nil,
                    "Expected core exercise '\(id)' to be absent from ExerciseLibrary")
        }
    }

    @Test("No synergist string equals 'core'")
    func noCoreInSynergists() {
        for ex in ExerciseLibrary.all {
            #expect(!ex.synergists.contains("core"),
                    "\(ex.id) lists 'core' as a synergist — core is excluded from the trainee-model taxonomy")
        }
    }

    // MARK: Normalization map integrity

    @Test("All normalization map values are valid canonical IDs")
    func normMapValuesAreCanonical() {
        var invalid: [String] = []
        for (variant, canonical) in ExerciseLibrary.normalizationMap {
            if ExerciseLibrary.byId[canonical] == nil {
                invalid.append("'\(variant)' → '\(canonical)' (canonical ID not found)")
            }
        }
        #expect(invalid.isEmpty, "Normalization map entries pointing to non-existent canonical IDs:\n\(invalid.joined(separator: "\n"))")
    }

    @Test("No normalization map key is itself a canonical ID")
    func normMapKeysAreNotCanonical() {
        var collisions: [String] = []
        for key in ExerciseLibrary.normalizationMap.keys {
            if ExerciseLibrary.byId[key] != nil {
                collisions.append("'\(key)' is both a canonical ID and a normalization map key")
            }
        }
        #expect(collisions.isEmpty, "Normalization key/canonical ID collisions:\n\(collisions.joined(separator: "\n"))")
    }

    // MARK: promptReferenceBlock()

    @Test("promptReferenceBlock contains every canonical exercise ID")
    func promptBlockContainsAllIds() {
        let block = ExerciseLibrary.promptReferenceBlock()
        var missing: [String] = []
        for ex in ExerciseLibrary.all {
            if !block.contains(ex.id) {
                missing.append(ex.id)
            }
        }
        #expect(missing.isEmpty, "Exercise IDs missing from prompt block:\n\(missing.joined(separator: "\n"))")
    }

    @Test("promptReferenceBlock contains the constraint header")
    func promptBlockHasHeader() {
        let block = ExerciseLibrary.promptReferenceBlock()
        #expect(block.contains("CANONICAL EXERCISE LIBRARY"))
        #expect(block.contains("You MUST only prescribe exercises from this list"))
        #expect(block.contains("exercise_id | name | primary_muscle | equipment_required"))
    }

    @Test("promptReferenceBlock is non-empty and reasonably sized")
    func promptBlockSize() {
        let block = ExerciseLibrary.promptReferenceBlock()
        // Should have content for all exercises
        #expect(block.count > 500)
        // Should not be excessively large (>10KB would be a problem for token budget)
        #expect(block.count < 10_000)
    }
}

// MARK: - Helpers

private func findDuplicates(_ ids: [String]) -> [String] {
    var counts: [String: Int] = [:]
    for id in ids { counts[id, default: 0] += 1 }
    return counts.filter { $0.value > 1 }.map(\.key).sorted()
}
