// Account Settings / personal API keys.
//
// A newly created secret lives only in this in-memory view model until the user
// finishes the reveal. It is never written to defaults, files, or diagnostics.
// An ambiguous create refreshes metadata and requires the user to leave the
// form before another create can be attempted.

import Combine
import Foundation

public enum APIKeyListState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

public enum APIKeyCreateState: Equatable, Sendable {
    case editing
    case submitting
    case failed(String)
    case uncertain(String)
    case created
}

public enum APIKeyCopyState: Equatable, Sendable {
    case idle
    case copied
    case failed
}

public enum APIKeyRevokeState: Equatable, Sendable {
    case idle
    case revoking
    case failed(String)
}

@MainActor
public final class AccountSettingsViewModel: ObservableObject, Identifiable {
    public let id = UUID()
    public private(set) var accountID: String

    @Published public private(set) var keys: [APIKey] = []
    @Published public private(set) var listState: APIKeyListState = .loading
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var listNotice: String?

    @Published public private(set) var isCreatePresented = false
    @Published public var draftName = "" {
        didSet { draftDidChange(from: oldValue, to: draftName) }
    }
    @Published public var draftScope: APIKeyCreatableScope = .read {
        didSet { if draftScope != oldValue { clearDefinitiveCreateError() } }
    }
    @Published public var draftExpiry: APIKeyExpiryChoice = .default {
        didSet { if draftExpiry != oldValue { clearDefinitiveCreateError() } }
    }
    @Published public private(set) var createState: APIKeyCreateState = .editing
    @Published public private(set) var createdKey: CreatedAPIKey?
    @Published public private(set) var isSecretObscured = false
    @Published public private(set) var copyState: APIKeyCopyState = .idle
    @Published public private(set) var uncertainMetadataRefreshFailed = false

    /// Durable, non-secret record for a create whose outcome is unknown.
    @Published public private(set) var pendingCreateIntent: APIKeyCreateIntent?
    @Published public private(set) var potentialOrphanKeys: [APIKey] = []
    @Published public private(set) var createIntentErrorMessage: String?
    @Published public private(set) var createIntentRecoveryIdentity: APIKeyCreateIntentFileIdentity?
    @Published public private(set) var isResetIntentConfirmationPresented = false

    @Published public private(set) var revokeTarget: APIKey?
    @Published public private(set) var revokingKeyID: String?
    @Published public private(set) var revokeState: APIKeyRevokeState = .idle

    public var onSessionExpired: (() -> Void)?

    public let service: any APIKeyServicing
    private let clipboard: any APIKeySecretCopying
    private let intentStore: any APIKeyCreateIntentStoring
    private let nowProvider: () -> Date

    private var hasLoaded = false
    private var hasAttemptedCreate = false
    private var sessionExpired = false
    private var isSceneActive = true
    private var clipboardReceipt: APIKeyClipboardReceipt?
    private var hasFreshInterruptedMetadata = false

    private var listRequestID = 0
    private var createRequestID = 0
    private var revokeRequestID = 0

    public static let maximumActiveKeys = 10

    public init(
        service: any APIKeyServicing,
        accountID: String,
        clipboard: any APIKeySecretCopying = SystemAPIKeySecretClipboard(),
        nowProvider: @escaping () -> Date = { Date() },
        intentStore: any APIKeyCreateIntentStoring = APIKeyCreateIntentStore.shared
    ) {
        self.service = service
        self.accountID = accountID
        self.clipboard = clipboard
        self.nowProvider = nowProvider
        self.intentStore = intentStore
    }

    // MARK: - Inspection

    public var now: Date { nowProvider() }

    public var activeKeyCount: Int {
        keys.filter { !$0.isExpired(at: now) }.count
    }

    public var isMetadataReady: Bool {
        listState == .loaded
    }

    public var hasReachedActiveKeyLimit: Bool {
        activeKeyCount >= Self.maximumActiveKeys
    }

    /// A persisted or in-memory interrupted create must be explicitly
    /// acknowledged or its possible orphan revoked before a new POST.
    public var hasUnresolvedCreateIntent: Bool {
        pendingCreateIntent != nil || createIntentErrorMessage != nil
    }

    public var isCreateBlocked: Bool {
        hasUnresolvedCreateIntent || hasReachedActiveKeyLimit
    }

    public var canResetUnreadableCreateIntent: Bool {
        createIntentRecoveryIdentity != nil
            && hasFreshInterruptedMetadata
            && listState == .loaded
            && !sessionExpired
            && !isBusy
    }

    public var isLoadingFirstPage: Bool {
        listState == .loading
    }

    public var isSessionExpired: Bool { sessionExpired }

    public var isRevoking: Bool {
        revokingKeyID != nil
    }

    public var isBusy: Bool {
        createState == .submitting || isRevoking
    }

    public var listErrorMessage: String? {
        if case .failed(let message) = listState { return message }
        return nil
    }

    public var revokeErrorMessage: String? {
        if case .failed(let message) = revokeState { return message }
        return nil
    }

    public var createErrorMessage: String? {
        if case .failed(let message) = createState { return message }
        return nil
    }

    public var createUncertainMessage: String? {
        if case .uncertain(let message) = createState { return message }
        return nil
    }

    public var isCreateFormEnabled: Bool {
        guard isCreatePresented,
              createdKey == nil,
              !sessionExpired,
              !hasUnresolvedCreateIntent else {
            return false
        }
        switch createState {
        case .submitting, .uncertain, .created:
            return false
        case .editing, .failed:
            return true
        }
    }

    public var isCreateSubmitDisabled: Bool {
        guard isCreateFormEnabled else { return true }
        return hasReachedActiveKeyLimit
    }

    public var nameValidationMessage: String? {
        guard hasAttemptedCreate || !draftName.isEmpty else { return nil }
        switch APIKeyNameValidator.validatedName(from: draftName) {
        case .success:
            return nil
        case .failure(.required):
            return String(localized: "apiKeys.create.name.required")
        case .failure(.tooLong):
            return String(localized: "apiKeys.create.name.tooLong")
        case .failure(.invalidCharacters):
            return String(localized: "apiKeys.create.name.invalid")
        }
    }

    public var isSecretRevealed: Bool {
        createdKey != nil && !isSecretObscured
    }

    public var canCopySecret: Bool {
        createdKey != nil && !isSecretObscured
    }

    // MARK: - Loading

    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    public func load() async {
        guard !sessionExpired else { return }
        restoreCreateIntent()
        hasFreshInterruptedMetadata = false
        let requestID = nextListRequestID()
        let hadKeys = !keys.isEmpty
        if hadKeys {
            isRefreshing = true
        } else {
            listState = .loading
        }

        do {
            let fetched = try await service.listAPIKeys()
            guard requestID == listRequestID, !sessionExpired else { return }
            keys = fetched
            listState = .loaded
            isRefreshing = false
            listNotice = nil
            refreshPotentialOrphanKeys()
            hasFreshInterruptedMetadata = hasUnresolvedCreateIntent
            if let target = revokeTarget,
               !fetched.contains(where: { $0.id == target.id }) {
                revokeTarget = nil
            }
        } catch {
            guard requestID == listRequestID, !sessionExpired else { return }
            isRefreshing = false
            hasFreshInterruptedMetadata = false
            let serviceError = Self.serviceError(from: error)
            if serviceError.isUnauthorized {
                expireSession()
                return
            }
            let message = Self.message(for: serviceError)
            if hadKeys {
                listState = .loaded
                listNotice = message
            } else {
                listState = .failed(message)
            }
        }
    }

    // MARK: - Create

    public func presentCreateForm() {
        guard !sessionExpired, !isBusy, createdKey == nil else { return }
        guard !hasUnresolvedCreateIntent else { return }
        guard listState == .loaded else { return }
        guard !hasReachedActiveKeyLimit else {
            listNotice = String(localized: "apiKeys.limit.message")
            return
        }
        resetCreateDraft()
        isCreatePresented = true
    }

    /// The form's Cancel action. The one-time reveal cannot be cancelled; its
    /// only exit is Done.
    public func cancelCreateForm() {
        guard createState != .submitting, createdKey == nil else { return }
        resetCreateDraft()
        isCreatePresented = false
    }

    /// Called when the create sheet disappears for a system reason. If a
    /// request was still in flight, invalidate its completion so a late
    /// response cannot repopulate the secret UI.
    public func createSheetDidDisappear() {
        guard isCreatePresented else { return }
        resetCreateDraft()
        isCreatePresented = false
    }

    public func submitCreate() async {
        guard isCreateFormEnabled,
              !hasReachedActiveKeyLimit,
              !hasUnresolvedCreateIntent,
              !sessionExpired,
              listState == .loaded else {
            return
        }
        hasAttemptedCreate = true
        guard case .success(let name) = APIKeyNameValidator.validatedName(
            from: draftName
        ) else {
            return
        }

        // The non-secret intent must be durable before the non-idempotent POST.
        // If this write fails, or another window already owns an unresolved
        // intent, no request is sent.
        let intent = APIKeyCreateIntent(
            accountID: accountID,
            name: name,
            scope: draftScope,
            expiresInDays: draftExpiry.expiresInDays,
            startedAt: nowProvider(),
            baselineKeyIDs: keys.map(\.id)
        )
        do {
            try intentStore.saveIfAbsent(intent)
        } catch {
            restoreCreateIntent()
            if let storeError = error as? APIKeyCreateIntentStoreError,
               storeError == .alreadyPending {
                createState = .failed(Self.intentPendingMessage)
            } else {
                createState = .failed(Self.intentPersistenceMessage)
            }
            return
        }
        pendingCreateIntent = intent
        refreshPotentialOrphanKeys()

        let request = APIKeyCreateRequest(
            name: name,
            scope: draftScope,
            expiresInDays: draftExpiry.expiresInDays
        )
        let requestID = nextCreateRequestID()
        createState = .submitting
        copyState = .idle

        do {
            let created = try await service.createAPIKey(request)
            guard requestID == createRequestID,
                  !sessionExpired,
                  accountID == intent.accountID else {
                return
            }
            createdKey = created
            // A response can land while the app is inactive. Never reveal a
            // freshly minted secret without an active, deliberate reveal.
            isSecretObscured = !isSceneActive
            copyState = .idle
            createState = .created
            if let index = keys.firstIndex(where: { $0.id == created.key.id }) {
                keys[index] = created.key
            } else {
                keys.insert(created.key, at: 0)
            }
            listState = .loaded
            listNotice = nil
            // The secret is now in hand. Clear the non-secret intent, but never
            // clear it for a stale session/account response.
            clearResolvedCreateIntent(intent, excluding: created.key.id)
        } catch {
            let serviceError = Self.serviceError(from: error)
            if serviceError.isDefinitiveCreateFailure {
                // The server definitely did not commit this create.
                clearResolvedCreateIntent(intent)
            }
            guard requestID == createRequestID,
                  !sessionExpired,
                  accountID == intent.accountID else {
                return
            }
            if serviceError.isUnauthorized {
                expireSession()
                return
            }

            if serviceError.isAmbiguousCreateFailure {
                // The request may have committed. Refresh metadata and block
                // resubmission in this form; do not issue another POST.
                createState = .uncertain(
                    String(localized: "apiKeys.create.uncertain.message")
                )
                uncertainMetadataRefreshFailed = false
                await refreshMetadataForUncertainCreate()
            } else {
                createState = .failed(Self.message(for: serviceError))
            }
        }
    }

    /// Explicit metadata refresh after an uncertain create. This intentionally
    /// calls only GET /api/auth/api-keys.
    public func refreshMetadataForUncertainCreate() async {
        guard case .uncertain = createState, !sessionExpired else { return }
        uncertainMetadataRefreshFailed = false
        await load()
        guard case .uncertain = createState, !sessionExpired else { return }
        uncertainMetadataRefreshFailed = listNotice != nil || listErrorMessage != nil
    }

    /// Re-read the list and recalculate possible orphans without retrying POST.
    public func refreshInterruptedCreateMetadata() async {
        guard hasUnresolvedCreateIntent else { return }
        await load()
    }

    /// User reviewed the list and accepted that a possible key cannot be
    /// recovered. CAS protects against clearing a newer intent from another
    /// window.
    public func acknowledgeInterruptedCreate() async {
        guard let intent = pendingCreateIntent,
              intent.accountID == accountID else { return }
        do {
            try intentStore.clear(
                accountID: intent.accountID,
                revision: intent.revision
            )
            if pendingCreateIntent?.revision == intent.revision {
                pendingCreateIntent = nil
                potentialOrphanKeys = []
            }
            createIntentErrorMessage = nil
            createIntentRecoveryIdentity = nil
            hasFreshInterruptedMetadata = false
        } catch {
            restoreCreateIntent()
            createIntentErrorMessage = Self.intentPersistenceMessage
        }
    }

    /// Opens the explicit destructive confirmation. Metadata must have been
    /// refreshed successfully in this review session first.
    public func requestResetUnreadableCreateIntent() {
        guard canResetUnreadableCreateIntent else { return }
        isResetIntentConfirmationPresented = true
    }

    public func cancelResetUnreadableCreateIntent() {
        isResetIntentConfirmationPresented = false
    }

    /// Removes only the quarantined record whose identity the user reviewed.
    /// A newer valid intent changes the file identity and rejects this reset.
    public func confirmResetUnreadableCreateIntent() async {
        guard let identity = createIntentRecoveryIdentity,
              identity.accountID == accountID,
              canResetUnreadableCreateIntent else {
            isResetIntentConfirmationPresented = false
            return
        }
        isResetIntentConfirmationPresented = false
        do {
            try intentStore.resetUnreadable(
                accountID: identity.accountID,
                expectedIdentity: identity
            )
            createIntentRecoveryIdentity = nil
            createIntentErrorMessage = nil
            pendingCreateIntent = nil
            potentialOrphanKeys = []
            hasFreshInterruptedMetadata = false
        } catch {
            let stale = (error as? APIKeyCreateIntentStoreError) == .staleReset
            restoreCreateIntent()
            if stale {
                listNotice = Self.intentResetStaleMessage
            } else {
                createIntentErrorMessage = Self.intentResetFailedMessage
            }
        }
    }

    public func finishSecretReveal() {
        guard createdKey != nil else { return }
        resetCreateDraft()
        isCreatePresented = false
    }

    public func hideSecret() {
        guard createdKey != nil else { return }
        isSecretObscured = true
    }

    public func revealSecret() {
        guard createdKey != nil, isSceneActive else { return }
        isSecretObscured = false
        copyState = .idle
    }

    public func copySecret() {
        guard let secret = createdKey?.secret, canCopySecret else { return }
        // Deliberate user action only. No automatic copy on create.
        let receipt = clipboard.copySecretToClipboard(secret.value)
        clipboardReceipt = receipt
        copyState = receipt == nil ? .failed : .copied
    }

    public func scenePhaseChanged(isActive: Bool) {
        isSceneActive = isActive
        guard !isActive, createdKey != nil else { return }
        isSecretObscured = true
        copyState = .idle
    }

    // MARK: - Revoke

    public func requestRevoke(_ key: APIKey) {
        guard !sessionExpired,
              !isCreatePresented,
              !isBusy,
              revokeTarget == nil else { return }
        revokeState = .idle
        revokeTarget = key
    }

    public func cancelRevoke() {
        guard revokingKeyID == nil else { return }
        revokeTarget = nil
        revokeState = .idle
    }

    public func confirmRevoke(_ explicitKey: APIKey? = nil) async {
        guard let target = explicitKey ?? revokeTarget,
              revokingKeyID == nil,
              !sessionExpired else {
            return
        }
        let requestID = nextRevokeRequestID()
        revokeTarget = nil
        revokingKeyID = target.id
        revokeState = .revoking

        do {
            try await service.revokeAPIKey(id: target.id)
            guard requestID == revokeRequestID, !sessionExpired else { return }
            let wasPotentialOrphan = potentialOrphanKeys.contains { $0.id == target.id }
            keys.removeAll { $0.id == target.id }
            listNotice = nil
            revokingKeyID = nil
            revokeState = .idle
            if pendingCreateIntent != nil {
                refreshPotentialOrphanKeys()
                if wasPotentialOrphan, potentialOrphanKeys.isEmpty {
                    // Revoking the last possible orphan resolves the warning.
                    await acknowledgeInterruptedCreate()
                }
            }
        } catch {
            guard requestID == revokeRequestID, !sessionExpired else { return }
            let serviceError = Self.serviceError(from: error)
            revokingKeyID = nil
            if serviceError.isUnauthorized {
                expireSession()
                return
            }
            revokeState = .failed(Self.message(for: serviceError))
        }
    }

    // MARK: - Session / account lifetime

    public func accountDidChange(to newAccountID: String) {
        guard newAccountID != accountID else { return }
        accountID = newAccountID
        clearSessionScopedState()
    }

    public func clearForSignOut() {
        clearSessionScopedState()
    }

    /// Clear any secret before the owning presentation is demolished.
    public func clearSensitiveStateOnDismissal() {
        clearOwnedClipboardSecret()
        guard createdKey != nil || clipboardReceipt != nil else { return }
        createdKey = nil
        isSecretObscured = false
        copyState = .idle
        uncertainMetadataRefreshFailed = false
        createState = .editing
        createRequestID += 1
    }

    public func shutdown() {
        clearSessionScopedState()
    }

    private func clearSessionScopedState() {
        listRequestID += 1
        createRequestID += 1
        revokeRequestID += 1
        hasLoaded = false
        sessionExpired = false
        keys = []
        listState = .loading
        isRefreshing = false
        listNotice = nil
        isCreatePresented = false
        resetCreateDraft()
        pendingCreateIntent = nil
        potentialOrphanKeys = []
        createIntentErrorMessage = nil
        createIntentRecoveryIdentity = nil
        isResetIntentConfirmationPresented = false
        hasFreshInterruptedMetadata = false
        revokeTarget = nil
        revokingKeyID = nil
        revokeState = .idle
    }

    private func expireSession() {
        guard !sessionExpired else { return }
        sessionExpired = true
        listRequestID += 1
        createRequestID += 1
        revokeRequestID += 1
        let message = String(localized: "diary.error.sessionExpired")
        keys = []
        listState = .failed(message)
        isRefreshing = false
        listNotice = nil
        isCreatePresented = false
        resetCreateDraft()
        pendingCreateIntent = nil
        potentialOrphanKeys = []
        createIntentErrorMessage = nil
        createIntentRecoveryIdentity = nil
        isResetIntentConfirmationPresented = false
        hasFreshInterruptedMetadata = false
        revokeTarget = nil
        revokingKeyID = nil
        revokeState = .idle
        onSessionExpired?()
    }

    // MARK: - Draft helpers

    private func resetCreateDraft() {
        clearOwnedClipboardSecret()
        createRequestID += 1
        draftName = ""
        draftScope = .read
        draftExpiry = .default
        hasAttemptedCreate = false
        createState = .editing
        createdKey = nil
        isSecretObscured = false
        copyState = .idle
        uncertainMetadataRefreshFailed = false
    }

    private func draftDidChange(from oldValue: String, to newValue: String) {
        guard oldValue != newValue else { return }
        clearDefinitiveCreateError()
    }

    private func clearDefinitiveCreateError() {
        guard case .failed = createState else { return }
        createState = .editing
    }

    // MARK: - Durable create-intent lifecycle

    private func restoreCreateIntent() {
        do {
            let intent = try intentStore.load(accountID: accountID)
            pendingCreateIntent = intent
            createIntentErrorMessage = nil
            createIntentRecoveryIdentity = nil
            refreshPotentialOrphanKeys()
        } catch {
            // Fail closed. Keep an in-memory intent if this window already
            // knew about one; never treat an unreadable record as absent.
            if let storeError = error as? APIKeyCreateIntentStoreError,
               case .unreadable(let identity) = storeError {
                createIntentRecoveryIdentity = identity
                createIntentErrorMessage = Self.intentUnreadableMessage
            } else {
                createIntentRecoveryIdentity = nil
                createIntentErrorMessage = Self.intentPersistenceMessage
            }
            if pendingCreateIntent == nil {
                potentialOrphanKeys = []
            }
        }
    }

    private func refreshPotentialOrphanKeys() {
        guard let intent = pendingCreateIntent,
              intent.accountID == accountID else {
            potentialOrphanKeys = []
            return
        }
        potentialOrphanKeys = intent.potentialOrphanKeys(from: keys)
    }

    /// Clears the non-secret intent only after a definitive result or a
    /// successful secret handoff in the current account/session.
    private func clearResolvedCreateIntent(
        _ intent: APIKeyCreateIntent,
        excluding handedOffKeyID: String? = nil
    ) {
        do {
            try intentStore.clear(
                accountID: intent.accountID,
                revision: intent.revision
            )
            if pendingCreateIntent?.revision == intent.revision {
                pendingCreateIntent = nil
                potentialOrphanKeys = []
            }
            createIntentErrorMessage = nil
            createIntentRecoveryIdentity = nil
            isResetIntentConfirmationPresented = false
            hasFreshInterruptedMetadata = false
        } catch {
            restoreCreateIntent()
            createIntentErrorMessage = Self.intentPersistenceMessage
            if let handedOffKeyID {
                potentialOrphanKeys.removeAll { $0.id == handedOffKeyID }
            }
        }
    }

    private func clearOwnedClipboardSecret() {
        guard let receipt = clipboardReceipt else { return }
        clipboardReceipt = nil
        clipboard.clearSecretFromClipboard(receipt)
    }

    // MARK: - Tokens

    private func nextListRequestID() -> Int {
        listRequestID += 1
        return listRequestID
    }

    private func nextCreateRequestID() -> Int {
        createRequestID += 1
        return createRequestID
    }

    private func nextRevokeRequestID() -> Int {
        revokeRequestID += 1
        return revokeRequestID
    }

    // MARK: - Error text

    private static func serviceError(from error: Error) -> APIKeyServiceError {
        (error as? APIKeyServiceError) ?? .unknown
    }

    private static func message(for error: APIKeyServiceError) -> String {
        switch error {
        case .unauthorized:
            return String(localized: "diary.error.sessionExpired")
        case .networkUnavailable:
            return String(localized: "apiKeys.error.network")
        case .timedOut:
            return String(localized: "apiKeys.error.timeout")
        case .cancelled:
            return String(localized: "apiKeys.error.cancelled")
        case .rateLimited:
            return String(localized: "apiKeys.error.rateLimited")
        case .limitReached:
            return String(localized: "apiKeys.limit.message")
        case .notFound:
            return String(localized: "apiKeys.error.notFound")
        case .rejected(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(localized: "apiKeys.error.rejected")
                : trimmed
        case .server:
            return String(localized: "apiKeys.error.server")
        case .invalidResponse:
            return String(localized: "apiKeys.error.invalidResponse")
        case .unknown:
            return String(localized: "apiKeys.error.unknown")
        }
    }

    private static var intentPersistenceMessage: String {
        String(
            localized: "apiKeys.intent.persistence",
            defaultValue: "The API-key safety record could not be saved or read. Key creation is disabled until it is resolved."
        )
    }

    private static var intentPendingMessage: String {
        String(
            localized: "apiKeys.intent.pending",
            defaultValue: "Another window has an unresolved API-key creation. Review it before creating another key."
        )
    }

    private static var intentUnreadableMessage: String {
        String(
            localized: "apiKeys.intent.unreadable",
            defaultValue: "The API-key safety record is unreadable. Key creation stays disabled. Review the key list for a possible orphan, then reset the safety record only if you accept that a key may exist without a recoverable secret."
        )
    }

    private static var intentResetStaleMessage: String {
        String(
            localized: "apiKeys.intent.reset.stale",
            defaultValue: "The safety record changed in another window. Review the refreshed warning before resetting."
        )
    }

    private static var intentResetFailedMessage: String {
        String(
            localized: "apiKeys.intent.reset.failed",
            defaultValue: "The unreadable safety record could not be reset. Try again."
        )
    }
}
