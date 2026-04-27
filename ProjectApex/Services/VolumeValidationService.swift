// VolumeValidationService.swift
// ProjectApex — Services
//
// Compares actual sets completed this week against the macro plan's targets
// per muscle group, and flags muscles with ≥20% volume deficit.
//
// Called from ProgressViewModel.loadAll() (needs both planned days + actual
// set logs together). Results are persisted to UserDefaults so
// SessionPlanService can read them synchronously when building the next
// session request.

import Foundation

// MARK: - VolumeDeficit

nonisolated struct VolumeDeficit: Codable, Sendable {
    let muscleGroup: String
    let targetSets: Int
    let actualSets: Int
    /// Fraction below target, e.g. 0.30 means 30% short. Always > 0.20.
    let deficitPercent: Double
}

extension VolumeDeficit: Identifiable {
    var id: String { muscleGroup }
}

// MARK: - VolumeValidationService

nonisolated enum VolumeValidationService {

    private static let userDefaultsKey = "apex.volume_deficits"

    // MARK: - Compute

    /// Compares actual sets this week (from `completedSetLogs`) against
    /// planned sets per muscle (derived from `plannedDays`).
    ///
    /// A `VolumeDeficit` is emitted for every muscle group where actual sets
    /// are more than 20% below the plan target for the week.
    ///
    /// - Parameters:
    ///   - completedSetLogs: All set_logs rows logged this calendar week.
    ///   - plannedDays: All TrainingDay entries scheduled for this week (from the Mesocycle).
    static func currentWeekDeficits(
        completedSetLogs: [SetLog],
        plannedDays: [TrainingDay]
    ) -> [VolumeDeficit] {
        // Build target map: muscle → total planned sets this week
        var targetMap: [String: Int] = [:]
        for day in plannedDays {
            for exercise in day.exercises {
                // Use ExerciseLibrary for the canonical muscle; fall back to the
                // exercise's own primaryMuscle field if the ID is non-canonical.
                let muscle = ExerciseLibrary.primaryMuscle(for: exercise.exerciseId)
                    ?? exercise.primaryMuscle
                targetMap[muscle, default: 0] += exercise.sets
            }
        }

        guard !targetMap.isEmpty else { return [] }

        // Build actual map: muscle → sets actually completed
        var actualMap: [String: Int] = [:]
        for log in completedSetLogs {
            // Prefer the primary_muscle column (populated at write time);
            // fall back to ExerciseLibrary lookup for older rows.
            let muscle = log.primaryMuscle
                ?? ExerciseLibrary.primaryMuscle(for: log.exerciseId)
                ?? "other"
            actualMap[muscle, default: 0] += 1
        }

        // Emit a deficit for any muscle ≥20% below target
        var deficits: [VolumeDeficit] = []
        for (muscle, target) in targetMap where target > 0 {
            let actual = actualMap[muscle] ?? 0
            let deficit = Double(target - actual) / Double(target)
            if deficit > 0.20 {
                deficits.append(VolumeDeficit(
                    muscleGroup: muscle,
                    targetSets: target,
                    actualSets: actual,
                    deficitPercent: deficit
                ))
            }
        }

        return deficits.sorted { $0.muscleGroup < $1.muscleGroup }
    }

    // MARK: - Persistence

    static func persist(_ deficits: [VolumeDeficit]) {
        guard let data = try? JSONEncoder().encode(deficits) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func load() -> [VolumeDeficit] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let deficits = try? JSONDecoder().decode([VolumeDeficit].self, from: data)
        else { return [] }
        return deficits
    }
}
