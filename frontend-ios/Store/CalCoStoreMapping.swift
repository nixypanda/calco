// Shared boundary mapping between API/Data and feature models; consistent error translation.
import Foundation

enum CalCoStoreMapping {
    static func diaryLog(from log: FoodLog) -> DiaryLog {
        DiaryLog(
            id: log.id,
            mealSlot: log.mealSlot,
            title: log.itemName,
            calories: log.calories,
            proteinG: log.proteinG,
            carbsG: log.carbsG,
            fatG: log.fatG,
            quantity: log.quantity,
            notes: log.notes,
            brand: log.itemBrand,
            itemReference: log.itemReference,
            logItem: LogSubmissionItem(logItem: log.item)
        )
    }

    static func diaryGoal(from goal: GoalSnapshot) -> DiaryGoalTargets {
        DiaryGoalTargets(
            calorieTarget: goal.targets.calorieTarget,
            proteinTargetG: goal.targets.proteinTargetG,
            carbsTargetG: goal.targets.carbsTargetG,
            fatTargetG: goal.targets.fatTargetG
        )
    }

    static func diaryPrefs(from preferences: DiaryPreferences) -> DiaryPrefs {
        DiaryPrefs(enabledSlots: preferences.enabledSlots)
    }

    static func diaryError(from error: Error) -> DiaryServiceError {
        if let featureError = error as? DiaryServiceError {
            return featureError
        }
        guard let apiError = error as? CalCoAPIError else {
            return .unknown
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .cancelled:
            return .cancelled
        case .network, .timeout:
            return .networkUnavailable
        case .rateLimited:
            return .server("Too many requests. Please try again later.")
        case .badStatus(_, let payload):
            return .server(nonEmpty(payload.message) ?? "The server could not complete the request.")
        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return .unknown
        }
    }

    static func foodSearchResult(from item: FoodSearchItem) -> FoodSearchResult {
        FoodSearchResult(
            id: item.id,
            source: item.source,
            sourceID: item.sourceID,
            barcode: item.barcode,
            name: item.name,
            brand: item.brand,
            categories: item.categories
        )
    }

    static func foodSearchError(from error: Error) -> FoodSearchServiceError {
        if let featureError = error as? FoodSearchServiceError {
            return featureError
        }
        guard let apiError = error as? CalCoAPIError else {
            return FoodSearchServiceError("An unexpected error occurred.")
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .cancelled, .network, .timeout:
            return FoodSearchServiceError("Network unavailable. Check your connection and try again.")
        case .rateLimited:
            return FoodSearchServiceError("Too many requests. Please try again later.")
        case .badStatus(_, let payload):
            return FoodSearchServiceError(
                nonEmpty(payload.message) ?? "The server could not complete the request."
            )
        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return FoodSearchServiceError("The server response could not be read.")
        }
    }

    static func foodDetail(from product: ProductDetail) -> FoodDetail {
        FoodDetail(
            id: product.id,
            name: product.name,
            brand: product.brand,
            categories: product.categories,
            defaultQuantity: product.defaultQuantity,
            defaultUnit: product.defaultUnit,
            nutrients: product.nutrients.map { nutrient in
                FoodNutrient(
                    code: nutrient.code,
                    amountPer100g: nutrient.amountPer100g,
                    unit: nutrient.unit
                )
            },
            servings: product.servings.map { serving in
                FoodServing(unit: serving.unit, gramsPerUnit: serving.gramsPerUnit)
            },
            allowedUnits: product.allowedUnits.map(foodUnit(from:))
        )
    }

    static func foodUnit(from unit: ProductUnit) -> FoodUnit {
        FoodUnit(code: unit.code, name: unit.name, kind: unit.kind)
    }

    static func foodDetailError(from error: Error) -> FoodDetailServiceError {
        if let featureError = error as? FoodDetailServiceError {
            return featureError
        }
        guard let apiError = error as? CalCoAPIError else {
            return .failed("An unexpected error occurred.")
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .network, .timeout, .cancelled:
            return .failed("Network unavailable. Check your connection and try again.")
        case .rateLimited:
            return .failed("Too many requests. Please try again later.")
        case .badStatus(_, let payload):
            return .failed(payload.message)
        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return .failed("The server response could not be read.")
        }
    }

    static func foodLogSubmitError(from error: Error) -> FoodDetailServiceError {
        if let featureError = error as? FoodDetailServiceError {
            return featureError
        }
        guard let apiError = error as? CalCoAPIError else {
            return .uncertain(error.localizedDescription)
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfterSeconds: retryAfter)
        case .badStatus(let statusCode, let payload):
            let message = nonEmpty(payload.message)
                ?? "The server could not complete the request."
            switch statusCode {
            case 409:
                return .conflict(message)
            case 408, 300..<400, 500...:
                return .uncertain(message)
            case 400..<500:
                return .failed(message)
            default:
                return .uncertain(message)
            }
        case .timeout, .network, .cancelled, .invalidResponse, .decoding:
            return .uncertain("Network unavailable. Check your connection and try again.")
        case .invalidURL, .encoding:
            return .failed(String(localized: "foodDetail.error.saveFailed"))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
