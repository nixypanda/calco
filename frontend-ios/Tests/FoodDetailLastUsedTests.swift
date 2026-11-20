import XCTest

@testable import CalCo

private actor LastUsedFoodDetailService: FoodDetailServicing {
    struct LastUsedCall: Equatable, Sendable {
        let item: LogSubmissionItem
        let date: LocalDiaryDate
        let mealSlot: MealSlot?
    }

    private var food: FoodDetail
    private var units: [FoodUnit]
    private var lastUsedResult: Result<RecentLogItem?, Error> = .success(nil)
    private var lastUsedCalls: [LastUsedCall] = []
    private var holdsNextLastUsed = false
    private var lastUsedStarted = false
    private var lastUsedReleased = false
    private var lastUsedFinished = false
    private var lastUsedContinuation: CheckedContinuation<Void, Never>?

    init(food: FoodDetail, units: [FoodUnit]) {
        self.food = food
        self.units = units
    }

    func setLastUsed(_ result: Result<RecentLogItem?, Error>) {
        lastUsedResult = result
    }

    func holdNextLastUsed() {
        holdsNextLastUsed = true
        lastUsedStarted = false
        lastUsedReleased = false
        lastUsedFinished = false
    }

    func recordedLastUsedCalls() -> [LastUsedCall] {
        lastUsedCalls
    }

    func waitForLastUsedStart() async {
        let deadline = Date().addingTimeInterval(2)
        while !lastUsedStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(lastUsedStarted, "Timed out waiting for last-used request")
    }

    func waitForLastUsedFinish() async {
        let deadline = Date().addingTimeInterval(2)
        while !lastUsedFinished, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(lastUsedFinished, "Timed out waiting for last-used response")
    }

    func releaseLastUsed() {
        lastUsedReleased = true
        lastUsedContinuation?.resume()
        lastUsedContinuation = nil
    }

    func fetchFoodDetail(id: String) async throws -> FoodDetail {
        food
    }

    func fetchUnits() async throws -> [FoodUnit] {
        units
    }

    func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        CreatedFoodLog(id: "log-1", date: request.date, mealSlot: request.mealSlot)
    }

    func lastUsed(
        for item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> RecentLogItem? {
        lastUsedCalls.append(LastUsedCall(item: item, date: date, mealSlot: mealSlot))
        if holdsNextLastUsed {
            holdsNextLastUsed = false
            lastUsedStarted = true
            await withCheckedContinuation { continuation in
                if lastUsedReleased {
                    continuation.resume()
                } else {
                    lastUsedContinuation = continuation
                }
            }
        }
        lastUsedFinished = true
        return try lastUsedResult.get()
    }
}

@MainActor
final class FoodDetailLastUsedTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    func testLastUsedPrefillsAmountAndUnitAfterFoodLoads() async {
        let service = makeService(allowedUnits: [unit("g"), unit("serving")])
        await service.setLastUsed(.success(recent(amount: "250", unit: "g")))
        let viewModel = makeViewModel(service: service, mealSlot: .lunch)

        await viewModel.load()
        await waitUntil { viewModel.amount == "250" }

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.amount, "250")
        XCTAssertEqual(viewModel.unit, "g")
        XCTAssertNil(viewModel.lastUsedNotice)
        let calls = await service.recordedLastUsedCalls()
        XCTAssertEqual(calls, [
            .init(item: .product(id: "food-1"), date: date, mealSlot: .lunch)
        ])
    }

    func testUnavailableLastUsedUnitFallsBackToVisibleDefault() async {
        let service = makeService(allowedUnits: [unit("g")])
        await service.setLastUsed(.success(recent(amount: "2", unit: "cup")))
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await waitUntil { viewModel.lastUsedNotice != nil }

        XCTAssertEqual(viewModel.amount, "100")
        XCTAssertEqual(viewModel.unit, "g")
        XCTAssertEqual(
            viewModel.lastUsedNotice,
            String(localized: "foodDetail.lastUsed.unavailableUnit")
        )
    }

    func testLastUsedFailureDoesNotBlockDetailOrChangeDefaults() async {
        let service = makeService(allowedUnits: [unit("g"), unit("serving")])
        await service.setLastUsed(.failure(URLError(.notConnectedToInternet)))
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await waitUntil {
            let calls = await service.recordedLastUsedCalls()
            return !calls.isEmpty
        }

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.amount, "100")
        XCTAssertEqual(viewModel.unit, "g")
        XCTAssertNil(viewModel.lastUsedNotice)
    }

    func testHeldLastUsedResponseDoesNotOverwriteUserEdit() async {
        let service = makeService(allowedUnits: [unit("g"), unit("serving")])
        await service.setLastUsed(.success(recent(amount: "250", unit: "g")))
        await service.holdNextLastUsed()
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await service.waitForLastUsedStart()
        XCTAssertEqual(viewModel.amount, "100")

        viewModel.amountChanged("175")
        viewModel.unitChanged("serving")
        await service.releaseLastUsed()
        await service.waitForLastUsedFinish()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.amount, "175")
        XCTAssertEqual(viewModel.unit, "serving")
        XCTAssertNil(viewModel.lastUsedNotice)
    }

    func testLastUsedUnauthorizedExpiresTheSessionWithoutBlockingDetail() async {
        let service = makeService(allowedUnits: [unit("g")])
        await service.setLastUsed(.failure(FoodDetailServiceError.unauthorized))
        var expiredCount = 0
        let viewModel = makeViewModel(service: service) {
            expiredCount += 1
        }

        await viewModel.load()
        await waitUntil { expiredCount == 1 }

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.amount, "100")
        XCTAssertEqual(expiredCount, 1)
    }

    func testHeldLastUsedDoesNotOverwriteSlotOrNotesEdits() async {
        let service = makeService(allowedUnits: [unit("g")])
        await service.setLastUsed(.success(recent(amount: "250", unit: "g")))
        await service.holdNextLastUsed()
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await service.waitForLastUsedStart()
        viewModel.mealSlotChanged(.dinner)
        viewModel.notesChanged("extra sauce")
        await service.releaseLastUsed()
        await service.waitForLastUsedFinish()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.amount, "100")
        XCTAssertEqual(viewModel.unit, "g")
        XCTAssertEqual(viewModel.mealSlot, .dinner)
        XCTAssertEqual(viewModel.notes, "extra sauce")
    }

    // MARK: - Helpers

    private func makeService(allowedUnits: [FoodUnit]) -> LastUsedFoodDetailService {
        LastUsedFoodDetailService(
            food: FoodDetail(
                id: "food-1",
                name: "Oats",
                defaultQuantity: "100",
                defaultUnit: "g",
                allowedUnits: allowedUnits
            ),
            units: allowedUnits
        )
    }

    private func makeViewModel(
        service: LastUsedFoodDetailService,
        mealSlot: MealSlot? = nil,
        onSessionExpired: @escaping () -> Void = {}
    ) -> FoodDetailViewModel {
        FoodDetailViewModel(
            foodID: "food-1",
            originDate: date,
            originMealSlot: mealSlot,
            service: service,
            onSessionExpired: onSessionExpired
        )
    }

    private func unit(_ code: String) -> FoodUnit {
        FoodUnit(code: code, name: code)
    }

    private func recent(amount: String, unit: String) -> RecentLogItem {
        RecentLogItem(
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            lastUsedDate: date.addingDays(-1),
            mealSlot: .lunch,
            quantity: NutritionQuantity(amount: amount, unit: unit)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var matched = await predicate()
        while !matched, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
            matched = await predicate()
        }
        XCTAssertTrue(matched, "Timed out waiting for condition")
    }
}
