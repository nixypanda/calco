import SwiftUI

public struct FoodDetailView: View {
    @ObservedObject private var viewModel: FoodDetailViewModel
    @FocusState private var focusedField: LogFormField?

    public init(viewModel: FoodDetailViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "foodDetail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 16) {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "foodDetail.retry")) {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                loadedView
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) { submitBar }
            }
        }
        .navigationTitle(viewModel.food?.name ?? String(localized: "foodDetail.title"))
        .task {
            if viewModel.food == nil {
                await viewModel.load()
            }
        }
    }


    private var loadedView: some View {
        Form {
            if let food = viewModel.food {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(food.name)
                            .font(.headline)
                        if let brand = food.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !food.categories.isEmpty {
                            Text(food.categories.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            LogFormView(
                amount: amountBinding,
                unit: unitBinding,
                units: viewModel.availableUnits,
                mealSlot: mealSlotBinding,
                notes: notesBinding,
                focusedField: $focusedField,
                validationMessage: viewModel.amountValidationMessage,
                isSubmitting: viewModel.isSubmitting
            )

            if let preview = viewModel.nutritionPreview, !preview.isEmpty {
                Section {
                    ForEach(preview, id: \.code) { nutrient in
                        HStack {
                            Text(nutrient.code)
                            Spacer(minLength: 8)
                            Text("\(nutrient.amount) \(nutrient.unit)")
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text(String(localized: "foodDetail.nutritionPreview"))
                }
            }
        }
    }

    private var amountBinding: Binding<String> {
        Binding(get: { viewModel.amount }, set: { viewModel.amountChanged($0) })
    }

    private var unitBinding: Binding<String> {
        Binding(get: { viewModel.unit }, set: { viewModel.unitChanged($0) })
    }

    private var mealSlotBinding: Binding<MealSlot?> {
        Binding(get: { viewModel.mealSlot }, set: { viewModel.mealSlotChanged($0) })
    }

    private var notesBinding: Binding<String> {
        Binding(get: { viewModel.notes }, set: { viewModel.notesChanged($0) })
    }


    private var submitBar: some View {
        VStack(spacing: 8) {
            if let message = viewModel.submitErrorMessage {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("foodDetail.submit.error")
            }

            if viewModel.didSubmitSuccessfully {
                Label {
                    Text(String(localized: "foodDetail.logged"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("foodDetail.submit.success")
            } else {
                Button {
                    focusedField = nil
                    Task { await viewModel.submit() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isSubmitting {
                            ProgressView()
                                .accessibilityHidden(true)
                            Text(String(localized: "foodDetail.logging"))
                        } else {
                            Text(String(localized: "foodDetail.log"))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSubmitting)
                .accessibilityIdentifier("foodDetail.submit")
                .accessibilityLabel(viewModel.isSubmitting ? String(localized: "foodDetail.logging") : String(localized: "foodDetail.log"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
