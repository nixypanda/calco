import SwiftUI

private enum FoodDetailConfirmation: Identifiable {
    case newSubmission(PendingLogSubmission)
    case discard(PendingLogSubmission)

    var id: String {
        switch self {
        case .newSubmission(let entry): return "new-\(entry.id)"
        case .discard(let entry): return "discard-\(entry.id)"
        }
    }
}

public struct FoodDetailView: View {
    @ObservedObject private var viewModel: FoodDetailViewModel
    @FocusState private var focusedField: LogFormField?
    @State private var confirmation: FoodDetailConfirmation?

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
                failedView(message)
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
            } else {
                viewModel.refreshRecoveryEntries()
            }
        }
        .alert(item: $confirmation) { confirmation in
            switch confirmation {
            case .newSubmission:
                return Alert(
                    title: Text(String(localized: "foodDetail.pending.newSubmission.confirmTitle")),
                    message: Text(String(localized: "foodDetail.pending.newSubmission.confirmMessage")),
                    primaryButton: .destructive(
                        Text(String(localized: "foodDetail.pending.newSubmission.confirmAction"))
                    ) {
                        Task { await viewModel.confirmCreateNewSubmission() }
                    },
                    secondaryButton: .cancel(
                        Text(String(localized: "foodDetail.pending.cancel"))
                    )
                )
            case .discard:
                return Alert(
                    title: Text(String(localized: "foodDetail.pending.discard.confirmTitle")),
                    message: Text(String(localized: "foodDetail.pending.discard.confirmMessage")),
                    primaryButton: .destructive(
                        Text(String(localized: "foodDetail.pending.discard.confirmAction"))
                    ) {
                        if case .discard(let entry) = confirmation {
                            viewModel.discardPending(entry)
                        }
                    },
                    secondaryButton: .cancel(
                        Text(String(localized: "foodDetail.pending.cancel"))
                    )
                )
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "foodDetail.retry")) {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // A food fetch failure must not strand an unresolved submission.
            pendingRecoverySections
        }
    }

    @ViewBuilder
    private func pendingRecoveryRow(
        _ pending: PendingLogSubmission
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(String(localized: "foodDetail.pending.title"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(pending.draft.amount) \(pending.draft.unit)")
                Text(pending.draft.date.formatted)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            if pending.state == .conflicted {
                Text(String(localized: "foodDetail.pending.conflicted"))
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                Button(role: .destructive) {
                    confirmation = .discard(pending)
                } label: {
                    Text(String(localized: "foodDetail.pending.discard"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("foodDetail.pending.discard")
            } else {
                Button {
                    Task { await viewModel.retryPending(pending) }
                } label: {
                    Text(String(localized: "foodDetail.pending.retry"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("foodDetail.pending.retry")
            }

            HStack {
                Button(String(localized: "foodDetail.pending.checkDiary")) {
                    viewModel.checkDiary()
                }
                .accessibilityIdentifier("foodDetail.pending.checkDiary")

                Spacer()

                Button(String(localized: "foodDetail.pending.later")) {
                    viewModel.dismissPendingNotice()
                }
                .accessibilityIdentifier("foodDetail.pending.later")
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private var pendingRecoverySections: some View {
        if !viewModel.visiblePendingSubmissions.isEmpty {
            Section {
                ForEach(viewModel.visiblePendingSubmissions) { pending in
                    pendingRecoveryRow(pending)
                }
            } header: {
                Text(String(localized: "foodDetail.pending.recoveryTitle"))
            }
            .accessibilityIdentifier("foodDetail.pending.notice")
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
                // Once logged, this form's draft is final. Reusing the form
                // would invite editing a submission that already succeeded.
                isSubmitting: !viewModel.isFormEditable
            )

            if let notice = viewModel.lastUsedNotice {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            viewModel.dismissLastUsedNotice()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "diary.common.dismiss"))
                    }
                    .accessibilityIdentifier("foodDetail.lastUsed.notice")
                }
            }

            pendingRecoverySections

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
            if let pending = viewModel.newSubmissionConfirmation {
                HStack(spacing: 8) {
                    if pending.state != .conflicted {
                        Button(String(localized: "foodDetail.pending.retry")) {
                            Task { await viewModel.retryPending(pending) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isBusy)
                        .accessibilityIdentifier("foodDetail.pending.resolve.retry")
                    }

                    Button(role: .destructive) {
                        confirmation = .newSubmission(pending)
                    } label: {
                        Text(String(localized: "foodDetail.pending.newSubmission"))
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy)
                    .accessibilityIdentifier("foodDetail.pending.resolve.new")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = viewModel.submitWarningMessage {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("foodDetail.submit.warning")
            }

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
                        if viewModel.isBusy {
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
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier("foodDetail.submit")
                .accessibilityLabel(viewModel.isBusy ? String(localized: "foodDetail.logging") : String(localized: "foodDetail.log"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
