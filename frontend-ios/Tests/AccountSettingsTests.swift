import XCTest

@testable import CalCo

private actor FakeAPIKeyService: APIKeyServicing {
    private var storedKeys: [APIKey]
    private var listError: APIKeyServiceError?
    private var createError: APIKeyServiceError?
    private var revokeError: APIKeyServiceError?
    private var appendOnCreateError: APIKey?
    private var listCallStorage = 0
    private var createRequestStorage: [APIKeyCreateRequest] = []
    private var revokeIDStorage: [String] = []

    init(keys: [APIKey] = []) {
        self.storedKeys = keys
    }

    func setKeys(_ keys: [APIKey]) { storedKeys = keys }
    func setListError(_ error: APIKeyServiceError?) { listError = error }
    func setCreateError(_ error: APIKeyServiceError?) { createError = error }
    func setRevokeError(_ error: APIKeyServiceError?) { revokeError = error }
    func setAppendOnCreateError(_ key: APIKey?) { appendOnCreateError = key }
    func listCallCount() -> Int { listCallStorage }
    func createRequests() -> [APIKeyCreateRequest] { createRequestStorage }
    func revokeIDs() -> [String] { revokeIDStorage }

    func listAPIKeys() async throws -> [APIKey] {
        listCallStorage += 1
        if let listError { throw listError }
        return storedKeys
    }

    func createAPIKey(_ request: APIKeyCreateRequest) async throws -> CreatedAPIKey {
        createRequestStorage.append(request)
        if let createError {
            if let appendOnCreateError {
                storedKeys.insert(appendOnCreateError, at: 0)
            }
            throw createError
        }

        let key = APIKey(
            id: "key-\(createRequestStorage.count)",
            name: request.name,
            tokenHint: "calco_pat_fixture",
            scope: request.scope == .read ? .read : .readWrite,
            createdAt: "2026-11-19T10:00:00Z",
            lastUsedAt: nil,
            expiresAt: request.expiresInDays.map { _ in "2027-02-17T10:00:00Z" }
        )
        storedKeys.insert(key, at: 0)
        return CreatedAPIKey(
            key: key,
            secret: APIKeySecret(
                value: "calco_pat_fixture_secret_\(createRequestStorage.count)"
            )
        )
    }

    func revokeAPIKey(id: String) async throws {
        revokeIDStorage.append(id)
        if let revokeError { throw revokeError }
        storedKeys.removeAll { $0.id == id }
    }
}

private actor HoldingCreateService: APIKeyServicing {
    private var storedKeys: [APIKey]
    private var createCallStorage = 0
    private var createStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(keys: [APIKey] = []) {
        self.storedKeys = keys
    }

    func setKeys(_ keys: [APIKey]) { storedKeys = keys }

    func listAPIKeys() async throws -> [APIKey] { storedKeys }

    func createAPIKey(_ request: APIKeyCreateRequest) async throws -> CreatedAPIKey {
        createCallStorage += 1
        createStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        let key = APIKey(
            id: "key-held-\(createCallStorage)",
            name: request.name,
            tokenHint: "calco_pat_fixture",
            scope: request.scope == .read ? .read : .readWrite,
            createdAt: "2026-11-19T10:00:00Z",
            expiresAt: nil
        )
        storedKeys.insert(key, at: 0)
        return CreatedAPIKey(
            key: key,
            secret: APIKeySecret(value: "calco_pat_fixture_held_secret")
        )
    }

    func revokeAPIKey(id: String) async throws {
        storedKeys.removeAll { $0.id == id }
    }

    func createCallCount() -> Int { createCallStorage }
    func keysSnapshot() -> [APIKey] { storedKeys }

    func waitForCreateStart() async {
        let deadline = Date().addingTimeInterval(5)
        while !createStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(createStarted, "Timed out waiting for create to start")
    }

    func releaseCreate() {
        continuation?.resume()
        continuation = nil
    }
}

private actor StaleListService: APIKeyServicing {
    private var listCallStorage = 0
    private var firstStarted = false
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private let oldKey: APIKey
    private let newKey: APIKey

    init(oldKey: APIKey, newKey: APIKey) {
        self.oldKey = oldKey
        self.newKey = newKey
    }

    func listAPIKeys() async throws -> [APIKey] {
        listCallStorage += 1
        if listCallStorage == 1 {
            firstStarted = true
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
            return [oldKey]
        }
        return [newKey]
    }

    func createAPIKey(_ request: APIKeyCreateRequest) async throws -> CreatedAPIKey {
        throw APIKeyServiceError.unknown
    }

    func revokeAPIKey(id: String) async throws {
        throw APIKeyServiceError.unknown
    }

    func waitForFirstList() async {
        let deadline = Date().addingTimeInterval(5)
        while !firstStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(firstStarted, "Timed out waiting for the first list")
    }

    func releaseFirstList() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@MainActor
private final class FakeAPIKeyClipboard: APIKeySecretCopying {
    var copiedSecrets: [String] = []
    var succeeds = true
    private(set) var clearAttempts = 0
    private(set) var clearedCount = 0
    private(set) var ignoredClearCount = 0
    private var currentChangeCount = 0
    private var ownedSecret: String?

    func copySecretToClipboard(_ secret: String) -> APIKeyClipboardReceipt? {
        copiedSecrets.append(secret)
        guard succeeds else { return nil }
        ownedSecret = secret
        currentChangeCount += 1
        return APIKeyClipboardReceipt(changeCount: currentChangeCount)
    }

    func clearSecretFromClipboard(_ receipt: APIKeyClipboardReceipt) {
        clearAttempts += 1
        guard receipt.changeCount == currentChangeCount else {
            ignoredClearCount += 1
            return
        }
        ownedSecret = nil
        clearedCount += 1
        currentChangeCount += 1
    }

    func simulateExternalClipboardChange() {
        ownedSecret = nil
        currentChangeCount += 1
    }

    var hasOwnedSecret: Bool { ownedSecret != nil }
}

private final class InMemoryAPIKeyCreateIntentStore:
    APIKeyCreateIntentStoring, @unchecked Sendable
{
    private let lock = NSLock()
    private var intents: [String: APIKeyCreateIntent] = [:]

    func load(accountID: String) throws -> APIKeyCreateIntent? {
        lock.withLock { intents[accountID] }
    }

    func saveIfAbsent(_ intent: APIKeyCreateIntent) throws {
        try lock.withLock {
            if intents[intent.accountID] != nil {
                throw APIKeyCreateIntentStoreError.alreadyPending
            }
            intents[intent.accountID] = intent
        }
    }

    func clear(accountID: String, revision: String) throws {
        try lock.withLock {
            guard let current = intents[accountID] else { return }
            guard current.revision == revision else {
                throw APIKeyCreateIntentStoreError.staleRevision
            }
            _ = intents.removeValue(forKey: accountID)
        }
    }

    func resetUnreadable(
        accountID: String,
        expectedIdentity: APIKeyCreateIntentFileIdentity
    ) throws {
        // The in-memory fake only stores valid intents; resetting one would
        // model exactly the stale-window hazard this test double must reject.
        if intents[accountID] != nil {
            throw APIKeyCreateIntentStoreError.staleReset
        }
    }
}

private final class UnreadableAPIKeyCreateIntentStore:
    APIKeyCreateIntentStoring, @unchecked Sendable
{
    func load(accountID: String) throws -> APIKeyCreateIntent? {
        throw APIKeyCreateIntentStoreError.unreadable(
            APIKeyCreateIntentFileIdentity(
                accountID: accountID,
                digest: "fixture-unreadable"
            )
        )
    }

    func saveIfAbsent(_ intent: APIKeyCreateIntent) throws {
        throw APIKeyCreateIntentStoreError.persistence
    }

    func clear(accountID: String, revision: String) throws {
        throw APIKeyCreateIntentStoreError.persistence
    }

    func resetUnreadable(
        accountID: String,
        expectedIdentity: APIKeyCreateIntentFileIdentity
    ) throws {
        throw APIKeyCreateIntentStoreError.persistence
    }
}

private final class SaveFailingAPIKeyCreateIntentStore:
    APIKeyCreateIntentStoring, @unchecked Sendable
{
    func load(accountID: String) throws -> APIKeyCreateIntent? { nil }

    func saveIfAbsent(_ intent: APIKeyCreateIntent) throws {
        throw APIKeyCreateIntentStoreError.persistence
    }

    func clear(accountID: String, revision: String) throws {
        throw APIKeyCreateIntentStoreError.persistence
    }

    func resetUnreadable(
        accountID: String,
        expectedIdentity: APIKeyCreateIntentFileIdentity
    ) throws {
        throw APIKeyCreateIntentStoreError.persistence
    }
}

@MainActor
final class AccountSettingsTests: XCTestCase {
    private let nowDate = APIKeyTimestamp.date(from: "2026-11-19T12:00:00Z")!

    private func key(
        id: String,
        name: String = "Backup",
        scope: APIKeyScope = .read,
        createdAt: String = "2026-11-19T10:00:00Z",
        lastUsedAt: String? = nil,
        expiresAt: String? = nil
    ) -> APIKey {
        APIKey(
            id: id,
            name: name,
            tokenHint: "calco_pat_\(id)",
            scope: scope,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            expiresAt: expiresAt
        )
    }

    private func makeViewModel(
        service: any APIKeyServicing,
        clipboard: FakeAPIKeyClipboard? = nil,
        intentStore: (any APIKeyCreateIntentStoring)? = nil,
        accountID: String = "account-a"
    ) -> AccountSettingsViewModel {
        AccountSettingsViewModel(
            service: service,
            accountID: accountID,
            clipboard: clipboard ?? FakeAPIKeyClipboard(),
            nowProvider: { [nowDate] in nowDate },
            intentStore: intentStore ?? InMemoryAPIKeyCreateIntentStore()
        )
    }

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-api-key-intent-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func intentFile(in directory: URL) throws -> URL {
        try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
    }

    private func ledgerDirectory(for intentDirectory: URL) -> URL {
        intentDirectory.deletingLastPathComponent().appendingPathComponent(
            "\(intentDirectory.lastPathComponent)-ledger",
            isDirectory: true
        )
    }

    // MARK: - Load

    func testLoadListsKeysAndRetriesAfterFailure() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        await service.setListError(.networkUnavailable)
        let viewModel = makeViewModel(service: service)

        await viewModel.load()

        XCTAssertNotNil(viewModel.listErrorMessage)
        XCTAssertTrue(viewModel.keys.isEmpty)

        await service.setListError(nil)
        await viewModel.load()

        XCTAssertEqual(viewModel.listState, .loaded)
        XCTAssertEqual(viewModel.keys.map(\.id), ["key-1"])
        XCTAssertNil(viewModel.listErrorMessage)
        let listCalls = await service.listCallCount()
        XCTAssertEqual(listCalls, 2)
    }

    func testUnauthorizedLoadClearsStateAndReportsSessionOnce() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        await service.setListError(.unauthorized)
        let viewModel = makeViewModel(service: service)
        var expiredCount = 0
        viewModel.onSessionExpired = { expiredCount += 1 }

        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(expiredCount, 1)
        XCTAssertTrue(viewModel.isSessionExpired)
        XCTAssertTrue(viewModel.keys.isEmpty)
        XCTAssertEqual(
            viewModel.listErrorMessage,
            String(localized: "diary.error.sessionExpired")
        )
    }

    func testStaleListResponseCannotOverwriteNewerMetadata() async {
        let old = key(id: "old", name: "Old")
        let new = key(id: "new", name: "New")
        let service = StaleListService(oldKey: old, newKey: new)
        let viewModel = makeViewModel(service: service)

        let firstLoad = Task { await viewModel.load() }
        await service.waitForFirstList()
        await viewModel.load()
        await service.releaseFirstList()
        await firstLoad.value

        XCTAssertEqual(viewModel.keys.map(\.id), ["new"])
    }

    // MARK: - Create and one-time reveal

    func testCreateTrimsNameRevealsOnceAndDoesNotAutoCopy() async {
        let service = FakeAPIKeyService()
        let clipboard = FakeAPIKeyClipboard()
        let viewModel = makeViewModel(service: service, clipboard: clipboard)

        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "  Nightly backup  "
        viewModel.draftScope = .readWrite
        viewModel.draftExpiry = .days30

        await viewModel.submitCreate()

        XCTAssertEqual(viewModel.createState, .created)
        XCTAssertEqual(viewModel.createdKey?.key.name, "Nightly backup")
        XCTAssertEqual(viewModel.createdKey?.key.scope, .readWrite)
        XCTAssertEqual(viewModel.keys.first?.id, "key-1")
        XCTAssertFalse(viewModel.isSecretObscured)
        XCTAssertTrue(clipboard.copiedSecrets.isEmpty)

        let requests = await service.createRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.name, "Nightly backup")
        XCTAssertEqual(requests.first?.scope, .readWrite)
        XCTAssertEqual(requests.first?.expiresInDays, 30)

        viewModel.copySecret()
        XCTAssertEqual(
            clipboard.copiedSecrets,
            ["calco_pat_fixture_secret_1"]
        )
        XCTAssertEqual(viewModel.copyState, .copied)

        viewModel.finishSecretReveal()

        XCTAssertNil(viewModel.createdKey)
        XCTAssertFalse(viewModel.isCreatePresented)
        XCTAssertEqual(viewModel.createState, .editing)
    }

    func testInvalidNameBlocksRequestUntilCorrected() async {
        let service = FakeAPIKeyService()
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = " \u{00A0}\n "

        await viewModel.submitCreate()

        XCTAssertEqual(viewModel.nameValidationMessage, String(localized: "apiKeys.create.name.required"))
        var requests = await service.createRequests()
        XCTAssertEqual(requests.count, 0)

        viewModel.draftName = "Name\u{202E}"
        await viewModel.submitCreate()

        XCTAssertEqual(
            viewModel.nameValidationMessage,
            String(localized: "apiKeys.create.name.invalid")
        )
        requests = await service.createRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testAmbiguousCreateRefreshesMetadataAndNeverBlindlyRetries() async {
        let existing = key(id: "key-1")
        let orphan = key(id: "key-orphan", name: "May have been created")
        let service = FakeAPIKeyService(keys: [existing])
        await service.setCreateError(.timedOut)
        await service.setAppendOnCreateError(orphan)
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Lost response"
        await viewModel.submitCreate()

        let createCallsAfterFailure = await service.createRequests()
        let listCallsAfterFailure = await service.listCallCount()
        XCTAssertEqual(createCallsAfterFailure.count, 1)
        XCTAssertEqual(listCallsAfterFailure, 2)
        XCTAssertEqual(viewModel.keys.map(\.id), ["key-orphan", "key-1"])
        guard case .uncertain = viewModel.createState else {
            return XCTFail("Expected an uncertain create state")
        }
        XCTAssertNotNil(viewModel.pendingCreateIntent)
        XCTAssertTrue(viewModel.isCreateSubmitDisabled)

        await viewModel.submitCreate()
        let createCallsAfterSecondSubmit = await service.createRequests()
        XCTAssertEqual(createCallsAfterSecondSubmit.count, 1)

        await viewModel.refreshMetadataForUncertainCreate()
        let listCallsAfterRefresh = await service.listCallCount()
        let createCallsAfterRefresh = await service.createRequests()
        XCTAssertEqual(listCallsAfterRefresh, 3)
        XCTAssertEqual(createCallsAfterRefresh.count, 1)
        guard case .uncertain = viewModel.createState else {
            return XCTFail("Metadata refresh must not unblock a blind retry")
        }
    }

    func testUncertainCreateReportsMetadataRefreshFailureAndStillDoesNotRetry() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        await service.setCreateError(.networkUnavailable)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        await service.setListError(.networkUnavailable)
        viewModel.presentCreateForm()
        viewModel.draftName = "Lost response"

        await viewModel.submitCreate()

        guard case .uncertain = viewModel.createState else {
            return XCTFail("Expected an uncertain create state")
        }
        XCTAssertTrue(viewModel.uncertainMetadataRefreshFailed)
        let createCalls = await service.createRequests()
        XCTAssertEqual(createCalls.count, 1)
        XCTAssertTrue(viewModel.isCreateSubmitDisabled)
    }

    func testCreateIntentPersistsBeforePostWithoutSecretOrBody() async throws {
        let directory = makeTempDirectory()
        let store = APIKeyCreateIntentStore(directoryURL: directory)
        let baseline = key(id: "key-existing", name: "Existing")
        let service = HoldingCreateService(keys: [baseline])
        let viewModel = makeViewModel(service: service, intentStore: store)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Nightly backup"
        viewModel.draftScope = .readWrite
        viewModel.draftExpiry = .days30

        let create = Task { await viewModel.submitCreate() }
        await service.waitForCreateStart()

        let intent = try XCTUnwrap(try store.load(accountID: "account-a"))
        XCTAssertEqual(intent.name, "Nightly backup")
        XCTAssertEqual(intent.scope, .readWrite)
        XCTAssertEqual(intent.expiresInDays, 30)
        XCTAssertEqual(intent.startedAt, nowDate)
        XCTAssertEqual(intent.baselineKeyIDs, ["key-existing"])

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let persistedText = try files.compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertFalse(persistedText.contains("calco_pat_"))
        XCTAssertFalse(persistedText.contains("token"))
        XCTAssertFalse(persistedText.contains("secret"))
        XCTAssertFalse(persistedText.contains("request"))

        await service.releaseCreate()
        await create.value
        XCTAssertNil(try store.load(accountID: "account-a"))
        XCTAssertNotNil(viewModel.createdKey)
    }

    func testIntentSaveFailureBlocksPost() async {
        let service = FakeAPIKeyService()
        let viewModel = makeViewModel(
            service: service,
            intentStore: SaveFailingAPIKeyCreateIntentStore()
        )
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Blocked key"

        await viewModel.submitCreate()

        let requests = await service.createRequests()
        XCTAssertEqual(requests.count, 0)
        XCTAssertNil(viewModel.createdKey)
        XCTAssertNotNil(viewModel.createErrorMessage)
    }

    func testUnreadableIntentStoreFailsClosedAndBlocksCreate() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        let viewModel = makeViewModel(
            service: service,
            intentStore: UnreadableAPIKeyCreateIntentStore()
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.hasUnresolvedCreateIntent)
        XCTAssertNotNil(viewModel.createIntentErrorMessage)
        viewModel.presentCreateForm()
        XCTAssertFalse(viewModel.isCreatePresented)
        let requests = await service.createRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testPersistedIntentSurvivesRestartAndFutureMetadataRevealsOrphan() async {
        let store = InMemoryAPIKeyCreateIntentStore()
        let baseline = key(id: "key-baseline")
        let service = FakeAPIKeyService(keys: [baseline])
        await service.setCreateError(.timedOut)
        let first = makeViewModel(service: service, intentStore: store)
        await first.load()
        first.presentCreateForm()
        first.draftName = "Interrupted"
        await first.submitCreate()
        XCTAssertNotNil(first.pendingCreateIntent)

        let restarted = makeViewModel(service: service, intentStore: store)
        await restarted.load()
        XCTAssertNotNil(restarted.pendingCreateIntent)
        XCTAssertTrue(restarted.potentialOrphanKeys.isEmpty)
        XCTAssertTrue(restarted.isCreateSubmitDisabled)
        var createCount = await service.createRequests().count
        XCTAssertEqual(createCount, 1)

        await service.setKeys([key(id: "key-orphan", name: "Orphan"), baseline])
        await restarted.load()

        XCTAssertEqual(restarted.potentialOrphanKeys.map(\.id), ["key-orphan"])
        createCount = await service.createRequests().count
        XCTAssertEqual(createCount, 1)
        await restarted.submitCreate()
        createCount = await service.createRequests().count
        XCTAssertEqual(createCount, 1)
    }

    func testHeldPostAccountSwitchKeepsOldAccountWarningAndDropsSecret() async {
        let store = InMemoryAPIKeyCreateIntentStore()
        let service = HoldingCreateService()
        let accountA = makeViewModel(service: service, intentStore: store)
        await accountA.load()
        accountA.presentCreateForm()
        accountA.draftName = "Held create"

        let create = Task { await accountA.submitCreate() }
        await service.waitForCreateStart()
        accountA.accountDidChange(to: "account-b")
        await service.releaseCreate()
        await create.value

        XCTAssertNil(accountA.createdKey)
        XCTAssertFalse(accountA.isCreatePresented)
        XCTAssertTrue(accountA.keys.isEmpty)

        let restartedA = makeViewModel(
            service: service,
            intentStore: store,
            accountID: "account-a"
        )
        await restartedA.load()

        XCTAssertNotNil(restartedA.pendingCreateIntent)
        XCTAssertEqual(restartedA.potentialOrphanKeys.map(\.id), ["key-held-1"])
        let createCount = await service.createCallCount()
        XCTAssertEqual(createCount, 1)
        await restartedA.submitCreate()
        let countAfterSubmit = await service.createCallCount()
        XCTAssertEqual(countAfterSubmit, 1)
    }

    func testCreateIntentStoreRejectsConcurrentBeginAndStaleClear() throws {
        let directory = makeTempDirectory()
        let firstStore = APIKeyCreateIntentStore(directoryURL: directory)
        let secondStore = APIKeyCreateIntentStore(directoryURL: directory)
        let date = nowDate
        let firstIntent = APIKeyCreateIntent(
            accountID: "account-a",
            revision: "revision-1",
            name: "First",
            scope: .read,
            expiresInDays: nil,
            startedAt: date,
            baselineKeyIDs: []
        )
        let secondIntent = APIKeyCreateIntent(
            accountID: "account-a",
            revision: "revision-2",
            name: "Second",
            scope: .readWrite,
            expiresInDays: 30,
            startedAt: date,
            baselineKeyIDs: []
        )

        try firstStore.saveIfAbsent(firstIntent)
        XCTAssertNil(try firstStore.load(accountID: "account-b"))
        XCTAssertThrowsError(try secondStore.saveIfAbsent(secondIntent)) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .alreadyPending)
        }
        XCTAssertEqual(try firstStore.load(accountID: "account-a")?.name, "First")
        XCTAssertThrowsError(
            try secondStore.clear(accountID: "account-a", revision: "stale")
        ) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .staleRevision)
        }

        try firstStore.clear(accountID: "account-a", revision: "revision-1")
        try secondStore.saveIfAbsent(secondIntent)
        XCTAssertThrowsError(
            try firstStore.clear(accountID: "account-a", revision: "revision-1")
        ) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .staleRevision)
        }
        XCTAssertEqual(try firstStore.load(accountID: "account-a")?.revision, "revision-2")

        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        try Data("not json".utf8).write(to: file, options: [.atomic])
        XCTAssertThrowsError(try firstStore.load(accountID: "account-a")) {
            guard case .unreadable(let identity) = $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected .unreadable, got \($0)")
            }
            XCTAssertEqual(identity.accountID, "account-a")
        }
    }

    func testCorruptIntentQuarantineSurvivesNewStoreAndStaleResetRejected() throws {
        let directory = makeTempDirectory()
        let firstStore = APIKeyCreateIntentStore(directoryURL: directory)
        let firstIntent = APIKeyCreateIntent(
            accountID: "account-a",
            revision: "revision-1",
            name: "Corrupt me",
            scope: .read,
            expiresInDays: nil,
            startedAt: nowDate,
            baselineKeyIDs: []
        )
        try firstStore.saveIfAbsent(firstIntent)
        let corruptFile = try intentFile(in: directory)
        try Data("not json".utf8).write(to: corruptFile, options: [.atomic])

        var capturedIdentity: APIKeyCreateIntentFileIdentity?
        XCTAssertThrowsError(try firstStore.load(accountID: "account-a")) {
            guard case .unreadable(let identity) = $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected .unreadable, got \($0)")
            }
            capturedIdentity = identity
        }
        let identity = try XCTUnwrap(capturedIdentity)
        let filesAfterQuarantine = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            filesAfterQuarantine.contains { $0.pathExtension == "quarantined" },
            "Corruption must install a durable quarantine marker"
        )

        // Even if another process removes the corrupt file, a new store must
        // not silently treat the account as having no unresolved create.
        try FileManager.default.removeItem(at: corruptFile)
        let newStore = APIKeyCreateIntentStore(directoryURL: directory)
        XCTAssertThrowsError(try newStore.load(accountID: "account-a")) {
            guard case .unreadable(let markerIdentity) =
                $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected durable quarantine, got \($0)")
            }
            XCTAssertEqual(markerIdentity, identity)
        }

        XCTAssertThrowsError(
            try newStore.resetUnreadable(
                accountID: "account-a",
                expectedIdentity: APIKeyCreateIntentFileIdentity(
                    accountID: "account-a",
                    digest: "wrong"
                )
            )
        ) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .staleReset)
        }
        try newStore.resetUnreadable(
            accountID: "account-a",
            expectedIdentity: identity
        )
        XCTAssertNil(try newStore.load(accountID: "account-a"))

        let replacement = APIKeyCreateIntent(
            accountID: "account-a",
            revision: "revision-2",
            name: "New valid intent",
            scope: .readWrite,
            expiresInDays: 30,
            startedAt: nowDate,
            baselineKeyIDs: []
        )
        try newStore.saveIfAbsent(replacement)
        XCTAssertThrowsError(
            try firstStore.resetUnreadable(
                accountID: "account-a",
                expectedIdentity: identity
            )
        ) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .staleReset)
        }
        XCTAssertEqual(
            try newStore.load(accountID: "account-a")?.revision,
            "revision-2",
            "A stale window must not erase a newer valid intent"
        )
    }

    func testFallbackLedgerResetCoversMarkerWriteFailureAndRejectsStaleWindow() throws {
        let directory = makeTempDirectory()
        let ledger = ledgerDirectory(for: directory)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: ledger)
        }
        let store = APIKeyCreateIntentStore(directoryURL: directory)
        try store.saveIfAbsent(
            APIKeyCreateIntent(
                accountID: "account-a",
                revision: "revision-1",
                name: "Fallback",
                scope: .read,
                expiresInDays: nil,
                startedAt: nowDate,
                baselineKeyIDs: []
            )
        )
        let corruptFile = try intentFile(in: directory)
        try Data("not json".utf8).write(to: corruptFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        var capturedIdentity: APIKeyCreateIntentFileIdentity?
        XCTAssertThrowsError(try store.load(accountID: "account-a")) {
            guard case .unreadable(let identity) = $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected .unreadable, got \($0)")
            }
            capturedIdentity = identity
        }
        let identity = try XCTUnwrap(capturedIdentity)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try FileManager.default.removeItem(at: corruptFile)

        let restarted = APIKeyCreateIntentStore(directoryURL: directory)
        XCTAssertThrowsError(try restarted.load(accountID: "account-a")) {
            guard case .unreadable = $0 as? APIKeyCreateIntentStoreError else {
                return XCTFail("Expected ledger fallback block, got \($0)")
            }
        }

        try restarted.resetUnreadable(
            accountID: "account-a",
            expectedIdentity: identity
        )
        XCTAssertNil(try restarted.load(accountID: "account-a"))

        let replacement = APIKeyCreateIntent(
            accountID: "account-a",
            revision: "revision-2",
            name: "Replacement",
            scope: .readWrite,
            expiresInDays: 30,
            startedAt: nowDate,
            baselineKeyIDs: []
        )
        try restarted.saveIfAbsent(replacement)
        XCTAssertThrowsError(
            try store.resetUnreadable(
                accountID: "account-a",
                expectedIdentity: identity
            )
        ) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .staleReset)
        }
        XCTAssertEqual(
            try restarted.load(accountID: "account-a")?.revision,
            "revision-2"
        )
    }

    func testCorruptFallbackLedgerFailsClosed() throws {
        let directory = makeTempDirectory()
        let ledger = ledgerDirectory(for: directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: ledger)
        }
        let store = APIKeyCreateIntentStore(directoryURL: directory)
        try store.saveIfAbsent(
            APIKeyCreateIntent(
                accountID: "account-a",
                revision: "revision-1",
                name: "Ledger",
                scope: .read,
                expiresInDays: nil,
                startedAt: nowDate,
                baselineKeyIDs: []
            )
        )
        let ledgerFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: ledger,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        try Data("broken ledger".utf8).write(to: ledgerFile, options: [.atomic])

        XCTAssertThrowsError(try store.load(accountID: "account-a")) {
            XCTAssertEqual($0 as? APIKeyCreateIntentStoreError, .unavailable)
        }
    }

    func testUnreadableIntentResetNeedsRefreshedMetadataConfirmationAndAllowsNewCreate() async throws {
        let directory = makeTempDirectory()
        let store = APIKeyCreateIntentStore(directoryURL: directory)
        try store.saveIfAbsent(
            APIKeyCreateIntent(
                accountID: "account-a",
                revision: "revision-1",
                name: "Unreadable",
                scope: .read,
                expiresInDays: nil,
                startedAt: nowDate,
                baselineKeyIDs: []
            )
        )
        let file = try intentFile(in: directory)
        try Data("{broken".utf8).write(to: file, options: [.atomic])

        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        let viewModel = makeViewModel(service: service, intentStore: store)
        await viewModel.load()

        XCTAssertTrue(viewModel.hasUnresolvedCreateIntent)
        XCTAssertNotNil(viewModel.createIntentRecoveryIdentity)
        XCTAssertTrue(viewModel.canResetUnreadableCreateIntent)
        viewModel.presentCreateForm()
        XCTAssertFalse(viewModel.isCreatePresented)

        viewModel.requestResetUnreadableCreateIntent()
        XCTAssertTrue(viewModel.isResetIntentConfirmationPresented)
        viewModel.cancelResetUnreadableCreateIntent()
        XCTAssertFalse(viewModel.isResetIntentConfirmationPresented)
        XCTAssertTrue(viewModel.hasUnresolvedCreateIntent)
        XCTAssertTrue(viewModel.canResetUnreadableCreateIntent)
        viewModel.presentCreateForm()
        XCTAssertFalse(viewModel.isCreatePresented)

        await viewModel.refreshInterruptedCreateMetadata()
        XCTAssertTrue(viewModel.canResetUnreadableCreateIntent)
        viewModel.requestResetUnreadableCreateIntent()
        await viewModel.confirmResetUnreadableCreateIntent()

        XCTAssertFalse(viewModel.hasUnresolvedCreateIntent)
        XCTAssertNil(viewModel.createIntentRecoveryIdentity)
        XCTAssertNil(try store.load(accountID: "account-a"))

        viewModel.presentCreateForm()
        XCTAssertTrue(viewModel.isCreatePresented)
        viewModel.draftName = "After reset"
        await viewModel.submitCreate()

        XCTAssertEqual(viewModel.createState, .created)
        XCTAssertNil(try store.load(accountID: "account-a"))
    }

    func testRevokingLastPossibleOrphanClearsInterruptedCreateWarning() async throws {
        let store = InMemoryAPIKeyCreateIntentStore()
        try store.saveIfAbsent(
            APIKeyCreateIntent(
                accountID: "account-a",
                revision: "revision-1",
                name: "Interrupted",
                scope: .read,
                expiresInDays: nil,
                startedAt: nowDate,
                baselineKeyIDs: []
            )
        )
        let orphan = key(id: "key-orphan")
        let service = FakeAPIKeyService(keys: [orphan])
        let viewModel = makeViewModel(service: service, intentStore: store)
        await viewModel.load()
        XCTAssertEqual(viewModel.potentialOrphanKeys.map(\.id), ["key-orphan"])

        viewModel.requestRevoke(orphan)
        await viewModel.confirmRevoke()

        XCTAssertNil(viewModel.pendingCreateIntent)
        XCTAssertTrue(viewModel.potentialOrphanKeys.isEmpty)
        XCTAssertNil(try store.load(accountID: "account-a"))
    }

    func testClipboardCleanupClearsOnlyOwnedSecret() async {
        let service = FakeAPIKeyService()
        let clipboard = FakeAPIKeyClipboard()
        let viewModel = makeViewModel(service: service, clipboard: clipboard)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Clipboard key"
        await viewModel.submitCreate()
        viewModel.copySecret()
        XCTAssertTrue(clipboard.hasOwnedSecret)

        viewModel.finishSecretReveal()
        XCTAssertEqual(clipboard.clearedCount, 1)
        XCTAssertEqual(clipboard.clearAttempts, 1)
        XCTAssertFalse(clipboard.hasOwnedSecret)

        let externalClipboard = FakeAPIKeyClipboard()
        let secondService = FakeAPIKeyService()
        let second = makeViewModel(service: secondService, clipboard: externalClipboard)
        await second.load()
        second.presentCreateForm()
        second.draftName = "External copy"
        await second.submitCreate()
        second.copySecret()
        XCTAssertTrue(externalClipboard.hasOwnedSecret)
        externalClipboard.simulateExternalClipboardChange()

        second.clearForSignOut()
        XCTAssertEqual(externalClipboard.clearAttempts, 1)
        XCTAssertEqual(externalClipboard.ignoredClearCount, 1)
        XCTAssertEqual(externalClipboard.clearedCount, 0)

        let accountClipboard = FakeAPIKeyClipboard()
        let accountService = FakeAPIKeyService()
        let accountVM = makeViewModel(service: accountService, clipboard: accountClipboard)
        await accountVM.load()
        accountVM.presentCreateForm()
        accountVM.draftName = "Account change"
        await accountVM.submitCreate()
        accountVM.copySecret()
        XCTAssertTrue(accountClipboard.hasOwnedSecret)
        accountVM.accountDidChange(to: "account-b")
        XCTAssertEqual(accountClipboard.clearedCount, 1)
        XCTAssertFalse(accountClipboard.hasOwnedSecret)
    }

    func testAmbiguousIntentRemainsUntilExplicitAcknowledge() async {
        let store = InMemoryAPIKeyCreateIntentStore()
        let service = FakeAPIKeyService()
        await service.setCreateError(.timedOut)
        let viewModel = makeViewModel(service: service, intentStore: store)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Ambiguous"
        await viewModel.submitCreate()
        XCTAssertNotNil(try store.load(accountID: "account-a"))

        viewModel.cancelCreateForm()
        await viewModel.refreshInterruptedCreateMetadata()
        await viewModel.acknowledgeInterruptedCreate()

        XCTAssertNil(try store.load(accountID: "account-a"))
        XCTAssertNil(viewModel.pendingCreateIntent)
        XCTAssertTrue(viewModel.potentialOrphanKeys.isEmpty)
    }

    func testDefinitiveCreateFailureAllowsExplicitRetry() async {
        let service = FakeAPIKeyService()
        await service.setCreateError(.limitReached)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Script"

        await viewModel.submitCreate()
        XCTAssertEqual(viewModel.createErrorMessage, String(localized: "apiKeys.limit.message"))
        XCTAssertNil(viewModel.pendingCreateIntent)
        let firstCallCount = await service.createRequests().count
        XCTAssertEqual(firstCallCount, 1)

        await service.setCreateError(nil)
        viewModel.draftName = "Script retry"
        await viewModel.submitCreate()

        let retryCallCount = await service.createRequests().count
        XCTAssertEqual(retryCallCount, 2)
        XCTAssertEqual(viewModel.createState, .created)
    }

    func testDoubleTapSendsOneCreateRequest() async {
        let service = HoldingCreateService()
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Double tap"

        let first = Task { await viewModel.submitCreate() }
        await service.waitForCreateStart()
        await viewModel.submitCreate()
        let callsDuringFlight = await service.createCallCount()
        XCTAssertEqual(callsDuringFlight, 1)

        await service.releaseCreate()
        await first.value
        let callsAfterRelease = await service.createCallCount()
        XCTAssertEqual(callsAfterRelease, 1)
        XCTAssertEqual(viewModel.createState, .created)
    }

    // MARK: - Secret lifetime and clipboard

    func testInactiveSceneObscuresSecretAndCopyRequiresDeliberateAction() async {
        let service = FakeAPIKeyService()
        let clipboard = FakeAPIKeyClipboard()
        let viewModel = makeViewModel(service: service, clipboard: clipboard)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Secret key"
        await viewModel.submitCreate()

        XCTAssertTrue(viewModel.isSecretRevealed)

        viewModel.scenePhaseChanged(isActive: false)

        XCTAssertTrue(viewModel.isSecretObscured)
        XCTAssertFalse(viewModel.canCopySecret)
        viewModel.copySecret()
        XCTAssertTrue(clipboard.copiedSecrets.isEmpty)
        XCTAssertEqual(viewModel.copyState, .idle)

        viewModel.scenePhaseChanged(isActive: true)
        viewModel.revealSecret()
        viewModel.copySecret()
        XCTAssertEqual(clipboard.copiedSecrets.count, 1)
        XCTAssertEqual(viewModel.copyState, .copied)

        viewModel.hideSecret()
        XCTAssertTrue(viewModel.isSecretObscured)
    }

    func testCreateCompletingWhileInactiveStartsObscuredAndRequiresReveal() async {
        let service = FakeAPIKeyService()
        let clipboard = FakeAPIKeyClipboard()
        let viewModel = makeViewModel(service: service, clipboard: clipboard)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Background key"
        viewModel.scenePhaseChanged(isActive: false)

        await viewModel.submitCreate()

        XCTAssertEqual(viewModel.createState, .created)
        XCTAssertTrue(viewModel.isSecretObscured)
        XCTAssertFalse(viewModel.canCopySecret)

        viewModel.revealSecret()
        XCTAssertTrue(viewModel.isSecretObscured, "Reveal requires an active app")

        viewModel.scenePhaseChanged(isActive: true)
        viewModel.revealSecret()
        XCTAssertFalse(viewModel.isSecretObscured)
        viewModel.copySecret()
        XCTAssertEqual(clipboard.copiedSecrets.count, 1)
    }

    func testAccountChangeDuringCreateIgnoresLateSecret() async {
        let service = HoldingCreateService()
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Late secret"

        let create = Task { await viewModel.submitCreate() }
        await service.waitForCreateStart()
        viewModel.clearForSignOut()
        await service.releaseCreate()
        await create.value

        XCTAssertNil(viewModel.createdKey)
        XCTAssertFalse(viewModel.isCreatePresented)
        XCTAssertTrue(viewModel.keys.isEmpty)
    }

    func testSystemCreateSheetDismissalClearsRevealedSecret() async {
        let service = FakeAPIKeyService()
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Dismissed key"
        await viewModel.submitCreate()
        XCTAssertNotNil(viewModel.createdKey)

        viewModel.createSheetDidDisappear()

        XCTAssertNil(viewModel.createdKey)
        XCTAssertFalse(viewModel.isCreatePresented)
        XCTAssertFalse(viewModel.canCopySecret)
        XCTAssertEqual(viewModel.createState, .editing)
    }

    func testCopyFailureKeepsSecretSelectableAndReportsFailure() async {
        let service = FakeAPIKeyService()
        let clipboard = FakeAPIKeyClipboard()
        clipboard.succeeds = false
        let viewModel = makeViewModel(service: service, clipboard: clipboard)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Secret key"
        await viewModel.submitCreate()

        viewModel.copySecret()

        XCTAssertEqual(viewModel.copyState, .failed)
        XCTAssertFalse(clipboard.copiedSecrets.isEmpty)
        XCTAssertNotNil(viewModel.createdKey)
    }

    func testAccountChangeAndSignOutClearSecretAndMetadata() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Secret key"
        await viewModel.submitCreate()
        XCTAssertNotNil(viewModel.createdKey)

        viewModel.accountDidChange(to: "account-b")

        XCTAssertEqual(viewModel.accountID, "account-b")
        XCTAssertNil(viewModel.createdKey)
        XCTAssertFalse(viewModel.isCreatePresented)
        XCTAssertTrue(viewModel.keys.isEmpty)
        XCTAssertEqual(viewModel.listState, .loading)

        await viewModel.load()
        viewModel.presentCreateForm()
        viewModel.draftName = "Another key"
        await viewModel.submitCreate()
        XCTAssertNotNil(viewModel.createdKey)

        viewModel.clearForSignOut()

        XCTAssertNil(viewModel.createdKey)
        XCTAssertTrue(viewModel.keys.isEmpty)
    }

    // MARK: - Revoke

    func testRevokeRequiresConfirmationAndRemovesKey() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1"), key(id: "key-2")])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        viewModel.requestRevoke(key(id: "key-1"))
        var revokeIDs = await service.revokeIDs()
        XCTAssertEqual(revokeIDs, [])

        viewModel.cancelRevoke()
        XCTAssertNil(viewModel.revokeTarget)
        revokeIDs = await service.revokeIDs()
        XCTAssertEqual(revokeIDs, [])

        viewModel.requestRevoke(key(id: "key-1"))
        await viewModel.confirmRevoke()

        revokeIDs = await service.revokeIDs()
        XCTAssertEqual(revokeIDs, ["key-1"])
        XCTAssertEqual(viewModel.keys.map(\.id), ["key-2"])
        XCTAssertNil(viewModel.revokeTarget)
        XCTAssertEqual(viewModel.revokeState, .idle)
    }

    func testRevokeFailureKeepsKeyAndShowsError() async {
        let service = FakeAPIKeyService(keys: [key(id: "key-1")])
        await service.setRevokeError(.networkUnavailable)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        viewModel.requestRevoke(key(id: "key-1"))
        await viewModel.confirmRevoke()

        XCTAssertEqual(viewModel.keys.map(\.id), ["key-1"])
        XCTAssertEqual(
            viewModel.revokeErrorMessage,
            String(localized: "apiKeys.error.network")
        )
        let revokeIDs = await service.revokeIDs()
        XCTAssertEqual(revokeIDs, ["key-1"])
    }

    // MARK: - Limits

    func testActiveKeyLimitDisablesCreateButExpiredKeysDoNot() async {
        let active = (1...10).map { key(id: "key-\($0)") }
        let service = FakeAPIKeyService(keys: active)
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        XCTAssertEqual(viewModel.activeKeyCount, 10)
        XCTAssertTrue(viewModel.hasReachedActiveKeyLimit)
        viewModel.presentCreateForm()
        XCTAssertFalse(viewModel.isCreatePresented)
        XCTAssertEqual(viewModel.listNotice, String(localized: "apiKeys.limit.message"))

        let expired = (1...10).map {
            key(
                id: "expired-\($0)",
                createdAt: "2026-01-01T10:00:00Z",
                expiresAt: "2026-02-01T10:00:00Z"
            )
        }
        await service.setKeys(expired)
        await viewModel.load()

        XCTAssertEqual(viewModel.activeKeyCount, 0)
        XCTAssertFalse(viewModel.hasReachedActiveKeyLimit)
        viewModel.presentCreateForm()
        XCTAssertTrue(viewModel.isCreatePresented)
    }

    func testRequiredLocalizationKeysAreDefined() {
        let keys = [
            "apiKeys.close",
            "apiKeys.create",
            "apiKeys.create.description",
            "apiKeys.create.details",
            "apiKeys.create.expiry",
            "apiKeys.create.expiry.30Days",
            "apiKeys.create.expiry.365Days",
            "apiKeys.create.expiry.90Days",
            "apiKeys.create.expiry.never",
            "apiKeys.create.name",
            "apiKeys.create.name.invalid",
            "apiKeys.create.name.required",
            "apiKeys.create.name.tooLong",
            "apiKeys.create.refresh",
            "apiKeys.create.scope",
            "apiKeys.create.scope.readDescription",
            "apiKeys.create.scope.readWriteDescription",
            "apiKeys.create.storageWarning",
            "apiKeys.create.submit",
            "apiKeys.create.submitting",
            "apiKeys.create.title",
            "apiKeys.create.uncertain.message",
            "apiKeys.create.uncertain.refreshFailed",
            "apiKeys.create.uncertain.title",
            "apiKeys.created",
            "apiKeys.description",
            "apiKeys.empty.message",
            "apiKeys.empty.title",
            "apiKeys.error.cancelled",
            "apiKeys.error.invalidResponse",
            "apiKeys.error.network",
            "apiKeys.error.notFound",
            "apiKeys.error.rateLimited",
            "apiKeys.error.rejected",
            "apiKeys.error.server",
            "apiKeys.error.timeout",
            "apiKeys.error.unknown",
            "apiKeys.expired",
            "apiKeys.expires",
            "apiKeys.hint",
            "apiKeys.keyboard.done",
            "apiKeys.lastUsed",
            "apiKeys.limit.footer",
            "apiKeys.limit.message",
            "apiKeys.list.title",
            "apiKeys.loading",
            "apiKeys.neverExpires",
            "apiKeys.neverUsed",
            "apiKeys.refreshing",
            "apiKeys.revoke",
            "apiKeys.revoke.confirm",
            "apiKeys.revoke.message",
            "apiKeys.revoke.named",
            "apiKeys.revoke.title",
            "apiKeys.revoking",
            "apiKeys.scope.read",
            "apiKeys.scope.readWrite",
            "apiKeys.scope.unknown",
            "apiKeys.secret.copy",
            "apiKeys.secret.copy.accessibility",
            "apiKeys.secret.copyFailed",
            "apiKeys.secret.copied",
            "apiKeys.secret.done",
            "apiKeys.secret.hidden",
            "apiKeys.secret.hide",
            "apiKeys.secret.reveal",
            "apiKeys.secret.storage",
            "apiKeys.secret.title",
            "apiKeys.secret.usage",
            "apiKeys.secret.usageExample",
            "apiKeys.secret.warning",
            "apiKeys.title",
        ]
        for key in keys {
            XCTAssertNotEqual(
                NSLocalizedString(key, bundle: .main, comment: ""),
                key,
                "Missing localized value for \(key)"
            )
        }
    }
}
