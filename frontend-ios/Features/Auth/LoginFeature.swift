import ComposableArchitecture
import Foundation

@Reducer
public struct LoginFeature {
    public enum Phase: Equatable, Sendable {
        case editing
        case submitting(requestID: UUID)
        case failed(LoginFailure)
    }

    @ObservableState
    public struct State: Equatable {
        public var username: String = ""
        public var password: String = ""
        public var phase: Phase = .editing

        public init(
            username: String = "",
            password: String = "",
            phase: Phase = .editing
        ) {
            self.username = username
            self.password = password
            self.phase = phase
        }

        public var isSubmitting: Bool {
            if case .submitting = phase { true } else { false }
        }
    }

    public enum Action: Equatable, Sendable {
        case usernameChanged(String)
        case passwordChanged(String)
        case submit
        case submitResponse(UUID, SessionCoordinator.SignInResult)
    }

    private enum CancelID {
        case submit
    }

    @Dependency(\.sessionClient) private var sessionClient
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case let .usernameChanged(username):
                state.username = username
                state.phase = .editing
                return .cancel(id: CancelID.submit)

            case let .passwordChanged(password):
                state.password = password
                state.phase = .editing
                return .cancel(id: CancelID.submit)

            case .submit:
                guard !state.isSubmitting else { return .none }

                let trimmedUsername = state.username
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedUsername.isEmpty else {
                    state.phase = .failed(.validation(.usernameRequired))
                    return .none
                }
                guard !state.password.isEmpty else {
                    state.phase = .failed(.validation(.passwordRequired))
                    return .none
                }

                let requestID = uuid()
                state.phase = .submitting(requestID: requestID)

                let password = state.password
                return .run { send in
                    let result = await sessionClient.signIn(
                        trimmedUsername,
                        password
                    )
                    await send(.submitResponse(requestID, result))
                }
                .cancellable(id: CancelID.submit, cancelInFlight: true)

            case let .submitResponse(requestID, result):
                guard case let .submitting(currentRequestID) = state.phase,
                      currentRequestID == requestID else {
                    return .none
                }

                switch result {
                case .signedIn:
                    state.phase = .editing
                    state.password = ""
                    return .none

                case .rejectedUnsupportedRole:
                    // The shared session authority owns unsupported-account
                    // presentation. The leaf only stops its own submission.
                    state.phase = .editing
                    state.password = ""
                    return .none

                case let .failed(failure):
                    state.phase = .failed(.authentication(map(failure)))
                    return .none
                }
            }
        }
    }

    private func map(_ failure: SessionCoordinator.Failure) -> AuthFeatureError {
        switch failure {
        case .invalidCredentials: .invalidCredentials
        case .networkUnavailable, .timedOut: .networkUnavailable
        case .server(let message): .server(message)
        case .cancelled, .unknown: .unknown
        }
    }
}
