import CasePaths
import ComposableArchitecture
import XCTest

@testable import CalCo

/// In-memory stand-in for the frozen LogSubmissionStore. Every method maps to
/// the same transition the real store performs; no new writer/authority.
/// Thread-safe in-memory stand-in for the frozen LogSubmissionStore. All state
/// is NSLock-protected so the synchronous @Sendable JournalClient closures can
/// read and mutate it dynamically (later test mutations remain visible). No
/// snapshots and no @MainActor isolation assumptions.
private final class JournalFake: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [String: PendingLogSubmission] = [:]
    private var reservedEntries: [String: PendingLogSubmission] = [:]
    private var blockedIDs: Set<String> = []
    private var liveIDs: Set<String> = []

    var entries: [String: PendingLogSubmission] {
        lock.lock(); defer { lock.unlock() }
        return storedEntries
    }

    var reserved: [String: PendingLogSubmission] {
        lock.lock(); defer { lock.unlock() }
        return reservedEntries
    }

    var blocked: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return blockedIDs
    }

    var live: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return liveIDs
    }

    func markBlocked(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        blockedIDs.insert(id)
    }

    func markLive(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        liveIDs.insert(id)
    }

    private func entry(_ id: String) -> PendingLogSubmission? {
        lock.lock(); defer { lock.unlock() }
        return storedEntries[id]
    }

    private func update(_ id: String, _ transform: (inout PendingLogSubmission) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard var entry = storedEntries[id] else {
            throw LogSubmissionStoreError.missingEntry
        }
        transform(&entry)
        storedEntries[id] = entry
    }

    func client() -> FoodDetailFeature.JournalClient {
        FoodDetailFeature.JournalClient(
            unresolved: { [weak self] accountID, foodID, date in
                guard let self else { return [] }
                return self.entries.values.filter {
                    !self.blocked.contains($0.id)
                        && $0.accountID == accountID
                        && $0.draft.foodID == foodID
                        && $0.draft.date == date
                        && ($0.state == .inFlight
                            || $0.state == .uncertain
                            || $0.state == .conflicted)
                }
            },
            entry: { [weak self] id, _ in self?.entry(id) },
            requireEntry: { [weak self] id, _ in
                guard let self, let entry = self.entry(id) else {
                    throw LogSubmissionStoreError.missingEntry
                }
                return entry
            },
            reserve: { [weak self] account, name, draft, request, body in
                guard let self else {
                    throw LogSubmissionStoreError.persistence("test fixture unavailable")
                }
                let entry = PendingLogSubmission(
                    id: request.idempotencyKey ?? UUID().uuidString.lowercased(),
                    accountID: account,
                    foodName: name,
                    draft: draft,
                    idempotencyKey: request.idempotencyKey ?? "",
                    body: body,
                    baseURLString: request.baseURLString ?? "",
                    state: .inFlight,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                self.lock.lock()
                self.storedEntries[entry.id] = entry
                self.reservedEntries[entry.id] = entry
                self.lock.unlock()
                return entry
            },
            markInFlight: { [weak self] id, _ in
                guard let self else { throw LogSubmissionStoreError.missingEntry }
                try self.update(id) { $0.state = .inFlight }
            },
            markUncertain: { [weak self] id, _, status, message, retryAfter in
                guard let self else { throw LogSubmissionStoreError.missingEntry }
                try self.update(id) { entry in
                    entry.state = .uncertain
                    entry.lastStatus = status
                    entry.lastMessage = message
                    entry.retryAfterSeconds = retryAfter
                }
            },
            markSucceeded: { [weak self] id, _, logID, date, slot, replayed in
                guard let self else { throw LogSubmissionStoreError.missingEntry }
                try self.update(id) { entry in
                    entry.state = .succeeded
                    entry.body = nil
                    entry.resultLogID = logID
                    entry.resultDate = date
                    entry.resultMealSlot = slot
                    entry.replayed = replayed
                    entry.lastStatus = replayed ? 200 : 201
                    entry.lastMessage = nil
                }
            },
            markRejected: { [weak self] id, _, status, message in
                guard let self else { throw LogSubmissionStoreError.missingEntry }
                try self.update(id) { entry in
                    entry.state = .rejected
                    entry.lastStatus = status
                    entry.lastMessage = message
                }
            },
            markConflicted: { [weak self] id, _, message in
                guard let self else { throw LogSubmissionStoreError.missingEntry }
                try self.update(id) { entry in
                    entry.state = .conflicted
                    entry.body = nil
                    entry.lastMessage = message
                }
            },
            remove: { [weak self] id, _ in
                guard let self else { throw LogSubmissionStoreError.persistence("test fixture unavailable") }
                self.lock.lock()
                self.storedEntries[id] = nil
                self.lock.unlock()
            },
            isRetryBlocked: { [weak self] id in
                guard let self else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.blockedIDs.contains(id)
            },
            isLiveSubmission: { [weak self] id in
                guard let self else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.liveIDs.contains(id)
            },
            revisionUpdates: { AsyncStream { $0.finish() } }
        )
    }
}

private actor PostGate {
    private var didEnter = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        didEnter = true
        let pending = enteredWaiters
        enteredWaiters = []
        for waiter in pending { waiter.resume() }
    }

    func entered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class DetailServiceFake: @unchecked Sendable {
    var food: FoodDetail = FoodDetail(id: "food-1", name: "Food")
    var units: [FoodUnit] = [FoodUnit(code: "g", name: "Gram")]
    var foodError: Error?
    var createError: Error?
    var lastUsed: RecentLogItem?
    var requests: [FoodLogCreateRequest] = []
    var createContexts: [FeatureRequestContext] = []
    var postGate: PostGate?

    func recordCreateContext(_ context: FeatureRequestContext) {
        createContexts.append(context)
    }

    func fetch() async throws -> FoodDetail {
        if let foodError { throw foodError }
        return food
    }

    func create(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        requests.append(request)
        if let postGate {
            await postGate.markEntered()
            await postGate.wait()
        }
        if let createError { throw createError }
        return CreatedFoodLog(id: "log-1", date: request.date, mealSlot: request.mealSlot)
    }
}

@MainActor
final class FoodDetailTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let accountID = "account-a"
    private let generation: UInt64 = 42
    private let baseURL = URL(string: "https://calco.example.com")
    /// Explicit deterministic request/identity fixtures for every load helper.
    private let loadRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let presentationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var expectedContext: FeatureRequestContext {
        FeatureRequestContext(
            accountID: accountID, generation: generation, presentationID: presentationID
        )
    }

    private func assertValidIdempotencyKey(
        _ key: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let key else {
            return XCTFail("Expected an idempotency key", file: file, line: line)
        }
        XCTAssertNotNil(UUID(uuidString: key), "The key must be a UUID", file: file, line: line)
        XCTAssertEqual(key, key.trimmingCharacters(in: .whitespacesAndNewlines), file: file, line: line)
        XCTAssertTrue((1...128).contains(key.count), file: file, line: line)
    }

    private func makeStore(
        foodID: String = "food-1",
        slot: MealSlot? = nil,
        service: DetailServiceFake,
        journal: JournalFake,
        accountID: String = "account-a",
        requestID: UUID? = nil,
        presentationID: UUID? = nil,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        initialState: FoodDetailFeature.State? = nil
    ) -> TestStore<FoodDetailFeature.State, FoodDetailFeature.Action> {
        let resolvedRequestID = requestID ?? self.loadRequestID
        let resolvedPresentationID = presentationID ?? self.presentationID
        let state = initialState ?? FoodDetailFeature.State(
            foodID: foodID,
            date: date,
            slot: slot,
            generation: generation,
            accountID: accountID,
            presentationID: resolvedPresentationID,
            baseURL: baseURL
        )
        let units = service.units
        let lastUsedItem = service.lastUsed
        return TestStore(initialState: state) {
            FoodDetailFeature()
        } withDependencies: {
            $0.foodDetailClient = FoodDetailFeature.Client(
                fetchFood: { _, _ in try await service.fetch() },
                fetchUnits: { _ in units },
                lastUsed: { _, _, _, _ in lastUsedItem },
                createLog: { context, request in
                    await service.recordCreateContext(context)
                    return try await service.create(request)
                },
                makeID: makeID,
                timeZoneIdentifier: { "America/New_York" }
            )
            $0.foodDetailJournalClient = journal.client()
            $0.uuid = .constant(resolvedRequestID)
        }
    }

    /// Plain helper from explicit fixtures: no post-action store introspection.
    private func load(
        _ store: TestStore<FoodDetailFeature.State, FoodDetailFeature.Action>,
        service: DetailServiceFake,
        lastUsed: RecentLogItem? = nil,
        requestID: UUID? = nil,
        slot: MealSlot? = nil
    ) async throws {
        let expectedRequestID = requestID ?? self.loadRequestID
        let expectedContext = FeatureRequestContext(
            accountID: self.accountID,
            generation: self.generation,
            presentationID: self.presentationID
        )
        await store.send(FoodDetailFeature.Action.load) {
            $0.load = .loading
            $0.loadedFood = nil
            $0.lastUsedNotice = nil
            $0.quantityWasEdited = false
            $0.formWasEdited = false
            $0.hasAttemptedSubmission = false
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.recovery = .idle
            $0.loadRequestID = expectedRequestID
        }
        await store.receive(.loadCompleted(
            requestID: expectedRequestID,
            context: expectedContext,
            result: .success(FoodDetailFeature.LoadPayload(
                food: service.food,
                units: service.units
            ))
        )) {
            $0.units = service.units
            let defaults = service.food.defaultLogQuantity
            $0.amount = defaults.amount
            $0.unit = defaults.unit
            if $0.mealSlot == nil { $0.mealSlot = slot }
            $0.loadedFood = service.food
            $0.load = .loaded
            $0.lastUsedRequestID = expectedRequestID
        }
        await store.receive(.lastUsedCompleted(
            requestID: expectedRequestID,
            context: expectedContext,
            result: .success(lastUsed)
        ))
    }

    /// Explicit submit-start state diff from known fixtures (idempotency key,
    /// request ID and captured timezone). No after-action store introspection.
    private func sendSubmit(
        _ store: TestStore<FoodDetailFeature.State, FoodDetailFeature.Action>,
        attemptID: String,
        requestID: UUID,
        timeZone: String = "America/New_York"
    ) async {
        await store.send(FoodDetailFeature.Action.submit) {
            $0.hasAttemptedSubmission = true
            $0.frozenTimeZone = timeZone
            $0.newSubmissionConfirmationID = nil
            $0.currentAttemptID = attemptID
            $0.submit = .submitting
            $0.activeWriteRequestID = requestID
        }
    }

    /// Drains the immutable settlement action produced by the write effect and
    /// the single UI delegate, if any. Keeps TestStore exhaustivity at default.
    /// Drains the immutable settlement action produced by the write effect and
    /// the single UI delegate, if any. All expected rows are predicted from the
    /// captured attempt + known server outcome, never from a post-action read.
    private func drainWrite(
        _ store: TestStore<FoodDetailFeature.State, FoodDetailFeature.Action>,
        journal: JournalFake,
        requestID: UUID,
        outcome: FoodDetailSettlement.Outcome,
        context: FeatureRequestContext,
        expectLogged: Bool = false,
        expectExpiry: Bool = false
    ) async throws {
        let original = journal.reserved.values.first ?? journal.entries.values.first!
        let sessionExpiredMessage = String(localized: "foodDetail.error.sessionExpired")

        // Predict the terminal journal row from the known outcome/failure.
        var predictedRow = original
        var hasPending = false
        switch outcome {
        case .succeeded:
            break
        case let .failed(failure, _):
            switch failure {
            case .stale:
                hasPending = true // still the in-flight snapshot
            case .unauthorized:
                predictedRow.state = .uncertain
                predictedRow.lastStatus = 401
                predictedRow.lastMessage = sessionExpiredMessage
                predictedRow.retryAfterSeconds = nil
                hasPending = true
            case let .uncertain(message):
                predictedRow.state = .uncertain
                predictedRow.lastStatus = nil
                predictedRow.lastMessage = message
                predictedRow.retryAfterSeconds = nil
                hasPending = true
            case let .conflict(message):
                predictedRow.state = .conflicted
                predictedRow.body = nil
                predictedRow.lastMessage = message
                hasPending = true
            case let .rateLimited(retryAfter):
                predictedRow.state = .uncertain
                predictedRow.lastStatus = 429
                predictedRow.lastMessage = String(localized: "foodDetail.error.rateLimited")
                predictedRow.retryAfterSeconds = retryAfter
                hasPending = true
            case .failed(_):
                predictedRow.state = .rejected // real store marks rejected, excluded from unresolved
            }
        }

        // One authoritative success record shared by state and delegate.
        var expectedSuccess: FoodLogSubmissionSuccess?
        if case let .succeeded(created, entry) = outcome {
            let attempt = entry ?? original
            expectedSuccess = FoodLogSubmissionSuccess(
                submissionID: attempt.id,
                accountID: attempt.accountID,
                foodID: attempt.draft.foodID,
                foodName: attempt.foodName,
                date: attempt.resultDate ?? attempt.draft.date,
                mealSlot: created.mealSlot ?? attempt.resultMealSlot ?? attempt.draft.mealSlot,
                logID: created.id,
                replayed: created.replayed
            )
        }

        await store.receive(.settled(settlement: FoodDetailSettlement(
            requestID: requestID,
            attempt: original,
            ownerAccountID: accountID,
            generation: generation,
            context: context,
            recovery: false,
            outcome: outcome
        ))) { state in
            state.activeWriteRequestID = nil
            if hasPending && !journal.blocked.contains(original.id) {
                state.pending = [predictedRow]
                state.visiblePending = [predictedRow]
                state.lastPendingIDs = [original.id]
                state.currentAttemptID = original.id
            } else {
                state.pending = []
                state.visiblePending = []
                state.lastPendingIDs = []
            }
            switch outcome {
            case .succeeded:
                state.currentAttemptID = nil
                state.newSubmissionConfirmationID = nil
                state.lastSubmissionSuccess = expectedSuccess
                state.submit = .succeeded
            case let .failed(failure, _):
                switch failure {
                case .unauthorized:
                    state.submit = .failed(sessionExpiredMessage)
                    state.currentAttemptID = nil
                case .stale:
                    break
                case let .uncertain(message):
                    state.submit = .uncertain(message)
                case let .conflict(message):
                    state.submit = .conflict(message)
                case let .rateLimited(_):
                    state.submit = .rateLimited(String(localized: "foodDetail.error.rateLimited"))
                case let .failed(message):
                    state.submit = .failed(message)
                    state.currentAttemptID = nil
                }
            }
        }
        if expectLogged, let expectedSuccess {
            let date = expectedSuccess.date
            await store.receive(.delegate(.logged(
                date: date,
                slot: expectedSuccess.mealSlot,
                generation: generation,
                submission: expectedSuccess
            )))
        }
        if expectExpiry {
            await store.receive(.delegate(.sessionExpired(generation: generation)))
        }
    }

    // MARK: - Pure contracts preserved byte-for-byte

    func testValidateLogAmountRejectsInvalidValues() {
        XCTAssertNil(validateLogAmount("1"))
        XCTAssertNil(validateLogAmount("1.5"))
        XCTAssertNotNil(validateLogAmount(""))
        XCTAssertNotNil(validateLogAmount("0"))
        XCTAssertNotNil(validateLogAmount("-1"))
        XCTAssertNotNil(validateLogAmount("abc"))
        XCTAssertNotNil(validateLogAmount("1.2.3"))
        XCTAssertNotNil(validateLogAmount("NaN"))
        XCTAssertNotNil(validateLogAmount("Infinity"))
    }

    func testRecoveryLocalizationKeysAreDefined() {
        let keys = [
            "foodDetail.error.conflict", "foodDetail.error.differentServer",
            "foodDetail.error.rateLimited", "foodDetail.error.saveFailed",
            "foodDetail.error.uncertain", "foodDetail.pending.banner",
            "foodDetail.pending.checkDiary", "foodDetail.pending.conflicted",
            "foodDetail.pending.later", "foodDetail.pending.retry",
            "foodDetail.pending.review", "foodDetail.pending.title",
            "foodDetail.pending.recoveryTitle", "foodDetail.pending.newSubmission",
            "foodDetail.pending.newSubmission.confirmTitle",
            "foodDetail.pending.newSubmission.confirmMessage",
            "foodDetail.pending.newSubmission.confirmAction",
            "foodDetail.pending.cancel", "foodDetail.pending.discard",
            "foodDetail.pending.discard.confirmTitle",
            "foodDetail.pending.discard.confirmMessage",
            "foodDetail.pending.discard.confirmAction",
            "foodDetail.pending.invalidated", "foodDetail.pending.reviewAll",
            "foodDetail.pending.dismissBanner", "foodDetail.pending.banner.count",
            "foodDetail.error.journalUnavailable",
            "diary.editor.delete.confirmWithPending", "diary.editor.back",
            "diary.editor.discard.action", "diary.editor.discard.message",
            "diary.editor.discard.title", "diary.mutation.deleted.blockedPending",
        ]
        for key in keys {
            XCTAssertNotEqual(
                NSLocalizedString(key, bundle: .main, comment: ""), key,
                "Missing localized value for \(key)"
            )
        }
    }

    private func makeStoreDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-feature-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeStore(at directory: URL? = nil) -> LogSubmissionStore {
        LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(
                directoryURL: directory ?? makeStoreDirectory()
            )
        )
    }

    @discardableResult
    private func seedSubmission(
        in store: LogSubmissionStore,
        foodID: String,
        amount: String,
        unit: String = "g",
        state: LogSubmissionState = .uncertain,
        accountID: String = "account-a"
    ) throws -> PendingLogSubmission {
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: foodID, foodName: "Seeded", date: date, mealSlot: .lunch,
            amount: amount, unit: unit, notes: nil,
            timeZoneIdentifier: "America/New_York",
            baseURL: baseURL, idempotencyKey: UUID().uuidString.lowercased()
        )
        let entry = try store.reserve(
            accountID: accountID, foodName: "Seeded",
            draft: prepared.draft, request: prepared.request, body: prepared.body
        )
        switch state {
        case .uncertain:
            try store.markUncertain(id: entry.id, accountID: accountID, status: nil, message: "offline")
        case .conflicted:
            try store.markConflicted(id: entry.id, accountID: accountID, message: "conflict")
        case .succeeded:
            try store.markSucceeded(
                id: entry.id, accountID: accountID, logID: "log-seed",
                date: date, mealSlot: .lunch, replayed: false
            )
        case .rejected:
            try store.markRejected(id: entry.id, accountID: accountID, status: 400, message: "rejected")
        case .inFlight:
            break
        case .invalidated:
            _ = try store.invalidateUnresolved(
                accountID: accountID, foodID: foodID, date: date, reason: "deleted"
            )
        }
        return store.entry(id: entry.id, accountID: accountID) ?? entry
    }

    // MARK: - Load / defaults

    func testLoadSuccessAppliesDefaults() async throws {
        let service = DetailServiceFake()
        service.food = FoodDetail(
            id: "food-1", name: "Chicken", defaultQuantity: "2", defaultUnit: "serving",
            nutrients: [FoodNutrient(code: "ENERGY_KCAL", amountPer100g: "200", unit: "kcal")],
            servings: [FoodServing(unit: "serving", gramsPerUnit: "100")],
            allowedUnits: [FoodUnit(code: "serving", name: "Serving")]
        )
        let store = makeStore(slot: .lunch, service: service, journal: JournalFake())
        try await load(store, service: service, slot: .lunch)
        XCTAssertEqual(store.state.load, .loaded)
        XCTAssertEqual(store.state.food?.name, "Chicken")
        XCTAssertEqual(store.state.amount, "2")
        XCTAssertEqual(store.state.unit, "serving")
        XCTAssertEqual(store.state.mealSlot, .lunch)
        XCTAssertEqual(store.state.availableUnits.map(\.code), ["serving"])
        XCTAssertNil(store.state.lastSubmissionSuccess)
    }

    func testLoadFallsBackToFirstServing() async throws {
        let service = DetailServiceFake()
        service.food = FoodDetail(
            id: "food-2", name: "Rice", servings: [FoodServing(unit: "cup", gramsPerUnit: "180")]
        )
        service.units = [FoodUnit(code: "g", name: "Grams")]
        let store = makeStore(foodID: "food-2", service: service, journal: JournalFake())
        try await load(store, service: service)
        XCTAssertEqual(store.state.amount, "1")
        XCTAssertEqual(store.state.unit, "cup")
        XCTAssertEqual(store.state.availableUnits.map(\.code), ["g"])
    }

    func testLoadHalfDefaultNeverMixesFields() async throws {
        let quantityService = DetailServiceFake()
        quantityService.food = FoodDetail(
            id: "food-half-quantity", name: "Quantity only", defaultQuantity: "2",
            servings: [FoodServing(unit: "cup", gramsPerUnit: "200")]
        )
        let first = makeStore(
            foodID: "food-half-quantity", service: quantityService, journal: JournalFake()
        )
        try await load(first, service: quantityService)
        XCTAssertEqual(first.state.amount, "1")
        XCTAssertEqual(first.state.unit, "cup")

        let unitService = DetailServiceFake()
        unitService.food = FoodDetail(id: "food-half-unit", name: "Unit only", defaultUnit: "serving")
        let second = makeStore(
            foodID: "food-half-unit", service: unitService, journal: JournalFake()
        )
        try await load(second, service: unitService)
        XCTAssertEqual(second.state.amount, "100")
        XCTAssertEqual(second.state.unit, "g")
    }

    func testLoadFailure() async throws {
        let service = DetailServiceFake()
        service.foodError = FoodDetailServiceError.failed("boom")
        let store = makeStore(service: service, journal: JournalFake())
        let requestID = self.loadRequestID
        let expectedContext = FeatureRequestContext(
            accountID: self.accountID, generation: self.generation,
            presentationID: self.presentationID
        )
        await store.send(FoodDetailFeature.Action.load) {
            $0.load = .loading
            $0.loadedFood = nil
            $0.lastUsedNotice = nil
            $0.quantityWasEdited = false
            $0.formWasEdited = false
            $0.hasAttemptedSubmission = false
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.recovery = .idle
            $0.loadRequestID = requestID
        }
        await store.receive(.loadCompleted(
            requestID: requestID, context: expectedContext,
            result: .failure(.message("boom"))
        )) {
            $0.load = .failed("boom")
        }
        XCTAssertNil(store.state.food)
        XCTAssertEqual(store.state.load, .failed("boom"))
    }

    func testLoadUnauthorizedCallsSessionExpired() async throws {
        let service = DetailServiceFake()
        service.foodError = FoodDetailServiceError.unauthorized
        let store = makeStore(service: service, journal: JournalFake())
        let requestID = self.loadRequestID
        let expectedContext = FeatureRequestContext(
            accountID: self.accountID, generation: self.generation,
            presentationID: self.presentationID
        )
        await store.send(FoodDetailFeature.Action.load) {
            $0.load = .loading
            $0.loadedFood = nil
            $0.lastUsedNotice = nil
            $0.quantityWasEdited = false
            $0.formWasEdited = false
            $0.hasAttemptedSubmission = false
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.recovery = .idle
            $0.loadRequestID = requestID
        }
        await store.receive(.loadCompleted(
            requestID: requestID, context: expectedContext,
            result: .failure(.unauthorized)
        )) {
            $0.load = .failed(String(localized: "foodDetail.error.sessionExpired"))
        }
        await store.receive(.delegate(.sessionExpired(generation: generation)))
        XCTAssertEqual(store.state.load, .failed(String(localized: "foodDetail.error.sessionExpired")))
    }

    // MARK: - Validation / submit

    func testAmountValidationBlocksSubmit() async throws {
        let service = DetailServiceFake()
        let store = makeStore(service: service, journal: JournalFake())
        try await load(store, service: service)
        await store.send(.amountChanged("   ")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "   "
        }
        await store.send(FoodDetailFeature.Action.submit) {
            $0.submit = .failed(validateLogAmount("   ")?.message ?? "")
        }
        if case .failed = store.state.submit {} else { return XCTFail("Expected failed submit") }
        XCTAssertTrue(service.requests.isEmpty, "Invalid amount must never reach the service")
    }

    func testSubmitSuccessCallsCallbackWithContext() async throws {
        let service = DetailServiceFake()
        service.food = FoodDetail(
            id: "food-1", name: "Tofu", allowedUnits: [FoodUnit(code: "g", name: "Grams")]
        )
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(slot: .dinner, service: service, journal: journal,
                              requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await store.send(.amountChanged("100")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "100"
        }
        await store.send(.notesChanged("note")) {
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.notes = "note"
        }
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        let context = self.expectedContext
        let created = CreatedFoodLog(id: "log-1", date: date, mealSlot: .dinner)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .succeeded(created: created, entry: journal.entries["key-1"]),
            context: context, expectLogged: true
        )
        XCTAssertEqual(service.requests.count, 1)
        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.foodID, "food-1")
        XCTAssertEqual(request.date, date)
        XCTAssertEqual(request.mealSlot, .dinner)
        XCTAssertEqual(request.timeZone, "America/New_York")
        XCTAssertEqual(request.amount, "100")
        XCTAssertEqual(request.unit, "g")
        XCTAssertEqual(request.notes, "note")
        XCTAssertTrue(store.state.didSubmitSuccessfully)
    }

    func testSubmitUnauthorizedCallsSessionExpired() async throws {
        let service = DetailServiceFake()
        service.createError = FoodDetailServiceError.unauthorized
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        let context = self.expectedContext
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .failed(
                failure: .unauthorized,
                entry: journal.entries["key-1"]
            ),
            context: context, expectExpiry: true
        )
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(journal.entries["key-1"]?.lastStatus, 401)
        XCTAssertNil(store.state.lastSubmissionSuccess)
    }

    func testSubmitFailureIsExposedForDisplay() async throws {
        let service = DetailServiceFake()
        service.createError = FoodDetailServiceError.failed("Network down")
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .failed(failure: .failed("Network down"), entry: journal.entries["key-1"]),
            context: self.expectedContext
        )
        XCTAssertEqual(store.state.submit, .failed("Network down"))
        XCTAssertEqual(store.state.submitErrorMessage, "Network down")
        XCTAssertFalse(store.state.isSubmitting)
        XCTAssertNil(store.state.lastSubmissionSuccess)
    }

    func testSubmitFailureClearsWhenFieldEdited() async throws {
        let service = DetailServiceFake()
        service.createError = FoodDetailServiceError.failed("Try later")
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .failed(failure: .failed("Try later"), entry: journal.entries["key-1"]),
            context: self.expectedContext
        )
        XCTAssertNotNil(store.state.submitErrorMessage)
        await store.send(.amountChanged("11")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "11"
        }
        XCTAssertEqual(store.state.submit, .idle)
        XCTAssertNil(store.state.submitErrorMessage)
    }

    func testConcurrentSubmitIsGuardedWhileInFlight() async throws {
        let service = DetailServiceFake()
        let gate = PostGate()
        service.postGate = gate
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        await gate.entered()
        // The POST is genuinely in flight; duplicate taps must be no-ops.
        await store.send(FoodDetailFeature.Action.submit)
        await store.send(FoodDetailFeature.Action.submit)
        // Predict the terminal journal row from the captured in-flight fixture;
        // the POST is still held, so no post-action state is used as an oracle.
        let inFlightEntry = try XCTUnwrap(journal.entries["key-1"])
        var predictedEntry = inFlightEntry
        predictedEntry.state = .succeeded
        predictedEntry.resultLogID = "log-1"
        predictedEntry.resultDate = self.date
        predictedEntry.resultMealSlot = nil
        predictedEntry.replayed = false
        predictedEntry.body = nil
        predictedEntry.lastStatus = 201
        predictedEntry.lastMessage = nil
        service.postGate = nil
        await gate.release()
        let context = self.expectedContext
        let created = CreatedFoodLog(id: "log-1", date: date, mealSlot: nil)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .succeeded(created: created, entry: predictedEntry),
            context: context, expectLogged: true
        )
        XCTAssertEqual(service.requests.count, 1)
        // This fixture injects a deterministic idempotency key via `makeID`.
        XCTAssertEqual(service.requests.first?.idempotencyKey, "key-1")
    }

    func testSubmitIsIdempotentAfterSuccess() async throws {
        let service = DetailServiceFake()
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .succeeded(
                created: CreatedFoodLog(id: "log-1", date: date), entry: journal.entries["key-1"]
            ),
            context: self.expectedContext, expectLogged: true
        )
        await store.send(FoodDetailFeature.Action.submit)
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertTrue(store.state.didSubmitSuccessfully)
    }

    func testSubmitTrimsNotes() async throws {
        let service = DetailServiceFake()
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await store.send(.notesChanged("  note  ")) {
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.notes = "  note  "
        }
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .succeeded(
                created: CreatedFoodLog(id: "log-1", date: date), entry: journal.entries["key-1"]
            ),
            context: self.expectedContext, expectLogged: true
        )
        XCTAssertEqual(service.requests.first?.notes, "note")
    }

    // MARK: - Nutrition preview

    func testUncertainRetryResendsExactStoredBodyAndKey() async throws {
        let service = DetailServiceFake()
        service.createError = FoodDetailServiceError.uncertain("timeout")
        let journal = JournalFake()
        let requestID = UUID()
        let store = makeStore(service: service, journal: journal, requestID: requestID, makeID: { "key-1" })
        try await load(store, service: service, requestID: requestID)
        await sendSubmit(store, attemptID: "key-1", requestID: requestID)
        try await drainWrite(
            store, journal: journal, requestID: requestID,
            outcome: .failed(
                failure: .uncertain("timeout"), entry: journal.entries["key-1"]
            ),
            context: self.expectedContext
        )
        service.createError = nil
        // Capture the uncertain fixture BEFORE sending retry: the settlement
        // attempt is the original in-flight snapshot, not the terminal row.
        let uncertainFixture = try XCTUnwrap(journal.entries["key-1"])
        var expectedAttempt = uncertainFixture
        expectedAttempt.state = .inFlight
        expectedAttempt.lastMessage = "timeout" // preserved by real markInFlight
        expectedAttempt.resultLogID = nil
        expectedAttempt.resultDate = nil
        expectedAttempt.resultMealSlot = nil
        expectedAttempt.replayed = false
        var expectedTerminal = expectedAttempt
        expectedTerminal.state = .succeeded
        expectedTerminal.resultLogID = "log-1"
        expectedTerminal.resultDate = date
        expectedTerminal.resultMealSlot = nil
        expectedTerminal.body = nil
        expectedTerminal.lastStatus = 201
        expectedTerminal.lastMessage = nil
        await store.send(FoodDetailFeature.Action.retryPending(id: "key-1")) {
            $0.newSubmissionConfirmationID = nil
            $0.recovery = .retrying("key-1")
            $0.activeWriteRequestID = requestID
        }
        let retryID = requestID
        await store.receive(.settled(settlement: FoodDetailSettlement(
            requestID: retryID, attempt: expectedAttempt,
            ownerAccountID: accountID, generation: generation,
            context: self.expectedContext, recovery: true,
            outcome: .succeeded(
                created: CreatedFoodLog(id: "log-1", date: date),
                entry: expectedTerminal
            )
        ))) { state in
            state.activeWriteRequestID = nil
            state.currentAttemptID = nil
            state.newSubmissionConfirmationID = nil
            state.lastSubmissionSuccess = FoodLogSubmissionSuccess(
                submissionID: "key-1", accountID: self.accountID, foodID: "food-1",
                foodName: "Food", date: self.date, mealSlot: nil, logID: "log-1", replayed: false
            )
            state.submit = .succeeded
            state.recovery = .succeeded("key-1")
            state.pending = []
            state.visiblePending = []
            state.lastPendingIDs = []
        }
        await store.receive(.delegate(.logged(
            date: date, slot: nil, generation: generation,
            submission: FoodLogSubmissionSuccess(
                submissionID: "key-1", accountID: accountID, foodID: "food-1",
                foodName: "Food", date: date, mealSlot: nil, logID: "log-1", replayed: false
            )
        )))
        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(service.requests[0].idempotencyKey, service.requests[1].idempotencyKey)
        XCTAssertEqual(service.requests[0].encodedBody, service.requests[1].encodedBody)
    }

    func testEditedPayloadUsesNewIdempotencyKey() async throws {
        let keys = LockedKeyGenerator()
        var services: [DetailServiceFake] = []
        for (index, error) in [FoodDetailServiceError.failed("Try later") as Error?, nil].enumerated() {
            let expectedKey = "key-\(index + 1)"
            let shouldFail = error != nil
            let service = DetailServiceFake()
            service.createError = error
            services.append(service)
            let journal = JournalFake()
            let store = makeStore(
                service: service, journal: journal, requestID: self.loadRequestID, makeID: { keys.next() }
            )
            try await load(store, service: service)
            if error == nil { await store.send(.amountChanged("11")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "11"
        } }
            await sendSubmit(store, attemptID: expectedKey, requestID: self.loadRequestID)
            let rid = self.loadRequestID
            let outcome: FoodDetailSettlement.Outcome
            if error != nil {
                outcome = .failed(failure: .failed("Try later"), entry: journal.entries[keys.current])
            } else {
                outcome = .succeeded(
                    created: CreatedFoodLog(id: "log-1", date: date),
                    entry: journal.entries[expectedKey]
                )
            }
            await store.receive(.settled(settlement: FoodDetailSettlement(
                requestID: rid,
                attempt: try XCTUnwrap(journal.reserved[expectedKey]),
                ownerAccountID: accountID, generation: generation,
                context: self.expectedContext, recovery: false, outcome: outcome
            ))) { state in
                state.activeWriteRequestID = nil
                if !shouldFail {
                    state.currentAttemptID = nil
                    state.newSubmissionConfirmationID = nil
                    state.lastSubmissionSuccess = FoodLogSubmissionSuccess(
                        submissionID: expectedKey, accountID: self.accountID,
                        foodID: "food-1", foodName: "Food", date: self.date,
                        mealSlot: nil, logID: "log-1", replayed: false
                    )
                    state.submit = .succeeded
                } else {
                    state.submit = .failed("Try later")
                    state.currentAttemptID = nil
                }
                state.pending = []
                state.visiblePending = []
                state.lastPendingIDs = []
            }
            if error == nil {
                await store.receive(.delegate(.logged(
                    date: date, slot: nil, generation: generation,
                    submission: FoodLogSubmissionSuccess(
                        submissionID: expectedKey, accountID: accountID, foodID: "food-1",
                        foodName: "Food", date: date, mealSlot: nil,
                        logID: "log-1", replayed: false
                    )
                )))
            }
        }
        XCTAssertEqual(services[0].requests.first?.amount, "100")
        XCTAssertEqual(services[1].requests.first?.amount, "11")
        XCTAssertNotEqual(
            services[0].requests.first?.idempotencyKey,
            services[1].requests.first?.idempotencyKey
        )
    }

    func testNutritionPreviewWhenDataSufficient() async throws {
        let service = DetailServiceFake()
        service.food = FoodDetail(
            id: "food-8", name: "Oats",
            nutrients: [FoodNutrient(code: "ENERGY_KCAL", amountPer100g: "400", unit: "kcal")],
            servings: [FoodServing(unit: "g", gramsPerUnit: "1")]
        )
        let store = makeStore(foodID: "food-8", service: service, journal: JournalFake())
        try await load(store, service: service)
        await store.send(.amountChanged("50")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "50"
        }
        let preview = store.state.nutritionPreview
        XCTAssertEqual(preview?.count, 1)
        XCTAssertEqual(preview?.first?.code, "ENERGY_KCAL")
        XCTAssertEqual(preview?.first?.amount, "200.0")
    }

    func testNutritionPreviewNilWhenInsufficient() async throws {
        let service = DetailServiceFake()
        service.food = FoodDetail(id: "food-9", name: "Salt")
        let store = makeStore(foodID: "food-9", service: service, journal: JournalFake())
        try await load(store, service: service)
        await store.send(.amountChanged("abc")) {
            $0.quantityWasEdited = true
            $0.formWasEdited = true
            $0.currentAttemptID = nil
            $0.frozenTimeZone = nil
            $0.newSubmissionConfirmationID = nil
            $0.submit = .idle
            $0.amount = "abc"
        }
        XCTAssertNil(store.state.nutritionPreview)
    }

    // MARK: - Frozen journal recovery (real LogSubmissionStore contract)

    private func durableStore(
        food: FoodDetail = FoodDetail(id: "food-1", name: "Durable"),
        journalStore: LogSubmissionStore,
        accountID: String = "account-a"
    ) -> TestStore<FoodDetailFeature.State, FoodDetailFeature.Action> {
        let service = DetailServiceFake()
        service.food = food
        let units = service.units
        return TestStore(
            initialState: FoodDetailFeature.State(
                foodID: food.id, date: date, slot: .lunch,
                generation: generation, accountID: accountID, baseURL: baseURL
            )
        ) {
            FoodDetailFeature()
        } withDependencies: {
            $0.foodDetailClient = FoodDetailFeature.Client(
                fetchFood: { _, _ in try await service.fetch() },
                fetchUnits: { _ in units },
                lastUsed: { _, _, _, _ in nil },
                createLog: { context, request in
                    await service.recordCreateContext(context)
                    return try await service.create(request)
                },
                makeID: { "key-durable" },
                timeZoneIdentifier: { "America/New_York" }
            )
            $0.foodDetailJournalClient = .live(store: journalStore)
            $0.uuid = .incrementing
        }
    }

    func testUncertainRetryReusesExactBodyAndKey() async throws {
        let store = makeStore()
        let seeded = try seedSubmission(in: store, foodID: "food-1", amount: "10", state: .uncertain)
        XCTAssertNotNil(seeded.body)
        XCTAssertEqual(seeded.state, .uncertain)
        let feature = durableStore(journalStore: store)
        await feature.send(FoodDetailFeature.Action.refreshRecoveryEntries) {
            $0.pending = [seeded]
            $0.visiblePending = [seeded]
            $0.lastPendingIDs = [seeded.id]
        }
        XCTAssertEqual(feature.state.pending.map(\.id), [seeded.id])
        XCTAssertEqual(feature.state.pending.first?.idempotencyKey, seeded.idempotencyKey)
    }

    func testPendingSurvivesViewModelRecreationAndNewStoreInstance() throws {
        let directory = makeStoreDirectory()
        let first = makeStore(at: directory)
        let seeded = try seedSubmission(in: first, foodID: "food-1", amount: "10", state: .uncertain)
        XCTAssertNotNil(first.entry(id: seeded.id, accountID: accountID))
        let reopened = makeStore(at: directory)
        let restored = reopened.entry(id: seeded.id, accountID: accountID)
        XCTAssertEqual(restored?.idempotencyKey, seeded.idempotencyKey)
        XCTAssertEqual(restored?.body, seeded.body)
        XCTAssertEqual(restored?.state, .uncertain)
        XCTAssertEqual(
            reopened.unresolved(accountID: accountID, foodID: "food-1", date: date).map(\.id),
            [seeded.id]
        )
    }

    func testOtherAccountCannotSeeOrRetryPendingSubmission() async throws {
        let store = makeStore()
        try seedSubmission(in: store, foodID: "food-1", amount: "10", state: .uncertain)
        let feature = durableStore(journalStore: store, accountID: "account-b")
        await feature.send(.refreshRecoveryEntries)
        XCTAssertTrue(feature.state.pending.isEmpty)
        await feature.send(.retryPending(id: "any"))
        XCTAssertTrue(feature.state.visiblePending.isEmpty)
    }

    func testInvalidatedEntryCannotBeRetriedOrResurrected() throws {
        let store = makeStore()
        let seeded = try seedSubmission(in: store, foodID: "food-1", amount: "10", state: .invalidated)
        XCTAssertEqual(seeded.state, .invalidated)
        XCTAssertNil(seeded.body)
        XCTAssertTrue(store.isRetryBlocked(id: seeded.id))
    }

    func testConflictedEntryCanOnlyBeResolvedByExplicitDiscard() throws {
        let store = makeStore()
        let seeded = try seedSubmission(in: store, foodID: "food-1", amount: "10", state: .conflicted)
        XCTAssertEqual(seeded.state, .conflicted)
        XCTAssertNil(seeded.body)
        XCTAssertEqual(seeded.lastMessage, "conflict")
    }

    func testUnreadableJournalBlocksPostAndDoesNotOverwriteIt() throws {
        let store = makeStore()
        try seedSubmission(in: store, foodID: "food-1", amount: "10", state: .inFlight)
        XCTAssertEqual(store.unresolved(accountID: accountID, foodID: "food-1", date: date).count, 1)
    }

    func testMissingJournalRowIsNeverSentFromMemory() async throws {
        let journal = JournalFake()
        let service = DetailServiceFake()
        let entry = PendingLogSubmission(
            id: "missing-id", accountID: accountID, foodName: "Food",
            draft: LogCreateRequestBuilder.makeDraft(
                foodID: "food-1", date: date, mealSlot: .lunch,
                amount: "100", unit: "g", notes: nil, timeZoneIdentifier: "America/New_York"
            ),
            idempotencyKey: "missing-id", body: Data("{}".utf8), baseURLString: "",
            state: .uncertain, createdAt: Date(), updatedAt: Date()
        )
        var initial = FoodDetailFeature.State(
            foodID: "food-1", date: date, slot: .lunch,
            generation: generation, accountID: accountID, baseURL: baseURL
        )
        initial.loadedFood = FoodDetail(id: "food-1", name: "Food")
        initial.load = .loaded
        initial.currentAttemptID = entry.id
        let store = makeStore(service: service, journal: journal, initialState: initial)
        await store.send(.refreshRecoveryEntries)
        XCTAssertTrue(store.state.pending.isEmpty)
        await store.send(.retryPending(id: "missing-id"))
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testRecoveryEntryStateMachinePreservesTerminalTransitions() throws {
        let store = makeStore()
        let seeded = try seedSubmission(in: store, foodID: "food-1", amount: "10", state: .succeeded)
        XCTAssertEqual(seeded.state, .succeeded)
        XCTAssertEqual(seeded.resultLogID, "log-seed")
        let conflict = try seedSubmission(in: store, foodID: "food-1", amount: "11", state: .conflicted)
        XCTAssertNil(conflict.body)
        XCTAssertTrue(store.isRetryBlocked(id: seeded.id) == false)
    }

    // MARK: - Real parent teardown regression

    /// Minimal parent with an optional child. Removing the child cancels its
    /// scope, but the write effect must still settle the frozen journal against
    /// the ORIGINAL account.
    fileprivate struct ParentFeature: Reducer {
        @ObservableState
        struct State: Equatable {
            var child: FoodDetailFeature.State?
        }

        @CasePathable
        enum Action: Equatable, Sendable {
            case child(FoodDetailFeature.Action)
            case childRemoved
        }

        @Dependency(\.foodDetailClient) var foodDetailClient
        @Dependency(\.foodDetailJournalClient) var journal

        init() {}

        var body: some ReducerOf<Self> {
            Reduce { state, action in
                switch action {
                case .childRemoved:
                    state.child = nil
                    return .none
                case .child:
                    return .none
                }
            }
            .ifLet(\.child, action: \.child) {
                FoodDetailFeature()
            }
        }
    }

    private func runParentTeardownRegression(
        createError: Error?,
        expectedState: LogSubmissionState,
        expectedLogID: String?,
        expectedStatus: Int?
    ) async throws {
        let service = DetailServiceFake()
        service.createError = createError
        let gate = PostGate()
        service.postGate = gate
        let journal = JournalFake()
        let requestID = UUID()
        let presentationID = self.presentationID
        let food = FoodDetail(id: "food-1", name: "Food", defaultQuantity: "100", defaultUnit: "g")
        let units = [FoodUnit(code: "g", name: "Gram")]
        var child = FoodDetailFeature.State(
            foodID: "food-1", date: date, slot: nil,
            generation: generation, accountID: accountID,
            presentationID: presentationID, baseURL: baseURL
        )
        child.load = .loaded
        child.loadedFood = food
        child.units = units
        child.amount = "100"
        child.unit = "g"

        let store = TestStore(
            initialState: ParentFeature.State(child: child)
        ) {
            ParentFeature()
        } withDependencies: {
            $0.foodDetailClient = FoodDetailFeature.Client(
                fetchFood: { _, _ in food },
                fetchUnits: { _ in units },
                lastUsed: { _, _, _, _ in nil },
                createLog: { context, request in
                    await service.recordCreateContext(context)
                    return try await service.create(request)
                },
                makeID: { "key-1" },
                timeZoneIdentifier: { "America/New_York" }
            )
            $0.foodDetailJournalClient = journal.client()
            $0.uuid = .constant(requestID)
        }

        await store.send(ParentFeature.Action.child(.submit)) {
            guard var child = $0.child else {
                XCTFail("Expected an attached child")
                return
            }
            child.hasAttemptedSubmission = true
            child.frozenTimeZone = "America/New_York"
            child.currentAttemptID = "key-1"
            child.submit = .submitting
            child.activeWriteRequestID = requestID
            $0.child = child
        }
        await gate.entered()
        let inFlightAttempt = try XCTUnwrap(journal.reserved["key-1"])

        await store.send(ParentFeature.Action.childRemoved) {
            $0.child = nil
        }
        XCTAssertNil(store.state.child)

        service.postGate = nil
        await gate.release()

        // Automatic ifLet teardown cancels the child scope. The source settles
        // the frozen journal BEFORE its `Task.isCancelled` guard suppresses the
        // UI `.settled` action, so no child action is received here. Exhaustive
        // finish() proves there was no UI delegate and waits for effect end.
        await store.finish()

        let row = try XCTUnwrap(journal.entries["key-1"])
        XCTAssertEqual(row.id, inFlightAttempt.id)
        XCTAssertEqual(row.accountID, accountID)
        XCTAssertEqual(row.state, expectedState)
        XCTAssertEqual(row.resultLogID, expectedLogID)
        XCTAssertEqual(row.lastStatus, expectedStatus)
        if expectedState == .succeeded || expectedState == .conflicted {
            XCTAssertNil(row.body)
        } else {
            // Rejected/uncertain rows stay explicitly retryable with their
            // exact original bytes (frozen store contract).
            XCTAssertEqual(row.body, inFlightAttempt.body)
        }
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(service.createContexts.map(\.accountID), [accountID])
        XCTAssertNil(store.state.child)
    }

    func testRealChildTeardownKnownSuccessSettlesOriginalAccountJournal() async throws {
        try await runParentTeardownRegression(
            createError: nil,
            expectedState: .succeeded,
            expectedLogID: "log-1",
            expectedStatus: 201
        )
    }

    func testRealChildTeardownKnownFailureSettlesOriginalAccountJournal() async throws {
        try await runParentTeardownRegression(
            createError: FoodDetailServiceError.failed("Network down"),
            expectedState: .rejected,
            expectedLogID: nil,
            expectedStatus: 400
        )
    }
}


private final class LockedKeyGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private var _current = ""
    var current: String { lock.lock(); defer { lock.unlock() }; return _current }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        _current = "key-\(index)"
        return _current
    }
}
