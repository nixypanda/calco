// Authenticated capability discovery.

import Foundation

public extension CalCoAPIClient {
    func fetchCapabilities(
        expectedAccountID: String? = nil
    ) async throws -> LogCreationIdempotencyCapability {
        let request = try makeRequest(
            method: .get,
            path: ["api", "capabilities"],
            expectedAccountID: expectedAccountID
        )
        let response = try await send(request, as: CapabilitiesResponse.self)
        return response.logCreationIdempotency
    }
}

public protocol LogCreationCapabilityProviding: Sendable {
    var baseURL: URL { get }
    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability
    /// Per-action probe. The default preserves legacy/offline test doubles;
    /// production passes the account frozen before the await.
    func fetchCapabilities(
        expectedAccountID: String
    ) async throws -> LogCreationIdempotencyCapability
}

public extension LogCreationCapabilityProviding {
    func fetchCapabilities(
        expectedAccountID: String
    ) async throws -> LogCreationIdempotencyCapability {
        try await fetchCapabilities()
    }
}

public struct CalCoLogCreationCapabilityProvider: LogCreationCapabilityProviding {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public var baseURL: URL { client.configuration.baseURL }

    public func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        try await fetchCapabilities(
            expectedAccountID: client.expectedAccountID ?? ""
        )
    }

    public func fetchCapabilities(
        expectedAccountID: String
    ) async throws -> LogCreationIdempotencyCapability {
        try await client.fetchCapabilities(
            expectedAccountID: expectedAccountID
        )
    }
}
