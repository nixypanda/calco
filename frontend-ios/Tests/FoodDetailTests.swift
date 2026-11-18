import SwiftUI
import XCTest

@testable import CalCo

private actor FakeFoodDetailService: FoodDetailServicing {
    private var food: FoodDetail?
    private var units: [FoodUnit] = []
    private var foodError: Error?
    private var createError: Error?
    private var delayNanoseconds: UInt64 = 0
    private var createCalls: [FoodLogCreateRequest] = []
    private var holdsNextCreate = false
    private var createStarted = false
    private var createReleased = false
    private var createContinuation: CheckedContinuation<Void, Never>?

    func setFood(_ value: FoodDetail?) { food = value }
    func setUnits(_ value: [FoodUnit]) { units = value }
    func setFoodError(_ value: Error?) { foodError = value }
    func setCreateError(_ value: Error?) { createError = value }
    func setDelayNanoseconds(_ value: UInt64) { delayNanoseconds = value }
    func recordedCreateCalls() -> [FoodLogCreateRequest] { createCalls }

    func holdNextCreate() {
        holdsNextCreate = true
        createStarted = false
        createReleased = false
    }

    func waitForCreateStart() async {
        let deadline = Date().addingTimeInterval(5)
        while !createStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(createStarted, "Timed out waiting for the create request")
    }

    func releaseCreate() {
        createReleased = true
        createContinuation?.resume()
        createContinuation = nil
    }

    func fetchFoodDetail(id: String) async throws -> FoodDetail {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let foodError { throw foodError }
        return food ?? FoodDetail(id: id, name: "Food")
    }

    func fetchUnits() async throws -> [FoodUnit] {
        units
    }

    func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if holdsNextCreate {
            holdsNextCreate = false
            createStarted = true
            await withCheckedContinuation { continuation in
                if createReleased {
                    continuation.resume()
                } else {
                    createContinuation = continuation
                }
            }
        }
        createCalls.append(request)
        if let createError { throw createError }
        return CreatedFoodLog(id: "log-1", date: request.date, mealSlot: request.mealSlot)
    }
}

@MainActor
private final class CallbackRecorder {
    var successes: [(LocalDiaryDate, MealSlot?)] = []
    var sessionExpiredCount = 0
}

@MainActor
final class FoodDetailTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    private func assertValidIdempotencyKey(
        _ key: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let key else {
            return XCTFail("Expected an idempotency key", file: file, line: line)
        }
        XCTAssertNotNil(UUID(uuidString: key), "The key must be a UUID", file: file, line: line)
        XCTAssertEqual(
            key,
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            "The key must not be blank or padded",
            file: file,
            line: line
        )
        XCTAssertTrue(
            (1...128).contains(key.count),
            "The key must fit the backend's 1...128 character limit",
            file: file,
            line: line
        )
    }

    private func makeViewModel(
        foodID: String,
        originMealSlot: MealSlot? = nil,
        service: FakeFoodDetailService,
        recorder: CallbackRecorder? = nil
    ) -> FoodDetailViewModel {
        let callbacks = recorder ?? CallbackRecorder()
        return FoodDetailViewModel(
            foodID: foodID,
            originDate: date,
            originMealSlot: originMealSlot,
            service: service,
            onSuccess: { callbacks.successes.append(($0, $1)) },
            onSessionExpired: { callbacks.sessionExpiredCount += 1 }
        )
    }

    func testLoadSuccessAppliesDefaults() async {
        let service = FakeFoodDetailService()
        await service.setFood(
            FoodDetail(
                id: "food-1",
                name: "Chicken",
                defaultQuantity: "2",
                defaultUnit: "serving",
                nutrients: [FoodNutrient(code: "ENERGY_KCAL", amountPer100g: "200", unit: "kcal")],
                servings: [FoodServing(unit: "serving", gramsPerUnit: "100")],
                allowedUnits: [FoodUnit(code: "serving", name: "Serving")]
            )
        )
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-1", originMealSlot: .lunch, service: service, recorder: recorder)

        await vm.load()

        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertEqual(vm.food?.name, "Chicken")
        XCTAssertEqual(vm.amount, "2")
        XCTAssertEqual(vm.unit, "serving")
        XCTAssertEqual(vm.mealSlot, .lunch)
        XCTAssertEqual(vm.availableUnits.map(\.code), ["serving"])
        XCTAssertTrue(recorder.successes.isEmpty, "Loading must not report a completed log")
        XCTAssertEqual(recorder.sessionExpiredCount, 0)
    }

    func testLoadFallsBackToFirstServing() async {
        let service = FakeFoodDetailService()
        await service.setFood(
            FoodDetail(
                id: "food-2",
                name: "Rice",
                nutrients: [],
                servings: [FoodServing(unit: "cup", gramsPerUnit: "180")],
                allowedUnits: []
            )
        )
        await service.setUnits([FoodUnit(code: "g", name: "Grams")])
        let vm = makeViewModel(foodID: "food-2", service: service)

        await vm.load()

        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertEqual(vm.amount, "1")
        XCTAssertEqual(vm.unit, "cup")
        XCTAssertEqual(vm.availableUnits.map(\.code), ["g"])
    }

    func testLoadHalfDefaultNeverMixesFields() async {
        let quantityOnlyService = FakeFoodDetailService()
        await quantityOnlyService.setFood(
            FoodDetail(
                id: "food-half-quantity",
                name: "Quantity only",
                defaultQuantity: "2",
                servings: [FoodServing(unit: "cup", gramsPerUnit: "200")]
            )
        )
        let quantityVM = makeViewModel(foodID: "food-half-quantity", service: quantityOnlyService)
        await quantityVM.load()

        XCTAssertEqual(quantityVM.amount, "1")
        XCTAssertEqual(quantityVM.unit, "cup")

        let unitOnlyService = FakeFoodDetailService()
        await unitOnlyService.setFood(
            FoodDetail(id: "food-half-unit", name: "Unit only", defaultUnit: "serving")
        )
        let unitVM = makeViewModel(foodID: "food-half-unit", service: unitOnlyService)
        await unitVM.load()

        XCTAssertEqual(unitVM.amount, "100")
        XCTAssertEqual(unitVM.unit, "g")
    }

    func testSubmitImmediatelyAfterLoadUsesValidFallback() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-auto", name: "Auto"))
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-auto", service: service, recorder: recorder)
        await vm.load()

        XCTAssertEqual(vm.loadState, .loaded)
        XCTAssertNotNil(vm.food)
        XCTAssertEqual(vm.amount, "100")
        XCTAssertEqual(vm.unit, "g")
        XCTAssertNil(vm.amountValidationMessage)

        await vm.submit()

        XCTAssertEqual(vm.submitState, .succeeded)
        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.amount, "100")
        XCTAssertEqual(calls.first?.unit, "g")
        XCTAssertEqual(recorder.successes.count, 1)
    }

    func testLoadFailure() async {
        let service = FakeFoodDetailService()
        await service.setFoodError(FoodDetailServiceError.failed("boom"))
        let vm = makeViewModel(foodID: "food-3", service: service)

        await vm.load()

        XCTAssertNil(vm.food)
        guard case .failed(let message) = vm.loadState else {
            return XCTFail("Expected failed load state")
        }
        XCTAssertEqual(message, "boom")
    }

    func testLoadUnauthorizedCallsSessionExpired() async {
        let service = FakeFoodDetailService()
        await service.setFoodError(FoodDetailServiceError.unauthorized)
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-4", service: service, recorder: recorder)

        await vm.load()

        XCTAssertEqual(recorder.sessionExpiredCount, 1)
        guard case .failed = vm.loadState else {
            return XCTFail("Expected failed load state")
        }
    }

    func testAmountValidationBlocksSubmit() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-5", name: "Egg"))
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-5", service: service, recorder: recorder)
        await vm.load()
        vm.amountChanged("   ")

        await vm.submit()

        guard case .failed(let message) = vm.submitState else {
            return XCTFail("Expected failed submit state")
        }
        XCTAssertFalse(message.isEmpty)
        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "Invalid amount must never reach the service")
        XCTAssertTrue(recorder.successes.isEmpty)
    }

    func testSubmitSuccessCallsCallbackWithContext() async {
        let service = FakeFoodDetailService()
        await service.setFood(
            FoodDetail(id: "food-6", name: "Tofu", allowedUnits: [FoodUnit(code: "g", name: "Grams")])
        )
        let recorder = CallbackRecorder()
        let vm = makeViewModel(
            foodID: "food-6",
            originMealSlot: .dinner,
            service: service,
            recorder: recorder
        )
        await vm.load()
        vm.amount = "100"
        vm.unit = "g"
        vm.mealSlot = .dinner
        vm.notes = "note"

        await vm.submit()

        XCTAssertEqual(vm.submitState, .succeeded)
        XCTAssertTrue(vm.didSubmitSuccessfully)
        XCTAssertNil(vm.submitErrorMessage)
        XCTAssertEqual(recorder.successes.count, 1)
        XCTAssertEqual(recorder.successes.first?.0, date)
        XCTAssertEqual(recorder.successes.first?.1, .dinner)

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1)
        let request = calls.first
        XCTAssertEqual(request?.foodID, "food-6")
        XCTAssertEqual(request?.date, date)
        XCTAssertEqual(request?.mealSlot, .dinner)
        XCTAssertEqual(request?.timeZone, TimeZone.current.identifier)
        XCTAssertEqual(request?.amount, "100")
        XCTAssertEqual(request?.unit, "g")
        XCTAssertEqual(request?.notes, "note")
    }

    func testSubmitUnauthorizedCallsSessionExpired() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-7", name: "Beans"))
        await service.setCreateError(FoodDetailServiceError.unauthorized)
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-7", service: service, recorder: recorder)
        await vm.load()
        vm.amount = "50"
        vm.unit = "g"

        await vm.submit()

        XCTAssertEqual(recorder.sessionExpiredCount, 1)
        XCTAssertTrue(recorder.successes.isEmpty, "Unauthorized submit must not report success")
        guard case .failed = vm.submitState else {
            return XCTFail("Expected failed submit state")
        }
        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "The service should still have been attempted")
    }

    func testConcurrentSubmitIsGuardedWhileInFlight() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-10", name: "Bread"))
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-10", service: service, recorder: recorder)
        await vm.load()
        vm.amount = "1"
        vm.unit = "g"
        await service.setDelayNanoseconds(50_000_000)

        async let first: Void = vm.submit()
        async let second: Void = vm.submit()
        await first
        await second

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "A second submit while one is in flight must be ignored")
        assertValidIdempotencyKey(calls.first?.idempotencyKey)
        XCTAssertEqual(recorder.successes.count, 1)
    }

    func testSubmitFailureIsExposedForDisplay() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-fail", name: "Failure Food"))
        await service.setCreateError(FoodDetailServiceError.failed("Network down"))
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-fail", service: service, recorder: recorder)
        await vm.load()
        vm.amount = "10"
        vm.unit = "g"

        await vm.submit()

        XCTAssertEqual(vm.submitState, .failed("Network down"))
        XCTAssertEqual(vm.submitErrorMessage, "Network down", "The failure banner renders submitErrorMessage")
        XCTAssertFalse(vm.isSubmitting, "The spinner must stop once the request fails")
        XCTAssertFalse(vm.didSubmitSuccessfully)
        XCTAssertTrue(recorder.successes.isEmpty, "A failed POST must not report success")
        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1)
    }

    func testSubmitFailureClearsWhenFieldEdited() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-clear", name: "Clearable"))
        await service.setCreateError(FoodDetailServiceError.failed("Try later"))
        let vm = makeViewModel(foodID: "food-clear", service: service)
        await vm.load()
        vm.amount = "10"
        vm.unit = "g"
        await vm.submit()
        XCTAssertNotNil(vm.submitErrorMessage)

        vm.amountChanged("11")

        XCTAssertEqual(vm.submitState, .idle)
        XCTAssertNil(vm.submitErrorMessage, "Editing must dismiss a stale failure banner")
    }

    func testValidationFailureIsVisibleWithoutRequest() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-validation", name: "Validation"))
        let vm = makeViewModel(foodID: "food-validation", service: service)
        await vm.load()
        vm.amountChanged("   ")

        await vm.submit()

        XCTAssertEqual(vm.submitErrorMessage, vm.amountValidationMessage)
        XCTAssertFalse(vm.submitErrorMessage?.isEmpty ?? true)
        XCTAssertFalse(vm.isSubmitting)
        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "Invalid input must never reach the service")
    }

    func testSubmitIsIdempotentAfterSuccess() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-once", name: "Once"))
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-once", service: service, recorder: recorder)
        await vm.load()
        vm.amount = "1"
        vm.unit = "g"

        await vm.submit()
        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "A repeated submit must not create a second log")
        XCTAssertEqual(recorder.successes.count, 1)
        XCTAssertEqual(vm.submitState, .succeeded)
        XCTAssertTrue(vm.didSubmitSuccessfully)
    }

    func testRetryAfterUncertainFailureReusesIdempotencyKey() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-retry", name: "Retry"))
        await service.setCreateError(
            FoodDetailServiceError.uncertain(
                "Network unavailable. Check your connection and try again."
            )
        )
        let recorder = CallbackRecorder()
        let vm = makeViewModel(foodID: "food-retry", service: service, recorder: recorder)
        await vm.load()
        vm.amount = "10"
        vm.unit = "g"

        await vm.submit()
        XCTAssertFalse(vm.didSubmitSuccessfully)
        XCTAssertTrue(recorder.successes.isEmpty, "An uncertain failure must not report success")

        await service.setCreateError(nil)
        await vm.retryPending()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2)
        assertValidIdempotencyKey(calls.first?.idempotencyKey)
        XCTAssertEqual(
            calls.first?.idempotencyKey,
            calls.last?.idempotencyKey,
            "An explicit retry of the unchanged request must replay the original key"
        )
        XCTAssertEqual(vm.submitState, .succeeded)
        XCTAssertEqual(recorder.successes.count, 1)
    }

    func testEditedPayloadUsesNewIdempotencyKey() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-edit", name: "Edited"))
        await service.setCreateError(FoodDetailServiceError.failed("Try later"))
        let vm = makeViewModel(foodID: "food-edit", service: service)
        await vm.load()
        vm.amount = "10"
        vm.unit = "g"

        await vm.submit()

        await service.setCreateError(nil)
        vm.amountChanged("11")
        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.amount, "10")
        XCTAssertEqual(calls.last?.amount, "11")
        assertValidIdempotencyKey(calls.first?.idempotencyKey)
        assertValidIdempotencyKey(calls.last?.idempotencyKey)
        XCTAssertNotEqual(
            calls.first?.idempotencyKey,
            calls.last?.idempotencyKey,
            "An edited payload must be a new logical submission with a new key"
        )
    }

    func testNewSubmissionFlowUsesNewIdempotencyKey() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-new-flow", name: "New Flow"))
        let first = makeViewModel(foodID: "food-new-flow", service: service)
        await first.load()
        first.amount = "10"
        first.unit = "g"
        await first.submit()

        let second = makeViewModel(foodID: "food-new-flow", service: service)
        await second.load()
        second.amount = "10"
        second.unit = "g"
        await second.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(
            calls.first?.idempotencyKey,
            calls.last?.idempotencyKey,
            "A new form flow must not reuse a previous submission's key"
        )
    }

    func testNutritionPreviewWhenDataSufficient() async {
        let service = FakeFoodDetailService()
        await service.setFood(
            FoodDetail(
                id: "food-8",
                name: "Oats",
                nutrients: [FoodNutrient(code: "ENERGY_KCAL", amountPer100g: "400", unit: "kcal")],
                servings: [FoodServing(unit: "g", gramsPerUnit: "1")]
            )
        )
        let vm = makeViewModel(foodID: "food-8", service: service)
        await vm.load()
        vm.amount = "50"
        vm.unit = "g"

        let preview = vm.nutritionPreview
        XCTAssertEqual(preview?.count, 1)
        XCTAssertEqual(preview?.first?.code, "ENERGY_KCAL")
        XCTAssertEqual(preview?.first?.amount, "200.0")
        XCTAssertEqual(preview?.first?.unit, "kcal")
    }

    func testNutritionPreviewNilWhenInsufficient() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-9", name: "Salt", nutrients: [], servings: []))
        let vm = makeViewModel(foodID: "food-9", service: service)
        await vm.load()
        vm.amount = "abc"
        vm.unit = "g"

        XCTAssertNil(vm.nutritionPreview)
    }

    func testViewObservesInjectedViewModel() {
        let vm = makeViewModel(foodID: "food-view", service: FakeFoodDetailService())
        let view = FoodDetailView(viewModel: vm)

        let storage = Mirror(reflecting: view).children
            .first { $0.label == "_viewModel" }?.value

        XCTAssertTrue(
            storage is ObservedObject<FoodDetailViewModel>,
            "FoodDetailView must observe the externally owned view model; @StateObject would retain a previous session's data"
        )
    }

    func testValidateLogAmountRejectsInvalidValues() {
        XCTAssertNil(validateLogAmount("1"))
        XCTAssertNil(validateLogAmount("1.5"))
        XCTAssertNotNil(validateLogAmount(""))
        XCTAssertNotNil(validateLogAmount("0"))
        XCTAssertNotNil(validateLogAmount("-1"))
        XCTAssertNotNil(validateLogAmount("abc"))
        XCTAssertNotNil(validateLogAmount("1.2.3"))
        XCTAssertNotNil(validateLogAmount("NaN"))
        XCTAssertNotNil(validateLogAmount("Infinity"))
    }

    func testSubmitTrimsNotes() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-trim", name: "Trim"))
        let vm = makeViewModel(foodID: "food-trim", service: service)
        await vm.load()
        vm.amount = "10"
        vm.unit = "g"
        vm.notes = "  note  "

        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.first?.notes, "note")
    }

    func testRecoveryLocalizationKeysAreDefined() {
        let keys = [
            "foodDetail.error.conflict",
            "foodDetail.error.differentServer",
            "foodDetail.error.rateLimited",
            "foodDetail.error.saveFailed",
            "foodDetail.error.uncertain",
            "foodDetail.pending.banner",
            "foodDetail.pending.checkDiary",
            "foodDetail.pending.conflicted",
            "foodDetail.pending.later",
            "foodDetail.pending.retry",
            "foodDetail.pending.review",
            "foodDetail.pending.title",
            "foodDetail.pending.recoveryTitle",
            "foodDetail.pending.newSubmission",
            "foodDetail.pending.newSubmission.confirmTitle",
            "foodDetail.pending.newSubmission.confirmMessage",
            "foodDetail.pending.newSubmission.confirmAction",
            "foodDetail.pending.cancel",
            "foodDetail.pending.discard",
            "foodDetail.pending.discard.confirmTitle",
            "foodDetail.pending.discard.confirmMessage",
            "foodDetail.pending.discard.confirmAction",
            "foodDetail.pending.invalidated",
            "foodDetail.pending.reviewAll",
            "foodDetail.pending.dismissBanner",
            "foodDetail.pending.banner.count",
            "foodDetail.error.journalUnavailable",
            "diary.editor.delete.confirmWithPending",
            "diary.editor.back",
            "diary.editor.discard.action",
            "diary.editor.discard.message",
            "diary.editor.discard.title",
            "diary.mutation.deleted.blockedPending",
        ]
        for key in keys {
            XCTAssertNotEqual(
                NSLocalizedString(key, bundle: .main, comment: ""),
                key,
                "Missing localized value for \(key)"
            )
        }
    }

    // MARK: - Durable submission journal

    private func makeStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-vm-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    private func makeDurableViewModel(
        foodID: String,
        service: FakeFoodDetailService,
        store: LogSubmissionStore,
        accountID: String = "account-a",
        recorder: CallbackRecorder? = nil
    ) -> FoodDetailViewModel {
        let callbacks = recorder ?? CallbackRecorder()
        return FoodDetailViewModel(
            foodID: foodID,
            originDate: date,
            originMealSlot: .lunch,
            service: service,
            onSuccess: { callbacks.successes.append(($0, $1)) },
            onSessionExpired: { callbacks.sessionExpiredCount += 1 },
            accountID: accountID,
            baseURL: URL(string: "https://calco.example.com"),
            submissionStore: store
        )
    }

    @discardableResult
    private func seedSubmission(
        in store: LogSubmissionStore,
        foodID: String,
        amount: String,
        unit: String = "g",
        state: LogSubmissionState = .uncertain,
        accountID: String = "account-a"
    ) throws -> PendingLogSubmission {
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: foodID,
            foodName: "Seeded",
            date: date,
            mealSlot: .lunch,
            amount: amount,
            unit: unit,
            notes: nil,
            timeZoneIdentifier: "America/New_York",
            baseURL: URL(string: "https://calco.example.com"),
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let entry = try store.reserve(
            accountID: accountID,
            foodName: "Seeded",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )
        switch state {
        case .uncertain:
            try store.markUncertain(
                id: entry.id,
                accountID: accountID,
                status: nil,
                message: "offline"
            )
        case .conflicted:
            try store.markConflicted(
                id: entry.id,
                accountID: accountID,
                message: "conflict"
            )
        case .succeeded:
            try store.markSucceeded(
                id: entry.id,
                accountID: accountID,
                logID: "log-seed",
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
        case .inFlight:
            break
        case .invalidated:
            _ = try store.invalidateUnresolved(
                accountID: accountID,
                foodID: foodID,
                date: date,
                reason: "deleted"
            )
        }
        return store.entry(id: entry.id, accountID: accountID) ?? entry
    }

    func testUncertainRetryReusesExactBodyAndKey() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-journal", name: "Journal"))
        await service.setCreateError(FoodDetailServiceError.uncertain("timeout"))
        let store = makeStore()
        let vm = makeDurableViewModel(foodID: "food-journal", service: service, store: store)
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        await vm.submit()
        XCTAssertEqual(vm.submitState, .uncertain("timeout"))

        await service.setCreateError(nil)
        await vm.submit()
        var calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "Normal Log must not silently retry or mint a key")
        XCTAssertNotNil(vm.newSubmissionConfirmation)

        await vm.retryPending()
        calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].idempotencyKey, calls[1].idempotencyKey)
        XCTAssertEqual(calls[0].encodedBody, calls[1].encodedBody)
        XCTAssertNotNil(calls[0].encodedBody)
        XCTAssertEqual(vm.submitState, .succeeded)
    }

    func testLateCreateSuccessAfterLogDeletionIsNotDelivered() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-delete-race", name: "Delete Race"))
        let store = makeStore()
        let recorder = CallbackRecorder()
        let vm = makeDurableViewModel(
            foodID: "food-delete-race",
            service: service,
            store: store,
            recorder: recorder
        )
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        await service.holdNextCreate()
        let submit = Task { await vm.submit() }
        await service.waitForCreateStart()

        let entry = try XCTUnwrap(store.entries(accountID: "account-a").first)
        _ = try store.invalidateUnresolved(
            accountID: "account-a",
            foodID: "food-delete-race",
            date: date,
            reason: String(localized: "foodDetail.pending.invalidated")
        )

        await service.releaseCreate()
        await submit.value

        XCTAssertEqual(vm.submitState, .failed(String(localized: "foodDetail.pending.invalidated")))
        XCTAssertTrue(recorder.successes.isEmpty)
        XCTAssertEqual(
            store.entry(id: entry.id, accountID: "account-a")?.state,
            .invalidated,
            "A late success must not overwrite the deletion barrier"
        )
        XCTAssertTrue(store.attentionEntries(accountID: "account-a").isEmpty)
    }

    func testPendingSurvivesViewModelRecreationAndNewStoreInstance() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-relaunch", name: "Relaunch"))
        await service.setCreateError(FoodDetailServiceError.uncertain("offline"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-relaunch-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let firstStore = LogSubmissionStore(persistence: persistence)
        let first = makeDurableViewModel(
            foodID: "food-relaunch",
            service: service,
            store: firstStore
        )
        await first.load()
        first.amountChanged("25")
        first.unitChanged("g")
        await first.submit()
        XCTAssertEqual(first.submitState, .uncertain("offline"))

        let relaunchedStore = LogSubmissionStore(persistence: persistence)
        let second = makeDurableViewModel(
            foodID: "food-relaunch",
            service: service,
            store: relaunchedStore
        )
        await second.load()
        XCTAssertEqual(second.pendingSubmissions.count, 1)
        XCTAssertEqual(second.pendingSubmissions.first?.state, .uncertain)

        await service.setCreateError(nil)
        await second.retryPending()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].idempotencyKey, calls[1].idempotencyKey)
        XCTAssertEqual(calls[0].encodedBody, calls[1].encodedBody)
        XCTAssertEqual(second.submitState, .succeeded)
        XCTAssertTrue(relaunchedStore.attentionEntries(accountID: "account-a").isEmpty)
    }

    func testReentrySubmitDoesNotBlindlyCreateNewAttempt() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(
            id: "food-reentry",
            name: "Reentry",
            defaultQuantity: "10",
            defaultUnit: "g"
        ))
        await service.setCreateError(FoodDetailServiceError.uncertain("offline"))
        let store = makeStore()
        let first = makeDurableViewModel(foodID: "food-reentry", service: service, store: store)
        await first.load()
        await first.submit()

        let second = makeDurableViewModel(foodID: "food-reentry", service: service, store: store)
        await second.load()
        await service.setCreateError(nil)
        await second.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "Re-entry must not silently mint a second key")
        XCTAssertEqual(second.submitState, .uncertain("offline"))
        XCTAssertEqual(
            second.newSubmissionConfirmation?.id,
            store.attentionEntries(accountID: "account-a").first?.id,
            "Normal Log must route the user to the matching unresolved attempt"
        )
    }

    func testAThenBThenARequiresExplicitConfirmationBeforeANewKey() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-aba", name: "A B A"))
        await service.setCreateError(FoodDetailServiceError.uncertain("offline"))
        let store = makeStore()
        let vm = makeDurableViewModel(foodID: "food-aba", service: service, store: store)
        await vm.load()
        vm.unitChanged("g")

        vm.amountChanged("10")
        await vm.submit()
        vm.amountChanged("11")
        await vm.submit()
        let firstA = store.attentionEntries(accountID: "account-a")
            .first { $0.draft.amount == "10" }

        vm.amountChanged("10")
        await vm.submit()

        var calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2, "Returning to A must not mint its third key implicitly")
        XCTAssertEqual(vm.newSubmissionConfirmation?.id, firstA?.id)

        await vm.confirmCreateNewSubmission()

        calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(Set(calls.compactMap(\.idempotencyKey)).count, 3)
        XCTAssertNotEqual(calls[2].idempotencyKey, firstA?.idempotencyKey)
        XCTAssertTrue(
            store.attentionEntries(accountID: "account-a").contains { $0.id == firstA?.id },
            "Confirming a new submission must not retry or resolve the older entry"
        )
    }

    func testNotNowNeverAuthorizesANewKeyWhileTheSameDraftIsUnresolved() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-not-now", name: "Not Now"))
        await service.setCreateError(FoodDetailServiceError.uncertain("offline"))
        let store = makeStore()
        let vm = makeDurableViewModel(foodID: "food-not-now", service: service, store: store)
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")
        await vm.submit()
        let pending = store.attentionEntries(accountID: "account-a").first

        vm.dismissPendingNotice()
        XCTAssertTrue(vm.hidesPendingNotice)
        XCTAssertTrue(vm.visiblePendingSubmissions.isEmpty)

        await service.setCreateError(nil)
        await vm.submit()

        var calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "“Not now” must not be treated as consent for a new key")
        XCTAssertEqual(vm.newSubmissionConfirmation?.id, pending?.id)
        XCTAssertFalse(
            vm.hidesPendingNotice,
            "A blocked Log action must reveal the recovery entry so the user can decide"
        )

        await vm.confirmCreateNewSubmission()

        calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(calls[1].idempotencyKey, pending?.idempotencyKey)
        XCTAssertEqual(
            store.attentionEntries(accountID: "account-a").first?.id,
            pending?.id,
            "The old unresolved entry remains a separate decision"
        )
    }

    func testEditsAwayAndBackStillRequireExplicitConfirmation() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-edit-back", name: "Edit Back"))
        await service.setCreateError(FoodDetailServiceError.uncertain("offline"))
        let store = makeStore()
        let vm = makeDurableViewModel(foodID: "food-edit-back", service: service, store: store)
        await vm.load()
        vm.unitChanged("g")

        vm.amountChanged("10")
        await vm.submit()
        let entryA = store.attentionEntries(accountID: "account-a").first

        vm.amountChanged("11")
        await vm.submit()
        vm.amountChanged("10")
        await vm.submit()

        var calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 2, "Edits back to A must not bypass the unresolved A entry")
        XCTAssertEqual(vm.newSubmissionConfirmation?.id, entryA?.id)

        await vm.confirmCreateNewSubmission()
        calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(Set(calls.compactMap(\.idempotencyKey)).count, 3)
    }

    func testConflictIsDefinitiveAndNeverAutoRetries() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-conflict", name: "Conflict"))
        await service.setCreateError(FoodDetailServiceError.conflict("different request"))
        let store = makeStore()
        let vm = makeDurableViewModel(foodID: "food-conflict", service: service, store: store)
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        await vm.submit()
        XCTAssertEqual(vm.submitState, .conflict("different request"))

        await service.setCreateError(nil)
        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "A conflicted key must not be retried")
        let entry = store.attentionEntries(accountID: "account-a").first
        XCTAssertEqual(entry?.state, .conflicted)
        XCTAssertNil(entry?.body)
    }

    func testDiskWriteFailureDoesNotSendThePost() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-disk", name: "Disk"))
        let store = LogSubmissionStore(persistence: FailingFoodLogSubmissionPersistence())
        let vm = makeDurableViewModel(foodID: "food-disk", service: service, store: store)
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "No POST may occur without a durable record")
        XCTAssertNotNil(vm.submitErrorMessage)
    }

    func testOtherAccountCannotSeeOrRetryPendingSubmission() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-account", name: "Account"))
        await service.setCreateError(FoodDetailServiceError.uncertain("offline"))
        let store = makeStore()
        let first = makeDurableViewModel(
            foodID: "food-account",
            service: service,
            store: store,
            accountID: "account-a"
        )
        await first.load()
        first.amountChanged("10")
        first.unitChanged("g")
        await first.submit()
        let pending = store.attentionEntries(accountID: "account-a").first
        XCTAssertNotNil(pending)

        let second = makeDurableViewModel(
            foodID: "food-account",
            service: service,
            store: store,
            accountID: "account-b"
        )
        await second.load()
        XCTAssertTrue(second.pendingSubmissions.isEmpty)
        if let pending {
            await second.retryPending(pending)
        }

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "Another account must not reuse the key")
    }

    func testInvalidatedEntryCannotBeRetriedOrResurrected() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-invalidated", name: "Invalidated"))
        let store = makeStore()
        let entry = try seedSubmission(
            in: store,
            foodID: "food-invalidated",
            amount: "10",
            state: .invalidated
        )
        let vm = makeDurableViewModel(
            foodID: "food-invalidated",
            service: service,
            store: store
        )
        await vm.load()
        XCTAssertTrue(vm.visiblePendingSubmissions.isEmpty)
        XCTAssertTrue(store.attentionEntries(accountID: "account-a").isEmpty)

        await vm.retryPending(entry)

        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "A deleted log's attempt must never be replayed")
        XCTAssertEqual(vm.submitErrorMessage, "deleted")
    }

    func testFailedFoodDetailFetchStillReachesPendingRecovery() async throws {
        let service = FakeFoodDetailService()
        await service.setFoodError(FoodDetailServiceError.failed("detail unavailable"))
        let store = makeStore()
        let entry = try seedSubmission(
            in: store,
            foodID: "food-recover-failed",
            amount: "10"
        )
        let vm = makeDurableViewModel(
            foodID: "food-recover-failed",
            service: service,
            store: store
        )

        await vm.load()
        guard case .failed = vm.loadState else {
            return XCTFail("Expected the food fetch to fail")
        }
        XCTAssertEqual(vm.pendingSubmissions.map(\.id), [entry.id])
        XCTAssertEqual(vm.visiblePendingSubmissions.map(\.id), [entry.id])

        await vm.retryPending()

        XCTAssertEqual(vm.submitState, .succeeded)
        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "Recovery must be usable without a food-detail fetch")
        XCTAssertEqual(calls.first?.idempotencyKey, entry.idempotencyKey)
        XCTAssertTrue(store.attentionEntries(accountID: "account-a").isEmpty)
    }

    func testMultiplePendingEntriesAreDiscoverableAndIndividuallyRetryable() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-multi", name: "Multi"))
        let store = makeStore()
        let first = try seedSubmission(
            in: store,
            foodID: "food-multi",
            amount: "10"
        )
        let second = try seedSubmission(
            in: store,
            foodID: "food-multi",
            amount: "11"
        )
        let vm = makeDurableViewModel(foodID: "food-multi", service: service, store: store)

        await vm.load()
        XCTAssertEqual(
            Set(vm.visiblePendingSubmissions.map(\.id)),
            [first.id, second.id]
        )

        await vm.retryPending(second)

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.idempotencyKey, second.idempotencyKey)
        XCTAssertEqual(
            store.attentionEntries(accountID: "account-a").map(\.id),
            [first.id],
            "The other unresolved entry remains available for review"
        )
    }

    func testConflictedEntryCanOnlyBeResolvedByExplicitDiscard() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-discard", name: "Discard"))
        let store = makeStore()
        let entry = try seedSubmission(
            in: store,
            foodID: "food-discard",
            amount: "10",
            state: .conflicted
        )
        let vm = makeDurableViewModel(foodID: "food-discard", service: service, store: store)
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        await vm.submit()
        var calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "A conflicted key must never be retried automatically")
        XCTAssertEqual(vm.newSubmissionConfirmation?.id, entry.id)

        vm.discardPending(entry)

        XCTAssertTrue(store.attentionEntries(accountID: "account-a").isEmpty)
        XCTAssertTrue(vm.visiblePendingSubmissions.isEmpty)
        XCTAssertEqual(vm.submitState, .idle)

        await vm.submit()
        calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "After explicit discard, Log is a fresh decision")
        XCTAssertNotEqual(calls.first?.idempotencyKey, entry.idempotencyKey)
    }

    func testSuccessfulLogDisablesFormAndRemovesRetryControls() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-success-lock", name: "Success Lock"))
        let store = makeStore()
        let older = try seedSubmission(
            in: store,
            foodID: "food-success-lock",
            amount: "10"
        )
        let vm = makeDurableViewModel(
            foodID: "food-success-lock",
            service: service,
            store: store
        )
        await vm.load()
        vm.amountChanged("20")
        vm.unitChanged("g")

        await vm.submit()

        XCTAssertEqual(vm.submitState, .succeeded)
        XCTAssertFalse(vm.isFormEditable)
        XCTAssertTrue(vm.visiblePendingSubmissions.isEmpty)
        XCTAssertFalse(vm.requiresNewSubmissionConfirmation)

        vm.amountChanged("21")
        XCTAssertEqual(vm.submitState, .succeeded, "Edits cannot revive the completed form")
        await vm.submit()
        await vm.retryPending(older)

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1, "No dead retry control may send after success")
    }

    func testNewPendingEntryUnhidesAnEarlierNotNow() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-unhide", name: "Unhide"))
        let store = makeStore()
        _ = try seedSubmission(
            in: store,
            foodID: "food-unhide",
            amount: "10"
        )
        let vm = makeDurableViewModel(foodID: "food-unhide", service: service, store: store)
        await vm.load()
        vm.dismissPendingNotice()
        XCTAssertTrue(vm.visiblePendingSubmissions.isEmpty)

        _ = try seedSubmission(
            in: store,
            foodID: "food-unhide",
            amount: "11"
        )
        vm.refreshRecoveryEntries()

        XCTAssertFalse(vm.hidesPendingNotice, "New recovery work must not stay hidden")
        XCTAssertEqual(vm.visiblePendingSubmissions.count, 2)
    }

    func testAbandonedInFlightRowRemainsRecoverableWithItsOwnKey() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-abandoned", name: "Abandoned"))
        let store = makeStore()
        let entry = try seedSubmission(
            in: store,
            foodID: "food-abandoned",
            amount: "10",
            state: .inFlight
        )
        let vm = makeDurableViewModel(
            foodID: "food-abandoned",
            service: service,
            store: store
        )

        await vm.load()
        XCTAssertEqual(vm.visiblePendingSubmissions.map(\.id), [entry.id])
        await vm.retryPending(entry)

        let calls = await service.recordedCreateCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.idempotencyKey, entry.idempotencyKey)
        XCTAssertEqual(vm.submitState, .succeeded)
    }

    func testLiveInFlightRowIsHiddenButStillBlocksNormalLog() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-live", name: "Live"))
        let store = makeStore()
        let entry = try seedSubmission(
            in: store,
            foodID: "food-live",
            amount: "10",
            state: .inFlight
        )
        try store.markInFlight(id: entry.id, accountID: "account-a")
        let vm = makeDurableViewModel(foodID: "food-live", service: service, store: store)
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        XCTAssertTrue(vm.visiblePendingSubmissions.isEmpty)
        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "A live row must still block a second key")
        XCTAssertEqual(vm.newSubmissionConfirmation?.id, entry.id)
    }

    func testUnreadableJournalBlocksPostAndDoesNotOverwriteIt() async {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-unreadable", name: "Unreadable"))
        let persistence = ThrowingLoadPersistence()
        let store = LogSubmissionStore(persistence: persistence)
        let vm = makeDurableViewModel(
            foodID: "food-unreadable",
            service: service,
            store: store
        )
        await vm.load()
        vm.amountChanged("10")
        vm.unitChanged("g")

        await vm.submit()

        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "No POST may happen while the journal is unreadable")
        XCTAssertEqual(
            vm.submitErrorMessage,
            String(localized: "foodDetail.error.journalUnavailable")
        )
        XCTAssertEqual(persistence.saveCount, 0, "The unreadable journal must not be overwritten")
    }

    func testMissingJournalRowIsNeverSentFromMemory() async throws {
        let service = FakeFoodDetailService()
        await service.setFood(FoodDetail(id: "food-missing-row", name: "Missing Row"))
        let store = makeStore()
        let entry = try seedSubmission(
            in: store,
            foodID: "food-missing-row",
            amount: "10"
        )
        try store.remove(id: entry.id, accountID: "account-a")
        let vm = makeDurableViewModel(
            foodID: "food-missing-row",
            service: service,
            store: store
        )
        await vm.load()

        await vm.retryPending(entry)

        let calls = await service.recordedCreateCalls()
        XCTAssertTrue(calls.isEmpty, "A missing durable row must not be recreated in memory")
        XCTAssertNotNil(vm.submitErrorMessage)
    }
}

private final class ThrowingLoadPersistence: LogSubmissionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var saves = 0

    var saveCount: Int { lock.withLock { saves } }

    func load(accountID: String) throws -> Data? {
        throw CocoaError(.fileReadCorruptFile)
    }

    func save(_ data: Data, accountID: String) throws {
        lock.withLock { saves += 1 }
        throw CocoaError(.fileWriteUnknown)
    }

    func quarantine(accountID: String, reason: String) {}
}

private struct FailingFoodLogSubmissionPersistence: LogSubmissionPersisting {
    func load(accountID: String) throws -> Data? { nil }
    func save(_ data: Data, accountID: String) throws {
        throw CocoaError(.fileWriteUnknown)
    }
    func quarantine(accountID: String, reason: String) {}
}
