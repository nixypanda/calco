import XCTest

@testable import CalCo

/// Independent account-recovery checks that are not covered by the owner's
/// existing 40 focused tests. All state is an isolated temporary directory.
@MainActor
final class APIKeyIntentRecoveryReviewTests: XCTestCase {
    private let accountID = "recovery-review-account"
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func intent() -> APIKeyCreateIntent {
        APIKeyCreateIntent(
            accountID: accountID,
            revision: "revision-1",
            name: "Review",
            scope: .read,
            expiresInDays: nil,
            startedAt: date,
            baselineKeyIDs: []
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-api-key-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func onlyFile(
        in directory: URL,
        withExtension pathExtension: String
    ) throws -> URL? {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == pathExtension }
    }

    func testMarkerWriteFailureThenCorruptDeletionStaysBlocked() throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let store = APIKeyCreateIntentStore(directoryURL: directory)
        try store.saveIfAbsent(intent())
        let corruptFile = try XCTUnwrap(try onlyFile(in: directory, withExtension: "json"))
        try Data("not json".utf8).write(to: corruptFile, options: [.atomic])

        // Make marker creation fail while leaving the corrupt record readable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        var identity: APIKeyCreateIntentFileIdentity?
        XCTAssertThrowsError(try store.load(accountID: accountID)) {
            guard case .unreadable(let observed) =
                    $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected .unreadable, got \($0)")
            }
            identity = observed
        }
        XCTAssertNotNil(identity)
        XCTAssertNil(
            try onlyFile(in: directory, withExtension: "quarantined"),
            "the permission setup must actually prevent marker creation"
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try FileManager.default.removeItem(at: corruptFile)

        let restarted = APIKeyCreateIntentStore(directoryURL: directory)
        XCTAssertThrowsError(
            try restarted.load(accountID: accountID),
            "a failed quarantine marker must not become a fresh grant if the corrupt file disappears"
        )
    }

    func testAccountChangeRevokesPendingResetGrant() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = APIKeyCreateIntentStore(directoryURL: directory)
        try store.saveIfAbsent(intent())
        let file = try XCTUnwrap(try onlyFile(in: directory, withExtension: "json"))
        try Data("{broken".utf8).write(to: file, options: [.atomic])

        let service = ReviewRecoveryAPIKeyService()
        let viewModel = AccountSettingsViewModel(
            service: service,
            accountID: accountID,
            clipboard: ReviewRecoveryClipboard(),
            nowProvider: { self.date },
            intentStore: store
        )
        await viewModel.load()
        XCTAssertTrue(viewModel.canResetUnreadableCreateIntent)
        viewModel.requestResetUnreadableCreateIntent()
        XCTAssertTrue(viewModel.isResetIntentConfirmationPresented)

        viewModel.accountDidChange(to: "another-account")

        XCTAssertNil(viewModel.createIntentRecoveryIdentity)
        XCTAssertFalse(viewModel.canResetUnreadableCreateIntent)
        XCTAssertFalse(viewModel.isResetIntentConfirmationPresented)
        viewModel.requestResetUnreadableCreateIntent()
        XCTAssertFalse(viewModel.isResetIntentConfirmationPresented)
        XCTAssertNotNil(
            try onlyFile(in: directory, withExtension: "json"),
            "changing accounts must not grant a reset of the old account's record"
        )
    }
}

private actor ReviewRecoveryAPIKeyService: APIKeyServicing {
    func listAPIKeys() async throws -> [APIKey] { [] }

    func createAPIKey(_ request: APIKeyCreateRequest) async throws -> CreatedAPIKey {
        throw APIKeyServiceError.unknown
    }

    func revokeAPIKey(id: String) async throws {
        throw APIKeyServiceError.unknown
    }
}

@MainActor
private final class ReviewRecoveryClipboard: APIKeySecretCopying {
    func copySecretToClipboard(_ secret: String) -> APIKeyClipboardReceipt? { nil }
    func clearSecretFromClipboard(_ receipt: APIKeyClipboardReceipt) {}
}
