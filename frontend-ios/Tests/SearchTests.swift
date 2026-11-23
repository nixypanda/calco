// SearchTests layout helpers build a window from a connected app
// `UIWindowScene`, preferring a foreground-active scene and falling back to any
// connected scene. Test hosts can briefly have no active scene after launch;
// layout only needs a scene for screen/trait environment, not activation. The
// scene-based initializer avoids the `UIWindow(frame:)` / `UIWindow()`
// deprecations while still giving the hosting controller a real window.

import Combine
import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@testable import CalCo

private actor FakeFoodSearchService: FoodSearchServicing {
    enum Mode: Sendable {
        case automatic
        case manual
    }

    private struct Call: Sendable {
        let query: String
        let scope: FoodSearchScope
    }

    private let mode: Mode
    private var automaticResult: Result<[FoodSearchResult], Error> = .success([])
    private var calls: [Call] = []
    private var pending: [String: CheckedContinuation<[FoodSearchResult], Error>] = [:]
    private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(mode: Mode = .automatic) {
        self.mode = mode
    }

    func setResults(_ results: [FoodSearchResult]) {
        automaticResult = .success(results)
    }

    func setError(_ error: Error) {
        automaticResult = .failure(error)
    }

    func callCount() -> Int {
        calls.count
    }

    func recordedQueries() -> [String] {
        calls.map(\.query)
    }

    func lastScope() -> FoodSearchScope? {
        calls.last?.scope
    }

    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult] {
        calls.append(Call(query: query, scope: scope))
        resumeRequestWaiters(for: query)

        switch mode {
        case .automatic:
            return try automaticResult.get()
        case .manual:
            return try await withCheckedThrowingContinuation { continuation in
                pending[query] = continuation
            }
        }
    }

    func waitForRequest(_ query: String) async {
        guard !calls.contains(where: { $0.query == query }) else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[query, default: []].append(continuation)
        }
    }

    @discardableResult
    func resolve(
        _ query: String,
        with result: Result<[FoodSearchResult], Error>
    ) -> Bool {
        guard let continuation = pending.removeValue(forKey: query) else {
            return false
        }
        continuation.resume(with: result)
        return true
    }

    private func resumeRequestWaiters(for query: String) {
        guard let waiters = requestWaiters.removeValue(forKey: query) else { return }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
final class SearchTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    private func makeViewModel(
        service: FoodSearchServicing,
        date: LocalDiaryDate? = nil,
        slot: MealSlot? = nil,
        debounceNanoseconds: UInt64 = 0,
        onSelect: @escaping (String, LocalDiaryDate, MealSlot?) -> Void = { _, _, _ in },
        onExpired: @escaping () -> Void = {}
    ) -> SearchViewModel {
        SearchViewModel(
            originDate: date ?? self.date,
            originMealSlot: slot,
            service: service,
            debounceNanoseconds: debounceNanoseconds,
            onSelectFood: onSelect,
            onSessionExpired: onExpired
        )
    }

    private func waitForState(
        _ expected: SearchLoadState,
        on viewModel: SearchViewModel
    ) async {
        if viewModel.state == expected {
            return
        }
        let stateExpectation = expectation(description: "state becomes \(expected)")
        stateExpectation.assertForOverFulfill = false
        var cancellable: AnyCancellable?
        cancellable = viewModel.$state
            .dropFirst()
            .sink { state in
                if state == expected {
                    stateExpectation.fulfill()
                }
            }
        await fulfillment(of: [stateExpectation], timeout: 2)
        cancellable?.cancel()
    }

    private func waitForLoaded(on viewModel: SearchViewModel) async {
        if isLoaded(viewModel.state) {
            return
        }
        let loaded = expectation(description: "state becomes loaded")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$state
            .dropFirst()
            .sink { state in
                if self.isLoaded(state) {
                    loaded.fulfill()
                }
            }
        await fulfillment(of: [loaded], timeout: 2)
        cancellable?.cancel()
    }

    private func waitForFailure(on viewModel: SearchViewModel) async {
        if case .failed = viewModel.state {
            return
        }
        let failed = expectation(description: "state becomes failed")
        var cancellable: AnyCancellable?
        cancellable = viewModel.$state
            .dropFirst()
            .sink { state in
                if case .failed = state {
                    failed.fulfill()
                }
            }
        await fulfillment(of: [failed], timeout: 2)
        cancellable?.cancel()
    }

    private func isLoaded(_ state: SearchLoadState) -> Bool {
        if case .loaded = state { return true }
        return false
    }

    private func settleMainActor() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await Task.yield()
                continuation.resume()
            }
        }
    }

    func testWhitespaceQueryStaysIdleAndClearsPreviousResults() async {
        let service = FakeFoodSearchService()
        await service.setResults([FoodSearchResult(id: "food-1", name: "Chicken")])
        let vm = makeViewModel(service: service)

        vm.queryChanged("chick")
        await waitForLoaded(on: vm)
        XCTAssertEqual(vm.results.map(\.id), ["food-1"])

        vm.queryChanged("   \n")
        XCTAssertEqual(vm.query, "   \n")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)

        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testSearchReturnsResultsForCurrentQuery() async {
        let service = FakeFoodSearchService()
        await service.setResults([
            FoodSearchResult(id: "food-1", name: "Chicken", brand: "Brand"),
            FoodSearchResult(id: "food-2", name: "Rice", brand: nil),
        ])
        let vm = makeViewModel(service: service, slot: .lunch)

        vm.queryChanged("chick")
        await waitForLoaded(on: vm)

        XCTAssertEqual(vm.results.map(\.id), ["food-1", "food-2"])
        let queries = await service.recordedQueries()
        XCTAssertEqual(queries, ["chick"])
        let scope = await service.lastScope()
        XCTAssertEqual(scope, .all)
    }

    func testEmptyResultsClearOldResultsAndSelection() async {
        let service = FakeFoodSearchService()
        await service.setResults([FoodSearchResult(id: "old", name: "Old")])
        var selectedIDs: [String] = []
        let vm = makeViewModel(service: service) { id, _, _ in
            selectedIDs.append(id)
        }

        vm.queryChanged("old")
        await waitForLoaded(on: vm)
        XCTAssertEqual(vm.results.count, 1)
        vm.selectResult(vm.results[0])
        XCTAssertEqual(vm.selectedResultID, "old")

        await service.setResults([])
        vm.queryChanged("nothing")
        await waitForState(.empty, on: vm)

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)
        XCTAssertEqual(selectedIDs, ["old"])
    }

    func testFailureClearsDataAndBlankMessageUsesGenericError() async {
        let service = FakeFoodSearchService()
        await service.setResults([FoodSearchResult(id: "old", name: "Old")])
        let vm = makeViewModel(service: service)

        vm.queryChanged("old")
        await waitForLoaded(on: vm)
        XCTAssertEqual(vm.results.count, 1)
        vm.selectResult(vm.results[0])
        XCTAssertEqual(vm.selectedResultID, "old")

        await service.setError(FoodSearchServiceError("   "))
        vm.queryChanged("broken")
        await waitForState(
            .failed(String(localized: "search.error.generic")),
            on: vm
        )

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)

        await service.setResults([FoodSearchResult(id: "new", name: "New")])
        vm.retry()
        await waitForLoaded(on: vm)
        XCTAssertEqual(vm.results.map(\.id), ["new"])
    }

    func testClearQueryCancelsPendingRequestAndClearsSelection() async {
        let service = FakeFoodSearchService(mode: .manual)
        let vm = makeViewModel(service: service)

        vm.queryChanged("seed")
        await service.waitForRequest("seed")
        let seeded = await service.resolve(
            "seed",
            with: .success([FoodSearchResult(id: "old", name: "Old")])
        )
        XCTAssertTrue(seeded)
        await waitForLoaded(on: vm)
        vm.selectResult(vm.results[0])
        XCTAssertEqual(vm.selectedResultID, "old")

        vm.queryChanged("pending")
        await service.waitForRequest("pending")
        vm.clearQuery()

        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)

        let resolved = await service.resolve(
            "pending",
            with: .success([FoodSearchResult(id: "stale", name: "Stale")])
        )
        XCTAssertTrue(resolved)
        await settleMainActor()

        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testDebouncedQueryWaitsBeforeCallingService() async throws {
        let service = FakeFoodSearchService()
        await service.setResults([FoodSearchResult(id: "food-1", name: "Chicken")])
        let vm = makeViewModel(service: service, debounceNanoseconds: 500_000_000)

        vm.queryChanged("chick")
        try await Task.sleep(nanoseconds: 20_000_000)

        let earlyCount = await service.callCount()
        XCTAssertEqual(earlyCount, 0)

        await waitForLoaded(on: vm)
        let queries = await service.recordedQueries()
        XCTAssertEqual(queries, ["chick"])
    }

    func testRepeatedProgrammaticSearchesShareOneInFlightRequest() async {
        let service = FakeFoodSearchService(mode: .manual)
        let vm = makeViewModel(service: service)

        vm.search("chick")
        await service.waitForRequest("chick")

        vm.search("chick")
        vm.submitSearch()
        vm.performSearch()
        vm.queryChanged("chick")
        await settleMainActor()

        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)

        let resolved = await service.resolve(
            "chick",
            with: .success([FoodSearchResult(id: "food-1", name: "Chicken")])
        )
        XCTAssertTrue(resolved)
        await waitForLoaded(on: vm)
        XCTAssertEqual(vm.results.map(\.id), ["food-1"])
    }

    func testStaleSuccessResponseCannotReplaceNewerResults() async {
        let service = FakeFoodSearchService(mode: .manual)
        let vm = makeViewModel(service: service)

        vm.queryChanged("first")
        await service.waitForRequest("first")
        vm.queryChanged("second")
        await service.waitForRequest("second")

        let secondResolved = await service.resolve(
            "second",
            with: .success([FoodSearchResult(id: "new", name: "New")])
        )
        XCTAssertTrue(secondResolved)
        await waitForLoaded(on: vm)
        XCTAssertEqual(vm.results.map(\.id), ["new"])

        let firstResolved = await service.resolve(
            "first",
            with: .success([FoodSearchResult(id: "old", name: "Old")])
        )
        XCTAssertTrue(firstResolved)
        await settleMainActor()

        XCTAssertTrue(isLoaded(vm.state))
        XCTAssertEqual(vm.results.map(\.id), ["new"])
    }

    func testStaleFailureResponseCannotReplaceNewerSuccess() async {
        let service = FakeFoodSearchService(mode: .manual)
        let vm = makeViewModel(service: service)

        vm.queryChanged("first")
        await service.waitForRequest("first")
        vm.queryChanged("second")
        await service.waitForRequest("second")

        let secondResolved = await service.resolve(
            "second",
            with: .success([FoodSearchResult(id: "new", name: "New")])
        )
        XCTAssertTrue(secondResolved)
        await waitForLoaded(on: vm)

        let firstResolved = await service.resolve(
            "first",
            with: .failure(FoodSearchServiceError("stale failure"))
        )
        XCTAssertTrue(firstResolved)
        await settleMainActor()

        XCTAssertTrue(isLoaded(vm.state))
        XCTAssertEqual(vm.results.map(\.id), ["new"])
    }

    func testInvalidateSessionClearsDataAndIgnoresInFlightResponse() async {
        let service = FakeFoodSearchService(mode: .manual)
        var selectedIDs: [String] = []
        let vm = makeViewModel(service: service) { id, _, _ in
            selectedIDs.append(id)
        }

        vm.queryChanged("seed")
        await service.waitForRequest("seed")
        let seeded = await service.resolve(
            "seed",
            with: .success([FoodSearchResult(id: "old", name: "Old")])
        )
        XCTAssertTrue(seeded)
        await waitForLoaded(on: vm)
        vm.selectResult(vm.results[0])
        XCTAssertEqual(selectedIDs, ["old"])

        vm.invalidateSession()
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)

        vm.queryChanged("session")
        await service.waitForRequest("session")
        vm.invalidateSession()

        let staleResolved = await service.resolve(
            "session",
            with: .success([FoodSearchResult(id: "stale", name: "Stale")])
        )
        XCTAssertTrue(staleResolved)
        await settleMainActor()

        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertEqual(selectedIDs, ["old"])
    }

    func testStaleUnauthorizedAfterInvalidationDoesNotExpireSession() async {
        let service = FakeFoodSearchService(mode: .manual)
        var expirationCount = 0
        let vm = makeViewModel(service: service, onExpired: { expirationCount += 1 })

        vm.queryChanged("old-session")
        await service.waitForRequest("old-session")
        vm.invalidateSession()

        let resolved = await service.resolve(
            "old-session",
            with: .failure(CalCoAPIError.unauthorized(nil))
        )
        XCTAssertTrue(resolved)
        await settleMainActor()

        XCTAssertEqual(expirationCount, 0)
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testUnauthorizedCallsSessionExpiredAndClearsData() async {
        let service = FakeFoodSearchService()
        await service.setResults([FoodSearchResult(id: "old", name: "Old")])
        var expirationCount = 0
        let vm = makeViewModel(service: service, onExpired: { expirationCount += 1 })

        vm.queryChanged("chick")
        await waitForLoaded(on: vm)
        vm.selectResult(vm.results[0])
        XCTAssertEqual(vm.selectedResultID, "old")

        await service.setError(CalCoAPIError.unauthorized(nil))
        vm.search("chick")
        await waitForState(.idle, on: vm)

        XCTAssertEqual(expirationCount, 1, "Unauthorized search fires the session callback once")
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertFalse(vm.isSearching, "Unauthorized cleanup must clear the loading flag")
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)
    }

    func testFoodSearchServiceUnauthorizedExpiresSession() async {
        let service = FakeFoodSearchService()
        await service.setError(FoodSearchServiceError.unauthorized)
        let expired = expectation(description: "session expired")
        let vm = makeViewModel(service: service, onExpired: { expired.fulfill() })

        vm.queryChanged("chick")
        await fulfillment(of: [expired], timeout: 2)

        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testTypedUnauthorizedErrorsAreRecognized() {
        XCTAssertTrue(isUnauthorizedFoodSearchError(FoodSearchServiceError.unauthorized))
        XCTAssertTrue(isUnauthorizedFoodSearchError(FoodSearchServiceError("", isUnauthorized: true)))
        XCTAssertTrue(isUnauthorizedFoodSearchError(CalCoAPIError.unauthorized(nil)))
        XCTAssertFalse(isUnauthorizedFoodSearchError(FoodSearchServiceError("server error")))
        XCTAssertFalse(isUnauthorizedFoodSearchError(NSError(domain: "legacy", code: 401)))
    }

    func testLegacyNSError401DoesNotExpireSession() async {
        let service = FakeFoodSearchService()
        await service.setError(NSError(domain: "legacy", code: 401))
        var expirationCount = 0
        let vm = makeViewModel(service: service, onExpired: { expirationCount += 1 })

        vm.queryChanged("chick")
        await waitForFailure(on: vm)

        XCTAssertEqual(expirationCount, 0)
        XCTAssertEqual(vm.query, "chick")
        if case .failed = vm.state {
        } else {
            XCTFail("expected a failure state")
        }
    }

    func testCancellationErrorDoesNotBecomeAUserFacingFailure() async {
        let service = FakeFoodSearchService()
        await service.setError(CalCoAPIError.cancelled)
        let vm = makeViewModel(service: service)

        vm.queryChanged("chick")
        await waitForState(.idle, on: vm)

        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.selectedResultID)
    }

    func testLoadedStateAlwaysCarriesResults() {
        XCTAssertNil(FoodSearchResults([]))
        let loaded = FoodSearchResults([FoodSearchResult(id: "food-1", name: "Chicken")])
        XCTAssertNotNil(loaded)

        XCTAssertEqual(SearchLoadState.idle.results, [])
        XCTAssertEqual(SearchLoadState.loading.results, [])
        XCTAssertEqual(SearchLoadState.empty.results, [])
        XCTAssertEqual(SearchLoadState.failed("boom").results, [])
        if let loaded {
            XCTAssertEqual(SearchLoadState.loaded(loaded).results.map(\.id), ["food-1"])
        }
    }

    func testSelectionUsesUpdatedContextAndIgnoresDuplicateTaps() async {
        let service = FakeFoodSearchService()
        let updatedDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
        var selections: [(id: String, date: LocalDiaryDate, slot: MealSlot?)] = []
        let vm = makeViewModel(
            service: service,
            slot: .lunch,
            onSelect: { id, date, slot in
                selections.append((id, date, slot))
            }
        )

        vm.updateContext(date: updatedDate, mealSlot: .snack)
        let result = FoodSearchResult(id: "food-42", name: "Tofu")

        vm.selectResult(result)
        vm.selectResult(result)

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.id, "food-42")
        XCTAssertEqual(selections.first?.date, updatedDate)
        XCTAssertEqual(selections.first?.slot, .snack)
        XCTAssertEqual(vm.selectedResultID, "food-42")

        vm.clearSelection()
        vm.selectResult(result)
        XCTAssertEqual(selections.count, 2)

        let laterDate = LocalDiaryDate(year: 2026, month: 12, day: 1)
        vm.updateContext(date: laterDate, mealSlot: .breakfast)
        XCTAssertNil(vm.selectedResultID)

        vm.selectResult(result)
        XCTAssertEqual(selections.count, 3)
        XCTAssertEqual(selections.last?.date, laterDate)
        XCTAssertEqual(selections.last?.slot, .breakfast)
    }

    func testSearchViewRendersLocalizedTextField() {
        let vm = makeViewModel(service: FakeFoodSearchService())
        let view = SearchView(viewModel: vm).frame(width: 390, height: 640)

        #if canImport(UIKit)
        let hosting = UIHostingController(rootView: view)
        hosting.loadViewIfNeeded()
        guard let window = makeLayoutWindow(width: 390, height: 640) else {
            XCTFail("Hosted test app must provide a UIWindowScene for layout")
            return
        }
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        let placeholder = firstSubview(in: hosting.view, as: UITextField.self)?.placeholder
        window.isHidden = true
        #elseif canImport(AppKit)
        let hosting = NSHostingController(rootView: view)
        hosting.loadView()
        hosting.view.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
        hosting.view.layoutSubtreeIfNeeded()
        let placeholder = firstSubview(
            in: hosting.view,
            as: NSTextField.self,
            matching: { $0.placeholderString != nil }
        )?.placeholderString
        #else
        let placeholder: String? = nil
        #endif

        XCTAssertEqual(placeholder, String(localized: "search.prompt"))
    }

    func testSearchViewAccessibility5FieldFitsCompactWidth() {
        let vm = makeViewModel(service: FakeFoodSearchService())
        let view = SearchView(viewModel: vm)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: 320, height: 568)
        let prompt = String(localized: "search.prompt")

        #if canImport(UIKit)
        let hosting = UIHostingController(rootView: view)
        hosting.loadViewIfNeeded()
        guard let window = makeLayoutWindow(width: 320, height: 568) else {
            XCTFail("Hosted test app must provide a UIWindowScene for layout")
            return
        }
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        let field = firstSubview(in: hosting.view, as: UITextField.self, matching: { $0.placeholder == prompt })
        let placeholder = field?.placeholder
        let fieldFrame = field.map { $0.convert($0.bounds, to: hosting.view) }
        window.isHidden = true
        #elseif canImport(AppKit)
        let hosting = NSHostingController(rootView: view)
        hosting.loadView()
        hosting.view.frame = NSRect(x: 0, y: 0, width: 320, height: 568)
        hosting.view.layoutSubtreeIfNeeded()
        let field = firstSubview(in: hosting.view, as: NSTextField.self, matching: { $0.placeholderString == prompt })
        let placeholder = field?.placeholderString
        let fieldFrame = field.map { $0.convert($0.bounds, to: hosting.view) }
        #else
        let placeholder: String? = nil
        let fieldFrame: CGRect? = nil
        #endif

        XCTAssertEqual(placeholder, prompt)
        XCTAssertNotNil(fieldFrame)
        guard let fieldFrame else { return }
        XCTAssertGreaterThan(fieldFrame.width, 0)
        XCTAssertGreaterThan(fieldFrame.height, 0)
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, 0)
        XCTAssertLessThanOrEqual(fieldFrame.maxX, 320)
        XCTAssertGreaterThanOrEqual(fieldFrame.minY, 0)
        XCTAssertLessThanOrEqual(fieldFrame.maxY, 568)
    }

    #if canImport(UIKit)
    private func makeLayoutWindow(width: CGFloat, height: CGFloat) -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first else {
            XCTFail("Hosted test app must provide a UIWindowScene for layout")
            return nil
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return window
    }

    private func firstSubview<View: UIView>(
        in view: UIView,
        as type: View.Type,
        matching: (View) -> Bool = { _ in true }
    ) -> View? {
        if let match = view as? View, matching(match) { return match }
        for subview in view.subviews {
            if let match = firstSubview(in: subview, as: type, matching: matching) { return match }
        }
        return nil
    }
    #endif

    #if canImport(AppKit)
    private func firstSubview<View: NSView>(
        in view: NSView,
        as type: View.Type,
        matching: (View) -> Bool = { _ in true }
    ) -> View? {
        if let match = view as? View, matching(match) { return match }
        for subview in view.subviews {
            if let match = firstSubview(in: subview, as: type, matching: matching) { return match }
        }
        return nil
    }
    #endif
}
