// Personal API-key wire models, validation, and service contracts.
//
// Secrets are deliberately modeled as a non-Codable wrapper with redacted
// reflection output. Nothing in this file persists a raw key.

import Foundation

// MARK: - Scope

/// A scope returned by the list endpoint. Unknown values are preserved so a
/// newer server scope cannot make the whole list fail to decode, but they are
/// never offered as a create choice.
public enum APIKeyScope: Equatable, Hashable, Sendable {
    case read
    case readWrite
    case unknown(String)
}

extension APIKeyScope: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "read":
            self = .read
        case "read_write":
            self = .readWrite
        default:
            self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue ?? "unknown")
    }

    public var wireValue: String? {
        switch self {
        case .read: return "read"
        case .readWrite: return "read_write"
        case .unknown: return nil
        }
    }
}

/// The create endpoint accepts only the two scopes the server documents.
public enum APIKeyCreatableScope: String, CaseIterable, Codable, Hashable, Sendable {
    case read
    case readWrite = "read_write"
}

// MARK: - Metadata

public struct APIKey: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tokenHint: String
    public let scope: APIKeyScope
    public let createdAt: String
    public let lastUsedAt: String?
    public let expiresAt: String?

    public init(
        id: String,
        name: String,
        tokenHint: String,
        scope: APIKeyScope,
        createdAt: String,
        lastUsedAt: String? = nil,
        expiresAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.tokenHint = tokenHint
        self.scope = scope
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case tokenHint = "token_hint"
        case scope
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case expiresAt = "expires_at"
    }

    public var isExpired: Bool {
        isExpired(at: Date())
    }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt,
              let date = APIKeyTimestamp.date(from: expiresAt) else {
            return false
        }
        return date <= now
    }
}

public struct APIKeyListResponse: Decodable, Equatable, Sendable {
    public let items: [APIKey]

    public init(items: [APIKey]) {
        self.items = items
    }
}

// MARK: - Create

public struct APIKeyCreateRequest: Encodable, Equatable, Sendable {
    public let name: String
    public let scope: APIKeyCreatableScope
    /// `nil` means the server creates a non-expiring key.
    public let expiresInDays: Int?

    public init(
        name: String,
        scope: APIKeyCreatableScope,
        expiresInDays: Int?
    ) {
        self.name = name
        self.scope = scope
        self.expiresInDays = expiresInDays
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case scope
        case expiresInDays = "expires_in_days"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(scope.rawValue, forKey: .scope)
        // Match the web client: never send an explicit null for "Never".
        if let expiresInDays {
            try container.encode(expiresInDays, forKey: .expiresInDays)
        }
    }
}

/// One-time create result. The server flattens key metadata and `token` at the
/// same level.
public struct CreatedAPIKey: Decodable, Equatable, Sendable {
    public let key: APIKey
    public let secret: APIKeySecret

    public init(key: APIKey, secret: APIKeySecret) {
        self.key = key
        self.secret = secret
    }

    private enum CodingKeys: String, CodingKey {
        case token
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try APIKey(from: decoder)
        secret = APIKeySecret(value: try container.decode(String.self, forKey: .token))
    }
}

/// The only place a raw secret is held. It is intentionally not Codable and
/// its description/debugDescription are redacted so accidental interpolation
/// or diagnostics cannot print the value.
public struct APIKeySecret: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

// MARK: - Expiry choices

public enum APIKeyExpiryChoice: String, CaseIterable, Hashable, Sendable {
    case days30
    case days90
    case days365
    case never

    public var expiresInDays: Int? {
        switch self {
        case .days30: return 30
        case .days90: return 90
        case .days365: return 365
        case .never: return nil
        }
    }

    public static let allowedDayRange = 1...3650

    public static func isValidExpiryDays(_ days: Int) -> Bool {
        allowedDayRange.contains(days)
    }

    /// The web UI defaults to 90 days; the API itself has no default.
    public static let `default`: APIKeyExpiryChoice = .days90
}

// MARK: - Name validation

public enum APIKeyNameValidationError: Error, Equatable, Sendable {
    case required
    case tooLong
    case invalidCharacters
}

/// Mirrors `ApiKeyName::new` in `backend/src/auth/domain.rs`: trim by Unicode
/// whitespace, count Unicode scalars (Rust `chars()`), reject control and
/// invisible formatting scalars, and require at least one visible scalar.
public enum APIKeyNameValidator {
    public static let maximumScalarCount = 64

    public static func validatedName(
        from raw: String
    ) -> Result<String, APIKeyNameValidationError> {
        let scalars = Array(raw.unicodeScalars)
        let trimmed = trimWhitespace(scalars)
        guard !trimmed.isEmpty else {
            return .failure(.required)
        }
        guard trimmed.count <= maximumScalarCount else {
            return .failure(.tooLong)
        }
        guard !trimmed.contains(where: isForbidden),
              trimmed.contains(where: isVisible) else {
            return .failure(.invalidCharacters)
        }
        return .success(String(String.UnicodeScalarView(trimmed)))
    }

    public static func trimmedName(from raw: String) -> String {
        let trimmed = trimWhitespace(Array(raw.unicodeScalars))
        return String(String.UnicodeScalarView(trimmed))
    }

    private static func trimWhitespace(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard !scalars.isEmpty else { return [] }
        var lower = 0
        var upper = scalars.count
        while lower < upper, isWhitespace(scalars[lower]) {
            lower += 1
        }
        while upper > lower, isWhitespace(scalars[upper - 1]) {
            upper -= 1
        }
        return Array(scalars[lower..<upper])
    }

    /// Matches Rust `char::is_whitespace` (Unicode White_Space). Foundation's
    /// `whitespacesAndNewlines` set is not identical and includes U+200B.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control {
            return true
        }
        switch scalar.value {
        case 0x00AD, 0x061C, 0x180E, 0x200B, 0x200E, 0x200F,
             0x2028, 0x2029, 0xFEFF:
            return true
        case 0x202A...0x202E, 0x2060...0x206F, 0xFFF9...0xFFFB:
            return true
        default:
            return false
        }
    }

    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        !isWhitespace(scalar)
            && scalar.properties.generalCategory != .control
            && scalar.value != 0x200C
            && scalar.value != 0x200D
    }
}

// MARK: - Timestamp display

public enum APIKeyTimestamp {
    public static func date(from raw: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = withFractionalSeconds.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Formats the date portion in the user's locale. Unparseable values fall
    /// back to their leading `YYYY-MM-DD` text rather than hiding metadata.
    public static func displayString(
        from raw: String,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = date(from: raw) else {
            return String(raw.prefix(10))
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Service contract

public enum APIKeyServiceError: Error, Equatable, Sendable {
    case unauthorized
    case networkUnavailable
    case timedOut
    case cancelled
    case rateLimited
    case limitReached
    case notFound
    case rejected(String)
    case server(String)
    case invalidResponse
    case unknown

    /// A create can reach the server even when the client never sees a
    /// response. Those failures must refresh metadata instead of retrying.
    public var isAmbiguousCreateFailure: Bool {
        switch self {
        case .networkUnavailable, .timedOut, .cancelled, .server, .invalidResponse:
            return true
        case .unauthorized, .rateLimited, .limitReached, .notFound, .rejected, .unknown:
            return false
        }
    }

    public var isUnauthorized: Bool {
        self == .unauthorized
    }

    /// A definitive result proves the server did not commit a key, so the
    /// durable create intent can be cleared. Ambiguous failures must keep it.
    public var isDefinitiveCreateFailure: Bool {
        switch self {
        case .unauthorized, .rateLimited, .limitReached, .notFound, .rejected:
            return true
        case .networkUnavailable, .timedOut, .cancelled, .server, .invalidResponse, .unknown:
            return false
        }
    }
}

public protocol APIKeyServicing: Sendable {
    func listAPIKeys() async throws -> [APIKey]
    func createAPIKey(_ request: APIKeyCreateRequest) async throws -> CreatedAPIKey
    func revokeAPIKey(id: String) async throws
}
