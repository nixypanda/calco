import SwiftUI

public struct SearchView: View {
    @ObservedObject private var viewModel: SearchViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var creationDestination: FoodCreationDestination?
    private let creationContextProvider: (() -> FoodCreationContext)?

    private let onOpenMeals: (() -> Void)?
    /// When the shared screen is the Search tab root, food/custom/barcode
    /// results are pushed onto that tab's own native detail stack. The Diary
    /// Add Food push leaves this nil and keeps the existing Diary-stack route.
    private let onSelectFoodID: ((String) -> Void)?

    /// One shared screen for both the Search tab and the Diary Add Food push.
    /// Navigation is owned by whichever stack hosts it: the system Back button
    /// returns to Diary from the push, and the tab bar handles the Search tab.
    /// There is no Add Food header and no Cancel control, so there is never a
    /// duplicate Back. The host keeps the selected diary date/meal context on
    /// the shared view model.
    public init(
        viewModel: SearchViewModel,
        onOpenMeals: (() -> Void)? = nil,
        onSelectFoodID: ((String) -> Void)? = nil,
        creationContextProvider: (() -> FoodCreationContext)? = nil
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.onOpenMeals = onOpenMeals
        self.onSelectFoodID = onSelectFoodID
        self.creationContextProvider = creationContextProvider
    }

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The three product-backed scopes used by the contextual Diary flow. The
    /// product has no favorites backend, so the middle scope is the real
    /// custom-food scope rather than an invented saved-favorites feature.
    public static var contextualScopes: [SearchScopeOption] {
        [.history, .custom, .all]
    }

    /// Both preexisting assistant purposes stay reachable from the single
    /// shared search screen through one native toolbar Menu.
    public static var compactAssistantPurposes: [AssistantDraftPurpose] {
        [.customFood, .adHocLog]
    }

    public var contextSubtitle: String {
        let date = viewModel.originDate.diaryDisplayTitle()
        guard let slot = viewModel.originMealSlot else { return date }
        return "\(date) · \(DiaryLabels.mealSlotName(slot))"
    }

    public var body: some View {
        // One scroll container owns the whole screen. The search box and scope
        // tabs are ordinary content at its top (not a pinned header above a
        // nested List), so they scroll up with the results. Removing the nested
        // Lists also removes the height reflow that made the screen jump while
        // typing: the top section no longer fights a full-height list sibling.
        ScrollView {
            VStack(spacing: 0) {
                Label(
                    String(format: String(localized: "search.loggingContext"), contextSubtitle),
                    systemImage: "calendar"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("search.loggingContext")
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
                searchProgressRow
                content
            }
        }
        .navigationTitle(String(localized: "search.title"))
        .navigationDestination(item: $creationDestination) { destination in
            FoodCreationFlowView(request: destination.request, context: destination.context) {
                creationDestination = nil
                Task { await viewModel.loadForAppearance() }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            viewModel.clearSelection()
        }
        .task {
            await viewModel.loadForAppearance()
        }
        .toolbar {
            if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               viewModel.scope != .barcode {
                ToolbarItem(placement: .automatic) {
                    Button(String(localized: "search.clear")) {
                        viewModel.clearQuery()
                    }
                    .accessibilityIdentifier("search.clear")
                }
            }
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

    private static func assistantPurposeTitle(_ purpose: AssistantDraftPurpose) -> String {
        switch purpose {
        case .customFood: return String(localized: "assistant.entry.customFood")
        case .adHocLog: return String(localized: "assistant.entry.adHocLog")
        }
    }

    private static func assistantPurposeIcon(_ purpose: AssistantDraftPurpose) -> String {
        switch purpose {
        case .customFood: return "square.and.pencil"
        case .adHocLog: return "fork.knife"
        }
    }

    private static func assistantPurposeIdentifier(_ purpose: AssistantDraftPurpose) -> String {
        switch purpose {
        case .customFood: return "search.assistant.customFood"
        case .adHocLog: return "search.assistant.adHocLog"
        }
    }

    /// A small inline progress row inside the scroll content. The results stay
    /// mounted while a new query is in flight, so typing no longer replaces the
    /// results with a differently-sized loading placeholder.
    @ViewBuilder
    private var searchProgressRow: some View {
        if viewModel.isSearching, viewModel.scope != .barcode {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "search.loading"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("search.loading.inline")
        }
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
        LazyVStack(spacing: 0) {
            ForEach(items) { result in
                Button {
                    selectResult(result)
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
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.result.\(result.id)")

                Divider().padding(.leading)
            }
        }
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
        LazyVStack(spacing: 0) {
            Text(String(localized: "search.recents.title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 12)

            ForEach(items) { item in
                recentRow(item)
                Divider().padding(.leading)
            }
        }
        .accessibilityIdentifier("search.recents")
    }

    /// Recents use the same native row composition as text results: leading
    /// alignment, the same horizontal/vertical row padding, a full-width
    /// `contentShape` tap target, the same name/brand/caption hierarchy and a
    /// divider after every row. A row tap opens the real food detail; the
    /// quantity chips stay as separate buttons inside the same aligned row so
    /// their hit areas never overlap the detail tap target.
    private func recentRow(_ item: RecentLogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openRecent(item)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
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
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canOpen(item))
            .accessibilityIdentifier("search.recent.\(item.id)")

            quantityChips(for: item)
            if viewModel.originMealSlot == nil {
                Text(String(format: String(localized: "search.quickAdd.destination"),
                            item.mealSlot.map(DiaryLabels.mealSlotName)
                                ?? String(localized: "foodDetail.mealSlot.none")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
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
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canQuickAdd)
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

    /// One selection entry for text results, recents and barcode lookups. The
    /// host decides which native stack owns the detail; the screen itself never
    /// duplicates a detail implementation or navigation control.
    private func selectResult(_ result: FoodSearchResult) {
        if let onSelectFoodID {
            onSelectFoodID(result.id)
        } else {
            viewModel.selectResult(result)
        }
    }

    private func onSelect(productID: String) {
        selectResult(FoodSearchResult(id: productID, name: productID))
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
            Button {
                if let onSelectFoodID {
                    onSelectFoodID(lookup.product.id)
                } else {
                    viewModel.openBarcodeResult()
                }
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
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.barcode.result")
        case .notFound(let message):
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label(String(localized: "search.barcode.notFoundTitle"), systemImage: "barcode")
                } description: {
                    Text(message)
                }
                if let creationContextProvider {
                    Button {
                        creationDestination = FoodCreationDestination(
                            request: FoodCreationRequest(entry: .barcode(viewModel.barcodeInput)),
                            context: creationContextProvider()
                        )
                    } label: {
                        Label(
                            String(localized: "search.barcode.notFound.create"),
                            systemImage: "square.and.pencil"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("search.barcode.create")
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
