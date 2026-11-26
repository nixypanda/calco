import ComposableArchitecture
import Foundation

@Reducer
public struct DiaryScreenFeature {
    @ObservableState
    public struct State: Equatable {
        public var diary: DiaryFeature.State
        public var latest: DiaryLatestFeature.State

        public var sessionExpiryForwarded: UInt64?
        public var copiedRequestIDs: Set<UUID>

        public var today: LocalDiaryDate { diary.today }
        public var selectedDate: LocalDiaryDate { diary.selectedDate }
        public var sessionGeneration: UInt64 { diary.sessionGeneration }

        public init(
            date: LocalDiaryDate,
            today: LocalDiaryDate,
            sessionGeneration: UInt64,
            diaryCache: DiaryFeature.Cache = DiaryFeature.Cache(),
            latestCache: DiaryLatestFeature.Cache = DiaryLatestFeature.Cache(),
            sessionExpiryForwarded: UInt64? = nil,
            copiedRequestIDs: Set<UUID> = []
        ) {
            let diaryState = DiaryFeature.State(
                date: date,
                today: today,
                sessionGeneration: sessionGeneration,
                cache: diaryCache
            )
            self.diary = diaryState
            self.latest = DiaryLatestFeature.State(
                destinationDate: diaryState.selectedDate,
                today: diaryState.today,
                sessionGeneration: sessionGeneration,
                cache: latestCache,
                phase: .idle(destinationDate: diaryState.selectedDate)
            )
            self.sessionExpiryForwarded = sessionExpiryForwarded
            self.copiedRequestIDs = copiedRequestIDs
        }

        public init(
            diary: DiaryFeature.State,
            latest: DiaryLatestFeature.State,
            sessionExpiryForwarded: UInt64? = nil,
            copiedRequestIDs: Set<UUID> = []
        ) {
            self.diary = diary
            self.latest = latest
            self.sessionExpiryForwarded = sessionExpiryForwarded
            self.copiedRequestIDs = copiedRequestIDs
        }
    }

    public enum Action: Equatable, Sendable {
        case diary(DiaryFeature.Action)
        case latest(DiaryLatestFeature.Action)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(selectedDate: LocalDiaryDate, generation: UInt64)
        case addFood(slot: MealSlot, date: LocalDiaryDate, generation: UInt64)
        case openLogEditor(id: String, date: LocalDiaryDate, generation: UInt64)
        case openMeals(date: LocalDiaryDate, generation: UInt64)
        case copied(requestID: UUID, destinationDate: LocalDiaryDate, destinationSlot: MealSlot, sessionGeneration: UInt64, logs: [FoodLog])
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.diary, action: \.diary) {
            DiaryFeature()
        }
        Scope(state: \.latest, action: \.latest) {
            DiaryLatestFeature()
        }
        Reduce { state, action in
            switch action {
            case .diary(let childAction):
                switch childAction {
                case .selectDate, .previousDay, .nextDay, .todayChanged, .foregroundRefresh:
                    let diarySelected = state.diary.selectedDate
                    let diaryToday = state.diary.today
                    if state.latest.destinationDate != diarySelected || state.latest.today != diaryToday {
                        return .send(.latest(.contextChanged(date: diarySelected, today: diaryToday)))
                    }
                    return .none
                case .delegate(let delegate):
                    switch delegate {
                    case .sessionExpired(let selectedDate, let generation):
                        guard generation == state.sessionGeneration else { return .none }
                        guard state.sessionExpiryForwarded != generation else { return .none }
                        state.sessionExpiryForwarded = generation
                        return .concatenate(
                            .send(.diary(.expireSession)),
                            .send(.latest(.expireSession)),
                            .send(.delegate(.sessionExpired(selectedDate: selectedDate, generation: generation)))
                        )
                    case .addFood(let slot, let date, let generation):
                        guard generation == state.sessionGeneration else { return .none }
                        guard !state.diary.isSessionExpired else { return .none }
                        return .send(.delegate(.addFood(slot: slot, date: date, generation: generation)))
                    case .openLogEditor(let id, let date, let generation):
                        guard generation == state.sessionGeneration else { return .none }
                        guard !state.diary.isSessionExpired else { return .none }
                        return .send(.delegate(.openLogEditor(id: id, date: date, generation: generation)))
                    case .openMeals(let date, let generation):
                        guard generation == state.sessionGeneration else { return .none }
                        guard !state.diary.isSessionExpired else { return .none }
                        return .send(.delegate(.openMeals(date: date, generation: generation)))
                    }
                default:
                    return .none
                }
            case .latest(let childAction):
                switch childAction {
                case .delegate(let delegate):
                    switch delegate {
                    case .sessionExpired(_, let generation):
                        guard generation == state.sessionGeneration else { return .none }
                        guard state.sessionExpiryForwarded != generation else { return .none }
                        state.sessionExpiryForwarded = generation
                        let selectedDate = state.diary.selectedDate
                        return .concatenate(
                            .send(.diary(.expireSession)),
                            .send(.latest(.expireSession)),
                            .send(.delegate(.sessionExpired(selectedDate: selectedDate, generation: generation)))
                        )
                    case .copied(let requestID, let destinationDate, let destinationSlot, let sessionGeneration, let logs):
                        guard sessionGeneration == state.sessionGeneration else { return .none }
                        guard !state.diary.isSessionExpired else { return .none }
                        guard state.sessionExpiryForwarded != sessionGeneration else { return .none }
                        guard !state.copiedRequestIDs.contains(requestID) else { return .none }
                        state.copiedRequestIDs.insert(requestID)
                        let validLogs = logs.filter { $0.logDate == destinationDate }
                        var effects: [Effect<Action>] = []
                        for log in validLogs {
                            let diaryLog = CalCoStoreMapping.diaryLog(from: log)
                            effects.append(.send(.diary(.applySavedLog(
                                generation: sessionGeneration,
                                log: diaryLog,
                                replacingID: log.id,
                                onDate: destinationDate
                            ))))
                        }
                        effects.append(.send(.delegate(.copied(
                            requestID: requestID,
                            destinationDate: destinationDate,
                            destinationSlot: destinationSlot,
                            sessionGeneration: sessionGeneration,
                            logs: logs
                        ))))
                        return .concatenate(effects)
                    }
                default:
                    return .none
                }
            case .delegate:
                return .none
            }
        }
    }
}
