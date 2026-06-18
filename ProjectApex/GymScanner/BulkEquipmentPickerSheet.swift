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
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Apex.textDim)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Apex.hairline)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Apex.bg)

                // Confirm button pinned at the bottom
                confirmButton
            }
            .background(Apex.bg)
            .navigationTitle("Add Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Apex.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Apex.textDim)
                }
            }
        }
        .preferredColorScheme(.dark)
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
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Apex.textFaint)
            TextField("", text: $searchText, prompt:
                Text("Search equipment…")
                    .foregroundColor(Apex.textFaint)
            )
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Apex.text)
            .tint(Apex.accent)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Apex.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .apexCard()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Apex.bg)
    }

    @ViewBuilder
    private func sectionView(for category: EquipmentCategory) -> some View {
        let items = types(for: category)
        let isCollapsed = collapsedSections.contains(category)

        Section {
            if !isCollapsed {
                ForEach(items, id: \.self) { type in
                    equipmentRow(type: type)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Apex.hairline)
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
                HStack(spacing: 7) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Apex.textFaint)
                        .frame(width: 14)
                    Image(systemName: category.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Apex.textDim)
                    ApexSectionLabel(text: category.rawValue, color: Apex.textDim)
                        .textCase(nil)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Select All / Deselect All toggle — only when section is expanded.
            // Demoted off-accent (textDim) so the bottom confirm bar is the sole
            // lime CTA.
            if !isCollapsed && hasSelectable {
                Button {
                    if sectionAllSelected {
                        selectableItems.forEach { selectedTypes.remove($0) }
                    } else {
                        selectableItems.forEach { selectedTypes.insert($0) }
                    }
                } label: {
                    Text(sectionAllSelected ? "Deselect All" : "Select All")
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Apex.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isAlreadyAdded ? Apex.textFaint : Apex.text)

                Spacer()

                if isAlreadyAdded {
                    Text("Added")
                        .font(.system(size: 12, weight: .semibold))
                        .fontWidth(.condensed)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Apex.textFaint)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Apex.accent)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Apex.textFaint)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAlreadyAdded)
    }

    private var confirmButton: some View {
        let isEmpty = selectedTypes.isEmpty
        return Button {
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
            ApexButton(title: confirmButtonTitle, icon: "plus")
                .opacity(isEmpty ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Apex.bg)
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
