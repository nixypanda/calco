// Meal create/edit reducer: debounced product search, name resolution,
// quantity/unit validation, dirty tracking and one-shot save. Every RPC carries
// captured account/generation/owner/requestID and is guarded before transport.

import ComposableArchitecture
import Dependencies
import Foundation

@Reducer
public struct MealEditorFeature {
    @ObservableState
    public struct State: Equatable {
        public let context: MealsCaptureContext
        public let mode: MealEditorMode

        public var loadState: MealEditorLoadState = .loading
        public var saveState: MealEditorSaveState = .idle
        public var components: [MealComponentRow] = []
        public var units: [ProductUnit] = []
        public var unitFallbackNotice: String?
        public var validationMessage: String?

        public var name: String = ""
        public var notes: String = ""
        public var totalAmount: String = ""
        public var totalUnit: String = "g"

        var nextRowID = 1
        var didStartLoad = false
        var baseline: MealFormSnapshot = .empty
        var searchTokens: [Int: Int] = [:]
        var resolutionTokens: [Int: Int] = [:]
        var activeLoadRequestID: UUID?
        var loadToken: Int = 0
        var pendingSaveRequestID: UUID?

        public init(context: MealsCaptureContext, mode: MealEditorMode) {
            self.context = context
            self.mode = mode
        }

        public var isSaving: Bool {
            if case .saving = saveState { true } else { false }
        }

        public var isReady: Bool {
            if case .ready = loadState { true } else { false }
        }

        public var didSave: Bool {
            if case .saved = saveState { true } else { false }
        }

        public var isSaveBlocked: Bool { didSave }

        public var hasUnsavedChanges: Bool { isReady && currentSnapshot != baseline }

        public var editorTitle: String {
            switch mode {
            case .create: return String(localized: "meals.editor.createTitle")
            case .edit: return String(localized: "meals.editor.editTitle")
            }
        }

        public var saveErrorMessage: String? {
            if case .failed(let message) = saveState { message } else { nil }
        }

        public var displayErrorMessage: String? { validationMessage ?? saveErrorMessage }

        public var totalQuantityHelperText: String? {
            guard !totalAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            guard MealQuantityRules.normalizedPositiveDecimal(totalAmount) != nil else {
                return String(localized: "meals.editor.error.totalInvalid")
            }
            if !MealQuantityRules.isMassUnit(totalUnit) {
                return String(localized: "meals.editor.totalNonMass")
            }
            return nil
        }

        public var validationErrors: [MealEditorValidationError] {
            var errors: [MealEditorValidationError] = []
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.nameRequired)
            }
            let selected = components.filter(\.hasSelection)
            let unresolved = components.filter { !$0.hasSelection && !$0.trimmedQuery.isEmpty }
            if selected.isEmpty && unresolved.isEmpty { errors.append(.componentsRequired) }
            if !unresolved.isEmpty { errors.append(.componentUnselected) }
            if components.contains(where: \.isMissing) { errors.append(.componentMissing) }
            if selected.contains(where: {
                MealQuantityRules.normalizedPositiveDecimal($0.amount) == nil
            }) { errors.append(.quantityInvalid) }
            if selected.contains(where: {
                $0.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) { errors.append(.unitRequired) }
            let trimmedTotal = totalAmount.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTotal.isEmpty,
               MealQuantityRules.normalizedPositiveDecimal(trimmedTotal) == nil {
                errors.append(.totalQuantityInvalid)
            }
            if !trimmedTotal.isEmpty,
               totalUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.unitRequired)
            }
            return errors
        }

        public var defaultUnitCode: String {
            if units.contains(where: { $0.code == "g" }) { return "g" }
            return units.first?.code ?? "g"
        }

        var currentSnapshot: MealFormSnapshot {
            MealFormSnapshot(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                totalAmount: totalAmount.trimmingCharacters(in: .whitespacesAndNewlines),
                totalUnit: totalUnit.trimmingCharacters(in: .whitespacesAndNewlines),
                components: components.compactMap { row in
                    if row.hasSelection {
                        return MealComponentSnapshot(
                            productID: row.productID,
                            query: "",
                            amount: row.amount.trimmingCharacters(in: .whitespacesAndNewlines),
                            unit: row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    guard !row.trimmedQuery.isEmpty else { return nil }
                    return MealComponentSnapshot(
                        productID: "",
                        query: row.trimmedQuery,
                        amount: row.amount.trimmingCharacters(in: .whitespacesAndNewlines),
                        unit: row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            )
        }

        mutating func clearTransientMessages() {
            validationMessage = nil
            if case .failed = saveState { saveState = .idle }
        }

        mutating func incrementSearchToken(rowID: Int) -> Int {
            searchTokens[rowID, default: 0] += 1
            return searchTokens[rowID] ?? 0
        }

        mutating func incrementResolutionToken(rowID: Int) -> Int {
            resolutionTokens[rowID, default: 0] += 1
            return resolutionTokens[rowID] ?? 0
        }

        func index(for rowID: Int) -> Int? { components.firstIndex { $0.id == rowID } }

        func makeRequest() -> MealWriteRequest? {
            var writeComponents: [MealComponentWriteRequest] = []
            for row in components where row.hasSelection {
                guard let amount = MealQuantityRules.normalizedPositiveDecimal(row.amount) else {
                    return nil
                }
                let unit = row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !unit.isEmpty else { return nil }
                writeComponents.append(
                    MealComponentWriteRequest(
                        productID: row.productID,
                        quantity: NutritionQuantity(amount: amount, unit: unit)
                    )
                )
            }
            guard !writeComponents.isEmpty else { return nil }

            let trimmedTotal = totalAmount.trimmingCharacters(in: .whitespacesAndNewlines)
            var total: NutritionQuantity?
            if !trimmedTotal.isEmpty {
                guard let amount = MealQuantityRules.normalizedPositiveDecimal(trimmedTotal) else {
                    return nil
                }
                let unit = totalUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !unit.isEmpty else { return nil }
                total = NutritionQuantity(amount: amount, unit: unit)
            }

            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return MealWriteRequest(
                name: trimmedName,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                totalQuantity: total,
                components: writeComponents
            )
        }
    }

    public enum Action: Sendable {
        case onAppear
        case loadIfNeeded
        case load
        case reload
        case unitsReceived(context: MealsRequestContext, token: Int, units: [ProductUnit], fallback: Bool)
        case mealReceived(context: MealsRequestContext, token: Int, meal: Meal?, units: [ProductUnit], fallback: Bool)
        case loadFailed(context: MealsRequestContext, token: Int, message: String)
        case loadUnauthorized(context: MealsRequestContext, token: Int)
        case loadCancelled(context: MealsRequestContext, token: Int)
        case nameChanged(String)
        case notesChanged(String)
        case totalAmountChanged(String)
        case totalUnitChanged(String)
        case addComponent
        case removeComponent(rowID: Int)
        case queryChanged(rowID: Int, query: String)
        case searchTimerFired(context: MealsRequestContext, rowID: Int, token: Int, query: String)
        case searchReceived(context: MealsRequestContext, rowID: Int, token: Int, query: String, products: [MealProduct])
        case searchFailed(context: MealsRequestContext, rowID: Int, token: Int, message: String, unauthorized: Bool)
        case selectProduct(rowID: Int, product: MealProduct)
        case clearProduct(rowID: Int)
        case componentAmountChanged(rowID: Int, amount: String)
        case componentUnitChanged(rowID: Int, unit: String)
        case nameResolved(context: MealsRequestContext, rowID: Int, productID: String, token: Int, name: String?)
        case resolveFailed(context: MealsRequestContext, rowID: Int, productID: String, token: Int, isMissing: Bool, unauthorized: Bool)
        case save
        case saved(Meal, context: MealsRequestContext)
        case saveFailed(message: String)
        case saveUnauthorized
        case saveUncertain
        case saveCancelled
        case dismissValidationMessage
        case cancelTapped
        case dirtyChanged(Bool)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case saved(Meal, generation: UInt64, presentationID: UUID)
        case cancelled(generation: UInt64, presentationID: UUID)
        case dirtyChanged(Bool)
        case sessionExpired(generation: UInt64, presentationID: UUID)
    }

    @Dependency(\.mealsClient) private var client
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce<State, Action> { (state: inout State, action: Action) -> Effect<Action> in
            switch action {
            case .onAppear, .loadIfNeeded:
                guard !state.didStartLoad else { return .none }
                return .send(.load)

            case .load:
                guard !state.didStartLoad else { return .none }
                state.didStartLoad = true
                state.loadToken += 1
                let token = state.loadToken
                state.loadState = .loading
                state.saveState = .idle
                state.validationMessage = nil
                state.unitFallbackNotice = nil
                state.searchTokens = [:]
                state.resolutionTokens = [:]
                let request = state.context.requestContext(requestID: uuid())
                state.activeLoadRequestID = request.requestID
                let mode = state.mode
                return .run { send in
                    var units: [ProductUnit] = []
                    do {
                        units = try await client.fetchUnits(request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.unitsReceived(context: request, token: token, units: units, fallback: false))
                    } catch {
                        if isUnauthorizedMealError(error) {
                            await Self.sendUnauthorized(request, token: token, send: send, client: client)
                        } else if let mealError = error as? MealServiceError,
                                  case .cancelled = mealError {
                            await Self.sendCancelled(request, token: token, send: send, client: client)
                        } else {
                            guard await Self.isCurrent(request, client: client) else { return }
                            await send(.unitsReceived(context: request, token: token, units: [], fallback: true))
                            units = []
                        }
                    }
                    switch mode {
                    case .create:
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.mealReceived(
                            context: request, token: token, meal: nil,
                            units: units, fallback: units.isEmpty
                        ))
                    case .edit(let id):
                        do {
                            let meal = try await client.getMeal(id, request)
                            guard await Self.isCurrent(request, client: client) else { return }
                            await send(.mealReceived(
                                context: request, token: token, meal: meal,
                                units: units, fallback: units.isEmpty
                            ))
                        } catch {
                            await Self.handleLoadError(
                                error, request: request, token: token, send: send, client: client
                            )
                        }
                    }
                }

            case .reload:
                state.didStartLoad = false
                return .send(.load)

            case let .unitsReceived(request, token, units, fallback):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken else { return .none }
                state.units = fallback ? [] : units
                state.unitFallbackNotice = fallback
                    ? String(localized: "meals.editor.unitFallback") : nil
                return .none

            case let .mealReceived(request, token, meal, units, fallback):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                var editable = MealQuantityRules.editorUnits(from: fallback ? [] : units)
                var effects: [Effect<Action>] = []
                switch state.mode {
                case .create:
                    state.units = editable
                    state.nextRowID = 1
                    state.components = [MealComponentRow(id: state.nextRowID, unit: state.defaultUnitCode)]
                    state.nextRowID += 1
                    state.name = ""
                    state.notes = ""
                    state.totalAmount = ""
                    state.totalUnit = state.defaultUnitCode
                case .edit:
                    guard let meal else { return .none }
                    editable = MealQuantityRules.merging(meal.totalQuantity?.unit, into: editable)
                    for component in meal.components {
                        editable = MealQuantityRules.merging(component.quantity.unit, into: editable)
                    }
                    state.units = editable
                    let rowIDs = Self.apply(meal, to: &state)
                    effects.append(contentsOf: Self.nameResolutions(
                        state: &state, client: client, meal: meal,
                        rowIDs: rowIDs, token: token, uuid: uuid
                    ))
                }
                state.baseline = state.currentSnapshot
                state.loadState = .ready
                return .merge(effects)

            case let .loadFailed(request, token, message):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                state.loadState = .failed(message)
                return .none

            case let .loadUnauthorized(request, token):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                state.loadState = .failed(String(localized: "meals.error.sessionExpired"))
                return .send(.delegate(.sessionExpired(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .loadCancelled(request, token):
                guard Self.isAuthorized(state, request: request),
                      token == state.loadToken,
                      state.activeLoadRequestID == request.requestID else { return .none }
                state.activeLoadRequestID = nil
                state.didStartLoad = false
                return .none

            case let .nameChanged(value):
                guard value != state.name else { return .none }
                state.name = value
                state.clearTransientMessages()
                return .none

            case let .notesChanged(value):
                guard value != state.notes else { return .none }
                state.notes = value
                state.clearTransientMessages()
                return .none

            case let .totalAmountChanged(value):
                guard value != state.totalAmount else { return .none }
                state.totalAmount = value
                state.clearTransientMessages()
                return .none

            case let .totalUnitChanged(value):
                guard value != state.totalUnit else { return .none }
                state.totalUnit = value
                state.clearTransientMessages()
                return .none

            case .addComponent:
                guard state.isReady, !state.isSaving else { return .none }
                state.components.append(
                    MealComponentRow(id: state.nextRowID, unit: state.defaultUnitCode)
                )
                state.nextRowID += 1
                state.clearTransientMessages()
                return .none

            case let .removeComponent(rowID):
                guard state.isReady, !state.isSaving else { return .none }
                _ = state.incrementSearchToken(rowID: rowID)
                _ = state.incrementResolutionToken(rowID: rowID)
                if state.components.count <= 1 {
                    let unit = state.components.first?.unit ?? state.defaultUnitCode
                    let id = state.components.first?.id ?? state.nextRowID
                    state.components = [MealComponentRow(id: id, unit: unit)]
                    if id == state.nextRowID { state.nextRowID += 1 }
                } else {
                    state.components.removeAll { $0.id == rowID }
                }
                state.clearTransientMessages()
                return .none

            case let .queryChanged(rowID, query):
                guard let index = state.index(for: rowID), !state.isSaving else { return .none }
                state.clearTransientMessages()
                let selectedName = state.components[index].productName
                state.components[index].query = query
                if state.components[index].productID.isEmpty || selectedName != query {
                    state.components[index].productID = ""
                    state.components[index].productName = nil
                    state.components[index].isMissing = false
                    _ = state.incrementResolutionToken(rowID: rowID)
                }
                let token = state.incrementSearchToken(rowID: rowID)
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else {
                    state.components[index].searchState = .idle
                    return .none
                }
                state.components[index].searchState = .loading
                let delay = client.debounceNanoseconds
                let request = state.context.requestContext(requestID: uuid())
                return .run { send in
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    guard await Self.isCurrent(request, client: client) else { return }
                    await send(.searchTimerFired(
                        context: request, rowID: rowID, token: token, query: trimmed
                    ))
                }

            case let .searchTimerFired(request, rowID, token, query):
                guard Self.isAuthorized(state, request: request),
                      token == state.searchTokens[rowID],
                      let index = state.index(for: rowID),
                      state.components[index].trimmedQuery == query else { return .none }
                return .run { send in
                    do {
                        let products = try await client.searchProducts(query, request)
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.searchReceived(
                            context: request, rowID: rowID, token: token,
                            query: query, products: products
                        ))
                    } catch {
                        await Self.handleSearchError(
                            error, request: request, rowID: rowID,
                            token: token, send: send, client: client
                        )
                    }
                }

            case let .searchReceived(request, rowID, token, query, products):
                guard Self.isAuthorized(state, request: request),
                      token == state.searchTokens[rowID],
                      let index = state.index(for: rowID),
                      state.components[index].trimmedQuery == query else { return .none }
                state.components[index].searchState = products.isEmpty ? .empty : .results(products)
                return .none

            case let .searchFailed(request, rowID, token, message, unauthorized):
                guard Self.isAuthorized(state, request: request),
                      token == state.searchTokens[rowID] else { return .none }
                if unauthorized {
                    return .send(.delegate(.sessionExpired(
                        generation: state.context.generation,
                        presentationID: state.context.id
                    )))
                }
                guard let index = state.index(for: rowID) else { return .none }
                state.components[index].searchState = .failed(
                    message.isEmpty ? String(localized: "meals.editor.searchFailed") : message
                )
                return .none

            case let .selectProduct(rowID, product):
                guard let index = state.index(for: rowID), !state.isSaving else { return .none }
                _ = state.incrementResolutionToken(rowID: rowID)
                _ = state.incrementSearchToken(rowID: rowID)
                state.components[index].productID = product.id
                state.components[index].productName = product.name
                state.components[index].query = product.name
                state.components[index].searchState = .idle
                state.components[index].isMissing = false
                state.components[index].isResolvingName = false
                state.clearTransientMessages()
                return .none

            case let .clearProduct(rowID):
                guard let index = state.index(for: rowID), !state.isSaving else { return .none }
                _ = state.incrementResolutionToken(rowID: rowID)
                _ = state.incrementSearchToken(rowID: rowID)
                state.components[index].productID = ""
                state.components[index].productName = nil
                state.components[index].query = ""
                state.components[index].searchState = .idle
                state.components[index].isMissing = false
                state.components[index].isResolvingName = false
                state.clearTransientMessages()
                return .none

            case let .componentAmountChanged(rowID, amount):
                guard let index = state.index(for: rowID), !state.isSaving else { return .none }
                state.components[index].amount = amount
                state.clearTransientMessages()
                return .none

            case let .componentUnitChanged(rowID, unit):
                guard let index = state.index(for: rowID), !state.isSaving else { return .none }
                state.components[index].unit = unit
                state.clearTransientMessages()
                return .none

            case let .nameResolved(request, rowID, productID, token, name):
                guard Self.isAuthorized(state, request: request),
                      token == state.resolutionTokens[rowID],
                      let index = state.index(for: rowID),
                      state.components[index].productID == productID else { return .none }
                state.components[index].productName = name
                state.components[index].query = name ?? ""
                state.components[index].isMissing = false
                state.components[index].isResolvingName = false
                return .none

            case let .resolveFailed(request, rowID, productID, token, isMissing, unauthorized):
                guard Self.isAuthorized(state, request: request),
                      token == state.resolutionTokens[rowID],
                      let index = state.index(for: rowID),
                      state.components[index].productID == productID else { return .none }
                if unauthorized {
                    return .send(.delegate(.sessionExpired(
                        generation: state.context.generation,
                        presentationID: state.context.id
                    )))
                }
                state.components[index].isResolvingName = false
                if isMissing {
                    state.components[index].isMissing = true
                    state.components[index].query = ""
                }
                return .none

            case .save:
                guard state.isReady, !state.isSaving, !state.isSaveBlocked else { return .none }
                if let first = state.validationErrors.first {
                    state.validationMessage = first.message
                    state.saveState = .idle
                    return .none
                }
                guard let writeRequest = state.makeRequest() else {
                    state.validationMessage = String(localized: "meals.error.saveFailed")
                    return .none
                }
                state.validationMessage = nil
                state.saveState = .saving
                let request = state.context.requestContext(requestID: uuid())
                state.pendingSaveRequestID = request.requestID
                let mode = state.mode
                return .run { send in
                    do {
                        let saved: Meal
                        switch mode {
                        case .create: saved = try await client.createMeal(writeRequest, request)
                        case .edit(let id): saved = try await client.updateMeal(id, writeRequest, request)
                        }
                        guard await Self.isCurrent(request, client: client) else { return }
                        await send(.saved(saved, context: request))
                    } catch {
                        await Self.handleSaveError(
                            error, request: request, mode: mode, send: send, client: client
                        )
                    }
                }

            case let .saved(meal, request):
                guard Self.isAuthorized(state, request: request),
                      state.pendingSaveRequestID == request.requestID else { return .none }
                state.pendingSaveRequestID = nil
                state.saveState = .saved
                state.baseline = state.currentSnapshot
                return .send(.delegate(.saved(
                    meal,
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .saveFailed(message):
                state.saveState = .failed(message)
                state.pendingSaveRequestID = nil
                return .none

            case .saveUnauthorized:
                state.saveState = .failed(String(localized: "meals.error.sessionExpired"))
                state.pendingSaveRequestID = nil
                return .send(.delegate(.sessionExpired(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case .saveUncertain:
                state.saveState = .failed(String(
                    localized: "meals.editor.createUncertain",
                    defaultValue: "CalCo couldn't confirm whether this meal was saved. Refresh the list before trying again."
                ))
                state.pendingSaveRequestID = nil
                return .none

            case .saveCancelled:
                state.saveState = .idle
                state.pendingSaveRequestID = nil
                return .none

            case .dismissValidationMessage:
                state.validationMessage = nil
                return .none

            case .cancelTapped:
                return .send(.delegate(.cancelled(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .dirtyChanged(dirty):
                return .send(.delegate(.dirtyChanged(dirty)))

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

    private static func sendUnauthorized(
        _ request: MealsRequestContext, token: Int,
        send: Send<Action>, client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        await send(.loadUnauthorized(context: request, token: token))
    }

    private static func sendCancelled(
        _ request: MealsRequestContext, token: Int,
        send: Send<Action>, client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        await send(.loadCancelled(context: request, token: token))
    }

    private static func handleLoadError(
        _ error: Error, request: MealsRequestContext, token: Int,
        send: Send<Action>, client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        if isUnauthorizedMealError(error) {
            await send(.loadUnauthorized(context: request, token: token))
        } else if let mealError = error as? MealServiceError,
                  case .cancelled = mealError {
            await send(.loadCancelled(context: request, token: token))
        } else {
            let message = mealServiceMessage(error)
            await send(.loadFailed(
                context: request, token: token,
                message: message.isEmpty ? String(localized: "meals.error.loadFailed") : message
            ))
        }
    }

    private static func handleSearchError(
        _ error: Error, request: MealsRequestContext, rowID: Int, token: Int,
        send: Send<Action>, client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        await send(.searchFailed(
            context: request,
            rowID: rowID,
            token: token,
            message: mealServiceMessage(error),
            unauthorized: isUnauthorizedMealError(error)
        ))
    }

    private static func handleSaveError(
        _ error: Error, request: MealsRequestContext, mode: MealEditorMode,
        send: Send<Action>, client: MealsFeatureClient
    ) async {
        guard await isCurrent(request, client: client) else { return }
        if isUnauthorizedMealError(error) {
            await send(.saveUnauthorized)
        } else if let mealError = error as? MealServiceError,
                  case .cancelled = mealError {
            await send(.saveCancelled)
        } else if case .create = mode,
                  let mealError = error as? MealServiceError,
                  mealError == .network || Self.isUncertainServerFailure(mealError) {
            await send(.saveUncertain)
        } else {
            let message = mealServiceMessage(error)
            await send(.saveFailed(message: message.isEmpty
                ? String(localized: "meals.error.saveFailed") : message))
        }
    }

    private static func isUncertainServerFailure(_ error: MealServiceError) -> Bool {
        if case .server = error { true } else { false }
    }

    @discardableResult
    private static func apply(_ meal: Meal, to state: inout State) -> [Int] {
        state.name = meal.name
        state.notes = meal.notes ?? ""
        if let total = meal.totalQuantity,
           !total.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.totalAmount = total.amount
            state.totalUnit = total.unit.isEmpty ? state.defaultUnitCode : total.unit
        } else {
            state.totalAmount = ""
            state.totalUnit = state.defaultUnitCode
        }

        state.nextRowID = 1
        var rowIDs: [Int] = []
        state.components = meal.components.map { component in
            let unit = component.quantity.unit.isEmpty ? state.defaultUnitCode : component.quantity.unit
            let productID: String
            var missing = false
            switch component.item.itemType {
            case .product: productID = component.item.id
            case .meal:
                productID = ""
                missing = true
            }
            let row = MealComponentRow(
                id: state.nextRowID,
                productID: productID,
                query: "",
                amount: component.quantity.amount,
                unit: unit,
                isMissing: missing,
                isResolvingName: !productID.isEmpty
            )
            rowIDs.append(state.nextRowID)
            state.nextRowID += 1
            return row
        }
        if state.components.isEmpty {
            state.components = [MealComponentRow(id: state.nextRowID, unit: state.defaultUnitCode)]
            rowIDs = [state.nextRowID]
            state.nextRowID += 1
        }
        return rowIDs
    }

    private static func nameResolutions(
        state: inout State,
        client: MealsFeatureClient,
        meal: Meal,
        rowIDs: [Int],
        token: Int,
        uuid: UUIDGenerator
    ) -> [Effect<Action>] {
        meal.components.enumerated().compactMap { position, component in
            guard case .product = component.item.itemType,
                  rowIDs.indices.contains(position) else { return nil }
            let rowID = rowIDs[position]
            let productID = component.item.id
            let resolutionToken = state.incrementResolutionToken(rowID: rowID)
            let request = state.context.requestContext(requestID: uuid())
            return .run { send in
                do {
                    let product = try await client.fetchProduct(productID, request)
                    guard await isCurrent(request, client: client) else { return }
                    await send(.nameResolved(
                        context: request, rowID: rowID, productID: productID,
                        token: resolutionToken, name: product.name
                    ))
                } catch {
                    guard await isCurrent(request, client: client) else { return }
                    await send(.resolveFailed(
                        context: request,
                        rowID: rowID,
                        productID: productID,
                        token: resolutionToken,
                        isMissing: Self.isMissingProduct(error),
                        unauthorized: isUnauthorizedMealError(error)
                    ))
                }
            }
        }
    }

    private static func isMissingProduct(_ error: Error) -> Bool {
        guard let mealError = error as? MealServiceError else { return false }
        switch mealError {
        case .notFound, .missingComponents: return true
        default: return false
        }
    }
}

struct MealFormSnapshot: Equatable {
    let name: String
    let notes: String
    let totalAmount: String
    let totalUnit: String
    let components: [MealComponentSnapshot]

    static let empty = MealFormSnapshot(
        name: "", notes: "", totalAmount: "", totalUnit: "", components: []
    )
}

struct MealComponentSnapshot: Equatable {
    let productID: String
    let query: String
    let amount: String
    let unit: String
}
