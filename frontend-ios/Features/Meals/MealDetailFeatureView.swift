
import ComposableArchitecture
import SwiftUI

public struct MealDetailFeatureView: View {
    @Bindable private var store: StoreOf<MealDetailFeature>
    @FocusState private var focusedField: LogFormField?
    @State private var confirmDelete = false
    @State private var isLoggingPresented = false

    public init(store: StoreOf<MealDetailFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.loadState {
            case .loading:
                ProgressView(String(localized: "meals.detail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(message: let message, missingComponents: let missingComponents):
                failedView(message: message, missingComponents: missingComponents)
            case .loaded:
                loadedView
                    .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle(store.displayName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            if let meal = store.meal {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "meals.detail.edit")) {
                        store.send(.editTapped(meal))
                    }
                    .disabled(store.isDeleting || store.isLogging)
                    .accessibilityIdentifier("meals.detail.edit")
                }
            }
            if focusedField != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "meals.detail.keyboardDone")) {
                        focusedField = nil
                    }
                    .accessibilityIdentifier("meals.detail.keyboardDone")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.supportsLogging, store.meal?.isDegraded == false {
                Button {
                    store.send(.dismissLogResult)
                    isLoggingPresented = true
                } label: {
                    Text(String(localized: "meals.detail.log"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canLog)
                .accessibilityIdentifier("meals.detail.openLog")
                .padding()
                .background(.bar)
            }
        }
        .sheet(isPresented: $isLoggingPresented) {
            MealLogFeatureView(store: store)
        }
        .task { store.send(.loadIfNeeded) }
        .alert(
            String(localized: "meals.detail.delete.confirmTitle"),
            isPresented: $confirmDelete
        ) {
            Button(role: .destructive) {
                store.send(.confirmDelete)
            } label: {
                Text(String(localized: "meals.detail.delete.confirmAction"))
            }
            Button(role: .cancel) {} label: {
                Text(String(localized: "meals.editor.cancel"))
            }
        } message: {
            Text(String(localized: "meals.detail.delete.confirmMessage"))
        }
    }

    private func failedView(message: String, missingComponents: Bool) -> some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Label {
                        Text(
                            missingComponents
                                ? String(localized: "meals.detail.error.missingComponents")
                                : message
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                    Button {
                        store.send(.retryLoad)
                    } label: {
                        Text(String(localized: "meals.detail.retry"))
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("meals.detail.retry")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("meals.detail.error")

            Section {
                deleteButton
                if let message = store.deleteErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("meals.detail.delete.error")
                }
            } footer: {
                Text(String(localized: "meals.detail.delete.snapshotNote"))
                    .font(.footnote)
            }
        }
    }

    private var loadedView: some View {
        Form {
            if let meal = store.meal {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meal.name)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let notes = meal.trimmedNotes {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let total = MealNutrientDisplay.quantity(meal.totalQuantity) {
                        LabeledContent(
                            String(localized: "meals.detail.total"),
                            value: total
                        )
                    }
                } header: {
                    Text(String(localized: "meals.detail.recipe"))
                }

                Section {
                    ForEach(meal.components) { component in
                        componentRow(component)
                    }
                    if let message = store.missingComponentsMessage {
                        Label {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("meals.detail.missing")
                    }
                } header: {
                    Text(String(localized: "meals.detail.components"))
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    if store.isDeleting {
                        HStack {
                            ProgressView()
                            Text(String(localized: "meals.detail.delete.deleting"))
                        }
                    } else {
                        Label(
                            String(localized: "meals.detail.delete"),
                            systemImage: "trash"
                        )
                    }
                }
                .disabled(store.isDeleting)
                .accessibilityIdentifier("meals.detail.delete")
            }
        }
        .accessibilityIdentifier("meals.detail")
    }

    private func componentRow(_ component: MealComponent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.withState { $0.componentName(component) })
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if component.missing {
                    Label(
                        String(localized: "meals.detail.missingBadge"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Text(
                    MealNutrientDisplay.quantity(component.quantity)
                        ?? String(localized: "meals.detail.unknownQuantity")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let kcal = MealNutrientDisplay.kcal(component.nutritionSummary) {
                Text(kcal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meals.detail.component.\(component.id)")
        .accessibilityLabel(
            [
                store.withState { $0.componentName(component) },
                MealNutrientDisplay.quantity(component.quantity),
                MealNutrientDisplay.kcal(component.nutritionSummary),
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            if store.isDeleting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "meals.detail.delete.deleting"))
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(String(localized: "meals.detail.delete"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(store.isDeleting)
        .accessibilityIdentifier("meals.detail.delete")
    }
}

/// Logging is a temporary task over the recipe page, not another browsing page.
public struct MealLogFeatureView: View {
    @Bindable private var store: StoreOf<MealDetailFeature>
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: LogFormField?

    public init(store: StoreOf<MealDetailFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(store.displayName).font(.headline)
                    LabeledContent(
                        String(localized: "library.adHoc.date"),
                        value: store.context.date.diaryDisplayTitle()
                    )
                    if case .failed(message: let message, missingComponents: _) = store.loadState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button(String(localized: "diary.common.retry")) {
                            store.send(.retryLoad)
                        }
                    }
                }
                LogFormView(
                    amount: amountBinding,
                    unit: unitBinding,
                    units: store.logFormUnits,
                    mealSlot: mealSlotBinding,
                    notes: notesBinding,
                    focusedField: $focusedField,
                    validationMessage: store.amountValidationMessage,
                    isSubmitting: store.isLogging
                )
                previewSection
                if let notice = store.portionFallbackNotice ?? store.unitFallbackNotice {
                    Section { Label(notice, systemImage: "info.circle") }
                }
                if let error = store.logErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("meals.detail.log.error")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(String(localized: "meals.detail.log"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "diary.common.cancel")) { dismiss() }
                        .disabled(store.isLogging)
                        .accessibilityIdentifier("meals.log.cancel")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    focusedField = nil
                    store.send(.logMeal)
                } label: {
                    HStack {
                        if store.isLogging { ProgressView() }
                        Text(String(localized: "meals.detail.log"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canLog || store.amountValidationMessage != nil)
                .accessibilityIdentifier("meals.detail.log")
                .padding()
                .background(.bar)
            }
            .interactiveDismissDisabled(store.isLogging)
            .task { store.send(.loadIfNeeded) }
            .onChange(of: store.didLog) { _, didLog in
                if didLog { dismiss() }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("meals.log.sheet")
    }

    private var previewSection: some View {
        Section {
            switch store.previewState {
            case .idle, .loading:
                ProgressView()
            case .loaded(let response):
                NutritionTable(rows: response.nutrients.map {
                    NutritionTableRow(id: $0.code, name: MealNutrientDisplay.label(for: $0.code),
                                      amount: $0.amount, unit: $0.unit)
                })
            case .failed(let message), .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
                Button(String(localized: "diary.common.retry")) {
                    store.send(.refreshPreview)
                }
            }
        } header: {
            Text(String(localized: "foodDetail.nutritionPreview"))
        }
    }

    private var amountBinding: Binding<String> {
        Binding(get: { store.portionAmount },
                set: { store.send(.portionAmountChanged($0)) })
    }

    private var unitBinding: Binding<String> {
        Binding(get: { store.portionUnit },
                set: { store.send(.portionUnitChanged($0)) })
    }

    private var mealSlotBinding: Binding<MealSlot?> {
        Binding(get: { store.mealSlot },
                set: { store.send(.mealSlotChanged($0)) })
    }

    private var notesBinding: Binding<String> {
        Binding(get: { store.logNotes },
                set: { store.send(.logNotesChanged($0)) })
    }
}
