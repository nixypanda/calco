// Custom-food create/edit screen. Creation has no serving/default portion
// fields; editing supports both. Unsaved edits require explicit discard.

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct CustomFoodEditorView: View {
    @ObservedObject private var viewModel: CustomFoodEditorViewModel
    @Environment(\.dismiss) private var dismissEnvironment
    @FocusState private var focusedField: Field?
    @State private var confirmingCancel = false
    @State private var confirmingResetStore = false

    private enum Field: Hashable {
        case name
        case brand
        case categories
        case defaultQuantity
        case defaultUnit
    }

    public init(viewModel: CustomFoodEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "foodDetail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failedView(message)
            case .loaded:
                loadedView
            }
        }
        .navigationTitle(Text(title))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationBarBackButtonHidden(true)
        .toolbar {
#if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "library.common.done")) {
                    focusedField = nil
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .accessibilityIdentifier("library.editor.keyboard.done")
            }
#endif
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "diary.common.cancel")) {
                    if viewModel.hasUnsavedChanges {
                        confirmingCancel = true
                    } else {
                        dismissEnvironment()
                    }
                }
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("diary.common.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Text(String(localized: "library.editor.save"))
                    }
                }
                .disabled(!viewModel.canSubmit)
                .accessibilityIdentifier("library.editor.save")
            }
        }
        .task {
            if case .loading = viewModel.loadState {
                await viewModel.load()
            }
        }
        .alert(
            String(localized: "diary.editor.discard.title"),
            isPresented: $confirmingCancel
        ) {
            Button(String(localized: "diary.editor.discard.action"), role: .destructive) {
                dismissEnvironment()
            }
            .accessibilityIdentifier("library.editor.discard.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "diary.editor.discard.message"))
        }
        .alert(
            String(localized: "library.reconcile.reset.title"),
            isPresented: $confirmingResetStore
        ) {
            Button(String(localized: "library.reconcile.reset.action"), role: .destructive) {
                Task { await viewModel.resetUnreadableReconciliation() }
            }
            Button(String(localized: "diary.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "library.reconcile.reset.message"))
        }
    }

    private var title: String {
        viewModel.mode.isCreate
            ? String(localized: "library.editor.create.title")
            : String(localized: "library.editor.edit.title")
    }

    @ViewBuilder
    private func failedView(_ message: String) -> some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "foodDetail.retry")) {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("library.editor.retry")

                    if viewModel.isReconciliationStoreBlocked {
                        Button(role: .destructive) {
                            confirmingResetStore = true
                        } label: {
                            Text(String(localized: "library.reconcile.reset"))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("library.reconcile.reset")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private var loadedView: some View {
        Form {
            if let attempt = viewModel.reconciliationAttempt {
                CustomFoodReconciliationView(
                    attempt: attempt,
                    candidates: viewModel.reconciliationCandidates,
                    message: viewModel.reconciliationMessage,
                    isRefreshing: viewModel.isRefreshingReconciliation,
                    onRefresh: {
                        Task { await viewModel.refreshReconciliationCandidates() }
                    },
                    onUse: { food in
                        Task { await viewModel.useReconciledFood(food) }
                    },
                    onDiscard: {
                        Task { await viewModel.discardReconciliation() }
                    }
                )
            } else if viewModel.hasRetainedLogIntent {
                retainedFoodSection
            } else {
                detailsSection
                if let barcodeNotice = viewModel.barcodeNotice {
                    Section {
                        Label(barcodeNotice, systemImage: "barcode")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library.barcode.notice")
                    }
                }
                NutrientEditorView(
                    title: String(localized: "library.editor.nutrients.title"),
                    help: String(localized: "library.editor.nutrients.help"),
                    state: viewModel.nutrientEditor,
                    isDisabled: !viewModel.isFormEditable,
                    onAmountChange: { viewModel.setNutrientAmount($0, code: $1) },
                    onAddOptional: { viewModel.addOptionalNutrient(code: $0) },
                    onRemove: { viewModel.removeNutrient(code: $0) }
                )
                if viewModel.mode.isCreate {
                    Section {
                        Text(String(localized: "library.editor.create.servingsNote"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    servingSection
                    defaultPortionSection
                }
                if !viewModel.mode.isCreate {
                    Section {
                        Text(String(localized: "library.editor.snapshotNote"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library.editor.snapshotNote")
                    }
                }
            }

            submittedLogSection

            if let message = viewModel.submitError {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.editor.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var retainedFoodSection: some View {
        Section {
            Label {
                Text(String(localized: "library.log.saved.title"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)

            if let foodID = viewModel.savedFoodID {
                Text(
                    String(
                        format: String(localized: "library.log.savedFoodID"),
                        foodID
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private var detailsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.editor.name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.editor.name.placeholder"),
                    text: $viewModel.name
                )
                .focused($focusedField, equals: .name)
                .disabled(!viewModel.isFormEditable)
                .accessibilityIdentifier("library.editor.name")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.editor.brand"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.editor.brand.placeholder"),
                    text: $viewModel.brand
                )
                .focused($focusedField, equals: .brand)
                .disabled(!viewModel.isFormEditable)
                .accessibilityIdentifier("library.editor.brand")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.editor.categories"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.editor.categories.placeholder"),
                    text: $viewModel.categoriesText
                )
                .focused($focusedField, equals: .categories)
                .disabled(!viewModel.isFormEditable)
                .accessibilityIdentifier("library.editor.categories")
            }
        } footer: {
            Text(String(localized: "library.editor.categories.help"))
        }
    }

    private var servingSection: some View {
        Section {
            ForEach(viewModel.servings) { serving in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(localized: "library.editor.servings.unit"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if viewModel.isFormEditable {
                            Button(role: .destructive) {
                                viewModel.removeServingRow(id: serving.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "library.editor.servings.remove"))
                            .accessibilityIdentifier("library.editor.serving.\(serving.id).remove")
                        }
                    }
                    TextField(
                        String(localized: "library.editor.servings.unit"),
                        text: servingBinding(serving, field: .unit)
                    )
                    .disabled(!viewModel.isFormEditable)
                    .accessibilityIdentifier("library.editor.serving.\(serving.id).unit")

                    Text(String(localized: "library.editor.servings.grams"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        String(localized: "library.editor.servings.grams"),
                        text: servingBinding(serving, field: .grams)
                    )
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .disabled(!viewModel.isFormEditable)
                    .accessibilityIdentifier("library.editor.serving.\(serving.id).grams")
                }
                .padding(.vertical, 2)
            }

            if viewModel.isFormEditable {
                Button {
                    viewModel.addServingRow()
                } label: {
                    Label(
                        String(localized: "library.editor.servings.add"),
                        systemImage: "plus.circle"
                    )
                }
                .accessibilityIdentifier("library.editor.servings.add")
            }
        } header: {
            Text(String(localized: "library.editor.servings.title"))
        } footer: {
            Text(String(localized: "library.editor.servings.help"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultPortionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.editor.default.quantity"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.editor.default.quantity"),
                    text: $viewModel.defaultQuantity
                )
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
                .focused($focusedField, equals: .defaultQuantity)
                .disabled(!viewModel.isFormEditable)
                .accessibilityIdentifier("library.editor.default.quantity")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.editor.default.unit"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.editor.default.unit"),
                    text: $viewModel.defaultUnit
                )
                .focused($focusedField, equals: .defaultUnit)
                .disabled(!viewModel.isFormEditable)
                .accessibilityIdentifier("library.editor.default.unit")
            }
        } header: {
            Text(String(localized: "library.editor.default.title"))
        } footer: {
            Text(String(localized: "library.editor.default.help"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var submittedLogSection: some View {
        switch viewModel.savedLogState {
        case .none:
            EmptyView()
        case .logging:
            Section {
                ProgressView(String(localized: "library.log.logging"))
                    .accessibilityIdentifier("library.log.logging")
            }
        case .pending(let message):
            Section {
                savedLogMessage(message, style: .orange)
                retainedLogIntentRow
                Button(String(localized: "foodDetail.pending.checkDiary")) {
                    viewModel.reviewPendingLogs()
                }
                .accessibilityIdentifier("library.log.review")
            } header: {
                Text(String(localized: "library.log.pending.title"))
            }
        case .retryable(let message):
            Section {
                savedLogMessage(message, style: .red)
                retainedLogIntentRow
                Button {
                    Task { await viewModel.retrySavedFoodLog() }
                } label: {
                    Text(String(localized: "library.log.retry"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("library.log.retry")
            } header: {
                Text(String(localized: "library.log.saved.title"))
            }
        case .logged:
            Section {
                Label(
                    String(localized: "library.log.logged"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .accessibilityIdentifier("library.log.logged")
                Button(String(localized: "library.common.done")) {
                    dismissEnvironment()
                }
                .accessibilityIdentifier("library.editor.done")
            }
        }
    }

    @ViewBuilder
    private var retainedLogIntentRow: some View {
        if let intent = viewModel.savedLogIntent {
            Text(LibraryLogIntentFormat.summary(intent))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library.log.intent")
        }
    }

    private func savedLogMessage(_ message: String, style: Color) -> some View {
        Text(message)
            .foregroundStyle(style)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("library.log.message")
    }

    private enum ServingField {
        case unit
        case grams
    }

    private func servingBinding(
        _ serving: ServingEditorRow,
        field: ServingField
    ) -> Binding<String> {
        Binding(
            get: {
                guard let current = viewModel.servings.first(where: { $0.id == serving.id })
                else { return "" }
                return field == .unit ? current.unit : current.gramsPerUnit
            },
            set: { value in
                switch field {
                case .unit:
                    viewModel.updateServingRow(id: serving.id, unit: value)
                case .grams:
                    viewModel.updateServingRow(id: serving.id, gramsPerUnit: value)
                }
            }
        )
    }
}
