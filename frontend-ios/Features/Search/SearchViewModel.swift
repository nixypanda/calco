import Combine
import Foundation
import SwiftUI

public typealias SearchSubmissionHandler = LogSubmissionHandler

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public private(set) var query: String = ""
    @Published public private(set) var scope: SearchScopeOption = .all
    @Published public private(set) var state: SearchLoadState = .idle
    /// A request is in flight. Kept separate from `state` so typing never swaps
    /// the visible results for a short loading placeholder (the old swap was
    /// the layout jump on every keystroke). The current rows stay put and an
    /// inline progress row is shown above them instead.
    @Published public private(set) var isSearching = false
    @Published public private(set) var selectedResultID: String? = nil
    @Published public private(set) var recentsState: RecentItemsLoadState = .idle
    @Published public private(set) var categorySuggestions: [CategorySuggestion] = []
    @Published public private(set) var barcodeInput: String = ""
    @Published public private(set) var barcodeState: BarcodeLookupState = .idle
    @Published public private(set) var quickAddState: SearchQuickAddState = .idle

    public private(set) var originDate: LocalDiaryDate
    public private(set) var originMealSlot: MealSlot?

    public var results: [FoodSearchResult] { state.results }

    private let service: FoodSearchServicing
    private let historyService: (any FoodSearchHistoryServicing)?
    private let debounceNanoseconds: UInt64
    private let timeZoneProvider: () -> String
    private let onSelectFood: (String, LocalDiaryDate, MealSlot?) -> Void
    private let onSelectMeal: (String, LocalDiaryDate, MealSlot?, NutritionQuantity?) -> Void
    private let onSessionExpired: () -> Void
    private let onSubmitDrafts: SearchSubmissionHandler?

    private var currentToken: Int = 0
    private var recentsToken: Int = 0
    private var categoryToken: Int = 0
    private var barcodeToken: Int = 0
    private var pendingTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?
    private var scheduledQuery: String?

    public init(
        originDate: LocalDiaryDate,
        originMealSlot: MealSlot? = nil,
        service: FoodSearchServicing,
        debounceNanoseconds: UInt64 = 300_000_000,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        onSelectFood: @escaping (String, LocalDiaryDate, MealSlot?) -> Void,
        onSelectMeal: @escaping (String, LocalDiaryDate, MealSlot?, NutritionQuantity?) -> Void = { _, _, _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        historyService: (any FoodSearchHistoryServicing)? = nil,
        onSubmitDrafts: SearchSubmissionHandler? = nil
    ) {
        self.originDate = originDate
        self.originMealSlot = originMealSlot
        self.service = service
        self.debounceNanoseconds = debounceNanoseconds
        self.timeZoneProvider = timeZoneProvider
        self.onSelectFood = onSelectFood
        self.onSelectMeal = onSelectMeal
        self.onSessionExpired = onSessionExpired
        self.historyService = historyService
        self.onSubmitDrafts = onSubmitDrafts
    }

    public func updateContext(date: LocalDiaryDate, mealSlot: MealSlot?) {
        guard originDate != date || originMealSlot != mealSlot else { return }
        originDate = date
        originMealSlot = mealSlot
        selectedResultID = nil
        clearRecents()
        if scope != .barcode, query.isEmpty {
            state = .idle
        }
        if scope == .history || scope == .all {
            Task { [weak self] in await self?.loadRecents(force: true) }
        }
    }

    public func updateNavigationContext(date: LocalDiaryDate, mealSlot: MealSlot?) {
        updateContext(date: date, mealSlot: mealSlot)
    }

    public func queryChanged(_ newQuery: String) {
        guard query != newQuery else { return }
        query = newQuery
        selectedResultID = nil
        // Do not blank the category chips here. They are replaced atomically by
        // the debounced fetch; clearing them on every keystroke removed and
        // re-inserted a row in the search layout and made the screen jump.
        if scope == .barcode {
            // Typing leaves barcode results behind without searching the
            // catalog; the barcode field is the active input in this mode.
            barcodeState = .idle
            return
        }
        scheduleSearch(for: newQuery)
        scheduleCategorySuggestions(for: newQuery)
    }

    public func search(_ newQuery: String? = nil) {
        if let newQuery {
            query = newQuery
        }
        guard scope != .barcode else {
            lookupBarcode()
            return
        }
        scheduleSearch(for: query, immediate: true)
        scheduleCategorySuggestions(for: query, immediate: true)
    }

    public func submitQuery() { search() }
    public func submitSearch() { search() }
    public func performSearch() { search() }
    public func retry() { search(query) }

    public func clearQuery() {
        resetSearch(clearQuery: true)
        categorySuggestions = []
        quickAddState = .idle
    }

    public func invalidateSession() {
        resetSearch(clearQuery: true)
        clearRecents()
        categorySuggestions = []
        isSearching = false
        barcodeInput = ""
        barcodeState = .idle
        quickAddState = .idle
    }

    public func selectResult(_ result: FoodSearchResult) {
        guard selectedResultID != result.id else { return }
        selectedResultID = result.id
        onSelectFood(result.id, originDate, originMealSlot)
    }

    /// Opens a saved meal in the meal editor/detail flow. Meal IDs never flow
    /// through the product-detail callback, even if both are catalog IDs.
    public func selectMeal(
        _ item: RecentLogItem,
        quantity: NutritionQuantity? = nil
    ) {
        guard case .meal(let meal) = item.item else { return }
        selectedResultID = item.id
        onSelectMeal(
            meal.id,
            originDate,
            originMealSlot,
            quantity ?? item.quantity
        )
    }

    /// Meal and product recents are openable; ad-hoc snapshots have no catalog
    /// identity or detail editor and stay quick-add-only.
    public func canOpen(_ item: RecentLogItem) -> Bool {
        switch item.item {
        case .product, .meal: return true
        case .adHoc: return false
        }
    }

    public func select(_ result: FoodSearchResult) { selectResult(result) }
    public func didSelect(_ result: FoodSearchResult) { selectResult(result) }

    public func clearSelection() {
        guard selectedResultID != nil else { return }
        selectedResultID = nil
    }

    // MARK: - Scope

    public func setScope(_ newScope: SearchScopeOption) {
        guard scope != newScope else { return }
        scope = newScope
        selectedResultID = nil
        categorySuggestions = []
        resetSearch(clearQuery: false)

        switch newScope {
        case .barcode:
            barcodeState = .idle
            quickAddState = .idle
        case .all, .history, .custom:
            barcodeState = .idle
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state = .idle
                if newScope == .all || newScope == .history {
                    Task { [weak self] in await self?.loadRecents(force: true) }
                }
            } else {
                scheduleSearch(for: query, immediate: true)
                scheduleCategorySuggestions(for: query, immediate: true)
            }
        }
    }

    // MARK: - Recents

    public func loadForAppearance() async {
        guard scope != .barcode else { return }
        if case .idle = recentsState {
            await loadRecents(force: false)
        }
    }

    public func loadRecents(force: Bool = true) async {
        guard let historyService else { return }
        if !force, case .loaded = recentsState { return }
        recentsToken += 1
        let token = recentsToken
        let date = originDate
        let slot = originMealSlot
        if recentsState.items.isEmpty {
            recentsState = .loading
        }

        do {
            let items = try await historyService.recentItems(
                from: date.addingDays(-30),
                to: date,
                mealSlot: slot
            )
            guard token == recentsToken,
                  originDate == date,
                  originMealSlot == slot else { return }
            recentsState = .loaded(items)
        } catch {
            guard token == recentsToken,
                  originDate == date,
                  originMealSlot == slot else { return }
            if isCancelledFoodSearchError(error) {
                if recentsState.items.isEmpty { recentsState = .idle }
                return
            }
            if isUnauthorizedFoodSearchError(error) {
                invalidateSession()
                onSessionExpired()
                return
            }
            let message = foodSearchErrorMessage(error)
            recentsState = .failed(
                message.isEmpty ? String(localized: "search.error.generic") : message
            )
        }
    }

    private func clearRecents() {
        recentsToken += 1
        recentsState = .idle
    }

    // MARK: - Categories

    public func applyCategorySuggestion(_ suggestion: CategorySuggestion) {
        guard scope != .barcode else { return }
        let quoted = suggestion.value.contains(where: \.isWhitespace)
            ? "\"\(suggestion.value)\""
            : suggestion.value
        let token = "category:\(quoted)"
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed.isEmpty ? token : "\(trimmed) \(token)"
        // A fetch for the pre-selection query may still be in flight. Invalidate
        // it or it would repopulate the chips we just consumed with stale data.
        categoryTask?.cancel()
        categoryToken += 1
        categorySuggestions = []
        selectedResultID = nil
        scheduleSearch(for: query, immediate: true)
    }

    private func scheduleCategorySuggestions(for rawQuery: String, immediate: Bool = false) {
        guard let historyService else { return }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope != .barcode, !trimmed.isEmpty else {
            categoryToken += 1
            categorySuggestions = []
            return
        }
        categoryTask?.cancel()
        categoryToken += 1
        let token = categoryToken
        let delay = immediate ? 0 : debounceNanoseconds
        categoryTask = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            do {
                let suggestions = try await historyService.categorySuggestions(
                    query: trimmed,
                    limit: 8
                )
                guard token == self.categoryToken,
                      self.scope != .barcode else { return }
                self.categorySuggestions = suggestions
            } catch {
                guard token == self.categoryToken else { return }
                if isUnauthorizedFoodSearchError(error) {
                    self.invalidateSession()
                    self.onSessionExpired()
                    return
                }
                // Suggestions are an enhancement; keep text results usable.
                self.categorySuggestions = []
            }
        }
    }

    // MARK: - Barcode

    public func barcodeChanged(_ value: String) {
        guard barcodeInput != value else { return }
        barcodeInput = value
        barcodeState = .idle
        barcodeToken += 1
    }

    public func lookupBarcode() {
        let value = barcodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let validation = BarcodeValidation.validated(value)
        guard case .success(let barcode) = validation else {
            barcodeToken += 1
            if case .failure(let error) = validation {
                barcodeState = .failed(error.message)
            } else {
                barcodeState = .failed(String(localized: "search.barcode.invalid"))
            }
            return
        }
        guard let historyService else {
            barcodeState = .failed(String(localized: "search.error.generic"))
            return
        }
        barcodeToken += 1
        let token = barcodeToken
        barcodeState = .loading
        Task { [weak self] in
            do {
                let lookup = try await historyService.lookupBarcode(barcode)
                guard let self, token == self.barcodeToken else { return }
                self.barcodeState = .found(lookup)
            } catch {
                guard let self, token == self.barcodeToken else { return }
                if isCancelledFoodSearchError(error) {
                    self.barcodeState = .idle
                    return
                }
                if isUnauthorizedFoodSearchError(error) {
                    self.invalidateSession()
                    self.onSessionExpired()
                    return
                }
                if let apiError = error as? CalCoAPIError,
                   apiError.statusCode == 404 {
                    self.barcodeState = .notFound(
                        String(localized: "search.barcode.notFound")
                    )
                    return
                }
                let message = foodSearchErrorMessage(error)
                self.barcodeState = .failed(
                    message.isEmpty ? String(localized: "search.error.generic") : message
                )
            }
        }
    }

    public func openBarcodeResult() {
        guard case .found(let lookup) = barcodeState else { return }
        selectedResultID = lookup.product.id
        onSelectFood(lookup.product.id, originDate, originMealSlot)
    }

    // MARK: - Quick add

    public func quickAdd(_ item: RecentLogItem, quantity: NutritionQuantity? = nil) {
        guard let onSubmitDrafts,
              !item.id.isEmpty,
              case .idle = quickAddState else { return }
        let chosen = quantity ?? item.quantity
        let draft = makeDraft(item: item, quantity: chosen)
        quickAddState = .submitting(item.id)
        onSubmitDrafts([draft], [item.name], item.name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.quickAddState = .added(item.name)
                Task { await self.loadRecents(force: true) }
            case .failure(let failure):
                self.quickAddState = .failed(failure.message)
            }
        }
    }

    public func dismissQuickAddMessage() {
        quickAddState = .idle
    }

    private func makeDraft(
        item: RecentLogItem,
        quantity: NutritionQuantity
    ) -> LogSubmissionDraft {
        let submissionItem = item.submissionItem
            ?? .adHoc(name: item.name, brand: item.brand)
        return LogSubmissionDraft(
            item: submissionItem,
            date: originDate,
            mealSlot: originMealSlot ?? item.mealSlot,
            amount: quantity.amount,
            unit: quantity.unit,
            notes: nil,
            timeZone: timeZoneProvider()
        )
    }

    // MARK: - Text search

    private func scheduleSearch(for rawQuery: String, immediate: Bool = false) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSearch(clearQuery: false)
            return
        }
        guard let apiScope = scope.foodSearchScope else { return }

        if isSearching, scheduledQuery == trimmed {
            return
        }

        pendingTask?.cancel()
        pendingTask = nil
        currentToken += 1
        let token = currentToken
        let scopedToken = scope

        scheduledQuery = trimmed
        selectedResultID = nil
        // Keep the current `state` and its rows. Only the transient progress
        // flag changes, so typing does not resize/replace the results area.
        isSearching = true

        let delay = immediate ? 0 : debounceNanoseconds
        pendingTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    // Only the current request may clear the loading state.
                    // A cancelled stale task must leave its replacement alone.
                    self?.clearCancelledRequest(token: token)
                    return
                }
            }
            guard let self else { return }
            guard !Task.isCancelled else {
                self.clearCancelledRequest(token: token)
                return
            }
            await self.executeSearch(
                token: token,
                query: trimmed,
                scope: apiScope,
                scopeToken: scopedToken
            )
        }
    }

    private func executeSearch(
        token: Int,
        query: String,
        scope apiScope: FoodSearchScope,
        scopeToken: SearchScopeOption
    ) async {
        guard token == currentToken, scope == scopeToken else { return }
        do {
            let items = try await service.searchFoods(query: query, scope: apiScope)
            guard token == currentToken, scope == scopeToken else { return }
            finishCurrentRequest()
            isSearching = false
            selectedResultID = nil
            if let loaded = FoodSearchResults(items) {
                state = .loaded(loaded)
            } else {
                state = .empty
            }
        } catch {
            guard token == currentToken, scope == scopeToken else { return }

            if isCancelledFoodSearchError(error) {
                finishCurrentRequest()
                isSearching = false
                selectedResultID = nil
                state = .idle
                return
            }

            if isUnauthorizedFoodSearchError(error) {
                // `invalidateSession` already calls resetSearch, which bumps
                // currentToken and clears pendingTask/scheduledQuery; make the
                // intent explicit and fire the session callback exactly once.
                finishCurrentRequest()
                invalidateSession()
                onSessionExpired()
                return
            }

            let message = foodSearchErrorMessage(error)
            finishCurrentRequest()
            isSearching = false
            selectedResultID = nil
            state = .failed(
                message.isEmpty ? String(localized: "search.error.generic") : message
            )
        }
    }

    /// Cancellation cleanup is token-guarded: `scheduleSearch`/`resetSearch`
    /// synchronously install the replacement (or clear the state) before a
    /// stale task observes its cancellation, so a stale task must never clear
    /// the new request's `isSearching`/`scheduledQuery`.
    private func clearCancelledRequest(token: Int) {
        guard token == currentToken else { return }
        finishCurrentRequest()
        isSearching = false
    }

    private func finishCurrentRequest() {
        scheduledQuery = nil
        pendingTask = nil
    }

    private func resetSearch(clearQuery: Bool) {
        pendingTask?.cancel()
        pendingTask = nil
        currentToken += 1
        scheduledQuery = nil
        isSearching = false
        if clearQuery {
            query = ""
        }
        selectedResultID = nil
        state = .idle
    }
}
