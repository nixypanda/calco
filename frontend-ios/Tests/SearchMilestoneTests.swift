import XCTest

@testable import CalCo

private actor FakeHistorySearchService: FoodSearchServicing, FoodSearchHistoryServicing {
    struct RecentsCall: Sendable, Equatable {
        let from: LocalDiaryDate
        let to: LocalDiaryDate
        let mealSlot: MealSlot?
    }

    private var searchResults: [FoodSearchResult] = []
    private var searches: [(String, FoodSearchScope)] = []
    private var recents: [RecentLogItem] = []
    private var recentsCalls: [RecentsCall] = []
    private var firstRecentsDelayNanoseconds: UInt64 = 0
    private var recentsFailuresRemaining = 0
    private var categories: [CategorySuggestion] = []
    private var categoryQueries: [String] = []
    private var barcodeResult: Result<BarcodeLookup, Error> =
        .failure(CalCoAPIError.invalidResponse)
    private var barcodeQueries: [String] = []

    func setSearchResults(_ values: [FoodSearchResult]) { searchResults = values }
    func setRecents(_ values: [RecentLogItem]) { recents = values }
    func setFirstRecentsDelay(_ value: UInt64) { firstRecentsDelayNanoseconds = value }
    func failNextRecents(_ count: Int = 1) { recentsFailuresRemaining = count }
    func setCategories(_ values: [CategorySuggestion]) { categories = values }
    func setBarcodeResult(_ value: Result<BarcodeLookup, Error>) { barcodeResult = value }

    func recordedSearches() -> [(String, FoodSearchScope)] { searches }
    func recordedRecentsCalls() -> [RecentsCall] { recentsCalls }
    func recordedCategoryQueries() -> [String] { categoryQueries }
    func recordedBarcodeQueries() -> [String] { barcodeQueries }

    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult] {
        searches.append((query, scope))
        return searchResults
    }

    func recentItems(
        from: LocalDiaryDate,
        to: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> [RecentLogItem] {
        recentsCalls.append(RecentsCall(from: from, to: to, mealSlot: mealSlot))
        if recentsCalls.count == 1, firstRecentsDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: firstRecentsDelayNanoseconds)
        }
        if recentsFailuresRemaining > 0 {
            recentsFailuresRemaining -= 1
            throw DiaryServiceError.server("recents failed")
        }
        return recents
    }

    func categorySuggestions(query: String, limit: Int) async throws -> [CategorySuggestion] {
        categoryQueries.append(query)
        return categories
    }

    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup {
        barcodeQueries.append(barcode)
        return try barcodeResult.get()
    }
}

@MainActor
final class SearchMilestoneTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    func testScopeDrivesCatalogScopeAndHistoryRecents() async {
        let service = FakeHistorySearchService()
        await service.setSearchResults([FoodSearchResult(id: "food-1", name: "Oats")])
        let vm = makeViewModel(service: service)

        vm.setScope(.history)
        vm.queryChanged("oat")
        await waitUntil { vm.state != .idle && vm.state != .loading }

        let searches = await service.recordedSearches()
        XCTAssertEqual(searches.last?.1, .history)
        let calls = await service.recordedRecentsCalls()
        XCTAssertEqual(calls.first?.from, date.addingDays(-30))
        XCTAssertEqual(calls.first?.to, date)
        XCTAssertEqual(calls.first?.mealSlot, .lunch)
    }

    func testEmptyQueryRecentsUseOriginDateAndSlot() async {
        let service = FakeHistorySearchService()
        let item = recentProduct()
        await service.setRecents([item])
        let vm = makeViewModel(service: service)

        await vm.loadForAppearance()

        XCTAssertEqual(vm.recentsState, .loaded([item]))
        let calls = await service.recordedRecentsCalls()
        XCTAssertEqual(calls.first?.from, date.addingDays(-30))
        XCTAssertEqual(calls.first?.to, date)
        XCTAssertEqual(calls.first?.mealSlot, .lunch)
    }

    func testLateRecentsResponseForPreviousDateIsIgnored() async {
        let service = FakeHistorySearchService()
        await service.setRecents([recentProduct(name: "Old")])
        await service.setFirstRecentsDelay(150_000_000)
        let vm = makeViewModel(service: service)

        let oldDate = date
        let newDate = date.addingDays(-1)
        vm.updateContext(date: oldDate, mealSlot: .lunch)
        Task { await vm.loadRecents(force: true) }
        await waitUntil { vm.recentsState == .loading }

        await service.setRecents([recentProduct(name: "New")])
        vm.updateContext(date: newDate, mealSlot: .lunch)
        await waitUntil {
            if case .loaded(let items) = vm.recentsState {
                return items.first?.name == "New"
            }
            return false
        }
        try? await Task.sleep(nanoseconds: 250_000_000)

        guard case .loaded(let items) = vm.recentsState else {
            return XCTFail("Expected new recents to stay loaded")
        }
        XCTAssertEqual(items.first?.name, "New")
        XCTAssertEqual(vm.originDate, newDate)
    }

    func testQuickAddBuildsHistoricalDraftAndPublishesSuccess() async {
        let service = FakeHistorySearchService()
        let item = recentProduct()
        await service.setRecents([item])
        var submitted: (drafts: [LogSubmissionDraft], names: [String], summary: String)?
        let vm = makeViewModel(service: service) { drafts, names, summary, completion in
            submitted = (drafts, names, summary)
            completion(.success([]))
        }
        await vm.loadForAppearance()

        vm.quickAdd(item, quantity: NutritionQuantity(amount: "75", unit: "g"))

        let capture = try? XCTUnwrap(submitted)
        XCTAssertEqual(capture?.drafts.count, 1)
        XCTAssertEqual(capture?.drafts.first?.date, date)
        XCTAssertEqual(capture?.drafts.first?.mealSlot, .lunch)
        XCTAssertEqual(capture?.drafts.first?.item, .product(id: "food-1"))
        XCTAssertEqual(capture?.drafts.first?.amount, "75")
        XCTAssertEqual(capture?.names, ["Oats"])
        XCTAssertEqual(capture?.summary, "Oats")
        XCTAssertEqual(vm.quickAddState, .added("Oats"))
    }

    func testQuickAddFailureKeepsActionableMessageUntilDismissed() async {
        let service = FakeHistorySearchService()
        let item = recentProduct()
        await service.setRecents([item])
        let vm = makeViewModel(service: service) { _, _, _, completion in
            completion(.failure(.uncertain("Network may have saved it")))
        }
        await vm.loadForAppearance()

        vm.quickAdd(item)
        XCTAssertEqual(vm.quickAddState, .failed("Network may have saved it"))

        vm.dismissQuickAddMessage()
        XCTAssertEqual(vm.quickAddState, .idle)
    }

    func testBatchReviewSubmitsSelectionsInOrderAndClearsOnSuccess() async {
        let service = FakeHistorySearchService()
        let first = recentProduct(id: "food-1", name: "Oats")
        let second = recentProduct(id: "food-2", name: "Rice")
        await service.setRecents([first, second])
        var submitted: [LogSubmissionDraft] = []
        let vm = makeViewModel(service: service) { drafts, _, _, completion in
            submitted = drafts
            completion(.success([]))
        }
        await vm.loadForAppearance()

        vm.toggleBatchSelection(first)
        vm.toggleBatchSelection(second, quantity: NutritionQuantity(amount: "200", unit: "g"))
        vm.presentBatchReview()
        XCTAssertTrue(vm.isBatchReviewPresented)
        vm.submitBatch()

        XCTAssertEqual(submitted.map(\.item), [
            .product(id: "food-1"),
            .product(id: "food-2"),
        ])
        XCTAssertEqual(submitted.map(\.amount), ["100", "200"])
        XCTAssertFalse(vm.isBatchReviewPresented)
        XCTAssertTrue(vm.batchSelection.isEmpty)
    }

    func testCategorySuggestionQuotesValuesWithSpaces() async {
        let service = FakeHistorySearchService()
        await service.setCategories([
            CategorySuggestion(value: "breakfast cereal", count: 4)
        ])
        let vm = makeViewModel(service: service)

        vm.queryChanged("oat")
        await waitUntil { vm.categorySuggestions.count == 1 }
        vm.applyCategorySuggestion(vm.categorySuggestions[0])

        XCTAssertEqual(vm.query, #"oat category:"breakfast cereal""#)
        await waitUntil { vm.state != .loading && vm.state != .idle }
        let searches = await service.recordedSearches()
        XCTAssertEqual(searches.last?.0, #"oat category:"breakfast cereal""#)
    }

    func testBarcodeLookupRejectsInvalidAndOpensFoundResult() async {
        let service = FakeHistorySearchService()
        let product = ProductDetail(
            id: "food-1",
            source: "local",
            visibility: "private",
            barcode: "0123456789012",
            name: "Milk"
        )
        await service.setBarcodeResult(.success(
            BarcodeLookup(
                product: product,
                lookup: BarcodeLookupMeta(origin: .openFoodFacts, note: "Imported")
            )
        ))
        var opened: [(String, LocalDiaryDate, MealSlot?)] = []
        let vm = makeViewModel(service: service) { _, _, _, _ in } onSelect: { id, date, slot in
            opened.append((id, date, slot))
        }

        vm.setScope(.barcode)
        vm.barcodeChanged("abcd")
        vm.lookupBarcode()
        XCTAssertEqual(
            vm.barcodeState,
            .failed(BarcodeValidationError.invalidCharacters.message)
        )

        vm.barcodeChanged("١٢٣٤")
        vm.lookupBarcode()
        XCTAssertEqual(
            vm.barcodeState,
            .failed(BarcodeValidationError.invalidCharacters.message)
        )

        vm.barcodeChanged("0123456789012")
        vm.lookupBarcode()
        await waitUntil {
            if case .found = vm.barcodeState { return true }
            return false
        }
        vm.openBarcodeResult()

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "food-1")
        XCTAssertEqual(opened.first?.1, date)
        XCTAssertEqual(opened.first?.2, .lunch)
        let barcodes = await service.recordedBarcodeQueries()
        XCTAssertEqual(barcodes, ["0123456789012"])
    }

    func testMealRecentUsesMealCallbackAndPreservesContext() {
        let service = FakeHistorySearchService()
        let meal = RecentLogItem(
            item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Curry")),
            lastUsedDate: date.addingDays(-1),
            mealSlot: .dinner,
            quantity: NutritionQuantity(amount: "1", unit: "serving")
        )
        let adHoc = RecentLogItem(
            item: .adHoc(AdHocLogItemSnapshot(name: "Toast")),
            lastUsedDate: date,
            mealSlot: .snack,
            quantity: NutritionQuantity(amount: "2", unit: "slice")
        )
        var openedProducts: [(String, LocalDiaryDate, MealSlot?)] = []
        var openedMeals: [(String, LocalDiaryDate, MealSlot?, NutritionQuantity?)] = []
        let vm = makeViewModel(
            service: service,
            onSelect: { openedProducts.append(($0, $1, $2)) },
            onSelectMeal: { openedMeals.append(($0, $1, $2, $3)) }
        )

        XCTAssertTrue(vm.canOpen(meal))
        XCTAssertTrue(vm.canOpen(recentProduct()))
        XCTAssertFalse(vm.canOpen(adHoc))

        vm.selectMeal(meal, quantity: NutritionQuantity(amount: "2", unit: "serving"))

        XCTAssertTrue(openedProducts.isEmpty)
        XCTAssertEqual(openedMeals.count, 1)
        XCTAssertEqual(openedMeals.first?.0, "meal-1")
        XCTAssertEqual(openedMeals.first?.1, date)
        XCTAssertEqual(openedMeals.first?.2, .lunch)
        XCTAssertEqual(
            openedMeals.first?.3,
            NutritionQuantity(amount: "2", unit: "serving")
        )
    }

    // MARK: - Helpers

    private func makeViewModel(
        service: FakeHistorySearchService,
        onSubmit: @escaping LogSubmissionHandler = { _, _, _, _ in },
        onSelect: @escaping (String, LocalDiaryDate, MealSlot?) -> Void = { _, _, _ in },
        onSelectMeal: @escaping (String, LocalDiaryDate, MealSlot?, NutritionQuantity?) -> Void = { _, _, _, _ in }
    ) -> SearchViewModel {
        SearchViewModel(
            originDate: date,
            originMealSlot: .lunch,
            service: service,
            debounceNanoseconds: 0,
            timeZoneProvider: { "Europe/Paris" },
            onSelectFood: onSelect,
            onSelectMeal: onSelectMeal,
            historyService: service,
            onSubmitDrafts: { drafts, names, summary, completion in
                onSubmit(drafts, names, summary, completion)
            }
        )
    }

    private func recentProduct(
        id: String = "food-1",
        name: String = "Oats"
    ) -> RecentLogItem {
        RecentLogItem(
            item: .product(ProductLogItemSnapshot(id: id, name: name)),
            lastUsedDate: date.addingDays(-2),
            mealSlot: .lunch,
            quantity: NutritionQuantity(amount: "100", unit: "g"),
            topQuantities: [
                QuantityLogUsage(
                    quantity: NutritionQuantity(amount: "100", unit: "g"),
                    logCount: 2
                )
            ]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }
}
