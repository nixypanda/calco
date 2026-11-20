import XCTest

@testable import CalCo

private final class APIKeyURLProtocol: URLProtocol {
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

private final class APIKeyRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}

final class APIKeyContractTests: XCTestCase {
    override func setUp() {
        super.setUp()
        APIKeyURLProtocol.setHandler { _ in .init(statusCode: 500) }
    }

    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIKeyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: session
        )
    }

    private func json(
        _ raw: String,
        statusCode: Int = 200
    ) -> APIKeyURLProtocol.Stub {
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

    // MARK: - DTOs

    func testListDecodesMetadataAndPreservesUnknownScope() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "id": "key-1",
                  "name": "Backup",
                  "token_hint": "calco_pat_abc123",
                  "scope": "read",
                  "created_at": "2026-11-19T10:00:00.123456Z",
                  "last_used_at": null,
                  "expires_at": null
                },
                {
                  "id": "key-2",
                  "name": "Future",
                  "token_hint": "calco_pat_future",
                  "scope": "future_scope",
                  "created_at": "2026-11-18T10:00:00Z",
                  "last_used_at": "2026-11-19T11:00:00Z",
                  "expires_at": "2026-12-19T10:00:00Z"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(APIKeyListResponse.self, from: data)

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].name, "Backup")
        XCTAssertEqual(response.items[0].scope, .read)
        XCTAssertNil(response.items[0].lastUsedAt)
        XCTAssertNil(response.items[0].expiresAt)
        XCTAssertEqual(response.items[1].scope, .unknown("future_scope"))
        XCTAssertEqual(response.items[1].lastUsedAt, "2026-11-19T11:00:00Z")
    }

    func testCreateResponseDecodesFlattenedSecretAndRedactsDescription() throws {
        let rawSecret = "calco_pat_fixture_not_a_real_secret"
        let data = Data(
            """
            {
              "id": "key-3",
              "name": "Script",
              "token_hint": "calco_pat_fixture",
              "scope": "read_write",
              "created_at": "2026-11-19T10:00:00Z",
              "last_used_at": null,
              "expires_at": "2027-02-17T10:00:00Z",
              "token": "\(rawSecret)"
            }
            """.utf8
        )

        let created = try JSONDecoder().decode(CreatedAPIKey.self, from: data)

        XCTAssertEqual(created.key.id, "key-3")
        XCTAssertEqual(created.key.scope, .readWrite)
        XCTAssertEqual(created.secret.value, rawSecret)
        XCTAssertEqual(String(describing: created.secret), "<redacted>")
        XCTAssertEqual(String(reflecting: created.secret), "<redacted>")
        XCTAssertFalse(String(describing: created.secret).contains(rawSecret))
    }

    func testCreateRequestOmitsNeverExpiryAndUsesWireScope() throws {
        let never = APIKeyCreateRequest(
            name: "Backup",
            scope: .read,
            expiresInDays: nil
        )
        let neverObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(never))
                as? [String: Any]
        )
        XCTAssertEqual(neverObject["name"] as? String, "Backup")
        XCTAssertEqual(neverObject["scope"] as? String, "read")
        XCTAssertNil(neverObject["expires_in_days"])

        let expiry = APIKeyCreateRequest(
            name: "Automation",
            scope: .readWrite,
            expiresInDays: 30
        )
        let expiryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(expiry))
                as? [String: Any]
        )
        XCTAssertEqual(expiryObject["scope"] as? String, "read_write")
        XCTAssertEqual(expiryObject["expires_in_days"] as? Int, 30)
    }

    // MARK: - Name / expiry / date rules

    func testNameValidationMatchesBackendTrimScalarAndInvisibleRules() {
        XCTAssertEqual(
            try? APIKeyNameValidator.validatedName(from: "  Script  ").get(),
            "Script"
        )
        XCTAssertEqual(
            try? APIKeyNameValidator.validatedName(
                from: String(repeating: "a", count: 64)
            ).get(),
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(
                from: String(repeating: "a", count: 65)
            ),
            .failure(.tooLong)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: " \u{00A0}\n\u{0085} "),
            .failure(.required)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: "Script\u{202E}"),
            .failure(.invalidCharacters)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: "\u{200B}"),
            .failure(.invalidCharacters)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: "\u{200D}"),
            .failure(.invalidCharacters)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: "a\u{200D}b"),
            .success("a\u{200D}b")
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: "line\u{2028}break"),
            .failure(.invalidCharacters)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(from: "Script\u{0007}"),
            .failure(.invalidCharacters)
        )
        XCTAssertEqual(
            APIKeyNameValidator.validatedName(
                from: String(repeating: "😀", count: 65)
            ),
            .failure(.tooLong)
        )
    }

    func testExpiryChoicesStayWithinServerLimits() {
        XCTAssertEqual(APIKeyExpiryChoice.default, .days90)
        XCTAssertEqual(APIKeyExpiryChoice.days30.expiresInDays, 30)
        XCTAssertEqual(APIKeyExpiryChoice.days90.expiresInDays, 90)
        XCTAssertEqual(APIKeyExpiryChoice.days365.expiresInDays, 365)
        XCTAssertNil(APIKeyExpiryChoice.never.expiresInDays)

        for choice in APIKeyExpiryChoice.allCases {
            if let days = choice.expiresInDays {
                XCTAssertTrue(APIKeyExpiryChoice.isValidExpiryDays(days))
            }
        }
        XCTAssertFalse(APIKeyExpiryChoice.isValidExpiryDays(0))
        XCTAssertFalse(APIKeyExpiryChoice.isValidExpiryDays(3_651))
    }

    func testTimestampParsingAndExpiredMetadata() throws {
        let fractional = try XCTUnwrap(
            APIKeyTimestamp.date(from: "2026-11-19T10:00:00.123456Z")
        )
        let plain = try XCTUnwrap(
            APIKeyTimestamp.date(from: "2026-11-19T10:00:00Z")
        )
        XCTAssertEqual(
            fractional.timeIntervalSince1970,
            plain.timeIntervalSince1970 + 0.123456,
            accuracy: 0.001
        )
        XCTAssertEqual(
            APIKeyTimestamp.displayString(
                from: "not-a-dateT10:00:00Z",
                locale: Locale(identifier: "en_US"),
                timeZone: TimeZone(secondsFromGMT: 0)!
            ),
            "not-a-date"
        )

        let key = APIKey(
            id: "key-1",
            name: "Expired",
            tokenHint: "calco_pat_hint",
            scope: .read,
            createdAt: "2026-11-01T10:00:00Z",
            expiresAt: "2026-11-18T10:00:00Z"
        )
        let now = try XCTUnwrap(APIKeyTimestamp.date(from: "2026-11-19T10:00:00Z"))
        XCTAssertTrue(key.isExpired(at: now))
        XCTAssertFalse(key.isExpired(at: now.addingTimeInterval(-86_401)))
    }

    // MARK: - API / adapter contract

    func testListUsesSessionPathAndNoAuthorizationHeader() async throws {
        let recorder = APIKeyRequestRecorder()
        APIKeyURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                #"{"items":[{"id":"key-1","name":"Backup","token_hint":"calco_pat_abc","scope":"read","created_at":"2026-11-19T10:00:00Z","last_used_at":null,"expires_at":null}]}"#
            )
        }

        let keys = try await CalCoAPIKeysServiceAdapter(client: makeClient())
            .listAPIKeys()

        XCTAssertEqual(keys.map(\.id), ["key-1"])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/auth/api-keys")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCreateUsesOneTimeTokenTrimsNameAndEncodesExpiry() async throws {
        let recorder = APIKeyRequestRecorder()
        APIKeyURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(
                """
                {
                  "id": "key-2",
                  "name": "Nightly backup",
                  "token_hint": "calco_pat_fixture",
                  "scope": "read_write",
                  "created_at": "2026-11-19T10:00:00Z",
                  "last_used_at": null,
                  "expires_at": "2026-12-19T10:00:00Z",
                  "token": "calco_pat_fixture_one_time"
                }
                """,
                statusCode: 201
            )
        }

        let created = try await CalCoAPIKeysServiceAdapter(client: makeClient())
            .createAPIKey(
                APIKeyCreateRequest(
                    name: "Nightly backup",
                    scope: .readWrite,
                    expiresInDays: 30
                )
            )

        XCTAssertEqual(created.key.id, "key-2")
        XCTAssertEqual(created.secret.value, "calco_pat_fixture_one_time")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/auth/api-keys")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(bodyData(from: request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["name"] as? String, "Nightly backup")
        XCTAssertEqual(object["scope"] as? String, "read_write")
        XCTAssertEqual(object["expires_in_days"] as? Int, 30)
    }

    func testRevokeUsesDeletePathAndAcceptsNoContent() async throws {
        let recorder = APIKeyRequestRecorder()
        APIKeyURLProtocol.setHandler { request in
            recorder.record(request)
            return .init(statusCode: 204)
        }

        try await CalCoAPIKeysServiceAdapter(client: makeClient())
            .revokeAPIKey(id: "key-2")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/auth/api-keys/key-2")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAdapterMapsLimitAndAmbiguousServerFailures() async {
        APIKeyURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "api_key_limit_reached", message: "limit"),
                statusCode: 409
            )
        }
        let service = CalCoAPIKeysServiceAdapter(client: makeClient())
        do {
            _ = try await service.createAPIKey(
                APIKeyCreateRequest(name: "Key", scope: .read, expiresInDays: nil)
            )
            XCTFail("Expected a limit failure")
        } catch {
            XCTAssertEqual(error as? APIKeyServiceError, .limitReached)
        }

        APIKeyURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "internal_error", message: "internal server error"),
                statusCode: 500
            )
        }
        do {
            _ = try await service.createAPIKey(
                APIKeyCreateRequest(name: "Key", scope: .read, expiresInDays: nil)
            )
            XCTFail("Expected a server failure")
        } catch {
            let mapped = error as? APIKeyServiceError
            guard case .server = mapped else {
                return XCTFail("Expected .server, got \(String(describing: mapped))")
            }
            XCTAssertTrue(mapped?.isAmbiguousCreateFailure == true)
        }

        APIKeyURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "invalid_api_key_name", message: "invalid name"),
                statusCode: 400
            )
        }
        do {
            _ = try await service.createAPIKey(
                APIKeyCreateRequest(name: "Key", scope: .read, expiresInDays: nil)
            )
            XCTFail("Expected a rejected failure")
        } catch {
            guard case .rejected = error as? APIKeyServiceError else {
                return XCTFail("Expected .rejected, got \(error)")
            }
        }
    }
}
