import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let generation = UInt64(42)

    private nonisolated func makeDay(_ d: LocalDiaryDate, calories: Double = 100) -> DiaryDay {
        DiaryDay(
            date: d,
            logs: [
                DiaryLog(id: "log-\(d.formatted)", title: "Lunch", calories: calories)
            ],
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    private func issueToken(for key: LocalDiaryDate) -> (DiaryFeature.Cache, DiaryFeature.Token) {
        var cache = DiaryFeature.Cache()
        let (inFlight, token) = cache.request(key)!
        return (inFlight, token)
    }

    func testInitialLoadCompletionAndDuplicatePostSettle() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let day = makeDay(date)
        let duplicateDay = makeDay(date, calories: 999)
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        let settledCache = inFlight.settling(date, token: token, result: .success(day))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: day)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = settledCache
        }
        XCTAssertEqual(store.state.visibleDay?.date, date)
        XCTAssertEqual(store.state.visibleDay?.logs.first?.calories, 100)

        // A duplicate success completion with the same captured token and
        // generation must not reapply a different day after settle.
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: duplicateDay))
        XCTAssertEqual(store.state.visibleDay?.date, date)
        XCTAssertEqual(store.state.visibleDay?.logs.first?.calories, 100)
        if case .loaded(let visibleDay, .settled) = store.state.phase {
            XCTAssertEqual(visibleDay, day)
        } else {
            XCTFail("expected settled loaded phase")
        }
    }

    func testDedupSuppressesSecondLoad() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.load)
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: date, token: token))
    }

    func testStaleCompletionHandling() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let bDate = otherDate
        let (inFlightA1, tokenA1) = issueToken(for: date)
        let (inFlightB, tokenB) = issueToken(for: bDate)
        let dayA = makeDay(date)

        // A2 is live while A1 and B completions are stale.
        var cache = DiaryFeature.Cache()
        let (liveInFlight, tokenA2) = cache.request(date)!
        // Retire A1/B by constructing an A2-owned cache; tokens remain distinct.
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: tokenA2),
            sessionGeneration: generation,
            cache: liveInFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.diaryFailed(generation: generation, requestDate: date, token: tokenA1, error: .cancelled))
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: date, token: tokenA2))

        await store.send(.diaryFailed(generation: generation, requestDate: bDate, token: tokenB, error: .cancelled))
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: date, token: tokenA2))

        let staleSettledCache = liveInFlight.settling(date, token: tokenA2, result: .success(dayA))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: tokenA2, day: dayA)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: dayA, activity: .settled)
            $0.cache = staleSettledCache
        }
        XCTAssertEqual(store.state.selectedDate, date)
        XCTAssertEqual(store.state.visibleDay?.date, date)
        _ = (inFlightA1, inFlightB, tokenA1, tokenB)
    }

    func testQuietRefreshFailureRetainsVisibleDay() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let day = makeDay(date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        let failedRefreshCache = inFlight.settling(date, token: token, result: .failure(.server("boom")))!
        await store.send(.diaryFailed(generation: generation, requestDate: date, token: token, error: .server("boom"))) {
            $0.phase = .loaded(day: day, activity: .failure(requestDate: date, token: token, message: diaryErrorMessage(DiaryServiceError.server("boom"))))
            $0.cache = failedRefreshCache
        }
        XCTAssertEqual(store.state.visibleDay?.date, date)
        XCTAssertEqual(store.state.visibleDay?.logs.first?.calories, 100)
    }

    func testInitialFailureCompletionHandling() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        let failedInitialCache = inFlight.settling(date, token: token, result: .failure(.networkUnavailable))!
        await store.send(.diaryFailed(generation: generation, requestDate: date, token: token, error: .networkUnavailable)) {
            $0.phase = .initialFailed(requestDate: date, token: token, message: diaryErrorMessage(DiaryServiceError.networkUnavailable))
            $0.cache = failedInitialCache
        }

        if case .initialFailed = store.state.phase {
            // expected: stale/inactive completion did not promote state
        } else {
            XCTFail("expected initial failed phase")
        }
    }

    func testUnauthorizedExpiresSessionOnceAndIgnoresStaleGeneration() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in throw DiaryServiceError.unauthorized })
        }

        let resetCache = inFlight.reset()
        await store.send(.diaryFailed(generation: generation, requestDate: date, token: token, error: .unauthorized)) {
            $0.phase = .sessionExpired(requestDate: date)
            $0.cache = resetCache
        }
        await store.receive(.delegate(.sessionExpired(selectedDate: date, generation: generation)))
        XCTAssertTrue(store.state.isSessionExpired)

        await store.send(.diaryFailed(generation: generation - 1, requestDate: date, token: token, error: .unauthorized))
        XCTAssertTrue(store.state.isSessionExpired)

        await store.send(.diaryReceived(generation: generation - 1, requestDate: date, token: token, day: makeDay(date)))
        XCTAssertTrue(store.state.isSessionExpired)
    }

    func testWrongDayPayloadRetainsContentAndIgnoresStaleToken() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let day = makeDay(date)
        let wrongDay = makeDay(otherDate)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        let wrongDayCache = inFlight.settling(date, token: token, result: .failure(.server("")))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: wrongDay)) {
            $0.phase = .loaded(day: day, activity: .failure(requestDate: date, token: token, message: String(localized: "diary.error.generic")))
            $0.cache = wrongDayCache
        }
        XCTAssertEqual(store.state.visibleDay?.date, date)
        XCTAssertEqual(store.state.visibleDay?.logs.first?.calories, 100)

        // Stale token completion is ignored even when its payload is wrong-day.
        var cache = DiaryFeature.Cache()
        let (firstInFlight, staleToken) = cache.request(date)!
        cache = firstInFlight.invalidate(date)
        let (liveInFlight, liveToken) = cache.request(date)!
        let staleState = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: liveToken),
            sessionGeneration: generation,
            cache: liveInFlight
        )
        let staleStore = TestStore(initialState: staleState) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }
        await staleStore.send(.diaryReceived(generation: generation, requestDate: date, token: staleToken, day: wrongDay))
        XCTAssertEqual(staleStore.state.phase, .initialLoading(requestDate: date, token: liveToken))
        _ = (firstInFlight, staleToken)
    }

    func testDelegatesExactProvenanceAndBlocking() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let day = makeDay(date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.addFood(.breakfast))
        await store.receive(.delegate(.addFood(slot: .breakfast, date: date, generation: generation)))

        await store.send(.openLogEditor("log-\(date.formatted)"))
        await store.receive(.delegate(.openLogEditor(id: "log-\(date.formatted)", date: date, generation: generation)))

        await store.send(.openLogEditor("missing"))
        // Unknown retained log id produces no delegate.

        await store.send(.openMeals)
        await store.receive(.delegate(.openMeals(date: date, generation: generation)))

        // Delegates are blocked while a date change is in flight.
        let (changingInFlight, changingToken) = issueToken(for: otherDate)
        let changingState = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .changingDate(from: date, requestDate: otherDate, token: changingToken)),
            sessionGeneration: generation,
            cache: changingInFlight
        )
        let changingStore = TestStore(initialState: changingState) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }
        await changingStore.send(.addFood(.lunch))
        await changingStore.send(.openLogEditor("log-\(date.formatted)"))
        await changingStore.send(.openMeals)

        // Delegates are blocked after session expiry.
        let expiredState = DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: date),
            sessionGeneration: generation
        )
        let expiredStore = TestStore(initialState: expiredState) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }
        await expiredStore.send(.addFood(.lunch))
        await expiredStore.send(.openLogEditor("log-\(date.formatted)"))
        await expiredStore.send(.openMeals)
        _ = (inFlight, token)
    }

    func testFutureCapAndTodayNoFetch() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: today)
        let day = makeDay(today)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(today) })
        }

        await store.send(.nextDay)
        XCTAssertEqual(store.state.selectedDate, today)

        let phaseBefore = store.state.phase
        let todayBefore = store.state.today
        await store.send(.todayChanged(today.addingDays(-1))) {
            $0.today = today.addingDays(-1)
        }
        XCTAssertEqual(store.state.phase, phaseBefore)
        XCTAssertEqual(store.state.today, today.addingDays(-1))
        _ = (token, todayBefore)
    }

    // MARK: - Cancellation harness

    private final class ControlledDiaryClient: @unchecked Sendable {
        struct Request: Sendable {
            let id: Int
            let date: LocalDiaryDate
            private let resumeHandler: @Sendable (Result<DiaryDay, Error>) -> Void
            private let waitHandler: @Sendable () async -> Void

            init(
                id: Int,
                date: LocalDiaryDate,
                resumeHandler: @escaping @Sendable (Result<DiaryDay, Error>) -> Void,
                waitHandler: @escaping @Sendable () async -> Void
            ) {
                self.id = id
                self.date = date
                self.resumeHandler = resumeHandler
                self.waitHandler = waitHandler
            }

            func resume(returning day: DiaryDay) {
                resumeHandler(.success(day))
            }

            func waitUntilCancelled() async {
                await waitHandler()
            }
        }

        private struct RequestState {
            var continuation: CheckedContinuation<DiaryDay, Error>?
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

        func fetchDay(_ date: LocalDiaryDate) async throws -> DiaryDay {
            let id = allocateID()
            let request = Request(
                id: id,
                date: date,
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
            continuation: CheckedContinuation<DiaryDay, Error>
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

        private func resume(id: Int, result: Result<DiaryDay, Error>) {
            lock.lock()
            var state = states[id, default: RequestState()]
            let continuation = state.continuation
            state.continuation = nil
            states[id] = state
            lock.unlock()
            continuation?.resume(with: result)
        }

        private func waitUntilCancelled(id: Int) async {
            if isCancelled(id: id) {
                return
            }
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

        private func registerCancelWaiter(
            id: Int,
            continuation: CheckedContinuation<Void, Never>
        ) {
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

    func testSelectDateCancellationStartsFreshRequestAndA2Lands() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let dayA = makeDay(date)
        let dayB = makeDay(otherDate)

        var initialCache = DiaryFeature.Cache()
        let (bSeedInFlight, bSeedToken) = initialCache.request(otherDate)!
        initialCache = bSeedInFlight.settling(otherDate, token: bSeedToken, result: .success(dayB))!

        let controlled = ControlledDiaryClient()
        var starts = controlled.starts.makeAsyncIterator()

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: today,
                phase: .loaded(day: dayB, activity: .settled),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { date, _ in try await controlled.fetchDay(date) })
        }

        // 1) Real .run starts A1; capture generation/date/token from live state.
        var cacheAfterA1 = initialCache.invalidate(date)
        let (a1InFlight, tokenA1) = cacheAfterA1.request(date)!
        cacheAfterA1 = a1InFlight

        await store.send(.selectDate(date)) {
            $0.phase = .loaded(
                day: dayB,
                activity: .changingDate(from: otherDate, requestDate: date, token: tokenA1)
            )
            $0.cache = cacheAfterA1
        }
        guard let reqA1 = await starts.next() else {
            XCTFail("Expected A1 fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(reqA1.date, date)
        XCTAssertEqual(store.state.sessionGeneration, generation)
        XCTAssertEqual(store.state.selectedDate, date)
        if case .loaded(_, .changingDate(let from, let requestDate, let token)) = store.state.phase {
            XCTAssertEqual(from, otherDate)
            XCTAssertEqual(requestDate, date)
            XCTAssertEqual(token, tokenA1)
        } else {
            XCTFail("Expected changingDate phase for A1")
        }

        // 2) selectDate(B) cancels A1 actual client task; no cancelled diaryFailed receive.
        var cacheAfterB = cacheAfterA1.invalidate(date)
        cacheAfterB = cacheAfterB.invalidate(otherDate)
        let (bInFlight, tokenB1) = cacheAfterB.request(otherDate)!
        cacheAfterB = bInFlight

        await store.send(.selectDate(otherDate)) {
            $0.phase = .loaded(
                day: dayB,
                activity: .changingDate(from: date, requestDate: otherDate, token: tokenB1)
            )
            $0.cache = cacheAfterB
        }
        await reqA1.waitUntilCancelled()
        guard let reqB1 = await starts.next() else {
            XCTFail("Expected B fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(reqB1.date, otherDate)

        // 3) selectDate(A) cancels B and starts fresh A2; token must not be stuck on A1.
        var cacheAfterA2 = cacheAfterB.invalidate(otherDate)
        cacheAfterA2 = cacheAfterA2.invalidate(date)
        let (a2InFlight, tokenA2) = cacheAfterA2.request(date)!
        cacheAfterA2 = a2InFlight
        XCTAssertNotEqual(tokenA2, tokenA1)

        await store.send(.selectDate(date)) {
            $0.phase = .loaded(
                day: dayB,
                activity: .changingDate(from: otherDate, requestDate: date, token: tokenA2)
            )
            $0.cache = cacheAfterA2
        }
        await reqB1.waitUntilCancelled()
        guard let reqA2 = await starts.next() else {
            XCTFail("Expected A2 fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(reqA2.date, date)

        // 4) A2 success lands as a genuine received action.
        let settledA2Cache = cacheAfterA2.settling(date, token: tokenA2, result: .success(dayA))!
        reqA2.resume(returning: dayA)
        await store.receive(
            .diaryReceived(generation: generation, requestDate: date, token: tokenA2, day: dayA)
        ) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: dayA, activity: .settled)
            $0.cache = settledA2Cache
        }

        XCTAssertEqual(store.state.selectedDate, date)
        XCTAssertEqual(store.state.visibleDay, dayA)
        controlled.finish()
    }

    // MARK: - Mutation stories

    func testSavedLogOverrideSurvivesStaleFetch() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let oldLog = DiaryLog(id: "log-\(date.formatted)", title: "Old")
        let savedLog = DiaryLog(id: "log-\(date.formatted)", title: "Saved")
        let day = DiaryDay(date: date, logs: [oldLog], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let savedDay = DiaryDay(date: date, logs: [savedLog], goal: day.goal, prefs: day.prefs)
        await store.send(.applySavedLog(generation: generation, log: savedLog, replacingID: oldLog.id, onDate: date)) {
            $0.phase = .loaded(day: savedDay, activity: .refreshing(requestDate: date, token: token))
            $0.savedLogOverrides = [date: [savedLog.id: savedLog]]
        }

        let staleDay = DiaryDay(date: date, logs: [oldLog], goal: day.goal, prefs: day.prefs)
        let reconciledDay = DiaryDay(date: date, logs: [savedLog], goal: day.goal, prefs: day.prefs)
        let settledCache = inFlight.settling(date, token: token, result: .success(reconciledDay))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: staleDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
            $0.savedLogOverrides = [date: [savedLog.id: savedLog]]
        }
    }

    func testSavedLogOverrideRetiresWhenServerCatchesUp() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let savedLog = DiaryLog(id: "log-\(date.formatted)", title: "Saved")
        let day = DiaryDay(date: date, logs: [savedLog], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight,
            savedLogOverrides: [date: [savedLog.id: savedLog]]
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let settledCache = inFlight.settling(date, token: token, result: .success(day))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: day)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = settledCache
            $0.savedLogOverrides = [:]
        }
    }

    func testDeletedLogTombstoneSurvivesStaleFetch() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let oldLog = DiaryLog(id: "log-\(date.formatted)", title: "Old")
        let day = DiaryDay(date: date, logs: [oldLog], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let deletedDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: day.prefs)
        await store.send(.applyDeletedLog(generation: generation, id: oldLog.id, onDate: date)) {
            $0.phase = .loaded(day: deletedDay, activity: .refreshing(requestDate: date, token: token))
            $0.deletedIDs = [date: [oldLog.id]]
        }

        let staleDay = DiaryDay(date: date, logs: [oldLog], goal: day.goal, prefs: day.prefs)
        let reconciledDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: day.prefs)
        let settledCache = inFlight.settling(date, token: token, result: .success(reconciledDay))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: staleDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
            $0.deletedIDs = [date: [oldLog.id]]
        }
    }

    func testDeletedLogTombstoneRetiresWhenServerRemoves() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let emptyDay = DiaryDay(date: date, logs: [], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: emptyDay, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight,
            deletedIDs: [date: ["log-\(date.formatted)"]]
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in emptyDay })
        }

        let settledCache = inFlight.settling(date, token: token, result: .success(emptyDay))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: emptyDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: emptyDay, activity: .settled)
            $0.cache = settledCache
            $0.deletedIDs = [:]
        }
    }

    func testCrossDateSaveDoesNotClobberVisibleDay() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: otherDate)
        let visibleDay = DiaryDay(date: otherDate, logs: [DiaryLog(id: "log-other", title: "Other")], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: visibleDay, activity: .settled),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in visibleDay })
        }

        let savedLog = DiaryLog(id: "log-saved", title: "Saved")
        await store.send(.applySavedLog(generation: generation, log: savedLog, replacingID: "old-row", onDate: date)) {
            $0.savedLogOverrides = [date: [savedLog.id: savedLog]]
        }
        XCTAssertEqual(store.state.visibleDay, visibleDay)
        _ = token
    }

    func testGoalOverrideHeldRefreshWinsOnceThenServerWins() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let oldGoal = DiaryGoalTargets(calorieTarget: 2100)
        let savedGoal = DiaryGoalTargets(calorieTarget: 2200)
        let serverGoal = DiaryGoalTargets(calorieTarget: 2300)
        let day = DiaryDay(date: date, logs: [], goal: oldGoal, prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let savedDay = DiaryDay(date: date, logs: [], goal: savedGoal, prefs: day.prefs)
        await store.send(.applySavedGoal(generation: generation, targets: savedGoal, effectiveDate: date)) {
            $0.phase = .loaded(day: savedDay, activity: .refreshing(requestDate: date, token: token))
            $0.pendingGoalOverride = DiaryFeature.PendingGoalOverride(targets: savedGoal, date: date, activeToken: token)
        }

        let staleDay = DiaryDay(date: date, logs: [], goal: oldGoal, prefs: day.prefs)
        let reconciledDay = DiaryDay(date: date, logs: [], goal: savedGoal, prefs: day.prefs)
        let settledCache = inFlight.settling(date, token: token, result: .success(reconciledDay))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: staleDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
            $0.pendingGoalOverride = nil
        }

        // A later fresh read with no pending override uses server state.
        let (inFlight2, token2) = issueToken(for: date)
        var state2 = store.state
        state2.cache = inFlight2
        state2.phase = .loaded(day: reconciledDay, activity: .refreshing(requestDate: date, token: token2))
        let store2 = TestStore(initialState: state2) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }
        let serverDay = DiaryDay(date: date, logs: [], goal: serverGoal, prefs: day.prefs)
        let settledCache2 = inFlight2.settling(date, token: token2, result: .success(serverDay))!
        await store2.send(.diaryReceived(generation: generation, requestDate: date, token: token2, day: serverDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: serverDay, activity: .settled)
            $0.cache = settledCache2
        }
    }

    func testPreferencesOverrideHeldInitialLoading() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let prefs = DiaryPrefs(enabledSlots: [.dinner])
        let day = DiaryDay(date: date, logs: [], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        await store.send(.applySavedPreferences(generation: generation, prefs: prefs)) {
            $0.pendingPrefsOverride = DiaryFeature.PendingPrefsOverride(prefs: prefs, activeToken: token)
        }

        let reconciledDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: prefs)
        let settledCache = inFlight.settling(date, token: token, result: .success(reconciledDay))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: day)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
            $0.pendingPrefsOverride = nil
        }
    }

    func testStaleGenerationMutationsAndExpiryClearAll() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let day = DiaryDay(date: date, logs: [DiaryLog(id: "log-1", title: "Old")], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight,
            savedLogOverrides: [date: ["log-1": DiaryLog(id: "log-1", title: "Saved")]],
            deletedIDs: [date: ["deleted"]],
            pendingGoalOverride: DiaryFeature.PendingGoalOverride(targets: DiaryGoalTargets(calorieTarget: 9), date: date, activeToken: token),
            pendingPrefsOverride: DiaryFeature.PendingPrefsOverride(prefs: DiaryPrefs(enabledSlots: [.dinner]), activeToken: token)
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        await store.send(.applySavedLog(generation: generation - 1, log: DiaryLog(id: "x", title: "x"), replacingID: "log-1", onDate: date))
        await store.send(.applyDeletedLog(generation: generation - 1, id: "log-1", onDate: date))
        await store.send(.applySavedGoal(generation: generation - 1, targets: DiaryGoalTargets(calorieTarget: 1), effectiveDate: date))
        await store.send(.applySavedPreferences(generation: generation - 1, prefs: DiaryPrefs(enabledSlots: [.lunch])))

        let resetCache = inFlight.reset()
        await store.send(.diaryFailed(generation: generation, requestDate: date, token: token, error: .unauthorized)) {
            $0.phase = .sessionExpired(requestDate: date)
            $0.cache = resetCache
            $0.savedLogOverrides = [:]
            $0.deletedIDs = [:]
            $0.pendingGoalOverride = nil
            $0.pendingPrefsOverride = nil
        }
        await store.receive(.delegate(.sessionExpired(selectedDate: date, generation: generation)))
    }

    func testLocalCacheMergeForSavedAndDeletedLogs() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let oldLog = DiaryLog(id: "log-\(date.formatted)", title: "Old")
        let savedLog = DiaryLog(id: "log-\(date.formatted)", title: "Saved")
        let appendedLog = DiaryLog(id: "log-new", title: "New")
        let day = DiaryDay(date: date, logs: [oldLog], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let cache = DiaryFeature.Cache().seed(date, value: day)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: cache
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        await store.send(.applySavedLog(generation: generation, log: savedLog, replacingID: oldLog.id, onDate: date)) {
            let updatedDay = DiaryDay(date: date, logs: [savedLog], goal: day.goal, prefs: day.prefs)
            $0.phase = .loaded(day: updatedDay, activity: .settled)
            $0.savedLogOverrides = [date: [savedLog.id: savedLog]]
            $0.cache = cache.invalidate(date).seed(date, value: updatedDay)
        }
        XCTAssertEqual(store.state.cache.cached(date), .success(DiaryDay(date: date, logs: [savedLog], goal: day.goal, prefs: day.prefs)))

        await store.send(.applySavedLog(generation: generation, log: appendedLog, replacingID: "missing", onDate: date)) {
            let updatedDay = DiaryDay(date: date, logs: [savedLog, appendedLog], goal: day.goal, prefs: day.prefs)
            $0.phase = .loaded(day: updatedDay, activity: .settled)
            $0.savedLogOverrides = [date: [savedLog.id: savedLog, appendedLog.id: appendedLog]]
            $0.cache = store.state.cache.invalidate(date).seed(date, value: updatedDay)
        }

        await store.send(.applyDeletedLog(generation: generation, id: savedLog.id, onDate: date)) {
            let updatedDay = DiaryDay(date: date, logs: [appendedLog], goal: day.goal, prefs: day.prefs)
            $0.phase = .loaded(day: updatedDay, activity: .settled)
            $0.savedLogOverrides = [date: [appendedLog.id: appendedLog]]
            $0.deletedIDs = [date: [savedLog.id]]
            $0.cache = store.state.cache.invalidate(date).seed(date, value: updatedDay)
        }
        XCTAssertEqual(store.state.cache.cached(date), .success(DiaryDay(date: date, logs: [appendedLog], goal: day.goal, prefs: day.prefs)))
    }

    func testCrossDateHeldSavePreservesVisibleAUntilBSettles() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let dayA = makeDay(date)
        let dayB = makeDay(otherDate)
        let savedA = DiaryLog(id: "saved-A", title: "Saved A")
        let savedB = DiaryLog(id: "saved-B", title: "Saved B")

        let controlled = ControlledDiaryClient()
        var starts = controlled.starts.makeAsyncIterator()

        var initialCache = DiaryFeature.Cache()
        let store = TestStore(
            initialState: DiaryFeature.State(
                today: today,
                phase: .loaded(day: dayA, activity: .settled),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { date, _ in try await controlled.fetchDay(date) })
        }

        var cacheAfterB = initialCache.invalidate(otherDate)
        let (bInFlight, tokenB) = cacheAfterB.request(otherDate)!
        cacheAfterB = bInFlight

        await store.send(.selectDate(otherDate)) {
            $0.phase = .loaded(day: dayA, activity: .changingDate(from: date, requestDate: otherDate, token: tokenB))
            $0.cache = cacheAfterB
        }
        guard let reqB = await starts.next() else {
            XCTFail("Expected B fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(reqB.date, otherDate)

        await store.send(.applySavedLog(generation: generation, log: savedA, replacingID: "old-row", onDate: date)) {
            $0.savedLogOverrides = [date: [savedA.id: savedA]]
        }
        await store.send(.applySavedLog(generation: generation, log: savedB, replacingID: "old-row", onDate: otherDate)) {
            $0.savedLogOverrides = [date: [savedA.id: savedA], otherDate: [savedB.id: savedB]]
        }

        XCTAssertEqual(store.state.selectedDate, otherDate)
        XCTAssertEqual(store.state.visibleDay, dayA)

        let settledBCache = cacheAfterB.settling(otherDate, token: tokenB, result: .success(dayB))!
        reqB.resume(returning: dayB)
        await store.receive(.diaryReceived(generation: generation, requestDate: otherDate, token: tokenB, day: dayB)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: dayB, activity: .settled)
            $0.cache = settledBCache
            $0.savedLogOverrides = [date: [savedA.id: savedA]]
        }

        XCTAssertEqual(store.state.visibleDay?.date, otherDate)
        XCTAssertEqual(store.state.savedLogOverrides[date], [savedA.id: savedA])
        controlled.finish()
    }

    func testDeleteThenResaveSameIDClearsTombstone() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let log = DiaryLog(id: "log-\(date.formatted)", title: "Original")
        let saved = DiaryLog(id: "log-\(date.formatted)", title: "Resaved")
        let day = DiaryDay(date: date, logs: [log], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: DiaryPrefs())
        let cache = DiaryFeature.Cache().seed(date, value: day)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: cache
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let deletedDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: day.prefs)
        await store.send(.applyDeletedLog(generation: generation, id: log.id, onDate: date)) {
            $0.phase = .loaded(day: deletedDay, activity: .settled)
            $0.deletedIDs = [date: [log.id]]
            $0.cache = cache.invalidate(date).seed(date, value: deletedDay)
        }

        let resavedDay = DiaryDay(date: date, logs: [saved], goal: day.goal, prefs: day.prefs)
        await store.send(.applySavedLog(generation: generation, log: saved, replacingID: log.id, onDate: date)) {
            $0.phase = .loaded(day: resavedDay, activity: .settled)
            $0.savedLogOverrides = [date: [saved.id: saved]]
            $0.deletedIDs = [:]
            $0.cache = store.state.cache.invalidate(date).seed(date, value: resavedDay)
        }
        XCTAssertNil(store.state.deletedIDs[date])
    }

    func testPreferencesHeldRefreshAndChangingDateProtectThenServerWins() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let oldPrefs = DiaryPrefs(enabledSlots: [.breakfast])
        let heldPrefs = DiaryPrefs(enabledSlots: [.dinner])
        let serverPrefs = DiaryPrefs(enabledSlots: [.lateNightSnack])
        let day = DiaryDay(date: date, logs: [], goal: DiaryGoalTargets(calorieTarget: 2000), prefs: oldPrefs)

        let (inFlight, token) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let heldDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: heldPrefs)
        await store.send(.applySavedPreferences(generation: generation, prefs: heldPrefs)) {
            $0.phase = .loaded(day: heldDay, activity: .refreshing(requestDate: date, token: token))
            $0.pendingPrefsOverride = DiaryFeature.PendingPrefsOverride(prefs: heldPrefs, activeToken: token)
        }

        let reconciledDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: heldPrefs)
        let settledCache = inFlight.settling(date, token: token, result: .success(reconciledDay))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: day)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
            $0.pendingPrefsOverride = nil
        }

        let (inFlight2, token2) = issueToken(for: date)
        var state2 = store.state
        state2.cache = inFlight2
        state2.phase = .loaded(day: reconciledDay, activity: .refreshing(requestDate: date, token: token2))
        let store2 = TestStore(initialState: state2) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }
        let serverDay = DiaryDay(date: date, logs: [], goal: day.goal, prefs: serverPrefs)
        let settledCache2 = inFlight2.settling(date, token: token2, result: .success(serverDay))!
        await store2.send(.diaryReceived(generation: generation, requestDate: date, token: token2, day: serverDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: serverDay, activity: .settled)
            $0.cache = settledCache2
        }

        // Changing-date phase also stores pending prefs and preserves selected date.
        let (inFlight3, token3) = issueToken(for: otherDate)
        let changingState = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .changingDate(from: date, requestDate: otherDate, token: token3)),
            sessionGeneration: generation,
            cache: inFlight3
        )
        let changingStore = TestStore(initialState: changingState) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }
        let changingPrefs = DiaryPrefs(enabledSlots: [.snack])
        await changingStore.send(.applySavedPreferences(generation: generation, prefs: changingPrefs)) {
            $0.phase = .loaded(day: DiaryDay(date: day.date, logs: day.logs, goal: day.goal, prefs: changingPrefs), activity: .changingDate(from: date, requestDate: otherDate, token: token3))
            $0.pendingPrefsOverride = DiaryFeature.PendingPrefsOverride(prefs: changingPrefs, activeToken: token3)
        }
        XCTAssertEqual(changingStore.state.selectedDate, otherDate)
    }
}
