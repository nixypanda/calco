import SwiftUI

public struct DiarySettingsView: View {
    @ObservedObject private var viewModel: DiarySettingsViewModel
    private let onClose: () -> Void

    @FocusState private var focusedField: SettingsField?

    private enum SettingsField: Hashable {
        case calories
        case protein
        case carbs
        case fat
    }

    public init(viewModel: DiarySettingsViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Form {
                goalSection
                mealSlotSection
            }
            .accessibilityIdentifier("settings.sheet")
            .navigationTitle(String(localized: "settings.title"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "settings.cancel")) {
                        requestClose()
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier("settings.cancel")
                }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "diary.editor.keyboardDone")) {
                        focusedField = nil
                    }
                    .accessibilityIdentifier("settings.keyboard.done")
                }
            }
            #endif
        }
        .interactiveDismissDisabled(viewModel.isSaving || viewModel.hasUnsavedChanges)
#if os(macOS)
        .onExitCommand {
            requestClose()
        }
#endif
        .alert(
            String(localized: "settings.discard.title"),
            isPresented: $viewModel.isDiscardConfirmationPresented
        ) {
            Button(String(localized: "settings.discard.action"), role: .destructive) {
                viewModel.confirmDiscard()
                onClose()
            }
            .accessibilityIdentifier("settings.discard.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {
                viewModel.cancelDiscard()
            }
            .accessibilityIdentifier("settings.discard.cancel")
        } message: {
            Text(String(localized: "settings.discard.message"))
        }
        .task {
            await viewModel.loadIfNeeded()
        }
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 640)
#endif
#if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
#endif
    }

    private func requestClose() {
        guard viewModel.requestDismissal() else { return }
        onClose()
    }

    @ViewBuilder
    private var goalSection: some View {
        Section {
            switch viewModel.goalState {
            case .loading:
                loadingRow(identifier: "settings.goals.loading")
            case .failed(let message):
                loadFailureRow(
                    message: message,
                    identifier: "settings.goals.error",
                    retryIdentifier: "settings.goals.retry"
                ) {
                    Task { await viewModel.retryGoals() }
                }
            case .loaded:
                goalFields
            }
        } header: {
            Text(String(localized: "settings.goals.title"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let status = viewModel.goalStatusMessage {
                    Text(status)
                        .accessibilityIdentifier("settings.goals.status")
                }
                Text(String(localized: "settings.goals.historicalNote"))
            }
        }
    }

    @ViewBuilder
    private var goalFields: some View {
        goalField(
            title: String(localized: "settings.goals.calories"),
            text: $viewModel.calorieTarget,
            field: .calories,
            identifier: "settings.goals.calories"
        )
        goalField(
            title: String(localized: "settings.goals.protein"),
            text: $viewModel.proteinTargetG,
            field: .protein,
            identifier: "settings.goals.protein"
        )
        goalField(
            title: String(localized: "settings.goals.carbs"),
            text: $viewModel.carbsTargetG,
            field: .carbs,
            identifier: "settings.goals.carbs"
        )
        goalField(
            title: String(localized: "settings.goals.fat"),
            text: $viewModel.fatTargetG,
            field: .fat,
            identifier: "settings.goals.fat"
        )

        Text(String(localized: "settings.goals.formula"))
            .font(.caption)
            .foregroundStyle(.secondary)

        if let message = viewModel.goalUnsupportedMessage {
            validationText(message, identifier: "settings.goals.unsupported")
        }
        if let message = viewModel.goalValidationMessage {
            validationText(message, identifier: "settings.goals.validationError")
        }
        if let message = viewModel.goalSaveErrorMessage {
            validationText(message, identifier: "settings.goals.error")
        }

        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { goalSaveControls }
            VStack(alignment: .leading, spacing: 8) { goalSaveControls }
        }
    }

    @ViewBuilder
    private var goalSaveControls: some View {
        if viewModel.goalNeedsDayReview {
            Button(String(localized: "settings.goals.reviewDay")) {
                focusedField = nil
                Task { await viewModel.reviewNewDayGoal() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("settings.goals.reviewDay")
        } else if viewModel.goalNeedsReconciliation {
            Button(String(localized: "settings.goals.reconcile")) {
                focusedField = nil
                Task { await viewModel.checkSavedGoal() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("settings.goals.reconcile")
        } else {
            Button {
                focusedField = nil
                Task { await viewModel.saveGoals() }
            } label: {
                saveButtonLabel(
                    title: String(localized: "settings.goals.save"),
                    saving: viewModel.goalSaveState.isSaving
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSaveGoals)
            .accessibilityIdentifier("settings.goals.save")
        }

        if viewModel.goalSaveState == .saved {
            Label(String(localized: "settings.saved"), systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings.goals.saved")
        }
    }

    private func goalField(
        title: String,
        text: Binding<String>,
        field: SettingsField,
        identifier: String
    ) -> some View {
        LabeledContent(title) {
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
                .disabled(!viewModel.canEditGoalFields)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        }
    }

    @ViewBuilder
    private var mealSlotSection: some View {
        Section {
            switch viewModel.preferencesState {
            case .loading:
                loadingRow(identifier: "settings.slots.loading")
            case .failed(let message):
                loadFailureRow(
                    message: message,
                    identifier: "settings.slots.error",
                    retryIdentifier: "settings.slots.retry"
                ) {
                    Task { await viewModel.retryPreferences() }
                }
            case .loaded:
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    Toggle(isOn: Binding(
                        get: { viewModel.selectedSlots.contains(slot) },
                        set: { viewModel.toggleSlot(slot, enabled: $0) }
                    )) {
                        Text(DiaryLabels.mealSlotName(slot))
                    }
                    .disabled(!viewModel.canEditPreferenceFields)
                    .accessibilityIdentifier("settings.slots.\(slot.rawValue)")
                }

                if let message = viewModel.preferencesValidationMessage {
                    validationText(message, identifier: "settings.slots.validationError")
                }
                if let message = viewModel.preferencesSaveErrorMessage {
                    validationText(message, identifier: "settings.slots.saveError")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { preferencesSaveControls }
                    VStack(alignment: .leading, spacing: 8) { preferencesSaveControls }
                }
            }
        } header: {
            Text(String(localized: "settings.slots.title"))
        } footer: {
            Text(String(localized: "settings.slots.description"))
        }
    }

    @ViewBuilder
    private var preferencesSaveControls: some View {
        if viewModel.preferencesNeedsReconciliation {
            Button(String(localized: "settings.slots.reconcile")) {
                Task { await viewModel.checkSavedPreferences() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("settings.slots.reconcile")
        } else {
            Button {
                Task { await viewModel.savePreferences() }
            } label: {
                saveButtonLabel(
                    title: String(localized: "settings.slots.save"),
                    saving: viewModel.preferencesSaveState.isSaving
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSavePreferences)
            .accessibilityIdentifier("settings.slots.save")
        }

        if viewModel.preferencesSaveState == .saved {
            Label(
                String(localized: "settings.saved"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.green)
            .accessibilityIdentifier("settings.slots.saved")
        }
    }

    private func loadingRow(identifier: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(String(localized: "settings.loading"))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(identifier)
    }

    private func loadFailureRow(
        message: String,
        identifier: String,
        retryIdentifier: String,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
            Button(String(localized: "diary.common.retry")) {
                retry()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(retryIdentifier)
        }
    }

    private func validationText(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func saveButtonLabel(title: String, saving: Bool) -> some View {
        HStack(spacing: 8) {
            if saving {
                ProgressView()
                    .accessibilityHidden(true)
            }
            Text(saving ? String(localized: "diary.editor.saving") : title)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
