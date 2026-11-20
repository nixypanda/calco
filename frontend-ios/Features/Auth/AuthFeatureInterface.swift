import Foundation

public enum AuthRole: String, Sendable, Equatable {
    case user
    case admin
    case other
}

public struct AuthUser: Equatable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let role: AuthRole
    public let displayName: String?
    /// Backend user-profile UUID used for request account binding. This is
    /// intentionally separate from `id`, which remains the journal/auth scope.
    public let profileID: String?

    public init(
        id: String,
        username: String,
        role: AuthRole,
        displayName: String?,
        profileID: String? = nil
    ) {
        self.id = id
        self.username = username
        self.role = role
        self.displayName = displayName
        self.profileID = profileID
    }
}

public enum SignInOutcome: Equatable, Sendable {
    case supported(AuthUser)
    case admin(AuthUser)
}

public enum AuthFeatureError: Error, Equatable, Sendable {
    case invalidCredentials
    case networkUnavailable
    case server(String)
    case unknown
}

public enum SessionUnavailableReason: Equatable, Sendable {
    case signedOut
    case expired
    case notFound
}

public protocol AuthAuthenticating: Sendable {
    func signIn(username: String, password: String) async throws -> SignInOutcome
}

public protocol AuthFeatureCoordinating: AnyObject {
    func authFeatureDidSignIn(_ user: AuthUser)
    func authFeatureDidRejectAdmin(_ user: AuthUser)
    func authFeatureDidRequestSignOut()
    func authFeatureDidReportSessionUnavailable(_ reason: SessionUnavailableReason)
}

public extension AuthFeatureCoordinating {
    func authFeatureDidRequestSignOut() {}
    func authFeatureDidReportSessionUnavailable(_ reason: SessionUnavailableReason) {}
}