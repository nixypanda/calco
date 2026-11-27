import ComposableArchitecture
import SwiftUI

public struct LogEditorFeatureView: View {
    @Bindable private var store: StoreOf<LogEditorFeature>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: LogFormField?

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    public init(store: StoreOf<LogEditorFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            List {
                errorSection
                headerSection
                LogFormView(
                    amount: amountBinding,
                    unit: unitBinding,
                    units: store.units,
                    mealSlot: mealSlotBinding,
                    notes: notesBinding,
                    focusedField: $focusedField,
                    validationMessage: store.validationMessage,
                    isSubmitting: !store.canEdit,
                    mealSlotIdentifier: "diary.editor.mealSlot",
                    amountIdentifier: "diary.editor.amount",
                    unitIdentifier: "diary.editor.unit",
                    validationIdentifier: "diary.editor.validation",
                    notesIdentifier: "diary.editor.notes"
                )
                if store.canEdit {
                    Section { deleteButton }
                }
            }
            actionBar
        }
        .navigationTitle(String(localized: "diary.editor.title"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button(String(localized: "diary.editor.keyboardDone")) {
                    focusedField = nil
                }
                .accessibilityIdentifier("diary.editor.keyboardDone")
            }
        }
#endif
        .confirmationDialog(
            store.deleteConfirmationMessage,
            isPresented: deleteConfirmationBinding
        ) {
            Button(String(localized: "diary.editor.delete.confirm.action"), role: .destructive) {
                Task { await store.send(.confirmDelete).finish() }
            }
            .accessibilityIdentifier("diary.editor.delete.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {
                store.send(.deleteCancelled)
            }
        }
        .task {
            await store.send(.task).finish()
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.confirmation == .delete },
            set: { presented in
                if !presented { store.send(.deleteCancelled) }
            }
        )
    }

    private var amountBinding: Binding<String> {
        Binding(
            get: { store.amount },
            set: { store.send(.amountChanged($0)) }
        )
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { store.unit },
            set: { store.send(.unitChanged($0)) }
        )
    }

    private var mealSlotBinding: Binding<MealSlot?> {
        Binding(
            get: { store.mealSlot },
            set: { store.send(.mealSlotChanged($0)) }
        )
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { store.notes },
            set: { store.send(.notesChanged($0)) }
        )
    }

    @ViewBuilder
    private var errorSection: some View {
        switch store.phase {
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .accessibilityIdentifier("diary.editor.error")
                Button(String(localized: "diary.common.retry")) {
                    store.send(.retry)
                }
                .accessibilityIdentifier("diary.editor.retry")
            }
        case .sessionExpired:
            Section {
                Label(
                    String(localized: "diary.error.sessionExpired"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(.red)
                .font(.footnote)
                .accessibilityIdentifier("diary.editor.sessionExpired")
            }
        case .saved:
            Section {
                Label(String(localized: "diary.editor.saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("diary.editor.saved")
            }
        case .deleted:
            Section {
                Label(String(localized: "diary.editor.deleted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("diary.editor.deleted")
            }
        default:
            EmptyView()
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = store.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(store.date.diaryDisplayTitle())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diary.editor.header")
        }
    }

    /// Actions live outside the scrolling form so they stay reachable with the
    /// keyboard up and at accessibility text sizes on small phones/iPads.
    /// Saving and deleting replace the actions with an explicit progress row so
    /// the operation cannot be dismissed or hidden behind a disappearing bar.
    @ViewBuilder
    private var actionBar: some View {
        if store.isBusy {
            HStack(spacing: 10) {
                ProgressView()
                Text(store.phase.busyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("diary.editor.progress")
        } else if store.canEdit {
            VStack(spacing: usesAccessibilityLayout ? 10 : 8) {
                saveButton
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diary.editor.actions")
        }
    }

    private var saveButton: some View {
        Button {
            focusedField = nil
            Task { await store.send(.saveTapped).finish() }
        } label: {
            Text(String(localized: "diary.editor.save"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canSave)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("diary.editor.save")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            focusedField = nil
            store.send(.deleteRequested)
        } label: {
            Text(String(localized: "diary.editor.delete"))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .tint(.red)
        .disabled(store.isBusy)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("diary.editor.delete")
    }
}
