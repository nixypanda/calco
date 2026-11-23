// Meal create/edit form with a product-only ingredient picker, validated
// quantities and units, and unsaved-change protection.

import SwiftUI

private enum MealEditorField: Hashable {
    case name
    case notes
    case totalAmount
}

public struct MealEditorView: View {
    @ObservedObject private var viewModel: MealEditorViewModel
    private let onCancel: () -> Void
    private let onDirtyChange: ((Bool) -> Void)?
    @FocusState private var focusedField: MealEditorField?
    @State private var confirmDiscard = false
    @State private var selectingIngredient: Int?

    private var backPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    public init(
        viewModel: MealEditorViewModel,
        onCancel: @escaping () -> Void,
        onDirtyChange: ((Bool) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onCancel = onCancel
        self.onDirtyChange = onDirtyChange
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "meals.editor.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failedView(message)
            case .ready:
                readyView
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) { errorBar }
            }
        }
        .navigationTitle(viewModel.editorTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(selectingIngredient == nil && (viewModel.hasUnsavedChanges || viewModel.isSaving))
        .navigationDestination(isPresented: ingredientPickerPresented) {
            if let rowID = selectingIngredient {
                ingredientPicker(rowID: rowID)
            }
        }
        .toolbar {
            if selectingIngredient == nil, viewModel.hasUnsavedChanges || viewModel.isSaving {
                ToolbarItem(placement: backPlacement) {
                    Button {
                        requestClose()
                    } label: {
                        Label(String(localized: "library.common.back"), systemImage: "chevron.left")
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier("meals.editor.back")
                }
            }
            if selectingIngredient == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        focusedField = nil
                        Task { await viewModel.save() }
                    } label: {
                        if viewModel.isSaving {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(String(localized: "meals.editor.saving"))
                            }
                        } else {
                            Text(String(localized: "meals.editor.save"))
                        }
                    }
                    .disabled(!viewModel.isReady || viewModel.isSaving || viewModel.isSaveBlocked)
                    .accessibilityIdentifier("meals.editor.save")
                }
            }
        }
        .interactiveDismissDisabled(viewModel.hasUnsavedChanges || viewModel.isSaving)
        .onAppear { onDirtyChange?(viewModel.hasUnsavedChanges) }
        .onChange(of: viewModel.hasUnsavedChanges) { _, dirty in
            onDirtyChange?(dirty)
        }
        .onDisappear {
            if selectingIngredient == nil { onDirtyChange?(false) }
        }
        .alert(
            String(localized: "meals.editor.discard.title"),
            isPresented: $confirmDiscard
        ) {
            Button(role: .destructive) {
                onCancel()
            } label: {
                Text(String(localized: "meals.editor.discard.confirm"))
            }
            Button(role: .cancel) {} label: {
                Text(String(localized: "meals.editor.discard.keepEditing"))
            }
        } message: {
            Text(String(localized: "meals.editor.discard.message"))
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private func failedView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

                Button {
                    Task { await viewModel.reload() }
                } label: {
                    Text(String(localized: "meals.editor.retry"))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("meals.editor.retry")

            }
            .frame(maxWidth: 480)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .accessibilityIdentifier("meals.editor.error")
    }

    private var readyView: some View {
        Form {
            basicSection
            recipeTotalSection
            componentsSection
        }
        .disabled(viewModel.isSaving)
    }

    private var basicSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "meals.editor.name"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "meals.editor.name"), text: $viewModel.name)
                    .focused($focusedField, equals: .name)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "meals.editor.name"))
                    .accessibilityIdentifier("meals.editor.name")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "meals.editor.notes"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "meals.editor.notes.placeholder"),
                    text: $viewModel.notes,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .focused($focusedField, equals: .notes)
                .labelsHidden()
                .accessibilityLabel(String(localized: "meals.editor.notes"))
                .accessibilityIdentifier("meals.editor.notes")
            }
        } header: {
            Text(String(localized: "meals.editor.basic"))
        }
    }

    @ViewBuilder
    private var recipeTotalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "meals.editor.total.amount"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "meals.editor.total.amount"),
                    text: $viewModel.totalAmount
                )
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
                .focused($focusedField, equals: .totalAmount)
                .labelsHidden()
                .accessibilityLabel(String(localized: "meals.editor.total.amount"))
                .accessibilityIdentifier("meals.editor.total.amount")
            }

            Picker(
                String(localized: "meals.editor.total.unit"),
                selection: $viewModel.totalUnit
            ) {
                ForEach(viewModel.units, id: \.code) { unit in
                    Text(unit.name).tag(unit.code)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("meals.editor.total.unit")
        } header: {
            Text(String(localized: "meals.editor.total"))
        } footer: {
            if let helper = viewModel.totalQuantityHelperText {
                Text(helper)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meals.editor.total.helper")
            } else {
                Text(String(localized: "meals.editor.total.footer"))
                    .accessibilityIdentifier("meals.editor.total.footer")
            }
        }
    }

    private var componentsSection: some View {
        Section {
            ForEach(viewModel.components) { row in
                componentView(row)
            }

            Button {
                focusedField = nil
                viewModel.addComponent()
            } label: {
                Label(
                    String(localized: "meals.editor.addComponent"),
                    systemImage: "plus.circle"
                )
            }
            .accessibilityIdentifier("meals.editor.addComponent")
        } header: {
            Text(String(localized: "meals.editor.components"))
        } footer: {
            if let notice = viewModel.unitFallbackNotice {
                Text(notice)
                    .accessibilityIdentifier("meals.editor.unitFallback")
            }
        }
    }

    private func componentView(_ row: MealComponentRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                focusedField = nil
                selectingIngredient = row.id
            } label: {
                HStack {
                    Text(row.hasSelection ? row.displayName : String(localized: "meals.editor.searchFood"))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("meals.editor.component.\(row.id).choose")

            if row.isResolvingName {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "meals.editor.loadingFood"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if row.isMissing {
                Label {
                    Text(String(localized: "meals.editor.missingFood.message"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("meals.editor.component.\(row.id).missing")
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 8) {
                    componentAmountField(rowID: row.id)
                    componentUnitPicker(rowID: row.id)
                    removeComponentButton(rowID: row.id)
                }
                VStack(alignment: .leading, spacing: 8) {
                    componentAmountField(rowID: row.id)
                    HStack(spacing: 8) {
                        componentUnitPicker(rowID: row.id)
                        Spacer(minLength: 8)
                        removeComponentButton(rowID: row.id)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meals.editor.component.\(row.id)")
    }

    private func componentAmountField(rowID: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "meals.editor.quantity"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                String(localized: "meals.editor.quantity"),
                text: componentAmountBinding(rowID: rowID)
            )
#if os(iOS)
            .keyboardType(.decimalPad)
#endif
            .labelsHidden()
            .accessibilityLabel(String(localized: "meals.editor.quantity"))
            .accessibilityIdentifier("meals.editor.component.\(rowID).quantity")
        }
    }

    private func componentUnitPicker(rowID: Int) -> some View {
        Picker(
            String(localized: "meals.editor.unit"),
            selection: componentUnitBinding(rowID: rowID)
        ) {
            ForEach(viewModel.units, id: \.code) { unit in
                Text(unit.name).tag(unit.code)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("meals.editor.component.\(rowID).unit")
    }

    private func removeComponentButton(rowID: Int) -> some View {
        Button(role: .destructive) {
            viewModel.removeComponent(rowID: rowID)
        } label: {
            Image(systemName: "trash")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .tint(.red)
        .accessibilityLabel(String(localized: "meals.editor.removeComponent"))
        .accessibilityIdentifier("meals.editor.component.\(rowID).remove")
    }

    @ViewBuilder
    private func searchResults(for row: MealComponentRow) -> some View {
        switch row.searchState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "meals.editor.searching"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text(String(localized: "meals.editor.searchEmpty"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.red)
        case .results(let products):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(products.prefix(8)) { product in
                    Button {
                        focusedField = nil
                        viewModel.selectProduct(rowID: row.id, product: product)
                        selectingIngredient = nil
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.name)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let brand = product.brand, !brand.isEmpty {
                                    Text(brand)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if let kcal = MealNutrientDisplay.kcal(product.nutritionSummary) {
                                Text(kcal)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "meals.editor.component.\(row.id).result.\(product.id)"
                    )
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var errorBar: some View {
        if let message = viewModel.displayErrorMessage {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("meals.editor.message")
        }
    }

    private func requestClose() {
        focusedField = nil
        if viewModel.hasUnsavedChanges {
            confirmDiscard = true
        } else {
            onCancel()
        }
    }

    private var ingredientPickerPresented: Binding<Bool> {
        Binding(get: { selectingIngredient != nil }, set: { if !$0 { selectingIngredient = nil } })
    }

    private func ingredientPicker(rowID: Int) -> some View {
        Form {
            TextField(String(localized: "meals.editor.searchFood"),
                      text: componentQueryBinding(rowID: rowID))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("meals.editor.component.\(rowID).search")
            if let row = viewModel.components.first(where: { $0.id == rowID }) {
                searchResults(for: row)
            }
        }
        .navigationTitle(String(localized: "meals.editor.searchFood"))
        // A native back-history menu must not jump over the dirty parent editor.
        .navigationBarBackButtonHidden(viewModel.hasUnsavedChanges)
        .toolbar {
            if viewModel.hasUnsavedChanges {
                ToolbarItem(placement: backPlacement) {
                    Button { selectingIngredient = nil } label: {
                        Label(String(localized: "library.common.back"), systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("meals.editor.ingredient.back")
                }
            }
        }
        .accessibilityIdentifier("meals.editor.ingredientPicker")
    }

    private func componentQueryBinding(rowID: Int) -> Binding<String> {
        Binding(
            get: {
                viewModel.components.first(where: { $0.id == rowID })?.query ?? ""
            },
            set: { viewModel.searchQueryChanged(rowID: rowID, query: $0) }
        )
    }

    private func componentAmountBinding(rowID: Int) -> Binding<String> {
        Binding(
            get: {
                viewModel.components.first(where: { $0.id == rowID })?.amount ?? ""
            },
            set: { viewModel.componentAmountChanged(rowID: rowID, amount: $0) }
        )
    }

    private func componentUnitBinding(rowID: Int) -> Binding<String> {
        Binding(
            get: {
                viewModel.components.first(where: { $0.id == rowID })?.unit ?? "g"
            },
            set: { viewModel.componentUnitChanged(rowID: rowID, unit: $0) }
        )
    }
}
