// OnboardingView.swift
// ProjectApex — Onboarding Feature  (P4-T09 → Brutalist overhaul #527 S1)
//
// Full first-run onboarding sequence presented as a full-screen sheet over
// the main TabView. Dismissed only after the user reaches the program-ready
// reveal and taps Start Training.
//
// Flow (#527 — Brutalist overhaul):
//   Intro:   Welcome → 3 "how it works" concept cards (no progress rail)
//   Profile (one question per screen, sharp segmented rail + NN/TT counter):
//     01 Name · 02 Experience · 03 Goal · 04 Days/week
//     05 Bodyweight (expected) + optional Height/Age
//     06 Sex (NEW) · 07 Injuries (NEW, optional) ·
//     08 Equipment (presets → review) · 09 Notifications (moved late)
//   Generating  → program-ready reveal → Start Training.
//
// First-run detection: KeychainService.retrieve(.userId) == nil
// On completion (#369 slice 3): the anonymous-auth `auth.uid()` is written to
// Keychain.userId (mirroring the auth subject, not a fresh UUID()); the
// public.users row is keyed to that same uid so slice 5's RLS policy matches.
// onboardingCompleted is stored in UserDefaults so subsequent launches skip
// this view immediately.
//
// The camera scanner was removed from onboarding (#527): equipment is collected
// via presets + the existing manual BulkEquipmentPickerSheet, never the camera.

import SwiftUI
import UserNotifications

// MARK: - Training Profile Input Model

/// Collected during the profile steps. Passed into ProgramGenerationService.
struct OnboardingProfile: Sendable {
    var displayName: String = ""
    var trainingAge: TrainingAge = .beginner
    var primaryGoal: TrainingGoal = .hypertrophy
    var daysPerWeek: Int = 4

    // FB-003: biometric fields
    /// User's bodyweight — optional, onboarding is not blocked if absent.
    var bodyweightKg: Double? = nil
    /// User's height in cm.
    var heightCm: Double? = nil
    /// User's age in years.
    var age: Int? = nil
    /// Whether bodyweight input is in kg (true) or lbs (false).
    var bodyweightInKg: Bool = true

    /// Biological sex (#527) — lowercase "male"/"female"; nil = prefer-not-to-say
    /// / unset. Persisted to UserDefaults only (no `users` column — see
    /// persistUserIfNeeded).
    var sex: String? = nil

    /// Injury / "work around" areas the user tapped (#527). Collected here for
    /// Slice 2 to persist as user-confirmed limitations; not written yet.
    var injuryAreas: Set<String> = []
}

enum TrainingAge: String, CaseIterable, Sendable {
    case beginner     = "Beginner (< 1 yr)"
    case intermediate = "Intermediate (1–3 yrs)"
    case advanced     = "Advanced (3+ yrs)"
}

enum TrainingGoal: String, CaseIterable, Sendable {
    case hypertrophy = "Hypertrophy (muscle size)"
    case strength    = "Strength (max weight)"
    case endurance   = "Muscular endurance"
    case general     = "General fitness"
}

// MARK: - OnboardingView

struct OnboardingView: View {

    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismiss) private var dismiss

    // Called when onboarding fully completes so ContentView can switch to Program tab.
    var onCompleted: ((GymProfile?) -> Void)? = nil

    // ── Flow steps ────────────────────────────────────────────────────────────
    // Intro (no rail) → numbered profile (rail) → generating → ready.
    private enum Step: Int, CaseIterable {
        case welcome, how          // intro
        case name, experience, goal, days, body, sex, injuries, equipment, notifications // profile (1…9)
        case generating, ready
    }

    @State private var step: Step = .welcome
    /// Which concept card (1…3) the "how it works" pager shows.
    @State private var howIndex: Int = 1

    @State private var profile = OnboardingProfile()
    /// Seeded from the UserDefaults cache (#318 U4) so equipment confirmed
    /// before an app kill rehydrates instead of forcing a re-entry.
    @State private var gymProfile: GymProfile? = GymProfile.loadFromUserDefaults()
    /// True once the user has confirmed an equipment list (presets review).
    /// Onboarding stays completable even if equipment is empty.
    @State private var notifGranted: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generationError: String? = nil

    /// Equipment review-list working copy (built from a preset or rehydrated).
    @State private var reviewItems: [EquipmentItem] = []
    @State private var presetLabel: String = ""
    @State private var showingEquipmentReview: Bool = false
    @State private var showingBulkPicker: Bool = false

    /// The total number of numbered profile steps shown on the rail.
    private let railTotal = 9

    var body: some View {
        ZStack {
            Apex.bg.ignoresSafeArea()

            Group {
                switch step {
                case .welcome:       welcomeView
                case .how:           howView
                case .name:          nameView
                case .experience:    experienceView
                case .goal:          goalView
                case .days:          daysView
                case .body:          bodyView
                case .sex:           sexView
                case .injuries:      injuriesView
                case .equipment:     equipmentView
                case .notifications: notificationsView
                case .generating:    generatingView
                case .ready:         readyView
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)  // Prevent accidental swipe-dismiss
        .sheet(isPresented: $showingBulkPicker) {
            BulkEquipmentPickerSheet(
                alreadyAdded: Set(reviewItems.map(\.equipmentType)),
                onConfirm: { items in
                    reviewItems.append(contentsOf: items)
                    showingBulkPicker = false
                },
                onCancel: { showingBulkPicker = false }
            )
        }
    }

    // MARK: - Navigation helpers

    private func go(to next: Step) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { step = next }
    }

    // MARK: - Shared scaffold

    /// Sharp segmented progress rail + tabular "NN / TT" counter.
    private func rail(_ stepNumber: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(0..<railTotal, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(i < stepNumber ? Apex.accent : Color.white.opacity(0.12))
                        .frame(height: 3)
                }
            }
            HStack(spacing: 3) {
                ApexNumeral(text: String(format: "%02d", stepNumber), size: 13, weight: .bold, color: Apex.textDim)
                Text("/ \(String(format: "%02d", railTotal))")
                    .font(.system(size: 12, weight: .semibold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.textFaint)
            }
            .fixedSize()
        }
    }

    /// Bottom action bar — pinned primary button with a fade-up gradient and an
    /// optional secondary text line.
    private func bottomBar(
        primary: String,
        icon: String = "arrow.right",
        enabled: Bool = true,
        action: @escaping () -> Void,
        secondary: (text: String, action: () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            Button(action: action) {
                ApexButton(title: primary, kind: enabled ? .filled : .ghost,
                           icon: icon, tint: enabled ? nil : Apex.textFaint)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)

            if let secondary {
                Button(action: secondary.action) {
                    Text(secondary.text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Apex.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Apex.pad)
        .padding(.bottom, 26)
        .padding(.top, 22)
        .background(
            LinearGradient(colors: [Apex.bg.opacity(0), Apex.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    /// Eyebrow + condensed big title + optional subtitle.
    private func titleBlock(eyebrow: String, title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ApexSectionLabel(text: eyebrow, color: Apex.accent)
            Text(title)
                .font(.system(size: 32, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Apex.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    /// Standard data-collection screen: back + rail header, title block, content,
    /// pinned primary action.
    private func profileScaffold<Content: View>(
        stepNumber: Int,
        back: @escaping () -> Void,
        eyebrow: String,
        title: String,
        subtitle: String? = nil,
        primary: String,
        primaryEnabled: Bool = true,
        primaryAction: @escaping () -> Void,
        secondary: (text: String, action: () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Apex.textDim)
                    }
                    .buttonStyle(.plain)
                    rail(stepNumber)
                }
                .padding(.top, 8)
                .padding(.bottom, 30)

                titleBlock(eyebrow: eyebrow, title: title, subtitle: subtitle)
                    .padding(.bottom, 26)

                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Apex.pad)
            .padding(.top, 8)

            bottomBar(primary: primary, enabled: primaryEnabled,
                      action: primaryAction, secondary: secondary)
        }
    }

    /// Full-width tappable choice card (experience / goal / sex).
    private func choiceCard(title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Apex.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(Apex.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .apexCard(emphasized: selected)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Intro · Welcome

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ApexSectionLabel(text: "Project Apex", color: Apex.accent)
            Text("STRENGTH,\nON AUTOPILOT.")
                .font(.system(size: 52, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .lineSpacing(-2)
                .padding(.top, 12)
            Text("A coach that decides every set for you — and learns who you are while it does it.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Apex.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            Spacer()
            Button { go(to: .how) } label: {
                ApexButton(title: "Begin", icon: "arrow.right")
            }
            .buttonStyle(.plain)
            Text("Takes about two minutes.")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Apex.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
        .padding(.horizontal, Apex.pad)
        .padding(.bottom, 30)
    }

    // MARK: - Intro · How it works (3 concept cards)

    private struct HowConcept { let n, icon, head, body, hot: String }
    private let howCards: [HowConcept] = [
        .init(n: "01", icon: "brain.head.profile", head: "IT'S A REAL COACH",
              body: "Most gym apps are spreadsheets you type into. This one does the thinking — it hands you the ",
              hot: "exact weight and reps, set by set."),
        .init(n: "02", icon: "chart.line.uptrend.xyaxis", head: "IT LEARNS YOU",
              body: "It builds a picture of how strong you are and how fast you recover. ",
              hot: "Every set you log sharpens it."),
        .init(n: "03", icon: "checkmark.seal", head: "IT'S HONEST",
              body: "The bar only ratchets up as you get stronger — it ",
              hot: "never quietly lowers a target."),
    ]

    private var howView: some View {
        let idx = min(max(howIndex, 1), 3)
        let c = howCards[idx - 1]
        return ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button { go(to: .name) } label: {
                        Text("Skip")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Apex.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
                Spacer()
                ApexNumeral(text: c.n, size: 120, weight: .black, color: Color.white.opacity(0.20))
                    .padding(.bottom, -6)
                Image(systemName: c.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Apex.accent)
                    .padding(.bottom, 18)
                ApexSectionLabel(text: "How it works", color: Apex.textFaint)
                Text(c.head)
                    .font(.system(size: 34, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                    .padding(.top, 6)
                (Text(c.body).foregroundColor(Apex.textDim)
                 + Text(c.hot).foregroundColor(Apex.accent))
                    .font(.system(size: 17, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                Spacer()
            }
            .padding(.horizontal, Apex.pad)

            VStack(spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(1...3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i == idx ? Apex.accent : Color.white.opacity(0.18))
                            .frame(width: i == idx ? 22 : 8, height: 3)
                    }
                    Spacer()
                }
                Button {
                    if idx >= 3 { go(to: .name) }
                    else { withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { howIndex = idx + 1 } }
                } label: {
                    ApexButton(title: idx >= 3 ? "Let's set up" : "Next", icon: "arrow.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Apex.pad)
            .padding(.bottom, 26)
            .padding(.top, 22)
            .background(
                LinearGradient(colors: [Apex.bg.opacity(0), Apex.bg],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }

    // MARK: - 01 Name

    private var nameView: some View {
        profileScaffold(
            stepNumber: 1,
            back: {
                howIndex = 3
                go(to: .how)
            },
            eyebrow: "Step 01",
            title: "What should the\ncoach call you?",
            primary: "Continue",
            primaryEnabled: !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            primaryAction: { go(to: .experience) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $profile.displayName, prompt:
                    Text("Alex").foregroundColor(Apex.textFaint))
                    .font(.system(size: 30, weight: .bold))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                    .tint(Apex.accent)
                    .autocorrectionDisabled()
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .padding(.vertical, 6)
                Rectangle().fill(Apex.accent).frame(height: 2)
            }
        }
    }

    // MARK: - 02 Experience

    private var experienceView: some View {
        profileScaffold(
            stepNumber: 2,
            back: { go(to: .name) },
            eyebrow: "Step 02",
            title: "How long have you\nbeen lifting?",
            subtitle: "This sets how aggressively your program ramps.",
            primary: "Continue",
            primaryAction: { go(to: .goal) }
        ) {
            VStack(spacing: 10) {
                experienceChoice(.beginner, "Beginner", "New to structured training, or under a year")
                experienceChoice(.intermediate, "Intermediate", "A year or two of consistent lifting")
                experienceChoice(.advanced, "Advanced", "Several years; you know your numbers")
            }
        }
    }

    private func experienceChoice(_ value: TrainingAge, _ title: String, _ subtitle: String) -> some View {
        choiceCard(title: title, subtitle: subtitle, selected: profile.trainingAge == value) {
            profile.trainingAge = value
        }
    }

    // MARK: - 03 Goal

    private var goalView: some View {
        profileScaffold(
            stepNumber: 3,
            back: { go(to: .experience) },
            eyebrow: "Step 03",
            title: "What are you\ntraining for?",
            primary: "Continue",
            primaryAction: { go(to: .days) }
        ) {
            VStack(spacing: 10) {
                goalChoice(.hypertrophy, "Build muscle", "Hypertrophy — size and shape")
                goalChoice(.strength, "Get stronger", "Strength — heavier on the big lifts")
                goalChoice(.endurance, "Muscular endurance", "Higher reps, more work capacity")
                goalChoice(.general, "General fitness", "A balanced mix")
            }
        }
    }

    private func goalChoice(_ value: TrainingGoal, _ title: String, _ subtitle: String) -> some View {
        choiceCard(title: title, subtitle: subtitle, selected: profile.primaryGoal == value) {
            profile.primaryGoal = value
        }
    }

    // MARK: - 04 Days per week

    private var daysView: some View {
        profileScaffold(
            stepNumber: 4,
            back: { go(to: .goal) },
            eyebrow: "Step 04",
            title: "How many days\na week?",
            subtitle: "We'll shape your split around this.",
            primary: "Continue",
            primaryAction: { go(to: .body) }
        ) {
            // #369 / O-F11: include 2 — the engine supports 2-day weeks.
            HStack(spacing: 10) {
                ForEach([2, 3, 4, 5, 6], id: \.self) { n in
                    let on = profile.daysPerWeek == n
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            profile.daysPerWeek = n
                        }
                    } label: {
                        ApexNumeral(text: "\(n)", size: 28, weight: .black, color: on ? Apex.onAccent : Apex.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(
                                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                                    .fill(on ? Apex.accent : Apex.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                                    .stroke(on ? Color.clear : Apex.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 05 Body basics (bodyweight expected + optional height/age)

    private var bodyView: some View {
        profileScaffold(
            stepNumber: 5,
            back: { go(to: .days) },
            eyebrow: "Step 05",
            title: "What do you\nweigh?",
            subtitle: "Your bodyweight anchors the weights the coach prescribes in your first sessions — the more accurate, the better your starting loads.",
            primary: "Continue",
            primaryAction: { go(to: .sex) }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                // Bodyweight — the expected, primary field (emphasized card).
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ApexSectionLabel(text: "Bodyweight", color: Apex.accent)
                        Spacer()
                        Picker("Unit", selection: $profile.bodyweightInKg) {
                            Text("kg").tag(true)
                            Text("lb").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField(
                            profile.bodyweightInKg ? "80" : "176",
                            text: bodyweightBinding
                        )
                        .keyboardType(.decimalPad)
                        .font(Apex.numeral(46, weight: .black))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                        .tint(Apex.accent)
                        .fixedSize()
                        Text(profile.bodyweightInKg ? "kg" : "lb")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Apex.textFaint)
                        Spacer()
                    }
                    Rectangle().fill(Apex.accent).frame(height: 2)
                }
                .padding(16)
                .apexCard(emphasized: true)

                // Optional secondary fields — clearly marked.
                VStack(alignment: .leading, spacing: 10) {
                    ApexSectionLabel(text: "Optional · sharpens calibration", color: Apex.textFaint)
                    VStack(spacing: 0) {
                        optionalRow(icon: "ruler", label: "Height", unit: "cm", binding: heightBinding)
                        Rectangle().fill(Apex.hairline).frame(height: 1)
                        optionalRow(icon: "person.fill", label: "Age", unit: "yrs", binding: ageBinding, keyboard: .numberPad)
                    }
                    .padding(.horizontal, 16)
                    .apexCard()
                }
            }
        }
    }

    private func optionalRow(icon: String, label: String, unit: String, binding: Binding<String>, keyboard: UIKeyboardType = .decimalPad) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Apex.textDim)
                .frame(width: 24)
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Apex.text)
            Text("Optional")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Apex.textFaint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().stroke(Apex.hairline, lineWidth: 1))
            Spacer()
            TextField("", text: binding, prompt: Text("—").foregroundColor(Apex.textFaint))
                .keyboardType(keyboard)
                .multilineTextAlignment(.trailing)
                .font(Apex.numeral(22, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .tint(Apex.accent)
                .frame(width: 70)
            Text(unit)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Apex.textFaint)
        }
        .padding(.vertical, 14)
    }

    // MARK: - 06 Sex

    private var sexView: some View {
        profileScaffold(
            stepNumber: 6,
            back: { go(to: .body) },
            eyebrow: "Step 06",
            title: "Sex",
            subtitle: "Used only to anchor your first-session weights more accurately.",
            primary: "Continue",
            primaryAction: { go(to: .injuries) },
            secondary: (text: "Prefer not to say", action: {
                profile.sex = nil
                go(to: .injuries)
            })
        ) {
            VStack(spacing: 10) {
                choiceCard(title: "Male", selected: profile.sex == "male") { profile.sex = "male" }
                choiceCard(title: "Female", selected: profile.sex == "female") { profile.sex = "female" }
            }
        }
    }

    // MARK: - 07 Injuries (optional)

    private struct InjuryArea { let name, icon: String }
    private let injuryAreas: [InjuryArea] = [
        .init(name: "Shoulders", icon: "figure.arms.open"),
        .init(name: "Lower back", icon: "figure.walk"),
        .init(name: "Knees", icon: "figure.run"),
        .init(name: "Elbows", icon: "figure.boxing"),
        .init(name: "Wrists", icon: "hand.raised"),
        .init(name: "Hips", icon: "figure.flexibility"),
        .init(name: "Neck", icon: "figure.mind.and.body"),
        .init(name: "Ankles", icon: "shoeprints.fill"),
    ]

    private var injuriesView: some View {
        let rows = stride(from: 0, to: injuryAreas.count, by: 2).map {
            Array(injuryAreas[$0..<min($0 + 2, injuryAreas.count)])
        }
        return profileScaffold(
            stepNumber: 7,
            back: { go(to: .sex) },
            eyebrow: "Step 07 · Optional",
            title: "Anything to\nwork around?",
            subtitle: "Tap any areas that flare up. The coach will avoid programming straight into them — you can change this anytime.",
            primary: "Continue",
            primaryAction: { go(to: .equipment) },
            secondary: (text: "Nothing right now", action: {
                profile.injuryAreas = []
                go(to: .equipment)
            })
        ) {
            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 10) {
                        ForEach(pair, id: \.name) { area in injuryBox(area) }
                        if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                }
            }
        }
    }

    private func injuryBox(_ area: InjuryArea) -> some View {
        let sel = profile.injuryAreas.contains(area.name)
        return Button {
            if sel { profile.injuryAreas.remove(area.name) }
            else { profile.injuryAreas.insert(area.name) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: area.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(sel ? Apex.onAccent : Apex.accent)
                    .frame(width: 20)
                Text(area.name)
                    .font(.system(size: 16, weight: .bold))
                    .fontWidth(.condensed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(sel ? Apex.onAccent : Apex.text)
                Spacer(minLength: 0)
                if sel {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Apex.onAccent)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .fill(sel ? Apex.accent : Apex.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                    .stroke(sel ? Color.clear : Apex.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 08 Equipment (presets → review)

    /// Preset → equipment-type seed maps, built from the real EquipmentType cases.
    private struct EquipPreset { let name, desc: String; let types: [EquipmentType] }
    private let equipPresets: [EquipPreset] = [
        .init(name: "Full commercial gym",
              desc: "Racks, machines, cables, the lot",
              types: [.barbell, .dumbbellSet, .ezCurlBar, .adjustableBench, .inclineBench,
                      .powerRack, .smithMachine, .cableMachineDual, .cableCrossover,
                      .latPulldown, .seatedRow, .legPress, .hackSquat, .legExtension,
                      .legCurl, .chestPressMachine, .shoulderPressMachine, .pecDeck,
                      .pullUpBar, .dipStation]),
        .init(name: "Standard gym",
              desc: "Barbell, dumbbells, key machines",
              types: [.barbell, .dumbbellSet, .adjustableBench, .powerRack, .cableMachine,
                      .latPulldown, .seatedRow, .legPress, .legExtension, .legCurl,
                      .pullUpBar]),
        .init(name: "Garage barbell gym",
              desc: "Rack, barbell, bench, dumbbells",
              types: [.barbell, .powerRack, .adjustableBench, .dumbbellSet, .pullUpBar,
                      .resistanceBands]),
        .init(name: "Home — dumbbells + bench",
              desc: "Adjustable dumbbells and a bench",
              types: [.dumbbellSet, .adjustableBench, .resistanceBands]),
        .init(name: "Bodyweight only",
              desc: "Bar, dips, bands",
              types: [.pullUpBar, .dipStation, .resistanceBands]),
    ]

    private var equipmentView: some View {
        if showingEquipmentReview {
            return AnyView(equipmentReviewView)
        } else {
            return AnyView(equipmentPresetView)
        }
    }

    private var equipmentPresetView: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Button { go(to: .injuries) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Apex.textDim)
                    }
                    .buttonStyle(.plain)
                    rail(8)
                }
                .padding(.top, 8)
                .padding(.bottom, 30)

                titleBlock(eyebrow: "Step 08", title: "What's your\nsetup?",
                           subtitle: "Pick the closest match — you'll fine-tune the list next.")
                    .padding(.bottom, 26)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(equipPresets.enumerated()), id: \.offset) { _, preset in
                            Button { seedPreset(preset) } label: {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(preset.name)
                                            .font(.system(size: 17, weight: .bold))
                                            .fontWidth(.condensed)
                                            .foregroundStyle(Apex.text)
                                        Text(preset.desc)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(Apex.textFaint)
                                    }
                                    Spacer(minLength: 8)
                                    Text("\(preset.types.count) items")
                                        .font(.system(size: 12, weight: .semibold))
                                        .fontWidth(.condensed)
                                        .foregroundStyle(Apex.textFaint)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .apexCard()
                            }
                            .buttonStyle(.plain)
                        }

                        // Start from scratch — empty review list.
                        Button { seedFromScratch() } label: {
                            HStack {
                                Text("Start from scratch")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Apex.textDim)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Apex.textFaint)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Color.clear.frame(height: 12)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Apex.pad)
            .padding(.top, 8)
        }
    }

    private var equipmentReviewView: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            showingEquipmentReview = false
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Apex.textDim)
                    }
                    .buttonStyle(.plain)
                    rail(8)
                }
                .padding(.top, 8)
                .padding(.bottom, 20)

                if !presetLabel.isEmpty {
                    ApexSectionLabel(text: "From: \(presetLabel)", color: Apex.accent)
                }
                Text("Your equipment")
                    .font(.system(size: 30, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(Apex.text)
                    .padding(.top, 6)
                    .padding(.bottom, 14)

                // Add / search lives at the TOP — find or add anything first.
                Button { showingBulkPicker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Apex.textFaint)
                        Text("Search or add equipment…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Apex.textFaint)
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Apex.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                    .apexCard()
                }
                .buttonStyle(.plain)
                .padding(.bottom, 9)

                Button { showingBulkPicker = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Apex.textDim)
                            .frame(width: 20)
                        Text("Add a machine we don't list")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Apex.textDim)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Apex.textFaint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .overlay(
                        RoundedRectangle(cornerRadius: Apex.corner, style: .continuous)
                            .stroke(Apex.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)

                ApexSectionLabel(text: "In your gym · \(reviewItems.count)", color: Apex.textFaint)
                    .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    if reviewItems.isEmpty {
                        Text("No equipment yet — add what you have above.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Apex.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(reviewItems.enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 12) {
                                    Circle().fill(Apex.accent.opacity(0.8)).frame(width: 6, height: 6)
                                    Text(item.equipmentType.displayName)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(Apex.text)
                                    Spacer()
                                    Button {
                                        reviewItems.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Apex.textFaint)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 13)
                                if i < reviewItems.count - 1 {
                                    Rectangle().fill(Apex.hairline.opacity(0.6)).frame(height: 1)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .apexCard()
                    }
                    Color.clear.frame(height: 110)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Apex.pad)
            .padding(.top, 8)

            bottomBar(
                primary: "Save my gym · \(reviewItems.count) items",
                icon: "checkmark",
                action: { confirmEquipment() }
            )
        }
    }

    // MARK: - 09 Notifications (moved late)

    private var notificationsView: some View {
        profileScaffold(
            stepNumber: 9,
            back: {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    showingEquipmentReview = true
                }
                go(to: .equipment)
            },
            eyebrow: "Step 09",
            title: "Stay on track.",
            primary: "Allow notifications",
            primaryAction: {
                Task {
                    await requestNotificationPermission()
                    go(to: .generating)
                }
            },
            secondary: (text: "Not now", action: { go(to: .generating) })
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Apex.accent)
                    .padding(.bottom, 4)
                notifBenefit("Rest-timer alerts so you never lose track between sets.")
                notifBenefit("A nudge when your next session is ready.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .apexCard()
        }
    }

    private func notifBenefit(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Apex.accent)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Apex.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Generating

    private var generatingView: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                if isGenerating {
                    ApexRing(progress: 0.35, lineWidth: 4)
                        .frame(width: 92, height: 92)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Apex.accent)
                } else if generationError != nil {
                    Circle().stroke(Apex.hairline, lineWidth: 4).frame(width: 92, height: 92)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Apex.amber)
                } else {
                    Circle().stroke(Apex.hairline, lineWidth: 4).frame(width: 92, height: 92)
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(Apex.accent)
                }
            }

            Text(generationError != nil ? "GENERATION\nFAILED" : "BUILDING YOUR\nPROGRAM")
                .multilineTextAlignment(.center)
                .font(.system(size: 30, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(Apex.text)
                .padding(.top, 28)

            if isGenerating {
                Text("The coach is designing your 12-week periodized plan. This can take up to a couple of minutes.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Apex.textDim)
                    .padding(.top, 12)
                    .padding(.horizontal, 30)
            } else if let err = generationError {
                Text(err)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Apex.amber.opacity(0.9))
                    .padding(.top, 12)
                    .padding(.horizontal, 30)
            }

            Spacer()

            if generationError != nil {
                VStack(spacing: 14) {
                    Button { Task { await runProgramGeneration() } } label: {
                        ApexButton(title: "Try again", icon: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    Button { go(to: .ready) } label: {
                        Text("Continue without a program")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Apex.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Apex.pad)
                .padding(.bottom, 26)
            }
        }
        .padding(.horizontal, Apex.pad)
        .task {
            if !isGenerating && generationError == nil {
                await runProgramGeneration()
            }
        }
    }

    // MARK: - Ready reveal (+ adaptive loop)

    private let adaptiveLoop: [(String, String, String)] = [
        ("01", "YOU DO THE SET", "Log the weight and reps you hit."),
        ("02", "IT READS YOUR STRENGTH", "Turns that into where you really are."),
        ("03", "IT UPDATES ITS MODEL", "Adjusts how it sees you on that lift."),
        ("04", "IT PLANS YOUR NEXT SET", "Prescribes the next target precisely."),
    ]

    private var readyView: some View {
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let welcomeName = name.isEmpty ? "ATHLETE" : name.uppercased()
        let cached = Mesocycle.loadFromUserDefaults()
        let weeks = cached?.totalWeeks
        return ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Apex.accent)
                        .padding(.top, 50)
                    ApexSectionLabel(text: "Your program is ready", color: Apex.accent)
                        .padding(.top, 18)
                    Text("WELCOME, \(welcomeName).")
                        .font(.system(size: 38, weight: .black))
                        .fontWidth(.condensed)
                        .foregroundStyle(Apex.text)
                        .padding(.top, 6)

                    // Program shape — real data where we have it.
                    HStack(spacing: 10) {
                        statTile(value: weeks.map(String.init) ?? "—", label: "Weeks")
                        statTile(value: "\(profile.daysPerWeek)", label: "Days/wk")
                        statTextTile(value: goalShort(profile.primaryGoal), label: "Focus")
                    }
                    .padding(.top, 22)

                    ApexSectionLabel(text: "The loop it runs on every set", color: Apex.textFaint)
                        .padding(.top, 30)
                        .padding(.bottom, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(adaptiveLoop.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .top, spacing: 14) {
                                ApexNumeral(text: s.0, size: 15, weight: .black, color: Apex.onAccent)
                                    .frame(width: 30, height: 30)
                                    .background(RoundedRectangle(cornerRadius: Apex.corner).fill(Apex.accent))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.1)
                                        .font(.system(size: 15, weight: .bold))
                                        .fontWidth(.condensed)
                                        .foregroundStyle(Apex.text)
                                    Text(s.2)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Apex.textFaint)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            if i < adaptiveLoop.count - 1 {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(Apex.accent.opacity(0.7))
                                    .frame(width: 30, alignment: .center)
                            }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .black))
                            Text("repeats every set, every session")
                                .font(.system(size: 12.5, weight: .semibold))
                                .fontWidth(.condensed)
                        }
                        .foregroundStyle(Apex.accent)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(16)
                    .apexCard()
                    .padding(.top, 8)

                    if generationError != nil {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Apex.amber)
                            Text("Program generation didn't finish — your answers are saved. Generate it from the Program tab.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Apex.amber.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .apexCard()
                        .padding(.top, 12)
                    }

                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, Apex.pad)
            }

            bottomBar(primary: "Start training", action: { completeOnboarding() })
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            ApexNumeral(text: value, size: 34, weight: .black, color: Apex.text)
            ApexSectionLabel(text: label, color: Apex.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .apexCard()
    }

    private func statTextTile(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .black))
                .fontWidth(.condensed)
                .multilineTextAlignment(.center)
                .foregroundStyle(Apex.text)
            ApexSectionLabel(text: label, color: Apex.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .apexCard()
    }

    /// Short, uppercase focus label for the program-shape tile.
    private func goalShort(_ goal: TrainingGoal) -> String {
        switch goal {
        case .hypertrophy: return "HYPER-\nTROPHY"
        case .strength:    return "STRENGTH"
        case .endurance:   return "ENDUR-\nANCE"
        case .general:     return "GENERAL"
        }
    }

    // MARK: - Bodyweight / biometric input bindings

    private var bodyweightBinding: Binding<String> {
        Binding(
            get: {
                guard let kg = profile.bodyweightKg else { return "" }
                let display = profile.bodyweightInKg ? kg : kg * 2.20462
                return display.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", display)
                    : String(format: "%.1f", display)
            },
            set: { text in
                if text.isEmpty {
                    profile.bodyweightKg = nil
                } else if let v = Double(text.replacingOccurrences(of: ",", with: ".")) {
                    profile.bodyweightKg = profile.bodyweightInKg ? v : v / 2.20462
                }
            }
        )
    }

    private var heightBinding: Binding<String> {
        Binding(
            get: {
                guard let cm = profile.heightCm else { return "" }
                return cm.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", cm)
                    : String(format: "%.1f", cm)
            },
            set: { text in
                if text.isEmpty { profile.heightCm = nil }
                else if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { profile.heightCm = v }
            }
        )
    }

    private var ageBinding: Binding<String> {
        Binding(
            get: { profile.age.map { String($0) } ?? "" },
            set: { text in
                if text.isEmpty { profile.age = nil }
                else if let v = Int(text) { profile.age = v }
            }
        )
    }

    // MARK: - Equipment actions

    /// Seed the review list from a preset and advance to the review screen.
    private func seedPreset(_ preset: EquipPreset) {
        presetLabel = preset.name
        reviewItems = preset.types.map { type in
            EquipmentItem(
                equipmentType: type,
                count: 1,
                detectedByVision: false,
                bodyweightOnly: type.isNaturallyBodyweightOnly ? true : nil
            )
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            showingEquipmentReview = true
        }
    }

    /// Start with an empty review list.
    private func seedFromScratch() {
        presetLabel = ""
        reviewItems = []
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            showingEquipmentReview = true
        }
    }

    /// Confirm the reviewed equipment into the `gymProfile` state (the same
    /// state the old gym-scan step produced) and advance to notifications.
    private func confirmEquipment() {
        if reviewItems.isEmpty {
            gymProfile = nil
        } else {
            gymProfile = GymProfile(
                scanSessionId: "onboarding_\(UUID().uuidString.prefix(8))",
                equipment: reviewItems
            )
            gymProfile?.saveToUserDefaults()
        }
        go(to: .notifications)
    }

    // MARK: - Actions

    private func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notifGranted = granted
        } catch {
            notifGranted = false
        }
    }

    private func runProgramGeneration() async {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil

        // Persist user record (and userId in Keychain) before generation.
        await persistUserIfNeeded()

        // Persist daysPerWeek before the gymProfile guard so it is always
        // written regardless of whether the user provided equipment.
        UserDefaults.standard.set(profile.daysPerWeek, forKey: UserProfileConstants.daysPerWeekKey)

        // Re-entry guard (#318 U4): if a program was already generated for this
        // user (e.g. the app was killed between generation and onboarding
        // completion), reuse the cached mesocycle instead of paying for a
        // second skeleton LLM call.
        if let cached = Mesocycle.loadFromUserDefaults(), cached.userId == deps.resolvedUserId {
            isGenerating = false
            go(to: .ready)
            return
        }

        guard let gymProf = gymProfile else {
            // No gym profile — can't generate a valid program. Advance directly to ready.
            isGenerating = false
            go(to: .ready)
            return
        }

        do {
            // #423 / #369: resolve the real auth uid BEFORE stamping the program's
            // owner. `resolvedOwnerUserId()` returns nil when auth never resolved or
            // resolved only to the placeholder — in that case we keep the local cache
            // but skip the server write (never stamp a row we can't own). When it
            // resolves we use the SAME uid for the mesocycle owner and the server
            // persist so they match.
            let owner = await deps.resolvedOwnerUserId()
            let userId = owner ?? deps.resolvedUserId
            print("[OnboardingView] runProgramGeneration — training_days_per_week: \(profile.daysPerWeek)")
            let skeleton = try await deps.macroPlanService.generateSkeleton(
                userId: userId,
                gymProfile: gymProf,
                experienceLevel: profile.trainingAge.rawValue,
                goals: [profile.primaryGoal.rawValue],
                bodyweightKg: profile.bodyweightKg,
                ageYears: profile.age,
                trainingAge: profile.trainingAge.rawValue,
                trainingDaysPerWeek: profile.daysPerWeek
            )
            let mesocycle = MacroPlanService.buildPendingMesocycle(from: skeleton, userId: userId)
            // Cache immediately so ProgramViewModel.loadProgram() finds it on the fast path.
            mesocycle.saveToUserDefaults()
            // #423: persist to the server `programs` table under the resolved owner.
            // Best-effort — failure leaves the local cache intact and does NOT block
            // onboarding (mirrors ProgramViewModel.persistProgram's local-first spirit).
            // Without this the program lived only in UserDefaults and every later
            // workout FK-failed on workout_sessions_program_id_fkey.
            await OnboardingProgramPersist.persistIfOwnerResolved(
                mesocycle,
                owner: owner,
                client: deps.supabaseClient
            )
            isGenerating = false
            go(to: .ready)
        } catch {
            isGenerating = false
            generationError = error.localizedDescription
        }
    }

    /// Writes the user record to Supabase and stores the userId in Keychain if not already done.
    /// Also persists biometric fields to UserDefaults so they are available to WorkoutSessionManager
    /// without a Supabase round-trip during active sessions (FB-003).
    private func persistUserIfNeeded() async {
        let keychain = deps.keychainService

        // Persist biometrics to UserDefaults for fast in-session access. These are
        // not identity-keyed, so they are written regardless of session state.
        UserDefaults.standard.set(profile.bodyweightKg, forKey: UserProfileConstants.bodyweightKgKey)
        UserDefaults.standard.set(profile.heightCm, forKey: UserProfileConstants.heightCmKey)
        UserDefaults.standard.set(profile.age, forKey: UserProfileConstants.ageKey)
        UserDefaults.standard.set(profile.trainingAge.rawValue, forKey: UserProfileConstants.trainingAgeKey)
        UserDefaults.standard.set(profile.primaryGoal.rawValue, forKey: UserProfileConstants.primaryGoalKey)
        // #527: sex is persisted to UserDefaults only — the public.users table has
        // no sex column (Settings writes sex the same way). When the user chose
        // "Prefer not to say", profile.sex is nil and we clear any prior value.
        UserDefaults.standard.set(profile.sex, forKey: UserProfileConstants.sexKey)

        // #527 S2: the user's injury / "work-around" selection lives in
        // profile.injuryAreas. Slice 2 owns persisting it as a user-confirmed
        // limitation (the limitation write-path is out of scope here) — do NOT
        // write it yet; it would land in the wrong shape without that path.

        // #369 slice 3: the `users` row's id MUST be the anonymous-auth
        // `auth.uid()` so slice 5's RLS policy (`id = auth.uid()`) will match.
        // The session is established at launch (slice 1); onboarding runs after,
        // so await the slice-1 readiness to make sure the uid has resolved before
        // we read it. If it still hasn't (sign-in failed/timed out), skip the
        // insert and the `.userId` mirror — do NOT write a placeholder-keyed row
        // that slice 5's RLS would orphan; the next onboarding run retries.
        _ = await deps.supabaseAuth.awaitFirstResolution()
        guard let userId = UserIdentityResolver.onboardingUserId(
            keychain: keychain,
            placeholder: AppDependencies.placeholderUserId
        ) else { return }
        // Mirror the auth uid into `.userId` (first-run signal + secondary read).
        try? keychain.store(userId.uuidString, for: .userId)

        // Best-effort upsert into users table — ON CONFLICT (id) DO UPDATE so the
        // row the handle_new_user trigger pre-provisioned (bare id) is overwritten
        // with the full profile. Failure is non-fatal for onboarding.
        let nameStr = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let userRow = UserInsertRow(
            id: userId,
            displayName: nameStr.isEmpty ? nil : nameStr,
            bodyweightKg: profile.bodyweightKg,
            heightCm: profile.heightCm,
            age: profile.age,
            trainingAge: profile.trainingAge.rawValue
        )
        try? await deps.supabaseClient.upsert(userRow, table: "users")

        // #147: hydrate trainee_models.model_json.goal via the
        // update-trainee-goal Edge Function. Best-effort — failure leaves
        // the iOS side reading GoalState.placeholder (cold-start fallback
        // until the next onboarding retry or DeveloperSettingsView reset).
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let goalPayload = TraineeGoalUpsertPayload(
            userId: userId,
            goal: GoalUpsertBody(
                statement: profile.primaryGoal.rawValue,
                focusAreas: [],
                updatedAt: isoFormatter.string(from: Date())
            ),
            acknowledgeTriggeringSessionCount: nil,
            stretchEdits: nil,
            acknowledgeCalibrationReview: nil
        )
        if let encoded = try? JSONEncoder().encode(goalPayload) {
            _ = try? await deps.supabaseClient.invokeFunction(
                "update-trainee-goal",
                body: encoded
            )
        }
    }

    private func completeOnboarding() {
        // #527: the camera gym-scan was removed; a user who provided no equipment
        // still has a usable onboarding. Mark "scan skipped" when no gym profile
        // was confirmed so SettingsView shows the persistent "complete your setup"
        // prompt (the same affordance the old scan-skip used).
        let noEquipment = gymProfile == nil
        UserDefaults.standard.set(noEquipment, forKey: OnboardingConstants.scanSkippedKey)
        // Mark onboarding as completed so subsequent launches skip this view.
        UserDefaults.standard.set(true, forKey: OnboardingConstants.onboardingCompletedKey)
        onCompleted?(gymProfile)
    }
}

// MARK: - Onboarding Program Persist (#423)

/// Resolve-before-stamp persist for the onboarding-generated program.
///
/// The onboarding path builds the skeleton + mesocycle and caches it in
/// UserDefaults, but historically never wrote it to the server `programs` table
/// (the server-persist lived only in `ProgramViewModel`). A fresh user therefore
/// had a cached program but ZERO server programs, so every workout FK-failed on
/// `workout_sessions_program_id_fkey` and `set_logs` RLS-failed (#423).
///
/// This helper writes the program to the server **only under a resolved real
/// owner uid** (the #369 owner-stamping rule). A nil owner (auth unresolved /
/// offline) or the placeholder uid is never persisted — the local cache is the
/// fallback and the next onboarding run / `loadProgram` retries. Failure is
/// best-effort: it never throws into the onboarding flow.
enum OnboardingProgramPersist {
    /// - Returns: `true` iff the server write succeeded under a real resolved owner.
    @discardableResult
    static func persistIfOwnerResolved(
        _ mesocycle: Mesocycle,
        owner: UUID?,
        client: SupabaseClient
    ) async -> Bool {
        // resolve-before-stamp: never persist a row we can't own.
        guard let owner, owner != AppDependencies.placeholderUserId else { return false }
        do {
            try await client.deactivateAndInsertProgram(mesocycle, userId: owner)
            return true
        } catch {
            // Best-effort — local cache is preserved; do NOT crash onboarding.
            return false
        }
    }
}

// MARK: - Onboarding Constants

enum OnboardingConstants {
    static let onboardingCompletedKey = "com.projectapex.onboardingCompleted"
    static let scanSkippedKey         = "com.projectapex.gymScanSkipped"
}

// MARK: - UserProfile UserDefaults Keys (FB-003)

/// Shared keys for storing user biometrics in UserDefaults.
/// Used by OnboardingView (write) and AppDependencies/WorkoutSessionManager (read).
enum UserProfileConstants {
    static let bodyweightKgKey  = "com.projectapex.user.bodyweightKg"
    static let heightCmKey      = "com.projectapex.user.heightCm"
    static let ageKey           = "com.projectapex.user.age"
    /// Biological sex used by the AI coach to calibrate first-session pressing
    /// loads. Stored lowercase ("male"/"female"); absent = unset (#494 PR4).
    static let sexKey           = "com.projectapex.user.sex"
    static let trainingAgeKey   = "com.projectapex.user.trainingAge"
    /// Primary training goal selected during onboarding (TrainingGoal.rawValue).
    /// Read by GenerationUserProfile.assemble as the fallback goal source when
    /// the trainee-model digest goal is not hydrated (#318 U4).
    static let primaryGoalKey   = "com.projectapex.user.primaryGoal"
    /// Number of training days per week selected during onboarding. Default 4 if absent.
    static let daysPerWeekKey   = "com.projectapex.user.daysPerWeek"
    /// Incremented after each completed workout session. 0 = no sessions ever completed.
    /// Used to show the first-session calibration banner (FB-005).
    static let sessionCountKey  = "com.projectapex.user.sessionCount"
}

// MARK: - UserInsertRow (local Codable for users table)

/// Codable row for inserting/updating public.users with all profile fields.
private struct UserInsertRow: Codable, Sendable {
    let id: UUID
    let displayName: String?
    let bodyweightKg: Double?
    let heightCm: Double?
    let age: Int?
    let trainingAge: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName  = "display_name"
        case bodyweightKg = "bodyweight_kg"
        case heightCm     = "height_cm"
        case age
        case trainingAge  = "training_age"
    }

    /// Omit nil fields rather than encoding them as JSON `null`. With the upsert
    /// (`resolution=merge-duplicates`) a `null` would overwrite a previously-set
    /// column on a re-onboard; omitting absent fields makes the merge additive.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(bodyweightKg, forKey: .bodyweightKg)
        try c.encodeIfPresent(heightCm, forKey: .heightCm)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(trainingAge, forKey: .trainingAge)
    }
}

// MARK: - TraineeGoalUpsertPayload (#147: onboarding goal write)

/// Request body for the `update-trainee-goal` Edge Function. Mirrors the
/// validator contract in `supabase/functions/update-trainee-goal/index.ts`:
/// top-level `user_id` (UUID string) and `goal` object carrying the
/// GoalState shape (statement + focusAreas + ISO-8601 updatedAt).
///
/// `internal` (not `private`) so the EF-contract parity test can encode it
/// directly and assert the wire shape the validator accepts (#154).
struct TraineeGoalUpsertPayload: Codable, Sendable {
    let userId: UUID
    let goal: GoalUpsertBody
    /// P5-D06 Slice B (#258): OPTIONAL top-level field. When non-nil, the EF
    /// idempotently appends this triggering-session count to
    /// `model_json.acknowledgedTriggeringSessionCounts`. Onboarding always
    /// passes `nil` — the synthesized `encodeIfPresent` then OMITS the key,
    /// keeping the onboarding wire shape exactly `{user_id, goal}`.
    let acknowledgeTriggeringSessionCount: Int?
    /// #269 S4: OPTIONAL. Athlete-raised stretch targets from the
    /// calibration-review screen. When non-nil the EF applies an upward-only
    /// clamp on `model_json.projections.patternProjections`. Synthesized
    /// `encodeIfPresent` OMITS the key when nil, so other call sites keep their
    /// exact wire shape.
    let stretchEdits: [StretchEditBody]?
    /// #269 S4: OPTIONAL. When true, the EF durably sets
    /// `model_json.calibrationReviewAcknowledged = true` so the pre-workout
    /// calibration banner does not reappear after a session sync. Omitted from
    /// the wire when nil.
    let acknowledgeCalibrationReview: Bool?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case goal
        case acknowledgeTriggeringSessionCount = "acknowledge_triggering_session_count"
        case stretchEdits = "stretch_edits"
        case acknowledgeCalibrationReview = "acknowledge_calibration_review"
    }
}

/// #269 S4: a single athlete-raised stretch target. Mirrors the EF's
/// `StretchEdit` shape (`pattern` rawValue + `stretch` kg). The default
/// member-name CodingKeys match the validator's expected camelCase-free
/// `{pattern, stretch}` wire shape.
struct StretchEditBody: Codable, Sendable {
    let pattern: String
    let stretch: Double
}

/// `internal` (not `private`) so the EF-contract parity test can assert the
/// camelCase wire shape (`statement`/`focusAreas`/`updatedAt`) the validator
/// requires — adding snake_case CodingKeys here would BREAK the EF (#154).
struct GoalUpsertBody: Codable, Sendable {
    let statement: String
    let focusAreas: [String]
    let updatedAt: String
}

// MARK: - Preview

#Preview {
    OnboardingView(onCompleted: { _ in })
        .environment(AppDependencies())
}
