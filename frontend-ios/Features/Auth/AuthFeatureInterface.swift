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

