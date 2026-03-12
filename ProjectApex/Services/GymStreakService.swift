// GymStreakService.swift
// ProjectApex — Services
//
// Computes a dynamic gym streak score from consecutive training days.
// The result is included in every AI inference call so the coach can
// modulate intensity and motivation based on training consistency.
//
// CACHING:
//   StreakResult is cached after each fetch. isStale returns true when
//   the cached value is > 6 hours old or a new session has completed
//   since the last fetch. When Supabase is unreachable the service
//   returns the last cached result; if there is no cache at all it
//   returns a neutral score of 50 ("Warming Up") so the workout is
//   never blocked.
//
// STREAK ALGORITHM (TDD §P4-E1):
//   - Sessions are fetched for the last 90 days and deduplicated to
//     calendar dates (2+ sessions on the same day count as 1 day).
//   - Starting from today (or yesterday if no session today) and walking
//     backwards, count consecutive calendar days with at least one
//     completed session.  A 1-day gap (a rest day) does NOT break the
//     streak; a 2+ day gap resets it.
//   - Streak score: min(100, currentStreakDays * 8)  (caps at 13 days → 104 → clamped to 100)
//   - Tiers:  0–2 "Cold" | 3–5 "Warming Up" | 6–9 "Active" | 10+ "On Fire"

import Foundation
import SwiftUI

// MARK: - StreakTier

/// AI intensity ceiling associated with each streak tier.
nonisolated enum StreakTier: String, Codable, Sendable, Equatable {
    case cold       = "Cold"
    case warmingUp  = "Warming Up"
    case active     = "Active"
    case onFire     = "On Fire"
}

// MARK: - StreakResult

/// Immutable snapshot of the user's training streak, ready for injection
/// into `WorkoutContext` on every AI inference call.
nonisolated struct StreakResult: Codable, Sendable, Equatable {

    /// Number of consecutive training days up to and including today.
    let currentStreakDays: Int

    /// All-time longest streak in the 90-day lookback window.
    let longestStreak: Int

    /// 0–100 intensity score derived from current streak.
    let streakScore: Int

    /// Qualitative tier that maps to an AI intensity ceiling.
    let streakTier: StreakTier

    /// Timestamp when this result was computed — used for staleness checks.
    let computedAt: Date

    enum CodingKeys: String, CodingKey {
        case currentStreakDays  = "current_streak_days"
        case longestStreak      = "longest_streak"
        case streakScore        = "streak_score"
        case streakTier         = "streak_tier"
        case computedAt         = "computed_at"
    }

    // MARK: - Factory

    /// Neutral fallback returned when Supabase is unreachable and no cache exists.
    static let neutral = StreakResult(
        currentStreakDays: 0,
        longestStreak: 0,
        streakScore: 50,
        streakTier: .warmingUp,
        computedAt: .distantPast  // Always stale → retried ASAP
    )

    /// Computes tier and score from raw consecutive day count.
    static func compute(currentStreakDays: Int, longestStreak: Int, now: Date = Date()) -> StreakResult {
        let score = min(100, currentStreakDays * 8)
        let tier: StreakTier
        switch currentStreakDays {
        case 0...2:  tier = .cold
        case 3...5:  tier = .warmingUp
        case 6...9:  tier = .active
        default:     tier = .onFire       // 10+
        }
        return StreakResult(
            currentStreakDays: currentStreakDays,
            longestStreak: longestStreak,
            streakScore: score,
            streakTier: tier,
            computedAt: now
        )
    }

    /// Returns `true` when this result is older than `staleDuration` seconds.
    func isStale(after staleDuration: TimeInterval = 6 * 3600, relativeTo now: Date = Date()) -> Bool {
        now.timeIntervalSince(computedAt) > staleDuration
    }

    // MARK: - UI Helpers

    /// Theme colour for tinting workout UI elements based on streak tier.
    /// Cold → slate, Warming Up → amber, Active → electric blue, On Fire → orange-red.
    var tintColor: Color {
        switch streakTier {
        case .cold:      return Color(red: 0.54, green: 0.60, blue: 0.69)   // slate
        case .warmingUp: return Color(red: 0.91, green: 0.63, blue: 0.19)   // amber
        case .active:    return Color(red: 0.23, green: 0.56, blue: 1.00)   // electric blue
        case .onFire:    return Color(red: 1.00, green: 0.42, blue: 0.19)   // orange-red
        }
    }

    /// SF Symbol name for the streak icon shown in PreWorkoutView.
    /// On Fire tier uses the flame; other tiers use a bolt/activity symbol.
    var tierIcon: String {
        switch streakTier {
        case .cold:      return "snowflake"
        case .warmingUp: return "bolt.fill"
        case .active:    return "bolt.fill"
        case .onFire:    return "flame.fill"
        }
    }
}

// MARK: - SessionDateRow (Supabase DTO)

/// Minimal projection of a `workout_sessions` row — only the date fields
/// needed for streak computation are decoded.
private nonisolated struct SessionDateRow: Decodable, Sendable {
    let sessionDate: String     // "YYYY-MM-DD" (DATE column from Postgres)
    let completed: Bool

    enum CodingKeys: String, CodingKey {
        case sessionDate = "session_date"
        case completed
    }
}

// MARK: - GymStreakService

/// Actor that owns streak computation and its 6-hour cache.
///
/// Usage:
///   let streak = await gymStreakService.computeStreak(userId: userId)
///   // Inject streak into WorkoutContext before every AI inference call.
actor GymStreakService {

    // MARK: - Dependencies

    private let supabase: SupabaseClient

    // MARK: - Cache

    private var cachedResult: StreakResult?

    // MARK: - Configuration

    /// How many days of session history to look back.
    private let lookbackDays: Int

    /// Background retry task when Supabase was unreachable at last fetch.
    private var backgroundRetryTask: Task<Void, Never>?

    // MARK: - Init

    init(supabase: SupabaseClient, lookbackDays: Int = 90) {
        self.supabase = supabase
        self.lookbackDays = lookbackDays
    }

    // MARK: - Public API

    /// Returns the current streak result, using the cache if fresh.
    ///
    /// - Parameter userId: The authenticated user's UUID.
    /// - Returns: A `StreakResult` — never throws; returns neutral on failure.
    func computeStreak(userId: UUID) async -> StreakResult {
        // Return cached result if still fresh
        if let cached = cachedResult, !cached.isStale() {
            return cached
        }
        return await fetchAndCompute(userId: userId)
    }

    /// Forces a re-fetch regardless of cache freshness.
    /// Call this after a new workout session is completed.
    func invalidate(userId: UUID) async {
        cachedResult = nil
        _ = await fetchAndCompute(userId: userId)
    }

    // MARK: - Internal (package-private for tests)

    /// Exposed for unit testing — computes streak purely from a pre-fetched
    /// array of calendar date strings in "YYYY-MM-DD" format.
    func computeFromDates(_ dateSets: [String], now: Date = Date()) -> StreakResult {
        computeStreak(from: dateSets, now: now)
    }

    // MARK: - Private helpers

    private func fetchAndCompute(userId: UUID) async -> StreakResult {
        do {
            let dates = try await fetchSessionHistory(userId: userId, lookbackDays: lookbackDays)
            let result = computeStreak(from: dates)
            cachedResult = result
            return result
        } catch {
            // Supabase unreachable — return last cache or neutral fallback
            scheduleBackgroundRetry(userId: userId)
            return cachedResult ?? .neutral
        }
    }

    /// Queries `workout_sessions` for completed sessions within the lookback window.
    /// Returns a deduplicated array of "YYYY-MM-DD" strings.
    private func fetchSessionHistory(userId: UUID, lookbackDays: Int) async throws -> [String] {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -lookbackDays, to: Date()
        ) ?? Date()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let cutoffString = formatter.string(from: cutoffDate)

        let rows: [SessionDateRow] = try await supabase.fetch(
            SessionDateRow.self,
            table: "workout_sessions",
            filters: [
                Filter(column: "user_id",      op: .eq,  value: userId.uuidString),
                Filter(column: "completed",    op: .is,  value: "true"),
                Filter(column: "session_date", op: .gte, value: cutoffString)
            ]
        )

        // Deduplicate to unique calendar dates
        let uniqueDates = Set(rows.map(\.sessionDate))
        return Array(uniqueDates)
    }

    /// Pure streak computation from a list of "YYYY-MM-DD" date strings.
    ///
    /// Algorithm:
    ///   1. Parse and sort dates descending (newest first).
    ///   2. Walk backwards from today counting days that have a session.
    ///      A single rest day does NOT break the streak; 2+ consecutive rest
    ///      days do (streak resets to 0 for prior days).
    ///   3. Also compute longestStreak in the window.
    private func computeStreak(from dateSets: [String], now: Date = Date()) -> StreakResult {
        let calendar = Calendar.current

        // Parse all "YYYY-MM-DD" strings into start-of-day Date values
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let trainingDays: Set<Date> = Set(dateSets.compactMap { str -> Date? in
            guard let date = dateFormatter.date(from: str) else { return nil }
            return calendar.startOfDay(for: date)
        })

        if trainingDays.isEmpty {
            return StreakResult.compute(currentStreakDays: 0, longestStreak: 0, now: now)
        }

        let today = calendar.startOfDay(for: now)

        // Current streak: walk backwards from today.
        // Rule: 1-day gap (rest day) is allowed; 2+ day gap breaks streak.
        var currentStreak = 0
        var checkDate = today
        var lastTrainingDate: Date? = nil

        // Determine starting anchor:
        // If there's a session today, start counting from today.
        // If last session was yesterday, start counting from yesterday.
        // Otherwise, current streak = 0.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        if trainingDays.contains(today) {
            lastTrainingDate = today
            currentStreak = 1
            checkDate = yesterday
        } else if trainingDays.contains(yesterday) {
            // No session today yet — streak is based on yesterday and earlier
            lastTrainingDate = yesterday
            currentStreak = 1
            checkDate = calendar.date(byAdding: .day, value: -2, to: today)!
        } else {
            // 2+ day gap from today — current streak is 0
            currentStreak = 0
        }

        // Walk backwards, allowing 1-day rest gaps
        if currentStreak > 0 {
            var gapAllowed = true  // one rest day can be absorbed per step
            while true {
                if trainingDays.contains(checkDate) {
                    currentStreak += 1
                    gapAllowed = true  // reset gap allowance after a training day
                    lastTrainingDate = checkDate
                    checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
                } else if gapAllowed {
                    // Skip one rest day — don't break streak
                    gapAllowed = false
                    checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
                } else {
                    // Two consecutive non-training days — streak broken
                    break
                }
            }
        }

        // Longest streak: scan the full lookback window
        let longestStreak = computeLongestStreak(in: trainingDays, calendar: calendar, upTo: today)

        return StreakResult.compute(
            currentStreakDays: currentStreak,
            longestStreak: max(longestStreak, currentStreak),
            now: now
        )
    }

    /// Computes the longest consecutive-day streak within the training day set,
    /// using the same 1-rest-day-allowed rule.
    private func computeLongestStreak(
        in trainingDays: Set<Date>,
        calendar: Calendar,
        upTo today: Date
    ) -> Int {
        guard !trainingDays.isEmpty else { return 0 }

        let sorted = trainingDays.sorted(by: <)
        var longest = 1
        var current = 1
        var gapAllowed = true

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            let dayDiff = calendar.dateComponents([.day], from: prev, to: curr).day ?? 0

            if dayDiff == 1 {
                // Consecutive day
                current += 1
                gapAllowed = true
            } else if dayDiff == 2 && gapAllowed {
                // One rest day — still consecutive
                current += 1
                gapAllowed = false
            } else {
                // Streak broken
                longest = max(longest, current)
                current = 1
                gapAllowed = true
            }
        }
        longest = max(longest, current)
        return longest
    }

    /// Schedules a single silent background retry after a failed Supabase fetch.
    /// The retry fires once after a 10-second delay so the workout is never blocked.
    private func scheduleBackgroundRetry(userId: UUID) {
        backgroundRetryTask?.cancel()
        backgroundRetryTask = Task.detached(priority: .utility) { [weak self, userId] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10 s
            guard !Task.isCancelled, let self else { return }
            _ = await self.fetchAndCompute(userId: userId)
        }
    }
}
