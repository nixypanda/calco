import ComposableArchitecture
import XCTest

@testable import CalCo

/// Behavioral coverage for `DiaryFeature.State.completedFetchCount`.
///
/// The counter must move only when an authoritative diary read is accepted:
/// identity guards pass, the payload day matches, and the resource cache
/// redeems the token. Failures, stale/cancelled/duplicate completions and local
/// mutations must leave it untouched, and nothing short of a fresh state
/// lifetime resets it.
@MainActor
final class DiaryFetchCompletionCountTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let generation: UInt64 = 42

    private nonisolated func makeDay(_ d: LocalDiaryDate, calories: Double = 100) -> DiaryDay {
        DiaryDay(
            date: d,
            logs: [DiaryLog(id: "log-\(d.formatted)", title: "Lunch", calories: calories)],
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    /// Mints the expected token from the *same* authoritative cache instance
    /// that is handed to the store, so issuance id/generation match the one the
    /// reducer issues. The returned cache is the expected "in flight" copy.
    private func issueToken(
        from cache: DiaryFeature.Cache,
        for key: LocalDiaryDate
    ) -> (DiaryFeature.Cache, DiaryFeature.Token) {
        var cache = cache
        let (inFlight, token) = cache.request(key)!
        return (inFlight, token)
    }

    // MARK: - Real effect driven success / failure

    func testRealReadSuccessesIncrementFromZeroToOneThenTwoAndFailureHolds() async {
        let date = self.date
        let generation = self.generation
        let day = self.makeDay(date)
        let stub = StubReadClient(days: [day])
        let initialCache = DiaryFeature.Cache()

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .idle(requestDate: date),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { requestDate, _ in
                try await stub.fetch(requestDate)
            }
        }

        // First genuine read: 0 -> 1.
        let (firstInFlight, firstToken) = self.issueToken(from: initialCache, for: date)
        await store.send(.load) {
            $0.phase = .initialLoading(requestDate: date, token: firstToken)
            $0.cache = firstInFlight
        }
        XCTAssertEqual(store.state.completedFetchCount, 0)
        let firstSettled = firstInFlight.settling(date, token: firstToken, result: .success(day))!
        await store.receive(.diaryReceived(generation: generation, requestDate: date, token: firstToken, day: day)) {
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = firstSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 1)

        // Second genuine read: 1 -> 2.
        let (secondInFlight, secondToken) = self.issueToken(from: firstSettled.invalidate(date), for: date)
        await store.send(.refresh) {
            $0.phase = .loaded(day: day, activity: .refreshing(requestDate: date, token: secondToken))
            $0.cache = secondInFlight
        }
        let secondSettled = secondInFlight.settling(date, token: secondToken, result: .success(day))!
        await store.receive(.diaryReceived(generation: generation, requestDate: date, token: secondToken, day: day)) {
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = secondSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 2)

        // A genuine server failure holds the count at 2.
        stub.fail(with: .server("boom"))
        let (thirdInFlight, thirdToken) = self.issueToken(from: secondSettled.invalidate(date), for: date)
        await store.send(.refresh) {
            $0.phase = .loaded(day: day, activity: .refreshing(requestDate: date, token: thirdToken))
            $0.cache = thirdInFlight
        }
        let thirdCache = thirdInFlight.settling(date, token: thirdToken, result: .failure(.server("boom")))!
        await store.receive(
            .diaryFailed(generation: generation, requestDate: date, token: thirdToken, error: .server("boom"))
        ) {
            $0.phase = .loaded(
                day: day,
                activity: .failure(
                    requestDate: date,
                    token: thirdToken,
                    message: diaryErrorMessage(DiaryServiceError.server("boom"))
                )
            )
            $0.cache = thirdCache
        }
        XCTAssertEqual(store.state.completedFetchCount, 2)
    }

    // MARK: - Unauthorized / silent expire

    func testUnauthorizedCompletionHoldsCountAndExpiresSession() async {
        let date = self.date
        let generation = self.generation
        let day = self.makeDay(date)
        let stub = StubReadClient(days: [day])
        let initialCache = DiaryFeature.Cache()

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .idle(requestDate: date),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { requestDate, _ in
                try await stub.fetch(requestDate)
            }
        }

        // Preseed the count by driving a real accepted read first.
        let (firstInFlight, firstToken) = self.issueToken(from: initialCache, for: date)
        await store.send(.load) {
            $0.phase = .initialLoading(requestDate: date, token: firstToken)
            $0.cache = firstInFlight
        }
        let firstSettled = firstInFlight.settling(date, token: firstToken, result: .success(day))!
        await store.receive(.diaryReceived(generation: generation, requestDate: date, token: firstToken, day: day)) {
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = firstSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 1)

        // Current-generation unauthorized expires but never counts.
        stub.fail(with: .unauthorized)
        let (secondInFlight, secondToken) = self.issueToken(from: firstSettled.invalidate(date), for: date)
        await store.send(.refresh) {
            $0.phase = .loaded(day: day, activity: .refreshing(requestDate: date, token: secondToken))
            $0.cache = secondInFlight
        }
        let expiredCache = secondInFlight.reset()
        await store.receive(
            .diaryFailed(generation: generation, requestDate: date, token: secondToken, error: .unauthorized)
        ) {
            $0.phase = .sessionExpired(requestDate: date)
            $0.cache = expiredCache
            $0.savedLogOverrides = [:]
            $0.deletedIDs = [:]
            $0.pendingGoalOverride = nil
            $0.pendingPrefsOverride = nil
            $0.mutationNotice = nil
        }
        await store.receive(.delegate(.sessionExpired(selectedDate: date, generation: generation)))
        XCTAssertTrue(store.state.isSessionExpired)
        XCTAssertEqual(store.state.completedFetchCount, 1)
    }

    func testSilentExpireHoldsCount() async {
        let date = self.date
        let generation = self.generation
        let day = self.makeDay(date)
        let stub = StubReadClient(days: [day])
        let initialCache = DiaryFeature.Cache()

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .idle(requestDate: date),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { requestDate, _ in
                try await stub.fetch(requestDate)
            }
        }

        let (firstInFlight, firstToken) = self.issueToken(from: initialCache, for: date)
        await store.send(.load) {
            $0.phase = .initialLoading(requestDate: date, token: firstToken)
            $0.cache = firstInFlight
        }
        let firstSettled = firstInFlight.settling(date, token: firstToken, result: .success(day))!
        await store.receive(.diaryReceived(generation: generation, requestDate: date, token: firstToken, day: day)) {
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = firstSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 1)

        // Silent expire clears cache/overrides/notice but never the count.
        let silentExpiredCache = firstSettled.reset()
        await store.send(.expireSession) {
            $0.phase = .sessionExpired(requestDate: date)
            $0.cache = silentExpiredCache
            $0.savedLogOverrides = [:]
            $0.deletedIDs = [:]
            $0.pendingGoalOverride = nil
            $0.pendingPrefsOverride = nil
            $0.mutationNotice = nil
        }
        XCTAssertTrue(store.state.isSessionExpired)
        XCTAssertEqual(store.state.completedFetchCount, 1)
    }

    // MARK: - Guarded completions never count

    func testStaleGenerationAndStaleTokenCompletionsDoNotIncrement() async {
        let date = self.date
        let generation = self.generation
        let (inFlight, token) = self.issueToken(from: DiaryFeature.Cache(), for: date)

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .initialLoading(requestDate: date, token: token),
                sessionGeneration: generation,
                cache: inFlight
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in self.makeDay(date) }
        }

        await store.send(
            .diaryReceived(generation: generation - 1, requestDate: date, token: token, day: self.makeDay(date))
        )
        XCTAssertEqual(store.state.completedFetchCount, 0)

        // A superseded token from the same authoritative cache cannot settle.
        let (laterInFlight, laterToken) = self.issueToken(from: inFlight.invalidate(date), for: date)
        XCTAssertNotEqual(laterToken, token)
        let staleStore = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .initialLoading(requestDate: date, token: laterToken),
                sessionGeneration: generation,
                cache: laterInFlight
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in self.makeDay(date) }
        }
        await staleStore.send(
            .diaryReceived(generation: generation, requestDate: date, token: token, day: self.makeDay(date))
        )
        XCTAssertEqual(laterInFlight.entry(for: date), .inFlight(laterToken))
        XCTAssertEqual(staleStore.state.completedFetchCount, 0)
    }

    func testWrongRequestDateAndWrongPayloadDayDoNotIncrement() async {
        let date = self.date
        let otherDate = self.otherDate
        let generation = self.generation
        let (inFlight, token) = self.issueToken(from: DiaryFeature.Cache(), for: date)

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .initialLoading(requestDate: date, token: token),
                sessionGeneration: generation,
                cache: inFlight
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in self.makeDay(date) }
        }

        // Captured request date does not match the selected date.
        await store.send(
            .diaryReceived(generation: generation, requestDate: otherDate, token: token, day: self.makeDay(otherDate))
        )
        XCTAssertEqual(store.state.completedFetchCount, 0)

        // Matching request date but wrong payload day settles as a failure, not a completed read.
        let wrongDayCache = inFlight.settling(date, token: token, result: .failure(.server("")))!
        await store.send(
            .diaryReceived(generation: generation, requestDate: date, token: token, day: self.makeDay(otherDate))
        ) {
            $0.cache = wrongDayCache
            $0.phase = .initialFailed(
                requestDate: date,
                token: token,
                message: String(localized: "diary.error.generic")
            )
        }
        XCTAssertEqual(store.state.completedFetchCount, 0)
    }

    func testDuplicateCompletionDoesNotIncrement() async {
        let date = self.date
        let generation = self.generation
        let day = self.makeDay(date)
        let (inFlight, token) = self.issueToken(from: DiaryFeature.Cache(), for: date)

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .initialLoading(requestDate: date, token: token),
                sessionGeneration: generation,
                cache: inFlight
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { _, _ in day }
        }

        let settled = inFlight.settling(date, token: token, result: .success(day))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: day)) {
            $0.cache = settled
            $0.phase = .loaded(day: day, activity: .settled)
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 1)

        // The same token after settle is rejected by the cache; no second count.
        await store.send(
            .diaryReceived(generation: generation, requestDate: date, token: token, day: self.makeDay(date, calories: 999))
        )
        XCTAssertEqual(store.state.completedFetchCount, 1)
    }

    // MARK: - Real cancellation

    func testCancelledRealReadDoesNotIncrementCount() async {
        let date = self.date
        let otherDate = self.otherDate
        let generation = self.generation
        let initialCache = DiaryFeature.Cache()
        let controlled = ControlledDiaryClient()
        var starts = controlled.starts.makeAsyncIterator()

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .idle(requestDate: date),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { requestDate, _ in
                try await controlled.fetchDay(requestDate)
            }
        }

        let (firstInFlight, firstToken) = self.issueToken(from: initialCache, for: date)
        await store.send(.load) {
            $0.phase = .initialLoading(requestDate: date, token: firstToken)
            $0.cache = firstInFlight
        }
        guard let firstRequest = await starts.next() else {
            XCTFail("Expected first fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(firstRequest.date, date)

        // A real date change cancels the first client task via effect cancellation.
        // The first read is still in flight (never resumed); the date change
        // invalidates it and starts a fresh request with no retained day.
        let (secondInFlight, secondToken) = self.issueToken(
            from: firstInFlight.invalidate(otherDate).invalidate(date),
            for: otherDate
        )
        await store.send(.selectDate(otherDate)) {
            $0.phase = .initialLoading(requestDate: otherDate, token: secondToken)
            $0.cache = secondInFlight
        }
        await firstRequest.waitUntilCancelled()
        guard let secondRequest = await starts.next() else {
            XCTFail("Expected second fetch start")
            controlled.finish()
            return
        }
        XCTAssertEqual(secondRequest.date, otherDate)
        XCTAssertEqual(store.state.completedFetchCount, 0)

        // Only the replacement read counts, once.
        let dayB = self.makeDay(otherDate)
        let secondSettled = secondInFlight.settling(otherDate, token: secondToken, result: .success(dayB))!
        secondRequest.resume(returning: dayB)
        await store.receive(
            .diaryReceived(generation: generation, requestDate: otherDate, token: secondToken, day: dayB)
        ) {
            $0.phase = .loaded(day: dayB, activity: .settled)
            $0.cache = secondSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 1)
        controlled.finish()
    }

    // MARK: - Date change / foreground monotonicity

    func testDateChangeAndForegroundSuccessesIncrementMonotonicallyAndPreserveOverrides() async {
        let date = self.date
        let today = self.today
        let otherDate = self.otherDate
        let generation = self.generation
        let dayToday = self.makeDay(today)
        let dayOther = self.makeDay(otherDate)
        let stub = StubReadClient(days: [dayToday, dayOther])
        let initialCache = DiaryFeature.Cache()
        let keepLog = DiaryLog(id: "keep", title: "Keep")
        let overrides: [LocalDiaryDate: [String: DiaryLog]] = [date: ["keep": keepLog]]
        let deleted: [LocalDiaryDate: Set<String>] = [date: ["tombstone"]]

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: today,
                phase: .idle(requestDate: today),
                sessionGeneration: generation,
                cache: initialCache,
                savedLogOverrides: overrides,
                deletedIDs: deleted
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { requestDate, _ in
                try await stub.fetch(requestDate)
            }
        }

        // Initial read: 0 -> 1.
        let (firstInFlight, firstToken) = self.issueToken(from: initialCache, for: today)
        await store.send(.load) {
            $0.phase = .initialLoading(requestDate: today, token: firstToken)
            $0.cache = firstInFlight
        }
        let firstSettled = firstInFlight.settling(today, token: firstToken, result: .success(dayToday))!
        await store.receive(.diaryReceived(generation: generation, requestDate: today, token: firstToken, day: dayToday)) {
            $0.phase = .loaded(day: dayToday, activity: .settled)
            $0.cache = firstSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.savedLogOverrides, overrides)
        XCTAssertEqual(store.state.deletedIDs, deleted)

        // Same-day foreground return: 1 -> 2, overrides untouched.
        let (refreshInFlight, refreshToken) = self.issueToken(from: firstSettled.invalidate(today), for: today)
        await store.send(.foregroundRefresh(newToday: today)) {
            $0.phase = .loaded(day: dayToday, activity: .refreshing(requestDate: today, token: refreshToken))
            $0.cache = refreshInFlight
        }
        let refreshSettled = refreshInFlight.settling(today, token: refreshToken, result: .success(dayToday))!
        await store.receive(
            .diaryReceived(generation: generation, requestDate: today, token: refreshToken, day: dayToday)
        ) {
            $0.phase = .loaded(day: dayToday, activity: .settled)
            $0.cache = refreshSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 2)
        XCTAssertEqual(store.state.savedLogOverrides, overrides)

        // Date change: 2 -> 3, overrides untouched.
        let (changeInFlight, changeToken) = self.issueToken(
            from: refreshSettled.invalidate(otherDate),
            for: otherDate
        )
        await store.send(.selectDate(otherDate)) {
            $0.phase = .loaded(
                day: dayToday,
                activity: .changingDate(from: today, requestDate: otherDate, token: changeToken)
            )
            $0.cache = changeInFlight
        }
        let changeSettled = changeInFlight.settling(otherDate, token: changeToken, result: .success(dayOther))!
        await store.receive(
            .diaryReceived(generation: generation, requestDate: otherDate, token: changeToken, day: dayOther)
        ) {
            $0.phase = .loaded(day: dayOther, activity: .settled)
            $0.cache = changeSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 3)
        XCTAssertEqual(store.state.savedLogOverrides, overrides)
        XCTAssertEqual(store.state.deletedIDs, deleted)
    }

    // MARK: - Local mutations

    func testLocalMutationsAndNoticeClearDoNotIncrementCount() async {
        let date = self.date
        let generation = self.generation
        let day = self.makeDay(date)
        let stub = StubReadClient(days: [day])
        let initialCache = DiaryFeature.Cache()

        let store = TestStore(
            initialState: DiaryFeature.State(
                today: self.today,
                phase: .idle(requestDate: date),
                sessionGeneration: generation,
                cache: initialCache
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client { requestDate, _ in
                try await stub.fetch(requestDate)
            }
        }

        let (firstInFlight, firstToken) = self.issueToken(from: initialCache, for: date)
        await store.send(.load) {
            $0.phase = .initialLoading(requestDate: date, token: firstToken)
            $0.cache = firstInFlight
        }
        let firstSettled = firstInFlight.settling(date, token: firstToken, result: .success(day))!
        await store.receive(.diaryReceived(generation: generation, requestDate: date, token: firstToken, day: day)) {
            $0.phase = .loaded(day: day, activity: .settled)
            $0.cache = firstSettled
            $0.completedFetchCount += 1
        }
        XCTAssertEqual(store.state.completedFetchCount, 1)

        await store.send(.toggleMacroMode) {
            $0.macroMode = .percent
        }
        let notice = DiaryMutationNotice(kind: .saved, title: "Saved")
        await store.send(.showMutationNotice(generation: generation, date: date, notice: notice)) {
            $0.mutationNotice = notice
        }
        await store.send(.clearMutationNotice) {
            $0.mutationNotice = nil
        }

        let goal = DiaryGoalTargets(calorieTarget: 2200)
        await store.send(.applySavedGoal(generation: generation, targets: goal, effectiveDate: date)) {
            let updated = DiaryDay(date: date, logs: day.logs, goal: goal, prefs: day.prefs)
            $0.phase = .loaded(day: updated, activity: .settled)
        }
        let prefs = DiaryPrefs(enabledSlots: [.dinner])
        await store.send(.applySavedPreferences(generation: generation, prefs: prefs)) {
            let updated = DiaryDay(date: date, logs: day.logs, goal: goal, prefs: prefs)
            $0.phase = .loaded(day: updated, activity: .settled)
        }

        XCTAssertEqual(store.state.completedFetchCount, 1)
        XCTAssertNil(store.state.mutationNotice)
    }

    // MARK: - Test doubles

    /// A real client seam that serves configured days and can be switched to a
    /// failure between reads, so effects (not hand-built actions) drive counts.
    private final class StubReadClient: @unchecked Sendable {
        private let lock = NSLock()
        private var days: [LocalDiaryDate: DiaryDay]
        private var error: DiaryServiceError?

        init(days: [DiaryDay]) {
            var byDate: [LocalDiaryDate: DiaryDay] = [:]
            for day in days {
                byDate[day.date] = day
            }
            self.days = byDate
        }

        func fail(with error: DiaryServiceError) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        func fetch(_ date: LocalDiaryDate) async throws -> DiaryDay {
            lock.lock()
            let failure = self.error
            let day = self.days[date]
            lock.unlock()
            if let failure {
                throw failure
            }
            guard let day else {
                throw DiaryServiceError.server("no stub day")
            }
            return day
        }
    }

    /// Controlled seam that exposes real in-flight starts and observes genuine
    /// effect cancellation, mirroring the pattern used by the foreground tests.
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
