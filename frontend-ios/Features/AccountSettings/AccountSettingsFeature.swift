// Account Settings / personal API keys reducer.
//
// A newly created secret lives only in this feature State until the user finishes
// the reveal. It is never persisted. Ambiguous creates refresh metadata (GET
// only) instead of retrying the POST. 401, account change, sign-out and
// dismissal clear session-scoped state and any receipt-owned clipboard secret.
// Every RPC carries captured account/generation/requestID; the live client
// guards before transport and completions re-check identity.

import ComposableArchitecture
import Dependencies
import Foundation

public enum APIKeyListPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded([APIKey])
    /// Existing keys stay visible during a refresh: one lifecycle case, not an
    /// independent `isRefreshing` boolean beside `loaded`.
    case refreshing(previous: [APIKey])
    case failed(String)

    public var keys: [APIKey] {
        switch self {
        case .loaded(let keys), .refreshing(previous: let keys): return keys
        case .idle, .loading, .failed: return []
        }
    }

    public var isRefreshing: Bool {
        if case .refreshing = self { true } else { false }
    }
}

@Reducer
public struct AccountSettingsFeature {
    @ObservableState
    public struct State: Equatable {
        public let accountID: String
        public let generation: UInt64

        public var keys: [APIKey] = []
        public var listPhase: APIKeyListPhase = .idle
        public var listNotice: String?

        public var isCreatePresented = false
        public var draftName = ""
        public var draftScope: APIKeyCreatableScope = .read
        public var draftExpiry: APIKeyExpiryChoice = .default
        public var createState: APIKeyCreateState = .editing
        public var createdKey: CreatedAPIKey?
        public var isSecretObscured = false
        public var copyState: APIKeyCopyState = .idle
        public var uncertainMetadataRefreshFailed = false

        public var revokeTarget: APIKey?
        public var revokingKeyID: String?
        public var revokeState: APIKeyRevokeState = .idle

        public var clipboardReceipt: APIKeyClipboardReceipt?
        public var isSceneActive = true
        public var now: Date

        public static let maximumActiveKeys = 10

        var hasLoaded = false
        var hasAttemptedCreate = false
        var sessionExpired = false
        var isUncertainRefresh = false
        var activeListRequestID: UUID?
        var activeCreateRequestID: UUID?
        var activeRevokeRequestID: UUID?

        public init(accountID: String, generation: UInt64, now: Date = Date()) {
            self.accountID = accountID
            self.generation = generation
            self.now = now
        }

        public var isMetadataReady: Bool {
            if case .loaded = listPhase { true } else { false }
        }

        public var activeKeyCount: Int { keys.filter { !$0.isExpired(at: now) }.count }

        public var hasReachedActiveKeyLimit: Bool {
            activeKeyCount >= Self.maximumActiveKeys
        }

        public var isLoadingFirstPage: Bool {
            if case .loading = listPhase { true } else { false }
        }

        public var isSessionExpired: Bool { sessionExpired }
        public var isRevoking: Bool { revokingKeyID != nil }
        public var isBusy: Bool { createState == .submitting || isRevoking }

        public var revokeErrorMessage: String? {
            if case .failed(let message) = revokeState { message } else { nil }
        }

        public var createErrorMessage: String? {
            if case .failed(let message) = createState { message } else { nil }
        }

        public var createUncertainMessage: String? {
            if case .uncertain(let message) = createState { message } else { nil }
        }

        public var isCreateFormEnabled: Bool {
            guard isCreatePresented,
                  createdKey == nil,
                  !sessionExpired else { return false }
            switch createState {
            case .submitting, .uncertain, .created: return false
            case .editing, .failed: return true
            }
        }

        public var isCreateSubmitDisabled: Bool {
            guard isCreateFormEnabled else { return true }
            return hasReachedActiveKeyLimit
        }

        public var nameValidationMessage: String? {
            guard hasAttemptedCreate || !draftName.isEmpty else { return nil }
            switch APIKeyNameValidator.validatedName(from: draftName) {
            case .success: return nil
            case .failure(.required): return String(localized: "apiKeys.create.name.required")
            case .failure(.tooLong): return String(localized: "apiKeys.create.name.tooLong")
            case .failure(.invalidCharacters): return String(localized: "apiKeys.create.name.invalid")
            }
        }

        public var isSecretRevealed: Bool { createdKey != nil && !isSecretObscured }
        public var canCopySecret: Bool { createdKey != nil && !isSecretObscured }

        func requestContext(requestID: UUID) -> APIKeyRequestContext {
            APIKeyRequestContext(
                accountID: accountID, generation: generation, requestID: requestID
            )
        }

        mutating func clearTransientCreateError() {
            if case .failed = createState { createState = .editing }
        }
    }

    public enum Action: Sendable {
        case onAppear
        case loadIfNeeded
        case load
        case refresh
        case nowUpdated(Date)
        case keysReceived(context: APIKeyRequestContext, keys: [APIKey])
        case loadFailed(context: APIKeyRequestContext, message: String, unauthorized: Bool)
        case presentCreateForm
        case cancelCreateForm
        case createSheetDidDisappear
        case draftNameChanged(String)
        case draftScopeChanged(APIKeyCreatableScope)
        case draftExpiryChanged(APIKeyExpiryChoice)
        case submitCreate
        case createReceived(context: APIKeyRequestContext, created: CreatedAPIKey)
        case createFailed(context: APIKeyRequestContext, error: APIKeyServiceError)
        case refreshMetadataForUncertainCreate
        case finishSecretReveal
        case hideSecret
        case revealSecret
        case copySecret
        case scenePhaseChanged(isActive: Bool)
        case requestRevoke(APIKey)
        case cancelRevoke
        case confirmRevoke
        case revokeReceived(context: APIKeyRequestContext, id: String)
        case revokeFailed(context: APIKeyRequestContext, error: APIKeyServiceError)
        case clearOnDismiss
        case accountChanged(String)
        case signOut
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(generation: UInt64)
        case accountChanged(id: String, generation: UInt64)
        case dismiss(generation: UInt64)
    }

    @Dependency(\.apiKeyClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce<State, Action> { (state: inout State, action: Action) -> Effect<Action> in
            switch action {
            case .onAppear, .loadIfNeeded:
                guard !state.hasLoaded else { return .none }
                state.hasLoaded = true
                return Self.startLoad(&state, client: client, uuid: uuid)

            case .load, .refresh:
                return Self.startLoad(&state, client: client, uuid: uuid)

            case let .nowUpdated(now):
                state.now = now
                return .none

            case let .keysReceived(request, keys):
                guard Self.isAuthorized(state, request: request),
                      state.activeListRequestID == request.requestID else { return .none }
                state.activeListRequestID = nil
                state.keys = keys
                state.listPhase = .loaded(keys)
                state.listNotice = nil
                state.isUncertainRefresh = false
                state.uncertainMetadataRefreshFailed = false
                if let target = state.revokeTarget,
                   !keys.contains(where: { $0.id == target.id }) {
                    state.revokeTarget = nil
                }
                return .none

            case let .loadFailed(request, message, unauthorized):
                guard Self.isAuthorized(state, request: request),
                      state.activeListRequestID == request.requestID else { return .none }
                state.activeListRequestID = nil
                if unauthorized { return Self.expireSession(&state, client: client) }
                let hadKeys = !state.keys.isEmpty
                if hadKeys {
                    state.listPhase = .loaded(state.keys)
                    state.listNotice = message
                } else {
                    state.listPhase = .failed(message)
                }
                if state.isUncertainRefresh {
                    state.uncertainMetadataRefreshFailed = true
                    state.isUncertainRefresh = false
                }
                return .none

            case .presentCreateForm:
                guard !state.sessionExpired, !state.isBusy, state.createdKey == nil else { return .none }
                guard state.isMetadataReady else { return .none }
                guard !state.hasReachedActiveKeyLimit else {
                    state.listNotice = String(localized: "apiKeys.limit.message")
                    return .none
                }
                Self.resetCreateDraft(&state, client: client)
                state.isCreatePresented = true
                return .none

            case .cancelCreateForm:
                guard state.createState != .submitting, state.createdKey == nil else { return .none }
                Self.resetCreateDraft(&state, client: client)
                state.isCreatePresented = false
                return .none

            case .createSheetDidDisappear:
                guard state.isCreatePresented else { return .none }
                Self.resetCreateDraft(&state, client: client)
                state.isCreatePresented = false
                return .none

            case let .draftNameChanged(name):
                guard name != state.draftName else { return .none }
                state.draftName = name
                state.clearTransientCreateError()
                return .none

            case let .draftScopeChanged(scope):
                guard scope != state.draftScope else { return .none }
                state.draftScope = scope
                state.clearTransientCreateError()
                return .none

            case let .draftExpiryChanged(expiry):
                guard expiry != state.draftExpiry else { return .none }
                state.draftExpiry = expiry
                state.clearTransientCreateError()
                return .none

            case .submitCreate:
                guard state.isCreateFormEnabled,
                      !state.hasReachedActiveKeyLimit,
                      !state.sessionExpired,
                      state.isMetadataReady else { return .none }
                state.hasAttemptedCreate = true
                guard case .success(let name) = APIKeyNameValidator.validatedName(from: state.draftName) else {
                    return .none
                }
                let requestModel = APIKeyCreateRequest(
                    name: name, scope: state.draftScope,
                    expiresInDays: state.draftExpiry.expiresInDays
                )
                let request = state.requestContext(requestID: uuid())
                state.activeCreateRequestID = request.requestID
                state.createState = .submitting
                state.copyState = .idle
                return .run { send in
                    do {
                        let created = try await client.createKey(requestModel, request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.createReceived(context: request, created: created))
                    } catch {
                        await Self.handleCreateError(
                            error, request: request, send: send, client: client
                        )
                    }
                }

            case let .createReceived(request, created):
                guard Self.isAuthorized(state, request: request),
                      state.activeCreateRequestID == request.requestID else { return .none }
                state.activeCreateRequestID = nil
                state.createdKey = created
                // A response can land while the app is inactive. Never reveal a
                // freshly minted secret without an active, deliberate reveal.
                state.isSecretObscured = !state.isSceneActive
                state.copyState = .idle
                state.createState = .created
                if let index = state.keys.firstIndex(where: { $0.id == created.key.id }) {
                    state.keys[index] = created.key
                } else {
                    state.keys.insert(created.key, at: 0)
                }
                state.listPhase = .loaded(state.keys)
                state.listNotice = nil
                return .none

            case let .createFailed(request, error):
                guard Self.isAuthorized(state, request: request),
                      state.activeCreateRequestID == request.requestID else { return .none }
                state.activeCreateRequestID = nil
                if error.isUnauthorized { return Self.expireSession(&state, client: client) }
                if error.isAmbiguousCreateFailure {
                    state.createState = .uncertain(
                        String(localized: "apiKeys.create.uncertain.message")
                    )
                    state.uncertainMetadataRefreshFailed = false
                    return Self.startUncertainRefresh(&state, client: client, uuid: uuid)
                }
                state.createState = .failed(Self.message(for: error))
                return .none

            case .refreshMetadataForUncertainCreate:
                guard case .uncertain = state.createState, !state.sessionExpired else { return .none }
                return Self.startUncertainRefresh(&state, client: client, uuid: uuid)

            case .finishSecretReveal:
                guard state.createdKey != nil else { return .none }
                Self.resetCreateDraft(&state, client: client)
                state.isCreatePresented = false
                return .none

            case .hideSecret:
                guard state.createdKey != nil else { return .none }
                state.isSecretObscured = true
                return .none

            case .revealSecret:
                guard state.createdKey != nil, state.isSceneActive else { return .none }
                state.isSecretObscured = false
                state.copyState = .idle
                return .none

            case .copySecret:
                guard let secret = state.createdKey?.secret, state.canCopySecret else { return .none }
                let receipt = client.copySecret(
                    secret.value,
                    state.accountID,
                    state.generation
                )
                state.clipboardReceipt = receipt
                state.copyState = receipt == nil ? .failed : .copied
                return .none

            case let .scenePhaseChanged(isActive):
                state.isSceneActive = isActive
                guard !isActive, state.createdKey != nil else { return .none }
                state.isSecretObscured = true
                state.copyState = .idle
                return .none

            case let .requestRevoke(key):
                guard !state.sessionExpired,
                      !state.isCreatePresented,
                      !state.isBusy,
                      state.revokeTarget == nil else { return .none }
                state.revokeState = .idle
                state.revokeTarget = key
                return .none

            case .cancelRevoke:
                guard state.revokingKeyID == nil else { return .none }
                state.revokeTarget = nil
                state.revokeState = .idle
                return .none

            case .confirmRevoke:
                guard let target = state.revokeTarget,
                      state.revokingKeyID == nil,
                      !state.sessionExpired else { return .none }
                let request = state.requestContext(requestID: uuid())
                state.activeRevokeRequestID = request.requestID
                state.revokeTarget = nil
                state.revokingKeyID = target.id
                state.revokeState = .revoking
                return .run { send in
                    do {
                        try await client.revokeKey(target.id, request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.revokeReceived(context: request, id: target.id))
                    } catch {
                        await Self.handleRevokeError(
                            error, request: request, send: send, client: client
                        )
                    }
                }

            case let .revokeReceived(request, id):
                guard Self.isAuthorized(state, request: request),
                      state.activeRevokeRequestID == request.requestID else { return .none }
                state.activeRevokeRequestID = nil
                state.keys.removeAll { $0.id == id }
                state.listNotice = nil
                state.revokingKeyID = nil
                state.revokeState = .idle
                return .none

            case let .revokeFailed(request, error):
                guard Self.isAuthorized(state, request: request),
                      state.activeRevokeRequestID == request.requestID else { return .none }
                state.activeRevokeRequestID = nil
                state.revokingKeyID = nil
                if error.isUnauthorized { return Self.expireSession(&state, client: client) }
                state.revokeState = .failed(Self.message(for: error))
                return .none

            case .clearOnDismiss:
                Self.clearOwnedClipboardSecret(&state, client: client)
                guard state.createdKey != nil || state.clipboardReceipt != nil else { return .none }
                state.createdKey = nil
                state.isSecretObscured = false
                state.copyState = .idle
                state.uncertainMetadataRefreshFailed = false
                state.createState = .editing
                state.activeCreateRequestID = nil
                return .none

            case let .accountChanged(newAccountID):
                guard newAccountID != state.accountID else { return .none }
                return .send(.delegate(.accountChanged(
                    id: newAccountID, generation: state.generation
                )))

            case .signOut:
                Self.clearSessionScopedState(&state, client: client)
                return .none

            case .delegate:
                return .none
            }
        }
    }

    /// Pure identity comparison; live @MainActor authority is awaited in effects.
    private static func isAuthorized(
        _ state: State, request: APIKeyRequestContext
    ) -> Bool {
        request.accountID == state.accountID
            && request.generation == state.generation
    }

    private static func isCurrent(
        _ request: APIKeyRequestContext, client: APIKeyFeatureClient
    ) async -> Bool {
        await MainActor.run {
            client.isCurrentSession(request.accountID, request.generation)
        }
    }

    private static func startLoad(
        _ state: inout State, client: APIKeyFeatureClient, uuid: UUIDGenerator
    ) -> Effect<Action> {
        guard !state.sessionExpired else { return .none }
        let request = state.requestContext(requestID: uuid())
        state.activeListRequestID = request.requestID
        let hadKeys = !state.keys.isEmpty
        state.listPhase = hadKeys ? .refreshing(previous: state.keys) : .loading
        return .run { send in
            do {
                let keys = try await client.listKeys(request)
                guard await isCurrent(request, client: client) else { return }
                await send(.keysReceived(context: request, keys: keys))
            } catch {
                await handleLoadError(error, request: request, send: send, client: client)
            }
        }
    }

    private static func startUncertainRefresh(
        _ state: inout State, client: APIKeyFeatureClient, uuid: UUIDGenerator
    ) -> Effect<Action> {
        guard case .uncertain = state.createState, !state.sessionExpired else { return .none }
        state.uncertainMetadataRefreshFailed = false
        state.isUncertainRefresh = true
        return startLoad(&state, client: client, uuid: uuid)
    }

    private static func handleLoadError(
        _ error: Error, request: APIKeyRequestContext,
        send: Send<Action>, client: APIKeyFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        let serviceError = (error as? APIKeyServiceError) ?? .unknown
        await send(.loadFailed(
            context: request,
            message: message(for: serviceError),
            unauthorized: serviceError.isUnauthorized
        ))
    }

    private static func handleCreateError(
        _ error: Error, request: APIKeyRequestContext,
        send: Send<Action>, client: APIKeyFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        await send(.createFailed(
            context: request, error: (error as? APIKeyServiceError) ?? .unknown
        ))
    }

    private static func handleRevokeError(
        _ error: Error, request: APIKeyRequestContext,
        send: Send<Action>, client: APIKeyFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        await send(.revokeFailed(
            context: request, error: (error as? APIKeyServiceError) ?? .unknown
        ))
    }

    private static func expireSession(
        _ state: inout State, client: APIKeyFeatureClient
    ) -> Effect<Action> {
        guard !state.sessionExpired else { return .none }
        state.sessionExpired = true
        state.activeListRequestID = nil
        state.activeCreateRequestID = nil
        state.activeRevokeRequestID = nil
        let message = String(localized: "diary.error.sessionExpired")
        clearOwnedClipboardSecret(&state, client: client)
        state.keys = []
        state.listPhase = .failed(message)
        state.listNotice = nil
        state.isCreatePresented = false
        resetCreateDraftFields(&state)
        state.revokeTarget = nil
        state.revokingKeyID = nil
        state.revokeState = .idle
        return .send(.delegate(.sessionExpired(generation: state.generation)))
    }

    private static func clearSessionScopedState(
        _ state: inout State, client: APIKeyFeatureClient
    ) {
        state.activeListRequestID = nil
        state.activeCreateRequestID = nil
        state.activeRevokeRequestID = nil
        state.hasLoaded = false
        state.sessionExpired = false
        state.keys = []
        state.listPhase = .idle
        state.listNotice = nil
        state.isCreatePresented = false
        resetCreateDraft(&state, client: client)
        state.revokeTarget = nil
        state.revokingKeyID = nil
        state.revokeState = .idle
    }

    private static func resetCreateDraft(
        _ state: inout State, client: APIKeyFeatureClient
    ) {
        clearOwnedClipboardSecret(&state, client: client)
        state.activeCreateRequestID = nil
        resetCreateDraftFields(&state)
    }

    private static func resetCreateDraftFields(_ state: inout State) {
        state.draftName = ""
        state.draftScope = .read
        state.draftExpiry = .default
        state.hasAttemptedCreate = false
        state.createState = .editing
        state.createdKey = nil
        state.isSecretObscured = false
        state.copyState = .idle
        state.uncertainMetadataRefreshFailed = false
        state.isUncertainRefresh = false
    }

    private static func clearOwnedClipboardSecret(
        _ state: inout State, client: APIKeyFeatureClient
    ) {
        guard let receipt = state.clipboardReceipt else { return }
        state.clipboardReceipt = nil
        client.clearSecret(receipt)
    }

    private static func message(for error: APIKeyServiceError) -> String {
        switch error {
        case .unauthorized: return String(localized: "diary.error.sessionExpired")
        case .networkUnavailable: return String(localized: "apiKeys.error.network")
        case .timedOut: return String(localized: "apiKeys.error.timeout")
        case .cancelled: return String(localized: "apiKeys.error.cancelled")
        case .rateLimited: return String(localized: "apiKeys.error.rateLimited")
        case .limitReached: return String(localized: "apiKeys.limit.message")
        case .notFound: return String(localized: "apiKeys.error.notFound")
        case .rejected(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "apiKeys.error.rejected") : trimmed
        case .server: return String(localized: "apiKeys.error.server")
        case .invalidResponse: return String(localized: "apiKeys.error.invalidResponse")
        case .unknown: return String(localized: "apiKeys.error.unknown")
        }
    }
}
