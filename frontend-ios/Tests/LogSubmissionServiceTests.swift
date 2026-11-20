import XCTest

@testable import CalCo

private final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64

    init(_ value: UInt64) {
        stored = value
    }

    var value: UInt64 {
        lock.withLock { stored }
    }

    func set(_ value: UInt64) {
        lock.withLock { stored = value }
    }
}

private actor RecordingSubmissionSender: LogSubmissionSending {
    enum Response {
        case logs([FoodLog])
        case error(LogSubmissionSendError)
    }

    private var responses: [Response]
    private var requests: [LogSubmissionRequest] = []
    private let onSend: (@Sendable () -> Void)?

    init(
        _ responses: [Response],
        onSend: (@Sendable () -> Void)? = nil
    ) {
        self.responses = responses
        self.onSend = onSend
    }

    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] {
        requests.append(request)
        onSend?()
        guard !responses.isEmpty else {
            throw LogSubmissionSendError.uncertain("unexpected extra send")
        }
        switch responses.removeFirst() {
        case .logs(let logs):
            return logs
        case .error(let error):
            throw error
        }
    }

    func recordedRequests() -> [LogSubmissionRequest] {
        requests
    }
}

@MainActor
final class LogSubmissionServiceTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 20)

    private func log(
        id: String = "log-1",
        item: FoodLogItem = .product(
            ProductLogItemSnapshot(id: "food-1", name: "Oats")
        )
    ) -> FoodLog {
        FoodLog(
            id: id,
            logDate: date,
            mealSlot: .lunch,
            item: item,
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
    }

    private func draft(
        item: LogSubmissionItem = .product(id: "food-1"),
        amount: String = "100",
        nutrients: [NutrientAmountValue]? = nil
    ) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: item,
            date: date,
            mealSlot: .lunch,
            amount: amount,
            unit: "g",
            notes: nil,
            timeZone: "America/New_York",
            nutrients: nutrients
        )
    }

    private func bodyDictionary(_ request: LogSubmissionRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: request.body)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testSingleRequestIsUnkeyedOrdinaryPOST() async throws {
        let sender = RecordingSubmissionSender([.logs([log()])])
        let service = LogSubmissionService(sender: sender)

        let result = await service.submit(
            accountID: "account-a",
            summary: "Oats",
            drafts: [draft()],
            itemNames: ["Oats"]
        )

        XCTAssertEqual(result, .success([log()]))
        let requests = await sender.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.requestPath, "/api/logs")
        let body = try bodyDictionary(request)
        XCTAssertNil(body["idempotency_key"])
        XCTAssertEqual(body["log_date"] as? String, "2026-11-20")
        let item = try XCTUnwrap(body["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "product")
        XCTAssertEqual(item["id"] as? String, "food-1")
    }

    func testBatchRequestIsUnkeyedAndUsesBatchRoute() async throws {
        let sender = RecordingSubmissionSender([
            .logs([
                log(id: "log-1"),
                log(
                    id: "log-2",
                    item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Bowl"))
                ),
            ])
        ])
        let service = LogSubmissionService(sender: sender)

        let result = await service.submit(
            accountID: "account-a",
            summary: "Oats + Bowl",
            drafts: [
                draft(),
                draft(item: .meal(id: "meal-1"), amount: "1"),
            ],
            itemNames: ["Oats", "Bowl"]
        )

        XCTAssertEqual(result.createdLogs.map(\.id), ["log-1", "log-2"])
        let requests = await sender.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.requestPath, "/api/logs/batch")
        let body = try bodyDictionary(request)
        XCTAssertNil(body["idempotency_key"])
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertNil(item["idempotency_key"])
        }
    }

    func testAdHocRequestBuildsNutrientsAndNoKey() async throws {
        let sender = RecordingSubmissionSender([
            .logs([
                log(
                    item: .adHoc(AdHocLogItemSnapshot(name: "Café", brand: "Local"))
                )
            ])
        ])
        let service = LogSubmissionService(sender: sender)

        let result = await service.submit(
            accountID: "account-a",
            summary: "Café",
            drafts: [
                draft(
                    item: .adHoc(name: "Café", brand: "Local"),
                    amount: "1",
                    nutrients: [
                        NutrientAmountValue(code: "energy_kcal", amount: "90", unit: "kcal")
                    ]
                )
            ],
            itemNames: ["Café"]
        )

        XCTAssertEqual(result.createdLogs.count, 1)
        let requests = await sender.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.requestPath, "/api/logs/ad-hoc")
        let body = try bodyDictionary(request)
        XCTAssertNil(body["idempotency_key"])
        XCTAssertEqual(body["name"] as? String, "Café")
        let nutrients = try XCTUnwrap(body["nutrients"] as? [[String: Any]])
        XCTAssertEqual(nutrients.first?["code"] as? String, "energy_kcal")
    }

    func testValidationRejectsEmptyAndOverLimitWithoutSending() async {
        let sender = RecordingSubmissionSender([])
        let service = LogSubmissionService(sender: sender)

        let empty = await service.submit(
            accountID: "account-a",
            summary: "",
            drafts: []
        )
        let invalid = await service.submit(
            accountID: "account-a",
            summary: "",
            drafts: [draft(amount: "0")]
        )
        let tooMany = await service.submit(
            accountID: "account-a",
            summary: "",
            drafts: Array(repeating: draft(), count: 51)
        )

        XCTAssertEqual(empty, .failure(.failed(String(localized: "foodDetail.error.saveFailed"))))
        XCTAssertEqual(invalid, .failure(.failed(String(localized: "foodDetail.error.saveFailed"))))
        XCTAssertEqual(tooMany, .failure(.failed(String(localized: "foodDetail.error.saveFailed"))))
        let requests = await sender.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testFiftyDraftsAreAllowed() async {
        let logs = (0..<50).map { log(id: "log-\($0)") }
        let sender = RecordingSubmissionSender([.logs(logs)])
        let service = LogSubmissionService(sender: sender)

        let result = await service.submit(
            accountID: "account-a",
            summary: "batch",
            drafts: Array(repeating: draft(), count: 50)
        )

        XCTAssertEqual(result.createdLogs.count, 50)
    }

    func testSenderFailuresMapWithoutAutomaticRetry() async {
        let sender = RecordingSubmissionSender([
            .error(.failed("validation")),
            .error(.uncertain("network")),
            .error(.unauthorized),
        ])
        let service = LogSubmissionService(sender: sender)

        let failed = await service.submit(accountID: "a", summary: "", drafts: [draft()])
        let uncertain = await service.submit(accountID: "a", summary: "", drafts: [draft()])
        let unauthorized = await service.submit(accountID: "a", summary: "", drafts: [draft()])

        XCTAssertEqual(failed, .failure(.failed("validation")))
        XCTAssertEqual(uncertain, .failure(.uncertain("network")))
        XCTAssertEqual(unauthorized, .failure(.unauthorized))
        let requests = await sender.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func testExplicitUserRetrySendsANewPlainRequest() async {
        let sender = RecordingSubmissionSender([
            .error(.uncertain("first may have landed")),
            .logs([log(id: "log-retry")]),
        ])
        let service = LogSubmissionService(sender: sender)

        let first = await service.submit(accountID: "a", summary: "", drafts: [draft()])
        let second = await service.submit(accountID: "a", summary: "", drafts: [draft()])

        XCTAssertEqual(first, .failure(.uncertain("first may have landed")))
        XCTAssertEqual(second.createdLogs.map(\.id), ["log-retry"])
        let requests = await sender.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].requestPath, "/api/logs")
        XCTAssertEqual(requests[1].requestPath, "/api/logs")
        XCTAssertEqual(requests[0].body, requests[1].body)
    }

    func testStaleAccountOrGenerationBeforeSendFailsUnauthorizedWithoutSending() async {
        let sender = RecordingSubmissionSender([])
        var current: LogSubmissionSessionContext? = LogSubmissionSessionContext(
            accountID: "account-b",
            generation: 2,
            baseURL: URL(string: "https://calco.example.com")!
        )
        let service = LogSubmissionService(
            sender: sender,
            sessionContextProvider: { current }
        )

        let wrongAccount = await service.submit(
            accountID: "account-a",
            summary: "",
            drafts: [draft()],
            generation: 2
        )
        current = LogSubmissionSessionContext(
            accountID: "account-a",
            generation: 3,
            baseURL: URL(string: "https://calco.example.com")!
        )
        let wrongGeneration = await service.submit(
            accountID: "account-a",
            summary: "",
            drafts: [draft()],
            generation: 2
        )

        XCTAssertEqual(wrongAccount, .failure(.unauthorized))
        XCTAssertEqual(wrongGeneration, .failure(.unauthorized))
        let requests = await sender.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testGenerationChangeAfterSendReturnsUncertainWithoutRetry() async {
        let generation = GenerationBox(4)
        let sender = RecordingSubmissionSender(
            [.logs([log()])],
            onSend: { generation.set(5) }
        )
        let service = LogSubmissionService(
            sender: sender,
            sessionContextProvider: {
                LogSubmissionSessionContext(
                    accountID: "account-a",
                    generation: generation.value,
                    baseURL: URL(string: "https://calco.example.com")!
                )
            }
        )

        let result = await service.submit(
            accountID: "account-a",
            summary: "",
            drafts: [draft()],
            generation: 4
        )

        XCTAssertEqual(
            result,
            .failure(.uncertain(String(localized: "foodDetail.error.sessionExpired")))
        )
        let requests = await sender.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }
}
