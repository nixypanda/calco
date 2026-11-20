import XCTest

@testable import CalCo

private final class AccountHeaderURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
        let delay: DispatchSemaphore?
    }

    private static let lock = NSLock()
    private static var storedHandler: (URLRequest) -> Stub = { _ in
        Stub(statusCode: 500, body: Data(), delay: nil)
    }
    private static var storedRequests: [URLRequest] = []

    static func setHandler(_ handler: @escaping (URLRequest) -> Stub) {
        lock.withLock {
            storedHandler = handler
            storedRequests = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    private static var handler: (URLRequest) -> Stub {
        lock.withLock { storedHandler }
    }

    private static func record(_ request: URLRequest) {
        lock.withLock { storedRequests.append(request) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.handler(request)
        if let delay = stub.delay {
            _ = delay.wait(timeout: .now() + 5)
        }
        Self.record(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:3002")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RecordingBoundCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
    let baseURL: URL
    let capability: LogCreationIdempotencyCapability
    private let lock = NSLock()
    private var expectedAccountIDs: [String] = []

    init(baseURL: URL, capability: LogCreationIdempotencyCapability) {
        self.baseURL = baseURL
        self.capability = capability
    }

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        capability
    }

    func fetchCapabilities(
        expectedAccountID: String
    ) async throws -> LogCreationIdempotencyCapability {
        lock.withLock { expectedAccountIDs.append(expectedAccountID) }
        return capability
    }

    var recordedExpectedAccountIDs: [String] {
        lock.withLock { expectedAccountIDs }
    }
}

private struct NoopSessionCookieClearer: SessionCookieClearing {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private final class SwitchingSessionService: SessionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var restoreSessionValue: LoginSession
    private var loginSessionValue: LoginSession

    init(restore: LoginSession, login: LoginSession? = nil) {
        self.restoreSessionValue = restore
        self.loginSessionValue = login ?? restore
    }

    func setLoginSession(_ session: LoginSession) {
        lock.withLock { loginSessionValue = session }
    }

    func restoreSession() async throws -> SessionRestoreOutcome {
        .authenticated(lock.withLock { restoreSessionValue })
    }

    func login(username: String, password: String) async throws -> LoginSession {
        lock.withLock { loginSessionValue }
    }

    func logout(sessionCookies: [HTTPCookie]) async throws {}
}


final class RequestAccountBindingTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    override func setUp() {
        super.setUp()
        AccountHeaderURLProtocol.setHandler { _ in
            .init(statusCode: 500, body: Data(), delay: nil)
        }
    }

    private func makeClient(expectedAccountID: String? = nil) -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHeaderURLProtocol.self]
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: URLSession(configuration: configuration),
            expectedAccountID: expectedAccountID
        )
    }

    private func json(_ raw: String, status: Int = 200) -> AccountHeaderURLProtocol.Stub {
        .init(statusCode: status, body: Data(raw.utf8), delay: nil)
    }

    private func header(_ name: String, in request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: name)
    }

    func testBoundClientAddsExpectedAccountHeaderToReads() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json(#"{"items":[{"code":"g","name":"Gram","kind":"mass"}]}"#)
        }
        let bound = makeClient(expectedAccountID: "profile-a").bound(
            toAccountID: "profile-a"
        )

        _ = try await bound.listUnits()

        let request = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: request),
            "profile-a"
        )
    }

    func testUnboundClientAddsNoHeader() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json(#"{"items":[]}"#)
        }
        _ = try await makeClient().listUnits()

        let request = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertNil(header(CalCoAPIClient.accountIDHeader, in: request))
    }

    func testSubmissionSenderPinsExpectedAccountHeaderBeforeRequest() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json(
                """
                {
                  "id":"log-1",
                  "log_date":"2026-11-19",
                  "meal_slot":"lunch",
                  "item":{"type":"product","id":"food-1","name":"Oats"},
                  "quantity":{"amount":"100","unit":"g"},
                  "nutrients":[]
                }
                """,
                status: 201
            )
        }
        let sender = CalCoLogSubmissionSender(client: makeClient())
        let request = LogSubmissionRequest(
            requestPath: "/api/logs",
            idempotencyKey: "bound-key",
            body: Data("{}".utf8),
            baseURLString: "http://127.0.0.1:3002"
        )

        _ = try await sender.send(request, expectedAccountID: "profile-a")

        let sent = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: sent),
            "profile-a"
        )
    }

    func testHeldRequestKeepsCapturedHeaderWhenAccountBindingChanges() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        AccountHeaderURLProtocol.setHandler { _ in
            started.signal()
            return .init(
                statusCode: 401,
                body: Data(
                    #"{"error":{"code":"session_account_changed","message":"account changed"}}"#.utf8
                ),
                delay: release
            )
        }
        let sender = CalCoLogSubmissionSender(client: makeClient())
        let request = LogSubmissionRequest(
            requestPath: "/api/logs",
            idempotencyKey: "held-key",
            body: Data("{}".utf8),
            baseURLString: "http://127.0.0.1:3002"
        )
        let sendTask = Task {
            try await sender.send(request, expectedAccountID: "profile-a")
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        // Another presentation is now bound to profile-b; the in-flight
        // request must still carry profile-a and be rejected as uncertain.
        let newPresentation = makeClient(expectedAccountID: "profile-b")
        XCTAssertEqual(newPresentation.expectedAccountID, "profile-b")
        release.signal()

        do {
            _ = try await sendTask.value
            XCTFail("stale account response must not succeed")
        } catch let error as LogSubmissionSendError {
            guard case .uncertain = error else {
                return XCTFail("expected uncertain, got \(error)")
            }
        }
        let sent = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: sent),
            "profile-a"
        )
    }

    func testCapabilityProviderSendsBoundAccountHeader() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json(
                """
                {"log_creation_idempotency":{
                  "version":2,
                  "single":true,
                  "ad_hoc":true,
                  "batch":true,
                  "batch_key_location":"top_level",
                  "deleted_operation_replay":"conflict",
                  "pre_migration_deleted_keys":"reconciliation_only",
                  "request_account_binding":"x-calco-account-id"
                }}
                """
            )
        }
        let provider = CalCoLogCreationCapabilityProvider(
            client: makeClient(expectedAccountID: "profile-a")
        )
        _ = try await provider.fetchCapabilities()

        let request = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: request),
            "profile-a"
        )
    }

    func testCapabilityProviderUsesExplicitFrozenAccountOnUnboundClient() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json(
                """
                {"log_creation_idempotency":{
                  "version":2,
                  "single":true,
                  "ad_hoc":true,
                  "batch":true,
                  "batch_key_location":"top_level",
                  "deleted_operation_replay":"conflict",
                  "pre_migration_deleted_keys":"reconciliation_only",
                  "request_account_binding":"x-calco-account-id"
                }}
                """
            )
        }
        let provider = CalCoLogCreationCapabilityProvider(
            client: makeClient()
        )
        _ = try await provider.fetchCapabilities(
            expectedAccountID: "profile-a"
        )

        let request = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: request),
            "profile-a"
        )
    }

    @MainActor
    func testServiceCapabilityProbeUsesFrozenProfileID() async {
        let baseURL = URL(string: "https://calco.example.com")!
        let provider = RecordingBoundCapabilityProvider(
            baseURL: baseURL,
            capability: LogCreationIdempotencyCapability(
                version: 2,
                single: true,
                adHoc: true,
                batch: true,
                batchKeyLocation: "top_level",
                deletedOperationReplay: "conflict",
                preMigrationDeletedKeys: "reconciliation_only"
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-capability-binding-\(UUID().uuidString)"
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(
                directoryURL: directory
            )
        )
        let service = LogSubmissionService(
            store: store,
            sender: CalCoLogSubmissionSender(client: makeClient()),
            capabilityProvider: provider,
            sessionContextProvider: {
                LogSubmissionSessionContext(
                    accountID: "identity-a",
                    generation: 9,
                    baseURL: baseURL,
                    profileID: "profile-a"
                )
            }
        )

        let failure = await service.ensureCapability(
            accountID: "identity-a",
            generation: 9,
            route: .single
        )

        XCTAssertNil(failure)
        XCTAssertEqual(
            provider.recordedExpectedAccountIDs,
            ["profile-a"]
        )
    }

    func testCapabilityBindingFlagIsStrictlyRequired() throws {
        let missing = """
        {"log_creation_idempotency":{
          "version":2,"single":true,"ad_hoc":true,"batch":true,
          "batch_key_location":"top_level",
          "deleted_operation_replay":"conflict",
          "pre_migration_deleted_keys":"reconciliation_only"
        }}
        """
        let missingCapability = try JSONDecoder()
            .decode(CapabilitiesResponse.self, from: Data(missing.utf8))
            .logCreationIdempotency
        XCTAssertFalse(missingCapability.supports(.single))
        XCTAssertFalse(missingCapability.supports(.adHoc))

        let withBinding = """
        {"log_creation_idempotency":{
          "version":2,"single":true,"ad_hoc":true,"batch":true,
          "batch_key_location":"top_level",
          "deleted_operation_replay":"conflict",
          "pre_migration_deleted_keys":"reconciliation_only",
          "request_account_binding":"x-calco-account-id"
        }}
        """
        let boundCapability = try JSONDecoder()
            .decode(CapabilitiesResponse.self, from: Data(withBinding.utf8))
            .logCreationIdempotency
        XCTAssertTrue(boundCapability.supports(.single))
        XCTAssertTrue(boundCapability.supports(.adHoc))
    }

    func testFoodDetailBoundAdapterAddsHeaderToDirectPOST() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json(
                """
                {
                  "id":"log-1",
                  "log_date":"2026-11-19",
                  "meal_slot":"lunch",
                  "item":{"type":"product","id":"food-1","name":"Oats"},
                  "quantity":{"amount":"100","unit":"g"},
                  "nutrients":[]
                }
                """,
                status: 201
            )
        }
        let adapter = CalCoFoodDetailServiceAdapter(client: makeClient())
        let request = FoodLogCreateRequest(
            date: date,
            timeZone: "Asia/Kolkata",
            mealSlot: .lunch,
            foodID: "food-1",
            amount: "100",
            unit: "g",
            notes: nil
        )

        _ = try await adapter.createLog(
            request,
            expectedAccountID: "profile-a"
        )

        let sent = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: sent),
            "profile-a"
        )
    }

    @MainActor
    func testAppShellFeatureServicesBindDistinctProfileID() async throws {
        let baseURL = URL(string: "http://127.0.0.1:3002")!
        let login = LoginSession(
            identity: AuthIdentity(
                id: "identity-a",
                username: "alice",
                role: .user
            ),
            profile: AuthProfile(id: "profile-a", displayName: "Alice")
        )
        let sessionService = SwitchingSessionService(restore: login)
        let session = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: baseURL,
            cookieClearer: NoopSessionCookieClearer()
        )
        await session.restore()
        guard case .signedIn(let user) = session.phase else {
            return XCTFail("Expected a signed-in session")
        }
        XCTAssertEqual(user.id, "identity-a")
        XCTAssertEqual(user.profileID, "profile-a")
        XCTAssertNotEqual(user.id, user.profileID)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-appshell-binding-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let coordinator = AppShellCoordinator(
            client: makeClient(),
            session: session,
            logSubmissionStore: store,
            logSubmissionSessionContextProvider: {
                guard case .signedIn(let current) = session.phase,
                      let profileID = current.profileID else {
                    return nil
                }
                return LogSubmissionSessionContext(
                    accountID: current.id,
                    generation: session.sessionGeneration,
                    baseURL: baseURL,
                    profileID: profileID
                )
            }
        )
        let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

        await assertBoundHeader("profile-a", pathContains: "/api/units") {
            _ = try? await coordinator.currentDiaryService.fetchUnits()
        }
        await assertBoundHeader("profile-a", pathContains: "/api/foods/search") {
            _ = try? await coordinator.currentSearchService.searchFoods(
                query: "oats",
                scope: .all
            )
        }
        await assertBoundHeader("profile-a", pathContains: "/api/goal") {
            _ = try? await coordinator.currentSettingsService.fetchGoal(on: date)
        }
        await assertBoundHeader("profile-a", pathContains: "/api/auth/api-keys") {
            _ = try? await coordinator.currentAPIKeyService.listAPIKeys()
        }
        await assertBoundHeader("profile-a", pathContains: "/api/meals") {
            _ = try? await coordinator.currentMealsService.listMeals()
        }
        await assertBoundHeader("profile-a", pathContains: "/api/foods/custom") {
            _ = try? await coordinator.currentLibraryService.listCustomFoods()
        }
    }

    @MainActor
    func testCapturedFeatureServiceKeepsOriginalProfileAfterAccountSwitch() async throws {
        let baseURL = URL(string: "http://127.0.0.1:3002")!
        let first = LoginSession(
            identity: AuthIdentity(
                id: "identity-a",
                username: "alice",
                role: .user
            ),
            profile: AuthProfile(id: "profile-a", displayName: "Alice")
        )
        let second = LoginSession(
            identity: AuthIdentity(
                id: "identity-b",
                username: "bob",
                role: .user
            ),
            profile: AuthProfile(id: "profile-b", displayName: "Bob")
        )
        let sessionService = SwitchingSessionService(
            restore: first,
            login: second
        )
        let session = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: baseURL,
            cookieClearer: NoopSessionCookieClearer()
        )
        await session.restore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-appshell-frozen-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let coordinator = AppShellCoordinator(
            client: makeClient(),
            session: session,
            logSubmissionStore: store,
            logSubmissionSessionContextProvider: {
                guard case .signedIn(let current) = session.phase,
                      let profileID = current.profileID else {
                    return nil
                }
                return LogSubmissionSessionContext(
                    accountID: current.id,
                    generation: session.sessionGeneration,
                    baseURL: baseURL,
                    profileID: profileID
                )
            }
        )
        let mealsA = coordinator.currentMealsService

        await assertBoundHeader("profile-a", pathContains: "/api/meals") {
            _ = try? await mealsA.listMeals()
        }

        let result = await session.signIn(username: "bob", password: "secret")
        guard case .signedIn(let userB) = result else {
            return XCTFail("Second account did not sign in")
        }
        XCTAssertEqual(userB.id, "identity-b")
        XCTAssertEqual(userB.profileID, "profile-b")

        await assertBoundHeader("profile-b", pathContains: "/api/meals") {
            _ = try? await coordinator.currentMealsService.listMeals()
        }
        await assertBoundHeader("profile-a", pathContains: "/api/meals") {
            _ = try? await mealsA.listMeals()
        }
    }

    func testAuthenticationRequestsStayUnbound() async throws {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json("{}")
        }
        let client = makeClient()
        _ = try? await client.currentSession()
        let request = try XCTUnwrap(AccountHeaderURLProtocol.requests.first)
        XCTAssertNil(header(CalCoAPIClient.accountIDHeader, in: request))
    }

    @MainActor
    func testMissingProductionProfileFailsClosedWithoutIdentityFallback() async {
        let baseURL = URL(string: "http://127.0.0.1:3002")!
        let login = LoginSession(
            identity: AuthIdentity(
                id: "identity-a",
                username: "alice",
                role: .user
            ),
            profile: nil
        )
        let sessionService = SwitchingSessionService(restore: login)
        let session = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: baseURL,
            cookieClearer: NoopSessionCookieClearer()
        )
        await session.restore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-appshell-missing-profile-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let coordinator = AppShellCoordinator(
            client: makeClient(),
            session: session,
            logSubmissionStore: store,
            logSubmissionSessionContextProvider: { nil }
        )

        XCTAssertNil(coordinator.currentUser)
        if case .signedIn = session.phase {
            XCTFail("Missing profile ID must not leave a signed-in feature graph")
        }
    }

    @MainActor
    func testAuthorityPolicyRejectsInjectedFeatureService() async {
        let baseURL = URL(string: "http://127.0.0.1:3002")!
        let login = LoginSession(
            identity: AuthIdentity(
                id: "identity-a",
                username: "alice",
                role: .user
            ),
            profile: AuthProfile(id: "profile-a", displayName: "Alice")
        )
        let session = SessionCoordinator(
            service: SwitchingSessionService(restore: login),
            cookieBaseURL: baseURL,
            cookieClearer: NoopSessionCookieClearer()
        )
        await session.restore()
        AccountHeaderURLProtocol.setHandler { _ in
            self.json("{}")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-appshell-injected-service-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let coordinator = AppShellCoordinator(
            client: makeClient(),
            session: session,
            diaryService: CalCoDiaryServiceAdapter(client: makeClient()),
            logSubmissionStore: store,
            logSubmissionSessionContextProvider: {
                LogSubmissionSessionContext(
                    accountID: "identity-a",
                    generation: session.sessionGeneration,
                    baseURL: baseURL,
                    profileID: "profile-a"
                )
            }
        )

        XCTAssertNil(coordinator.currentUser)
        XCTAssertTrue(AccountHeaderURLProtocol.requests.isEmpty)
        if case .signedIn = session.phase {
            XCTFail("Authority-bound policy must reject injected feature services")
        }
    }

    @MainActor
    func testAuthorityPolicyRejectsInjectedSubmissionService() async {
        let baseURL = URL(string: "http://127.0.0.1:3002")!
        let login = LoginSession(
            identity: AuthIdentity(
                id: "identity-a",
                username: "alice",
                role: .user
            ),
            profile: AuthProfile(id: "profile-a", displayName: "Alice")
        )
        let session = SessionCoordinator(
            service: SwitchingSessionService(restore: login),
            cookieBaseURL: baseURL,
            cookieClearer: NoopSessionCookieClearer()
        )
        await session.restore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-appshell-injected-submission-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let injected = LogSubmissionService(
            store: store,
            sender: CalCoLogSubmissionSender(client: makeClient()),
            capabilityProvider: CalCoLogCreationCapabilityProvider(client: makeClient())
        )
        let coordinator = AppShellCoordinator(
            client: makeClient(),
            session: session,
            logSubmissionStore: store,
            logSubmissionService: injected,
            logSubmissionSessionContextProvider: {
                LogSubmissionSessionContext(
                    accountID: "identity-a",
                    generation: session.sessionGeneration,
                    baseURL: baseURL,
                    profileID: "profile-a"
                )
            }
        )

        XCTAssertNil(coordinator.currentUser)
        if case .signedIn = session.phase {
            XCTFail("Authority-bound policy must reject injected submission services")
        }
    }

    @MainActor
    private func assertBoundHeader(
        _ expected: String,
        pathContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async -> Void
    ) async {
        AccountHeaderURLProtocol.setHandler { _ in
            self.json("{}")
        }
        await operation()
        let requests = AccountHeaderURLProtocol.requests
        let request: URLRequest?
        if let pathContains {
            request = requests.last {
                $0.url?.path.contains(pathContains) == true
            }
        } else {
            request = requests.last
        }
        guard let request else {
            return XCTFail(
                "No request was recorded for \(pathContains ?? "any path")",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            header(CalCoAPIClient.accountIDHeader, in: request),
            expected,
            file: file,
            line: line
        )
    }
}
