import ComposableArchitecture
import Foundation

@Reducer
public struct DiaryLatestFeature {
    public typealias Cache = ResourceCache<LocalDiaryDate, [DiaryLatestSlot], DiaryServiceError>
    public typealias Token = Cache.RequestToken

    public static let lookbackDays = 30

    public enum Activity: Equatable, Sendable {
        case settled
        case refreshing(token: Token)
        case failed(token: Token, message: String)
    }

    public enum Phase: Equatable, Sendable {
        case idle(destinationDate: LocalDiaryDate)
        case loading(destinationDate: LocalDiaryDate, slot: MealSlot?, token: Token)
        case loaded(destinationDate: LocalDiaryDate, slots: [DiaryLatestSlot], loadedForDate: LocalDiaryDate, activity: Activity)
        case failed(destinationDate: LocalDiaryDate, message: String, token: Token?)
        case sessionExpired(destinationDate: LocalDiaryDate)

        public var destinationDate: LocalDiaryDate {
            switch self {
            case .idle(let destinationDate),
                 .loading(let destinationDate, _, _),
                 .loaded(let destinationDate, _, _, _),
                 .failed(let destinationDate, _, _),
                 .sessionExpired(let destinationDate):
                return destinationDate
            }
        }
    }

    public struct CopyRequest: Equatable, Sendable {
        public let requestID: UUID
        public let sessionGeneration: UInt64
        public let destinationDate: LocalDiaryDate
        public let destinationSlot: MealSlot
        public let review: DiaryLatestReview
        public let timeZone: String
        public let drafts: [LogSubmissionDraft]
    }

    public struct SubmissionClient: Sendable {
        public var submit: @MainActor @Sendable (
            [LogSubmissionDraft],
            [String],
            String,
            UInt64
        ) async -> LogSubmissionServiceResult
        public static func live(
            submissionHandler: LogSubmissionHandler?,
            isCurrentGeneration: @escaping @MainActor @Sendable (UInt64) -> Bool
        ) -> Self {
            Self { drafts, itemNames, summary, expectedGeneration in
                guard isCurrentGeneration(expectedGeneration) else {
                    return .failure(.unauthorized)
                }
                guard let submissionHandler else {
                    return .failure(.failed(String(localized: "foodDetail.error.saveFailed")))
                }
                return await withCheckedContinuation { continuation in
                    submissionHandler(drafts, itemNames, summary) { result in
                        continuation.resume(returning: result)
                    }
                }
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var destinationDate: LocalDiaryDate
        public var today: LocalDiaryDate
        public let sessionGeneration: UInt64
        public var cache: Cache
        public var phase: Phase
        public var review: DiaryLatestReview?
        public var loadingSlot: MealSlot?
        public var errorMessage: String?

        public var copyRequest: CopyRequest?
        public var isSubmitting: Bool
        public var copyErrorMessage: String?
        public var copySucceeded: Bool

        public var selectedDate: LocalDiaryDate { destinationDate }
        public var isSessionExpired: Bool { phase.isSessionExpired }

        public init(
            destinationDate: LocalDiaryDate,
            today: LocalDiaryDate,
            sessionGeneration: UInt64,
            cache: Cache = Cache(),
            phase: Phase? = nil,
            review: DiaryLatestReview? = nil,
            loadingSlot: MealSlot? = nil,
            errorMessage: String? = nil,
            copyRequest: CopyRequest? = nil,
            isSubmitting: Bool = false,
            copyErrorMessage: String? = nil,
            copySucceeded: Bool = false
        ) {
            self.destinationDate = destinationDate
            self.today = today
            self.sessionGeneration = sessionGeneration
            self.cache = cache
            self.phase = phase ?? .idle(destinationDate: destinationDate)
            self.review = review
            self.loadingSlot = loadingSlot
            self.errorMessage = errorMessage
            self.copyRequest = copyRequest
            self.isSubmitting = isSubmitting
            self.copyErrorMessage = copyErrorMessage
            self.copySucceeded = copySucceeded
        }

        internal init(
            today: LocalDiaryDate,
            phase: Phase,
            sessionGeneration: UInt64 = 0,
            cache: Cache = Cache(),
            review: DiaryLatestReview? = nil,
            loadingSlot: MealSlot? = nil,
            errorMessage: String? = nil,
            copyRequest: CopyRequest? = nil,
            isSubmitting: Bool = false,
            copyErrorMessage: String? = nil,
            copySucceeded: Bool = false
        ) {
            self.destinationDate = phase.destinationDate
            self.today = today
            self.sessionGeneration = sessionGeneration
            self.cache = cache
            self.phase = phase
            self.review = review
            self.loadingSlot = loadingSlot
            self.errorMessage = errorMessage
            self.copyRequest = copyRequest
            self.isSubmitting = isSubmitting
            self.copyErrorMessage = copyErrorMessage
            self.copySucceeded = copySucceeded
        }
    }

    public enum Action: Equatable, Sendable {
        case loadIfNeeded
        case load
        case retry
        case refresh
        case refreshLatest
        case prepareLatest(MealSlot)
        case prepareLatestReview(MealSlot)
        case cancelLatest
        case cancelLatestReview
        case submitLatest
        case dismissCopyError
        case submitCompleted(requestID: UUID, generation: UInt64, result: LogSubmissionServiceResult)
        case dismissError
        case dismissLatestError
        case latestSlotsReceived(
            generation: UInt64,
            destinationDate: LocalDiaryDate,
            slot: MealSlot?,
            token: Token,
            result: Result<[DiaryLatestSlot], DiaryServiceError>
        )
        case latestReceived(
            generation: UInt64,
            destinationDate: LocalDiaryDate,
            slot: MealSlot?,
            token: Token,
            result: Result<[DiaryLatestSlot], DiaryServiceError>
        )
        case contextChanged(date: LocalDiaryDate, today: LocalDiaryDate)
        case invalidateCachedSuggestions(generation: UInt64)
        case expireSession
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(destinationDate: LocalDiaryDate, generation: UInt64)
        case copied(requestID: UUID, destinationDate: LocalDiaryDate, destinationSlot: MealSlot, sessionGeneration: UInt64, logs: [FoodLog])
    }

    private enum CancelID: Hashable {
        case latest
    }

    private enum RequestMode {
        case initial
        case refresh
        case retry
    }

    public struct Client: Sendable {
        public var latestSlots: @Sendable (_ before: LocalDiaryDate, _ lookbackDays: Int, _ expectedGeneration: UInt64) async throws -> [DiaryLatestSlot]
        public static func live(service: any DiaryServicing) -> Self {
            // Base/unwrapped read seam. This factory captures the supplied
            // service at creation time; it is intentionally not guarded. Future
            // runtime base-client closures must resolve the current service per
            // call after the generation precheck instead of caching one here.
            Self { before, lookbackDays, _ in
                try await service.latestSlots(before: before, lookbackDays: lookbackDays)
            }
        }

        /// Wraps `self` so generation validity is checked before and after the
        /// underlying read. Stale generations surface as `.cancelled` (never
        /// `.unauthorized`) so a stale read cannot trigger session expiry.
        public func guarded(
            isCurrentGeneration: @escaping @MainActor @Sendable (UInt64) -> Bool
        ) -> Self {
            let base = self.latestSlots
            return Self { before, lookbackDays, expectedGeneration in
                let currentBefore = await MainActor.run { isCurrentGeneration(expectedGeneration) }
                guard currentBefore else { throw DiaryServiceError.cancelled }
                do {
                    let slots = try await base(before, lookbackDays, expectedGeneration)
                    let currentAfter = await MainActor.run { isCurrentGeneration(expectedGeneration) }
                    guard currentAfter else { throw DiaryServiceError.cancelled }
                    return slots
                } catch {
                    if error is CancellationError { throw error }
                    let currentAfter = await MainActor.run { isCurrentGeneration(expectedGeneration) }
                    guard currentAfter else { throw DiaryServiceError.cancelled }
                    throw error
                }
            }
        }

        /// Factory form for late base-client/service resolution. `base` is
        /// invoked per call after the generation gate, so no service or
        /// coordinator is captured long-term.
        public static func guarded(
            base: @escaping @Sendable (LocalDiaryDate, Int, UInt64) async throws -> [DiaryLatestSlot],
            isCurrentGeneration: @escaping @MainActor @Sendable (UInt64) -> Bool
        ) -> Self {
            Self(latestSlots: base).guarded(isCurrentGeneration: isCurrentGeneration)
        }

    }

    @Dependency(\.diaryLatestClient) private var diaryLatestClient
    @Dependency(\.diaryLatestSubmissionClient) private var diaryLatestSubmissionClient
    @Dependency(\.timeZone) private var timeZone
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadIfNeeded:
                guard !state.isSubmitting else { return .none }
                guard !state.isSessionExpired else { return .none }
                switch state.phase {
                case .loading:
                    return .none
                case .loaded:
                    switch state.cache.entry(for: state.destinationDate) {
                    case .notRequested, .settled(.failure):
                        return startRead(state: &state, slot: nil, mode: .refresh)
                    case .inFlight, .settled(.success):
                        return .none
                    }
                case .idle, .failed:
                    if case .settled(.success(let cachedSlots)) = state.cache.entry(for: state.destinationDate) {
                        state.phase = .loaded(
                            destinationDate: state.destinationDate,
                            slots: cachedSlots,
                            loadedForDate: state.destinationDate,
                            activity: .settled
                        )
                        state.loadingSlot = nil
                        state.errorMessage = nil
                        return .none
                    }
                    return startRead(state: &state, slot: nil, mode: .initial)
                case .sessionExpired:
                    return .none
                }

            case .load, .retry:
                guard !state.isSubmitting else { return .none }
                guard !state.isSessionExpired else { return .none }
                return startRead(state: &state, slot: nil, mode: .initial)

            case .refresh, .refreshLatest:
                guard !state.isSubmitting else { return .none }
                guard !state.isSessionExpired else { return .none }
                return startRead(state: &state, slot: nil, mode: .refresh)

            case let .prepareLatest(slot):
                return prepareLatest(state: &state, slot: slot)

            case let .prepareLatestReview(slot):
                return prepareLatest(state: &state, slot: slot)

            case .cancelLatest:
                cancelUnderlyingRead(state: &state)
                return .cancel(id: CancelID.latest)

            case .cancelLatestReview:
                guard !state.isSubmitting else { return .none }
                cancelUnderlyingRead(state: &state)
                state.review = nil
                state.errorMessage = nil
                state.copyErrorMessage = nil
                state.copyRequest = nil
                return .cancel(id: CancelID.latest)

            case .dismissError, .dismissLatestError:
                state.errorMessage = nil
                return .none

            case .dismissCopyError:
                state.copyErrorMessage = nil
                return .none

            case .submitLatest:
                return submitLatest(state: &state)

            case let .submitCompleted(requestID, generation, result):
                return handleSubmissionCompletion(
                    state: &state,
                    requestID: requestID,
                    generation: generation,
                    result: result
                )

            case let .latestSlotsReceived(generation, requestDate, slot, token, result),
                 let .latestReceived(generation, requestDate, slot, token, result):
                return handleCompletion(
                    state: &state,
                    generation: generation,
                    requestDate: requestDate,
                    slot: slot,
                    token: token,
                    result: result
                )

            case let .contextChanged(date, today):
                return contextChanged(state: &state, date: date, today: today)

            case let .invalidateCachedSuggestions(generation):
                guard generation == state.sessionGeneration, !state.isSessionExpired else { return .none }
                // Any changed log date can be a source in another destination's
                // lookback. Reject every old cache token without fetching the
                // visible date. Explicit review/copy intents remain unchanged.
                state.cache = state.cache.clearAll()
                state.phase = .idle(destinationDate: state.destinationDate)
                state.loadingSlot = nil
                state.errorMessage = nil
                return .cancel(id: CancelID.latest)

            case .expireSession:
                return expireLatestSession(state: &state)

            case .delegate:
                return .none
            }
        }
    }

    private func prepareLatest(state: inout State, slot: MealSlot) -> Effect<Action> {
        guard !state.isSubmitting else { return .none }
        guard !state.phase.isSessionExpired else { return .none }
        if case .loading = state.phase { return .none }

        let destinationDate = state.destinationDate

        if case .settled(.success(let cachedSlots)) = state.cache.entry(for: destinationDate) {
            state.phase = .loaded(
                destinationDate: destinationDate,
                slots: cachedSlots,
                loadedForDate: destinationDate,
                activity: .settled
            )
            state.loadingSlot = nil
            state.errorMessage = nil
            applyReviewOrError(state: &state, slot: slot, slots: cachedSlots, destinationDate: destinationDate)
            return .none
        }

        return startRead(state: &state, slot: slot, mode: .initial)
    }

    private func startRead(
        state: inout State,
        slot: MealSlot?,
        mode: RequestMode
    ) -> Effect<Action> {
        guard !state.phase.isSessionExpired else { return .none }
        if case .loading = state.phase { return .none }

        let destinationDate = state.destinationDate

        var cache = state.cache
        switch cache.entry(for: destinationDate) {
        case .inFlight:
            return .none
        default:
            cache = cache.invalidate(destinationDate)
        }
        guard let (newCache, token) = cache.request(destinationDate) else {
            return .none
        }
        state.cache = newCache

        let retainedSlots: [DiaryLatestSlot]? = {
            if case .loaded(let dd, let slots, _, _) = state.phase, dd == destinationDate {
                return slots
            }
            return nil
        }()

        switch mode {
        case .refresh:
            if let retainedSlots {
                state.phase = .loaded(
                    destinationDate: destinationDate,
                    slots: retainedSlots,
                    loadedForDate: destinationDate,
                    activity: .refreshing(token: token)
                )
            } else {
                state.phase = .loading(destinationDate: destinationDate, slot: slot, token: token)
            }
        case .initial, .retry:
            state.phase = .loading(destinationDate: destinationDate, slot: slot, token: token)
        }

        state.loadingSlot = (mode == .refresh && retainedSlots != nil) ? state.loadingSlot : slot
        if mode != .refresh || retainedSlots == nil {
            state.errorMessage = nil
        }

        let generation = state.sessionGeneration
        let client = diaryLatestClient
        return .run { send in
            do {
                let slots = try await client.latestSlots(destinationDate, Self.lookbackDays, generation)
                await send(.latestSlotsReceived(
                    generation: generation,
                    destinationDate: destinationDate,
                    slot: slot,
                    token: token,
                    result: .success(slots)
                ))
            } catch {
                let serviceError: DiaryServiceError
                if let typed = error as? DiaryServiceError {
                    serviceError = typed
                } else if isUnauthorizedDiaryError(error) {
                    serviceError = .unauthorized
                } else if isCancelledDiaryError(error) || error is CancellationError {
                    serviceError = .cancelled
                } else {
                    serviceError = .server(diaryErrorMessage(error))
                }
                await send(.latestSlotsReceived(
                    generation: generation,
                    destinationDate: destinationDate,
                    slot: slot,
                    token: token,
                    result: .failure(serviceError)
                ))
            }
        }
        .cancellable(id: CancelID.latest, cancelInFlight: true)
    }

    private func cancelUnderlyingRead(state: inout State) {
        let destinationDate = state.destinationDate
        switch state.phase {
        case .loading(let requestDate, _, let token):
            if requestDate == destinationDate,
               case .inFlight(let pendingToken) = state.cache.entry(for: requestDate),
               pendingToken == token {
                state.cache = state.cache.invalidate(requestDate)
            }
            state.phase = .idle(destinationDate: requestDate)
        case .loaded(let requestDate, let slots, let loadedForDate, .refreshing(let token)):
            if requestDate == destinationDate,
               case .inFlight(let pendingToken) = state.cache.entry(for: requestDate),
               pendingToken == token {
                state.cache = state.cache.invalidate(requestDate)
            }
            state.phase = .loaded(
                destinationDate: requestDate,
                slots: slots,
                loadedForDate: loadedForDate,
                activity: .settled
            )
        case .loaded(let requestDate, let slots, let loadedForDate, .failed(let token, _)):
            if requestDate == destinationDate,
               case .inFlight(let pendingToken) = state.cache.entry(for: requestDate),
               pendingToken == token {
                state.cache = state.cache.invalidate(requestDate)
            }
            state.phase = .loaded(
                destinationDate: requestDate,
                slots: slots,
                loadedForDate: loadedForDate,
                activity: .settled
            )
        default:
            break
        }
        state.loadingSlot = nil
    }

    private func contextChanged(state: inout State, date: LocalDiaryDate, today: LocalDiaryDate) -> Effect<Action> {
        let oldDestination = state.destinationDate
        if date == oldDestination {
            state.today = today
            return .none
        }
        cancelUnderlyingRead(state: &state)
        // Invalidate the old destination's in-flight token via the authoritative
        // cache without resetting the whole cache.
        if case .inFlight = state.cache.entry(for: oldDestination) {
            state.cache = state.cache.invalidate(oldDestination)
        }
        state.destinationDate = date
        state.today = today
        state.loadingSlot = nil
        state.errorMessage = nil
        switch state.cache.entry(for: date) {
        case .settled(.success(let cachedSlots)):
            state.phase = .loaded(
                destinationDate: date,
                slots: cachedSlots,
                loadedForDate: date,
                activity: .settled
            )
        default:
            state.phase = .idle(destinationDate: date)
        }
        if !(state.isSubmitting || state.copyRequest != nil) {
            state.review = nil
        }
        return .cancel(id: CancelID.latest)
    }

    private func expireLatestSession(state: inout State) -> Effect<Action> {
        guard !state.phase.isSessionExpired else { return .none }
        cancelUnderlyingRead(state: &state)
        state.cache = state.cache.reset()
        state.review = nil
        state.loadingSlot = nil
        state.errorMessage = nil
        state.copyErrorMessage = nil
        state.copySucceeded = false
        state.isSubmitting = false
        state.copyRequest = nil
        state.phase = .sessionExpired(destinationDate: state.destinationDate)
        return .cancel(id: CancelID.latest)
    }

    private func submitLatest(state: inout State) -> Effect<Action> {
        guard !state.isSubmitting else { return .none }
        guard !state.isSessionExpired else { return .none }

        let review = state.review ?? state.copyRequest?.review
        guard let review else { return .none }

        let timeZoneIdentifier = timeZone.identifier
        guard let drafts = review.makeDrafts(timeZone: timeZoneIdentifier), !drafts.isEmpty else {
            state.copyErrorMessage = String(localized: "diary.latest.invalid")
            return .none
        }

        let requestID = uuid()
        let itemNames = review.items.map(\.title)
        let summary = LogSubmissionSummary.text(for: drafts, names: itemNames)
        let generation = state.sessionGeneration

        state.copyRequest = CopyRequest(
            requestID: requestID,
            sessionGeneration: generation,
            destinationDate: review.destinationDate,
            destinationSlot: review.destinationSlot,
            review: review,
            timeZone: timeZoneIdentifier,
            drafts: drafts
        )
        state.isSubmitting = true
        state.copyErrorMessage = nil
        state.copySucceeded = false

        // A copy submission must not be cancelled by read cancellation; cancel only
        // the active read and preserve the immutable captured payload.
        cancelUnderlyingRead(state: &state)

        let client = diaryLatestSubmissionClient
        return .run { send in
            let result = await client.submit(drafts, itemNames, summary, generation)
            await send(.submitCompleted(requestID: requestID, generation: generation, result: result))
        }
    }

    private func handleSubmissionCompletion(
        state: inout State,
        requestID: UUID,
        generation: UInt64,
        result: LogSubmissionServiceResult
    ) -> Effect<Action> {
        guard let copyRequest = state.copyRequest, copyRequest.requestID == requestID else {
            return .none
        }
        guard generation == state.sessionGeneration else { return .none }
        guard generation == copyRequest.sessionGeneration else { return .none }

        state.isSubmitting = false

        switch result {
        case .success(let logs):
            state.cache = state.cache.clearAll()
            cancelUnderlyingRead(state: &state)

            if state.phase.destinationDate == copyRequest.destinationDate,
               case .loaded(let loadedDate, let slots, let loadedForDate, _) = state.phase {
                let filteredSlots = slots.filter { $0.mealSlot != copyRequest.destinationSlot }
                state.phase = .loaded(
                    destinationDate: loadedDate,
                    slots: filteredSlots,
                    loadedForDate: loadedForDate,
                    activity: .settled
                )
            }

            if state.review == copyRequest.review {
                state.review = nil
            }
            state.copyRequest = nil
            state.copyErrorMessage = nil
            state.copySucceeded = true
            state.errorMessage = nil

            return .send(.delegate(.copied(
                requestID: requestID,
                destinationDate: copyRequest.destinationDate,
                destinationSlot: copyRequest.destinationSlot,
                sessionGeneration: generation,
                logs: logs
            )))

        case .failure(let failure):
            switch failure {
            case .unauthorized:
                state.cache = state.cache.reset()
                state.copyRequest = nil
                state.review = nil
                state.loadingSlot = nil
                state.errorMessage = nil
                state.copyErrorMessage = nil
                state.copySucceeded = false
                state.phase = .sessionExpired(destinationDate: copyRequest.destinationDate)
                return .send(.delegate(.sessionExpired(
                    destinationDate: copyRequest.destinationDate,
                    generation: generation
                )))

            case .failed(let message), .uncertain(let message):
                state.copyRequest = copyRequest
                state.copyErrorMessage = message
                state.copySucceeded = false
                return .none
            }
        }
    }

    private func handleCompletion(
        state: inout State,
        generation: UInt64,
        requestDate: LocalDiaryDate,
        slot: MealSlot?,
        token: Token,
        result: Result<[DiaryLatestSlot], DiaryServiceError>
    ) -> Effect<Action> {
        guard generation == state.sessionGeneration else { return .none }
        guard requestDate == state.destinationDate else { return .none }
        guard isTokenActive(state.phase, requestDate: requestDate, token: token) else { return .none }

        switch result {
        case .success(let slots):
            guard let newCache = state.cache.settling(requestDate, token: token, result: .success(slots)) else {
                return .none
            }
            state.cache = newCache
            state.phase = .loaded(
                destinationDate: requestDate,
                slots: slots,
                loadedForDate: requestDate,
                activity: .settled
            )
            state.loadingSlot = nil
            state.errorMessage = nil

            if let slot {
                applyReviewOrError(state: &state, slot: slot, slots: slots, destinationDate: requestDate)
            }
            return .none

        case .failure(let error):
            if isCancelledDiaryError(error) || error == .cancelled {
                state.loadingSlot = nil
                switch state.phase {
                case .loading:
                    state.phase = .idle(destinationDate: requestDate)
                case .loaded(let loadedDate, let slots, let loadedForDate, .refreshing(let pendingToken)):
                    if pendingToken == token {
                        if case .inFlight(let cacheToken) = state.cache.entry(for: requestDate),
                           cacheToken == token {
                            state.cache = state.cache.invalidate(requestDate)
                        }
                        state.phase = .loaded(
                            destinationDate: loadedDate,
                            slots: slots,
                            loadedForDate: loadedForDate,
                            activity: .settled
                        )
                    }
                default:
                    break
                }
                if case .inFlight(let pendingToken) = state.cache.entry(for: requestDate),
                   pendingToken == token {
                    state.cache = state.cache.invalidate(requestDate)
                }
                return .none
            }

            if error == .unauthorized {
                state.cache = state.cache.reset()
                state.review = nil
                state.loadingSlot = nil
                state.errorMessage = nil
                state.phase = .sessionExpired(destinationDate: requestDate)
                return .send(.delegate(.sessionExpired(destinationDate: requestDate, generation: state.sessionGeneration)))
            }

            guard let newCache = state.cache.settling(requestDate, token: token, result: .failure(error)) else {
                return .none
            }
            state.cache = newCache
            state.loadingSlot = nil

            let message = diaryErrorMessage(error)
            state.errorMessage = message

            if case .loaded(let dd, let retainedSlots, let loadedForDate, _) = state.phase, dd == requestDate {
                state.phase = .loaded(
                    destinationDate: requestDate,
                    slots: retainedSlots,
                    loadedForDate: loadedForDate,
                    activity: .failed(token: token, message: message)
                )
            } else {
                state.phase = .failed(destinationDate: requestDate, message: message, token: token)
            }
            return .none
        }
    }

    private func applyReviewOrError(
        state: inout State,
        slot: MealSlot,
        slots: [DiaryLatestSlot],
        destinationDate: LocalDiaryDate
    ) {
        var bySlot: [MealSlot: DiaryLatestSlot] = [:]
        for source in slots {
            bySlot[source.mealSlot] = source
        }
        guard let source = bySlot[slot], !source.logs.isEmpty else {
            state.review = nil
            state.errorMessage = String(
                format: String(localized: "diary.latest.empty"),
                DiaryLabels.mealSlotName(slot)
            )
            return
        }
        guard source.logs.count <= LogSubmissionRequestBuilder.maxDrafts else {
            state.review = nil
            state.errorMessage = String(
                format: String(localized: "diary.latest.tooMany"),
                LogSubmissionRequestBuilder.maxDrafts
            )
            return
        }
        state.review = DiaryLatestReview(
            destinationDate: destinationDate,
            destinationSlot: slot,
            sourceDate: source.sourceDate,
            items: source.logs
        )
        state.errorMessage = nil
    }

    private func isTokenActive(_ phase: Phase, requestDate: LocalDiaryDate, token: Token) -> Bool {
        switch phase {
        case .loading(let rd, _, let tk):
            return rd == requestDate && tk == token
        case .loaded(let rd, _, _, .refreshing(let tk)):
            return rd == requestDate && tk == token
        case .loaded(let rd, _, _, .failed(let tk, _)):
            return rd == requestDate && tk == token
        case .failed(let rd, _, let tk?):
            return rd == requestDate && tk == token
        default:
            return false
        }
    }
}

extension DiaryLatestFeature.Phase {
    var isSessionExpired: Bool {
        if case .sessionExpired = self { true } else { false }
    }
}

extension DependencyValues {
    public var diaryLatestClient: DiaryLatestFeature.Client {
        get { self[DiaryLatestClientKey.self] }
        set { self[DiaryLatestClientKey.self] = newValue }
    }

    public var diaryLatestSubmissionClient: DiaryLatestFeature.SubmissionClient {
        get { self[DiaryLatestSubmissionClientKey.self] }
        set { self[DiaryLatestSubmissionClientKey.self] = newValue }
    }
}

private enum DiaryLatestClientKey: DependencyKey {
    static let liveValue: DiaryLatestFeature.Client = .init { _, _, _ in
        throw DiaryServiceError.unknown
    }
    static let testValue: DiaryLatestFeature.Client = .init { _, _, _ in
        throw DiaryServiceError.unknown
    }
}

private enum DiaryLatestSubmissionClientKey: DependencyKey {
    static let liveValue: DiaryLatestFeature.SubmissionClient = .init { _, _, _, _ in
        .failure(.failed(String(localized: "diary.error.generic")))
    }
    static let testValue: DiaryLatestFeature.SubmissionClient = .init { _, _, _, _ in
        .failure(.failed(String(localized: "diary.error.generic")))
    }
}
