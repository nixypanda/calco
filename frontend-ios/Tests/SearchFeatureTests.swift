import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class SearchFeatureTests: XCTestCase {
    private let requestID = UUID()
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let nextDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let generation = UInt64(42)

    private var result: FoodSearchResult {
        FoodSearchResult(id: "food-1", name: "Oats", brand: "CalCo")
    }

    private func makeClient(
        search: @escaping @Sendable (String, FoodSearchScope) async throws -> [FoodSearchResult]
    ) -> FoodSearchClient {
        FoodSearchClient(search: search)
    }

    private final class QueryCapture: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var queries: [String] = []

        func append(_ query: String) {
            lock.withLock { queries.append(query) }
        }
    }

    func testDebounceLoadsCatalogResult() async {
        let result = self.result
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let clock = TestClock()
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                query: "",
                scope: .all,
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in [result] }
            $0.uuid = .constant(requestID)
            $0.continuousClock = clock
        }

        await store.send(.queryChanged("ab")) {
            $0.phase = .debouncing(
                requestID: requestID,
                query: "ab",
                scope: .all,
                previousResults: []
            )
        }
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.searchDebounced) {
            $0.phase = .loading(
                requestID: requestID,
                query: "ab",
                scope: .all,
                previousResults: []
            )
        }
        await store.receive(\.resultReceived) {
            $0.phase = .loaded(
                requestID: requestID,
                query: "ab",
                scope: .all,
                results: [result]
            )
        }
        await store.finish()
    }

    func testEmptyQueryClearsToIdle() async {
        let result = self.result
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                phase: .loaded(
                    requestID: requestID,
                    query: "oats",
                    scope: .all,
                    results: [result]
                ),
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in [result] }
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
        }

        await store.send(.queryChanged("")) {
            $0.phase = .idle(query: "", scope: .all, results: [])
        }
        await store.finish()
    }

    func testVisibleResultsRemainWhileDebouncing() async {
        let result = self.result
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                phase: .loaded(
                    requestID: requestID,
                    query: "oats",
                    scope: .all,
                    results: [result]
                ),
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in [result] }
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
        }

        let task = await store.send(.queryChanged("oat")) {
            $0.phase = .debouncing(
                requestID: self.requestID,
                query: "oat",
                scope: .all,
                previousResults: [result]
            )
        }
        XCTAssertEqual(store.state.results, [result])
        await task.cancel()
        await store.finish()
    }

    func testScopeChangeToBarcodeCancelsCatalogWork() async {
        let result = self.result
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                phase: .loaded(
                    requestID: requestID,
                    query: "oats",
                    scope: .all,
                    results: [result]
                ),
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in [result] }
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
        }

        await store.send(.scopeChanged(.barcode)) {
            $0.phase = .idle(query: "oats", scope: .barcode, results: [])
        }
        await store.finish()
    }

    func testUnauthorizedSearchEmitsCapturedGeneration() async {
        let result = self.result
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let clock = TestClock()
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                query: "",
                scope: .all,
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in
                throw FoodSearchServiceError.unauthorized
            }
            $0.uuid = .constant(requestID)
            $0.continuousClock = clock
        }

        await store.send(.queryChanged("ab")) {
            $0.phase = .debouncing(
                requestID: requestID,
                query: "ab",
                scope: .all,
                previousResults: []
            )
        }
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.searchDebounced) {
            $0.phase = .loading(
                requestID: requestID,
                query: "ab",
                scope: .all,
                previousResults: []
            )
        }
        await store.receive(\.resultReceived) {
            $0.phase = .idle(query: "", scope: .all, results: [])
        }
        await store.receive(\.delegate, .sessionExpired(generation: generation))
        await store.finish()
    }

    func testStaleResponseIsIgnored() async {
        let result = self.result
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let clock = TestClock()
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                query: "",
                scope: .all,
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { query, _ in
                if query == "ab" {
                    return [result]
                }
                return []
            }
            $0.uuid = .incrementing
            $0.continuousClock = clock
        }

        await store.send(.queryChanged("ab")) {
            $0.phase = .debouncing(
                requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                query: "ab",
                scope: .all,
                previousResults: []
            )
        }
        await store.send(.queryChanged("abc")) {
            $0.phase = .debouncing(
                requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                query: "abc",
                scope: .all,
                previousResults: []
            )
        }

        await clock.advance(by: .milliseconds(300))

        // Only the latest debounced request should become loading.
        let secondRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        await store.receive(\.searchDebounced) {
            $0.phase = .loading(
                requestID: secondRequestID,
                query: "abc",
                scope: .all,
                previousResults: []
            )
        }
        await store.receive(\.resultReceived) {
            $0.phase = .loaded(
                requestID: secondRequestID,
                query: "abc",
                scope: .all,
                results: []
            )
        }

        // The stale first request, if delivered, must not change state.
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        await store.send(.resultReceived(
            requestID: firstRequestID,
            query: "ab",
            scope: .all,
            result: .success([result])
        ))
        await store.finish()
    }

    func testSelectResultEmitsCapturedContext() async {
        let result = self.result
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                phase: .loaded(
                    requestID: requestID,
                    query: "oats",
                    scope: .all,
                    results: [result]
                ),
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in [result] }
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
        }

        await store.send(.selectResult(id: result.id)) {
            $0.selectedResultID = result.id
        }
        await store.receive(\.delegate, .selectedFood(
            id: result.id,
            date: date,
            mealSlot: nil,
            generation: generation
        ))
        await store.finish()
    }

    func testContextUpdatePreservesResultsAndClearsSelection() async {
        let result = self.result
        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                phase: .loaded(
                    requestID: requestID,
                    query: "oats",
                    scope: .all,
                    results: [result]
                ),
                sessionGeneration: generation,
                selectedResultID: result.id
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { _, _ in [result] }
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
        }

        await store.send(.updateContext(date: nextDate, mealSlot: nil)) {
            $0.originDate = self.nextDate
            $0.selectedResultID = nil
        }
        XCTAssertEqual(store.state.results, [result])
        await store.finish()
    }

    func testRawQuerySpacesPreservedAndOnlyLatestTrimmedRequestFires() async {
        let result = self.result
        let clock = TestClock()
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let secondRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                query: "",
                scope: .all,
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { query, scope in
                XCTAssertEqual(query, "oat m")
                XCTAssertEqual(scope, .all)
                return [result]
            }
            $0.uuid = .incrementing
            $0.continuousClock = clock
        }

        await store.send(.queryChanged("oat ")) {
            $0.phase = .debouncing(
                requestID: firstRequestID,
                query: "oat ",
                scope: .all,
                previousResults: []
            )
        }
        XCTAssertEqual(store.state.query, "oat ")

        await store.send(.queryChanged("oat m ")) {
            $0.phase = .debouncing(
                requestID: secondRequestID,
                query: "oat m ",
                scope: .all,
                previousResults: []
            )
        }
        XCTAssertEqual(store.state.query, "oat m ")

        await clock.advance(by: .milliseconds(300))

        await store.receive(\.searchDebounced) {
            $0.phase = .loading(
                requestID: secondRequestID,
                query: "oat m ",
                scope: .all,
                previousResults: []
            )
        }
        XCTAssertEqual(store.state.query, "oat m ")
        await store.receive(\.resultReceived) {
            $0.phase = .loaded(
                requestID: secondRequestID,
                query: "oat m ",
                scope: .all,
                results: [result]
            )
        }
        XCTAssertEqual(store.state.query, "oat m ")
        await store.finish()
    }

    func testTrailingSpaceSurvivesCompletedDebounceAndTypingContinues() async {
        let result = self.result
        let clock = TestClock()
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let secondRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let capture = QueryCapture()

        let store = TestStore(
            initialState: SearchFeature.State(
                originDate: date,
                originMealSlot: nil,
                query: "",
                scope: .all,
                sessionGeneration: generation
            )
        ) {
            SearchFeature()
        } withDependencies: {
            $0.foodSearchClient = makeClient { query, _ in
                capture.append(query)
                return [result]
            }
            $0.uuid = .incrementing
            $0.continuousClock = clock
        }

        // Pause past the debounce window while the field still shows a trailing space.
        await store.send(.queryChanged("oat ")) {
            $0.phase = .debouncing(
                requestID: firstRequestID,
                query: "oat ",
                scope: .all,
                previousResults: []
            )
        }
        XCTAssertEqual(store.state.query, "oat ")
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.searchDebounced) {
            $0.phase = .loading(
                requestID: firstRequestID,
                query: "oat ",
                scope: .all,
                previousResults: []
            )
        }
        XCTAssertEqual(store.state.query, "oat ")
        await store.receive(\.resultReceived) {
            $0.phase = .loaded(
                requestID: firstRequestID,
                query: "oat ",
                scope: .all,
                results: [result]
            )
        }
        XCTAssertEqual(store.state.query, "oat ")

        // The next keystroke must append after the preserved space, not replace it.
        await store.send(.queryChanged("oat m")) {
            $0.phase = .debouncing(
                requestID: secondRequestID,
                query: "oat m",
                scope: .all,
                previousResults: [result]
            )
        }
        XCTAssertEqual(store.state.query, "oat m")
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.searchDebounced) {
            $0.phase = .loading(
                requestID: secondRequestID,
                query: "oat m",
                scope: .all,
                previousResults: [result]
            )
        }
        XCTAssertEqual(store.state.query, "oat m")
        await store.receive(\.resultReceived) {
            $0.phase = .loaded(
                requestID: secondRequestID,
                query: "oat m",
                scope: .all,
                results: [result]
            )
        }
        XCTAssertEqual(store.state.query, "oat m")
        XCTAssertEqual(capture.queries, ["oat", "oat m"])
        await store.finish()
    }
}
