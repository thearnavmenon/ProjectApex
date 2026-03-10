// ScannerView.swift
// ProjectApex — GymScanner Feature
//
// The main SwiftUI view for the gym equipment scanning flow. Composed of:
//
//   ┌─────────────────────────────────────┐
//   │         CameraPreviewView            │  ← Full-screen live camera feed
//   │                                      │
//   │    [Scanning overlay + crosshair]    │  ← Animated scan indicator
//   │                                      │
//   │  ┌─── EquipmentChecklistOverlay ───┐ │  ← Bottom sheet: live checklist
//   │  │  ✅ Dumbbell Set                │ │
//   │  │  ✅ Barbell                     │ │
//   │  │  ⏳ Cable Machine...            │ │
//   │  └────────────────────────────────┘ │
//   └─────────────────────────────────────┘
//
// State transitions rendered by this view (driven by ScannerViewModel.state):
//   .idle              → "Start Scanning" button
//   .requestingPermission → spinner
//   .scanning          → live feed + checklist overlay + "Done" button
//   .confirming        → editable equipment list + "Confirm Profile" button
//   .completed         → success screen (triggers navigation pop in parent)
//   .permissionDenied  → settings deep-link prompt
//   .error             → inline error with retry option

import SwiftUI
import AVFoundation

// MARK: - ScannerView

struct ScannerView: View {

    // `@State` is the correct property wrapper for `@Observable` classes (iOS 17+).
    // The ViewModel is owned by this view — not injected from a parent.
    @State private var viewModel = ScannerViewModel()

    /// Callback invoked when a confirmed GymProfile is ready for the parent to persist.
    var onProfileConfirmed: ((GymProfile) -> Void)?

    // For the confirmation sheet presentation
    @State private var showingAddEquipmentSheet = false

    var body: some View {
        ZStack {
            // Background: always black so camera preview has a clean surround
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .idle:
                idleView

            case .requestingPermission:
                permissionSpinnerView

            case .scanning:
                scanningView

            case .confirming:
                confirmingView

            case .completed(let profile):
                completedView(profile: profile)

            case .permissionDenied:
                permissionDeniedView

            case .error(let error):
                errorView(error: error)
            }
        }
        .navigationTitle("Gym Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // ---------------------------------------------------------------------------
    // MARK: State Views
    // ---------------------------------------------------------------------------

    /// Initial state: instructional prompt + Start button.
    private var idleView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 80))
                .foregroundStyle(.white.opacity(0.8))

            VStack(spacing: 12) {
                Text("Scan Your Gym")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text("Pan your camera slowly around your gym.\nCapture all machines, free weights, cables, and benches.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button(action: { viewModel.startScan() }) {
                Label("Start Scanning", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    /// Shown briefly while awaiting the OS permission dialog.
    private var permissionSpinnerView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.5)
            Text("Requesting Camera Access…")
                .foregroundStyle(.white)
                .font(.subheadline)
        }
    }

    /// The core scanning experience: camera preview + overlay.
    private var scanningView: some View {
        ZStack(alignment: .bottom) {
            // Live camera feed fills the screen
            CameraPreviewView(previewLayer: viewModel.previewLayer)
                .ignoresSafeArea()

            // Scanning animation overlay
            ScanAnimationOverlay(pendingRequests: viewModel.pendingAPIRequests)

            VStack(spacing: 0) {
                // Top HUD: frame counter + pending indicator
                scanHUD
                    .padding(.top, 60) // Below the notch / Dynamic Island

                Spacer()

                // Bottom: live equipment checklist sheet
                EquipmentChecklistOverlay(
                    equipment: viewModel.detectedEquipment,
                    framesProcessed: viewModel.framesProcessed
                )

                // Done scanning button
                Button(action: { viewModel.stopScan() }) {
                    Text("Done Scanning")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .padding(.horizontal, 24)
                .padding(.bottom, 36)
            }
        }
    }

    /// HUD bar shown during scanning with frame count and in-flight request indicator.
    private var scanHUD: some View {
        HStack {
            // Frames processed counter
            Label("\(viewModel.framesProcessed) frames", systemImage: "photo.stack")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())

            Spacer()

            // In-flight API request indicator
            if viewModel.pendingAPIRequests > 0 {
                HStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.7)
                    Text("Analysing…")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
    }

    /// Confirmation screen: editable equipment list before profile is saved.
    private var confirmingView: some View {
        // @Bindable allows `$viewModel.detectedEquipment` bindings for the ForEach.
        // This requires `detectedEquipment` to have a public setter on the @Observable class.
        @Bindable var vm = viewModel
        return NavigationStack {
            List {
                Section {
                    ForEach($vm.detectedEquipment) { $item in
                        EquipmentRowView(item: $item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.removeEquipment(id: viewModel.detectedEquipment[index].id)
                        }
                    }
                } header: {
                    Text("\(viewModel.detectedEquipment.count) items detected")
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                Section {
                    Button(action: { showingAddEquipmentSheet = true }) {
                        Label("Add Equipment Manually", systemImage: "plus.circle")
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Confirm Equipment")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Re-scan") {
                        viewModel.reset()
                    }
                    .foregroundStyle(.red)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        viewModel.confirmProfile()
                        if case .completed(let profile) = viewModel.state {
                            onProfileConfirmed?(profile)
                        }
                    }) {
                        Text("Confirm")
                            .bold()
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddEquipmentSheet) {
            AddEquipmentSheet(onAdd: { item in
                viewModel.addEquipment(item)
                showingAddEquipmentSheet = false
            })
        }
        .colorScheme(.dark)
    }

    /// Success state shown after the GymProfile has been saved.
    private func completedView(profile: GymProfile) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .symbolEffect(.bounce)

            VStack(spacing: 8) {
                Text("Gym Profile Saved")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("\(profile.equipment.count) pieces of equipment catalogued.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Summary chips
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible()), count: 2),
                spacing: 8
            ) {
                ForEach(profile.equipment.prefix(6)) { item in
                    Text(item.equipmentType.displayName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    /// Shown when camera permission has been denied (FR-001-A graceful degradation).
    private var permissionDeniedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)

            VStack(spacing: 8) {
                Text("Camera Access Required")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Project Apex needs camera access to scan your gym equipment.\nYou can enable it in Settings.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)

            Button("Enter Equipment Manually") {
                // Manually populate an empty list and go straight to confirming
                viewModel.reset()
                // Bypass scanning, go direct to confirm with empty list
                // In a full implementation, this would push to a form-based entry flow
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Shown for non-permission errors (camera setup failure, etc.).
    private func errorView(error: ScannerError) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.yellow)

            VStack(spacing: 8) {
                Text("Scanner Error")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text(error.errorDescription ?? "An unknown error occurred.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
    }
}

// MARK: - CameraPreviewView

/// `UIViewRepresentable` wrapper that hosts the `AVCaptureVideoPreviewLayer`
/// in a SwiftUI hierarchy. Needed because `AVCaptureVideoPreviewLayer` is a
/// `CALayer` subclass and requires a `UIView` to host it.
struct CameraPreviewView: UIViewRepresentable {

    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.setPreviewLayer(previewLayer)
    }

    // Internal UIView subclass that manages the preview layer's frame.
    class PreviewUIView: UIView {
        private var currentPreviewLayer: AVCaptureVideoPreviewLayer?

        func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
            // Remove old layer if present
            currentPreviewLayer?.removeFromSuperlayer()
            currentPreviewLayer = layer
            self.layer.addSublayer(layer)
            layer.frame = bounds
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            currentPreviewLayer?.frame = bounds
        }
    }
}

// MARK: - ScanAnimationOverlay

/// Animating scan lines + corner brackets to give visual feedback that scanning is active.
struct ScanAnimationOverlay: View {

    let pendingRequests: Int

    @State private var scanLineOffset: CGFloat = -200
    @State private var opacity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Subtle grid tint
                Color.black.opacity(0.15)
                    .ignoresSafeArea()

                // Corner bracket decorations
                CornerBrackets()
                    .stroke(.white.opacity(0.8), lineWidth: 3)
                    .frame(width: geo.size.width * 0.7, height: geo.size.width * 0.7)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // Animated horizontal scan line
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .green.opacity(0.6), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .offset(y: scanLineOffset)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .opacity(pendingRequests > 0 ? opacity : 0.3)
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.5)
                .repeatForever(autoreverses: true)
            ) {
                scanLineOffset = 200
                opacity = 0.4
            }
        }
        .allowsHitTesting(false) // Pass touches through to camera controls
    }
}

/// A `Shape` that draws four L-shaped corner brackets (like a viewfinder).
struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length: CGFloat = 24
        let corners: [(CGPoint, (CGFloat, CGFloat), (CGFloat, CGFloat))] = [
            (rect.origin,
             (rect.minX + length, rect.minY), (rect.minX, rect.minY + length)),
            (CGPoint(x: rect.maxX, y: rect.minY),
             (rect.maxX - length, rect.minY), (rect.maxX, rect.minY + length)),
            (CGPoint(x: rect.minX, y: rect.maxY),
             (rect.minX + length, rect.maxY), (rect.minX, rect.maxY - length)),
            (CGPoint(x: rect.maxX, y: rect.maxY),
             (rect.maxX - length, rect.maxY), (rect.maxX, rect.maxY - length))
        ]
        for (origin, h, v) in corners {
            path.move(to: CGPoint(x: h.0, y: h.1))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: v.0, y: v.1))
        }
        return path
    }
}

// MARK: - EquipmentChecklistOverlay

/// Bottom sheet overlay shown during scanning. Displays the live-updating
/// checklist of detected equipment categories (PRD Section 3.1.1, Step 2).
struct EquipmentChecklistOverlay: View {

    let equipment: [EquipmentItem]
    let framesProcessed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Handle / drag indicator
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(0.4))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected Equipment")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(framesProcessed == 0
                         ? "Move your camera around the gym…"
                         : "\(framesProcessed) frames analysed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
                Spacer()

                if equipment.isEmpty {
                    // Pulsing dot when nothing found yet
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                } else {
                    Text("\(equipment.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(6)
                        .background(.green, in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Equipment list (scrollable, max ~3 visible items, then scrolls)
            if equipment.isEmpty {
                HStack {
                    Spacer()
                    Text("Pan your camera to start detecting equipment")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(equipment) { item in
                            EquipmentDetectionRow(item: item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // Animate new items appearing
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: equipment.count)
    }
}

/// A single row in the live checklist: checkmark icon + equipment name + weight summary.
struct EquipmentDetectionRow: View {

    let item: EquipmentItem

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))

            Text(item.equipmentType.displayName)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()

            // Show a compact weight summary from the details
            if let weightSummary = item.details.weightSummary {
                Text(weightSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("×\(item.count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .scaleEffect(appeared ? 1.0 : 0.9)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                appeared = true
            }
        }
    }
}

// MARK: - EquipmentRowView (Confirmation Screen)

/// An editable row for the confirmation list. Allows inline count editing.
struct EquipmentRowView: View {

    @Binding var item: EquipmentItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.equipmentType.displayName)
                    .font(.body)

                if let weightSummary = item.details.weightSummary {
                    Text(weightSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Inline stepper for count editing
            HStack(spacing: 0) {
                Button {
                    if item.count > 1 { item.count -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(item.count <= 1)

                Text("\(item.count)")
                    .font(.body.monospacedDigit())
                    .frame(width: 24)
                    .multilineTextAlignment(.center)

                Button {
                    item.count += 1
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
            }
            .foregroundStyle(.primary)
        }
    }
}

// MARK: - AddEquipmentSheet

/// Modal sheet for manually adding an equipment item (FR-001-F).
struct AddEquipmentSheet: View {

    var onAdd: (EquipmentItem) -> Void

    @State private var equipmentTypeName = ""
    @State private var count = 1
    @State private var detailsKind: DetailsKind = .bodyweightOnly
    @State private var minKg: Double = 0
    @State private var maxKg: Double = 100
    @State private var incrementKg: Double = 2.5

    @Environment(\.dismiss) private var dismiss

    enum DetailsKind: String, CaseIterable, Identifiable {
        case bodyweightOnly = "Bodyweight Only"
        case incrementBased = "Stack / Dumbbell"
        case plateBased     = "Plate Loaded"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    TextField("Type (e.g. dumbbell_set)", text: $equipmentTypeName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Stepper("Count: \(count)", value: $count, in: 1...20)
                }

                Section("Weight Details") {
                    Picker("Kind", selection: $detailsKind) {
                        ForEach(DetailsKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }

                    if detailsKind == .incrementBased {
                        HStack {
                            Text("Min kg")
                            Spacer()
                            TextField("0", value: $minKg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                        HStack {
                            Text("Max kg")
                            Spacer()
                            TextField("100", value: $maxKg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                        HStack {
                            Text("Increment kg")
                            Spacer()
                            TextField("2.5", value: $incrementKg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }

                    if detailsKind == .plateBased {
                        HStack {
                            Text("Bar weight kg")
                            Spacer()
                            TextField("20", value: $minKg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                }
            }
            .navigationTitle("Add Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = equipmentTypeName
                            .trimmingCharacters(in: .whitespaces)
                            .lowercased()
                            .replacingOccurrences(of: " ", with: "_")
                        guard !trimmed.isEmpty else { return }

                        // Map the raw string to an EquipmentType (known or unknown)
                        let equipType = EquipmentType(rawString: trimmed)

                        let details: EquipmentDetails
                        switch detailsKind {
                        case .bodyweightOnly:
                            details = .bodyweightOnly
                        case .incrementBased:
                            details = .incrementBased(minKg: minKg, maxKg: maxKg, incrementKg: incrementKg)
                        case .plateBased:
                            // Default plate set for a manually-added plate-based item
                            details = .plateBased(
                                barWeightKg: minKg,
                                availablePlatesKg: [1.25, 2.5, 5.0, 10.0, 20.0]
                            )
                        }

                        let item = EquipmentItem(
                            equipmentType: equipType,
                            count: count,
                            details: details,
                            detectedByVision: false
                        )
                        onAdd(item)
                    }
                    .disabled(equipmentTypeName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - EquipmentDetails weight summary helper

private extension EquipmentDetails {
    /// A compact human-readable summary for display in list rows.
    var weightSummary: String? {
        switch self {
        case .incrementBased(let min, let max, _):
            return "\(formatKg(min))–\(formatKg(max)) kg"
        case .plateBased(let bar, let plates):
            let maxPlate = plates.max() ?? 0
            let approxMax = bar + maxPlate * 2
            return "up to ~\(formatKg(approxMax)) kg"
        case .bodyweightOnly:
            return nil
        }
    }

    private func formatKg(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(kg))
            : String(format: "%.1f", kg)
    }
}

// MARK: - EquipmentType display name helper

private extension EquipmentType {
    /// Human-readable display name derived from the enum case.
    var displayName: String {
        switch self {
        case .dumbbellSet:    return "Dumbbell Set"
        case .barbell:        return "Barbell"
        case .ezCurlBar:      return "EZ Curl Bar"
        case .cableMachine:   return "Cable Machine"
        case .smithMachine:   return "Smith Machine"
        case .legPress:       return "Leg Press"
        case .adjustableBench: return "Adjustable Bench"
        case .flatBench:      return "Flat Bench"
        case .pullUpBar:      return "Pull-up Bar"
        case .unknown(let raw):
            return raw
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }
}

// MARK: - EquipmentType convenience init

private extension EquipmentType {
    /// Converts a raw snake_case string from the UI into the appropriate enum case.
    init(rawString: String) {
        switch rawString {
        case "dumbbell_set":     self = .dumbbellSet
        case "barbell":          self = .barbell
        case "ez_curl_bar":      self = .ezCurlBar
        case "cable_machine":    self = .cableMachine
        case "smith_machine":    self = .smithMachine
        case "leg_press":        self = .legPress
        case "adjustable_bench": self = .adjustableBench
        case "flat_bench":       self = .flatBench
        case "pull_up_bar":      self = .pullUpBar
        default:                 self = .unknown(rawString)
        }
    }
}

// MARK: - Previews

#Preview("Idle State") {
    NavigationStack {
        ScannerView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Confirming State — Mock Data") {
    NavigationStack {
        ScannerView()
    }
    .preferredColorScheme(.dark)
}
