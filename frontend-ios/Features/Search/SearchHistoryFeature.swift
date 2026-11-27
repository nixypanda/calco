import ComposableArchitecture
import Foundation

public struct SearchHistoryClient: Sendable {
    public var recentItems: @Sendable (
        _ from: LocalDiaryDate,
        _ to: LocalDiaryDate,
        _ mealSlot: MealSlot?
    ) async throws -> [RecentLogItem]
    public var categorySuggestions: @Sendable (
        _ query: String,
        _ limit: Int
    ) async throws -> [CategorySuggestion]
    public static func live(service: any FoodSearchHistoryServicing) -> Self {
        Self(
            recentItems: { from, to, mealSlot in
                try await service.recentItems(from: from, to: to, mealSlot: mealSlot)
            },
            categorySuggestions: { query, limit in
                try await service.categorySuggestions(query: query, limit: limit)
            }
        )
    }
}

private enum SearchHistoryClientKey: DependencyKey {
    static let liveValue: SearchHistoryClient = SearchHistoryClient(
        recentItems: { _, _, _ in
            fatalError("Unimplemented: SearchHistoryClient.recentItems")
            return []
        },
        categorySuggestions: { _, _ in
            fatalError("Unimplemented: SearchHistoryClient.categorySuggestions")
            return []
        }
    )

    static let testValue: SearchHistoryClient = SearchHistoryClient(
        recentItems: { _, _, _ in
            fatalError("Unimplemented: SearchHistoryClient.recentItems")
            return []
        },
        categorySuggestions: { _, _ in
            fatalError("Unimplemented: SearchHistoryClient.categorySuggestions")
            return []
        }
    )
}

public extension DependencyValues {
    var searchHistoryClient: SearchHistoryClient {
        get { self[SearchHistoryClientKey.self] }
        set { self[SearchHistoryClientKey.self] = newValue }
    }
}

@Reducer
public struct SearchHistoryFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public let sessionGeneration: UInt64
        public var contextDate: LocalDiaryDate
        public var contextMealSlot: MealSlot?
        public var recents: RecentsLoad
        public var categoryLookup: CategoryLookup

        public init(
            contextDate: LocalDiaryDate,
            contextMealSlot: MealSlot?,
            sessionGeneration: UInt64,
            recents: RecentsLoad = .idle,
            categoryLookup: CategoryLookup = .idle
        ) {
            self.contextDate = contextDate
            self.contextMealSlot = contextMealSlot
            self.sessionGeneration = sessionGeneration
            self.recents = recents
            self.categoryLookup = categoryLookup
        }

        public var visibleCategorySuggestions: [CategorySuggestion] {
            categoryLookup.visibleSuggestions
        }
    }

    public enum RecentsLoad: Equatable, Sendable {
        case idle
        case loading(
            requestID: UUID,
            contextDate: LocalDiaryDate,
            contextMealSlot: MealSlot?,
            priorItems: [RecentLogItem]
        )
        case loaded(
            requestID: UUID,
            contextDate: LocalDiaryDate,
            contextMealSlot: MealSlot?,
            items: [RecentLogItem]
        )
        case failed(
            requestID: UUID,
            contextDate: LocalDiaryDate,
            contextMealSlot: MealSlot?,
            message: String
        )

        public var items: [RecentLogItem] {
            guard case .loaded(_, _, _, let items) = self else { return [] }
            return items
        }

        public var visibleItems: [RecentLogItem] {
            switch self {
            case .idle, .failed: []
            case .loading(_, _, _, let priorItems): priorItems
            case .loaded(_, _, _, let items): items
            }
        }

        public var isLoading: Bool {
            if case .loading = self { true } else { false }
        }
    }

    public enum CategoryLookup: Equatable, Sendable {
        case idle
        case debouncing(requestID: UUID, query: String, visibleSuggestions: [CategorySuggestion])
        case loading(requestID: UUID, query: String, visibleSuggestions: [CategorySuggestion])
        case loaded(requestID: UUID, query: String, suggestions: [CategorySuggestion])
        case failed(
            requestID: UUID,
            query: String,
            visibleSuggestions: [CategorySuggestion],
            message: String
        )

        public var visibleSuggestions: [CategorySuggestion] {
            switch self {
            case .idle:
                return []
            case .debouncing(_, _, let visibleSuggestions),
                 .loading(_, _, let visibleSuggestions),
                 .failed(_, _, let visibleSuggestions, _):
                return visibleSuggestions
            case .loaded(_, _, let suggestions):
                return suggestions
            }
        }

        public var currentQuery: String? {
            switch self {
            case .idle:
                return nil
            case .debouncing(_, let query, _),
                 .loading(_, let query, _),
                 .loaded(_, let query, _),
                 .failed(_, let query, _, _):
                return query
            }
        }
    }

    public enum SearchHistoryFailure: Error, Equatable, Sendable {
        case cancelled
        case unauthorized
        case message(String)
    }

    public enum Action: Equatable, Sendable {
        case contextChanged(date: LocalDiaryDate, mealSlot: MealSlot?)
        case loadRecents
        case refreshRecents
        case recentsResponse(
            requestID: UUID,
            contextDate: LocalDiaryDate,
            contextMealSlot: MealSlot?,
            Result<[RecentLogItem], SearchHistoryFailure>
        )
        case categoryQueryChanged(String)
        case categoryDebounceElapsed(requestID: UUID, query: String)
        case categoryResponse(
            requestID: UUID,
            query: String,
            Result<[CategorySuggestion], SearchHistoryFailure>
        )
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(generation: UInt64)
    }

    private enum CancelID {
        case recents
        case category
    }

    @Dependency(\.searchHistoryClient) var searchHistoryClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock

    private let debounceDuration: Duration

    public init(debounceDuration: Duration = .milliseconds(300)) {
        self.debounceDuration = debounceDuration
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            // Context invalidation only. Parent decides whether to reload based on
            // active scope/mode (e.g. all/history reload recents; barcode does not).
            case let .contextChanged(date, mealSlot):
                guard state.contextDate != date || state.contextMealSlot != mealSlot else {
                    return .none
                }
                state.contextDate = date
                state.contextMealSlot = mealSlot
                state.recents = .idle
                return .cancel(id: CancelID.recents)

            case .loadRecents:
                switch state.recents {
                case .loading, .loaded:
                    return .none
                case .idle, .failed:
                    return loadRecents(&state, force: false)
                }

            case .refreshRecents:
                return loadRecents(&state, force: true)

            case let .recentsResponse(requestID, contextDate, contextMealSlot, result):
                guard case .loading(let currentRequestID, let currentDate, let currentSlot, let priorItems) = state.recents,
                      currentRequestID == requestID,
                      currentDate == contextDate,
                      currentSlot == contextMealSlot,
                      state.contextDate == contextDate,
                      state.contextMealSlot == contextMealSlot
                else {
                    return .none
                }
                switch result {
                case .success(let items):
                    state.recents = .loaded(
                        requestID: requestID,
                        contextDate: contextDate,
                        contextMealSlot: contextMealSlot,
                        items: items
                    )
                    return .none
                case .failure(.cancelled):
                    if priorItems.isEmpty {
                        state.recents = .idle
                    } else {
                        state.recents = .loaded(
                            requestID: requestID,
                            contextDate: contextDate,
                            contextMealSlot: contextMealSlot,
                            items: priorItems
                        )
                    }
                    return .none
                case .failure(.unauthorized):
                    state.recents = .failed(
                        requestID: requestID,
                        contextDate: contextDate,
                        contextMealSlot: contextMealSlot,
                        message: ""
                    )
                    return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                case .failure(.message(let message)):
                    state.recents = .failed(
                        requestID: requestID,
                        contextDate: contextDate,
                        contextMealSlot: contextMealSlot,
                        message: message
                    )
                    return .none
                }

            case .categoryQueryChanged(let rawQuery):
                let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if query.isEmpty {
                    guard state.categoryLookup != .idle else { return .none }
                    state.categoryLookup = .idle
                    return .cancel(id: CancelID.category)
                }
                if state.categoryLookup.currentQuery == query {
                    switch state.categoryLookup {
                    case .debouncing, .loading, .loaded:
                        return .none
                    case .idle, .failed:
                        break
                    }
                }
                let requestID = uuid()
                let visibleSuggestions = state.categoryLookup.visibleSuggestions
                state.categoryLookup = .debouncing(
                    requestID: requestID,
                    query: query,
                    visibleSuggestions: visibleSuggestions
                )
                return .run { [clock, debounceDuration, requestID, query] send in
                    do {
                        try await clock.sleep(for: debounceDuration)
                    } catch {
                        return
                    }
                    await send(.categoryDebounceElapsed(requestID: requestID, query: query))
                }
                .cancellable(id: CancelID.category, cancelInFlight: true)

            case let .categoryDebounceElapsed(requestID, query):
                guard case .debouncing(let currentRequestID, let currentQuery, let visibleSuggestions) = state.categoryLookup,
                      currentRequestID == requestID,
                      currentQuery == query
                else {
                    return .none
                }
                state.categoryLookup = .loading(
                    requestID: requestID,
                    query: query,
                    visibleSuggestions: visibleSuggestions
                )
                return .run { [searchHistoryClient, requestID, query] send in
                    do {
                        let suggestions = try await searchHistoryClient.categorySuggestions(query, 8)
                        await send(.categoryResponse(requestID: requestID, query: query, .success(suggestions)))
                    } catch {
                        if error is CancellationError {
                            guard !Task.isCancelled else { return }
                            await send(.categoryResponse(requestID: requestID, query: query, .failure(.cancelled)))
                            return
                        }
                        if let apiError = error as? CalCoAPIError, case .cancelled = apiError {
                            guard !Task.isCancelled else { return }
                            await send(.categoryResponse(requestID: requestID, query: query, .failure(.cancelled)))
                            return
                        }
                        if isUnauthorizedFoodSearchError(error) {
                            await send(.categoryResponse(requestID: requestID, query: query, .failure(.unauthorized)))
                        } else {
                            let message = foodSearchErrorMessage(error)
                            await send(
                                .categoryResponse(
                                    requestID: requestID,
                                    query: query,
                                    .failure(.message(message.isEmpty ? String(localized: "search.error.generic") : message))
                                )
                            )
                        }
                    }
                }
                .cancellable(id: CancelID.category, cancelInFlight: true)

            case let .categoryResponse(requestID, query, result):
                guard case .loading(let currentRequestID, let currentQuery, let visibleSuggestions) = state.categoryLookup,
                      currentRequestID == requestID,
                      currentQuery == query
                else {
                    return .none
                }
                switch result {
                case .success(let suggestions):
                    state.categoryLookup = .loaded(
                        requestID: requestID,
                        query: query,
                        suggestions: suggestions
                    )
                    return .none
                case .failure(.cancelled):
                    state.categoryLookup = .loaded(
                        requestID: requestID,
                        query: query,
                        suggestions: visibleSuggestions
                    )
                    return .none
                case .failure(.unauthorized):
                    state.categoryLookup = .failed(
                        requestID: requestID,
                        query: query,
                        visibleSuggestions: visibleSuggestions,
                        message: ""
                    )
                    return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                case .failure(.message(let message)):
                    state.categoryLookup = .failed(
                        requestID: requestID,
                        query: query,
                        visibleSuggestions: visibleSuggestions,
                        message: message
                    )
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }

    private func loadRecents(_ state: inout State, force: Bool) -> Effect<Action> {
        let requestID = uuid()
        let contextDate = state.contextDate
        let contextMealSlot = state.contextMealSlot
        let priorItems = state.recents.visibleItems
        state.recents = .loading(
            requestID: requestID,
            contextDate: contextDate,
            contextMealSlot: contextMealSlot,
            priorItems: priorItems
        )
        let from = contextDate.addingDays(-30)
        let to = contextDate
        return .run { [searchHistoryClient, requestID, contextDate, contextMealSlot, from, to] send in
            do {
                let items = try await searchHistoryClient.recentItems(from, to, contextMealSlot)
                await send(
                    .recentsResponse(
                        requestID: requestID,
                        contextDate: contextDate,
                        contextMealSlot: contextMealSlot,
                        .success(items)
                    )
                )
            } catch {
                if error is CancellationError {
                    guard !Task.isCancelled else { return }
                    await send(
                        .recentsResponse(
                            requestID: requestID,
                            contextDate: contextDate,
                            contextMealSlot: contextMealSlot,
                            .failure(.cancelled)
                        )
                    )
                    return
                }
                if let apiError = error as? CalCoAPIError, case .cancelled = apiError {
                    guard !Task.isCancelled else { return }
                    await send(
                        .recentsResponse(
                            requestID: requestID,
                            contextDate: contextDate,
                            contextMealSlot: contextMealSlot,
                            .failure(.cancelled)
                        )
                    )
                    return
                }
                if isUnauthorizedFoodSearchError(error) {
                    await send(
                        .recentsResponse(
                            requestID: requestID,
                            contextDate: contextDate,
                            contextMealSlot: contextMealSlot,
                            .failure(.unauthorized)
                        )
                    )
                } else {
                    let message = foodSearchErrorMessage(error)
                    await send(
                        .recentsResponse(
                            requestID: requestID,
                            contextDate: contextDate,
                            contextMealSlot: contextMealSlot,
                            .failure(.message(message.isEmpty ? String(localized: "search.error.generic") : message))
                        )
                    )
                }
            }
        }
        .cancellable(id: CancelID.recents, cancelInFlight: true)
    }
}
