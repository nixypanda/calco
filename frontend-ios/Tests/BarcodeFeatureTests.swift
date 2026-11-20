import XCTest

@testable import CalCo

private actor FakeBarcodeService: BarcodeServicing {
    private var results: [Result<BarcodeLookup, Error>] = []
    private var calls: [String] = []
    private var firstDelayNanoseconds: UInt64 = 0

    func enqueue(_ result: Result<BarcodeLookup, Error>) {
        results.append(result)
    }

    func setFirstDelay(_ value: UInt64) {
        firstDelayNanoseconds = value
    }

    func recordedCalls() -> [String] { calls }

    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup {
        calls.append(barcode)
        guard !results.isEmpty else { throw BarcodeServiceError.invalidResponse }
        let result = results.removeFirst()
        if calls.count == 1, firstDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: firstDelayNanoseconds)
        }
        return try result.get()
    }
}

private final class BarcodeURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let error: Error?

        init(
            statusCode: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data(),
            error: Error? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    private static let lock = NSLock()
    private static var storedHandler: (URLRequest) -> Stub = { _ in Stub(statusCode: 500) }
    private static var storedRequests: [URLRequest] = []

    static func setUp(handler: @escaping (URLRequest) -> Stub) {
        lock.lock()
        storedHandler = handler
        storedRequests = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        BarcodeURLProtocol.lock.lock()
        let handler = BarcodeURLProtocol.storedHandler
        BarcodeURLProtocol.storedRequests.append(request)
        BarcodeURLProtocol.lock.unlock()

        let stub = handler(request)
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

@MainActor
final class BarcodeFeatureTests: XCTestCase {
    private func makeProduct(
        id: String = "food-1",
        name: String = "Imported oats",
        barcode: String = "0001234"
    ) -> ProductDetail {
        ProductDetail(
            id: id,
            source: "OFF",
            visibility: "global",
            barcode: barcode,
            name: name,
            brand: "Farm",
            nutritionSummary: ProductNutritionSummary(
                per100g: NutritionSummary(
                    energyKcal: "389",
                    proteinG: "16.9",
                    carbsG: "66.3",
                    fatG: "6.9"
                )
            ),
            nutrients: [
                ProductNutrient(
                    code: NutrientCodes.energyKcal,
                    amountPer100g: "389",
                    unit: "kcal"
                )
            ]
        )
    }

    private func makeLookup(
        origin: BarcodeLookupOrigin = .local,
        note: String? = nil,
        barcode: String = "0001234"
    ) -> BarcodeLookup {
        BarcodeLookup(
            product: makeProduct(barcode: barcode),
            lookup: BarcodeLookupMeta(origin: origin, note: note)
        )
    }

    private func makeViewModel(
        service: FakeBarcodeService,
        onSelect: @escaping (BarcodeLookup) -> Void = { _ in },
        onCreate: @escaping (BarcodeCustomFoodDraft) -> Void = { _ in },
        onExpired: @escaping () -> Void = {}
    ) -> BarcodeViewModel {
        BarcodeViewModel(
            service: service,
            onSelectProduct: onSelect,
            onCreateCustomFood: onCreate,
            onSessionExpired: onExpired
        )
    }

    // MARK: - Validation

    func testValidationPreservesLeadingZerosAndRejectsUnsupportedInput() {
        XCTAssertEqual(
            BarcodeValidation.sanitizedInput("00 12-34a"),
            "001234"
        )
        XCTAssertEqual(
            BarcodeValidation.validated("0001234"),
            .success("0001234")
        )
        XCTAssertEqual(
            BarcodeValidation.validated(" 0001234 "),
            .success("0001234")
        )
        XCTAssertEqual(BarcodeValidation.validated("123"), .failure(.invalidLength))
        XCTAssertEqual(
            BarcodeValidation.validated("1234567890123456789012345"),
            .failure(.invalidLength)
        )
        XCTAssertEqual(
            BarcodeValidation.validated("12a34"),
            .failure(.invalidCharacters)
        )
        XCTAssertEqual(BarcodeValidation.validated("   "), .failure(.empty))
        XCTAssertEqual(
            BarcodeValidation.sanitizedInput("١٢٣٤٥"),
            "",
            "Only ASCII digits match the backend contract"
        )
    }

    // MARK: - View model

    func testLookupFoundRequiresExplicitProductSelection() async {
        let service = FakeBarcodeService()
        await service.enqueue(.success(makeLookup(origin: .openFoodFacts, note: "Imported")))
        var selected: BarcodeLookup?
        let viewModel = makeViewModel(service: service, onSelect: { selected = $0 })

        viewModel.barcodeChanged("0001234")
        await viewModel.performLookup()

        guard case .found(let lookup) = viewModel.state else {
            return XCTFail("Expected a found lookup")
        }
        XCTAssertEqual(lookup.product.barcode, "0001234")
        XCTAssertEqual(lookup.lookup.origin, .openFoodFacts)
        XCTAssertNil(selected, "A result must not navigate or log until the user acts")
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, ["0001234"])

        viewModel.selectFoundProduct()
        XCTAssertEqual(selected?.product.id, "food-1")
    }

    func testNotFoundProducesOnlyAnExplicitCustomDraftCallback() async {
        let service = FakeBarcodeService()
        await service.enqueue(.failure(BarcodeServiceError.notFound(barcode: "0001234")))
        var draft: BarcodeCustomFoodDraft?
        let viewModel = makeViewModel(service: service, onCreate: { draft = $0 })

        viewModel.barcodeChanged("0001234")
        await viewModel.performLookup()

        XCTAssertEqual(viewModel.state, .notFound(barcode: "0001234"))
        XCTAssertNil(draft, "A missing barcode must not create a draft automatically")
        viewModel.createCustomFoodDraft()
        XCTAssertEqual(draft, BarcodeCustomFoodDraft(barcode: "0001234"))
        XCTAssertEqual(draft?.basicHandoff.purpose, .customFood)
        XCTAssertEqual(draft?.basicHandoff.barcode, "0001234")
        XCTAssertEqual(draft?.basicHandoff.name, "")
    }

    func testUpstreamFailureIsNotReportedAsNotFoundAndCanRetry() async {
        let service = FakeBarcodeService()
        await service.enqueue(.failure(BarcodeServiceError.upstreamUnavailable))
        await service.enqueue(.success(makeLookup()))
        let viewModel = makeViewModel(service: service)

        viewModel.barcodeChanged("0001234")
        await viewModel.performLookup()
        XCTAssertEqual(viewModel.state, .failed(.upstreamUnavailable))
        XCTAssertTrue(BarcodeServiceError.upstreamUnavailable.canRetry)

        viewModel.retry()
        await waitUntil { !viewModel.isBusy && viewModel.state != .failed(.upstreamUnavailable) }
        guard case .found = viewModel.state else {
            return XCTFail("Expected retry to find the product")
        }
    }

    func testRateLimitedFailureKeepsRetryAndPreservesBarcodeInput() async {
        let service = FakeBarcodeService()
        await service.enqueue(.failure(BarcodeServiceError.rateLimited(retryAfterSeconds: 9)))
        let viewModel = makeViewModel(service: service)

        viewModel.barcodeChanged("0001234")
        await viewModel.performLookup()

        XCTAssertEqual(
            viewModel.state,
            .failed(.rateLimited(retryAfterSeconds: 9))
        )
        XCTAssertEqual(viewModel.barcodeInput, "0001234")
        XCTAssertEqual(
            BarcodeServiceError.rateLimited(retryAfterSeconds: 9).message,
            String(format: String(localized: "barcode.error.rateLimited"), 9)
        )
    }

    func testUnauthorizedFailureNotifiesSessionAndIsNotRetryable() async {
        let service = FakeBarcodeService()
        await service.enqueue(.failure(BarcodeServiceError.unauthorized))
        var expired = 0
        let viewModel = makeViewModel(service: service, onExpired: { expired += 1 })

        viewModel.barcodeChanged("0001234")
        await viewModel.performLookup()

        XCTAssertEqual(expired, 1)
        XCTAssertEqual(viewModel.state, .failed(.unauthorized))
        XCTAssertFalse(BarcodeServiceError.unauthorized.canRetry)
    }

    func testStaleLookupCannotReplaceNewerBarcodeResult() async {
        let service = FakeBarcodeService()
        await service.enqueue(.success(makeLookup(barcode: "0001111")))
        await service.setFirstDelay(200_000_000)
        await service.enqueue(.success(makeLookup(barcode: "0002222")))
        let viewModel = makeViewModel(service: service)

        viewModel.barcodeChanged("0001111")
        let oldRequest = Task { await viewModel.performLookup() }
        await waitUntil { viewModel.isBusy }

        viewModel.barcodeChanged("0002222")
        await viewModel.performLookup()
        await oldRequest.value

        guard case .found(let lookup) = viewModel.state else {
            return XCTFail("Expected the newer lookup to stay visible")
        }
        XCTAssertEqual(lookup.product.barcode, "0002222")
    }

    func testCancelReturnsToIdleWithoutCallback() async {
        let service = FakeBarcodeService()
        await service.enqueue(.success(makeLookup()))
        await service.setFirstDelay(300_000_000)
        var selected: BarcodeLookup?
        let viewModel = makeViewModel(service: service, onSelect: { selected = $0 })

        viewModel.barcodeChanged("0001234")
        let request = Task { await viewModel.performLookup() }
        await waitUntil { viewModel.isBusy }
        viewModel.cancel()
        await request.value

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(selected)
    }

    func testInvalidBarcodeDoesNotCallTheService() async {
        let service = FakeBarcodeService()
        let viewModel = makeViewModel(service: service)

        viewModel.barcodeChanged("123")
        await viewModel.performLookup()

        XCTAssertEqual(viewModel.state, .failed(.invalidBarcode(.invalidLength)))
        let calls = await service.recordedCalls()
        XCTAssertEqual(calls, [])
    }

    // MARK: - Adapter contract

    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BarcodeURLProtocol.self]
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func errorJSON(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    private func productJSON(origin: String, barcode: String) -> Data {
        Data(
            """
            {
              "id": "food-1",
              "source": "OFF",
              "source_id": "0001234",
              "visibility": "global",
              "barcode": "\(barcode)",
              "name": "Imported oats",
              "brand": null,
              "categories": ["cereal"],
              "default_quantity": null,
              "default_unit": null,
              "nutrition_summary": {
                "per_100g": {
                  "energy_kcal": "389",
                  "protein_g": "16.9",
                  "carbs_g": "66.3",
                  "fat_g": "6.9",
                  "fiber_g": "10.6"
                }
              },
              "nutrients": [
                {"code": "ENERGY_KCAL", "amount_per_100g": "389", "unit": "kcal",
                 "source": null, "confidence": null}
              ],
              "servings": [],
              "allowed_units": [],
              "created_at": "2026-11-19T00:00:00Z",
              "updated_at": "2026-11-19T00:00:00Z",
              "lookup": {
                "origin": "\(origin)",
                "note": "Food was not found locally and was imported from Open Food Facts."
              }
            }
            """.utf8
        )
    }

    func testAdapterPreservesLeadingZeroPathAndImportedOrigin() async throws {
        BarcodeURLProtocol.setUp { _ in
            .init(body: self.productJSON(origin: "open_food_facts", barcode: "0001234"))
        }
        let lookup = try await CalCoBarcodeServiceAdapter(client: makeClient())
            .lookupBarcode("0001234")

        XCTAssertEqual(lookup.product.barcode, "0001234")
        XCTAssertEqual(lookup.lookup.origin, .openFoodFacts)
        XCTAssertEqual(
            lookup.lookup.note,
            "Food was not found locally and was imported from Open Food Facts."
        )
        let request = try XCTUnwrap(BarcodeURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/foods/barcode/0001234")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAdapterMapsMissingAndUpstreamFailuresDistinctly() async throws {
        let service = CalCoBarcodeServiceAdapter(client: makeClient())

        BarcodeURLProtocol.setUp { _ in
            .init(
                statusCode: 404,
                body: self.errorJSON(
                    code: "not_found",
                    message: "product with barcode 0001234 not found"
                )
            )
        }
        do {
            _ = try await service.lookupBarcode("0001234")
            XCTFail("Expected not found")
        } catch {
            XCTAssertEqual(
                error as? BarcodeServiceError,
                .notFound(barcode: "0001234")
            )
        }

        BarcodeURLProtocol.setUp { _ in
            .init(
                statusCode: 503,
                body: self.errorJSON(
                    code: "external_unavailable",
                    message: "external food catalog is temporarily unavailable"
                )
            )
        }
        do {
            _ = try await service.lookupBarcode("0001234")
            XCTFail("Expected upstream failure")
        } catch {
            XCTAssertEqual(error as? BarcodeServiceError, .upstreamUnavailable)
        }

        BarcodeURLProtocol.setUp { _ in
            .init(
                statusCode: 502,
                body: self.errorJSON(
                    code: "external_invalid_response",
                    message: "external food catalog returned unusable product data"
                )
            )
        }
        do {
            _ = try await service.lookupBarcode("0001234")
            XCTFail("Expected upstream invalid response")
        } catch {
            XCTAssertEqual(error as? BarcodeServiceError, .upstreamInvalidResponse)
        }
    }

    func testAdapterMapsRateLimitUnauthorizedAndValidation() async throws {
        let service = CalCoBarcodeServiceAdapter(client: makeClient())

        BarcodeURLProtocol.setUp { _ in
            .init(
                statusCode: 429,
                headers: ["Retry-After": "12"],
                body: self.errorJSON(code: "rate_limited", message: "too many requests")
            )
        }
        do {
            _ = try await service.lookupBarcode("0001234")
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(
                error as? BarcodeServiceError,
                .rateLimited(retryAfterSeconds: 12)
            )
        }

        BarcodeURLProtocol.setUp { _ in
            .init(
                statusCode: 401,
                body: self.errorJSON(code: "unauthenticated", message: "Unauthorized")
            )
        }
        do {
            _ = try await service.lookupBarcode("0001234")
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? BarcodeServiceError, .unauthorized)
        }

        BarcodeURLProtocol.setUp { _ in
            XCTFail("Invalid input must not reach the network")
            return .init(statusCode: 500)
        }
        do {
            _ = try await service.lookupBarcode("12a34")
            XCTFail("Expected local validation failure")
        } catch {
            XCTAssertEqual(
                error as? BarcodeServiceError,
                .invalidBarcode(.invalidCharacters)
            )
        }
        XCTAssertTrue(BarcodeURLProtocol.requests.isEmpty)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }
}
