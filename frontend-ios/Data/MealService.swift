// Meal service contract, feature-visible catalog values, and error mapping.
//
// This file deliberately contains no submission transport. Logging a meal goes
// through the shared typed log-submission handler so the journal owns
// idempotency, retry, account isolation, and deletion barriers.

import Foundation

public struct MealProduct: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let nutritionSummary: NutritionSummary?

    public init(
        id: String,
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        nutritionSummary: NutritionSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.categories = categories
        self.nutritionSummary = nutritionSummary
    }

    public var displayName: String {
        guard let brand, !brand.isEmpty else { return name }
        return "\(name) · \(brand)"
    }
}

public enum MealServiceError: Error, Equatable, Sendable {
    case unauthorized
    case cancelled
    case notFound(String)
    /// A referenced product is missing or was deleted. The server currently
    /// returns 404 for a meal detail/list response when any component product
    /// cannot be resolved.
    case missingComponents(String)
    case forbidden(String)
    case validation(String)
    case network
    case rateLimited(retryAfterSeconds: Int?)
    case server(String)
}

public protocol MealsServicing: Sendable {
    func listMeals() async throws -> [Meal]
    func getMeal(id: String) async throws -> Meal
    func createMeal(_ request: MealWriteRequest) async throws -> Meal
    func updateMeal(id: String, _ request: MealWriteRequest) async throws -> Meal
    func deleteMeal(id: String) async throws
    func mealNutrients(
        mealID: String,
        amount: String,
        unit: String
    ) async throws -> MealNutritionResponse
    func fetchUnits() async throws -> [ProductUnit]
    /// Product-name search for the ingredient picker. Uses the existing
    /// `/api/foods/search` endpoint in the adapter.
    func searchComponentProducts(query: String) async throws -> [MealProduct]
    func fetchComponentProduct(id: String) async throws -> MealProduct
    /// Most recent logged portion for this meal. Optional so existing fakes
    /// stay source-compatible; shell/detail callers get the server value when
    /// available and fall back to the meal's configured portion otherwise.
    func lastUsedPortion(
        forMealID mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> NutritionQuantity?
}

public extension MealsServicing {
    func lastUsedPortion(
        forMealID mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> NutritionQuantity? {
        nil
    }
}

public func mealServiceMessage(_ error: Error) -> String {
    guard let error = error as? MealServiceError else {
        return String(localized: "meals.error.server")
    }
    switch error {
    case .unauthorized:
        return String(localized: "meals.error.sessionExpired")
    case .cancelled:
        return ""
    case .notFound:
        return String(localized: "meals.error.notFound")
    case .missingComponents(let message):
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "meals.error.missingComponents")
            : trimmed
    case .forbidden:
        return String(localized: "meals.error.forbidden")
    case .validation(let message), .server(let message):
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "meals.error.server")
            : trimmed
    case .network:
        return String(localized: "meals.error.network")
    case .rateLimited:
        return String(localized: "meals.error.rateLimited")
    }
}

public func isUnauthorizedMealError(_ error: Error) -> Bool {
    if let serviceError = error as? MealServiceError, serviceError == .unauthorized {
        return true
    }
    if let apiError = error as? CalCoAPIError, apiError.isUnauthorized {
        return true
    }
    return false
}

public func isMissingComponentsMealError(_ error: Error) -> Bool {
    if let serviceError = error as? MealServiceError,
       case .missingComponents = serviceError {
        return true
    }
    return false
}

/// Builds a typed meal log draft for the shared journal. Returns nil when the
/// quantity is not a positive plain decimal or the unit is not one the meal
/// nutrition contract can convert to grams.
public enum MealLogDraftBuilder {
    public static func makeDraft(
        meal: Meal,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String? = nil,
        unit: String? = nil,
        notes: String? = nil,
        timeZone: String
    ) -> LogSubmissionDraft? {
        let portion = meal.defaultPortion
        let rawAmount = amount ?? portion.amount
        let rawUnit = unit ?? portion.unit
        guard let normalizedAmount = MealQuantityRules.normalizedPositiveDecimal(rawAmount) else {
            return nil
        }
        let trimmedUnit = rawUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUnit.isEmpty, MealQuantityRules.isMassUnit(trimmedUnit) else {
            return nil
        }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LogSubmissionDraft(
            item: .meal(id: meal.id),
            date: date,
            mealSlot: mealSlot,
            amount: normalizedAmount,
            unit: trimmedUnit,
            notes: trimmedNotes?.isEmpty == false ? trimmedNotes : nil,
            timeZone: timeZone
        )
    }
}
