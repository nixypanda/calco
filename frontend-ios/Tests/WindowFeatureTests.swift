import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class WindowFeatureTests: XCTestCase {
    private let requestID = UUID()
    private let generation = UInt64(7)
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let historicalDate = LocalDiaryDate(year: 2026, month: 11, day: 15)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 16)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)

    private var report: NutritionDetailsReport {
        NutritionDetailsReport(
            date: date,
            reference: NutritionDetailsReference(
                code: "REF",
                name: "Reference",
                authority: "Authority",
                jurisdiction: "US",
                populationLabel: "Adults",
                sourceURL: "https://example.com"
            ),
            loggedItems: 2,
            nutrients: [
                NutritionDetailsNutrient(
                    code: "ENERGY_KCAL",
                    name: "Energy",
                    section: .overview,
                    knownAmount: 100,
                    unit: "kcal",
                    referenceAmount: 200,
                    guidanceKind: .adequacy,
                    itemsWithData: 1,
                    coverage: .complete,
                    status: .belowReference
                )
            ]
        )
    }

    private func makeClient(
        fetch: @escaping @Sendable (LocalDiaryDate) async throws -> NutritionDetailsReport
    ) -> NutritionDetailsFeature.Client {
        NutritionDetailsFeature.Client(fetch: fetch)
    }

    func testOpenNutritionUsesExplicitSelectedDate() async {
        let report = self.report
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let historicalDate = self.historicalDate
        let otherDate = self.otherDate
        let today = self.today
        let store = TestStore(
            initialState: WindowFeature.State(sessionGeneration: generation, today: today)
        ) {
            WindowFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        await store.send(.openNutrition(selectedDate: historicalDate, today: today)) {
            $0.nutrition = NutritionDetailsFeature.State(
                date: historicalDate,
                today: today,
                sessionGeneration: generation
            )
        }
        await store.finish()
    }

    func testDuplicateOpenPreservesGuidance() async {
        let report = self.report
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let historicalDate = self.historicalDate
        let otherDate = self.otherDate
        let today = self.today
        var child = NutritionDetailsFeature.State(
            date: historicalDate,
            today: today,
            sessionGeneration: generation
        )
        child.phase = .loaded(report: report, requestDate: historicalDate)
        child.expandedNutrientCodes = ["ENERGY_KCAL"]

        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                nutrition: child
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        await store.send(.openNutrition(selectedDate: historicalDate, today: today))
        XCTAssertEqual(store.state.nutrition?.expandedNutrientCodes, ["ENERGY_KCAL"])
        await store.finish()
    }

    func testCloseAndReopenUsesDistinctDestination() async {
        let report = self.report
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let historicalDate = self.historicalDate
        let otherDate = self.otherDate
        let today = self.today
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                nutrition: NutritionDetailsFeature.State(
                    date: historicalDate,
                    today: today,
                    sessionGeneration: generation
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        await store.send(.closeNutrition) {
            $0.nutrition = nil
        }
        await store.send(.openNutrition(selectedDate: otherDate, today: today)) {
            $0.nutrition = NutritionDetailsFeature.State(
                date: otherDate,
                today: today,
                sessionGeneration: generation
            )
        }
        await store.finish()
    }

    func testUnauthorizedChildForwardsOriginalGeneration() async {
        let report = self.report
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let historicalDate = self.historicalDate
        let otherDate = self.otherDate
        let today = self.today
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                nutrition: NutritionDetailsFeature.State(
                    today: today,
                    phase: .loading(requestDate: date, requestID: requestID),
                    sessionGeneration: generation
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in
                throw NutritionDetailsServiceError.unauthorized
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.nutrition(.reportFailed(
            requestDate: date,
            requestID: requestID,
            failure: .unauthorized
        ))) {
            $0.nutrition?.phase = .sessionExpired(requestDate: date)
            $0.nutrition?.expandedNutrientCodes = []
        }
        await store.receive(\.nutrition, .delegate(.sessionExpired(
            selectedDate: date,
            generation: generation
        ))) {
            $0.nutrition = nil
        }
        await store.receive(\.delegate, .sessionExpired(
            selectedDate: date,
            generation: generation,
            reason: .expired
        ))
        await store.finish()
    }

    func testStaleChildSessionExpiredIsIgnored() async {
        let report = self.report
        let requestID = self.requestID
        let generation = self.generation
        let date = self.date
        let historicalDate = self.historicalDate
        let otherDate = self.otherDate
        let today = self.today
        let staleGeneration = UInt64(3)
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                nutrition: NutritionDetailsFeature.State(
                    today: today,
                    phase: .loading(requestDate: date, requestID: requestID),
                    sessionGeneration: staleGeneration
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in
                throw NutritionDetailsServiceError.unauthorized
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.nutrition(.reportFailed(
            requestDate: date,
            requestID: requestID,
            failure: .unauthorized
        ))) {
            $0.nutrition?.phase = .sessionExpired(requestDate: date)
            $0.nutrition?.expandedNutrientCodes = []
        }
        await store.receive(\.nutrition, .delegate(.sessionExpired(
            selectedDate: date,
            generation: staleGeneration
        )))
        await store.finish()
    }

    func testFreshWindowRecentsRefreshUsesInitialDayAndNoMealSlot() async {
        let recentsRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000110")!
        var initial = WindowFeature.State(sessionGeneration: generation, today: today)
        initial.search.catalog.phase = .idle(query: "", scope: .all, results: [])
        let store = TestStore(initialState: initial) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .constant(recentsRequestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        // A fresh window carries no explicit search context. An external invalidation
        // on an active scope must refresh against the window's initial day with no
        // meal slot, proving default search coherence through effect output rather
        // than restating initializer fields.
        await store.send(.searchRecentsInvalidated(generation: generation))
        await store.receive {
            guard case .search(.history(.refreshRecents)) = $0 else { return false }
            return true
        } assert: {
            $0.search.history.recents = .loading(
                requestID: recentsRequestID,
                contextDate: self.today,
                contextMealSlot: nil,
                priorItems: []
            )
        }
        await store.receive {
            guard case .search(.history(.recentsResponse(let requestID, let date, let slot, .success(let items)))) = $0,
                  requestID == recentsRequestID,
                  date == self.today,
                  slot == nil,
                  items.isEmpty
            else { return false }
            return true
        } assert: {
            $0.search.history.recents = .loaded(
                requestID: recentsRequestID,
                contextDate: self.today,
                contextMealSlot: nil,
                items: []
            )
        }
        await store.finish()
    }

    func testSearchCreateCustomFoodDraftCapturesOriginAndHistoricalDate() async {
        let presentationID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: SearchScreenFeature.State(
                    date: historicalDate,
                    mealSlot: .lunch,
                    generation: generation
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .constant(presentationID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.barcodeClient.lookup = { _ in
                XCTFail("No barcode lookup expected")
                throw BarcodeServiceError.cancelled
            }
        }

        await store.send(.search(.delegate(.createCustomFoodDraft(
            barcode: "0001234",
            date: historicalDate,
            mealSlot: .lunch,
            generation: generation,
            origin: .searchTab
        )))) {
            $0.foodCreation = SearchFoodCreationPresentation(
                id: presentationID,
                barcode: "0001234",
                date: self.historicalDate,
                mealSlot: .lunch,
                generation: self.generation,
                origin: .searchTab
            )
        }
        await store.finish()
    }

    func testDuplicateCreateCustomFoodDraftDoesNotOverwritePresentation() async {
        let existingID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let existing = SearchFoodCreationPresentation(
            id: existingID,
            barcode: "111",
            date: historicalDate,
            mealSlot: .breakfast,
            generation: generation,
            origin: .diaryPush
        )
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: SearchScreenFeature.State(
                    date: historicalDate,
                    mealSlot: .lunch,
                    generation: generation
                ),
                foodCreation: existing
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .constant(newID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.search(.delegate(.createCustomFoodDraft(
            barcode: "222",
            date: otherDate,
            mealSlot: .dinner,
            generation: generation,
            origin: .searchTab
        ))))
        XCTAssertEqual(store.state.foodCreation, existing)
        await store.finish()
    }

    func testOldDismissalIDCannotClearNewFoodCreation() async {
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let newPresentation = SearchFoodCreationPresentation(
            id: newID,
            barcode: "999",
            date: otherDate,
            mealSlot: .dinner,
            generation: generation,
            origin: .searchTab
        )
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                foodCreation: newPresentation
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.closeFoodCreation(expectedPresentationID: oldID))
        XCTAssertEqual(store.state.foodCreation, newPresentation)

        await store.send(.foodCreationCompleted(expectedPresentationID: oldID))
        XCTAssertEqual(store.state.foodCreation, newPresentation)

        await store.send(.closeFoodCreation(expectedPresentationID: newID)) {
            $0.foodCreation = nil
        }
        await store.finish()
    }

    func testFoodCreationCompletedRefreshesHistoryForActiveScope() async {
        let presentationID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let recentsRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000107")!
        var search = SearchScreenFeature.State(date: historicalDate, mealSlot: .breakfast, generation: generation)
        search.catalog.phase = .idle(query: "", scope: .all, results: [])
        let presentation = SearchFoodCreationPresentation(
            id: presentationID,
            barcode: "123",
            date: historicalDate,
            mealSlot: .breakfast,
            generation: generation,
            origin: .diaryPush
        )
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: search,
                foodCreation: presentation
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .constant(recentsRequestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.foodCreationCompleted(expectedPresentationID: presentationID)) {
            $0.foodCreation = nil
        }
        await store.receive {
            guard case .search(.history(.refreshRecents)) = $0 else { return false }
            return true
        } assert: {
            $0.search.history.recents = .loading(
                requestID: recentsRequestID,
                contextDate: self.historicalDate,
                contextMealSlot: .breakfast,
                priorItems: []
            )
        }
        await store.receive {
            guard case .search(.history(.recentsResponse(let requestID, let date, let slot, .success(let items)))) = $0,
                  requestID == recentsRequestID,
                  date == self.historicalDate,
                  slot == .breakfast,
                  items.isEmpty
            else { return false }
            return true
        } assert: {
            $0.search.history.recents = .loaded(
                requestID: recentsRequestID,
                contextDate: self.historicalDate,
                contextMealSlot: .breakfast,
                items: []
            )
        }
        await store.finish()
    }

    func testSearchSelectionDelegatesCarryExactProvenance() async {
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: SearchScreenFeature.State(
                    date: historicalDate,
                    mealSlot: .dinner,
                    generation: generation
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        let quantity = NutritionQuantity(amount: "2", unit: "servings")
        await store.send(.search(.delegate(.selectedFood(
            id: "food-1",
            date: historicalDate,
            mealSlot: .dinner,
            generation: generation,
            origin: .searchTab
        ))))
        await store.receive(\.delegate, .selectedFood(
            id: "food-1",
            date: historicalDate,
            mealSlot: .dinner,
            generation: generation,
            origin: .searchTab
        ))

        await store.send(.search(.delegate(.selectedMeal(
            id: "meal-1",
            date: historicalDate,
            mealSlot: .dinner,
            quantity: quantity,
            generation: generation,
            origin: .diaryPush
        ))))
        await store.receive(\.delegate, .selectedMeal(
            id: "meal-1",
            date: historicalDate,
            mealSlot: .dinner,
            quantity: quantity,
            generation: generation,
            origin: .diaryPush
        ))
        await store.finish()
    }

    func testStaleSearchSessionExpiredIsIgnored() async {
        let staleGeneration = UInt64(3)
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: SearchScreenFeature.State(
                    date: historicalDate,
                    mealSlot: .lunch,
                    generation: generation
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.search(.delegate(.sessionExpired(generation: staleGeneration))))
        await store.finish()
    }

    func testSearchSessionExpiredForwardsCapturedOriginDate() async {
        let presentationID = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: SearchScreenFeature.State(
                    date: historicalDate,
                    mealSlot: .lunch,
                    generation: generation
                ),
                foodCreation: SearchFoodCreationPresentation(
                    id: presentationID,
                    barcode: "123",
                    date: historicalDate,
                    mealSlot: .lunch,
                    generation: generation,
                    origin: .searchTab
                )
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(.search(.delegate(.sessionExpired(generation: generation)))) {
            $0.foodCreation = nil
        }
        await store.receive(\.delegate, .sessionExpired(
            selectedDate: historicalDate,
            generation: generation,
            reason: .expired
        ))
        await store.finish()
    }

    func testExternalSearchRecentsInvalidatedRefreshesActiveScopesOnly() async {
        let recentsRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000109")!
        var activeSearch = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        activeSearch.catalog.phase = .idle(query: "", scope: .all, results: [])
        let activeStore = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: activeSearch
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .constant(recentsRequestID)
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await activeStore.send(.searchRecentsInvalidated(generation: generation))
        await activeStore.receive {
            guard case .search(.history(.refreshRecents)) = $0 else { return false }
            return true
        } assert: {
            $0.search.history.recents = .loading(
                requestID: recentsRequestID,
                contextDate: self.date,
                contextMealSlot: .breakfast,
                priorItems: []
            )
        }
        await activeStore.receive {
            guard case .search(.history(.recentsResponse(let requestID, let responseDate, let slot, .success(let items)))) = $0,
                  requestID == recentsRequestID,
                  responseDate == self.date,
                  slot == .breakfast,
                  items.isEmpty
            else { return false }
            return true
        } assert: {
            $0.search.history.recents = .loaded(
                requestID: recentsRequestID,
                contextDate: self.date,
                contextMealSlot: .breakfast,
                items: []
            )
        }
        await activeStore.finish()

        var barcodeSearch = SearchScreenFeature.State(date: date, mealSlot: .breakfast, generation: generation)
        barcodeSearch.catalog.phase = .idle(query: "", scope: .barcode, results: [])
        let inactiveStore = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                search: barcodeSearch
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in
                XCTFail("Barcode scope should not refresh recents")
                return []
            }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await inactiveStore.send(.searchRecentsInvalidated(generation: generation))
        await inactiveStore.send(.searchRecentsInvalidated(generation: generation + 1))
        await inactiveStore.finish()
    }

    // MARK: - Diary ownership

    func testDiaryChildIsInstalledByDefaultWithoutFetching() async {
        let generation = self.generation
        let today = self.today
        let diaryClient = DiaryFeature.Client(fetchDay: { (_: LocalDiaryDate, _: UInt64) async throws -> DiaryDay in
            XCTFail("Diary client must not fetch on Window install")
            throw DiaryServiceError.unknown
        })
        let diaryLatestClient = DiaryLatestFeature.Client(latestSlots: { (_: LocalDiaryDate, _: Int, _: UInt64) async throws -> [DiaryLatestSlot] in
            XCTFail("Diary latest client must not fetch on Window install")
            return []
        })
        let state = WindowFeature.State(sessionGeneration: generation, today: today)
        let store: TestStore<WindowFeature.State, WindowFeature.Action> = TestStore(initialState: state) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.diaryClient = diaryClient
            $0.diaryLatestClient = diaryLatestClient
        }

        XCTAssertEqual(store.state.diary.diary.sessionGeneration, generation)
        XCTAssertEqual(store.state.diary.diary.today, today)
        XCTAssertEqual(store.state.diary.selectedDate, today)
        await store.finish()
    }

    func testUnrelatedWindowActionDoesNotFetchDiary() async {
        let generation = self.generation
        let today = self.today
        let diaryClient = DiaryFeature.Client(fetchDay: { (_: LocalDiaryDate, _: UInt64) async throws -> DiaryDay in
            XCTFail("Unrelated Window action must not fetch diary")
            throw DiaryServiceError.unknown
        })
        let diaryLatestClient = DiaryLatestFeature.Client(latestSlots: { (_: LocalDiaryDate, _: Int, _: UInt64) async throws -> [DiaryLatestSlot] in
            XCTFail("Unrelated Window action must not fetch diary latest")
            return []
        })
        let state = WindowFeature.State(sessionGeneration: generation, today: today)
        let store: TestStore<WindowFeature.State, WindowFeature.Action> = TestStore(initialState: state) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.diaryClient = diaryClient
            $0.diaryLatestClient = diaryLatestClient
        }

        await store.send(WindowFeature.Action.closeNutrition)
        await store.send(WindowFeature.Action.todayChanged(today))
        await store.finish()
    }

    func testDiarySessionExpiredForwardsExactPayload() async {
        let generation = self.generation
        let today = self.today
        let date = self.date
        let state = WindowFeature.State(sessionGeneration: generation, today: today)
        let store: TestStore<WindowFeature.State, WindowFeature.Action> = TestStore(initialState: state) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.sessionExpired(selectedDate: date, generation: generation)
        )))
        await store.receive(\.delegate, WindowFeature.Delegate.sessionExpired(
            selectedDate: date,
            generation: generation,
            reason: .expired
        ))
        await store.finish()
    }

    func testStaleDiarySessionExpiredIsIgnored() async {
        let generation = self.generation
        let today = self.today
        let date = self.date
        let staleGeneration = UInt64(3)
        let state = WindowFeature.State(sessionGeneration: generation, today: today)
        let store = TestStore(initialState: state) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.sessionExpired(selectedDate: date, generation: staleGeneration)
        )))
        await store.finish()
    }

    func testDiaryOpenMealsAndCopiedDelegatesAreIgnored() async {
        let generation = self.generation
        let today = self.today
        let date = self.date
        let requestID = UUID()
        let diaryClient = DiaryFeature.Client(fetchDay: { (_: LocalDiaryDate, _: UInt64) async throws -> DiaryDay in
            XCTFail("Ignored diary delegate must not fetch")
            throw DiaryServiceError.unknown
        })
        let state = WindowFeature.State(sessionGeneration: generation, today: today)
        let store: TestStore<WindowFeature.State, WindowFeature.Action> = TestStore(initialState: state) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
            $0.diaryClient = diaryClient
        }

        // The log-editor delegate is now forwarded (see the dedicated test);
        // openMeals and copied remain legacy-owned NOOPs with no duplicate GET.
        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.openMeals(date: date, generation: generation)
        )))
        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.copied(
                requestID: requestID,
                destinationDate: date,
                destinationSlot: .dinner,
                sessionGeneration: generation,
                logs: []
            )
        )))
        await store.finish()
    }

    func testDiaryAddFoodDelegateForwardsExactPayload() async {
        let generation = self.generation
        let today = self.today
        let date = self.date
        let state = WindowFeature.State(sessionGeneration: generation, today: today)
        let store = TestStore(initialState: state) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.addFood(slot: .breakfast, date: date, generation: generation)
        )))
        await store.receive(\.delegate, WindowFeature.Delegate.addFood(
            slot: .breakfast,
            date: date,
            generation: generation
        ))
        await store.finish()
    }

    func testStaleDiaryAddFoodDelegateIsIgnored() async {
        let generation = self.generation
        let today = self.today
        let date = self.date
        let store = TestStore(
            initialState: WindowFeature.State(sessionGeneration: generation, today: today)
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.addFood(
                slot: .breakfast,
                date: date,
                generation: generation + 1
            )
        )))
        await store.finish()
    }

    func testExpiredDiaryAddFoodDelegateIsIgnored() async {
        let generation = self.generation
        let today = self.today
        let date = self.date
        let expiredDiary = DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: date),
            sessionGeneration: generation
        )
        let screen = DiaryScreenFeature.State(
            diary: expiredDiary,
            latest: DiaryLatestFeature.State(
                destinationDate: date,
                today: today,
                sessionGeneration: generation
            )
        )
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                diary: screen
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.foodSearchClient.search = { _, _ in [] }
            $0.searchHistoryClient.recentItems = { _, _, _ in [] }
            $0.searchHistoryClient.categorySuggestions = { _, _ in [] }
        }

        await store.send(WindowFeature.Action.diary(DiaryScreenFeature.Action.delegate(
            DiaryScreenFeature.Delegate.addFood(slot: .breakfast, date: date, generation: generation)
        )))
        await store.finish()
    }
}
