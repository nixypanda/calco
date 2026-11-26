import Clocks
import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class SearchHistoryFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 5, day: 10)
    private let otherDate = LocalDiaryDate(year: 2026, month: 5, day: 11)
    private let generation: UInt64 = 7

    func testLoadRecentsGuardsWhenInFlightAndRefreshReplacesInFlight() async {
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let secondRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondResponse = [Self.makeRecentItem(id: "product-2", name: "Second")]
        let client = ControlledRecentItemsClient()

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .lunch,
                sessionGeneration: generation
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.searchHistoryClient.recentItems = { @Sendable from, to, mealSlot in
                XCTAssertEqual(from, self.date.addingDays(-30))
                XCTAssertEqual(to, self.date)
                XCTAssertEqual(mealSlot, .lunch)
                return try await client.next()
            }
        }

        await store.send(.loadRecents) {
            $0.recents = .loading(
                requestID: firstRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                priorItems: []
            )
        }

        // Normal load is guarded while already loading.
        await store.send(.loadRecents)

        await store.send(.refreshRecents) {
            $0.recents = .loading(
                requestID: secondRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                priorItems: []
            )
        }

        await client.resumeNext(with: .success(secondResponse))
        await store.receive(\.recentsResponse) {
            $0.recents = .loaded(
                requestID: secondRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                items: secondResponse
            )
        }
    }

    func testContextChangeInvalidatesOldRecentsAndStaleResponseIsIgnored() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let staleItems = [Self.makeRecentItem(id: "product-1", name: "Stale")]
        let client = ControlledRecentItemsClient()

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .lunch,
                sessionGeneration: generation
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.searchHistoryClient.recentItems = { @Sendable _, _, _ in
                try await client.next()
            }
        }

        await store.send(.loadRecents) {
            $0.recents = .loading(
                requestID: requestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                priorItems: []
            )
        }
        await client.waitUntilPendingCount(1)

        await store.send(.contextChanged(date: otherDate, mealSlot: .dinner)) {
            $0.contextDate = self.otherDate
            $0.contextMealSlot = .dinner
            $0.recents = .idle
        }
        await store.finish()
        XCTAssertEqual(store.state.recents, .idle)

        // Old response is explicitly injected after cancellation; stale guard must ignore it.
        await store.send(
            .recentsResponse(
                requestID: requestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                .success(staleItems)
            )
        )
        XCTAssertEqual(store.state.recents, .idle)
    }

    func testCategoryDebounceCancelsPreviousAndKeepsOldChipsVisibleUntilReplacement() async {
        let clock = TestClock()
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let secondRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let oldSuggestions = [CategorySuggestion(value: "oat", count: 2)]
        let newSuggestions = [CategorySuggestion(value: "oats", count: 3)]

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .lunch,
                sessionGeneration: generation
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.searchHistoryClient.categorySuggestions = { @Sendable query, limit in
                XCTAssertEqual(limit, 8)
                switch query {
                case "oa": return oldSuggestions
                case "oat": return newSuggestions
                default: return []
                }
            }
        }

        await store.send(.categoryQueryChanged("oa")) {
            $0.categoryLookup = .debouncing(
                requestID: firstRequestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.categoryDebounceElapsed) {
            $0.categoryLookup = .loading(
                requestID: firstRequestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await store.receive(\.categoryResponse) {
            $0.categoryLookup = .loaded(
                requestID: firstRequestID,
                query: "oa",
                suggestions: oldSuggestions
            )
        }

        await store.send(.categoryQueryChanged("oat")) {
            $0.categoryLookup = .debouncing(
                requestID: secondRequestID,
                query: "oat",
                visibleSuggestions: oldSuggestions
            )
        }
        XCTAssertEqual(store.state.visibleCategorySuggestions, oldSuggestions)

        await clock.advance(by: .milliseconds(300))
        await store.receive(\.categoryDebounceElapsed) {
            $0.categoryLookup = .loading(
                requestID: secondRequestID,
                query: "oat",
                visibleSuggestions: oldSuggestions
            )
        }
        XCTAssertEqual(store.state.visibleCategorySuggestions, oldSuggestions)

        await store.receive(\.categoryResponse) {
            $0.categoryLookup = .loaded(
                requestID: secondRequestID,
                query: "oat",
                suggestions: newSuggestions
            )
        }
        XCTAssertEqual(store.state.visibleCategorySuggestions, newSuggestions)
    }

    func testUnauthorizedRecentsFailureEmitsSessionExpiredWithOriginalGeneration() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .breakfast,
                sessionGeneration: generation
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.searchHistoryClient.recentItems = { @Sendable _, _, _ in
                throw CalCoAPIError.unauthorized(nil)
            }
        }

        await store.send(.loadRecents) {
            $0.recents = .loading(
                requestID: requestID,
                contextDate: self.date,
                contextMealSlot: .breakfast,
                priorItems: []
            )
        }
        await store.receive(\.recentsResponse) {
            $0.recents = .failed(
                requestID: requestID,
                contextDate: self.date,
                contextMealSlot: .breakfast,
                message: ""
            )
        }
        await store.receive(\.delegate, .sessionExpired(generation: generation))
    }

    func testUnauthorizedCategoryFailureEmitsSessionExpiredWithOriginalGeneration() async {
        let clock = TestClock()
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .breakfast,
                sessionGeneration: generation
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.searchHistoryClient.categorySuggestions = { @Sendable _, _ in
                throw CalCoAPIError.unauthorized(nil)
            }
        }

        await store.send(.categoryQueryChanged("oa")) {
            $0.categoryLookup = .debouncing(
                requestID: requestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.categoryDebounceElapsed) {
            $0.categoryLookup = .loading(
                requestID: requestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await store.receive(\.categoryResponse) {
            $0.categoryLookup = .failed(
                requestID: requestID,
                query: "oa",
                visibleSuggestions: [],
                message: ""
            )
        }
        await store.receive(\.delegate, .sessionExpired(generation: generation))
    }

    func testLoadRecentsGuardedWhenAlreadyLoadedAndRefreshPreservesVisibleItems() async {
        let firstRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let refreshRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let loadedItems = [Self.makeRecentItem(id: "product-1", name: "Loaded")]
        let refreshedItems = [Self.makeRecentItem(id: "product-2", name: "Refreshed")]
        let client = ControlledRecentItemsClient()

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .lunch,
                sessionGeneration: generation
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.searchHistoryClient.recentItems = { @Sendable _, _, _ in
                try await client.next()
            }
        }

        await store.send(.loadRecents) {
            $0.recents = .loading(
                requestID: firstRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                priorItems: []
            )
        }
        await client.resumeNext(with: .success(loadedItems))
        await store.receive(\.recentsResponse) {
            $0.recents = .loaded(
                requestID: firstRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                items: loadedItems
            )
        }

        await store.send(.loadRecents)

        await store.send(.refreshRecents) {
            $0.recents = .loading(
                requestID: refreshRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                priorItems: loadedItems
            )
        }
        XCTAssertEqual(store.state.recents.visibleItems, loadedItems)

        await client.resumeNext(with: .success(refreshedItems))
        await store.receive(\.recentsResponse) {
            $0.recents = .loaded(
                requestID: refreshRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                items: refreshedItems
            )
        }
    }

    func testServiceCancellationSettlesRecentsAndCategoryWithoutClearingNewRequest() async {
        let recentsRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let categoryRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let oldSuggestions = [CategorySuggestion(value: "old", count: 1)]
        let clock = TestClock()

        let store = TestStore(
            initialState: SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: .lunch,
                sessionGeneration: generation,
                categoryLookup: .loaded(
                    requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                    query: "old",
                    suggestions: oldSuggestions
                )
            )
        ) {
            SearchHistoryFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = clock
            $0.searchHistoryClient.recentItems = { @Sendable _, _, _ in
                throw CancellationError()
            }
            $0.searchHistoryClient.categorySuggestions = { @Sendable _, _ in
                throw CancellationError()
            }
        }

        await store.send(.loadRecents) {
            $0.recents = .loading(
                requestID: recentsRequestID,
                contextDate: self.date,
                contextMealSlot: .lunch,
                priorItems: []
            )
        }
        await store.receive(\.recentsResponse) {
            $0.recents = .idle
        }

        await store.send(.categoryQueryChanged("new")) {
            $0.categoryLookup = .debouncing(
                requestID: categoryRequestID,
                query: "new",
                visibleSuggestions: oldSuggestions
            )
        }
        await clock.advance(by: .milliseconds(300))
        await store.receive(\.categoryDebounceElapsed) {
            $0.categoryLookup = .loading(
                requestID: categoryRequestID,
                query: "new",
                visibleSuggestions: oldSuggestions
            )
        }
        await store.receive(\.categoryResponse) {
            $0.categoryLookup = .loaded(
                requestID: categoryRequestID,
                query: "new",
                suggestions: oldSuggestions
            )
        }
    }

    private static func makeRecentItem(id: String, name: String) -> RecentLogItem {
        RecentLogItem(
            item: .product(ProductLogItemSnapshot(id: id, name: name)),
            lastUsedDate: LocalDiaryDate(year: 2026, month: 5, day: 9),
            mealSlot: .lunch,
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
    }
}

private final class ControlledRecentItemsClient: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<[RecentLogItem], Error>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var queuedResults: [Result<[RecentLogItem], Error>] = []
    private var pendingCountContinuations: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func next() async throws -> [RecentLogItem] {
        let immediateResult: Result<[RecentLogItem], Error>? = lock.withLock {
            guard !queuedResults.isEmpty else { return nil }
            return queuedResults.removeFirst()
        }
        if let immediateResult {
            return try immediateResult.get()
        }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    notifyPendingCountContinuationsLocked()
                }
            }
        } onCancel: {
            let waiter: Waiter? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func waitUntilPendingCount(_ count: Int) async {
        let shouldWait: Bool = lock.withLock {
            waiters.count < count
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if waiters.count >= count {
                    continuation.resume()
                } else {
                    pendingCountContinuations.append((count: count, continuation: continuation))
                }
            }
        }
    }

    func resumeNext(with result: Result<[RecentLogItem], Error>) {
        let waiter: Waiter? = lock.withLock {
            guard !waiters.isEmpty else {
                queuedResults.append(result)
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.continuation.resume(with: result)
    }

    private func notifyPendingCountContinuationsLocked() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for pending in pendingCountContinuations {
            if waiters.count >= pending.count {
                pending.continuation.resume()
            } else {
                remaining.append(pending)
            }
        }
        pendingCountContinuations = remaining
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
