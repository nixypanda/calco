// Real TCA ad-hoc logging feature. `.logOnly` uses the shared writer directly;
// `.saveAndLog` creates the catalog entry once, retains its ID, and only an
// explicit user retry logs that retained food. No blind create retry.

import ComposableArchitecture
import Foundation

@Reducer
public struct AdHocLogFeature {
    public struct LoadPayload: Equatable, Sendable {
        public let definitions: [NutrientDefinition]
        public let units: [ProductUnit]
    }

    @ObservableState
    public struct State: Equatable {
        public let accountID: String
        public let sessionGeneration: UInt64
        public let today: LocalDiaryDate
        public let logContext: LibraryLogContext
        public let presentationID: UUID
        public let initialAssistantDraft: AssistantReviewedDraft?

        public var loadPhase: LibraryLoadState = .loading
        public var definitions: [NutrientDefinition] = []
        public var units: [FoodUnit] = []
        public var submissionState: LibrarySubmissionState = .idle
        public var savedFoodLogState: SavedFoodLogState = .none
        public var isSavingFood = false
        public var formError: String?
        public var savedFoodID: String?
        public var savedFoodName: String?
        public var savedLogIntent: SavedFoodLogIntent?
        public var savedFoodIntentID: String?
        public var isDirty = false
        public var pendingReview: AdHocReview?
        public var hasAttemptedReview = false
        public var loadRequestID: UUID?

        public var name = ""
        public var brand = ""
        public var date: LocalDiaryDate
        public var mealSlot: MealSlot?
        public var amount = "100"
        public var unit = "g"
        public var notes = ""
        public var portionWeightText = ""
        public var mode: AdHocSaveMode = .logOnly
        public var nutrientEditor = NutrientEditorState(definitions: [])

        public var assistantServingGrams: [String: Decimal] = [:]
        public var assistantPortionWeightGrams: Decimal?
        public var assistantQuantityNeedsReview = false
        public var latestIssuedReviewID: String?
        /// Immutable issued review retained after SwiftUI clears its alert
        /// binding, so a captured confirmation can still be validated.
        public var latestIssuedReview: AdHocReview?
        public var latestIssuedReviewContext: FeatureRequestContext?
        /// Accepted confirmations are single-use even if the same captured
        /// action is delivered again after a failure or completion.
        public var confirmedReviewID: String?

        /// Identity of the in-flight logical write. Every completion is checked
        /// against request ID, generation, and account before it can settle.
        public var activeWriteRequestID: UUID?
        public var activeWriteGeneration: UInt64?
        public var activeWriteAccountID: String?

        public init(
            accountID: String,
            generation: UInt64,
            today: LocalDiaryDate,
            logContext: LibraryLogContext,
            presentationID: UUID = UUID(),
            assistantDraft: AssistantReviewedDraft? = nil
        ) {
            self.accountID = accountID
            self.sessionGeneration = generation
            self.today = today
            self.logContext = logContext
            self.presentationID = presentationID
            self.initialAssistantDraft = assistantDraft
            self.date = min(logContext.date, today)
            self.mealSlot = logContext.mealSlot
        }

        public var isBusy: Bool {
            isSavingFood
                || submissionState == .submitting
                || savedFoodLogState == .logging
        }

        public var isSubmissionCompleted: Bool {
            if case .completed = submissionState { true } else { false }
        }

        public var isFormDisabled: Bool {
            isBusy || isSubmissionCompleted || savedFoodID != nil
        }

        public var hasUnsavedChanges: Bool { isDirty && savedFoodID == nil && !isBusy }

        public var canReview: Bool {
            guard case .loaded = loadPhase else { return false }
            return !isBusy && !isSubmissionCompleted && savedFoodID == nil
        }

        public var requestContext: FeatureRequestContext {
            FeatureRequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                presentationID: presentationID
            )
        }

        public func formValues() -> AdHocLogFormValues {
            AdHocLogFormValues(
                name: name,
                brand: brand,
                date: date,
                mealSlot: mealSlot,
                amount: amount,
                unit: unit,
                notes: notes,
                nutrientEditor: nutrientEditor
            )
        }
    }

    public enum Action: Equatable, Sendable {
        case load
        case loadCompleted(requestID: UUID, context: FeatureRequestContext, result: Result<LoadPayload, LibraryFailure>)
        case nameChanged(String)
        case brandChanged(String)
        case amountChanged(String)
        case unitChanged(String)
        case notesChanged(String)
        case mealSlotChanged(MealSlot?)
        case dateChanged(LocalDiaryDate)
        case modeChanged(AdHocSaveMode)
        case portionWeightChanged(String)
        case nutrientAmountChanged(code: String, amount: String)
        case nutrientAdded(code: String)
        case nutrientRemoved(code: String)
        case reviewRequested
        case reviewBindingCleared
        case reviewCancelled
        case reviewConfirmed(review: AdHocReview, context: FeatureRequestContext)
        case adHocCompleted(
            requestID: UUID,
            context: FeatureRequestContext,
            generation: UInt64,
            intentID: String,
            date: LocalDiaryDate,
            slot: MealSlot?,
            drafts: [LogSubmissionDraft],
            result: LogSubmissionServiceResult
        )
        case foodCreated(
            requestID: UUID,
            context: FeatureRequestContext,
            generation: UInt64,
            intentID: String,
            name: String,
            intent: SavedFoodLogIntent,
            result: Result<String, LibraryFailure>
        )
        case savedLogCompleted(
            requestID: UUID,
            context: FeatureRequestContext,
            generation: UInt64,
            intentID: String,
            intent: SavedFoodLogIntent,
            drafts: [LogSubmissionDraft],
            result: LogSubmissionServiceResult
        )
        case retrySavedFoodLog
        case clearFormError
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        /// Authoritative record for Window's single mutation delivery. The
        /// shared writer does NOT also fan out; Window owns the one refresh.
        case logged(event: LibraryLoggedEvent)
        case sessionExpired(generation: UInt64)
        case dismiss(generation: UInt64)
    }

    public struct Client: Sendable {
        public var definitions: @Sendable (FeatureRequestContext) async throws -> [NutrientDefinition]
        public var units: @Sendable (FeatureRequestContext) async throws -> [ProductUnit]
        public var create: @Sendable (FeatureRequestContext, CustomFoodWriteRequest) async throws -> String
        public var log: LibraryLogClient
        public var timeZoneIdentifier: @Sendable () -> String
        public var makeID: @Sendable () -> String

        public init(
            definitions: @escaping @Sendable (FeatureRequestContext) async throws -> [NutrientDefinition],
            units: @escaping @Sendable (FeatureRequestContext) async throws -> [ProductUnit],
            create: @escaping @Sendable (FeatureRequestContext, CustomFoodWriteRequest) async throws -> String,
            log: LibraryLogClient,
            timeZoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier },
            makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
        ) {
            self.definitions = definitions
            self.units = units
            self.create = create
            self.log = log
            self.timeZoneIdentifier = timeZoneIdentifier
            self.makeID = makeID
        }

        public static func live(
            service: any LibraryServicing,
            log: LibraryLogClient,
            isCurrent: @escaping FeatureContextGuard
        ) -> Self {
            func guardContext(_ context: FeatureRequestContext) async throws {
                guard await isCurrent(context) else { throw FeatureContextError.stale }
            }
            return Self(
                definitions: { context in
                    try await guardContext(context)
                    return try await service.nutrientDefinitions()
                },
                units: { context in
                    try await guardContext(context)
                    return try await service.units()
                },
                create: { context, request in
                    try await guardContext(context)
                    return try await service.createCustomFood(request)
                },
                log: log
            )
        }
    }

    @Dependency(\.adHocLogClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .load:
                let requestID = uuid()
                state.loadRequestID = requestID
                state.loadPhase = .loading
                state.formError = nil
                state.assistantServingGrams = [:]
                state.assistantPortionWeightGrams = nil
                state.assistantQuantityNeedsReview = false
                let context = state.requestContext
                let client = self.client
                return .run { send in
                    do {
                        async let definitionsTask = client.definitions(context)
                        async let unitsTask = client.units(context)
                        let payload = try await (definitionsTask, unitsTask)
                        await send(.loadCompleted(
                            requestID: requestID,
                            context: context,
                            result: .success(LoadPayload(
                                definitions: payload.0, units: payload.1
                            ))
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
                state.loadRequestID = nil
                switch result {
                case let .success(payload):
                    state.definitions = payload.definitions
                    var foodUnits = payload.units.map {
                        FoodUnit(code: $0.code, name: $0.name, kind: $0.kind)
                    }
                    if !foodUnits.contains(where: { $0.code == "g" }) {
                        foodUnits.insert(FoodUnit(code: "g", name: "Gram"), at: 0)
                    }
                    state.units = foodUnits
                    state.nutrientEditor = NutrientEditorState(
                        definitions: payload.definitions
                    )
                    if !state.units.contains(where: { $0.code == state.unit }) {
                        state.unit = "g"
                    }
                    state.isDirty = false
                    state.loadPhase = .loaded
                    if let draft = state.initialAssistantDraft,
                       draft.purpose == .adHocLog,
                       !applyAssistantDraft(draft, state: &state) {
                        state.formError = String(localized: "library.assistant.prefillFailed")
                    }
                case let .failure(failure):
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                    state.loadPhase = .failed(failure.message)
                }
                return .none

            case let .nameChanged(value):
                markDirty(&state)
                state.name = value
            case let .brandChanged(value):
                markDirty(&state)
                state.brand = value
            case let .amountChanged(value):
                guard value != state.amount else { return .none }
                state.isDirty = true
                state.formError = nil
                state.amount = value
                assistantAmountDidChange(&state)
            case let .unitChanged(value):
                guard value != state.unit else { return .none }
                state.isDirty = true
                state.formError = nil
                state.unit = value
                assistantUnitDidChange(&state)
            case let .notesChanged(value):
                markDirty(&state)
                state.notes = value
            case let .mealSlotChanged(slot):
                markDirty(&state)
                state.mealSlot = slot
            case let .dateChanged(date):
                guard date != state.date else { return .none }
                markDirty(&state)
                state.date = min(date, state.today)
            case let .modeChanged(mode):
                markDirty(&state)
                state.mode = mode
            case let .portionWeightChanged(value):
                guard value != state.portionWeightText else { return .none }
                state.isDirty = true
                state.formError = nil
                state.portionWeightText = value
                assistantPortionWeightDidChange(&state)
            case let .nutrientAmountChanged(code, amount):
                guard state.canReview else { return .none }
                state.nutrientEditor.setAmount(amount, for: code)
                markDirty(&state)
            case let .nutrientAdded(code):
                guard state.canReview else { return .none }
                state.nutrientEditor.addOptional(code: code)
                markDirty(&state)
            case let .nutrientRemoved(code):
                guard state.canReview else { return .none }
                state.nutrientEditor.remove(code: code)
                markDirty(&state)

            case .reviewRequested:
                return requestReview(&state)

            case .reviewBindingCleared:
                // SwiftUI may clear the alert binding before the confirm
                // button action runs. Keep the issued review authoritative for
                // a captured confirmation, but hide the alert.
                state.pendingReview = nil
                return .none

            case .reviewCancelled:
                // Explicit cancellation revokes confirmation authority while
                // preserving the edited form and conversation.
                state.pendingReview = nil
                state.latestIssuedReviewID = nil
                state.latestIssuedReview = nil
                state.latestIssuedReviewContext = nil
                return .none

            case let .reviewConfirmed(review, context):
                guard !state.isBusy,
                      !state.isSubmissionCompleted,
                      state.savedFoodID == nil,
                      review.id == state.latestIssuedReviewID,
                      state.latestIssuedReview.map({ $0 == review }) == true,
                      state.latestIssuedReviewContext.map({ $0 == context }) == true,
                      context == state.requestContext,
                      state.confirmedReviewID != review.id,
                      (state.pendingReview.map({ $0 == review }) ?? true) else { return .none }

                let customFood: CustomFoodWriteRequest?
                let logIntent: SavedFoodLogIntent?
                switch review.mode {
                case .logOnly:
                    customFood = nil
                    logIntent = nil
                case .saveAndLog:
                    guard let food = review.customFood,
                          let intent = review.logIntent else {
                        state.formError = String(localized: "library.adHoc.error.saveSetup")
                        return .none
                    }
                    customFood = food
                    logIntent = intent
                }

                state.pendingReview = nil
                state.formError = nil
                state.confirmedReviewID = review.id
                let requestID = uuid()
                state.activeWriteRequestID = requestID
                state.activeWriteGeneration = state.sessionGeneration
                state.activeWriteAccountID = state.accountID
                switch review.mode {
                case .logOnly:
                    state.submissionState = .submitting
                    return submitAdHoc(
                        requestID: requestID,
                        intentID: review.id,
                        draft: review.draft,
                        name: review.name,
                        context: context
                    )
                case .saveAndLog:
                    guard let customFood, let logIntent else { return .none }
                    state.isSavingFood = true
                    let client = self.client
                    let name = review.name
                    let generation = context.generation
                    return .run { send in
                        do {
                            let foodID = try await client.create(context, customFood)
                            await send(.foodCreated(
                                requestID: requestID,
                                context: context,
                                generation: generation,
                                intentID: review.id,
                                name: name,
                                intent: logIntent,
                                result: .success(foodID)
                            ))
                        } catch {
                            await send(.foodCreated(
                                requestID: requestID,
                                context: context,
                                generation: generation,
                                intentID: review.id,
                                name: name,
                                intent: logIntent,
                                result: .failure(LibraryFailure.map(error))
                            ))
                        }
                    }
                }

            case let .adHocCompleted(requestID, context, generation, intentID, date, slot, drafts, result):
                guard Self.isCurrentWrite(requestID, context: context, generation: generation, state: state) else {
                    return .none
                }
                state.activeWriteRequestID = nil
                state.submissionState = handle(result)
                if case let .success(logs) = result {
                    state.isDirty = false
                    state.submissionState = .completed(logID: logs.first?.id)
                    return .send(.delegate(.logged(event: Self.event(
                        intentID: intentID,
                        drafts: drafts,
                        logs: logs,
                        date: date,
                        slot: slot,
                        state: state
                    ))))
                }
                return .none

            case let .foodCreated(requestID, context, generation, intentID, name, intent, result):
                guard Self.isCurrentWrite(requestID, context: context, generation: generation, state: state) else {
                    return .none
                }
                state.activeWriteRequestID = nil
                state.isSavingFood = false
                switch result {
                case let .success(foodID):
                    state.savedFoodID = foodID
                    state.savedFoodName = name
                    state.savedLogIntent = intent
                    state.savedFoodIntentID = intentID
                    state.isDirty = false
                    state.savedFoodLogState = .logging
                    let logRequestID = uuid()
                    state.activeWriteRequestID = logRequestID
                    state.activeWriteGeneration = state.sessionGeneration
                    state.activeWriteAccountID = state.accountID
                    return submitSavedFoodLog(
                        requestID: logRequestID,
                        intentID: intentID,
                        foodID: foodID,
                        intent: intent,
                        state: &state
                    )
                case let .failure(failure):
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                    if case .uncertain = failure {
                        state.formError = String(
                            localized: "library.editor.create.uncertain",
                            defaultValue: "CalCo couldn't confirm whether this food was saved. Check the library before trying again."
                        )
                    } else {
                        state.formError = failure.message
                    }
                }
                return .none

            case let .savedLogCompleted(requestID, context, generation, intentID, intent, drafts, result):
                guard Self.isCurrentWrite(requestID, context: context, generation: generation, state: state) else {
                    return .none
                }
                state.activeWriteRequestID = nil
                switch result {
                case let .success(logs):
                    let logID = logs.first?.id
                    state.savedFoodLogState = .logged(logID: logID)
                    state.submissionState = .completed(logID: logID)
                    state.isDirty = false
                    return .send(.delegate(.logged(event: Self.event(
                        intentID: intentID,
                        drafts: drafts,
                        logs: logs,
                        date: intent.date,
                        slot: intent.mealSlot,
                        state: state
                    ))))
                case let .failure(failure):
                    state.savedFoodLogState = .failed(message: Self.logFailureMessage(failure))
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                }
                return .none

            case .retrySavedFoodLog:
                guard let foodID = state.savedFoodID,
                      let intent = state.savedLogIntent,
                      let intentID = state.savedFoodIntentID else { return .none }
                guard case .failed = state.savedFoodLogState else { return .none }
                state.savedFoodLogState = .logging
                let requestID = uuid()
                state.activeWriteRequestID = requestID
                state.activeWriteGeneration = state.sessionGeneration
                state.activeWriteAccountID = state.accountID
                return submitSavedFoodLog(
                    requestID: requestID,
                    intentID: intentID,
                    foodID: foodID,
                    intent: intent,
                    state: &state
                )

            case .clearFormError:
                state.formError = nil
                state.assistantQuantityNeedsReview = false
            case .delegate:
                return .none
            }
            return .none
        }
    }

    // MARK: - Effects

    private func requestReview(_ state: inout State) -> Effect<Action> {
        guard state.canReview else { return .none }
        state.hasAttemptedReview = true
        state.formError = nil
        if state.assistantQuantityNeedsReview {
            state.formError = String(localized: "library.adHoc.error.unitConversion")
            return .none
        }
        let values = state.formValues()
        let draft: LogSubmissionDraft
        switch values.validate(timeZone: client.timeZoneIdentifier()) {
        case let .failure(error):
            state.formError = error.message(definitions: state.definitions)
            return .none
        case let .success(validated):
            draft = validated
        }

        var customFood: CustomFoodWriteRequest?
        var logIntent: SavedFoodLogIntent?
        if state.mode == .saveAndLog {
            switch values.makeCustomFoodWriteRequest(
                portionWeightText: state.portionWeightText
            ) {
            case let .failure(error):
                state.formError = error.message(definitions: state.definitions)
                return .none
            case let .success(request):
                customFood = request
            }
            switch values.savedFoodLogIntent(timeZone: client.timeZoneIdentifier()) {
            case let .failure(error):
                state.formError = error.message(definitions: state.definitions)
                return .none
            case let .success(intent):
                logIntent = intent
            }
        }

        let review = AdHocReview(
            id: client.makeID(),
            mode: state.mode,
            name: values.name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: draft.amount,
            unit: draft.unit,
            date: draft.date,
            mealSlot: draft.mealSlot,
            draft: draft,
            customFood: customFood,
            logIntent: logIntent
        )
        state.latestIssuedReviewID = review.id
        state.latestIssuedReview = review
        state.latestIssuedReviewContext = state.requestContext
        state.pendingReview = review
        return .none
    }

    private func submitAdHoc(
        requestID: UUID,
        intentID: String,
        draft: LogSubmissionDraft,
        name: String,
        context: FeatureRequestContext
    ) -> Effect<Action> {
        let log = client.log
        let generation = context.generation
        let accountID = context.accountID
        let date = draft.date
        let slot = draft.mealSlot
        let drafts = [draft]
        return .run { send in
            let result = await log.submitAsync(
                drafts: drafts, names: [name], summary: name,
                accountID: accountID, generation: generation
            )
            await send(.adHocCompleted(
                requestID: requestID,
                context: context,
                generation: generation,
                intentID: intentID,
                date: date,
                slot: slot,
                drafts: drafts,
                result: result
            ))
        }
    }

    private func submitSavedFoodLog(
        requestID: UUID,
        intentID: String,
        foodID: String,
        intent: SavedFoodLogIntent,
        state: inout State
    ) -> Effect<Action> {
        let log = client.log
        let generation = state.sessionGeneration
        let accountID = state.accountID
        let context = state.requestContext
        let draft = intent.logSubmissionDraft(productID: foodID)
        let drafts = [draft]
        let name = state.savedFoodName ?? foodID
        return .run { send in
            let result = await log.submitAsync(
                drafts: drafts, names: [name], summary: name,
                accountID: accountID, generation: generation
            )
            await send(.savedLogCompleted(
                requestID: requestID,
                context: context,
                generation: generation,
                intentID: intentID,
                intent: intent,
                drafts: drafts,
                result: result
            ))
        }
    }

    private static func isCurrentWrite(
        _ requestID: UUID,
        context: FeatureRequestContext,
        generation: UInt64,
        state: State
    ) -> Bool {
        state.activeWriteRequestID == requestID
            && context == state.requestContext
            && state.activeWriteGeneration == generation
            && state.activeWriteAccountID == state.accountID
            && generation == state.sessionGeneration
    }

    private static func event(
        intentID: String,
        drafts: [LogSubmissionDraft],
        logs: [FoodLog],
        date: LocalDiaryDate,
        slot: MealSlot?,
        state: State
    ) -> LibraryLoggedEvent {
        LibraryLoggedEvent(
            intentID: intentID,
            drafts: drafts,
            logs: logs,
            accountID: state.accountID,
            generation: state.sessionGeneration,
            date: date,
            slot: slot,
            presentationID: state.presentationID
        )
    }

    private func handle(
        _ result: LogSubmissionServiceResult
    ) -> LibrarySubmissionState {
        switch result {
        case let .success(logs):
            return .completed(logID: logs.first?.id)
        case let .failure(failure):
            if case .unauthorized = failure {
                return .failed(message: String(localized: "foodDetail.error.sessionExpired"))
            }
            return .failed(message: Self.logFailureMessage(failure))
        }
    }

    private static func logFailureMessage(_ failure: LogSubmissionServiceFailure) -> String {
        switch failure {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .uncertain:
            return String(
                localized: "library.log.uncertain",
                defaultValue: "CalCo couldn't confirm this log. Check the library and diary before retrying."
            )
        case let .failed(message):
            return message
        }
    }

    // MARK: - Assistant draft and serving conversion

    @discardableResult
    private func applyAssistantDraft(
        _ draft: AssistantReviewedDraft,
        state: inout State
    ) -> Bool {
        guard draft.purpose == .adHocLog,
              case .loaded = state.loadPhase,
              !state.isBusy,
              state.savedFoodID == nil else { return false }
        let unitsByCode = Dictionary(
            state.nutrientEditor.definitions.map { ($0.code, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let quantity = draft.suggestedLogQuantity,
              let nutrients = draft.scaledNutrientsForSuggestedLog(
                  unitsByCode: unitsByCode
              ) else { return false }
        var mergedUnits = state.units
        var servingGrams: [String: Decimal] = [:]
        for serving in draft.servings {
            if let grams = CatalogDecimal.parseNonNegative(serving.gramsPerUnit), grams > 0 {
                servingGrams[serving.unit] = grams
            }
            if !mergedUnits.contains(where: { $0.code == serving.unit }) {
                mergedUnits.append(
                    FoodUnit(
                        code: serving.unit,
                        name: serving.unit.capitalized,
                        kind: "serving"
                    )
                )
            }
        }
        state.units = mergedUnits
        state.assistantServingGrams = servingGrams
        state.assistantPortionWeightGrams = draft.suggestedLog.flatMap {
            CatalogDecimal.parseNonNegative($0.totalWeightGrams)
        }
        state.name = draft.name
        state.brand = draft.brand ?? ""
        state.amount = quantity.amount
        state.unit = quantity.unit
        state.portionWeightText = draft.suggestedLog?.totalWeightGrams ?? ""
        state.nutrientEditor = NutrientEditorState(
            definitions: state.nutrientEditor.definitions,
            initial: nutrients
        )
        state.assistantQuantityNeedsReview = false
        state.isDirty = true
        return true
    }

    private func gramsPerUnit(_ unit: String, state: State) -> Decimal? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "g" { return 1 }
        return state.assistantServingGrams[trimmed]
    }

    private func assistantAmountDidChange(_ state: inout State) {
        guard let oldWeight = state.assistantPortionWeightGrams,
              oldWeight > 0,
              let amountValue = CatalogDecimal.parseNonNegative(
                  state.amount.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              amountValue > 0,
              let factor = gramsPerUnit(state.unit, state: state) else { return }
        let newWeight = CatalogDecimal.round(amountValue * factor)
        guard newWeight > 0 else { return }
        rescaleNutrients(from: oldWeight, to: newWeight, state: &state)
        state.assistantPortionWeightGrams = newWeight
        state.portionWeightText = CatalogDecimal.canonical(newWeight)
        state.assistantQuantityNeedsReview = false
    }

    private func assistantUnitDidChange(_ state: inout State) {
        guard let weight = state.assistantPortionWeightGrams, weight > 0 else { return }
        guard let factor = gramsPerUnit(state.unit, state: state), factor > 0 else {
            state.assistantQuantityNeedsReview = true
            state.formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        let newAmount = CatalogDecimal.round(weight / factor)
        guard newAmount > 0 else {
            state.assistantQuantityNeedsReview = true
            state.formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        state.amount = CatalogDecimal.canonical(newAmount)
        state.portionWeightText = CatalogDecimal.canonical(weight)
        state.assistantQuantityNeedsReview = false
    }

    private func assistantPortionWeightDidChange(_ state: inout State) {
        guard let oldWeight = state.assistantPortionWeightGrams,
              oldWeight > 0,
              let newWeight = CatalogDecimal.parseNonNegative(
                  state.portionWeightText.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              newWeight > 0 else { return }
        guard let factor = gramsPerUnit(state.unit, state: state), factor > 0 else {
            state.assistantQuantityNeedsReview = true
            state.formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        rescaleNutrients(from: oldWeight, to: newWeight, state: &state)
        state.assistantPortionWeightGrams = newWeight
        let newAmount = CatalogDecimal.round(newWeight / factor)
        guard newAmount > 0 else {
            state.assistantQuantityNeedsReview = true
            state.formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        state.amount = CatalogDecimal.canonical(newAmount)
        state.assistantQuantityNeedsReview = false
    }

    private func rescaleNutrients(from oldWeight: Decimal, to newWeight: Decimal, state: inout State) {
        guard oldWeight > 0, newWeight > 0, oldWeight != newWeight else { return }
        let ratio = newWeight / oldWeight
        for row in state.nutrientEditor.rows {
            guard let value = CatalogDecimal.parseNonNegative(row.amount) else { continue }
            state.nutrientEditor.setAmount(
                CatalogDecimal.canonical(CatalogDecimal.round(value * ratio)),
                for: row.code
            )
        }
    }

    private func markDirty(_ state: inout State) {
        state.isDirty = true
        state.formError = nil
    }
}

extension DependencyValues {
    public var adHocLogClient: AdHocLogFeature.Client {
        get { self[AdHocLogClientKey.self] }
        set { self[AdHocLogClientKey.self] = newValue }
    }
}

private enum AdHocLogClientKey: DependencyKey {
    static let liveValue: AdHocLogFeature.Client = .init(
        definitions: { _ in [] },
        units: { _ in [] },
        create: { _, _ in throw CustomFoodServiceError.failed("unimplemented") },
        log: LibraryLogClient(
            submit: { _, _, _, _, _, completion in
                completion(.failure(.failed(String(localized: "library.submission.unavailable"))))
            },
            isCurrentOwner: { _, _ in false }
        )
    )
    static let testValue = liveValue
}
