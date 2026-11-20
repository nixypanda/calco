import XCTest

@testable import CalCo

private actor ReviewerSingleRetryService: FoodDetailServicing {
    private(set) var createCalls = 0

    func fetchFoodDetail(id: String) async throws -> FoodDetail {
        FoodDetail(id: id, name: "Capability Review")
    }

    func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        createCalls += 1
        return CreatedFoodLog(
            id: "created-\(createCalls)",
            date: request.date,
            mealSlot: request.mealSlot
        )
    }
}

private final class ReviewerUnsupportedCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
    let baseURL = URL(string: "https://calco.example.com")!

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        LogCreationIdempotencyCapability(
            version: 0,
            single: false,
            adHoc: false,
            batch: false,
            batchKeyLocation: nil,
            deletedOperationReplay: "unavailable",
            preMigrationDeletedKeys: "reconciliation_only"
        )
    }
}

private final class ReviewerReadyCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
    let baseURL = URL(string: "https://calco.example.com")!

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        LogCreationIdempotencyCapability(
            version: 2,
            single: true,
            adHoc: true,
            batch: true,
            batchKeyLocation: "top_level",
            deletedOperationReplay: "conflict",
            preMigrationDeletedKeys: "reconciliation_only"
        )
    }
}

private actor ReviewerPersistedSender: LogSubmissionSending {
    private(set) var sendCount = 0
    private let date: LocalDiaryDate

    init(date: LocalDiaryDate) {
        self.date = date
    }

    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        sendCount += 1
        return LogSubmissionSendResult(
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
        )
    }
}

private actor ReviewerUncertainSender: LogSubmissionSending {
    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        throw LogSubmissionSendError.uncertain("offline")
    }
}

private actor ReviewerWrongItemSender: LogSubmissionSending {
    private let date: LocalDiaryDate

    init(date: LocalDiaryDate) {
        self.date = date
    }

    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        LogSubmissionSendResult(
            logs: [
                FoodLog(
                    id: "foreign-log",
                    logDate: date,
                    mealSlot: .lunch,
                    item: .product(ProductLogItemSnapshot(id: "other-food", name: "Other")),
                    quantity: NutritionQuantity(amount: "100", unit: "g")
                )
            ],
            statusCode: 201
        )
    }
}

private actor ReviewerHeldSender: LogSubmissionSending {
    private let date: LocalDiaryDate
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sendCount = 0

    init(date: LocalDiaryDate) {
        self.date = date
    }

    func send(_ request: LogSubmissionRequest) async throws -> LogSubmissionSendResult {
        sendCount += 1
        started = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
        return LogSubmissionSendResult(
            logs: [
                FoodLog(
                    id: "log-held",
                    logDate: date,
                    mealSlot: .lunch,
                    item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
                    quantity: NutritionQuantity(amount: "100", unit: "g")
                )
            ],
            statusCode: 201
        )
    }

    func waitForStart() async {
        let deadline = Date().addingTimeInterval(2)
        while !started, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(started, "Timed out waiting for held send")
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ReviewerSessionContextState {
    var context: LogSubmissionSessionContext?
}

private final class ReviewerHeldCapabilityProvider:
    LogCreationCapabilityProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedBaseURL: URL
    private var storedResult: Result<LogCreationIdempotencyCapability, Error> =
        .success(LogCreationIdempotencyCapability(
            version: 2,
            single: true,
            adHoc: true,
            batch: true,
            batchKeyLocation: "top_level",
            deletedOperationReplay: "conflict",
            preMigrationDeletedKeys: "reconciliation_only"
        ))
    private var holdNext = false
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(baseURL: URL = URL(string: "https://calco.example.com")!) {
        self.storedBaseURL = baseURL
    }

    var baseURL: URL {
        lock.withLock { storedBaseURL }
    }

    func setBaseURL(_ url: URL) {
        lock.withLock { storedBaseURL = url }
    }

    func holdNextRequest() {
        lock.withLock {
            holdNext = true
            started = false
            released = false
            continuation = nil
        }
    }

    func fetchCapabilities() async throws -> LogCreationIdempotencyCapability {
        let shouldHold = lock.withLock { () -> Bool in
            guard holdNext else { return false }
            holdNext = false
            started = true
            return true
        }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyReleased = lock.withLock { () -> Bool in
                    if released { return true }
                    self.continuation = continuation
                    return false
                }
                if alreadyReleased {
                    continuation.resume()
                }
            }
        }
        return try lock.withLock { storedResult }.get()
    }

    func waitForStart() async {
        let deadline = Date().addingTimeInterval(2)
        while !lock.withLock({ started }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(lock.withLock { started }, "Timed out waiting for capability probe")
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            let current = self.continuation
            self.continuation = nil
            return current
        }
        continuation?.resume()
    }
}

@MainActor
final class ReviewerCapabilityRetryTests: XCTestCase {
    private let accountID = "capability-review-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    func testSingleRetryMustBeBlockedWhenCapabilityIsNotCurrentlyVerified() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-capability-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: "food-capability-review",
            foodName: "Capability Review",
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: URL(string: "https://calco.example.com"),
            idempotencyKey: "review-single-retry-key"
        )
        let entry = try store.reserve(
            accountID: accountID,
            foodName: "Capability Review",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body,
            capabilityVersion: 2
        )
        try store.markUncertain(
            id: entry.id,
            accountID: accountID,
            status: nil,
            message: "offline"
        )

        let service = ReviewerSingleRetryService()
        let viewModel = FoodDetailViewModel(
            foodID: "food-capability-review",
            originDate: date,
            originMealSlot: .lunch,
            service: service,
            accountID: accountID,
            baseURL: URL(string: "https://calco.example.com"),
            submissionStore: store,
            singleCapabilityReady: { false }
        )
        await viewModel.load()
        viewModel.refreshRecoveryEntries()
        XCTAssertEqual(viewModel.pendingSubmissions.map(\.id), [entry.id])

        await viewModel.retryPending()

        let calls = await service.createCalls
        XCTAssertEqual(
            calls,
            0,
            "A stored v2 key must not be replayed while the current capability is unverified"
        )
    }

    func testPersistedHandoffMustBeBlockedWhenCapabilityIsVersionZero() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-persisted-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerUnsupportedCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-persisted-key"
        )
        let adapter = JournalLibraryLogSubmissionService(service: service)

        let outcome = await adapter.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: "review-persisted-key",
                draft: draft,
                itemName: "Oats",
                summary: "Oats",
                request: prepared.request
            )
        )

        let sends = await sender.sendCount
        XCTAssertEqual(
            sends,
            0,
            "A save-food handoff must not POST a keyed request while capability is version zero"
        )
        guard case .failure(.capabilityUnavailable) = outcome.result else {
            return XCTFail("Expected capability gating, got \(outcome.result)")
        }
    }

    func testPersistedHandoffKeepsVerifiedCapabilityAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-persisted-relaunch-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: persistence)
        let provider = ReviewerReadyCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: ReviewerUncertainSender(),
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-persisted-relaunch-key"
        )
        let adapter = JournalLibraryLogSubmissionService(service: service)

        let outcome = await adapter.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: "review-persisted-relaunch-key",
                draft: draft,
                itemName: "Oats",
                summary: "Oats",
                request: prepared.request
            )
        )
        guard case .failure(.uncertain) = outcome.result else {
            return XCTFail("Expected an uncertain journal result, got \(outcome.result)")
        }
        let entry = try XCTUnwrap(
            store.entry(
                accountID: accountID,
                idempotencyKey: "review-persisted-relaunch-key"
            )
        )
        XCTAssertEqual(
            entry.capabilityVersion,
            2,
            "A handoff key verified under v2 must be stamped as replayable"
        )
        XCTAssertNotNil(entry.body)

        let relaunched = LogSubmissionStore(persistence: persistence)
        let reloaded = try XCTUnwrap(
            relaunched.entry(
                accountID: accountID,
                idempotencyKey: "review-persisted-relaunch-key"
            )
        )
        XCTAssertEqual(
            reloaded.state,
            .uncertain,
            "A verified v2 handoff must remain retryable after relaunch"
        )
        XCTAssertNotNil(reloaded.body)
    }

    func testSubmitReservedRejectsAccountSwitchBetweenReserveAndSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-account-switch-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: "account-a")
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-account-switch-key"
        )
        let entry = try store.reserve(
            accountID: "account-a",
            summary: "Oats",
            drafts: [draft],
            request: prepared.request,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )

        // The session changes after the entry was reserved but before send.
        _ = await service.refreshCapability(accountID: "account-b", generation: 2)

        let result = await service.submitReserved(entry, accountID: "account-a")

        let sends = await sender.sendCount
        XCTAssertEqual(
            sends,
            0,
            "An account switch must not send account A's entry under account B's session"
        )
        guard case .failure(.capabilityUnavailable) = result else {
            return XCTFail("Expected account-bound capability rejection, got \(result)")
        }
    }

    func testSubmitReservedRejectsSameGenerationForeignGrant() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-same-generation-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: "account-a")
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-same-generation-key"
        )
        let entry = try store.reserve(
            accountID: "account-a",
            summary: "Oats",
            drafts: [draft],
            request: prepared.request,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )

        _ = await service.refreshCapability(accountID: "account-b", generation: 2)

        let result = await service.submitReserved(
            entry,
            accountID: "account-a",
            generation: 2
        )

        let sends = await sender.sendCount
        XCTAssertEqual(
            sends,
            0,
            "Generation 2 is bound to account B; account A must not reuse it"
        )
        guard case .failure(.capabilityUnavailable) = result else {
            return XCTFail("Expected account-bound generation rejection, got \(result)")
        }
    }

    func testSameTimestampPreparedIntentIsBlockedButClockAdvanceAllowsLaterAction() async throws {
        final class Clock {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
        }
        let clock = Clock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-intent-clock-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory),
            now: { clock.now }
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )

        let first = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: provider.baseURL
        ).get()
        let firstResult = await service.submitPreparedIntent(first)
        guard case .success = firstResult else {
            return XCTFail("First intent should send: \(firstResult)")
        }

        let sameTick = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: provider.baseURL
        ).get()
        let sameTickResult = await service.submitPreparedIntent(sameTick)
        guard case .failure(.uncertain) = sameTickResult else {
            return XCTFail("Same-tick overlap must fail closed: \(sameTickResult)")
        }
        var sends = await sender.sendCount
        XCTAssertEqual(sends, 1)

        clock.now.addTimeInterval(1)
        let later = try service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: provider.baseURL
        ).get()
        let laterResult = await service.submitPreparedIntent(later)
        guard case .success = laterResult else {
            return XCTFail("A later-clock intent should send: \(laterResult)")
        }
        sends = await sender.sendCount
        XCTAssertEqual(sends, 2)
    }

    func testPersistedSucceededReplayRejectsChangedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-changed-success-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let state = ReviewerSessionContextState()
        state.context = LogSubmissionSessionContext(
            accountID: accountID,
            generation: 1,
            baseURL: provider.baseURL
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let originalDraft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let originalRequest = try LogSubmissionRequestBuilder.prepare(
            drafts: [originalDraft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-changed-success-key"
        ).request
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: [originalDraft],
            request: originalRequest,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )
        try store.markSucceeded(
            id: entry.id,
            accountID: accountID,
            logID: "old-log",
            date: date,
            mealSlot: .lunch,
            replayed: false
        )

        let changedDraft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "200",
            unit: "g",
            notes: "different payload",
            timeZone: "Asia/Kolkata"
        )
        let changedRequest = try LogSubmissionRequestBuilder.prepare(
            drafts: [changedDraft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-changed-success-key"
        ).request
        let adapter = JournalLibraryLogSubmissionService(
            service: service,
            sessionContextProvider: { state.context }
        )

        let outcome = await adapter.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: "review-changed-success-key",
                draft: changedDraft,
                itemName: "Oats",
                summary: "Oats",
                request: changedRequest
            )
        )

        let sends = await sender.sendCount
        XCTAssertEqual(sends, 0)
        guard case .failure(.conflict) = outcome.result else {
            return XCTFail("Changed payload must not replay as success, got \(outcome.result)")
        }
    }

    func testPersistedUncertainReplayRejectsChangedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-changed-uncertain-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let state = ReviewerSessionContextState()
        state.context = LogSubmissionSessionContext(
            accountID: accountID,
            generation: 1,
            baseURL: provider.baseURL
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let originalDraft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let originalRequest = try LogSubmissionRequestBuilder.prepare(
            drafts: [originalDraft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-changed-uncertain-key"
        ).request
        let entry = try store.reserve(
            accountID: accountID,
            summary: "Oats",
            drafts: [originalDraft],
            request: originalRequest,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )
        try store.markUncertain(
            id: entry.id,
            accountID: accountID,
            status: nil,
            message: "offline"
        )

        let changedDraft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "200",
            unit: "g",
            notes: "different payload",
            timeZone: "Asia/Kolkata"
        )
        let changedRequest = try LogSubmissionRequestBuilder.prepare(
            drafts: [changedDraft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-changed-uncertain-key"
        ).request
        let adapter = JournalLibraryLogSubmissionService(
            service: service,
            sessionContextProvider: { state.context }
        )

        let outcome = await adapter.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: "review-changed-uncertain-key",
                draft: changedDraft,
                itemName: "Oats",
                summary: "Oats",
                request: changedRequest
            )
        )

        let sends = await sender.sendCount
        XCTAssertEqual(sends, 0)
        guard case .failure(.conflict) = outcome.result else {
            return XCTFail("Changed payload must conflict, not remain pending: \(outcome.result)")
        }
    }

    func testTwoPreparedIntentsCannotCreateSecondLogAfterFirstSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-prepared-race-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let state = ReviewerSessionContextState()
        state.context = LogSubmissionSessionContext(
            accountID: accountID,
            generation: 1,
            baseURL: provider.baseURL
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider,
            sessionContextProvider: { state.context }
        )
        _ = await service.refreshCapability(accountID: accountID, generation: 1)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )

        let firstIntent: PreparedLogSubmissionIntent
        let secondIntent: PreparedLogSubmissionIntent
        switch service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ) {
        case .success(let intent):
            firstIntent = intent
        case .failure(let failure):
            return XCTFail("First intent failed: \(failure)")
        }
        switch service.prepareIntent(
            accountID: accountID,
            summary: "Oats",
            drafts: [draft],
            itemNames: ["Oats"],
            baseURL: provider.baseURL,
            generation: 1
        ) {
        case .success(let intent):
            secondIntent = intent
        case .failure(let failure):
            return XCTFail("Second intent failed: \(failure)")
        }

        let firstResult = await service.submitPreparedIntent(
            firstIntent,
            generation: 1
        )
        guard case .success = firstResult else {
            return XCTFail("First prepared intent should send: \(firstResult)")
        }
        let secondResult = await service.submitPreparedIntent(
            secondIntent,
            generation: 1
        )

        let sends = await sender.sendCount
        XCTAssertEqual(
            sends,
            1,
            "Two prepared intents for the same item/date must not create a second log"
        )
        XCTAssertFalse(
            {
                if case .success = secondResult { return true }
                return false
            }(),
            "The second prepared intent must fail closed: \(secondResult)"
        )
    }

    func testSessionContextChangeBeforeSubmitBlocksForeignSend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-context-before-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let state = ReviewerSessionContextState()
        state.context = LogSubmissionSessionContext(
            accountID: "account-a",
            generation: 1,
            baseURL: provider.baseURL
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider,
            sessionContextProvider: { state.context }
        )
        _ = await service.refreshCapability(accountID: "account-a", generation: 1)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-context-before-key"
        )
        let entry = try store.reserve(
            accountID: "account-a",
            summary: "Oats",
            drafts: [draft],
            request: prepared.request,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )

        state.context = LogSubmissionSessionContext(
            accountID: "account-b",
            generation: 2,
            baseURL: provider.baseURL
        )

        let result = await service.submitReserved(
            entry,
            accountID: "account-a",
            generation: 1
        )

        let sends = await sender.sendCount
        XCTAssertEqual(sends, 0)
        guard case .failure(.capabilityUnavailable) = result else {
            return XCTFail("Expected stale-context rejection, got \(result)")
        }
    }

    func testHeldSendStaleContextLeavesUncertainAndRetainsBody() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-held-send-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerHeldSender(date: date)
        let provider = ReviewerReadyCapabilityProvider()
        let state = ReviewerSessionContextState()
        state.context = LogSubmissionSessionContext(
            accountID: "account-a",
            generation: 1,
            baseURL: provider.baseURL
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider,
            sessionContextProvider: { state.context }
        )
        _ = await service.refreshCapability(accountID: "account-a", generation: 1)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-held-send-key"
        )
        let entry = try store.reserve(
            accountID: "account-a",
            summary: "Oats",
            drafts: [draft],
            request: prepared.request,
            itemNames: ["Oats"],
            capabilityVersion: 2
        )

        let task = Task {
            await service.submitReserved(
                entry,
                accountID: "account-a",
                generation: 1
            )
        }
        await sender.waitForStart()
        state.context = LogSubmissionSessionContext(
            accountID: "account-b",
            generation: 2,
            baseURL: provider.baseURL
        )
        await sender.release()
        let result = await task.value

        guard case .failure(.uncertain) = result else {
            return XCTFail("A stale held send must be uncertain, got \(result)")
        }
        let stored = try XCTUnwrap(
            store.entry(id: entry.id, accountID: "account-a")
        )
        XCTAssertEqual(stored.state, .uncertain)
        XCTAssertEqual(stored.body, prepared.request.body)
        let sends = await sender.sendCount
        XCTAssertEqual(sends, 1)
    }

    func testSessionContextChangeDuringCapabilityProbeRetainsCatalogIntent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-context-probe-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerHeldCapabilityProvider()
        let state = ReviewerSessionContextState()
        state.context = LogSubmissionSessionContext(
            accountID: "account-a",
            generation: 1,
            baseURL: provider.baseURL
        )
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider,
            sessionContextProvider: { state.context }
        )
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-context-probe-key"
        )
        provider.holdNextRequest()
        let task = Task {
            await service.reserveExact(
                accountID: "account-a",
                summary: "Oats",
                draft: draft,
                itemName: "Oats",
                request: prepared.request,
                generation: 1
            )
        }
        await provider.waitForStart()
        state.context = LogSubmissionSessionContext(
            accountID: "account-b",
            generation: 2,
            baseURL: provider.baseURL
        )
        provider.release()
        let result = await task.value

        guard case .failure(.capabilityUnavailable) = result else {
            return XCTFail("Expected context-bound probe rejection, got \(result)")
        }
        let sends = await sender.sendCount
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(store.entries(accountID: "account-a").isEmpty)
    }

    func testPersistedHandoffRejectsMismatchedResponseAndKeepsBody() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-mismatch-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let provider = ReviewerReadyCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: ReviewerWrongItemSender(date: date),
            capabilityProvider: provider
        )
        _ = await service.refreshCapability(accountID: accountID)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-mismatch-key"
        )
        let adapter = JournalLibraryLogSubmissionService(service: service)

        let outcome = await adapter.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: "review-mismatch-key",
                draft: draft,
                itemName: "Oats",
                summary: "Oats",
                request: prepared.request
            )
        )

        guard case .failure(.uncertain) = outcome.result else {
            return XCTFail("A mismatched response must be uncertain, got \(outcome.result)")
        }
        let entry = try XCTUnwrap(
            store.entry(
                accountID: accountID,
                idempotencyKey: "review-mismatch-key"
            )
        )
        XCTAssertEqual(entry.state, .uncertain)
        XCTAssertEqual(entry.body, prepared.request.body)
        XCTAssertNotNil(entry.body)
    }

    func testPersistedHandoffRejectsBaseURLChangeDuringProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-base-probe-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerHeldCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-base-probe-key"
        )
        let adapter = JournalLibraryLogSubmissionService(service: service)
        provider.holdNextRequest()
        let task = Task {
            await adapter.submitPersisted(
                LibraryPersistedLogRequest(
                    accountID: accountID,
                    operationID: "review-base-probe-key",
                    draft: draft,
                    itemName: "Oats",
                    summary: "Oats",
                    request: prepared.request
                )
            )
        }
        await provider.waitForStart()
        provider.setBaseURL(URL(string: "https://other.example.com")!)
        provider.release()

        let outcome = await task.value
        let sends = await sender.sendCount
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
        guard case .failure(.capabilityUnavailable) = outcome.result else {
            return XCTFail("Expected base-bound capability rejection, got \(outcome.result)")
        }
    }

    func testPersistedHandoffRejectsAccountChangeDuringProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-review-account-probe-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let sender = ReviewerPersistedSender(date: date)
        let provider = ReviewerHeldCapabilityProvider()
        let service = LogSubmissionService(
            store: store,
            sender: sender,
            capabilityProvider: provider
        )
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: provider.baseURL,
            idempotencyKey: "review-account-probe-key"
        )
        let adapter = JournalLibraryLogSubmissionService(service: service)
        provider.holdNextRequest()
        let task = Task {
            await adapter.submitPersisted(
                LibraryPersistedLogRequest(
                    accountID: accountID,
                    operationID: "review-account-probe-key",
                    draft: draft,
                    itemName: "Oats",
                    summary: "Oats",
                    request: prepared.request
                )
            )
        }
        await provider.waitForStart()
        _ = await service.refreshCapability(accountID: "account-b", generation: 2)
        provider.release()

        let outcome = await task.value
        let sends = await sender.sendCount
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(store.entries(accountID: accountID).isEmpty)
        guard case .failure(.capabilityUnavailable) = outcome.result else {
            return XCTFail("Expected account-bound capability rejection, got \(outcome.result)")
        }
    }
}
