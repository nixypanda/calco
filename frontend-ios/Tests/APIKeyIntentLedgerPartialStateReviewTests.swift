import XCTest

@testable import CalCo

/// Independent partial-state checks for the API-key intent ledger. Isolated
/// temporary directories only; no live keys or app-support data.
@MainActor
final class APIKeyIntentLedgerPartialStateReviewTests: XCTestCase {
    private let accountID = "ledger-partial-account"
    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> (store: APIKeyCreateIntentStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-ledger-partial-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (APIKeyCreateIntentStore(directoryURL: directory), directory)
    }

    private func intent(revision: String = "revision-1") -> APIKeyCreateIntent {
        APIKeyCreateIntent(
            accountID: accountID,
            revision: revision,
            name: "Partial",
            scope: .read,
            expiresInDays: nil,
            startedAt: startedAt,
            baselineKeyIDs: []
        )
    }

    private func intentFile(in directory: URL) throws -> URL {
        try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
    }

    private func ledgerFile(in directory: URL) throws -> URL {
        let ledger = directory.deletingLastPathComponent().appendingPathComponent(
            "\(directory.lastPathComponent)-ledger",
            isDirectory: true
        )
        return try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: ledger,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
    }

    func testLedgerLossWithValidIntentStillBlocksNewCreate() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.saveIfAbsent(intent())

        try FileManager.default.removeItem(at: try ledgerFile(in: directory))

        XCTAssertEqual(try store.load(accountID: accountID)?.revision, "revision-1")
        XCTAssertNotNil(try store.load(accountID: accountID))
    }

    func testIntentLossWithLedgerOnlyBlocksUntilExactReset() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.saveIfAbsent(intent())
        let source = try intentFile(in: directory)
        try FileManager.default.removeItem(at: source)

        let restarted = APIKeyCreateIntentStore(directoryURL: directory)
        var identity: APIKeyCreateIntentFileIdentity?
        XCTAssertThrowsError(try restarted.load(accountID: accountID)) {
            guard case .unreadable(let observed) =
                    $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected ledger-only block, got \($0)")
            }
            identity = observed
        }
        let captured = try XCTUnwrap(identity)
        try restarted.resetUnreadable(
            accountID: accountID,
            expectedIdentity: captured
        )
        XCTAssertNil(try restarted.load(accountID: accountID))
    }

    func testClearRejectsStaleLedgerRevisionWithoutErasingIntent() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.saveIfAbsent(intent())
        let ledger = try ledgerFile(in: directory)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: ledger))
                as? [String: Any]
        )
        object["revision"] = "newer-revision"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: ledger, options: [.atomic])

        XCTAssertThrowsError(
            try store.clear(accountID: accountID, revision: "revision-1")
        ) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .staleRevision)
        }
        XCTAssertEqual(try store.load(accountID: accountID)?.revision, "revision-1")
    }

    func testNormalClearRevisionRemovesIntentLedgerAndAnyMarker() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.saveIfAbsent(intent())

        try store.clear(accountID: accountID, revision: "revision-1")

        XCTAssertNil(try store.load(accountID: accountID))
        let sibling = directory.deletingLastPathComponent().appendingPathComponent(
            "\(directory.lastPathComponent)-ledger",
            isDirectory: true
        )
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: sibling,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMissingLedgerLegacyIntentLoadsAndClears() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.saveIfAbsent(intent())
        let revision = "revision-1"
        try FileManager.default.removeItem(at: try ledgerFile(in: directory))

        XCTAssertEqual(try store.load(accountID: accountID)?.revision, revision)
        try store.clear(accountID: accountID, revision: revision)
        XCTAssertNil(try store.load(accountID: accountID))
    }
}
