import Combine
import Foundation
import SwiftUI

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public private(set) var query: String = ""
    @Published public private(set) var state: SearchLoadState = .idle
    @Published public private(set) var selectedResultID: String? = nil

    public private(set) var originDate: LocalDiaryDate
    public private(set) var originMealSlot: MealSlot?

    public var results: [FoodSearchResult] { state.results }

    private let service: FoodSearchServicing
    private let debounceNanoseconds: UInt64
    private let onSelectFood: (String, LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void

    private var currentToken: Int = 0
    private var pendingTask: Task<Void, Never>?
    private var scheduledQuery: String?

    public init(
        originDate: LocalDiaryDate,
        originMealSlot: MealSlot? = nil,
        service: FoodSearchServicing,
        debounceNanoseconds: UInt64 = 300_000_000,
        onSelectFood: @escaping (String, LocalDiaryDate, MealSlot?) -> Void,
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.originDate = originDate
        self.originMealSlot = originMealSlot
        self.service = service
        self.debounceNanoseconds = debounceNanoseconds
        self.onSelectFood = onSelectFood
        self.onSessionExpired = onSessionExpired
    }

    public func updateContext(date: LocalDiaryDate, mealSlot: MealSlot?) {
        guard originDate != date || originMealSlot != mealSlot else { return }
        originDate = date
        originMealSlot = mealSlot
        selectedResultID = nil
    }

    public func updateNavigationContext(date: LocalDiaryDate, mealSlot: MealSlot?) {
        updateContext(date: date, mealSlot: mealSlot)
    }

    public func queryChanged(_ newQuery: String) {
        guard query != newQuery else { return }
        query = newQuery
        scheduleSearch(for: newQuery)
    }

    public func search(_ newQuery: String? = nil) {
        if let newQuery {
            query = newQuery
        }
        scheduleSearch(for: query, immediate: true)
    }

    public func submitQuery() { search() }
    public func submitSearch() { search() }
    public func performSearch() { search() }
    public func retry() { search(query) }

    public func clearQuery() {
        resetSearch(clearQuery: true)
    }

    public func invalidateSession() {
        resetSearch(clearQuery: true)
    }

    public func selectResult(_ result: FoodSearchResult) {
        guard selectedResultID != result.id else { return }
        selectedResultID = result.id
        onSelectFood(result.id, originDate, originMealSlot)
    }

    public func select(_ result: FoodSearchResult) { selectResult(result) }
    public func didSelect(_ result: FoodSearchResult) { selectResult(result) }

    public func clearSelection() {
        guard selectedResultID != nil else { return }
        selectedResultID = nil
    }

    private func scheduleSearch(for rawQuery: String, immediate: Bool = false) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetSearch(clearQuery: false)
            return
        }

        if state == .loading, scheduledQuery == trimmed {
            return
        }

        pendingTask?.cancel()
        pendingTask = nil
        currentToken += 1
        let token = currentToken

        scheduledQuery = trimmed
        selectedResultID = nil
        state = .loading

        let delay = immediate ? 0 : debounceNanoseconds
        pendingTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.executeSearch(token: token, query: trimmed)
        }
    }

    private func executeSearch(token: Int, query: String) async {
        guard token == currentToken else { return }
        do {
            let items = try await service.searchFoods(query: query, scope: .all)
            guard token == currentToken else { return }
            finishCurrentRequest()
            selectedResultID = nil
            if let loaded = FoodSearchResults(items) {
                state = .loaded(loaded)
            } else {
                state = .empty
            }
        } catch {
            guard token == currentToken else { return }

            if isCancelledFoodSearchError(error) {
                finishCurrentRequest()
                selectedResultID = nil
                state = .idle
                return
            }

            if isUnauthorizedFoodSearchError(error) {
                invalidateSession()
                onSessionExpired()
                return
            }

            let message = foodSearchErrorMessage(error)
            finishCurrentRequest()
            selectedResultID = nil
            state = .failed(
                message.isEmpty ? String(localized: "search.error.generic") : message
            )
        }
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
        if clearQuery {
            query = ""
        }
        selectedResultID = nil
        state = .idle
    }
}
