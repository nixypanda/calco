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

    /// Compact iPhone uses the native Log Food presentation: quantity first,
    /// a live energy/macro summary, then the rest of the form. Expanded/iPad and
    /// Mac keep the long-standing detail layout and title.
    private let compactStyle: Bool

    public init(viewModel: FoodDetailViewModel, compactStyle: Bool = false) {
        self.viewModel = viewModel
        self.compactStyle = compactStyle
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
                    .safeAreaInset(edge: .bottom, spacing: 0) { submitBar }
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(compactStyle ? .inline : .large)
        #endif
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

    private var navigationTitle: String {
        if compactStyle {
            return String(localized: "foodDetail.log")
        }
        return viewModel.food?.name ?? String(localized: "foodDetail.title")
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
                    VStack(alignment: .leading, spacing: compactStyle ? 4 : 6) {
                        Text(food.name)
                            .font(compactStyle ? .title3.weight(.semibold) : .headline)
                            .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityIdentifier("foodDetail.foodName")
                }
            }

            quantitySection
            nutritionSection

            detailsSection

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
            fullNutritionSection
        }
    }

    // MARK: Quantity

    private var quantitySection: some View {
        Section {
            HStack {
                Text(String(localized: "foodDetail.amount"))
                Spacer(minLength: 12)
                TextField(String(localized: "foodDetail.amount"), text: amountBinding)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .frame(maxWidth: 110)
                    .focused($focusedField, equals: .amount)
                    .disabled(!viewModel.isFormEditable)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "foodDetail.amount"))
                    .accessibilityIdentifier("foodDetail.amount.field")
            }
            Picker(String(localized: "foodDetail.unit"), selection: unitBinding) {
                ForEach(viewModel.availableUnits, id: \.code) { unit in
                    Text(unit.name).tag(unit.code)
                }
            }
            .pickerStyle(.menu)
            .disabled(!viewModel.isFormEditable)
            .accessibilityIdentifier("foodDetail.unit.picker")
        } footer: {
            if let message = viewModel.amountValidationMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityIdentifier("foodDetail.amount.error")
            }
        }
    }

    // MARK: Live nutrition

    @ViewBuilder
    private var nutritionSection: some View {
        if let summary = makeLogNutritionSummary(from: viewModel.nutritionPreview),
           summary.hasPrimaryValues {
            Section {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.energy ?? "0")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.7)
                            .accessibilityIdentifier("foodDetail.liveNutrition.energy")
                        Text("kcal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        macroColumn(
                            title: String(localized: "meals.nutrient.protein"),
                            value: summary.protein
                        )
                        macroColumn(
                            title: String(localized: "meals.nutrient.carbs"),
                            value: summary.carbs
                        )
                        macroColumn(
                            title: String(localized: "meals.nutrient.fat"),
                            value: summary.fat
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, compactStyle ? 6 : 2)
            }
            .accessibilityIdentifier("foodDetail.liveNutrition")
        }
    }

    private func macroColumn(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "0")
                    .font(.headline)
                Text("g")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Meal, date, notes

    private var detailsSection: some View {
        Section {
            Picker(String(localized: "foodDetail.mealSlot"), selection: mealSlotBinding) {
                Text(String(localized: "foodDetail.mealSlot.none")).tag(MealSlot?.none)
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    Text(DiaryLabels.mealSlotName(slot)).tag(MealSlot?.some(slot))
                }
            }
            .disabled(!viewModel.isFormEditable)
            .accessibilityIdentifier("foodDetail.mealSlot.picker")

            LabeledContent {
                Text(viewModel.originDate.diaryDisplayTitle())
                    .foregroundStyle(.secondary)
            } label: {
                Label(String(localized: "library.adHoc.date"), systemImage: "calendar")
            }
            .accessibilityIdentifier("foodDetail.date")

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "foodDetail.notes"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "foodDetail.notes"), text: notesBinding, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($focusedField, equals: .notes)
                    .disabled(!viewModel.isFormEditable)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "foodDetail.notes"))
                    .accessibilityIdentifier("foodDetail.notes.field")
            }
        }
    }

    // MARK: Full nutrition

    @ViewBuilder
    private var fullNutritionSection: some View {
        if let preview = viewModel.nutritionPreview, !preview.isEmpty {
            Section {
                DisclosureGroup(String(localized: "foodDetail.nutritionPreview")) {
                    ForEach(preview, id: \.code) { nutrient in
                        HStack {
                            Text(logNutritionLabel(for: nutrient.code))
                            Spacer(minLength: 8)
                            Text("\(nutrient.amount) \(nutrient.unit)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .accessibilityIdentifier("foodDetail.nutritionPreview")
            }
        }
    }

    // MARK: Bindings

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

    // MARK: Bottom submit bar

    /// SwiftUI lifts this single primary action above the keyboard. Scrolling
    /// dismisses the keyboard interactively; submitting also clears focus.
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
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
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
