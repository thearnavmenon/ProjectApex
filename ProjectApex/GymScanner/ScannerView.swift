// ScannerView.swift
// ProjectApex — GymScanner Feature
//
// The main SwiftUI view for the guided gym equipment scanning flow.
//
// UX Flow:
//   1. Idle        — "Start" button with instructional text
//   2. Previewing  — Live camera + shutter button + item count + "Done" button
//   3. Analyzing   — Spinner overlay while Vision API runs
//   4. Reviewed    — Result card (identified equipment) with "Add" / "Discard"
//   5. Confirming  — Editable equipment list before saving the profile
//   6. Completed   — Success screen
//
// State transitions rendered by this view (driven by ScannerViewModel.state):
//   .idle              → "Start" button
//   .requestingPermission → spinner
//   .previewing        → live feed + shutter + count badge + "Done"
//   .analyzing         → live feed + centered spinner
//   .reviewed          → dimmed feed + result card
//   .confirming        → editable equipment list + "Confirm Profile" button
//   .completed         → success screen
//   .permissionDenied  → settings deep-link prompt
//   .error             → inline error with retry option

import SwiftUI
import AVFoundation

// MARK: - ScannerView

struct ScannerView: View {

    @State private var viewModel = ScannerViewModel()

    /// Callback invoked when a confirmed GymProfile is ready for the parent to persist.
    var onProfileConfirmed: ((GymProfile) -> Void)?

    // For the confirmation sheet presentations
    @State private var showingAddEquipmentSheet = false
    @State private var itemBeingEdited: EquipmentItem?

    // For editing the reviewed item before confirming
    @State private var showingEditBeforeAddSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .idle:
                idleView

            case .requestingPermission:
                permissionSpinnerView

            case .previewing:
                previewingView

            case .analyzing:
                analyzingView

            case .reviewed(let item):
                reviewedView(item: item)

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

                Text("Take a photo of each piece of equipment,\none at a time, to build your gym profile.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button(action: { viewModel.startCapture() }) {
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

    /// The main guided capture state: live camera preview + shutter button.
    private var previewingView: some View {
        ZStack {
            // Live camera feed fills the screen
            CameraPreviewView(previewLayer: viewModel.previewLayer)
                .ignoresSafeArea()

            // Top bar: item count + Done button
            VStack {
                HStack {
                    // Item count badge
                    if !viewModel.detectedEquipment.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("\(viewModel.detectedEquipment.count) item\(viewModel.detectedEquipment.count == 1 ? "" : "s") captured")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                    }

                    Spacer()

                    // Done button (only visible when ≥1 item captured)
                    if !viewModel.detectedEquipment.isEmpty {
                        Button(action: { viewModel.doneCapturing() }) {
                            Text("Done")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.white, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)

                Spacer()

                // Instruction label
                Text("Point at one piece of equipment")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 20)

                // Shutter button
                Button(action: { viewModel.captureAndIdentify() }) {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                        Circle()
                            .stroke(.white.opacity(0.4), lineWidth: 3)
                            .frame(width: 86, height: 86)
                    }
                }
                .padding(.bottom, 52)
            }

            // "Nothing detected" toast
            if viewModel.nothingDetectedToast {
                VStack {
                    Spacer()
                    Text("No gym equipment detected — try again")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.bottom, 160)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.nothingDetectedToast)
            }
        }
    }

    /// Shown while the Vision API is processing the captured photo.
    private var analyzingView: some View {
        ZStack {
            CameraPreviewView(previewLayer: viewModel.previewLayer)
                .ignoresSafeArea()

            // Frosted overlay
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.8)

                Text("Identifying equipment…")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
    }

    /// Shown when the Vision API identified an item. User confirms or discards.
    private func reviewedView(item: EquipmentItem) -> some View {
        ZStack {
            CameraPreviewView(previewLayer: viewModel.previewLayer)
                .ignoresSafeArea()

            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Result card
                VStack(spacing: 20) {
                    // Equipment icon (system image) and name
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)

                        Text(item.equipmentType.displayName)
                            .font(.title2.bold())
                            .foregroundStyle(.primary)

                        Text("×\(item.count) detected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    // Action buttons
                    HStack(spacing: 12) {
                        // Discard
                        Button(action: { viewModel.rejectDetection() }) {
                            Label("Discard", systemImage: "xmark")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        // Add to list
                        Button(action: { viewModel.confirmDetection() }) {
                            Label("Add to List", systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    // Edit before adding link
                    Button(action: { showingEditBeforeAddSheet = true }) {
                        Text("Edit before adding")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: $showingEditBeforeAddSheet) {
            EquipmentEditSheet(
                existingItem: item,
                onSave: { edited in
                    showingEditBeforeAddSheet = false
                    // Add the edited item then dismiss the reviewed state.
                    viewModel.addEquipment(edited)
                    viewModel.rejectDetection() // Clears the .reviewed state
                },
                onCancel: { showingEditBeforeAddSheet = false }
            )
        }
    }

    /// Confirmation screen: editable equipment list before profile is saved.
    private var confirmingView: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.detectedEquipment) { item in
                        EquipmentRowView(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { itemBeingEdited = item }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.removeEquipment(id: viewModel.detectedEquipment[index].id)
                        }
                    }
                } header: {
                    Text("\(viewModel.detectedEquipment.count) item\(viewModel.detectedEquipment.count == 1 ? "" : "s") detected")
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
                        Text("Save")
                            .bold()
                    }
                    .disabled(viewModel.detectedEquipment.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingAddEquipmentSheet) {
            EquipmentEditSheet(
                existingItem: nil,
                onSave: { item in
                    viewModel.addEquipment(item)
                    showingAddEquipmentSheet = false
                },
                onCancel: { showingAddEquipmentSheet = false }
            )
        }
        .sheet(item: $itemBeingEdited) { item in
            EquipmentEditSheet(
                existingItem: item,
                onSave: { updated in
                    viewModel.updateEquipment(updated)
                    itemBeingEdited = nil
                },
                onCancel: { itemBeingEdited = nil }
            )
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

    /// Shown when camera permission has been denied.
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
                viewModel.reset()
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Shown for non-permission errors.
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
/// in a SwiftUI hierarchy.
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

    class PreviewUIView: UIView {
        private var currentPreviewLayer: AVCaptureVideoPreviewLayer?

        func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
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

// MARK: - EquipmentRowView (Confirmation Screen)

/// A display row for the confirmation list. Tap to open the edit sheet.
struct EquipmentRowView: View {

    let item: EquipmentItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.equipmentType.displayName)
                    .font(.body)

                if let notes = item.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("×\(item.count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(.primary)

            Text(item.detectedByVision ? "AI" : "Manual")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    item.detectedByVision
                        ? Color.blue.opacity(0.18)
                        : Color.orange.opacity(0.18),
                    in: Capsule()
                )
                .foregroundStyle(item.detectedByVision ? Color.blue : Color.orange)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - EquipmentEditSheet

/// Modal sheet for adding new equipment or editing existing items.
struct EquipmentEditSheet: View {

    let existingItem: EquipmentItem?
    var onSave: (EquipmentItem) -> Void
    var onCancel: () -> Void

    @State private var selectedType: EquipmentType = .dumbbellSet
    @State private var count: Int = 1
    @State private var notes: String = ""

    private var isEditing: Bool { existingItem != nil }
    private var title: String { isEditing ? "Edit Equipment" : "Add Equipment" }
    private var saveLabel: String { isEditing ? "Save" : "Add" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment Type") {
                    Picker("Type", selection: $selectedType) {
                        ForEach(EquipmentType.knownCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper("Count: \(count)", value: $count, in: 1...50)
                }

                Section("Notes (optional)") {
                    TextField("e.g. broken cable, limited plates…", text: $notes)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel) { commitSave() }
                }
            }
        }
        .onAppear { populateFromExisting() }
    }

    private func populateFromExisting() {
        guard let item = existingItem else { return }
        selectedType = item.equipmentType
        count = item.count
        notes = item.notes ?? ""
    }

    private func commitSave() {
        let item = EquipmentItem(
            id: existingItem?.id ?? UUID(),
            equipmentType: selectedType,
            count: count,
            notes: notes.isEmpty ? nil : notes,
            detectedByVision: existingItem?.detectedByVision ?? false
        )
        onSave(item)
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
