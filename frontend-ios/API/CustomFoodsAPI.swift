// Custom-food management and nutrient-definition endpoint calls.

import Foundation

public extension CalCoAPIClient {
    /// Lists the current catalog's custom foods. The server scopes mutations by
    /// ownership; the list is the reconciliation source after an uncertain
    /// create.
    func listCustomFoods() async throws -> [ProductDetail] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "foods", "custom"]
        )
        return try await send(request, as: CustomFoodListResponse.self).items
    }

    /// Creates a custom food. This route is deliberately not idempotent; callers
    /// must route an uncertain outcome through custom-food reconciliation.
    func createCustomFood(_ body: CustomFoodWriteRequest) async throws -> String {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .post,
            path: ["api", "foods", "custom"],
            body: data
        )
        return try await send(request, as: CustomFoodIDResponse.self).id
    }

    /// Replaces the complete custom-food aggregate. A lost response can be
    /// verified by re-reading the food; repeating the same PUT is idempotent.
    func updateCustomFood(id: String, body: CustomFoodWriteRequest) async throws -> String {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .put,
            path: ["api", "foods", "custom", id],
            body: data
        )
        return try await send(request, as: CustomFoodIDResponse.self).id
    }

    func deleteCustomFood(id: String) async throws {
        let request = try makeRequest(
            method: .delete,
            path: ["api", "foods", "custom", id]
        )
        try await sendVoidWithoutRedirects(request)
    }

    func listNutrientDefinitions() async throws -> [NutrientDefinition] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "nutrients"]
        )
        return try await send(request, as: NutrientDefinitionListResponse.self).items
    }
}
