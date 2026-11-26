import ComposableArchitecture
import Foundation

@Reducer
public struct SearchScreenFeature {
    public enum NavigationOrigin: Equatable, Sendable {
        case diaryPush
        case searchTab
    }

    @ObservableState
    public struct State: Equatable {
        public var catalog: SearchFeature.State
        public var history: SearchHistoryFeature.State
        public var quickAdd: SearchQuickAddFeature.State
        public var barcode: BarcodeFeature.State

        public var originDate: LocalDiaryDate { catalog.originDate }
        public var originMealSlot: MealSlot? { catalog.originMealSlot }
        public var sessionGeneration: UInt64 { catalog.sessionGeneration }

        public init(date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64) {
            self.catalog = SearchFeature.State(
                originDate: date,
                originMealSlot: mealSlot,
                sessionGeneration: generation
            )
            self.history = SearchHistoryFeature.State(
                contextDate: date,
                contextMealSlot: mealSlot,
                sessionGeneration: generation
            )
            self.quickAdd = SearchQuickAddFeature.State(
                originDate: date,
                originMealSlot: mealSlot,
                sessionGeneration: generation
            )
            self.barcode = BarcodeFeature.State(sessionGeneration: generation)
        }
    }

    public enum Action: Sendable {
        case queryChanged(String)
        case searchSubmitted
        case scopeChanged(SearchScopeOption)
        case updateContext(date: LocalDiaryDate, mealSlot: MealSlot?)
        case appeared
        case clearQuery
        case categorySuggestionSelected(CategorySuggestion)
        case selectRecent(item: RecentLogItem, quantity: NutritionQuantity?, origin: NavigationOrigin = .diaryPush)
        case quickAdd(item: RecentLogItem, quantity: NutritionQuantity?)
        case selectCatalogResult(id: String, origin: NavigationOrigin)
        case selectBarcodeProduct(origin: NavigationOrigin)
        case createBarcodeDraft(origin: NavigationOrigin)
        case catalog(SearchFeature.Action)
        case history(SearchHistoryFeature.Action)
        case quickAddFeature(SearchQuickAddFeature.Action)
        case barcode(BarcodeFeature.Action)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case selectedFood(
            id: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            generation: UInt64,
            origin: NavigationOrigin = .diaryPush
        )
        case selectedMeal(
            id: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            quantity: NutritionQuantity,
            generation: UInt64,
            origin: NavigationOrigin = .diaryPush
        )
        case createCustomFoodDraft(
            barcode: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            generation: UInt64,
            origin: NavigationOrigin = .diaryPush
        )
        case sessionExpired(generation: UInt64)
        case diaryChanged(date: LocalDiaryDate, generation: UInt64)
    }

    private let catalogReducer = SearchFeature()
    private let historyReducer = SearchHistoryFeature()
    private let quickAddReducer = SearchQuickAddFeature()
    private let barcodeReducer = BarcodeFeature()

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .queryChanged(let query):
                return queryChanged(&state, query: query)

            case .searchSubmitted:
                return searchSubmitted(&state)

            case .scopeChanged(let scope):
                return scopeChanged(&state, scope: scope)

            case .updateContext(let date, let mealSlot):
                return updateContext(&state, date: date, mealSlot: mealSlot)

            case .appeared:
                return appeared(&state)

            case .clearQuery:
                return clearQuery(&state)

            case .categorySuggestionSelected(let suggestion):
                return categorySuggestionSelected(&state, suggestion: suggestion)

            case .selectRecent(let item, let quantity, let origin):
                return selectRecent(&state, item: item, quantity: quantity, origin: origin)

            case .quickAdd(let item, let quantity):
                return run(
                    &state,
                    child: \.quickAdd,
                    action: .quickAdd(item, quantity),
                    reducer: quickAddReducer,
                    map: Action.quickAddFeature
                )

            case .selectCatalogResult(let id, let origin):
                return selectCatalogResult(&state, id: id, origin: origin)

            case .selectBarcodeProduct(let origin):
                return selectBarcodeProduct(&state, origin: origin)

            case .createBarcodeDraft(let origin):
                return createBarcodeDraft(&state, origin: origin)

            case .catalog(let childAction):
                return handleCatalogAction(&state, action: childAction)

            case .history(let childAction):
                return handleHistoryAction(&state, action: childAction)

            case .quickAddFeature(let childAction):
                return handleQuickAddAction(&state, action: childAction)

            case .barcode(let childAction):
                return handleBarcodeAction(&state, action: childAction)

            case .delegate:
                return .none
            }
        }
    }

    private func queryChanged(_ state: inout State, query: String) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        effects.append(
            run(
                &state,
                child: \.catalog,
                action: .queryChanged(query),
                reducer: catalogReducer,
                map: Action.catalog
            )
        )

        if state.catalog.scope == .barcode {
            effects.append(
                run(
                    &state,
                    child: \.barcode,
                    action: .barcodeChanged(query),
                    reducer: barcodeReducer,
                    map: Action.barcode
                )
            )
        } else {
            effects.append(
                run(
                    &state,
                    child: \.history,
                    action: .categoryQueryChanged(query),
                    reducer: historyReducer,
                    map: Action.history
                )
            )
        }

        return .merge(effects)
    }

    private func searchSubmitted(_ state: inout State) -> Effect<Action> {
        if state.catalog.scope == .barcode {
            return run(
                &state,
                child: \.barcode,
                action: .lookupSubmitted,
                reducer: barcodeReducer,
                map: Action.barcode
            )
        }

        var effects: [Effect<Action>] = []
        effects.append(
            run(
                &state,
                child: \.catalog,
                action: .searchSubmitted,
                reducer: catalogReducer,
                map: Action.catalog
            )
        )
        let query = state.catalog.query
        effects.append(
            run(
                &state,
                child: \.history,
                action: .categoryQueryChanged(query),
                reducer: historyReducer,
                map: Action.history
            )
        )
        return .merge(effects)
    }

    private func scopeChanged(_ state: inout State, scope: SearchScopeOption) -> Effect<Action> {
        let previousScope = state.catalog.scope
        guard previousScope != scope else { return .none }

        var effects: [Effect<Action>] = []

        if previousScope == .barcode, scope != .barcode {
            effects.append(
                run(
                    &state,
                    child: \.barcode,
                    action: .cancelLookup,
                    reducer: barcodeReducer,
                    map: Action.barcode
                )
            )
        }

        effects.append(
            run(
                &state,
                child: \.catalog,
                action: .scopeChanged(scope),
                reducer: catalogReducer,
                map: Action.catalog
            )
        )

        if scope == .barcode {
            effects.append(
                run(
                    &state,
                    child: \.history,
                    action: .categoryQueryChanged(""),
                    reducer: historyReducer,
                    map: Action.history
                )
            )
        } else {
            let query = state.catalog.query
            effects.append(
                run(
                    &state,
                    child: \.history,
                    action: .categoryQueryChanged(query),
                    reducer: historyReducer,
                    map: Action.history
                )
            )
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               scope == .all || scope == .history {
                effects.append(
                    run(
                        &state,
                        child: \.history,
                        action: .loadRecents,
                        reducer: historyReducer,
                        map: Action.history
                    )
                )
            }
        }

        return .merge(effects)
    }

    private func updateContext(
        _ state: inout State,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) -> Effect<Action> {
        guard state.originDate != date || state.originMealSlot != mealSlot else {
            return .none
        }

        var effects: [Effect<Action>] = []

        effects.append(
            run(
                &state,
                child: \.catalog,
                action: .updateContext(date: date, mealSlot: mealSlot),
                reducer: catalogReducer,
                map: Action.catalog
            )
        )
        effects.append(
            run(
                &state,
                child: \.history,
                action: .contextChanged(date: date, mealSlot: mealSlot),
                reducer: historyReducer,
                map: Action.history
            )
        )
        effects.append(
            run(
                &state,
                child: \.quickAdd,
                action: .contextChanged(originDate: date, mealSlot: mealSlot),
                reducer: quickAddReducer,
                map: Action.quickAddFeature
            )
        )

        if state.catalog.scope == .all || state.catalog.scope == .history {
            effects.append(
                run(
                    &state,
                    child: \.history,
                    action: .refreshRecents,
                    reducer: historyReducer,
                    map: Action.history
                )
            )
        }

        return .merge(effects)
    }

    private func appeared(_ state: inout State) -> Effect<Action> {
        state.catalog.selectedResultID = nil
        guard state.catalog.scope == .all || state.catalog.scope == .history else {
            return .none
        }
        return run(
            &state,
            child: \.history,
            action: .loadRecents,
            reducer: historyReducer,
            map: Action.history
        )
    }

    private func clearQuery(_ state: inout State) -> Effect<Action> {
        var effects: [Effect<Action>] = []

        effects.append(
            run(
                &state,
                child: \.catalog,
                action: .queryChanged(""),
                reducer: catalogReducer,
                map: Action.catalog
            )
        )
        effects.append(
            run(
                &state,
                child: \.history,
                action: .categoryQueryChanged(""),
                reducer: historyReducer,
                map: Action.history
            )
        )

        if !state.quickAdd.isBusy {
            effects.append(
                run(
                    &state,
                    child: \.quickAdd,
                    action: .dismissMessage,
                    reducer: quickAddReducer,
                    map: Action.quickAddFeature
                )
            )
        }

        return .merge(effects)
    }

    private func categorySuggestionSelected(
        _ state: inout State,
        suggestion: CategorySuggestion
    ) -> Effect<Action> {
        guard state.catalog.scope != .barcode else { return .none }

        let quoted = suggestion.value.contains(where: \.isWhitespace)
            ? "\"\(suggestion.value)\""
            : suggestion.value
        let token = "category:\(quoted)"
        let trimmed = state.catalog.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmed.isEmpty ? token : "\(trimmed) \(token)"

        _ = catalogReducer.reduce(into: &state.catalog, action: .queryChanged(query))
        let historyClearEffect = historyReducer.reduce(
            into: &state.history,
            action: .categoryQueryChanged("")
        ).map(Action.history)

        let searchEffect = run(
            &state,
            child: \.catalog,
            action: .searchSubmitted,
            reducer: catalogReducer,
            map: Action.catalog
        )

        return .merge(historyClearEffect, searchEffect)
    }

    private func selectCatalogResult(
        _ state: inout State,
        id: String,
        origin: NavigationOrigin
    ) -> Effect<Action> {
        let date = state.originDate
        let mealSlot = state.originMealSlot
        let generation = state.sessionGeneration
        return run(
            &state,
            child: \.catalog,
            action: .selectResult(id: id),
            reducer: catalogReducer,
            map: Action.catalog
        )
        .map { action in
            guard case .catalog(.delegate(.selectedFood(let selectedID, _, _, let delegateGeneration))) = action,
                  delegateGeneration == generation else {
                return action
            }
            return .delegate(.selectedFood(
                id: selectedID,
                date: date,
                mealSlot: mealSlot,
                generation: delegateGeneration,
                origin: origin
            ))
        }
    }

    private func selectBarcodeProduct(
        _ state: inout State,
        origin: NavigationOrigin
    ) -> Effect<Action> {
        let date = state.originDate
        let mealSlot = state.originMealSlot
        let generation = state.sessionGeneration
        return run(
            &state,
            child: \.barcode,
            action: .foundProductSelected,
            reducer: barcodeReducer,
            map: Action.barcode
        )
        .map { action in
            guard case .barcode(.delegate(.selectedProduct(let lookup, let delegateGeneration))) = action,
                  delegateGeneration == generation else {
                return action
            }
            return .delegate(.selectedFood(
                id: lookup.product.id,
                date: date,
                mealSlot: mealSlot,
                generation: delegateGeneration,
                origin: origin
            ))
        }
    }

    private func createBarcodeDraft(
        _ state: inout State,
        origin: NavigationOrigin
    ) -> Effect<Action> {
        let date = state.originDate
        let mealSlot = state.originMealSlot
        let generation = state.sessionGeneration
        return run(
            &state,
            child: \.barcode,
            action: .createCustomFoodDraftSelected,
            reducer: barcodeReducer,
            map: Action.barcode
        )
        .map { action in
            guard case .barcode(.delegate(.createCustomFoodDraft(let draft, let delegateGeneration))) = action,
                  delegateGeneration == generation else {
                return action
            }
            return .delegate(.createCustomFoodDraft(
                barcode: draft.barcode,
                date: date,
                mealSlot: mealSlot,
                generation: delegateGeneration,
                origin: origin
            ))
        }
    }

    private func selectRecent(
        _ state: inout State,
        item: RecentLogItem,
        quantity: NutritionQuantity?,
        origin: NavigationOrigin
    ) -> Effect<Action> {
        let generation = state.sessionGeneration
        switch item.item {
        case .adHoc:
            return .none
        case .product(let product):
            return .send(.delegate(.selectedFood(
                id: product.id,
                date: state.originDate,
                mealSlot: state.originMealSlot,
                generation: generation,
                origin: origin
            )))
        case .meal(let meal):
            return .send(.delegate(.selectedMeal(
                id: meal.id,
                date: state.originDate,
                mealSlot: state.originMealSlot,
                quantity: quantity ?? item.quantity,
                generation: generation,
                origin: origin
            )))
        }
    }

    private func handleCatalogAction(
        _ state: inout State,
        action: SearchFeature.Action
    ) -> Effect<Action> {
        let effect = run(
            &state,
            child: \.catalog,
            action: action,
            reducer: catalogReducer,
            map: Action.catalog
        )

        guard case .delegate(let delegate) = action else { return effect }

        let delegateEffect: Effect<Action>
        switch delegate {
        case .selectedFood(let id, let date, let mealSlot, let generation):
            guard generation == state.sessionGeneration else { return effect }
            delegateEffect = .send(.delegate(.selectedFood(
                id: id,
                date: date,
                mealSlot: mealSlot,
                generation: generation,
                origin: .diaryPush
            )))
        case .sessionExpired(let generation):
            guard generation == state.sessionGeneration else { return effect }
            delegateEffect = .send(.delegate(.sessionExpired(generation: generation)))
        }

        return .merge(effect, delegateEffect)
    }

    private func handleHistoryAction(
        _ state: inout State,
        action: SearchHistoryFeature.Action
    ) -> Effect<Action> {
        let effect = run(
            &state,
            child: \.history,
            action: action,
            reducer: historyReducer,
            map: Action.history
        )

        guard case .delegate(let delegate) = action else { return effect }

        switch delegate {
        case .sessionExpired(let generation):
            guard generation == state.sessionGeneration else { return effect }
            return .merge(effect, .send(.delegate(.sessionExpired(generation: generation))))
        }
    }

    private func handleQuickAddAction(
        _ state: inout State,
        action: SearchQuickAddFeature.Action
    ) -> Effect<Action> {
        let effect = run(
            &state,
            child: \.quickAdd,
            action: action,
            reducer: quickAddReducer,
            map: Action.quickAddFeature
        )

        guard case .delegate(let delegate) = action else { return effect }

        switch delegate {
        case .logged:
            return effect

        case .refresh(let originDate, let sessionGeneration):
            guard sessionGeneration == state.sessionGeneration else { return effect }
            var effects: [Effect<Action>] = [
                effect,
                .send(.delegate(.diaryChanged(date: originDate, generation: sessionGeneration)))
            ]
            if state.catalog.scope == .all || state.catalog.scope == .history {
                effects.append(
                    run(
                        &state,
                        child: \.history,
                        action: .refreshRecents,
                        reducer: historyReducer,
                        map: Action.history
                    )
                )
            }
            return .merge(effects)

        case .sessionExpired(let generation):
            guard generation == state.sessionGeneration else { return effect }
            return .merge(effect, .send(.delegate(.sessionExpired(generation: generation))))
        }
    }

    private func handleBarcodeAction(
        _ state: inout State,
        action: BarcodeFeature.Action
    ) -> Effect<Action> {
        let effect = run(
            &state,
            child: \.barcode,
            action: action,
            reducer: barcodeReducer,
            map: Action.barcode
        )

        guard case .delegate(let delegate) = action else { return effect }

        switch delegate {
        case .selectedProduct(let lookup, let generation):
            guard generation == state.sessionGeneration else { return effect }
            return .merge(
                effect,
                .send(.delegate(.selectedFood(
                    id: lookup.product.id,
                    date: state.originDate,
                    mealSlot: state.originMealSlot,
                    generation: generation,
                    origin: .diaryPush
                )))
            )

        case .createCustomFoodDraft(let draft, let generation):
            guard generation == state.sessionGeneration else { return effect }
            return .merge(
                effect,
                .send(.delegate(.createCustomFoodDraft(
                    barcode: draft.barcode,
                    date: state.originDate,
                    mealSlot: state.originMealSlot,
                    generation: generation,
                    origin: .diaryPush
                )))
            )

        case .sessionExpired(_, let generation):
            guard generation == state.sessionGeneration else { return effect }
            return .merge(effect, .send(.delegate(.sessionExpired(generation: generation))))
        }
    }

    private func run<ChildState, ChildAction>(
        _ state: inout State,
        child: WritableKeyPath<State, ChildState>,
        action: ChildAction,
        reducer: some Reducer<ChildState, ChildAction>,
        map: @escaping (ChildAction) -> Action
    ) -> Effect<Action> {
        reducer.reduce(into: &state[keyPath: child], action: action).map(map)
    }
}
