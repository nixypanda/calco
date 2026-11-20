import XCTest

@testable import CalCo

private final class SafetyReadyCapabilityProvider: LogCreationCapabilityProviding, @unchecked Sendable {
    let baseURL = URL(string: "https://calco.example.com")!

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        LogCreationIdempotencyCapability(
            version: 2,
            single: true,
            adHoc: true,
            batch: true,
            batchKeyLocation: "top_level",
            deletedOperationReplay: "conflict",
            preMigrationDeletedKeys: "reconciliation_only"
        )
    }
}

@MainActor
final class SafetyRepairRegressionTests: XCTestCase {
    private let accountID = "safety-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    private func draft(_ name: String = "Oats") -> CustomFoodWriteRequest {
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

    private func intent() -> CustomFoodLogIntent {
        CustomFoodLogIntent(
            date: date,
            mealSlot: .lunch,
            amount: "1",
            unit: "plate",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
    }

    func testCatalogSuccessPersistsFoodIDAndBlocksAnotherCreateUntilHandoff() async throws {
        let store = CustomFoodReconciliationStore(
            persistence: MemoryReconciliationPersistence()
        )
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        service.enqueueCreate(.success("saved-food"))

        let result = await engine.create(
            draft: draft(),
            baselineFoodIDs: [],
            logIntent: intent()
        )

        XCTAssertEqual(result, .saved(foodID: "saved-food"))
        let retained = try XCTUnwrap(try store.attempt(accountID: accountID))
        XCTAssertEqual(retained.foodID, "saved-food")
        XCTAssertEqual(retained.logIntent, intent())

        // A new engine simulates relaunch. It must not POST the catalog create
        // again while the owed log is still unresolved.
        let relaunched = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        let blocked = await relaunched.create(
            draft: draft("Duplicate"),
            baselineFoodIDs: []
        )
        XCTAssertEqual(blocked, .needsReconciliation(retained))
        XCTAssertEqual(service.createCallCount, 1)

        try relaunched.completeLogHandoff(attemptID: retained.id)
        XCTAssertNil(try store.attempt(accountID: accountID))
    }

    func testStaleLogHandoffCannotClearNewerAttempt() async throws {
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
            draft: draft("A"),
            baselineFoodIDs: []
        ) else { return XCTFail("expected attempt A") }
        try windowB.discard(attempt: attemptA)

        service.enqueueCreate(.failure(.uncertain("lost B")))
        guard case .needsReconciliation(let attemptB) = await windowB.create(
            draft: draft("B"),
            baselineFoodIDs: []
        ) else { return XCTFail("expected attempt B") }

        XCTAssertThrowsError(
            try windowA.completeLogHandoff(attemptID: attemptA.id)
        )
        XCTAssertEqual(try store.attempt(accountID: accountID)?.id, attemptB.id)
    }

    func testResumedSavedFoodLogsProductWithoutCreatingCatalogFoodAgain() async throws {
        let store = CustomFoodReconciliationStore(
            persistence: MemoryReconciliationPersistence()
        )
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        service.enqueueCreate(.success("saved-food"))
        _ = await engine.create(
            draft: draft(),
            baselineFoodIDs: [],
            logIntent: intent()
        )
        XCTAssertEqual(service.createCallCount, 1)

        let submission = FakeLibraryLogSubmissionService(
            results: [.success(logs: [], replayed: false)]
        )
        let viewModel = AdHocLogViewModel(
            service: service,
            submissionService: submission,
            reconciliationStore: store,
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await viewModel.load()

        XCTAssertEqual(viewModel.savedFoodID, "saved-food")
        XCTAssertEqual(viewModel.savedLogIntent, intent())
        XCTAssertNil(viewModel.reconciliationAttempt)
        XCTAssertFalse(viewModel.canReview)

        await viewModel.retrySavedFoodLog()

        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertEqual(submission.submissions.count, 1)
        XCTAssertEqual(
            submission.submissions[0].drafts[0].item,
            .product(id: "saved-food")
        )
        XCTAssertNil(try store.attempt(accountID: accountID))
    }

    func testMealEditorStaleDiscardCannotClearNewerAttempt() async {
        let persistence = MemoryMealReconciliationPersistence()
        let store = MealCreateReconciliationStore(persistence: persistence)
        let request = MealWriteRequest(
            name: "Porridge",
            components: [
                MealComponentWriteRequest(
                    productID: "oats",
                    quantity: NutritionQuantity(amount: "50", unit: "g")
                )
            ]
        )
        let attemptA = MealCreateAttempt(
            accountID: accountID,
            request: request,
            baselineMealIDs: []
        )
        try? store.save(attemptA)
        let viewModel = MealEditorViewModel(
            mode: .create,
            accountID: accountID,
            service: SafetyMealsService(),
            reconciliationStore: store
        )
        await viewModel.load()
        XCTAssertEqual(viewModel.reconciliationAttempt?.id, attemptA.id)

        // Another window replaces A with B.
        try? store.clear(accountID: accountID)
        let attemptB = MealCreateAttempt(
            accountID: accountID,
            request: request,
            baselineMealIDs: []
        )
        try? store.save(attemptB)

        viewModel.discardReconciliation()

        XCTAssertEqual(try? store.attempt(accountID: accountID)?.id, attemptB.id)
        XCTAssertNotNil(viewModel.reconciliationMessage)
    }

    func testMealMatchingIsUnorderedAndNormalizesDecimalScale() {
        let request = MealWriteRequest(
            name: "Bowl",
            totalQuantity: NutritionQuantity(amount: "300", unit: "g"),
            components: [
                MealComponentWriteRequest(
                    productID: "oats",
                    quantity: NutritionQuantity(amount: "50.0", unit: "g")
                ),
                MealComponentWriteRequest(
                    productID: "banana",
                    quantity: NutritionQuantity(amount: "100", unit: "g")
                ),
            ]
        )
        let reordered = Meal(
            id: "meal-1",
            name: "Bowl",
            totalQuantity: NutritionQuantity(amount: "300.00", unit: "g"),
            components: [
                MealComponent(
                    id: "c2",
                    item: ItemReference(itemType: .product, id: "banana"),
                    quantity: NutritionQuantity(amount: "100.000", unit: "g")
                ),
                MealComponent(
                    id: "c1",
                    item: ItemReference(itemType: .product, id: "oats"),
                    quantity: NutritionQuantity(amount: "50", unit: "g")
                ),
            ]
        )
        XCTAssertTrue(MealCreateAttempt.matches(meal: reordered, request: request))

        let duplicateRequest = MealWriteRequest(
            name: "Bowl",
            components: [
                MealComponentWriteRequest(
                    productID: "oats",
                    quantity: NutritionQuantity(amount: "50", unit: "g")
                ),
                MealComponentWriteRequest(
                    productID: "oats",
                    quantity: NutritionQuantity(amount: "50", unit: "g")
                ),
            ]
        )
        let single = Meal(
            id: "meal-2",
            name: "Bowl",
            components: [
                MealComponent(
                    id: "c1",
                    item: ItemReference(itemType: .product, id: "oats"),
                    quantity: NutritionQuantity(amount: "50", unit: "g")
                ),
            ]
        )
        XCTAssertFalse(MealCreateAttempt.matches(meal: single, request: duplicateRequest))
    }

    func testAssistantAmountAndUnitChangesPreservePer100gTruth() async throws {
        let service = FakeLibraryService()
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: FakeLibraryLogSubmissionService(
                results: [.success(logs: [], replayed: false)]
            ),
            reconciliationStore: CustomFoodReconciliationStore(
                persistence: MemoryReconciliationPersistence()
            ),
            accountID: accountID,
            initialDate: date,
            today: date,
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
            servings: [.init(unit: "plate", gramsPerUnit: "350")]
        )
        let reviewed = try AssistantReviewedDraft(
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
        XCTAssertTrue(adHoc.applyAssistantDraft(reviewed))
        adHoc.mode = .saveAndLog

        adHoc.unit = "g"
        XCTAssertEqual(adHoc.amount, "350")
        XCTAssertEqual(adHoc.portionWeightText, "350")

        adHoc.amount = "700"
        XCTAssertEqual(adHoc.portionWeightText, "700")
        XCTAssertEqual(adHoc.nutrientEditor.amount(for: "ENERGY_KCAL"), "700")

        adHoc.unit = "plate"
        XCTAssertEqual(adHoc.amount, "2")
        XCTAssertEqual(adHoc.portionWeightText, "700")

        adHoc.requestReview()
        service.enqueueCreate(.success("new-food"))
        await adHoc.confirmReview()

        let created = try XCTUnwrap(service.createdRequests.first)
        let energy = try XCTUnwrap(created.nutrients.first { $0.code == "ENERGY_KCAL" })
        XCTAssertEqual(energy.amountPer100g, Decimal(100))
    }

    func testJournalPendingLookupUsesTypedItemAndDate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-safety-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let service = LogSubmissionService(
            store: store,
            sender: NeverCalledLogSender(),
            capabilityProvider: SafetyReadyCapabilityProvider()
        )
        _ = await service.refreshCapability(accountID: accountID)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: nil,
            idempotencyKey: "safety-key"
        )
        try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            request: prepared.request
        )

        let adapter = JournalLibraryLogSubmissionService(service: service)
        XCTAssertNotNil(
            adapter.pendingSubmission(
                accountID: accountID,
                item: .product(id: "food-1"),
                date: date
            )
        )
        XCTAssertNil(
            adapter.pendingSubmission(
                accountID: accountID,
                item: .product(id: "food-1"),
                date: LocalDiaryDate(year: 2026, month: 11, day: 18)
            )
        )
        XCTAssertNil(
            adapter.pendingSubmission(
                accountID: "other-account",
                item: .product(id: "food-1"),
                date: date
            )
        )
    }
}

private final class NeverCalledLogSender: LogSubmissionSending, @unchecked Sendable {
    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        XCTFail("the journal duplicate check must avoid a second send")
        throw LogSubmissionSendError.failed("unexpected send")
    }
}

private final class MemoryMealReconciliationPersistence:
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

private final class SafetyMealsService: MealsServicing, @unchecked Sendable {
    func listMeals() async throws -> [Meal] { [] }
    func getMeal(id: String) async throws -> Meal {
        throw MealServiceError.notFound("missing")
    }
    func createMeal(_ request: MealWriteRequest) async throws -> Meal {
        throw MealServiceError.server("unexpected create")
    }
    func updateMeal(id: String, _ request: MealWriteRequest) async throws -> Meal {
        throw MealServiceError.server("unexpected update")
    }
    func deleteMeal(id: String) async throws {}
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
    func searchComponentProducts(query: String) async throws -> [MealProduct] { [] }
    func fetchComponentProduct(id: String) async throws -> MealProduct {
        throw MealServiceError.notFound("missing")
    }
}
