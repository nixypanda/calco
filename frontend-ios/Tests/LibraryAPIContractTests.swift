import XCTest

@testable import CalCo

private final class LibraryURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
        let error: Error?

        init(statusCode: Int = 200, body: Data = Data(), error: Error? = nil) {
            self.statusCode = statusCode
            self.body = body
            self.error = error
        }
    }

    private static let lock = NSLock()
    private static var storedHandler: (URLRequest) -> Stub = { _ in Stub(statusCode: 500) }

    static func setHandler(_ handler: @escaping (URLRequest) -> Stub) {
        lock.withLock { storedHandler = handler }
    }

    private static var handler: (URLRequest) -> Stub {
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

private final class LibraryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var all: [URLRequest] {
        lock.withLock { requests }
    }
}

final class LibraryAPIContractTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    override func setUp() {
        super.setUp()
        LibraryURLProtocol.setHandler { _ in .init(statusCode: 500) }
    }

    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryURLProtocol.self]
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func json(_ raw: String, status: Int = 200) -> LibraryURLProtocol.Stub {
        .init(statusCode: status, body: Data(raw.utf8))
    }

    private func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBytes { raw in
                stream.read(
                    raw.bindMemory(to: UInt8.self).baseAddress!,
                    maxLength: raw.count
                )
            }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    func testCreateEncodesFullAggregateAndReturnsID() async throws {
        let recorder = LibraryRequestRecorder()
        LibraryURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(#"{"id":"food-1"}"#, status: 201)
        }
        let request = CustomFoodWriteRequest(
            name: "Oats",
            brand: nil,
            categories: ["breakfast"],
            defaultQuantity: 1,
            defaultUnit: "cup",
            nutrients: [
                CustomFoodNutrientWrite(code: "ENERGY_KCAL", amountPer100g: 12.5),
                CustomFoodNutrientWrite(code: "PROTEIN_G", amountPer100g: 4),
            ],
            servings: [CustomFoodServingWrite(unit: "cup", gramsPerUnit: 40)]
        )

        let id = try await makeClient().createCustomFood(request)

        XCTAssertEqual(id, "food-1")
        let recorded = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.url?.path, "/api/foods/custom")
        let body = try XCTUnwrap(bodyData(recorded))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["name"] as? String, "Oats")
        XCTAssertNil(object["brand"])
        XCTAssertEqual(object["categories"] as? [String], ["breakfast"])
        XCTAssertEqual(
            (object["default_quantity"] as? NSNumber)?.doubleValue,
            1
        )
        XCTAssertEqual(object["default_unit"] as? String, "cup")
        let nutrients = try XCTUnwrap(object["nutrients"] as? [[String: Any]])
        XCTAssertEqual(nutrients.count, 2)
        XCTAssertEqual(
            (nutrients[0]["amount_per_100g"] as? NSNumber)?.doubleValue,
            12.5
        )
        let servings = try XCTUnwrap(object["servings"] as? [[String: Any]])
        XCTAssertEqual(servings[0]["unit"] as? String, "cup")
        XCTAssertEqual(
            (servings[0]["grams_per_unit"] as? NSNumber)?.doubleValue,
            40
        )
    }

    func testListCustomFoodsDecodesProductDetails() async throws {
        LibraryURLProtocol.setHandler { _ in
            self.json(
                """
                {
                  "items": [{
                    "id": "food-1",
                    "source": "USER",
                    "visibility": "global",
                    "name": "Oats",
                    "brand": "Home",
                    "categories": ["breakfast"],
                    "default_quantity": "100",
                    "default_unit": "g",
                    "nutrition_summary": {"per_100g": {"energy_kcal": "389"}},
                    "nutrients": [
                      {"code": "ENERGY_KCAL", "amount_per_100g": "389", "unit": "kcal"}
                    ],
                    "servings": [],
                    "allowed_units": [
                      {"code": "g", "name": "Gram", "kind": "mass"}
                    ]
                  }]
                }
                """
            )
        }
        let foods = try await makeClient().listCustomFoods()
        XCTAssertEqual(foods.count, 1)
        XCTAssertEqual(foods[0].name, "Oats")
        XCTAssertEqual(foods[0].defaultQuantity, "100")
        XCTAssertEqual(foods[0].allowedUnits.first?.code, "g")
        let mapped = CustomFood(product: foods[0])
        XCTAssertEqual(mapped.nutrients.first?.amountPer100g, "389")
    }

    func testListNutrientsDecodesDefinitions() async throws {
        LibraryURLProtocol.setHandler { _ in
            self.json(
                """
                {"items":[
                  {"code":"ENERGY_KCAL","name":"Energy","unit":"kcal","category":"energy"}
                ]}
                """
            )
        }
        let definitions = try await makeClient().listNutrientDefinitions()
        XCTAssertEqual(definitions, [
            NutrientDefinition(
                code: "ENERGY_KCAL",
                name: "Energy",
                unit: "kcal",
                category: "energy"
            ),
        ])
    }

    func testUpdateAndDeleteUseCustomFoodPaths() async throws {
        let recorder = LibraryRequestRecorder()
        LibraryURLProtocol.setHandler { request in
            recorder.record(request)
            if request.httpMethod == "DELETE" {
                return .init(statusCode: 204)
            }
            return self.json(#"{"id":"food-2"}"#)
        }
        let request = CustomFoodWriteRequest(
            name: "Oats",
            nutrients: [
                CustomFoodNutrientWrite(code: "ENERGY_KCAL", amountPer100g: 100),
            ]
        )
        let id = try await makeClient().updateCustomFood(id: "food-2", body: request)
        XCTAssertEqual(id, "food-2")
        try await makeClient().deleteCustomFood(id: "food-2")

        XCTAssertEqual(recorder.all[0].httpMethod, "PUT")
        XCTAssertEqual(recorder.all[0].url?.path, "/api/foods/custom/food-2")
        XCTAssertEqual(recorder.all[1].httpMethod, "DELETE")
        XCTAssertEqual(recorder.all[1].url?.path, "/api/foods/custom/food-2")
    }

    func testAdHocRequestUsesTopLevelIdempotencyKeyAndReturnsReplayStatus() async throws {
        let recorder = LibraryRequestRecorder()
        LibraryURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                """
                {
                  "id": "log-1",
                  "log_date": "2026-11-19",
                  "meal_slot": "lunch",
                  "item": {"type": "ad_hoc", "name": "Bowl"},
                  "quantity": {"amount": "1", "unit": "bowl"},
                  "nutrients": [
                    {"code": "ENERGY_KCAL", "amount": "250", "unit": "kcal"},
                    {"code": "PROTEIN_G", "amount": "10", "unit": "g"},
                    {"code": "CARBS_G", "amount": "40", "unit": "g"},
                    {"code": "FAT_G", "amount": "5", "unit": "g"}
                  ]
                }
                """,
                status: 200
            )
        }
        let draft = LogSubmissionDraft(
            item: .adHoc(name: "Bowl", brand: nil),
            date: date,
            mealSlot: .lunch,
            amount: "1",
            unit: "bowl",
            notes: nil,
            timeZone: "Asia/Kolkata",
            nutrients: [
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "250", unit: "kcal"),
                NutrientAmountValue(code: "PROTEIN_G", amount: "10", unit: "g"),
                NutrientAmountValue(code: "CARBS_G", amount: "40", unit: "g"),
                NutrientAmountValue(code: "FAT_G", amount: "5", unit: "g"),
            ]
        )
        let request = try AdHocLogRequestBuilder.makeRequest(
            draft: draft,
            idempotencyKey: "ad-hoc-key"
        )
        let (log, status) = try await makeClient().createAdHocLog(request)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(log.id, "log-1")
        let recorded = try XCTUnwrap(recorder.all.first)
        XCTAssertEqual(recorded.url?.path, "/api/logs/ad-hoc")
        let body = try XCTUnwrap(bodyData(recorded))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["idempotency_key"] as? String, "ad-hoc-key")
        XCTAssertEqual(object["name"] as? String, "Bowl")
        XCTAssertEqual((object["quantity"] as? [String: Any])?["unit"] as? String, "bowl")
        let nutrients = try XCTUnwrap(object["nutrients"] as? [[String: Any]])
        XCTAssertEqual(nutrients.compactMap { $0["code"] as? String }, [
            "CARBS_G", "ENERGY_KCAL", "FAT_G", "PROTEIN_G",
        ])
    }

    func testAdapterMapsHTTPErrorsWithoutTreatingAmbiguityAsRejection() {
        func payload(_ message: String) -> APIErrorPayload {
            APIErrorPayload(code: "validation", message: message)
        }
        XCTAssertEqual(
            CalCoLibraryServiceAdapter.map(
                CalCoAPIError.badStatus(statusCode: 403, payload: payload("forbidden"))
            ),
            .failed("forbidden")
        )
        XCTAssertEqual(
            CalCoLibraryServiceAdapter.map(
                CalCoAPIError.badStatus(statusCode: 404, payload: payload("missing"))
            ),
            .notFound("missing")
        )
        XCTAssertEqual(
            CalCoLibraryServiceAdapter.map(
                CalCoAPIError.badStatus(statusCode: 409, payload: payload("conflict"))
            ),
            .conflict("conflict")
        )
        XCTAssertEqual(
            CalCoLibraryServiceAdapter.map(CalCoAPIError.timeout),
            .uncertain(String(localized: "library.error.uncertain"))
        )
        XCTAssertEqual(
            CalCoLibraryServiceAdapter.map(
                CalCoAPIError.badStatus(statusCode: 503, payload: payload("busy"))
            ),
            .uncertain("busy")
        )
        XCTAssertEqual(
            CalCoLibraryServiceAdapter.map(CalCoAPIError.unauthorized(nil)),
            .unauthorized
        )
    }
}
