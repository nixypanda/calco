import XCTest
import Darwin

@testable import CalCo

// Lock-guarded, per-test HTTP stubs keyed by a unique port so parallel tests cannot interfere.

private struct StubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let delay: TimeInterval
    let failure: URLError.Code?

    init(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: Data = Data(),
        delay: TimeInterval = 0,
        failure: URLError.Code? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.delay = delay
        self.failure = failure
    }
}

private final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()

    private let lock = NSLock()
    private var responses: [String: StubResponse] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var lastPort = 30_000

    func register(_ response: StubResponse) -> String {
        lock.lock()
        lastPort += 1
        let token = String(lastPort)
        responses[token] = response
        requests[token] = []
        lock.unlock()
        return token
    }

    func response(for token: String) -> StubResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[token]
    }

    func record(_ request: URLRequest, for token: String) {
        lock.lock()
        requests[token, default: []].append(request)
        lock.unlock()
    }

    func recordedRequests(for token: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests[token] ?? []
    }
}

private final class APIDataURLProtocol: URLProtocol {
    private let lock = NSLock()
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard let port = request.url?.port else { return false }
        let token = String(port)
        return StubRegistry.shared.response(for: token) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let port = url.port,
              let stub = StubRegistry.shared.response(for: String(port)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        StubRegistry.shared.record(request, for: String(port))

        if let failure = stub.failure {
            complete {
                self.client?.urlProtocol(self, didFailWithError: URLError(failure))
            }
            return
        }

        let deliver = { [weak self] in
            guard let self else { return }
            self.complete {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                )!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !stub.body.isEmpty {
                    self.client?.urlProtocol(self, didLoad: stub.body)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    private func complete(_ work: () -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        work()
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let response: String
    private let lock = NSLock()
    private let received = DispatchSemaphore(value: 0)
    private var requests: [String] = []

    init(response: String) throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(listener)
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.port = UInt16(bigEndian: address.sin_port)
        self.response = response
    }

    deinit { Darwin.close(listener) }

    func start() {
        DispatchQueue.global().async { [self] in
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&descriptor, 1, 10_000) > 0 else { return }
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let size = Darwin.recv(connection, &bytes, bytes.count, 0)
            guard size > 0 else { return }
            lock.withLock { requests.append(String(decoding: bytes.prefix(size), as: UTF8.self)) }
            received.signal()
            let payload = Array(response.utf8)
            _ = payload.withUnsafeBytes { Darwin.send(connection, $0.baseAddress, $0.count, 0) }
        }
    }

    func waitForRequest(timeout: TimeInterval) -> Bool {
        received.wait(timeout: .now() + timeout) == .success
    }

    var capturedRequests: [String] { lock.withLock { requests } }
}

final class APIDataTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    private func stubClient(
        response: StubResponse = StubResponse(),
        requestTimeout: TimeInterval = 30
    ) -> (client: CalCoAPIClient, token: String) {
        let token = StubRegistry.shared.register(response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIDataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CalCoAPIClient(
            configuration: CalCoAPIConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(token)")!,
                requestTimeout: requestTimeout
            ),
            session: session
        )
        return (client, token)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testClientAppendsAPIPathToConfiguredBaseURL() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "https://example.com")!)
        let url = try client.makeURL(path: ["api", "auth", "session"])
        XCTAssertEqual(url.absoluteString, "https://example.com/api/auth/session")
    }

    func testURLKeepsBasePathAndEncodesQuery() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "https://example.com/prefix")!)
        let url = try client.makeURL(
            path: ["api", "foods", "search"],
            queryItems: [
                URLQueryItem(name: "q", value: "chicken & rice/é"),
                URLQueryItem(name: "scope", value: "all"),
            ]
        )

        XCTAssertEqual(url.path, "/prefix/api/foods/search")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "q" })?.value, "chicken & rice/é")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "scope" })?.value, "all")
    }

    func testURLEncodesUnsafePathSegment() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "http://localhost:3002")!)
        let url = try client.makeURL(path: ["api", "foods", "a/b c"])
        XCTAssertTrue(url.absoluteString.hasSuffix("/api/foods/a%2Fb%20c"))
    }

    func testURLRejectsUnsupportedScheme() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "ftp://example.com")!)
        XCTAssertThrowsError(try client.makeURL(path: ["api", "logs"])) { error in
            XCTAssertEqual(error as? CalCoAPIError, .invalidURL)
        }
    }

    func testURLRejectsUserInfo() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "http://user:pass@example.com")!)
        XCTAssertThrowsError(try client.makeURL(path: ["api", "logs"])) { error in
            XCTAssertEqual(error as? CalCoAPIError, .invalidURL)
        }
    }

    func testURLRejectsQueryInBaseURL() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "http://example.com?token=secret")!)
        XCTAssertThrowsError(try client.makeURL(path: ["api", "logs"])) { error in
            XCTAssertEqual(error as? CalCoAPIError, .invalidURL)
        }
    }

    func testURLRejectsFragmentInBaseURL() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "http://example.com/#section")!)
        XCTAssertThrowsError(try client.makeURL(path: ["api", "logs"])) { error in
            XCTAssertEqual(error as? CalCoAPIError, .invalidURL)
        }
    }

    func testURLRejectsDotSegmentsAndEmptySegments() throws {
        let client = CalCoAPIClient(baseURL: URL(string: "http://example.com")!)
        for path in [["api", ".", "logs"], ["api", "..", "logs"], ["api", "", "logs"], ["api", "logs", "."]] {
            XCTAssertThrowsError(try client.makeURL(path: path)) { error in
                XCTAssertEqual(error as? CalCoAPIError, .invalidURL)
            }
        }
    }

    func testRequestsDoNotSetAuthorizationHeader() async throws {
        let (client, token) = stubClient(
            response: StubResponse(body: Data(#"{"admin_exists":true}"#.utf8))
        )
        _ = try await client.bootstrapStatus()
        let request = try XCTUnwrap(StubRegistry.shared.recordedRequests(for: token).last)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testSearchSendsExpectedPathAndQuery() async throws {
        let (client, token) = stubClient(
            response: StubResponse(body: Data(#"{"items":[]}"#.utf8))
        )
        let items = try await client.searchFoods(query: "oats", scope: .history)

        XCTAssertTrue(items.isEmpty)
        let request = try XCTUnwrap(StubRegistry.shared.recordedRequests(for: token).last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/foods/search")
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "q" })?.value, "oats")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "scope" })?.value, "history")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedIsMappedForSessionExpiry() async throws {
        let (client, _) = stubClient(
            response: StubResponse(
                statusCode: 401,
                body: Data(
                    #"{"error":{"code":"session_expired","message":"session_expired"}}"#.utf8
                )
            )
        )
        do {
            _ = try await client.currentSession()
            XCTFail("Expected an unauthorized error")
        } catch let error as CalCoAPIError {
            XCTAssertTrue(error.isUnauthorized)
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.payload?.code, "session_expired")
        }
    }

    func testInvalidCredentialsDoesNotSignalSessionExpiry() async throws {
        let (client, _) = stubClient(
            response: StubResponse(
                statusCode: 401,
                body: Data(
                    #"{"error":{"code":"invalid_credentials","message":"invalid_credentials"}}"#.utf8
                )
            )
        )
        do {
            _ = try await client.login(username: "u", password: "bad")
            XCTFail("Expected an unauthorized error")
        } catch let error as CalCoAPIError {
            XCTAssertTrue(error.isUnauthorized)
            XCTAssertTrue(error.isInvalidCredentials)
        }
    }

    func testRateLimitedCarriesRetryAfterSeconds() async throws {
        let (client, _) = stubClient(
            response: StubResponse(statusCode: 429, headers: ["Retry-After": "5"])
        )
        do {
            _ = try await client.currentSession()
            XCTFail("Expected a rate limited error")
        } catch let error as CalCoAPIError {
            XCTAssertEqual(error.statusCode, 429)
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 5)
        }
    }

    func testRateLimitedWithoutRetryAfterHeader() async throws {
        let (client, _) = stubClient(response: StubResponse(statusCode: 429))
        do {
            _ = try await client.currentSession()
            XCTFail("Expected a rate limited error")
        } catch let error as CalCoAPIError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
            XCTAssertNil(retryAfter)
        }
    }

    func testTimeoutMapsToTimeoutError() async throws {
        let (client, _) = stubClient(response: StubResponse(failure: .timedOut))
        do {
            _ = try await client.currentSession()
            XCTFail("Expected a timeout error")
        } catch let error as CalCoAPIError {
            XCTAssertEqual(error, .timeout)
        }
    }

    func testCancellationMapsToCancelledError() async throws {
        let (client, token) = stubClient(response: StubResponse(delay: 30))
        let task = Task {
            try await client.currentSession()
        }
        let deadline = Date().addingTimeInterval(2)
        while StubRegistry.shared.recordedRequests(for: token).isEmpty && Date() < deadline {
            await Task.yield()
        }
        XCTAssertFalse(StubRegistry.shared.recordedRequests(for: token).isEmpty)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected a cancelled error")
        } catch let error as CalCoAPIError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testLogoutSendsProvidedSessionCookieHeader() async throws {
        let (client, token) = stubClient(response: StubResponse(statusCode: 200))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "calco_session",
            .value: "test-token",
            .domain: "127.0.0.1",
            .path: "/",
        ]))

        try await client.logout(sessionCookies: [cookie])

        let request = try XCTUnwrap(
            StubRegistry.shared.recordedRequests(for: token).last
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/auth/logout")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cookie"),
            "calco_session=test-token"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testInjectedSessionLogoutDoesNotFollowCrossOriginRedirectWithCookie() async throws {
        let destination = try LoopbackHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        destination.start()
        let origin = try LoopbackHTTPServer(response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(destination.port)/capture\r\nContent-Length: 0\r\n\r\n")
        origin.start()
        let configuration = URLSessionConfiguration.ephemeral
        let client = CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!,
            session: URLSession(configuration: configuration)
        )
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "calco_session",
            .value: "loopback-test-value",
            .domain: "127.0.0.1",
            .path: "/",
        ]))

        do {
            try await client.logout(sessionCookies: [cookie])
            XCTFail("The redirect must not be treated as a completed logout")
        } catch let error as CalCoAPIError {
            XCTAssertEqual(error.statusCode, 302)
        }

        XCTAssertTrue(origin.waitForRequest(timeout: 2))
        XCTAssertTrue(origin.capturedRequests.first?.contains("Cookie: calco_session=loopback-test-value") == true)
        XCTAssertFalse(destination.waitForRequest(timeout: 1))
        XCTAssertTrue(destination.capturedRequests.isEmpty)
    }

    func testLoginSessionDecodesUserAndAdminRoles() throws {
        let user = try decode(
            LoginSession.self,
            """
            {
              "identity": {
                "id": "identity-1",
                "username": "tester",
                "role": "user",
                "created_at": "2026-11-17T10:00:00Z",
                "updated_at": "2026-11-17T10:00:00Z"
              },
              "profile": {
                "id": "profile-1",
                "display_name": "Test User",
                "created_at": "2026-11-17T10:00:00Z",
                "updated_at": "2026-11-17T10:00:00Z"
              }
            }
            """
        )
        XCTAssertFalse(user.isAdmin)
        XCTAssertTrue(user.isRegularUser)
        XCTAssertEqual(user.displayName, "Test User")

        let admin = try decode(
            LoginSession.self,
            """
            {
              "identity": {"id": "identity-2", "username": "admin", "role": "admin"},
              "profile": null
            }
            """
        )
        XCTAssertTrue(admin.isAdmin)
        XCTAssertFalse(admin.isRegularUser)
        XCTAssertEqual(admin.displayName, "admin")
    }

    func testUnknownRoleDecodesAsOther() throws {
        let session = try decode(
            LoginSession.self,
            #"{"identity":{"id":"i","username":"u","role":"auditor"},"profile":null}"#
        )
        XCTAssertEqual(session.identity.role, .other)
        XCTAssertFalse(session.isAdmin)
        XCTAssertFalse(session.isRegularUser)
    }

    func testFoodLogDecodesSnapshotsAndMacros() throws {
        let log = try decode(
            FoodLog.self,
            """
            {
              "id": "log-1",
              "log_date": "2026-11-17",
              "device_timezone": "Europe/Paris",
              "meal_slot": "late_night_snack",
              "item": {"type": "product", "id": "food-1", "name": "Oats", "brand": null},
              "quantity": {"amount": "50", "unit": "g"},
              "nutrients": [
                {"code": "ENERGY_KCAL", "amount": "194.5", "unit": "kcal"},
                {"code": "PROTEIN_G", "amount": "8.25", "unit": "g"},
                {"code": "CARBS_G", "amount": "33.1", "unit": "g"},
                {"code": "FAT_G", "amount": "3.4", "unit": "g"}
              ],
              "notes": null,
              "created_at": "2026-11-17T10:00:00Z",
              "updated_at": "2026-11-17T10:00:00Z"
            }
            """
        )

        XCTAssertEqual(log.logDate, date)
        XCTAssertEqual(log.mealSlot, .lateNightSnack)
        XCTAssertEqual(log.itemName, "Oats")
        XCTAssertEqual(log.quantity, NutritionQuantity(amount: "50", unit: "g"))
        XCTAssertEqual(log.calories, 194.5)
        XCTAssertEqual(log.proteinG, 8.25)
        XCTAssertEqual(log.itemReference, ItemReference(itemType: .product, id: "food-1"))
    }

    func testUnknownOptionalMealSlotBecomesNil() throws {
        let log = try decode(
            FoodLog.self,
            """
            {
              "id": "log-2",
              "log_date": "2026-11-17",
              "device_timezone": null,
              "meal_slot": "brunch",
              "item": {"type": "ad_hoc", "name": "Toast"},
              "quantity": {"amount": "1", "unit": "slice"},
              "nutrients": [],
              "notes": null
            }
            """
        )
        XCTAssertNil(log.mealSlot)
        XCTAssertEqual(log.itemName, "Toast")
    }

    func testDiaryPreferencesRoundTrip() throws {
        let prefs = DiaryPreferences(enabledMealSlots: [.breakfast, .dinner])
        let data = try JSONEncoder().encode(prefs)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["enabled_meal_slots"] as? [String], ["breakfast", "dinner"])

        let decoded = try JSONDecoder().decode(DiaryPreferences.self, from: data)
        XCTAssertEqual(decoded.enabledMealSlots, [.breakfast, .dinner])
        XCTAssertTrue(decoded.isEnabled(.dinner))
        XCTAssertFalse(decoded.isEnabled(.lunch))
    }

    func testFlexibleDoubleAcceptsJSONNumbers() throws {
        let summary = try decode(
            DaySummary.self,
            """
            {"date": "2026-11-17", "energy_kcal": 2010, "protein_g": 120, "carbs_g": 210.25, "fat_g": 65}
            """
        )
        XCTAssertEqual(summary.energyKcal, 2010)
        XCTAssertEqual(summary.carbsG, 210.25)
    }

    func testDiaryPreferencesUseTenSecondTimeout() {
        XCTAssertEqual(CalCoAPIClient.diaryPreferencesTimeout, 10)
    }

    func testDaySummaryDecodesDecimalStrings() throws {
        let summary = try decode(
            DaySummary.self,
            """
            {
              "date": "2026-11-17",
              "energy_kcal": "2010.5",
              "protein_g": "120",
              "carbs_g": "210.25",
              "fat_g": "65"
            }
            """
        )
        XCTAssertEqual(summary.date, date)
        XCTAssertEqual(summary.energyKcal, 2010.5)
        XCTAssertEqual(summary.proteinG, 120)
        XCTAssertEqual(summary.carbsG, 210.25)
        XCTAssertEqual(summary.fatG, 65)
    }

    func testLocalDiaryDateUsesYYYYMMDDWireFormat() throws {
        let summary = DaySummary(
            date: date,
            energyKcal: 1,
            proteinG: 2,
            carbsG: 3,
            fatG: 4
        )
        let data = try JSONEncoder().encode(summary)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["date"] as? String, "2026-11-17")
    }

    func testGoalSnapshotDecodesFlatTargets() throws {
        let goal = try decode(
            GoalSnapshot.self,
            """
            {
              "requested_date": "2026-11-17",
              "effective_from": "2026-11-01",
              "source": "saved",
              "calorie_target": "2000",
              "protein_target_g": "120",
              "carbs_target_g": "210",
              "fat_target_g": "70"
            }
            """
        )
        XCTAssertEqual(goal.requestedDate, date)
        XCTAssertEqual(goal.effectiveFrom, LocalDiaryDate(year: 2026, month: 11, day: 1))
        XCTAssertTrue(goal.isSaved)
        XCTAssertEqual(goal.targets.calorieTarget, 2000)
        XCTAssertEqual(goal.targets.proteinTargetG, 120)
        XCTAssertEqual(goal.targets.carbsTargetG, 210)
        XCTAssertEqual(goal.targets.fatTargetG, 70)
    }

    func testProductDetailDefaultsAndNutritionPreview() throws {
        let product = try decode(
            ProductDetail.self,
            """
            {
              "id": "food-1",
              "source": "USER",
              "source_id": null,
              "visibility": "global",
              "barcode": null,
              "name": "Oats",
              "brand": "Farm",
              "categories": ["Breakfast"],
              "default_quantity": "2",
              "default_unit": "serving",
              "nutrition_summary": {
                "per_100g": {
                  "energy_kcal": "400",
                  "protein_g": "10",
                  "carbs_g": "60",
                  "fat_g": "8",
                  "fiber_g": "5"
                }
              },
              "nutrients": [
                {"code": "ENERGY_KCAL", "amount_per_100g": "400", "unit": "kcal", "source": null, "confidence": "approved"}
              ],
              "servings": [{"unit": "serving", "grams_per_unit": "50"}],
              "allowed_units": [{"code": "serving", "name": "Serving", "kind": "serving"}],
              "created_at": "2026-11-17T10:00:00Z",
              "updated_at": "2026-11-17T10:00:00Z"
            }
            """
        )

        XCTAssertEqual(product.sourceID, nil)
        XCTAssertEqual(product.defaultLogQuantity, NutritionQuantity(amount: "2", unit: "serving"))
        XCTAssertEqual(product.allowedUnits.map(\.code), ["serving"])
        XCTAssertEqual(product.nutrientsPer100g.first?.amount, "400")

        let preview = try XCTUnwrap(
            product.nutrients(for: NutritionQuantity(amount: "2", unit: "serving"))
        )
        XCTAssertEqual(preview.first?.code, "ENERGY_KCAL")
        XCTAssertEqual(preview.first?.amountValue, 400)
    }

    func testSafeAmountClampsInvalidAndNegativeValues() {
        XCTAssertEqual(NutritionMath.safeAmount("194.5"), 194.5)
        XCTAssertEqual(NutritionMath.safeAmount(" 12 "), 12)
        XCTAssertEqual(NutritionMath.safeAmount("abc"), 0)
        XCTAssertEqual(NutritionMath.safeAmount("-5"), 0)
        XCTAssertEqual(NutritionMath.safeAmount(nil), 0)
    }

    func testDefaultLogQuantityFallsBackToServingThenGrams() {
        let product = ProductDetail(
            id: "food-x",
            source: "USER",
            visibility: "global",
            name: "Oats"
        )
        XCTAssertEqual(product.defaultLogQuantity, NutritionQuantity(amount: "100", unit: "g"))

        let withServing = ProductDetail(
            id: "food-y",
            source: "USER",
            visibility: "global",
            name: "Oats",
            servings: [ProductServing(unit: "cup", gramsPerUnit: "40")]
        )
        XCTAssertEqual(withServing.defaultLogQuantity, NutritionQuantity(amount: "1", unit: "cup"))
    }

    func testCreateLogEncodingMatchesBackendKeys() throws {
        let request = CreateLogRequest(
            logDate: date,
            deviceTimeZone: "Europe/Paris",
            mealSlot: .lunch,
            item: ItemReference(itemType: .product, id: "food-1"),
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["log_date"] as? String, "2026-11-17")
        XCTAssertEqual(object["device_timezone"] as? String, "Europe/Paris")
        XCTAssertEqual(object["meal_slot"] as? String, "lunch")
        XCTAssertTrue(object["notes"] is NSNull)

        let item = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "product")
        XCTAssertEqual(item["id"] as? String, "food-1")

        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["amount"] as? String, "150")
        XCTAssertEqual(quantity["unit"] as? String, "g")
    }

    func testCreateLogOmitsNilMealSlotAndTimezone() throws {
        let request = CreateLogRequest(
            logDate: date,
            deviceTimeZone: nil,
            mealSlot: nil,
            productID: "food-2",
            quantity: NutritionQuantity(amount: "1", unit: "serving")
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["meal_slot"])
        XCTAssertNil(object["device_timezone"])
        XCTAssertTrue(object["notes"] is NSNull)
    }
}
