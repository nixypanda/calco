// Bridges GET /api/foods/search and the fast-logging history endpoints to
// Search; preserves cancellation passthrough.

import Foundation

public struct CalCoFoodSearchServiceAdapter: FoodSearchServicing, FoodSearchHistoryServicing {
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
            throw map(error)
        }
    }

    public func recentItems(
        from fromDate: LocalDiaryDate,
        to toDate: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> [RecentLogItem] {
        do {
            return try await client.recentItems(
                from: fromDate,
                to: toDate,
                mealSlot: mealSlot
            )
        } catch {
            throw map(error)
        }
    }

    public func categorySuggestions(
        query: String,
        limit: Int
    ) async throws -> [CategorySuggestion] {
        do {
            return try await client.categorySuggestions(query: query, limit: limit)
        } catch {
            throw map(error)
        }
    }

    public func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup {
        do {
            return try await client.lookupBarcode(barcode)
        } catch {
            throw map(error)
        }
    }

    private func map(_ error: Error) -> Error {
        if let apiError = error as? CalCoAPIError, case .cancelled = apiError {
            return error
        }
        if isUnauthorizedFoodSearchError(error) {
            return FoodSearchServiceError.unauthorized
        }
        if let apiError = error as? CalCoAPIError {
            // Not-found and validation payloads remain useful to the barcode UI.
            return apiError
        }
        return CalCoStoreMapping.foodSearchError(from: error)
    }

    private static func apiScope(from scope: FoodSearchScope) -> SearchScope {
        SearchScope(rawValue: scope.rawValue) ?? .all
    }
}
