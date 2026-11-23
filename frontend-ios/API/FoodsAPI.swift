// Food search and product endpoint calls.

import Foundation

public extension CalCoAPIClient {
    func searchFoods(
        query: String,
        scope: SearchScope = .all
    ) async throws -> [FoodSearchItem] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "foods", "search"],
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "scope", value: scope.rawValue),
            ]
        )
        let response = try await send(request, as: FoodSearchResponse.self)
        return response.items
    }

    func getFoodDetail(id: String) async throws -> ProductDetail {
        let request = try makeRequest(
            method: .get,
            path: ["api", "foods", id]
        )
        return try await send(request, as: ProductDetail.self)
    }

    func listUnits() async throws -> [ProductUnit] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "units"]
        )
        let response = try await send(request, as: ProductUnitListResponse.self)
        return response.items
    }

    func categorySuggestions(
        query: String,
        limit: Int = 8
    ) async throws -> [CategorySuggestion] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "foods", "categories"],
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        return try await send(request, as: CategorySuggestionResponse.self).items
    }

    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup {
        let request = try makeRequest(
            method: .get,
            path: ["api", "foods", "barcode", barcode]
        )
        return try await send(request, as: BarcodeLookup.self)
    }
}
