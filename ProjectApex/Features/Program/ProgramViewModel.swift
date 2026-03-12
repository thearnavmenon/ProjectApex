// ProgramViewModel.swift
// ProjectApex — Features/Program
//
// Observable view model bridging ProgramGenerationService and Supabase fetch
// to the ProgramOverviewView. Manages loading, empty, and error states.

import SwiftUI

// MARK: - ProgramViewState

enum ProgramViewState: Equatable {
    case loading
    case empty
    case loaded(Mesocycle)
    case generating
    case error(String)

    static func == (lhs: ProgramViewState, rhs: ProgramViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.empty, .empty), (.generating, .generating): return true
        case (.loaded(let a), .loaded(let b)): return a.id == b.id
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - ProgramViewModel

@Observable
@MainActor
final class ProgramViewModel {

    // MARK: Published State

    var viewState: ProgramViewState = .loading
    var selectedDay: TrainingDay?
    var selectedWeek: TrainingWeek?

    // MARK: Private

    private let supabaseClient: SupabaseClient
    private let programGenerationService: ProgramGenerationService

    /// Stable user ID for Supabase operations. Replace with real auth when available.
    private let userId: UUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001") ?? UUID()

    // MARK: Init

    init(supabaseClient: SupabaseClient, programGenerationService: ProgramGenerationService) {
        self.supabaseClient = supabaseClient
        self.programGenerationService = programGenerationService
    }

    // MARK: - Load

    /// Loads the active program: tries UserDefaults cache first, then Supabase.
    func loadProgram() async {
        viewState = .loading

        // 1. Fast path: UserDefaults cache
        if let cached = Mesocycle.loadFromUserDefaults() {
            viewState = .loaded(cached)
            return
        }

        // 2. Network fetch
        do {
            if let row = try await supabaseClient.fetchActiveProgram(userId: userId) {
                let mesocycle = row.toMesocycle()
                mesocycle.saveToUserDefaults()
                viewState = .loaded(mesocycle)
            } else {
                viewState = .empty
            }
        } catch {
            // If fetch fails but no cache → show empty so user can generate
            viewState = .empty
        }
    }

    // MARK: - Regenerate

    /// Replaces the existing program with a freshly generated one.
    /// Clears local cache + deactivates old Supabase row before generating.
    /// Called from Settings → "Regenerate Program".
    func regenerateProgram(gymProfile: GymProfile) async {
        // Clear the local cache so the new program is not shadowed by the old one
        Mesocycle.clearUserDefaults()
        // Delegate to the shared generation path (handles generating state + Supabase persist)
        await generateProgram(gymProfile: gymProfile)
    }

    // MARK: - Generate

    /// Triggers program generation from a GymProfile and UserProfile.
    /// Called from the empty state CTA and from regenerateProgram().
    func generateProgram(gymProfile: GymProfile) async {
        guard await !programGenerationService.isGenerating else { return }
        viewState = .generating

        // Build a minimal user profile for generation.
        // In Phase 4 this will draw from HealthKit / onboarding data.
        let userProfile = UserProfile(
            userId: userId.uuidString,
            experienceLevel: "intermediate",
            goals: ["hypertrophy"],
            bodyweightKg: nil,
            ageYears: nil
        )

        do {
            let mesocycle = try await programGenerationService.generate(
                userProfile: userProfile,
                gymProfile: gymProfile
            )
            // Persist to Supabase (fire-and-forget for UX speed)
            let capturedUserId = userId
            let capturedClient = supabaseClient
            Task.detached {
                do {
                    try await capturedClient.deactivatePrograms(userId: capturedUserId)
                    let row = ProgramRow.forInsert(from: mesocycle, userId: capturedUserId)
                    try await capturedClient.insert(row, table: "programs")
                } catch {
                    // Non-fatal: program already in local cache
                }
            }
            mesocycle.saveToUserDefaults()
            viewState = .loaded(mesocycle)
        } catch ProgramGenerationError.equipmentConstraintViolation(let violations) {
            viewState = .error("Could not satisfy equipment constraints for \(violations.count) exercise(s). Please re-scan your gym.")
        } catch {
            viewState = .error(error.localizedDescription)
        }
    }

    // MARK: - Computed helpers

    /// Current week index (0-based) based on mesocycle creation date.
    func currentWeekIndex(in mesocycle: Mesocycle) -> Int {
        let elapsed = Date().timeIntervalSince(mesocycle.createdAt)
        let weeks = Int(elapsed / (7 * 24 * 3600))
        return min(weeks, mesocycle.weeks.count - 1)
    }
}
