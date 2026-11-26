import ComposableArchitecture
import Foundation

@Reducer
public struct DiaryFeature {
    public typealias Cache = ResourceCache<LocalDiaryDate, DiaryDay, DiaryServiceError>
    public typealias Token = Cache.RequestToken

    public struct PendingGoalOverride: Equatable, Sendable {
        public let targets: DiaryGoalTargets
        public let date: LocalDiaryDate
        public let activeToken: Token

        public init(targets: DiaryGoalTargets, date: LocalDiaryDate, activeToken: Token) {
            self.targets = targets
            self.date = date
            self.activeToken = activeToken
        }
    }

    public struct PendingPrefsOverride: Equatable, Sendable {
        public let prefs: DiaryPrefs
        public let activeToken: Token

        public init(prefs: DiaryPrefs, activeToken: Token) {
            self.prefs = prefs
            self.activeToken = activeToken
        }
    }

    public enum Activity: Equatable, Sendable {
        case settled
        case refreshing(requestDate: LocalDiaryDate, token: Token)
        case changingDate(from: LocalDiaryDate, requestDate: LocalDiaryDate, token: Token)
        case failure(requestDate: LocalDiaryDate, token: Token, message: String)
    }

    public enum Phase: Equatable, Sendable {
        case idle(requestDate: LocalDiaryDate)
        case initialLoading(requestDate: LocalDiaryDate, token: Token)
        case loaded(day: DiaryDay, activity: Activity)
        case initialFailed(requestDate: LocalDiaryDate, token: Token, message: String)
        case sessionExpired(requestDate: LocalDiaryDate)

        public var requestDate: LocalDiaryDate {
            switch self {
            case .idle(let requestDate),
                 .initialLoading(let requestDate, _),
                 .initialFailed(let requestDate, _, _),
                 .sessionExpired(let requestDate):
                return requestDate
            case .loaded(let day, let activity):
                switch activity {
                case .settled:
                    return day.date
                case .refreshing(let requestDate, _),
                     .changingDate(_, let requestDate, _),
                     .failure(let requestDate, _, _):
                    return requestDate
                }
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        public var today: LocalDiaryDate
        public var phase: Phase
        public let sessionGeneration: UInt64
        public var cache: Cache
        public var macroMode: DiaryMacroDisplayMode
        public var savedLogOverrides: [LocalDiaryDate: [String: DiaryLog]] = [:]
        public var deletedIDs: [LocalDiaryDate: Set<String>] = [:]
        public var pendingGoalOverride: PendingGoalOverride? = nil
        public var pendingPrefsOverride: PendingPrefsOverride? = nil
        public var mutationNotice: DiaryMutationNotice? = nil
        /// Number of accepted diary reads for this state's lifetime. Incremented
        /// once per authoritative `.diaryReceived` settle; never reset locally.
        public var completedFetchCount: Int = 0

        public var selectedDate: LocalDiaryDate {
            switch phase {
            case .idle(let requestDate),
                 .initialLoading(let requestDate, _),
                 .initialFailed(let requestDate, _, _),
                 .sessionExpired(let requestDate):
                return requestDate
            case .loaded(let day, let activity):
                switch activity {
                case .settled:
                    return day.date
                case .refreshing(let requestDate, _),
                     .changingDate(_, let requestDate, _),
                     .failure(let requestDate, _, _):
                    return requestDate
                }
            }
        }

        public var visibleDay: DiaryDay? {
            if case .loaded(let day, _) = phase { return day }
            return nil
        }

        public var isSessionExpired: Bool {
            if case .sessionExpired = phase { return true }
            return false
        }

        public var canGoNext: Bool {
            selectedDate < today && !isSessionExpired
        }

        public init(
            date: LocalDiaryDate,
            today: LocalDiaryDate,
            sessionGeneration: UInt64,
            macroMode: DiaryMacroDisplayMode = .grams,
            cache: Cache = Cache(),
            savedLogOverrides: [LocalDiaryDate: [String: DiaryLog]] = [:],
            deletedIDs: [LocalDiaryDate: Set<String>] = [:],
            pendingGoalOverride: PendingGoalOverride? = nil,
            pendingPrefsOverride: PendingPrefsOverride? = nil,
            mutationNotice: DiaryMutationNotice? = nil
        ) {
            self.today = today
            self.phase = .idle(requestDate: min(date, today))
            self.sessionGeneration = sessionGeneration
            self.macroMode = macroMode
            self.cache = cache
            self.savedLogOverrides = savedLogOverrides
            self.deletedIDs = deletedIDs
            self.pendingGoalOverride = pendingGoalOverride
            self.pendingPrefsOverride = pendingPrefsOverride
            self.mutationNotice = mutationNotice
        }

        internal init(
            today: LocalDiaryDate,
            phase: Phase,
            sessionGeneration: UInt64 = 0,
            macroMode: DiaryMacroDisplayMode = .grams,
            cache: Cache = Cache(),
            savedLogOverrides: [LocalDiaryDate: [String: DiaryLog]] = [:],
            deletedIDs: [LocalDiaryDate: Set<String>] = [:],
            pendingGoalOverride: PendingGoalOverride? = nil,
            pendingPrefsOverride: PendingPrefsOverride? = nil,
            mutationNotice: DiaryMutationNotice? = nil
        ) {
            self.today = today
            self.phase = phase
            self.sessionGeneration = sessionGeneration
            self.macroMode = macroMode
            self.cache = cache
            self.savedLogOverrides = savedLogOverrides
            self.deletedIDs = deletedIDs
            self.pendingGoalOverride = pendingGoalOverride
            self.pendingPrefsOverride = pendingPrefsOverride
            self.mutationNotice = mutationNotice
        }
    }

    public enum Action: Equatable, Sendable {
        case loadIfNeeded
        case load
        case retry
        case refresh
        case previousDay
        case nextDay
        case selectDate(LocalDiaryDate)
        case todayChanged(LocalDiaryDate)
        case foregroundRefresh(newToday: LocalDiaryDate)
        case toggleMacroMode
        case addFood(MealSlot)
        case openLogEditor(String)
        case openMeals
        case diaryReceived(generation: UInt64, requestDate: LocalDiaryDate, token: Token, day: DiaryDay)
        case diaryFailed(generation: UInt64, requestDate: LocalDiaryDate, token: Token, error: DiaryServiceError)
        case applySavedLog(generation: UInt64, log: DiaryLog, replacingID: String, onDate: LocalDiaryDate)
        case applyDeletedLog(generation: UInt64, id: String, onDate: LocalDiaryDate)
        /// Explicit, generation-tagged cache invalidation for one date. Used when
        /// a submission touched a non-visible date whose rows could not be
        /// applied locally; the next visit then issues a fresh authoritative read.
        case invalidateCachedDay(generation: UInt64, date: LocalDiaryDate)
        case applySavedGoal(generation: UInt64, targets: DiaryGoalTargets, effectiveDate: LocalDiaryDate)
        case applySavedPreferences(generation: UInt64, prefs: DiaryPrefs)
        case showMutationNotice(generation: UInt64, date: LocalDiaryDate, notice: DiaryMutationNotice)
        case clearMutationNotice
        case expireSession
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(selectedDate: LocalDiaryDate, generation: UInt64)
        case addFood(slot: MealSlot, date: LocalDiaryDate, generation: UInt64)
        case openLogEditor(id: String, date: LocalDiaryDate, generation: UInt64)
        case openMeals(date: LocalDiaryDate, generation: UInt64)
    }

    private enum CancelID: Hashable {
        case diary
    }

    public struct Client: Sendable {
        public var fetchDay: @Sendable (LocalDiaryDate, UInt64) async throws -> DiaryDay

        public init(fetchDay: @escaping @Sendable (LocalDiaryDate, UInt64) async throws -> DiaryDay) {
            self.fetchDay = fetchDay
        }

        public static func live(service: any DiaryServicing) -> Self {
            // Base/unwrapped read seam. This factory captures the supplied
            // service at creation time; it is intentionally not guarded. Future
            // runtime base-client closures must resolve the current service per
            // call after the generation precheck instead of caching one here.
            Self { date, _ in
                try await service.fetchDiary(for: date)
            }
        }

        /// Wraps `self` so generation validity is checked before and after the
        /// underlying read. Stale generations surface as `.cancelled` (never
        /// `.unauthorized`) so a stale read cannot trigger session expiry.
        public func guarded(
            isCurrentGeneration: @escaping @MainActor @Sendable (UInt64) -> Bool
        ) -> Self {
            let base = self.fetchDay
            return Self { date, expectedGeneration in
                let currentBefore = await MainActor.run { isCurrentGeneration(expectedGeneration) }
                guard currentBefore else { throw DiaryServiceError.cancelled }
                do {
                    let day = try await base(date, expectedGeneration)
                    let currentAfter = await MainActor.run { isCurrentGeneration(expectedGeneration) }
                    guard currentAfter else { throw DiaryServiceError.cancelled }
                    return day
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
            base: @escaping @Sendable (LocalDiaryDate, UInt64) async throws -> DiaryDay,
            isCurrentGeneration: @escaping @MainActor @Sendable (UInt64) -> Bool
        ) -> Self {
            Self(fetchDay: base).guarded(isCurrentGeneration: isCurrentGeneration)
        }

    }

    @Dependency(\.diaryClient) private var diaryClient
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadIfNeeded:
                guard !state.isSessionExpired else { return .none }
                guard case .idle = state.phase else { return .none }
                return startRequest(state: &state, requestDate: state.selectedDate, mode: .initial)

            case .load:
                guard !state.isSessionExpired else { return .none }
                return startRequest(state: &state, requestDate: state.selectedDate, mode: .initial)

            case .retry:
                guard !state.isSessionExpired else { return .none }
                let requestDate = state.selectedDate
                // If we are in an inline failure activity, keep retained content.
                if case .loaded(let day, .failure) = state.phase {
                    _ = day
                }
                return startRequest(state: &state, requestDate: requestDate, mode: .retry)

            case .refresh:
                guard !state.isSessionExpired else { return .none }
                return startRequest(state: &state, requestDate: state.selectedDate, mode: .refresh)

            case .previousDay:
                guard !state.isSessionExpired else { return .none }
                let target = state.selectedDate.addingDays(-1)
                return .send(.selectDate(target))

            case .nextDay:
                guard state.canGoNext else { return .none }
                let target = state.selectedDate.addingDays(1)
                return .send(.selectDate(target))

            case let .selectDate(date):
                guard !state.isSessionExpired else { return .none }
                let clamped = min(date, state.today)
                let current = state.selectedDate

                if clamped == current {
                    // Retry failed loads on the same date.
                    switch state.phase {
                    case .initialFailed, .idle:
                        return startRequest(state: &state, requestDate: clamped, mode: .initial)
                    case .loaded(_, .failure):
                        return startRequest(state: &state, requestDate: clamped, mode: .retry)
                    default:
                        return .none
                    }
                }

                // A real date change retires any mutation notice tied to the
                // previous day. Same-date refreshes/retries preserve it.
                state.mutationNotice = nil

                // Retire any in-flight request for the date we are leaving so a
                // later revisit can issue a fresh request.
                if case .inFlight(_) = state.cache.entry(for: current) {
                    state.cache = state.cache.invalidate(current)
                }

                return startRequest(state: &state, requestDate: clamped, mode: .change(from: current))

            case let .todayChanged(changed):
                state.today = changed
                return .none

            case let .foregroundRefresh(newToday):
                let oldToday = state.today
                let wasViewingToday = (state.selectedDate == oldToday)

                if newToday == oldToday {
                    state.today = newToday
                    guard !state.isSessionExpired else { return .none }
                    guard wasViewingToday else { return .none }
                    return startRequest(state: &state, requestDate: state.selectedDate, mode: .refresh)
                }

                state.today = newToday

                if wasViewingToday || state.selectedDate > newToday {
                    state.mutationNotice = nil
                    if state.isSessionExpired {
                        state.phase = .sessionExpired(requestDate: newToday)
                        return .none
                    }
                    // Force a fresh target read even when that date is already
                    // in flight; otherwise rollover would leave the old day.
                    state.cache = state.cache.invalidate(newToday)
                    return startRequest(state: &state, requestDate: newToday, mode: .initial)
                }

                return .none

            case .toggleMacroMode:                state.macroMode = (state.macroMode == .grams) ? .percent : .grams
                return .none

            case let .addFood(slot):
                guard !state.isSessionExpired else { return .none }
                guard !isChangingDate(state.phase) else { return .none }
                return .send(.delegate(.addFood(slot: slot, date: state.selectedDate, generation: state.sessionGeneration)))

            case let .openLogEditor(id):
                guard !state.isSessionExpired else { return .none }
                guard !isChangingDate(state.phase) else { return .none }
                guard let day = state.visibleDay, day.logs.contains(where: { $0.id == id }) else {
                    return .none
                }
                return .send(.delegate(.openLogEditor(id: id, date: state.selectedDate, generation: state.sessionGeneration)))

            case .openMeals:
                guard !state.isSessionExpired else { return .none }
                guard !isChangingDate(state.phase) else { return .none }
                return .send(.delegate(.openMeals(date: state.selectedDate, generation: state.sessionGeneration)))

            case let .diaryReceived(generation, requestDate, token, day):
                // Captured request identity must be validated before any cache or
                // phase side effects. A stale completion can never mutate state.
                guard generation == state.sessionGeneration else { return .none }
                guard requestDate == state.selectedDate else { return .none }
                guard isTokenActive(state.phase, requestDate: requestDate, token: token) else { return .none }

                if day.date != requestDate {
                    // Consume pending overrides for this token even on wrong-day.
                    if state.pendingGoalOverride?.activeToken == token {
                        state.pendingGoalOverride = nil
                    }
                    if state.pendingPrefsOverride?.activeToken == token {
                        state.pendingPrefsOverride = nil
                    }
                    // Wrong-day payload: only mutate if this token still owns the
                    // cache entry. A rejected settle means the request was already
                    // retired/superseded and must not change visible state.
                    guard let newCache = state.cache.settling(
                        requestDate,
                        token: token,
                        result: .failure(.server(""))
                    ) else {
                        return .none
                    }
                    state.cache = newCache
                    return applyFailure(
                        state: &state,
                        requestDate: requestDate,
                        token: token,
                        message: String(localized: "diary.error.generic")
                    )
                }

                // Fresh fetch reconciliation: prune stale overrides/tombstones
                // and let local saved rows win until the server catches up.
                // Compute all local results first; commit them only after the
                // cache accepts this completion.
                let fetchedIDs = Set(day.logs.map(\.id))
                var overrides = state.savedLogOverrides[requestDate] ?? [:]
                overrides = overrides.filter { fetchedIDs.contains($0.key) }
                let tombstones = state.deletedIDs[requestDate] ?? []
                let stillStale = tombstones.intersection(fetchedIDs)

                let resolvedLogs = day.logs
                    .filter { !tombstones.contains($0.id) }
                    .map { row -> DiaryLog in
                        guard let saved = overrides[row.id] else { return row }
                        if saved == row {
                            var mutableOverrides = overrides
                            mutableOverrides.removeValue(forKey: row.id)
                            overrides = mutableOverrides
                            return row
                        }
                        return saved
                    }

                let hasPendingGoal = state.pendingGoalOverride?.activeToken == token
                    && state.pendingGoalOverride?.date == requestDate
                let hasPendingPrefs = state.pendingPrefsOverride?.activeToken == token

                var resolvedGoal = day.goal
                if let pending = state.pendingGoalOverride, hasPendingGoal {
                    resolvedGoal = pending.targets
                }
                var resolvedPrefs = day.prefs
                if let pending = state.pendingPrefsOverride, hasPendingPrefs {
                    resolvedPrefs = pending.prefs
                }

                let reconciledDay = DiaryDay(
                    date: day.date,
                    logs: resolvedLogs,
                    goal: resolvedGoal,
                    prefs: resolvedPrefs
                )

                guard let newCache = state.cache.settling(requestDate, token: token, result: .success(reconciledDay)) else {
                    return .none
                }

                state.savedLogOverrides[requestDate] = overrides.isEmpty ? nil : overrides
                state.deletedIDs[requestDate] = stillStale.isEmpty ? nil : stillStale
                if hasPendingGoal {
                    state.pendingGoalOverride = nil
                }
                if hasPendingPrefs {
                    state.pendingPrefsOverride = nil
                }
                state.cache = newCache
                // Count only a fully accepted read: identity guards passed, the
                // payload day matched, and the cache redeemed this token. Stale,
                // cancelled, failed, wrong-day and duplicate completions return
                // before this point. Never reset locally.
                state.completedFetchCount += 1

                // Promote inflight phase to settled loaded.
                switch state.phase {
                case .initialLoading, .idle:
                    state.phase = .loaded(day: reconciledDay, activity: .settled)
                case .loaded(let retainedDay, .refreshing):
                    state.phase = .loaded(day: reconciledDay, activity: .settled)
                    _ = retainedDay
                case .loaded(_, .changingDate):
                    state.phase = .loaded(day: reconciledDay, activity: .settled)
                case .loaded(_, .failure):
                    state.phase = .loaded(day: reconciledDay, activity: .settled)
                case .initialFailed:
                    state.phase = .loaded(day: reconciledDay, activity: .settled)
                default:
                    state.phase = .loaded(day: reconciledDay, activity: .settled)
                }
                return .none

            case let .diaryFailed(generation, requestDate, token, error):
                guard generation == state.sessionGeneration else { return .none }
                guard requestDate == state.selectedDate else { return .none }
                guard isTokenActive(state.phase, requestDate: requestDate, token: token) else { return .none }

                if isCancelledDiaryError(error) {
                    // Consume pending overrides for this token.
                    if state.pendingGoalOverride?.activeToken == token {
                        state.pendingGoalOverride = nil
                    }
                    if state.pendingPrefsOverride?.activeToken == token {
                        state.pendingPrefsOverride = nil
                    }
                    // Cancelled completions never surface an error or get stuck.
                    return .none
                }

                if isUnauthorizedDiaryError(error) {
                    state.cache = state.cache.reset()
                    state.savedLogOverrides = [:]
                    state.deletedIDs = [:]
                    state.pendingGoalOverride = nil
                    state.pendingPrefsOverride = nil
                    state.mutationNotice = nil
                    state.phase = .sessionExpired(requestDate: requestDate)
                    return .send(.delegate(.sessionExpired(selectedDate: requestDate, generation: state.sessionGeneration)))
                }

                // Consume pending overrides for this token.
                if state.pendingGoalOverride?.activeToken == token {
                    state.pendingGoalOverride = nil
                }
                if state.pendingPrefsOverride?.activeToken == token {
                    state.pendingPrefsOverride = nil
                }

                let message = diaryErrorMessage(error)
                guard let newCache = state.cache.settling(requestDate, token: token, result: .failure(error)) else {
                    return .none
                }
                state.cache = newCache
                return applyFailure(state: &state, requestDate: requestDate, token: token, message: message)

            case let .applySavedLog(generation, log, replacingID, onDate):
                guard generation == state.sessionGeneration else { return .none }
                guard !state.isSessionExpired else { return .none }

                let effectiveID = log.id.isEmpty ? replacingID : log.id

                var overrides = state.savedLogOverrides[onDate] ?? [:]
                overrides.removeValue(forKey: replacingID)
                overrides[effectiveID] = log
                state.savedLogOverrides[onDate] = overrides

                if var tombstones = state.deletedIDs[onDate] {
                    tombstones.remove(effectiveID)
                    state.deletedIDs[onDate] = tombstones.isEmpty ? nil : tombstones
                }

                if state.selectedDate == onDate,
                   let visible = state.visibleDay,
                   visible.date == onDate {
                    var logs = visible.logs
                    if let index = logs.firstIndex(where: { $0.id == replacingID || $0.id == effectiveID }) {
                        logs[index] = log
                    } else {
                        logs.append(log)
                    }
                    let updatedDay = DiaryDay(date: visible.date, logs: logs, goal: visible.goal, prefs: visible.prefs)
                    if case .loaded(_, let activity) = state.phase {
                        state.phase = .loaded(day: updatedDay, activity: activity)
                    }
                }

                switch state.cache.entry(for: onDate) {
                case .settled(.success(let cachedDay)):
                    var logs = cachedDay.logs
                    if let index = logs.firstIndex(where: { $0.id == replacingID || $0.id == effectiveID }) {
                        logs[index] = log
                    } else {
                        logs.append(log)
                    }
                    let updatedCacheDay = DiaryDay(date: cachedDay.date, logs: logs, goal: cachedDay.goal, prefs: cachedDay.prefs)
                    state.cache = state.cache.invalidate(onDate)
                    state.cache = state.cache.seed(onDate, value: updatedCacheDay)
                default:
                    break
                }

                return .none

            case let .applyDeletedLog(generation, id, onDate):
                guard generation == state.sessionGeneration else { return .none }
                guard !state.isSessionExpired else { return .none }

                state.savedLogOverrides[onDate]?.removeValue(forKey: id)
                if state.savedLogOverrides[onDate]?.isEmpty == true {
                    state.savedLogOverrides[onDate] = nil
                }
                var tombstones = state.deletedIDs[onDate] ?? []
                tombstones.insert(id)
                state.deletedIDs[onDate] = tombstones

                if state.selectedDate == onDate,
                   let visible = state.visibleDay,
                   visible.date == onDate {
                    let logs = visible.logs.filter { $0.id != id }
                    let updatedDay = DiaryDay(date: visible.date, logs: logs, goal: visible.goal, prefs: visible.prefs)
                    if case .loaded(_, let activity) = state.phase {
                        state.phase = .loaded(day: updatedDay, activity: activity)
                    }
                }

                switch state.cache.entry(for: onDate) {
                case .settled(.success(let cachedDay)):
                    let logs = cachedDay.logs.filter { $0.id != id }
                    let updatedCacheDay = DiaryDay(date: cachedDay.date, logs: logs, goal: cachedDay.goal, prefs: cachedDay.prefs)
                    state.cache = state.cache.invalidate(onDate)
                    state.cache = state.cache.seed(onDate, value: updatedCacheDay)
                default:
                    break
                }

                return .none

            case let .invalidateCachedDay(generation, date):
                // Minimal feature-owned invalidation: no request, no visible
                // phase change, no override/tombstone mutation. Only the cache
                // entry for the named date is made requestable again.
                guard generation == state.sessionGeneration else { return .none }
                guard !state.isSessionExpired else { return .none }
                state.cache = state.cache.invalidate(date)
                return .none

            case let .applySavedGoal(generation, targets, effectiveDate):
                guard generation == state.sessionGeneration else { return .none }
                guard !state.isSessionExpired else { return .none }
                guard state.selectedDate == effectiveDate else { return .none }

                let activeToken: Token? = {
                    switch state.phase {
                    case .initialLoading(let rd, let tk) where rd == effectiveDate:
                        return tk
                    case .loaded(_, .refreshing(let rd, let tk)) where rd == effectiveDate:
                        return tk
                    case .loaded(_, .changingDate(_, let rd, let tk)) where rd == effectiveDate:
                        return tk
                    default:
                        return nil
                    }
                }()

                if let token = activeToken {
                    state.pendingGoalOverride = PendingGoalOverride(
                        targets: targets,
                        date: effectiveDate,
                        activeToken: token
                    )
                }

                if let visible = state.visibleDay, visible.date == effectiveDate {
                    let updatedDay = DiaryDay(date: visible.date, logs: visible.logs, goal: targets, prefs: visible.prefs)
                    if case .loaded(_, let activity) = state.phase {
                        state.phase = .loaded(day: updatedDay, activity: activity)
                    }
                }

                return .none

            case let .applySavedPreferences(generation, prefs):
                guard generation == state.sessionGeneration else { return .none }
                guard !state.isSessionExpired else { return .none }
                guard !prefs.enabledSlots.isEmpty else { return .none }

                let activeToken: Token? = {
                    switch state.phase {
                    case .initialLoading(let rd, let tk) where rd == state.selectedDate:
                        return tk
                    case .loaded(_, .refreshing(let rd, let tk)) where rd == state.selectedDate:
                        return tk
                    case .loaded(_, .changingDate(_, let rd, let tk)) where rd == state.selectedDate:
                        return tk
                    default:
                        return nil
                    }
                }()

                if let visible = state.visibleDay {
                    let updatedDay = DiaryDay(date: visible.date, logs: visible.logs, goal: visible.goal, prefs: prefs)
                    if case .loaded(_, let activity) = state.phase {
                        state.phase = .loaded(day: updatedDay, activity: activity)
                    }
                }

                if let token = activeToken {
                    state.pendingPrefsOverride = PendingPrefsOverride(prefs: prefs, activeToken: token)
                }

                return .none

            case let .showMutationNotice(generation, date, notice):
                guard generation == state.sessionGeneration else { return .none }
                guard !state.isSessionExpired else { return .none }
                guard date == state.selectedDate else { return .none }
                state.mutationNotice = notice
                return .none

            case .clearMutationNotice:
                state.mutationNotice = nil
                return .none

            case .expireSession:
                guard !state.isSessionExpired else { return .none }
                state.cache = state.cache.reset()
                state.savedLogOverrides = [:]
                state.deletedIDs = [:]
                state.pendingGoalOverride = nil
                state.pendingPrefsOverride = nil
                state.mutationNotice = nil
                state.phase = .sessionExpired(requestDate: state.selectedDate)
                return .cancel(id: CancelID.diary)

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Request helpers

    private enum RequestMode {
        case initial
        case refresh
        case retry
        case change(from: LocalDiaryDate)
    }

    private func startRequest(
        state: inout State,
        requestDate: LocalDiaryDate,
        mode: RequestMode
    ) -> Effect<Action> {
        guard !state.isSessionExpired else { return .none }

        // A new request is an authoritative read; pending one-shot overrides
        // must not mask it.
        state.pendingGoalOverride = nil
        state.pendingPrefsOverride = nil

        // Retire previous in-flight request on the target key if needed is handled
        // by callers; here ensure we can issue (suppress duplicates).
        if case .inFlight(_) = state.cache.entry(for: requestDate) {
            return .none
        }

        state.cache = state.cache.invalidate(requestDate)
        guard let (newCache, token) = state.cache.request(requestDate) else {
            return .none
        }
        state.cache = newCache

        let retainedDay: DiaryDay? = {
            if case .loaded(let day, _) = state.phase { return day }
            return nil
        }()

        switch mode {
        case .initial:
            state.phase = .initialLoading(requestDate: requestDate, token: token)
        case .refresh:
            if let day = retainedDay {
                state.phase = .loaded(day: day, activity: .refreshing(requestDate: requestDate, token: token))
            } else {
                state.phase = .initialLoading(requestDate: requestDate, token: token)
            }
        case .retry:
            if let day = retainedDay {
                state.phase = .loaded(day: day, activity: .refreshing(requestDate: requestDate, token: token))
            } else {
                state.phase = .initialLoading(requestDate: requestDate, token: token)
            }
        case .change(let from):
            if let day = retainedDay {
                state.phase = .loaded(day: day, activity: .changingDate(from: from, requestDate: requestDate, token: token))
            } else {
                state.phase = .initialLoading(requestDate: requestDate, token: token)
            }
        }

        let generation = state.sessionGeneration
        let client = diaryClient
        return .run { send in
            do {
                let day = try await client.fetchDay(requestDate, generation)
                await send(.diaryReceived(generation: generation, requestDate: requestDate, token: token, day: day))
            } catch {
                let serviceError: DiaryServiceError
                if let typed = error as? DiaryServiceError {
                    serviceError = typed
                } else if isUnauthorizedDiaryError(error) {
                    serviceError = .unauthorized
                } else if isCancelledDiaryError(error) {
                    serviceError = .cancelled
                } else {
                    serviceError = .server(diaryErrorMessage(error))
                }
                await send(.diaryFailed(generation: generation, requestDate: requestDate, token: token, error: serviceError))
            }
        }
        .cancellable(id: CancelID.diary, cancelInFlight: true)
    }

    private func applyFailure(
        state: inout State,
        requestDate: LocalDiaryDate,
        token: Token,
        message: String
    ) -> Effect<Action> {
        switch state.phase {
        case .loaded(let day, _):
            state.phase = .loaded(day: day, activity: .failure(requestDate: requestDate, token: token, message: message))
        case .initialLoading:
            state.phase = .initialFailed(requestDate: requestDate, token: token, message: message)
        case .idle:
            state.phase = .initialFailed(requestDate: requestDate, token: token, message: message)
        default:
            state.phase = .initialFailed(requestDate: requestDate, token: token, message: message)
        }
        return .none
    }

    private func isChangingDate(_ phase: Phase) -> Bool {
        if case .loaded(_, .changingDate) = phase { return true }
        return false
    }

    private func isTokenActive(_ phase: Phase, requestDate: LocalDiaryDate, token: Token) -> Bool {
        switch phase {
        case .initialLoading(let rd, let tk):
            return rd == requestDate && tk == token
        case .initialFailed(let rd, let tk, _):
            return rd == requestDate && tk == token
        case .loaded(_, .refreshing(let rd, let tk)):
            return rd == requestDate && tk == token
        case .loaded(_, .changingDate(_, let rd, let tk)):
            return rd == requestDate && tk == token
        case .loaded(_, .failure(let rd, let tk, _)):
            return rd == requestDate && tk == token
        default:
            return false
        }
    }
}

extension DependencyValues {
    public var diaryClient: DiaryFeature.Client {
        get { self[DiaryClientKey.self] }
        set { self[DiaryClientKey.self] = newValue }
    }
}

private enum DiaryClientKey: DependencyKey {
    static let liveValue: DiaryFeature.Client = .init { _, _ in
        throw DiaryServiceError.unknown
    }
    static let testValue: DiaryFeature.Client = .init { _, _ in
        throw DiaryServiceError.unknown
    }
}
