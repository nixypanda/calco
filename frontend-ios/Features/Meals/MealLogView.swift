import SwiftUI

/// Logging is a temporary task over the recipe page, not another browsing page.
struct MealLogView: View {
    @ObservedObject var viewModel: MealDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: LogFormField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(viewModel.displayName).font(.headline)
                    LabeledContent(String(localized: "library.adHoc.date"),
                                   value: viewModel.date.diaryDisplayTitle())
                    if case .failed(let message, _) = viewModel.loadState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button(String(localized: "diary.common.retry")) {
                            Task { await viewModel.retryLoad() }
                        }
                    }
                }
                LogFormView(
                    amount: $viewModel.portionAmount,
                    unit: $viewModel.portionUnit,
                    units: viewModel.logFormUnits,
                    mealSlot: $viewModel.mealSlot,
                    notes: $viewModel.logNotes,
                    focusedField: $focusedField,
                    validationMessage: viewModel.amountValidationMessage,
                    isSubmitting: viewModel.isLogging
                )
                previewSection
                if let notice = viewModel.portionFallbackNotice ?? viewModel.unitFallbackNotice {
                    Section { Label(notice, systemImage: "info.circle") }
                }
                if let error = viewModel.logErrorMessage {
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
                        .disabled(viewModel.isLogging)
                        .accessibilityIdentifier("meals.log.cancel")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    focusedField = nil
                    viewModel.logMeal()
                } label: {
                    HStack {
                        if viewModel.isLogging { ProgressView() }
                        Text(String(localized: "meals.detail.log"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canLog || viewModel.amountValidationMessage != nil)
                .accessibilityIdentifier("meals.detail.log")
                .padding()
                .background(.bar)
            }
            .interactiveDismissDisabled(viewModel.isLogging)
            .task { await viewModel.loadIfNeeded() }
            .onChange(of: viewModel.didLog) { _, didLog in
                if didLog { dismiss() }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("meals.log.sheet")
    }

    private var previewSection: some View {
        Section {
            switch viewModel.previewState {
            case .idle, .loading:
                ProgressView()
            case .loaded(let response):
                NutritionTable(rows: response.nutrients.map {
                    NutritionTableRow(id: $0.code, name: MealNutrientDisplay.label(for: $0.code),
                                      amount: $0.amount, unit: $0.unit)
                })
            case .failed(let message), .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
                Button(String(localized: "diary.common.retry")) { viewModel.refreshPreview() }
            }
        } header: {
            Text(String(localized: "foodDetail.nutritionPreview"))
        }
    }
}

/// Route-owned model for logging a recent meal without opening a recipe browser.
struct MealLogTaskHost: View {
    @StateObject private var viewModel: MealDetailViewModel

    init(mealID: String, date: LocalDiaryDate, mealSlot: MealSlot?,
         initialPortion: NutritionQuantity?, service: MealsServicing,
         onSubmitDrafts: LogSubmissionHandler?, onSessionExpired: @escaping () -> Void,
         onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void) {
        _viewModel = StateObject(wrappedValue: MealDetailViewModel(
            mealID: mealID, date: date, mealSlot: mealSlot, initialPortion: initialPortion,
            service: service, onSubmitDrafts: onSubmitDrafts,
            onSessionExpired: onSessionExpired, onLogged: onLogged
        ))
    }

    var body: some View { MealLogView(viewModel: viewModel) }
}
