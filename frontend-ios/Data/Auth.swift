// Authentication wire models.

import Foundation

public enum IdentityRole: String, Codable, Sendable {
    case admin
    case user
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = IdentityRole(rawValue: raw) ?? .other
    }
}

public struct AuthIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let role: IdentityRole

    public init(id: String, username: String, role: IdentityRole) {
        self.id = id
        self.username = username
        self.role = role
    }
}

public struct AuthProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public struct LoginSession: Codable, Equatable, Sendable {
    public let identity: AuthIdentity
    public let profile: AuthProfile?

    public init(identity: AuthIdentity, profile: AuthProfile? = nil) {
        self.identity = identity
        self.profile = profile
    }

    public var isAdmin: Bool { identity.role == .admin }
    public var isRegularUser: Bool { identity.role == .user }
    public var displayName: String { profile?.displayName ?? identity.username }
}

public struct BootstrapStatus: Codable, Equatable, Sendable {
    public let adminExists: Bool

    public init(adminExists: Bool) {
        self.adminExists = adminExists
    }

    private enum CodingKeys: String, CodingKey {
        case adminExists = "admin_exists"
    }
}

public struct LoginRequest: Encodable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}
