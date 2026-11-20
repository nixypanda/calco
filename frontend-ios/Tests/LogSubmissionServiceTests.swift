import XCTest

@testable import CalCo

private final class RecordingSubmissionSender: LogSubmissionSending, @unchecked Sendable {
    enum Mode {
        case result(LogSubmissionSendResult)
        case failure(LogSubmissionSendError)
    }

    private let lock = NSLock()
    private var modes: [Mode]
    private var requests: [LogSubmissionRequest] = []

    init(_ modes: [Mode]) {
        self.modes = modes
    }

    var recordedRequests: [LogSubmissionRequest] {
        lock.withLock { requests }
    }

    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        let mode: Mode = lock.withLock {
            requests.append(request)
            return modes.removeFirst()
        }
        switch mode {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

private final class CountingFailingPersistence: LogSubmissionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let base: FileLogSubmissionPersistence
    private var saveCount = 0
    private var failOnSave: Int?

    init(base: FileLogSubmissionPersistence) {
        self.base = base
    }

    func failSave(number: Int?) {
        lock.withLock { failOnSave = number }
    }

    func recordedSaveCount() -> Int {
        lock.withLock { saveCount }
    }

    func load(accountID: String) throws -> Data? {
        try base.load(accountID: accountID)
    }

    func save(_ data: Data, accountID: String) throws {
        let shouldFail = lock.withLock {
            saveCount += 1
            return failOnSave == saveCount
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.save(data, accountID: accountID)
    }

    func quarantine(accountID: String, reason: String) {
        base.quarantine(accountID: accountID, reason: reason)
    }
}

private final class TestCapabilityProvider: LogCreationCapabilityProviding, @unchecked Sendable {
    var baseURL: URL
    var result: Result<LogCreationIdempotencyCapability, Error>

    init(
        baseURL: URL = URL(string: "https://calco.example.com")!,
        result: Result<LogCreationIdempotencyCapability, Error> = .success(.ready)
    ) {
        self.baseURL = baseURL
        self.result = result
    }

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        try result.get()
    }
}

private extension LogCreationIdempotencyCapability {
    static let ready = LogCreationIdempotencyCapability(
        version: 2,
        single: true,
        adHoc: true,
        batch: true,
        batchKeyLocation: "top_level",
        deletedOperationReplay: "conflict",
        preMigrationDeletedKeys: "reconciliation_only"
    )
}

private final class HeldCapabilityProvider: LogCreationCapabilityProviding, @unchecked Sendable {
    let baseURL = URL(string: "https://calco.example.com")!
    var result: Result<LogCreationIdempotencyCapability, Error> = .success(.ready)
    private var holdNext = false
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func holdNextRequest() {
        holdNext = true
        started = false
        released = false
    }

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        if holdNext {
            holdNext = false
            started = true
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
        return try result.get()
    }

    func waitForStart() async {
        let deadline = Date().addingTimeInterval(2)
        while !started, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(started, "Timed out waiting for capability probe")
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor HoldingSubmissionSender: LogSubmissionSending {
    private let result: LogSubmissionSendResult
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var requests = 0

    init(result: LogSubmissionSendResult) {
        self.result = result
    }

    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        requests += 1
        started = true
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        return result
    }

    func waitForStart() async {
        let deadline = Date().addingTimeInterval(2)
        while !started, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(started, "Timed out waiting for the held send")
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func sendCount() -> Int { requests }
}

private final class TestSubmissionClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
final class LogSubmissionServiceTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let accountID = "account-a"
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testUnresolvedMatchingAttemptBlocksNewSubmissionBeforeSend() async throws {
        let store = makeStore()
        let existing = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft(.product(id: "food-1"))],
            request: try preparedRequest(drafts: [draft(.product(id: "food-1"))])
        )
        let sender = RecordingSubmissionSender([
            .failure(.uncertain("should not send"))
        ])
        let service = await makeReadyService(store: store, sender: sender)

        let result = await service.submit(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft(.product(id: "food-1"))],
            itemNames: ["Oats"],
            baseURL: URL(string: "https://calco.example.com")
        )

        XCTAssertEqual(result, .failure(.uncertain(
            String(localized: "submission.pendingExists")
        )))
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        XCTAssertEqual(store.entries(accountID: accountID).map(\.id), [existing.id])
    }

    func testBatchRetryReplaysExactBodyAndStoresEveryLogInOrder() async throws {
        let store = makeStore()
        let drafts = [
            draft(.product(id: "food-1"), amount: "60"),
            draft(.meal(id: "meal-1"), amount: "1", unit: "serving"),
        ]
        let returnedLogs = [
            FoodLog(
                id: "log-1",
                logDate: date,
                mealSlot: .lunch,
                item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                quantity: NutritionQuantity(amount: "60", unit: "g")
            ),
            FoodLog(
                id: "log-2",
                logDate: date,
                mealSlot: .lunch,
                item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Curry")),
                quantity: NutritionQuantity(amount: "1", unit: "serving")
            ),
        ]
        let sender = RecordingSubmissionSender([
            .failure(.uncertain("Network may have saved it")),
            .result(LogSubmissionSendResult(logs: returnedLogs, statusCode: 200)),
        ])
        let service = await makeReadyService(store: store, sender: sender)

        let first = await service.submit(
            accountID: accountID,
            summary: "Oats and 1 more",
            drafts: drafts,
            itemNames: ["Oats", "Curry"],
            baseURL: URL(string: "https://calco.example.com")
        )
        XCTAssertEqual(first, .failure(.uncertain("Network may have saved it")))
        let stored = try XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertEqual(stored.state, .uncertain)
        XCTAssertEqual(stored.requestPath, "/api/logs/batch")
        XCTAssertEqual(stored.allDrafts.map(\.item), [
            .product(id: "food-1"),
            .meal(id: "meal-1"),
        ])

        let retried = await service.retry(entry: stored, accountID: accountID)

        XCTAssertEqual(retried, .success(logs: returnedLogs, replayed: true))
        let requests = sender.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1], "Retry must reuse the exact stored bytes")
        XCTAssertEqual(requests[0].requestPath, "/api/logs/batch")
        XCTAssertEqual(requests[0].idempotencyKey, stored.idempotencyKey)
        let entry = try XCTUnwrap(store.entry(id: stored.id, accountID: accountID))
        XCTAssertEqual(entry.state, .succeeded)
        XCTAssertNil(entry.body)
        XCTAssertTrue(entry.replayed)
        XCTAssertEqual(entry.resultLogs?.map(\.id), ["log-1", "log-2"])
        XCTAssertEqual(entry.itemName(at: 0), "Oats")
        XCTAssertEqual(entry.itemName(at: 1), "Curry")
    }

    func testBatchConflictIsTerminalAndCannotBeRetried() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .failure(.conflict("A different batch used this key")),
            .result(LogSubmissionSendResult(logs: [], statusCode: 200)),
        ])
        let service = await makeReadyService(store: store, sender: sender)
        let drafts = [
            draft(.product(id: "food-1")),
            draft(.meal(id: "meal-1")),
        ]

        let first = await service.submit(
            accountID: accountID,
            summary: "Batch",
            drafts: drafts,
            baseURL: URL(string: "https://calco.example.com")
        )
        XCTAssertEqual(first, .failure(.conflict("A different batch used this key")))
        let stored = try XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertEqual(stored.state, .conflicted)
        XCTAssertNil(stored.body)

        let retried = await service.retry(entry: stored, accountID: accountID)

        XCTAssertEqual(retried, .failure(.conflict("A different batch used this key")))
        XCTAssertEqual(sender.recordedRequests.count, 1)
    }

    func testRejectedEntryIsNotResentOnRetry() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .failure(.failed("Validation failed")),
            .result(LogSubmissionSendResult(logs: [], statusCode: 201)),
        ])
        let service = await makeReadyService(store: store, sender: sender)

        let first = await service.submit(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft(.product(id: "food-1"))],
            baseURL: URL(string: "https://calco.example.com")
        )
        XCTAssertEqual(first, .failure(.rejected("Validation failed")))
        let stored = try XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertEqual(stored.state, .rejected)

        let retried = await service.retry(entry: stored, accountID: accountID)

        XCTAssertEqual(retried, .failure(.rejected("Validation failed")))
        XCTAssertEqual(sender.recordedRequests.count, 1)
    }

    func testAmbiguousStatusesKeepJournalRetryableAndValidationDoesNot() {
        let payload = APIErrorPayload(code: "error", message: "Server error")
        for status in [408, 500, 502, 503, 504, 302] {
            let mapped = CalCoLogSubmissionSender.map(
                .badStatus(statusCode: status, payload: payload)
            )
            guard case .uncertain = mapped else {
                return XCTFail("HTTP \(status) must remain ambiguous and retryable")
            }
        }
        for status in [400, 422] {
            let mapped = CalCoLogSubmissionSender.map(
                .badStatus(statusCode: status, payload: payload)
            )
            if case .failed = mapped {
            } else {
                XCTFail("HTTP \(status) must be definitive")
            }
        }
        XCTAssertEqual(
            CalCoLogSubmissionSender.map(.unauthorized(nil)),
            .unauthorized
        )
        XCTAssertEqual(
            CalCoLogSubmissionSender.map(
                .badStatus(statusCode: 409, payload: payload)
            ),
            .conflict("Server error")
        )
    }

    func testPreparedEntryIsVisibleToDeletionBarrierBeforeSendStarts() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201))
        ])
        let service = await makeReadyService(store: store, sender: sender)
        let draft = draft(.product(id: "food-1"))

        let preparation = service.prepare(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: URL(string: "https://calco.example.com")
        )
        let entry = try XCTUnwrap(try preparation.get())

        let invalidated = try store.blockBeforeDeleting(
            accountID: accountID,
            item: .product(id: "food-1"),
            date: date,
            reason: "deleted"
        )
        XCTAssertEqual(invalidated.map(\.id), [entry.id])

        let result = await service.submitReserved(entry, accountID: accountID)

        XCTAssertEqual(result, .failure(.rejected("deleted")))
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        XCTAssertEqual(store.entry(id: entry.id, accountID: accountID)?.state, .invalidated)
    }

    func testServerSuccessWithJournalWriteFailureNeverReportsCleanSuccess() async throws {
        let persistence = CountingFailingPersistence(
            base: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let store = LogSubmissionStore(persistence: persistence)
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(
                logs: [
                    FoodLog(
                        id: "log-1",
                        logDate: date,
                        mealSlot: .lunch,
                        item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                        quantity: NutritionQuantity(amount: "100", unit: "g")
                    )
                ],
                statusCode: 201
            ))
        ])
        let service = await makeReadyService(store: store, sender: sender)
        let draft = draft(.product(id: "food-1"))
        let prepared = try service.prepare(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: URL(string: "https://calco.example.com")
        ).get()
        // reserve=1, markInFlight=2, markSucceeded=3
        persistence.failSave(number: 3)

        let result = await service.submitReserved(prepared, accountID: accountID)

        guard case .failure(.journalUnavailable) = result else {
            return XCTFail("Expected a fail-closed journal result, got \(result)")
        }
        persistence.failSave(number: nil)
        let relaunched = LogSubmissionStore(persistence: persistence)
        let stored = try XCTUnwrap(relaunched.entry(id: prepared.id, accountID: accountID))
        XCTAssertNotEqual(stored.state, .succeeded)
        XCTAssertNotNil(stored.body)
        XCTAssertFalse(relaunched.unresolved(
            accountID: accountID,
            item: .product(id: "food-1"),
            date: date
        ).isEmpty)
    }

    func testMalformedResponseNeverMarksSuccessAndRetriesSameBytes() async throws {
        let store = makeStore()
        let correctLog = FoodLog(
            id: "log-1",
            logDate: date,
            mealSlot: .lunch,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201)),
            .result(LogSubmissionSendResult(logs: [correctLog], statusCode: 200)),
        ])
        let service = await makeReadyService(store: store, sender: sender)

        let first = await service.submit(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft(.product(id: "food-1"))],
            baseURL: URL(string: "https://calco.example.com")
        )

        guard case .failure(.uncertain) = first else {
            return XCTFail("An empty response must not be marked successful")
        }
        let entry = try XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertNotEqual(entry.state, .succeeded)
        XCTAssertNotNil(entry.body)

        let retried = await service.retry(entry: entry, accountID: accountID)
        XCTAssertEqual(retried, .success(logs: [correctLog], replayed: true))
        let requests = sender.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
    }

    func testBatchAndAdHocAreGatedByCapabilityContext() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201))
        ])
        let unsupported = LogCreationIdempotencyCapability(
            version: 0,
            single: false,
            adHoc: false,
            batch: false,
            batchKeyLocation: nil,
            deletedOperationReplay: "unavailable",
            preMigrationDeletedKeys: "reconciliation_only"
        )
        let provider = TestCapabilityProvider(result: .success(unsupported))
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let versionZeroReady = await service.refreshCapability(accountID: accountID)
        XCTAssertFalse(versionZeroReady)

        let batch = service.prepare(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: provider.baseURL
        )
        guard case .failure(.capabilityUnavailable) = batch else {
            return XCTFail("Version 0 must block batch preparation")
        }
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
        XCTAssertTrue(sender.recordedRequests.isEmpty)

        provider.result = .success(.ready)
        let readyAfterUpgrade = await service.refreshCapability(accountID: accountID)
        XCTAssertTrue(readyAfterUpgrade)
        let prepared = service.prepare(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: provider.baseURL
        )
        XCTAssertNoThrow(try prepared.get())

        provider.baseURL = URL(string: "https://other.example.com")!
        let changedServer = service.prepare(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-2")), draft(.meal(id: "meal-2"))],
            baseURL: provider.baseURL
        )
        guard case .failure(.capabilityUnavailable) = changedServer else {
            return XCTFail("A stale grant must not survive a server change")
        }

        service.invalidateCapability()
        let invalidated = service.prepare(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-3")), draft(.meal(id: "meal-3"))],
            baseURL: provider.baseURL
        )
        guard case .failure(.capabilityUnavailable) = invalidated else {
            return XCTFail("A generation/account reset must invalidate the grant")
        }
    }

    func testOldOrUnreadyCapabilityPreservesVerifiedEntryUntilUpgrade() async throws {
        let store = makeStore()
        let correctLogs = [
            FoodLog(
                id: "log-1",
                logDate: date,
                mealSlot: .lunch,
                item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                quantity: NutritionQuantity(amount: "100", unit: "g")
            ),
            FoodLog(
                id: "log-2",
                logDate: date,
                mealSlot: .lunch,
                item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Curry")),
                quantity: NutritionQuantity(amount: "1", unit: "serving")
            ),
        ]
        let sender = RecordingSubmissionSender([
            .failure(.uncertain("offline")),
            .result(LogSubmissionSendResult(logs: correctLogs, statusCode: 200)),
        ])
        let provider = TestCapabilityProvider()
        let service = await makeReadyService(store: store, sender: sender, provider: provider)
        let drafts = [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))]
        _ = await service.submit(
            accountID: accountID,
            summary: "Batch",
            drafts: drafts,
            baseURL: provider.baseURL
        )
        let entry = try XCTUnwrap(store.entries(accountID: accountID).first)
        let originalBody = entry.body

        for blockedResult in [
            Result<LogCreationIdempotencyCapability, Error>.failure(
                CalCoAPIError.badStatus(
                    statusCode: 404,
                    payload: APIErrorPayload(code: "not_found", message: "not found")
                )
            ),
            .success(LogCreationIdempotencyCapability(
                version: 0,
                single: false,
                adHoc: false,
                batch: false,
                batchKeyLocation: nil,
                deletedOperationReplay: "unavailable",
                preMigrationDeletedKeys: "reconciliation_only"
            )),
        ] {
            provider.result = blockedResult
            let result = await service.retry(entry: entry, accountID: accountID)
            guard case .failure(.capabilityUnavailable) = result else {
                return XCTFail("Expected capability block, got \(result)")
            }
            let preserved = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
            XCTAssertEqual(preserved.state, .uncertain)
            XCTAssertEqual(preserved.body, originalBody)
            XCTAssertEqual(sender.recordedRequests.count, 1)
        }

        provider.result = .success(.ready)
        let result = await service.retry(entry: entry, accountID: accountID)
        XCTAssertEqual(result, .success(logs: correctLogs, replayed: true))
        XCTAssertEqual(sender.recordedRequests.count, 2)
    }

    func testCapabilityIsAccountScopedAndMissingRouteFailsClosed() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201))
        ])
        let provider = TestCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: "account-a")

        let otherAccount = service.prepare(
            accountID: "account-b",
            summary: "Batch",
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: provider.baseURL
        )
        guard case .failure(.capabilityUnavailable) = otherAccount else {
            return XCTFail("A grant must not cross account boundaries")
        }

        provider.result = .failure(CalCoAPIError.badStatus(
            statusCode: 404,
            payload: APIErrorPayload(code: "not_found", message: "not found")
        ))
        _ = await service.refreshCapability(accountID: accountID)
        let oldServer = service.prepare(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: provider.baseURL
        )
        guard case .failure(.capabilityUnavailable) = oldServer else {
            return XCTFail("A 404 capability route must fail closed")
        }
    }

    func testLegacyBatchRetryBecomesReconciliationOnlyWithoutCapability() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201))
        ])
        let provider = TestCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: provider.baseURL,
            idempotencyKey: "legacy-batch"
        )
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            request: prepared.request
        )

        let result = await service.retry(entry: entry, accountID: accountID)

        guard case .failure(.reconciliationOnly) = result else {
            return XCTFail("An unverified legacy batch must never replay")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        XCTAssertEqual(
            store.entry(id: entry.id, accountID: accountID)?.state,
            .reconciliationOnly
        )
    }

    func testSingleSubmissionRequiresVerifiedCapability() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(
                logs: [
                    FoodLog(
                        id: "log-1",
                        logDate: date,
                        mealSlot: .lunch,
                        item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                        quantity: NutritionQuantity(amount: "100", unit: "g")
                    )
                ],
                statusCode: 201
            ))
        ])
        let service = await makeReadyService(store: store, sender: sender)
        let result = await service.submit(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft(.product(id: "food-1"))],
            baseURL: URL(string: "https://calco.example.com")
        )
        XCTAssertTrue(result.createdLogs.count == 1)
    }

    func testServerChangedIsNeverRejectedOrReplayed() async throws {
        let sender = CalCoLogSubmissionSender(
            client: CalCoAPIClient(baseURL: URL(string: "https://new.example.com")!)
        )
        do {
            _ = try await sender.send(
                LogSubmissionRequest(
                    requestPath: "/api/logs",
                    idempotencyKey: "key",
                    body: Data("{}".utf8),
                    baseURLString: "https://old.example.com"
                )
            )
            XCTFail("Expected the origin mismatch to block the request")
        } catch let error as LogSubmissionSendError {
            guard case .serverChanged = error else {
                return XCTFail("Expected serverChanged, got \(error)")
            }
        }

        let store = makeStore()
        let recording = RecordingSubmissionSender([
            .failure(.serverChanged("The configured server changed")),
            .result(LogSubmissionSendResult(logs: [], statusCode: 201)),
        ])
        let service = await makeReadyService(store: store, sender: recording)
        let result = await service.submit(
            accountID: accountID,
            summary: "Batch",
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: URL(string: "https://calco.example.com")
        )
        XCTAssertEqual(result, .failure(.serverChanged("The configured server changed")))
        let entry = try XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertEqual(entry.state, .serverChanged)
        XCTAssertNotNil(entry.body)
        let retried = await service.retry(entry: entry, accountID: accountID)
        XCTAssertEqual(retried, .failure(.serverChanged("The configured server changed")))
        XCTAssertEqual(recording.recordedRequests.count, 1)
    }

    func testTransientCapabilityFailurePreservesVerifiedPendingBytesForRetry() async throws {
        let store = makeStore()
        let correctLogs = [
            FoodLog(
                id: "log-1",
                logDate: date,
                mealSlot: .lunch,
                item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                quantity: NutritionQuantity(amount: "100", unit: "g")
            ),
            FoodLog(
                id: "log-2",
                logDate: date,
                mealSlot: .lunch,
                item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Curry")),
                quantity: NutritionQuantity(amount: "1", unit: "serving")
            ),
        ]
        let sender = RecordingSubmissionSender([
            .failure(.uncertain("offline")),
            .result(LogSubmissionSendResult(logs: correctLogs, statusCode: 200)),
        ])
        let provider = TestCapabilityProvider()
        let service = await makeReadyService(store: store, sender: sender, provider: provider)
        let drafts = [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))]
        let first = await service.submit(
            accountID: accountID,
            summary: "Batch",
            drafts: drafts,
            baseURL: provider.baseURL
        )
        XCTAssertEqual(first, .failure(.uncertain("offline")))
        let entry = try XCTUnwrap(store.entries(accountID: accountID).first)
        let originalBody = entry.body
        XCTAssertNotNil(originalBody)

        provider.result = .failure(CalCoAPIError.badStatus(
            statusCode: 503,
            payload: APIErrorPayload(code: "unavailable", message: "unavailable")
        ))
        let blocked = await service.retry(entry: entry, accountID: accountID)
        guard case .failure(.capabilityTemporarilyUnavailable) = blocked else {
            return XCTFail("A transient probe must block, not downgrade: \(blocked)")
        }
        let preserved = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertEqual(preserved.state, .uncertain)
        XCTAssertEqual(preserved.body, originalBody)
        XCTAssertEqual(sender.recordedRequests.count, 1)

        provider.result = .success(.ready)
        let retried = await service.retry(entry: preserved, accountID: accountID)
        XCTAssertEqual(retried, .success(logs: correctLogs, replayed: true))
        XCTAssertEqual(sender.recordedRequests.count, 2)
        XCTAssertEqual(sender.recordedRequests[0], sender.recordedRequests[1])
    }

    func testVerifiedEntryBlocksOnServerIdentityChangeWithoutSending() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .failure(.uncertain("offline")),
            .result(LogSubmissionSendResult(logs: [], statusCode: 200)),
        ])
        let provider = TestCapabilityProvider()
        let service = await makeReadyService(store: store, sender: sender, provider: provider)
        let drafts = [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))]
        _ = await service.submit(
            accountID: accountID,
            summary: "Batch",
            drafts: drafts,
            baseURL: provider.baseURL
        )
        let entry = try XCTUnwrap(store.entries(accountID: accountID).first)
        let originalBody = entry.body

        provider.baseURL = URL(string: "https://other.example.com")!
        let result = await service.retry(entry: entry, accountID: accountID)

        guard case .failure(.serverChanged) = result else {
            return XCTFail("Expected a server-identity block, got \(result)")
        }
        XCTAssertEqual(sender.recordedRequests.count, 1)
        let preserved = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertEqual(preserved.state, .serverChanged)
        XCTAssertEqual(preserved.body, originalBody)
    }

    func testLegacySingleEntryWithoutCapabilityProvenanceIsReconciliationOnly() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201))
        ])
        let provider = TestCapabilityProvider()
        let service = await makeReadyService(store: store, sender: sender, provider: provider)
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: "food-1",
            foodName: "Oats",
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: provider.baseURL,
            idempotencyKey: "legacy-single"
        )
        let entry = try store.reserve(
            accountID: accountID,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        let result = await service.retry(entry: entry, accountID: accountID)

        guard case .failure(.reconciliationOnly) = result else {
            return XCTFail("Unverified single entries must not replay")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        XCTAssertEqual(
            store.entry(id: entry.id, accountID: accountID)?.state,
            .reconciliationOnly
        )
    }

    func testMissingComponentsConflictIsDefinitiveNotIdempotencyConflict() async {
        let payload = APIErrorPayload(
            code: "missing_components",
            message: "replace them before logging"
        )
        let mapped = CalCoLogSubmissionSender.map(
            .badStatus(statusCode: 409, payload: payload)
        )
        guard case .missingComponents(let message) = mapped else {
            return XCTFail("Expected missingComponents, got \(mapped)")
        }
        XCTAssertEqual(message, "replace them before logging")
    }

    func testHeldCapabilityProbeCannotOverwriteNewAccountOrSessionGrant() async {
        let store = makeStore()
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [], statusCode: 201))
        ])
        let provider = HeldCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        provider.holdNextRequest()
        let oldProbe = Task {
            await service.refreshCapability(accountID: "account-a", generation: 1)
        }
        await provider.waitForStart()

        service.invalidateCapability()
        provider.release()
        let oldGranted = await oldProbe.value
        XCTAssertFalse(oldGranted)
        XCTAssertFalse(service.isCapabilityReady(accountID: "account-a", route: .single))

        provider.result = .success(.ready)
        let newGranted = await service.refreshCapability(
            accountID: "account-b",
            generation: 2
        )
        XCTAssertTrue(newGranted)
        XCTAssertTrue(service.isCapabilityReady(accountID: "account-b", route: .single))
        XCTAssertFalse(service.isCapabilityReady(accountID: "account-a", route: .single))
    }

    func testStaleGenerationCannotClearNewerAccountGrant() async {
        let store = makeStore()
        let sender = RecordingSubmissionSender([])
        let provider = TestCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )

        let newerGrant = await service.refreshCapability(
            accountID: "account-b",
            generation: 2
        )
        XCTAssertTrue(newerGrant)
        let staleGrant = await service.refreshCapability(
            accountID: "account-a",
            generation: 1
        )
        XCTAssertFalse(staleGrant)
        XCTAssertTrue(service.isCapabilityReady(accountID: "account-b", route: .single))
        XCTAssertFalse(service.isCapabilityReady(accountID: "account-a", route: .single))
    }

    func testSubmitReservedBlocksUnverifiedCapabilityAndRetainsBody() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([])
        let provider = TestCapabilityProvider(result: .success(
            LogCreationIdempotencyCapability(
                version: 0,
                single: false,
                adHoc: false,
                batch: false,
                batchKeyLocation: nil,
                deletedOperationReplay: "unavailable",
                preMigrationDeletedKeys: "reconciliation_only"
            )
        ))
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let drafts = [draft(.product(id: "food-1"))]
        let request = try preparedRequest(drafts: drafts)
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            request: request,
            capabilityVersion: 2
        )

        let result = await service.submitReserved(entry, accountID: accountID)

        guard case .failure(.capabilityUnavailable) = result else {
            return XCTFail("Expected capability gating, got \(result)")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        let preserved = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertEqual(preserved.state, .inFlight)
        XCTAssertEqual(preserved.body, request.body)
        XCTAssertEqual(preserved.capabilityVersion, 2)
    }

    func testSubmitReservedNeverUpgradesUnverifiedProvenance() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([])
        let service = await makeReadyService(store: store, sender: sender)
        let drafts = [draft(.product(id: "food-1"))]
        let request = try preparedRequest(drafts: drafts)
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            request: request
        )

        let result = await service.submitReserved(entry, accountID: accountID)

        guard case .failure(.reconciliationOnly) = result else {
            return XCTFail("Unverified provenance must never be silently upgraded")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        let preserved = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertNil(preserved.capabilityVersion)
        XCTAssertEqual(preserved.state, .inFlight)
        XCTAssertEqual(preserved.body, request.body)
    }

    func testSubmitReservedRejectsStaleGenerationWithoutClearingCurrentGrant() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([])
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: TestCapabilityProvider()
        )
        let newerGrant = await service.refreshCapability(
            accountID: accountID,
            generation: 2
        )
        XCTAssertTrue(newerGrant)
        let drafts = [draft(.product(id: "food-1"))]
        let request = try preparedRequest(drafts: drafts)
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            request: request,
            capabilityVersion: 2
        )

        let result = await service.submitReserved(
            entry,
            accountID: accountID,
            generation: 1
        )

        guard case .failure(.capabilityUnavailable) = result else {
            return XCTFail("A stale generation must not send, got \(result)")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        XCTAssertTrue(service.isCapabilityReady(accountID: accountID, route: .single))
    }

    func testSubmitReservedMarksServerChangedWithoutSending() async throws {
        let store = makeStore()
        let sender = RecordingSubmissionSender([])
        let service = await makeReadyService(store: store, sender: sender)
        let drafts = [draft(.product(id: "food-1"))]
        let request = try LogSubmissionRequestBuilder.prepare(
            drafts: drafts,
            baseURL: URL(string: "https://other.example.com"),
            idempotencyKey: "other-server-key"
        ).request
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            request: request,
            capabilityVersion: 2
        )

        let result = await service.submitReserved(entry, accountID: accountID)

        guard case .failure(.serverChanged) = result else {
            return XCTFail("Expected a server-change rejection, got \(result)")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        let preserved = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertEqual(preserved.state, .serverChanged)
        XCTAssertEqual(preserved.body, request.body)
    }

    func testHeldSendCannotCommitJournalAfterSessionGenerationChanges() async throws {
        let store = makeStore()
        let returned = FoodLog(
            id: "log-held",
            logDate: date,
            mealSlot: .lunch,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        let sender = HoldingSubmissionSender(
            result: LogSubmissionSendResult(logs: [returned], statusCode: 201)
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: TestCapabilityProvider()
        )
        _ = await service.refreshCapability(accountID: accountID, generation: 1)
        let drafts = [draft(.product(id: "food-1"))]
        let request = try preparedRequest(drafts: drafts)
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            request: request,
            capabilityVersion: 2
        )

        let task = Task {
            await service.submitReserved(
                entry,
                accountID: accountID,
                generation: 1
            )
        }
        await sender.waitForStart()
        service.invalidateCapability(generation: 2)
        await sender.release()
        let result = await task.value

        guard case .failure(.uncertain) = result else {
            return XCTFail("A stale send must not commit a success, got \(result)")
        }
        let sends = await sender.sendCount()
        XCTAssertEqual(sends, 1)
        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertNotEqual(stored.state, .succeeded)
        XCTAssertEqual(stored.state, .uncertain)
        XCTAssertEqual(stored.body, request.body)
    }

    func testConcurrentSameOperationReservesOneJournalRowAndSendsOnce() async throws {
        let store = makeStore()
        let returned = FoodLog(
            id: "log-one",
            logDate: date,
            mealSlot: .lunch,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        let sender = HoldingSubmissionSender(
            result: LogSubmissionSendResult(logs: [returned], statusCode: 201)
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: TestCapabilityProvider()
        )
        _ = await service.refreshCapability(accountID: accountID, generation: 1)
        let drafts = [draft(.product(id: "food-1"))]
        let request = try LogSubmissionRequestBuilder.prepare(
            drafts: drafts,
            baseURL: URL(string: "https://calco.example.com"),
            idempotencyKey: "concurrent-operation-key"
        ).request
        let persisted = LibraryPersistedLogRequest(
            accountID: accountID,
            operationID: "concurrent-operation-key",
            draft: drafts[0],
            itemName: "Oats",
            summary: "Oats",
            request: request
        )
        let adapter = JournalLibraryLogSubmissionService(service: service)

        let first = Task { await adapter.submitPersisted(persisted) }
        let second = Task { await adapter.submitPersisted(persisted) }
        await sender.waitForStart()
        await sender.release()
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        let sends = await sender.sendCount()
        XCTAssertEqual(sends, 1, "Only one live send may own this operation")
        XCTAssertEqual(store.entries(accountID: accountID).count, 1)
        let results = [firstOutcome.result, secondOutcome.result]
        XCTAssertEqual(
            results.filter {
                if case .success = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            results.filter {
                if case .failure(.uncertain) = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testLaterIntentAfterFirstSuccessCanCreateSecondLog() async throws {
        let store = makeStore()
        let firstLog = FoodLog(
            id: "log-first",
            logDate: date,
            mealSlot: .lunch,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        let secondLog = FoodLog(
            id: "log-second",
            logDate: date,
            mealSlot: .lunch,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [firstLog], statusCode: 201)),
            .result(LogSubmissionSendResult(logs: [secondLog], statusCode: 201)),
        ])
        let provider = TestCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID, generation: 1)
        let drafts = [draft(.product(id: "food-1"))]
        let firstIntent = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ).get()
        let firstResult = await service.submitPreparedIntent(
            firstIntent,
            generation: 1
        )
        guard case .success = firstResult else {
            return XCTFail("First intent failed: \(firstResult)")
        }

        let laterIntent = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ).get()
        let laterResult = await service.submitPreparedIntent(
            laterIntent,
            generation: 1
        )
        guard case .success = laterResult else {
            return XCTFail("A later intentional log should be allowed: \(laterResult)")
        }
        XCTAssertEqual(sender.recordedRequests.count, 2)
    }

    func testExpiredPreparedIntentIsDiscardedWithoutSending() async throws {
        let clock = TestSubmissionClock()
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory),
            now: { clock.now }
        )
        let returned = FoodLog(
            id: "log-expired",
            logDate: date,
            mealSlot: .lunch,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: [returned], statusCode: 201)),
        ])
        let provider = TestCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID, generation: 1)
        let drafts = [draft(.product(id: "food-1"))]
        let expired = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ).get()
        clock.now.addTimeInterval(301)

        let expiredResult = await service.submitPreparedIntent(
            expired,
            generation: 1
        )
        guard case .failure(.journalUnavailable) = expiredResult else {
            return XCTFail("An expired intent must not send: \(expiredResult)")
        }
        XCTAssertTrue(sender.recordedRequests.isEmpty)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)

        let fresh = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: drafts,
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ).get()
        let freshResult = await service.submitPreparedIntent(
            fresh,
            generation: 1
        )
        guard case .success = freshResult else {
            return XCTFail("A fresh intent should send: \(freshResult)")
        }
        XCTAssertEqual(sender.recordedRequests.count, 1)
    }

    func testMixedBatchOverlapCannotMintSecondOperationBeforeFirstCompletes() async throws {
        let store = makeStore()
        let productDraft = draft(.product(id: "food-1"))
        let mealDraft = draft(.meal(id: "meal-1"))
        let returned = [
            FoodLog(
                id: "log-1",
                logDate: date,
                mealSlot: .lunch,
                item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                quantity: NutritionQuantity(amount: "100", unit: "g")
            ),
            FoodLog(
                id: "log-2",
                logDate: date,
                mealSlot: .lunch,
                item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Curry")),
                quantity: NutritionQuantity(amount: "100", unit: "g")
            ),
        ]
        let sender = RecordingSubmissionSender([
            .result(LogSubmissionSendResult(logs: returned, statusCode: 201)),
        ])
        let provider = TestCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID, generation: 1)
        let batch = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats and Curry",
            drafts: [productDraft, mealDraft],
            itemNames: ["Oats", "Curry"],
            baseURL: provider.baseURL,
            generation: 1
        ).get()
        let overlappingSingle = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: [productDraft],
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ).get()

        let batchResult = await service.submitPreparedIntent(batch, generation: 1)
        guard case .success = batchResult else {
            return XCTFail("Batch should send: \(batchResult)")
        }
        let overlapResult = await service.submitPreparedIntent(
            overlappingSingle,
            generation: 1
        )
        guard case .failure(.uncertain) = overlapResult else {
            return XCTFail("Batch overlap must fail closed: \(overlapResult)")
        }
        XCTAssertEqual(sender.recordedRequests.count, 1)
        XCTAssertEqual(store.entries(accountID: accountID).count, 1)
    }

    // MARK: - Helpers

    private func makeReadyService(
        store: LogSubmissionStore,
        sender: any LogSubmissionSending,
        provider: TestCapabilityProvider = TestCapabilityProvider()
    ) async -> LogSubmissionService {
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID)
        return service
    }

    private func makeStore() -> LogSubmissionStore {
        LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    private func draft(
        _ item: LogSubmissionItem,
        amount: String = "100",
        unit: String = "g"
    ) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: item,
            date: date,
            mealSlot: .lunch,
            amount: amount,
            unit: unit,
            notes: nil,
            timeZone: "Europe/Paris"
        )
    }

    private func preparedRequest(
        drafts: [LogSubmissionDraft]
    ) throws -> LogSubmissionRequest {
        try LogSubmissionRequestBuilder.prepare(
            drafts: drafts,
            baseURL: URL(string: "https://calco.example.com")!,
            idempotencyKey: "matching-key"
        ).request
    }
}
