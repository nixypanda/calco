// Bridges meal CRUD, unit lookup, ingredient search, and nutrition preview to
// the Meals feature. No log submissions happen here.

import Foundation

public struct CalCoMealsServiceAdapter: MealsServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func listMeals() async throws -> [Meal] {
        do {
            return try await client.listMeals()
        } catch {
            throw Self.map(error)
        }
    }

    public func getMeal(id: String) async throws -> Meal {
        do {
            return try await client.getMeal(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    public func createMeal(_ request: MealWriteRequest) async throws -> Meal {
        do {
            return try await client.createMeal(request)
        } catch {
            throw Self.map(error)
        }
    }

    public func updateMeal(id: String, _ request: MealWriteRequest) async throws -> Meal {
        do {
            return try await client.updateMeal(id: id, request)
        } catch {
            throw Self.map(error)
        }
    }

    public func deleteMeal(id: String) async throws {
        do {
            try await client.deleteMeal(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    public func mealNutrients(
        mealID: String,
        amount: String,
        unit: String
    ) async throws -> MealNutritionResponse {
        do {
            return try await client.getMealNutrients(
                mealID: mealID,
                amount: amount,
                unit: unit
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func fetchUnits() async throws -> [ProductUnit] {
        do {
            return try await client.listUnits()
        } catch {
            throw Self.map(error)
        }
    }

    public func searchComponentProducts(query: String) async throws -> [MealProduct] {
        do {
            let items = try await client.searchFoods(query: query, scope: .all)
            return items.map { item in
                MealProduct(
                    id: item.id,
                    name: item.name,
                    brand: item.brand,
                    categories: item.categories,
                    nutritionSummary: item.nutritionSummary.per100g
                )
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func fetchComponentProduct(id: String) async throws -> MealProduct {
        do {
            let product = try await client.getFoodDetail(id: id)
            return MealProduct(
                id: product.id,
                name: product.name,
                brand: product.brand,
                categories: product.categories,
                nutritionSummary: product.nutritionSummary.per100g
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func lastUsedPortion(
        forMealID mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> NutritionQuantity? {
        do {
            let items = try await client.lastUsedItems(
                LastUsedItemsRequest(
                    fromDate: date.addingDays(-30),
                    toDate: date,
                    mealSlot: mealSlot,
                    items: [.meal(id: mealID)]
                )
            )
            return items.first {
                $0.submissionItem == .meal(id: mealID)
            }?.quantity
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> MealServiceError {
        if let serviceError = error as? MealServiceError {
            return serviceError
        }
        if error is CancellationError {
            return .cancelled
        }
        guard let apiError = error as? CalCoAPIError else {
            return .server(error.localizedDescription)
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .cancelled:
            return .cancelled
        case .timeout, .network:
            return .network
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfterSeconds: retryAfter)
        case .badStatus(let statusCode, let payload):
            let message = Self.nonEmpty(payload.message)
                ?? String(localized: "meals.error.server")
            switch statusCode {
            case 400, 422:
                return .validation(message)
            case 403:
                return .forbidden(message)
            case 404:
                return Self.isMissingComponentMessage(message)
                    ? .missingComponents(message)
                    : .notFound(message)
            case 409 where payload.code == "missing_components":
                return .missingComponents(message)
            case 429:
                return .rateLimited(retryAfterSeconds: nil)
            default:
                return .server(message)
            }
        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return .server(String(localized: "meals.error.server"))
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The API currently signals an unresolvable meal component as a 404 with
    /// a product-not-found message (directly or wrapped by the meal domain).
    private static func isMissingComponentMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("product") && lowercased.contains("not found")
    }
}
