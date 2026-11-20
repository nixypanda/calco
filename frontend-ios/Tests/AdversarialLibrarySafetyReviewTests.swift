import XCTest

@testable import CalCo

/// Adversarial regression checks for cross-window catalog reconciliation and
/// the save-food-then-log crash window. These use only in-memory persistence
/// and injected fakes; no network, database, real keys, or app-support files.
@MainActor
final class AdversarialLibrarySafetyReviewTests: XCTestCase {
    private let accountID = "review-account"

    private func draft(name: String) -> CustomFoodWriteRequest {
        CustomFoodWriteRequest(
            name: name,
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: 100),
                .init(code: "PROTEIN_G", amountPer100g: 4),
                .init(code: "CARBS_G", amountPer100g: 10),
                .init(code: "FAT_G", amountPer100g: 2),
            ]
        )
    }

    private func logIntent() -> CustomFoodLogIntent {
        CustomFoodLogIntent(
            date: LocalDiaryDate(year: 2026, month: 11, day: 19),
            mealSlot: .lunch,
            amount: "1",
            unit: "bowl",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
    }

    /// Two windows share `CustomFoodReconciliationStore`. A window holding an
    /// older attempt must not be able to clear the safety record another window
    /// created after that older attempt was discarded.
    func testStaleReconciliationCannotClearNewerAttemptFromAnotherWindow() async throws {
        let store = CustomFoodReconciliationStore(
            persistence: MemoryReconciliationPersistence()
        )
        let service = FakeLibraryService()
        let windowA = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        let windowB = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )

        service.enqueueCreate(.failure(.uncertain("lost A")))
        guard case .needsReconciliation(let attemptA) = await windowA.create(
            draft: draft(name: "Oats A"),
            baselineFoodIDs: []
        ) else {
            return XCTFail("expected the first window to reserve an attempt")
        }

        // Window B resolves the first uncertainty, then starts a fresh create
        // whose safety record is now the only durable guard against duplicates.
        try windowB.discard(attempt: attemptA)
        service.enqueueCreate(.failure(.uncertain("lost B")))
        guard case .needsReconciliation(let attemptB) = await windowB.create(
            draft: draft(name: "Oats B"),
            baselineFoodIDs: []
        ) else {
            return XCTFail("expected the second window to reserve an attempt")
        }

        // Window A still displays the stale attempt. Accepting its candidate
        // must not erase window B's newer attempt.
        XCTAssertThrowsError(
            try windowA.resolve(
                attempt: attemptA,
                food: LibraryTestFixtures.food(matching: draft(name: "Oats A"), id: "candidate-a")
            )
        )
        XCTAssertEqual(
            try store.attempt(accountID: accountID)?.id,
            attemptB.id,
            "a stale window must not clear a newer custom-food safety record"
        )
    }

    /// AI drafts may name a serving unit ("plate", "bowl", ...) that is not in
    /// the server's global unit list. The ad-hoc editor must merge that unit so
    /// the picker can display the accepted draft instead of showing no selection.
    func testAssistantSuggestedServingUnitIsSelectableInAdHocEditor() async throws {
        let service = FakeLibraryService()
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: FakeLibraryLogSubmissionService(results: []),
            reconciliationStore: CustomFoodReconciliationStore(
                persistence: MemoryReconciliationPersistence()
            ),
            accountID: accountID,
            initialDate: LocalDiaryDate(year: 2026, month: 11, day: 19),
            today: LocalDiaryDate(year: 2026, month: 11, day: 19),
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await adHoc.load()
        let payload = AssistantFoodDraftPayload(
            name: "Curry",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "100"),
                .init(code: "PROTEIN_G", amountPer100g: "4"),
                .init(code: "CARBS_G", amountPer100g: "10"),
                .init(code: "FAT_G", amountPer100g: "2"),
            ],
            servings: [
                .init(unit: "plate", gramsPerUnit: "350"),
            ]
        )
        let draft = try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: AssistantSuggestedLog(
                amount: "1",
                unit: "plate",
                totalWeightGrams: "350"
            ),
            warnings: []
        )

        XCTAssertTrue(adHoc.applyAssistantDraft(draft))
        XCTAssertEqual(adHoc.unit, "plate")
        XCTAssertTrue(
            adHoc.units.contains { $0.code == "plate" },
            "the unit picker must be able to represent the assistant's serving unit"
        )
    }

    /// Switching an AI-prefilled ad-hoc draft from its serving unit to grams
    /// must not turn the absolute nutrient totals into a wildly wrong per-100 g
    /// catalog food. Today the old portion weight stays visible but is ignored
    /// for grams, while the nutrient totals still describe the original serving.
    func testAssistantUnitChangeToGramsMustNotCorruptPer100g() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [.success(logs: [], replayed: false)]
        )
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: submission,
            reconciliationStore: CustomFoodReconciliationStore(
                persistence: MemoryReconciliationPersistence()
            ),
            accountID: accountID,
            initialDate: LocalDiaryDate(year: 2026, month: 11, day: 19),
            today: LocalDiaryDate(year: 2026, month: 11, day: 19),
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await adHoc.load()
        let payload = AssistantFoodDraftPayload(
            name: "Curry",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "100"),
                .init(code: "PROTEIN_G", amountPer100g: "4"),
                .init(code: "CARBS_G", amountPer100g: "10"),
                .init(code: "FAT_G", amountPer100g: "2"),
            ],
            servings: [
                .init(unit: "plate", gramsPerUnit: "350"),
            ]
        )
        let draft = try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: AssistantSuggestedLog(
                amount: "1",
                unit: "plate",
                totalWeightGrams: "350"
            ),
            warnings: []
        )
        XCTAssertTrue(adHoc.applyAssistantDraft(draft))
        adHoc.mode = .saveAndLog

        // The picker cannot show "plate" today, so selecting a listed mass unit
        // is a realistic recovery attempt by the user.
        adHoc.unit = "g"
        adHoc.requestReview()
        guard adHoc.pendingReview != nil else { return } // blocking review is safe
        service.enqueueCreate(.success("new-food"))
        await adHoc.confirmReview()

        let created = try XCTUnwrap(service.createdRequests.first)
        let energy = try XCTUnwrap(
            created.nutrients.first { $0.code == "ENERGY_KCAL" }
        )
        XCTAssertEqual(
            energy.amountPer100g,
            Decimal(100),
            "changing the display unit must not turn 100 kcal/100 g into \(energy.amountPer100g) kcal/100 g"
        )
    }

    /// Reconciliation can only distinguish a new meal from an older identical
    /// one if the pre-create baseline was actually read. A failed list must not
    /// degrade to an empty baseline and send the non-idempotent POST anyway.
    func testMealCreateFailsClosedWhenBaselineMealListFails() async {
        let service = ReviewMealsService()
        service.listResult = .failure(.network)
        service.createResult = .success(
            Meal(id: "meal-1", name: "Review Meal")
        )
        let viewModel = MealEditorViewModel(
            mode: .create,
            accountID: accountID,
            service: service,
            reconciliationStore: MealCreateReconciliationStore(
                persistence: ReviewMealReconciliationPersistence()
            )
        )
        await viewModel.load()
        viewModel.name = "Review Meal"
        viewModel.selectProduct(
            rowID: 1,
            product: MealProduct(id: "oats", name: "Oats")
        )
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        await viewModel.save()

        XCTAssertTrue(
            service.createRequests.isEmpty,
            "a create without a trustworthy baseline cannot be reconciled safely"
        )
    }

    /// The first meal save is still fetching its pre-create baseline before the
    /// durable attempt exists. A second save (double tap or another window) must
    /// not pass the same check and send a second non-idempotent create.
    func testConcurrentMealSavesShareOneDurableCreateAttempt() async {
        let service = ReviewMealsService()
        service.listDelayNanoseconds = 1_000_000_000
        service.createResult = .success(
            Meal(id: "meal-1", name: "Review Meal")
        )
        let viewModel = MealEditorViewModel(
            mode: .create,
            accountID: accountID,
            service: service,
            reconciliationStore: MealCreateReconciliationStore(
                persistence: ReviewMealReconciliationPersistence()
            )
        )
        await viewModel.load()
        viewModel.name = "Review Meal"
        viewModel.selectProduct(
            rowID: 1,
            product: MealProduct(id: "oats", name: "Oats")
        )
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        let first = Task { await viewModel.save() }
        let deadline = Date().addingTimeInterval(2)
        while service.listCallCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(service.listCallCount, 1, "first save must reach the baseline fetch")
        let second = Task { await viewModel.save() }
        let overlapDeadline = Date().addingTimeInterval(2)
        while service.listCallCount < 2, Date() < overlapDeadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(
            service.listCallCount,
            2,
            "both saves must overlap before the first baseline returns"
        )
        _ = await (first.value, second.value)

        XCTAssertEqual(
            service.createRequests.count,
            1,
            "concurrent saves must share one durable intent and one POST"
        )
    }

    /// The catalog POST commits before the log journal can be reserved. If the
    /// process dies in that gap, the app needs the durable log intent to resume
    /// logging the saved food instead of asking the user to create it again.
    func testSaveAndLogKeepsResumeIntentAfterCatalogCommitBeforeJournalReserve() async throws {
        let store = CustomFoodReconciliationStore(
            persistence: MemoryReconciliationPersistence()
        )
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        let intent = logIntent()
        service.enqueueCreate(.success("saved-food"))

        let result = await engine.create(
            draft: draft(name: "Oats"),
            baselineFoodIDs: [],
            logIntent: intent
        )

        XCTAssertEqual(result, .saved(foodID: "saved-food"))
        let retained = try XCTUnwrap(
            try store.attempt(accountID: accountID),
            "the log intent must survive catalog success until a journal entry owns the retry"
        )
        XCTAssertEqual(retained.logIntent, intent)
    }
}

private final class ReviewMealsService: MealsServicing, @unchecked Sendable {
    var listResult: Result<[Meal], MealServiceError> = .success([])
    var createResult: Result<Meal, MealServiceError> = .failure(.server("unset"))
    var listDelayNanoseconds: UInt64 = 0
    private(set) var listCallCount = 0
    private(set) var createRequests: [MealWriteRequest] = []

    func listMeals() async throws -> [Meal] {
        listCallCount += 1
        if listDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: listDelayNanoseconds)
        }
        return try listResult.get()
    }

    func getMeal(id: String) async throws -> Meal {
        throw MealServiceError.notFound("missing")
    }

    func createMeal(_ request: MealWriteRequest) async throws -> Meal {
        createRequests.append(request)
        return try createResult.get()
    }

    func updateMeal(id: String, _ request: MealWriteRequest) async throws -> Meal {
        throw MealServiceError.server("unexpected update")
    }

    func deleteMeal(id: String) async throws {
        throw MealServiceError.server("unexpected delete")
    }

    func mealNutrients(
        mealID: String,
        amount: String,
        unit: String
    ) async throws -> MealNutritionResponse {
        throw MealServiceError.server("unexpected nutrition")
    }

    func fetchUnits() async throws -> [ProductUnit] {
        [ProductUnit(code: "g", name: "Gram", kind: "mass")]
    }

    func searchComponentProducts(query: String) async throws -> [MealProduct] {
        []
    }

    func fetchComponentProduct(id: String) async throws -> MealProduct {
        throw MealServiceError.notFound("missing")
    }
}

private final class ReviewMealReconciliationPersistence:
    MealCreateReconciliationPersisting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var data: [String: Data] = [:]

    func load(accountID: String) throws -> Data? {
        lock.withLock { data[accountID] }
    }

    func save(_ data: Data, accountID: String) throws {
        lock.withLock { self.data[accountID] = data }
    }

    func remove(accountID: String) throws {
        lock.withLock { data.removeValue(forKey: accountID) }
    }

    func quarantine(accountID: String, reason: String) {
        lock.withLock { data.removeValue(forKey: accountID) }
    }
}
