// Library service contracts and shared error vocabulary.

import Foundation

public enum CustomFoodServiceError: Error, Equatable, Sendable {
    case unauthorized
    case notFound(String)
    /// A definitive rejection: the server did not apply the request.
    case failed(String)
    /// Transport or server ambiguity: the request may have been applied.
    case uncertain(String)
    case conflict(String)
    case rateLimited(retryAfterSeconds: Int?)

    public var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .notFound(let message), .failed(let message), .uncertain(let message),
             .conflict(let message):
            return message
        case .rateLimited:
            return String(localized: "foodDetail.error.rateLimited")
        }
    }

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

public protocol LibraryServicing: Sendable {
    func listCustomFoods() async throws -> [CustomFood]
    func customFood(id: String) async throws -> CustomFood
    func nutrientDefinitions() async throws -> [NutrientDefinition]
    func units() async throws -> [ProductUnit]
    func createCustomFood(_ request: CustomFoodWriteRequest) async throws -> String
    func updateCustomFood(id: String, request: CustomFoodWriteRequest) async throws -> String
    func deleteCustomFood(id: String) async throws
}

public extension LibraryServicing {
    func nutrientDefinitions() async throws -> [NutrientDefinition] { [] }
    func units() async throws -> [ProductUnit] { [] }
}

// MARK: - Shared safe submission contract

/// Thin async seam over the generalized journal handler. Implementations must
/// come from `LogSubmissionHandler` / `LogSubmissionService`; this type carries
/// no alternate storage and never performs a direct POST.
@MainActor
public protocol LibraryLogSubmitting: AnyObject {
    func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult

    /// The shared journal's unresolved entry for exactly this typed item and
    /// date, if one exists. Callers must not mint a second key beside it.
    func pendingSubmission(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate
    ) -> PendingLogSubmission?

    /// Sends the exact persisted journal request. The adapter must resolve by
    /// the durable operation key across terminal states and never mint a new
    /// key. `journalOwned` is explicit evidence that the shared journal now
    /// owns this operation; it must not be inferred from an error enum.
    func submitPersisted(
        _ request: LibraryPersistedLogRequest
    ) async -> LibraryLogHandoffOutcome
}

public struct LibraryPersistedLogRequest: Equatable, Sendable {
    public let accountID: String
    public let operationID: String
    public let draft: LogSubmissionDraft
    public let itemName: String
    public let summary: String
    public let request: LogSubmissionRequest

    public init(
        accountID: String,
        operationID: String,
        draft: LogSubmissionDraft,
        itemName: String,
        summary: String,
        request: LogSubmissionRequest
    ) {
        self.accountID = accountID
        self.operationID = operationID
        self.draft = draft
        self.itemName = itemName
        self.summary = summary
        self.request = request
    }
}

public struct LibraryLogHandoffOutcome: Equatable, Sendable {
    public let result: LogSubmissionServiceResult
    public let journalOwned: Bool
    /// Another unresolved journal operation for the same typed item/date.
    /// Present only when this catalog intent was deliberately retained.
    public let blockingEntry: PendingLogSubmission?

    public init(
        result: LogSubmissionServiceResult,
        journalOwned: Bool,
        blockingEntry: PendingLogSubmission? = nil
    ) {
        self.result = result
        self.journalOwned = journalOwned
        self.blockingEntry = blockingEntry
    }
}

public extension LibraryLogSubmitting {
    func pendingSubmission(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate
    ) -> PendingLogSubmission? { nil }

    /// The default is deliberately fail-closed: only the shared journal adapter
    /// can prove durable ownership of a persisted operation key.
    func submitPersisted(
        _ request: LibraryPersistedLogRequest
    ) async -> LibraryLogHandoffOutcome {
        LibraryLogHandoffOutcome(
            result: .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            )),
            journalOwned: false
        )
    }
}

/// Safe default until the app shell wires the shared journal. It never writes a
/// log and never attempts a fallback POST.
@MainActor
public final class UnavailableLibraryLogSubmissionService: LibraryLogSubmitting {
    nonisolated public init() {}

    public func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        .failure(.journalUnavailable(String(localized: "library.submission.unavailable")))
    }
}

/// Adapts the app shell's `LogSubmissionHandler` (the same callback used by
/// quick-add, repeat, and batch review) to an async call. The handler must
/// call its completion exactly once on every path.
@MainActor
public final class HandlerLibraryLogSubmissionService: LibraryLogSubmitting {
    private let handler: LogSubmissionHandler

    public init(handler: @escaping LogSubmissionHandler) {
        self.handler = handler
    }

    public func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        await withCheckedContinuation { continuation in
            handler(drafts, itemNames, summary) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

/// Direct adapter over the shared `LogSubmissionService`. This is the preferred
/// shell integration when the service instance is available: it keeps account,
/// key, journal, retry, and exact-body ownership in the one shared service.
@MainActor
public final class JournalLibraryLogSubmissionService: LibraryLogSubmitting {
    private let service: LogSubmissionService
    private let sessionContextProvider: LogSubmissionSessionContextProvider?

    public init(
        service: LogSubmissionService,
        sessionContextProvider: LogSubmissionSessionContextProvider? = nil
    ) {
        self.service = service
        self.sessionContextProvider = sessionContextProvider
    }

    private func capturedContext(
        accountID: String
    ) -> LogSubmissionSessionContext? {
        guard let sessionContextProvider else { return nil }
        guard let context = sessionContextProvider(),
              context.accountID == accountID else {
            return nil
        }
        return context
    }

    public func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        if sessionContextProvider != nil,
           capturedContext(accountID: accountID) == nil {
            return .failure(.capabilityUnavailable(
                String(localized: "foodDetail.error.capabilityUnavailable")
            ))
        }
        let context = capturedContext(accountID: accountID)
        return await service.submit(
            accountID: accountID,
            summary: summary,
            drafts: drafts,
            itemNames: itemNames,
            baseURL: baseURL,
            generation: context?.generation
        )
    }

    public func pendingSubmission(
        accountID: String,
        item: LogSubmissionItem,
        date: LocalDiaryDate
    ) -> PendingLogSubmission? {
        service.store.unresolved(accountID: accountID, item: item, date: date)
            .max { $0.updatedAt < $1.updatedAt }
    }

    public func submitPersisted(
        _ request: LibraryPersistedLogRequest
    ) async -> LibraryLogHandoffOutcome {
        let captured = capturedContext(accountID: request.accountID)
        if sessionContextProvider != nil, captured == nil {
            return LibraryLogHandoffOutcome(
                result: .failure(.capabilityUnavailable(
                    String(localized: "foodDetail.error.capabilityUnavailable")
                )),
                journalOwned: false
            )
        }
        guard request.operationID == request.request.idempotencyKey,
              !request.operationID.isEmpty
        else {
            return LibraryLogHandoffOutcome(
                result: .failure(.rejected(
                    String(localized: "foodDetail.error.saveFailed")
                )),
                journalOwned: false
            )
        }

        if let existing = service.store.entry(
            accountID: request.accountID,
            idempotencyKey: request.operationID
        ) {
            // Compare the complete durable operation identity before any
            // terminal/unresolved early return. This includes origin, route,
            // typed drafts, and the exact serialized body bytes. Legacy
            // terminal entries without a retained body/hash fail closed.
            guard existing.matchesRequest(
                request.request,
                drafts: [request.draft]
            ) else {
                return LibraryLogHandoffOutcome(
                    result: .failure(.conflict(
                        String(localized: "foodDetail.error.conflict")
                    )),
                    journalOwned: false
                )
            }
            switch existing.state {
            case .succeeded:
                return LibraryLogHandoffOutcome(
                    result: .success(logs: [], replayed: existing.replayed),
                    journalOwned: true
                )
            case .inFlight, .uncertain:
                return LibraryLogHandoffOutcome(
                    result: .failure(.uncertain(
                        existing.lastMessage
                            ?? String(localized: "submission.pendingExists")
                    )),
                    journalOwned: true
                )
            case .conflicted:
                return LibraryLogHandoffOutcome(
                    result: .failure(.conflict(
                        existing.lastMessage
                            ?? String(localized: "foodDetail.error.conflict")
                    )),
                    journalOwned: true
                )
            case .rejected:
                // A definitive HTTP rejection did not reserve the backend key.
                // Reusing the same key/body for an explicit retry is safe.
                try? service.store.remove(
                    id: existing.id,
                    accountID: request.accountID
                )
            case .invalidated:
                return LibraryLogHandoffOutcome(
                    result: .failure(.reconciliationOnly(
                        existing.lastMessage
                            ?? String(localized: "foodDetail.pending.invalidated")
                    )),
                    journalOwned: true
                )
            case .serverChanged:
                return LibraryLogHandoffOutcome(
                    result: .failure(.serverChanged(
                        existing.lastMessage
                            ?? String(localized: "foodDetail.error.differentServer")
                    )),
                    journalOwned: false
                )
            case .reconciliationOnly:
                return LibraryLogHandoffOutcome(
                    result: .failure(.reconciliationOnly(
                        existing.lastMessage
                            ?? String(localized: "submission.reconciliationOnly")
                    )),
                    journalOwned: true
                )
            }
        }

        let others = service.store.unresolved(
            accountID: request.accountID,
            item: request.draft.item,
            date: request.draft.date
        ).filter { $0.idempotencyKey != request.operationID }
        if let blocking = others.max(by: { $0.updatedAt < $1.updatedAt }) {
            return LibraryLogHandoffOutcome(
                result: .failure(.uncertain(
                    String(localized: "submission.pendingExists")
                )),
                journalOwned: false,
                blockingEntry: blocking
            )
        }

        let reservation = await service.reserveExact(
            accountID: request.accountID,
            summary: request.summary,
            draft: request.draft,
            itemName: request.itemName,
            request: request.request,
            generation: captured?.generation
        )
        switch reservation {
        case .failure(let failure):
            return LibraryLogHandoffOutcome(
                result: .failure(failure),
                journalOwned: false
            )
        case .success(let entry):
            let result = await service.submitReserved(
                entry,
                accountID: request.accountID,
                generation: captured?.generation
            )
            return LibraryLogHandoffOutcome(result: result, journalOwned: true)
        }
    }

}

// MARK: - Load state

public enum LibraryLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

public enum CustomFoodDetailLoadState: Equatable, Sendable {
    case loading
    case loaded(CustomFood)
    case removed
    case failed(String)
}

public enum LibrarySubmissionState: Equatable, Sendable {
    case idle
    case submitting
    case pending(message: String)
    case failed(message: String)
    case completed(logID: String?, replayed: Bool)
}

/// Logging state after a custom food has already been created. The retained
/// food ID must never be discarded in favor of creating the food again.
public enum SavedFoodLogState: Equatable, Sendable {
    case none
    case logging
    /// The journal may have committed or still hold this operation. Retrying
    /// requires the shell's shared pending-log recovery; no new key is minted.
    case pending(message: String)
    /// Definitively rejected; a new submit of the saved food is safe.
    case retryable(message: String)
    case logged(logID: String?, replayed: Bool)
}


public enum LibraryLogIntentFormat {
    public static func summary(_ intent: CustomFoodLogIntent) -> String {
        String(
            format: String(localized: "library.log.intent"),
            intent.amount,
            intent.unit,
            intent.date.formatted,
            slotLabel(intent.mealSlot)
        )
    }

    public static func slotLabel(_ slot: MealSlot?) -> String {
        switch slot {
        case .none:
            return String(localized: "foodDetail.mealSlot.none")
        case .breakfast:
            return String(localized: "foodDetail.mealSlot.breakfast")
        case .lunch:
            return String(localized: "foodDetail.mealSlot.lunch")
        case .dinner:
            return String(localized: "foodDetail.mealSlot.dinner")
        case .snack:
            return String(localized: "foodDetail.mealSlot.snack")
        case .lateNightSnack:
            return String(localized: "foodDetail.mealSlot.lateNightSnack")
        }
    }
}
