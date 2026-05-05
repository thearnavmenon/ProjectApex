// EquipmentCatalogSeedTests.swift
// ProjectApexTests
//
// Smoke tests for Resources/equipment_catalog_seed.json (Phase 1 / Slice 4, issue #7).
//
// Covers:
//   • Exactly 42 entries (count regression guard)
//   • All 26 base EquipmentType IDs present
//   • All 16 specialty IDs present
//   • Every entry has required non-empty fields (id, display_name, category, arrays)
//   • category is one of the four valid values
//   • primary_muscle_groups references only the locked-six muscle groups
//   • default_increment_kg (where non-null) is a positive number

import XCTest

final class EquipmentCatalogSeedTests: XCTestCase {

    // MARK: ─── Helpers ────────────────────────────────────────────────────────

    private struct CatalogEntry: Decodable {
        let id: String
        let display_name: String
        let category: String
        let default_max_kg: Double?
        let default_increment_kg: Double?
        let primary_muscle_groups: [String]
        let exercise_tags: [String]
    }

    private static let seedFileURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()          // ProjectApexTests/
            .deletingLastPathComponent()          // ProjectApex/ (repo root)
            .appendingPathComponent("ProjectApex/Resources/equipment_catalog_seed.json")
    }()

    private static let entries: [CatalogEntry] = {
        let data = try! Data(contentsOf: seedFileURL)
        return try! JSONDecoder().decode([CatalogEntry].self, from: data)
    }()

    // MARK: ─── Count ──────────────────────────────────────────────────────────

    func test_count_isExactly42() {
        XCTAssertEqual(Self.entries.count, 42,
            "Seed file must contain exactly 42 entries; edit count indicates unintended removal")
    }

    // MARK: ─── Base IDs (26) ──────────────────────────────────────────────────

    func test_baseIDs_allPresent() {
        let expected: Set<String> = [
            "dumbbell-set", "barbell", "ez-curl-bar", "cable-machine", "cable-machine-dual",
            "smith-machine", "leg-press", "hack-squat", "adjustable-bench", "flat-bench",
            "incline-bench", "pull-up-bar", "dip-station", "resistance-bands", "kettlebell-set",
            "power-rack", "squat-rack", "lat-pulldown", "seated-row", "chest-press-machine",
            "shoulder-press-machine", "leg-extension", "leg-curl", "pec-deck", "preacher-curl",
            "cable-crossover"
        ]
        let actual = Set(Self.entries.map(\.id))
        XCTAssertTrue(expected.isSubset(of: actual),
            "Missing base IDs: \(expected.subtracting(actual))")
    }

    // MARK: ─── Specialty IDs (16) ─────────────────────────────────────────────

    func test_specialtyIDs_allPresent() {
        let expected: Set<String> = [
            "hip-thrust-machine", "ghd-glute-ham-raise", "reverse-hyper", "t-bar-row",
            "trap-bar", "belt-squat-pendulum-squat", "hs-chest-press", "hs-incline-press",
            "hs-lat-pulldown", "hs-iso-row", "hs-shoulder-press", "standing-calf-raise",
            "seated-calf-raise", "abductor-machine", "adductor-machine", "sissy-squat-machine"
        ]
        let actual = Set(Self.entries.map(\.id))
        XCTAssertTrue(expected.isSubset(of: actual),
            "Missing specialty IDs: \(expected.subtracting(actual))")
    }

    // MARK: ─── Required Fields ────────────────────────────────────────────────

    func test_requiredFields_noEmptyStrings() {
        for entry in Self.entries {
            XCTAssertFalse(entry.id.isEmpty,           "Empty id in entry")
            XCTAssertFalse(entry.display_name.isEmpty, "Empty display_name for id=\(entry.id)")
            XCTAssertFalse(entry.category.isEmpty,     "Empty category for id=\(entry.id)")
        }
    }

    func test_requiredArrays_nonEmpty() {
        for entry in Self.entries {
            XCTAssertFalse(entry.primary_muscle_groups.isEmpty,
                "primary_muscle_groups is empty for id=\(entry.id)")
            XCTAssertFalse(entry.exercise_tags.isEmpty,
                "exercise_tags is empty for id=\(entry.id)")
        }
    }

    // MARK: ─── Category Values ────────────────────────────────────────────────

    func test_category_validValues() {
        let valid: Set<String> = ["plate-loaded", "weight-stack", "fixed-weight", "bodyweight"]
        for entry in Self.entries {
            XCTAssertTrue(valid.contains(entry.category),
                "Invalid category '\(entry.category)' for id=\(entry.id)")
        }
    }

    // MARK: ─── Muscle Groups ──────────────────────────────────────────────────

    func test_primaryMuscleGroups_lockedSixOnly() {
        let locked: Set<String> = ["back", "chest", "biceps", "shoulders", "triceps", "legs"]
        for entry in Self.entries {
            for muscle in entry.primary_muscle_groups {
                XCTAssertTrue(locked.contains(muscle),
                    "Unknown muscle group '\(muscle)' in id=\(entry.id)")
            }
        }
    }

    // MARK: ─── Numeric Increments ─────────────────────────────────────────────

    func test_defaultIncrementKg_positiveWhereNonNull() {
        for entry in Self.entries {
            if let increment = entry.default_increment_kg {
                XCTAssertGreaterThan(increment, 0,
                    "default_increment_kg must be positive for id=\(entry.id); got \(increment)")
            }
        }
    }

    // MARK: ─── No Duplicate IDs ───────────────────────────────────────────────

    func test_ids_unique() {
        let ids = Self.entries.map(\.id)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count,
            "Duplicate IDs found in seed file")
    }
}
