// BulkEquipmentPickerSheet.swift
// ProjectApex — GymScanner Feature
//
// A full-screen sheet that lets the user select multiple equipment types at once.
//
// Features:
//   • Searchable list filtered in real-time across all sections
//   • Equipment grouped into collapsible sections matching EquipmentCategory
//   • Per-item checkmark toggle; section-level "Select All / Deselect All" header
//   • Already-present items greyed out and non-selectable (duplicate prevention)
//   • Live "Add X Items" confirm button at the bottom
//   • "Can't find it? Add custom" fallback link that opens EquipmentEditSheet

import SwiftUI

// MARK: - BulkEquipmentPickerSheet

struct BulkEquipmentPickerSheet: View {

    /// Equipment types already in the GymProfile — greyed out and non-selectable.
    let alreadyAdded: Set<EquipmentType>

    /// Called with the newly selected items when the user taps the confirm button.
    var onConfirm: ([EquipmentItem]) -> Void

    /// Called when the user dismisses without confirming.
    var onCancel: () -> Void

    // MARK: State

    @State private var searchText: String = ""
    @State private var selectedTypes: Set<EquipmentType> = []
    @State private var collapsedSections: Set<EquipmentCategory> = []
    @State private var showingCustomAdd = false

    // MARK: Derived

    /// All known categories in display order.
    private let categories = EquipmentCategory.allCases

    /// Returns equipment types for a given category, filtered by the current search query.
    private func types(for category: EquipmentCategory) -> [EquipmentType] {
        let base = EquipmentType.knownCases.filter { $0.category == category }
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// Categories that have at least one visible (post-search) item.
    private var visibleCategories: [EquipmentCategory] {
        categories.filter { !types(for: $0).isEmpty }
    }

    /// True if every visible item in `category` is selected.
    private func allSelected(in category: EquipmentCategory) -> Bool {
        let selectable = types(for: category).filter { !alreadyAdded.contains($0) }
        return !selectable.isEmpty && selectable.allSatisfy { selectedTypes.contains($0) }
    }

    private var confirmButtonTitle: String {
        let count = selectedTypes.count
        if count == 0 { return "Select Items" }
        return "Add \(count) Item\(count == 1 ? "" : "s")"
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Inline search bar
                searchBar

                // Grouped equipment list
                List {
                    ForEach(visibleCategories) { category in
                        sectionView(for: category)
                    }

                    // Custom add fallback
                    Section {
                        Button {
                            showingCustomAdd = true
                        } label: {
                            Label("Can't find it? Add custom", systemImage: "plus.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)

                // Confirm button pinned at the bottom
                confirmButton
            }
            .navigationTitle("Add Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .sheet(isPresented: $showingCustomAdd) {
            EquipmentEditSheet(
                existingItem: nil,
                onSave: { item in
                    showingCustomAdd = false
                    onConfirm([item])
                },
                onCancel: { showingCustomAdd = false }
            )
        }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search equipment…", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func sectionView(for category: EquipmentCategory) -> some View {
        let items = types(for: category)
        let isCollapsed = collapsedSections.contains(category)

        Section {
            if !isCollapsed {
                ForEach(items, id: \.self) { type in
                    equipmentRow(type: type)
                }
            }
        } header: {
            categoryHeader(for: category, items: items, isCollapsed: isCollapsed)
        }
    }

    private func categoryHeader(
        for category: EquipmentCategory,
        items: [EquipmentType],
        isCollapsed: Bool
    ) -> some View {
        let selectableItems = items.filter { !alreadyAdded.contains($0) }
        let hasSelectable = !selectableItems.isEmpty
        let sectionAllSelected = allSelected(in: category)

        return HStack {
            // Collapse/expand chevron
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isCollapsed {
                        collapsedSections.remove(category)
                    } else {
                        collapsedSections.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Image(systemName: category.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(category.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Select All / Deselect All toggle — only when section is expanded
            if !isCollapsed && hasSelectable {
                Button {
                    if sectionAllSelected {
                        selectableItems.forEach { selectedTypes.remove($0) }
                    } else {
                        selectableItems.forEach { selectedTypes.insert($0) }
                    }
                } label: {
                    Text(sectionAllSelected ? "Deselect All" : "Select All")
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private func equipmentRow(type: EquipmentType) -> some View {
        let isAlreadyAdded = alreadyAdded.contains(type)
        let isSelected = selectedTypes.contains(type)

        return Button {
            guard !isAlreadyAdded else { return }
            if isSelected {
                selectedTypes.remove(type)
            } else {
                selectedTypes.insert(type)
            }
        } label: {
            HStack(spacing: 12) {
                Text(type.displayName)
                    .foregroundStyle(isAlreadyAdded ? .tertiary : .primary)

                Spacer()

                if isAlreadyAdded {
                    Text("Added")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.quaternary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAlreadyAdded)
    }

    private var confirmButton: some View {
        Button {
            let items = selectedTypes.map { type in
                EquipmentItem(
                    equipmentType: type,
                    count: 1,
                    detectedByVision: false,
                    bodyweightOnly: type.isNaturallyBodyweightOnly ? true : nil
                )
            }
            onConfirm(items)
        } label: {
            Text(confirmButtonTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedTypes.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Preview

#Preview {
    BulkEquipmentPickerSheet(
        alreadyAdded: [.dumbbellSet, .barbell, .adjustableBench],
        onConfirm: { items in
            print("Confirmed \(items.count) items")
        },
        onCancel: { }
    )
    .preferredColorScheme(.dark)
}
