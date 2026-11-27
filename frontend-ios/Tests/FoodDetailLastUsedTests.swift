import ComposableArchitecture
import XCTest

@testable import CalCo

/// Deterministic gate for the metadata read; no sleeps or polling.
private actor LastUsedGate {
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didEnter = false
    private var released = false

    func markEntered() {
        didEnter = true
        let pending = enteredWaiters
        enteredWaiters = []
        for waiter in pending { waiter.resume() }
    }

    func entered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class LastUsedServiceFake: @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let item: LogSubmissionItem
        let date: LocalDiaryDate
        let mealSlot: MealSlot?
    }

    var result: Result<RecentLogItem?, Error> = .success(nil)
    var calls: [Call] = []
    var gate: LastUsedGate?

    func lastUsed(
        _ item: LogSubmissionItem,
        _ date: LocalDiaryDate,
        _ slot: MealSlot?
    ) async throws -> RecentLogItem? {
        calls.append(Call(item: item, date: date, mealSlot: slot))
        if let gate {
            await gate.markEntered()
            await gate.wait()
        }
        return try result.get()
    }
}

@MainActor
private final class EmptyJournal: @unchecked Sendable {
    func client() -> FoodDetailFeature.JournalClient {
        FoodDetailFeature.JournalClient(
            unresolved: { _, _, _ in [] },
            entry: { _, _ in nil },
            requireEntry: { _, _ in throw LogSubmissionStoreError.missingEntry },
            reserve: { _, _, _, _, _ in throw LogSubmissionStoreError.persistence("test fixture unavailable") },
            markInFlight: { _, _ in throw LogSubmissionStoreError.missingEntry },
            markUncertain: { _, _, _, _, _ in throw LogSubmissionStoreError.missingEntry },
            markSucceeded: { _, _, _, _, _, _ in throw LogSubmissionStoreError.missingEntry },
            markRejected: { _, _, _, _ in throw LogSubmissionStoreError.missingEntry },
            markConflicted: { _, _, _ in throw LogSubmissionStoreError.missingEntry },
            remove: { _, _ in },
            isRetryBlocked: { _ in false },
            isLiveSubmission: { _ in false },
            revisionUpdates: { AsyncStream { $0.finish() } }
        )
    }
}

@MainActor
final class FoodDetailLastUsedTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let generation: UInt64 = 42
    private let accountID = "account-a"
    private let presentationID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func unit(_ code: String) -> FoodUnit { FoodUnit(code: code, name: code) }

    private func recent(amount: String, unit: String) -> RecentLogItem {
        RecentLogItem(
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            lastUsedDate: date.addingDays(-1),
            mealSlot: .lunch,
            quantity: NutritionQuantity(amount: amount, unit: unit)
        )
    }

    private func makeService(allowedUnits: [FoodUnit]) -> LastUsedServiceFake {
        let service = LastUsedServiceFake()
        service.result = .success(nil)
        return service
    }

    private func makeStore(
        service: LastUsedServiceFake,
        allowedUnits: [FoodUnit],
        slot: MealSlot? = nil,
        requestID: UUID = UUID(),
        presentationID: UUID? = nil
    ) -> TestStore<FoodDetailFeature.State, FoodDetailFeature.Action> {
        let food = FoodDetail(
            id: "food-1", name: "Oats",
            defaultQuantity: "100", defaultUnit: "g",
            allowedUnits: allowedUnits
        )
        let capturedDate = date
        return TestStore(
            initialState: FoodDetailFeature.State(
                foodID: "food-1", date: date, slot: slot,
                generation: generation, accountID: accountID,
                presentationID: presentationID ?? self.presentationID
            )
        ) {
            FoodDetailFeature()
        } withDependencies: {
            $0.foodDetailClient = FoodDetailFeature.Client(
                fetchFood: { _, _ in food },
                fetchUnits: { _ in allowedUnits },
                lastUsed: { _, item, day, slot in
                    try await service.lastUsed(item, day, slot)
                },
                createLog: { _, _ in CreatedFoodLog(id: "log-1", date: capturedDate) }
            )
            $0.foodDetailJournalClient = EmptyJournal().client()
            $0.uuid = .constant(requestID)
        }
    }

    private var expectedContext: FeatureRequestContext {
        FeatureRequestContext(
            accountID: accountID, generation: generation, presentationID: presentationID
        )
    }

    /// Explicit load-start state diff; no post-action store introspection.
    private func sendLoad(
        _ store: TestStore<FoodDetailFeature.State, FoodDetailFeature.Action>,
        requestID: UUID
    ) async {
        await store.send(FoodDetailFeature.Action.load) {
            $0.load = .loading
            $0.loadedFood = nil
            $0.lastUsedNotice = nil
            $0.quantityWasEdited = false
            $0.formWasEdited = false
            $0.hasAttemptedSubmission = false
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.recovery = .idle
            $0.loadRequestID = requestID
        }
    }

    private func receiveLoad(
        _ store: TestStore<FoodDetailFeature.State, FoodDetailFeature.Action>,
        allowedUnits: [FoodUnit],
        requestID: UUID,
        slot: MealSlot? = nil
    ) async throws {
        let food = FoodDetail(
            id: "food-1", name: "Oats",
            defaultQuantity: "100", defaultUnit: "g",
            allowedUnits: allowedUnits
        )
        await store.receive(.loadCompleted(
            requestID: requestID,
            context: self.expectedContext,
            result: .success(FoodDetailFeature.LoadPayload(food: food, units: allowedUnits))
        )) {
            $0.units = allowedUnits
            let defaults = food.defaultLogQuantity
            $0.amount = defaults.amount
            $0.unit = defaults.unit
            if $0.mealSlot == nil { $0.mealSlot = slot }
            $0.loadedFood = food
            $0.load = .loaded
            $0.lastUsedRequestID = requestID
        }
    }

    private func receiveLastUsed(
        _ store: TestStore<FoodDetailFeature.State, FoodDetailFeature.Action>,
        result: Result<RecentLogItem?, FoodDetailLoadFailure>,
        requestID: UUID,
        mutation: ((inout FoodDetailFeature.State) -> Void)? = nil
    ) async {
        if let mutation {
            await store.receive(.lastUsedCompleted(
                requestID: requestID, context: self.expectedContext, result: result
            )) { mutation(&$0) }
        } else {
            await store.receive(.lastUsedCompleted(
                requestID: requestID, context: self.expectedContext, result: result
            ))
        }
    }

    func testLastUsedPrefillsAmountAndUnitAfterFoodLoads() async throws {
        let units = [unit("g"), unit("serving")]
        let service = makeService(allowedUnits: units)
        service.result = .success(recent(amount: "250", unit: "g"))
        let requestID = UUID()
        let store = makeStore(service: service, allowedUnits: units, slot: .lunch, requestID: requestID)

        await sendLoad(store, requestID: requestID)
        try await receiveLoad(store, allowedUnits: units, requestID: requestID, slot: .lunch)
        await receiveLastUsed(store, result: .success(recent(amount: "250", unit: "g")), requestID: requestID) {
            $0.amount = "250"
            $0.unit = "g"
        }

        XCTAssertEqual(store.state.load, .loaded)
        XCTAssertEqual(store.state.amount, "250")
        XCTAssertEqual(store.state.unit, "g")
        XCTAssertNil(store.state.lastUsedNotice)
        XCTAssertEqual(service.calls.map(\.item), [.product(id: "food-1")])
        XCTAssertEqual(service.calls.map(\.date), [date])
        XCTAssertEqual(service.calls.map(\.mealSlot), [.lunch])
    }

    func testUnavailableLastUsedUnitFallsBackToVisibleDefault() async throws {
        let units = [unit("g")]
        let service = makeService(allowedUnits: units)
        service.result = .success(recent(amount: "2", unit: "cup"))
        let requestID = UUID()
        let store = makeStore(service: service, allowedUnits: units, requestID: requestID)

        await sendLoad(store, requestID: requestID)
        try await receiveLoad(store, allowedUnits: units, requestID: requestID)
        await receiveLastUsed(store, result: .success(recent(amount: "2", unit: "cup")), requestID: requestID) {
            $0.lastUsedNotice = String(localized: "foodDetail.lastUsed.unavailableUnit")
        }

        XCTAssertEqual(store.state.amount, "100")
        XCTAssertEqual(store.state.unit, "g")
        XCTAssertEqual(
            store.state.lastUsedNotice,
            String(localized: "foodDetail.lastUsed.unavailableUnit")
        )
    }

    func testLastUsedFailureDoesNotBlockDetailOrChangeDefaults() async throws {
        let units = [unit("g"), unit("serving")]
        let service = makeService(allowedUnits: units)
        service.result = .failure(URLError(.notConnectedToInternet))
        let requestID = UUID()
        let store = makeStore(service: service, allowedUnits: units, requestID: requestID)

        await sendLoad(store, requestID: requestID)
        try await receiveLoad(store, allowedUnits: units, requestID: requestID)
        await receiveLastUsed(
            store, result: .failure(.message(service.result.failureDescription)), requestID: requestID
        )

        XCTAssertEqual(store.state.load, .loaded)
        XCTAssertEqual(store.state.amount, "100")
        XCTAssertEqual(store.state.unit, "g")
        XCTAssertNil(store.state.lastUsedNotice)
        XCTAssertEqual(service.calls.count, 1)
    }

    func testHeldLastUsedResponseDoesNotOverwriteUserEdit() async throws {
        let units = [unit("g"), unit("serving")]
        let gate = LastUsedGate()
        let service = makeService(allowedUnits: units)
        service.gate = gate
        service.result = .success(recent(amount: "250", unit: "g"))
        let requestID = UUID()
        let store = makeStore(service: service, allowedUnits: units, requestID: requestID)

        await sendLoad(store, requestID: requestID)
        try await receiveLoad(store, allowedUnits: units, requestID: requestID)
        await gate.entered()
        XCTAssertEqual(store.state.amount, "100")

        await store.send(.amountChanged("175")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "175"
        }
        await store.send(.unitChanged("serving")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.unit = "serving"
        }
        await gate.release()
        await receiveLastUsed(store, result: .success(recent(amount: "250", unit: "g")), requestID: requestID)

        XCTAssertEqual(store.state.amount, "175")
        XCTAssertEqual(store.state.unit, "serving")
        XCTAssertNil(store.state.lastUsedNotice)
    }

    func testLastUsedUnauthorizedExpiresTheSessionWithoutBlockingDetail() async throws {
        let units = [unit("g")]
        let service = makeService(allowedUnits: units)
        service.result = .failure(FoodDetailServiceError.unauthorized)
        let requestID = UUID()
        let store = makeStore(service: service, allowedUnits: units, requestID: requestID)

        await sendLoad(store, requestID: requestID)
        try await receiveLoad(store, allowedUnits: units, requestID: requestID)
        await receiveLastUsed(store, result: .failure(.unauthorized), requestID: requestID)
        await store.receive(.delegate(.sessionExpired(generation: generation)))

        XCTAssertEqual(store.state.load, .loaded)
        XCTAssertEqual(store.state.amount, "100")
    }

    func testHeldLastUsedDoesNotOverwriteSlotOrNotesEdits() async throws {
        let units = [unit("g")]
        let gate = LastUsedGate()
        let service = makeService(allowedUnits: units)
        service.gate = gate
        service.result = .success(recent(amount: "250", unit: "g"))
        let requestID = UUID()
        let store = makeStore(service: service, allowedUnits: units, requestID: requestID)

        await sendLoad(store, requestID: requestID)
        try await receiveLoad(store, allowedUnits: units, requestID: requestID)
        await gate.entered()
        await store.send(.mealSlotChanged(.dinner)) {
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.mealSlot = .dinner
        }
        await store.send(.notesChanged("extra sauce")) {
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.notes = "extra sauce"
        }
        await gate.release()
        await receiveLastUsed(store, result: .success(recent(amount: "250", unit: "g")), requestID: requestID)

        XCTAssertEqual(store.state.amount, "100")
        XCTAssertEqual(store.state.unit, "g")
        XCTAssertEqual(store.state.mealSlot, .dinner)
        XCTAssertEqual(store.state.notes, "extra sauce")
    }
}

private extension Result where Failure == Error {
    var failureDescription: String {
        switch self {
        case let .failure(error): return error.localizedDescription
        case .success: return ""
        }
    }
}
