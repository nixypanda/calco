// Composes the assistant, custom-food editor, and ad-hoc review flow.

import ComposableArchitecture
import Foundation

public enum FoodCreationEntry: Equatable, Sendable {
    case assistant(purpose: AssistantDraftPurpose, barcode: String?)
    case barcode(String)
}

@Reducer
public struct FoodCreationFeature {
    @ObservableState
    public struct State: Equatable {
        public let entry: FoodCreationEntry
        public let accountID: String
        public let sessionGeneration: UInt64
        public let today: LocalDiaryDate
        public let logContext: LibraryLogContext
        public let presentationID: UUID

        public var assistant: FoodCreationAssistantFeature.State?
        public var editor: CustomFoodEditorFeature.State?
        public var adHoc: AdHocLogFeature.State?
        public var acceptedDraft: AssistantReviewedDraft?
        public var isReviewPresented = false

        public init(
            entry: FoodCreationEntry,
            accountID: String,
            generation: UInt64,
            today: LocalDiaryDate,
            logContext: LibraryLogContext,
            presentationID: UUID = UUID()
        ) {
            self.entry = entry
            self.accountID = accountID
            self.sessionGeneration = generation
            self.today = today
            self.logContext = logContext
            self.presentationID = presentationID

            switch entry {
            case let .assistant(purpose, barcode):
                assistant = FoodCreationAssistantFeature.State(
                    assistant: AssistantFeature.State(
                        purpose: purpose,
                        initialBarcode: barcode,
                        sessionGeneration: generation
                    )
                )
            case let .barcode(barcode):
                editor = CustomFoodEditorFeature.State(
                    mode: .create,
                    accountID: accountID,
                    generation: generation,
                    presentationID: presentationID,
                    initialBarcode: barcode
                )
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case assistant(FoodCreationAssistantFeature.Action)
        case editor(CustomFoodEditorFeature.Action)
        case adHoc(AdHocLogFeature.Action)
        case reviewPresentedChanged(Bool)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        /// The entire presentation is removed by the parent. Back retains the
        /// retained draft; only a completed save/log clears the whole task.
        case finished(generation: UInt64, presentationID: UUID)
        case logged(event: LibraryLoggedEvent)
        case sessionExpired(generation: UInt64)
    }

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case let .assistant(childAction):
                guard var child = state.assistant else { return .none }
                let childEffect = FoodCreationAssistantFeature().reduce(into: &child, action: childAction)
                state.assistant = child
                switch childAction {
                case let .delegate(.acceptedReviewedDraft(purpose, generation, draft)):
                    guard generation == state.sessionGeneration,
                          purpose == draft.purpose,
                          child.assistant.isDraftAccepted,
                          child.assistant.reviewedDraft == draft,
                          state.acceptedDraft != draft else {
                        return childEffect.map(Action.assistant)
                    }
                    state.acceptedDraft = draft
                    switch purpose {
                    case .customFood:
                        state.editor = CustomFoodEditorFeature.State(
                            mode: .create,
                            accountID: state.accountID,
                            generation: state.sessionGeneration,
                            presentationID: state.presentationID,
                            assistantDraft: draft
                        )
                    case .adHocLog:
                        state.adHoc = AdHocLogFeature.State(
                            accountID: state.accountID,
                            generation: state.sessionGeneration,
                            today: state.today,
                            logContext: state.logContext,
                            presentationID: state.presentationID,
                            assistantDraft: draft
                        )
                    }
                    state.isReviewPresented = true
                    return childEffect.map(Action.assistant)

                case let .delegate(.sessionExpired(generation)):
                    guard generation == state.sessionGeneration else {
                        return childEffect.map(Action.assistant)
                    }
                    return .merge(
                        childEffect.map(Action.assistant),
                        .send(.delegate(.sessionExpired(generation: generation)))
                    )
                case .delegate:
                    break
                default:
                    break
                }
                return childEffect.map(Action.assistant)

            case let .editor(childAction):
                guard var child = state.editor else { return .none }
                let childEffect = CustomFoodEditorFeature().reduce(into: &child, action: childAction)
                state.editor = child
                switch childAction {
                case let .delegate(.saved(_, generation, presentationID)):
                    guard generation == state.sessionGeneration,
                          presentationID == state.presentationID else {
                        return childEffect.map(Action.editor)
                    }
                    return .merge(
                        childEffect.map(Action.editor),
                        .send(.delegate(.finished(
                            generation: generation, presentationID: presentationID
                        )))
                    )
                case let .delegate(.sessionExpired(generation)):
                    guard generation == state.sessionGeneration else {
                        return childEffect.map(Action.editor)
                    }
                    return .merge(
                        childEffect.map(Action.editor),
                        .send(.delegate(.sessionExpired(generation: generation)))
                    )
                case .delegate:
                    break
                default:
                    break
                }
                return childEffect.map(Action.editor)

            case let .adHoc(childAction):
                guard var child = state.adHoc else { return .none }
                let childEffect = AdHocLogFeature().reduce(into: &child, action: childAction)
                state.adHoc = child
                switch childAction {
                case let .delegate(.logged(event)):
                    guard event.generation == state.sessionGeneration,
                          event.accountID == state.accountID else {
                        return childEffect.map(Action.adHoc)
                    }
                    return .merge(
                        childEffect.map(Action.adHoc),
                        .send(.delegate(.logged(event: event))),
                        .send(.delegate(.finished(
                            generation: event.generation, presentationID: state.presentationID
                        )))
                    )
                case let .delegate(.sessionExpired(generation)):
                    guard generation == state.sessionGeneration else {
                        return childEffect.map(Action.adHoc)
                    }
                    return .merge(
                        childEffect.map(Action.adHoc),
                        .send(.delegate(.sessionExpired(generation: generation)))
                    )
                case .delegate:
                    break
                default:
                    break
                }
                return childEffect.map(Action.adHoc)

            case let .reviewPresentedChanged(presented):
                state.isReviewPresented = presented
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
