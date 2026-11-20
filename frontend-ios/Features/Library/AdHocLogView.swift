// One-off ad-hoc log screen and the "save food and log" review flow.

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

public struct AdHocLogView: View {
    @ObservedObject private var viewModel: AdHocLogViewModel
    @Environment(\.dismiss) private var dismissEnvironment
    @FocusState private var focusedField: LogFormField?
    @State private var confirmingCancel = false

    public init(viewModel: AdHocLogViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "library.adHoc.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failedView(message)
            case .loaded:
                loadedView
            }
        }
        .navigationTitle(Text(String(localized: "library.adHoc.title")))
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
                .accessibilityIdentifier("library.adHoc.keyboard.done")
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
                .accessibilityIdentifier("library.adHoc.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    viewModel.requestReview()
                } label: {
                    if viewModel.submissionState == .submitting || viewModel.isSavingFood {
                        ProgressView()
                    } else {
                        Text(String(localized: "library.adHoc.submit"))
                    }
                }
                .disabled(!viewModel.canReview)
                .accessibilityIdentifier("library.adHoc.submit")
            }
        }
        .task {
            if case .loading = viewModel.loadState {
                await viewModel.load()
            }
        }
        .alert(item: $viewModel.pendingReview) { review in
            reviewAlert(review)
        }
        .alert(
            String(localized: "diary.editor.discard.title"),
            isPresented: $confirmingCancel
        ) {
            Button(String(localized: "diary.editor.discard.action"), role: .destructive) {
                dismissEnvironment()
            }
            Button(String(localized: "diary.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "diary.editor.discard.message"))
        }
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
                    .accessibilityIdentifier("library.adHoc.retry")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private var loadedView: some View {
        Form {
            if viewModel.savedFoodID == nil {
                detailsSection
                logFormSection
                NutrientEditorView(
                    title: String(localized: "library.adHoc.nutrients.title"),
                    help: String(localized: "library.adHoc.nutrients.help"),
                    state: viewModel.nutrientEditor,
                    isDisabled: viewModel.isFormDisabled,
                    onAmountChange: { viewModel.setNutrientAmount($0, code: $1) },
                    onAddOptional: { viewModel.addOptionalNutrient(code: $0) },
                    onRemove: { viewModel.removeNutrient(code: $0) }
                )

                if viewModel.mode == .saveAndLog {
                    portionWeightSection
                }
            }

            statusSections

            if let error = viewModel.formError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.adHoc.error")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var detailsSection: some View {
        Section {
            Picker(String(localized: "library.adHoc.mode"), selection: $viewModel.mode) {
                Text(String(localized: "library.adHoc.mode.logOnly"))
                    .tag(AdHocSaveMode.logOnly)
                Text(String(localized: "library.adHoc.mode.saveAndLog"))
                    .tag(AdHocSaveMode.saveAndLog)
            }
            .disabled(viewModel.isFormDisabled)
            .accessibilityIdentifier("library.adHoc.mode")

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.adHoc.name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(String(localized: "library.adHoc.name"), text: $viewModel.name)
                    .disabled(viewModel.isFormDisabled)
                    .accessibilityIdentifier("library.adHoc.name")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.adHoc.brand"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.editor.brand.placeholder"),
                    text: $viewModel.brand
                )
                .disabled(viewModel.isFormDisabled)
                .accessibilityIdentifier("library.adHoc.brand")
            }

            DatePicker(
                String(localized: "library.adHoc.date"),
                selection: Binding(
                    get: {
                        DiaryDateConversion.date(from: viewModel.date) ?? Date()
                    },
                    set: { viewModel.setDate($0) }
                ),
                in: ...(
                    DiaryDateConversion.date(from: viewModel.today) ?? Date()
                ),
                displayedComponents: .date
            )
            .disabled(viewModel.isFormDisabled)
            .accessibilityIdentifier("library.adHoc.date")
        } header: {
            Text(String(localized: "library.adHoc.details"))
        }
    }

    private var logFormSection: some View {
        LogFormView(
            amount: Binding(
                get: { viewModel.amount },
                set: { viewModel.amount = $0 }
            ),
            unit: Binding(
                get: { viewModel.unit },
                set: { viewModel.unit = $0 }
            ),
            units: viewModel.units,
            mealSlot: Binding(
                get: { viewModel.mealSlot },
                set: { viewModel.mealSlot = $0 }
            ),
            notes: Binding(
                get: { viewModel.notes },
                set: { viewModel.notes = $0 }
            ),
            focusedField: $focusedField,
            validationMessage: nil,
            isSubmitting: viewModel.isFormDisabled
        )
    }

    private var portionWeightSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "library.adHoc.portionWeight"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    String(localized: "library.adHoc.portionWeight"),
                    text: $viewModel.portionWeightText
                )
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
                .disabled(viewModel.isFormDisabled)
                .accessibilityIdentifier("library.adHoc.portionWeight")
            }
        } footer: {
            Text(String(localized: "library.adHoc.portionWeight.help"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        switch viewModel.savedFoodLogState {
        case .none:
            EmptyView()
        case .logging:
            Section {
                ProgressView(String(localized: "library.log.logging"))
                    .accessibilityIdentifier("library.log.logging")
            }
        case .failed(let message):
            Section {
                statusMessage(message, color: .red)
                retainedLogIntentRow
                if let foodID = viewModel.savedFoodID {
                    Text(
                        String(
                            format: String(localized: "library.log.savedFoodID"),
                            foodID
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
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
            } footer: {
                Text(String(localized: "library.log.saved.help"))
            }
        case .logged(let logID):
            Section {
                Label(
                    String(localized: "library.log.logged"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .accessibilityIdentifier("library.adHoc.logged")
                retainedLogIntentRow
                if let foodID = viewModel.savedFoodID {
                    Text(
                        String(
                            format: String(localized: "library.log.savedFoodID"),
                            foodID
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                if let logID {
                    Text(logID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(String(localized: "library.common.done")) {
                    dismissEnvironment()
                }
                .accessibilityIdentifier("library.adHoc.done")
            }
        }

        switch viewModel.submissionState {
        case .failed(let message):
            Section {
                statusMessage(message, color: .red)
            } header: {
                Text(String(localized: "library.log.failed.title"))
            }
        case .completed(let logID):
            if !viewModel.hasLoggedSavedFood {
                Section {
                    Label(
                        String(localized: "library.adHoc.logged"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("library.adHoc.logged")
                    if let logID {
                        Text(logID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button(String(localized: "library.common.done")) {
                        dismissEnvironment()
                    }
                    .accessibilityIdentifier("library.adHoc.done")
                }
            }
        case .idle, .submitting:
            EmptyView()
        }
    }

    @ViewBuilder
    private var retainedLogIntentRow: some View {
        if let intent = viewModel.savedLogIntent {
            Text(
                LibraryLogIntentFormat.summary(
                    date: intent.date,
                    mealSlot: intent.mealSlot,
                    amount: intent.amount,
                    unit: intent.unit
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("library.log.intent")
        }
    }

    private func statusMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .foregroundStyle(color)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("library.adHoc.status")
    }

    private func reviewAlert(_ review: AdHocReview) -> Alert {
        switch review.mode {
        case .logOnly:
            return Alert(
                title: Text(String(localized: "library.adHoc.review.title")),
                message: Text(
                    String(
                        format: String(localized: "library.adHoc.review.message"),
                        review.name,
                        review.amount,
                        review.unit,
                        review.date.formatted
                    )
                ),
                primaryButton: .default(
                    Text(String(localized: "library.adHoc.review.confirm"))
                ) {
                    Task { await viewModel.confirmReview(review) }
                },
                secondaryButton: .cancel(
                    Text(String(localized: "diary.common.cancel"))
                )
            )
        case .saveAndLog:
            return Alert(
                title: Text(String(localized: "library.adHoc.saveAndLogReview.title")),
                message: Text(
                    String(
                        format: String(localized: "library.adHoc.saveAndLogReview.message"),
                        review.name,
                        review.amount,
                        review.unit,
                        review.date.formatted
                    )
                ),
                primaryButton: .default(
                    Text(String(localized: "library.adHoc.saveAndLogReview.confirm"))
                ) {
                    Task { await viewModel.confirmReview(review) }
                },
                secondaryButton: .cancel(
                    Text(String(localized: "diary.common.cancel"))
                )
            )
        }
    }
}
