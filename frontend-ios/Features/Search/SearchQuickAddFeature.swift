import ComposableArchitecture
import Foundation

@Reducer
public struct SearchQuickAddFeature {
    public struct Request: Equatable, Sendable {
        public let requestID: UUID
        public let itemID: String
        public let itemName: String
        public let originDate: LocalDiaryDate
        public let mealSlot: MealSlot?
        public let quantity: NutritionQuantity

        public init(
            requestID: UUID,
            itemID: String,
            itemName: String,
            originDate: LocalDiaryDate,
            mealSlot: MealSlot?,
            quantity: NutritionQuantity
        ) {
            self.requestID = requestID
            self.itemID = itemID
            self.itemName = itemName
            self.originDate = originDate
            self.mealSlot = mealSlot
            self.quantity = quantity
        }
    }

    public struct Receipt: Equatable, Sendable {
        public let itemName: String
        public let createdLogCount: Int

        public init(itemName: String, createdLogCount: Int) {
            self.itemName = itemName
            self.createdLogCount = createdLogCount
        }
    }

    public struct FailureContext: Equatable, Sendable {
        public let requestID: UUID?
        public let itemID: String
        public let originDate: LocalDiaryDate
        public let mealSlot: MealSlot?

        public init(
            requestID: UUID?,
            itemID: String,
            originDate: LocalDiaryDate,
            mealSlot: MealSlot?
        ) {
            self.requestID = requestID
            self.itemID = itemID
            self.originDate = originDate
            self.mealSlot = mealSlot
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case submitting(Request)
        case succeeded(Receipt)
        case failed(FailureContext, LogSubmissionServiceFailure)
    }

    @ObservableState
    public struct State: Equatable {
        public var originDate: LocalDiaryDate
        public var originMealSlot: MealSlot?
        public let sessionGeneration: UInt64
        public var phase: Phase

        public init(
            originDate: LocalDiaryDate,
            originMealSlot: MealSlot? = nil,
            sessionGeneration: UInt64,
            phase: Phase = .idle
        ) {
            self.originDate = originDate
            self.originMealSlot = originMealSlot
            self.sessionGeneration = sessionGeneration
            self.phase = phase
        }

        public var isBusy: Bool {
            if case .submitting = phase { return true }
            return false
        }
    }

    public enum Action: Equatable, Sendable {
        case quickAdd(RecentLogItem, NutritionQuantity?)
        case contextChanged(originDate: LocalDiaryDate, mealSlot: MealSlot?)
        case dismissMessage
        case submitCompleted(requestID: UUID, result: LogSubmissionServiceResult)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case logged(itemID: String, originDate: LocalDiaryDate, mealSlot: MealSlot?, sessionGeneration: UInt64)
        case refresh(originDate: LocalDiaryDate, sessionGeneration: UInt64)
        case sessionExpired(generation: UInt64)
    }

    public struct Client: Sendable {
        public var submit: @MainActor @Sendable (
            [LogSubmissionDraft],
            [String],
            String,
            UInt64
        ) async -> LogSubmissionServiceResult

        public init(
            submit: @escaping @MainActor @Sendable (
                [LogSubmissionDraft],
                [String],
                String,
                UInt64
            ) async -> LogSubmissionServiceResult
        ) {
            self.submit = submit
        }

        public static func live(
            submissionHandler: SearchSubmissionHandler?,
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

    @Dependency(\.searchQuickAddClient) private var searchQuickAddClient
    @Dependency(\.uuid) private var uuid
    @Dependency(\.timeZone) private var timeZone

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case let .quickAdd(item, quantity):
                guard !item.id.isEmpty else { return .none }
                if case .submitting = state.phase { return .none }

                let chosen = quantity ?? item.quantity
                let requestID = uuid()
                let originDate = state.originDate
                let expectedGeneration = state.sessionGeneration
                let mealSlot = state.originMealSlot ?? item.mealSlot
                let timeZoneIdentifier = timeZone.identifier
                let submissionItem = item.submissionItem
                    ?? .adHoc(name: item.name, brand: item.brand)
                let draft = LogSubmissionDraft(
                    item: submissionItem,
                    date: originDate,
                    mealSlot: mealSlot,
                    amount: chosen.amount,
                    unit: chosen.unit,
                    notes: nil,
                    timeZone: timeZoneIdentifier
                )

                state.phase = .submitting(SearchQuickAddFeature.Request(
                    requestID: requestID,
                    itemID: item.id,
                    itemName: item.name,
                    originDate: originDate,
                    mealSlot: mealSlot,
                    quantity: chosen
                ))

                return .run { send in
                    let result = await searchQuickAddClient.submit(
                        [draft],
                        [item.name],
                        item.name,
                        expectedGeneration
                    )
                    await send(.submitCompleted(requestID: requestID, result: result))
                }

            case let .contextChanged(originDate, mealSlot):
                state.originDate = originDate
                state.originMealSlot = mealSlot
                return .none

            case .dismissMessage:
                switch state.phase {
                case .succeeded, .failed:
                    state.phase = .idle
                case .idle, .submitting:
                    return .none
                }
                return .none

            case let .submitCompleted(requestID, result):
                guard case let .submitting(request) = state.phase,
                      request.requestID == requestID else {
                    return .none
                }

                switch result {
                case let .success(logs):
                    state.phase = .succeeded(SearchQuickAddFeature.Receipt(
                        itemName: request.itemName,
                        createdLogCount: logs.count
                    ))
                    return .merge(
                        .send(.delegate(.logged(
                            itemID: request.itemID,
                            originDate: request.originDate,
                            mealSlot: request.mealSlot,
                            sessionGeneration: state.sessionGeneration
                        ))),
                        .send(.delegate(.refresh(
                            originDate: request.originDate,
                            sessionGeneration: state.sessionGeneration
                        )))
                    )

                case let .failure(failure):
                    state.phase = .failed(
                        SearchQuickAddFeature.FailureContext(
                            requestID: requestID,
                            itemID: request.itemID,
                            originDate: request.originDate,
                            mealSlot: request.mealSlot
                        ),
                        failure
                    )
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(
                            generation: state.sessionGeneration
                        )))
                    }
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}

extension DependencyValues {
    public var searchQuickAddClient: SearchQuickAddFeature.Client {
        get { self[SearchQuickAddClientKey.self] }
        set { self[SearchQuickAddClientKey.self] = newValue }
    }
}

private enum SearchQuickAddClientKey: DependencyKey {
    static let liveValue: SearchQuickAddFeature.Client = .init { _, _, _, _ in
        .failure(.failed(String(localized: "foodDetail.error.saveFailed")))
    }
    static let testValue: SearchQuickAddFeature.Client = .init { _, _, _, _ in
        .failure(.failed(String(localized: "foodDetail.error.saveFailed")))
    }
}
