// File-level note: URLSession's shared HTTPCookieStorage applies Set-Cookie values
// outside Swift's await boundaries. The coordinator therefore treats cookie
// removal as temporal rather than instantaneous: an immediate clear for the jar
// as it exists now, a queued clear for cookies a stale operation may still
// write, and a final awaited clear after logout. `operationBarrier` serializes
// the server/cookie portions of operations so a late Set-Cookie cannot resurrect
// a session that has already been invalidated or signed out. The tests in
// SessionCoordinatorTests.swift exercise these shared-jar timing invariants with
// ephemeral HTTPCookieStorage instances.
//
// Additional invariants preserved here:
// - The coordinator depends on narrow session/cookie-clearing protocols rather
//   than Store adapters; no credential, API key, bearer token, or session token
//   is stored by this file, and authentication is exclusively the backend's
//   HttpOnly cookie.
// - A valid admin or unrecognized-role cookie is not usable by this app; it is
//   removed so a later restore cannot silently re-enter that state.
// - Sign-in clears any earlier session cookie before login and does not retain a
//   cookie from a failed or ambiguous attempt, so the next user starts from a
//   clean cookie jar.
// - Session-state reset handlers are snapshotted before invocation so a handler
//   may unregister itself or another feature while running.
// - A restore 401 is an expired or missing session, never a credential prompt
//   with private data behind it.

import Combine
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Narrow session dependencies

public enum SessionRestoreOutcome: Equatable, Sendable {
    case authenticated(LoginSession)

    case unauthenticated(SessionUnavailableReason)
}

public protocol SessionServicing: Sendable {
    func restoreSession() async throws -> SessionRestoreOutcome

    func login(username: String, password: String) async throws -> LoginSession

    func logout(sessionCookies: [HTTPCookie]) async throws
}

public protocol SessionCookieClearing: Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie]
    func clearCookies(for baseURL: URL)
}

// MARK: - Default cookie-only service

public struct CalCoSessionService: SessionServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func restoreSession() async throws -> SessionRestoreOutcome {
        do {
            return .authenticated(try await client.currentSession())
        } catch let error as CalCoAPIError where error.isUnauthorized {
            return .unauthenticated(Self.unavailableReason(from: error.payload))
        }
    }

    public func login(username: String, password: String) async throws -> LoginSession {
        try await client.login(username: username, password: password)
    }

    public func logout() async throws {
        try await client.logout()
    }

    public func logout(sessionCookies: [HTTPCookie]) async throws {
        try await client.logout(sessionCookies: sessionCookies)
    }

    private static func unavailableReason(
        from payload: APIErrorPayload?
    ) -> SessionUnavailableReason {
        let code = payload?.code.lowercased() ?? ""
        if code.contains("expired") {
            return .expired
        }
        if code.contains("not_found") || code.contains("notfound") {
            return .notFound
        }
        return .signedOut
    }
}

public struct HostCookieSessionClearer: SessionCookieClearing {
    public static let defaultCookieName = "calco_session"

    public let cookieName: String

    private let storage: HTTPCookieStorage

    public init(
        cookieName: String = Self.defaultCookieName,
        storage: HTTPCookieStorage = .shared
    ) {
        let trimmed = cookieName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cookieName = trimmed.isEmpty ? Self.defaultCookieName : trimmed
        self.storage = storage
    }

    public func sessionCookies(for baseURL: URL) -> [HTTPCookie] {
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else {
            return []
        }

        let requestPath = Self.logoutRequestPath(for: baseURL)
        let allowsSecureCookies = baseURL.scheme?.lowercased() == "https"
        return (storage.cookies ?? []).filter {
            Self.shouldRevoke(
                $0,
                host: host,
                cookieName: cookieName,
                requestPath: requestPath,
                allowsSecureCookies: allowsSecureCookies
            )
        }
    }

    public func clearCookies(for baseURL: URL) {
        guard let host = baseURL.host?.lowercased(), !host.isEmpty else {
            return
        }

        let requestPaths = Self.authRequestPaths(for: baseURL)
        for cookie in storage.cookies ?? [] where Self.shouldClear(
            cookie,
            host: host,
            cookieName: cookieName,
            requestPaths: requestPaths
        ) {
            storage.deleteCookie(cookie)
        }
    }

    static func shouldRevoke(
        _ cookie: HTTPCookie,
        host: String,
        cookieName: String,
        requestPath: String,
        allowsSecureCookies: Bool
    ) -> Bool {
        guard cookie.name == cookieName,
              domainMatches(cookie.domain, host: host),
              !cookie.isSecure || allowsSecureCookies else {
            return false
        }
        return pathMatches(cookiePath: cookie.path, requestPath: requestPath)
    }

    static func shouldClear(
        _ cookie: HTTPCookie,
        host: String,
        cookieName: String,
        requestPaths: [String]
    ) -> Bool {
        guard cookie.name == cookieName,
              domainMatches(cookie.domain, host: host) else {
            return false
        }
        return requestPaths.contains {
            pathMatches(cookiePath: cookie.path, requestPath: $0)
        }
    }

    static func domainMatches(_ cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedHost = host.lowercased()
        guard !domain.isEmpty, !normalizedHost.isEmpty else { return false }
        return normalizedHost == domain || normalizedHost.hasSuffix("." + domain)
    }

    static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        var normalizedCookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if !normalizedCookiePath.hasPrefix("/") {
            normalizedCookiePath = "/" + normalizedCookiePath
        }

        var normalizedRequestPath = requestPath.isEmpty ? "/" : requestPath
        if !normalizedRequestPath.hasPrefix("/") {
            normalizedRequestPath = "/" + normalizedRequestPath
        }

        if normalizedCookiePath == "/" { return true }
        guard normalizedRequestPath.hasPrefix(normalizedCookiePath) else {
            return false
        }
        if normalizedRequestPath.count == normalizedCookiePath.count {
            return true
        }
        if normalizedCookiePath.hasSuffix("/") { return true }

        let boundary = normalizedRequestPath.index(
            normalizedRequestPath.startIndex,
            offsetBy: normalizedCookiePath.count
        )
        return normalizedRequestPath[boundary] == "/"
    }

    static func authRequestPaths(for baseURL: URL) -> [String] {
        let basePath = normalizedBasePath(for: baseURL)
        return [
            "/api/auth/bootstrap/status",
            "/api/auth/login",
            "/api/auth/session",
            "/api/auth/logout",
        ].map { basePath + $0 }
    }

    static func logoutRequestPath(for baseURL: URL) -> String {
        normalizedBasePath(for: baseURL) + "/api/auth/logout"
    }

    private static func normalizedBasePath(for baseURL: URL) -> String {
        var basePath = baseURL.path
        while basePath.count > 1 && basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        return basePath == "/" ? "" : basePath
    }
}

// MARK: - Coordinator

@MainActor
public final class SessionCoordinator: ObservableObject {
    // MARK: Public state vocabulary

    public enum Phase: Equatable, Sendable {
        case idle

        case restoring

        case signingIn

        case signedOut(SessionUnavailableReason)

        case signedIn(AuthUser)

        case unsupportedAccount(AuthUser)

        case restoreFailed(Failure)
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidCredentials
        case networkUnavailable
        case timedOut
        case cancelled
        case server(message: String)
        case unknown
    }

    public enum SignInResult: Equatable, Sendable {
        case signedIn(AuthUser)
        case rejectedUnsupportedRole(AuthUser)
        case failed(Failure)
    }

    public enum SignOutResult: Equatable, Sendable {
        case completed
        case completedWithServerFailure(Failure)
    }

    public typealias StateResetHandler = @MainActor () -> Void

    // MARK: Published state

    @Published public private(set) var phase: Phase = .idle

    public private(set) var sessionGeneration: UInt64 = 0

    // MARK: Dependencies and internals

    private let service: any SessionServicing
    private let cookieClearer: any SessionCookieClearing
    private let cookieBaseURL: URL
    private var stateResetHandlers: [UUID: StateResetHandler] = [:]

    private var operationBarrier: Task<Void, Never>?

    // MARK: Init

    public init(
        service: any SessionServicing,
        cookieBaseURL: URL,
        cookieClearer: any SessionCookieClearing = HostCookieSessionClearer()
    ) {
        self.service = service
        self.cookieBaseURL = cookieBaseURL
        self.cookieClearer = cookieClearer
    }

    public convenience init(
        client: CalCoAPIClient,
        cookieClearer: any SessionCookieClearing = HostCookieSessionClearer()
    ) {
        self.init(
            service: CalCoSessionService(client: client),
            cookieBaseURL: client.configuration.baseURL,
            cookieClearer: cookieClearer
        )
    }

    // MARK: Inspection

    public var signedInUser: AuthUser? {
        guard case .signedIn(let user) = phase else { return nil }
        return user
    }

    public var unsupportedAccount: AuthUser? {
        guard case .unsupportedAccount(let user) = phase else { return nil }
        return user
    }

    public var isSignedIn: Bool { signedInUser != nil }
    public var isRestoring: Bool { phase == .restoring }
    public var isSigningIn: Bool { phase == .signingIn }

    // MARK: Feature-state reset registration

    @discardableResult
    public func registerSessionStateReset(
        _ handler: @escaping StateResetHandler
    ) -> UUID {
        let id = UUID()
        stateResetHandlers[id] = handler
        return id
    }

    public func unregisterSessionStateReset(_ id: UUID) {
        stateResetHandlers.removeValue(forKey: id)
    }

    // MARK: Lifecycle

    @discardableResult
    public func start() async -> Phase {
        guard phase == .idle else { return phase }
        return await restore()
    }

    @discardableResult
    public func restore() async -> Phase {
        let generation = beginTransition(to: .restoring)

        let result: RestoreOperationResult = await enqueue { [service] in
            do {
                return .success(try await service.restoreSession())
            } catch {
                return Self.restoreResult(from: error)
            }
        }

        guard generation == sessionGeneration else {
            return phase
        }

        switch result {
        case .success(.authenticated(let session)):
            let user = Self.authUser(from: session)
            switch user.role {
            case .user:
                phase = .signedIn(user)

            case .admin, .other:
                cookieClearer.clearCookies(for: cookieBaseURL)
                phase = .unsupportedAccount(user)
            }

        case .success(.unauthenticated(let reason)):
            cookieClearer.clearCookies(for: cookieBaseURL)
            phase = .signedOut(reason)

        case .unauthorized(let reason):
            cookieClearer.clearCookies(for: cookieBaseURL)
            phase = .signedOut(reason)

        case .failure(let failure):
            phase = .restoreFailed(failure)
        }

        return phase
    }

    public func signIn(username: String, password: String) async -> SignInResult {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            return .failed(.invalidCredentials)
        }

        let generation = beginTransition(to: .signingIn)

        let result: SignInOperationResult = await enqueue {
            [service, cookieClearer, cookieBaseURL] in
            cookieClearer.clearCookies(for: cookieBaseURL)

            do {
                return .success(
                    try await service.login(
                        username: trimmedUsername,
                        password: password
                    )
                )
            } catch {
                return .failure(Self.failure(from: error))
            }
        }

        guard generation == sessionGeneration else {
            return .failed(.cancelled)
        }

        switch result {
        case .success(let session):
            let user = Self.authUser(from: session)
            switch user.role {
            case .user:
                phase = .signedIn(user)
                return .signedIn(user)

            case .admin, .other:
                cookieClearer.clearCookies(for: cookieBaseURL)
                phase = .unsupportedAccount(user)
                return .rejectedUnsupportedRole(user)
            }

        case .failure(let failure):
            cookieClearer.clearCookies(for: cookieBaseURL)
            phase = .signedOut(.signedOut)
            return .failed(failure)
        }
    }

    @discardableResult
    public func signOut() async -> SignOutResult {
        let initialCookies = cookieClearer.sessionCookies(for: cookieBaseURL)

        sessionGeneration &+= 1
        resetFeatureState()
        cookieClearer.clearCookies(for: cookieBaseURL)
        phase = .signedOut(.signedOut)

        let result: OperationResult<Void> = await enqueue {
            [service, cookieClearer, cookieBaseURL, initialCookies] in
            let queuedCookies = cookieClearer.sessionCookies(for: cookieBaseURL)
            if !queuedCookies.isEmpty {
                cookieClearer.clearCookies(for: cookieBaseURL)
            }
            let revocationCookies = queuedCookies.isEmpty
                ? initialCookies
                : queuedCookies

            defer {
                if !cookieClearer.sessionCookies(for: cookieBaseURL).isEmpty {
                    cookieClearer.clearCookies(for: cookieBaseURL)
                }
            }

            do {
                try await service.logout(sessionCookies: revocationCookies)
                return .success(())
            } catch {
                return .failure(Self.failure(from: error))
            }
        }

        switch result {
        case .success:
            return .completed
        case .failure(let failure):
            return .completedWithServerFailure(failure)
        }
    }

    @discardableResult
    public func handleUnauthorized(
        atGeneration generation: UInt64? = nil,
        reason: SessionUnavailableReason = .expired
    ) -> Bool {
        if let generation, generation != sessionGeneration {
            return false
        }

        sessionGeneration &+= 1
        resetFeatureState()
        cookieClearer.clearCookies(for: cookieBaseURL)
        scheduleCookieClearAfterQueuedOperations()
        phase = .signedOut(reason)
        return true
    }

    public func dismissUnsupportedAccount() {
        guard case .unsupportedAccount = phase else { return }
        phase = .signedOut(.signedOut)
    }

    // MARK: Internals

    private enum OperationResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(Failure)
    }

    private enum RestoreOperationResult: Sendable {
        case success(SessionRestoreOutcome)
        case unauthorized(SessionUnavailableReason)
        case failure(Failure)
    }

    private enum SignInOperationResult: Sendable {
        case success(LoginSession)
        case failure(Failure)
    }

    private func beginTransition(to next: Phase) -> UInt64 {
        sessionGeneration &+= 1
        resetFeatureState()
        phase = next
        return sessionGeneration
    }

    private func resetFeatureState() {
        let handlers = Array(stateResetHandlers.values)
        for handler in handlers {
            handler()
        }
    }

    private func enqueue<Value: Sendable>(
        _ operation: @escaping @MainActor () async -> Value
    ) async -> Value {
        let previous = operationBarrier
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        operationBarrier = Task { @MainActor in
            _ = await task.value
        }
        return await task.value
    }

    private func scheduleCookieClearAfterQueuedOperations() {
        let previous = operationBarrier
        let task = Task { @MainActor [cookieClearer, cookieBaseURL] in
            await previous?.value
            cookieClearer.clearCookies(for: cookieBaseURL)
        }
        operationBarrier = Task { @MainActor in
            await task.value
        }
    }

    // MARK: Mapping

    private static func authUser(from session: LoginSession) -> AuthUser {
        AuthUser(
            id: session.identity.id,
            username: session.identity.username,
            role: authRole(from: session.identity.role),
            displayName: session.profile?.displayName
        )
    }

    private static func authRole(from role: IdentityRole) -> AuthRole {
        switch role {
        case .user: return .user
        case .admin: return .admin
        case .other: return .other
        }
    }

    private static func restoreResult(from error: Error) -> RestoreOperationResult {
        if let apiError = error as? CalCoAPIError, apiError.isUnauthorized {
            return .unauthorized(unavailableReason(from: apiError.payload))
        }

        let failure = failure(from: error)
        if failure == .invalidCredentials {
            return .unauthorized(.expired)
        }
        return .failure(failure)
    }

    private static func failure(from error: Error) -> Failure {
        if let failure = error as? Failure {
            return failure
        }

        if let authError = error as? AuthFeatureError {
            switch authError {
            case .invalidCredentials:
                return .invalidCredentials
            case .networkUnavailable:
                return .networkUnavailable
            case .server(let message):
                return .server(message: message)
            case .unknown:
                return .unknown
            }
        }

        guard let apiError = error as? CalCoAPIError else {
            return .unknown
        }

        switch apiError {
        case .unauthorized(let payload):
            if apiError.isInvalidCredentials {
                return .invalidCredentials
            }
            if let message = nonEmpty(payload?.message) {
                return .server(message: message)
            }
            return .invalidCredentials

        case .network:
            return .networkUnavailable

        case .timeout:
            return .timedOut

        case .cancelled:
            return .cancelled

        case .rateLimited:
            return .server(
                message: "Too many attempts. Please try again later."
            )

        case .badStatus(_, let payload):
            return .server(
                message: nonEmpty(payload.message)
                    ?? "The server could not complete the request."
            )

        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return .unknown
        }
    }

    private static func unavailableReason(
        from payload: APIErrorPayload?
    ) -> SessionUnavailableReason {
        let code = payload?.code.lowercased() ?? ""
        if code.contains("expired") {
            return .expired
        }
        if code.contains("not_found") || code.contains("notfound") {
            return .notFound
        }
        return .signedOut
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
