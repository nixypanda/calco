import ComposableArchitecture
import SwiftUI

public struct AdHocLogFeatureView: View {
    @Bindable public var store: StoreOf<AdHocLogFeature>
    public var body: some View {
        Form {
            switch store.loadPhase {
            case .loading:
                HStack {
                    ProgressView()
                    Text(String(localized: "library.adHoc.loading"))
                }
            case let .failed(message):
                Text(message).foregroundStyle(.red)
                    .accessibilityIdentifier("library.adHoc.error")
                Button(String(localized: "foodDetail.retry")) { store.send(.load) }
            case .loaded:
                formContent
            }
        }
        .navigationTitle(String(localized: "library.adHoc.title"))
        .onAppear { store.send(.load) }
        .alert(String(localized: "library.adHoc.review.title"), isPresented: .init(
            get: { store.pendingReview != nil },
            set: { if !$0 { store.send(.reviewBindingCleared) } }
        )) {
            if let review = store.pendingReview,
               let context = store.latestIssuedReviewContext,
               store.latestIssuedReviewID == review.id {
                let capturedReview = review
                let capturedContext = context
                Button(String(localized: "library.adHoc.review.confirm")) {
                    store.send(.reviewBindingCleared)
                    store.send(.reviewConfirmed(review: capturedReview, context: capturedContext))
                }
                .accessibilityIdentifier("library.adHoc.review.confirm")
                Button(String(localized: "diary.common.cancel"), role: .cancel) {
                    store.send(.reviewCancelled)
                }
            }
        } message: {
            if let review = store.pendingReview {
                Text("\(review.name) · \(review.amount) \(review.unit)")
            }
        }
        .accessibilityIdentifier("library.adHoc")
    }

    @ViewBuilder
    private var formContent: some View {
        Section {
            TextField(String(localized: "library.adHoc.name"), text: Binding(
                get: { store.name },
                set: { store.send(.nameChanged($0)) }
            ))
            .disabled(store.isFormDisabled)
            TextField(String(localized: "library.adHoc.brand"), text: Binding(
                get: { store.brand },
                set: { store.send(.brandChanged($0)) }
            ))
            .disabled(store.isFormDisabled)
            Picker(String(localized: "library.adHoc.mode"), selection: Binding(
                get: { store.mode },
                set: { store.send(.modeChanged($0)) }
            )) {
                ForEach(AdHocSaveMode.allCases, id: \.self) { mode in
                    Text(mode == .logOnly
                        ? String(localized: "library.adHoc.mode.logOnly")
                        : String(localized: "library.adHoc.mode.saveAndLog")
                    ).tag(mode)
                }
            }
            .disabled(store.isFormDisabled)
        }

        Section {
            DatePicker(
                String(localized: "library.adHoc.date"),
                selection: Binding(
                    get: { DiaryDateConversion.date(from: store.date) ?? Date() },
                    set: { store.send(.dateChanged(fromDate($0))) }
                ),
                displayedComponents: .date
            )
            .disabled(store.isFormDisabled)
            Picker(String(localized: "library.adHoc.slot"), selection: Binding(
                get: { store.mealSlot },
                set: { store.send(.mealSlotChanged($0)) }
            )) {
                Text(String(localized: "foodDetail.mealSlot.none")).tag(MealSlot?.none)
                ForEach([MealSlot.breakfast, .lunch, .dinner, .snack, .lateNightSnack], id: \.self) { slot in
                    Text(DiaryLabels.mealSlotName(slot)).tag(MealSlot?.some(slot))
                }
            }
            .disabled(store.isFormDisabled)
        }

        Section {
            TextField(String(localized: "library.adHoc.amount"), text: Binding(
                get: { store.amount },
                set: { store.send(.amountChanged($0)) }
            ))
            .keyboardType(.decimalPad)
            .disabled(store.isFormDisabled)
            Picker(String(localized: "library.adHoc.unit"), selection: Binding(
                get: { store.unit },
                set: { store.send(.unitChanged($0)) }
            )) {
                ForEach(store.units) { unit in
                    Text(unit.name).tag(unit.code)
                }
            }
            .disabled(store.isFormDisabled)
            TextField(String(localized: "library.adHoc.portionWeight"), text: Binding(
                get: { store.portionWeightText },
                set: { store.send(.portionWeightChanged($0)) }
            ))
            .keyboardType(.decimalPad)
            .disabled(store.isFormDisabled)
            TextField(String(localized: "library.adHoc.notes"), text: Binding(
                get: { store.notes },
                set: { store.send(.notesChanged($0)) }
            ))
            .disabled(store.isFormDisabled)
        }

        NutrientEditorView(
            title: String(localized: "library.adHoc.nutrients"),
            state: store.nutrientEditor,
            isDisabled: store.isFormDisabled,
            onAmountChange: { code, amount in
                store.send(.nutrientAmountChanged(code: code, amount: amount))
            },
            onAddOptional: { store.send(.nutrientAdded(code: $0)) },
            onRemove: { store.send(.nutrientRemoved(code: $0)) }
        )

        Section {
            if let error = store.formError {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("library.adHoc.formError")
            }
            if let id = store.savedFoodID {
                Text(String(format: String(localized: "library.adHoc.savedFood"), id))
            }
            if case let .failed(message) = store.savedFoodLogState {
                Text(message).foregroundStyle(.orange)
                Button(String(localized: "library.adHoc.retry")) {
                    store.send(.retrySavedFoodLog)
                }
                .accessibilityIdentifier("library.adHoc.retry")
            }
            if case let .completed(logID) = store.submissionState {
                Text(String(format: String(localized: "library.adHoc.logged"), logID ?? ""))
                    .accessibilityIdentifier("library.adHoc.logged")
            }
            Button(String(localized: "library.adHoc.review")) {
                store.send(.reviewRequested)
            }
            .disabled(!store.canReview)
            .accessibilityIdentifier("library.adHoc.review")
        }
    }

    private func fromDate(_ date: Date) -> LocalDiaryDate {
        DiaryDateConversion.day(from: date) ?? store.date
    }
}
