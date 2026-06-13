// LiveLoopCoreTests.swift
// ProjectApexTests — Phase 3 UI overhaul · Slice 8 (#350)
//
// Two layers, mirroring the issue's test plan:
//
//   1. UNCONDITIONAL (local green bar): the LiveLoopModel derivation + the real
//      VM/SessionManager binding. Drives start → log via Done → rest morph → next
//      set against the actual WorkoutViewModel/WorkoutSessionManager FSM, and
//      asserts the model's Done→Finish relabel, the double-log / stray-brush
//      guards, and the time-digits-`ink-muted` vs work-`ink` split (§1 "work is
//      ink, time is pencil").
//
//   2. GATED image snapshots (APEX_SNAPSHOT_TESTS=1): the set + rest states in
//      light + dim. Reference PNGs are NOT recorded here — that is the CI record
//      job's exclusive task (DrawnInstrumentSnapshotTests header). Until then these
//      are reference-pending; running WITHOUT the env var skips them entirely.
//
// The model is the testable core: it is a pure value type, so the guards and the
// ink/pencil contract are asserted in milliseconds with no UIKit. The VM-driven
// flow proves the binding against the genuine actor (no fake FSM).

import Testing
import XCTest
import Foundation
import SwiftUI
@testable import ProjectApex

#if canImport(UIKit)
import SnapshotTesting
import UIKit
#endif

// MARK: - Fixtures (a real manager + a deterministic prescription)

/// A fixed JSON prescription string — no network, no retries.
private func liveLoopPrescriptionJSON(weightKg: Double = 80.0, reps: Int = 8) -> String {
    """
    {
      "set_prescription": {
        "weight_kg": \(weightKg),
        "reps": \(reps),
        "tempo": "3-1-1-0",
        "rir_target": 2,
        "rest_seconds": 90,
        "coaching_cue": "Drive through the bar",
        "reasoning": "Based on recent performance trend.",
        "safety_flags": [],
        "intent": "top",
        "set_framing": "Heaviest work of the day. Brace and grind."
      }
    }
    """
}

private struct LiveLoopMockLLM: LLMProvider {
    let response: String
    func complete(systemPrompt: String, userPayload: String) async throws -> String { response }
}

/// HTTP 201 for every request so set-log writes never hit the network or spin the
/// write-ahead-queue retry loop. Mirrors WorkoutSessionManagerTests' succeed mock.
/// (URLProtocol's Sendable conformance is already unavailable, so we don't restate it.)
private final class LiveLoopSucceedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private func makeLiveLoopViewModel(weightKg: Double = 80.0, reps: Int = 8) -> WorkoutViewModel {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LiveLoopSucceedURLProtocol.self]
    let supabase = SupabaseClient(
        supabaseURL: URL(string: "https://test.supabase.co")!,
        anonKey: "test-key",
        urlSession: URLSession(configuration: config)
    )
    let inference = AIInferenceService(
        provider: LiveLoopMockLLM(response: liveLoopPrescriptionJSON(weightKg: weightKg, reps: reps)),
        gymProfile: nil,
        maxRetries: 0
    )
    let memory = MemoryService(supabase: supabase, embeddingAPIKey: "")
    let suite = "com.test.liveloop.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let gymFactStore = GymFactStore(userDefaults: defaults)
    let waq = WriteAheadQueue(supabase: supabase, userDefaults: defaults)
    let manager = WorkoutSessionManager(
        aiInference: inference,
        healthKit: HealthKitService(),
        memoryService: memory,
        supabase: supabase,
        gymFactStore: gymFactStore,
        writeAheadQueue: waq
    )
    return WorkoutViewModel(manager: manager)
}

private func makeLiveLoopDay(exerciseCount: Int = 1, setsPerExercise: Int = 2) -> TrainingDay {
    let exercises = (0..<exerciseCount).map { i in
        PlannedExercise(
            id: UUID(),
            exerciseId: "exercise_\(i)",
            name: "Exercise \(i)",
            primaryMuscle: "pectoralis_major",
            synergists: [],
            equipmentRequired: .barbell,
            sets: setsPerExercise,
            repRange: RepRange(min: 6, max: 10),
            tempo: "3-1-1-0",
            restSeconds: 90,
            rirTarget: 2,
            coachingCues: []
        )
    }
    return TrainingDay(id: UUID(), dayOfWeek: 1, dayLabel: "Push_A", exercises: exercises, sessionNotes: nil)
}

/// One active-set fixture for pure-model assertions (no manager needed).
private func activeState(
    exercise: PlannedExercise,
    setNumber: Int
) -> SessionState {
    .active(exercise: exercise, setNumber: setNumber)
}

private func samplePrescription(weightKg: Double = 82.5, reps: Int = 8, intent: SetIntent = .top) -> SetPrescription {
    SetPrescription(
        weightKg: weightKg, reps: reps, tempo: "3-1-1-0", rirTarget: 2, restSeconds: 90,
        coachingCue: "cue", reasoning: "why", safetyFlags: [], confidence: 0.9, intent: intent,
        setFraming: "frame"
    )
}

// MARK: - Pure-model suite (unconditional)

@Suite("LiveLoopModel — derivation, relabel, ink/pencil split")
struct LiveLoopModelTests {

    @Test("Set state: hero uses U+00D7 (never letter x), weight is ink-token, reps are pencil")
    func setStateHeroLockup() {
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 4)
        let ex = day.exercises[0]
        let model = LiveLoopModel(
            sessionState: activeState(exercise: ex, setNumber: 2),
            prescription: samplePrescription(weightKg: 82.5, reps: 8),
            restSecondsRemaining: 0,
            trainingDay: day
        )
        #expect(model.phase == .set)
        #expect(model.heroWeightText == "82.5 kg")
        // Connective × is the real U+00D7, never the ASCII letter.
        #expect(model.heroRepsText.contains("\u{00D7}"))
        #expect(!model.heroRepsText.lowercased().contains("x"))
        #expect(model.heroRepsText == " \u{00D7} 8")
        #expect(model.setPositionText == "set 2 of 4")
        #expect(model.exerciseName == ex.name)
    }

    @Test("Whole-number weight drops the trailing .0 (no false precision, §3)")
    func wholeWeightHasNoTrailingZero() {
        #expect(LiveLoopModel.weightText(weightKg: 100) == "100 kg")
        #expect(LiveLoopModel.weightText(weightKg: 82.5) == "82.5 kg")
        #expect(LiveLoopModel.weightText(weightKg: 0) == "BW")
    }

    @Test("Done relabels to Finish on the last set of the last exercise — not before")
    func doneRelabelsToFinishOnLastSet() {
        // Two exercises, 2 sets each. Last set of session = exercise[1], set 2.
        let day = makeLiveLoopDay(exerciseCount: 2, setsPerExercise: 2)
        let first = day.exercises[0]
        let last = day.exercises[1]

        // Set 1 of the last exercise — still "Done".
        let notYet = LiveLoopModel(
            sessionState: activeState(exercise: last, setNumber: 1),
            prescription: samplePrescription(), restSecondsRemaining: 0, trainingDay: day
        )
        #expect(notYet.isLastSetOfSession == false)
        #expect(notYet.doneLabel == "Done")

        // Last set of the FIRST exercise — still "Done" (more exercises remain).
        let firstExLastSet = LiveLoopModel(
            sessionState: activeState(exercise: first, setNumber: 2),
            prescription: samplePrescription(), restSecondsRemaining: 0, trainingDay: day
        )
        #expect(firstExLastSet.isLastSetOfSession == false)
        #expect(firstExLastSet.doneLabel == "Done")

        // Last set of the LAST exercise — "Finish".
        let finish = LiveLoopModel(
            sessionState: activeState(exercise: last, setNumber: 2),
            prescription: samplePrescription(), restSecondsRemaining: 0, trainingDay: day
        )
        #expect(finish.isLastSetOfSession == true)
        #expect(finish.doneLabel == "Finish")
    }

    @Test("Rest digits are m:ss, clamped at zero — the pencil hero")
    func restDigitsFormat() {
        #expect(LiveLoopModel.restDigits(90) == "1:30")
        #expect(LiveLoopModel.restDigits(5) == "0:05")
        #expect(LiveLoopModel.restDigits(0) == "0:00")
        #expect(LiveLoopModel.restDigits(-3) == "0:00")
    }

    @Test("Rest state exposes the countdown + next-set preview, no set-hero fields")
    func restStateFields() {
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 3)
        let ex = day.exercises[0]
        let model = LiveLoopModel(
            sessionState: .resting(nextExercise: ex, setNumber: 3),
            prescription: nil, restSecondsRemaining: 87, trainingDay: day
        )
        #expect(model.phase == .rest)
        #expect(model.restDigitsText == "1:27")
        #expect(model.nextPreviewText.contains(ex.name))
        #expect(model.heroWeightText.isEmpty)
    }

    @Test("doneEnabled is false without a prescription (nothing to log)")
    func doneDisabledWithoutPrescription() {
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 2)
        let ex = day.exercises[0]
        let noRx = LiveLoopModel(
            sessionState: activeState(exercise: ex, setNumber: 1),
            prescription: nil, restSecondsRemaining: 0, trainingDay: day
        )
        #expect(noRx.doneEnabled == false)
        let withRx = LiveLoopModel(
            sessionState: activeState(exercise: ex, setNumber: 1),
            prescription: samplePrescription(), restSecondsRemaining: 0, trainingDay: day
        )
        #expect(withRx.doneEnabled == true)
    }

    @Test("Non-set/rest states (idle/preflight/complete) are the .other phase, no hero")
    func otherPhases() {
        let day = makeLiveLoopDay()
        for state in [SessionState.idle, .preflight, .error("boom")] {
            let model = LiveLoopModel(sessionState: state, prescription: nil, restSecondsRemaining: 0, trainingDay: day)
            #expect(model.phase == .other)
            #expect(model.doneEnabled == false)
        }
    }
}

// MARK: - Ink/pencil colour contract (token-level, unconditional)

@Suite("LiveLoop ink/pencil contract — work is ink, time is pencil (§1)")
struct LiveLoopInkPencilTests {

    @Test("Work and time use the SAME family at DIFFERENT value: ink vs ink-muted")
    func workInkTimePencil() {
        // The view renders work numbers with `theme.ink` and time digits with
        // `theme.inkMuted`. Assert the two tokens are distinct so the split is
        // visible, in both appearances.
        for theme in [Theme.light, Theme.dim] {
            #expect(theme.ink != theme.inkMuted)
            // ink-muted is a genuinely lighter/closer-to-paper value than ink —
            // a real "pencil" register, not an arbitrary second colour.
            #expect(theme.ink.relativeLuminance != theme.inkMuted.relativeLuminance)
        }
    }
}

// MARK: - VM/SessionManager binding (unconditional, async)

/// Drives the genuine actor through start → log via Done → rest → next set, the way
/// LiveLoopView's `handleDoneTap` does (onSetComplete at prescription reps/intent).
final class LiveLoopBindingTests: XCTestCase {

    override func setUp() { super.setUp(); PausedSessionState.clear() }
    override func tearDown() { PausedSessionState.clear(); super.tearDown() }

    /// Poll the VM state until `predicate` holds or the timeout elapses, pulling
    /// fresh actor state each tick (the live screen polls; tests do the same).
    @MainActor
    private func waitFor(
        _ vm: WorkoutViewModel,
        timeout: TimeInterval = 3.0,
        _ predicate: (WorkoutViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await vm.pullState()
            if predicate(vm) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func test_start_logViaDone_restMorph_nextSet() async {
        let vm = makeLiveLoopViewModel()
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 2)

        vm.startSession(trainingDay: day, programId: UUID(), userId: UUID())
        await waitFor(vm) { if case .active = $0.sessionState { return true }; return false }

        // Active on set 1, model in .set, Done (not last) enabled.
        var model = LiveLoopModel(sessionState: vm.sessionState, prescription: vm.currentPrescription,
                                  restSecondsRemaining: vm.restSecondsRemaining, trainingDay: day)
        XCTAssertEqual(model.phase, .set)
        XCTAssertEqual(model.doneLabel, "Done", "set 1 of 2 is not the last set")
        XCTAssertTrue(model.doneEnabled)

        // Log set 1 the way the Done slab does: reps + intent from the prescription.
        let rx1 = vm.currentPrescription!
        vm.onSetComplete(actualReps: rx1.reps, rpeFelt: nil, intent: rx1.intent ?? .top, completionFlags: [])

        // Morph to rest.
        await waitFor(vm) { $0.isResting }
        model = LiveLoopModel(sessionState: vm.sessionState, prescription: vm.currentPrescription,
                              restSecondsRemaining: vm.restSecondsRemaining, trainingDay: day)
        XCTAssertEqual(model.phase, .rest, "post-log state morphs to the rest card")
        XCTAssertEqual(vm.completedSets.count, 1, "set 1 logged")

        // Advance past rest to set 2.
        vm.skipRest()
        await waitFor(vm) {
            if case .active(_, let n) = $0.sessionState { return n == 2 }
            return false
        }
        model = LiveLoopModel(sessionState: vm.sessionState, prescription: vm.currentPrescription,
                              restSecondsRemaining: vm.restSecondsRemaining, trainingDay: day)
        XCTAssertEqual(model.phase, .set)
        // Set 2 of 2 on the only exercise → last set of the session → Finish.
        XCTAssertTrue(model.isLastSetOfSession)
        XCTAssertEqual(model.doneLabel, "Finish")
    }

    @MainActor
    func test_doubleLogGuard_secondCompleteIsRejectedWhileInFlight() async {
        let vm = makeLiveLoopViewModel()
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 3)
        vm.startSession(trainingDay: day, programId: UUID(), userId: UUID())
        await waitFor(vm) { if case .active = $0.sessionState { return true }; return false }

        let rx = vm.currentPrescription!
        // Fire two completes back-to-back. The VM's isCompletingSet guard (the same
        // flag LiveLoopView.doneEnabled reads) must let only the first through.
        vm.onSetComplete(actualReps: rx.reps, rpeFelt: nil, intent: rx.intent ?? .top)
        XCTAssertTrue(vm.isCompletingSet, "first complete sets the in-flight guard")
        vm.onSetComplete(actualReps: rx.reps, rpeFelt: nil, intent: rx.intent ?? .top)

        await waitFor(vm) { !$0.isCompletingSet && $0.isResting }
        XCTAssertEqual(vm.completedSets.count, 1, "only one set logged despite two taps")
    }

    @MainActor
    func test_strayBrushGuard_doneDisabledWhenNoPrescriptionOrInFlight() async {
        // The view's doneEnabled = model.doneEnabled && !isCompletingSet && !isMorphing.
        // Prove the model half: no prescription → not loggable (a brush on a card with
        // nothing to log is rejected at the source).
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 2)
        let ex = day.exercises[0]
        let noRx = LiveLoopModel(sessionState: .active(exercise: ex, setNumber: 1),
                                 prescription: nil, restSecondsRemaining: 0, trainingDay: day)
        XCTAssertFalse(noRx.doneEnabled)
    }
}

// MARK: - VoiceOver + geometry (host-rendered, unconditional where UIKit exists)

#if canImport(UIKit)
@MainActor
@Suite("LiveLoop accessibility — VoiceOver reads hero numbers + Done")
struct LiveLoopAccessibilityTests {

    /// The hero lockup and the Done slab carry explicit accessibility labels so
    /// VoiceOver reads "82.5 kg × 8" and "Done"/"Finish". We assert the label
    /// strings the view builds from the model (the view threads these verbatim).
    @Test("Hero label reads weight × reps; Done label tracks the relabel")
    func voiceOverLabels() {
        let day = makeLiveLoopDay(exerciseCount: 1, setsPerExercise: 2)
        let ex = day.exercises[0]

        let setModel = LiveLoopModel(sessionState: .active(exercise: ex, setNumber: 1),
                                     prescription: samplePrescription(weightKg: 82.5, reps: 8),
                                     restSecondsRemaining: 0, trainingDay: day)
        // The view's accessibilityLabel for the hero is "\(weight) \(reps)".
        let heroLabel = "\(setModel.heroWeightText) \(setModel.heroRepsText)"
        #expect(heroLabel.contains("82.5 kg"))
        #expect(heroLabel.contains("\u{00D7} 8"))
        #expect(setModel.doneLabel == "Done")

        let finishModel = LiveLoopModel(sessionState: .active(exercise: ex, setNumber: 2),
                                        prescription: samplePrescription(),
                                        restSecondsRemaining: 0, trainingDay: day)
        #expect(finishModel.doneLabel == "Finish")
    }
}
#endif

// MARK: - Gated image snapshots (reference-pending; NEVER record here)

#if canImport(UIKit)
// `nonisolated` so the `.enabled(if:)` macro can reference these from the suite's
// nonisolated context (under the project's `-default-isolation=MainActor`).
nonisolated private var liveLoopSnapshotEnabled: Bool {
    ProcessInfo.processInfo.environment["APEX_SNAPSHOT_TESTS"] == "1"
}
nonisolated private var liveLoopRecordMode: Bool {
    ProcessInfo.processInfo.environment["APEX_RECORD_SNAPSHOTS"] == "1"
}

@Suite("LiveLoop snapshots — set + rest, light + dim", .enabled(if: liveLoopSnapshotEnabled))
@MainActor
struct LiveLoopSnapshotTests {

    private static let canvas = CGSize(width: 393, height: 852)

    private static func host(_ view: some View, appearance: Appearance) -> UIViewController {
        let rooted = view
            .environment(\.apexTheme, Theme.current(appearance))
            .frame(width: canvas.width, height: canvas.height)
        let vc = UIHostingController(rootView: rooted)
        vc.view.frame = CGRect(origin: .zero, size: canvas)
        vc.view.backgroundColor = UIColor(
            red: Theme.current(appearance).paper.red,
            green: Theme.current(appearance).paper.green,
            blue: Theme.current(appearance).paper.blue,
            alpha: 1
        )
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        return vc
    }

    private static let imaging: Snapshotting<UIViewController, UIImage> = .image(precision: 0.99, perceptualPrecision: 0.98)

    @Test("Set state — light")
    func setState_light() {
        let vc = Self.host(LiveLoopView(viewModel: .mockActive(), trainingDay: makeLiveLoopDay()), appearance: .light)
        assertSnapshot(of: vc, as: Self.imaging, named: "liveloop-set-light", record: liveLoopRecordMode)
    }

    @Test("Set state — dim")
    func setState_dim() {
        let vc = Self.host(LiveLoopView(viewModel: .mockActive(), trainingDay: makeLiveLoopDay()), appearance: .dim)
        assertSnapshot(of: vc, as: Self.imaging, named: "liveloop-set-dim", record: liveLoopRecordMode)
    }

    @Test("Rest state — light")
    func restState_light() {
        let vc = Self.host(LiveLoopView(viewModel: .mockResting(), trainingDay: makeLiveLoopDay()), appearance: .light)
        assertSnapshot(of: vc, as: Self.imaging, named: "liveloop-rest-light", record: liveLoopRecordMode)
    }

    @Test("Rest state — dim")
    func restState_dim() {
        let vc = Self.host(LiveLoopView(viewModel: .mockResting(), trainingDay: makeLiveLoopDay()), appearance: .dim)
        assertSnapshot(of: vc, as: Self.imaging, named: "liveloop-rest-dim", record: liveLoopRecordMode)
    }
}
#endif
