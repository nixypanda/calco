import XCTest

@testable import CalCo

private actor FakeMealsService: MealsServicing {
    private var listResult: Result<[Meal], MealServiceError> = .success([])
    private var getMealResult: Result<Meal, MealServiceError> = .failure(
        .notFound("meal not found")
    )
    private var createResult: Result<Meal, MealServiceError> = .failure(.server("unset"))
    private var updateResult: Result<Meal, MealServiceError> = .failure(.server("unset"))
    private var deleteError: MealServiceError?
    private var nutritionResult = MealNutritionResponse(
        mealID: "meal-1",
        quantity: NutritionQuantity(amount: "100", unit: "g"),
        nutritionSummary: NutritionSummary(energyKcal: "100"),
        nutrients: [NutrientAmountValue(code: "ENERGY_KCAL", amount: "100", unit: "kcal")]
    )
    private var nutritionResultsByAmount: [String: MealNutritionResponse] = [:]
    private var nutritionError: MealServiceError?
    private var units: [ProductUnit] = [ProductUnit(code: "g", name: "Gram", kind: "mass")]
    private var unitsError: MealServiceError?
    private var searchResults: [MealProduct] = []
    private var searchResultsByQuery: [String: [MealProduct]] = [:]
    private var searchDelaysByQuery: [String: UInt64] = [:]
    private var searchError: MealServiceError?
    private var componentProducts: [String: MealProduct] = [:]
    private var missingProductIDs: Set<String> = []
    private var componentError: MealServiceError?
    private var nutritionDelayNanoseconds: UInt64 = 0
    private var searchDelayNanoseconds: UInt64 = 0
    private var heldProductIDs: Set<String> = []
    private var startedHeldProductIDs: Set<String> = []
    private var releasedHeldProductIDs: Set<String> = []
    private var productContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var lastUsedResult: Result<NutritionQuantity?, MealServiceError> = .success(nil)
    private var lastUsedRequests: [(String, LocalDiaryDate, MealSlot?)] = []

    private var listCallCount = 0
    private var createRequests: [MealWriteRequest] = []
    private var updateRequests: [(String, MealWriteRequest)] = []
    private var nutritionRequests: [(String, String)] = []
    private var searchQueries: [String] = []
    private var deleteIDs: [String] = []

    func setListResult(_ value: Result<[Meal], MealServiceError>) { listResult = value }
    func setGetMealResult(_ value: Result<Meal, MealServiceError>) { getMealResult = value }
    func setCreateResult(_ value: Result<Meal, MealServiceError>) { createResult = value }
    func setUpdateResult(_ value: Result<Meal, MealServiceError>) { updateResult = value }
    func setDeleteError(_ value: MealServiceError?) { deleteError = value }
    func setNutritionResult(_ value: MealNutritionResponse) { nutritionResult = value }
    func setNutritionResults(_ value: [String: MealNutritionResponse]) {
        nutritionResultsByAmount = value
    }
    func setNutritionError(_ value: MealServiceError?) { nutritionError = value }
    func setUnits(_ value: [ProductUnit]) { units = value }
    func setUnitsError(_ value: MealServiceError?) { unitsError = value }
    func setSearchResults(_ value: [MealProduct]) { searchResults = value }
    func setSearchResults(_ value: [MealProduct], for query: String) {
        searchResultsByQuery[query] = value
    }
    func setSearchDelayNanoseconds(_ value: UInt64, for query: String) {
        searchDelaysByQuery[query] = value
    }
    func setSearchError(_ value: MealServiceError?) { searchError = value }
    func setComponentProducts(_ value: [MealProduct]) {
        componentProducts = Dictionary(uniqueKeysWithValues: value.map { ($0.id, $0) })
    }
    func setMissingProductIDs(_ value: Set<String>) { missingProductIDs = value }
    func setComponentError(_ value: MealServiceError?) { componentError = value }
    func setNutritionDelayNanoseconds(_ value: UInt64) { nutritionDelayNanoseconds = value }
    func setSearchDelayNanoseconds(_ value: UInt64) { searchDelayNanoseconds = value }

    func holdComponentProduct(id: String) {
        heldProductIDs.insert(id)
    }

    func hasStartedComponentProduct(id: String) -> Bool {
        startedHeldProductIDs.contains(id)
    }

    func releaseComponentProduct(id: String) {
        releasedHeldProductIDs.insert(id)
        productContinuations.removeValue(forKey: id)?.resume()
    }
    func setLastUsedResult(_ value: Result<NutritionQuantity?, MealServiceError>) {
        lastUsedResult = value
    }

    func recordedListCallCount() -> Int { listCallCount }
    func recordedCreateRequests() -> [MealWriteRequest] { createRequests }
    func recordedUpdateRequests() -> [(String, MealWriteRequest)] { updateRequests }
    func recordedNutritionRequests() -> [(String, String)] { nutritionRequests }
    func recordedSearchQueries() -> [String] { searchQueries }
    func recordedDeleteIDs() -> [String] { deleteIDs }
    func recordedLastUsedRequests() -> [(String, LocalDiaryDate, MealSlot?)] {
        lastUsedRequests
    }

    func listMeals() async throws -> [Meal] {
        listCallCount += 1
        return try listResult.get()
    }

    func getMeal(id: String) async throws -> Meal {
        try getMealResult.get()
    }

    func createMeal(_ request: MealWriteRequest) async throws -> Meal {
        createRequests.append(request)
        return try createResult.get()
    }

    func updateMeal(id: String, _ request: MealWriteRequest) async throws -> Meal {
        updateRequests.append((id, request))
        return try updateResult.get()
    }

    func deleteMeal(id: String) async throws {
        deleteIDs.append(id)
        if let deleteError { throw deleteError }
    }

    func mealNutrients(
        mealID: String,
        amount: String,
        unit: String
    ) async throws -> MealNutritionResponse {
        nutritionRequests.append((amount, unit))
        if nutritionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: nutritionDelayNanoseconds)
        }
        if let nutritionError { throw nutritionError }
        return nutritionResultsByAmount[amount] ?? nutritionResult
    }

    func fetchUnits() async throws -> [ProductUnit] {
        if let unitsError { throw unitsError }
        return units
    }

    func searchComponentProducts(query: String) async throws -> [MealProduct] {
        searchQueries.append(query)
        let delay = searchDelaysByQuery[query] ?? searchDelayNanoseconds
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if let searchError { throw searchError }
        return searchResultsByQuery[query] ?? searchResults
    }

    func fetchComponentProduct(id: String) async throws -> MealProduct {
        if heldProductIDs.contains(id) {
            startedHeldProductIDs.insert(id)
            if !releasedHeldProductIDs.contains(id) {
                await withCheckedContinuation { continuation in
                    productContinuations[id] = continuation
                }
            }
        }
        if let componentError { throw componentError }
        if missingProductIDs.contains(id) {
            throw MealServiceError.notFound("product \(id) not found")
        }
        if let product = componentProducts[id] {
            return product
        }
        return MealProduct(id: id, name: "Food \(id)")
    }

    func lastUsedPortion(
        forMealID mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> NutritionQuantity? {
        lastUsedRequests.append((mealID, date, mealSlot))
        return try lastUsedResult.get()
    }
}

private final class MealLogRecorder {
    var drafts: [LogSubmissionDraft] = []
    var itemNames: [String] = []
    var summaries: [String] = []
    var calls = 0
    var result: LogSubmissionServiceResult = .success([])

    var handler: LogSubmissionHandler {
        { [weak self] drafts, itemNames, summary, completion in
            guard let self else { return }
            self.calls += 1
            self.drafts = drafts
            self.itemNames = itemNames
            self.summaries.append(summary)
            completion(self.result)
        }
    }
}

@MainActor
final class MealsTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    private func makeMeal(
        id: String = "meal-1",
        name: String = "Porridge",
        notes: String? = "Morning meal",
        total: NutritionQuantity? = NutritionQuantity(amount: "250", unit: "g"),
        componentProducts: [String] = ["oats", "milk"],
        componentAmounts: [String] = ["50", "200"]
    ) -> Meal {
        Meal(
            id: id,
            name: name,
            notes: notes,
            totalQuantity: total,
            nutritionSummary: NutritionSummary(energyKcal: "310", proteinG: "12.5"),
            components: zip(componentProducts, componentAmounts).enumerated().map { index, pair in
                MealComponent(
                    id: "component-\(index + 1)",
                    item: ItemReference(itemType: .product, id: pair.0),
                    quantity: NutritionQuantity(amount: pair.1, unit: "g"),
                    nutritionSummary: NutritionSummary(energyKcal: index == 0 ? "190" : "120")
                )
            },
            createdAt: "2026-11-19T08:00:00Z",
            updatedAt: "2026-11-19T08:00:00Z"
        )
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for state", file: file, line: line)
    }

    private func editorViewModel(
        mode: MealEditorMode,
        service: FakeMealsService,
        accountID: String = "account-1",
        searchDebounceNanoseconds: UInt64 = 300_000_000,
        onSessionExpired: @escaping () -> Void = {},
        onSaved: @escaping (Meal) -> Void = { _ in }
    ) -> MealEditorViewModel {
        MealEditorViewModel(
            mode: mode,
            accountID: accountID,
            service: service,
            onSessionExpired: onSessionExpired,
            onSaved: onSaved,
            searchDebounceNanoseconds: searchDebounceNanoseconds
        )
    }

    func testListLoadAndQuickAddUsesTypedMealDraft() async {
        let service = FakeMealsService()
        let meal = makeMeal()
        await service.setListResult(.success([meal]))
        let logs = MealLogRecorder()
        var loggedContexts: [(LocalDiaryDate, MealSlot?)] = []
        let viewModel = MealsListViewModel(
            date: date,
            mealSlot: .lunch,
            service: service,
            onSubmitDrafts: logs.handler,
            onLogged: { date, slot in loggedContexts.append((date, slot)) }
        )

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded([meal]))
        XCTAssertEqual(viewModel.meals.map(\.id), [meal.id])

        viewModel.quickAdd(meal)
        XCTAssertEqual(logs.calls, 1)
        let draft = logs.drafts.first
        XCTAssertEqual(draft?.item, .meal(id: "meal-1"))
        XCTAssertEqual(draft?.date, date)
        XCTAssertEqual(draft?.mealSlot, .lunch)
        XCTAssertEqual(draft?.amount, "250")
        XCTAssertEqual(draft?.unit, "g")
        XCTAssertEqual(logs.itemNames, ["Porridge"])

        await waitUntil {
            viewModel.quickAddState == .added(mealID: "meal-1")
        }
        XCTAssertEqual(loggedContexts.count, 1)
        XCTAssertEqual(loggedContexts.first?.0, date)
        XCTAssertEqual(loggedContexts.first?.1, .lunch)
    }

    func testListQuickAddAcceptsRecentPortionOverride() async {
        let service = FakeMealsService()
        let meal = makeMeal()
        await service.setListResult(.success([meal]))
        let logs = MealLogRecorder()
        let viewModel = MealsListViewModel(
            date: date,
            service: service,
            onSubmitDrafts: logs.handler
        )
        await viewModel.load()

        viewModel.quickAdd(meal, portion: NutritionQuantity(amount: "125", unit: "g"))

        XCTAssertEqual(logs.drafts.first?.amount, "125")
        XCTAssertEqual(logs.drafts.first?.unit, "g")
    }

    func testListQuickAddFallsBackToGramsForNonMassTotal() async {
        let service = FakeMealsService()
        let meal = makeMeal(total: NutritionQuantity(amount: "4", unit: "serving"))
        await service.setListResult(.success([meal]))
        let logs = MealLogRecorder()
        let viewModel = MealsListViewModel(
            date: date,
            mealSlot: nil,
            service: service,
            onSubmitDrafts: logs.handler
        )

        await viewModel.load()
        viewModel.quickAdd(meal)

        XCTAssertEqual(logs.drafts.first?.amount, "100")
        XCTAssertEqual(logs.drafts.first?.unit, "g")
    }

    func testListFailureAndUnauthorizedSignalSession() async {
        let service = FakeMealsService()
        await service.setListResult(.failure(.unauthorized))
        var sessionExpired = 0
        let viewModel = MealsListViewModel(
            date: date,
            service: service,
            onSessionExpired: { sessionExpired += 1 }
        )

        await viewModel.load()

        XCTAssertEqual(sessionExpired, 1)
        guard case .failed(let message) = viewModel.state else {
            return XCTFail("Expected failed list state")
        }
        XCTAssertEqual(message, String(localized: "meals.error.sessionExpired"))
    }

    func testDetailLoadDefaultsPortionResolvesNamesAndPreviewsServerNutrition() async {
        let service = FakeMealsService()
        let meal = makeMeal()
        await service.setGetMealResult(.success(meal))
        await service.setUnits([
            ProductUnit(code: "g", name: "Gram", kind: "mass"),
            ProductUnit(code: "kg", name: "Kilogram", kind: "mass"),
            ProductUnit(code: "serving", name: "Serving", kind: "serving"),
        ])
        await service.setComponentProducts([
            MealProduct(id: "oats", name: "Oats"),
            MealProduct(id: "milk", name: "Milk"),
        ])
        let nutrition = MealNutritionResponse(
            mealID: "meal-1",
            quantity: NutritionQuantity(amount: "250", unit: "g"),
            nutritionSummary: NutritionSummary(energyKcal: "310"),
            nutrients: [NutrientAmountValue(code: "ENERGY_KCAL", amount: "310", unit: "kcal")]
        )
        await service.setNutritionResult(nutrition)
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            mealSlot: .breakfast,
            service: service,
            previewDebounceNanoseconds: 0
        )

        await viewModel.load()
        await waitUntil {
            viewModel.previewState == .loaded(nutrition)
        }

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.portionAmount, "250")
        XCTAssertEqual(viewModel.portionUnit, "g")
        XCTAssertEqual(viewModel.availableUnits.map(\.code), ["g", "kg"])
        XCTAssertEqual(viewModel.componentName(meal.components[0]), "Oats")
        XCTAssertEqual(viewModel.componentName(meal.components[1]), "Milk")
        let requests = await service.recordedNutritionRequests()
        XCTAssertEqual(requests.first?.0, "250")
        XCTAssertEqual(requests.first?.1, "g")
    }

    func testDetailUsesInjectedLastUsedPortionWhenValid() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            initialPortion: NutritionQuantity(amount: "175", unit: "g"),
            service: service,
            previewDebounceNanoseconds: 0
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.portionAmount, "175")
        XCTAssertEqual(viewModel.portionUnit, "g")
        XCTAssertNil(viewModel.portionFallbackNotice)

        let invalidService = FakeMealsService()
        await invalidService.setGetMealResult(.success(makeMeal()))
        let invalidViewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            initialPortion: NutritionQuantity(amount: "1", unit: "serving"),
            service: invalidService,
            previewDebounceNanoseconds: 0
        )
        await invalidViewModel.load()
        XCTAssertEqual(invalidViewModel.portionAmount, "250")
        XCTAssertEqual(invalidViewModel.portionUnit, "g")
        XCTAssertEqual(
            invalidViewModel.portionFallbackNotice,
            String(localized: "meals.detail.lastUsed.unavailableUnit")
        )
    }

    func testDetailFetchesServerLastUsedWhenNoInjectedPortion() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        await service.setLastUsedResult(.success(
            NutritionQuantity(amount: "180", unit: "g")
        ))
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            mealSlot: .breakfast,
            service: service,
            previewDebounceNanoseconds: 0
        )

        await viewModel.load()
        await waitUntil { viewModel.portionAmount == "180" }

        XCTAssertEqual(viewModel.portionUnit, "g")
        XCTAssertNil(viewModel.portionFallbackNotice)
        let requests = await service.recordedLastUsedRequests()
        XCTAssertEqual(requests.first?.0, "meal-1")
        XCTAssertEqual(requests.first?.1, date)
        XCTAssertEqual(requests.first?.2, .breakfast)
    }

    func testDetailNonMassTotalUsesHundredGramPortion() async {
        let service = FakeMealsService()
        let meal = makeMeal(total: NutritionQuantity(amount: "2", unit: "serving"))
        await service.setGetMealResult(.success(meal))
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service,
            previewDebounceNanoseconds: 0
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.portionAmount, "100")
        XCTAssertEqual(viewModel.portionUnit, "g")
    }

    func testDegradedMealDisablesQuickAddPreviewAndLogging() async {
        let service = FakeMealsService()
        let missingComponent = MealComponent(
            id: "component-missing",
            item: ItemReference(itemType: .product, id: "deleted"),
            quantity: NutritionQuantity(amount: "200", unit: "g"),
            nutritionSummary: nil,
            missing: true,
            missingReason: "product_unavailable",
            name: "Unavailable food"
        )
        let meal = Meal(
            id: "meal-broken",
            name: "Broken Porridge",
            totalQuantity: NutritionQuantity(amount: "250", unit: "g"),
            nutritionSummary: nil,
            components: [missingComponent],
            hasMissingComponents: true
        )
        await service.setGetMealResult(.success(meal))
        await service.setListResult(.success([meal]))
        let list = MealsListViewModel(
            date: date,
            mealSlot: .breakfast,
            service: service,
            onSubmitDrafts: { _, _, _, _ in }
        )
        await list.load()
        XCTAssertFalse(list.canQuickAdd(meal))
        XCTAssertTrue(meal.isDegraded)

        let detail = MealDetailViewModel(
            mealID: meal.id,
            date: date,
            mealSlot: .breakfast,
            service: service,
            onSubmitDrafts: { _, _, _, _ in },
            previewDebounceNanoseconds: 0
        )
        await detail.load()

        XCTAssertEqual(detail.loadState, .loaded)
        XCTAssertFalse(detail.canLog)
        XCTAssertNotNil(detail.missingComponentsMessage)
        XCTAssertEqual(detail.componentName(missingComponent), "Unavailable food")
        XCTAssertEqual(
            detail.previewState,
            .unavailable(String(localized: "meals.error.missingComponents"))
        )
        let nutritionRequests = await service.recordedNutritionRequests()
        XCTAssertTrue(nutritionRequests.isEmpty)
    }

    func testDetailLogUsesTypedMealDraftAndJournalResult() async {
        let service = FakeMealsService()
        let meal = makeMeal()
        await service.setGetMealResult(.success(meal))
        let logs = MealLogRecorder()
        var logged: [(LocalDiaryDate, MealSlot?)] = []
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            mealSlot: .dinner,
            service: service,
            onSubmitDrafts: logs.handler,
            onLogged: { date, slot in logged.append((date, slot)) },
            previewDebounceNanoseconds: 0
        )
        await viewModel.load()
        viewModel.portionAmountChanged("150")
        viewModel.logNotesChanged("small portion")

        viewModel.logMeal()
        await waitUntil {
            if case .succeeded = viewModel.logState { return true }
            return false
        }

        XCTAssertEqual(logs.calls, 1)
        let draft = logs.drafts.first
        XCTAssertEqual(draft?.item, .meal(id: "meal-1"))
        XCTAssertEqual(draft?.date, date)
        XCTAssertEqual(draft?.mealSlot, .dinner)
        XCTAssertEqual(draft?.amount, "150")
        XCTAssertEqual(draft?.unit, "g")
        XCTAssertEqual(draft?.notes, "small portion")
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.1, .dinner)
    }

    func testDetailInvalidPortionBlocksPreviewAndLog() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        let logs = MealLogRecorder()
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service,
            onSubmitDrafts: logs.handler,
            previewDebounceNanoseconds: 0
        )
        await viewModel.load()
        viewModel.portionAmountChanged("")

        XCTAssertNotNil(viewModel.amountValidationMessage)
        if case .unavailable = viewModel.previewState {
            // Expected.
        } else {
            XCTFail("Expected unavailable preview state")
        }
        viewModel.logMeal()
        XCTAssertEqual(logs.calls, 0)
    }

    func testDetailIgnoresStalePreviewResponse() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        await service.setNutritionDelayNanoseconds(150_000_000)
        let stale = MealNutritionResponse(
            mealID: "meal-1",
            quantity: NutritionQuantity(amount: "250", unit: "g"),
            nutritionSummary: NutritionSummary(energyKcal: "310"),
            nutrients: [
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "310", unit: "kcal")
            ]
        )
        let fresh = MealNutritionResponse(
            mealID: "meal-1",
            quantity: NutritionQuantity(amount: "50", unit: "g"),
            nutritionSummary: NutritionSummary(energyKcal: "62"),
            nutrients: [
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "62", unit: "kcal")
            ]
        )
        await service.setNutritionResults(["250": stale, "50": fresh])
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service,
            previewDebounceNanoseconds: 0
        )
        await viewModel.load()
        try? await Task.sleep(nanoseconds: 20_000_000)
        viewModel.portionAmountChanged("50")

        await waitUntil {
            if case .loaded(let response) = viewModel.previewState {
                return response.quantity.amount == "50"
            }
            return false
        }
        let requests = await service.recordedNutritionRequests()
        XCTAssertTrue(requests.contains { $0.0 == "50" })
        XCTAssertEqual(viewModel.previewState, .loaded(
            MealNutritionResponse(
                mealID: "meal-1",
                quantity: NutritionQuantity(amount: "50", unit: "g"),
                nutritionSummary: NutritionSummary(energyKcal: "62"),
                nutrients: [
                    NutrientAmountValue(code: "ENERGY_KCAL", amount: "62", unit: "kcal")
                ]
            )
        ))
    }

    func testDetailDeleteNotFoundIsTreatedAsDeleted() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        await service.setDeleteError(.notFound("meal not found"))
        var deleted = 0
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service,
            onDeleted: { deleted += 1 }
        )
        await viewModel.load()

        await viewModel.deleteMeal()

        XCTAssertEqual(viewModel.deleteState, .deleted)
        XCTAssertEqual(deleted, 1)
        let ids = await service.recordedDeleteIDs()
        XCTAssertEqual(ids, ["meal-1"])
    }

    func testDetailMissingComponentNameIsVisible() async {
        let service = FakeMealsService()
        let meal = makeMeal()
        await service.setGetMealResult(.success(meal))
        await service.setMissingProductIDs(["milk"])
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service,
            previewDebounceNanoseconds: 0
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.missingComponentIDs.contains("milk"))
        XCTAssertEqual(
            viewModel.componentName(meal.components[1]),
            String(localized: "meals.editor.missingFood")
        )
        XCTAssertNotNil(viewModel.missingComponentsMessage)
    }

    func testDetailMissingComponentsLoadFailureIsFlagged() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.failure(.missingComponents("product oats not found")))
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service
        )

        await viewModel.load()

        guard case .failed(_, let missingComponents) = viewModel.loadState else {
            return XCTFail("Expected failed load")
        }
        XCTAssertTrue(missingComponents)
    }

    func testEditorCreateSaveBuildsValidatedRequest() async {
        let service = FakeMealsService()
        let saved = makeMeal(id: "meal-new", name: "Oats Bowl")
        await service.setCreateResult(.success(saved))
        var savedMeals: [Meal] = []
        let viewModel = editorViewModel(
            mode: .create,
            service: service,
            searchDebounceNanoseconds: 0,
            onSaved: { savedMeals.append($0) }
        )
        await viewModel.load()
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.name = "Oats Bowl"
        viewModel.notes = "  Breakfast  "
        viewModel.totalAmount = "50"
        viewModel.totalUnit = "g"
        viewModel.selectProduct(rowID: 1, product: MealProduct(id: "oats", name: "Oats"))
        viewModel.componentAmountChanged(rowID: 1, amount: "50")
        viewModel.componentUnitChanged(rowID: 1, unit: "g")
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        await viewModel.save()

        XCTAssertTrue(viewModel.didSave)
        XCTAssertEqual(savedMeals.map(\.id), ["meal-new"])
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        let requests = await service.recordedCreateRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.name, "Oats Bowl")
        XCTAssertEqual(requests.first?.notes, "Breakfast")
        XCTAssertEqual(requests.first?.totalQuantity, NutritionQuantity(amount: "50", unit: "g"))
        XCTAssertEqual(requests.first?.components.count, 1)
        XCTAssertEqual(requests.first?.components.first?.item.itemType, .product)
        XCTAssertEqual(requests.first?.components.first?.item.id, "oats")
        XCTAssertEqual(
            requests.first?.components.first?.quantity,
            NutritionQuantity(amount: "50", unit: "g")
        )
    }

    func testEditorSaveCannotCreateTwice() async {
        let service = FakeMealsService()
        await service.setCreateResult(.success(makeMeal(id: "meal-1")))
        let viewModel = editorViewModel(mode: .create, service: service)
        await viewModel.load()
        viewModel.name = "Meal"
        viewModel.selectProduct(rowID: 1, product: MealProduct(id: "oats", name: "Oats"))
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        await viewModel.save()
        await viewModel.save()

        let requests = await service.recordedCreateRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testUncertainCreateShowsOrdinaryErrorAndAllowsExplicitRetry() async {
        let service = FakeMealsService()
        await service.setCreateResult(.failure(.network))
        let viewModel = editorViewModel(mode: .create, service: service)
        await viewModel.load()
        viewModel.name = "Meal"
        viewModel.selectProduct(rowID: 1, product: MealProduct(id: "oats", name: "Oats"))
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        await viewModel.save()

        XCTAssertFalse(viewModel.didSave)
        XCTAssertFalse(viewModel.isSaveBlocked)
        XCTAssertEqual(
            viewModel.saveErrorMessage,
            String(
                localized: "meals.editor.createUncertain",
                defaultValue: "CalCo couldn't confirm whether this meal was saved. Refresh the list before trying again."
            )
        )

        await service.setCreateResult(.success(makeMeal(id: "meal-new")))
        await viewModel.save()

        let requests = await service.recordedCreateRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(viewModel.didSave)
    }

    func testEditorValidationBlocksSave() async {
        let service = FakeMealsService()
        let viewModel = editorViewModel(mode: .create, service: service)
        await viewModel.load()

        await viewModel.save()

        XCTAssertEqual(
            viewModel.displayErrorMessage,
            String(localized: "meals.editor.error.nameRequired")
        )
        XCTAssertFalse(viewModel.didSave)

        viewModel.name = "Meal"
        await viewModel.save()
        XCTAssertEqual(
            viewModel.displayErrorMessage,
            String(localized: "meals.editor.error.componentRequired")
        )

        viewModel.selectProduct(rowID: 1, product: MealProduct(id: "oats", name: "Oats"))
        viewModel.componentAmountChanged(rowID: 1, amount: "0")
        await viewModel.save()
        XCTAssertEqual(
            viewModel.displayErrorMessage,
            String(localized: "meals.editor.error.quantityInvalid")
        )

        let requests = await service.recordedCreateRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testEditorComponentSearchPickerAndSelectionReset() async {
        let service = FakeMealsService()
        await service.setSearchResults([
            MealProduct(id: "oats", name: "Oats", brand: "Farm"),
            MealProduct(id: "milk", name: "Milk"),
        ])
        let viewModel = editorViewModel(
            mode: .create,
            service: service,
            searchDebounceNanoseconds: 0
        )
        await viewModel.load()

        viewModel.searchQueryChanged(rowID: 1, query: "oa")
        await waitUntil {
            if case .results(let products) = viewModel.components[0].searchState {
                return products.count == 2
            }
            return false
        }
        let queries = await service.recordedSearchQueries()
        XCTAssertEqual(queries, ["oa"])

        viewModel.selectProduct(rowID: 1, product: MealProduct(id: "oats", name: "Oats"))
        XCTAssertEqual(viewModel.components[0].productID, "oats")
        XCTAssertEqual(viewModel.components[0].query, "Oats")

        viewModel.searchQueryChanged(rowID: 1, query: "Oat")
        XCTAssertEqual(viewModel.components[0].productID, "")
        XCTAssertNil(viewModel.components[0].productName)
    }

    func testEditorEditLoadsMissingComponentAndReplacesIt() async {
        let service = FakeMealsService()
        let meal = makeMeal()
        await service.setGetMealResult(.success(meal))
        await service.setMissingProductIDs(["milk"])
        let updated = makeMeal(componentProducts: ["oats"], componentAmounts: ["80"])
        await service.setUpdateResult(.success(updated))
        let viewModel = editorViewModel(
            mode: .edit(id: "meal-1"),
            service: service,
            searchDebounceNanoseconds: 0
        )

        await viewModel.load()
        await waitUntil { !viewModel.components[1].isResolvingName }
        XCTAssertTrue(viewModel.components[1].isMissing)
        XCTAssertTrue(viewModel.validationErrors.contains(.componentMissing))
        XCTAssertFalse(viewModel.hasUnsavedChanges)

        viewModel.removeComponent(rowID: viewModel.components[1].id)
        XCTAssertEqual(viewModel.components.count, 1)
        viewModel.selectProduct(
            rowID: viewModel.components[0].id,
            product: MealProduct(id: "oats", name: "Oats")
        )
        viewModel.componentAmountChanged(rowID: viewModel.components[0].id, amount: "80")

        XCTAssertFalse(viewModel.validationErrors.contains(.componentMissing))
        await viewModel.save()

        XCTAssertTrue(viewModel.didSave)
        let updates = await service.recordedUpdateRequests()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.0, "meal-1")
        XCTAssertEqual(updates.first?.1.components.count, 1)
        XCTAssertEqual(updates.first?.1.components.first?.item.id, "oats")
    }

    func testEditorComponentSearchIgnoresStaleQueryResponse() async {
        let service = FakeMealsService()
        await service.setSearchResults([MealProduct(id: "oats", name: "Oats")], for: "oa")
        await service.setSearchResults([MealProduct(id: "milk", name: "Milk")], for: "mi")
        await service.setSearchDelayNanoseconds(150_000_000, for: "oa")
        let viewModel = editorViewModel(
            mode: .create,
            service: service,
            searchDebounceNanoseconds: 0
        )
        await viewModel.load()

        viewModel.searchQueryChanged(rowID: 1, query: "oa")
        let searchDeadline = Date().addingTimeInterval(2)
        while !(await service.recordedSearchQueries()).contains("oa"),
              Date() < searchDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let firstQueries = await service.recordedSearchQueries()
        XCTAssertTrue(firstQueries.contains("oa"))
        viewModel.searchQueryChanged(rowID: 1, query: "mi")
        await waitUntil {
            if case .results(let products) = viewModel.components[0].searchState {
                return products.map(\.id) == ["milk"]
            }
            return false
        }
        try? await Task.sleep(nanoseconds: 220_000_000)

        guard case .results(let products) = viewModel.components[0].searchState else {
            return XCTFail("Expected the fresh search results to remain")
        }
        XCTAssertEqual(products.map(\.id), ["milk"])
    }

    func testLateComponentNameCannotOverwriteNewlySelectedProduct() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        await service.setMissingProductIDs(["milk"])
        await service.holdComponentProduct(id: "milk")
        let viewModel = editorViewModel(
            mode: .edit(id: "meal-1"),
            service: service,
            searchDebounceNanoseconds: 0
        )

        await viewModel.load()
        let deadline = Date().addingTimeInterval(2)
        while !(await service.hasStartedComponentProduct(id: "milk")),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let milkRow = viewModel.components.first { $0.productID == "milk" }
        let rowID = milkRow?.id ?? viewModel.components[1].id
        viewModel.selectProduct(
            rowID: rowID,
            product: MealProduct(id: "replacement", name: "Replacement Food")
        )
        await service.releaseComponentProduct(id: "milk")
        try? await Task.sleep(nanoseconds: 30_000_000)

        let row = viewModel.components.first { $0.id == rowID }
        XCTAssertEqual(row?.productID, "replacement")
        XCTAssertEqual(row?.productName, "Replacement Food")
        XCTAssertEqual(row?.query, "Replacement Food")
        XCTAssertEqual(row?.isMissing, false)
    }

    func testEditorEditClearsOptionalNotesAndTotal() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        await service.setUpdateResult(.success(makeMeal(notes: nil, total: nil)))
        let viewModel = editorViewModel(mode: .edit(id: "meal-1"), service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.notes, "Morning meal")
        XCTAssertEqual(viewModel.totalAmount, "250")

        viewModel.notes = "   "
        viewModel.totalAmount = ""
        await viewModel.save()

        let updates = await service.recordedUpdateRequests()
        XCTAssertEqual(updates.count, 1)
        XCTAssertNil(updates.first?.1.notes)
        XCTAssertNil(updates.first?.1.totalQuantity)
    }

    func testDetailPreviewFailureCanRetry() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        await service.setNutritionError(.network)
        let viewModel = MealDetailViewModel(
            mealID: "meal-1",
            date: date,
            service: service,
            previewDebounceNanoseconds: 0
        )
        await viewModel.load()
        await waitUntil {
            if case .failed = viewModel.previewState { return true }
            return false
        }

        await service.setNutritionError(nil)
        let nutrition = MealNutritionResponse(
            mealID: "meal-1",
            quantity: NutritionQuantity(amount: "250", unit: "g"),
            nutritionSummary: NutritionSummary(energyKcal: "310"),
            nutrients: [NutrientAmountValue(code: "ENERGY_KCAL", amount: "310", unit: "kcal")]
        )
        await service.setNutritionResult(nutrition)
        viewModel.refreshPreview()

        await waitUntil {
            viewModel.previewState == .loaded(nutrition)
        }
    }

    func testEditorDirtyTrackingUsesLoadedBaseline() async {
        let service = FakeMealsService()
        await service.setGetMealResult(.success(makeMeal()))
        let viewModel = editorViewModel(mode: .edit(id: "meal-1"), service: service)
        await viewModel.load()

        XCTAssertFalse(viewModel.hasUnsavedChanges)
        viewModel.name = "Porridge Deluxe"
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        viewModel.name = "Porridge"
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testEditorSaveUnauthorizedSignalsSessionAndKeepsForm() async {
        let service = FakeMealsService()
        await service.setCreateResult(.failure(.unauthorized))
        var sessionExpired = 0
        let viewModel = editorViewModel(
            mode: .create,
            service: service,
            onSessionExpired: { sessionExpired += 1 }
        )
        await viewModel.load()
        viewModel.name = "Meal"
        viewModel.selectProduct(rowID: 1, product: MealProduct(id: "oats", name: "Oats"))
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        await viewModel.save()

        XCTAssertEqual(sessionExpired, 1)
        XCTAssertEqual(
            viewModel.saveErrorMessage,
            String(localized: "meals.error.sessionExpired")
        )
        XCTAssertFalse(viewModel.didSave)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
    }

    func testMealQuantityRulesAndDefaultPortion() {
        XCTAssertEqual(MealQuantityRules.normalizedPositiveDecimal(" 2.50 "), "2.50")
        XCTAssertEqual(MealQuantityRules.normalizedPositiveDecimal(".5"), "0.5")
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("0"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("-1"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("1,5"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("1e3"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("abc"))

        let massMeal = makeMeal(total: NutritionQuantity(amount: "250", unit: "kg"))
        XCTAssertEqual(massMeal.defaultPortion, NutritionQuantity(amount: "250", unit: "kg"))
        let nonMassMeal = makeMeal(total: NutritionQuantity(amount: "2", unit: "serving"))
        XCTAssertEqual(nonMassMeal.defaultPortion, NutritionQuantity(amount: "100", unit: "g"))

        let draft = MealLogDraftBuilder.makeDraft(
            meal: massMeal,
            date: date,
            mealSlot: .snack,
            amount: "1.5",
            unit: "kg",
            notes: "  ",
            timeZone: "UTC"
        )
        XCTAssertEqual(draft?.item, .meal(id: "meal-1"))
        XCTAssertEqual(draft?.amount, "1.5")
        XCTAssertEqual(draft?.unit, "kg")
        XCTAssertNil(draft?.notes)
        XCTAssertNil(
            MealLogDraftBuilder.makeDraft(
                meal: massMeal,
                date: date,
                mealSlot: nil,
                amount: "1",
                unit: "serving",
                timeZone: "UTC"
            )
        )
    }
}
