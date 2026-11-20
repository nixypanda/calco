import XCTest

@testable import CalCo

private final class HandoffReadyCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
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
final class HandoffContractRegressionTests: XCTestCase {
    private let accountID = "handoff-contract"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    private func fill(_ viewModel: AdHocLogViewModel) {
        viewModel.name = "Bowl"
        viewModel.amount = "1"
        viewModel.unit = "g"
        viewModel.mode = .saveAndLog
        viewModel.setNutrientAmount("250", code: "ENERGY_KCAL")
        viewModel.setNutrientAmount("10", code: "PROTEIN_G")
        viewModel.setNutrientAmount("40", code: "CARBS_G")
        viewModel.setNutrientAmount("5", code: "FAT_G")
    }

    private func makeCatalogStore(
        _ persistence: any CustomFoodReconciliationPersisting
    ) -> CustomFoodReconciliationStore {
        CustomFoodReconciliationStore(persistence: persistence)
    }

    private func makeAdHoc(
        library: FakeLibraryService,
        submission: any LibraryLogSubmitting,
        catalogStore: CustomFoodReconciliationStore
    ) -> AdHocLogViewModel {
        AdHocLogViewModel(
            service: library,
            submissionService: submission,
            reconciliationStore: catalogStore,
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
    }

    func testRealJournalSucceededEntryPreventsSecondSendAfterCatalogClearFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-handoff-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalStore = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = CountingLogSender(
            date: date,
            item: .product(ProductLogItemSnapshot(id: "saved-food", name: "Bowl"))
        )
        let journalService = LogSubmissionService(
            store: journalStore,
            sender: sender,
            capabilityProvider: HandoffReadyCapabilityProvider()
        )
        let catalogStore = makeCatalogStore(RemoveFailingCustomPersistence())
        let library = FakeLibraryService()
        library.enqueueCreate(.success("saved-food"))
        let submission = JournalLibraryLogSubmissionService(service: journalService)
        let viewModel = makeAdHoc(
            library: library,
            submission: submission,
            catalogStore: catalogStore
        )
        await viewModel.load()
        fill(viewModel)
        viewModel.requestReview()
        await viewModel.confirmReview()

        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(
            viewModel.savedFoodLogState,
            SavedFoodLogState.logged(logID: "log-1", replayed: false)
        )
        let retained = try XCTUnwrap(
            try catalogStore.attempt(accountID: accountID)
        )
        XCTAssertEqual(retained.foodID, "saved-food")
        XCTAssertEqual(
            retained.journalOperationID,
            retained.journalRequest?.operationID
        )
        let journalEntry = try XCTUnwrap(
            journalStore.entry(
                accountID: accountID,
                idempotencyKey: retained.journalOperationID ?? ""
            )
        )
        XCTAssertEqual(journalEntry.state, .succeeded)

        let reopened = makeAdHoc(
            library: library,
            submission: submission,
            catalogStore: catalogStore
        )
        await reopened.load()
        XCTAssertEqual(reopened.savedFoodID, "saved-food")
        await reopened.retrySavedFoodLog()

        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(journalStore.entries(accountID: accountID).count, 1)
    }

    func testOtherUnresolvedOperationRetainsOwedCatalogIntent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-preflight-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalStore = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = CountingLogSender(
            date: date,
            item: .product(ProductLogItemSnapshot(id: "saved-food", name: "Bowl"))
        )
        let journalService = LogSubmissionService(
            store: journalStore,
            sender: sender,
            capabilityProvider: HandoffReadyCapabilityProvider()
        )
        let otherDraft = LogSubmissionDraft(
            item: .product(id: "saved-food"),
            date: date,
            mealSlot: .lunch,
            amount: "1",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [otherDraft],
            baseURL: nil,
            idempotencyKey: "other-window-key"
        )
        try journalStore.reserve(
            accountID: accountID,
            summary: "Other",
            drafts: [otherDraft],
            request: prepared.request
        )

        let catalogStore = makeCatalogStore(MemoryReconciliationPersistence())
        let library = FakeLibraryService()
        library.enqueueCreate(.success("saved-food"))
        let viewModel = makeAdHoc(
            library: library,
            submission: JournalLibraryLogSubmissionService(service: journalService),
            catalogStore: catalogStore
        )
        await viewModel.load()
        fill(viewModel)
        viewModel.requestReview()
        await viewModel.confirmReview()

        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(viewModel.savedFoodID, "saved-food")
        guard case .pending = viewModel.savedFoodLogState else {
            return XCTFail("the other unresolved operation must be surfaced")
        }
        let retained = try XCTUnwrap(
            try catalogStore.attempt(accountID: accountID)
        )
        XCTAssertNotEqual(retained.journalOperationID, "other-window-key")
        XCTAssertEqual(
            journalStore.unresolved(
                accountID: accountID,
                item: .product(id: "saved-food"),
                date: date
            ).count,
            1
        )
    }

    func testCorruptCustomFileStaysBlockedAcrossNewStoreUntilReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-corrupt-custom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileCustomFoodReconciliationPersistence(
            directoryURL: directory
        )
        try persistence.save(Data("corrupt".utf8), accountID: accountID)
        let first = CustomFoodReconciliationStore(persistence: persistence)
        XCTAssertThrowsError(try first.attempt(accountID: accountID))
        XCTAssertNotNil(try persistence.load(accountID: accountID))

        let relaunched = CustomFoodReconciliationStore(persistence: persistence)
        XCTAssertThrowsError(try relaunched.attempt(accountID: accountID))
        XCTAssertNotNil(try persistence.load(accountID: accountID))

        try relaunched.reset(accountID: accountID)
        XCTAssertNil(try persistence.load(accountID: accountID))
        XCTAssertNil(try relaunched.attempt(accountID: accountID))
    }

    func testCorruptMealFileStaysBlockedAcrossNewStoreUntilReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-corrupt-meal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileMealCreateReconciliationPersistence(
            directoryURL: directory
        )
        try persistence.save(Data("corrupt".utf8), accountID: accountID)
        let first = MealCreateReconciliationStore(persistence: persistence)
        XCTAssertThrowsError(try first.attempt(accountID: accountID))
        XCTAssertNotNil(try persistence.load(accountID: accountID))

        let relaunched = MealCreateReconciliationStore(persistence: persistence)
        XCTAssertThrowsError(try relaunched.attempt(accountID: accountID))
        XCTAssertNotNil(try persistence.load(accountID: accountID))

        try relaunched.reset(accountID: accountID)
        XCTAssertNil(try persistence.load(accountID: accountID))
    }

    func testCustomNoLogClearFailureRetainsIntentWithoutSecondPOST() async {
        let persistence = RemoveFailingCustomPersistence()
        let store = makeCatalogStore(persistence)
        let library = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: library,
            store: store,
            accountID: accountID
        )
        library.enqueueCreate(.success("created-food"))

        let result = await engine.create(
            draft: foodDraft(),
            baselineFoodIDs: []
        )

        guard case .needsReconciliation(let attempt) = result else {
            return XCTFail("clear failure must surface recovery")
        }
        XCTAssertEqual(attempt.foodID, "created-food")
        XCTAssertEqual(library.createCallCount, 1)
        let second = await engine.create(
            draft: foodDraft("Second"),
            baselineFoodIDs: []
        )
        guard case .needsReconciliation = second else {
            return XCTFail("durable intent must block another create")
        }
        XCTAssertEqual(library.createCallCount, 1)
    }

    func testCustomDefinitiveFailureClearFailureRetainsWarning() async {
        let store = makeCatalogStore(RemoveFailingCustomPersistence())
        let library = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: library,
            store: store,
            accountID: accountID
        )
        library.enqueueCreate(.failure(.failed("invalid")))

        let result = await engine.create(
            draft: foodDraft(),
            baselineFoodIDs: []
        )

        guard case .needsReconciliation = result else {
            return XCTFail("clear failure must not report a clean rejection")
        }
        XCTAssertNotNil(try? store.attempt(accountID: accountID))
    }

    func testMealSuccessClearFailureRetainsReconciliationWithoutRepost() async {
        let persistence = RemoveFailingMealPersistence()
        let store = MealCreateReconciliationStore(persistence: persistence)
        let service = ConfigurableMealsService()
        service.createResult = .success(Meal(id: "meal-1", name: "Meal"))
        let viewModel = MealEditorViewModel(
            mode: .create,
            accountID: accountID,
            service: service,
            reconciliationStore: store
        )
        await viewModel.load()
        viewModel.name = "Meal"
        viewModel.selectProduct(
            rowID: 1,
            product: MealProduct(id: "oats", name: "Oats")
        )
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        await viewModel.save()

        XCTAssertEqual(service.createRequests.count, 1)
        XCTAssertNotNil(viewModel.reconciliationAttempt)
        XCTAssertNotNil(try? store.attempt(accountID: accountID))
        await viewModel.save()
        XCTAssertEqual(service.createRequests.count, 1)
    }

    func testMealDefinitiveFailureClearFailureRetainsWarning() async {
        let store = MealCreateReconciliationStore(
            persistence: RemoveFailingMealPersistence()
        )
        let service = ConfigurableMealsService()
        service.createResult = .failure(.validation("bad meal"))
        let viewModel = MealEditorViewModel(
            mode: .create,
            accountID: accountID,
            service: service,
            reconciliationStore: store
        )
        await viewModel.load()
        viewModel.name = "Meal"
        viewModel.selectProduct(
            rowID: 1,
            product: MealProduct(id: "oats", name: "Oats")
        )
        viewModel.componentAmountChanged(rowID: 1, amount: "50")

        await viewModel.save()

        XCTAssertEqual(service.createRequests.count, 1)
        XCTAssertNotNil(viewModel.reconciliationAttempt)
        XCTAssertNotNil(try? store.attempt(accountID: accountID))
    }

    func testUnsupportedCapabilityRetainsCatalogIntentWithoutJournalEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-unsupported-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalStore = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = CountingLogSender(
            date: date,
            item: .product(ProductLogItemSnapshot(id: "saved-food", name: "Bowl"))
        )
        let journalService = LogSubmissionService(
            store: journalStore,
            sender: sender,
            capabilityProvider: HandoffUnsupportedCapabilityProvider()
        )
        let catalogStore = makeCatalogStore(MemoryReconciliationPersistence())
        let library = FakeLibraryService()
        library.enqueueCreate(.success("saved-food"))
        let viewModel = makeAdHoc(
            library: library,
            submission: JournalLibraryLogSubmissionService(service: journalService),
            catalogStore: catalogStore
        )
        await viewModel.load()
        fill(viewModel)
        viewModel.requestReview()
        await viewModel.confirmReview()

        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertTrue(journalStore.entries(accountID: accountID).isEmpty)
        let retained = try XCTUnwrap(
            try catalogStore.attempt(accountID: accountID)
        )
        XCTAssertEqual(retained.foodID, "saved-food")
        XCTAssertNotNil(retained.journalRequest)
        guard case .retryable = viewModel.savedFoodLogState else {
            return XCTFail("capability failure must remain retryable")
        }
    }

    func testTransientCapabilityFailureRetainsExactJournalRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-transient-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalStore = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = CountingLogSender(
            date: date,
            item: .product(ProductLogItemSnapshot(id: "saved-food", name: "Bowl"))
        )
        let journalService = LogSubmissionService(
            store: journalStore,
            sender: sender,
            capabilityProvider: HandoffTransientCapabilityProvider()
        )
        let catalogStore = makeCatalogStore(MemoryReconciliationPersistence())
        let library = FakeLibraryService()
        library.enqueueCreate(.success("saved-food"))
        let viewModel = makeAdHoc(
            library: library,
            submission: JournalLibraryLogSubmissionService(service: journalService),
            catalogStore: catalogStore
        )
        await viewModel.load()
        fill(viewModel)
        viewModel.requestReview()
        await viewModel.confirmReview()

        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertTrue(journalStore.entries(accountID: accountID).isEmpty)
        let retained = try XCTUnwrap(
            try catalogStore.attempt(accountID: accountID)
        )
        let request = try XCTUnwrap(retained.journalRequest)
        XCTAssertEqual(request.operationID, retained.journalOperationID)
        XCTAssertFalse(request.body.isEmpty)
        guard case .retryable = viewModel.savedFoodLogState else {
            return XCTFail("transient capability failure must remain retryable")
        }
    }

    func testPersistedReplayRejectsPathOnlyChange() async throws {
        let (adapter, store, sender, entry, original) = try await replayFixture(state: .succeeded)
        let changed = LogSubmissionRequest(
            requestPath: "/api/logs/batch",
            idempotencyKey: original.idempotencyKey,
            body: original.body,
            baseURLString: original.baseURLString
        )
        let outcome = await adapter.submitPersisted(
            replayRequest(entry: entry, request: changed)
        )
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertFalse(outcome.journalOwned)
        guard case .failure(.conflict) = outcome.result else {
            return XCTFail("path change must conflict")
        }
        XCTAssertEqual(
            try store.entry(id: entry.id, accountID: accountID)?.state,
            .succeeded
        )
    }

    func testPersistedReplayRejectsDraftOnlyChange() async throws {
        let (adapter, store, sender, entry, original) = try await replayFixture(state: .succeeded)
        var changedDraft = entry.draft
        changedDraft = LogSubmissionDraft(
            item: changedDraft.item,
            date: changedDraft.date,
            mealSlot: changedDraft.mealSlot,
            amount: "101",
            unit: changedDraft.unit,
            notes: changedDraft.notes,
            timeZone: changedDraft.timeZone,
            nutrients: changedDraft.nutrients
        )
        let outcome = await adapter.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: original.idempotencyKey,
                draft: changedDraft,
                itemName: entry.foodName,
                summary: entry.foodName,
                request: original
            )
        )
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertFalse(outcome.journalOwned)
        guard case .failure(.conflict) = outcome.result else {
            return XCTFail("draft change must conflict")
        }
    }

    func testPersistedReplayRejectsExactBodyFormatChange() async throws {
        let (adapter, store, sender, entry, original) = try await replayFixture(state: .succeeded)
        let changed = LogSubmissionRequest(
            requestPath: original.requestPath,
            idempotencyKey: original.idempotencyKey,
            body: original.body + Data(" ".utf8),
            baseURLString: original.baseURLString
        )
        let outcome = await adapter.submitPersisted(
            replayRequest(entry: entry, request: changed)
        )
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertFalse(outcome.journalOwned)
        guard case .failure(.conflict) = outcome.result else {
            return XCTFail("byte change must conflict")
        }
    }

    func testPersistedReplayRejectsChangedPayloadInRejectedState() async throws {
        let (adapter, store, sender, entry, original) = try await replayFixture(state: .rejected)
        let changed = LogSubmissionRequest(
            requestPath: original.requestPath,
            idempotencyKey: original.idempotencyKey,
            body: original.body + Data(" ".utf8),
            baseURLString: original.baseURLString
        )
        let outcome = await adapter.submitPersisted(
            replayRequest(entry: entry, request: changed)
        )
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertFalse(outcome.journalOwned)
        guard case .failure(.conflict) = outcome.result else {
            return XCTFail("rejected changed payload must conflict")
        }
        XCTAssertEqual(
            try store.entry(id: entry.id, accountID: accountID)?.state,
            .rejected
        )
    }

    private func replayFixture(
        state: LogSubmissionState
    ) async throws -> (
        JournalLibraryLogSubmissionService,
        LogSubmissionStore,
        CountingLogSender,
        PendingLogSubmission,
        LogSubmissionRequest
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-replay-identity-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = CountingLogSender(
            date: date,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats"))
        )
        let provider = HandoffReadyCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let original = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "replay-identity-key"
        )
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            request: original.request,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )
        switch state {
        case .succeeded:
            try store.markSucceeded(
                id: entry.id,
                accountID: accountID,
                logID: "log-1",
                date: date,
                mealSlot: .lunch,
                replayed: false
            )
        case .rejected:
            try store.markRejected(
                id: entry.id,
                accountID: accountID,
                status: 400,
                message: "rejected"
            )
        default:
            break
        }
        let adapter = JournalLibraryLogSubmissionService(service: service)
        return (adapter, store, sender, entry, original.request)
    }

    private func replayRequest(
        entry: PendingLogSubmission,
        request: LogSubmissionRequest
    ) -> LibraryPersistedLogRequest {
        LibraryPersistedLogRequest(
            accountID: accountID,
            operationID: request.idempotencyKey,
            draft: entry.draft,
            itemName: entry.foodName,
            summary: entry.foodName,
            request: request
        )
    }

    private func foodDraft(_ name: String = "Food") -> CustomFoodWriteRequest {
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
}

private final class CountingLogSender: LogSubmissionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sends = 0
    private let date: LocalDiaryDate
    private let item: FoodLogItem

    init(date: LocalDiaryDate, item: FoodLogItem) {
        self.date = date
        self.item = item
    }

    var sendCount: Int { lock.withLock { sends } }

    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        lock.withLock { sends += 1 }
        return LogSubmissionSendResult(
            logs: [
                FoodLog(
                    id: "log-1",
                    logDate: date,
                    mealSlot: .lunch,
                    item: item,
                    quantity: NutritionQuantity(amount: "1", unit: "g"),
                    nutrients: []
                ),
            ],
            statusCode: 201
        )
    }
}

private final class RemoveFailingCustomPersistence:
    CustomFoodReconciliationPersisting,
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
        throw CocoaError(.fileWriteUnknown)
    }

    func quarantine(accountID: String, reason: String) {
        lock.withLock { data.removeValue(forKey: accountID) }
    }
}

private final class RemoveFailingMealPersistence:
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
        throw CocoaError(.fileWriteUnknown)
    }

    func quarantine(accountID: String, reason: String) {
        lock.withLock { data.removeValue(forKey: accountID) }
    }
}

private final class ConfigurableMealsService: MealsServicing, @unchecked Sendable {
    var createResult: Result<Meal, MealServiceError> =
        .failure(.server("unset"))
    private(set) var createRequests: [MealWriteRequest] = []

    func listMeals() async throws -> [Meal] { [] }

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

    func searchComponentProducts(query: String) async throws -> [MealProduct] {
        []
    }

    func fetchComponentProduct(id: String) async throws -> MealProduct {
        throw MealServiceError.notFound("missing")
    }
}


private final class HandoffUnsupportedCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
    let baseURL = URL(string: "https://calco.example.com")!

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        LogCreationIdempotencyCapability(
            version: 0,
            single: false,
            adHoc: false,
            batch: false,
            batchKeyLocation: nil,
            deletedOperationReplay: "unavailable",
            preMigrationDeletedKeys: "reconciliation_only"
        )
    }
}

private final class HandoffTransientCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
    let baseURL = URL(string: "https://calco.example.com")!

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        throw CalCoAPIError.badStatus(
            statusCode: 503,
            payload: APIErrorPayload(code: "unavailable", message: "unavailable")
        )
    }
}
