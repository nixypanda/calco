import SwiftUI

public struct SearchView: View {
    @ObservedObject private var viewModel: SearchViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let onOpenMeals: (() -> Void)?
    private let onOpenAssistant: ((AssistantDraftPurpose, String?) -> Void)?
    private let onDraftBarcodeWithAssistant: ((String) -> Void)?
    private let onCreateCustomFoodFromBarcode: ((String) -> Void)?

    public init(
        viewModel: SearchViewModel,
        onOpenMeals: (() -> Void)? = nil,
        onOpenAssistant: ((AssistantDraftPurpose, String?) -> Void)? = nil,
        onDraftBarcodeWithAssistant: ((String) -> Void)? = nil,
        onCreateCustomFoodFromBarcode: ((String) -> Void)? = nil
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.onOpenMeals = onOpenMeals
        self.onOpenAssistant = onOpenAssistant
        self.onDraftBarcodeWithAssistant = onDraftBarcodeWithAssistant
        self.onCreateCustomFoodFromBarcode = onCreateCustomFoodFromBarcode
    }

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    public var body: some View {
        VStack(spacing: 0) {
            scopePicker
            if viewModel.scope == .barcode {
                barcodeField
            } else {
                searchField
            }
            if !viewModel.categorySuggestions.isEmpty {
                categorySuggestions
            }
            quickAddBanner
            content
        }
        .navigationTitle(String(localized: "search.title"))
        .onAppear {
            viewModel.clearSelection()
        }
        .task {
            await viewModel.loadForAppearance()
        }
        .toolbar {
            if let onOpenMeals {
                ToolbarItem(placement: .automatic) {
                    Button {
                        onOpenMeals()
                    } label: {
                        Label(String(localized: "meals.title"), systemImage: "fork.knife")
                    }
                    .accessibilityIdentifier("search.meals")
                }
            }
            if let onOpenAssistant {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            onOpenAssistant(.customFood, nil)
                        } label: {
                            Label(
                                String(localized: "assistant.entry.customFood"),
                                systemImage: "square.and.pencil"
                            )
                        }
                        .accessibilityIdentifier("search.assistant.customFood")
                        Button {
                            onOpenAssistant(.adHocLog, nil)
                        } label: {
                            Label(
                                String(localized: "assistant.entry.adHocLog"),
                                systemImage: "fork.knife"
                            )
                        }
                        .accessibilityIdentifier("search.assistant.adHocLog")
                    } label: {
                        Label(
                            String(localized: "assistant.title"),
                            systemImage: "sparkles"
                        )
                    }
                    .accessibilityIdentifier("search.assistant")
                }
            }
            if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               viewModel.scope != .barcode {
                ToolbarItem(placement: .automatic) {
                    Button(String(localized: "search.clear")) {
                        viewModel.clearQuery()
                    }
                    .accessibilityIdentifier("search.clear")
                }
            }
            if !viewModel.batchSelection.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewModel.presentBatchReview()
                    } label: {
                        Label(
                            String(
                                format: String(localized: "search.batch.review"),
                                viewModel.batchSelection.count
                            ),
                            systemImage: "checklist"
                        )
                    }
                    .accessibilityIdentifier("search.batch.reviewButton")
                }
            }
        }
        .sheet(isPresented: batchReviewBinding) {
            batchReviewSheet
        }
    }

    @ViewBuilder
    private var scopePicker: some View {
        if usesAccessibilityLayout {
            scopePickerControl.pickerStyle(.menu)
        } else {
            scopePickerControl.pickerStyle(.segmented)
        }
    }

    private var scopePickerControl: some View {
        Picker(
            String(localized: "search.scope.label"),
            selection: Binding(
                get: { viewModel.scope },
                set: { viewModel.setScope($0) }
            )
        ) {
            ForEach(SearchScopeOption.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityIdentifier("search.scope")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "search.prompt"), text: searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .submitLabel(.search)
                .onSubmit { viewModel.submitSearch() }
                .accessibilityIdentifier("search.field")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var barcodeField: some View {
        HStack(spacing: 8) {
            Image(systemName: "barcode.viewfinder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "search.barcode.prompt"), text: barcodeText)
                .textFieldStyle(.plain)
                .font(.body.monospacedDigit())
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .lineLimit(1)
                .submitLabel(.search)
                .onSubmit { viewModel.lookupBarcode() }
                .accessibilityIdentifier("search.barcode.field")
            Button(String(localized: "search.barcode.lookup")) {
                viewModel.lookupBarcode()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.barcodeInput.isEmpty)
            .accessibilityIdentifier("search.barcode.lookupButton")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var searchText: Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { viewModel.queryChanged($0) }
        )
    }

    private var barcodeText: Binding<String> {
        Binding(
            get: { viewModel.barcodeInput },
            set: { viewModel.barcodeChanged($0) }
        )
    }

    private var categorySuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.categorySuggestions) { suggestion in
                    Button {
                        viewModel.applyCategorySuggestion(suggestion)
                    } label: {
                        Text("\(suggestion.value) (\(suggestion.count))")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("search.category.\(suggestion.value)")
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
        .accessibilityIdentifier("search.categories")
    }

    @ViewBuilder
    private var quickAddBanner: some View {
        switch viewModel.quickAddState {
        case .idle:
            EmptyView()
        case .submitting(let id):
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "search.quickAdd.saving"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("search.quickAdd.progress.\(id)")
        case .added(let name):
            HStack(spacing: 8) {
                Label(
                    String(format: String(localized: "search.quickAdd.added"), name),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)
                Spacer(minLength: 8)
                Button {
                    viewModel.dismissQuickAddMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "search.common.dismiss"))
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("search.quickAdd.added")
        case .failed(let message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    viewModel.dismissQuickAddMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "search.common.dismiss"))
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("search.quickAdd.error")
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.scope == .barcode {
            barcodeContent
        } else if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textResultsContent
        } else {
            recentsContent
        }
    }

    // MARK: - Text results

    @ViewBuilder
    private var textResultsContent: some View {
        switch viewModel.state {
        case .idle:
            recentsContent
        case .loading:
            loadingView(identifier: "search.loading")
        case .loaded(let loaded):
            resultsView(loaded.items)
        case .empty:
            emptyView
        case .failed(let message):
            errorView(message: message)
        }
    }

    private func resultsView(_ items: [FoodSearchResult]) -> some View {
        List(items) { result in
            Button {
                viewModel.selectResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let brand = result.brand, !brand.isEmpty {
                        Text(brand)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !result.categories.isEmpty {
                        Text(result.categories.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .listRowSeparator(.visible)
            .accessibilityIdentifier("search.result.\(result.id)")
        }
        .listStyle(.plain)
        .accessibilityIdentifier("search.results")
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsContent: some View {
        switch viewModel.recentsState {
        case .idle:
            idleView
        case .loading:
            loadingView(identifier: "search.recents.loading")
        case .loaded(let items):
            if items.isEmpty {
                idleView
            } else {
                recentsList(items)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "search.retry")) {
                    Task { await viewModel.loadRecents(force: true) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("search.recents.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private func recentsList(_ items: [RecentLogItem]) -> some View {
        List {
            Section {
                ForEach(items) { item in
                    recentRow(item)
                }
            } header: {
                Text(String(localized: "search.recents.title"))
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("search.recents")
    }

    private func recentRow(_ item: RecentLogItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    viewModel.toggleBatchSelection(item)
                } label: {
                    Image(
                        systemName: viewModel.isSelectedForBatch(item)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        viewModel.isSelectedForBatch(item) ? Color.accentColor : .secondary
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "search.batch.select"))
                .accessibilityValue(
                    viewModel.isSelectedForBatch(item)
                        ? String(localized: "search.batch.selected")
                        : String(localized: "search.batch.notSelected")
                )
                .accessibilityIdentifier("search.recent.select.\(item.id)")

                Button {
                    openRecent(item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let brand = item.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(
                            String(
                                format: String(localized: "search.recents.lastUsed"),
                                item.lastUsedDate.formatted
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen(item))
                .accessibilityIdentifier("search.recent.\(item.id)")
            }

            quantityChips(for: item)
        }
        .padding(.vertical, 4)
    }

    private func quantityChips(for item: RecentLogItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let quantities = item.topQuantities.isEmpty
                    ? [QuantityLogUsage(quantity: item.quantity, logCount: 1)]
                    : item.topQuantities
                ForEach(Array(quantities.enumerated()), id: \.offset) { _, usage in
                    Button {
                        viewModel.quickAdd(item, quantity: usage.quantity)
                    } label: {
                        Label(
                            usage.quantity.described,
                            systemImage: "plus"
                        )
                        .font(.caption)
                        .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "search.quickAdd.quantity"),
                            usage.quantity.described,
                            item.name
                        )
                    )
                    .accessibilityIdentifier(
                        "search.quickAdd.\(item.id).\(usage.quantity.amount).\(usage.quantity.unit)"
                    )
                }
            }
        }
    }

    private func canOpen(_ item: RecentLogItem) -> Bool {
        viewModel.canOpen(item)
    }

    private func openRecent(_ item: RecentLogItem) {
        switch item.item {
        case .product(let product):
            onSelect(productID: product.id)
        case .meal:
            viewModel.selectMeal(item)
        case .adHoc:
            break
        }
    }

    private func onSelect(productID: String) {
        viewModel.selectResult(
            FoodSearchResult(id: productID, name: productID)
        )
    }

    // MARK: - Barcode

    @ViewBuilder
    private var barcodeContent: some View {
        switch viewModel.barcodeState {
        case .idle:
            ContentUnavailableView {
                Label(
                    String(localized: "search.barcode.title"),
                    systemImage: "barcode"
                )
            } description: {
                Text(String(localized: "search.barcode.prompt"))
            }
            .accessibilityIdentifier("search.barcode.idle")
        case .loading:
            loadingView(identifier: "search.barcode.loading")
        case .found(let lookup):
            List {
                Button {
                    viewModel.openBarcodeResult()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lookup.product.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let brand = lookup.product.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(barcodeOriginText(lookup.lookup))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let barcode = lookup.product.barcode {
                            Text(barcode)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.barcode.result")
            }
            .listStyle(.plain)
        case .notFound(let message):
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label(String(localized: "search.barcode.notFoundTitle"), systemImage: "barcode")
                } description: {
                    Text(message)
                }
                if let onCreateCustomFoodFromBarcode {
                    Button {
                        onCreateCustomFoodFromBarcode(viewModel.barcodeInput)
                    } label: {
                        Label(
                            String(localized: "search.barcode.notFound.create"),
                            systemImage: "square.and.pencil"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("search.barcode.create")
                }
                if let onDraftBarcodeWithAssistant {
                    Button {
                        onDraftBarcodeWithAssistant(viewModel.barcodeInput)
                    } label: {
                        Label(
                            String(localized: "assistant.entry.barcodeCustomFood"),
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("search.barcode.assistant")
                }
            }
            .accessibilityIdentifier("search.barcode.notFound")
        case .failed(let message):
            errorView(message: message)
        }
    }

    private func barcodeOriginText(_ meta: BarcodeLookupMeta) -> String {
        switch meta.origin {
        case .local:
            return String(localized: "search.barcode.origin.local")
        case .openFoodFacts:
            return meta.note ?? String(localized: "search.barcode.origin.openFoodFacts")
        }
    }

    // MARK: - Batch review

    private var batchReviewBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isBatchReviewPresented },
            set: { if !$0 { viewModel.dismissBatchReview() } }
        )
    }

    private var batchReviewSheet: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        String(localized: "search.batch.date"),
                        value: viewModel.originDate.formatted
                    )
                    LabeledContent(
                        String(localized: "search.batch.slot"),
                        value: viewModel.originMealSlot.map(DiaryLabels.mealSlotName)
                            ?? String(localized: "diary.unslotted")
                    )
                }
                Section(String(localized: "search.batch.items")) {
                    ForEach(viewModel.batchSelection, id: \.key) { selection in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selection.item.name)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(selection.quantity.described)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                viewModel.removeBatchSelection(selection.item)
                                if viewModel.batchSelection.isEmpty {
                                    viewModel.dismissBatchReview()
                                }
                            } label: {
                                Label(
                                    String(localized: "search.batch.remove"),
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }
                if let message = viewModel.submissionMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("search.batch.error")
                    }
                }
            }
            .navigationTitle(String(localized: "search.batch.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "search.batch.cancel")) {
                        viewModel.dismissBatchReview()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "search.batch.submit")) {
                        viewModel.submitBatch()
                    }
                    .disabled(viewModel.batchSelection.isEmpty)
                    .accessibilityIdentifier("search.batch.submit")
                }
            }
        }
    }

    // MARK: - Shared states

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "search.empty.prompt"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityIdentifier("search.idle")
    }

    private func loadingView(identifier: String) -> some View {
        VStack(spacing: usesAccessibilityLayout ? 12 : 8) {
            ProgressView()
            Text(String(localized: "search.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier(identifier)
    }

    private var emptyView: some View {
        VStack(spacing: usesAccessibilityLayout ? 12 : 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "search.empty.noResults"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.empty")
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: usesAccessibilityLayout ? 16 : 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "search.retry")) {
                if viewModel.scope == .barcode {
                    viewModel.lookupBarcode()
                } else {
                    viewModel.retry()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("search.retry")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.error")
    }
}
