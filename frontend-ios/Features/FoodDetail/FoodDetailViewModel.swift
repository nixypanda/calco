import Combine
import Foundation
import SwiftUI

public enum FoodDetailLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

private enum FoodDetailResolvedState: Equatable, Sendable {
    case loading
    case loaded(FoodDetail)
    case failed(String)
}

public enum FoodDetailSubmitState: Equatable, Sendable {
    case idle
    case submitting
    case failed(String)
    case succeeded
}

@MainActor
public final class FoodDetailViewModel: ObservableObject {
    @Published private var resolvedState: FoodDetailResolvedState = .loading
    @Published public var units: [FoodUnit] = []
    @Published public var amount: String = ""
    @Published public var unit: String = ""
    @Published public var mealSlot: MealSlot?
    @Published public var notes: String = ""
    @Published public var submitState: FoodDetailSubmitState = .idle

    public let foodID: String
    public let originDate: LocalDiaryDate
    public let originMealSlot: MealSlot?

    private let service: FoodDetailServicing
    private let onSuccess: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void

    public init(
        foodID: String,
        originDate: LocalDiaryDate,
        originMealSlot: MealSlot? = nil,
        service: FoodDetailServicing,
        onSuccess: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.foodID = foodID
        self.originDate = originDate
        self.originMealSlot = originMealSlot
        self.service = service
        self.onSuccess = onSuccess
        self.onSessionExpired = onSessionExpired
        self.mealSlot = originMealSlot
    }

    public var loadState: FoodDetailLoadState {
        switch resolvedState {
        case .loading: return .loading
        case .loaded: return .loaded
        case .failed(let message): return .failed(message)
        }
    }

    public var food: FoodDetail? {
        if case .loaded(let food) = resolvedState { return food }
        return nil
    }

    public var availableUnits: [FoodUnit] {
        sourceUnits(food: food, units: units)
    }

    public var amountValidationMessage: String? {
        validateLogAmount(amount)?.message
    }

    public var submitErrorMessage: String? {
        if case .failed(let message) = submitState { return message }
        return nil
    }

    public var isSubmitting: Bool {
        if case .submitting = submitState { return true }
        return false
    }

    public var didSubmitSuccessfully: Bool {
        if case .succeeded = submitState { return true }
        return false
    }

    public var nutritionPreview: [NutrientAmount]? {
        guard case .loaded(let food) = resolvedState else { return nil }
        return makeNutritionPreview(for: food, amount: amount, unit: unit)
    }

    public func load() async {
        resolvedState = .loading
        do {
            async let foodTask = service.fetchFoodDetail(id: foodID)
            async let unitsTask = service.fetchUnits()
            let (loadedFood, loadedUnits) = try await (foodTask, unitsTask)

            units = loadedUnits
            let defaultLogQuantity = loadedFood.defaultLogQuantity
            amount = defaultLogQuantity.amount
            unit = defaultLogQuantity.unit
            if mealSlot == nil {
                mealSlot = originMealSlot
            }
            resolvedState = .loaded(loadedFood)
        } catch {
            if isUnauthorizedFoodDetailError(error) {
                onSessionExpired()
                resolvedState = .failed(String(localized: "foodDetail.error.sessionExpired"))
            } else {
                resolvedState = .failed(foodDetailErrorMessage(error))
            }
        }
    }

    public func amountChanged(_ value: String) {
        amount = value
        clearSubmitFailure()
    }

    public func unitChanged(_ value: String) {
        unit = value
        clearSubmitFailure()
    }

    public func mealSlotChanged(_ value: MealSlot?) {
        mealSlot = value
        clearSubmitFailure()
    }

    public func notesChanged(_ value: String) {
        notes = value
        clearSubmitFailure()
    }

    private func clearSubmitFailure() {
        if case .failed = submitState {
            submitState = .idle
        }
    }

    public func submit() async {
        if isSubmitting || didSubmitSuccessfully { return }
        guard case .loaded = resolvedState else { return }
        if let validationMessage = amountValidationMessage {
            submitState = .failed(validationMessage)
            return
        }

        submitState = .submitting
        let request = FoodLogCreateRequest(
            date: originDate,
            timeZone: TimeZone.current.identifier,
            mealSlot: mealSlot,
            foodID: foodID,
            amount: amount,
            unit: unit,
            notes: {
                let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()
        )

        do {
            _ = try await service.createLog(request)
            submitState = .succeeded
            onSuccess(originDate, mealSlot)
        } catch {
            if isUnauthorizedFoodDetailError(error) {
                onSessionExpired()
                submitState = .failed(String(localized: "foodDetail.error.sessionExpired"))
            } else {
                submitState = .failed(foodDetailErrorMessage(error))
            }
        }
    }
}
