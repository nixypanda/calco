import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class SearchScreenFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let nextDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let generation: UInt64 = 7

    private var catalogResult: FoodSearchResult {
        FoodSearchResult(id: "food-1", name: "Oats", brand: "CalCo")
    }

    private var productRecent: RecentLogItem {
        RecentLogItem(
            item: .product(ProductLogItemSnapshot(id: "product-1", name: "Yogurt")),
            lastUsedDate: date,
            mealSlot: .breakfast,
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
    }

    private var mealRecent: RecentLogItem {
        RecentLogItem(
            item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Lunch box")),
            lastUsedDate: date,
            mealSlot: .lunch,
            quantity: NutritionQuantity(amount: "1", unit: "serving")
        )
    }

    private var adHocRecent: RecentLogItem {
        RecentLogItem(
            item: .adHoc(AdHocLogItemSnapshot(name: "Homemade")),
            lastUsedDate: date,
            mealSlot: .snack,
            quantity: NutritionQuantity(amount: "1", unit: "cup")
        )
    }

    private func makeBarcodeLookup(barcode: String = "0001234") -> BarcodeLookup {
        BarcodeLookup(
            product: ProductDetail(
                id: "p1",
                source: "USER",
                sourceID: "s1",
                visibility: "shared",
                barcode: barcode,
                name: "Test food",
                brand: "Brand",
                categories: [],
                defaultQuantity: "100",
                defaultUnit: "g",
                nutritionSummary: ProductNutritionSummary(per100g: .empty),
                nutrients: [
                    ProductNutrient(
                        code: NutrientCodes.energyKcal,
                        amountPer100g: "389",
                        unit: "kcal"
                    )
                ],
                servings: [],
                allowedUnits: []
            ),
            lookup: BarcodeLookupMeta(origin: .local, note: nil)
        )
    }

    func testQueryFanoutUpdatesCatalogAndHistoryCategories() async {
        let catalogClock = TestClock()
        let catalogRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let result = catalogResult

        let catalogStore = TestStore(
            initialState: SearchScreenFeature.State(
                date: date,
                mealSlot: .breakfast,
                generation: generation
            )
        ) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(catalogRequestID)
            $0.continuousClock = catalogClock
            $0.foodSearchClient.search = { _, _ in [result] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
        }

        await catalogStore.send(.queryChanged("oa")) {
            $0.catalog.phase = .debouncing(
                requestID: catalogRequestID,
                query: "oa",
                scope: .all,
                previousResults: []
            )
            $0.history.categoryLookup = .debouncing(
                requestID: catalogRequestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await catalogClock.advance(by: .milliseconds(300))
        await catalogStore.receive(\.catalog.searchDebounced) {
            $0.catalog.phase = .loading(
                requestID: catalogRequestID,
                query: "oa",
                scope: .all,
                previousResults: []
            )
        }
        await catalogStore.receive(\.catalog.resultReceived) {
            $0.catalog.phase = .loaded(
                requestID: catalogRequestID,
                query: "oa",
                scope: .all,
                results: [result]
            )
        }
        await catalogStore.receive(\.history.categoryDebounceElapsed) {
            $0.history.categoryLookup = .loading(
                requestID: catalogRequestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await catalogStore.receive(\.history.categoryResponse) {
            $0.history.categoryLookup = .loaded(
                requestID: catalogRequestID,
                query: "oa",
                suggestions: []
            )
        }

        let historyClock = TestClock()
        let historyRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let suggestions = [CategorySuggestion(value: "oat", count: 2)]
        let historyStore = TestStore(
            initialState: SearchScreenFeature.State(
                date: date,
                mealSlot: .breakfast,
                generation: generation
            )
        ) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(historyRequestID)
            $0.continuousClock = historyClock
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in suggestions }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
        }

        await historyStore.send(.queryChanged("oa")) {
            $0.catalog.phase = .debouncing(
                requestID: historyRequestID,
                query: "oa",
                scope: .all,
                previousResults: []
            )
            $0.history.categoryLookup = .debouncing(
                requestID: historyRequestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await historyClock.advance(by: .milliseconds(300))
        await historyStore.receive(\.catalog.searchDebounced) {
            $0.catalog.phase = .loading(
                requestID: historyRequestID,
                query: "oa",
                scope: .all,
                previousResults: []
            )
        }
        await historyStore.receive(\.catalog.resultReceived) {
            $0.catalog.phase = .loaded(
                requestID: historyRequestID,
                query: "oa",
                scope: .all,
                results: []
            )
        }
        await historyStore.receive(\.history.categoryDebounceElapsed) {
            $0.history.categoryLookup = .loading(
                requestID: historyRequestID,
                query: "oa",
                visibleSuggestions: []
            )
        }
        await historyStore.receive(\.history.categoryResponse) {
            $0.history.categoryLookup = .loaded(
                requestID: historyRequestID,
                query: "oa",
                suggestions: suggestions
            )
        }
    }

    func testContextUpdateIsAtomicAndRefreshesRecentsForAllScope() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let recents = [productRecent]

        let store = TestStore(
            initialState: SearchScreenFeature.State(
                date: date,
                mealSlot: .breakfast,
                generation: generation
            )
        ) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in recents }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.updateContext(date: nextDate, mealSlot: .dinner)) {
            $0.catalog.originDate = self.nextDate
            $0.catalog.originMealSlot = .dinner
            $0.history.contextDate = self.nextDate
            $0.history.contextMealSlot = .dinner
            $0.history.recents = .loading(
                requestID: requestID,
                contextDate: self.nextDate,
                contextMealSlot: .dinner,
                priorItems: []
            )
            $0.quickAdd.originDate = self.nextDate
            $0.quickAdd.originMealSlot = .dinner
        }

        await store.receive(\.history.recentsResponse) {
            $0.history.recents = .loaded(
                requestID: requestID,
                contextDate: self.nextDate,
                contextMealSlot: .dinner,
                items: recents
            )
        }
    }

    func testBarcodeScopeChangeCancelsLookupAndPreservesInput() async {
        let lookupRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let recentsRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        var state = SearchScreenFeature.State(date: date, mealSlot: nil, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: nil,
            phase: .idle(query: "", scope: .barcode, results: []),
            sessionGeneration: generation
        )
        state.barcode = BarcodeFeature.State(
            barcodeInput: "1234",
            lookup: .lookingUp(requestID: lookupRequestID, barcode: "1234"),
            sessionGeneration: generation
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(recentsRequestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.scopeChanged(.all)) {
            $0.barcode = BarcodeFeature.State(
                barcodeInput: "1234",
                lookup: .idle,
                sessionGeneration: self.generation
            )
            $0.catalog.phase = .idle(query: "", scope: .all, results: [])
            $0.history.categoryLookup = .idle
            $0.history.recents = .loading(
                requestID: recentsRequestID,
                contextDate: self.date,
                contextMealSlot: nil,
                priorItems: []
            )
        }
        await store.receive(\.history.recentsResponse) {
            $0.history.recents = .loaded(
                requestID: recentsRequestID,
                contextDate: self.date,
                contextMealSlot: nil,
                items: []
            )
        }
    }

    func testQuickAddRefreshUsesOriginalDateAndConditionallyRefreshesCurrentRecents() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let refreshRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let recents = [productRecent]
        var state = SearchScreenFeature.State(date: nextDate, mealSlot: .dinner, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: nextDate,
            originMealSlot: .dinner,
            phase: .idle(query: "", scope: .all, results: []),
            sessionGeneration: generation
        )
        state.history = SearchHistoryFeature.State(
            contextDate: nextDate,
            contextMealSlot: .dinner,
            sessionGeneration: generation
        )
        state.quickAdd = SearchQuickAddFeature.State(
            originDate: nextDate,
            originMealSlot: .dinner,
            sessionGeneration: generation,
            phase: .submitting(SearchQuickAddFeature.Request(
                requestID: requestID,
                itemID: productRecent.id,
                itemName: productRecent.name,
                originDate: date,
                mealSlot: .breakfast,
                quantity: productRecent.quantity
            ))
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(refreshRequestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { from, to, mealSlot in
                XCTAssertEqual(from, self.nextDate.addingDays(-30))
                XCTAssertEqual(to, self.nextDate)
                XCTAssertEqual(mealSlot, .dinner)
                return recents
            }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.quickAddFeature(.submitCompleted(requestID: requestID, result: .success([])))) {
            $0.quickAdd.phase = .succeeded(SearchQuickAddFeature.Receipt(
                itemName: self.productRecent.name,
                createdLogCount: 0
            ))
        }
        await store.receive(\.quickAddFeature.delegate, .logged(
            itemID: self.productRecent.id,
            originDate: self.date,
            mealSlot: .breakfast,
            sessionGeneration: self.generation
        ))
        await store.receive(\.quickAddFeature.delegate, .refresh(
            originDate: self.date,
            sessionGeneration: self.generation
        )) {
            $0.history.recents = .loading(
                requestID: refreshRequestID,
                contextDate: self.nextDate,
                contextMealSlot: .dinner,
                priorItems: []
            )
        }
        await store.receive(\.delegate, .diaryChanged(date: self.date, generation: self.generation))
        await store.receive(\.history.recentsResponse) {
            $0.history.recents = .loaded(
                requestID: refreshRequestID,
                contextDate: self.nextDate,
                contextMealSlot: .dinner,
                items: recents
            )
        }
    }

    func testMealRecentSelectionRoutesTypedMealAndAdHocDoesNotOpen() async {
        let store = TestStore(
            initialState: SearchScreenFeature.State(
                date: date,
                mealSlot: .lunch,
                generation: generation
            )
        ) {
            SearchScreenFeature()
        }

        let override = NutritionQuantity(amount: "2", unit: "serving")
        await store.send(.selectRecent(item: mealRecent, quantity: override))
        await store.receive(\.delegate, .selectedMeal(
            id: "meal-1",
            date: self.date,
            mealSlot: .lunch,
            quantity: override,
            generation: self.generation,
            origin: .diaryPush
        ))

        await store.send(.selectRecent(item: adHocRecent, quantity: nil))
    }

    func testStaleChildGenerationDelegateIsIgnored() async {
        let staleGeneration: UInt64 = 1
        let staleRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!

        let store = TestStore(
            initialState: SearchScreenFeature.State(
                date: date,
                mealSlot: .breakfast,
                generation: generation
            )
        ) {
            SearchScreenFeature()
        }

        await store.send(.catalog(.delegate(.selectedFood(
            id: "food-1",
            date: self.date,
            mealSlot: .breakfast,
            generation: staleGeneration
        ))))

        await store.send(.history(.delegate(.sessionExpired(generation: staleGeneration))))

        var quickState = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        quickState.quickAdd.phase = .submitting(SearchQuickAddFeature.Request(
            requestID: staleRequestID,
            itemID: "product-1",
            itemName: "Yogurt",
            originDate: date,
            mealSlot: .breakfast,
            quantity: NutritionQuantity(amount: "100", unit: "g")
        ))
        let quickStore = TestStore(initialState: quickState) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await quickStore.send(.quickAddFeature(.submitCompleted(requestID: staleRequestID, result: .failure(.unauthorized)))) {
            $0.quickAdd.phase = .failed(
                SearchQuickAddFeature.FailureContext(
                    requestID: staleRequestID,
                    itemID: "product-1",
                    originDate: self.date,
                    mealSlot: .breakfast
                ),
                .unauthorized
            )
        }
        await quickStore.receive(\.quickAddFeature.delegate, .sessionExpired(generation: self.generation))
        await quickStore.receive(\.delegate, .sessionExpired(generation: self.generation))
    }

    func testClearQueryClearsCatalogAndCategoriesAndDismissesIdleQuickAddFeedback() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        var state = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            phase: .loaded(
                requestID: requestID,
                query: "oats",
                scope: .all,
                results: [catalogResult]
            ),
            sessionGeneration: generation,
            selectedResultID: catalogResult.id
        )
        state.history = SearchHistoryFeature.State(
            contextDate: date,
            contextMealSlot: .breakfast,
            sessionGeneration: generation,
            categoryLookup: .loaded(
                requestID: requestID,
                query: "oats",
                suggestions: [CategorySuggestion(value: "oat", count: 1)]
            )
        )
        state.quickAdd = SearchQuickAddFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            sessionGeneration: generation,
            phase: .succeeded(SearchQuickAddFeature.Receipt(itemName: "Yogurt", createdLogCount: 1))
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.clearQuery) {
            $0.catalog.phase = .idle(query: "", scope: .all, results: [])
            $0.catalog.selectedResultID = nil
            $0.history.categoryLookup = .idle
            $0.quickAdd.phase = .idle
        }
    }

    func testClearQueryPreservesBusyQuickAddSubmission() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        let submitting = SearchQuickAddFeature.Request(
            requestID: requestID,
            itemID: "product-1",
            itemName: "Yogurt",
            originDate: date,
            mealSlot: .breakfast,
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        var state = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            phase: .loaded(
                requestID: requestID,
                query: "oats",
                scope: .all,
                results: [catalogResult]
            ),
            sessionGeneration: generation
        )
        state.history = SearchHistoryFeature.State(
            contextDate: date,
            contextMealSlot: .breakfast,
            sessionGeneration: generation,
            categoryLookup: .loaded(
                requestID: requestID,
                query: "oats",
                suggestions: [CategorySuggestion(value: "oat", count: 1)]
            )
        )
        state.quickAdd = SearchQuickAddFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            sessionGeneration: generation,
            phase: .submitting(submitting)
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.clearQuery) {
            $0.catalog.phase = .idle(query: "", scope: .all, results: [])
            $0.history.categoryLookup = .idle
        }
        XCTAssertEqual(store.state.quickAdd.phase, .submitting(submitting))
    }

    func testCategorySuggestionSelectedUsesExactGrammarAndImmediateSearch() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        var state = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            phase: .idle(query: "oats", scope: .all, results: []),
            sessionGeneration: generation
        )
        state.history = SearchHistoryFeature.State(
            contextDate: date,
            contextMealSlot: .breakfast,
            sessionGeneration: generation,
            categoryLookup: .loaded(
                requestID: requestID,
                query: "oats",
                suggestions: [CategorySuggestion(value: "rolled oats", count: 1)]
            )
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { query, scope in
                XCTAssertEqual(query, "oats category:\"rolled oats\"")
                XCTAssertEqual(scope, .all)
                return [self.catalogResult]
            }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.categorySuggestionSelected(CategorySuggestion(value: "rolled oats", count: 1))) {
            $0.catalog.phase = .loading(
                requestID: requestID,
                query: "oats category:\"rolled oats\"",
                scope: .all,
                previousResults: []
            )
            $0.history.categoryLookup = .idle
        }
        await store.receive(\.catalog.resultReceived) {
            $0.catalog.phase = .loaded(
                requestID: requestID,
                query: "oats category:\"rolled oats\"",
                scope: .all,
                results: [self.catalogResult]
            )
        }
    }

    func testAppearedClearsSelectedResultBeforeGuardedHistoryLoad() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000070")!
        var state = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            phase: .loaded(
                requestID: requestID,
                query: "oats",
                scope: .all,
                results: [catalogResult]
            ),
            sessionGeneration: generation,
            selectedResultID: catalogResult.id
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [self.productRecent] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.appeared) {
            $0.catalog.selectedResultID = nil
            $0.history.recents = .loading(
                requestID: requestID,
                contextDate: self.date,
                contextMealSlot: .breakfast,
                priorItems: []
            )
        }
        await store.receive(\.history.recentsResponse) {
            $0.history.recents = .loaded(
                requestID: requestID,
                contextDate: self.date,
                contextMealSlot: .breakfast,
                items: [self.productRecent]
            )
        }

        await store.send(.catalog(.selectResult(id: catalogResult.id))) {
            $0.catalog.selectedResultID = self.catalogResult.id
        }
        await store.receive(\.catalog.delegate, .selectedFood(
            id: self.catalogResult.id,
            date: self.date,
            mealSlot: .breakfast,
            generation: self.generation
        ))
        await store.receive(\.delegate, .selectedFood(
            id: self.catalogResult.id,
            date: self.date,
            mealSlot: .breakfast,
            generation: self.generation,
            origin: .diaryPush
        ))
    }

    func testUpdateContextSameAllScopeLoadedIsNoOpAndDoesNotRefreshRecents() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000080")!
        var state = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: .breakfast,
            phase: .loaded(
                requestID: requestID,
                query: "oats",
                scope: .all,
                results: [catalogResult]
            ),
            sessionGeneration: generation
        )
        state.history = SearchHistoryFeature.State(
            contextDate: date,
            contextMealSlot: .breakfast,
            sessionGeneration: generation,
            recents: .loaded(
                requestID: requestID,
                contextDate: date,
                contextMealSlot: .breakfast,
                items: [productRecent]
            )
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in
                XCTFail("Same context update should not refresh recents")
                return []
            }
            $0.searchHistoryClient.categorySuggestions = { _, _ in
                XCTFail("Same context update should not trigger category suggestions")
                return []
            }
        }

        await store.send(.updateContext(date: date, mealSlot: .breakfast))
        await store.finish()
    }

    func testCatalogSelectionCapturesNavigationOriginAtActionTime() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000090")!
        var state = SearchScreenFeature.State(date: date, mealSlot: .lunch, generation: generation)
        state.catalog = SearchFeature.State(
            originDate: date,
            originMealSlot: .lunch,
            phase: .loaded(
                requestID: requestID,
                query: "oats",
                scope: .all,
                results: [catalogResult]
            ),
            sessionGeneration: generation
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.selectCatalogResult(id: catalogResult.id, origin: .searchTab)) {
            $0.catalog.selectedResultID = self.catalogResult.id
        }
        await store.receive(\.delegate, .selectedFood(
            id: self.catalogResult.id,
            date: self.date,
            mealSlot: .lunch,
            generation: self.generation,
            origin: .searchTab
        ))

        await store.send(.selectCatalogResult(id: catalogResult.id, origin: .diaryPush))
        await store.receive(\.delegate, .selectedFood(
            id: self.catalogResult.id,
            date: self.date,
            mealSlot: .lunch,
            generation: self.generation,
            origin: .diaryPush
        ))
    }

    func testBarcodeCreateDraftCapturesOriginAndContextAtActionTime() async {
        var state = SearchScreenFeature.State(date: nextDate, mealSlot: .dinner, generation: generation)
        state.barcode = BarcodeFeature.State(
            barcodeInput: "0001234",
            lookup: .notFound(barcode: "0001234"),
            sessionGeneration: generation
        )

        let store = TestStore(initialState: state) {
            SearchScreenFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.createBarcodeDraft(origin: .searchTab))
        await store.receive(\.delegate, .createCustomFoodDraft(
            barcode: "0001234",
            date: self.nextDate,
            mealSlot: .dinner,
            generation: self.generation,
            origin: .searchTab
        ))
    }
}
