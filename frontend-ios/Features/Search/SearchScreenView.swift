import ComposableArchitecture
import SwiftUI

/// Native Search screen ported from `SearchView` onto the parent TCA store.
///
/// This is the Search cutover view: it is Store-backed and deliberately has no
/// `ObservableObject`/ViewModel adapter. Every write goes through an explicit
/// parent or child action; state is only ever read from the store. The optional
/// `onOpenMeals` closure is an explicit transitional parent-intent seam — the
/// host supplies it; this view never navigates or writes an API itself.
public struct SearchScreenView: View {
    private let store: StoreOf<SearchScreenFeature>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Native header Meals control. The host wires this to a parent-level
    /// intent; this view never switches tabs or mutates navigation itself.
    private let onOpenMeals: (() -> Void)?

    /// Scope set shown by the picker. Defaults to the standalone (all four)
    /// set; contextual Diary hosts pass `SearchScreenView.contextualScopes`.
    private let scopeOptions: [SearchScopeOption]

    /// Captured at view construction; used to tag navigation-producing intents
    /// with explicit lineage. Pure metadata, not mutable state.
    private let navigationOrigin: SearchScreenFeature.NavigationOrigin

    public init(
        store: StoreOf<SearchScreenFeature>,
        onOpenMeals: (() -> Void)? = nil,
        scopeOptions: [SearchScopeOption]? = nil,
        navigationOrigin: SearchScreenFeature.NavigationOrigin = .diaryPush
    ) {
        self.store = store
        self.onOpenMeals = onOpenMeals
        self.scopeOptions = scopeOptions ?? SearchScopeOption.allCases
        self.navigationOrigin = navigationOrigin
    }

    // MARK: Derived store state (read-only)

    private var catalog: SearchFeature.State { store.catalog }
    private var history: SearchHistoryFeature.State { store.history }
    private var quickAddChild: SearchQuickAddFeature.State { store.quickAdd }
    private var barcodeChild: BarcodeFeature.State { store.barcode }

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

    /// `originDate`/`originMealSlot`/`sessionGeneration` are computed on the
    /// parent from the catalog child; this view reads them through the catalog
    /// child directly so it never duplicates context in local `@State`.
    public var contextSubtitle: String {
        let date = catalog.originDate.diaryDisplayTitle()
        guard let slot = catalog.originMealSlot else { return date }
        return "\(date) · \(DiaryLabels.mealSlotName(slot))"
    }

    private var canQuickAdd: Bool { !quickAddChild.isBusy }

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
                if catalog.scope == .barcode {
                    barcodeField
                } else {
                    searchField
                }
                if !history.visibleCategorySuggestions.isEmpty {
                    categorySuggestions
                }
                quickAddBanner
                searchProgressRow
                content
            }
        }
        .navigationTitle(String(localized: "search.title"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Appearance is an intent. The parent owns the load-if-needed
            // decision; the view never force-fetches on every appearance.
            store.send(.appeared)
        }
        .toolbar {
            if let onOpenMeals {
                ToolbarItem(placement: .automatic) {
                    Button {
                        onOpenMeals()
                    } label: {
                        Label(String(localized: "meals.title"), systemImage: "square.stack.3d.up")
                    }
                    .accessibilityIdentifier("search.openMeals")
                }
            }
            if !catalog.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               catalog.scope != .barcode {
                ToolbarItem(placement: .automatic) {
                    Button(String(localized: "search.clear")) {
                        // Parent owns the full clear semantics (query, chips,
                        // quick-add message); no direct state write here.
                        store.send(.clearQuery)
                    }
                    .accessibilityIdentifier("search.clear")
                }
            }
        }
    }

    // MARK: - Scope picker

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
                get: { catalog.scope },
                set: { store.send(.scopeChanged($0)) }
            )
        ) {
            ForEach(scopeOptions, id: \.self) { option in
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

    // MARK: - Inline progress

    /// A small inline progress row inside the scroll content. The results stay
    /// mounted while a new query is in flight, so typing no longer replaces the
    /// results with a differently-sized loading placeholder.
    @ViewBuilder
    private var searchProgressRow: some View {
        if catalog.isSearching, catalog.scope != .barcode {
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

    // MARK: - Search / barcode input

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                String(localized: "search.prompt"),
                text: Binding(
                    get: { catalog.query },
                    set: { store.send(.queryChanged($0)) }
                )
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .submitLabel(.search)
            .onSubmit { store.send(.searchSubmitted) }
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
            TextField(
                String(localized: "search.barcode.prompt"),
                text: Binding(
                    // Barcode input is owned by the parent's persistent barcode
                    // child; the view has no local duplicate.
                    get: { barcodeChild.barcodeInput },
                    set: { store.send(.barcode(.barcodeChanged($0))) }
                )
            )
            .textFieldStyle(.plain)
            .font(.body.monospacedDigit())
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .lineLimit(1)
            .submitLabel(.search)
            .onSubmit { store.send(.barcode(.lookupSubmitted)) }
            .accessibilityIdentifier("search.barcode.field")
            Button(String(localized: "search.barcode.lookup")) {
                store.send(.barcode(.lookupSubmitted))
            }
            .buttonStyle(.borderedProminent)
            .disabled(barcodeChild.barcodeInput.isEmpty)
            .accessibilityIdentifier("search.barcode.lookupButton")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Category chips

    private var categorySuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(history.visibleCategorySuggestions) { suggestion in
                    Button {
                        // Parent constructs the exact category grammar, clears
                        // the chips and runs the immediate search.
                        store.send(.categorySuggestionSelected(suggestion))
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

    // MARK: - Quick-add banner

    @ViewBuilder
    private var quickAddBanner: some View {
        switch quickAddChild.phase {
        case .idle:
            EmptyView()
        case .submitting(let request):
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "search.quickAdd.saving"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityIdentifier("search.quickAdd.progress.\(request.itemID)")
        case .succeeded(let receipt):
            HStack(spacing: 8) {
                Label(
                    String(format: String(localized: "search.quickAdd.added"), receipt.itemName),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.green)
                Spacer(minLength: 8)
                Button {
                    store.send(.quickAddFeature(.dismissMessage))
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
        case .failed(_, let failure):
            HStack(spacing: 8) {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    store.send(.quickAddFeature(.dismissMessage))
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

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        if catalog.scope == .barcode {
            barcodeContent
        } else if !catalog.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textResultsContent
        } else {
            recentsContent
        }
    }

    // MARK: - Text results

    @ViewBuilder
    private var textResultsContent: some View {
        switch catalog.phase {
        case .idle:
            recentsContent
        case .debouncing, .loading:
            // Retained native delta: prior rows stay mounted during an
            // in-flight query; the inline progress row reports the refresh.
            if catalog.results.isEmpty {
                loadingView(identifier: "search.loading")
            } else {
                resultsView(catalog.results)
            }
        case .loaded:
            if catalog.results.isEmpty {
                emptyView
            } else {
                resultsView(catalog.results)
            }
        case .failed(_, _, _, let message, _):
            errorView(message: message)
        }
    }

    private func resultsView(_ items: [FoodSearchResult]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { result in
                SearchResultRow(
                    result: result,
                    isSelected: catalog.selectedResultID == result.id,
                    onSelect: {
                        // Parent captures navigation origin + context/gen at
                        // action time and emits a single outward delegate.
                        store.send(.selectCatalogResult(id: result.id, origin: navigationOrigin))
                    }
                )
                Divider().padding(.leading)
            }
        }
        .accessibilityIdentifier("search.results")
    }

    // MARK: - Recents

    @ViewBuilder
    private var recentsContent: some View {
        switch history.recents {
        case .idle:
            idleView
        case .loading:
            loadingView(identifier: "search.recents.loading")
        case .loaded(_, _, _, let items):
            if items.isEmpty {
                idleView
            } else {
                recentsList(items)
            }
        case .failed(_, _, _, let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "search.retry")) {
                    store.send(.history(.refreshRecents))
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
    /// divider after every row. A row tap opens the real food detail (parent
    /// intent); the quantity chips stay as separate buttons inside the same
    /// aligned row so their hit areas never overlap the detail tap target.
    private func recentRow(_ item: RecentLogItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                store.send(.selectRecent(item: item, quantity: nil, origin: navigationOrigin))
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
            if catalog.originMealSlot == nil {
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
                        store.send(.quickAdd(item: item, quantity: usage.quantity))
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
                    .disabled(!canQuickAdd)
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

    /// Meal and product recents are openable; ad-hoc snapshots have no catalog
    /// identity or detail editor and stay quick-add-only. The parent owns the
    /// handoff; this is only the row's disabled state.
    private func canOpen(_ item: RecentLogItem) -> Bool {
        switch item.item {
        case .product, .meal: return true
        case .adHoc: return false
        }
    }

    // MARK: - Barcode

    @ViewBuilder
    private var barcodeContent: some View {
        switch barcodeChild.lookup {
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
        case .invalid(let error):
            barcodeErrorView(message: error.message, canRetry: false)
        case .lookingUp:
            loadingView(identifier: "search.barcode.loading")
        case .found(let lookup):
            Button {
                store.send(.selectBarcodeProduct(origin: navigationOrigin))
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
        case .notFound:
            VStack(spacing: 16) {
                ContentUnavailableView {
                    Label(String(localized: "search.barcode.notFoundTitle"), systemImage: "barcode")
                } description: {
                    Text(String(localized: "search.barcode.notFound"))
                }
                Button {
                    createBarcodeCustomFood()
                } label: {
                    Label(
                        String(localized: "search.barcode.create"),
                        systemImage: "square.and.pencil"
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.barcode.create")
            }
            .accessibilityIdentifier("search.barcode.notFound")
        case .failed(_, let error):
            barcodeErrorView(message: error.message, canRetry: error.canRetry)
        }
    }

    private func barcodeErrorView(message: String, canRetry: Bool) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button(String(localized: "search.retry")) {
                    store.send(.barcode(.retrySubmitted))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.error")
    }

    /// The create control emits a parent intent. The parent captures origin
    /// + context/gen at action time and emits the outward creation delegate;
    /// this view never constructs a request or writes an API itself.
    private func createBarcodeCustomFood() {
        store.send(.createBarcodeDraft(origin: navigationOrigin))
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
                // Explicit submit intent; the parent re-runs the current query.
                store.send(.searchSubmitted)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("search.retry")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.error")
    }
}
