import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryForegroundFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let generation = UInt64(42)

    private let notice = DiaryMutationNotice(kind: .saved, title: "Saved")

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

    // 1. Same-day, viewing today, non-expired: exactly one quiet refresh.
    func testForegroundRefreshSameDayQuietRefreshPreservesVisibleAndNotice() async {
        let today = self.today
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()
        var expectedCache = initialCache
        let (expectedInFlight, token) = expectedCache.request(today)!
        expectedCache = expectedInFlight

        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: self.makeDay(today), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(today) })
        }

        await store.send(.foregroundRefresh(newToday: today)) {
            $0.phase = .loaded(day: self.makeDay(today), activity: .refreshing(requestDate: today, token: token))
            $0.cache = expectedCache
        }
        let reconciledDay = self.makeDay(today)
        let settledCache = expectedCache.settling(today, token: token, result: .success(reconciledDay))!
        await store.receive(.diaryReceived(generation: generation, requestDate: today, token: token, day: reconciledDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
        }
        XCTAssertEqual(store.state.mutationNotice, self.notice)
    }

    // 2. Same-day historical selection: no fetch.
    func testForegroundRefreshSameDayHistoricalNone() async {
        let today = self.today
        let otherDate = self.otherDate
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()

        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: self.makeDay(otherDate), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(today) })
        }

        await store.send(.foregroundRefresh(newToday: today))
        XCTAssertEqual(store.state.today, today)
        XCTAssertEqual(store.state.selectedDate, otherDate)
        XCTAssertEqual(store.state.mutationNotice, self.notice)
    }

    // 3. Rollover while viewing today: today update, notice clear, initial loading full reload.
    func testForegroundRefreshRolloverViewingTodayInitialLoading() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()
        var expectedCache = initialCache
        let (expectedInFlight, token) = expectedCache.request(newToday)!
        expectedCache = expectedInFlight

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .loaded(day: self.makeDay(oldToday), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(newToday) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .initialLoading(requestDate: newToday, token: token)
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        let reconciledDay = self.makeDay(newToday)
        let settledCache = expectedCache.settling(newToday, token: token, result: .success(reconciledDay))!
        await store.receive(.diaryReceived(generation: generation, requestDate: newToday, token: token, day: reconciledDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
        }
    }

    // 4. Rollover historical selection (selected < newToday): only today update.
    func testForegroundRefreshRolloverHistoricalOnlyTodayUpdate() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let selected = self.otherDate
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .loaded(day: self.makeDay(selected), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(newToday) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
        }
        XCTAssertEqual(store.state.selectedDate, selected)
        XCTAssertEqual(store.state.mutationNotice, self.notice)
    }

    // Old-clock regression: selected == newToday is historical/equal, so only today updates.
    func testForegroundRefreshOldClockSelectedEqualsNewTodayOnlyTodayUpdate() async {
        let oldToday = self.today
        let newToday = self.otherDate
        let selected = self.otherDate
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .loaded(day: self.makeDay(selected), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(newToday) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
        }
        XCTAssertEqual(store.state.selectedDate, selected)
        XCTAssertEqual(store.state.mutationNotice, self.notice)
    }

    // 5. Rollover clamp (selected > newToday): today update + reload to newToday.
    func testForegroundRefreshRolloverClampReload() async {
        let oldToday = self.today
        let newToday = self.date
        let selected = self.otherDate
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()
        var expectedCache = initialCache
        let (expectedInFlight, token) = expectedCache.request(newToday)!
        expectedCache = expectedInFlight

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .loaded(day: self.makeDay(selected), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(newToday) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .initialLoading(requestDate: newToday, token: token)
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        let reconciledDay = self.makeDay(newToday)
        let settledCache = expectedCache.settling(newToday, token: token, result: .success(reconciledDay))!
        await store.receive(.diaryReceived(generation: generation, requestDate: newToday, token: token, day: reconciledDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
        }
    }

    // 6. Expired rollover: today + sessionExpired(requestDate:newToday) + notice clear; no fetch.
    func testForegroundRefreshExpiredRollover() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .sessionExpired(requestDate: oldToday),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(newToday) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .sessionExpired(requestDate: newToday)
            $0.mutationNotice = nil
        }
        XCTAssertEqual(store.state.cache, initialCache)
    }

    // 7. Same-day expired: none.
    func testForegroundRefreshSameDayExpiredNone() async {
        let today = self.today
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()

        let state = DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: today),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(today) })
        }

        await store.send(.foregroundRefresh(newToday: today))
        XCTAssertEqual(store.state.today, today)
        XCTAssertEqual(store.state.mutationNotice, self.notice)
    }

    // Same-day inflight dedup: no duplicate request.
    func testForegroundRefreshSameDayInflightDedup() async {
        let today = self.today
        let generation = self.generation
        let (initialCache, _) = issueToken(for: today)

        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: self.makeDay(today), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(today) })
        }

        await store.send(.foregroundRefresh(newToday: today))
        XCTAssertEqual(store.state.cache, initialCache)
        XCTAssertEqual(store.state.mutationNotice, self.notice)
    }

    // Rollover target already in flight: fresh issue + old token rejected.
    func testForegroundRefreshRolloverTargetInflightFreshIssueAndOldTokenReject() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let generation = self.generation
        let (oldInFlight, oldToken) = issueToken(for: newToday)

        var expectedCache = oldInFlight.invalidate(newToday)
        let (expectedInFlight, newToken) = expectedCache.request(newToday)!
        expectedCache = expectedInFlight

        let controlled = ControlledDiaryClient()
        var starts = controlled.starts.makeAsyncIterator()

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .loaded(day: self.makeDay(oldToday), activity: .settled),
            sessionGeneration: generation,
            cache: oldInFlight,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { date, _ in try await controlled.fetchDay(date) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .initialLoading(requestDate: newToday, token: newToken)
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        guard let newReq = await starts.next() else {
            XCTFail("Expected fresh fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(newReq.date, newToday)

        await store.send(.diaryReceived(generation: generation, requestDate: newToday, token: oldToken, day: self.makeDay(newToday)))
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: newToday, token: newToken))

        let reconciledDay = self.makeDay(newToday)
        let settledCache = expectedCache.settling(newToday, token: newToken, result: .success(reconciledDay))!
        newReq.resume(returning: reconciledDay)
        await store.receive(.diaryReceived(generation: generation, requestDate: newToday, token: newToken, day: reconciledDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
        }

        controlled.finish()
    }

    // Saved overrides / tombstones preserved at rollover and reconciled on completion.
    func testForegroundRefreshRolloverPreservesOverridesAndReconciles() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let otherDate = self.otherDate
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()

        let savedLog = DiaryLog(
            id: "log-x",
            title: "Saved",
            quantity: NutritionQuantity(amount: "200", unit: "g")
        )
        let keepLog = DiaryLog(id: "keep", title: "Keep")
        let initialOverrides: [LocalDiaryDate: [String: DiaryLog]] = [
            newToday: ["log-x": savedLog],
            otherDate: ["keep": keepLog]
        ]
        let initialDeleted: [LocalDiaryDate: Set<String>] = [
            newToday: ["del-1"],
            otherDate: ["del-2"]
        ]

        var expectedCache = initialCache
        let (expectedInFlight, token) = expectedCache.request(newToday)!
        expectedCache = expectedInFlight

        let state = DiaryFeature.State(
            today: oldToday,
            phase: .loaded(day: self.makeDay(oldToday), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            savedLogOverrides: initialOverrides,
            deletedIDs: initialDeleted,
            mutationNotice: self.notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(newToday) })
        }

        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .initialLoading(requestDate: newToday, token: token)
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        XCTAssertEqual(store.state.savedLogOverrides, initialOverrides)
        XCTAssertEqual(store.state.deletedIDs, initialDeleted)

        let reconciledDay = self.makeDay(newToday)
        let settledCache = expectedCache.settling(newToday, token: token, result: .success(reconciledDay))!
        await store.receive(.diaryReceived(generation: generation, requestDate: newToday, token: token, day: reconciledDay)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: reconciledDay, activity: .settled)
            $0.cache = settledCache
            $0.savedLogOverrides = [otherDate: ["keep": keepLog]]
            $0.deletedIDs = [otherDate: ["del-2"]]
        }
    }

    // Stale old request completion after rollover is rejected.
    func testForegroundRefreshStaleOldRequestCompletionAfterRollover() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let generation = self.generation
        let dayOld = self.makeDay(oldToday)
        let dayNew = self.makeDay(newToday)

        let controlled = ControlledDiaryClient()
        var starts = controlled.starts.makeAsyncIterator()

        let initialCache = DiaryFeature.Cache()
        let store = TestStore(
            initialState: DiaryFeature.State(
                today: oldToday,
                phase: .loaded(day: dayOld, activity: .settled),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { date, _ in try await controlled.fetchDay(date) })
        }

        var cacheAfterOld = initialCache
        let (oldInFlight, oldToken) = cacheAfterOld.request(oldToday)!
        cacheAfterOld = oldInFlight
        await store.send(.refresh) {
            $0.phase = .loaded(day: dayOld, activity: .refreshing(requestDate: oldToday, token: oldToken))
            $0.cache = cacheAfterOld
        }
        guard let oldReq = await starts.next() else {
            XCTFail("Expected old fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(oldReq.date, oldToday)

        var expectedCache = cacheAfterOld
        let (newInFlight, newToken) = expectedCache.request(newToday)!
        expectedCache = newInFlight
        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .initialLoading(requestDate: newToday, token: newToken)
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        await oldReq.waitUntilCancelled()

        guard let newReq = await starts.next() else {
            XCTFail("Expected new fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(newReq.date, newToday)

        await store.send(.diaryReceived(generation: generation, requestDate: oldToday, token: oldToken, day: dayOld))
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: newToday, token: newToken))

        let settledCache = expectedCache.settling(newToday, token: newToken, result: .success(dayNew))!
        newReq.resume(returning: dayNew)
        await store.receive(.diaryReceived(generation: generation, requestDate: newToday, token: newToken, day: dayNew)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: dayNew, activity: .settled)
            $0.cache = settledCache
        }

        controlled.finish()
    }

    // Actual underlying cancellation when foreground rollover replaces an in-flight old read.
    func testForegroundRefreshRolloverCancelsUnderlyingOldRead() async {
        let oldToday = self.today
        let newToday = oldToday.addingDays(1)
        let generation = self.generation
        let dayOld = self.makeDay(oldToday)
        let dayNew = self.makeDay(newToday)

        let controlled = ControlledDiaryClient()
        var starts = controlled.starts.makeAsyncIterator()

        let initialCache = DiaryFeature.Cache()
        let store = TestStore(
            initialState: DiaryFeature.State(
                today: oldToday,
                phase: .loaded(day: dayOld, activity: .settled),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { date, _ in try await controlled.fetchDay(date) })
        }

        var cacheAfterOld = initialCache
        let (oldInFlight, oldToken) = cacheAfterOld.request(oldToday)!
        cacheAfterOld = oldInFlight
        await store.send(.refresh) {
            $0.phase = .loaded(day: dayOld, activity: .refreshing(requestDate: oldToday, token: oldToken))
            $0.cache = cacheAfterOld
        }
        guard let oldReq = await starts.next() else {
            XCTFail("Expected old fetch start")
            controlled.finish()
            return
        }

        var expectedCache = cacheAfterOld
        let (newInFlight, newToken) = expectedCache.request(newToday)!
        expectedCache = newInFlight
        await store.send(.foregroundRefresh(newToday: newToday)) {
            $0.today = newToday
            $0.phase = .initialLoading(requestDate: newToday, token: newToken)
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        await oldReq.waitUntilCancelled()

        guard let newReq = await starts.next() else {
            XCTFail("Expected new fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(newReq.date, newToday)

        let settledCache = expectedCache.settling(newToday, token: newToken, result: .success(dayNew))!
        newReq.resume(returning: dayNew)
        await store.receive(.diaryReceived(generation: generation, requestDate: newToday, token: newToken, day: dayNew)) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: dayNew, activity: .settled)
            $0.cache = settledCache
        }

        controlled.finish()
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

}