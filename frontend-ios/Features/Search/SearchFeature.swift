import ComposableArchitecture
import Foundation

public struct FoodSearchClient: Sendable {
    public var search: @Sendable (_ query: String, _ scope: FoodSearchScope) async throws -> [FoodSearchResult]
    public static func live(service: any FoodSearchServicing) -> Self {
        Self { query, scope in
            try await service.searchFoods(query: query, scope: scope)
        }
    }

    public static let unimplemented = Self(
        search: { _, _ in
            fatalError("Unimplemented: FoodSearchClient.search")
        }
    )
}

private enum FoodSearchClientKey: DependencyKey {
    static let liveValue: FoodSearchClient = .unimplemented
    static let testValue: FoodSearchClient = .unimplemented
}

public extension DependencyValues {
    var foodSearchClient: FoodSearchClient {
        get { self[FoodSearchClientKey.self] }
        set { self[FoodSearchClientKey.self] = newValue }
    }
}

@Reducer
public struct SearchFeature {
    public enum Phase: Equatable, Sendable {
        case idle(query: String, scope: SearchScopeOption, results: [FoodSearchResult])
        case debouncing(requestID: UUID, query: String, scope: SearchScopeOption, previousResults: [FoodSearchResult])
        case loading(requestID: UUID, query: String, scope: SearchScopeOption, previousResults: [FoodSearchResult])
        case loaded(requestID: UUID, query: String, scope: SearchScopeOption, results: [FoodSearchResult])
        case failed(requestID: UUID, query: String, scope: SearchScopeOption, message: String, previousResults: [FoodSearchResult])

        public var query: String {
            switch self {
            case .idle(let query, _, _),
                 .debouncing(_, let query, _, _),
                 .loading(_, let query, _, _),
                 .loaded(_, let query, _, _),
                 .failed(_, let query, _, _, _):
                return query
            }
        }

        public var scope: SearchScopeOption {
            switch self {
            case .idle(_, let scope, _),
                 .debouncing(_, _, let scope, _),
                 .loading(_, _, let scope, _),
                 .loaded(_, _, let scope, _),
                 .failed(_, _, let scope, _, _):
                return scope
            }
        }

        public var results: [FoodSearchResult] {
            switch self {
            case .idle(_, _, let results),
                 .loaded(_, _, _, let results):
                return results
            case .debouncing(_, _, _, let previousResults),
                 .loading(_, _, _, let previousResults),
                 .failed(_, _, _, _, let previousResults):
                return previousResults
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var originDate: LocalDiaryDate
        public var originMealSlot: MealSlot?
        public let sessionGeneration: UInt64
        public var phase: Phase
        public var selectedResultID: String?

        public var query: String { phase.query }
        public var scope: SearchScopeOption { phase.scope }
        public var results: [FoodSearchResult] { phase.results }
        public var isSearching: Bool {
            switch phase {
            case .debouncing, .loading: true
            case .idle, .loaded, .failed: false
            }
        }

        public init(
            originDate: LocalDiaryDate,
            originMealSlot: MealSlot? = nil,
            query: String = "",
            scope: SearchScopeOption = .all,
            sessionGeneration: UInt64
        ) {
            self.originDate = originDate
            self.originMealSlot = originMealSlot
            self.sessionGeneration = sessionGeneration
            self.phase = .idle(query: query, scope: scope, results: [])
            self.selectedResultID = nil
        }

        internal init(
            originDate: LocalDiaryDate,
            originMealSlot: MealSlot? = nil,
            phase: Phase,
            sessionGeneration: UInt64 = 0,
            selectedResultID: String? = nil
        ) {
            self.originDate = originDate
            self.originMealSlot = originMealSlot
            self.sessionGeneration = sessionGeneration
            self.phase = phase
            self.selectedResultID = selectedResultID
        }
    }

    public enum Action: Equatable, Sendable {
        case queryChanged(String)
        case searchSubmitted
        case scopeChanged(SearchScopeOption)
        case updateContext(date: LocalDiaryDate, mealSlot: MealSlot?)
        case selectResult(id: String)
        case searchDebounced(requestID: UUID, query: String, scope: SearchScopeOption)
        case resultReceived(requestID: UUID, query: String, scope: SearchScopeOption, result: Result<[FoodSearchResult], FoodSearchServiceError>)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case selectedFood(id: String, date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64)
        case sessionExpired(generation: UInt64)
    }

    private enum CancelID: Hashable {
        case search
    }

    @Dependency(\.foodSearchClient) private var foodSearchClient
    @Dependency(\.uuid) private var uuid
    @Dependency(\.continuousClock) private var clock

    public init() {}

    private static let debounceNanoseconds: UInt64 = 300_000_000

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .queryChanged(let newQuery):
                let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard state.query != newQuery else { return .none }

                if state.scope == .barcode {
                    state.phase = .idle(query: newQuery, scope: .barcode, results: [])
                    state.selectedResultID = nil
                    return .cancel(id: CancelID.search)
                }

                if trimmed.isEmpty {
                    state.phase = .idle(query: newQuery, scope: state.scope, results: [])
                    state.selectedResultID = nil
                    return .cancel(id: CancelID.search)
                }

                let requestID = uuid()
                let requestScope = state.scope
                let previousResults = state.phase.results
                state.phase = .debouncing(
                    requestID: requestID,
                    query: newQuery,
                    scope: requestScope,
                    previousResults: previousResults
                )
                state.selectedResultID = nil

                return .run { send in
                    do {
                        try await clock.sleep(for: .nanoseconds(Self.debounceNanoseconds))
                    } catch {
                        return
                    }
                    await send(.searchDebounced(requestID: requestID, query: newQuery, scope: requestScope))
                }
                .cancellable(id: CancelID.search, cancelInFlight: true)

            case .searchSubmitted:
                if state.scope == .barcode {
                    state.phase = .idle(query: state.query, scope: .barcode, results: [])
                    state.selectedResultID = nil
                    return .cancel(id: CancelID.search)
                }

                let rawQuery = state.query
                let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedQuery.isEmpty else {
                    state.phase = .idle(query: state.query, scope: state.scope, results: [])
                    state.selectedResultID = nil
                    return .cancel(id: CancelID.search)
                }
                guard let apiScope = state.scope.foodSearchScope else {
                    state.phase = .idle(query: state.query, scope: state.scope, results: [])
                    state.selectedResultID = nil
                    return .cancel(id: CancelID.search)
                }

                let requestID = uuid()
                let requestScope = state.scope
                let previousResults = state.phase.results
                state.phase = .loading(
                    requestID: requestID,
                    query: rawQuery,
                    scope: requestScope,
                    previousResults: previousResults
                )
                state.selectedResultID = nil

                return .run { send in
                    do {
                        let items = try await foodSearchClient.search(normalizedQuery, apiScope)
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: requestScope,
                            result: .success(items)
                        ))
                    } catch let error as FoodSearchServiceError {
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: requestScope,
                            result: .failure(error)
                        ))
                    } catch {
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: requestScope,
                            result: .failure(FoodSearchServiceError(foodSearchErrorMessage(error)))
                        ))
                    }
                }
                .cancellable(id: CancelID.search, cancelInFlight: true)

            case .scopeChanged(let newScope):
                guard newScope != state.scope else { return .none }

                state.selectedResultID = nil
                state.phase = .idle(query: state.query, scope: newScope, results: [])

                if newScope == .barcode {
                    return .cancel(id: CancelID.search)
                }

                let rawQuery = state.query
                let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedQuery.isEmpty else {
                    if newScope == .all || newScope == .history {
                        // Recents are owned by a separate component; catalog state
                        // simply becomes idle for an empty query.
                    }
                    return .cancel(id: CancelID.search)
                }
                guard let apiScope = newScope.foodSearchScope else {
                    return .cancel(id: CancelID.search)
                }

                let requestID = uuid()
                let previousResults = state.phase.results
                state.phase = .loading(
                    requestID: requestID,
                    query: rawQuery,
                    scope: newScope,
                    previousResults: previousResults
                )

                return .run { send in
                    do {
                        let items = try await foodSearchClient.search(normalizedQuery, apiScope)
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: newScope,
                            result: .success(items)
                        ))
                    } catch let error as FoodSearchServiceError {
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: newScope,
                            result: .failure(error)
                        ))
                    } catch {
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: newScope,
                            result: .failure(FoodSearchServiceError(foodSearchErrorMessage(error)))
                        ))
                    }
                }
                .cancellable(id: CancelID.search, cancelInFlight: true)

            case .updateContext(let date, let mealSlot):
                guard state.originDate != date || state.originMealSlot != mealSlot else {
                    return .none
                }
                state.originDate = date
                state.originMealSlot = mealSlot
                state.selectedResultID = nil
                if state.scope != .barcode, state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.phase = .idle(query: state.query, scope: state.scope, results: [])
                }
                return .none

            case .selectResult(let id):
                guard state.results.contains(where: { $0.id == id }) else { return .none }
                state.selectedResultID = id
                return .send(.delegate(.selectedFood(
                    id: id,
                    date: state.originDate,
                    mealSlot: state.originMealSlot,
                    generation: state.sessionGeneration
                )))

            case .searchDebounced(let requestID, let query, let scope):
                guard case .debouncing(let currentRequestID, let currentQuery, let currentScope, _) = state.phase,
                      currentRequestID == requestID,
                      currentQuery == query,
                      currentScope == scope else {
                    return .none
                }
                guard scope != .barcode else {
                    state.phase = .idle(query: query, scope: .barcode, results: [])
                    return .cancel(id: CancelID.search)
                }
                let rawQuery = query
                let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedQuery.isEmpty else {
                    state.phase = .idle(query: query, scope: scope, results: [])
                    return .cancel(id: CancelID.search)
                }
                guard let apiScope = scope.foodSearchScope else {
                    state.phase = .idle(query: query, scope: scope, results: [])
                    return .cancel(id: CancelID.search)
                }

                let previousResults = state.phase.results
                state.phase = .loading(
                    requestID: requestID,
                    query: rawQuery,
                    scope: scope,
                    previousResults: previousResults
                )
                state.selectedResultID = nil

                return .run { send in
                    do {
                        let items = try await foodSearchClient.search(normalizedQuery, apiScope)
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: scope,
                            result: .success(items)
                        ))
                    } catch let error as FoodSearchServiceError {
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: scope,
                            result: .failure(error)
                        ))
                    } catch {
                        await send(.resultReceived(
                            requestID: requestID,
                            query: rawQuery,
                            scope: scope,
                            result: .failure(FoodSearchServiceError(foodSearchErrorMessage(error)))
                        ))
                    }
                }
                .cancellable(id: CancelID.search, cancelInFlight: true)

            case .resultReceived(let requestID, let query, let scope, let result):
                guard case .loading(let loadingRequestID, let loadingQuery, let loadingScope, let previousResults) = state.phase,
                      loadingRequestID == requestID,
                      loadingQuery == query,
                      loadingScope == scope else {
                    return .none
                }

                switch result {
                case .success(let items):
                    state.phase = .loaded(
                        requestID: requestID,
                        query: query,
                        scope: scope,
                        results: items
                    )
                    state.selectedResultID = nil
                    return .none

                case .failure(let error):
                    if isCancelledFoodSearchError(error as Error) {
                        state.phase = .idle(query: query, scope: scope, results: [])
                        state.selectedResultID = nil
                        return .none
                    }

                    if isUnauthorizedFoodSearchError(error as Error) {
                        state.phase = .idle(query: "", scope: scope, results: [])
                        state.selectedResultID = nil
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }

                    let message = foodSearchErrorMessage(error as Error)
                    state.phase = .failed(
                        requestID: requestID,
                        query: query,
                        scope: scope,
                        message: message.isEmpty ? String(localized: "search.error.generic") : message,
                        previousResults: previousResults
                    )
                    state.selectedResultID = nil
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
