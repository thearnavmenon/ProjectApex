// ManualSessionLogView.swift
// ProjectApex — Features/Workout
//
// Manual session logging sheet. Allows the user to enter what they lifted
// (weight, reps, RPE) for each exercise in a programme day, then submit the
// session to Supabase as a completed, manually-logged record.
//
// Use cases:
//   • Logging a workout done without the app (backdating)
//   • Seeding realistic test data before the AI has enough live sessions
//   • Logging a session done at a different gym
//
// Behaviour:
//   • No AI inference calls — pure data entry
//   • Writes to workout_sessions with manually_logged: true
//   • Writes individual set_logs for each set entered
//   • Calls MemoryService.embed() per set log (AI learns from manual sessions)
//   • Marks the day as completed in the programme calendar

import SwiftUI

// MARK: - ManualSetEntry

/// Transient UI state for a single set within a manual log entry.
struct ManualSetEntry: Identifiable {
    let id = UUID()
    var weightKg: Double = 0
    var reps: Int = 0
    var rpe: Int? = nil

    // Formatted weight string for the text field
    var weightString: String = ""
    var rpeString: String = ""
}

// MARK: - ManualExerciseEntry

/// Transient UI state for one exercise in the manual log form.
struct ManualExerciseEntry: Identifiable {
    let exercise: PlannedExercise
    var sets: [ManualSetEntry]

    var id: String { exercise.exerciseId }

    init(exercise: PlannedExercise) {
        self.exercise = exercise
        // Pre-populate with the planned number of sets
        self.sets = (1...max(1, exercise.sets)).map { _ in ManualSetEntry() }
    }
}

// MARK: - ManualSessionLogView

struct ManualSessionLogView: View {

    let day: TrainingDay
    let week: TrainingWeek
    let mesocycleCreatedAt: Date
    /// The mesocycle programme ID — stored on the workout_sessions row.
    let programId: UUID
    /// When non-nil, skips creating a new session row and writes set logs directly
    /// against this existing session ID. Used to backfill missing set logs.
    var existingSessionId: UUID? = nil
    /// Called after a successful submit so the caller can mark the day as completed.
    var onSessionLogged: (() -> Void)? = nil

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    /// The date the user says they trained on. Defaults to today.
    @State private var sessionDate: Date = Date()
    /// Per-exercise log entries initialised from the day's exercise list.
    @State private var entries: [ManualExerciseEntry]
    /// Submission in progress.
    @State private var isSubmitting: Bool = false
    /// Error message shown in an alert.
    @State private var errorMessage: String? = nil
    /// Shown on success before dismissal.
    @State private var showSuccessBanner: Bool = false

    init(day: TrainingDay, week: TrainingWeek, mesocycleCreatedAt: Date, programId: UUID, existingSessionId: UUID? = nil, onSessionLogged: (() -> Void)? = nil) {
        self.day = day
        self.week = week
        self.mesocycleCreatedAt = mesocycleCreatedAt
        self.programId = programId
        self.existingSessionId = existingSessionId
        self.onSessionLogged = onSessionLogged
        _entries = State(initialValue: day.exercises.map { ManualExerciseEntry(exercise: $0) })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        headerCard
                        ForEach($entries) { $entry in
                            ExerciseLogCard(entry: $entry)
                        }
                        Color.clear.frame(height: 100)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                VStack {
                    Spacer()
                    submitButton
                }
            }
            .navigationTitle(existingSessionId != nil ? "Add Set Logs" : "Log Past Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.04, green: 0.04, blue: 0.06), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.70))
                }
            }
            .alert("Log Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .overlay(alignment: .top) {
                if showSuccessBanner {
                    successBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showSuccessBanner)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(day.dayLabel.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Week \(week.weekNumber) · \(week.phase.displayTitle)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text("MANUAL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.78, green: 0.82, blue: 0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.78, green: 0.82, blue: 0.88).opacity(0.12), in: Capsule())
            }

            Divider().background(Color.white.opacity(0.08))

            // Date picker
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Session Date")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
                DatePicker(
                    "",
                    selection: $sessionDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .colorScheme(.dark)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Submit Button

    private var submitButton: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.06))
            Button(action: {
                Task { await submitSession() }
            }) {
                HStack(spacing: 10) {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    Text(isSubmitting ? "Saving…" : "Save Session")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    isSubmitting
                        ? Color(red: 0.23, green: 0.56, blue: 1.00).opacity(0.60)
                        : Color(red: 0.23, green: 0.56, blue: 1.00),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .foregroundStyle(.white)
            }
            .disabled(isSubmitting)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
        }
    }

    // MARK: - Success Banner

    private var successBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.30, green: 0.96, blue: 0.60))
            Text("Session logged successfully")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Submission Logic

    @MainActor
    private func submitSession() async {
        isSubmitting = true
        defer { isSubmitting = false }

        let userId = deps.resolvedUserId

        // DATE column (session_date): use local calendar date string to avoid UTC-offset rollover.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        // Intentionally use the device's local calendar so the date matches what the user selected.
        let sessionDateString = dateFormatter.string(from: sessionDate)

        // TIMESTAMP columns (logged_at, etc.): use full ISO8601 with timezone.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone.current

        // When backfilling an existing completed session, skip creating a new session row.
        let sessionId: UUID
        if let existing = existingSessionId {
            print("[ManualSessionLog] Backfilling set logs for existing session: \(existing)")
            sessionId = existing
        } else {
            print("[ManualSessionLog] Submitting session for date: \(sessionDateString) (local: \(sessionDate))")
            sessionId = UUID()
            let sessionPayload = ManualSessionPayload(
                id: sessionId.uuidString,
                userId: userId.uuidString,
                programId: programId.uuidString,
                sessionDate: sessionDateString,
                weekNumber: week.weekNumber,
                dayType: day.dayLabel,
                completed: true,
                manuallyLogged: true
            )
            do {
                try await deps.supabaseClient.insert(sessionPayload, table: "workout_sessions")
                // Count this as a completed session so subsequent inference calls
                // are not treated as first-session calibration (FB-005).
                let current = UserDefaults.standard.integer(forKey: UserProfileConstants.sessionCountKey)
                UserDefaults.standard.set(current + 1, forKey: UserProfileConstants.sessionCountKey)
            } catch {
                errorMessage = "Could not save session: \(error.localizedDescription)"
                return
            }
        }

        // Build and write set logs
        var allSetLogs: [(SetLog, PlannedExercise)] = []
        for entry in entries {
            for (setIndex, setEntry) in entry.sets.enumerated() {
                // Skip empty sets (weight 0 and reps 0) unless user explicitly entered something
                let weight = parseWeight(setEntry.weightString) ?? setEntry.weightKg
                let reps = setEntry.reps
                guard reps > 0 || weight > 0 else { continue }

                let rpe = parseRPE(setEntry.rpeString) ?? setEntry.rpe

                let setLog = SetLog(
                    id: UUID(),
                    sessionId: sessionId,
                    exerciseId: entry.exercise.exerciseId,
                    setNumber: setIndex + 1,
                    weightKg: weight,
                    repsCompleted: reps,
                    rpeFelt: rpe,
                    rirEstimated: rpe.map { max(0, 10 - $0) },
                    aiPrescribed: nil,
                    loggedAt: sessionDate,
                    primaryMuscle: ExerciseLibrary.primaryMuscle(for: entry.exercise.exerciseId) ?? entry.exercise.primaryMuscle
                )
                allSetLogs.append((setLog, entry.exercise))
            }
        }

        // Write set logs to Supabase
        for (setLog, _) in allSetLogs {
            let payload = ManualSetLogPayload(from: setLog)
            do {
                try await deps.supabaseClient.insert(payload, table: "set_logs")
            } catch {
                // Non-fatal: continue writing remaining sets
                print("[ManualSessionLog] set_log write failed: \(error.localizedDescription)")
            }
        }

        // Embed set logs into RAG memory (fire-and-forget)
        let memoryService = deps.memoryService
        let userIdStr = userId.uuidString
        let sessionIdStr = sessionId.uuidString

        for (setLog, exercise) in allSetLogs {
            let weight = setLog.weightKg
            let reps = setLog.repsCompleted
            let rpeStr = setLog.rpeFelt.map { ", RPE \($0)" } ?? ""
            let text = "Manual log — \(exercise.name): \(formatWeight(weight))kg x \(reps)\(rpeStr)"
            let tags = ["manual_log", "exercise_outcome"]
            let muscleGroups = [exercise.primaryMuscle] + exercise.synergists
            let exerciseId = exercise.exerciseId

            Task.detached {
                await memoryService.embed(
                    text: text,
                    sessionId: sessionIdStr,
                    exerciseId: exerciseId,
                    tags: tags,
                    muscleGroups: muscleGroups,
                    userId: userIdStr
                )
            }
        }

        // Notify caller that the session was logged (e.g. to mark the day completed)
        onSessionLogged?()

        // Show success banner then dismiss
        showSuccessBanner = true
        try? await Task.sleep(for: .seconds(1.2))
        dismiss()
    }

    // MARK: - Helpers

    private func parseWeight(_ str: String) -> Double? {
        guard !str.isEmpty else { return nil }
        return Double(str.replacingOccurrences(of: ",", with: "."))
    }

    private func parseRPE(_ str: String) -> Int? {
        guard !str.isEmpty else { return nil }
        guard let val = Int(str), (1...10).contains(val) else { return nil }
        return val
    }

    private func formatWeight(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", kg)
            : String(format: "%.1f", kg)
    }
}

// MARK: - ExerciseLogCard

private struct ExerciseLogCard: View {

    @Binding var entry: ManualExerciseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Exercise header
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.exercise.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(entry.exercise.primaryMuscle.formattedMuscleName)
                        .font(.caption2.bold())
                        .foregroundStyle(muscleColor(for: entry.exercise.primaryMuscle))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(muscleColor(for: entry.exercise.primaryMuscle).opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(entry.exercise.equipmentRequired.displayName)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.08))

            // Column headers
            HStack(spacing: 0) {
                Text("SET")
                    .frame(width: 40, alignment: .center)
                Text("WEIGHT (KG)")
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("REPS")
                    .frame(width: 64, alignment: .center)
                Text("RPE")
                    .frame(width: 64, alignment: .center)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .kerning(0.4)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.06))

            // Set rows
            ForEach($entry.sets) { $setEntry in
                SetInputRow(
                    setNumber: (entry.sets.firstIndex(where: { $0.id == setEntry.id }) ?? 0) + 1,
                    setEntry: $setEntry
                )
                if setEntry.id != entry.sets.last?.id {
                    Divider()
                        .background(Color.white.opacity(0.05))
                        .padding(.leading, 16)
                }
            }

            Divider().background(Color.white.opacity(0.06))

            // Add / remove set buttons
            HStack(spacing: 12) {
                Button(action: {
                    entry.sets.append(ManualSetEntry())
                }) {
                    Label("Add Set", systemImage: "plus.circle")
                        .font(.caption.bold())
                        .foregroundStyle(Color(red: 0.23, green: 0.56, blue: 1.00))
                }
                .buttonStyle(.plain)

                if entry.sets.count > 1 {
                    Button(action: {
                        entry.sets.removeLast()
                    }) {
                        Label("Remove", systemImage: "minus.circle")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.40))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func muscleColor(for muscle: String) -> Color {
        let lower = muscle.lowercased()
        if lower.contains("pector") || lower.contains("chest") { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if lower.contains("lat") || lower.contains("back") || lower.contains("rhom") { return Color(red: 0.30, green: 0.70, blue: 0.96) }
        if lower.contains("delt") || lower.contains("shoulder") { return Color(red: 0.70, green: 0.50, blue: 0.96) }
        if lower.contains("quad") || lower.contains("hamstr") || lower.contains("glut") || lower.contains("calf") { return Color(red: 0.30, green: 0.96, blue: 0.60) }
        if lower.contains("bicep") || lower.contains("tricep") { return Color(red: 0.96, green: 0.80, blue: 0.30) }
        if lower.contains("core") || lower.contains("abdom") { return Color(red: 0.96, green: 0.60, blue: 0.30) }
        return Color(red: 0.78, green: 0.82, blue: 0.88)
    }
}

// MARK: - SetInputRow

private struct SetInputRow: View {

    let setNumber: Int
    @Binding var setEntry: ManualSetEntry

    var body: some View {
        HStack(spacing: 0) {
            // Set number
            Text("\(setNumber)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 40, alignment: .center)

            // Weight input
            TextField("0", text: $setEntry.weightString)
                .keyboardType(.decimalPad)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

            // Reps stepper
            HStack(spacing: 6) {
                Button(action: {
                    setEntry.reps = max(0, setEntry.reps - 1)
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.50))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)

                Text("\(setEntry.reps)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 30, alignment: .center)

                Button(action: {
                    setEntry.reps = setEntry.reps + 1
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.50))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 64)

            // RPE input (optional, 1-10)
            TextField("—", text: $setEntry.rpeString)
                .keyboardType(.numberPad)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.70))
                .multilineTextAlignment(.center)
                .frame(width: 64)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Supabase Payload DTOs (Manual logging)

/// workout_sessions row with the additional manually_logged flag.
private struct ManualSessionPayload: Encodable {
    let id: String
    let userId: String
    let programId: String
    let sessionDate: String
    let weekNumber: Int
    let dayType: String
    let completed: Bool
    let manuallyLogged: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case programId      = "program_id"
        case sessionDate    = "session_date"
        case weekNumber     = "week_number"
        case dayType        = "day_type"
        case completed
        case manuallyLogged = "manually_logged"
    }
}

/// set_logs row for manually entered sets (no ai_prescribed column).
private struct ManualSetLogPayload: Encodable {
    let id: String
    let sessionId: String
    let exerciseId: String
    let setNumber: Int
    let weightKg: Double
    let repsCompleted: Int
    let rpeFelt: Int?
    let rirEstimated: Int?
    let loggedAt: String
    let primaryMuscle: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId     = "session_id"
        case exerciseId    = "exercise_id"
        case setNumber     = "set_number"
        case weightKg      = "weight_kg"
        case repsCompleted = "reps_completed"
        case rpeFelt       = "rpe_felt"
        case rirEstimated  = "rir_estimated"
        case loggedAt      = "logged_at"
        case primaryMuscle = "primary_muscle"
    }

    init(from log: SetLog) {
        let formatter = ISO8601DateFormatter()
        self.id            = log.id.uuidString
        self.sessionId     = log.sessionId.uuidString
        self.exerciseId    = log.exerciseId
        self.setNumber     = log.setNumber
        self.weightKg      = log.weightKg
        self.repsCompleted = log.repsCompleted
        self.rpeFelt       = log.rpeFelt
        self.rirEstimated  = log.rirEstimated
        self.loggedAt      = formatter.string(from: log.loggedAt)
        self.primaryMuscle = log.primaryMuscle
    }
}

// MARK: - String helper (reused from ProgramDayDetailView scope)

private extension String {
    /// Converts snake_case muscle names to Title Case for display.
    var formattedMuscleName: String {
        self.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Preview

#Preview {
    ManualSessionLogView(
        day: Mesocycle.mockMesocycle().weeks[0].trainingDays[0],
        week: Mesocycle.mockMesocycle().weeks[0],
        mesocycleCreatedAt: Date(),
        programId: UUID()
    )
    .environment(AppDependencies())
}
