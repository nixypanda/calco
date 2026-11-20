// Meal CRUD and portion-nutrition endpoint calls.

import Foundation

public extension CalCoAPIClient {
    func listMeals() async throws -> [Meal] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "meals"]
        )
        let response = try await send(request, as: MealListResponse.self)
        return response.items
    }

    func getMeal(id: String) async throws -> Meal {
        let request = try makeRequest(
            method: .get,
            path: ["api", "meals", id]
        )
        return try await send(request, as: Meal.self)
    }

    func createMeal(_ body: MealWriteRequest) async throws -> Meal {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .post,
            path: ["api", "meals"],
            body: data
        )
        return try await send(request, as: Meal.self)
    }

    func updateMeal(id: String, _ body: MealWriteRequest) async throws -> Meal {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .put,
            path: ["api", "meals", id],
            body: data
        )
        return try await send(request, as: Meal.self)
    }

    func deleteMeal(id: String) async throws {
        let request = try makeRequest(
            method: .delete,
            path: ["api", "meals", id]
        )
        // DELETE /api/meals/{id} returns 204 with no body.
        try await sendVoidWithoutRedirects(request)
    }

    func getMealNutrients(
        mealID: String,
        amount: String,
        unit: String
    ) async throws -> MealNutritionResponse {
        let request = try makeRequest(
            method: .get,
            path: ["api", "meals", mealID, "nutrients"],
            queryItems: [
                URLQueryItem(name: "amount", value: amount),
                URLQueryItem(name: "unit", value: unit),
            ]
        )
        return try await send(request, as: MealNutritionResponse.self)
    }
}
