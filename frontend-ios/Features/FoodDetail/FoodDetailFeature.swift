// Real TCA Food Detail feature. The durable single-food journal stays frozen:
// this reducer only owns decision state and calls the existing store/service
// through value clients. No new writer, replay, idempotency, or auto-retry.

import ComposableArchitecture
import Foundation

public enum FoodDetailLoadFailure: Error, Equatable, Sendable {
    case unauthorized
    case stale
    case message(String)
}

/// Cancellation scope for one logical write. A parent removing the detail
/// child cancels this ID; terminal journal settlement still completes in the
/// effect before any UI send is attempted.
public enum FoodDetailWriteCancelID: Hashable, Sendable {
    case current
}

/// Immutable record of a write whose terminal journal transition has already
/// been persisted by the effect. The reducer uses it only for UI/delegates.
public struct FoodDetailSettlement: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case succeeded(created: CreatedFoodLog, entry: PendingLogSubmission?)
        case failed(failure: FoodDetailSubmitFailure, entry: PendingLogSubmission?)
    }

    public let requestID: UUID
    public let attempt: PendingLogSubmission
    public let ownerAccountID: String
    public let generation: UInt64
    public let context: FeatureRequestContext
    public let recovery: Bool
    public let outcome: Outcome
}

public enum FoodDetailSubmitFailure: Equatable, Sendable {
    case unauthorized
    case stale
    case failed(String)
    case uncertain(String)
    case conflict(String)
    case rateLimited(Int?)
}

@Reducer
public struct FoodDetailFeature {
    @ObservableState
    public struct State: Equatable {
        // Immutable context captured when the detail was opened.
        public let foodID: String
        public let originDate: LocalDiaryDate
        public let originMealSlot: MealSlot?
        public let accountID: String
        public let sessionGeneration: UInt64
        public let presentationID: UUID
        public let baseURL: URL?
        public let foodName: String?

        public var load: FoodDetailLoadState = .loading
        /// Resolved food is separate from the public no-payload load state,
        /// exactly as the retired VM kept it in its private resolved state.
        public var loadedFood: FoodDetail?
        public var units: [FoodUnit] = []
        public var amount = ""
        public var unit = ""
        public var mealSlot: MealSlot?
        public var notes = ""
        public var submit: FoodDetailSubmitState = .idle
        public var recovery: FoodDetailRecoveryState = .idle
        public var pending: [PendingLogSubmission] = []
        public var visiblePending: [PendingLogSubmission] = []
        public var hidesPendingNotice = false
        public var lastUsedNotice: String?
        public var newSubmissionConfirmationID: String?
        public var lastSubmissionSuccess: FoodLogSubmissionSuccess?

        public var quantityWasEdited = false
        public var formWasEdited = false
        public var hasAttemptedSubmission = false
        public var frozenTimeZone: String?
        public var currentAttemptID: String?
        public var activeWriteRequestID: UUID?
        public var lastPendingIDs: Set<String> = []
        public var loadRequestID: UUID?
        public var lastUsedRequestID: UUID?

        public init(
            foodID: String,
            date: LocalDiaryDate,
            slot: MealSlot? = nil,
            generation: UInt64,
            accountID: String,
            presentationID: UUID = UUID(),
            baseURL: URL? = nil,
            foodName: String? = nil
        ) {
            self.foodID = foodID
            self.originDate = date
            self.originMealSlot = slot
            self.sessionGeneration = generation
            self.accountID = accountID
            self.presentationID = presentationID
            self.baseURL = baseURL
            self.foodName = foodName
            self.mealSlot = slot
        }

        public var food: FoodDetail? { loadedFood }

        public var availableUnits: [FoodUnit] {
            sourceUnits(food: food, units: units)
        }

        public var amountValidationMessage: String? { validateLogAmount(amount)?.message }

        public var submitErrorMessage: String? {
            if case .failed(let message) = submit { message } else { nil }
        }

        public var submitWarningMessage: String? {
            switch submit {
            case .uncertain(let message), .conflict(let message), .rateLimited(let message): message
            case .idle, .submitting, .failed, .succeeded: nil
            }
        }

        public var isSubmitting: Bool {
            if case .submitting = submit { true } else { false }
        }

        public var isRetryingPending: Bool {
            if case .retrying = recovery { true } else { false }
        }

        public var isBusy: Bool { isSubmitting || isRetryingPending }

        public var didSubmitSuccessfully: Bool {
            if case .succeeded = submit { true } else { false }
        }

        public var isFormEditable: Bool { !isBusy && !didSubmitSuccessfully }

        public var requiresNewSubmissionConfirmation: Bool { newSubmissionConfirmationID != nil }

        public var pendingRecoverySubmission: PendingLogSubmission? { visiblePending.first }

        public var nutritionPreview: [NutrientAmount]? {
            guard let food else { return nil }
            return makeNutritionPreview(for: food, amount: amount, unit: unit)
        }

        public var displayName: String { food?.name ?? foodName ?? foodID }

        public var requestContext: FeatureRequestContext {
            FeatureRequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                presentationID: presentationID
            )
        }
    }

    public struct LoadPayload: Equatable, Sendable {
        public let food: FoodDetail
        public let units: [FoodUnit]
    }

    public enum Action: Equatable, Sendable {
        case load
        case loadCompleted(requestID: UUID, context: FeatureRequestContext, result: Result<LoadPayload, FoodDetailLoadFailure>)
        case lastUsedCompleted(requestID: UUID, context: FeatureRequestContext, result: Result<RecentLogItem?, FoodDetailLoadFailure>)
        case amountChanged(String)
        case unitChanged(String)
        case mealSlotChanged(MealSlot?)
        case notesChanged(String)
        case dismissLastUsedNotice
        case dismissPendingNotice
        case submit
        case submitConfirmedNew
        case retryPending(id: String?)
        case discardPending(id: String)
        case checkDiary
        case journalRevision
        case refreshRecoveryEntries
        /// Sent by the parent when the detail child is removed. Cancels only
        /// the write effect; the effect still settles the frozen journal.
        case scopeTeardown
        /// UI-only action. Terminal journal marks are already persisted by the
        /// effect that produced this value; the reducer must not repeat them.
        case settled(settlement: FoodDetailSettlement)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        /// Delivered once per successful logical submission. `submission` carries
        /// the frozen journal identity so the parent can deduplicate by source,
        /// account, generation, and submission ID.
        case logged(
            date: LocalDiaryDate,
            slot: MealSlot?,
            generation: UInt64,
            submission: FoodLogSubmissionSuccess
        )
        case sessionExpired(generation: UInt64)
        case checkDiary(date: LocalDiaryDate, generation: UInt64)
        case dismiss(generation: UInt64)
    }

    public struct Client: Sendable {
        public var fetchFood: @Sendable (FeatureRequestContext, String) async throws -> FoodDetail
        public var fetchUnits: @Sendable (FeatureRequestContext) async throws -> [FoodUnit]
        public var lastUsed: @Sendable (FeatureRequestContext, LogSubmissionItem, LocalDiaryDate, MealSlot?) async throws -> RecentLogItem?
        public var createLog: @Sendable (FeatureRequestContext, FoodLogCreateRequest) async throws -> CreatedFoodLog
        public var makeID: @Sendable () -> String
        public var timeZoneIdentifier: @Sendable () -> String

        public init(
            fetchFood: @escaping @Sendable (FeatureRequestContext, String) async throws -> FoodDetail,
            fetchUnits: @escaping @Sendable (FeatureRequestContext) async throws -> [FoodUnit],
            lastUsed: @escaping @Sendable (FeatureRequestContext, LogSubmissionItem, LocalDiaryDate, MealSlot?) async throws -> RecentLogItem?,
            createLog: @escaping @Sendable (FeatureRequestContext, FoodLogCreateRequest) async throws -> CreatedFoodLog,
            makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
            timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
        ) {
            self.fetchFood = fetchFood
            self.fetchUnits = fetchUnits
            self.lastUsed = lastUsed
            self.createLog = createLog
            self.makeID = makeID
            self.timeZoneIdentifier = timeZoneIdentifier
        }

        /// D supplies `isCurrent` from the live session authority. No metadata
        /// transport is entered unless the captured owner is still current.
        public static func live(
            service: any FoodDetailServicing,
            isCurrent: @escaping FeatureContextGuard
        ) -> Self {
            func guardContext(_ context: FeatureRequestContext) async throws {
                guard await isCurrent(context) else { throw FeatureContextError.stale }
            }
            return Self(
                fetchFood: { context, id in
                    try await guardContext(context)
                    return try await service.fetchFoodDetail(id: id)
                },
                fetchUnits: { context in
                    try await guardContext(context)
                    return try await service.fetchUnits()
                },
                lastUsed: { context, item, date, slot in
                    try await guardContext(context)
                    return try await service.lastUsed(for: item, date: date, mealSlot: slot)
                },
                createLog: { context, request in
                    try await guardContext(context)
                    return try await service.createLog(request)
                }
            )
        }
    }

    /// Value facade over the frozen `LogSubmissionStore`. Each closure is a
    /// direct call to the existing store method; the state machine and bytes
    /// barriers entirely remain in that store.
    public struct JournalClient: Sendable {
        // Function types must not carry argument labels; each closure takes
        // positional arguments (the live adapter keeps the frozen store's
        // labelled method calls intact).
        public var unresolved: @Sendable (String, String, LocalDiaryDate) -> [PendingLogSubmission]
        public var entry: @Sendable (String, String) -> PendingLogSubmission?
        public var requireEntry: @Sendable (String, String) throws -> PendingLogSubmission
        public var reserve: @Sendable (
            String, String, LogSubmissionDraft, FoodLogCreateRequest, Data
        ) throws -> PendingLogSubmission
        public var markInFlight: @Sendable (String, String) throws -> Void
        public var markUncertain: @Sendable (String, String, Int?, String, Int?) throws -> Void
        public var markSucceeded: @Sendable (
            String, String, String?, LocalDiaryDate, MealSlot?, Bool
        ) throws -> Void
        public var markRejected: @Sendable (String, String, Int, String) throws -> Void
        public var markConflicted: @Sendable (String, String, String) throws -> Void
        public var remove: @Sendable (String, String) throws -> Void
        public var isRetryBlocked: @Sendable (String) -> Bool
        public var isLiveSubmission: @Sendable (String) -> Bool
        public var revisionUpdates: @Sendable () -> AsyncStream<Void>
        public static func live(store: LogSubmissionStore) -> Self {
            // The store is @MainActor; TCA Store/TestStore reduce on the main
            // actor. The unchecked wrapper only carries the reference into
            // @Sendable closures; every call is still made with assumeIsolated.
            let journal = UncheckedJournal(store: store)
            return Self(
                unresolved: { account, foodID, date in
                    MainActor.assumeIsolated {
                        journal.store.unresolved(accountID: account, foodID: foodID, date: date)
                    }
                },
                entry: { id, account in
                    MainActor.assumeIsolated {
                        journal.store.entry(id: id, accountID: account)
                    }
                },
                requireEntry: { id, account in
                    try MainActor.assumeIsolated {
                        try journal.store.requireEntry(id: id, accountID: account)
                    }
                },
                reserve: { account, name, draft, request, body in
                    try MainActor.assumeIsolated {
                        try journal.store.reserve(
                            accountID: account,
                            foodName: name,
                            draft: draft,
                            request: request,
                            body: body
                        )
                    }
                },
                markInFlight: { id, account in
                    try MainActor.assumeIsolated {
                        try journal.store.markInFlight(id: id, accountID: account)
                    }
                },
                markUncertain: { id, account, status, message, retryAfter in
                    try MainActor.assumeIsolated {
                        try journal.store.markUncertain(
                            id: id,
                            accountID: account,
                            status: status,
                            message: message,
                            retryAfterSeconds: retryAfter
                        )
                    }
                },
                markSucceeded: { id, account, logID, date, slot, replayed in
                    try MainActor.assumeIsolated {
                        try journal.store.markSucceeded(
                            id: id,
                            accountID: account,
                            logID: logID,
                            date: date,
                            mealSlot: slot,
                            replayed: replayed
                        )
                    }
                },
                markRejected: { id, account, status, message in
                    try MainActor.assumeIsolated {
                        try journal.store.markRejected(
                            id: id,
                            accountID: account,
                            status: status,
                            message: message
                        )
                    }
                },
                markConflicted: { id, account, message in
                    try MainActor.assumeIsolated {
                        try journal.store.markConflicted(id: id, accountID: account, message: message)
                    }
                },
                remove: { id, account in
                    try MainActor.assumeIsolated {
                        try journal.store.remove(id: id, accountID: account)
                    }
                },
                isRetryBlocked: { id in
                    MainActor.assumeIsolated { journal.store.isRetryBlocked(id: id) }
                },
                isLiveSubmission: { id in
                    MainActor.assumeIsolated { journal.store.isLiveSubmission(id: id) }
                },
                revisionUpdates: {
                    AsyncStream<Void> { continuation in
                        let task = Task { @MainActor in
                            for await _ in journal.store.$revision.values.dropFirst() {
                                continuation.yield(())
                            }
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                }
            )
        }
    }

    private enum CancelID {
        case lastUsed
        case revision
    }

    @Dependency(\.foodDetailClient) private var client
    @Dependency(\.foodDetailJournalClient) private var journal
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce<State, Action> { (state: inout State, action: Action) -> Effect<Action> in
            switch action {
            case .load:
                state.load = .loading
                state.loadedFood = nil
                state.lastUsedNotice = nil
                state.quantityWasEdited = false
                state.formWasEdited = false
                state.hasAttemptedSubmission = false
                state.currentAttemptID = nil
                state.frozenTimeZone = nil
                state.newSubmissionConfirmationID = nil
                state.submit = .idle
                state.recovery = .idle
                let requestID = uuid()
                state.loadRequestID = requestID
                let foodID = state.foodID
                let context = state.requestContext
                let client = self.client
                let journal = self.journal
                return .merge(
                    .run { send in
                        do {
                            async let food = client.fetchFood(context, foodID)
                            async let units = client.fetchUnits(context)
                            let payload = try await (food, units)
                            await send(.loadCompleted(
                                requestID: requestID,
                                context: context,
                                result: .success(LoadPayload(food: payload.0, units: payload.1))
                            ))
                        } catch {
                            await send(.loadCompleted(
                                requestID: requestID,
                                context: context,
                                result: .failure(Self.mapLoadError(error))
                            ))
                        }
                    },
                    .run { send in
                        for await _ in journal.revisionUpdates() {
                            await send(.journalRevision)
                        }
                    }
                    .cancellable(id: CancelID.revision, cancelInFlight: true)
                )

            case let .loadCompleted(requestID, context, result):
                guard state.loadRequestID == requestID,
                      context == state.requestContext else { return .none }
                switch result {
                case let .success(payload):
                    state.units = payload.units
                    let defaults = payload.food.defaultLogQuantity
                    state.amount = defaults.amount
                    state.unit = defaults.unit
                    if state.mealSlot == nil { state.mealSlot = state.originMealSlot }
                    state.loadedFood = payload.food
                    state.load = .loaded
                    let lastUsedID = uuid()
                    state.lastUsedRequestID = lastUsedID
                    let lastUsedFoodID = payload.food.id
                    let lastUsedDate = state.originDate
                    let lastUsedSlot = state.originMealSlot
                    let client = self.client
                    return .run { send in
                        do {
                            let lastUsed = try await client.lastUsed(
                                context,
                                .product(id: lastUsedFoodID),
                                lastUsedDate,
                                lastUsedSlot
                            )
                            await send(.lastUsedCompleted(
                                requestID: lastUsedID,
                                context: context,
                                result: .success(lastUsed)
                            ))
                        } catch {
                            await send(.lastUsedCompleted(
                                requestID: lastUsedID,
                                context: context,
                                result: .failure(Self.mapLoadError(error))
                            ))
                        }
                    }
                    .cancellable(id: CancelID.lastUsed, cancelInFlight: true)

                case let .failure(failure):
                    switch failure {
                    case .unauthorized:
                        state.load = .failed(String(localized: "foodDetail.error.sessionExpired"))
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    case .stale:
                        break
                    case .message(let message):
                        state.load = .failed(message)
                    }
                }
                refreshRecovery(&state)
                return .none

            case let .lastUsedCompleted(requestID, context, result):
                guard state.lastUsedRequestID == requestID,
                      context == state.requestContext else { return .none }
                switch result {
                case let .success(lastUsed):
                    applyLastUsed(lastUsed, to: &state)
                case let .failure(failure):
                    switch failure {
                    case .unauthorized:
                        return .send(.delegate(.sessionExpired(
                            generation: state.sessionGeneration
                        )))
                    case .stale, .message:
                        break
                    }
                }
                refreshRecovery(&state)
                return .none

            case let .amountChanged(value):
                state.quantityWasEdited = true
                formDidChange(&state)
                state.amount = value
                return .none

            case let .unitChanged(value):
                state.quantityWasEdited = true
                formDidChange(&state)
                state.unit = value
                return .none

            case let .mealSlotChanged(slot):
                formDidChange(&state)
                state.mealSlot = slot
                return .none

            case let .notesChanged(notes):
                formDidChange(&state)
                state.notes = notes
                return .none

            case .dismissLastUsedNotice:
                state.lastUsedNotice = nil
                return .none

            case .dismissPendingNotice:
                state.hidesPendingNotice = true
                return .none

            case .submit:
                return submit(&state, authorizingNewLogicalSubmission: false)

            case .submitConfirmedNew:
                guard state.newSubmissionConfirmationID != nil else { return .none }
                state.newSubmissionConfirmationID = nil
                return submit(&state, authorizingNewLogicalSubmission: true)

            case let .retryPending(id):
                return retryPending(id, state: &state)

            case let .discardPending(id):
                guard let entry = state.pending.first(where: { $0.id == id }),
                      entry.accountID == state.accountID,
                      entry.state == .conflicted else { return .none }
                do {
                    try journal.remove(id, state.accountID)
                } catch {
                    state.recovery = .failed(String(localized: "foodDetail.error.saveFailed"))
                    return .none
                }
                if state.currentAttemptID == id { state.currentAttemptID = nil }
                if state.newSubmissionConfirmationID == id { state.newSubmissionConfirmationID = nil }
                state.pending.removeAll { $0.id == id }
                if case .conflict = state.submit { state.submit = .idle }
                refreshRecovery(&state)
                return .none

            case .checkDiary:
                let date = state.pendingRecoverySubmission?.draft.date ?? state.originDate
                return .send(.delegate(.checkDiary(date: date, generation: state.sessionGeneration)))

            case .journalRevision, .refreshRecoveryEntries:
                refreshRecovery(&state)
                return .none

            case .scopeTeardown:
                // The effect owns durable settlement; cancellation only stops
                // UI delivery. No journal action is taken here.
                return .cancel(id: FoodDetailWriteCancelID.current)

            case let .settled(settlement):
                guard settlement.requestID == state.activeWriteRequestID,
                      state.currentAttemptID == settlement.attempt.id,
                      !state.didSubmitSuccessfully else { return .none }
                state.activeWriteRequestID = nil
                guard settlement.context == state.requestContext,
                      settlement.generation == state.sessionGeneration else { return .none }
                // The effect already persisted the terminal journal transition.
                // This reducer only applies UI state and one typed delegate.
                switch settlement.outcome {
                case let .succeeded(created, entry):
                    return applySettledSuccess(
                        attempt: entry ?? settlement.attempt,
                        created: created,
                        recovery: settlement.recovery,
                        state: &state
                    )
                case let .failed(failure, _):
                    return applySettledFailure(
                        failure, recovery: settlement.recovery, state: &state
                    )
                }

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Effects

    private func submit(_ state: inout State, authorizingNewLogicalSubmission: Bool) -> Effect<Action> {
        guard !state.isBusy, !state.didSubmitSuccessfully,
              case .loaded = state.load else { return .none }
        if let message = state.amountValidationMessage {
            state.submit = .failed(message)
            return .none
        }
        refreshRecovery(&state)

        let attemptTimeZone = state.currentAttemptID
            .flatMap { journal.entry($0, state.accountID)?.draft.timeZone }
        if let id = state.currentAttemptID {
            guard let stored = journal.entry(id, state.accountID) else {
                state.currentAttemptID = nil
                state.submit = .failed(String(localized: "foodDetail.error.saveFailed"))
                return .none
            }
            if stored.state == .succeeded {
                return deliverStoredSuccess(stored, recovery: false, state: &state)
            }
            if stored.state == .invalidated {
                state.currentAttemptID = nil
                state.submit = .failed(blockedDeletionMessage(stored))
                return .none
            }
            if stored.state != .rejected {
                if !authorizingNewLogicalSubmission {
                    blockForUnresolved(stored, state: &state)
                    return .none
                }
            } else {
                state.currentAttemptID = nil
            }
        }

        let timeZone = state.frozenTimeZone
            ?? attemptTimeZone
            ?? client.timeZoneIdentifier()
        let draft = LogCreateRequestBuilder.makeDraft(
            foodID: state.foodID,
            date: state.originDate,
            mealSlot: state.mealSlot,
            amount: state.amount,
            unit: state.unit,
            notes: state.notes,
            timeZoneIdentifier: timeZone
        )
        if !authorizingNewLogicalSubmission,
           let matching = state.pending.first(where: { draftFieldsMatch($0.draft, draft) }) {
            blockForUnresolved(matching, state: &state)
            return .none
        }

        state.hasAttemptedSubmission = true
        state.frozenTimeZone = timeZone
        state.newSubmissionConfirmationID = nil
        let key = client.makeID()
        do {
            let prepared = try LogCreateRequestBuilder.prepare(
                foodID: state.foodID,
                foodName: state.displayName,
                date: state.originDate,
                mealSlot: draft.mealSlot,
                amount: draft.amount,
                unit: draft.unit,
                notes: draft.notes,
                timeZoneIdentifier: timeZone,
                baseURL: state.baseURL,
                idempotencyKey: key
            )
            let entry = try journal.reserve(state.accountID, state.displayName, prepared.draft, prepared.request, prepared.body)
            state.currentAttemptID = entry.id
            return startSend(entry, recovery: false, state: &state)
        } catch let error as LogSubmissionStoreError {
            state.currentAttemptID = nil
            state.submit = .failed(Self.storeFailureMessage(error))
        } catch let error as LogCreateRequestBuilderError {
            state.currentAttemptID = nil
            state.submit = .failed(Self.builderFailureMessage(error))
        } catch {
            state.currentAttemptID = nil
            state.submit = .failed(String(localized: "foodDetail.error.saveFailed"))
        }
        return .none
    }

    private func retryPending(_ requestedID: String?, state: inout State) -> Effect<Action> {
        guard !state.isBusy, !state.didSubmitSuccessfully else { return .none }
        let id = requestedID ?? state.pendingRecoverySubmission?.id
        guard let id,
              let requested = state.pending.first(where: { $0.id == id }),
              requested.accountID == state.accountID else { return .none }
        let attempt: PendingLogSubmission
        do {
            attempt = try journal.requireEntry(id, state.accountID)
        } catch {
            let message = String(localized: "foodDetail.error.saveFailed")
            state.recovery = .failed(message)
            state.submit = .failed(message)
            refreshRecovery(&state)
            return .none
        }
        if attempt.state == .succeeded {
            return deliverStoredSuccess(attempt, recovery: true, state: &state)
        }
        if attempt.state == .invalidated || journal.isRetryBlocked(id) {
            let message = blockedDeletionMessage(attempt)
            state.recovery = .failed(message)
            state.submit = .failed(message)
            refreshRecovery(&state)
            return .none
        }
        if attempt.state == .conflicted || attempt.body == nil {
            let message = attempt.lastMessage ?? String(localized: "foodDetail.error.conflict")
            state.recovery = .conflicted(message)
            state.submit = .conflict(message)
            return .none
        }
        if attempt.state == .inFlight && journal.isLiveSubmission(id) {
            state.recovery = .failed(String(localized: "foodDetail.error.saveFailed"))
            return .none
        }
        guard attempt.state != .rejected else {
            state.recovery = .failed(String(localized: "foodDetail.error.saveFailed"))
            return .none
        }
        state.newSubmissionConfirmationID = nil
        state.recovery = .retrying(id)
        return startSend(attempt, recovery: true, state: &state)
    }

    /// Reserve → markInFlight → requireEntry → single service write. The exact
    /// stored body and key are used; no re-encode and no automatic retry.
    private func startSend(
        _ entry: PendingLogSubmission,
        recovery: Bool,
        state: inout State
    ) -> Effect<Action> {
        do {
            try journal.markInFlight(entry.id, state.accountID)
            let attempt = try journal.requireEntry(entry.id, state.accountID)
            if attempt.state == .invalidated || journal.isRetryBlocked(attempt.id) {
                let message = blockedDeletionMessage(attempt)
                state.currentAttemptID = nil
                state.submit = .failed(message)
                if recovery { state.recovery = .failed(message) }
                refreshRecovery(&state)
                return .none
            }
            state.currentAttemptID = attempt.id
            guard let request = attempt.request else {
                let message = String(localized: "foodDetail.error.saveFailed")
                try? journal.markUncertain(attempt.id, state.accountID, nil, message, nil)
                state.submit = .failed(message)
                if recovery { state.recovery = .failed(message) }
                refreshRecovery(&state)
                return .none
            }
            if !recovery { state.submit = .submitting }
            let generation = state.sessionGeneration
            let context = state.requestContext
            let ownerAccountID = state.accountID
            let capturedBaseURL = state.baseURL
            let requestID = uuid()
            state.activeWriteRequestID = requestID
            return .run { send in
                // Durable terminal settlement happens here, on the main actor,
                // with the ORIGINAL owner identity — before any UI send and
                // with no cancellation check. A known server reply is never
                // discarded just because the child scope went away.
                let settlement: FoodDetailSettlement
                do {
                    let created = try await client.createLog(context, request)
                    let settledEntry = await MainActor.run { () -> PendingLogSubmission? in
                        try? journal.markSucceeded(
                            attempt.id, ownerAccountID, created.id,
                            created.date, created.mealSlot, created.replayed
                        )
                        return journal.entry(attempt.id, ownerAccountID)
                    }
                    settlement = FoodDetailSettlement(
                        requestID: requestID,
                        attempt: attempt,
                        ownerAccountID: ownerAccountID,
                        generation: generation,
                        context: context,
                        recovery: recovery,
                        outcome: .succeeded(created: created, entry: settledEntry)
                    )
                } catch {
                    let failure = Self.mapSubmitError(error)
                    let settledEntry = await MainActor.run {
                        Self.settleFailure(
                            failure,
                            attempt: attempt,
                            ownerAccountID: ownerAccountID,
                            capturedBaseURL: capturedBaseURL,
                            journal: journal
                        )
                    }
                    settlement = FoodDetailSettlement(
                        requestID: requestID,
                        attempt: attempt,
                        ownerAccountID: ownerAccountID,
                        generation: generation,
                        context: context,
                        recovery: recovery,
                        outcome: .failed(failure: failure, entry: settledEntry)
                    )
                }
                // Only UI delivery is scope-aware. The journal is durable now.
                guard !Task.isCancelled else { return }
                await send(.settled(settlement: settlement))
            }
            .cancellable(id: FoodDetailWriteCancelID.current, cancelInFlight: false)
        } catch {
            let message = String(localized: "foodDetail.error.saveFailed")
            state.submit = .failed(message)
            if recovery { state.recovery = .failed(message) }
            refreshRecovery(&state)
            return .none
        }
    }

    // MARK: - UI-only settlement (the effect already persisted the journal)

    /// Replays the authoritative result already stored in the frozen journal.
    /// No transport, no new key, no new journal transition. The original
    /// submission ID, account, date and slot stay the identity of the result;
    /// a second delivery for the same submission is suppressed.
    private func deliverStoredSuccess(
        _ entry: PendingLogSubmission,
        recovery: Bool,
        state: inout State
    ) -> Effect<Action> {
        guard entry.accountID == state.accountID,
              let date = entry.resultDate else { return .none }
        let success = FoodLogSubmissionSuccess(
            submissionID: entry.id,
            accountID: entry.accountID,
            foodID: entry.draft.foodID,
            foodName: entry.foodName,
            date: date,
            mealSlot: entry.resultMealSlot ?? entry.draft.mealSlot,
            logID: entry.resultLogID,
            replayed: entry.replayed
        )
        let alreadyDelivered = state.lastSubmissionSuccess?.submissionID == entry.id
        state.currentAttemptID = nil
        state.newSubmissionConfirmationID = nil
        state.lastSubmissionSuccess = success
        state.submit = .succeeded
        if recovery { state.recovery = .succeeded(entry.id) }
        refreshRecovery(&state)
        guard !alreadyDelivered else { return .none }
        return .send(.delegate(.logged(
            date: success.date,
            slot: success.mealSlot,
            generation: state.sessionGeneration,
            submission: success
        )))
    }

    private func applySettledSuccess(
        attempt: PendingLogSubmission,
        created: CreatedFoodLog,
        recovery: Bool,
        state: inout State
    ) -> Effect<Action> {
        let success = FoodLogSubmissionSuccess(
            submissionID: attempt.id,
            accountID: attempt.accountID,
            foodID: attempt.draft.foodID,
            foodName: attempt.foodName,
            date: attempt.resultDate ?? attempt.draft.date,
            mealSlot: created.mealSlot ?? attempt.resultMealSlot ?? attempt.draft.mealSlot,
            logID: created.id,
            replayed: created.replayed
        )
        state.currentAttemptID = nil
        state.newSubmissionConfirmationID = nil
        state.lastSubmissionSuccess = success
        state.submit = .succeeded
        if recovery { state.recovery = .succeeded(attempt.id) }
        refreshRecovery(&state)
        return .send(.delegate(.logged(
            date: success.date,
            slot: success.mealSlot,
            generation: state.sessionGeneration,
            submission: success
        )))
    }

    private func applySettledFailure(
        _ failure: FoodDetailSubmitFailure,
        recovery: Bool,
        state: inout State
    ) -> Effect<Action> {
        var expireSession = false
        switch failure {
        case .stale:
            break
        case .unauthorized:
            let message = String(localized: "foodDetail.error.sessionExpired")
            state.submit = .failed(message)
            if recovery { state.recovery = .failed(message) }
            state.currentAttemptID = nil
            expireSession = true
        case let .uncertain(message):
            state.submit = .uncertain(message)
            if recovery { state.recovery = .failed(message) }
        case let .conflict(message):
            state.submit = .conflict(message)
            if recovery { state.recovery = .conflicted(message) }
        case let .rateLimited(retryAfter):
            _ = retryAfter
            let message = String(localized: "foodDetail.error.rateLimited")
            state.submit = .rateLimited(message)
            if recovery { state.recovery = .failed(message) }
        case let .failed(message):
            state.submit = .failed(message)
            if recovery { state.recovery = .failed(message) }
            state.currentAttemptID = nil
        }
        refreshRecovery(&state)
        return expireSession
            ? .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
            : .none
    }

    /// Effect-side terminal settlement. Uses only the captured original
    /// account/id/body/date/slot and the existing frozen store transitions.
    /// No cancellation check is performed before the marks.
    private static func settleFailure(
        _ failure: FoodDetailSubmitFailure,
        attempt: PendingLogSubmission,
        ownerAccountID: String,
        capturedBaseURL: URL?,
        journal: FoodDetailFeature.JournalClient
    ) -> PendingLogSubmission? {
        switch failure {
        case .stale:
            break
        case .unauthorized:
            try? journal.markUncertain(
                attempt.id, ownerAccountID, 401,
                String(localized: "foodDetail.error.sessionExpired"), nil
            )
        case let .uncertain(message):
            try? journal.markUncertain(attempt.id, ownerAccountID, nil, message, nil)
        case let .conflict(message):
            try? journal.markConflicted(attempt.id, ownerAccountID, message)
        case let .rateLimited(retryAfter):
            try? journal.markUncertain(
                attempt.id, ownerAccountID, 429,
                String(localized: "foodDetail.error.rateLimited"), retryAfter
            )
        case let .failed(message):
            if !attempt.baseURLString.isEmpty,
               let capturedBaseURL,
               attempt.baseURLString != capturedBaseURL.absoluteString {
                try? journal.markUncertain(attempt.id, ownerAccountID, nil, message, nil)
            } else {
                try? journal.markRejected(attempt.id, ownerAccountID, 400, message)
            }
        }
        return journal.entry(attempt.id, ownerAccountID)
    }

    private func formDidChange(_ state: inout State) {
        guard !state.didSubmitSuccessfully else { return }
        state.formWasEdited = true
        state.currentAttemptID = nil
        state.frozenTimeZone = nil
        state.newSubmissionConfirmationID = nil
        switch state.submit {
        case .failed, .uncertain, .conflict, .rateLimited:
            state.submit = .idle
        case .idle, .submitting, .succeeded:
            break
        }
    }

    private func applyLastUsed(_ lastUsed: RecentLogItem?, to state: inout State) {
        guard !state.formWasEdited,
              !state.hasAttemptedSubmission,
              state.currentAttemptID == nil,
              state.pending.isEmpty,
              state.newSubmissionConfirmationID == nil,
              let quantity = lastUsed?.quantity,
              !state.quantityWasEdited,
              positiveAmount(quantity.amount) != nil,
              let food = state.food else { return }
        let allowed = sourceUnits(food: food, units: state.units)
        guard allowed.isEmpty || allowed.contains(where: { $0.code == quantity.unit }) else {
            state.lastUsedNotice = String(localized: "foodDetail.lastUsed.unavailableUnit")
            return
        }
        state.amount = quantity.amount
        state.unit = quantity.unit
    }

    private func refreshRecovery(_ state: inout State) {
        var entries = journal.unresolved(state.accountID, state.foodID, state.originDate)
        if let id = state.currentAttemptID,
           let stored = journal.entry(id, state.accountID),
           stored.state == .inFlight || stored.state == .uncertain || stored.state == .conflicted {
            if !journal.isRetryBlocked(id) {
                state.currentAttemptID = stored.id
                if !entries.contains(where: { $0.id == stored.id }) {
                    entries.insert(stored, at: 0)
                }
            } else {
                state.currentAttemptID = nil
            }
        }
        let ids = Set(entries.map(\.id))
        if ids != state.lastPendingIDs {
            state.hidesPendingNotice = false
            state.lastPendingIDs = ids
        }
        if let id = state.newSubmissionConfirmationID,
           !entries.contains(where: { $0.id == id }) {
            state.newSubmissionConfirmationID = nil
        }
        state.pending = entries
        state.visiblePending = entries.filter { pending in
            guard pending.state == .inFlight else { return true }
            return !journal.isLiveSubmission(pending.id)
        }
    }

    private func blockForUnresolved(_ entry: PendingLogSubmission, state: inout State) {
        state.newSubmissionConfirmationID = entry.id
        state.hidesPendingNotice = false
        switch entry.state {
        case .conflicted:
            state.submit = .conflict(entry.lastMessage ?? String(localized: "foodDetail.error.conflict"))
        case .inFlight, .uncertain:
            state.submit = .uncertain(entry.lastMessage ?? String(localized: "foodDetail.error.uncertain"))
        case .invalidated:
            state.submit = .failed(blockedDeletionMessage(entry))
        case .succeeded, .rejected:
            break
        }
    }

    private func draftFieldsMatch(_ lhs: LogSubmissionDraft, _ rhs: LogSubmissionDraft) -> Bool {
        lhs.foodID == rhs.foodID
            && lhs.date == rhs.date
            && lhs.mealSlot == rhs.mealSlot
            && lhs.amount == rhs.amount
            && lhs.unit == rhs.unit
            && lhs.notes == rhs.notes
    }

    private func blockedDeletionMessage(_ entry: PendingLogSubmission) -> String {
        if entry.state == .invalidated,
           let stored = entry.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return String(localized: "foodDetail.pending.invalidated")
    }

    // MARK: - Error mapping

    private static func mapLoadError(_ error: Error) -> FoodDetailLoadFailure {
        if error is FeatureContextError { return .stale }
        if isUnauthorizedFoodDetailError(error) { return .unauthorized }
        return .message(foodDetailErrorMessage(error))
    }

    private static func mapSubmitError(_ error: Error) -> FoodDetailSubmitFailure {
        if error is FeatureContextError { return .stale }
        if isUnauthorizedFoodDetailError(error) { return .unauthorized }
        guard let serviceError = error as? FoodDetailServiceError else {
            return .uncertain(error.localizedDescription)
        }
        switch serviceError {
        case .unauthorized:
            return .unauthorized
        case .failed(let message):
            return .failed(message)
        case .uncertain(let message):
            return .uncertain(message)
        case .conflict(let message):
            return .conflict(message)
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter)
        }
    }

    private static func storeFailureMessage(_ error: LogSubmissionStoreError) -> String {
        switch error {
        case .unreadableJournal:
            return String(localized: "foodDetail.error.journalUnavailable")
        case .missingEntry, .submissionInFlight, .invalidAccount, .invalidRequest,
             .bodyTooLarge, .tooManyEntries, .persistence:
            return String(localized: "foodDetail.error.saveFailed")
        }
    }

    private static func builderFailureMessage(_ error: LogCreateRequestBuilderError) -> String {
        switch error {
        case .bodyTooLarge: String(localized: "foodDetail.error.notesTooLong")
        case .invalidKey, .invalidItem, .encoding: String(localized: "foodDetail.error.saveFailed")
        }
    }
}

private final class UncheckedJournal: @unchecked Sendable {
    let store: LogSubmissionStore
    init(store: LogSubmissionStore) { self.store = store }
}

extension DependencyValues {
    public var foodDetailClient: FoodDetailFeature.Client {
        get { self[FoodDetailClientKey.self] }
        set { self[FoodDetailClientKey.self] = newValue }
    }

    public var foodDetailJournalClient: FoodDetailFeature.JournalClient {
        get { self[FoodDetailJournalClientKey.self] }
        set { self[FoodDetailJournalClientKey.self] = newValue }
    }
}

private enum FoodDetailClientKey: DependencyKey {
    static let liveValue: FoodDetailFeature.Client = .init(
        fetchFood: { _, _ in throw FoodDetailServiceError.failed(String(localized: "foodDetail.error.saveFailed")) },
        fetchUnits: { _ in [] },
        lastUsed: { _, _, _, _ in nil },
        createLog: { _, _ in throw FoodDetailServiceError.failed(String(localized: "foodDetail.error.saveFailed")) }
    )
    static let testValue = liveValue
}

private enum FoodDetailJournalClientKey: DependencyKey {
    static let liveValue: FoodDetailFeature.JournalClient = .live(store: .shared)
    static let testValue: FoodDetailFeature.JournalClient = .live(store: .shared)
}
