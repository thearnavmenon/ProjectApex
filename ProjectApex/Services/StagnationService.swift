// StagnationService.swift
// ProjectApex — Services
//
// Detects strength stagnation from historical set_logs.
// Runs in a Task.detached block after finishSession() and persists
// signals to UserDefaults so SessionPlanService can read them synchronously.
//
// Stagnation rules:
//   plateaued — e1RM within 2% across last 3 sessions AND avgRPE < 8.0
//               When avgRPE is nil (manual-logged rows with no RPE entry),
//               the threshold tightens to 4+ sessions before calling plateau,
//               preventing false positives on sessions where effort is unknown.
//   declining — e1RM dropped ≥5% from first to last of last 3 sessions
//               AND inter-session gap < 5 days on average (suggesting
//               the drop isn't just deload spacing)
//
// e1RM formula: Epley — weight × (1 + reps / 30)

import Foundation

// MARK: - StagnationVerdict

nonisolated enum StagnationVerdict: String, Codable, Sendable {
    case progressing
    case plateaued
    case declining
}

// MARK: - StagnationSignal

nonisolated struct StagnationSignal: Codable, Sendable {
    let exerciseId: String
    let exerciseName: String
    /// Number of consecutive sessions without a new e1RM PR.
    let sessionsWithoutProgress: Int
    /// Date of the last time a new e1RM was set. Nil if no PR found in window.
    let lastPRDate: Date?
    /// Average RPE from the last 3 sessions. Nil if rpe_felt is absent on all relevant rows.
    let avgRPELast3Sessions: Double?
    let verdict: StagnationVerdict
}

// Identifiable conformance via exerciseId — used in ForEach in ProgressView.
extension StagnationSignal: Identifiable {
    var id: String { exerciseId }
}

// MARK: - StagnationService

nonisolated enum StagnationService {

    private static let userDefaultsKey = "apex.stagnation_signals"

    // MARK: - Compute

    /// Analyses `setLogs` and returns one `StagnationSignal` per exercise
    /// that has been trained in at least 3 distinct sessions.
    ///
    /// Exercises with fewer than 3 sessions always receive `.progressing`
    /// since there is insufficient data to evaluate a trend.
    static func computeSignals(from setLogs: [SetLog]) -> [StagnationSignal] {
        // Group logs by exerciseId
        var logsByExercise: [String: [SetLog]] = [:]
        for log in setLogs {
            logsByExercise[log.exerciseId, default: []].append(log)
        }

        var signals: [StagnationSignal] = []

        for (exerciseId, logs) in logsByExercise {
            // Derive a display name: convert snake_case → Title Case
            let exerciseName = exerciseId
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")

            // Group logs by sessionId to compute per-session stats
            var sessionGroups: [UUID: [SetLog]] = [:]
            for log in logs {
                sessionGroups[log.sessionId, default: []].append(log)
            }

            // Build sorted session records (oldest → newest)
            struct SessionRecord {
                let sessionId: UUID
                let date: Date
                let bestE1RM: Double
                let avgRPE: Double?
            }

            var records: [SessionRecord] = sessionGroups.map { (sessionId, sessionLogs) in
                let date = sessionLogs.compactMap { $0.loggedAt }.min() ?? Date.distantPast
                let bestE1RM = sessionLogs.map { e1rm(weight: $0.weightKg, reps: $0.repsCompleted) }.max() ?? 0
                let rpeValues = sessionLogs.compactMap { $0.rpeFelt.map { Double($0) } }
                let avgRPE: Double? = rpeValues.isEmpty ? nil : rpeValues.reduce(0, +) / Double(rpeValues.count)
                return SessionRecord(sessionId: sessionId, date: date, bestE1RM: bestE1RM, avgRPE: avgRPE)
            }

            records.sort { $0.date < $1.date }

            guard records.count >= 3 else {
                // Not enough data — emit progressing
                signals.append(StagnationSignal(
                    exerciseId: exerciseId,
                    exerciseName: exerciseName,
                    sessionsWithoutProgress: 0,
                    lastPRDate: records.last?.date,
                    avgRPELast3Sessions: nil,
                    verdict: .progressing
                ))
                continue
            }

            let last3 = Array(records.suffix(3))
            let e1RMs = last3.map(\.bestE1RM)

            // Average RPE across the last 3 sessions.
            // Collect all non-nil RPE values; if all are nil, avgRPE stays nil.
            let rpeValues = last3.compactMap(\.avgRPE)
            let avgRPE: Double? = rpeValues.isEmpty ? nil : rpeValues.reduce(0, +) / Double(rpeValues.count)

            // Check declining: e1RM dropped ≥5% from first to last of the 3 sessions
            // AND average inter-session gap < 5 days
            let firstE1RM = e1RMs[0]
            let lastE1RM  = e1RMs[2]
            let drop = firstE1RM > 0 ? (firstE1RM - lastE1RM) / firstE1RM : 0
            let gap1 = last3[1].date.timeIntervalSince(last3[0].date) / 86400
            let gap2 = last3[2].date.timeIntervalSince(last3[1].date) / 86400
            let avgGap = (gap1 + gap2) / 2

            let isDecining = drop >= 0.05 && avgGap < 5

            // Check plateaued: e1RM within 2% across all 3 sessions AND low effort signal.
            //
            // RPE gating logic:
            //   - RPE present and < 8.0 → low effort confirmed, 3-session window sufficient.
            //   - RPE present and ≥ 8.0 → athlete is working hard; flat e1RM is expected,
            //                             not a plateau. Do not fire.
            //   - RPE absent (nil)       → likely a manually-logged session where the user
            //                             didn't fill in RPE. Treat nil as "unknown" rather
            //                             than "low". Require a longer streak (4+ sessions)
            //                             before calling it a plateau, so a single missed RPE
            //                             entry doesn't trigger a false-positive banner.
            //                             4 sessions of flat progress is meaningful signal
            //                             regardless of effort data.
            let minE1RM = e1RMs.min() ?? 0
            let maxE1RM = e1RMs.max() ?? 0
            let spread  = minE1RM > 0 ? (maxE1RM - minE1RM) / minE1RM : 0
            let rpeIsLow: Bool
            if let avgRPE {
                rpeIsLow = avgRPE < 8.0
            } else {
                // No RPE data — require 4+ sessions before calling plateau
                rpeIsLow = records.count >= 4
            }
            let isPlateaued = spread <= 0.02 && rpeIsLow

            // Count sessions without a new PR (sessions where e1RM didn't improve)
            var sessionsWithoutProgress = 0
            var allTimeBest: Double = 0
            var lastPRDate: Date?
            for record in records {
                if record.bestE1RM > allTimeBest {
                    allTimeBest = record.bestE1RM
                    lastPRDate = record.date
                    sessionsWithoutProgress = 0
                } else {
                    sessionsWithoutProgress += 1
                }
            }

            let verdict: StagnationVerdict
            if isDecining {
                verdict = .declining
            } else if isPlateaued {
                verdict = .plateaued
            } else {
                verdict = .progressing
            }

            signals.append(StagnationSignal(
                exerciseId: exerciseId,
                exerciseName: exerciseName,
                sessionsWithoutProgress: sessionsWithoutProgress,
                lastPRDate: lastPRDate,
                avgRPELast3Sessions: avgRPE,
                verdict: verdict
            ))
        }

        return signals.sorted { $0.exerciseId < $1.exerciseId }
    }

    // MARK: - Persistence

    static func persist(_ signals: [StagnationSignal]) {
        guard let data = try? JSONEncoder().encode(signals) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func load() -> [StagnationSignal] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let signals = try? JSONDecoder().decode([StagnationSignal].self, from: data)
        else { return [] }
        return signals
    }

    // MARK: - Private helpers

    /// Epley e1RM: weight × (1 + reps / 30)
    private static func e1rm(weight: Double, reps: Int) -> Double {
        weight * (1.0 + Double(reps) / 30.0)
    }
}
