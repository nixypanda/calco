import ComposableArchitecture
import Foundation

/// Typed seam used by a food-creation flow to receive an accepted, reviewed
/// assistant draft (or a session-expiry signal) without reaching into global
/// navigation or session state itself.
///
/// The flow that installs this dependency owns the actual authority to open an
/// editor or invalidate a session; this client is only a callback value.
public struct FoodCreationAssistantHandoffClient: Sendable {
    public var acceptReviewedDraft: @MainActor @Sendable (AssistantReviewedDraft) -> Void
    public var sessionExpired: @MainActor @Sendable (UInt64) -> Void

    public init(
        acceptReviewedDraft: @escaping @MainActor @Sendable (AssistantReviewedDraft) -> Void,
        sessionExpired: @escaping @MainActor @Sendable (UInt64) -> Void
    ) {
        self.acceptReviewedDraft = acceptReviewedDraft
        self.sessionExpired = sessionExpired
    }

    /// Fails fast so a flow that forgets to install a real handoff is caught
    /// immediately rather than silently dropping an accepted draft.
    public static let unimplemented = Self(
        acceptReviewedDraft: { _ in
            fatalError("Unimplemented: FoodCreationAssistantHandoffClient.acceptReviewedDraft")
        },
        sessionExpired: { _ in
            fatalError("Unimplemented: FoodCreationAssistantHandoffClient.sessionExpired")
        }
    )
}

extension DependencyValues {
    public var foodCreationAssistantHandoff: FoodCreationAssistantHandoffClient {
        get { self[FoodCreationAssistantHandoffKey.self] }
        set { self[FoodCreationAssistantHandoffKey.self] = newValue }
    }
}

private enum FoodCreationAssistantHandoffKey: DependencyKey {
    static let liveValue: FoodCreationAssistantHandoffClient = .unimplemented
    static let testValue: FoodCreationAssistantHandoffClient = .unimplemented
}

/// Local TCA parent for the live food-creation assistant flow.
///
/// It owns only the child `AssistantFeature` state. The child's accepted flag
/// remains the single source of truth for duplicate accepts; this reducer just
/// forwards one genuine accept (and a matching-expiry signal) to the injected
/// handoff client. All purpose/generation validation is done against the child
/// state after the child has reduced the action.
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
    }

    @Dependency(\.foodCreationAssistantHandoff) private var handoff

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
                let handoff = self.handoff
                return .run { _ in
                    await handoff.acceptReviewedDraft(draft)
                }

            case let .assistant(.delegate(.sessionExpired(generation))):
                // A stale child cannot invalidate the current session.
                guard generation == state.assistant.sessionGeneration else {
                    return .none
                }
                let handoff = self.handoff
                return .run { _ in
                    await handoff.sessionExpired(generation)
                }

            case .assistant:
                return .none
            }
        }
    }
}
