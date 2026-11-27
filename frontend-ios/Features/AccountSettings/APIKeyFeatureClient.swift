// Value-type dependency client for the Account Settings / API keys TCA feature.
// It wraps the frozen `APIKeyServicing` contract and the existing
// `APIKeySecretCopying` clipboard seam. Services live here, never in State.
//
// Every RPC carries a captured account/generation/requestID context. The live
// client checks it against the CURRENT session on the main actor before each
// transport; a stale or foreign account can never read, create or revoke.

import ComposableArchitecture
import Foundation

public struct APIKeyRequestContext: Equatable, Sendable {
    public let accountID: String
    public let generation: UInt64
    public let requestID: UUID
}

public struct APIKeyFeatureClient: Sendable {
    public var listKeys: @Sendable (APIKeyRequestContext) async throws -> [APIKey]
    public var createKey: @Sendable (APIKeyCreateRequest, APIKeyRequestContext) async throws -> CreatedAPIKey
    public var revokeKey: @Sendable (String, APIKeyRequestContext) async throws -> Void
    /// Guards the captured account/generation immediately before the MainActor
    /// pasteboard write, so a stale session cannot copy a secret.
    public var copySecret: @Sendable (String, String, UInt64) -> APIKeyClipboardReceipt?
    public var clearSecret: @Sendable (APIKeyClipboardReceipt) -> Void
    public var now: @Sendable () -> Date
    public var isCurrentSession: @MainActor @Sendable (String, UInt64) -> Bool

    public init(
        listKeys: @escaping @Sendable (APIKeyRequestContext) async throws -> [APIKey],
        createKey: @escaping @Sendable (APIKeyCreateRequest, APIKeyRequestContext) async throws -> CreatedAPIKey,
        revokeKey: @escaping @Sendable (String, APIKeyRequestContext) async throws -> Void,
        copySecret: @escaping @Sendable (String, String, UInt64) -> APIKeyClipboardReceipt?,
        clearSecret: @escaping @Sendable (APIKeyClipboardReceipt) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        isCurrentSession: @escaping @MainActor @Sendable (String, UInt64) -> Bool
    ) {
        self.listKeys = listKeys
        self.createKey = createKey
        self.revokeKey = revokeKey
        self.copySecret = copySecret
        self.clearSecret = clearSecret
        self.now = now
        self.isCurrentSession = isCurrentSession
    }

    public static func live(
        service: any APIKeyServicing,
        clipboard: any APIKeySecretCopying = SystemAPIKeySecretClipboard(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        isCurrentSession: @escaping @MainActor @Sendable (String, UInt64) -> Bool
    ) -> Self {
        Self(
            listKeys: { context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.listAPIKeys()
            },
            createKey: { request, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.createAPIKey(request)
            },
            revokeKey: { id, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                try await service.revokeAPIKey(id: id)
            },
            copySecret: { secret, accountID, generation in
                guard MainActor.assumeIsolated({
                    isCurrentSession(accountID, generation)
                }) else { return nil }
                return MainActor.assumeIsolated {
                    clipboard.copySecretToClipboard(secret)
                }
            },
            clearSecret: { receipt in
                MainActor.assumeIsolated {
                    clipboard.clearSecretFromClipboard(receipt)
                }
            },
            now: nowProvider,
            isCurrentSession: isCurrentSession
        )
    }

    private static func guardCurrent(
        _ context: APIKeyRequestContext,
        isCurrentSession: @MainActor @Sendable (String, UInt64) -> Bool
    ) async throws {
        let current = await MainActor.run {
            isCurrentSession(context.accountID, context.generation)
        }
        guard current else { throw APIKeyServiceError.unauthorized }
    }
}

public extension DependencyValues {
    var apiKeyClient: APIKeyFeatureClient {
        get { self[APIKeyFeatureClientKey.self] }
        set { self[APIKeyFeatureClientKey.self] = newValue }
    }
}

private enum APIKeyFeatureClientKey: DependencyKey {
    // Fail closed when a host forgets to wire the live client.
    static let liveValue: APIKeyFeatureClient = .init(
        listKeys: { _ in throw APIKeyServiceError.unauthorized },
        createKey: { _, _ in throw APIKeyServiceError.unauthorized },
        revokeKey: { _, _ in throw APIKeyServiceError.unauthorized },
        copySecret: { _, _, _ in nil },
        clearSecret: { _ in },
        isCurrentSession: { _, _ in false }
    )
    static let testValue: APIKeyFeatureClient = liveValue
}
