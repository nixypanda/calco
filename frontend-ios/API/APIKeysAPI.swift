// Browser-session-only personal API-key management endpoints.
//
// These calls intentionally use the shared cookie session and never attach an
// Authorization header. No response body or secret is logged here.

import Foundation

public extension CalCoAPIClient {
    static let apiKeyManagementTimeout: TimeInterval = 30

    func listAPIKeys() async throws -> [APIKey] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "auth", "api-keys"],
            timeout: Self.apiKeyManagementTimeout
        )
        return try await send(request, as: APIKeyListResponse.self).items
    }

    func createAPIKey(_ body: APIKeyCreateRequest) async throws -> CreatedAPIKey {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .post,
            path: ["api", "auth", "api-keys"],
            body: data,
            timeout: Self.apiKeyManagementTimeout
        )
        return try await send(request, as: CreatedAPIKey.self)
    }

    func revokeAPIKey(id: String) async throws {
        let request = try makeRequest(
            method: .delete,
            path: ["api", "auth", "api-keys", id],
            timeout: Self.apiKeyManagementTimeout
        )
        // 204 has no response body; redirects are rejected by the client.
        try await sendVoidWithoutRedirects(request)
    }
}
