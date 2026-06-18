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

    // Slice 6 (#10) — set-intent capture for manual log entries.
    /// Selected intent. Nil until the user picks one — no silent default.
    var intent: SetIntent? = nil
    /// Whether the user has explicitly interacted with the intent picker
    /// for this set. Save is gated on this flag for every non-empty entry.
    /// The flag is the load-bearing rule from issue #10 — even if a future
    /// flow pre-fills `intent`, the user must still tap.
    var intentTouched: Bool = false

    /// True when this entry has weight or reps and therefore counts toward
    /// the manual-log submission. Mirrors the
    /// `guard reps > 0 || weight > 0 else { continue }` filter applied at
    /// submit time (see `submitSession`). Empty entries are skipped — they
    /// neither gate nor contribute.
    var hasContent: Bool {
        let parsedWeight = Double(weightString.replacingOccurrences(of: ",", with: ".")) ?? weightKg
        return reps > 0 || parsedWeight > 0
    }
}

// MARK: - Submit gate (Slice 6 / #10) — unit-testable helper

/// Returns true when every non-empty set entry across every exercise has
/// a touched intent. Pulled out as a top-level function so the gate is
/// observable from XCTest without a SwiftUI / @State harness.
///
/// AC from issue #10: Save disabled until each non-empty set entry has
/// an explicitly-tapped intent. Empty entries (no weight, no reps) do
/// not gate — they're filtered out at submit.
func manualLogCanSubmit(entries: [ManualExerciseEntry]) -> Bool {
    for entry in entries {
        for setEntry in entry.sets where setEntry.hasContent {
            if !setEntry.intentTouched { return false }
        }
    }
    return true
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
                Apex.bg.ignoresSafeArea()

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Apex.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(existingSessionId != nil ? "ADD SET LOGS" : "LOG PAST SESSION")
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .foregroundStyle(Apex.textDim)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Apex.textDim)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(day.dayLabel.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 20, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                    ApexSectionLabel(
                        text: "Week \(week.weekNumber) · \(week.phase.displayTitle)",
                        color: Apex.textFaint
                    )
                }
                Spacer()
                Text("MANUAL")
                    .font(.system(size: 10, weight: .black))
                    .fontWidth(.condensed)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(Apex.onAccent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Apex.accent))
            }

            Rectangle().fill(Apex.hairline).frame(height: 1)

            // Date picker
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Apex.textDim)
                ApexSectionLabel(text: "Session Date")
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
                .tint(Apex.accent)
            }
        }
        .padding(16)
        .apexCard()
    }

    // MARK: - Submit Button

    /// Slice 6 (#10): Save is disabled until every non-empty set entry has
    /// a touched intent. Gating logic lives in the file-scope helper
    /// `manualLogCanSubmit(entries:)` so it's unit-testable.
    private var canSubmit: Bool {
        !isSubmitting && manualLogCanSubmit(entries: entries)
    }

    private var submitButton: some View {
        VStack(spacing: 10) {
            // Inline hint when the gate is closed by missing intents — gives
            // the user a reason for the disabled state rather than a silent
            // dead button.
            if !isSubmitting && !manualLogCanSubmit(entries: entries) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .bold))
                    Text("Pick an intent for every logged set before saving")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Apex.amber)
            }

            Button(action: {
                Task { await submitSession() }
            }) {
                ApexButton(
                    title: isSubmitting ? "Saving…" : "Save Session",
                    icon: isSubmitting ? nil : "checkmark"
                )
                .opacity(canSubmit ? 1.0 : 0.35)
            }
            .disabled(!canSubmit)
            .accessibilityHint(canSubmit
                               ? "Save this manual session"
                               : "Pick an intent for every logged set first")
            .animation(.easeInOut(duration: 0.18), value: canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [Apex.bg.opacity(0), Apex.bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Success Banner

    private var successBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Apex.accent)
            Text("Session logged successfully")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Apex.text)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Capsule().fill(Apex.surface))
        .overlay(Capsule().stroke(Apex.hairline, lineWidth: 1))
    }

    // MARK: - Submission Logic

    @MainActor
    private func submitSession() async {
        isSubmitting = true
        defer { isSubmitting = false }

        // #369 slice 6: a manual session creates owned workout_sessions/set_logs
        // rows, so resolve the real owner first and abort rather than stamping the
        // placeholder (which RLS would reject). isSubmitting resets via the defer;
        // surface the reason via the existing Log-Failed alert rather than silently.
        guard let userId = await deps.resolvedOwnerUserId() else {
            errorMessage = "Sign-in isn't confirmed yet. Please wait a moment and try again."
            return
        }

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
                manuallyLogged: true,
                status: "completed"   // #369 [10] — count toward PR baselines / last-time anchors
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
        var allSetLogs: [(SetLog, PlannedExercise, SetIntent)] = []
        for entry in entries {
            for (setIndex, setEntry) in entry.sets.enumerated() {
                // Skip empty sets (weight 0 and reps 0) unless user explicitly entered something
                let weight = parseWeight(setEntry.weightString) ?? setEntry.weightKg
                let reps = setEntry.reps
                guard reps > 0 || weight > 0 else { continue }

                let rpe = parseRPE(setEntry.rpeString) ?? setEntry.rpe
                // Slice 6 / #60: intent must be non-nil when writing to set_logs
                // (NOT NULL schema constraint). Manual-entry picker is optional, so
                // fall back to .top — the most likely intent for a manually logged
                // set the user actually did. Documented at-the-call-site default per
                // ADR-0005 "no silent defaults at any layer" — if the user didn't
                // pick, the choice is visible in this code, not silently resolved
                // inside the encoder.
                let resolvedIntent: SetIntent = setEntry.intent ?? .top

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
                    primaryMuscle: ExerciseLibrary.primaryMuscle(for: entry.exercise.exerciseId)?.rawValue ?? entry.exercise.primaryMuscle,
                    intent: resolvedIntent
                )
                allSetLogs.append((setLog, entry.exercise, resolvedIntent))
            }
        }

        // Write set logs to Supabase
        for (setLog, _, intent) in allSetLogs {
            let payload = ManualSetLogPayload(from: setLog, intent: intent)
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

        for (setLog, exercise, _) in allSetLogs {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.exercise.name)
                        .font(.system(size: 16, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                    ApexTagChip(
                        text: entry.exercise.primaryMuscle.formattedMuscleName,
                        tint: muscleColor(for: entry.exercise.primaryMuscle)
                    )
                }
                Spacer()
                Text(entry.exercise.equipmentRequired.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Rectangle().fill(Apex.hairline).frame(height: 1)

            // Column headers
            HStack(spacing: 0) {
                ApexSectionLabel(text: "Set", color: Apex.textFaint)
                    .frame(width: 32, alignment: .center)
                ApexSectionLabel(text: "Weight (kg)", color: Apex.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                ApexSectionLabel(text: "Reps", color: Apex.textFaint)
                    .frame(width: 56, alignment: .center)
                ApexSectionLabel(text: "RPE", color: Apex.textFaint)
                    .frame(width: 48, alignment: .center)
                ApexSectionLabel(text: "Intent", color: Apex.textFaint)
                    .frame(width: 80, alignment: .center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle().fill(Apex.hairline.opacity(0.5)).frame(height: 1)

            // Set rows
            ForEach($entry.sets) { $setEntry in
                SetInputRow(
                    setNumber: (entry.sets.firstIndex(where: { $0.id == setEntry.id }) ?? 0) + 1,
                    setEntry: $setEntry
                )
                if setEntry.id != entry.sets.last?.id {
                    Rectangle().fill(Apex.hairline.opacity(0.35))
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }

            Rectangle().fill(Apex.hairline.opacity(0.5)).frame(height: 1)

            // Add / remove set buttons
            HStack(spacing: 16) {
                Button(action: {
                    entry.sets.append(ManualSetEntry())
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .black))
                        Text("Add Set")
                            .font(.system(size: 13, weight: .bold))
                            .fontWidth(.condensed)
                            .textCase(.uppercase)
                            .tracking(0.8)
                    }
                    .foregroundStyle(Apex.accent)
                }
                .buttonStyle(.plain)

                if entry.sets.count > 1 {
                    Button(action: {
                        entry.sets.removeLast()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "minus")
                                .font(.system(size: 12, weight: .black))
                            Text("Remove")
                                .font(.system(size: 13, weight: .bold))
                                .fontWidth(.condensed)
                                .textCase(.uppercase)
                                .tracking(0.8)
                        }
                        .foregroundStyle(Apex.textDim)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .apexCard()
    }

    private func muscleColor(for muscle: String) -> Color {
        // Typed-first dispatch (Slice 1) with substring-match fallback for
        // non-canonical strings. Core branch removed — core is excluded from
        // the locked-six taxonomy per ADR-0005.
        if let primary = PrimaryMuscle(rawValue: muscle.lowercased()) {
            switch primary {
            case .chest:                            return Color(red: 0.96, green: 0.42, blue: 0.30)
            case .back:                             return Color(red: 0.30, green: 0.70, blue: 0.96)
            case .shoulders:                        return Color(red: 0.70, green: 0.50, blue: 0.96)
            case .quads, .hamstrings, .glutes,
                 .calves:                           return Color(red: 0.30, green: 0.96, blue: 0.60)
            case .biceps, .triceps:                 return Color(red: 0.96, green: 0.80, blue: 0.30)
            }
        }
        let lower = muscle.lowercased()
        if lower.contains("pector") || lower.contains("chest") { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if lower.contains("lat") || lower.contains("back") || lower.contains("rhom") { return Color(red: 0.30, green: 0.70, blue: 0.96) }
        if lower.contains("delt") || lower.contains("shoulder") { return Color(red: 0.70, green: 0.50, blue: 0.96) }
        if lower.contains("quad") || lower.contains("hamstr") || lower.contains("glut") || lower.contains("calf") { return Color(red: 0.30, green: 0.96, blue: 0.60) }
        if lower.contains("bicep") || lower.contains("tricep") { return Color(red: 0.96, green: 0.80, blue: 0.30) }
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
            ApexNumeral(text: "\(setNumber)", size: 15, color: Apex.textDim)
                .frame(width: 32, alignment: .center)

            // Weight input
            TextField("0", text: $setEntry.weightString)
                .keyboardType(.decimalPad)
                .font(Apex.numeral(16, weight: .bold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

            // Reps stepper
            HStack(spacing: 4) {
                Button(action: {
                    setEntry.reps = max(0, setEntry.reps - 1)
                }) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Apex.textDim)
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)

                ApexNumeral(text: "\(setEntry.reps)", size: 15)
                    .frame(width: 24, alignment: .center)

                Button(action: {
                    setEntry.reps = setEntry.reps + 1
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Apex.textDim)
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 56)

            // RPE input (optional, 1-10)
            TextField("—", text: $setEntry.rpeString)
                .keyboardType(.numberPad)
                .font(Apex.numeral(15, weight: .bold))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.textDim)
                .multilineTextAlignment(.center)
                .frame(width: 48)
                .padding(.vertical, 10)

            // Intent picker (Slice 6 / #10).
            //
            // Deliberate asymmetry with ActiveSetView's chip-row picker:
            // ActiveSetView dedicates the full screen width to one set,
            // so a 5-chip row is thumb-friendly and visually rich. This
            // surface packs N exercises × M sets per exercise into a
            // dense table — adding a 5-chip row per set would either
            // double the table height (a chip row below each input row)
            // or wrap-fail at iPhone widths (5 × ~80pt chip > 375pt
            // available row width minus the existing 4 columns). A
            // compact Menu fits as a 5th column in the existing row
            // rhythm.
            //
            // The trade-off is one of two interaction patterns for the
            // same data type — chips elsewhere, dropdown here. Documented
            // in the PR description so future maintainers understand the
            // intent. If the manual log is ever redesigned to a per-set
            // expanded layout (e.g. card per set), revisit and unify on
            // chips.
            //
            // Visual: shows "—" while untouched (cue that the field is
            // required); shows the selected intent name once tapped.
            // Empty rows (weight = 0 AND reps = 0) don't gate at submit,
            // but the picker is still tappable so the user can fill the
            // intent before the numbers if they prefer that order.
            intentMenu
                .frame(width: 80)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var intentMenu: some View {
        Menu {
            ForEach(SetIntent.allCases, id: \.self) { intent in
                Button {
                    setEntry.intent = intent
                    setEntry.intentTouched = true
                } label: {
                    if setEntry.intent == intent {
                        Label(intentLabel(intent), systemImage: "checkmark")
                    } else {
                        Text(intentLabel(intent))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(setEntry.intentTouched
                     ? (setEntry.intent.map(intentLabel) ?? "—")
                     : "—")
                    .font(.system(size: 12, weight: .bold))
                    .fontWidth(.condensed)
                    .foregroundStyle(setEntry.intentTouched
                                     ? Apex.accent
                                     : Apex.textDim)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Apex.textFaint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(
                        setEntry.intentTouched
                            ? Apex.accent.opacity(0.55)
                            : Apex.hairline,
                        lineWidth: setEntry.intentTouched ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set \(setNumber) intent")
        .accessibilityValue(setEntry.intent.map(intentLabel) ?? "Not selected")
    }

    private func intentLabel(_ intent: SetIntent) -> String {
        switch intent {
        case .warmup:    return "Warmup"
        case .top:       return "Top"
        case .backoff:   return "Backoff"
        case .technique: return "Technique"
        case .amrap:     return "AMRAP"
        }
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
    /// #369 [10]: a manually-logged session is a completed session. Without an
    /// explicit status the row is inserted with status = NULL, and the PR-baseline
    /// / last-performance queries filter `status != "abandoned"` — under which NULL
    /// evaluates to NULL (not true), silently excluding manual sessions from PR
    /// baselines and last-time anchors. Setting "completed" makes them count.
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId         = "user_id"
        case programId      = "program_id"
        case sessionDate    = "session_date"
        case weekNumber     = "week_number"
        case dayType        = "day_type"
        case completed
        case manuallyLogged = "manually_logged"
        case status
    }
}

/// set_logs row for manually entered sets (no ai_prescribed column).
// internal (not private): exposed for encoder regression tests (#66).
struct ManualSetLogPayload: Encodable {
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
    let localDate: String
    let intent: String

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
        case localDate     = "local_date"
        case intent
    }

    /// Slice 6 / #60 fix: intent and local_date are required by the schema.
    /// intent is a required init parameter (compiler-enforced) per ADR-0005
    /// "no silent defaults at any layer."
    init(from log: SetLog, intent: SetIntent) {
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
        self.localDate     = SetLog.formatLocalDate(log.loggedAt)
        self.intent        = intent.rawValue
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

// MARK: - Slice 6 picker previews (#10)
//
// Exercises the per-set intent picker (compact Menu in the rightmost
// column) under realistic mixed-state data. HITL visual review uses
// these to verify column readability at iPhone Pro widths and the
// touched/untouched visual distinction.

private struct ManualLogIntentPickerPreview: View {
    @State private var entry: ManualExerciseEntry

    init() {
        let exercise = PlannedExercise(
            id: UUID(),
            exerciseId: "barbell_bench_press",
            name: "Barbell Bench Press",
            primaryMuscle: "pectoralis_major",
            synergists: ["anterior_deltoid", "triceps_brachii"],
            equipmentRequired: .barbell,
            sets: 4,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 150,
            rirTarget: 2,
            coachingCues: []
        )
        var e = ManualExerciseEntry(exercise: exercise)
        // Replace auto-generated empties with a realistic mixed-state set.
        // Set 1: confirmed top (touched) — picker shows "Top" in blue.
        var s1 = ManualSetEntry(); s1.weightString = "80"; s1.reps = 10
        s1.rpeString = "7"; s1.intent = .top; s1.intentTouched = true
        // Set 2: non-empty but UNTOUCHED — gates the Save button. Picker
        // shows "—" in muted white. This is the case the AC hangs on.
        var s2 = ManualSetEntry(); s2.weightString = "80"; s2.reps = 10
        s2.rpeString = "8"
        // Set 3: empty — does not gate, picker still tappable but stays "—".
        let s3 = ManualSetEntry()
        // Set 4: confirmed backoff (touched) — picker shows "Backoff" in blue.
        var s4 = ManualSetEntry(); s4.weightString = "70"; s4.reps = 8
        s4.rpeString = "7"; s4.intent = .backoff; s4.intentTouched = true
        e.sets = [s1, s2, s3, s4]
        _entry = State(initialValue: e)
    }

    var body: some View {
        ZStack {
            Apex.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    ExerciseLogCard(entry: $entry)
                        .padding(.horizontal, 16)
                }
                .padding(.top, 16)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Manual log — 4 sets, mixed touched/untouched") {
    // Row 1 (touched, .top):       Picker shows "Top"     in app-blue.
    // Row 2 (NON-EMPTY, untouched): Picker shows "—" muted — the gating case.
    // Row 3 (empty):                Picker shows "—" muted — does not gate.
    // Row 4 (touched, .backoff):    Picker shows "Backoff" in app-blue.
    // The Save Session button (not visible in this card-only preview) would
    // be DISABLED by row 2's untouched intent.
    ManualLogIntentPickerPreview()
}
