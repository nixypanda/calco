import ComposableArchitecture
import SwiftUI

public struct SettingsFeatureView: View {
    @Bindable private var store: StoreOf<SettingsFeature>

    private let onSignOut: () -> Void

    @FocusState private var focusedField: SettingsField?

    private enum SettingsField: Hashable {
        case calories
        case protein
        case carbs
        case fat
    }

    public init(
        store: StoreOf<SettingsFeature>,
        onSignOut: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onSignOut = onSignOut
    }

    private var backPlacement: ToolbarItemPlacement {
#if os(iOS)
        .navigationBarLeading
#else
        .navigation
#endif
    }

    public var body: some View {
        NavigationStack {
            Form {
                goalSection
                mealSlotSection
                accountSection
            }
            .accessibilityIdentifier("settings.sheet")
            .navigationTitle(String(localized: "settings.title"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
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
        .interactiveDismissDisabled(store.isSaving || store.hasUnsavedChanges)
        .alert(
            String(localized: "settings.discard.title"),
            isPresented: discardConfirmationBinding
        ) {
            Button(String(localized: "settings.discard.action"), role: .destructive) {
                store.send(.confirmDiscard)
            }
            .accessibilityIdentifier("settings.discard.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {
                store.send(.cancelDiscard)
            }
            .accessibilityIdentifier("settings.discard.cancel")
        } message: {
            Text(String(localized: "settings.discard.message"))
        }
        .task {
            await store.send(.task).finish()
        }
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 640)
#endif
    }

    private var discardConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.confirmation == .discardPrompt },
            set: { presented in
                if !presented { store.send(.cancelDiscard) }
            }
        )
    }

    private func goalBinding(_ field: SettingsFeature.GoalField) -> Binding<String> {
        Binding(
            get: { store.goalTexts[field] },
            set: { store.send(.goalFieldChanged(field, $0)) }
        )
    }

    private func slotBinding(_ slot: MealSlot) -> Binding<Bool> {
        Binding(
            get: { store.selectedSlots.contains(slot) },
            set: { store.send(.toggleSlot(slot, $0)) }
        )
    }

    private func focusField(_ field: SettingsFeature.GoalField) -> SettingsField {
        switch field {
        case .calories: return .calories
        case .protein: return .protein
        case .carbs: return .carbs
        case .fat: return .fat
        }
    }

    @ViewBuilder
    private var goalSection: some View {
        Section {
            switch store.goalPhase {
            case .idle, .loading:
                loadingRow(identifier: "settings.goals.loading")
            case .failed(let message):
                loadFailureRow(
                    message: message,
                    identifier: "settings.goals.error",
                    retryIdentifier: "settings.goals.retry"
                ) {
                    Task { await store.send(.retryGoals).finish() }
                }
            case .loaded:
                goalFields
            }
        } header: {
            Text(String(localized: "settings.goals.title"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let status = store.goalStatusMessage {
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
            field: .calories,
            identifier: "settings.goals.calories"
        )
        goalField(
            title: String(localized: "settings.goals.protein"),
            field: .protein,
            identifier: "settings.goals.protein"
        )
        goalField(
            title: String(localized: "settings.goals.carbs"),
            field: .carbs,
            identifier: "settings.goals.carbs"
        )
        goalField(
            title: String(localized: "settings.goals.fat"),
            field: .fat,
            identifier: "settings.goals.fat"
        )

        Text(String(localized: "settings.goals.formula"))
            .font(.caption)
            .foregroundStyle(.secondary)

        if let message = store.goalUnsupportedMessage {
            validationText(message, identifier: "settings.goals.unsupported")
        }
        if let message = store.goalValidationMessage {
            validationText(message, identifier: "settings.goals.validationError")
        }
        if let message = store.goalSaveErrorMessage {
            validationText(message, identifier: "settings.goals.error")
        }

        VStack(alignment: .leading, spacing: 10) {
            goalSaveControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var goalSaveControls: some View {
        switch store.goalDayReview {
        case .required:
            Button(String(localized: "settings.goals.reviewDay")) {
                focusedField = nil
                Task { await store.send(.reviewNewDayGoal).finish() }
            }
            .buttonStyle(.bordered)
            .disabled(store.isSaving)
            .accessibilityIdentifier("settings.goals.reviewDay")
        default:
            if store.goalSave.isReconciliation {
                Button(String(localized: "settings.goals.reconcile")) {
                    focusedField = nil
                    store.send(.checkSavedGoal)
                }
                .buttonStyle(.bordered)
                .disabled(store.isSaving)
                .accessibilityIdentifier("settings.goals.reconcile")
            } else {
                Button {
                    focusedField = nil
                    Task { @MainActor in
                        // Let the focused field commit its binding before the
                        // reducer reads the typed values.
                        await store.send(.saveGoals).finish()
                    }
                } label: {
                    saveButtonLabel(
                        title: String(localized: "settings.goals.save"),
                        saving: store.goalSave == .saving
                    )
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canSaveGoals)
                .accessibilityIdentifier("settings.goals.save")
            }
        }

        if store.goalSave == .saved {
            Label(String(localized: "settings.saved"), systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("settings.goals.saved")
        }
    }

    private func goalField(
        title: String,
        field: SettingsFeature.GoalField,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: goalBinding(field))
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: focusField(field))
                .disabled(!store.canEditGoalFields)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var mealSlotSection: some View {
        Section {
            switch store.prefsPhase {
            case .idle, .loading:
                loadingRow(identifier: "settings.slots.loading")
            case .failed(let message):
                loadFailureRow(
                    message: message,
                    identifier: "settings.slots.error",
                    retryIdentifier: "settings.slots.retry"
                ) {
                    Task { await store.send(.retryPreferences).finish() }
                }
            case .loaded:
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    Toggle(isOn: slotBinding(slot)) {
                        Text(DiaryLabels.mealSlotName(slot))
                    }
                    .disabled(!store.canEditPreferenceFields)
                    .accessibilityIdentifier("settings.slots.\(slot.rawValue)")
                }

                if let message = store.preferencesValidationMessage {
                    validationText(message, identifier: "settings.slots.validationError")
                }
                if let message = store.preferencesSaveErrorMessage {
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
        if store.prefsSave.isReconciliation {
            Button(String(localized: "settings.slots.reconcile")) {
                store.send(.checkSavedPreferences)
            }
            .buttonStyle(.bordered)
            .disabled(store.isSaving)
            .accessibilityIdentifier("settings.slots.reconcile")
        } else {
            Button {
                Task { await store.send(.savePreferences).finish() }
            } label: {
                saveButtonLabel(
                    title: String(localized: "settings.slots.save"),
                    saving: store.prefsSave == .saving
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canSavePreferences)
            .accessibilityIdentifier("settings.slots.save")
        }

        if store.prefsSave == .saved {
            Label(
                String(localized: "settings.saved"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.green)
            .accessibilityIdentifier("settings.slots.saved")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Button {
                store.send(.presentAccountSettings)
            } label: {
                Label(String(localized: "apiKeys.title"), systemImage: "key")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(store.isSaving)
            .accessibilityIdentifier("settings.apiKeys.entry")

            Button(role: .destructive) {
                onSignOut()
            } label: {
                Label(String(localized: "auth.signOut"), systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("auth.signOut")
        } footer: {
            Text(String(localized: "apiKeys.description"))
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
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}
