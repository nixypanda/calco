import Foundation
import XCTest

@testable import CalCo

// Focused wire-level tests for the log editor's PUT/GET/DELETE plumbing.
// Uses its own URLProtocol class and handler so it cannot interfere with the
// shared AdapterURLProtocol used by ServiceAdaptersTests.

private final class LogEditorURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
    }

    typealias Handler = (URLRequest) -> Stub

    private static let lock = NSLock()
    private static var storedHandler: Handler = { _ in Stub(statusCode: 500, body: Data()) }

    static func setHandler(_ handler: @escaping Handler) {
        lock.withLock { storedHandler = handler }
    }

    private static var handler: Handler { lock.withLock { storedHandler } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.handler(request)
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

private final class LogEditorRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [URLRequest] { lock.withLock { storage } }
}

@MainActor
final class LogUpdateRequestTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)

    override func setUp() {
        super.setUp()
        LogEditorURLProtocol.setHandler { _ in .init(statusCode: 500, body: Data()) }
    }

    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogEditorURLProtocol.self]
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
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

    private func jsonObject(from request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(bodyData(from: request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func encodedRequest(_ request: UpdateLogRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: "https://calco.test")!)
        urlRequest.httpMethod = "PUT"
        urlRequest.httpBody = try JSONEncoder().encode(request)
        return urlRequest
    }

    private func stubLog(
        id: String = "log-1",
        statusCode: Int = 200
    ) -> LogEditorURLProtocol.Stub {
        .init(
            statusCode: statusCode,
            body: Data(
                """
                {
                  "id": "\(id)",
                  "log_date": "2026-11-17",
                  "device_timezone": "Europe/Paris",
                  "meal_slot": "lunch",
                  "item": {"type": "product", "id": "food-1", "name": "Oats"},
                  "quantity": {"amount": "150", "unit": "g"},
                  "nutrients": [
                    {"code": "ENERGY_KCAL", "amount": "300", "unit": "kcal"}
                  ],
                  "notes": "with milk"
                }
                """.utf8
            )
        )
    }

    private func errorStub(code: String, message: String) -> LogEditorURLProtocol.Stub {
        .init(
            statusCode: 401,
            body: Data(
                #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8
            )
        )
    }

    func testClearableFieldsEncodeExplicitNullAndAbsentFieldsAreOmitted() throws {
        let request = UpdateLogRequest(
            mealSlot: .null,
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: .null
        )
        let object = try jsonObject(from: encodedRequest(request))

        XCTAssertTrue(object.keys.contains("meal_slot"))
        XCTAssertTrue(object["meal_slot"] is NSNull)
        XCTAssertTrue(object.keys.contains("notes"))
        XCTAssertTrue(object["notes"] is NSNull)
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["amount"] as? String, "150")
        XCTAssertEqual(quantity["unit"] as? String, "g")
        XCTAssertFalse(object.keys.contains("log_date"))
        XCTAssertFalse(object.keys.contains("device_timezone"))
    }

    func testSetFieldsEncodeConcreteValues() throws {
        let request = UpdateLogRequest(
            logDate: date,
            mealSlot: .value(.lateNightSnack),
            deviceTimeZone: .value("Europe/Paris"),
            quantity: NutritionQuantity(amount: "2", unit: "serving"),
            notes: .value("before bed")
        )
        let object = try jsonObject(from: encodedRequest(request))

        XCTAssertEqual(object["log_date"] as? String, "2026-11-17")
        XCTAssertEqual(object["meal_slot"] as? String, "late_night_snack")
        XCTAssertEqual(object["device_timezone"] as? String, "Europe/Paris")
        XCTAssertEqual(object["notes"] as? String, "before bed")
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["amount"] as? String, "2")
        XCTAssertEqual(quantity["unit"] as? String, "serving")
    }

    func testAdapterGetUpdateAndDeleteUseExpectedEndpoints() async throws {
        let recorder = LogEditorRequestRecorder()
        LogEditorURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.httpMethod {
            case "DELETE":
                return .init(statusCode: 204, body: Data())
            default:
                return self.stubLog()
            }
        }
        let adapter = CalCoDiaryServiceAdapter(client: makeClient())

        let fetched = try await adapter.getLog(id: "log-1")
        let updated = try await adapter.updateLog(
            id: "log-1",
            request: UpdateLogRequest(
                mealSlot: .null,
                quantity: NutritionQuantity(amount: "150", unit: "g"),
                notes: .null
            )
        )
        try await adapter.deleteLog(id: "log-1")

        XCTAssertEqual(fetched.id, "log-1")
        XCTAssertEqual(fetched.mealSlot, .lunch)
        XCTAssertEqual(fetched.title, "Oats")
        XCTAssertEqual(fetched.quantity, NutritionQuantity(amount: "150", unit: "g"))
        XCTAssertEqual(fetched.notes, "with milk")
        XCTAssertEqual(updated.calories, 300)

        let getRequest = try XCTUnwrap(recorder.requests.first(where: { $0.httpMethod == "GET" }))
        XCTAssertEqual(getRequest.url?.path, "/api/logs/log-1")
        let putRequest = try XCTUnwrap(recorder.requests.first(where: { $0.httpMethod == "PUT" }))
        XCTAssertEqual(putRequest.url?.path, "/api/logs/log-1")
        let putBody = try jsonObject(from: putRequest)
        XCTAssertTrue(putBody["meal_slot"] is NSNull)
        XCTAssertTrue(putBody["notes"] is NSNull)
        let deleteRequest = try XCTUnwrap(recorder.requests.first(where: { $0.httpMethod == "DELETE" }))
        XCTAssertEqual(deleteRequest.url?.path, "/api/logs/log-1")
    }

    func testAdapterFetchUnitsMapsProductUnitsToFoodUnits() async throws {
        LogEditorURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/api/units")
            return .init(
                statusCode: 200,
                body: Data(
                    #"{"items":[{"code":"g","name":"Gram","kind":"mass"},{"code":"serving","name":"Serving","kind":"serving"}]}"#.utf8
                )
            )
        }

        let units = try await CalCoDiaryServiceAdapter(client: makeClient()).fetchUnits()

        XCTAssertEqual(units.map(\.code), ["g", "serving"])
        XCTAssertEqual(units.first?.name, "Gram")
        XCTAssertEqual(units.first?.kind, "mass")
    }

    func testAdapterMapsUnauthorizedFromMutationEndpoints() async throws {
        LogEditorURLProtocol.setHandler { _ in
            self.errorStub(code: "session_expired", message: "Session expired")
        }
        let adapter = CalCoDiaryServiceAdapter(client: makeClient())

        for operation in ["get", "update", "delete"] {
            do {
                switch operation {
                case "get": _ = try await adapter.getLog(id: "log-1")
                case "update":
                    _ = try await adapter.updateLog(
                        id: "log-1",
                        request: UpdateLogRequest(mealSlot: .null)
                    )
                default: try await adapter.deleteLog(id: "log-1")
                }
                XCTFail("Expected an unauthorized error for \(operation)")
            } catch let error as DiaryServiceError {
                XCTAssertEqual(error, .unauthorized)
                XCTAssertTrue(isUnauthorizedDiaryError(error))
            }
        }
    }

    func testAdapterMapsServerErrorFromUpdateToMessage() async throws {
        LogEditorURLProtocol.setHandler { _ in
            .init(
                statusCode: 422,
                body: Data(#"{"error":{"code":"validation","message":"Invalid quantity"}}"#.utf8)
            )
        }

        do {
            _ = try await CalCoDiaryServiceAdapter(client: makeClient()).updateLog(
                id: "log-1",
                request: UpdateLogRequest(quantity: NutritionQuantity(amount: "0", unit: "g"))
            )
            XCTFail("Expected a server error")
        } catch let error as DiaryServiceError {
            XCTAssertEqual(error, .server("Invalid quantity"))
            XCTAssertEqual(diaryErrorMessage(error), "Invalid quantity")
        }
    }
}
