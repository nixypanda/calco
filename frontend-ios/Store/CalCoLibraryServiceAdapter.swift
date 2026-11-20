// Bridges the catalog client to Library. There is intentionally no ad-hoc POST
// here: ad-hoc writes must go through `LibraryLogSubmitting` so the shared
// journal owns the key, exact body, replay, and retry barriers.

import Foundation

public struct CalCoLibraryServiceAdapter: LibraryServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func listCustomFoods() async throws -> [CustomFood] {
        do {
            return try await client.listCustomFoods().map(CustomFood.init(product:))
        } catch {
            throw Self.map(error)
        }
    }

    public func customFood(id: String) async throws -> CustomFood {
        do {
            return CustomFood(product: try await client.getFoodDetail(id: id))
        } catch {
            throw Self.map(error)
        }
    }

    public func nutrientDefinitions() async throws -> [NutrientDefinition] {
        do {
            return try await client.listNutrientDefinitions()
        } catch {
            throw Self.map(error)
        }
    }

    public func units() async throws -> [ProductUnit] {
        do {
            return try await client.listUnits()
        } catch {
            throw Self.map(error)
        }
    }

    public func createCustomFood(_ request: CustomFoodWriteRequest) async throws -> String {
        do {
            return try await client.createCustomFood(request)
        } catch {
            throw Self.map(error)
        }
    }

    public func updateCustomFood(
        id: String,
        request: CustomFoodWriteRequest
    ) async throws -> String {
        do {
            return try await client.updateCustomFood(id: id, body: request)
        } catch {
            throw Self.map(error)
        }
    }

    public func deleteCustomFood(id: String) async throws {
        do {
            try await client.deleteCustomFood(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    public static func map(_ error: Error) -> CustomFoodServiceError {
        if let serviceError = error as? CustomFoodServiceError {
            return serviceError
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
                ?? String(localized: "library.error.server")
            switch statusCode {
            case 404:
                return .notFound(message)
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
            return .uncertain(
                String(localized: "library.error.uncertain")
            )
        case .invalidURL, .encoding:
            return .failed(String(localized: "library.error.request"))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
