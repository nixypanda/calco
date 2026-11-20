import XCTest

@testable import CalCo

private final class CapabilitiesURLProtocol: URLProtocol {
    static var responseBody: Data?
    static var statusCode = 200
    static var requestURL: URL?
    static var requestMethod: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestURL = request.url
        Self.requestMethod = request.httpMethod
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = Self.responseBody {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CapabilitiesTests: XCTestCase {
    func testVersionTwoCapabilityRequiresAllBatchSafetyFields() throws {
        let capability = try decode(
            """
            {
              "log_creation_idempotency": {
                "version": 2,
                "single": true,
                "ad_hoc": true,
                "batch": true,
                "batch_key_location": "top_level",
                "deleted_operation_replay": "conflict",
                "pre_migration_deleted_keys": "reconciliation_only",
                "request_account_binding": "x-calco-account-id"
              }
            }
            """
        )

        XCTAssertEqual(capability.requestAccountBinding, "x-calco-account-id")
        XCTAssertTrue(capability.supportsBatchIdempotency)
        XCTAssertTrue(capability.supportsAdHocIdempotency)
        XCTAssertTrue(capability.supports(.single))
    }

    func testUnreadyCapabilityFailsClosed() throws {
        let capability = try decode(
            """
            {
              "log_creation_idempotency": {
                "version": 0,
                "single": false,
                "ad_hoc": false,
                "batch": false,
                "batch_key_location": null,
                "deleted_operation_replay": "unavailable",
                "pre_migration_deleted_keys": "reconciliation_only"
              }
            }
            """
        )

        XCTAssertFalse(capability.supports(.batch))
        XCTAssertFalse(capability.supports(.adHoc))
        XCTAssertFalse(capability.supports(.single))
    }

    func testMissingOrUnexpectedFieldsAreRejected() {
        XCTAssertThrowsError(
            try decode(
                #"{"log_creation_idempotency":{"version":2,"batch":true}}"#
            )
        )
    }

    func testClientRequestsAuthenticatedCapabilitiesEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapabilitiesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CalCoAPIClient(
            baseURL: URL(string: "https://calco.example.com")!,
            session: session
        )
        CapabilitiesURLProtocol.statusCode = 200
        CapabilitiesURLProtocol.responseBody = Data(
            """
            {
              "log_creation_idempotency": {
                "version": 2,
                "single": true,
                "ad_hoc": true,
                "batch": true,
                "batch_key_location": "top_level",
                "deleted_operation_replay": "conflict",
                "pre_migration_deleted_keys": "reconciliation_only",
                "request_account_binding": "x-calco-account-id"
              }
            }
            """.utf8
        )

        let capability = try await client.fetchCapabilities()

        XCTAssertEqual(capability.version, 2)
        XCTAssertEqual(
            CapabilitiesURLProtocol.requestURL?.path,
            "/api/capabilities"
        )
        XCTAssertEqual(CapabilitiesURLProtocol.requestMethod, "GET")
    }

    private func decode(_ json: String) throws -> LogCreationIdempotencyCapability {
        try JSONDecoder()
            .decode(CapabilitiesResponse.self, from: Data(json.utf8))
            .logCreationIdempotency
    }
}
