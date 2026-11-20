import XCTest

@testable import CalCo

// SessionCoordinator owns app-level session decisions. These tests use narrow
// in-memory fakes: no URLSession, database, keyring, or real credentials.

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!


    private final class FakeSessionService: SessionServicing, @unchecked Sendable {
        typealias RestoreHandler = @Sendable () async throws -> SessionRestoreOutcome
        typealias LoginHandler =
            @Sendable (_ username: String, _ password: String) async throws -> LoginSession
        typealias LogoutHandler = @Sendable () async throws -> Void

        private let lock = NSLock()
        private var restoreHandler: RestoreHandler
        private var loginHandler: LoginHandler
        private var logoutHandler: LogoutHandler
        private var restoreCallCount = 0
        private var loginCallCount = 0
        private var logoutCallCount = 0
        private var recordedCredentials: [(String, String)] = []
        private var recordedLogoutCookies: [[HTTPCookie]] = []

        init(
            restore: @escaping RestoreHandler = { .unauthenticated(.signedOut) },
            login: @escaping LoginHandler = { _, _ in
                throw CalCoAPIError.unauthorized(nil)
            },
            logout: @escaping LogoutHandler = {}
        ) {
            self.restoreHandler = restore
            self.loginHandler = login
            self.logoutHandler = logout
        }

        var restoreCalls: Int { lock.withLock { restoreCallCount } }
        var loginCalls: Int { lock.withLock { loginCallCount } }
        var logoutCalls: Int { lock.withLock { logoutCallCount } }
        var credentials: [(String, String)] { lock.withLock { recordedCredentials } }
        var logoutCookieRecords: [[HTTPCookie]] {
            lock.withLock { recordedLogoutCookies }
        }

        func setRestoreHandler(_ handler: @escaping RestoreHandler) {
            lock.withLock { restoreHandler = handler }
        }

        func setLoginHandler(_ handler: @escaping LoginHandler) {
            lock.withLock { loginHandler = handler }
        }

        func setLogoutHandler(_ handler: @escaping LogoutHandler) {
            lock.withLock { logoutHandler = handler }
        }

        func restoreSession() async throws -> SessionRestoreOutcome {
            let handler = lock.withLock {
                restoreCallCount += 1
                return restoreHandler
            }
            return try await handler()
        }

        func login(username: String, password: String) async throws -> LoginSession {
            let handler = lock.withLock {
                loginCallCount += 1
                recordedCredentials.append((username, password))
                return loginHandler
            }
            return try await handler(username, password)
        }

        func logout() async throws {
            let handler = lock.withLock {
                logoutCallCount += 1
                return logoutHandler
            }
            try await handler()
        }

        func logout(sessionCookies: [HTTPCookie]) async throws {
            let handler = lock.withLock {
                logoutCallCount += 1
                recordedLogoutCookies.append(sessionCookies)
                return logoutHandler
            }
            try await handler()
        }
    }

    private final class RecordingCookieClearer: SessionCookieClearing, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        private var cookies: [HTTPCookie] = []

        func sessionCookies(for baseURL: URL) -> [HTTPCookie] {
            lock.withLock { cookies }
        }

        func setCookies(_ cookies: [HTTPCookie]) {
            lock.withLock { self.cookies = cookies }
        }

        func clearCookies(for baseURL: URL) {
            lock.withLock {
                storage.append(baseURL)
                cookies.removeAll()
            }
        }

        var calls: [URL] { lock.withLock { storage } }
        var count: Int { lock.withLock { storage.count } }
    }

    private final class ResetRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.withLock { count += 1 }
        }

        var resets: Int { lock.withLock { count } }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fire() {
            fired = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }


    private func makeSession(
        id: String = "identity-1",
        username: String = "tester",
        role: IdentityRole = .user,
        displayName: String? = "Test User"
    ) -> LoginSession {
        LoginSession(
            identity: AuthIdentity(id: id, username: username, role: role),
            profile: displayName.map {
                AuthProfile(id: "profile-\(id)", displayName: $0)
            }
        )
    }

    private func expectedUser(from session: LoginSession) -> AuthUser {
        let role: AuthRole
        switch session.identity.role {
        case .user: role = .user
        case .admin: role = .admin
        case .other: role = .other
        }
        return AuthUser(
            id: session.identity.id,
            username: session.identity.username,
            role: role,
            displayName: session.profile?.displayName,
            profileID: session.profile?.id
        )
    }

    private func makeCoordinator(
        service: FakeSessionService,
        cookies: RecordingCookieClearer
    ) -> SessionCoordinator {
        SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: cookies
        )
    }

    private func makeCookieStorage() throws -> HTTPCookieStorage {
        let configuration = URLSessionConfiguration.ephemeral
        guard let storage = configuration.httpCookieStorage else {
            throw NSError(
                domain: "CalCoTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ephemeral URLSessionConfiguration has no HTTPCookieStorage"]
            )
        }
        return storage
    }

    private func setCookie(
        name: String = HostCookieSessionClearer.defaultCookieName,
        value: String = "token",
        domain: String,
        path: String = "/",
        in storage: HTTPCookieStorage
    ) {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .expires: Date().addingTimeInterval(3_600),
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            return XCTFail("Could not construct test cookie \(name)@\(domain)\(path)")
        }
        storage.setCookie(cookie)
    }

    private func cookieDescriptions(in storage: HTTPCookieStorage) -> [String] {
        (storage.cookies ?? [])
            .map { "\($0.domain)|\($0.path)|\($0.name)" }
            .sorted()
    }

    private func hasSessionCookie(
        domain: String? = nil,
        in storage: HTTPCookieStorage
    ) -> Bool {
        (storage.cookies ?? []).contains {
            $0.name == HostCookieSessionClearer.defaultCookieName
                && (domain == nil || $0.domain == domain)
        }
    }

    private final class CookieStorageBox: @unchecked Sendable {
        let storage: HTTPCookieStorage

        init(_ storage: HTTPCookieStorage) {
            self.storage = storage
        }

        var hasSessionCookie: Bool {
            (storage.cookies ?? []).contains {
                $0.name == HostCookieSessionClearer.defaultCookieName
            }
        }

        func setSessionCookie(domain: String, value: String) {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: HostCookieSessionClearer.defaultCookieName,
                .value: value,
                .domain: domain,
                .path: "/",
                .expires: Date().addingTimeInterval(3_600),
            ]
            guard let cookie = HTTPCookie(properties: properties) else { return }
            storage.setCookie(cookie)
        }
    }


    func testCookieDomainMatchingIsHostScopedAndRejectsLookalikes() {
        XCTAssertTrue(
            HostCookieSessionClearer.domainMatches(".example.com", host: "api.example.com")
        )
        XCTAssertTrue(
            HostCookieSessionClearer.domainMatches("example.com", host: "api.example.com")
        )
        XCTAssertTrue(
            HostCookieSessionClearer.domainMatches("api.example.com", host: "api.example.com")
        )
        XCTAssertTrue(
            HostCookieSessionClearer.domainMatches("127.0.0.1", host: "127.0.0.1")
        )
        XCTAssertFalse(
            HostCookieSessionClearer.domainMatches("evil-example.com", host: "api.example.com")
        )
        XCTAssertFalse(
            HostCookieSessionClearer.domainMatches("example.com", host: "notexample.com")
        )
        XCTAssertFalse(
            HostCookieSessionClearer.domainMatches("other.example.com", host: "api.example.com")
        )
    }

    func testHostCookieClearerRemovesOnlyCalCoSessionCookiesForHostAndAuthPaths() throws {
        let storage = try makeCookieStorage()
        setCookie(domain: "api.example.com", path: "/", in: storage)
        setCookie(domain: ".example.com", path: "/", in: storage)
        setCookie(domain: "api.example.com", path: "/api/auth", in: storage)
        setCookie(domain: "api.example.com", path: "/admin", in: storage)
        setCookie(name: "theme", domain: "api.example.com", path: "/", in: storage)
        setCookie(name: "sibling_theme", domain: ".example.com", path: "/", in: storage)
        setCookie(domain: "sibling.example.com", path: "/", in: storage)
        setCookie(domain: "notexample.com", path: "/", in: storage)

        HostCookieSessionClearer(storage: storage)
            .clearCookies(for: URL(string: "https://api.example.com")!)

        XCTAssertEqual(cookieDescriptions(in: storage), [
            ".example.com|/|sibling_theme",
            "api.example.com|/|theme",
            "api.example.com|/admin|calco_session",
            "notexample.com|/|calco_session",
            "sibling.example.com|/|calco_session",
        ].sorted())
    }

    func testHostCookieClearerRespectsConfiguredNameAndBasePathPrefix() throws {
        let storage = try makeCookieStorage()
        setCookie(name: "custom_session", domain: "api.example.com", path: "/calco", in: storage)
        setCookie(
            name: "custom_session",
            domain: "api.example.com",
            path: "/calco/api/auth",
            in: storage
        )
        setCookie(
            name: "custom_session",
            domain: "api.example.com",
            path: "/other",
            in: storage
        )
        setCookie(domain: "api.example.com", path: "/", in: storage)

        HostCookieSessionClearer(cookieName: "custom_session", storage: storage)
            .clearCookies(for: URL(string: "https://api.example.com/calco")!)

        XCTAssertEqual(cookieDescriptions(in: storage), [
            "api.example.com|/|calco_session",
            "api.example.com|/other|custom_session",
        ].sorted())
    }

    func testSessionCookieSnapshotIsScopedToTheLogoutRequest() throws {
        let storage = try makeCookieStorage()
        setCookie(value: "live-token", domain: "calco.example.com", path: "/", in: storage)
        setCookie(value: "admin-token", domain: "calco.example.com", path: "/admin", in: storage)
        setCookie(name: "theme", domain: "calco.example.com", path: "/", in: storage)
        setCookie(domain: "sibling.example.com", path: "/", in: storage)

        let snapshot = HostCookieSessionClearer(storage: storage)
            .sessionCookies(for: URL(string: "https://calco.example.com")!)

        XCTAssertEqual(snapshot.map(\.name), [HostCookieSessionClearer.defaultCookieName])
        XCTAssertEqual(snapshot.map(\.domain), ["calco.example.com"])
        XCTAssertEqual(storage.cookies?.count, 4, "Snapshotting must not mutate cookie storage")
    }

    func testSessionCookieSnapshotDoesNotSendSecureCookieOverHTTP() throws {
        let storage = try makeCookieStorage()
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: HostCookieSessionClearer.defaultCookieName,
            .value: "secure-token",
            .domain: "calco.example.com",
            .path: "/",
            .secure: true,
            .expires: Date().addingTimeInterval(3_600),
        ]
        storage.setCookie(try XCTUnwrap(HTTPCookie(properties: properties)))
        let clearer = HostCookieSessionClearer(storage: storage)

        XCTAssertTrue(
            clearer.sessionCookies(for: URL(string: "http://calco.example.com")!).isEmpty
        )
        XCTAssertEqual(
            clearer.sessionCookies(for: URL(string: "https://calco.example.com")!).count,
            1
        )
    }

    func testCookiePathMatchingUsesPathBoundaries() {
        XCTAssertTrue(HostCookieSessionClearer.pathMatches(cookiePath: "/", requestPath: "/api/auth/login"))
        XCTAssertTrue(
            HostCookieSessionClearer.pathMatches(
                cookiePath: "/calco",
                requestPath: "/calco/api/auth/login"
            )
        )
        XCTAssertFalse(
            HostCookieSessionClearer.pathMatches(
                cookiePath: "/cal",
                requestPath: "/calco/api/auth/login"
            )
        )
        XCTAssertFalse(
            HostCookieSessionClearer.pathMatches(
                cookiePath: "/api/auth",
                requestPath: "/administrator"
            )
        )
    }


    func testStartRestoresRegularUserOnlyOnce() async {
        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        await coordinator.start()
        await coordinator.start()

        XCTAssertEqual(coordinator.phase, .signedIn(expectedUser(from: session)))
        XCTAssertEqual(coordinator.signedInUser, expectedUser(from: session))
        XCTAssertTrue(coordinator.isSignedIn)
        XCTAssertEqual(service.restoreCalls, 1)
        XCTAssertEqual(cookies.count, 0, "A successful restore must keep the cookie")
    }

    func testRestoreRejectsAdminAndUnrecognizedRolesAndClearsCookies() async {
        for (role, expectedRole) in [
            (IdentityRole.admin, AuthRole.admin),
            (IdentityRole.other, AuthRole.other),
        ] {
            let session = makeSession(username: "unsupported", role: role)
            let service = FakeSessionService(restore: { .authenticated(session) })
            let cookies = RecordingCookieClearer()
            let coordinator = makeCoordinator(service: service, cookies: cookies)

            await coordinator.restore()

            guard case .unsupportedAccount(let user) = coordinator.phase else {
                return XCTFail("Expected an unsupported account for \(role)")
            }
            XCTAssertEqual(user.role, expectedRole)
            XCTAssertNil(coordinator.signedInUser)
            XCTAssertFalse(coordinator.isSignedIn)
            XCTAssertEqual(cookies.calls, [baseURL])

            coordinator.dismissUnsupportedAccount()
            XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        }
    }

    func testRestoreUnauthorizedReportsReasonAndClearsFeatureStateAndCookies() async {
        for (reason, expected) in [
            (SessionUnavailableReason.expired, SessionUnavailableReason.expired),
            (.notFound, .notFound),
            (.signedOut, .signedOut),
        ] {
            let reset = ResetRecorder()
            let service = FakeSessionService(restore: { .unauthenticated(reason) })
            let cookies = RecordingCookieClearer()
            let coordinator = makeCoordinator(service: service, cookies: cookies)
            coordinator.registerSessionStateReset { reset.record() }

            await coordinator.restore()

            XCTAssertEqual(coordinator.phase, .signedOut(expected))
            XCTAssertEqual(reset.resets, 1)
            XCTAssertEqual(cookies.calls, [baseURL])
        }
    }

    func testRestoreNetworkFailureIsNotSignedOutAndClearsPreviousPrivateData() async {
        let session = makeSession()
        let reset = ResetRecorder()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)
        coordinator.registerSessionStateReset { reset.record() }

        await coordinator.restore()
        XCTAssertTrue(coordinator.isSignedIn)
        XCTAssertEqual(reset.resets, 1)

        service.setRestoreHandler { throw CalCoAPIError.network("offline") }
        await coordinator.restore()

        guard case .restoreFailed(.networkUnavailable) = coordinator.phase else {
            return XCTFail("A transport failure must not become signedOut")
        }
        XCTAssertNil(coordinator.signedInUser)
        XCTAssertFalse(coordinator.isSignedIn)
        XCTAssertEqual(reset.resets, 2, "The previous user's feature data must be cleared")
        XCTAssertEqual(cookies.count, 0, "Transport failure does not prove the cookie is invalid")
    }

    func testRestoreTypedTransportAndServerFailuresStayDistinct() async {
        let cases: [(CalCoAPIError, SessionCoordinator.Failure)] = [
            (.timeout, .timedOut),
            (
                .badStatus(
                    statusCode: 503,
                    payload: APIErrorPayload(code: "unavailable", message: "Maintenance")
                ),
                .server(message: "Maintenance")
            ),
        ]

        for (error, expected) in cases {
            let service = FakeSessionService(restore: { throw error })
            let cookies = RecordingCookieClearer()
            let coordinator = makeCoordinator(service: service, cookies: cookies)

            await coordinator.restore()

            XCTAssertEqual(coordinator.phase, .restoreFailed(expected))
            XCTAssertFalse(coordinator.isSignedIn)
            XCTAssertEqual(cookies.count, 0)
        }
    }


    func testLoginRegularUserUsesCookieLoginAndEntersApp() async {
        let session = makeSession()
        let service = FakeSessionService(login: { _, _ in session })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        let result = await coordinator.signIn(
            username: "  tester \n",
            password: " s3cret "
        )

        XCTAssertEqual(result, .signedIn(expectedUser(from: session)))
        XCTAssertEqual(coordinator.phase, .signedIn(expectedUser(from: session)))
        XCTAssertEqual(service.credentials.count, 1)
        XCTAssertEqual(service.credentials.first?.0, "tester")
        XCTAssertEqual(service.credentials.first?.1, " s3cret ")
        XCTAssertEqual(cookies.calls, [baseURL], "The login should start from a clean cookie jar")
        XCTAssertEqual(coordinator.sessionGeneration, 1)
    }

    func testLoginRejectsAdminAndUnrecognizedRolesWithoutEnteringApp() async {
        for (role, expectedRole) in [
            (IdentityRole.admin, AuthRole.admin),
            (IdentityRole.other, AuthRole.other),
        ] {
            let session = makeSession(username: "unsupported", role: role)
            let service = FakeSessionService(login: { _, _ in session })
            let cookies = RecordingCookieClearer()
            let coordinator = makeCoordinator(service: service, cookies: cookies)

            let result = await coordinator.signIn(username: "unsupported", password: "pw")

            XCTAssertEqual(
                result,
                .rejectedUnsupportedRole(expectedUser(from: session))
            )
            guard case .unsupportedAccount(let user) = coordinator.phase else {
                return XCTFail("Expected an unsupported account for \(role)")
            }
            XCTAssertEqual(user.role, expectedRole)
            XCTAssertNil(coordinator.signedInUser)
            XCTAssertEqual(cookies.count, 2, "Pre-login cleanup plus rejected-role cleanup")
        }
    }

    func testLoginInvalidCredentialsLeavesSignedOutAndClearsCookies() async {
        let service = FakeSessionService(login: { _, _ in
            throw CalCoAPIError.unauthorized(
                APIErrorPayload(code: "invalid_credentials", message: "Wrong username or password")
            )
        })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        let result = await coordinator.signIn(username: "tester", password: "wrong")

        XCTAssertEqual(result, .failed(.invalidCredentials))
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertNil(coordinator.signedInUser)
        XCTAssertEqual(cookies.count, 2)
    }

    func testLoginTransportFailureIsTypedAndLeavesSignedOut() async {
        let service = FakeSessionService(login: { _, _ in
            throw CalCoAPIError.network("offline")
        })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        let result = await coordinator.signIn(username: "tester", password: "pw")

        XCTAssertEqual(result, .failed(.networkUnavailable))
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertFalse(coordinator.isSignedIn)
        XCTAssertEqual(cookies.count, 2)
    }


    func testSignOutClearsLocalSessionEvenWhenServerLogoutFails() async {
        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let cookies = RecordingCookieClearer()
        let reset = ResetRecorder()
        let coordinator = makeCoordinator(service: service, cookies: cookies)
        coordinator.registerSessionStateReset { reset.record() }

        await coordinator.restore()
        service.setLogoutHandler {
            throw CalCoAPIError.badStatus(
                statusCode: 500,
                payload: APIErrorPayload(code: "server_error", message: "offline")
            )
        }

        let result = await coordinator.signOut()

        XCTAssertEqual(
            result,
            .completedWithServerFailure(.server(message: "offline"))
        )
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertNil(coordinator.signedInUser)
        XCTAssertEqual(reset.resets, 2, "Restore start plus sign-out must clear feature state")
        XCTAssertEqual(service.logoutCalls, 1)
        XCTAssertEqual(cookies.calls, [baseURL], "Cookies are cleared even after failure")
    }

    func testSignOutSuccessClearsCookiesByHost() async {
        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        await coordinator.restore()
        let result = await coordinator.signOut()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertEqual(cookies.calls, [baseURL])
        XCTAssertEqual(service.logoutCalls, 1)
    }

    func testCustomClearerMustSnapshotBeforeClearingForRevocation() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: HostCookieSessionClearer.defaultCookieName,
            .value: "snapshot-value",
            .domain: "calco.example.com",
            .path: "/",
        ]))
        let cookies = RecordingCookieClearer()
        cookies.setCookies([cookie])
        let service = FakeSessionService()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        let result = await coordinator.signOut()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(cookies.calls, [baseURL])
        XCTAssertEqual(service.logoutCookieRecords.last?.map(\.value), ["snapshot-value"])
        XCTAssertTrue(cookies.sessionCookies(for: baseURL).isEmpty)
    }

    func testSignOutWithRealCookieStorageClearsOnlyCalCoCookieOnServerFailure() async throws {
        let storage = try makeCookieStorage()
        setCookie(domain: "calco.example.com", path: "/", in: storage)
        setCookie(name: "theme", domain: "calco.example.com", path: "/", in: storage)
        setCookie(domain: "sibling.example.com", path: "/", in: storage)

        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        await coordinator.restore()
        XCTAssertEqual(cookieDescriptions(in: storage), [
            "calco.example.com|/|calco_session",
            "calco.example.com|/|theme",
            "sibling.example.com|/|calco_session",
        ].sorted())

        service.setLogoutHandler { throw CalCoAPIError.network("offline") }
        let result = await coordinator.signOut()

        XCTAssertEqual(result, .completedWithServerFailure(.networkUnavailable))
        XCTAssertEqual(cookieDescriptions(in: storage), [
            "calco.example.com|/|theme",
            "sibling.example.com|/|calco_session",
        ].sorted())
    }

    func testSignOutClearsSessionCookieBeforeStalledLogoutCompletes() async throws {
        let storage = try makeCookieStorage()
        setCookie(value: "live-token", domain: "calco.example.com", path: "/", in: storage)
        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        await coordinator.restore()
        XCTAssertTrue(hasSessionCookie(in: storage))

        let logoutEntered = Signal()
        let logoutGate = Gate()
        service.setLogoutHandler {
            await logoutEntered.fire()
            await logoutGate.wait()
        }

        let signOutTask = Task { await coordinator.signOut() }
        await logoutEntered.wait()

        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertFalse(hasSessionCookie(in: storage))
        XCTAssertEqual(service.logoutCookieRecords.count, 1)

        await logoutGate.open()
        let result = await signOutTask.value
        XCTAssertEqual(result, .completed)
    }

    func testForceQuitDuringStalledSignOutCannotRestoreSession() async throws {
        let storage = try makeCookieStorage()
        setCookie(value: "live-token", domain: "calco.example.com", path: "/", in: storage)
        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        await coordinator.restore()
        XCTAssertTrue(coordinator.isSignedIn)

        let logoutEntered = Signal()
        let logoutGate = Gate()
        service.setLogoutHandler {
            await logoutEntered.fire()
            await logoutGate.wait()
        }

        let signOutTask = Task { await coordinator.signOut() }
        await logoutEntered.wait()
        XCTAssertFalse(hasSessionCookie(in: storage))

        let box = CookieStorageBox(storage)
        let relaunchedService = FakeSessionService(restore: {
            box.hasSessionCookie
                ? .authenticated(session)
                : .unauthenticated(.signedOut)
        })
        let relaunched = SessionCoordinator(
            service: relaunchedService,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )
        await relaunched.start()

        XCTAssertEqual(relaunched.phase, .signedOut(.signedOut))
        XCTAssertNil(relaunched.signedInUser)

        await logoutGate.open()
        _ = await signOutTask.value
    }

    func testSignOutRevokesSnapshotCookieAfterSynchronousLocalClear() async throws {
        let storage = try makeCookieStorage()
        setCookie(value: "live-token", domain: "calco.example.com", path: "/", in: storage)
        setCookie(name: "theme", domain: "calco.example.com", path: "/", in: storage)
        setCookie(domain: "sibling.example.com", path: "/", in: storage)
        let service = FakeSessionService()
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        let result = await coordinator.signOut()

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(hasSessionCookie(domain: "calco.example.com", in: storage))
        let revoked = try XCTUnwrap(service.logoutCookieRecords.last)
        XCTAssertEqual(revoked.map(\.name), [HostCookieSessionClearer.defaultCookieName])
        XCTAssertEqual(revoked.map(\.domain), ["calco.example.com"])
        XCTAssertEqual(cookieDescriptions(in: storage), [
            "calco.example.com|/|theme",
            "sibling.example.com|/|calco_session",
        ].sorted())
    }

    func testStaleLoginResponseCannotReauthenticateAfterSignOut() async throws {
        let storage = try makeCookieStorage()
        let box = CookieStorageBox(storage)
        let oldSession = makeSession(id: "identity-old", username: "old")
        let loginEntered = Signal()
        let loginGate = Gate()
        let service = FakeSessionService(login: { _, _ in
            await loginEntered.fire()
            await loginGate.wait()
            box.setSessionCookie(domain: "calco.example.com", value: "old-session-token")
            return oldSession
        })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        let loginTask = Task {
            await coordinator.signIn(username: "old", password: "pw")
        }
        await loginEntered.wait()
        XCTAssertEqual(coordinator.phase, .signingIn)

        let signOutTask = Task { await coordinator.signOut() }
        for _ in 0..<100 where coordinator.phase != .signedOut(.signedOut) {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertFalse(hasSessionCookie(in: storage))

        await loginGate.open()
        let loginResult = await loginTask.value
        let signOutResult = await signOutTask.value

        XCTAssertEqual(loginResult, .failed(.cancelled))
        XCTAssertEqual(signOutResult, .completed)
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertFalse(hasSessionCookie(in: storage))
        XCTAssertEqual(
            service.logoutCookieRecords.last?.map(\.name),
            [HostCookieSessionClearer.defaultCookieName]
        )

        let relaunchedService = FakeSessionService(restore: {
            box.hasSessionCookie
                ? .authenticated(oldSession)
                : .unauthenticated(.signedOut)
        })
        let relaunched = SessionCoordinator(
            service: relaunchedService,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )
        await relaunched.start()

        XCTAssertEqual(relaunched.phase, .signedOut(.signedOut))
        XCTAssertNil(relaunched.signedInUser)
    }


    func testUnauthorizedFromAnyScreenInvalidatesSessionAndClearsFeatureState() async {
        let session = makeSession()
        let service = FakeSessionService(restore: { .authenticated(session) })
        let cookies = RecordingCookieClearer()
        let reset = ResetRecorder()
        let coordinator = makeCoordinator(service: service, cookies: cookies)
        coordinator.registerSessionStateReset { reset.record() }

        await coordinator.restore()
        let generation = coordinator.sessionGeneration

        let didInvalidate = coordinator.handleUnauthorized(
            atGeneration: generation,
            reason: .expired
        )

        XCTAssertTrue(didInvalidate)
        XCTAssertEqual(coordinator.phase, .signedOut(.expired))
        XCTAssertNil(coordinator.signedInUser)
        XCTAssertEqual(reset.resets, 2)
        XCTAssertEqual(cookies.calls, [baseURL])
    }

    func testStaleUnauthorizedDoesNotExpireANewerSession() async {
        let first = makeSession(id: "identity-1", username: "first")
        let second = makeSession(id: "identity-2", username: "second")
        let service = FakeSessionService(restore: { .authenticated(first) })
        let cookies = RecordingCookieClearer()
        let reset = ResetRecorder()
        let coordinator = makeCoordinator(service: service, cookies: cookies)
        coordinator.registerSessionStateReset { reset.record() }

        await coordinator.restore()
        let staleGeneration = coordinator.sessionGeneration

        service.setLoginHandler { _, _ in second }
        let result = await coordinator.signIn(username: "second", password: "pw")
        XCTAssertEqual(result, .signedIn(expectedUser(from: second)))
        let resetsAfterLogin = reset.resets

        let didInvalidate = coordinator.handleUnauthorized(atGeneration: staleGeneration)

        XCTAssertFalse(didInvalidate)
        XCTAssertEqual(coordinator.phase, .signedIn(expectedUser(from: second)))
        XCTAssertEqual(coordinator.signedInUser, expectedUser(from: second))
        XCTAssertEqual(reset.resets, resetsAfterLogin)
    }

    func testStaleRestoreResponseCannotOverwriteNewerInvalidation() async {
        let session = makeSession()
        let entered = Signal()
        let gate = Gate()
        let service = FakeSessionService(restore: {
            await entered.fire()
            await gate.wait()
            return .authenticated(session)
        })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        let restoreTask = Task { await coordinator.restore() }
        await entered.wait()
        XCTAssertEqual(coordinator.phase, .restoring)

        XCTAssertTrue(coordinator.handleUnauthorized(reason: .expired))
        await gate.open()
        let returnedPhase = await restoreTask.value

        XCTAssertEqual(returnedPhase, .signedOut(.expired))
        XCTAssertEqual(coordinator.phase, .signedOut(.expired))
        XCTAssertNil(coordinator.signedInUser)
    }

    func testStaleLoginResponseCannotReauthenticateAfterInvalidation() async {
        let session = makeSession()
        let entered = Signal()
        let gate = Gate()
        let service = FakeSessionService(login: { _, _ in
            await entered.fire()
            await gate.wait()
            return session
        })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        let loginTask = Task {
            await coordinator.signIn(username: "tester", password: "pw")
        }
        await entered.wait()
        XCTAssertEqual(coordinator.phase, .signingIn)

        XCTAssertTrue(coordinator.handleUnauthorized(reason: .expired))
        await gate.open()
        let result = await loginTask.value

        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertEqual(coordinator.phase, .signedOut(.expired))
        XCTAssertNil(coordinator.signedInUser)
    }

    func testSignInWaitsForPendingSignOutAndIsNotClearedByIt() async {
        let first = makeSession(id: "identity-1", username: "first")
        let second = makeSession(id: "identity-2", username: "second")
        let logoutEntered = Signal()
        let logoutGate = Gate()
        let service = FakeSessionService(login: { _, _ in first })
        let cookies = RecordingCookieClearer()
        let coordinator = makeCoordinator(service: service, cookies: cookies)

        _ = await coordinator.signIn(username: "first", password: "pw")
        XCTAssertTrue(coordinator.isSignedIn)

        service.setLogoutHandler {
            await logoutEntered.fire()
            await logoutGate.wait()
        }
        service.setLoginHandler { _, _ in second }

        let signOutTask = Task { await coordinator.signOut() }
        await logoutEntered.wait()
        let signInTask = Task {
            await coordinator.signIn(username: "second", password: "pw")
        }
        for _ in 0..<100 where coordinator.phase != .signingIn {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.phase, .signingIn)

        await logoutGate.open()
        let signOutResult = await signOutTask.value
        let signInResult = await signInTask.value

        XCTAssertEqual(signOutResult, .completed)
        XCTAssertEqual(signInResult, .signedIn(expectedUser(from: second)))
        XCTAssertEqual(coordinator.phase, .signedIn(expectedUser(from: second)))
        XCTAssertEqual(cookies.count, 3)
    }

    func testRealStorageStaleLoginCookieClearedAfterSynchronousInvalidation() async throws {
        let storage = try makeCookieStorage()
        setCookie(value: "live-token", domain: "calco.example.com", path: "/", in: storage)

        let session = makeSession()
        let entered = Signal()
        let gate = Gate()
        let box = CookieStorageBox(storage)
        let service = FakeSessionService(login: { _, _ in
            await entered.fire()
            await gate.wait()
            box.setSessionCookie(domain: "calco.example.com", value: "stale-login-token")
            return session
        })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        let loginTask = Task { await coordinator.signIn(username: "tester", password: "pw") }
        await entered.wait()

        XCTAssertTrue(coordinator.handleUnauthorized(reason: .expired))
        XCTAssertFalse(hasSessionCookie(in: storage))

        await gate.open()
        let result = await loginTask.value
        XCTAssertEqual(result, .failed(.cancelled))

        for _ in 0..<1000 where hasSessionCookie(in: storage) {
            await Task.yield()
        }
        XCTAssertFalse(hasSessionCookie(in: storage))
        XCTAssertEqual(coordinator.phase, .signedOut(.expired))
    }

    func testRealStorageLogoutResponseCookieClearedByFinalAwaitedClear() async throws {
        let storage = try makeCookieStorage()
        setCookie(value: "live-token", domain: "calco.example.com", path: "/", in: storage)

        let box = CookieStorageBox(storage)
        let service = FakeSessionService(logout: {
            box.setSessionCookie(domain: "calco.example.com", value: "logout-response-token")
        })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        let result = await coordinator.signOut()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(service.logoutCookieRecords.last?.map(\.value), ["live-token"])
        XCTAssertFalse(hasSessionCookie(in: storage))
    }

    func testRealStorageSignOutQueuedSnapshotPrefersStaleLoginCookie() async throws {
        let storage = try makeCookieStorage()

        let entered = Signal()
        let gate = Gate()
        let box = CookieStorageBox(storage)
        let staleSession = makeSession(id: "identity-stale", username: "stale")
        let service = FakeSessionService(login: { _, _ in
            await entered.fire()
            await gate.wait()
            box.setSessionCookie(domain: "calco.example.com", value: "stale-login-token")
            return staleSession
        })
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: HostCookieSessionClearer(storage: storage)
        )

        let loginTask = Task { await coordinator.signIn(username: "stale", password: "pw") }
        await entered.wait()
        XCTAssertFalse(hasSessionCookie(in: storage))

        box.setSessionCookie(domain: "calco.example.com", value: "distinct-initial-token")

        let signOutTask = Task { await coordinator.signOut() }
        for _ in 0..<100 where coordinator.phase != .signedOut(.signedOut) {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))

        await gate.open()
        let loginResult = await loginTask.value
        let signOutResult = await signOutTask.value

        XCTAssertEqual(loginResult, .failed(.cancelled))
        XCTAssertEqual(signOutResult, .completed)
        XCTAssertFalse(hasSessionCookie(in: storage))
        XCTAssertEqual(service.logoutCookieRecords.last?.map(\.value), ["stale-login-token"])
    }
}
