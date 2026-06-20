// ScannerView.swift
// ProjectApex — GymScanner Feature
//
// The manual gym-equipment setup screen. The camera "gym scanner" (Vision API
// single-item capture) was removed in S3 (#527); equipment is now entered
// exclusively through the manual BulkEquipmentPickerSheet / EquipmentEditSheet.
//
// UX Flow:
//   1. Review list — the editable equipment list (tap a row to edit, swipe to
//      delete, "Add Equipment Manually" opens the bulk picker).
//   2. Completed   — the profile has been saved; the parent dismisses.
//
// State transitions rendered by this view (driven by ScannerViewModel.state):
//   .confirming  → editable equipment list + "Save" button
//   .completed   → success screen

import SwiftUI

// MARK: - EquipmentSetupView

struct EquipmentSetupView: View {

    @State private var viewModel = ScannerViewModel()

    /// Pre-seed the editable list (e.g. an existing profile's equipment).
    var initialEquipment: [EquipmentItem] = []

    /// Callback invoked when a confirmed GymProfile is ready for the parent to persist.
    var onProfileConfirmed: ((GymProfile) -> Void)?

    // For the confirmation sheet presentations
    @State private var showingBulkPickerSheet = false
    @State private var itemBeingEdited: EquipmentItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .confirming:
                confirmingView

            case .completed(let profile):
                completedView(profile: profile)
            }
        }
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if viewModel.detectedEquipment.isEmpty, !initialEquipment.isEmpty {
                initialEquipment.forEach { viewModel.addEquipment($0) }
            }
        }
    }

    // ---------------------------------------------------------------------------
    // MARK: State Views
    // ---------------------------------------------------------------------------

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
                    Text("\(viewModel.detectedEquipment.count) item\(viewModel.detectedEquipment.count == 1 ? "" : "s")")
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))

                Section {
                    Button(action: { showingBulkPickerSheet = true }) {
                        Label("Add Equipment", systemImage: "plus.circle")
                    }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your Equipment")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
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
        .sheet(isPresented: $showingBulkPickerSheet) {
            BulkEquipmentPickerSheet(
                alreadyAdded: Set(viewModel.detectedEquipment.map(\.equipmentType)),
                onConfirm: { items in
                    items.forEach { viewModel.addEquipment($0) }
                    showingBulkPickerSheet = false
                },
                onCancel: { showingBulkPickerSheet = false }
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
    @State private var customName: String = ""
    @State private var count: Int = 1
    @State private var notes: String = ""

    private var isEditing: Bool { existingItem != nil }
    private var title: String { isEditing ? "Edit Equipment" : "Add Equipment" }
    private var saveLabel: String { isEditing ? "Save" : "Add" }

    /// Trimmed custom machine name; non-empty means "use a custom type".
    private var trimmedCustomName: String {
        customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                    .disabled(!trimmedCustomName.isEmpty)

                    Stepper("Count: \(count)", value: $count, in: 1...50)
                }

                Section {
                    TextField("e.g. Belt squat machine", text: $customName)
                } header: {
                    Text("Custom Name (optional)")
                } footer: {
                    Text("Can't find it in the list? Type the machine's name here and we'll add it as a custom item.")
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
        count = item.count
        notes = item.notes ?? ""
        // A custom (unknown) machine pre-fills the name field; a known type
        // selects the picker.
        if case .unknown(let raw) = item.equipmentType {
            customName = raw
        } else {
            selectedType = item.equipmentType
        }
    }

    private func commitSave() {
        // A non-empty custom name creates a custom EquipmentType.unknown(...);
        // otherwise the known-type picker selection is used.
        let type: EquipmentType = trimmedCustomName.isEmpty
            ? selectedType
            : .unknown(trimmedCustomName)
        let item = EquipmentItem(
            id: existingItem?.id ?? UUID(),
            equipmentType: type,
            count: count,
            notes: notes.isEmpty ? nil : notes,
            detectedByVision: existingItem?.detectedByVision ?? false
        )
        onSave(item)
    }
}

// MARK: - Previews

#Preview("Equipment Setup") {
    NavigationStack {
        EquipmentSetupView()
    }
    .preferredColorScheme(.dark)
}
