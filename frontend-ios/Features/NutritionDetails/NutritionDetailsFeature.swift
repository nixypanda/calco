import ComposableArchitecture
import Foundation

@Reducer
public struct NutritionDetailsFeature {
    public enum Phase: Equatable, Sendable {
        case idle(requestDate: LocalDiaryDate)
        case loading(requestDate: LocalDiaryDate, requestID: UUID)
        case loaded(report: NutritionDetailsReport, requestDate: LocalDiaryDate)
        case failed(requestDate: LocalDiaryDate, message: String, requestID: UUID)
        case sessionExpired(requestDate: LocalDiaryDate)

        public var requestDate: LocalDiaryDate {
            switch self {
            case .idle(let requestDate),
                 .loading(let requestDate, _),
                 .loaded(_, let requestDate),
                 .failed(let requestDate, _, _),
                 .sessionExpired(let requestDate):
                return requestDate
            }
        }
    }

    public enum Failure: Equatable, Sendable {
        case cancelled
        case unauthorized
        case message(String)
    }

    @ObservableState
    public struct State: Equatable {
        public var today: LocalDiaryDate
        public var phase: Phase
        public let sessionGeneration: UInt64
        public var expandedNutrientCodes: Set<String> = []

        public var selectedDate: LocalDiaryDate {
            phase.requestDate
        }

        public init(date: LocalDiaryDate, today: LocalDiaryDate, sessionGeneration: UInt64) {
            self.today = today
            self.phase = .idle(requestDate: min(date, today))
            self.sessionGeneration = sessionGeneration
        }

        internal init(today: LocalDiaryDate, phase: Phase, sessionGeneration: UInt64 = 0) {
            self.today = today
            self.phase = phase
            self.sessionGeneration = sessionGeneration
        }

        public var isSessionExpired: Bool {
            if case .sessionExpired = phase { true } else { false }
        }

        public var canGoNext: Bool {
            selectedDate < today && !isSessionExpired
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
        case toggleGuidance(String)
        case reportReceived(requestDate: LocalDiaryDate, requestID: UUID, report: NutritionDetailsReport)
        case reportFailed(requestDate: LocalDiaryDate, requestID: UUID, failure: Failure)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(selectedDate: LocalDiaryDate, generation: UInt64)
    }

    public struct Client: Sendable {
        public var fetch: @Sendable (LocalDiaryDate) async throws -> NutritionDetailsReport
        public static func live(service: any NutritionDetailsServicing) -> Self {
            Self { date in
                try await service.fetchNutritionDetails(for: date)
            }
        }
    }

    @Dependency(\.nutritionDetailsClient) private var nutritionDetailsClient
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .loadIfNeeded:
                guard case .idle = state.phase else { return .none }
                if state.isSessionExpired { return .none }
                return .send(.load)

            case .load, .retry, .refresh:
                guard !state.isSessionExpired else { return .none }
                let requestID = uuid()
                let date = state.selectedDate
                state.phase = .loading(requestDate: date, requestID: requestID)
                return .run { send in
                    do {
                        let report = try await nutritionDetailsClient.fetch(date)
                        await send(.reportReceived(requestDate: date, requestID: requestID, report: report))
                    } catch {
                        await send(.reportFailed(
                            requestDate: date,
                            requestID: requestID,
                            failure: Self.map(error)
                        ))
                    }
                }

            case .previousDay:
                guard !state.isSessionExpired else { return .none }
                return .send(.selectDate(state.selectedDate.addingDays(-1)))

            case .nextDay:
                guard state.canGoNext else { return .none }
                return .send(.selectDate(state.selectedDate.addingDays(1)))

            case let .selectDate(date):
                guard !state.isSessionExpired else { return .none }
                let clamped = min(date, state.today)
                guard clamped != state.selectedDate else {
                    switch state.phase {
                    case .idle, .loading, .loaded:
                        return .none
                    case .failed, .sessionExpired:
                        return .send(.load)
                    }
                }

                state.phase = .idle(requestDate: clamped)
                state.expandedNutrientCodes = []
                return .send(.load)

            case let .todayChanged(changed):
                state.today = changed
                return .none

            case let .toggleGuidance(code):
                guard case .loaded(let report, _) = state.phase,
                      report.nutrients.contains(where: { $0.code == code }) else {
                    return .none
                }
                if state.expandedNutrientCodes.contains(code) {
                    state.expandedNutrientCodes.remove(code)
                } else {
                    state.expandedNutrientCodes.insert(code)
                }
                return .none

            case let .reportReceived(requestDate, requestID, report):
                guard requestDate == state.selectedDate else { return .none }
                guard case .loading(let loadingDate, let loadingID) = state.phase,
                      loadingDate == requestDate,
                      loadingID == requestID else {
                    return .none
                }
                guard report.date == requestDate else {
                    state.phase = .failed(
                        requestDate: requestDate,
                        message: NutritionDetailsCopy.invalidResponse,
                        requestID: requestID
                    )
                    return .none
                }
                state.expandedNutrientCodes = []
                state.phase = .loaded(report: report, requestDate: requestDate)
                return .none

            case let .reportFailed(requestDate, requestID, failure):
                guard requestDate == state.selectedDate else { return .none }
                guard case .loading(let loadingDate, let loadingID) = state.phase,
                      loadingDate == requestDate,
                      loadingID == requestID else {
                    return .none
                }

                switch failure {
                case .cancelled:
                    return .none

                case .unauthorized:
                    return expireSession(state: &state, requestDate: requestDate)

                case .message(let message):
                    state.phase = .failed(
                        requestDate: requestDate,
                        message: message,
                        requestID: requestID
                    )
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }

    private static func map(_ error: Error) -> Failure {
        if isCancelledNutritionDetailsError(error) {
            return .cancelled
        }
        if isUnauthorizedNutritionDetailsError(error) {
            return .unauthorized
        }
        return .message(nutritionDetailsErrorMessage(error))
    }

    private func expireSession(state: inout State, requestDate: LocalDiaryDate) -> Effect<Action> {
        // Parent lifetime: this delegate is delivered once per reducer instance
        // because reportFailed only handles a .loading phase, so a second
        // expiry cannot reach this helper.
        state.expandedNutrientCodes = []
        state.phase = .sessionExpired(requestDate: requestDate)
        return .send(.delegate(.sessionExpired(selectedDate: requestDate, generation: state.sessionGeneration)))
    }
}

extension DependencyValues {
    public var nutritionDetailsClient: NutritionDetailsFeature.Client {
        get { self[NutritionDetailsClientKey.self] }
        set { self[NutritionDetailsClientKey.self] = newValue }
    }
}

private enum NutritionDetailsClientKey: DependencyKey {
    static let liveValue: NutritionDetailsFeature.Client = .init { _ in
        throw NutritionDetailsServiceError.unknown
    }
    static let testValue: NutritionDetailsFeature.Client = .init { _ in
        throw NutritionDetailsServiceError.unknown
    }
}
