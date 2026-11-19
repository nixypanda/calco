import XCTest

@testable import CalCo


private final class AdapterURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?

        init(
            statusCode: Int = 200,
            headers: [String: String] = [:],
            body: Data = Data(),
            error: Error? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    typealias Handler = (URLRequest) -> Stub

    private static let lock = NSLock()
    private static var storedHandler: Handler = { _ in Stub(statusCode: 500) }

    static func setHandler(_ handler: @escaping Handler) {
        lock.withLock { storedHandler = handler }
    }

    private static var handler: Handler {
        lock.withLock { storedHandler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.handler(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AdapterRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}

private final class AdapterWarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ message: String) {
        lock.withLock { storage.append(message) }
    }

    var warnings: [String] {
        lock.withLock { storage }
    }
}

final class ServiceAdaptersTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    override func setUp() {
        super.setUp()
        AdapterURLProtocol.setHandler { _ in .init(statusCode: 500) }
    }


    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: session
        )
    }

    private func json(
        _ raw: String,
        statusCode: Int = 200
    ) -> AdapterURLProtocol.Stub {
        .init(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: Data(raw.utf8)
        )
    }

    private func errorJSON(code: String, message: String) -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                stream.read(
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    maxLength: rawBuffer.count
                )
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private func queryValue(_ request: URLRequest, name: String) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }


    func testSessionServiceLoginReturnsSessionFromCookieEndpoint() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                """
                {
                  "identity": {"id": "identity-1", "username": "tester", "role": "user"},
                  "profile": {"id": "profile-1", "display_name": "Test User"}
                }
                """
            )
        }

        let session = try await CalCoSessionService(client: makeClient())
            .login(username: "tester", password: "pw")

        XCTAssertEqual(session.identity.id, "identity-1")
        XCTAssertEqual(session.identity.username, "tester")
        XCTAssertEqual(session.identity.role, .user)
        XCTAssertEqual(session.profile?.displayName, "Test User")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/auth/login")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(bodyData(from: request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["username"] as? String, "tester")
        XCTAssertEqual(object["password"] as? String, "pw")
    }

    func testSessionServiceRestoreMapsUnauthorizedReasons() async throws {
        let recorder = AdapterRequestRecorder()
        let service = CalCoSessionService(client: makeClient())

        for (code, expected) in [
            ("session_expired", SessionUnavailableReason.expired),
            ("session_not_found", .notFound),
            ("unauthenticated", .signedOut),
        ] {
            AdapterURLProtocol.setHandler { request in
                recorder.record(request)
                return self.json(
                    self.errorJSON(code: code, message: "Unauthorized"),
                    statusCode: 401
                )
            }

            let outcome = try await service.restoreSession()
            XCTAssertEqual(outcome, .unauthenticated(expected))
        }

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/auth/session")
    }

    func testDiaryFetchMapsLogsGoalAndPreferences() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/api/logs":
                return self.json(
                    """
                    {
                      "log_date": "2026-11-17",
                      "items": [
                        {
                          "id": "log-1",
                          "log_date": "2026-11-17",
                          "device_timezone": "Europe/Paris",
                          "meal_slot": "late_night_snack",
                          "item": {
                            "type": "product",
                            "id": "food-1",
                            "name": "Oats",
                            "brand": "Farm"
                          },
                          "quantity": {"amount": "50", "unit": "g"},
                          "nutrients": [
                            {"code": "ENERGY_KCAL", "amount": "194.5", "unit": "kcal"},
                            {"code": "PROTEIN_G", "amount": "8.25", "unit": "g"},
                            {"code": "CARBS_G", "amount": "33.1", "unit": "g"},
                            {"code": "FAT_G", "amount": "3.4", "unit": "g"}
                          ],
                          "notes": "with milk"
                        }
                      ]
                    }
                    """
                )
            case "/api/goal":
                return self.json(
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
            case "/api/diary-preferences":
                return self.json(#"{"enabled_meal_slots": ["breakfast", "dinner"]}"#)
            default:
                return .init(statusCode: 404)
            }
        }

        let day = try await CalCoDiaryServiceAdapter(client: makeClient())
            .fetchDiary(for: date)

        XCTAssertEqual(day.date, date)
        XCTAssertEqual(day.logs.count, 1)
        let log = try XCTUnwrap(day.logs.first)
        XCTAssertEqual(log.id, "log-1")
        XCTAssertEqual(log.mealSlot, .lateNightSnack)
        XCTAssertEqual(log.title, "Oats")
        XCTAssertEqual(log.calories, 194.5)
        XCTAssertEqual(log.proteinG, 8.25)
        XCTAssertEqual(log.carbsG, 33.1)
        XCTAssertEqual(log.fatG, 3.4)

        XCTAssertEqual(day.goal.calorieTarget, 2_000)
        XCTAssertEqual(day.goal.proteinTargetG, 120)
        XCTAssertEqual(day.goal.carbsTargetG, 210)
        XCTAssertEqual(day.goal.fatTargetG, 70)
        XCTAssertEqual(day.prefs.enabledSlots, [.breakfast, .dinner])

        let logsRequest = try XCTUnwrap(
            recorder.requests.first(where: { $0.url?.path == "/api/logs" })
        )
        XCTAssertEqual(queryValue(logsRequest, name: "log_date"), "2026-11-17")
        let goalRequest = try XCTUnwrap(
            recorder.requests.first(where: { $0.url?.path == "/api/goal" })
        )
        XCTAssertEqual(queryValue(goalRequest, name: "date"), "2026-11-17")
    }

    func testDiaryPreferencesFailureFallsBackToAllSlotsWithWarning() async throws {
        let warnings = AdapterWarningRecorder()
        AdapterURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/api/logs":
                return self.json(#"{"log_date": "2026-11-17", "items": []}"#)
            case "/api/goal":
                return self.json(
                    """
                    {
                      "requested_date": "2026-11-17",
                      "effective_from": null,
                      "source": "default",
                      "calorie_target": "1800",
                      "protein_target_g": "100",
                      "carbs_target_g": "200",
                      "fat_target_g": "60"
                    }
                    """
                )
            case "/api/diary-preferences":
                return self.json(
                    self.errorJSON(code: "server_error", message: "prefs unavailable"),
                    statusCode: 503
                )
            default:
                return .init(statusCode: 404)
            }
        }

        let adapter = CalCoDiaryServiceAdapter(
            client: makeClient(),
            onPreferencesFallback: { warnings.record($0) }
        )
        let day = try await adapter.fetchDiary(for: date)

        XCTAssertEqual(day.prefs.enabledSlots, Set(MealSlot.allCases))
        XCTAssertEqual(warnings.warnings.count, 1)
        XCTAssertTrue(warnings.warnings[0].contains("preferences"))
        XCTAssertEqual(day.goal.calorieTarget, 1_800)
    }

    func testDiaryUnauthorizedMapsToTypedServiceError() async throws {
        AdapterURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/api/logs":
                return self.json(
                    self.errorJSON(code: "session_expired", message: "Session expired"),
                    statusCode: 401
                )
            case "/api/goal":
                return self.json(
                    """
                    {
                      "requested_date": "2026-11-17",
                      "source": "default",
                      "calorie_target": "1800",
                      "protein_target_g": "100",
                      "carbs_target_g": "200",
                      "fat_target_g": "60"
                    }
                    """
                )
            case "/api/diary-preferences":
                return self.json(#"{"enabled_meal_slots": ["breakfast"]}"#)
            default:
                return .init(statusCode: 404)
            }
        }

        do {
            _ = try await CalCoDiaryServiceAdapter(client: makeClient())
                .fetchDiary(for: date)
            XCTFail("Expected a diary error")
        } catch let error as DiaryServiceError {
            XCTAssertEqual(error, .unauthorized)
        }
    }


    func testFoodSearchMapsItemsAndScope() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                """
                {
                  "items": [
                    {
                      "id": "food-1",
                      "source": "USER",
                      "source_id": "src-1",
                      "barcode": "12345",
                      "name": "Oats",
                      "brand": "Farm",
                      "categories": ["Breakfast"],
                      "nutrition_summary": {"per_100g": {"energy_kcal": "400"}}
                    }
                  ]
                }
                """
            )
        }

        let results = try await CalCoFoodSearchServiceAdapter(client: makeClient())
            .searchFoods(query: "oats", scope: .history)

        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.id, "food-1")
        XCTAssertEqual(result.source, "USER")
        XCTAssertEqual(result.sourceID, "src-1")
        XCTAssertEqual(result.barcode, "12345")
        XCTAssertEqual(result.name, "Oats")
        XCTAssertEqual(result.brand, "Farm")
        XCTAssertEqual(result.categories, ["Breakfast"])

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/api/foods/search")
        XCTAssertEqual(queryValue(request, name: "q"), "oats")
        XCTAssertEqual(queryValue(request, name: "scope"), "history")
    }

    func testFoodSearchUnauthorizedMapsToServiceError() async throws {
        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "session_expired", message: "Session expired"),
                statusCode: 401
            )
        }

        do {
            _ = try await CalCoFoodSearchServiceAdapter(client: makeClient())
                .searchFoods(query: "oats", scope: .all)
            XCTFail("Expected a search error")
        } catch let error as FoodSearchServiceError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertTrue(isUnauthorizedFoodSearchError(error))
        }
    }

    func testFoodSearchCancellationPassesThroughToCaller() async throws {
        AdapterURLProtocol.setHandler { _ in
            .init(error: URLError(.cancelled))
        }

        do {
            _ = try await CalCoFoodSearchServiceAdapter(client: makeClient())
                .searchFoods(query: "oats", scope: .all)
            XCTFail("Expected cancellation to propagate")
        } catch {
            XCTAssertTrue(isCancelledFoodSearchError(error))
            XCTAssertFalse(error is FoodSearchServiceError)
        }
    }

    func testFoodDetailAndUnitsMapToFeatureModels() async throws {
        AdapterURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/api/foods/food-1":
                return self.json(
                    """
                    {
                      "id": "food-1",
                      "source": "USER",
                      "source_id": "src-1",
                      "visibility": "global",
                      "barcode": null,
                      "name": "Oats",
                      "brand": "Farm",
                      "categories": ["Breakfast"],
                      "default_quantity": "2",
                      "default_unit": "serving",
                      "nutrition_summary": {"per_100g": {}},
                      "nutrients": [
                        {
                          "code": "ENERGY_KCAL",
                          "amount_per_100g": "400",
                          "unit": "kcal",
                          "source": null,
                          "confidence": "approved"
                        }
                      ],
                      "servings": [{"unit": "serving", "grams_per_unit": "50"}],
                      "allowed_units": [
                        {"code": "serving", "name": "Serving", "kind": "serving"}
                      ]
                    }
                    """
                )
            case "/api/units":
                return self.json(
                    """
                    {
                      "items": [
                        {"code": "g", "name": "Grams", "kind": "mass"},
                        {"code": "serving", "name": "Serving", "kind": "serving"}
                      ]
                    }
                    """
                )
            default:
                return .init(statusCode: 404)
            }
        }

        let adapter = CalCoFoodDetailServiceAdapter(client: makeClient())
        async let foodTask = adapter.fetchFoodDetail(id: "food-1")
        async let unitsTask = adapter.fetchUnits()
        let (food, units) = try await (foodTask, unitsTask)

        XCTAssertEqual(food.id, "food-1")
        XCTAssertEqual(food.name, "Oats")
        XCTAssertEqual(food.brand, "Farm")
        XCTAssertEqual(food.categories, ["Breakfast"])
        XCTAssertEqual(food.defaultQuantity, "2")
        XCTAssertEqual(food.defaultUnit, "serving")
        XCTAssertEqual(food.nutrients, [
            FoodNutrient(code: "ENERGY_KCAL", amountPer100g: "400", unit: "kcal")
        ])
        XCTAssertEqual(food.servings, [FoodServing(unit: "serving", gramsPerUnit: "50")])
        XCTAssertEqual(food.allowedUnits, [
            FoodUnit(code: "serving", name: "Serving", kind: "serving")
        ])
        XCTAssertEqual(units.map(\.code), ["g", "serving"])
        XCTAssertEqual(units.first?.kind, "mass")
    }

    func testFoodDetailUnauthorizedMapsToTypedError() async throws {
        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "session_expired", message: "Session expired"),
                statusCode: 401
            )
        }

        do {
            _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
                .fetchFoodDetail(id: "food-1")
            XCTFail("Expected an unauthorized food detail error")
        } catch let error as FoodDetailServiceError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testCreateLogPreservesDateTimezoneSlotNotesAndMapsResponse() async throws {
        let idempotencyKey = "b6b1f5a4-3c2e-4a7e-9f6d-1a2b3c4d5e6f"
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                """
                {
                  "id": "log-9",
                  "log_date": "2026-11-16",
                  "device_timezone": "America/New_York",
                  "meal_slot": "lunch",
                  "item": {"type": "product", "id": "food-1", "name": "Oats"},
                  "quantity": {"amount": "150", "unit": "g"},
                  "nutrients": [],
                  "notes": "note"
                }
                """
            )
        }

        let request = FoodLogCreateRequest(
            date: LocalDiaryDate(year: 2026, month: 11, day: 16),
            timeZone: "America/New_York",
            mealSlot: .lunch,
            foodID: "food-1",
            amount: "150",
            unit: "g",
            notes: "note",
            idempotencyKey: idempotencyKey
        )
        let created = try await CalCoFoodDetailServiceAdapter(client: makeClient())
            .createLog(request)

        XCTAssertEqual(created.id, "log-9")
        XCTAssertEqual(created.date, LocalDiaryDate(year: 2026, month: 11, day: 16))
        XCTAssertEqual(created.mealSlot, .lunch)

        let urlRequest = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.path, "/api/logs")
        let body = try XCTUnwrap(bodyData(from: urlRequest))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(object["log_date"] as? String, "2026-11-16")
        XCTAssertEqual(object["device_timezone"] as? String, "America/New_York")
        XCTAssertEqual(object["meal_slot"] as? String, "lunch")
        XCTAssertEqual(object["notes"] as? String, "note")
        XCTAssertEqual(object["idempotency_key"] as? String, idempotencyKey)
        XCTAssertNil(object["idempotency-key"])

        let item = try XCTUnwrap(object["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "product")
        XCTAssertEqual(item["id"] as? String, "food-1")

        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["amount"] as? String, "150")
        XCTAssertEqual(quantity["unit"] as? String, "g")
    }

    func testCreateLogUnauthorizedMapsToTypedError() async throws {
        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "session_expired", message: "Session expired"),
                statusCode: 401
            )
        }

        do {
            _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
                .createLog(
                    FoodLogCreateRequest(
                        date: date,
                        timeZone: "Europe/Paris",
                        mealSlot: .dinner,
                        foodID: "food-1",
                        amount: "100",
                        unit: "g",
                        notes: nil
                    )
                )
            XCTFail("Expected an unauthorized create error")
        } catch let error as FoodDetailServiceError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    private func createdLogJSON() -> String {
        """
        {
          "id": "log-9",
          "log_date": "2026-11-17",
          "device_timezone": "America/New_York",
          "meal_slot": "lunch",
          "item": {"type": "product", "id": "food-1", "name": "Oats"},
          "quantity": {"amount": "150", "unit": "g"},
          "nutrients": [],
          "notes": "Café"
        }
        """
    }

    private func preparedRequest(
        notes: String,
        baseURL: String = "http://127.0.0.1:3002"
    ) throws -> FoodLogCreateRequest {
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: "food-1",
            foodName: "Oats",
            date: date,
            mealSlot: .lunch,
            amount: "150",
            unit: "g",
            notes: notes,
            timeZoneIdentifier: "America/New_York",
            baseURL: URL(string: baseURL)!,
            idempotencyKey: "b6b1f5a4-3c2e-4a7e-9f6d-1a2b3c4d5e6f"
        )
        return prepared.request
    }

    func testCreateLogSendsPreparedBodyVerbatimIncludingNFDNotes() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(self.createdLogJSON(), statusCode: 201)
        }
        let request = try preparedRequest(notes: "Cafe\u{301}")

        _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
            .createLog(request)

        let urlRequest = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(try bodyData(from: urlRequest), request.encodedBody)
    }

    func testCreateLog201IsNotReplayedAnd200IsReplayed() async throws {
        let recorder = AdapterRequestRecorder()
        var statusCode = 201
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(self.createdLogJSON(), statusCode: statusCode)
        }
        let request = try preparedRequest(notes: "Café")
        let adapter = CalCoFoodDetailServiceAdapter(client: makeClient())

        let created = try await adapter.createLog(request)
        XCTAssertFalse(created.replayed)

        statusCode = 200
        let replayed = try await adapter.createLog(request)
        XCTAssertTrue(replayed.replayed)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testCreateLog409MapsConflict() async throws {
        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "conflict", message: "key was already used"),
                statusCode: 409
            )
        }

        do {
            _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
                .createLog(try preparedRequest(notes: "Café"))
            XCTFail("Expected a conflict error")
        } catch let error as FoodDetailServiceError {
            XCTAssertEqual(error, .conflict("key was already used"))
        }
    }

    func testCreateLogServerAndRequestTimeoutErrorsMapUncertain() async throws {
        for statusCode in [408, 500, 503] {
            AdapterURLProtocol.setHandler { _ in
                self.json(
                    self.errorJSON(code: "unknown", message: "try later"),
                    statusCode: statusCode
                )
            }
            do {
                _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
                    .createLog(try preparedRequest(notes: "Café"))
                XCTFail("Expected an uncertain error")
            } catch let error as FoodDetailServiceError {
                XCTAssertEqual(error, .uncertain("try later"))
            }
        }
    }

    func testCreateLogTransportTimeoutMapsUncertain() async throws {
        AdapterURLProtocol.setHandler { _ in
            .init(error: URLError(.timedOut))
        }

        do {
            _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
                .createLog(try preparedRequest(notes: "Café"))
            XCTFail("Expected an uncertain error")
        } catch let error as FoodDetailServiceError {
            guard case .uncertain = error else {
                return XCTFail("Expected an uncertain error, got \(error)")
            }
        }
    }

    func testCreateLogRefusesChangedBaseURLWithoutSending() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(self.createdLogJSON(), statusCode: 201)
        }
        let request = try preparedRequest(
            notes: "Café",
            baseURL: "https://another.example.com"
        )

        do {
            _ = try await CalCoFoodDetailServiceAdapter(client: makeClient())
                .createLog(request)
            XCTFail("Expected the changed server to be refused")
        } catch let error as FoodDetailServiceError {
            guard case .failed(let message) = error else {
                return XCTFail("Expected a definitive failure, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testSettingsAdapterLoadsTodayGoalAndCanonicalPreferences() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/api/goal":
                return self.json(
                    """
                    {
                      "requested_date": "2026-11-17",
                      "effective_from": "2026-11-01",
                      "source": "saved",
                      "calorie_target": "2140",
                      "protein_target_g": "160",
                      "carbs_target_g": "240",
                      "fat_target_g": "60"
                    }
                    """
                )
            case "/api/diary-preferences":
                return self.json(#"{"enabled_meal_slots": ["dinner", "breakfast"]}"#)
            default:
                return .init(statusCode: 404)
            }
        }

        let adapter = CalCoSettingsServiceAdapter(client: makeClient())
        let goal = try await adapter.fetchGoal(on: date)
        let preferences = try await adapter.fetchDiaryPreferences()

        XCTAssertEqual(goal.requestedDate, date)
        XCTAssertEqual(goal.effectiveFrom, LocalDiaryDate(year: 2026, month: 11, day: 1))
        XCTAssertEqual(goal.targets.calorieTarget, 2_140)
        XCTAssertEqual(goal.targets.proteinTargetG, 160)
        XCTAssertEqual(goal.targets.carbsTargetG, 240)
        XCTAssertEqual(goal.targets.fatTargetG, 60)
        XCTAssertEqual(preferences.enabledSlots, [.breakfast, .dinner])

        let goalRequest = try XCTUnwrap(
            recorder.requests.first(where: { $0.url?.path == "/api/goal" })
        )
        XCTAssertEqual(goalRequest.httpMethod, "GET")
        XCTAssertEqual(queryValue(goalRequest, name: "date"), "2026-11-17")
    }

    func testSettingsAdapterSavesGoalAndPreferenceContract() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/api/goal":
                return self.json(
                    """
                    {
                      "requested_date": "2026-11-17",
                      "effective_from": "2026-11-17",
                      "source": "saved",
                      "calorie_target": "2150",
                      "protein_target_g": "170",
                      "carbs_target_g": "210",
                      "fat_target_g": "70"
                    }
                    """
                )
            case "/api/diary-preferences":
                return self.json(#"{"enabled_meal_slots": ["breakfast", "dinner"]}"#)
            default:
                return .init(statusCode: 404)
            }
        }

        let adapter = CalCoSettingsServiceAdapter(client: makeClient())
        let savedGoal = try await adapter.saveGoal(SaveGoalRequest(
            localDate: date,
            deviceTimeZone: "Asia/Kolkata",
            targets: GoalTargets(
                calorieTarget: 2_150,
                proteinTargetG: 170,
                carbsTargetG: 210,
                fatTargetG: 70
            )
        ))
        let savedPreferences = try await adapter.updateDiaryPreferences(
            DiaryPreferences(enabledMealSlots: [.breakfast, .dinner])
        )

        XCTAssertEqual(savedGoal.effectiveFrom, date)
        XCTAssertEqual(savedPreferences.enabledMealSlots, [.breakfast, .dinner])

        let goalRequest = try XCTUnwrap(
            recorder.requests.first(where: { $0.url?.path == "/api/goal" })
        )
        XCTAssertEqual(goalRequest.httpMethod, "PUT")
        let goalBody = try XCTUnwrap(bodyData(from: goalRequest))
        let goalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: goalBody) as? [String: Any]
        )
        XCTAssertEqual(goalObject["local_date"] as? String, "2026-11-17")
        XCTAssertEqual(goalObject["device_timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual((goalObject["calorie_target"] as? NSNumber)?.doubleValue, 2_150)
        XCTAssertEqual((goalObject["protein_target_g"] as? NSNumber)?.doubleValue, 170)
        XCTAssertEqual((goalObject["carbs_target_g"] as? NSNumber)?.doubleValue, 210)
        XCTAssertEqual((goalObject["fat_target_g"] as? NSNumber)?.doubleValue, 70)

        let prefsRequest = try XCTUnwrap(
            recorder.requests.first(where: { $0.url?.path == "/api/diary-preferences" })
        )
        XCTAssertEqual(prefsRequest.httpMethod, "PUT")
        let prefsBody = try XCTUnwrap(bodyData(from: prefsRequest))
        let prefsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: prefsBody) as? [String: Any]
        )
        XCTAssertEqual(prefsObject["enabled_meal_slots"] as? [String], ["breakfast", "dinner"])
    }

    func testSettingsAdapterMapsDefinitiveRejectionAndUnauthorizedSeparately() async throws {
        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "validation", message: "invalid targets"),
                statusCode: 400
            )
        }
        do {
            _ = try await CalCoSettingsServiceAdapter(client: makeClient()).saveGoal(
                SaveGoalRequest(
                    localDate: date,
                    deviceTimeZone: "Asia/Kolkata",
                    targets: GoalTargets(
                        calorieTarget: 2_100,
                        proteinTargetG: 150,
                        carbsTargetG: 240,
                        fatTargetG: 60
                    )
                )
            )
            XCTFail("Expected a rejection")
        } catch let error as DiarySettingsServiceError {
            XCTAssertEqual(error, .rejected("invalid targets"))
        }

        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "session_expired", message: "Session expired"),
                statusCode: 401
            )
        }
        do {
            _ = try await CalCoSettingsServiceAdapter(client: makeClient())
                .fetchDiaryPreferences()
            XCTFail("Expected an unauthorized error")
        } catch let error as DiarySettingsServiceError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testSettingsAdapterPreservesCancellationAndLocalizesRateAndServerFallbacks() async throws {
        AdapterURLProtocol.setHandler { _ in .init(error: URLError(.cancelled)) }
        do {
            _ = try await CalCoSettingsServiceAdapter(client: makeClient())
                .fetchDiaryPreferences()
            XCTFail("Expected cancellation")
        } catch let error as DiarySettingsServiceError {
            XCTAssertEqual(error, .cancelled)
        }

        AdapterURLProtocol.setHandler { _ in
            self.json(self.errorJSON(code: "rate_limited", message: "slow down"), statusCode: 429)
        }
        do {
            _ = try await CalCoSettingsServiceAdapter(client: makeClient())
                .saveGoal(SaveGoalRequest(
                    localDate: date,
                    deviceTimeZone: "Asia/Kolkata",
                    targets: GoalTargets(
                        calorieTarget: 2_100,
                        proteinTargetG: 150,
                        carbsTargetG: 240,
                        fatTargetG: 60
                    )
                ))
            XCTFail("Expected a rate-limit rejection")
        } catch let error as DiarySettingsServiceError {
            XCTAssertEqual(error, .rejected(String(localized: "settings.error.rateLimited")))
        }

        AdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "unknown", message: "   "),
                statusCode: 503
            )
        }
        do {
            _ = try await CalCoSettingsServiceAdapter(client: makeClient())
                .fetchGoal(on: date)
            XCTFail("Expected a server error")
        } catch let error as DiarySettingsServiceError {
            XCTAssertEqual(error, .server(String(localized: "settings.error.server")))
        }

        XCTAssertTrue(isAmbiguousDiarySettingsError(DiarySettingsServiceError.cancelled))
        XCTAssertFalse(isAmbiguousDiarySettingsError(DiarySettingsServiceError.rejected("no")))
    }

    func testSettingsAdapterSendsExactScaleFiveDecimalGoalBody() async throws {
        let recorder = AdapterRequestRecorder()
        AdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                """
                {
                  "requested_date": "2026-11-17",
                  "effective_from": "2026-11-17",
                  "source": "saved",
                  "calorie_target": "2102.66673",
                  "protein_target_g": "150.12345",
                  "carbs_target_g": "240.54321",
                  "fat_target_g": "60.00001"
                }
                """
            )
        }
        let exact = GoalTargetsDecimal(
            calorieTarget: Decimal(string: "2102.66673")!,
            proteinTargetG: Decimal(string: "150.12345")!,
            carbsTargetG: Decimal(string: "240.54321")!,
            fatTargetG: Decimal(string: "60.00001")!
        )

        _ = try await CalCoSettingsServiceAdapter(client: makeClient()).saveGoal(
            SaveGoalRequest(
                localDate: date,
                deviceTimeZone: "Asia/Kolkata",
                exactTargets: exact
            )
        )

        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(bodyData(from: request))
        let raw = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"calorie_target\":2102.66673"))
        XCTAssertTrue(raw.contains("\"protein_target_g\":150.12345"))
        XCTAssertTrue(raw.contains("\"carbs_target_g\":240.54321"))
        XCTAssertTrue(raw.contains("\"fat_target_g\":60.00001"))
    }
}
