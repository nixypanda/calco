// Meal detail reducer: recipe load, degraded/missing component resolution,
// debounced server portion preview, last-used prefill, delete, and single-POST
// logging. Every RPC carries captured account/generation/owner/requestID; the
// live client guards before transport and completions re-check authority.

import ComposableArchitecture
import Dependencies
import Foundation

@Reducer
public struct MealDetailFeature {
    @ObservableState
    public struct State: Equatable {
        public let context: MealsCaptureContext
        public let mealID: String
        public let fallbackName: String?
        public let preferredPortion: NutritionQuantity?

        public var loadState: MealDetailLoadState = .loading
        public var componentNames: [String: String] = [:]
        public var missingComponentIDs: Set<String> = []
        public var units: [ProductUnit] = []
        public var previewState: MealPortionPreviewState = .idle
        public var deleteState: MealDeleteState = .idle
        public var logState: MealLogState = .idle
        public var unitFallbackNotice: String?
        public var portionFallbackNotice: String?

        public var portionAmount: String = "100"
        public var portionUnit: String = "g"
        public var mealSlot: MealSlot?
        public var logNotes: String = ""

        // Request identity only; never a service, cache or authority.
        var loadedMeal: Meal?
        var portionWasEdited = false
        var loadToken = 0
        var previewToken = 0
        var lastUsedToken = 0
        var activeLoadRequestID: UUID?
        var activePreviewRequestID: UUID?
        var activeLastUsedRequestID: UUID?
        var pendingDeleteRequestID: UUID?
        var pendingSubmissionID: UUID?

        public init(
            context: MealsCaptureContext,
            mealID: String,
            mealName: String? = nil,
            initialPortion: NutritionQuantity? = nil
        ) {
            self.context = context
            self.mealID = mealID
            self.fallbackName = mealName
            self.preferredPortion = initialPortion
            self.mealSlot = context.mealSlot
        }

        public var meal: Meal? { loadedMeal }

        public var displayName: String {
            loadedMeal?.name ?? fallbackName ?? String(localized: "meals.detail.title")
        }

        public var isLoading: Bool {
            if case .loading = loadState { true } else { false }
        }

        public var supportsLogging: Bool { context.allowsLogging }

        public var isLogging: Bool {
            if case .submitting = logState { true } else { false }
        }

        public var isDeleting: Bool {
            if case .deleting = deleteState { true } else { false }
        }

        public var didLog: Bool {
            if case .succeeded = logState { true } else { false }
        }

        public var canLog: Bool {
            context.allowsLogging
                && loadedMeal != nil
                && loadedMeal?.isDegraded != true
                && !isLogging
                && !isDeleting
        }

        public var availableUnits: [ProductUnit] {
            MealQuantityRules.massUnits(from: units)
        }

        public var logFormUnits: [FoodUnit] {
            availableUnits.map { FoodUnit(code: $0.code, name: $0.name, kind: $0.kind) }
        }

        public var amountValidationMessage: String? {
            let trimmedAmount = portionAmount.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedAmount.isEmpty { return String(localized: "meals.error.amountRequired") }
            guard MealQuantityRules.normalizedPositiveDecimal(trimmedAmount) != nil else {
                return String(localized: "meals.error.amountInvalid")
            }
            let trimmedUnit = portionUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUnit.isEmpty { return String(localized: "meals.error.unitRequired") }
            if !MealQuantityRules.isMassUnit(trimmedUnit) {
                return String(localized: "meals.error.portionUnit")
            }
            return nil
        }

        public var logErrorMessage: String? {
            if case .failed(let message) = logState { message } else { nil }
        }

        public var deleteErrorMessage: String? {
            if case .failed(let message) = deleteState { message } else { nil }
        }

        public var missingComponentsMessage: String? {
            missingComponentIDs.isEmpty ? nil : String(localized: "meals.detail.missingComponents")
        }

        public func componentName(_ component: MealComponent) -> String {
            if component.missing {
                return component.name ?? String(localized: "meals.editor.missingFood")
            }
            if missingComponentIDs.contains(component.item.id) {
                return String(localized: "meals.editor.missingFood")
            }
            if let name = componentNames[component.item.id], !name.isEmpty { return name }
            return String(localized: "meals.editor.unknownFood")
        }
    }

    public enum Action: Sendable {
        case onAppear
        case loadIfNeeded
        case load
        case retryLoad
        case mealReceived(context: MealsRequestContext, token: Int, meal: Meal, units: [ProductUnit], unitsFallback: Bool)
        case loadFailed(context: MealsRequestContext, token: Int, message: String, missingComponents: Bool)
        case loadUnauthorized(context: MealsRequestContext, token: Int)
        case portionAmountChanged(String)
        case portionUnitChanged(String)
        case mealSlotChanged(MealSlot?)
        case logNotesChanged(String)
        case refreshPreview
        case previewTimerFired(context: MealsRequestContext, token: Int, amount: String, unit: String)
        case previewReceived(context: MealsRequestContext, token: Int, nutrition: MealNutritionResponse)
        case previewFailed(context: MealsRequestContext, token: Int, message: String?, unauthorized: Bool)
        case lastUsedReceived(context: MealsRequestContext, token: Int, portion: NutritionQuantity?)
        case componentNameReceived(context: MealsRequestContext, token: Int, id: String, product: MealProduct?, unauthorized: Bool)
        case editTapped(Meal)
        case logMeal
        case logSubmitted(MealsLoggedPayload)
        case dismissLogResult
        case requestDelete
        case confirmDelete
        case deleteSucceeded(context: MealsRequestContext)
        case deleteNotFound(context: MealsRequestContext)
        case deleteCancelled(context: MealsRequestContext)
        case deleteFailed(context: MealsRequestContext, message: String)
        case deleteUnauthorized(context: MealsRequestContext)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case edit(Meal, context: LibraryLogContext, generation: UInt64, presentationID: UUID)
        case logged(MealsLoggedPayload)
        case deleted(mealID: String, generation: UInt64, presentationID: UUID)
        case sessionExpired(generation: UInt64, presentationID: UUID)
    }

    @Dependency(\.mealsClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear, .loadIfNeeded:
                guard state.loadedMeal == nil else { return .none }
                return .send(.load)

            case .load, .retryLoad:
                state.loadToken += 1
                state.previewToken += 1
                state.lastUsedToken += 1
                let token = state.loadToken
                state.loadState = .loading
                state.componentNames = [:]
                state.missingComponentIDs = []
                state.previewState = .idle
                state.unitFallbackNotice = nil
                state.portionFallbackNotice = nil
                state.portionWasEdited = false
                let request = state.context.requestContext(requestID: uuid())
                state.activeLoadRequestID = request.requestID
                let mealID = state.mealID
                let unitsRequest = state.context.requestContext(requestID: uuid())
                return .run { send in
                    do {
                        async let mealTask = client.getMeal(mealID, request)
                        async let unitsTask = client.fetchUnits(unitsRequest)
                        let meal = try await mealTask
                        let units = try? await unitsTask
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.mealReceived(
                            context: request,
                            token: token,
                            meal: meal,
                            units: units ?? [],
                            unitsFallback: (units?.isEmpty ?? true)
                        ))
                    } catch {
                        await Self.handleLoadError(error, request: request, token: token, send: send, client: client)
                    }
                }

            case let .mealReceived(request, token, meal, units, unitsFallback):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                if unitsFallback {
                    state.units = [ProductUnit(code: "g", name: "Gram", kind: "mass")]
                    state.unitFallbackNotice = String(localized: "meals.editor.unitFallback")
                } else {
                    state.units = units
                    state.unitFallbackNotice = nil
                }
                state.loadedMeal = meal
                state.missingComponentIDs = Set(meal.components.filter(\.missing).map(\.item.id))
                for component in meal.components where component.missing {
                    state.componentNames[component.item.id] = component.name
                        ?? String(localized: "meals.editor.missingFood")
                }
                Self.applyDefaultPortion(&state, for: meal)
                state.loadState = .loaded
                var effects: [Effect<Action>] = []
                if state.preferredPortion == nil {
                    effects.append(Self.lastUsedLookup(&state, client: client, uuid: uuid, token: token))
                }
                effects.append(contentsOf: Self.nameResolutions(
                    &state, client: client, meal: meal, token: token, uuid: uuid
                ))
                effects.append(Self.schedulePreview(&state, client: client, uuid: uuid, immediate: true))
                return .merge(effects)

            case let .loadFailed(request, token, message, missingComponents):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                state.loadState = .failed(message: message, missingComponents: missingComponents)
                return .none

            case let .loadUnauthorized(request, token):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                state.loadState = .failed(
                    message: String(localized: "meals.error.sessionExpired"),
                    missingComponents: false
                )
                return .send(.delegate(.sessionExpired(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .portionAmountChanged(value):
                state.portionWasEdited = true
                state.portionAmount = value
                return Self.schedulePreview(&state, client: client, uuid: uuid, immediate: false)

            case let .portionUnitChanged(value):
                state.portionWasEdited = true
                state.portionUnit = value
                return Self.schedulePreview(&state, client: client, uuid: uuid, immediate: false)

            case let .mealSlotChanged(slot):
                state.mealSlot = slot
                state.logState = .idle
                return .none

            case let .logNotesChanged(notes):
                state.logNotes = notes
                return .none

            case .refreshPreview:
                return Self.schedulePreview(&state, client: client, uuid: uuid, immediate: true)

            case let .previewTimerFired(request, token, amount, unit):
                guard Self.isAuthorized(state, request: request),
                      token == state.previewToken,
                      state.activePreviewRequestID == request.requestID else { return .none }
                let mealID = state.mealID
                return .run { send in
                    do {
                        let nutrition = try await client.mealNutrients(mealID, amount, unit, request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.previewReceived(context: request, token: token, nutrition: nutrition))
                    } catch {
                        await Self.handlePreviewError(
                            error, request: request, token: token, send: send, client: client
                        )
                    }
                }

            case let .previewReceived(request, token, nutrition):
                guard Self.isAuthorized(state, request: request),
                      token == state.previewToken,
                      state.activePreviewRequestID == request.requestID else { return .none }
                state.activePreviewRequestID = nil
                state.previewState = .loaded(nutrition)
                return .none

            case let .previewFailed(request, token, message, unauthorized):
                guard Self.isAuthorized(state, request: request),
                      token == state.previewToken,
                      state.activePreviewRequestID == request.requestID else { return .none }
                state.activePreviewRequestID = nil
                if unauthorized {
                    state.previewState = .failed(String(localized: "meals.error.sessionExpired"))
                    return .send(.delegate(.sessionExpired(
                        generation: state.context.generation,
                        presentationID: state.context.id
                    )))
                }
                if message?.isEmpty ?? true { return .none }
                state.previewState = .failed(message ?? String(localized: "meals.error.previewFailed"))
                return .none

            case let .lastUsedReceived(request, token, portion):
                guard Self.isAuthorized(state, request: request),
                      token == state.lastUsedToken,
                      state.activeLastUsedRequestID == request.requestID,
                      token == state.loadToken else { return .none }
                state.activeLastUsedRequestID = nil
                guard !state.portionWasEdited, let portion else { return .none }
                guard MealQuantityRules.isMassUnit(portion.unit),
                      MealQuantityRules.normalizedPositiveDecimal(portion.amount) != nil else {
                    state.portionFallbackNotice = String(
                        localized: "meals.detail.lastUsed.unavailableUnit"
                    )
                    return .none
                }
                Self.setPortion(&state, portion)
                state.portionFallbackNotice = nil
                return Self.schedulePreview(&state, client: client, uuid: uuid, immediate: true)

            case let .componentNameReceived(request, token, id, product, unauthorized):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken else { return .none }
                if unauthorized {
                    return .send(.delegate(.sessionExpired(
                        generation: state.context.generation,
                        presentationID: state.context.id
                    )))
                }
                if let product {
                    state.componentNames[id] = product.name
                    state.missingComponentIDs.remove(id)
                } else {
                    state.componentNames[id] = String(localized: "meals.editor.missingFood")
                    state.missingComponentIDs.insert(id)
                }
                return .none

            case let .editTapped(meal):
                return .send(.delegate(.edit(
                    meal,
                    context: state.context.loggingContext(),
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case .logMeal:
                guard state.context.allowsLogging,
                      let meal = state.loadedMeal,
                      !meal.isDegraded,
                      !state.isLogging,
                      !state.isDeleting,
                      state.amountValidationMessage == nil else { return .none }
                guard let draft = MealLogDraftBuilder.makeDraft(
                    meal: meal,
                    date: state.context.date,
                    mealSlot: state.mealSlot,
                    amount: state.portionAmount,
                    unit: state.portionUnit,
                    notes: state.logNotes,
                    timeZone: state.context.timeZone
                ) else {
                    state.logState = .failed(String(localized: "meals.error.invalidPortion"))
                    return .none
                }
                state.logState = .submitting
                let captured = LibraryLogContext(date: state.context.date, mealSlot: state.mealSlot)
                let accountID = state.context.accountID
                let generation = state.context.generation
                let presentationID = state.context.id
                let requestID = uuid()
                let request = state.context.requestContext(requestID: requestID)
                let drafts = [draft]
                state.pendingSubmissionID = requestID
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
                    await send(.logSubmitted(payload))
                }

            case let .logSubmitted(payload):
                guard case .submitting = state.logState,
                      state.pendingSubmissionID == payload.requestID,
                      payload.accountID == state.context.accountID,
                      payload.generation == state.context.generation,
                      payload.presentationID == state.context.id else { return .none }
                state.pendingSubmissionID = nil
                switch payload.result {
                case .success(let logs):
                    state.logState = .succeeded(logID: logs.first?.id)
                    return .send(.delegate(.logged(payload)))
                case .failure(.unauthorized):
                    state.logState = .failed(String(localized: "foodDetail.error.sessionExpired"))
                    return .send(.delegate(.sessionExpired(
                        generation: state.context.generation,
                        presentationID: state.context.id
                    )))
                case .failure(.uncertain):
                    state.logState = .failed(String(
                        localized: "meals.detail.log.uncertain",
                        defaultValue: "CalCo couldn't confirm this log. Check the diary before retrying."
                    ))
                    return .none
                case .failure(.failed(let message)):
                    state.logState = .failed(message)
                    return .none
                }

            case .dismissLogResult:
                switch state.logState {
                case .succeeded, .failed:
                    state.logState = .idle
                    state.pendingSubmissionID = nil
                case .idle, .submitting: break
                }
                return .none

            case .requestDelete:
                return .none

            case .confirmDelete:
                guard !state.isDeleting else { return .none }
                state.deleteState = .deleting
                let request = state.context.requestContext(requestID: uuid())
                state.pendingDeleteRequestID = request.requestID
                let mealID = state.mealID
                return .run { send in
                    do {
                        try await client.deleteMeal(mealID, request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.deleteSucceeded(context: request))
                    } catch {
                        await Self.handleDeleteError(
                            error, request: request, send: send, client: client
                        )
                    }
                }

            case let .deleteSucceeded(request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingDeleteRequestID == request.requestID else { return .none }
                state.pendingDeleteRequestID = nil
                state.deleteState = .deleted
                return .send(.delegate(.deleted(
                    mealID: state.mealID,
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .deleteNotFound(request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingDeleteRequestID == request.requestID else { return .none }
                state.pendingDeleteRequestID = nil
                state.deleteState = .deleted
                return .send(.delegate(.deleted(
                    mealID: state.mealID,
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .deleteCancelled(request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingDeleteRequestID == request.requestID else { return .none }
                state.pendingDeleteRequestID = nil
                state.deleteState = .idle
                return .none

            case let .deleteFailed(request, message):
                guard Self.isAuthorized(state, request: request),
                      state.pendingDeleteRequestID == request.requestID else { return .none }
                state.pendingDeleteRequestID = nil
                state.deleteState = .failed(message)
                return .none

            case let .deleteUnauthorized(request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingDeleteRequestID == request.requestID else { return .none }
                state.pendingDeleteRequestID = nil
                state.deleteState = .failed(String(localized: "meals.error.sessionExpired"))
                return .send(.delegate(.sessionExpired(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case .delegate:
                return .none
            }
        }
    }

    /// Pure identity comparison; live @MainActor authority is awaited in effects.
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

    private static func applyDefaultPortion(_ state: inout State, for meal: Meal) {
        if let preferred = state.preferredPortion {
            if MealQuantityRules.isMassUnit(preferred.unit),
               MealQuantityRules.normalizedPositiveDecimal(preferred.amount) != nil {
                setPortion(&state, preferred)
                state.portionFallbackNotice = nil
                return
            }
            state.portionFallbackNotice = String(localized: "meals.detail.lastUsed.unavailableUnit")
        }
        setPortion(&state, meal.defaultPortion)
    }

    private static func setPortion(_ state: inout State, _ portion: NutritionQuantity) {
        state.portionAmount = portion.amount
        state.portionUnit = portion.unit
    }

    private static func lastUsedLookup(
        _ state: inout State,
        client: MealsFeatureClient,
        uuid: UUIDGenerator,
        token: Int
    ) -> Effect<Action> {
        state.lastUsedToken = token
        let request = state.context.requestContext(requestID: uuid())
        state.activeLastUsedRequestID = request.requestID
        let mealID = state.mealID
        let date = state.context.date
        let slot = state.context.mealSlot
        return .run { send in
            do {
                let portion = try await client.lastUsedPortion(mealID, date, slot, request)
                guard await isCurrent(request, client: client) else { return }
                await send(.lastUsedReceived(context: request, token: token, portion: portion))
            } catch {
                guard await isCurrent(request, client: client) else { return }
                if isUnauthorizedMealError(error) {
                    await send(.loadUnauthorized(context: request, token: token))
                }
            }
        }
    }

    private static func nameResolutions(
        _ state: inout State,
        client: MealsFeatureClient,
        meal: Meal,
        token: Int,
        uuid: UUIDGenerator
    ) -> [Effect<Action>] {
        meal.components.compactMap { component in
            guard !component.missing,
                  case .product = component.item.itemType else { return nil }
            let id = component.item.id
            let request = state.context.requestContext(requestID: uuid())
            return .run { send in
                do {
                    let product = try await client.fetchProduct(id, request)
                    guard await isCurrent(request, client: client) else { return }
                    await send(.componentNameReceived(
                        context: request, token: token, id: id,
                        product: product, unauthorized: false
                    ))
                } catch {
                    guard await isCurrent(request, client: client) else { return }
                    await send(.componentNameReceived(
                        context: request,
                        token: token,
                        id: id,
                        product: nil,
                        unauthorized: isUnauthorizedMealError(error)
                    ))
                }
            }
        }
    }

    private static func schedulePreview(
        _ state: inout State,
        client: MealsFeatureClient,
        uuid: UUIDGenerator,
        immediate: Bool
    ) -> Effect<Action> {
        state.previewToken += 1
        let token = state.previewToken
        guard let meal = state.loadedMeal else { return .none }
        if meal.isDegraded {
            state.previewState = .unavailable(String(localized: "meals.error.missingComponents"))
            return .none
        }
        if let message = state.amountValidationMessage {
            state.previewState = .unavailable(message)
            return .none
        }
        guard let amount = MealQuantityRules.normalizedPositiveDecimal(state.portionAmount) else {
            state.previewState = .unavailable(String(localized: "meals.error.amountInvalid"))
            return .none
        }
        let unit = state.portionUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        let delay = immediate ? 0 : client.debounceNanoseconds
        let request = state.context.requestContext(requestID: uuid())
        state.activePreviewRequestID = request.requestID
        state.previewState = .loading
        let mealID = state.mealID
        return .run { send in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard await isCurrent(request, client: client) else { return }
            await send(.previewTimerFired(context: request, token: token, amount: amount, unit: unit))
        }
    }

    private static func handleLoadError(
        _ error: Error,
        request: MealsRequestContext,
        token: Int,
        send: Send<Action>,
        client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        if isUnauthorizedMealError(error) {
            await send(.loadUnauthorized(context: request, token: token))
        } else if let mealError = error as? MealServiceError,
                  case .cancelled = mealError {
            await send(.loadFailed(
                context: request, token: token,
                message: String(localized: "meals.error.loadFailed"),
                missingComponents: false
            ))
        } else {
            let message = mealServiceMessage(error)
            await send(.loadFailed(
                context: request,
                token: token,
                message: message.isEmpty ? String(localized: "meals.error.loadFailed") : message,
                missingComponents: isMissingComponentsMealError(error)
            ))
        }
    }

    private static func handlePreviewError(
        _ error: Error,
        request: MealsRequestContext,
        token: Int,
        send: Send<Action>,
        client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        await send(.previewFailed(
            context: request,
            token: token,
            message: mealServiceMessage(error),
            unauthorized: isUnauthorizedMealError(error)
        ))
    }

    private static func handleDeleteError(
        _ error: Error,
        request: MealsRequestContext,
        send: Send<Action>,
        client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        if isUnauthorizedMealError(error) {
            await send(.deleteUnauthorized(context: request))
        } else if let mealError = error as? MealServiceError {
            switch mealError {
            case .notFound: await send(.deleteNotFound(context: request))
            case .cancelled: await send(.deleteCancelled(context: request))
            default:
                let message = mealServiceMessage(error)
                await send(.deleteFailed(
                    context: request,
                    message: message.isEmpty ? String(localized: "meals.error.deleteFailed") : message
                ))
            }
        } else {
            let message = mealServiceMessage(error)
            await send(.deleteFailed(
                context: request,
                message: message.isEmpty ? String(localized: "meals.error.deleteFailed") : message
            ))
        }
    }
}
