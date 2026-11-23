import Combine
import XCTest

@testable import CalCo

private final class UnreadableJournalPersistence: LogSubmissionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var savedData: [Data] = []
    private var quarantines = 0

    var saveCount: Int { lock.withLock { savedData.count } }
    var quarantineCount: Int { lock.withLock { quarantines } }

    func load(accountID: String) throws -> Data? {
        throw CocoaError(.fileReadCorruptFile)
    }

    func save(_ data: Data, accountID: String) throws {
        lock.withLock { savedData.append(data) }
    }

    func quarantine(accountID: String, reason: String) {
        lock.withLock { quarantines += 1 }
    }
}

private final class CorruptJournalPersistence: LogSubmissionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var saves = 0
    private var quarantines = 0

    init(corrupt: Data) {
        data = corrupt
    }

    var currentData: Data? { lock.withLock { data } }
    var saveCount: Int { lock.withLock { saves } }
    var quarantineCount: Int { lock.withLock { quarantines } }

    func load(accountID: String) throws -> Data? {
        lock.withLock { data }
    }

    func save(_ newData: Data, accountID: String) throws {
        lock.withLock {
            saves += 1
            data = newData
        }
    }

    func quarantine(accountID: String, reason: String) {
        lock.withLock { quarantines += 1 }
    }
}

private final class FailingSavePersistence: LogSubmissionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let base: FileLogSubmissionPersistence
    private var shouldFail = false

    init(base: FileLogSubmissionPersistence) {
        self.base = base
    }

    func setShouldFail(_ value: Bool) {
        lock.withLock { shouldFail = value }
    }

    func load(accountID: String) throws -> Data? {
        try base.load(accountID: accountID)
    }

    func save(_ data: Data, accountID: String) throws {
        if lock.withLock({ shouldFail }) {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.save(data, accountID: accountID)
    }

    func quarantine(accountID: String, reason: String) {
        base.quarantine(accountID: accountID, reason: reason)
    }
}

@MainActor
final class LogSubmissionStoreTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeReservation(
        accountID: String = "account-a",
        foodID: String = "food-1",
        date: LocalDiaryDate? = nil,
        key: String = "b6b1f5a4-3c2e-4a7e-9f6d-1a2b3c4d5e6f",
        notes: String = "Café"
    ) throws -> (draft: LogSubmissionDraft, request: FoodLogCreateRequest, body: Data) {
        try LogCreateRequestBuilder.prepare(
            foodID: foodID,
            foodName: "Oats",
            date: date ?? self.date,
            mealSlot: .lunch,
            amount: "150",
            unit: "g",
            notes: notes,
            timeZoneIdentifier: "America/New_York",
            baseURL: URL(string: "https://calco.example.com")!,
            idempotencyKey: key
        )
    }

    func testReservePersistsKeyAndExactBodyBeforeSend() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: persistence)
        let prepared = try makeReservation()

        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        let reloaded = LogSubmissionStore(persistence: persistence)
        let restored = try XCTUnwrap(
            reloaded.entry(id: entry.id, accountID: entryAccount)
        )
        XCTAssertEqual(restored.idempotencyKey, prepared.request.idempotencyKey)
        XCTAssertEqual(restored.body, prepared.body)
        XCTAssertEqual(restored.state, .uncertain, "A crashed in-flight row becomes uncertain")
    }

    func testAccountsAreIsolated() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try makeReservation()
        _ = try store.reserve(
            accountID: "account-a",
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        XCTAssertEqual(store.entries(accountID: "account-a").count, 1)
        XCTAssertEqual(store.entries(accountID: "account-b").count, 0)
    }

    func testWriteFailureDoesNotLeaveReservationOrDestroyPreviousEntry() throws {
        let base = FileLogSubmissionPersistence(directoryURL: directory)
        let persistence = FailingSavePersistence(base: base)
        let store = LogSubmissionStore(persistence: persistence)
        let first = try makeReservation(key: "11111111-1111-1111-1111-111111111111")
        let second = try makeReservation(key: "22222222-2222-2222-2222-222222222222")

        _ = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: first.draft,
            request: first.request,
            body: first.body
        )
        persistence.setShouldFail(true)

        XCTAssertThrowsError(
            try store.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: second.draft,
                request: second.request,
                body: second.body
            )
        )
        persistence.setShouldFail(false)

        let reloaded = LogSubmissionStore(persistence: base)
        XCTAssertEqual(reloaded.entries(accountID: entryAccount).map(\.idempotencyKey), [
            first.request.idempotencyKey
        ])
    }

    func testSuccessClearsBodyAndRemovesEntryFromAttention() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try makeReservation()
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        try store.markSucceeded(
            id: entry.id,
            accountID: entryAccount,
            logID: "log-1",
            date: date,
            mealSlot: .lunch,
            replayed: true
        )

        XCTAssertTrue(store.attentionEntries(accountID: entryAccount).isEmpty)
        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: entryAccount))
        XCTAssertNil(stored.body)
        XCTAssertEqual(stored.state, .succeeded)
        XCTAssertTrue(stored.replayed)
    }

    func testConflictClearsBodyAndStaysVisible() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try makeReservation()
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        try store.markConflicted(id: entry.id, accountID: entryAccount, message: "conflict")

        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: entryAccount))
        XCTAssertEqual(stored.state, .conflicted)
        XCTAssertNil(stored.body)
        XCTAssertEqual(store.attentionEntries(accountID: entryAccount).count, 1)
    }

    func testAttentionExcludesLiveInFlightButUnresolvedStillBlocks() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try makeReservation()
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        XCTAssertEqual(entry.state, .inFlight)
        XCTAssertEqual(
            store.attentionEntries(accountID: entryAccount).map(\.id),
            [entry.id],
            "An in-flight row with no live sender is a crash leftover"
        )

        try store.markInFlight(id: entry.id, accountID: entryAccount)
        XCTAssertTrue(
            store.attentionEntries(accountID: entryAccount).isEmpty,
            "A live in-flight request is not a stale recovery item"
        )
        XCTAssertEqual(
            store.unresolved(
                accountID: entryAccount,
                foodID: "food-1",
                date: date
            ).map(\.id),
            [entry.id],
            "A normal Log must still see a live matching attempt"
        )

        try store.markUncertain(
            id: entry.id,
            accountID: entryAccount,
            status: nil,
            message: "offline"
        )
        XCTAssertEqual(store.attentionEntries(accountID: entryAccount).map(\.id), [entry.id])
    }

    func testRevisionObserversSeeLiveThenUncertainTransitionImmediately() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try makeReservation()
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )
        var observedAttention: [[String]] = []
        let cancellable = store.$revision
            .dropFirst()
            .sink { _ in
                observedAttention.append(
                    store.attentionEntries(accountID: self.entryAccount).map(\.id)
                )
            }

        try store.markInFlight(id: entry.id, accountID: entryAccount)
        XCTAssertEqual(
            observedAttention.last,
            [],
            "The banner must not show a live in-flight request"
        )

        try store.markUncertain(
            id: entry.id,
            accountID: entryAccount,
            status: nil,
            message: "offline"
        )
        XCTAssertEqual(
            observedAttention.last,
            [entry.id],
            "Observers must see the new ambiguous state on the same revision"
        )
        withExtendedLifetime(cancellable) {}
    }

    func testDeletedLogInvalidatesMatchingAttemptsWithoutErasingUnrelatedEntries() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: persistence)
        let matching = try makeReservation(
            foodID: "food-1",
            key: "11111111-1111-1111-1111-111111111111"
        )
        let unrelatedFood = try makeReservation(
            foodID: "food-2",
            key: "22222222-2222-2222-2222-222222222222"
        )
        let otherDate = try makeReservation(
            foodID: "food-1",
            date: date.addingDays(-1),
            key: "33333333-3333-3333-3333-333333333333"
        )
        let matchingEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: matching.draft,
            request: matching.request,
            body: matching.body
        )
        let unrelatedEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: unrelatedFood.draft,
            request: unrelatedFood.request,
            body: unrelatedFood.body
        )
        let otherDateEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: otherDate.draft,
            request: otherDate.request,
            body: otherDate.body
        )

        let invalidated = try store.invalidateUnresolved(
            accountID: entryAccount,
            foodID: "food-1",
            date: date,
            reason: "deleted"
        )

        XCTAssertEqual(invalidated.map(\.id), [matchingEntry.id])
        let stored = try XCTUnwrap(store.entry(id: matchingEntry.id, accountID: entryAccount))
        XCTAssertEqual(stored.state, .invalidated)
        XCTAssertNil(stored.body)
        XCTAssertEqual(stored.lastMessage, "deleted")
        XCTAssertEqual(stored.idempotencyKey, matching.request.idempotencyKey)
        XCTAssertTrue(store.isRetryBlocked(id: matchingEntry.id))
        XCTAssertEqual(
            store.attentionEntries(accountID: entryAccount).map(\.id).sorted(),
            [unrelatedEntry.id, otherDateEntry.id].sorted()
        )
        XCTAssertTrue(
            store.unresolved(accountID: entryAccount, foodID: "food-1", date: date).isEmpty
        )

        XCTAssertNotNil(store.entry(id: unrelatedEntry.id, accountID: entryAccount))
        XCTAssertNotNil(store.entry(id: otherDateEntry.id, accountID: entryAccount))
        XCTAssertEqual(
            Set(store.entries(accountID: entryAccount).map(\.id)),
            [matchingEntry.id, unrelatedEntry.id, otherDateEntry.id],
            "A deletion must not silently erase unrelated ambiguous attempts"
        )

        let reloaded = LogSubmissionStore(persistence: persistence)
        XCTAssertEqual(
            reloaded.entry(id: matchingEntry.id, accountID: entryAccount)?.state,
            .invalidated,
            "The terminal invalidation must survive a relaunch"
        )
        XCTAssertEqual(
            reloaded.attentionEntries(accountID: entryAccount).map(\.id).sorted(),
            [unrelatedEntry.id, otherDateEntry.id].sorted(),
            "Only the unrelated attempts remain recoverable"
        )
    }

    func testBlockBeforeDeletingWriteFailureDoesNotChangeJournalOrBlockRetry() throws {
        let base = FileLogSubmissionPersistence(directoryURL: directory)
        let persistence = FailingSavePersistence(base: base)
        let store = LogSubmissionStore(persistence: persistence)
        let prepared = try makeReservation()
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )
        try store.markUncertain(
            id: entry.id,
            accountID: entryAccount,
            status: nil,
            message: "offline"
        )
        persistence.setShouldFail(true)

        XCTAssertThrowsError(
            try store.blockBeforeDeleting(
                accountID: entryAccount,
                foodID: "food-1",
                date: date,
                reason: "deleted"
            )
        )

        // DELETE was not sent, so the unpersisted barrier must roll back. The
        // journal still describes a retryable attempt.
        XCTAssertFalse(store.isRetryBlocked(id: entry.id))
        XCTAssertEqual(
            store.attentionEntries(accountID: entryAccount).map(\.id),
            [entry.id]
        )
        XCTAssertEqual(
            store.unresolved(accountID: entryAccount, foodID: "food-1", date: date).map(\.id),
            [entry.id]
        )
        persistence.setShouldFail(false)
        let reloaded = LogSubmissionStore(persistence: base)
        XCTAssertEqual(
            reloaded.entry(id: entry.id, accountID: entryAccount)?.state,
            .uncertain,
            "An aborted pre-delete barrier must leave the durable journal unchanged"
        )
    }

    func testBlockBeforeDeletingRefusesLiveMatchingSubmissionWithoutTouchingOthers() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: persistence)
        let live = try makeReservation(
            foodID: "food-1",
            key: "11111111-1111-1111-1111-111111111111"
        )
        let unrelated = try makeReservation(
            foodID: "food-2",
            key: "22222222-2222-2222-2222-222222222222"
        )
        let liveEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: live.draft,
            request: live.request,
            body: live.body
        )
        let unrelatedEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: unrelated.draft,
            request: unrelated.request,
            body: unrelated.body
        )
        try store.markInFlight(id: liveEntry.id, accountID: entryAccount)

        XCTAssertThrowsError(
            try store.blockBeforeDeleting(
                accountID: entryAccount,
                foodID: "food-1",
                date: date,
                reason: "deleted"
            )
        ) { error in
            XCTAssertEqual(error as? LogSubmissionStoreError, .submissionInFlight)
        }

        let storedLive = try XCTUnwrap(
            store.entry(id: liveEntry.id, accountID: entryAccount)
        )
        XCTAssertEqual(storedLive.state, .inFlight)
        XCTAssertNotNil(storedLive.body)
        XCTAssertFalse(store.isRetryBlocked(id: liveEntry.id))
        let storedUnrelated = try XCTUnwrap(
            store.entry(id: unrelatedEntry.id, accountID: entryAccount)
        )
        XCTAssertEqual(storedUnrelated.state, .inFlight)
        XCTAssertNotNil(storedUnrelated.body)

        let reloaded = LogSubmissionStore(persistence: persistence)
        XCTAssertEqual(
            reloaded.entry(id: liveEntry.id, accountID: entryAccount)?.state,
            .uncertain,
            "The held submission must survive a relaunch"
        )
    }

    func testUnreadableJournalFailsClosedWithoutSaving() throws {
        let persistence = UnreadableJournalPersistence()
        let store = LogSubmissionStore(persistence: persistence)
        let prepared = try makeReservation()

        XCTAssertThrowsError(
            try store.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body
            )
        ) { error in
            guard let storeError = error as? LogSubmissionStoreError,
                  case .unreadableJournal = storeError
            else {
                return XCTFail("Expected an unreadable-journal failure, got \(error)")
            }
        }

        XCTAssertEqual(persistence.saveCount, 0, "No write may replace an unreadable journal")
        XCTAssertThrowsError(
            try store.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body
            )
        )
        XCTAssertEqual(persistence.saveCount, 0, "The fail-closed state must persist")
        XCTAssertNotNil(store.journalError(accountID: entryAccount))
    }

    func testCorruptJournalIsQuarantinedButNeverOverwritten() throws {
        let corrupt = Data("{not-json".utf8)
        let persistence = CorruptJournalPersistence(corrupt: corrupt)
        let store = LogSubmissionStore(persistence: persistence)
        let prepared = try makeReservation()

        XCTAssertTrue(store.entries(accountID: entryAccount).isEmpty)
        XCTAssertThrowsError(
            try store.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body
            )
        ) { error in
            guard let storeError = error as? LogSubmissionStoreError,
                  case .unreadableJournal = storeError
            else {
                return XCTFail("Expected the quarantined journal to fail closed, got \(error)")
            }
        }

        XCTAssertEqual(persistence.quarantineCount, 1)
        XCTAssertEqual(persistence.saveCount, 0, "Quarantine must not be followed by an overwrite")
        XCTAssertEqual(persistence.currentData, corrupt, "The original bytes remain untouched")
    }

    func testMissingEntryThrowsInsteadOfSendingFromMemory() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )

        XCTAssertThrowsError(
            try store.markInFlight(id: "missing-entry", accountID: entryAccount)
        ) { error in
            XCTAssertEqual(error as? LogSubmissionStoreError, .missingEntry)
        }
        XCTAssertThrowsError(
            try store.requireEntry(id: "missing-entry", accountID: entryAccount)
        ) { error in
            XCTAssertEqual(error as? LogSubmissionStoreError, .missingEntry)
        }
    }

    func testNewerSchemaJournalIsQuarantinedWithoutBlockingTheLegacyJournal() throws {
        let newer = Data(#"{"schemaVersion":2,"entries":[]}"#.utf8)
        let persistence = CorruptJournalPersistence(corrupt: newer)
        let store = LogSubmissionStore(persistence: persistence)

        XCTAssertEqual(store.entries(accountID: entryAccount), [])
        XCTAssertNil(store.journalError(accountID: entryAccount))
        XCTAssertEqual(persistence.quarantineCount, 1)
        XCTAssertEqual(persistence.saveCount, 0, "A newer journal must not be overwritten")
        XCTAssertEqual(persistence.currentData, newer, "The quarantined source stays untouched")

        let prepared = try makeReservation()
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )
        XCTAssertEqual(entry.accountID, entryAccount)
        XCTAssertEqual(persistence.saveCount, 1)
    }

    private var entryAccount: String { "account-a" }
}
