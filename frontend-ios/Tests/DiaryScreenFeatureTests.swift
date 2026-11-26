import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryScreenFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let generation: UInt64 = 42

    // MARK: - Fixtures

    private nonisolated func makeDay(_ day: LocalDiaryDate, calories: Double = 100) -> DiaryDay {
        DiaryDay(
            date: day,
            logs: [DiaryLog(id: "log-\(day.formatted)", title: "Lunch", calories: calories)],
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    private nonisolated func makeFoodLog(_ day: LocalDiaryDate, id: String = "food-log-1") -> FoodLog {
        FoodLog(
            id: id,
            logDate: day,
            mealSlot: .dinner,
            item: .product(ProductLogItemSnapshot(id: "product-1", name: "Yogurt")),
            quantity: NutritionQuantity(amount: "100", unit: "g"),
            nutrients: [],
            notes: "copied"
        )
    }

    private nonisolated func makeReview(_ day: LocalDiaryDate) -> DiaryLatestReview {
        DiaryLatestReview(
            destinationDate: day,
            destinationSlot: .dinner,
            sourceDate: day.addingDays(-1),
            items: [
                DiaryLog(
                    id: "latest-log",
                    title: "Oats",
                    quantity: NutritionQuantity(amount: "60", unit: "g"),
                    logItem: .product(id: "food-1")
                )
            ]
        )
    }

    private nonisolated func latestCacheIsNotRequested(
        _ cache: DiaryLatestFeature.Cache,
        at day: LocalDiaryDate
    ) -> Bool {
        if case .notRequested = cache.entry(for: day) { return true }
        return false
    }

    private nonisolated func latestCacheIsSettledSuccess(
        _ cache: DiaryLatestFeature.Cache,
        at day: LocalDiaryDate
    ) -> Bool {
        if case .settled(.success) = cache.entry(for: day) { return true }
        return false
    }

    // MARK: - Controlled latest read (accepted DiaryLatestFeatureTests harness)

    private final class ControlledLatestClient: @unchecked Sendable {
        struct Request: Sendable {
            let id: Int
            private let resumeHandler: @Sendable (Result<[DiaryLatestSlot], Error>) -> Void
            private let waitHandler: @Sendable () async -> Void

            init(
                id: Int,
                resumeHandler: @escaping @Sendable (Result<[DiaryLatestSlot], Error>) -> Void,
                waitHandler: @escaping @Sendable () async -> Void
            ) {
                self.id = id
                self.resumeHandler = resumeHandler
                self.waitHandler = waitHandler
            }

            func waitUntilCancelled() async {
                await waitHandler()
            }
        }

        private struct RequestState {
            var continuation: CheckedContinuation<[DiaryLatestSlot], Error>?
            var cancelWaiter: CheckedContinuation<Void, Never>?
            var isCancelled = false
        }

        private let lock = NSLock()
        private var states: [Int: RequestState] = [:]
        private var nextID = 0
        private let startContinuation: AsyncStream<Request>.Continuation
        let starts: AsyncStream<Request>

        init() {
            var continuation: AsyncStream<Request>.Continuation?
            self.starts = AsyncStream<Request> { continuation = $0 }
            self.startContinuation = continuation!
        }

        func latestSlots(before: LocalDiaryDate, lookbackDays: Int) async throws -> [DiaryLatestSlot] {
            let id = allocateID()
            let request = Request(
                id: id,
                resumeHandler: { [weak self] result in
                    self?.resume(id: id, result: result)
                },
                waitHandler: { [weak self] in
                    await self?.waitUntilCancelled(id: id)
                }
            )

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    enqueueStart(id: id, request: request, continuation: continuation)
                }
            } onCancel: {
                handleCancel(id: id)
            }
        }

        func finish() {
            startContinuation.finish()
        }

        private func allocateID() -> Int {
            lock.lock()
            let id = nextID
            nextID += 1
            lock.unlock()
            return id
        }

        private func enqueueStart(
            id: Int,
            request: Request,
            continuation: CheckedContinuation<[DiaryLatestSlot], Error>
        ) {
            lock.lock()
            var state = states[id, default: RequestState()]
            if state.isCancelled {
                states[id] = state
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                startContinuation.yield(request)
                return
            }
            state.continuation = continuation
            states[id] = state
            lock.unlock()
            startContinuation.yield(request)
        }

        private func handleCancel(id: Int) {
            lock.lock()
            var state = states[id, default: RequestState()]
            state.isCancelled = true
            let continuation = state.continuation
            let cancelWaiter = state.cancelWaiter
            state.continuation = nil
            state.cancelWaiter = nil
            states[id] = state
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
            cancelWaiter?.resume()
        }

        private func resume(id: Int, result: Result<[DiaryLatestSlot], Error>) {
            lock.lock()
            var state = states[id, default: RequestState()]
            let continuation = state.continuation
            state.continuation = nil
            states[id] = state
            lock.unlock()
            continuation?.resume(with: result)
        }

        private func waitUntilCancelled(id: Int) async {
            if isCancelled(id: id) { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                registerCancelWaiter(id: id, continuation: continuation)
            }
        }

        private func isCancelled(id: Int) -> Bool {
            lock.lock()
            let cancelled = states[id, default: RequestState()].isCancelled
            lock.unlock()
            return cancelled
        }

        private func registerCancelWaiter(id: Int, continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            var state = states[id, default: RequestState()]
            if state.isCancelled {
                lock.unlock()
                continuation.resume()
                return
            }
            state.cancelWaiter = continuation
            states[id] = state
            lock.unlock()
        }
    }

    // MARK: - Controlled submission (accepted DiaryLatestFeatureTests harness)

    private final class ControlledSubmissionClient {
        struct Request: Sendable {
            let id: UUID
            let resume: @Sendable (LogSubmissionServiceResult) -> Void
        }

        private let lock = NSLock()
        private let startContinuation: AsyncStream<Request>.Continuation
        let starts: AsyncStream<Request>
        private(set) var invocationCount = 0

        init() {
            var continuation: AsyncStream<Request>.Continuation?
            self.starts = AsyncStream<Request> { continuation = $0 }
            self.startContinuation = continuation!
        }

        func submit(
            drafts: [LogSubmissionDraft],
            names: [String],
            summary: String,
            expectedGeneration: UInt64
        ) async -> LogSubmissionServiceResult {
            lock.lock()
            invocationCount += 1
            let id = UUID()
            lock.unlock()
            return await withCheckedContinuation { continuation in
                startContinuation.yield(
                    Request(
                        id: id,
                        resume: { result in continuation.resume(returning: result) }
                    )
                )
            }
        }

        func resume(_ request: Request, result: LogSubmissionServiceResult) {
            request.resume(result)
        }

        func finish() {
            startContinuation.finish()
        }
    }

    // MARK: - Expiry

    func testExpiryFromDiaryForwardsOnceAndBothChildrenExpire() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let expectedDiaryCache = state.diary.cache.reset()
        let expectedLatestCache = state.latest.cache.reset()
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.diary(.delegate(.sessionExpired(selectedDate: date, generation: generation)))) {
            $0.sessionExpiryForwarded = generation
        }
        await store.receive(.diary(.expireSession)) {
            $0.diary.cache = expectedDiaryCache
            $0.diary.phase = .sessionExpired(requestDate: date)
        }
        await store.receive(.latest(.expireSession)) {
            $0.latest.cache = expectedLatestCache
            $0.latest.phase = .sessionExpired(destinationDate: date)
        }
        await store.receive(.delegate(.sessionExpired(selectedDate: date, generation: generation)))

        XCTAssertTrue(store.state.diary.isSessionExpired)
        XCTAssertTrue(store.state.latest.isSessionExpired)

        await store.send(.latest(.delegate(.sessionExpired(destinationDate: date, generation: generation))))
        XCTAssertEqual(store.state.sessionExpiryForwarded, generation)
    }

    func testExpiryStaleGenerationIsIgnored() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.diary(.delegate(.sessionExpired(selectedDate: date, generation: generation - 1))))
        XCTAssertEqual(store.state.sessionExpiryForwarded, nil)
        XCTAssertFalse(store.state.diary.isSessionExpired)
        XCTAssertFalse(store.state.latest.isSessionExpired)
    }

    func testDirectExpireSessionIsIdempotentAndDoesNotBumpCacheGeneration() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let diaryCache = DiaryFeature.Cache().reset()
        let latestCache = DiaryLatestFeature.Cache().reset()
        let diaryGeneration = diaryCache.generation
        let latestGeneration = latestCache.generation
        let expectedDiaryGeneration = diaryGeneration + 1
        let expectedLatestGeneration = latestGeneration + 1

        let state = DiaryScreenFeature.State(
            date: date,
            today: today,
            sessionGeneration: generation,
            diaryCache: diaryCache,
            latestCache: latestCache
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.diary(.expireSession)) {
            $0.diary.cache = $0.diary.cache.reset()
            $0.diary.phase = .sessionExpired(requestDate: date)
        }
        await store.send(.latest(.expireSession)) {
            $0.latest.cache = $0.latest.cache.reset()
            $0.latest.phase = .sessionExpired(destinationDate: date)
        }
        await store.send(.diary(.expireSession))
        await store.send(.latest(.expireSession))

        XCTAssertEqual(store.state.diary.cache.generation, expectedDiaryGeneration)
        XCTAssertEqual(store.state.latest.cache.generation, expectedLatestGeneration)
        XCTAssertTrue(store.state.diary.isSessionExpired)
        XCTAssertTrue(store.state.latest.isSessionExpired)
    }

    // MARK: - Navigation delegates

    func testNavigationDelegatesForwardPayloads() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let slot = MealSlot.breakfast
        let state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.diary(.delegate(.addFood(slot: slot, date: date, generation: generation))))
        await store.receive(.delegate(.addFood(slot: slot, date: date, generation: generation)))

        await store.send(.diary(.delegate(.openLogEditor(id: "log-1", date: date, generation: generation))))
        await store.receive(.delegate(.openLogEditor(id: "log-1", date: date, generation: generation)))

        await store.send(.diary(.delegate(.openMeals(date: date, generation: generation))))
        await store.receive(.delegate(.openMeals(date: date, generation: generation)))
    }

    func testNavigationDelegatesRejectedWhenStaleOrExpired() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        var state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        state.diary = DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: date),
            sessionGeneration: generation
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.diary(.delegate(.addFood(slot: .breakfast, date: date, generation: generation))))
        await store.send(.diary(.delegate(.addFood(slot: .breakfast, date: date, generation: generation - 1))))
        await store.send(.diary(.delegate(.openMeals(date: date, generation: generation))))
    }

    // MARK: - Context synchronization

    func testChildSelectedDateSyncsLatestContext() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let day = makeDay(otherDate)

        let diaryCache = DiaryFeature.Cache()
        let (expectedInFlight, diaryToken) = diaryCache.request(otherDate)!
        let expectedSettled = expectedInFlight.settling(
            otherDate,
            token: diaryToken,
            result: .success(day)
        )!
        let state = DiaryScreenFeature.State(
            date: date,
            today: today,
            sessionGeneration: generation,
            diaryCache: diaryCache
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in day }
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in [] }
        }

        await store.send(.diary(.selectDate(otherDate))) {
            $0.diary.phase = .initialLoading(requestDate: otherDate, token: diaryToken)
            $0.diary.cache = expectedInFlight
        }
        await store.receive(.latest(.contextChanged(date: otherDate, today: today))) {
            $0.latest.destinationDate = otherDate
            $0.latest.phase = .idle(destinationDate: otherDate)
        }
        await store.receive(.diary(.diaryReceived(
            generation: generation,
            requestDate: otherDate,
            token: diaryToken,
            day: day
        ))) {
            $0.diary.completedFetchCount += 1
            $0.diary.cache = expectedSettled
            $0.diary.phase = .loaded(day: day, activity: .settled)
        }

        XCTAssertEqual(store.state.selectedDate, otherDate)
        XCTAssertEqual(store.state.latest.destinationDate, otherDate)
    }

    func testTodayOnlySameContextRetainsLatestReview() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let day = makeDay(date)
        let review = makeReview(date)

        var state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        state.diary = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: DiaryFeature.Cache()
        )
        state.latest = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .loaded(destinationDate: date, slots: [], loadedForDate: date, activity: .settled),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in day }
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in [] }
        }

        await store.send(.diary(.foregroundRefresh(newToday: today)))
        XCTAssertEqual(store.state.latest.review, review)
        XCTAssertEqual(store.state.latest.destinationDate, date)
    }

    func testForegroundRefreshSyncsDerivedSelectedDate() async {
        let today = self.today
        let generation = self.generation
        let newToday = today.addingDays(1)
        let day = makeDay(today)
        let newDay = makeDay(newToday)

        let diaryCache = DiaryFeature.Cache()
        let (expectedInFlight, token) = diaryCache.request(newToday)!
        let expectedSettled = expectedInFlight.settling(
            newToday,
            token: token,
            result: .success(newDay)
        )!
        var state = DiaryScreenFeature.State(
            date: today,
            today: today,
            sessionGeneration: generation,
            diaryCache: diaryCache
        )
        state.diary = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: diaryCache
        )
        state.latest = DiaryLatestFeature.State(
            destinationDate: today,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: today)
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in newDay }
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in [] }
        }

        await store.send(.diary(.foregroundRefresh(newToday: newToday))) {
            $0.diary.today = newToday
            $0.diary.mutationNotice = nil
            $0.diary.phase = .initialLoading(requestDate: newToday, token: token)
            $0.diary.cache = expectedInFlight
        }
        await store.receive(.latest(.contextChanged(date: newToday, today: newToday))) {
            $0.latest.destinationDate = newToday
            $0.latest.today = newToday
            $0.latest.phase = .idle(destinationDate: newToday)
        }
        await store.receive(.diary(.diaryReceived(
            generation: generation,
            requestDate: newToday,
            token: token,
            day: newDay
        ))) {
            $0.diary.completedFetchCount += 1
            $0.diary.cache = expectedSettled
            $0.diary.phase = .loaded(day: newDay, activity: .settled)
        }

        XCTAssertEqual(store.state.selectedDate, newToday)
        XCTAssertEqual(store.state.latest.destinationDate, newToday)
    }

    func testContextChangePreservesFailedCopyReview() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let review = makeReview(date)
        let requestID = UUID()
        let copyRequest = DiaryLatestFeature.CopyRequest(
            requestID: requestID,
            sessionGeneration: generation,
            destinationDate: date,
            destinationSlot: .dinner,
            review: review,
            timeZone: "UTC",
            drafts: review.makeDrafts(timeZone: "UTC")!
        )

        var state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        state.latest = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review,
            copyRequest: copyRequest,
            isSubmitting: false,
            copyErrorMessage: "boom",
            copySucceeded: false
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.latest(.contextChanged(date: otherDate, today: today))) {
            $0.latest.destinationDate = otherDate
            $0.latest.phase = .idle(destinationDate: otherDate)
        }
        XCTAssertEqual(store.state.latest.review, review)
        XCTAssertEqual(store.state.latest.copyRequest, copyRequest)
    }

    // MARK: - Copy reconciliation

    func testCopiedAppliesValidLogsAndForwardsOriginalPayload() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let valid1 = makeFoodLog(date, id: "valid-1")
        let valid2 = makeFoodLog(date, id: "valid-2")
        let wrongDateLog = makeFoodLog(otherDate, id: "wrong-date")
        let originalLogs = [valid1, valid2, wrongDateLog]
        let requestID = UUID()

        let state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.latest(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: originalLogs
        )))) {
            $0.copiedRequestIDs = [requestID]
        }
        await store.receive(.diary(.applySavedLog(
            generation: generation,
            log: CalCoStoreMapping.diaryLog(from: valid1),
            replacingID: valid1.id,
            onDate: date
        ))) {
            $0.diary.savedLogOverrides[date] = [valid1.id: CalCoStoreMapping.diaryLog(from: valid1)]
        }
        await store.receive(.diary(.applySavedLog(
            generation: generation,
            log: CalCoStoreMapping.diaryLog(from: valid2),
            replacingID: valid2.id,
            onDate: date
        ))) {
            $0.diary.savedLogOverrides[date]?[valid2.id] = CalCoStoreMapping.diaryLog(from: valid2)
        }
        await store.receive(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: originalLogs
        )))

        XCTAssertNotNil(store.state.diary.savedLogOverrides[date]?["valid-1"])
        XCTAssertNotNil(store.state.diary.savedLogOverrides[date]?["valid-2"])
        XCTAssertNil(store.state.diary.savedLogOverrides[date]?["wrong-date"])
    }

    func testCopiedDedupsRequestID() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let validLog = makeFoodLog(date, id: "valid-log")
        let requestID = UUID()

        let state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.latest(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: [validLog]
        )))) {
            $0.copiedRequestIDs = [requestID]
        }
        await store.receive(.diary(.applySavedLog(
            generation: generation,
            log: CalCoStoreMapping.diaryLog(from: validLog),
            replacingID: validLog.id,
            onDate: date
        ))) {
            $0.diary.savedLogOverrides[date] = [validLog.id: CalCoStoreMapping.diaryLog(from: validLog)]
        }
        await store.receive(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: [validLog]
        )))

        await store.send(.latest(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: [validLog]
        ))))
        XCTAssertEqual(store.state.copiedRequestIDs.count, 1)
    }

    func testCopiedStaleGenerationIsIgnored() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let validLog = makeFoodLog(date, id: "valid-log")
        let requestID = UUID()

        let state = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.latest(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation - 1,
            logs: [validLog]
        ))))
        XCTAssertEqual(store.state.copiedRequestIDs.count, 0)
    }

    func testCopiedAllowedForNewGenerationAfterOldExpiryLatch() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let validLog = makeFoodLog(date, id: "valid-log")
        let requestID = UUID()

        let state = DiaryScreenFeature.State(
            date: date,
            today: today,
            sessionGeneration: generation + 1,
            sessionExpiryForwarded: generation
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        }

        await store.send(.latest(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation + 1,
            logs: [validLog]
        )))) {
            $0.copiedRequestIDs = [requestID]
        }
        await store.receive(.diary(.applySavedLog(
            generation: generation + 1,
            log: CalCoStoreMapping.diaryLog(from: validLog),
            replacingID: validLog.id,
            onDate: date
        ))) {
            $0.diary.savedLogOverrides[date] = [validLog.id: CalCoStoreMapping.diaryLog(from: validLog)]
        }
        await store.receive(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation + 1,
            logs: [validLog]
        )))
    }

    // MARK: - Real in-flight copy across a real parent date change

    func testActiveCopySurvivesRealSelectDate() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let review = makeReview(date)
        let requestID = UUID()
        // Derive the immutable expectation from the exact dependency value the
        // reducer reads; Foundation may normalize "UTC" to "GMT".
        let injectedTimeZone = TimeZone(identifier: "UTC")!
        let timeZone = injectedTimeZone.identifier
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!
        let expectedCopyRequest = DiaryLatestFeature.CopyRequest(
            requestID: requestID,
            sessionGeneration: generation,
            destinationDate: date,
            destinationSlot: .dinner,
            review: review,
            timeZone: timeZone,
            drafts: expectedDrafts
        )
        let submittedLog = makeFoodLog(date, id: "submitted-log")
        let otherDay = makeDay(otherDate)

        let diaryCache = DiaryFeature.Cache()
        let (expectedDiaryInFlight, diaryToken) = diaryCache.request(otherDate)!
        let expectedDiarySettled = expectedDiaryInFlight.settling(
            otherDate,
            token: diaryToken,
            result: .success(otherDay)
        )!

        var state = DiaryScreenFeature.State(
            date: date,
            today: today,
            sessionGeneration: generation,
            diaryCache: diaryCache
        )
        state.latest = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )

        let controlled = ControlledSubmissionClient()
        var starts = controlled.starts.makeAsyncIterator()

        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in otherDay }
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in [] }
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { drafts, _, _, _ in
                await controlled.submit(
                    drafts: drafts,
                    names: [],
                    summary: "",
                    expectedGeneration: generation
                )
            }
            $0.uuid = .constant(requestID)
            $0.timeZone = injectedTimeZone
        }

        await store.send(.latest(.submitLatest)) {
            $0.latest.copyRequest = expectedCopyRequest
            $0.latest.isSubmitting = true
            $0.latest.copyErrorMessage = nil
            $0.latest.copySucceeded = false
        }
        guard let submission = await starts.next() else {
            XCTFail("Expected submission start")
            controlled.finish()
            return
        }
        XCTAssertEqual(controlled.invocationCount, 1)

        await store.send(.diary(.selectDate(otherDate))) {
            $0.diary.mutationNotice = nil
            $0.diary.phase = .initialLoading(requestDate: otherDate, token: diaryToken)
            $0.diary.cache = expectedDiaryInFlight
        }
        await store.receive(.latest(.contextChanged(date: otherDate, today: today))) {
            $0.latest.destinationDate = otherDate
            $0.latest.phase = .idle(destinationDate: otherDate)
        }
        await store.receive(.diary(.diaryReceived(
            generation: generation,
            requestDate: otherDate,
            token: diaryToken,
            day: otherDay
        ))) {
            $0.diary.completedFetchCount += 1
            $0.diary.cache = expectedDiarySettled
            $0.diary.phase = .loaded(day: otherDay, activity: .settled)
        }
        XCTAssertTrue(store.state.latest.isSubmitting)
        XCTAssertEqual(store.state.latest.copyRequest, expectedCopyRequest)

        controlled.resume(submission, result: .success([submittedLog]))
        await store.receive(.latest(.submitCompleted(
            requestID: requestID,
            generation: generation,
            result: .success([submittedLog])
        ))) {
            $0.latest.isSubmitting = false
            $0.latest.cache = $0.latest.cache.clearAll()
            $0.latest.review = nil
            $0.latest.copyRequest = nil
            $0.latest.copyErrorMessage = nil
            $0.latest.copySucceeded = true
            $0.latest.errorMessage = nil
        }
        await store.receive(.latest(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: [submittedLog]
        )))) {
            $0.copiedRequestIDs = [requestID]
        }
        await store.receive(.diary(.applySavedLog(
            generation: generation,
            log: CalCoStoreMapping.diaryLog(from: submittedLog),
            replacingID: submittedLog.id,
            onDate: date
        ))) {
            $0.diary.savedLogOverrides[date] = [submittedLog.id: CalCoStoreMapping.diaryLog(from: submittedLog)]
        }
        await store.receive(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: [submittedLog]
        )))

        XCTAssertEqual(store.state.selectedDate, otherDate)
        XCTAssertEqual(store.state.diary.visibleDay?.date, otherDate)
        XCTAssertNotNil(store.state.diary.savedLogOverrides[date]?["submitted-log"])
        XCTAssertNil(store.state.diary.savedLogOverrides[otherDate]?["submitted-log"])
        controlled.finish()
    }

    // MARK: - Real latest read cancellation and token isolation

    func testControlledLatestReadCancellationAndOldTokenRejection() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let controlled = ControlledLatestClient()
        var starts = controlled.starts.makeAsyncIterator()

        var latestBase = DiaryLatestFeature.Cache()
        latestBase = latestBase.seed(otherDate, value: [])
        let (expectedInFlight, initialToken) = latestBase.request(date)!
        let expectedAfterCancel = expectedInFlight.invalidate(date)

        let state = DiaryScreenFeature.State(
            date: date,
            today: today,
            sessionGeneration: generation,
            latestCache: latestBase
        )
        let store = TestStore(initialState: state) {
            DiaryScreenFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { before, _, _ in
                try await controlled.latestSlots(
                    before: before,
                    lookbackDays: DiaryLatestFeature.lookbackDays
                )
            }
        }

        await store.send(.latest(.load)) {
            $0.latest.phase = .loading(destinationDate: date, slot: nil, token: initialToken)
            $0.latest.cache = expectedInFlight
        }
        guard let request = await starts.next() else {
            XCTFail("Expected latest request start")
            controlled.finish()
            return
        }
        XCTAssertEqual(request.id, 0)

        await store.send(.latest(.contextChanged(date: otherDate, today: today))) {
            $0.latest.destinationDate = otherDate
            $0.latest.phase = .loaded(
                destinationDate: otherDate,
                slots: [],
                loadedForDate: otherDate,
                activity: .settled
            )
            $0.latest.cache = expectedAfterCancel
        }
        await request.waitUntilCancelled()

        XCTAssertTrue(latestCacheIsNotRequested(store.state.latest.cache, at: date))
        XCTAssertTrue(latestCacheIsSettledSuccess(store.state.latest.cache, at: otherDate))
        XCTAssertEqual(store.state.latest.cache.entry(for: otherDate), latestBase.entry(for: otherDate))
        XCTAssertNil(
            expectedAfterCancel.settling(
                date,
                token: initialToken,
                result: .success([])
            )
        )

        await store.send(.latest(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: nil,
            token: initialToken,
            result: .success([])
        )))
        XCTAssertEqual(store.state.latest.destinationDate, otherDate)
        XCTAssertTrue(latestCacheIsSettledSuccess(store.state.latest.cache, at: otherDate))
        controlled.finish()
    }
}

// Test-local harness: both children emit session-expiry delegates from one
// source action so their reductions race before either parent effect runs.
private struct QueuedExpiryHarness: Reducer {
    @CasePathable
    enum Action: Equatable, Sendable {
        case screen(DiaryScreenFeature.Action)
        case fireBoth(selectedDate: LocalDiaryDate, generation: UInt64)
    }

    struct State: Equatable {
        var screen: DiaryScreenFeature.State
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.screen, action: \.screen) {
            DiaryScreenFeature()
        }
        Reduce { _, action in
            guard case let .fireBoth(selectedDate, generation) = action else { return .none }
            return .merge(
                .send(.screen(.diary(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation
                ))))),
                .send(.screen(.latest(.delegate(.sessionExpired(
                    destinationDate: selectedDate,
                    generation: generation
                )))))
            )
        }
    }
}

@MainActor
extension DiaryScreenFeatureTests {
    func testQueuedBothOriginsForwardOneDelegate() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let screenState = DiaryScreenFeature.State(date: date, today: today, sessionGeneration: generation)
        let expectedDiaryCache = screenState.diary.cache.reset()
        let expectedLatestCache = screenState.latest.cache.reset()
        let store = TestStore(
            initialState: QueuedExpiryHarness.State(screen: screenState)
        ) {
            QueuedExpiryHarness()
        }

        await store.send(.fireBoth(selectedDate: date, generation: generation))
        await store.receive(.screen(.diary(.delegate(.sessionExpired(
            selectedDate: date,
            generation: generation
        ))))) {
            $0.screen.sessionExpiryForwarded = generation
        }
        await store.receive(.screen(.latest(.delegate(.sessionExpired(
            destinationDate: date,
            generation: generation
        )))))
        await store.receive(.screen(.diary(.expireSession))) {
            $0.screen.diary.cache = expectedDiaryCache
            $0.screen.diary.phase = .sessionExpired(requestDate: date)
        }
        await store.receive(.screen(.latest(.expireSession))) {
            $0.screen.latest.cache = expectedLatestCache
            $0.screen.latest.phase = .sessionExpired(destinationDate: date)
        }
        await store.receive(.screen(.delegate(.sessionExpired(
            selectedDate: date,
            generation: generation
        ))))
    }
}
