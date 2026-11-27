// Meal list reducer: load/refresh and quick-add through the shared writer.
// Every request captures account/generation/owner/requestID before any await;
// completions are rejected if that authority or request identity changed.

import ComposableArchitecture
import Foundation

public enum MealsListPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded([Meal])
    /// Previous valid results stay visible while a refresh is in flight. This
    /// is one lifecycle case, not an `isRefreshing` boolean beside `loaded`.
    case refreshing(previous: [Meal])
    case failed(String)

    public var meals: [Meal] {
        switch self {
        case .loaded(let meals), .refreshing(previous: let meals): return meals
        case .idle, .loading, .failed: return []
        }
    }

    public var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    public var isRefreshing: Bool {
        if case .refreshing = self { true } else { false }
    }
}

@Reducer
public struct MealsListFeature {
    @ObservableState
    public struct State: Equatable {
        public let context: MealsCaptureContext
        public var phase: MealsListPhase = .idle
        public var transientError: String?
        public var quickAddState: MealQuickAddState = .idle

        var pendingLoadID: UUID?
        var pendingSubmissionID: UUID?

        public init(context: MealsCaptureContext) {
            self.context = context
        }

        public var meals: [Meal] { phase.meals }
        public var isEmpty: Bool {
            guard case .loaded(let meals) = phase else { return false }
            return meals.isEmpty
        }

        public var quickAddMessage: String? {
            switch quickAddState {
            case .idle, .submitting: return nil
            case .added: return String(localized: "meals.list.quickAdd.added")
            case .failed(let message): return message
            }
        }

        public func canQuickAdd(_ meal: Meal) -> Bool {
            guard context.allowsLogging,
                  !meal.isDegraded,
                  quickAddStateIsIdle else { return false }
            return MealLogDraftBuilder.makeDraft(
                meal: meal,
                date: context.date,
                mealSlot: context.mealSlot,
                timeZone: context.timeZone
            ) != nil
        }

        private var quickAddStateIsIdle: Bool {
            if case .idle = quickAddState { true } else { false }
        }
    }

    public enum Action: Sendable {
        case onAppear
        case loadIfNeeded
        case load
        case refresh
        case mealsReceived(context: MealsRequestContext, meals: [Meal])
        case loadFailed(context: MealsRequestContext, message: String)
        case loadUnauthorized(context: MealsRequestContext)
        case loadCancelled(context: MealsRequestContext)
        case dismissTransientError
        case openMeal(Meal)
        case createMeal
        case quickAdd(mealID: String, portion: NutritionQuantity?)
        case quickAddSubmitted(mealID: String, payload: MealsLoggedPayload)
        case dismissQuickAddMessage
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case openDetail(mealID: String, context: LibraryLogContext, generation: UInt64, presentationID: UUID)
        case openEditor(id: String, name: String, context: LibraryLogContext, generation: UInt64, presentationID: UUID)
        case logged(MealsLoggedPayload)
        case sessionExpired(generation: UInt64, presentationID: UUID)
    }

    @Dependency(\.mealsClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear, .loadIfNeeded:
                guard case .idle = state.phase else { return .none }
                return .send(.load)

            case .load:
                let hadContent = !state.meals.isEmpty
                state.phase = hadContent ? .refreshing(previous: state.meals) : .loading
                state.transientError = nil
                let requestID = uuid()
                state.pendingLoadID = requestID
                let request = state.context.requestContext(requestID: requestID)
                return .run { send in
                    do {
                        let meals = try await client.listMeals(request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.mealsReceived(context: request, meals: meals))
                    } catch {
                        await Self.handleLoadError(error, request: request, send: send, client: client)
                    }
                }

            case .refresh:
                return .send(.load)

            case let .mealsReceived(request, meals):
                guard Self.isAuthorized(state, request: request),
                      state.pendingLoadID == request.requestID else { return .none }
                state.pendingLoadID = nil
                state.phase = .loaded(meals)
                state.transientError = nil
                return .none

            case let .loadFailed(request, message):
                guard Self.isAuthorized(state, request: request),
                      state.pendingLoadID == request.requestID else { return .none }
                state.pendingLoadID = nil
                if !state.meals.isEmpty {
                    state.phase = .loaded(state.meals)
                    state.transientError = message
                } else {
                    state.phase = .failed(message)
                }
                return .none

            case let .loadUnauthorized(request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingLoadID == request.requestID else { return .none }
                state.pendingLoadID = nil
                state.transientError = nil
                state.phase = state.meals.isEmpty
                    ? .failed(String(localized: "meals.error.sessionExpired"))
                    : .loaded(state.meals)
                return .send(.delegate(.sessionExpired(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .loadCancelled(request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingLoadID == request.requestID else { return .none }
                state.pendingLoadID = nil
                if state.meals.isEmpty { state.phase = .idle }
                return .none

            case .dismissTransientError:
                state.transientError = nil
                return .none

            case let .openMeal(meal):
                return .send(.delegate(.openDetail(
                    mealID: meal.id,
                    context: state.context.loggingContext(),
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case .createMeal:
                return .send(.delegate(.openEditor(
                    id: "",
                    name: "",
                    context: state.context.loggingContext(),
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .quickAdd(mealID, portion):
                guard state.context.allowsLogging,
                      case .idle = state.quickAddState,
                      let meal = state.meals.first(where: { $0.id == mealID }),
                      !meal.isDegraded else { return .none }
                guard let draft = MealLogDraftBuilder.makeDraft(
                    meal: meal,
                    date: state.context.date,
                    mealSlot: state.context.mealSlot,
                    amount: portion?.amount,
                    unit: portion?.unit,
                    timeZone: state.context.timeZone
                ) else {
                    state.quickAddState = .failed(String(localized: "meals.error.invalidPortion"))
                    return .none
                }
                let captured = state.context.loggingContext()
                let accountID = state.context.accountID
                let generation = state.context.generation
                let presentationID = state.context.id
                let requestID = uuid()
                let request = state.context.requestContext(requestID: requestID)
                let drafts = [draft]
                state.pendingSubmissionID = requestID
                state.quickAddState = .submitting(mealID: mealID)
                return .run { send in
                    let result = await client.submitDraft(drafts, [meal.name], meal.name, request)
                    guard await Self.isCurrent(request, client: client) else { return }
                    let payload = MealsLoggedPayload(
                        requestID: requestID,
                        drafts: drafts,
                        context: captured,
                        accountID: accountID,
                        generation: generation,
                        presentationID: presentationID,
                        result: result
                    )
                    await send(.quickAddSubmitted(mealID: mealID, payload: payload))
                }

            case let .quickAddSubmitted(mealID, payload):
                guard case .submitting(let submittingID) = state.quickAddState,
                      submittingID == mealID,
                      state.pendingSubmissionID == payload.requestID,
                      payload.accountID == state.context.accountID,
                      payload.generation == state.context.generation,
                      payload.presentationID == state.context.id else { return .none }
                state.pendingSubmissionID = nil
                switch payload.result {
                case .success:
                    state.quickAddState = .added(mealID: mealID)
                    return .send(.delegate(.logged(payload)))
                case .failure(.unauthorized):
                    state.quickAddState = .failed(String(localized: "foodDetail.error.sessionExpired"))
                    return .send(.delegate(.sessionExpired(
                        generation: state.context.generation,
                        presentationID: state.context.id
                    )))
                case .failure(.uncertain):
                    state.quickAddState = .failed(String(
                        localized: "meals.list.quickAdd.uncertain",
                        defaultValue: "CalCo couldn't confirm this log. Check the diary before retrying."
                    ))
                    return .none
                case .failure(.failed(let message)):
                    state.quickAddState = .failed(message)
                    return .none
                }

            case .dismissQuickAddMessage:
                if case .submitting = state.quickAddState { return .none }
                state.quickAddState = .idle
                state.pendingSubmissionID = nil
                return .none

            case .delegate:
                return .none
            }
        }
    }

    /// Pure state/identity comparison. Live session authority is checked only
    /// in the async effect and inside the client before transport (both can
    /// await MainActor); a synchronous reducer must not call that @MainActor API.
    private static func isAuthorized(
        _ state: State, request: MealsRequestContext
    ) -> Bool {
        request.accountID == state.context.accountID
            && request.generation == state.context.generation
            && request.ownerID == state.context.id
    }

    private static func isCurrent(
        _ request: MealsRequestContext, client: MealsFeatureClient
    ) async -> Bool {
        await MainActor.run {
            client.isCurrentSession(request.accountID, request.generation)
        }
    }

    private static func handleLoadError(
        _ error: Error,
        request: MealsRequestContext,
        send: Send<Action>,
        client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        if isUnauthorizedMealError(error) {
            await send(.loadUnauthorized(context: request))
        } else if let mealError = error as? MealServiceError,
                  case .cancelled = mealError {
            await send(.loadCancelled(context: request))
        } else {
            let message = mealServiceMessage(error)
            await send(.loadFailed(
                context: request,
                message: message.isEmpty ? String(localized: "meals.error.loadFailed") : message
            ))
        }
    }
}
