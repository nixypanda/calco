// Meal detail: recipe contents, server-calculated portion nutrition, logging,
// editing, and confirmed deletion.

import SwiftUI

public struct MealDetailView: View {
    @ObservedObject private var viewModel: MealDetailViewModel
    private let onEdit: (Meal) -> Void
    @FocusState private var focusedField: LogFormField?
    @State private var confirmDelete = false

    public init(
        viewModel: MealDetailViewModel,
        onEdit: @escaping (Meal) -> Void
    ) {
        self.viewModel = viewModel
        self.onEdit = onEdit
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView(String(localized: "meals.detail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message, let missingComponents):
                failedView(
                    message: message,
                    missingComponents: missingComponents
                )
            case .loaded:
                loadedView
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) { actionBar }
            }
        }
        .navigationTitle(viewModel.displayName)
        .toolbar {
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
        .task {
            await viewModel.loadIfNeeded()
        }
        .alert(
            String(localized: "meals.detail.delete.confirmTitle"),
            isPresented: $confirmDelete
        ) {
            Button(role: .destructive) {
                Task { await viewModel.deleteMeal() }
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
                        Task { await viewModel.retryLoad() }
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
                if let message = viewModel.deleteErrorMessage {
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
            if let meal = viewModel.meal {
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
                    if let message = viewModel.missingComponentsMessage {
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

            LogFormView(
                amount: portionAmountBinding,
                unit: portionUnitBinding,
                units: viewModel.logFormUnits,
                mealSlot: mealSlotBinding,
                notes: logNotesBinding,
                focusedField: $focusedField,
                validationMessage: viewModel.amountValidationMessage,
                isSubmitting: viewModel.isLogging
            )

            if let notice = viewModel.unitFallbackNotice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let notice = viewModel.portionFallbackNotice {
                Section {
                    Label {
                        Text(notice)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("meals.detail.portionFallback")
            }

            previewSection
        }
        .accessibilityIdentifier("meals.detail")
    }

    private func componentRow(_ component: MealComponent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.componentName(component))
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
                viewModel.componentName(component),
                MealNutrientDisplay.quantity(component.quantity),
                MealNutrientDisplay.kcal(component.nutritionSummary),
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            switch viewModel.previewState {
            case .idle:
                Text(String(localized: "meals.detail.preview.prompt"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meals.detail.preview.idle")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "meals.detail.preview.loading"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meals.detail.preview.loading")
                }
            case .loaded(let nutrition):
                if nutrition.nutrients.isEmpty {
                    Text(String(localized: "meals.detail.preview.empty"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meals.detail.preview.empty")
                } else {
                    if let quantity = MealNutrientDisplay.quantity(nutrition.quantity) {
                        // The stable success marker lives on a real, hittable
                        // row. A Section-level identifier is not exposed by
                        // this Form on iOS 26, and the header alone would be
                        // visible before any server preview arrived.
                        Text(quantity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("meals.detail.preview")
                            .accessibilityLabel(quantity)
                    }
                    ForEach(nutrition.nutrients, id: \.code) { nutrient in
                        HStack {
                            Text(MealNutrientDisplay.label(for: nutrient.code))
                            Spacer(minLength: 8)
                            Text(MealNutrientDisplay.value(nutrient))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(
                            "meals.detail.preview.nutrient.\(nutrient.code)"
                        )
                    }
                }
            case .unavailable(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meals.detail.preview.unavailable")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("meals.detail.preview.error")
                    Button(String(localized: "meals.detail.preview.retry")) {
                        viewModel.refreshPreview()
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("meals.detail.preview.retry")
                }
            }
        } header: {
            Text(String(localized: "meals.detail.preview"))
                .accessibilityIdentifier("meals.detail.preview.header")
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let meal = viewModel.meal {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        editButton(meal)
                        deleteButton
                    }
                    VStack(spacing: 8) {
                        editButton(meal)
                        deleteButton
                    }
                }
            }

            if let message = viewModel.deleteErrorMessage {
                inlineMessage(message, systemImage: "trash", color: .red)
                    .accessibilityIdentifier("meals.detail.delete.error")
            }

            if let message = viewModel.logErrorMessage {
                inlineMessage(message, systemImage: "exclamationmark.triangle.fill", color: .red)
                    .accessibilityIdentifier("meals.detail.log.error")
            }

            if viewModel.didLog {
                Label {
                    Text(String(localized: "meals.detail.logged"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("meals.detail.log.success")
            }

            if viewModel.canLog {
                Button {
                    focusedField = nil
                    viewModel.logMeal()
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isLogging {
                            ProgressView()
                                .accessibilityHidden(true)
                            Text(String(localized: "meals.detail.logging"))
                        } else {
                            Text(String(localized: "meals.detail.log"))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.isLogging
                        || viewModel.isDeleting
                        || viewModel.amountValidationMessage != nil
                )
                .accessibilityIdentifier("meals.detail.log")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func editButton(_ meal: Meal) -> some View {
        Button {
            focusedField = nil
            onEdit(meal)
        } label: {
            Text(String(localized: "meals.detail.edit"))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isLogging || viewModel.isDeleting)
        .accessibilityIdentifier("meals.detail.edit")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            if viewModel.isDeleting {
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
        .disabled(viewModel.isDeleting || viewModel.isLogging)
        .accessibilityIdentifier("meals.detail.delete")
    }

    private func inlineMessage(
        _ message: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portionAmountBinding: Binding<String> {
        Binding(
            get: { viewModel.portionAmount },
            set: { viewModel.portionAmountChanged($0) }
        )
    }

    private var portionUnitBinding: Binding<String> {
        Binding(
            get: { viewModel.portionUnit },
            set: { viewModel.portionUnitChanged($0) }
        )
    }

    private var mealSlotBinding: Binding<MealSlot?> {
        Binding(
            get: { viewModel.mealSlot },
            set: { viewModel.mealSlotChanged($0) }
        )
    }

    private var logNotesBinding: Binding<String> {
        Binding(
            get: { viewModel.logNotes },
            set: { viewModel.logNotesChanged($0) }
        )
    }
}
