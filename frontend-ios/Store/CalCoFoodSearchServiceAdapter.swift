// Bridges GET /api/foods/search to Search; preserves cancellation passthrough.
import Foundation

public struct CalCoFoodSearchServiceAdapter: FoodSearchServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func searchFoods(
        query: String,
        scope: FoodSearchScope
    ) async throws -> [FoodSearchResult] {
        do {
            let items = try await client.searchFoods(
                query: query,
                scope: Self.apiScope(from: scope)
            )
            return items.map(CalCoStoreMapping.foodSearchResult(from:))
        } catch {
            if let apiError = error as? CalCoAPIError, case .cancelled = apiError {
                throw error
            }
            throw CalCoStoreMapping.foodSearchError(from: error)
        }
    }

    private static func apiScope(from scope: FoodSearchScope) -> SearchScope {
        SearchScope(rawValue: scope.rawValue) ?? .all
    }
}
