// Real TCA custom-food create/edit feature. Validation reuses the existing
// pure form logic; catalogue writes go through the injected existing service.

import ComposableArchitecture
import Foundation

@Reducer
public struct CustomFoodEditorFeature {
    public struct LoadPayload: Equatable, Sendable {
        public let definitions: [NutrientDefinition]
        public let food: CustomFood?
    }

    @ObservableState
    public struct State: Equatable {
        public let mode: CustomFoodEditorMode
        public let accountID: String
        public let sessionGeneration: UInt64
        public let presentationID: UUID
        public let initialAssistantDraft: AssistantReviewedDraft?
        public let initialBarcode: String?

        public var loadPhase: LibraryLoadState = .loading
        public var isSaving = false
        public var submitError: String?
        public var savedFoodID: String?
        public var barcodeNotice: String?
        public var isDirty = false
        public var hasAttemptedSubmit = false
        public var hasAppliedInitialAssistantDraft = false
        public var hasAppliedInitialBarcode = false
        public var loadRequestID: UUID?
        public var saveRequestID: UUID?

        public var name = ""
        public var brand = ""
        public var categoriesText = ""
        public var defaultQuantity = ""
        public var defaultUnit = ""
        public var servings: [ServingEditorRow] = []
        public var nutrientEditor = NutrientEditorState(definitions: [])

        public init(
            mode: CustomFoodEditorMode,
            accountID: String,
            generation: UInt64,
            presentationID: UUID = UUID(),
            assistantDraft: AssistantReviewedDraft? = nil,
            initialBarcode: String? = nil
        ) {
            self.mode = mode
            self.accountID = accountID
            self.sessionGeneration = generation
            self.presentationID = presentationID
            self.initialAssistantDraft = assistantDraft
            self.initialBarcode = initialBarcode
        }

        public var foodID: String? { mode.foodID }
        public var titleKey: String { mode.isCreate ? "library.editor.create.title" : "library.editor.edit.title" }

        public var isFormEditable: Bool {
            if case .loaded = loadPhase { !isSaving && savedFoodID == nil } else { false }
        }

        public var hasUnsavedChanges: Bool { isDirty && savedFoodID == nil && !isSaving }
        public var canSubmit: Bool { isFormEditable && !isSaving }

        public var requestContext: FeatureRequestContext {
            FeatureRequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                presentationID: presentationID
            )
        }

        public func formValues() -> CustomFoodFormValues {
            CustomFoodFormValues(
                name: name,
                brand: brand,
                categoriesText: categoriesText,
                defaultQuantity: defaultQuantity,
                defaultUnit: defaultUnit,
                servings: servings.map {
                    CustomFoodServingInput(unit: $0.unit, gramsPerUnit: $0.gramsPerUnit)
                },
                nutrientEditor: nutrientEditor
            )
        }
    }

    public enum Action: Equatable, Sendable {
        case load
        case loadCompleted(requestID: UUID, context: FeatureRequestContext, result: Result<LoadPayload, LibraryFailure>)
        case submit
        case saveCompleted(requestID: UUID, context: FeatureRequestContext, generation: UInt64, result: Result<String, LibraryFailure>)
        case nameChanged(String)
        case brandChanged(String)
        case categoriesChanged(String)
        case defaultQuantityChanged(String)
        case defaultUnitChanged(String)
        case servingAdded
        case servingRemoved(id: String)
        case servingUpdated(id: String, unit: String?, gramsPerUnit: String?)
        case nutrientAmountChanged(code: String, amount: String)
        case nutrientAdded(code: String)
        case nutrientRemoved(code: String)
        case clearSubmitError
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case saved(id: String, generation: UInt64, presentationID: UUID)
        case sessionExpired(generation: UInt64)
        case dismiss(generation: UInt64)
    }

    public struct Client: Sendable {
        public var definitions: @Sendable (FeatureRequestContext) async throws -> [NutrientDefinition]
        public var customFood: @Sendable (FeatureRequestContext, String) async throws -> CustomFood
        public var create: @Sendable (FeatureRequestContext, CustomFoodWriteRequest) async throws -> String
        public var update: @Sendable (FeatureRequestContext, String, CustomFoodWriteRequest) async throws -> String
        public static func live(
            service: any LibraryServicing,
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
                customFood: { context, id in
                    try await guardContext(context)
                    return try await service.customFood(id: id)
                },
                create: { context, request in
                    try await guardContext(context)
                    return try await service.createCustomFood(request)
                },
                update: { context, id, request in
                    try await guardContext(context)
                    return try await service.updateCustomFood(id: id, request: request)
                }
            )
        }
    }

    @Dependency(\.customFoodEditorClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .load:
                let requestID = uuid()
                state.loadRequestID = requestID
                state.loadPhase = .loading
                state.submitError = nil
                let context = state.requestContext
                let client = self.client
                let foodID = state.foodID
                return .run { send in
                    do {
                        async let definitions = client.definitions(context)
                        let food: CustomFood?
                        if let foodID {
                            food = try await client.customFood(context, foodID)
                        } else {
                            food = nil
                        }
                        let payload = try await (definitions, food)
                        await send(.loadCompleted(
                            requestID: requestID,
                            context: context,
                            result: .success(LoadPayload(
                                definitions: payload.0, food: payload.1
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
                    if let food = payload.food {
                        state.name = food.name
                        state.brand = food.brand ?? ""
                        state.categoriesText = food.categories.joined(separator: ", ")
                        state.defaultQuantity = food.defaultQuantity ?? ""
                        state.defaultUnit = food.defaultUnit ?? ""
                        state.servings = food.servings.map {
                            ServingEditorRow(
                                id: uuid().uuidString.lowercased(),
                                unit: $0.unit,
                                gramsPerUnit: $0.gramsPerUnit
                            )
                        }
                        state.nutrientEditor = NutrientEditorState(
                            definitions: payload.definitions,
                            initial: food.nutrientsPer100g
                        )
                    } else {
                        state.nutrientEditor = NutrientEditorState(
                            definitions: payload.definitions
                        )
                    }
                    state.isDirty = false
                    state.hasAttemptedSubmit = false
                    state.loadPhase = .loaded

                    if let draft = state.initialAssistantDraft,
                       draft.purpose == .customFood,
                       !state.hasAppliedInitialAssistantDraft {
                        state.hasAppliedInitialAssistantDraft = true
                        if !applyAssistantDraft(draft, state: &state) {
                            state.submitError = String(localized: "library.assistant.prefillFailed")
                        }
                    } else if state.mode.isCreate,
                              let barcode = state.initialBarcode,
                              !state.hasAppliedInitialBarcode {
                        state.hasAppliedInitialBarcode = true
                        state.barcodeNotice = String(
                            format: String(localized: "library.assistant.barcodeNotPersisted"),
                            barcode
                        )
                    }

                case let .failure(failure):
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                    state.loadPhase = .failed(failure.message)
                }
                return .none

            case .submit:
                guard state.canSubmit, case .loaded = state.loadPhase else { return .none }
                state.hasAttemptedSubmit = true
                state.submitError = nil
                let values = state.formValues()
                let request: CustomFoodWriteRequest
                switch values.validate() {
                case let .failure(error):
                    state.submitError = values.errorMessage(
                        error, definitions: state.nutrientEditor.definitions
                    )
                    return .none
                case let .success(validated):
                    request = validated
                }

                state.isSaving = true
                let requestID = uuid()
                state.saveRequestID = requestID
                let context = state.requestContext
                let client = self.client
                let foodID = state.foodID
                let generation = state.sessionGeneration
                return .run { send in
                    do {
                        let id: String
                        if let foodID {
                            id = try await client.update(context, foodID, request)
                        } else {
                            id = try await client.create(context, request)
                        }
                        await send(.saveCompleted(
                            requestID: requestID, context: context,
                            generation: generation, result: .success(id)
                        ))
                    } catch {
                        await send(.saveCompleted(
                            requestID: requestID,
                            context: context,
                            generation: generation,
                            result: .failure(LibraryFailure.map(error))
                        ))
                    }
                }

            case let .saveCompleted(requestID, context, generation, result):
                guard requestID == state.saveRequestID,
                      context == state.requestContext,
                      generation == state.sessionGeneration else { return .none }
                state.saveRequestID = nil
                state.isSaving = false
                var savedDelegate: Action?
                switch result {
                case let .success(id):
                    state.savedFoodID = id
                    state.isDirty = false
                    // Only an accepted, owner-current completion may finish a
                    // presentation. A stale reply emits nothing.
                    savedDelegate = .delegate(.saved(
                        id: id, generation: generation,
                        presentationID: state.presentationID
                    ))
                case let .failure(failure):
                    if case .unauthorized = failure {
                        return .send(.delegate(.sessionExpired(generation: state.sessionGeneration)))
                    }
                    if case let .uncertain(message) = failure, state.mode.isCreate {
                        state.submitError = String(
                            localized: "library.editor.create.uncertain",
                            defaultValue: "CalCo couldn't confirm whether this food was saved. Check the library before trying again."
                        )
                    } else {
                        state.submitError = failure.message
                    }
                }
                return savedDelegate.map { .send($0) } ?? .none

            case let .nameChanged(value):
                markDirty(&state)
                state.name = value
            case let .brandChanged(value):
                markDirty(&state)
                state.brand = value
            case let .categoriesChanged(value):
                markDirty(&state)
                state.categoriesText = value
            case let .defaultQuantityChanged(value):
                markDirty(&state)
                state.defaultQuantity = value
            case let .defaultUnitChanged(value):
                markDirty(&state)
                state.defaultUnit = value
            case .servingAdded:
                guard state.isFormEditable else { return .none }
                state.servings.append(ServingEditorRow(id: uuid().uuidString.lowercased()))
            case let .servingRemoved(id):
                guard state.isFormEditable else { return .none }
                state.servings.removeAll { $0.id == id }
            case let .servingUpdated(id, unit, gramsPerUnit):
                guard state.isFormEditable,
                      let index = state.servings.firstIndex(where: { $0.id == id })
                else { return .none }
                if let unit { state.servings[index].unit = unit }
                if let gramsPerUnit { state.servings[index].gramsPerUnit = gramsPerUnit }
            case let .nutrientAmountChanged(code, amount):
                guard state.isFormEditable else { return .none }
                state.nutrientEditor.setAmount(amount, for: code)
                markDirty(&state)
            case let .nutrientAdded(code):
                guard state.isFormEditable else { return .none }
                state.nutrientEditor.addOptional(code: code)
                markDirty(&state)
            case let .nutrientRemoved(code):
                guard state.isFormEditable else { return .none }
                state.nutrientEditor.remove(code: code)
                markDirty(&state)
            case .clearSubmitError:
                if case .failed = state.loadPhase { state.loadPhase = .loaded }
                state.submitError = nil
            case .delegate:
                return .none
            }
            return .none
        }
    }

    /// Applies a fully typed reviewed assistant draft. Barcodes are review-only:
    /// the server does not persist them for custom foods.
    @discardableResult
    private func applyAssistantDraft(
        _ draft: AssistantReviewedDraft,
        state: inout State
    ) -> Bool {
        guard state.mode.isCreate,
              draft.purpose == .customFood,
              state.isFormEditable else { return false }
        let unitsByCode = Dictionary(
            state.nutrientEditor.definitions.map { ($0.code, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let nutrients = draft.per100gNutrients(unitsByCode: unitsByCode) else {
            return false
        }
        state.name = draft.name
        state.brand = draft.brand ?? ""
        state.categoriesText = draft.categories.joined(separator: ", ")
        state.defaultQuantity = draft.defaultQuantity ?? ""
        state.defaultUnit = draft.defaultUnit ?? ""
        state.servings = draft.servings.map {
            ServingEditorRow(
                id: uuid().uuidString.lowercased(),
                unit: $0.unit,
                gramsPerUnit: $0.gramsPerUnit
            )
        }
        state.nutrientEditor = NutrientEditorState(
            definitions: state.nutrientEditor.definitions,
            initial: nutrients
        )
        state.barcodeNotice = draft.barcode.map {
            String(format: String(localized: "library.assistant.barcodeNotPersisted"), $0)
        }
        state.isDirty = true
        return true
    }

    private func markDirty(_ state: inout State) {
        guard !state.isSaving else { return }
        state.isDirty = true
        state.submitError = nil
    }
}

extension DependencyValues {
    public var customFoodEditorClient: CustomFoodEditorFeature.Client {
        get { self[CustomFoodEditorClientKey.self] }
        set { self[CustomFoodEditorClientKey.self] = newValue }
    }
}

private enum CustomFoodEditorClientKey: DependencyKey {
    static let liveValue: CustomFoodEditorFeature.Client = .init(
        definitions: { _ in [] },
        customFood: { _, _ in throw CustomFoodServiceError.notFound("unimplemented") },
        create: { _, _ in throw CustomFoodServiceError.failed("unimplemented") },
        update: { _, _, _ in throw CustomFoodServiceError.failed("unimplemented") }
    )
    static let testValue = liveValue
}
