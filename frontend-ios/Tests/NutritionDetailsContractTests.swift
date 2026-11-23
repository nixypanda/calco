import Foundation
import XCTest

@testable import CalCo

final class NutritionDetailsContractTests: XCTestCase {
    private func decode(_ json: String) throws -> NutritionDetailsReport {
        try JSONDecoder().decode(NutritionDetailsReport.self, from: Data(json.utf8))
    }

    private func nutrient(
        _ report: NutritionDetailsReport,
        _ code: String
    ) throws -> NutritionDetailsNutrient {
        try XCTUnwrap(report.nutrients.first { $0.code == code })
    }

    // MARK: - Wire contract

    func testReportDecodesDatesReferencesSectionsAndServerDecisions() throws {
        let report = try decode(NutritionDetailsTestFixtures.sampleJSON)

        XCTAssertEqual(report.date, NutritionDetailsTestFixtures.day)
        XCTAssertEqual(report.loggedItems, 2)
        XCTAssertEqual(report.reference.code, "us_fda_dv_adult_2020")
        XCTAssertEqual(report.reference.name, "FDA Nutrition Facts Daily Values")
        XCTAssertEqual(report.reference.authority, "U.S. Food and Drug Administration")
        XCTAssertEqual(report.reference.jurisdiction, "US")
        XCTAssertEqual(report.reference.populationLabel, "Adults and children 4 years and older")
        XCTAssertTrue(report.reference.sourceURL.hasPrefix("https://www.fda.gov/"))

        XCTAssertEqual(
            report.nutrients(in: .overview).map(\.code),
            ["ENERGY_KCAL", "PROTEIN_G"]
        )
        XCTAssertEqual(
            report.nutrients(in: .carbohydrates).map(\.code),
            ["FIBER_G", "SUGAR_G", "ADDED_SUGAR_G"]
        )
        XCTAssertEqual(
            report.nutrients(in: .fats).map(\.code),
            ["SATURATED_FAT_G", "TRANS_FAT_G"]
        )
        XCTAssertEqual(report.nutrients(in: .limits).map(\.code), ["SODIUM_MG"])
        XCTAssertEqual(
            report.nutrients(in: .vitaminsMinerals).map(\.code),
            ["POTASSIUM_MG", "MAGNESIUM_MG", "VITAMIN_D_UG", "CALCIUM_MG"]
        )

        let sodium = try nutrient(report, "SODIUM_MG")
        XCTAssertEqual(sodium.section, .limits)
        XCTAssertEqual(sodium.guidanceKind, .maximum)
        XCTAssertEqual(sodium.coverage, .complete)
        XCTAssertEqual(sodium.status, .overLimit)
        XCTAssertEqual(sodium.itemsWithData, 2)
        XCTAssertEqual(sodium.referenceAmount, NutritionDetailsTestFixtures.decimal("2300"))
    }

    func testZeroIsKnownWhileNullAndMissingAreUnknown() throws {
        let report = try decode(NutritionDetailsTestFixtures.sampleJSON)

        let energy = try nutrient(report, "ENERGY_KCAL")
        XCTAssertEqual(energy.knownAmount, 0)
        XCTAssertEqual(energy.amountDisplay, .value(0, unit: "kcal"))
        XCTAssertEqual(energy.overviewAmountDisplay, .value(0, unit: "kcal"))
        XCTAssertEqual(energy.guidance, .knownMinimum(0))

        let fiber = try nutrient(report, "FIBER_G")
        XCTAssertNil(fiber.knownAmount)
        XCTAssertEqual(fiber.amountDisplay, .unknownOfReference(
            reference: NutritionDetailsTestFixtures.decimal("28"),
            unit: "g"
        ))
        XCTAssertEqual(fiber.overviewAmountDisplay, .unknown)
        XCTAssertEqual(fiber.guidance, .noData)

        let addedSugar = try nutrient(report, "ADDED_SUGAR_G")
        XCTAssertEqual(addedSugar.knownAmount, 0)
        XCTAssertNotNil(addedSugar.knownAmount)

        let protein = try nutrient(report, "PROTEIN_G")
        XCTAssertEqual(protein.knownAmount, NutritionDetailsTestFixtures.decimal("10"))
        XCTAssertEqual(protein.amountDisplay, .value(10, unit: "g"))
    }

    func testProgressMatchesWebRulesForInformationalMissingAndZeroReferences() throws {
        let report = try decode(NutritionDetailsTestFixtures.sampleJSON)

        XCTAssertNil(try nutrient(report, "ENERGY_KCAL").progressPercent)
        XCTAssertNil(try nutrient(report, "FIBER_G").progressPercent)
        XCTAssertNil(try nutrient(report, "VITAMIN_D_UG").progressPercent)
        XCTAssertNil(try nutrient(report, "CALCIUM_MG").progressPercent)
        XCTAssertEqual(try nutrient(report, "ADDED_SUGAR_G").progressPercent, 0)
        XCTAssertEqual(
            try XCTUnwrap(try nutrient(report, "MAGNESIUM_MG").progressPercent),
            (184.2 / 420.0) * 100.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(try nutrient(report, "SATURATED_FAT_G").progressPercent),
            125,
            accuracy: 0.000_001
        )
    }

    func testDangerousStatusIsOnlyMaximumOverLimit() throws {
        let report = try decode(NutritionDetailsTestFixtures.sampleJSON)

        XCTAssertTrue(try nutrient(report, "SODIUM_MG").isDangerous)
        XCTAssertTrue(try nutrient(report, "SATURATED_FAT_G").isDangerous)
        XCTAssertFalse(try nutrient(report, "ADDED_SUGAR_G").isDangerous)
        XCTAssertFalse(try nutrient(report, "POTASSIUM_MG").isDangerous)
    }

    func testGuidancePreservesServerCoverageAndReferenceInterpretation() throws {
        let report = try decode(NutritionDetailsTestFixtures.sampleJSON)

        XCTAssertEqual(try nutrient(report, "SUGAR_G").guidance, .noDailyReference)
        XCTAssertEqual(
            try nutrient(report, "ADDED_SUGAR_G").guidance,
            .withinLimit(NutritionDetailsTestFixtures.decimal("50"))
        )
        XCTAssertEqual(
            try nutrient(report, "SATURATED_FAT_G").guidance,
            .overLimit(NutritionDetailsTestFixtures.decimal("5"))
        )
        XCTAssertEqual(try nutrient(report, "POTASSIUM_MG").guidance, .referenceReached)
        XCTAssertEqual(
            try nutrient(report, "MAGNESIUM_MG").guidance,
            .knownMinimum(NutritionDetailsTestFixtures.decimal("184.2"))
        )
        XCTAssertEqual(try nutrient(report, "VITAMIN_D_UG").guidance, .noDailyReference)
        XCTAssertEqual(try nutrient(report, "CALCIUM_MG").guidance, .referenceReached)
    }

    func testUnknownCoverageEnumFailsClosed() throws {
        let json = NutritionDetailsTestFixtures.sampleJSON.replacingOccurrences(
            of: #""coverage": "partial""#,
            with: #""coverage": "mostly""#
        )
        XCTAssertThrowsError(try decode(json))
    }

    func testUnknownSectionEnumFailsClosed() throws {
        let json = NutritionDetailsTestFixtures.sampleJSON.replacingOccurrences(
            of: #""section": "limits""#,
            with: #""section": "minerals""#
        )
        XCTAssertThrowsError(try decode(json))
    }

    func testInvalidDecimalStringFailsInsteadOfBecomingZero() throws {
        let json = NutritionDetailsTestFixtures.sampleJSON.replacingOccurrences(
            of: #""known_amount": "184.2""#,
            with: #""known_amount": "not-a-number""#
        )
        XCTAssertThrowsError(try decode(json))
    }

    func testMissingNullableAmountsDecodeAsUnknown() throws {
        let json = #"""
        {
          "date": "2026-08-14",
          "reference": {
            "code": "ref",
            "name": "Reference",
            "authority": "Authority",
            "jurisdiction": "US",
            "population_label": "Adults",
            "source_url": "https://example.com"
          },
          "logged_items": 0,
          "nutrients": [
            {
              "code": "FIBER_G",
              "name": "Dietary Fiber",
              "section": "carbohydrates",
              "unit": "g",
              "guidance_kind": "adequacy",
              "items_with_data": 0,
              "coverage": "none",
              "status": "no_data"
            }
          ]
        }
        """#
        let report = try decode(json)
        let fiber = try nutrient(report, "FIBER_G")
        XCTAssertNil(fiber.knownAmount)
        XCTAssertNil(fiber.referenceAmount)
        XCTAssertEqual(fiber.amountDisplay, .unknown)
        XCTAssertEqual(fiber.guidance, .noData)
        XCTAssertNil(fiber.progressPercent)
    }

    func testEmptyReportKeepsNoItemsNoticeInsteadOfMissingCoverageWarning() {
        let report = NutritionDetailsTestFixtures.report(loggedItems: 0, nutrients: [])
        XCTAssertEqual(report.coverageNotice.severity, .info)
        XCTAssertEqual(report.coverageNotice.notice, .noItemsLogged)
        XCTAssertTrue(report.nutrients(in: .overview).isEmpty)
        XCTAssertFalse(report.hasPartialCoverage)
        XCTAssertFalse(report.hasNoCoverage)
    }

    // MARK: - Display math

    func testDecimalFormattingAlwaysShowsTwoPlaces() {
        let format = NutritionDetailsFormat.self
        XCTAssertEqual(format.decimal(0), "0.00")
        XCTAssertEqual(format.decimal(NutritionDetailsTestFixtures.decimal("184.2")), "184.20")
        XCTAssertEqual(format.decimal(NutritionDetailsTestFixtures.decimal("420")), "420.00")
        XCTAssertEqual(format.decimal(NutritionDetailsTestFixtures.decimal("28.04")), "28.04")
        XCTAssertEqual(format.decimal(NutritionDetailsTestFixtures.decimal("1.255")), "1.26")
        XCTAssertEqual(format.decimal(NutritionDetailsTestFixtures.decimal("1000.555")), "1000.56")
    }

    func testAmountFormattingKeepsUnitsAndOmitsBlankUnits() {
        XCTAssertEqual(
            NutritionDetailsFormat.amount(
                NutritionDetailsTestFixtures.decimal("0"),
                unit: "g"
            ),
            "0.00 g"
        )
        XCTAssertEqual(
            NutritionDetailsFormat.amount(
                NutritionDetailsTestFixtures.decimal("18"),
                unit: "mg"
            ),
            "18.00 mg"
        )
        XCTAssertEqual(
            NutritionDetailsFormat.amount(
                NutritionDetailsTestFixtures.decimal("18"),
                unit: "  "
            ),
            "18.00"
        )
    }

    // MARK: - Coverage notice

    func testCoverageNoticeNoItemsIsInformationalEvenWithIncompleteNutrients() {
        let report = NutritionDetailsTestFixtures.report(
            loggedItems: 0,
            nutrients: [
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: nil,
                    referenceAmount: 28,
                    coverage: .partial,
                    status: .partialData
                )
            ]
        )
        XCTAssertEqual(report.coverageNotice.severity, .info)
        XCTAssertEqual(report.coverageNotice.notice, .noItemsLogged)
    }

    func testCoverageNoticePartialCoverageWinsAndWarns() {
        let report = NutritionDetailsTestFixtures.report(
            loggedItems: 2,
            nutrients: [
                NutritionDetailsTestFixtures.nutrient(
                    code: "FIBER_G",
                    knownAmount: 10,
                    referenceAmount: 28,
                    coverage: .partial,
                    status: .partialData
                ),
                NutritionDetailsTestFixtures.nutrient(
                    code: "SODIUM_MG",
                    knownAmount: nil,
                    referenceAmount: 2300,
                    coverage: .none,
                    status: .noData
                ),
            ]
        )
        XCTAssertEqual(report.coverageNotice.severity, .warning)
        XCTAssertEqual(report.coverageNotice.notice, .partialCoverage)
        XCTAssertTrue(report.hasPartialCoverage)
        XCTAssertTrue(report.hasNoCoverage)
    }

    func testCoverageNoticeMissingNutrientsWarnsWhenNothingIsPartial() {
        let report = NutritionDetailsTestFixtures.report(
            loggedItems: 2,
            nutrients: [
                NutritionDetailsTestFixtures.nutrient(
                    code: "FIBER_G",
                    knownAmount: nil,
                    referenceAmount: 28,
                    coverage: .none,
                    status: .noData
                ),
                NutritionDetailsTestFixtures.nutrient(
                    code: "SODIUM_MG",
                    knownAmount: 100,
                    referenceAmount: 2300,
                    coverage: .complete,
                    status: .withinLimit
                ),
            ]
        )
        XCTAssertEqual(report.coverageNotice.severity, .warning)
        XCTAssertEqual(report.coverageNotice.notice, .missingNutrients)
    }

    func testCoverageNoticeCompleteReportsCountForSingularAndPluralCopy() {
        let nutrient = NutritionDetailsTestFixtures.nutrient(
            knownAmount: 10,
            referenceAmount: 28,
            coverage: .complete,
            status: .belowReference
        )
        let one = NutritionDetailsTestFixtures.report(loggedItems: 1, nutrients: [nutrient])
        XCTAssertEqual(one.coverageNotice.severity, .info)
        XCTAssertEqual(one.coverageNotice.notice, .includedItems(1))

        let many = NutritionDetailsTestFixtures.report(loggedItems: 3, nutrients: [nutrient])
        XCTAssertEqual(many.coverageNotice.severity, .info)
        XCTAssertEqual(many.coverageNotice.notice, .includedItems(3))
    }

    // MARK: - Guidance branches

    func testGuidanceBranchesCoverUnknownKnownMinimumReferenceAndLimitMath() {
        let cases: [(NutritionDetailsNutrient, NutritionDetailsGuidance)] = [
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: nil,
                    referenceAmount: 28,
                    coverage: .none,
                    status: .noData
                ),
                .noData
            ),
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: nil,
                    referenceAmount: 28,
                    coverage: .partial,
                    status: .partialData
                ),
                .noKnownAmount
            ),
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: 10,
                    referenceAmount: 28,
                    coverage: .complete,
                    status: .belowReference
                ),
                .toReference(NutritionDetailsTestFixtures.decimal("18"))
            ),
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: 28,
                    referenceAmount: 28,
                    coverage: .complete,
                    status: .metReference
                ),
                .referenceReached
            ),
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: 25,
                    referenceAmount: 20,
                    guidanceKind: .maximum,
                    coverage: .complete,
                    status: .overLimit
                ),
                .overLimit(NutritionDetailsTestFixtures.decimal("5"))
            ),
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: 20,
                    referenceAmount: 20,
                    guidanceKind: .maximum,
                    coverage: .complete,
                    status: .withinLimit
                ),
                .withinLimit(0)
            ),
            (
                NutritionDetailsTestFixtures.nutrient(
                    knownAmount: 5,
                    referenceAmount: nil,
                    guidanceKind: .adequacy,
                    coverage: .complete,
                    status: .belowReference
                ),
                .noDailyReference
            ),
        ]

        for (nutrient, expected) in cases {
            XCTAssertEqual(nutrient.guidance, expected, nutrient.code)
        }
    }

    func testDateTitleContainsWeekdayMonthAndDay() {
        let title = NutritionDetailsCopy.dateTitle(
            NutritionDetailsTestFixtures.day,
            locale: Locale(identifier: "en_US")
        )
        XCTAssertTrue(title.contains("Friday"))
        XCTAssertTrue(title.contains("August"))
        XCTAssertTrue(title.contains("14"))
        XCTAssertTrue(title.contains("2026"))
    }
}

// MARK: - Adapter and API contract

private struct NutritionDetailsAdapterStub {
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

private final class NutritionDetailsAdapterURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> NutritionDetailsAdapterStub

    private static let lock = NSLock()
    private static var storedHandler: Handler = { _ in
        NutritionDetailsAdapterStub(statusCode: 500)
    }

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
            url: request.url ?? URL(string: "http://127.0.0.1")!,
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

private final class NutritionDetailsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}

final class NutritionDetailsAdapterTests: XCTestCase {
    private let date = NutritionDetailsTestFixtures.day

    override func setUp() {
        super.setUp()
        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            NutritionDetailsAdapterStub(statusCode: 500)
        }
    }

    private func makeClient() -> CalCoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NutritionDetailsAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CalCoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:3002")!,
            session: session
        )
    }

    private func json(
        _ raw: String,
        statusCode: Int = 200
    ) -> NutritionDetailsAdapterStub {
        NutritionDetailsAdapterStub(
            statusCode: statusCode,
            body: Data(raw.utf8)
        )
    }

    private func errorJSON(code: String, message: String) -> String {
        #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private func queryValue(_ request: URLRequest, name: String) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    func testAdapterSendsSelectedDateWithoutAuthorizationAndMapsTheReport() async throws {
        let recorder = NutritionDetailsRequestRecorder()
        NutritionDetailsAdapterURLProtocol.setHandler { request in
            recorder.record(request)
            return self.json(NutritionDetailsTestFixtures.sampleJSON)
        }

        let report = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
            .fetchNutritionDetails(for: date)

        XCTAssertEqual(report.date, date)
        XCTAssertEqual(report.loggedItems, 2)
        XCTAssertEqual(report.nutrients.count, 12)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/nutrition/details")
        XCTAssertEqual(queryValue(request, name: "date"), "2026-08-14")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAdapterMapsUnauthorized() async {
        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "session_expired", message: "Session expired"),
                statusCode: 401
            )
        }

        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected unauthorized")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdapterMapsNetworkTimeoutAndCancellation() async {
        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            NutritionDetailsAdapterStub(error: URLError(.timedOut))
        }
        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected a network error")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            NutritionDetailsAdapterStub(error: URLError(.cancelled))
        }
        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected cancellation")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdapterMapsRateLimitAndServerMessages() async {
        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "rate_limited", message: "slow down"),
                statusCode: 429
            )
        }
        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected a rate limit error")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(
                error,
                .server(String(localized: "nutrition.error.rateLimited"))
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "validation", message: "invalid date"),
                statusCode: 400
            )
        }
        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected a server rejection")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(error, .server("invalid date"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAdapterFailsClosedOnUnreadableAndUnknownServerResponses() async {
        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            self.json("not-json")
        }
        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected an invalid response")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        NutritionDetailsAdapterURLProtocol.setHandler { _ in
            self.json(
                self.errorJSON(code: "unknown", message: "   "),
                statusCode: 503
            )
        }
        do {
            _ = try await CalCoNutritionDetailsServiceAdapter(client: makeClient())
                .fetchNutritionDetails(for: date)
            XCTFail("Expected a server error")
        } catch let error as NutritionDetailsServiceError {
            XCTAssertEqual(
                error,
                .server(String(localized: "nutrition.error.generic"))
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
