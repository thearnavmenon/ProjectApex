// ProgressViewModel.swift
// ProjectApex — Features/Progress
//
// Loads and computes all data for the Progress tab.
// Owned locally by ProgressTabView (not shared globally).
//
// Data strategy:
//   1. Fetch the user's completed workout_sessions (last 90 days, no heavy JSONB).
//   2. Fetch all set_logs for those sessions (using session_id.in.(...)).
//      Explicit select column list avoids pulling ai_prescribed JSONB.
//   3. All aggregation (key lifts, trend, volume, heatmap) is done client-side.
//   4. Stagnation signals are loaded from UserDefaults (written post-session).
//   5. Volume deficits need the current week's planned days — passed in from
//      the mesocycle so no extra network call is required.

import Foundation
import Observation

// MARK: - DTOs

nonisolated struct KeyLiftSummary: Identifiable, Sendable {
    var id: String { exerciseId }
    let exerciseId: String
    let name: String
    /// Best e1RM in the most recent 2-week window.
    let currentE1RM: Double
    /// Difference vs best e1RM from the 4–6 week window. Nil if no data in that window.
    let deltaVs4WeeksAgo: Double?
    let trend: TrendDirection
}

nonisolated enum TrendDirection: Sendable {
    case up, flat, down
}

nonisolated struct TrendPoint: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let e1RM: Double
    let isAllTimeBest: Bool

    init(date: Date, e1RM: Double, isAllTimeBest: Bool) {
        self.id = UUID()
        self.date = date
        self.e1RM = e1RM
        self.isAllTimeBest = isAllTimeBest
    }
}

nonisolated struct WeeklyVolumeRow: Identifiable, Sendable {
    let id: UUID
    /// "W1", "W2", ... relative to the most recent week = W1
    let weekLabel: String
    let weekStart: Date
    /// muscle → set count
    let setsByMuscle: [String: Int]

    init(weekLabel: String, weekStart: Date, setsByMuscle: [String: Int]) {
        self.id = UUID()
        self.weekLabel = weekLabel
        self.weekStart = weekStart
        self.setsByMuscle = setsByMuscle
    }
}

nonisolated struct HeatmapCell: Identifiable, Sendable {
    let id: UUID
    /// Column index: 0 = oldest week, 11 = most recent week.
    let weekIndex: Int
    /// Row index: 0 = Monday, 6 = Sunday.
    let dayOfWeek: Int
    let sessionCount: Int
    let hasPR: Bool

    init(weekIndex: Int, dayOfWeek: Int, sessionCount: Int, hasPR: Bool) {
        self.id = UUID()
        self.weekIndex = weekIndex
        self.dayOfWeek = dayOfWeek
        self.sessionCount = sessionCount
        self.hasPR = hasPR
    }
}

// MARK: - ProgressSessionRow

/// Lightweight DTO for fetching workout_sessions metadata in ProgressViewModel.
/// Decodes session_date as String (not Date) to avoid ISO 8601 fractional-seconds
/// parsing failures — the same pattern used by ProgramViewModel.SessionMetaRow.
private struct ProgressSessionRow: Decodable {
    let id: UUID
    let sessionDate: String   // raw string from Supabase, e.g. "2026-03-20T10:00:00.123456+00:00"

    enum CodingKeys: String, CodingKey {
        case id
        case sessionDate = "session_date"
    }

    /// Parses the session_date string into a Date.
    /// session_date is a Postgres DATE column — Supabase returns it as "yyyy-MM-dd".
    /// Falls back through ISO8601 variants for any future migration to TIMESTAMPTZ.
    var date: Date {
        // Primary: bare DATE format "2026-03-20"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        if let d = df.date(from: sessionDate) { return d }
        // Fallback: full ISO8601 with fractional seconds
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: sessionDate) { return d }
        // Fallback: plain ISO8601
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: sessionDate) { return d }
        return Date.distantPast
    }
}

// MARK: - ProgressViewModel

@Observable
@MainActor
final class ProgressViewModel {

    // MARK: - State

    var keyLifts: [KeyLiftSummary] = []
    /// exerciseId → sorted TrendPoints (oldest first)
    var trendData: [String: [TrendPoint]] = [:]
    var selectedTrendExercise: String?
    var weeklyVolume: [WeeklyVolumeRow] = []
    var heatmapData: [HeatmapCell] = []
    var stagnationSignals: [StagnationSignal] = []
    var isLoading = true
    var errorMessage: String?

    // MARK: - Dependencies

    private let supabaseClient: SupabaseClient
    private let userId: UUID

    // MARK: - Init

    init(supabaseClient: SupabaseClient, userId: UUID) {
        self.supabaseClient = supabaseClient
        self.userId = userId
    }

    // MARK: - Load

    func loadAll(plannedWeekDays: [TrainingDay] = []) async {
        isLoading = true
        errorMessage = nil

        do {
            // Step 1: fetch completed workout sessions (last 90 days).
            // Uses a lightweight DTO (ProgressSessionRow) that decodes session_date as
            // String to avoid ISO 8601 fractional-seconds parsing failures — matching
            // the pattern used by ProgramViewModel.SessionMetaRow.
            let cutoff = Date().addingTimeInterval(-90 * 86_400)
            let sessionRows: [ProgressSessionRow] = try await supabaseClient.fetch(
                ProgressSessionRow.self,
                table: "workout_sessions",
                filters: [
                    Filter(column: "user_id",      op: .eq,  value: userId.uuidString),
                    Filter(column: "completed",     op: .is,  value: "true"),
                    Filter(column: "session_date",  op: .gte, value: iso8601(cutoff)),
                ],
                order: "session_date.asc",
                select: "id,session_date"
            )

            print("[ProgressViewModel] Fetched \(sessionRows.count) sessions for userId=\(userId.uuidString)")
            guard !sessionRows.isEmpty else {
                print("[ProgressViewModel] No sessions found — Progress tab will be empty.")
                isLoading = false
                return
            }

            // Step 2: fetch set_logs for those sessions (two-query pattern)
            let sessionIds = sessionRows.map { $0.id.uuidString }.joined(separator: ",")
            let setLogs: [SetLog] = try await supabaseClient.fetch(
                SetLog.self,
                table: "set_logs",
                filters: [
                    Filter(column: "session_id", op: .in, value: "(\(sessionIds))"),
                ],
                order: "logged_at.asc",
                select: "id,session_id,exercise_id,set_number,weight_kg,reps_completed,rpe_felt,rir_estimated,logged_at,primary_muscle"
            )

            print("[ProgressViewModel] Loaded \(sessionRows.count) sessions, \(setLogs.count) set_logs")

            // Step 3: compute all sections client-side
            // Build a sessionId → Date map from the lightweight session rows
            let sessionDateMap: [UUID: Date] = Dictionary(
                uniqueKeysWithValues: sessionRows.map { ($0.id, $0.date) }
            )

            // Build a minimal WorkoutSession array for the heatmap (needs session dates)
            let sessions = sessionRows.map { row in
                WorkoutSession(id: row.id, userId: userId, programId: UUID(),
                               sessionDate: row.date, weekNumber: 0, dayType: "",
                               completed: true)
            }

            keyLifts     = computeKeyLifts(setLogs: setLogs, sessionDateMap: sessionDateMap)
            trendData    = computeTrendData(setLogs: setLogs, sessionDateMap: sessionDateMap)
            weeklyVolume = computeWeeklyVolume(setLogs: setLogs)
            heatmapData  = computeHeatmap(sessions: sessions, setLogs: setLogs, sessionDateMap: sessionDateMap)

            // Step 4: volume deficits if planned days were provided
            if !plannedWeekDays.isEmpty {
                let thisWeekLogs = setLogs.filter { isThisCalendarWeek($0.loggedAt) }
                let deficits = VolumeValidationService.currentWeekDeficits(
                    completedSetLogs: thisWeekLogs,
                    plannedDays: plannedWeekDays
                )
                VolumeValidationService.persist(deficits)
            }

            // Step 5: load stagnation signals (persisted post-session)
            stagnationSignals = StagnationService.load()

            // Default trend exercise to whichever exercise has the most sessions
            if selectedTrendExercise == nil {
                selectedTrendExercise = trendData
                    .max { $0.value.count < $1.value.count }?.key
                    ?? trendData.keys.sorted().first
            }

        } catch {
            errorMessage = error.localizedDescription
            print("[ProgressViewModel] loadAll error: \(error)")
        }

        isLoading = false
    }

    // MARK: - Key Lifts

    /// Muscle groups shown in the Key Lifts section, in display order.
    private static let keyLiftMuscles: [String] = [
        "chest", "back", "shoulders", "quads", "hamstrings"
    ]

    /// For each target muscle group, finds the exercise with the highest recent e1RM
    /// and returns a summary card. Works with whatever exercise IDs the AI generates —
    /// no hardcoded exercise ID allowlist.
    private func computeKeyLifts(
        setLogs: [SetLog],
        sessionDateMap: [UUID: Date]
    ) -> [KeyLiftSummary] {
        let now = Date()
        let twoWeeksAgo  = now.addingTimeInterval(-14 * 86_400)
        let fourWeeksAgo = now.addingTimeInterval(-28 * 86_400)
        let sixWeeksAgo  = now.addingTimeInterval(-42 * 86_400)

        // Group logs by primary muscle (use ExerciseLibrary fallback for nil column)
        var logsByMuscle: [String: [SetLog]] = [:]
        for log in setLogs {
            let muscle = log.primaryMuscle
                ?? ExerciseLibrary.primaryMuscle(for: log.exerciseId)
                ?? "other"
            logsByMuscle[muscle, default: []].append(log)
        }

        return Self.keyLiftMuscles.compactMap { muscle in
            guard let muscleLogs = logsByMuscle[muscle], !muscleLogs.isEmpty else { return nil }

            // Within this muscle, find the exercise with the highest recent e1RM
            var byExercise: [String: [SetLog]] = [:]
            for log in muscleLogs { byExercise[log.exerciseId, default: []].append(log) }

            // Pick the exercise with the best e1RM in the recent 2-week window
            var bestExerciseId: String? = nil
            var bestCurrentE1RM: Double = 0
            for (exId, exLogs) in byExercise {
                let recent = exLogs.filter { date(of: $0, in: sessionDateMap) >= twoWeeksAgo }
                let best = recent.map { e1rm($0) }.max() ?? 0
                if best > bestCurrentE1RM {
                    bestCurrentE1RM = best
                    bestExerciseId = exId
                }
            }

            // Fall back to all-time best if nothing in last 2 weeks
            if bestCurrentE1RM == 0 {
                for (exId, exLogs) in byExercise {
                    let best = exLogs.map { e1rm($0) }.max() ?? 0
                    if best > bestCurrentE1RM {
                        bestCurrentE1RM = best
                        bestExerciseId = exId
                    }
                }
            }

            guard let exerciseId = bestExerciseId, bestCurrentE1RM > 0 else { return nil }

            // Compute delta vs 4–6 weeks ago for the same exercise
            let referenceLogs = (byExercise[exerciseId] ?? []).filter {
                let d = date(of: $0, in: sessionDateMap)
                return d >= sixWeeksAgo && d < fourWeeksAgo
            }
            let referenceBest = referenceLogs.map { e1rm($0) }.max()
            let delta = referenceBest.map { bestCurrentE1RM - $0 }

            let trend: TrendDirection
            if let d = delta {
                if d > 1.0       { trend = .up }
                else if d < -1.0 { trend = .down }
                else             { trend = .flat }
            } else {
                trend = .flat
            }

            let name = ExerciseLibrary.lookup(exerciseId)?.name
                ?? exerciseId.split(separator: "_")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")

            return KeyLiftSummary(
                exerciseId: exerciseId,
                name: name,
                currentE1RM: bestCurrentE1RM,
                deltaVs4WeeksAgo: delta,
                trend: trend
            )
        }
    }

    // MARK: - Trend Data

    private func computeTrendData(
        setLogs: [SetLog],
        sessionDateMap: [UUID: Date]
    ) -> [String: [TrendPoint]] {
        var logsByExercise: [String: [SetLog]] = [:]
        for log in setLogs {
            logsByExercise[log.exerciseId, default: []].append(log)
        }

        var result: [String: [TrendPoint]] = [:]

        for (exerciseId, logs) in logsByExercise {
            var sessionGroups: [UUID: [SetLog]] = [:]
            for log in logs { sessionGroups[log.sessionId, default: []].append(log) }

            var sessionBests: [(date: Date, e1RM: Double)] = []
            for (sessionId, sessionLogs) in sessionGroups {
                guard let d = sessionDateMap[sessionId] else { continue }
                let best = sessionLogs.map { e1rm($0) }.max() ?? 0
                if best > 0 { sessionBests.append((date: d, e1RM: best)) }
            }

            guard sessionBests.count >= 1 else { continue }
            sessionBests.sort { $0.date < $1.date }

            var allTimeBest: Double = 0
            let points: [TrendPoint] = sessionBests.map { entry in
                let isPR = entry.e1RM > allTimeBest
                if isPR { allTimeBest = entry.e1RM }
                return TrendPoint(date: entry.date, e1RM: entry.e1RM, isAllTimeBest: isPR)
            }

            result[exerciseId] = points
        }

        return result
    }

    // MARK: - Weekly Volume

    private func computeWeeklyVolume(setLogs: [SetLog]) -> [WeeklyVolumeRow] {
        let calendar = Calendar.current
        let now = Date()

        var weekStarts: [Date] = []
        for i in (0..<8).reversed() {
            let base = calendar.date(byAdding: .weekOfYear, value: -i, to: now)!
            let weekStart = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: base)
            ) ?? base
            weekStarts.append(weekStart)
        }

        return weekStarts.enumerated().map { (index, weekStart) in
            let weekEnd = weekStart.addingTimeInterval(7 * 86_400)
            let weekLogs = setLogs.filter { $0.loggedAt >= weekStart && $0.loggedAt < weekEnd }

            var setsByMuscle: [String: Int] = [:]
            for log in weekLogs {
                let muscle = log.primaryMuscle
                    ?? ExerciseLibrary.primaryMuscle(for: log.exerciseId)
                    ?? "other"
                setsByMuscle[muscle, default: 0] += 1
            }

            let weekLabel = "W\(8 - index)"
            return WeeklyVolumeRow(weekLabel: weekLabel, weekStart: weekStart, setsByMuscle: setsByMuscle)
        }
    }

    // MARK: - Heatmap

    private func computeHeatmap(
        sessions: [WorkoutSession],
        setLogs: [SetLog],
        sessionDateMap: [UUID: Date]
    ) -> [HeatmapCell] {
        let calendar = Calendar.current
        let now = Date()

        guard let startOfGrid = calendar.date(byAdding: .weekOfYear, value: -11, to: now) else { return [] }
        let gridStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfGrid)
        ) ?? startOfGrid

        // Determine which sessions contain a PR (new all-time best e1RM for any exercise)
        var exerciseBests: [String: Double] = [:]
        var sessionHasPR: Set<UUID> = []
        for log in setLogs.sorted(by: { $0.loggedAt < $1.loggedAt }) {
            let curr = e1rm(log)
            let prev = exerciseBests[log.exerciseId] ?? 0
            if curr > prev {
                exerciseBests[log.exerciseId] = curr
                sessionHasPR.insert(log.sessionId)
            }
        }

        var grid: [Int: [Int: (count: Int, hasPR: Bool)]] = [:]

        for session in sessions {
            let d = session.sessionDate
            guard d >= gridStart else { continue }
            let weekIndex = calendar.dateComponents([.weekOfYear], from: gridStart, to: d).weekOfYear ?? 0
            let clampedWeek = min(max(weekIndex, 0), 11)
            // ISO weekday: Sun=1, Mon=2 … Sat=7 → convert to Mon=0…Sun=6
            let isoWeekday = calendar.component(.weekday, from: d)
            let dayIndex = (isoWeekday + 5) % 7

            let hasPR = sessionHasPR.contains(session.id)
            if grid[clampedWeek] == nil { grid[clampedWeek] = [:] }
            let existing = grid[clampedWeek]?[dayIndex] ?? (count: 0, hasPR: false)
            grid[clampedWeek]?[dayIndex] = (count: existing.count + 1, hasPR: existing.hasPR || hasPR)
        }

        var cells: [HeatmapCell] = []
        for weekIndex in 0..<12 {
            for dayIndex in 0..<7 {
                let data = grid[weekIndex]?[dayIndex]
                cells.append(HeatmapCell(
                    weekIndex: weekIndex,
                    dayOfWeek: dayIndex,
                    sessionCount: data?.count ?? 0,
                    hasPR: data?.hasPR ?? false
                ))
            }
        }
        return cells
    }

    // MARK: - Utilities

    private func e1rm(_ log: SetLog) -> Double {
        log.weightKg * (1.0 + Double(log.repsCompleted) / 30.0)
    }

    private func date(of log: SetLog, in map: [UUID: Date]) -> Date {
        map[log.sessionId] ?? log.loggedAt
    }

    private func isThisCalendarWeek(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .weekOfYear)
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
