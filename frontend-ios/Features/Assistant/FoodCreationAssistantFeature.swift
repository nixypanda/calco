import ComposableArchitecture
import Foundation

/// Owns the assistant child and forwards accepted drafts or session expiry.
@Reducer
public struct FoodCreationAssistantFeature {
    @ObservableState
    public struct State: Equatable {
        public var assistant: AssistantFeature.State

        public init(assistant: AssistantFeature.State) {
            self.assistant = assistant
        }
    }

    public enum Action: Equatable, Sendable {
        case assistant(AssistantFeature.Action)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case acceptedReviewedDraft(
            purpose: AssistantDraftPurpose,
            sessionGeneration: UInt64,
            draft: AssistantReviewedDraft
        )
        case sessionExpired(generation: UInt64)
    }

    public init() {}

    public var body: some Reducer<State, Action> {
        Scope(state: \.assistant, action: \.assistant) {
            AssistantFeature()
        }
        Reduce { state, action in
            switch action {
            case let .assistant(.delegate(.acceptedReviewedDraft(purpose, sessionGeneration, draft))):
                // The child reduces first, so an actual accept has already set
                // `accepted` before this delegate reaches the parent. Reject a
                // forged or stale payload that does not match that context.
                guard sessionGeneration == state.assistant.sessionGeneration,
                      purpose == state.assistant.purpose,
                      state.assistant.isDraftAccepted,
                      state.assistant.reviewedDraft == draft else {
                    return .none
                }
                return .send(.delegate(.acceptedReviewedDraft(
                    purpose: purpose,
                    sessionGeneration: sessionGeneration,
                    draft: draft
                )))

            case let .assistant(.delegate(.sessionExpired(generation))):
                // A stale child cannot invalidate the current session.
                guard generation == state.assistant.sessionGeneration else {
                    return .none
                }
                return .send(.delegate(.sessionExpired(generation: generation)))

            case .assistant, .delegate:
                return .none
            }
        }
    }
}
