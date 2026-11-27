// Real TCA Library list + custom-food detail. Catalog CRUD only: the Library
// management surface intentionally has no new logging product route. Log writes
// belong to AdHocLogFeature/FoodCreationFeature through the shared writer.

import ComposableArchitecture
import Foundation

/// Immutable owner context captured for a single feature request. Every async
/// metadata call carries it to the transport and back; a reply is accepted only
/// when the owner (account, generation, presentation) still matches.
/// Equatable success marker for a completed delete. `Void` is not `Equatable`,
/// which prevents synthesized `Equatable` for actions carrying `Result`.
public struct LibraryDeleteSucceeded: Equatable, Sendable {}

public struct FeatureRequestContext: Equatable, Sendable {
    public let accountID: String
    public let generation: UInt64
    public let presentationID: UUID
}

public enum FeatureContextError: Error, Equatable, Sendable {
    /// The captured owner is no longer current; transport must not be called.
    case stale
}

public typealias FeatureContextGuard = @MainActor @Sendable (FeatureRequestContext) -> Bool

public typealias LibraryLogSubmitHandler = @MainActor @Sendable (
    _ drafts: [LogSubmissionDraft],
    _ itemNames: [String],
    _ summary: String,
    _ accountID: String,
    _ generation: UInt64,
    _ completion: @escaping (LogSubmissionServiceResult) -> Void
) -> Void

/// Shared writer seam. `submit` is the existing app-shell generation-guarded
/// handler; no feature posts logs directly and nothing is replayed here.
public struct LibraryLogClient: Sendable {
    public var submit: LibraryLogSubmitHandler
    public var isCurrentOwner: @MainActor @Sendable (String, UInt64) -> Bool
    @MainActor
    public func submitAsync(
        drafts: [LogSubmissionDraft],
        names: [String],
        summary: String,
        accountID: String,
        generation: UInt64
    ) async -> LogSubmissionServiceResult {
        guard isCurrentOwner(accountID, generation) else { return .failure(.unauthorized) }
        return await withCheckedContinuation { continuation in
            submit(drafts, names, summary, accountID, generation) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

/// Typed authoritative mutation record. Window builds the single
/// `DiaryMutationDelivery` from these fields; the writer must never flatten a
/// success to a void notification or rely on a retained coordinator callback.
public struct LibraryLoggedEvent: Equatable, Sendable {
    /// Existing per-logical-intent token (ad-hoc review ID / saved-food intent
    /// ID). It is context, not the mutation dedup ID: authoritative server rows
    /// and captured generation/account decide delivery identity.
    public let intentID: String
    public let drafts: [LogSubmissionDraft]
    public let logs: [FoodLog]
    public let accountID: String
    public let generation: UInt64
    public let date: LocalDiaryDate
    public let slot: MealSlot?
    public let presentationID: UUID
}

public enum LibraryFailure: Error, Equatable, Sendable {
    case unauthorized
    case notFound(String)
    case failed(String)
    case uncertain(String)
    case conflict(String)
    case rateLimited(Int?)

    public var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case let .notFound(message), let .failed(message),
             let .uncertain(message), let .conflict(message):
            return message
        case .rateLimited:
            return String(localized: "foodDetail.error.rateLimited")
        }
    }

    public static func map(_ error: Error) -> LibraryFailure {
        if let serviceError = error as? CustomFoodServiceError {
            switch serviceError {
            case .unauthorized: return .unauthorized
            case let .notFound(message): return .notFound(message)
            case let .failed(message): return .failed(message)
            case let .uncertain(message): return .uncertain(message)
            case let .conflict(message): return .conflict(message)
            case let .rateLimited(retryAfter): return .rateLimited(retryAfter)
            }
        }
        return .failed(error.localizedDescription)
    }
}

@Reducer
public struct LibraryFeature {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @ObservableState
    public struct State: Equatable {
        public let accountID: String
        public let sessionGeneration: UInt64
        public let logContext: LibraryLogContext
        public let today: LocalDiaryDate
        public let presentationID: UUID

        public var phase: Phase = .loading
        public var foods: [CustomFood] = []
        public var refreshError: String?
        public var searchText = ""
        public var loadRequestID: UUID?
        public var detail: CustomFoodDetailFeature.State?

        public init(
            accountID: String,
            generation: UInt64,
            logContext: LibraryLogContext,
            today: LocalDiaryDate,
            presentationID: UUID = UUID()
        ) {
            self.accountID = accountID
            self.sessionGeneration = generation
            self.logContext = logContext
            self.today = today
            self.presentationID = presentationID
        }

        public var filteredFoods: [CustomFood] {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return foods }
            return foods.filter { food in
                food.name.localizedCaseInsensitiveContains(query)
                    || (food.brand?.localizedCaseInsensitiveContains(query) ?? false)
                    || food.categories.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        public var isLoading: Bool {
            if case .loading = phase { true } else { false }
        }

        public var requestContext: FeatureRequestContext {
            FeatureRequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                presentationID: presentationID
            )
        }
    }

    public enum Action: Equatable, Sendable {
        case load
        case loadCompleted(requestID: UUID, context: FeatureRequestContext, result: Result<[CustomFood], LibraryFailure>)
        case refresh
        case searchChanged(String)
        case openDetail(id: String)
        case detailDismissed
        case detail(CustomFoodDetailFeature.Action)
        case removeFood(id: String)
        case openCustomFoodEditor
        case openCreation(entry: FoodCreationEntry)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case openDetail(
            id: String, date: LocalDiaryDate, generation: UInt64, presentationID: UUID
        )
        case openEditor(
            mode: CustomFoodEditorMode, date: LocalDiaryDate, slot: MealSlot?,
            generation: UInt64, presentationID: UUID
        )
        case openCreation(
            entry: FoodCreationEntry, date: LocalDiaryDate, slot: MealSlot?,
            generation: UInt64, presentationID: UUID
        )
        case deleted(id: String, generation: UInt64)
        case sessionExpired(generation: UInt64)
        case dismiss(generation: UInt64)
    }

    public struct Client: Sendable {
        public var list: @Sendable (FeatureRequestContext) async throws -> [CustomFood]
        public var customFood: @Sendable (FeatureRequestContext, String) async throws -> CustomFood
        public var delete: @Sendable (FeatureRequestContext, String) async throws -> Void
        public static func live(
            service: any LibraryServicing,
            isCurrent: @escaping FeatureContextGuard
        ) -> Self {
            func guardContext(_ context: FeatureRequestContext) async throws {
                guard await isCurrent(context) else { throw FeatureContextError.stale }
            }
            return Self(
                list: { context in
                    try await guardContext(context)
                    return try await service.listCustomFoods()
                },
                customFood: { context, id in
                    try await guardContext(context)
                    return try await service.customFood(id: id)
                },
                delete: { context, id in
                    try await guardContext(context)
                    try await service.deleteCustomFood(id: id)
                }
            )
        }
    }

    @Dependency(\.libraryClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .load, .refresh:
                let requestID = uuid()
                state.loadRequestID = requestID
                if state.foods.isEmpty { state.phase = .loading }
                state.refreshError = nil
                let context = state.requestContext
                let client = self.client
                return .run { send in
                    do {
                        let foods = try await client.list(context)
                        await send(.loadCompleted(
                            requestID: requestID, context: context, result: .success(foods)
                        ))
                    } catch {
                        await send(.loadCompleted(
                            requestID: requestID,
                            context: context,
                            result: .failure(LibraryFailure.map(error))
                        ))
                    }
                }

            case let .loadCompleted(requestID, context, result):
                guard state.loadRequestID == requestID,
                      context == state.requestContext else { return .none }
                switch result {
                case let .success(foods):
                    state.foods = foods.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    state.phase = .loaded
                case let .failure(failure):
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                    if state.foods.isEmpty {
                        state.phase = .failed(failure.message)
                    } else {
                        state.refreshError = failure.message
                    }
                }
                return .none

            case let .searchChanged(text):
                state.searchText = text
                return .none

            case let .openDetail(id):
                let presentationID = uuid()
                state.detail = CustomFoodDetailFeature.State(
                    foodID: id,
                    accountID: state.accountID,
                    generation: state.sessionGeneration,
                    presentationID: presentationID
                )
                return .send(.delegate(.openDetail(
                    id: id,
                    date: state.logContext.date,
                    generation: state.sessionGeneration,
                    presentationID: presentationID
                )))

            case .detailDismissed:
                state.detail = nil
                return .none

            case let .removeFood(id):
                state.foods.removeAll { $0.id == id }
                if state.foods.isEmpty, case .loaded = state.phase { state.phase = .loaded }
                return .none

            case .openCustomFoodEditor:
                return .send(.delegate(.openEditor(
                    mode: .create,
                    date: state.logContext.date,
                    slot: state.logContext.mealSlot,
                    generation: state.sessionGeneration,
                    presentationID: uuid()
                )))

            case let .openCreation(entry):
                return .send(.delegate(.openCreation(
                    entry: entry,
                    date: state.logContext.date,
                    slot: state.logContext.mealSlot,
                    generation: state.sessionGeneration,
                    presentationID: uuid()
                )))

            case let .detail(childAction):
                guard var child = state.detail else { return .none }
                let childEffect = CustomFoodDetailFeature().reduce(into: &child, action: childAction)
                state.detail = child
                switch childAction {
                case let .delegate(.deleted(id, generation)):
                    guard generation == state.sessionGeneration else { return childEffect.map(Action.detail) }
                    state.foods.removeAll { $0.id == id }
                    state.detail = nil
                    return .merge(
                        childEffect.map(Action.detail),
                        .send(.delegate(.deleted(id: id, generation: generation)))
                    )
                case let .delegate(.edit(id, generation)):
                    guard generation == state.sessionGeneration else { return childEffect.map(Action.detail) }
                    return .merge(
                        childEffect.map(Action.detail),
                        .send(.delegate(.openEditor(
                            mode: .edit(id: id),
                            date: state.logContext.date,
                            slot: state.logContext.mealSlot,
                            generation: generation,
                            presentationID: uuid()
                        )))
                    )
                case let .delegate(.sessionExpired(generation)):
                    guard generation == state.sessionGeneration else { return childEffect.map(Action.detail) }
                    return .merge(
                        childEffect.map(Action.detail),
                        .send(.delegate(.sessionExpired(generation: generation)))
                    )
                case .delegate:
                    break
                default:
                    break
                }
                return childEffect.map(Action.detail)

            case .delegate:
                return .none
            }
        }
    }
}

// MARK: - Custom food detail

@Reducer
public struct CustomFoodDetailFeature {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded(CustomFood)
        case removed
        case failed(String)
    }

    public enum DeletePhase: Equatable, Sendable {
        case idle
        case deleting
        case failed(String)
    }

    @ObservableState
    public struct State: Equatable {
        public let foodID: String
        public let accountID: String
        public let sessionGeneration: UInt64
        public let presentationID: UUID
        public var phase: Phase = .loading
        public var deletePhase: DeletePhase = .idle
        public var loadRequestID: UUID?
        public var deleteRequestID: UUID?

        public init(
            foodID: String,
            accountID: String,
            generation: UInt64,
            presentationID: UUID = UUID()
        ) {
            self.foodID = foodID
            self.accountID = accountID
            self.sessionGeneration = generation
            self.presentationID = presentationID
        }

        public var food: CustomFood? {
            if case .loaded(let food) = phase { food } else { nil }
        }

        public var isDeleting: Bool {
            if case .deleting = deletePhase { true } else { false }
        }

        public var deleteErrorMessage: String? {
            if case .failed(let message) = deletePhase { message } else { nil }
        }

        public var requestContext: FeatureRequestContext {
            FeatureRequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                presentationID: presentationID
            )
        }
    }

    public enum Action: Equatable, Sendable {
        case load
        case loadCompleted(requestID: UUID, context: FeatureRequestContext, result: Result<CustomFood, LibraryFailure>)
        case delete
        case deleteCompleted(requestID: UUID, context: FeatureRequestContext, generation: UInt64, result: Result<LibraryDeleteSucceeded, LibraryFailure>)
        case uncertainDeleteResolved(requestID: UUID, context: FeatureRequestContext, generation: UInt64, foods: [CustomFood])
        case clearDeleteError
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case deleted(id: String, generation: UInt64)
        case edit(id: String, generation: UInt64)
        case sessionExpired(generation: UInt64)
    }

    @Dependency(\.libraryClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .load:
                let requestID = uuid()
                state.loadRequestID = requestID
                state.phase = .loading
                let context = state.requestContext
                let client = self.client
                let id = state.foodID
                return .run { send in
                    do {
                        let food = try await client.customFood(context, id)
                        await send(.loadCompleted(
                            requestID: requestID, context: context, result: .success(food)
                        ))
                    } catch {
                        await send(.loadCompleted(
                            requestID: requestID,
                            context: context,
                            result: .failure(LibraryFailure.map(error))
                        ))
                    }
                }

            case let .loadCompleted(requestID, context, result):
                guard state.loadRequestID == requestID,
                      context == state.requestContext,
                      case .loading = state.phase else {
                    return .none
                }
                state.loadRequestID = nil
                switch result {
                case let .success(food):
                    state.phase = .loaded(food)
                case let .failure(failure):
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                    if case .notFound = failure {
                        state.phase = .removed
                    } else {
                        state.phase = .failed(failure.message)
                    }
                }
                return .none

            case .delete:
                guard !state.isDeleting, state.food != nil else { return .none }
                state.deletePhase = .deleting
                let requestID = uuid()
                state.deleteRequestID = requestID
                let context = state.requestContext
                let client = self.client
                let id = state.foodID
                let generation = state.sessionGeneration
                return .run { send in
                    do {
                        try await client.delete(context, id)
                        await send(.deleteCompleted(
                            requestID: requestID, context: context,
                            generation: generation, result: .success(LibraryDeleteSucceeded())
                        ))
                    } catch {
                        await send(.deleteCompleted(
                            requestID: requestID,
                            context: context,
                            generation: generation,
                            result: .failure(LibraryFailure.map(error))
                        ))
                    }
                }

            case let .deleteCompleted(requestID, context, generation, result):
                guard requestID == state.deleteRequestID,
                      context == state.requestContext,
                      generation == state.sessionGeneration else { return .none }
                state.deleteRequestID = nil
                switch result {
                case .success:
                    state.deletePhase = .idle
                    return .send(.delegate(.deleted(
                        id: state.foodID, generation: state.sessionGeneration
                    )))
                case let .failure(failure):
                    switch failure {
                    case .unauthorized:
                        state.deletePhase = .failed(failure.message)
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    case .notFound:
                        // A repeated DELETE after a lost success is a success.
                        state.deletePhase = .idle
                        return .send(.delegate(.deleted(
                            id: state.foodID, generation: state.sessionGeneration
                        )))
                    case .uncertain:
                        // Refresh the authoritative list before offering another
                        // destructive action; never blindly retry the DELETE.
                        let resolutionID = uuid()
                        state.deleteRequestID = resolutionID
                        let client = self.client
                        let resolvedContext = state.requestContext
                        let resolvedGeneration = state.sessionGeneration
                        return .run { send in
                            let foods = try? await client.list(resolvedContext)
                            await send(.uncertainDeleteResolved(
                                requestID: resolutionID,
                                context: resolvedContext,
                                generation: resolvedGeneration,
                                foods: foods ?? []
                            ))
                        }
                    case let .failed(message), let .conflict(message):
                        state.deletePhase = .failed(message)
                    case .rateLimited:
                        state.deletePhase = .failed(
                            String(localized: "foodDetail.error.rateLimited")
                        )
                    }
                }
                return .none

            case let .uncertainDeleteResolved(requestID, context, generation, foods):
                guard requestID == state.deleteRequestID,
                      context == state.requestContext,
                      generation == state.sessionGeneration else { return .none }
                state.deleteRequestID = nil
                if foods.contains(where: { $0.id == state.foodID }) {
                    state.deletePhase = .failed(String(localized: "library.detail.deleteUncertain"))
                } else {
                    state.deletePhase = .idle
                    return .send(.delegate(.deleted(
                        id: state.foodID, generation: state.sessionGeneration
                    )))
                }
                return .none

            case .clearDeleteError:
                if case .failed = state.deletePhase { state.deletePhase = .idle }
                return .none

            case .delegate:
                return .none
            }
        }
    }
}

extension DependencyValues {
    public var libraryClient: LibraryFeature.Client {
        get { self[LibraryClientKey.self] }
        set { self[LibraryClientKey.self] = newValue }
    }

    public var libraryLogClient: LibraryLogClient {
        get { self[LibraryLogClientKey.self] }
        set { self[LibraryLogClientKey.self] = newValue }
    }
}

private enum LibraryClientKey: DependencyKey {
    static let liveValue: LibraryFeature.Client = .init(
        list: { _ in [] },
        customFood: { _, _ in throw CustomFoodServiceError.notFound("unimplemented") },
        delete: { _, _ in }
    )
    static let testValue = liveValue
}

private enum LibraryLogClientKey: DependencyKey {
    static let liveValue: LibraryLogClient = LibraryLogClient(
        submit: { _, _, _, _, _, completion in
            completion(.failure(.failed(String(localized: "library.submission.unavailable"))))
        },
        isCurrentOwner: { _, _ in false }
    )
    static let testValue = liveValue
}
