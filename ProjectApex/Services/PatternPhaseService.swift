// PatternPhaseService.swift
// ProjectApex — Services
//
// Tracks per-movement-pattern periodization phase state.
// Runs in a Task.detached block after finishSession() and persists
// state to UserDefaults so ProgramViewModel can read it synchronously
// before the next session generation.
//
// Phase transition rule (Option B — derived from macro plan):
//   threshold = max(3, phaseWeeks × max(1, daysPerWeek / 2))
//
//   For 4 days/week: accumulation=8, intensification=8, peaking=6, deload=3
//   For 3 days/week: accumulation=4, intensification=4, peaking=3, deload=3
//
// Phase order: accumulation → intensification → peaking → deload
// Phase NEVER regresses on absence. LLM handles reintroduction via temporal context.
// Skipped sessions do NOT advance pattern phases.

import Foundation

// MARK: - MovementPatternPhaseState

/// Per-movement-pattern periodization state. Persisted to UserDefaults.
/// Slice 1 migrated `pattern` from String to MovementPattern; Codable
/// round-trip is wire-compatible (MovementPattern's String raw values
/// match the prior storage strings).
nonisolated struct MovementPatternPhaseState: Codable, Sendable, Identifiable {
    /// Movement pattern, e.g. .horizontalPush, .squat, .isolation.
    let pattern: MovementPattern
    /// Current periodization phase for this specific movement pattern.
    var phase: MesocyclePhase
    /// Completed (non-skipped) sessions for this pattern in the current phase.
    var sessionsCompletedInPhase: Int
    /// Sessions required to advance to the next phase. Derived from daysPerWeek at creation.
    let sessionsRequiredForPhase: Int

    /// Identifiable conformance — pattern is stable within a programme.
    var id: MovementPattern { pattern }
}

// MARK: - PatternPhaseInfo

/// Lightweight DTO serialised into TemporalContext JSON for the LLM.
/// Decoupled from MovementPatternPhaseState so the LLM payload stays lean.
nonisolated struct PatternPhaseInfo: Codable, Sendable {
    /// Current phase name (MesocyclePhase raw value, e.g. "accumulation").
    let currentPhase: String
    /// Sessions completed in the current phase.
    let sessionsCompleted: Int
    /// Sessions required to advance to the next phase.
    let sessionsRequired: Int

    enum CodingKeys: String, CodingKey {
        case currentPhase    = "current_phase"
        case sessionsCompleted = "sessions_completed"
        case sessionsRequired  = "sessions_required"
    }
}

// MARK: - PatternPhaseService

nonisolated enum PatternPhaseService {

    private static let userDefaultsKey = "apex.pattern_phase_states"

    /// Ordered phase progression. Phases advance in this order and never regress.
    static let phaseOrder: [MesocyclePhase] = [
        .accumulation, .intensification, .peaking, .deload
    ]

    // MARK: - Threshold (Option B)

    /// Sessions required to advance from the given phase.
    ///
    /// Formula: max(3, phaseWeeks × max(1, daysPerWeek / 2))
    /// This mirrors the macro plan's phase durations, scaled by estimated pattern frequency
    /// (each pattern appears on roughly half the training days in a typical split).
    static func sessionsRequired(for phase: MesocyclePhase, daysPerWeek: Int) -> Int {
        let phaseWeeks: Int
        switch phase {
        case .accumulation:    phaseWeeks = 4
        case .intensification: phaseWeeks = 4
        case .peaking:         phaseWeeks = 3
        case .deload:          phaseWeeks = 1
        }
        let multiplier = max(1, daysPerWeek / 2)
        return max(3, phaseWeeks * multiplier)
    }

    // MARK: - Advance After Completed Session

    /// Pure function: advances phase state for the patterns trained in a completed session.
    ///
    /// Called by WorkoutSessionManager.finishSession() (not on skip — skip safety is structural).
    /// The caller is responsible for persisting the returned array.
    ///
    /// - Parameters:
    ///   - current: The currently persisted pattern phase states.
    ///   - trainedPatterns: Movement patterns trained in the just-completed session.
    ///   - daysPerWeek: The programme's training days per week (from UserDefaults or skeleton).
    /// - Returns: Updated array with counters incremented and phase transitions applied.
    static func advancePhases(
        current: [MovementPatternPhaseState],
        trainedPatterns: Set<MovementPattern>,
        daysPerWeek: Int
    ) -> [MovementPatternPhaseState] {
        guard !trainedPatterns.isEmpty else { return current }

        var updated = current

        // Advance existing pattern entries
        for i in updated.indices where trainedPatterns.contains(updated[i].pattern) {
            updated[i].sessionsCompletedInPhase += 1

            // Transition when threshold is met
            if updated[i].sessionsCompletedInPhase >= updated[i].sessionsRequiredForPhase {
                if let nextPhase = nextPhase(after: updated[i].phase) {
                    let req = sessionsRequired(for: nextPhase, daysPerWeek: daysPerWeek)
                    updated[i] = MovementPatternPhaseState(
                        pattern: updated[i].pattern,
                        phase: nextPhase,
                        sessionsCompletedInPhase: 0,
                        sessionsRequiredForPhase: req
                    )
                }
                // Already at deload (terminal phase) — no further transition
            }
        }

        // Create new entries for patterns encountered for the first time
        let existingPatterns = Set(updated.map(\.pattern))
        let newPatterns = trainedPatterns.subtracting(existingPatterns).sorted { $0.rawValue < $1.rawValue }
        for pattern in newPatterns {
            let req = sessionsRequired(for: .accumulation, daysPerWeek: daysPerWeek)
            updated.append(MovementPatternPhaseState(
                pattern: pattern,
                phase: .accumulation,
                sessionsCompletedInPhase: 1,
                sessionsRequiredForPhase: req
            ))
        }

        return updated
    }

    // MARK: - Migration: Compute Initial Phases from History

    /// Pure function: derives initial pattern phase states from historical set logs.
    ///
    /// Called once on the first generateDaySession() call after this feature is deployed,
    /// when no persisted pattern phases exist but set log history is available.
    /// The caller is responsible for persisting the returned array.
    ///
    /// Algorithm:
    ///   1. Count distinct completed session IDs per movement pattern.
    ///   2. Walk through the phase thresholds, consuming sessions, to derive the current phase.
    ///   3. The remaining session count becomes sessionsCompletedInPhase.
    static func computeInitialPhases(
        from setLogs: [SetLog],
        daysPerWeek: Int
    ) -> [MovementPatternPhaseState] {
        guard !setLogs.isEmpty else { return [] }

        // Group distinct session IDs per movement pattern
        var sessionsByPattern: [MovementPattern: Set<UUID>] = [:]
        for log in setLogs {
            guard let def = ExerciseLibrary.lookup(log.exerciseId) else { continue }
            sessionsByPattern[def.movementPattern, default: []].insert(log.sessionId)
        }

        var states: [MovementPatternPhaseState] = []

        for (pattern, sessionIds) in sessionsByPattern {
            var remainingSessions = sessionIds.count
            var derivedPhase: MesocyclePhase = .accumulation

            // Walk through phases, consuming sessions against each threshold
            for phase in phaseOrder {
                let threshold = sessionsRequired(for: phase, daysPerWeek: daysPerWeek)
                if remainingSessions >= threshold {
                    remainingSessions -= threshold
                    if let next = nextPhase(after: phase) {
                        derivedPhase = next
                    } else {
                        // Deload is terminal — clamp remaining count to threshold
                        derivedPhase = phase
                        remainingSessions = min(remainingSessions, threshold)
                        break
                    }
                } else {
                    derivedPhase = phase
                    break
                }
            }

            let req = sessionsRequired(for: derivedPhase, daysPerWeek: daysPerWeek)
            states.append(MovementPatternPhaseState(
                pattern: pattern,
                phase: derivedPhase,
                sessionsCompletedInPhase: remainingSessions,
                sessionsRequiredForPhase: req
            ))
        }

        return states.sorted { $0.pattern.rawValue < $1.pattern.rawValue }
    }

    // MARK: - Persistence

    static func persist(_ states: [MovementPatternPhaseState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func load() -> [MovementPatternPhaseState] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let states = try? JSONDecoder().decode([MovementPatternPhaseState].self, from: data)
        else { return [] }
        return states
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    // MARK: - Private helpers

    private static func nextPhase(after phase: MesocyclePhase) -> MesocyclePhase? {
        guard let idx = phaseOrder.firstIndex(of: phase), idx + 1 < phaseOrder.count else {
            return nil
        }
        return phaseOrder[idx + 1]
    }
}
