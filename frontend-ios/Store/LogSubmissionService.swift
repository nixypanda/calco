// Shared typed submission path for quick-add, batch review, and repeat-latest.
// The journal is reserved before every send; retries replay the stored bytes.

import Foundation

public typealias LogSubmissionHandler = (
    _ drafts: [LogSubmissionDraft],
    _ itemNames: [String],
    _ summary: String,
    _ completion: @escaping (LogSubmissionServiceResult) -> Void
) -> Void

public struct LogSubmissionSendResult: Equatable, Sendable {
    public let logs: [FoodLog]
    public let statusCode: Int

    public init(logs: [FoodLog], statusCode: Int) {
        self.logs = logs
        self.statusCode = statusCode
    }
}

public protocol LogSubmissionSending: Sendable {
    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult
    /// Account-bound send used by the shared journal. The default preserves
    /// legacy/offline test doubles that do not perform HTTP.
    func send(
        _ request: LogSubmissionRequest,
        expectedAccountID: String
    ) async throws -> LogSubmissionSendResult
}

public extension LogSubmissionSending {
    func send(
        _ request: LogSubmissionRequest,
        expectedAccountID: String
    ) async throws -> LogSubmissionSendResult {
        try await send(request)
    }
}

public enum LogSubmissionSendError: Error, Equatable, Sendable {
    case unauthorized
    case failed(String)
    case uncertain(String)
    case conflict(String)
    case rateLimited(retryAfterSeconds: Int?)
    /// A meal contains unavailable products. This is a definitive rejection,
    /// not an idempotency-key conflict.
    case missingComponents(String)
    /// The stored request belongs to a different API origin. It was not sent.
    case serverChanged(String)
}

public struct CalCoLogSubmissionSender: LogSubmissionSending {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        try await send(
            request,
            expectedAccountID: client.expectedAccountID ?? ""
        )
    }

    public func send(
        _ request: LogSubmissionRequest,
        expectedAccountID: String
    ) async throws -> LogSubmissionSendResult {
        if let expected = request.baseURLString,
           expected != client.configuration.baseURL.absoluteString {
            throw LogSubmissionSendError.serverChanged(
                String(localized: "foodDetail.error.differentServer")
            )
        }
        // Logging is never allowed to fall back to an ambient cookie when the
        // per-action account binding is missing. Keep the journal bytes for
        // recovery instead of sending an unbound write.
        let requestAccountID = expectedAccountID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !requestAccountID.isEmpty else {
            throw LogSubmissionSendError.uncertain(
                String(localized: "foodDetail.error.sessionExpired")
            )
        }
        do {
            let (logs, status) = try await client.createSubmissionRaw(
                request,
                expectedAccountID: requestAccountID
            )
            return LogSubmissionSendResult(logs: logs, statusCode: status)
        } catch let error as CalCoAPIError {
            throw Self.map(error)
        } catch {
            throw LogSubmissionSendError.uncertain(error.localizedDescription)
        }
    }

    public static func map(_ error: CalCoAPIError) -> LogSubmissionSendError {
        switch error {
        case .unauthorized:
            if error.isSessionAccountChanged {
                return .uncertain(
                    Self.message(for: error)
                )
            }
            return .unauthorized
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfterSeconds: retryAfter)
        case .timeout, .network, .invalidResponse, .decoding, .cancelled:
            return .uncertain(Self.message(for: error))
        case .badStatus(let status, _) where status == 409:
            if error.payload?.code == "missing_components" {
                return .missingComponents(Self.message(for: error))
            }
            return .conflict(Self.message(for: error))
        case .badStatus(let status, _)
            where status == 408 || status == 429 || (300..<400).contains(status)
                || (500..<600).contains(status):
            return .uncertain(Self.message(for: error))
        case .badStatus(let status, _) where (400..<500).contains(status):
            return .failed(Self.message(for: error))
        case .badStatus(_, _), .invalidURL, .encoding:
            return .failed(Self.message(for: error))
        }
    }

    private static func message(for error: CalCoAPIError) -> String {
        let generic = String(localized: "foodDetail.error.saveFailed")
        let message = error.payload?.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }
        switch error {
        case .timeout:
            return String(localized: "foodDetail.error.uncertain")
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .rateLimited:
            return String(localized: "foodDetail.error.rateLimited")
        default:
            return generic
        }
    }
}

public enum LogSubmissionServiceFailure: Error, Equatable, Sendable {
    case unauthorized
    case rejected(String)
    case uncertain(String)
    case conflict(String)
    case missingComponents(String)
    case serverChanged(String)
    case reconciliationOnly(String)
    case capabilityUnavailable(String)
    case capabilityTemporarilyUnavailable(String)
    case journalUnavailable(String)

    public var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .rejected(let message), .uncertain(let message), .conflict(let message),
             .missingComponents(let message), .serverChanged(let message),
             .reconciliationOnly(let message), .capabilityUnavailable(let message),
             .capabilityTemporarilyUnavailable(let message):
            return message
        case .journalUnavailable:
            return String(localized: "foodDetail.error.journalUnavailable")
        }
    }

    public var isTemporaryCapabilityFailure: Bool {
        if case .capabilityTemporarilyUnavailable = self { return true }
        return false
    }
}

public enum LogSubmissionServiceResult: Equatable, Sendable {
    case success(logs: [FoodLog], replayed: Bool)
    case failure(LogSubmissionServiceFailure)

    public var createdLogs: [FoodLog] {
        guard case .success(let logs, _) = self else { return [] }
        return logs
    }
}

/// Immutable account/generation/origin captured for one submission action.
/// Every await boundary must revalidate the same value before reserving,
/// sending, or publishing a result.
public struct LogSubmissionSessionContext: Equatable, Sendable {
    /// Journal/account scope. Existing local operations use the authenticated
    /// identity ID here.
    public let accountID: String
    public let generation: UInt64
    public let baseURL: URL
    /// Backend user-profile UUID required by `X-CalCo-Account-ID`.
    public let profileID: String?

    public init(
        accountID: String,
        generation: UInt64,
        baseURL: URL,
        profileID: String? = nil
    ) {
        self.accountID = accountID
        self.generation = generation
        self.baseURL = baseURL
        self.profileID = profileID
    }

    public var requestAccountID: String {
        guard let profileID else { return accountID }
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? accountID : trimmed
    }
}

public typealias LogSubmissionSessionContextProvider =
    @MainActor () -> LogSubmissionSessionContext?

@MainActor
public final class LogSubmissionService {
    private enum CapabilityStatus {
        case ready(LogCreationIdempotencyCapability)
        case unsupported(String)
        case transient(String)
    }

    public let store: LogSubmissionStore
    private let sender: any LogSubmissionSending
    private let capabilityProvider: (any LogCreationCapabilityProviding)?
    private let now: () -> Date
    private let sessionContextProvider: LogSubmissionSessionContextProvider?
    private var capabilityAccountID: String?
    private var capabilityBaseURL: URL?
    private var capabilityStatus: CapabilityStatus?
    private var capabilityRequestToken: UInt64 = 0
    private var capabilityGeneration: UInt64?
    /// Immutable generation-to-account binding. A generation high-water mark
    /// prevents a stale task from rebinding the same generation to another
    /// account after a session switch.
    private var generationAccounts: [UInt64: String] = [:]
    private var generationFloor: UInt64 = 0

    public init(
        store: LogSubmissionStore,
        sender: any LogSubmissionSending,
        capabilityProvider: (any LogCreationCapabilityProviding)? = nil,
        now: @escaping () -> Date = Date.init,
        sessionContextProvider: LogSubmissionSessionContextProvider? = nil
    ) {
        self.store = store
        self.sender = sender
        self.capabilityProvider = capabilityProvider
        self.now = now
        self.sessionContextProvider = sessionContextProvider
    }

    public func invalidateCapability(generation: UInt64? = nil) {
        capabilityRequestToken &+= 1
        if let generation {
            generationFloor = max(generationFloor, generation)
            capabilityGeneration = generation
        } else {
            capabilityGeneration = nil
        }
        clearCapabilityState()
    }

    private func clearCapabilityState() {
        capabilityAccountID = nil
        capabilityBaseURL = nil
        capabilityStatus = nil
    }

    public func isCapabilityReady(
        accountID: String,
        route: LogSubmissionRoute
    ) -> Bool {
        capabilityFailure(accountID: accountID, route: route) == nil
    }

    /// Binds a generation to exactly one account. A generation that was already
    /// used by another account can never be rebound, even if the caller passes
    /// it again with a different account.
    private func bindGeneration(
        accountID: String,
        generation: UInt64?
    ) -> UInt64? {
        if let generation {
            guard generation >= generationFloor else { return nil }
            if let current = capabilityGeneration, generation < current {
                return nil
            }
            if let existing = generationAccounts[generation], existing != accountID {
                return nil
            }
            generationAccounts[generation] = accountID
            capabilityGeneration = generation
            return generation
        }
        if let current = capabilityGeneration {
            guard generationAccounts[current] == accountID else { return nil }
            return current
        }
        guard generationFloor == 0 else { return nil }
        if let existing = generationAccounts[0], existing != accountID {
            return nil
        }
        generationAccounts[0] = accountID
        capabilityGeneration = 0
        return 0
    }

    public func refreshCapability(
        accountID: String,
        generation: UInt64? = nil,
        expectedAccountID: String? = nil
    ) async -> Bool {
        guard let capabilityProvider else {
            invalidateCapability()
            return false
        }
        guard let boundGeneration = bindGeneration(
            accountID: accountID,
            generation: generation
        ) else {
            return false
        }
        let expectedBaseURL = capabilityProvider.baseURL
        let requestAccountID: String
        if let expectedAccountID,
           !expectedAccountID.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            requestAccountID = expectedAccountID
        } else if let current = currentRequestAccountID(
            accountID: accountID,
            generation: boundGeneration
        ) {
            requestAccountID = current
        } else {
            capabilityAccountID = accountID
            capabilityBaseURL = expectedBaseURL
            capabilityStatus = .unsupported(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
            return false
        }
        capabilityRequestToken &+= 1
        let token = capabilityRequestToken
        clearCapabilityState()
        do {
            let fetched = try await capabilityProvider.fetchCapabilities(
                expectedAccountID: requestAccountID
            )
            guard token == capabilityRequestToken,
                  capabilityGeneration == boundGeneration,
                  generationAccounts[boundGeneration] == accountID else {
                return false
            }
            guard capabilityProvider.baseURL == expectedBaseURL else {
                capabilityAccountID = accountID
                capabilityBaseURL = expectedBaseURL
                capabilityStatus = .unsupported(
                    String(localized: "foodDetail.error.capabilityUnavailable")
                )
                return false
            }
            capabilityAccountID = accountID
            capabilityBaseURL = expectedBaseURL
            if fetched.supportsRequestAccountBinding {
                capabilityStatus = .ready(fetched)
                return true
            }
            capabilityStatus = .unsupported(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
            return false
        } catch let error as CalCoAPIError {
            guard token == capabilityRequestToken,
                  capabilityGeneration == boundGeneration,
                  generationAccounts[boundGeneration] == accountID else {
                return false
            }
            capabilityAccountID = accountID
            capabilityBaseURL = expectedBaseURL
            switch error {
            case .badStatus(let status, _) where status == 503 || (500..<600).contains(status):
                capabilityStatus = .transient(
                    String(localized: "foodDetail.error.capabilityTemporarilyUnavailable")
                )
            case .timeout, .network, .invalidResponse, .cancelled:
                capabilityStatus = .transient(
                    String(localized: "foodDetail.error.capabilityTemporarilyUnavailable")
                )
            case .badStatus(let status, _) where status == 404:
                capabilityStatus = .unsupported(
                    String(localized: "foodDetail.error.capabilityUnavailable")
                )
            default:
                capabilityStatus = .unsupported(
                    String(localized: "foodDetail.error.capabilityUnavailable")
                )
            }
            return false
        } catch {
            guard token == capabilityRequestToken,
                  capabilityGeneration == boundGeneration,
                  generationAccounts[boundGeneration] == accountID else {
                return false
            }
            capabilityAccountID = accountID
            capabilityBaseURL = expectedBaseURL
            capabilityStatus = .transient(
                String(localized: "foodDetail.error.capabilityTemporarilyUnavailable")
            )
            return false
        }
    }

    private func capabilityFailure(
        accountID: String,
        route: LogSubmissionRoute
    ) -> LogSubmissionServiceFailure? {
        guard let capabilityProvider,
              capabilityAccountID == accountID,
              capabilityBaseURL == capabilityProvider.baseURL,
              let generation = capabilityGeneration,
              generationAccounts[generation] == accountID else {
            return .capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
        }
        switch capabilityStatus {
        case .ready(let capability) where capability.supports(route):
            return nil
        case .ready:
            return .capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
        case .transient(let message):
            return .capabilityTemporarilyUnavailable(message)
        case .unsupported(let message):
            return .capabilityUnavailable(message)
        case nil:
            return .capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
        }
    }

    private func capabilityVersion(
        for route: LogSubmissionRoute,
        accountID: String
    ) -> Int? {
        guard let capabilityProvider,
              capabilityBaseURL == capabilityProvider.baseURL,
              capabilityAccountID == accountID,
              let generation = capabilityGeneration,
              generationAccounts[generation] == accountID,
              case .ready(let capability)? = capabilityStatus,
              capability.supports(route) else {
            return nil
        }
        return capability.version
    }

    /// Immutable context for one action. In production the provider is the
    /// shared session authority; tests may use the explicit generation binding.
    private func captureContext(
        accountID: String,
        generation: UInt64?
    ) -> LogSubmissionSessionContext? {
        if let sessionContextProvider {
            guard let current = sessionContextProvider(),
                  current.accountID == accountID,
                  current.baseURL == capabilityProvider?.baseURL else {
                return nil
            }
            if let generation, current.generation != generation {
                return nil
            }
            return current
        }
        let effective: UInt64
        if let generation {
            effective = generation
        } else if let current = capabilityGeneration {
            effective = current
        } else {
            effective = 0
        }
        guard effective >= generationFloor,
              let baseURL = capabilityProvider?.baseURL else {
            return nil
        }
        if let bound = generationAccounts[effective], bound != accountID {
            return nil
        }
        return LogSubmissionSessionContext(
            accountID: accountID,
            generation: effective,
            baseURL: baseURL
        )
    }

    /// Reads the current session once, before any capability await. Production
    /// callers normally pass an already-frozen value; this fallback exists for
    /// direct service calls and keeps capability probes account-bound.
    private func currentRequestAccountID(
        accountID: String,
        generation: UInt64?
    ) -> String? {
        guard let sessionContextProvider else { return accountID }
        guard let current = sessionContextProvider(),
              current.accountID == accountID else {
            return nil
        }
        if let generation, current.generation != generation {
            return nil
        }
        return current.requestAccountID
    }

    private func contextStillValid(_ context: LogSubmissionSessionContext) -> Bool {
        if let sessionContextProvider {
            return sessionContextProvider() == context
        }
        return context.generation >= generationFloor
            && capabilityGeneration == context.generation
            && generationAccounts[context.generation] == context.accountID
    }

    public func ensureCapability(
        accountID: String,
        generation: UInt64? = nil,
        route: LogSubmissionRoute
    ) async -> LogSubmissionServiceFailure? {
        guard let context = captureContext(
            accountID: accountID,
            generation: generation
        ) else {
            return .capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
        }
        let effectiveGeneration = context.generation
        if generationAccounts[effectiveGeneration] == nil {
            _ = await refreshCapability(
                accountID: accountID,
                generation: effectiveGeneration,
                expectedAccountID: context.requestAccountID
            )
        } else if capabilityFailure(accountID: accountID, route: route) == nil {
            return nil
        } else {
            _ = await refreshCapability(
                accountID: accountID,
                generation: effectiveGeneration,
                expectedAccountID: context.requestAccountID
            )
        }
        guard contextStillValid(context) else {
            return .capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )
        }
        return capabilityFailure(accountID: accountID, route: route)
    }

    /// Synchronous reservation for callers that already hold a verified
    /// capability. Shell quick-add uses `prepareIntent` so a cold capability
    /// probe can recover without creating an unverified journal row.
    public func prepare(
        accountID: String,
        summary: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String] = [],
        baseURL: URL?,
        generation: UInt64? = nil
    ) -> Result<PendingLogSubmission, LogSubmissionServiceFailure> {
        guard let context = captureContext(
            accountID: accountID,
            generation: generation
        ) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        let route = LogSubmissionRoute.route(for: drafts)
        if let failure = capabilityFailure(accountID: accountID, route: route) {
            return .failure(failure)
        }
        for draft in drafts {
            let unresolved = store.unresolved(
                accountID: accountID,
                item: draft.item,
                date: draft.date
            )
            if !unresolved.isEmpty {
                return .failure(.uncertain(
                    String(localized: "submission.pendingExists")
                ))
            }
        }

        let prepared: LogSubmissionRequest
        do {
            prepared = try LogSubmissionRequestBuilder.prepare(
                drafts: drafts,
                baseURL: baseURL
            ).request
        } catch let error as LogCreateRequestBuilderError {
            return .failure(.rejected(Self.builderMessage(error)))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }

        do {
            let entry = try store.reserve(
                accountID: context.accountID,
                summary: summary,
                drafts: drafts,
                request: prepared,
                itemNames: itemNames,
                capabilityVersion: capabilityVersion(
                    for: route,
                    accountID: context.accountID
                )
            )
            return .success(entry)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
    }

    /// Captures the action synchronously, with no journal row or key. The
    /// caller must await capability and then call `submitPreparedIntent`.
    public func prepareIntent(
        accountID: String,
        summary: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String] = [],
        baseURL: URL?,
        generation: UInt64? = nil
    ) -> Result<PreparedLogSubmissionIntent, LogSubmissionServiceFailure> {
        guard let context = captureContext(
            accountID: accountID,
            generation: generation
        ) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        for draft in drafts {
            let unresolved = store.unresolved(
                accountID: context.accountID,
                item: draft.item,
                date: draft.date
            )
            if !unresolved.isEmpty {
                return .failure(.uncertain(
                    String(localized: "submission.pendingExists")
                ))
            }
        }
        let request: LogSubmissionRequest
        do {
            request = try LogSubmissionRequestBuilder.prepare(
                drafts: drafts,
                baseURL: baseURL
            ).request
        } catch let error as LogCreateRequestBuilderError {
            return .failure(.rejected(Self.builderMessage(error)))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        do {
            let intent = try store.prepareIntent(
                accountID: context.accountID,
                summary: summary,
                drafts: drafts,
                request: request,
                itemNames: itemNames.isEmpty ? nil : itemNames
            )
            return .success(intent)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
    }

    public func submitPreparedIntent(
        _ intent: PreparedLogSubmissionIntent,
        generation: UInt64? = nil
    ) async -> LogSubmissionServiceResult {
        guard let context = captureContext(
            accountID: intent.accountID,
            generation: generation
        ) else {
            store.discardPreparedIntent(id: intent.id, accountID: intent.accountID)
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        let route = LogSubmissionRoute.route(for: intent.drafts)
        if let failure = await ensureCapability(
            accountID: context.accountID,
            generation: context.generation,
            route: route
        ) {
            store.discardPreparedIntent(id: intent.id, accountID: intent.accountID)
            return .failure(failure)
        }
        guard contextStillValid(context) else {
            store.discardPreparedIntent(id: intent.id, accountID: intent.accountID)
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        if let reason = store.preparedIntentCancellationReason(
            id: intent.id,
            accountID: intent.accountID
        ) {
            store.discardPreparedIntent(id: intent.id, accountID: intent.accountID)
            return .failure(.rejected(reason))
        }
        let entry: PendingLogSubmission
        do {
            entry = try store.reservePreparedIntent(
                id: intent.id,
                accountID: intent.accountID,
                capabilityVersion: capabilityVersion(
                    for: route,
                    accountID: context.accountID
                )
            )
        } catch let error as LogSubmissionStoreError {
            if case .preparedIntentUnavailable = error,
               let existing = store.entry(
                   accountID: context.accountID,
                   idempotencyKey: intent.request.idempotencyKey
               ),
               existing.allDrafts == intent.drafts,
               existing.requestPath == intent.request.requestPath,
               existing.baseURLString == (intent.request.baseURLString ?? ""),
               existing.body == nil || existing.body == intent.request.body {
                return await submitReserved(
                    existing,
                    accountID: context.accountID,
                    generation: context.generation
                )
            }
            store.discardPreparedIntent(id: intent.id, accountID: intent.accountID)
            return .failure(Self.storeFailure(error))
        } catch {
            store.discardPreparedIntent(id: intent.id, accountID: intent.accountID)
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        return await submitReserved(
            entry,
            accountID: context.accountID,
            generation: context.generation
        )
    }

    public func submitReserved(
        _ entry: PendingLogSubmission,
        accountID: String,
        generation: UInt64? = nil
    ) async -> LogSubmissionServiceResult {
        guard entry.accountID == accountID,
              let context = captureContext(
                  accountID: accountID,
                  generation: generation
              ) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        let route = Self.route(for: entry.requestPath)

        // Never send the caller's in-memory copy. Reload first so a vanished,
        // unreadable, or concurrently changed row fails closed.
        let stored: PendingLogSubmission
        do {
            stored = try store.requireEntry(id: entry.id, accountID: accountID)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        if stored.state == .succeeded {
            return .success(logs: [], replayed: stored.replayed)
        }
        if stored.state == .conflicted {
            return .failure(.conflict(
                stored.lastMessage ?? String(localized: "foodDetail.error.conflict")
            ))
        }
        if stored.state == .rejected {
            return .failure(.rejected(
                stored.lastMessage ?? String(localized: "foodDetail.error.saveFailed")
            ))
        }
        if stored.state == .serverChanged {
            return .failure(.serverChanged(
                stored.lastMessage ?? String(localized: "foodDetail.error.differentServer")
            ))
        }
        if stored.state == .reconciliationOnly {
            return .failure(.reconciliationOnly(
                stored.lastMessage ?? String(localized: "submission.reconciliationOnly")
            ))
        }

        // Provenance is minted only after a verified capability fetch and must
        // already be durable. Never upgrade an unverifiable entry here; keep
        // its exact body for explicit reconciliation instead of replaying it.
        guard stored.capabilityVersion == 2 else {
            return .failure(.reconciliationOnly(
                String(localized: "submission.reconciliationOnly")
            ))
        }

        if !stored.baseURLString.isEmpty,
           stored.baseURLString != context.baseURL.absoluteString {
            let message = String(localized: "foodDetail.error.differentServer")
            do {
                try store.markServerChanged(
                    id: stored.id,
                    accountID: accountID,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.serverChanged(message))
        }

        if let failure = await ensureCapability(
            accountID: context.accountID,
            generation: context.generation,
            route: route
        ) {
            return .failure(failure)
        }
        guard contextStillValid(context) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }

        // The capability probe can suspend. Re-read so a delete barrier or a
        // concurrent journal change cannot be bypassed by the earlier snapshot.
        let current: PendingLogSubmission
        do {
            current = try store.requireEntry(id: stored.id, accountID: accountID)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        guard current.capabilityVersion == 2 else {
            return .failure(.reconciliationOnly(
                String(localized: "submission.reconciliationOnly")
            ))
        }
        return await send(current, context: context)
    }

    /// Reserves a caller-supplied exact request after verifying capability.
    /// Library save-and-log needs the key/body persisted in its catalog intent
    /// to be the same bytes the journal owns and replays.
    public func reserveExact(
        accountID: String,
        summary: String,
        draft: LogSubmissionDraft,
        itemName: String,
        request: LogSubmissionRequest,
        generation: UInt64? = nil
    ) async -> Result<PendingLogSubmission, LogSubmissionServiceFailure> {
        guard let context = captureContext(
            accountID: accountID,
            generation: generation
        ) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        if let requestBaseURL = request.baseURLString,
           !requestBaseURL.isEmpty,
           requestBaseURL != context.baseURL.absoluteString {
            return .failure(.serverChanged(
                String(localized: "foodDetail.error.differentServer")
            ))
        }
        let route = LogSubmissionRoute.route(for: [draft])
        if let failure = await ensureCapability(
            accountID: context.accountID,
            generation: context.generation,
            route: route
        ) {
            return .failure(failure)
        }
        guard contextStillValid(context) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        do {
            let entry = try store.reserve(
                accountID: context.accountID,
                summary: summary,
                drafts: [draft],
                request: request,
                itemNames: [itemName],
                capabilityVersion: capabilityVersion(
                    for: route,
                    accountID: context.accountID
                )
            )
            return .success(entry)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
    }

    /// A new intentional submission mints a new key only when it cannot match
    /// an unresolved attempt. If any draft matches one, this fails closed and
    /// directs recovery through that stored operation.
    public func submit(
        accountID: String,
        summary: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String] = [],
        baseURL: URL?,
        generation: UInt64? = nil
    ) async -> LogSubmissionServiceResult {
        guard let context = captureContext(
            accountID: accountID,
            generation: generation
        ) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        let route = LogSubmissionRoute.route(for: drafts)
        if let failure = await ensureCapability(
            accountID: context.accountID,
            generation: context.generation,
            route: route
        ) {
            return .failure(failure)
        }
        guard contextStillValid(context) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        switch prepare(
            accountID: context.accountID,
            summary: summary,
            drafts: drafts,
            itemNames: itemNames,
            baseURL: baseURL,
            generation: context.generation
        ) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let entry):
            return await submitReserved(
                entry,
                accountID: context.accountID,
                generation: context.generation
            )
        }
    }

    public func retry(
        entry: PendingLogSubmission,
        accountID: String,
        generation: UInt64? = nil
    ) async -> LogSubmissionServiceResult {
        guard entry.accountID == accountID,
              let context = captureContext(
                  accountID: accountID,
                  generation: generation
              ) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        let stored: PendingLogSubmission
        do {
            stored = try store.requireEntry(id: entry.id, accountID: accountID)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        if stored.state == .succeeded {
            return .success(logs: [], replayed: stored.replayed)
        }
        if stored.state == .conflicted {
            return .failure(.conflict(
                stored.lastMessage ?? String(localized: "foodDetail.error.conflict")
            ))
        }
        if stored.state == .rejected {
            return .failure(.rejected(
                stored.lastMessage ?? String(localized: "foodDetail.error.saveFailed")
            ))
        }
        if stored.state == .serverChanged {
            return .failure(.serverChanged(
                stored.lastMessage ?? String(localized: "foodDetail.error.differentServer")
            ))
        }
        if stored.state == .reconciliationOnly {
            return .failure(.reconciliationOnly(
                stored.lastMessage ?? String(localized: "submission.reconciliationOnly")
            ))
        }
        let route = Self.route(for: stored.requestPath)
        guard stored.capabilityVersion == 2 else {
            let message = String(localized: "submission.reconciliationOnly")
            do {
                try store.markReconciliationOnly(
                    id: stored.id,
                    accountID: accountID,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.reconciliationOnly(message))
        }
        if !stored.baseURLString.isEmpty,
           stored.baseURLString != context.baseURL.absoluteString {
            let message = String(localized: "foodDetail.error.differentServer")
            do {
                try store.markServerChanged(
                    id: stored.id,
                    accountID: accountID,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.serverChanged(message))
        }
        _ = await refreshCapability(
            accountID: context.accountID,
            generation: context.generation,
            expectedAccountID: context.requestAccountID
        )
        guard contextStillValid(context) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        if let failure = capabilityFailure(
            accountID: context.accountID,
            route: route
        ) {
            // A verified entry keeps its exact bytes and unresolved state while
            // the capability probe is unavailable or the server is temporarily
            // behind. Only provenance that cannot be verified is downgraded.
            return .failure(failure)
        }
        let current: PendingLogSubmission
        do {
            current = try store.requireEntry(id: stored.id, accountID: accountID)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        guard current.body != nil,
              current.state != .invalidated,
              current.capabilityVersion == 2 else {
            return .failure(.rejected(
                current.lastMessage
                    ?? String(localized: "foodDetail.pending.invalidated")
            ))
        }
        return await send(current, context: context)
    }

    private func send(
        _ entry: PendingLogSubmission,
        context: LogSubmissionSessionContext
    ) async -> LogSubmissionServiceResult {
        guard contextStillValid(context) else {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.sessionExpired")
            ))
        }
        let accountID = context.accountID
        let claimed: Bool
        do {
            claimed = try store.claimSubmission(id: entry.id, accountID: accountID)
        } catch let error as LogSubmissionStoreError {
            return .failure(Self.storeFailure(error))
        } catch {
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        if !claimed {
            if let current = store.entry(id: entry.id, accountID: accountID) {
                switch current.state {
                case .succeeded:
                    return .success(logs: [], replayed: current.replayed)
                case .invalidated, .rejected:
                    return .failure(.rejected(
                        current.lastMessage
                            ?? String(localized: "foodDetail.pending.invalidated")
                    ))
                case .inFlight, .uncertain, .conflicted, .serverChanged,
                     .reconciliationOnly:
                    break
                }
            }
            return .failure(.uncertain(
                String(localized: "submission.pendingExists")
            ))
        }

        let attempt: PendingLogSubmission
        do {
            attempt = try store.requireEntry(id: entry.id, accountID: accountID)
        } catch {
            store.abandonLiveSubmission(id: entry.id)
            return .failure(.journalUnavailable(
                String(localized: "foodDetail.error.journalUnavailable")
            ))
        }
        if store.isRetryBlocked(id: attempt.id)
            || attempt.state == .invalidated
            || attempt.body == nil {
            store.abandonLiveSubmission(id: attempt.id)
            return .failure(.rejected(
                attempt.lastMessage ?? String(localized: "foodDetail.pending.invalidated")
            ))
        }
        guard let request = attempt.submissionRequest else {
            store.abandonLiveSubmission(id: attempt.id)
            return .failure(.rejected(String(localized: "foodDetail.error.saveFailed")))
        }
        guard contextStillValid(context) else {
            store.abandonLiveSubmission(id: attempt.id)
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.sessionExpired")
            ))
        }

        do {
            let response = try await sender.send(
                request,
                expectedAccountID: context.requestAccountID
            )
            let contextIsCurrent = contextStillValid(context)
            if !contextIsCurrent
                || store.isRetryBlocked(id: attempt.id)
                || store.entry(id: attempt.id, accountID: accountID)?.state == .invalidated {
                let message = String(localized: "foodDetail.error.sessionExpired")
                try? store.markUncertain(
                    id: attempt.id,
                    accountID: accountID,
                    status: response.statusCode,
                    message: message
                )
                return .failure(.uncertain(message))
            }
            guard Self.responseMatches(response.logs, drafts: attempt.allDrafts) else {
                let message = String(localized: "foodDetail.error.invalidResponse")
                do {
                    try store.markUncertain(
                        id: attempt.id,
                        accountID: accountID,
                        status: response.statusCode,
                        message: message
                    )
                } catch {
                    return .failure(.journalUnavailable(
                        String(localized: "foodDetail.error.journalUnavailable")
                    ))
                }
                return .failure(.uncertain(message))
            }
            let logs = response.logs.map {
                LogSubmissionCreatedLog(
                    id: $0.id,
                    date: $0.logDate,
                    mealSlot: $0.mealSlot,
                    item: LogSubmissionItem(logItem: $0.item)
                        ?? .adHoc(name: $0.item.name, brand: $0.item.brand)
                )
            }
            do {
                try store.markSucceeded(
                    id: attempt.id,
                    accountID: accountID,
                    logs: logs,
                    replayed: response.statusCode == 200
                )
            } catch {
                // The server committed, but the terminal journal write did not.
                // Report an unresolved operation rather than a clean success.
                return .failure(.journalUnavailable(
                    String(localized: "foodDetail.error.journalUnavailable")
                ))
            }
            return .success(logs: response.logs, replayed: response.statusCode == 200)
        } catch let error as LogSubmissionSendError {
            return handle(error, entry: attempt, accountID: accountID)
        } catch {
            let message = error.localizedDescription
            do {
                try store.markUncertain(
                    id: attempt.id,
                    accountID: accountID,
                    status: nil,
                    message: message
                )
            } catch {
                return .failure(.journalUnavailable(
                    String(localized: "foodDetail.error.journalUnavailable")
                ))
            }
            return .failure(.uncertain(message))
        }
    }

    private func handle(
        _ error: LogSubmissionSendError,
        entry: PendingLogSubmission,
        accountID: String
    ) -> LogSubmissionServiceResult {
        switch error {
        case .unauthorized:
            let message = String(localized: "foodDetail.error.sessionExpired")
            do {
                try store.markUncertain(
                    id: entry.id,
                    accountID: accountID,
                    status: 401,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.unauthorized)
        case .failed(let message):
            do {
                try store.markRejected(
                    id: entry.id,
                    accountID: accountID,
                    status: 400,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.rejected(message))
        case .uncertain(let message):
            do {
                try store.markUncertain(
                    id: entry.id,
                    accountID: accountID,
                    status: nil,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.uncertain(message))
        case .conflict(let message):
            do {
                try store.markConflicted(id: entry.id, accountID: accountID, message: message)
            } catch {
                return journalWriteFailure()
            }
            return .failure(.conflict(message))
        case .missingComponents(let message):
            do {
                try store.markRejected(
                    id: entry.id,
                    accountID: accountID,
                    status: 409,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.missingComponents(message))
        case .serverChanged(let message):
            do {
                try store.markServerChanged(
                    id: entry.id,
                    accountID: accountID,
                    message: message
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.serverChanged(message))
        case .rateLimited(let retryAfter):
            let message = String(localized: "foodDetail.error.rateLimited")
            do {
                try store.markUncertain(
                    id: entry.id,
                    accountID: accountID,
                    status: 429,
                    message: message,
                    retryAfterSeconds: retryAfter
                )
            } catch {
                return journalWriteFailure()
            }
            return .failure(.uncertain(message))
        }
    }

    private func journalWriteFailure() -> LogSubmissionServiceResult {
        .failure(.journalUnavailable(
            String(localized: "foodDetail.error.journalUnavailable")
        ))
    }

    private static func route(for path: String) -> LogSubmissionRoute {
        switch path {
        case LogSubmissionRoute.batch.requestPath: return .batch
        case LogSubmissionRoute.adHoc.requestPath: return .adHoc
        default: return .single
        }
    }

    private static func responseMatches(
        _ logs: [FoodLog],
        drafts: [LogSubmissionDraft]
    ) -> Bool {
        guard !drafts.isEmpty, logs.count == drafts.count else { return false }
        for (log, draft) in zip(logs, drafts) {
            guard log.logDate == draft.date,
                  LogSubmissionItem(logItem: log.item) == draft.item else {
                return false
            }
        }
        return true
    }

    private static func builderMessage(_ error: LogCreateRequestBuilderError) -> String {
        switch error {
        case .bodyTooLarge:
            return String(localized: "foodDetail.error.notesTooLong")
        case .invalidKey, .invalidItem, .encoding:
            return String(localized: "foodDetail.error.saveFailed")
        }
    }

    private static func storeFailure(
        _ error: LogSubmissionStoreError
    ) -> LogSubmissionServiceFailure {
        switch error {
        case .idempotencyConflict:
            return .conflict(String(localized: "foodDetail.error.conflict"))
        case .preparedIntentCancelled(let reason):
            return .rejected(reason)
        case .preparedIntentPending:
            return .uncertain(String(localized: "submission.pendingExists"))
        case .preparedIntentUnavailable:
            return .journalUnavailable(
                String(localized: "foodDetail.error.journalUnavailable")
            )
        default:
            return .journalUnavailable(storeMessage(error))
        }
    }

    private static func storeMessage(_ error: LogSubmissionStoreError) -> String {
        switch error {
        case .unreadableJournal:
            return String(localized: "foodDetail.error.journalUnavailable")
        default:
            return String(localized: "foodDetail.error.saveFailed")
        }
    }
}

public enum LogSubmissionSummary {
    public static func text(for drafts: [LogSubmissionDraft], names: [String]) -> String {
        guard let first = names.first, !first.isEmpty else {
            return String(localized: "search.quickAdd")
        }
        guard names.count > 1 else { return first }
        return String(
            format: String(localized: "search.batch.summary"),
            first,
            names.count - 1
        )
    }
}
