// Bridges the daily nutrient-report endpoint into the feature's typed service
// errors. The endpoint is user-scoped and read-only; no client-side report
// derivation or caching happens here.

import Foundation

public struct CalCoNutritionDetailsServiceAdapter: NutritionDetailsServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func fetchNutritionDetails(
        for date: LocalDiaryDate
    ) async throws -> NutritionDetailsReport {
        do {
            return try await client.fetchNutritionDetails(on: date)
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: Error) -> NutritionDetailsServiceError {
        if let serviceError = error as? NutritionDetailsServiceError {
            return serviceError
        }
        if isCancelledNutritionDetailsError(error) {
            return .cancelled
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
            return .server(String(localized: "nutrition.error.rateLimited"))
        case .badStatus(_, let payload):
            let trimmed = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return .server(
                trimmed.isEmpty
                    ? String(localized: "nutrition.error.generic")
                    : trimmed
            )
        case .invalidResponse, .decoding:
            return .invalidResponse
        case .invalidURL, .encoding:
            return .unknown
        }
    }
}
