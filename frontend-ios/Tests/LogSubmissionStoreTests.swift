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

private final class QuarantineMoveHooks: @unchecked Sendable {
    var quarantine: (URL, URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
    }
    var recovery: (URL, URL) throws -> Void = {
        try FileManager.default.moveItem(at: $0, to: $1)
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: first.body,
            capabilityVersion: 2
        )
        persistence.setShouldFail(true)

        XCTAssertThrowsError(
            try store.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: second.draft,
                request: second.request,
                body: second.body,
                capabilityVersion: 2
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: matching.body,
            capabilityVersion: 2
        )
        let unrelatedEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: unrelatedFood.draft,
            request: unrelatedFood.request,
            body: unrelatedFood.body,
            capabilityVersion: 2
        )
        let otherDateEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: otherDate.draft,
            request: otherDate.request,
            body: otherDate.body,
            capabilityVersion: 2
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
            body: prepared.body,
            capabilityVersion: 2
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
            body: live.body,
            capabilityVersion: 2
        )
        let unrelatedEntry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: unrelated.draft,
            request: unrelated.request,
            body: unrelated.body,
            capabilityVersion: 2
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
                body: prepared.body,
                capabilityVersion: 2
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
                body: prepared.body,
                capabilityVersion: 2
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
                body: prepared.body,
                capabilityVersion: 2
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

    func testQuarantineDoesNotRemoveOnlyEvidenceWhenMarkerWriteFails() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        try persistence.save(Data("{not-json".utf8), accountID: entryAccount)
        let originalPermissions = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            if let originalPermissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: originalPermissions],
                    ofItemAtPath: directory.path
                )
            }
        }

        persistence.quarantine(accountID: entryAccount, reason: "invalid-envelope")

        XCTAssertFalse(persistence.isQuarantined(accountID: entryAccount))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(
            files.contains { $0.hasSuffix(".json") },
            "The corrupt source must remain when the durable marker cannot be written"
        )

        if let originalPermissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions],
                ofItemAtPath: directory.path
            )
        }
        let relaunched = LogSubmissionStore(persistence: persistence)
        XCTAssertTrue(relaunched.entries(accountID: entryAccount).isEmpty)
        XCTAssertNotNil(
            relaunched.journalError(accountID: entryAccount),
            "A relaunch must not reinterpret the still-corrupt source as an empty journal"
        )
    }

    func testQuarantineMarkerSurvivesRelaunchUntilExplicitRecovery() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        try persistence.save(Data("{not-json".utf8), accountID: entryAccount)
        let store = LogSubmissionStore(persistence: persistence)

        XCTAssertTrue(store.entries(accountID: entryAccount).isEmpty)
        XCTAssertNotNil(store.journalError(accountID: entryAccount))
        XCTAssertTrue(persistence.isQuarantined(accountID: entryAccount))

        let relaunched = LogSubmissionStore(persistence: persistence)
        XCTAssertTrue(relaunched.entries(accountID: entryAccount).isEmpty)
        XCTAssertNotNil(
            relaunched.journalError(accountID: entryAccount),
            "A moved corrupt file must remain blocked across relaunch"
        )
        let prepared = try makeReservation()
        XCTAssertThrowsError(
            try relaunched.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body,
                capabilityVersion: 2
            )
        )

        try relaunched.recoverQuarantinedJournal(accountID: entryAccount)
        XCTAssertFalse(persistence.isQuarantined(accountID: entryAccount))
        XCTAssertNil(relaunched.journalError(accountID: entryAccount))
        XCTAssertNoThrow(
            try relaunched.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body,
                capabilityVersion: 2
            )
        )
    }

    func testRecoveryMovesCorruptSourceBeforeClearingMarker() throws {
        let hooks = QuarantineMoveHooks()
        var persistence = FileLogSubmissionPersistence(directoryURL: directory)
        persistence.quarantineMove = { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }
        persistence.recoveryMove = { url, destination in
            try hooks.recovery(url, destination)
        }
        try persistence.save(Data("{not-json".utf8), accountID: entryAccount)
        let store = LogSubmissionStore(persistence: persistence)

        XCTAssertTrue(store.entries(accountID: entryAccount).isEmpty)
        XCTAssertNotNil(store.journalError(accountID: entryAccount))
        XCTAssertTrue(persistence.isQuarantined(accountID: entryAccount))
        let source = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )

        try store.recoverQuarantinedJournal(accountID: entryAccount)

        XCTAssertFalse(persistence.isQuarantined(accountID: entryAccount))
        XCTAssertNil(store.journalError(accountID: entryAccount))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let prepared = try makeReservation()
        XCTAssertNoThrow(
            try store.reserve(
                accountID: entryAccount,
                foodName: "Oats",
                draft: prepared.draft,
                request: prepared.request,
                body: prepared.body,
                capabilityVersion: 2
            )
        )
    }

    func testRecoveryMoveRefusalKeepsMarkerAndSourceBlocked() throws {
        let hooks = QuarantineMoveHooks()
        var persistence = FileLogSubmissionPersistence(directoryURL: directory)
        persistence.quarantineMove = { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }
        persistence.recoveryMove = { url, destination in
            try hooks.recovery(url, destination)
        }
        try persistence.save(Data("{not-json".utf8), accountID: entryAccount)
        let store = LogSubmissionStore(persistence: persistence)
        XCTAssertTrue(store.entries(accountID: entryAccount).isEmpty)
        XCTAssertNotNil(store.journalError(accountID: entryAccount))
        hooks.recovery = { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertThrowsError(
            try store.recoverQuarantinedJournal(accountID: entryAccount)
        )
        XCTAssertTrue(persistence.isQuarantined(accountID: entryAccount))
        XCTAssertNotNil(store.journalError(accountID: entryAccount))
        let source = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRecoveryDoesNotRemoveNewSourceWithStaleIdentity() throws {
        let hooks = QuarantineMoveHooks()
        var persistence = FileLogSubmissionPersistence(directoryURL: directory)
        persistence.quarantineMove = { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }
        persistence.recoveryMove = { url, destination in
            try hooks.recovery(url, destination)
        }
        try persistence.save(Data("{not-json".utf8), accountID: entryAccount)
        let store = LogSubmissionStore(persistence: persistence)
        XCTAssertTrue(store.entries(accountID: entryAccount).isEmpty)
        XCTAssertNotNil(store.journalError(accountID: entryAccount))
        let source = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        try Data("new-valid-source".utf8).write(to: source, options: [.atomic])

        XCTAssertThrowsError(
            try store.recoverQuarantinedJournal(accountID: entryAccount)
        )
        XCTAssertTrue(persistence.isQuarantined(accountID: entryAccount))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            "new-valid-source"
        )
    }

    func testReserveSameKeyReturnsExactExistingEntryAndConflictsOnChangedPayload() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try makeReservation(key: "same-operation-key")
        let first = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body,
            capabilityVersion: 2
        )
        let second = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body,
            capabilityVersion: 2
        )
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(store.entries(accountID: entryAccount).count, 1)

        let changedDraft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "200",
            unit: "g",
            notes: "Café",
            timeZone: "America/New_York"
        )
        let changedRequest = try LogSubmissionRequestBuilder.prepare(
            drafts: [changedDraft],
            baseURL: URL(string: "https://calco.example.com"),
            idempotencyKey: "same-operation-key"
        ).request
        XCTAssertThrowsError(
            try store.reserve(
                accountID: entryAccount,
                summary: "Oats",
                drafts: [changedDraft],
                request: changedRequest,
                capabilityVersion: 2
            )
        ) {
            XCTAssertEqual($0 as? LogSubmissionStoreError, .idempotencyConflict)
        }
        XCTAssertEqual(store.entries(accountID: entryAccount).count, 1)
    }

    func testTerminalExactMatchUsesRetainedHashAndChangedPayloadConflicts() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: persistence)
        let prepared = try makeReservation(key: "terminal-hash-key")
        let entry = try store.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body,
            capabilityVersion: 2
        )
        try store.markSucceeded(
            id: entry.id,
            accountID: entryAccount,
            logID: "terminal-log",
            date: date,
            mealSlot: .lunch,
            replayed: false
        )
        let relaunched = LogSubmissionStore(persistence: persistence)
        let terminal = try XCTUnwrap(
            relaunched.entry(id: entry.id, accountID: entryAccount)
        )
        XCTAssertNil(terminal.body)
        XCTAssertNotNil(terminal.requestSHA256)
        let logRequest = LogSubmissionRequest(
            requestPath: "/api/logs",
            idempotencyKey: prepared.request.idempotencyKey ?? "terminal-hash-key",
            body: prepared.body,
            baseURLString: prepared.request.baseURLString
        )
        XCTAssertTrue(
            terminal.matchesRequest(
                logRequest,
                drafts: [prepared.draft]
            )
        )

        let replay = try relaunched.reserve(
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body,
            capabilityVersion: 2
        )
        XCTAssertEqual(replay.id, entry.id)
        XCTAssertEqual(replay.state, .succeeded)

        let changedDraft = LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: date,
            mealSlot: .lunch,
            amount: "200",
            unit: "g",
            notes: "Café",
            timeZone: "America/New_York"
        )
        let changedRequest = try LogSubmissionRequestBuilder.prepare(
            drafts: [changedDraft],
            baseURL: URL(string: "https://calco.example.com"),
            idempotencyKey: "terminal-hash-key"
        ).request
        XCTAssertThrowsError(
            try relaunched.reserve(
                accountID: entryAccount,
                summary: "Oats",
                drafts: [changedDraft],
                request: changedRequest,
                capabilityVersion: 2
            )
        ) {
            XCTAssertEqual($0 as? LogSubmissionStoreError, .idempotencyConflict)
        }
        XCTAssertEqual(relaunched.entries(accountID: entryAccount).count, 1)
    }

    func testLegacyTerminalWithoutBodyOrHashCannotMatchRequest() throws {
        let prepared = try makeReservation(key: "legacy-terminal-key")
        let entry = PendingLogSubmission(
            id: "legacy-terminal",
            accountID: entryAccount,
            foodName: "Oats",
            draft: prepared.draft,
            idempotencyKey: "legacy-terminal-key",
            body: nil,
            requestSHA256: nil,
            baseURLString: "https://calco.example.com",
            requestPath: "/api/logs",
            state: .succeeded,
            createdAt: Date(),
            updatedAt: Date()
        )
        XCTAssertFalse(
            entry.matchesRequest(
                LogSubmissionRequest(
                    requestPath: "/api/logs",
                    idempotencyKey: "legacy-terminal-key",
                    body: prepared.body,
                    baseURLString: prepared.request.baseURLString
                ),
                drafts: [prepared.draft]
            )
        )
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

    private var entryAccount: String { "account-a" }
}
