import XCTest

@testable import CalCo

@MainActor
final class LogSubmissionJournalV2Tests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let accountID = "account-a"
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testVersionOneEnvelopeMigratesProductDraftAndRewritesV2() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let body = try JSONEncoder().encode(["legacy": true])
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "entries": [[
                "id": "entry-1",
                "accountID": accountID,
                "foodName": "Oats",
                "draft": [
                    "foodID": "food-1",
                    "date": [
                        "year": 2026,
                        "month": 11,
                        "day": 17,
                    ],
                    "mealSlot": "lunch",
                    "amount": "150",
                    "unit": "g",
                    "notes": "Café",
                    "timeZone": "Europe/Paris",
                ],
                "idempotencyKey": "legacy-key",
                "body": body.base64EncodedString(),
                "baseURLString": "https://calco.example.com",
                "requestPath": "/api/logs",
                "state": "uncertain",
                "attemptCount": 1,
                "createdAt": Date().timeIntervalSinceReferenceDate,
                "updatedAt": Date().timeIntervalSinceReferenceDate,
                "replayed": false,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try persistence.save(data, accountID: accountID)

        let store = LogSubmissionStore(persistence: persistence)
        let entry = try XCTUnwrap(store.entries(accountID: accountID).first)
        XCTAssertEqual(entry.draft.item, .product(id: "food-1"))
        XCTAssertEqual(entry.draft.foodID, "food-1")
        XCTAssertEqual(entry.draft.notes, "Café")
        XCTAssertEqual(entry.state, .reconciliationOnly)
        XCTAssertNil(entry.body, "A pre-v2 key must never replay automatically")

        let rewritten = try XCTUnwrap(persistence.load(accountID: accountID))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let draft = try XCTUnwrap(entries.first?["draft"] as? [String: Any])
        XCTAssertEqual((draft["item"] as? [String: Any])?["type"] as? String, "product")
        XCTAssertNil(draft["foodID"])
    }

    func testBatchReservationRequiresAtLeastTwoDrafts() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            baseURL: URL(string: "https://calco.example.com")!,
            idempotencyKey: "batch-key"
        )
        XCTAssertEqual(prepared.route, .batch)

        XCTAssertThrowsError(
            try store.reserve(
                accountID: accountID,
                summary: "One",
                drafts: [draft(.product(id: "food-1"))],
                request: prepared.request
            )
        ) { error in
            XCTAssertEqual(error as? LogSubmissionStoreError, .invalidRequest)
        }
    }

    func testAdHocRouteRejectsProductDraft() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let request = LogSubmissionRequest(
            requestPath: "/api/logs/ad-hoc",
            idempotencyKey: "ad-hoc-key",
            body: Data("{}".utf8)
        )
        XCTAssertThrowsError(
            try store.reserve(
                accountID: accountID,
                summary: "Oats",
                drafts: [draft(.product(id: "food-1"))],
                request: request
            )
        ) { error in
            XCTAssertEqual(error as? LogSubmissionStoreError, .invalidRequest)
        }
    }

    func testBatchRouteRejectsAdHocDraftEvenWithAFabricatedRequest() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let request = LogSubmissionRequest(
            requestPath: "/api/logs/batch",
            idempotencyKey: "batch-key",
            body: Data("{}".utf8)
        )
        let adHoc = LogSubmissionDraft(
            item: .adHoc(name: "Toast", brand: nil),
            date: date,
            mealSlot: .lunch,
            amount: "1",
            unit: "serving",
            notes: nil,
            timeZone: "Europe/Paris"
        )
        XCTAssertThrowsError(
            try store.reserve(
                accountID: accountID,
                summary: "Toast and Oats",
                drafts: [adHoc, draft(.product(id: "food-1"))],
                request: request
            )
        ) { error in
            XCTAssertEqual(error as? LogSubmissionStoreError, .invalidRequest)
        }
    }

    func testDeletingMealInvalidatesWholeBatchButLeavesOtherItemAlone() throws {
        let persistence = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: persistence)
        let batch = try reserve(
            store,
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            key: "batch-key"
        )
        let other = try reserve(
            store,
            drafts: [draft(.product(id: "food-2"))],
            key: "other-key"
        )

        let invalidated = try store.blockBeforeDeleting(
            accountID: accountID,
            item: .meal(id: "meal-1"),
            date: date,
            reason: "deleted"
        )
        XCTAssertEqual(invalidated.map(\.id), [batch.id])
        XCTAssertTrue(store.isRetryBlocked(id: batch.id))
        XCTAssertEqual(
            store.entry(id: batch.id, accountID: accountID)?.state,
            .invalidated
        )
        XCTAssertNil(store.entry(id: batch.id, accountID: accountID)?.body)
        XCTAssertEqual(store.unresolved(
            accountID: accountID,
            item: .product(id: "food-1"),
            date: date
        ).count, 0)
        XCTAssertEqual(store.unresolved(
            accountID: accountID,
            item: .product(id: "food-2"),
            date: date
        ).map(\.id), [other.id])
    }

    func testAdHocBarrierMatchesNameAndBrandWithoutAnID() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let adHoc = try reserve(
            store,
            drafts: [.init(
                item: .adHoc(name: "Toast", brand: "Bakery"),
                date: date,
                mealSlot: .snack,
                amount: "2",
                unit: "slice",
                notes: nil,
                timeZone: "Europe/Paris",
                nutrients: []
            )],
            key: "ad-hoc-key"
        )
        let invalidated = try store.blockBeforeDeleting(
            accountID: accountID,
            item: .adHoc(name: "Toast", brand: "Bakery"),
            date: date,
            reason: "deleted"
        )
        XCTAssertEqual(invalidated.map(\.id), [adHoc.id])
        XCTAssertTrue(store.isRetryBlocked(id: adHoc.id))
    }

    func testBatchSuccessStoresLogsInOriginalOrderAndFirstCompatibilityResult() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let entry = try reserve(
            store,
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            key: "batch-key"
        )
        try store.markSucceeded(
            id: entry.id,
            accountID: accountID,
            logs: [
                LogSubmissionCreatedLog(
                    id: "log-2",
                    date: date,
                    mealSlot: .lunch,
                    item: .meal(id: "meal-1")
                ),
                LogSubmissionCreatedLog(
                    id: "log-1",
                    date: date,
                    mealSlot: .lunch,
                    item: .product(id: "food-1")
                ),
            ],
            replayed: true
        )
        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
        XCTAssertEqual(stored.state, .succeeded)
        XCTAssertEqual(stored.resultLogID, "log-2")
        XCTAssertEqual(stored.resultLogs?.map(\.id), ["log-2", "log-1"])
        XCTAssertTrue(stored.replayed)
        XCTAssertEqual(stored.lastStatus, 200)
        XCTAssertNil(stored.body)
    }

    func testItemNamesArePersistedForGenericRecovery() throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let entry = try reserve(
            store,
            drafts: [draft(.product(id: "food-1")), draft(.meal(id: "meal-1"))],
            key: "batch-key",
            names: ["Oats", "Rice bowl"]
        )
        let reloaded = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let stored = try XCTUnwrap(reloaded.entry(id: entry.id, accountID: accountID))
        XCTAssertEqual(stored.itemName(at: 0), "Oats")
        XCTAssertEqual(stored.itemName(at: 1), "Rice bowl")
        XCTAssertEqual(stored.itemName(at: 9), "Item 10")
    }

    // MARK: - Helpers

    private func draft(_ item: LogSubmissionItem) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: item,
            date: date,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Europe/Paris"
        )
    }

    @discardableResult
    private func reserve(
        _ store: LogSubmissionStore,
        drafts: [LogSubmissionDraft],
        key: String,
        names: [String]? = nil
    ) throws -> PendingLogSubmission {
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: drafts,
            baseURL: URL(string: "https://calco.example.com")!,
            idempotencyKey: key
        )
        return try store.reserve(
            accountID: accountID,
            summary: names?.first ?? "Summary",
            drafts: drafts,
            request: prepared.request,
            itemNames: names,
            capabilityVersion: 2
        )
    }
}
