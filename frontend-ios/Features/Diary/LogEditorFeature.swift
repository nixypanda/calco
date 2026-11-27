import ComposableArchitecture
import Foundation

/// A single log-editing session, owned by a TCA store rather than an
/// ObservableObject. Every failure path is an explicit lifecycle payload:
/// transport/server failures surface a retryable message, cancellation returns
/// to editing, and a 401 marks the session expired and delegates to the owner.
///
/// The captured identity (log ID, date, slot, account, generation and a unique
/// presentation ID) is immutable for the editor's lifetime. It is the only
/// authority used to stamp mutations and to reject stale completions; there is
/// no service, journal or cache authority in `State`.
@Reducer
public struct LogEditorFeature {
    /// Immutable session identity captured at every async boundary. It is a value
    /// payload only — never a service or authority. The wiring owner verifies
    /// current account/generation BEFORE transport, and every reply is checked
    /// against the receiving store's captured context BEFORE any state mutation
    /// or delegate emission.
    public struct RequestContext: Equatable, Sendable {
        public let accountID: String
        public let generation: UInt64
        public let ownerID: UUID
    }

    // MARK: - Lifecycle

    public enum Phase: Equatable, Sendable {
        case editing
        case saving(requestID: UUID)
        case deleting(requestID: UUID)
        case saved
        case deleted
        case failed(String)
        case sessionExpired

        public var isBusy: Bool {
            switch self {
            case .saving, .deleting: return true
            default: return false
            }
        }

        /// Terminal editors are safe to replace on a later diary tap. Editing,
        /// saving, deleting, failed and expired editors must be preserved.
        public var isTerminal: Bool {
            switch self {
            case .saved, .deleted: return true
            default: return false
            }
        }

        public var canEdit: Bool {
            switch self {
            case .editing, .failed: return true
            default: return false
            }
        }

        public var busyMessage: String {
            switch self {
            case .saving: return String(localized: "diary.editor.saving")
            case .deleting: return String(localized: "diary.editor.deleting")
            default: return ""
            }
        }
    }

    public enum Confirmation: Equatable, Sendable {
        case none
        case delete
    }

    public enum EditorFailure: Equatable, Sendable {
        case unauthorized
        case cancelled
        case message(String)
    }

    public enum BarrierFailure: Equatable, Sendable {
        case journalUnavailable
        case persistence
        case liveSubmission
        case accountUnavailable
        case blockedFallback
    }

    // MARK: - State

    @ObservableState
    public struct State: Equatable {
        // Captured context — immutable for this editor session.
        public let logID: String
        public let date: LocalDiaryDate
        public let originalSlot: MealSlot?
        public let sessionGeneration: UInt64
        public let accountID: String
        public let presentationID: UUID
        public let title: String
        public let subtitle: String?
        /// Product identity used to conservatively invalidate journal attempts
        /// if this log is deleted. Nil for non-product logs.
        public let productID: String?

        // Form values.
        public var amount: String
        public var unit: String
        public var mealSlot: MealSlot?
        public var notes: String
        public var units: [FoodUnit]

        // Dirty baseline, captured when the editor opened.
        private let initialAmount: String
        private let initialUnit: String
        private let initialMealSlot: MealSlot?
        private let initialNotes: String

        public var phase: Phase = .editing
        public var confirmation: Confirmation = .none
        /// Last authoritative PUT response. The owner applies it immediately so
        /// a failed or stale refetch cannot hide the save.
        public var lastSavedLog: DiaryLog?
        /// Journal attempts durably blocked by this editor's deletes. It
        /// accumulates across retries so a later successful DELETE still
        /// explains why retry is no longer offered for those attempts.
        public var blockedPendingCount: Int = 0
        /// Unresolved journal attempts matching this product/date at open time.
        /// Defaults to zero; loaded on `.task` through the client (never State).
        public var matchingPendingCount: Int = 0

        public init(
            log: DiaryLog,
            date: LocalDiaryDate,
            accountID: String,
            sessionGeneration: UInt64,
            presentationID: UUID = UUID(),
            units: [FoodUnit] = []
        ) {
            let initialAmount = log.quantity?.amount ?? "100"
            let initialUnit = log.quantity?.unit ?? "g"
            self.logID = log.id
            self.date = date
            self.originalSlot = log.mealSlot
            self.sessionGeneration = sessionGeneration
            self.accountID = accountID
            self.presentationID = presentationID
            self.title = log.title
            self.subtitle = log.brand
            self.productID = log.productID
            self.amount = initialAmount
            self.unit = initialUnit
            self.mealSlot = log.mealSlot
            self.notes = log.notes ?? ""
            self.initialAmount = initialAmount
            self.initialUnit = initialUnit
            self.initialMealSlot = log.mealSlot
            self.initialNotes = log.notes ?? ""
            self.units = Self.fallbackUnits(including: initialUnit, supplied: units)
        }

        /// Saving and deleting states remain dirty until the owner leaves the
        /// editor, so a back/row-switch cannot silently discard an in-flight edit.
        public var hasUnsavedChanges: Bool {
            amount != initialAmount
                || unit != initialUnit
                || mealSlot != initialMealSlot
                || notes != initialNotes
        }

        public var validationMessage: String? {
            validateLogAmount(amount)?.message
        }

        /// A delete that would disable an unresolved retry must warn that it is
        /// about to block that attempt, not only show the normal warning.
        public var deleteConfirmationMessage: String {
            matchingPendingCount > 0
                ? String(localized: "diary.editor.delete.confirmWithPending")
                : String(localized: "diary.editor.delete.confirm")
        }

        public var errorMessage: String? {
            switch phase {
            case .failed(let message): return message
            case .sessionExpired: return String(localized: "diary.error.sessionExpired")
            default: return nil
            }
        }

        public var canEdit: Bool { phase.canEdit }
        public var isBusy: Bool { phase.isBusy }
        public var isTerminal: Bool { phase.isTerminal }
        public var isSessionExpired: Bool {
            if case .sessionExpired = phase { true } else { false }
        }

        public var canSave: Bool {
            canEdit && hasUnsavedChanges && validationMessage == nil
        }

        public var requestContext: RequestContext {
            RequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                ownerID: presentationID
            )
        }

        fileprivate static func fallbackUnits(including current: String, supplied: [FoodUnit]) -> [FoodUnit] {
            let defaults = [
                FoodUnit(code: "g", name: "Gram", kind: "mass"),
                FoodUnit(code: "kg", name: "Kilogram", kind: "mass"),
                FoodUnit(code: "oz", name: "Ounce", kind: "mass"),
                FoodUnit(code: "ml", name: "Millilitre", kind: "volume"),
                FoodUnit(code: "l", name: "Litre", kind: "volume"),
                FoodUnit(code: "serving", name: "Serving", kind: "serving"),
            ]
            var seen = Set<String>()
            var result: [FoodUnit] = []
            func append(_ unit: FoodUnit) {
                guard !unit.code.isEmpty, seen.insert(unit.code).inserted else { return }
                result.append(unit)
            }
            for unit in defaults { append(unit) }
            for unit in supplied { append(unit) }
            append(FoodUnit(code: current, name: current, kind: "unit"))
            return result
        }
    }

    // MARK: - Action

    public enum Action: Equatable, Sendable {
        case task
        case pendingCountLoaded(context: RequestContext, count: Int)
        case unitsLoaded(context: RequestContext, units: [FoodUnit])
        case amountChanged(String)
        case unitChanged(String)
        case mealSlotChanged(MealSlot?)
        case notesChanged(String)
        case retry
        case saveTapped
        case deleteRequested
        case deleteCancelled
        case confirmDelete
        case saveSucceeded(context: RequestContext, requestID: UUID, log: DiaryLog)
        case saveFailed(context: RequestContext, requestID: UUID, failure: EditorFailure)
        case deleteSucceeded(context: RequestContext, requestID: UUID, blockedPendingCount: Int)
        case deleteFailed(context: RequestContext, requestID: UUID, failure: EditorFailure, blockedPendingCount: Int)
        case barrierFailed(context: RequestContext, requestID: UUID, failure: BarrierFailure)
        case delegate(Delegate)
    }

    /// Typed, authoritative server callbacks. The notice is built from the
    /// captured title (and delete barrier count) before the asynchronous handoff,
    /// so a later generation/date change cannot rewrite what the user did.
    /// Exactly one success is emitted per presentation ID; the owner is the sole
    /// applier (no second POST, no refetch, no notice from this child).
    public enum Delegate: Equatable, Sendable {
        case saved(
            presentationID: UUID,
            logID: String,
            date: LocalDiaryDate,
            authoritativeDiaryLog: DiaryLog,
            notice: DiaryMutationNotice,
            generation: UInt64
        )
        case deleted(
            presentationID: UUID,
            logID: String,
            date: LocalDiaryDate,
            notice: DiaryMutationNotice,
            generation: UInt64
        )
        case sessionExpired(generation: UInt64)
    }

    // MARK: - Client

    /// Service closures live in `DependencyValues`, never in `State`.
    public struct Client: Sendable {
        public var fetchUnits: @Sendable (RequestContext) async throws -> [FoodUnit]
        public var updateLog: @Sendable (RequestContext, String, UpdateLogRequest) async throws -> DiaryLog
        public var deleteLog: @Sendable (RequestContext, String) async throws -> Void
        public var blockBeforeDeleting: @MainActor @Sendable (RequestContext, String, LocalDiaryDate, String) throws -> Int
        public var matchingPendingCount: @MainActor @Sendable (RequestContext, String, LocalDiaryDate) -> Int
    }

    @Dependency(\.logEditorClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    // MARK: - Reducer

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                let client = self.client
                let context = state.requestContext
                let productID = state.productID
                let date = state.date
                return .merge(
                    .run { send in
                        // Units are a convenience, not a correctness requirement.
                        // A failure keeps the local fallback list.
                        guard let fetched = try? await client.fetchUnits(context), !fetched.isEmpty else {
                            return
                        }
                        await send(.unitsLoaded(context: context, units: fetched))
                    },
                    .run { send in
                        guard let productID,
                              !context.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else {
                            await send(.pendingCountLoaded(context: context, count: 0))
                            return
                        }
                        let count = await MainActor.run { client.matchingPendingCount(context, productID, date) }
                        await send(.pendingCountLoaded(context: context, count: count))
                    }
                )

            case let .pendingCountLoaded(context, count):
                guard Self.isCurrent(context, in: state) else { return .none }
                state.matchingPendingCount = count
                return .none

            case let .unitsLoaded(context, units):
                guard Self.isCurrent(context, in: state), !units.isEmpty else { return .none }
                state.units = State.fallbackUnits(including: state.unit, supplied: units)
                return .none

            case let .amountChanged(value):
                guard state.canEdit else { return .none }
                state.amount = value
                return .none

            case let .unitChanged(value):
                guard state.canEdit else { return .none }
                state.unit = value
                return .none

            case let .mealSlotChanged(value):
                guard state.canEdit else { return .none }
                state.mealSlot = value
                return .none

            case let .notesChanged(value):
                guard state.canEdit else { return .none }
                state.notes = value
                return .none

            case .retry:
                guard case .failed = state.phase else { return .none }
                state.phase = .editing
                return .none

            case .saveTapped:
                guard state.canSave else { return .none }
                let requestID = uuid()
                state.phase = .saving(requestID: requestID)

                // Match the create flow: trim and treat whitespace-only notes as cleared.
                let trimmedNotes = state.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                let request = UpdateLogRequest(
                    mealSlot: state.mealSlot.map { OptionalField<MealSlot>.value($0) } ?? .null,
                    quantity: NutritionQuantity(amount: state.amount, unit: state.unit),
                    notes: trimmedNotes.isEmpty ? .null : .value(trimmedNotes)
                )
                let client = self.client
                let context = state.requestContext
                let logID = state.logID
                return .run { send in
                    do {
                        let updated = try await client.updateLog(context, logID, request)
                        await send(.saveSucceeded(context: context, requestID: requestID, log: updated))
                    } catch {
                        await send(.saveFailed(
                            context: context,
                            requestID: requestID,
                            failure: Self.mapEditor(error)
                        ))
                    }
                }

            case let .saveSucceeded(context, requestID, log):
                guard Self.isCurrent(context, in: state),
                      case .saving(let active) = state.phase,
                      active == requestID else { return .none }
                state.lastSavedLog = log
                state.phase = .saved
                return .send(.delegate(.saved(
                    presentationID: state.presentationID,
                    logID: state.logID,
                    date: state.date,
                    authoritativeDiaryLog: log,
                    notice: DiaryMutationNotice(kind: .saved, title: state.title),
                    generation: state.sessionGeneration
                )))

            case let .saveFailed(context, requestID, failure):
                guard Self.isCurrent(context, in: state),
                      case .saving(let active) = state.phase,
                      active == requestID else { return .none }
                switch failure {
                case .unauthorized:
                    state.phase = .sessionExpired
                    return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                case .cancelled:
                    state.phase = .editing
                    return .none
                case .message(let message):
                    state.phase = .failed(message)
                    return .none
                }

            case .deleteRequested:
                guard state.canEdit else { return .none }
                state.confirmation = .delete
                return .none

            case .deleteCancelled:
                state.confirmation = .none
                return .none

            case .confirmDelete:
                guard state.canEdit else { return .none }
                state.confirmation = .none
                let requestID = uuid()
                state.phase = .deleting(requestID: requestID)
                let client = self.client
                let context = state.requestContext
                let date = state.date
                let logID = state.logID
                let productID = state.productID
                return .run { send in
                    // Fail closed before the backend DELETE. The journal barrier
                    // must be durable first; otherwise a late POST replay could
                    // recreate the log. Only after user confirmation is it safe
                    // to invalidate matching attempts. Non-product logs have no
                    // journal identity and skip the barrier entirely.
                    var blocked = 0
                    if let productID {
                        do {
                            blocked = try await MainActor.run {
                                try client.blockBeforeDeleting(
                                    context,
                                    productID,
                                    date,
                                    String(localized: "foodDetail.pending.invalidated")
                                )
                            }
                        } catch {
                            await send(.barrierFailed(
                                context: context,
                                requestID: requestID,
                                failure: Self.mapBarrier(error)
                            ))
                            return
                        }
                    }
                    do {
                        try await client.deleteLog(context, logID)
                        await send(.deleteSucceeded(
                            context: context,
                            requestID: requestID,
                            blockedPendingCount: blocked
                        ))
                    } catch {
                        await send(.deleteFailed(
                            context: context,
                            requestID: requestID,
                            failure: Self.mapEditor(error),
                            blockedPendingCount: blocked
                        ))
                    }
                }

            case let .barrierFailed(context, requestID, failure):
                guard Self.isCurrent(context, in: state),
                      case .deleting(let active) = state.phase,
                      active == requestID else { return .none }
                state.phase = .failed(Self.barrierMessage(failure))
                return .none

            case let .deleteSucceeded(context, requestID, blocked):
                guard Self.isCurrent(context, in: state),
                      case .deleting(let active) = state.phase,
                      active == requestID else { return .none }
                state.phase = .deleted
                state.blockedPendingCount += blocked
                return .send(.delegate(.deleted(
                    presentationID: state.presentationID,
                    logID: state.logID,
                    date: state.date,
                    notice: DiaryMutationNotice(
                        kind: .deleted,
                        title: state.title,
                        blockedPendingCount: state.blockedPendingCount
                    ),
                    generation: state.sessionGeneration
                )))

            case let .deleteFailed(context, requestID, failure, blocked):
                guard Self.isCurrent(context, in: state),
                      case .deleting(let active) = state.phase,
                      active == requestID else { return .none }
                state.blockedPendingCount += blocked
                switch failure {
                case .unauthorized:
                    state.phase = .sessionExpired
                    return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                case .cancelled:
                    state.phase = .failed(blocked > 0
                        ? String(localized: "diary.editor.delete.cancelledWithBarrier")
                        : String(localized: "diary.editor.delete.cancelled"))
                    return .none
                case .message(let message):
                    state.phase = .failed(blocked > 0
                        ? String(format: String(localized: "diary.editor.delete.failedWithBarrier"), message)
                        : message)
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }

    /// Captured identity from the reply must equal the receiving store's
    /// account, generation and presentation ID before any mutation or delegate.
    private static func isCurrent(_ context: RequestContext, in state: State) -> Bool {
        context == state.requestContext
    }

    // MARK: - Error mapping

    private static func mapEditor(_ error: Error) -> EditorFailure {
        if isUnauthorizedDiaryError(error) { return .unauthorized }
        if isCancelledDiaryError(error) || error is CancellationError { return .cancelled }
        return .message(diaryErrorMessage(error))
    }

    private static func mapBarrier(_ error: Error) -> BarrierFailure {
        guard let storeError = error as? LogSubmissionStoreError else {
            return .blockedFallback
        }
        switch storeError {
        case .unreadableJournal: return .journalUnavailable
        case .persistence: return .persistence
        case .submissionInFlight: return .liveSubmission
        case .invalidAccount: return .accountUnavailable
        case .missingEntry, .invalidRequest, .bodyTooLarge, .tooManyEntries:
            return .blockedFallback
        }
    }

    private static func barrierMessage(_ failure: BarrierFailure) -> String {
        switch failure {
        case .journalUnavailable: String(localized: "diary.editor.delete.journalUnavailable")
        case .persistence: String(localized: "diary.editor.delete.persistenceFailed")
        case .liveSubmission: String(localized: "diary.editor.delete.liveSubmission")
        case .accountUnavailable: String(localized: "diary.editor.delete.accountUnavailable")
        case .blockedFallback: String(localized: "diary.editor.delete.blockedFallback")
        }
    }
}

extension DependencyValues {
    public var logEditorClient: LogEditorFeature.Client {
        get { self[LogEditorClientKey.self] }
        set { self[LogEditorClientKey.self] = newValue }
    }
}

private enum LogEditorClientKey: DependencyKey {
    static let liveValue: LogEditorFeature.Client = .init(
        fetchUnits: { _ in [] },
        updateLog: { _, _, _ in throw DiaryServiceError.unknown },
        deleteLog: { _, _ in throw DiaryServiceError.unknown },
        blockBeforeDeleting: { _, _, _, _ in 0 },
        matchingPendingCount: { _, _, _ in 0 }
    )
    static let testValue: LogEditorFeature.Client = liveValue
}
