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
    @FocusState private var focusedField: MealEditorField?
    @State private var confirmDiscard = false
    @State private var confirmDiscardReconciliation = false
    @State private var confirmResetReconciliation = false

    public init(
        viewModel: MealEditorViewModel,
        onCancel: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onCancel = onCancel
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    requestClose()
                } label: {
                    Text(String(localized: "meals.editor.cancel"))
                }
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("meals.editor.cancel")
            }
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
        .interactiveDismissDisabled(viewModel.hasUnsavedChanges || viewModel.isSaving)
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

                Button {
                    onCancel()
                } label: {
                    Text(String(localized: "meals.editor.cancel"))
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 480)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .accessibilityIdentifier("meals.editor.error")
    }

    private var readyView: some View {
        Form {
            if viewModel.needsCreateReconciliation
                || viewModel.reconciliationUnreadable {
                reconciliationSections
            } else {
                basicSection
                recipeTotalSection
                componentsSection
            }
        }
        .disabled(viewModel.isSaving)
        .alert(
            String(localized: "meals.reconcile.discard.title"),
            isPresented: $confirmDiscardReconciliation
        ) {
            Button(role: .destructive) {
                viewModel.discardReconciliation()
            } label: {
                Text(String(localized: "meals.reconcile.discard.confirm"))
            }
            Button(role: .cancel) {} label: {
                Text(String(localized: "meals.editor.discard.keepEditing"))
            }
        } message: {
            Text(String(localized: "meals.reconcile.discard.message"))
        }
        .alert(
            String(localized: "meals.reconcile.reset.title"),
            isPresented: $confirmResetReconciliation
        ) {
            Button(role: .destructive) {
                viewModel.resetUnreadableReconciliation()
            } label: {
                Text(String(localized: "meals.reconcile.reset.confirm"))
            }
            Button(role: .cancel) {} label: {
                Text(String(localized: "meals.editor.discard.keepEditing"))
            }
        } message: {
            Text(String(localized: "meals.reconcile.reset.message"))
        }
    }

    @ViewBuilder
    private var reconciliationSections: some View {
        if let attempt = viewModel.reconciliationAttempt {
            Section {
                Label {
                    Text(String(localized: "meals.reconcile.title"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .font(.headline)
                .foregroundStyle(.orange)

                Text(
                    String(
                        format: String(localized: "meals.reconcile.message"),
                        attempt.displayName
                    )
                )
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("meals.reconcile.message")

                Button {
                    Task { await viewModel.refreshReconciliationCandidates() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isRefreshingReconciliation {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            viewModel.isRefreshingReconciliation
                                ? String(localized: "meals.reconcile.refreshing")
                                : String(localized: "meals.reconcile.refresh")
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRefreshingReconciliation)
                .accessibilityIdentifier("meals.reconcile.refresh")
            }

            if !viewModel.reconciliationCandidates.isEmpty {
                Section {
                    ForEach(viewModel.reconciliationCandidates) { meal in
                        Button {
                            viewModel.useReconciledMeal(meal)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meal.name)
                                        .foregroundStyle(.primary)
                                    if let total = MealNutrientDisplay.quantity(
                                        meal.totalQuantity
                                    ) {
                                        Text(total)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(String(localized: "meals.reconcile.use"))
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .disabled(viewModel.isRefreshingReconciliation)
                        .accessibilityIdentifier("meals.reconcile.candidate.\(meal.id)")
                    }
                } header: {
                    Text(String(localized: "meals.reconcile.candidates"))
                }
            }

            if let message = viewModel.reconciliationMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("meals.reconcile.status")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDiscardReconciliation = true
                } label: {
                    Text(String(localized: "meals.reconcile.discard"))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("meals.reconcile.discard")
            } footer: {
                Text(String(localized: "meals.reconcile.discard.help"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if viewModel.reconciliationUnreadable {
            Section {
                Label {
                    Text(String(localized: "meals.reconcile.storeUnavailable"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier("meals.reconcile.storeUnavailable")

                Button(role: .destructive) {
                    confirmResetReconciliation = true
                } label: {
                    Text(String(localized: "meals.reconcile.reset"))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("meals.reconcile.reset")
            }
        }
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
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "meals.editor.searchFood"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    String(localized: "meals.editor.searchFood"),
                    text: componentQueryBinding(rowID: row.id)
                )
                .labelsHidden()
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .accessibilityLabel(String(localized: "meals.editor.searchFood"))
                .accessibilityIdentifier("meals.editor.component.\(row.id).search")
            }

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

            searchResults(for: row)

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
        }
        .buttonStyle(.borderless)
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
