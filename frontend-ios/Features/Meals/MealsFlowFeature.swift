// Root Meals flow. It owns the list and a typed navigation stack so the host
// can compose one `StoreOf<MealsFlowFeature>` inside the window store. All
// cross-feature coordination is delegated with the captured context/generation.

import ComposableArchitecture
import Foundation

@Reducer
public enum MealsPath {
    case detail(MealDetailFeature)
    case editor(MealEditorFeature)
}

extension MealsPath.State: Equatable {}

@Reducer
public struct MealsFlowFeature {
    @ObservableState
    public struct State: Equatable {
        public let context: MealsCaptureContext
        public var list: MealsListFeature.State
        public var path: StackState<MealsPath.State> = StackState()
        public var hasDirtyEditor = false

        public init(
            context: MealsCaptureContext,
            initialMealID: String? = nil,
            initialPortion: NutritionQuantity? = nil
        ) {
            self.context = context
            self.list = MealsListFeature.State(context: context)
            if let initialMealID {
                path.append(.detail(MealDetailFeature.State(
                    context: context,
                    mealID: initialMealID,
                    initialPortion: initialPortion
                )))
            }
        }

        public var isAtRoot: Bool { path.isEmpty }
    }

    public enum Action: Sendable {
        case list(MealsListFeature.Action)
        case path(StackActionOf<MealsPath>)
        case close
        case back
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case logged(MealsLoggedPayload)
        case deleted(mealID: String, generation: UInt64, presentationID: UUID)
        case sessionExpired(generation: UInt64, presentationID: UUID)
        case close(generation: UInt64, presentationID: UUID)
        case back(generation: UInt64, presentationID: UUID)
        case dirtyChanged(Bool, generation: UInt64, presentationID: UUID)
    }

    public init() {}

    public var body: some Reducer<State, Action> {
        Scope(state: \.list, action: \.list) {
            MealsListFeature()
        }
        Reduce { state, action in
            switch action {
            case .close:
                return .send(.delegate(.close(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case .back:
                return .send(.delegate(.back(
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .list(.delegate(.openDetail(mealID, context, generation, presentationID))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                state.path.append(.detail(MealDetailFeature.State(
                    context: state.context,
                    mealID: mealID
                )))
                return .none

            case let .list(.delegate(.openEditor(id, name, context, generation, presentationID))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                let mode: MealEditorMode = id.isEmpty ? .create : .edit(id: id)
                state.path.append(.editor(MealEditorFeature.State(
                    context: state.context,
                    mode: mode
                )))
                return .none

            case let .list(.delegate(.logged(payload))):
                guard Self.isAuthorized(
                    state,
                    generation: payload.generation,
                    presentationID: payload.presentationID
                ) else { return .none }
                return .send(.delegate(.logged(payload)))

            case let .list(.delegate(.sessionExpired(generation, presentationID))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                return .send(.delegate(.sessionExpired(
                    generation: generation, presentationID: presentationID
                )))

            case let .path(.element(id: _, action: .detail(.delegate(.edit(meal, context, generation, presentationID))))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                state.path.append(.editor(MealEditorFeature.State(
                    context: state.context,
                    mode: .edit(id: meal.id)
                )))
                return .none

            case let .path(.element(id: _, action: .detail(.delegate(.deleted(mealID, generation, presentationID))))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                if !state.path.isEmpty { state.path.removeLast() }
                return .merge(
                    .send(.list(.refresh)),
                    .send(.delegate(.deleted(
                        mealID: mealID, generation: generation, presentationID: presentationID
                    )))
                )

            case let .path(.element(id: _, action: .detail(.delegate(.logged(payload))))):
                guard Self.isAuthorized(
                    state,
                    generation: payload.generation,
                    presentationID: payload.presentationID
                ) else { return .none }
                return .send(.delegate(.logged(payload)))

            case let .path(.element(id: _, action: .detail(.delegate(.sessionExpired(generation, presentationID))))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                return .send(.delegate(.sessionExpired(
                    generation: generation, presentationID: presentationID
                )))

            case let .path(.element(id: _, action: .editor(.delegate(.saved(meal, generation, presentationID))))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                let wasEditing: Bool
                if let last = state.path.last {
                    switch last {
                    case .editor(let editor): wasEditing = editor.mode.mealID != nil
                    default: wasEditing = true
                    }
                } else {
                    wasEditing = true
                }
                if !state.path.isEmpty { state.path.removeLast() }
                state.hasDirtyEditor = false
                if wasEditing {
                    return .send(.list(.refresh))
                }
                state.path.append(.detail(MealDetailFeature.State(
                    context: state.context,
                    mealID: meal.id
                )))
                return .send(.list(.refresh))

            case let .path(.element(id: _, action: .editor(.delegate(.cancelled(generation, presentationID))))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                if !state.path.isEmpty { state.path.removeLast() }
                state.hasDirtyEditor = false
                return .none

            case let .path(.element(id: _, action: .editor(.delegate(.dirtyChanged(dirty))))):
                state.hasDirtyEditor = dirty
                return .send(.delegate(.dirtyChanged(
                    dirty,
                    generation: state.context.generation,
                    presentationID: state.context.id
                )))

            case let .path(.element(id: _, action: .editor(.delegate(.sessionExpired(generation, presentationID))))):
                guard Self.isAuthorized(state, generation: generation, presentationID: presentationID) else {
                    return .none
                }
                return .send(.delegate(.sessionExpired(
                    generation: generation, presentationID: presentationID
                )))

            case .list, .path, .delegate:
                return .none
            }
        }
        .forEach(\.path, action: \.path)
    }

    private static func isAuthorized(_ state: State, generation: UInt64, presentationID: UUID) -> Bool {
        generation == state.context.generation && presentationID == state.context.id
    }
}
