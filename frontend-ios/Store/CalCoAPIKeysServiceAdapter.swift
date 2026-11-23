// Bridges the session-cookie API-key endpoints to Account Settings.
//
// The adapter preserves the difference between a definitive rejection and an
// ambiguous create outcome so the view model never blindly creates a second
// key after a lost response.

import Foundation

public struct CalCoAPIKeysServiceAdapter: APIKeyServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func listAPIKeys() async throws -> [APIKey] {
        do {
            return try await client.listAPIKeys()
        } catch {
            throw map(error)
        }
    }

    public func createAPIKey(_ request: APIKeyCreateRequest) async throws -> CreatedAPIKey {
        do {
            return try await client.createAPIKey(request)
        } catch {
            throw map(error)
        }
    }

    public func revokeAPIKey(id: String) async throws {
        do {
            try await client.revokeAPIKey(id: id)
        } catch {
            throw map(error)
        }
    }

    private func map(_ error: Error) -> APIKeyServiceError {
        if let error = error as? APIKeyServiceError {
            return error
        }

        guard let apiError = error as? CalCoAPIError else {
            return .unknown
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .network:
            return .networkUnavailable
        case .timeout:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .rateLimited:
            return .rateLimited
        case .badStatus(let statusCode, let payload):
            switch payload.code {
            case "unauthorized", "session_expired", "session_not_found", "session_revoked":
                return .unauthorized
            case "api_key_limit_reached":
                return .limitReached
            case "api_key_not_found":
                return .notFound
            case "invalid_api_key_name", "invalid_api_key_scope", "invalid_api_key_expiry":
                return .rejected(Self.nonEmpty(payload.message) ?? "invalid_api_key_request")
            default:
                let message = Self.nonEmpty(payload.message)
                if statusCode == 408 || statusCode >= 500 {
                    // A gateway/backend failure may happen after the create was
                    // committed. Preserve it as an ambiguous server failure.
                    return .server(message ?? "server_error")
                }
                if (400..<500).contains(statusCode) {
                    return .rejected(message ?? "request_rejected")
                }
                return .server(message ?? "server_error")
            }
        case .invalidURL, .encoding:
            return .unknown
        case .invalidResponse, .decoding:
            return .invalidResponse
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
