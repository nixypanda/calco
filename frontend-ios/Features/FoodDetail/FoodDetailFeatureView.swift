
import ComposableArchitecture
import SwiftUI

public struct FoodDetailFeatureView: View {
    @Bindable public var store: StoreOf<FoodDetailFeature>
    @FocusState private var focusedField: LogFormField?
    @State private var discardCandidateID: String?

    public init(store: StoreOf<FoodDetailFeature>) {
        self.store = store
    }

    public var body: some View {
        Form {
            switch store.load {
            case .loading:
                HStack {
                    ProgressView()
                    Text("foodDetail.loading")
                }
                .accessibilityIdentifier("foodDetail.loading")
            case let .failed(message):
                Section {
                    Text(message).foregroundStyle(.red)
                    Button(String(localized: "foodDetail.retry")) { store.send(.load) }
                        .accessibilityIdentifier("foodDetail.retry")
                }
            case .loaded:
                content
            }
        }
        .navigationTitle(store.displayName)
        .onAppear { store.send(.load) }
        .alert(String(localized: "foodDetail.pending.discard.title"), isPresented: .init(
            get: { discardCandidateID != nil },
            set: { if !$0 { discardCandidateID = nil } }
        )) {
            Button(String(localized: "foodDetail.pending.discard.action"), role: .destructive) {
                if let id = discardCandidateID { store.send(.discardPending(id: id)) }
                discardCandidateID = nil
            }
            Button(String(localized: "diary.common.cancel"), role: .cancel) { discardCandidateID = nil }
        }
        .alert(String(localized: "foodDetail.pending.resolve.title"), isPresented: .init(
            get: { store.requiresNewSubmissionConfirmation },
            set: { if !$0 { store.send(.dismissPendingNotice) } }
        )) {
            Button(String(localized: "foodDetail.pending.resolve.retry")) {
                if let id = store.newSubmissionConfirmationID {
                    store.send(.retryPending(id: id))
                }
            }
            .accessibilityIdentifier("foodDetail.pending.resolve.retry")
            Button(String(localized: "foodDetail.pending.resolve.new")) {
                store.send(.submitConfirmedNew)
            }
            .accessibilityIdentifier("foodDetail.pending.resolve.new")
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.visiblePending.isEmpty && !store.hidesPendingNotice {
            recoverySection
        }
        if let notice = store.lastUsedNotice {
            Section {
                HStack {
                    Text(notice)
                    Spacer()
                    Button(String(localized: "diary.common.dismiss")) {
                        store.send(.dismissLastUsedNotice)
                    }
                }
            }
            .accessibilityIdentifier("foodDetail.lastUsed.notice")
        }

        Section {
            LogFormView(
                amount: Binding(
                    get: { store.amount },
                    set: { store.send(.amountChanged($0)) }
                ),
                unit: Binding(
                    get: { store.unit },
                    set: { store.send(.unitChanged($0)) }
                ),
                units: store.availableUnits,
                mealSlot: Binding(
                    get: { store.mealSlot },
                    set: { store.send(.mealSlotChanged($0)) }
                ),
                notes: Binding(
                    get: { store.notes },
                    set: { store.send(.notesChanged($0)) }
                ),
                focusedField: $focusedField,
                validationMessage: store.amountValidationMessage,
                isSubmitting: store.isSubmitting
            )
            .disabled(!store.isFormEditable)
        } header: {
            Text(String(localized: "foodDetail.log.section"))
        }

        Section {
            Text(store.originDate.diaryDisplayTitle())
        } header: {
            Text(String(localized: "foodDetail.date"))
        }
        .accessibilityIdentifier("foodDetail.date")

        if let summary = makeLogNutritionSummary(from: store.nutritionPreview) {
            Section {
                liveNutrition(summary)
            } header: {
                Text(String(localized: "foodDetail.nutrition.live"))
            }
            .accessibilityIdentifier("foodDetail.liveNutrition")
        }

        if let preview = store.nutritionPreview, !preview.isEmpty {
            Section {
                NutritionTable(rows: preview.map {
                    NutritionTableRow(
                        id: $0.code,
                        name: logNutritionLabel(for: $0.code),
                        amount: $0.amount,
                        unit: $0.unit
                    )
                })
            } header: {
                Text(String(localized: "foodDetail.nutritionPreview"))
            }
            .accessibilityIdentifier("foodDetail.nutritionPreview")
        }

        Section {
            if let message = store.submitWarningMessage {
                Text(message)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("foodDetail.submit.warning")
            }
            if let message = store.submitErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("foodDetail.submit.error")
            }
            if store.didSubmitSuccessfully {
                Text(String(localized: "foodDetail.submit.success"))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("foodDetail.submit.success")
            }
            Button {
                store.send(.submit)
            } label: {
                if store.isBusy {
                    ProgressView()
                } else {
                    Text(String(localized: "foodDetail.log"))
                }
            }
            .disabled(store.isBusy || !store.isFormEditable)
            .accessibilityIdentifier("foodDetail.submit")
            .accessibilityLabel(
                store.isBusy
                    ? String(localized: "foodDetail.logging")
                    : String(localized: "foodDetail.log")
            )
        }
    }

    private var recoverySection: some View {
        Section {
            ForEach(store.visiblePending) { pending in
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.foodName)
                    Text(pending.lastMessage ?? pending.state.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "foodDetail.pending.retry")) {
                            store.send(.retryPending(id: pending.id))
                        }
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("foodDetail.pending.retry")
                        Button(String(localized: "foodDetail.pending.checkDiary")) {
                            store.send(.checkDiary)
                        }
                        .accessibilityIdentifier("foodDetail.pending.checkDiary")
                        if pending.state == .conflicted {
                            Button(String(localized: "foodDetail.pending.discard"), role: .destructive) {
                                discardCandidateID = pending.id
                            }
                            .disabled(store.isBusy)
                            .accessibilityIdentifier("foodDetail.pending.discard")
                        }
                    }
                }
            }
            Button(String(localized: "foodDetail.pending.later")) {
                store.send(.dismissPendingNotice)
            }
            .accessibilityIdentifier("foodDetail.pending.later")
        } header: {
            Text(String(localized: "foodDetail.pending.notice"))
        }
        .accessibilityIdentifier("foodDetail.pending.notice")
    }

    @ViewBuilder
    private func liveNutrition(_ summary: LogNutritionSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach([
                (String(localized: "meals.nutrient.energy"), summary.energyDisplay),
                (String(localized: "meals.nutrient.protein"), summary.proteinDisplay),
                (String(localized: "meals.nutrient.carbs"), summary.carbsDisplay),
                (String(localized: "meals.nutrient.fat"), summary.fatDisplay),
            ], id: \.0) { row in
                GridRow {
                    Text(row.0)
                    Text(row.1).monospacedDigit().gridColumnAlignment(.trailing)
                }
            }
        }
        .accessibilityIdentifier("foodDetail.liveNutrition.values")
    }
}
