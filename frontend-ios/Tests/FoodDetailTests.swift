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

    func setFood(_ value: FoodDetail?) { food = value }
    func setUnits(_ value: [FoodUnit]) { units = value }
    func setFoodError(_ value: Error?) { foodError = value }
    func setCreateError(_ value: Error?) { createError = value }
    func setDelayNanoseconds(_ value: UInt64) { delayNanoseconds = value }
    func recordedCreateCalls() -> [FoodLogCreateRequest] { createCalls }

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
}
