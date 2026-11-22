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

            Section {
                Button {
                    focusedField = nil
                    if let meal = viewModel.meal {
                        onEdit(meal)
                    }
                } label: {
                    Label(
                        String(localized: "meals.detail.edit"),
                        systemImage: "pencil"
                    )
                }
                .disabled(viewModel.isDeleting)
                .accessibilityIdentifier("meals.detail.edit")

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    if viewModel.isDeleting {
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
                .disabled(viewModel.isDeleting)
                .accessibilityIdentifier("meals.detail.delete")
            }
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
        .disabled(viewModel.isDeleting)
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
        .disabled(viewModel.isDeleting)
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
}
