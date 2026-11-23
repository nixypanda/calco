import Combine
import Foundation

public enum LoginValidation: Equatable, Sendable {
    case usernameRequired
    case passwordRequired
}

public enum LoginFailure: Equatable, Sendable {
    case validation(LoginValidation)
    case authentication(AuthFeatureError)
}

public enum LoginPhase: Equatable, Sendable {
    case editing
    case submitting
    case failed(LoginFailure)
    case adminRejected(AuthUser)
}

@MainActor
public final class LoginViewModel: ObservableObject {
    @Published public var username: String = "" {
        didSet { clearValidationFailureIfNeeded() }
    }
    @Published public var password: String = "" {
        didSet { clearValidationFailureIfNeeded() }
    }
    @Published public private(set) var phase: LoginPhase = .editing

    private let authenticator: any AuthAuthenticating
    private weak var coordinator: (any AuthFeatureCoordinating)?

    public init(
        authenticator: any AuthAuthenticating,
        coordinator: (any AuthFeatureCoordinating)? = nil
    ) {
        self.authenticator = authenticator
        self.coordinator = coordinator
    }

    public var unsupportedAdmin: AuthUser? {
        if case .adminRejected(let user) = phase { return user }
        return nil
    }

    public var isSubmitDisabled: Bool {
        if case .submitting = phase { return true }
        return false
    }

    public func submit() async {
        guard !isSubmitDisabled else { return }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            phase = .failed(.validation(.usernameRequired))
            return
        }
        guard !password.isEmpty else {
            phase = .failed(.validation(.passwordRequired))
            return
        }

        phase = .submitting

        do {
            let outcome = try await authenticator.signIn(
                username: trimmedUsername,
                password: password
            )
            switch outcome {
            case .supported(let user):
                phase = .editing
                coordinator?.authFeatureDidSignIn(user)
            case .admin(let user):
                phase = .adminRejected(user)
                coordinator?.authFeatureDidRejectAdmin(user)
            }
        } catch {
            phase = .failed(.authentication(Self.map(error)))
        }
    }

    public func dismissUnsupportedAdmin() {
        if case .adminRejected = phase {
            phase = .editing
        }
    }

    private func clearValidationFailureIfNeeded() {
        if case .failed(.validation) = phase {
            phase = .editing
        }
    }

    private static func map(_ error: Error) -> AuthFeatureError {
        if let featureError = error as? AuthFeatureError { return featureError }
        return .unknown
    }
}