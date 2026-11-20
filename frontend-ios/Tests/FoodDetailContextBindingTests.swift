import XCTest

@testable import CalCo

@MainActor
final class FoodDetailContextBindingTests: XCTestCase {
    private let accountID = "context-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let baseURL = URL(string: "https://calco.example.com")!

    private actor AsyncGate {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?

        func hold() async {
            started = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilStarted() async {
            while !started {
                await Task.yield()
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor ContextFoodDetailService: FoodDetailServicing {
        let gate: AsyncGate
        let lastUsedGate = AsyncGate()
        private var shouldHoldLastUsed = false
        private(set) var createCalls = 0
        private(set) var lastUsedCalls = 0

        init(gate: AsyncGate = AsyncGate()) {
            self.gate = gate
        }

        func holdLastUsed() {
            shouldHoldLastUsed = true
        }

        func lastUsed(
            for item: LogSubmissionItem,
            date: LocalDiaryDate,
            mealSlot: MealSlot?
        ) async throws -> RecentLogItem? {
            lastUsedCalls += 1
            if shouldHoldLastUsed {
                await lastUsedGate.hold()
            }
            return RecentLogItem(
                item: .product(ProductLogItemSnapshot(id: "food-1", name: "Context Food")),
                lastUsedDate: date,
                mealSlot: mealSlot,
                quantity: NutritionQuantity(amount: "250", unit: "g")
            )
        }

        func fetchFoodDetail(id: String) async throws -> FoodDetail {
            FoodDetail(
                id: id,
                name: "Context Food",
                defaultQuantity: "100",
                defaultUnit: "g",
                allowedUnits: [FoodUnit(code: "g", name: "Gram")]
            )
        }

        func fetchUnits() async throws -> [FoodUnit] {
            [FoodUnit(code: "g", name: "Gram")]
        }

        func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
            createCalls += 1
            await gate.hold()
            return CreatedFoodLog(
                id: "created-log",
                date: request.date,
                mealSlot: request.mealSlot
            )
        }
    }

    private func makeStore() -> (LogSubmissionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-fooddetail-context-\(UUID().uuidString)")
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (store, directory)
    }

    private func makeViewModel(
        service: ContextFoodDetailService,
        store: LogSubmissionStore,
        context: @escaping () -> LogSubmissionSessionContext?,
        capabilityGate: AsyncGate? = nil,
        onSessionExpired: @escaping () -> Void = {},
        onSuccess: @escaping () -> Void = {}
    ) -> FoodDetailViewModel {
        FoodDetailViewModel(
            foodID: "food-1",
            originDate: date,
            originMealSlot: .lunch,
            service: service,
            onSuccess: { _, _ in onSuccess() },
            onSessionExpired: onSessionExpired,
            accountID: accountID,
            baseURL: baseURL,
            submissionStore: store,
            submissionContextProvider: context,
            singleCapabilityEnsure: {
                if let capabilityGate {
                    await capabilityGate.hold()
                }
                return true
            }
        )
    }

    private func context(
        account: String? = nil,
        generation: UInt64 = 1,
        base: URL? = nil
    ) -> LogSubmissionSessionContext {
        LogSubmissionSessionContext(
            accountID: account ?? accountID,
            generation: generation,
            baseURL: base ?? baseURL
        )
    }

    func testAccountSwitchWhileCapabilityHeldDoesNotPOST() async {
        let service = ContextFoodDetailService()
        let capabilityGate = AsyncGate()
        let (store, _) = makeStore()
        var current = context()
        let viewModel = makeViewModel(
            service: service,
            store: store,
            context: { current },
            capabilityGate: capabilityGate
        )
        await viewModel.load()
        let submit = Task { await viewModel.submit() }
        await capabilityGate.waitUntilStarted()
        current = context(account: "other-account", generation: 2)
        await capabilityGate.release()
        await submit.value

        let calls = await service.createCalls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
        XCTAssertEqual(viewModel.submitState, .failed(
            String(localized: "foodDetail.error.sessionExpired")
        ))
    }

    func testContextSwitchAfterDetailLoadBeforeLogDoesNotPOST() async {
        let service = ContextFoodDetailService()
        let (store, _) = makeStore()
        var current = context()
        let viewModel = makeViewModel(
            service: service,
            store: store,
            context: { current }
        )
        await viewModel.load()
        current = context(generation: 2)
        await viewModel.submit()

        let calls = await service.createCalls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
    }

    func testHeldDirectPOSTContextSwitchMarksJournalUncertain() async {
        let service = ContextFoodDetailService()
        let (store, _) = makeStore()
        var current = context()
        var sessionExpiredCount = 0
        var successCount = 0
        let viewModel = makeViewModel(
            service: service,
            store: store,
            context: { current },
            onSessionExpired: { sessionExpiredCount += 1 },
            onSuccess: { successCount += 1 }
        )
        await viewModel.load()
        let submit = Task { await viewModel.submit() }
        await service.gate.waitUntilStarted()
        current = context(generation: 2)
        await service.gate.release()
        await submit.value

        let calls = await service.createCalls
        XCTAssertEqual(calls, 1)
        guard case .uncertain = viewModel.submitState else {
            return XCTFail("stale POST must not publish clean success")
        }
        XCTAssertNil(viewModel.lastSubmissionSuccess)
        XCTAssertEqual(successCount, 0)
        XCTAssertEqual(sessionExpiredCount, 1)
        let entry = try! XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertEqual(entry.state, .uncertain)
        XCTAssertNotNil(entry.body)
        XCTAssertFalse(store.isLiveSubmission(id: entry.id))
    }

    func testLastUsedSwitchBeforeReleaseDoesNotApplyForeignQuantity() async {
        let service = ContextFoodDetailService()
        let (store, _) = makeStore()
        var current = context()
        var sessionExpiredCount = 0
        let viewModel = makeViewModel(
            service: service,
            store: store,
            context: { current },
            onSessionExpired: { sessionExpiredCount += 1 }
        )
        await service.holdLastUsed()
        await viewModel.load()
        await service.lastUsedGate.waitUntilStarted()
        current = context(generation: 2)
        await service.lastUsedGate.release()

        let deadline = Date().addingTimeInterval(2)
        while sessionExpiredCount == 0, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(sessionExpiredCount, 1)
        XCTAssertEqual(viewModel.amount, "100")
        XCTAssertEqual(viewModel.unit, "g")
    }

    func testStaleOldCapabilityCannotGrantAfterAccountSwitch() async {
        let service = ContextFoodDetailService()
        let capabilityGate = AsyncGate()
        let (store, _) = makeStore()
        var current = context()
        let viewModel = makeViewModel(
            service: service,
            store: store,
            context: { current },
            capabilityGate: capabilityGate
        )
        await viewModel.load()
        let submit = Task { await viewModel.submit() }
        await capabilityGate.waitUntilStarted()
        current = context(account: "foreign", generation: 1)
        await capabilityGate.release()
        await submit.value

        let calls = await service.createCalls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
    }

    func testSameGenerationForeignAccountOrServerIsInvalid() async {
        let service = ContextFoodDetailService()
        let (store, _) = makeStore()
        var current = context(account: "foreign")
        let viewModel = makeViewModel(
            service: service,
            store: store,
            context: { current }
        )
        await viewModel.load()
        await viewModel.submit()
        var calls = await service.createCalls
        XCTAssertEqual(calls, 0)

        current = context(base: URL(string: "https://other.example.com")!)
        await viewModel.submit()
        calls = await service.createCalls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
    }
}
