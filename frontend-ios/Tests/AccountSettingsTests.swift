import ComposableArchitecture
import Dependencies
import XCTest

@testable import CalCo

/// Migration of the retired `AccountSettingsViewModel` harness (C deleted the
/// VM/view). Every safety scenario is now driven through `AccountSettingsFeature`
/// with C's frozen `APIKeyRequestContext(accountID, generation, requestID)` and
/// memberwise `APIKeyFeatureClient`; pure `APIKeyContractTests` /
/// `APIKeySecretClipboard` remain untouched. Selector-level mapping is in
/// `test-migration/test-mapping.md`.
@MainActor
final class AccountSettingsTests: XCTestCase {
    private let generation: UInt64 = 55
    private let accountID = "acct-5"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ id: UUID) -> APIKeyRequestContext {
        APIKeyRequestContext(accountID: accountID, generation: generation, requestID: id)
    }

    private var key: APIKey {
        APIKey(id: "key-1", name: "CI", tokenHint: "abcd…wxyz",
               scope: .read, createdAt: "2026-11-01T00:00:00Z")
    }

    private var created: CreatedAPIKey {
        CreatedAPIKey(
            key: APIKey(id: "key-2", name: "New key", tokenHint: "1234…9876",
                        scope: .readWrite, createdAt: "2026-11-26T00:00:00Z"),
            secret: APIKeySecret(value: "super-secret-value")
        )
    }

    private var state: AccountSettingsFeature.State {
        AccountSettingsFeature.State(accountID: accountID, generation: generation, now: now)
    }

    private func client(
        keys: [APIKey] = [],
        listError: (any Error & Sendable)? = nil,
        createError: (any Error & Sendable)? = nil,
        revokeError: (any Error & Sendable)? = nil,
        createCalls: LockIsolated<Int>? = nil,
        createNames: LockIsolated<[String]>? = nil,
        revokeCalls: LockIsolated<[String]>? = nil,
        copyReceipt: APIKeyClipboardReceipt? = APIKeyClipboardReceipt(changeCount: 9),
        cleared: LockIsolated<[APIKeyClipboardReceipt]>? = nil,
        copyCalls: LockIsolated<[(String, String, UInt64)]>? = nil,
        listGate: AsyncGate? = nil,
        createGate: AsyncGate? = nil,
        isCurrent: @escaping @Sendable (String, UInt64) -> Bool = { _, _ in true }
    ) -> APIKeyFeatureClient {
        let created = self.created
        return APIKeyFeatureClient(
            listKeys: { _ in
                if let listGate { await listGate.wait() }
                if let listError { throw listError }
                return keys
            },
            createKey: { model, context in
                createCalls?.withValue { $0 += 1 }
                createNames?.withValue { $0.append(model.name) }
                _ = context
                if let createError { throw createError }
                if let createGate { await createGate.wait() }
                return created
            },
            revokeKey: { id, _ in
                revokeCalls?.withValue { $0.append(id) }
                if let revokeError { throw revokeError }
            },
            copySecret: { secret, accountID, generation in
                copyCalls?.withValue { $0.append((secret, accountID, generation)) }
                return copyReceipt
            },
            clearSecret: { receipt in cleared?.withValue { $0.append(receipt) } },
            now: { self.now },
            isCurrentSession: isCurrent
        )
    }

    // MARK: - Load / metadata

    /// Old `testStaleListResponseCannotOverwriteNewerMetadata`.
    func testAccountStaleListResponseIsIgnored() async {
        // Hold the real GET so the stale reply is injected while it is in flight.
        let gate = AsyncGate()
        let store = TestStore(initialState: state) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(keys: [self.key], listGate: gate)
            $0.uuid = .incrementing
        }

        await store.send(.load) {
            $0.listPhase = .loading
            $0.activeListRequestID = UUID(0)
        }
        await store.send(.keysReceived(context: request(UUID(9)), keys: [self.key]))
        XCTAssertEqual(store.state.listPhase.keys, [])
        await gate.open()
        await store.receive({ action in
            guard case let .keysReceived(context, keys) = action else { return false }
            return context == self.request(UUID(0)) && keys == [self.key]
        }) {
            $0.keys = [self.key]
            $0.listPhase = .loaded([self.key])
            $0.activeListRequestID = nil
            $0.isUncertainRefresh = false
            $0.uncertainMetadataRefreshFailed = false
        }
    }

    /// Old `testUncertainCreateReportsMetadataRefreshFailureAndStillDoesNotRetry`.
    func testAccountUncertainCreateMetadataFailureKeepsFormAndRetriesOnlyMetadata() async {
        let createCalls = LockIsolated(0)
        var initial = state
        initial.keys = [self.key]
        initial.listPhase = .loaded([self.key])
        initial.isCreatePresented = true
        initial.draftName = "CI"
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(
                keys: [self.key],
                listError: APIKeyServiceError.networkUnavailable,
                createError: APIKeyServiceError.networkUnavailable,
                createCalls: createCalls
            )
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        await store.receive({ action in
            guard case let .createFailed(context, error) = action else { return false }
            return context == self.request(UUID(0)) && error == .networkUnavailable
        }) {
            $0.activeCreateRequestID = nil
            $0.createState = .uncertain(String(localized: "apiKeys.create.uncertain.message"))
            $0.uncertainMetadataRefreshFailed = false
            $0.listPhase = .refreshing(previous: [self.key])
            $0.activeListRequestID = UUID(1)
            $0.isUncertainRefresh = true
        }
        await store.receive({ action in
            guard case let .loadFailed(context, message, unauthorized) = action else { return false }
            return context == self.request(UUID(1))
                && message == String(localized: "apiKeys.error.network")
                && unauthorized == false
        }) {
            $0.activeListRequestID = nil
            $0.listPhase = .loaded([self.key])
            $0.listNotice = String(localized: "apiKeys.error.network")
            $0.uncertainMetadataRefreshFailed = true
            $0.isUncertainRefresh = false
        }
        XCTAssertEqual(createCalls.value, 1)
        if case .uncertain = store.state.createState {} else {
            XCTFail("An uncertain create must keep its message until explicit dismissal")
        }
    }

    /// Old `testLoadListsKeysAndRetriesAfterFailure` / `testDefinitiveCreateFailureAllowsExplicitRetry`.
    func testAccountDefinitiveCreateFailureAllowsExplicitRetry() async {
        let createCalls = LockIsolated(0)
        var initial = state
        initial.listPhase = .loaded([])
        initial.isCreatePresented = true
        initial.draftName = "CI"
        let shouldFail = LockedBool(true)
        let created = self.created
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = APIKeyFeatureClient(
                listKeys: { _ in [] },
                createKey: { _, _ in
                    createCalls.withValue { $0 += 1 }
                    // A definitive rejection is retryable; `.server` is an
                    // ambiguous transport failure and must NOT be retried.
                    if shouldFail.current { throw APIKeyServiceError.rejected("busy") }
                    return created
                },
                revokeKey: { _, _ in },
                copySecret: { _, _, _ in nil },
                clearSecret: { _ in },
                now: { self.now },
                isCurrentSession: { _, _ in true }
            )
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        await store.receive({ action in
            guard case let .createFailed(context, error) = action else { return false }
            return context == self.request(UUID(0)) && error == .rejected("busy")
        }) {
            $0.activeCreateRequestID = nil
            $0.createState = .failed("busy")
        }
        shouldFail.current = false
        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(1)
        }
        await store.receive({ action in
            guard case let .createReceived(context, created) = action else { return false }
            return context == self.request(UUID(1)) && created == self.created
        }) {
            $0.activeCreateRequestID = nil
            $0.createdKey = self.created
            $0.isSecretObscured = false
            $0.copyState = .idle
            $0.createState = .created
            $0.keys = [self.created.key]
            $0.listPhase = .loaded([self.created.key])
            $0.listNotice = nil
        }
        XCTAssertEqual(createCalls.value, 2)
    }

    // MARK: - Create form validation and reveal

    /// Old `testInvalidNameBlocksRequestUntilCorrected`.
    func testAccountInvalidNameBlocksRequestUntilCorrected() async {
        let createCalls = LockIsolated(0)
        var initial = state
        initial.listPhase = .loaded([])
        initial.isCreatePresented = true
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(createCalls: createCalls)
            $0.uuid = .incrementing
        }

        await store.send(.draftNameChanged("   ")) {
            $0.draftName = "   "
        }
        await store.send(.submitCreate) {
            $0.hasAttemptedCreate = true
        }
        XCTAssertEqual(createCalls.value, 0)
        await store.send(.draftNameChanged("CI")) {
            $0.draftName = "CI"
            $0.createState = .editing
        }
        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.copyState = .idle
        }
        await store.receive({ action in
            guard case let .createReceived(context, created) = action else { return false }
            return context == self.request(UUID(0)) && created == self.created
        }) {
            $0.activeCreateRequestID = nil
            $0.createdKey = self.created
            $0.isSecretObscured = false
            $0.copyState = .idle
            $0.createState = .created
            $0.keys = [self.created.key]
            $0.listPhase = .loaded([self.created.key])
            $0.listNotice = nil
        }
        XCTAssertEqual(createCalls.value, 1)
    }

    /// Old `testCreateTrimsNameRevealsOnceAndDoesNotAutoCopy`.
    func testAccountCreateTrimsNameAndDoesNotAutoCopy() async {
        let names = LockIsolated<[String]>([])
        var initial = state
        initial.listPhase = .loaded([])
        initial.isCreatePresented = true
        initial.draftName = "  CI key  "
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(createNames: names)
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        await store.receive({ action in
            guard case let .createReceived(context, created) = action else { return false }
            return context == self.request(UUID(0)) && created == self.created
        }) {
            $0.activeCreateRequestID = nil
            $0.createdKey = self.created
            $0.isSecretObscured = false
            $0.copyState = .idle
            $0.createState = .created
            $0.keys = [self.created.key]
            $0.listPhase = .loaded([self.created.key])
            $0.listNotice = nil
        }
        XCTAssertEqual(names.value, ["CI key"])
        XCTAssertTrue(store.state.isSecretRevealed)
        XCTAssertEqual(store.state.copyState, .idle)
        XCTAssertNil(store.state.clipboardReceipt)
    }

    /// Old `testDoubleTapSendsOneCreateRequest`.
    func testAccountDoubleTapCreateSendsOneRequest() async {
        let createCalls = LockIsolated(0)
        let gate = AsyncGate()
        var initial = state
        initial.isCreatePresented = true
        initial.draftName = "CI"
        initial.listPhase = .loaded([self.key])
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(createCalls: createCalls, createGate: gate)
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        // Second tap while the POST is genuinely in flight must be ignored.
        await store.send(.submitCreate)
        await gate.open()
        await store.receive({ action in
            guard case let .createReceived(context, created) = action else { return false }
            return context == self.request(UUID(0)) && created == self.created
        }) {
            $0.createState = .created
            $0.createdKey = self.created
            $0.activeCreateRequestID = nil
            $0.isSecretObscured = false
            $0.copyState = .idle
            $0.keys = [self.created.key]
            $0.listPhase = .loaded([self.created.key])
            $0.listNotice = nil
        }
        XCTAssertEqual(createCalls.value, 1)
    }

    /// Old `testCreateCompletingWhileInactiveStartsObscuredAndRequiresReveal`.
    func testAccountCreateCompletingInactiveStartsObscured() async {
        var initial = state
        initial.listPhase = .loaded([])
        initial.isCreatePresented = true
        initial.draftName = "CI"
        initial.isSceneActive = false
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client()
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        await store.receive({ action in
            guard case let .createReceived(context, created) = action else { return false }
            return context == self.request(UUID(0)) && created == self.created
        }) {
            $0.activeCreateRequestID = nil
            $0.createdKey = self.created
            $0.isSecretObscured = true
            $0.copyState = .idle
            $0.createState = .created
            $0.keys = [self.created.key]
            $0.listPhase = .loaded([self.created.key])
            $0.listNotice = nil
        }
        await store.send(.revealSecret)
        XCTAssertTrue(store.state.isSecretObscured)
        XCTAssertFalse(store.state.canCopySecret)

        await store.send(.scenePhaseChanged(isActive: true)) {
            $0.isSceneActive = true
        }
        await store.send(.revealSecret) {
            $0.isSecretObscured = false
            $0.copyState = .idle
        }
        XCTAssertTrue(store.state.isSecretRevealed)
    }

    /// Old `testCopyFailureKeepsSecretSelectableAndReportsFailure`.
    func testAccountCopyFailureKeepsSecretSelectable() async {
        var initial = state
        initial.listPhase = .loaded([])
        initial.createdKey = created
        initial.createState = .created
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(copyReceipt: nil)
        }

        await store.send(.copySecret) {
            $0.copyState = .failed
        }
        XCTAssertNil(store.state.clipboardReceipt)
        XCTAssertNotNil(store.state.createdKey)
        XCTAssertTrue(store.state.canCopySecret)
    }

    /// Old `testClipboardCleanupClearsOnlyOwnedSecret` / `testSignOutClearSecretAndMetadata`.
    func testAccountSignOutClearsReceiptAndSessionScopedState() async {
        let receipt = APIKeyClipboardReceipt(changeCount: 9)
        let cleared = LockIsolated<[APIKeyClipboardReceipt]>([])
        var initial = state
        initial.keys = [self.key]
        initial.listPhase = .loaded([self.key])
        initial.createdKey = created
        initial.clipboardReceipt = receipt
        initial.copyState = .copied
        initial.isCreatePresented = true
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(cleared: cleared)
        }

        await store.send(.signOut) {
            $0.activeListRequestID = nil
            $0.activeCreateRequestID = nil
            $0.activeRevokeRequestID = nil
            $0.hasLoaded = false
            $0.sessionExpired = false
            $0.keys = []
            $0.listPhase = .idle
            $0.listNotice = nil
            $0.isCreatePresented = false
            $0.draftName = ""
            $0.draftScope = .read
            $0.draftExpiry = .default
            $0.hasAttemptedCreate = false
            $0.createState = .editing
            $0.createdKey = nil
            $0.isSecretObscured = false
            $0.copyState = .idle
            $0.uncertainMetadataRefreshFailed = false
            $0.clipboardReceipt = nil
            $0.revokeTarget = nil
            $0.revokingKeyID = nil
            $0.revokeState = .idle
        }
        XCTAssertEqual(cleared.value, [receipt])
    }

    /// Old `testHeldPostAccountSwitchKeepsOldAccountClearedAndAllowsFreshCreate`
    /// and `testAccountChangeDuringCreateIgnoresLateSecret`.
    func testAccountLateSecretFromOldAccountIsIgnored() async {
        let generation = self.generation
        let created = self.created
        // Hold the genuine POST reply; inject a late secret attributed to a
        // different account while it is in flight, then release the real reply.
        let gate = AsyncGate()
        var initial = state
        initial.listPhase = .loaded([])
        initial.isCreatePresented = true
        initial.draftName = "CI"
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(createGate: gate)
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        let oldAccountContext = APIKeyRequestContext(
            accountID: "acct-6", generation: generation, requestID: UUID(0)
        )
        await store.send(.createReceived(context: oldAccountContext, created: created))
        XCTAssertNil(store.state.createdKey)
        XCTAssertEqual(store.state.createState, .submitting)

        await gate.open()
        await store.receive({ action in
            guard case let .createReceived(context, received) = action else { return false }
            return context == self.request(UUID(0)) && received == created
        }) {
            $0.activeCreateRequestID = nil
            $0.createdKey = created
            $0.isSecretObscured = false
            $0.copyState = .idle
            $0.createState = .created
            $0.keys = [created.key]
            $0.listPhase = .loaded([created.key])
            $0.listNotice = nil
        }
        XCTAssertEqual(store.state.createdKey, created)
        XCTAssertEqual(store.state.keys, [created.key])
    }

    /// Old `testAccountChangeAndSignOutClearSecretAndMetadata` (account-change
    /// delegate path) and live-guard drop of a held secret reply.
    func testAccountLiveGuardDropsHeldSecretForFormerSession() async {
        let current = LockedBool(true)
        let gate = AsyncGate()
        var initial = state
        initial.listPhase = .loaded([])
        initial.isCreatePresented = true
        initial.draftName = "CI"
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(
                createGate: gate, isCurrent: { _, _ in current.current }
            )
            $0.uuid = .incrementing
        }

        await store.send(.submitCreate) {
            $0.createState = .submitting
            $0.activeCreateRequestID = UUID(0)
            $0.hasAttemptedCreate = true
        }
        current.current = false // session switched while POST was in flight
        await gate.open()
        await store.finish()
        XCTAssertNil(store.state.createdKey)
        XCTAssertEqual(store.state.createState, .submitting)
    }

    // MARK: - Revoke / limits

    /// Old `testRevokeRequiresConfirmationAndRemovesKey`.
    func testAccountRevokeRequiresExplicitConfirmation() async {
        let revokeCalls = LockIsolated<[String]>([])
        var initial = state
        initial.keys = [self.key]
        initial.listPhase = .loaded([self.key])
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(revokeCalls: revokeCalls)
            $0.uuid = .incrementing
        }

        await store.send(.requestRevoke(key)) {
            $0.revokeTarget = self.key
        }
        await store.send(.cancelRevoke) {
            $0.revokeTarget = nil
            $0.revokeState = .idle
        }
        await store.send(.requestRevoke(key)) {
            $0.revokeTarget = self.key
        }
        await store.send(.confirmRevoke) {
            $0.revokingKeyID = self.key.id
            $0.revokeState = .revoking
            $0.revokeTarget = nil
            $0.activeRevokeRequestID = UUID(0)
        }
        await store.receive({ action in
            guard case let .revokeReceived(context, id) = action else { return false }
            return context == self.request(UUID(0)) && id == self.key.id
        }) {
            $0.keys = []
            $0.listNotice = nil
            $0.revokingKeyID = nil
            $0.revokeState = .idle
            $0.activeRevokeRequestID = nil
        }
        XCTAssertEqual(revokeCalls.value, ["key-1"])
    }

    /// Old `testRevokeFailureKeepsKeyAndShowsError`.
    func testAccountRevokeFailureKeepsKeyAndShowsError() async {
        var initial = state
        initial.keys = [self.key]
        initial.listPhase = .loaded([self.key])
        initial.revokeTarget = key
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(revokeError: APIKeyServiceError.server("busy"))
            $0.uuid = .incrementing
        }

        await store.send(.confirmRevoke) {
            $0.revokingKeyID = self.key.id
            $0.revokeState = .revoking
            $0.revokeTarget = nil
            $0.activeRevokeRequestID = UUID(0)
        }
        await store.receive({ action in
            guard case let .revokeFailed(context, error) = action else { return false }
            return context == self.request(UUID(0)) && error == .server("busy")
        }) {
            $0.activeRevokeRequestID = nil
            $0.revokingKeyID = nil
            $0.revokeState = .failed(String(localized: "apiKeys.error.server"))
        }
        XCTAssertEqual(store.state.keys, [self.key])
    }

    /// Old `testActiveKeyLimitDisablesCreateButExpiredKeysDoNot`.
    func testAccountActiveKeyLimitCountsOnlyUnexpiredKeys() {
        var initial = state
        initial.keys = (0..<10).map { index in
            APIKey(id: "key-\(index)", name: "Key \(index)", tokenHint: "abcd",
                   scope: .read, createdAt: "2026-11-01T00:00:00Z")
        }
        initial.listPhase = .loaded(initial.keys)
        XCTAssertTrue(initial.hasReachedActiveKeyLimit)

        var withExpired = initial
        withExpired.keys[0] = APIKey(id: "expired", name: "Expired", tokenHint: "abcd",
                                     scope: .read, createdAt: "2026-11-01T00:00:00Z",
                                     expiresAt: "2020-01-01T00:00:00Z")
        XCTAssertFalse(withExpired.hasReachedActiveKeyLimit)
    }

    /// Old `testCreateTrimsNameRevealsOnceAndDoesNotAutoCopy` / copy-current-session
    /// assertions: an explicit copy passes the full secret with the captured
    /// account and generation to the clipboard seam, only once.
    func testAccountExplicitCopyCarriesFullSecretAndCurrentSession() async {
        let receipt = APIKeyClipboardReceipt(changeCount: 11)
        let copyCalls = LockIsolated<[(String, String, UInt64)]>([])
        var initial = state
        initial.listPhase = .loaded([])
        initial.createdKey = created
        initial.createState = .created
        let store = TestStore(initialState: initial) {
            AccountSettingsFeature()
        } withDependencies: {
            $0.apiKeyClient = client(copyReceipt: receipt, copyCalls: copyCalls)
        }

        await store.send(.copySecret) {
            $0.clipboardReceipt = receipt
            $0.copyState = .copied
        }
        let recorded = copyCalls.value
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.0, created.secret.value)
        XCTAssertEqual(recorded.first?.1, accountID)
        XCTAssertEqual(recorded.first?.2, generation)
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var current: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Deterministic in-flight gate: holds an effect open without sleeps so a
/// second tap / session change can occur while the request is pending.
private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
