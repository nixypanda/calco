import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryLatestFeatureTests: XCTestCase {
    private let destinationDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let sourceDate = LocalDiaryDate(year: 2026, month: 10, day: 28)
    private let generation = UInt64(42)

    private func makeSlots() -> [DiaryLatestSlot] {
        [
            DiaryLatestSlot(
                sourceDate: sourceDate,
                mealSlot: .dinner,
                logs: [
                    DiaryLog(
                        id: "log-1",
                        mealSlot: .dinner,
                        title: "Oats",
                        quantity: NutritionQuantity(amount: "60", unit: "g"),
                        notes: "with milk",
                        logItem: .product(id: "food-1")
                    ),
                    DiaryLog(
                        id: "log-2",
                        mealSlot: .dinner,
                        title: "Curry",
                        quantity: NutritionQuantity(amount: "1", unit: "serving"),
                        logItem: .meal(id: "meal-1")
                    ),
                ]
            )
        ]
    }

    private func issueToken(for key: LocalDiaryDate) -> (DiaryLatestFeature.Cache, DiaryLatestFeature.Token) {
        var cache = DiaryLatestFeature.Cache()
        let (inFlight, token) = cache.request(key)!
        return (inFlight, token)
    }

    func testCachedSuccessCreatesReviewWithoutRequest() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let sourceDate = self.sourceDate
        var (cache, _) = issueToken(for: date)
        cache = cache.settling(date, token: cache.entry(for: date).inFlightToken!, result: .success(slots))!

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: cache,
            phase: .idle(destinationDate: date)
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in
                XCTFail("cached read must not call service")
                return []
            }
        }

        await store.send(.prepareLatest(.dinner)) {
            $0.phase = .loaded(
                destinationDate: date,
                slots: slots,
                loadedForDate: date,
                activity: .settled
            )
            $0.cache = cache
            $0.loadingSlot = nil
            $0.errorMessage = nil
            $0.review = DiaryLatestReview(
                destinationDate: date,
                destinationSlot: .dinner,
                sourceDate: sourceDate,
                items: slots.first!.logs
            )
        }
    }

    func testPrepareLatestIssuesRequestAndCreatesReviewOnCompletion() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let sourceDate = self.sourceDate

        var emptyCache = DiaryLatestFeature.Cache()
        let (inFlight, token) = emptyCache.request(date)!
        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: emptyCache,
            phase: .idle(destinationDate: date)
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.prepareLatest(.dinner)) {
            $0.phase = .loading(destinationDate: date, slot: .dinner, token: token)
            $0.cache = inFlight
            $0.loadingSlot = .dinner
            $0.errorMessage = nil
        }

        let settledCache = inFlight.settling(date, token: token, result: .success(slots))!
        await store.receive(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(slots)
        )) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = settledCache
            $0.loadingSlot = nil
            $0.errorMessage = nil
            $0.review = DiaryLatestReview(
                destinationDate: date,
                destinationSlot: .dinner,
                sourceDate: sourceDate,
                items: slots.first!.logs
            )
        }
    }

    func testStaleGenerationIsIgnored() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loading(destinationDate: date, slot: .dinner, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation + 1,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(slots)
        ))
        XCTAssertEqual(store.state.phase, .loading(destinationDate: date, slot: .dinner, token: token))
    }

    func testStaleTokenIsIgnored() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let (inFlight, token) = issueToken(for: date)
        var cache = DiaryLatestFeature.Cache()
        let (_, otherToken) = cache.request(date)!
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loading(destinationDate: date, slot: .dinner, token: otherToken),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(slots)
        ))
        XCTAssertEqual(store.state.phase, .loading(destinationDate: date, slot: .dinner, token: otherToken))
    }

    func testWrongDateIsIgnored() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let otherDate = destinationDate.addingDays(1)
        let slots = makeSlots()
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loading(destinationDate: date, slot: .dinner, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: otherDate,
            slot: .dinner,
            token: token,
            result: .success(slots)
        ))
        XCTAssertEqual(store.state.phase, .loading(destinationDate: date, slot: .dinner, token: token))
    }

    func testDuplicateCompletionAfterSettleIsIgnored() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let duplicateSlots = makeSlots()
        let (inFlight, token) = issueToken(for: date)
        let settledCache = inFlight.settling(date, token: token, result: .success(slots))!
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled),
            sessionGeneration: generation,
            cache: settledCache
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in duplicateSlots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(duplicateSlots)
        ))
        if case .loaded(_, let visibleSlots, _, _) = store.state.phase {
            XCTAssertEqual(visibleSlots, slots)
        } else {
            XCTFail("expected loaded phase")
        }
    }

    func testEmptySourceSetsErrorAndNoReview() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loading(destinationDate: date, slot: .lunch, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in [] }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .lunch,
            token: token,
            result: .success([])
        )) {
            $0.phase = .loaded(destinationDate: date, slots: [], loadedForDate: date, activity: .settled)
            $0.cache = inFlight.settling(date, token: token, result: .success([]))!
            $0.loadingSlot = nil
            $0.errorMessage = String(
                format: String(localized: "diary.latest.empty"),
                DiaryLabels.mealSlotName(.lunch)
            )
            $0.review = nil
        }
    }

    func testTooManySourceSetsErrorAndNoReview() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let logs = (0..<51).map { index in
            DiaryLog(
                id: "log-\(index)",
                mealSlot: .dinner,
                title: "Item \(index)",
                quantity: NutritionQuantity(amount: "10", unit: "g"),
                logItem: .product(id: "food-1")
            )
        }
        let slots = [DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .dinner, logs: logs)]
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loading(destinationDate: date, slot: .dinner, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(slots)
        )) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = inFlight.settling(date, token: token, result: .success(slots))!
            $0.loadingSlot = nil
            $0.errorMessage = String(
                format: String(localized: "diary.latest.tooMany"),
                LogSubmissionRequestBuilder.maxDrafts
            )
            $0.review = nil
        }
    }

    func testFailurePreservesLoadedSlotsAndSetsError() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let (inFlight, token) = issueToken(for: date)
        let settledCache = inFlight.settling(date, token: token, result: .success(slots))!
        // Issue a refresh token by invalidating first.
        let invalidated = settledCache.invalidate(date)
        let (refreshInFlight, refreshToken) = invalidated.request(date)!
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .refreshing(token: refreshToken)),
            sessionGeneration: generation,
            cache: refreshInFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in throw DiaryServiceError.server("Latest lookup failed") }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: nil,
            token: refreshToken,
            result: .failure(.server("Latest lookup failed"))
        )) {
            $0.phase = .loaded(
                destinationDate: date,
                slots: slots,
                loadedForDate: date,
                activity: .failed(token: refreshToken, message: "Latest lookup failed")
            )
            $0.cache = refreshInFlight.settling(date, token: refreshToken, result: .failure(.server("Latest lookup failed")))!
            $0.loadingSlot = nil
            $0.errorMessage = "Latest lookup failed"
            $0.review = nil
        }
    }

    func testCancelReviewClearsReviewAndError() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let (cache, _) = issueToken(for: date)
        let settledCache = cache.settling(date, token: cache.entry(for: date).inFlightToken!, result: .success(slots))!
        let review = DiaryLatestReview(destinationDate: date, destinationSlot: .dinner, sourceDate: sourceDate, items: slots.first!.logs)
        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: settledCache,
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled),
            review: review,
            errorMessage: "boom"
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        }

        await store.send(.cancelLatestReview) {
            $0.review = nil
            $0.errorMessage = nil
            $0.loadingSlot = nil
        }
    }

    func testReviewTargetCapturesDateAndSlot() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let sourceDate = self.sourceDate
        let (inFlight, token) = issueToken(for: date)
        let settledCache = inFlight.settling(date, token: token, result: .success(slots))!
        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loading(destinationDate: date, slot: .dinner, token: token),
            sessionGeneration: generation,
            cache: inFlight
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(slots)
        )) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = settledCache
            $0.loadingSlot = nil
            $0.errorMessage = nil
            $0.review = DiaryLatestReview(
                destinationDate: date,
                destinationSlot: .dinner,
                sourceDate: sourceDate,
                items: slots.first!.logs
            )
        }
    }

    // MARK: - Cancellation harness

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

    func testCancellationCancelsUnderlyingWork() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let controlled = ControlledLatestClient()
        var starts = controlled.starts.makeAsyncIterator()

        var emptyCache = DiaryLatestFeature.Cache()
        let (inFlight, token) = emptyCache.request(date)!

        let store = TestStore(
            initialState: DiaryLatestFeature.State(
                destinationDate: date,
                today: today,
                sessionGeneration: generation,
                cache: emptyCache,
                phase: .idle(destinationDate: date)
            )
        ) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { before, _, _ in
                try await controlled.latestSlots(before: before, lookbackDays: DiaryLatestFeature.lookbackDays)
            }
        }

        await store.send(.prepareLatest(.dinner)) {
            $0.phase = .loading(destinationDate: date, slot: .dinner, token: token)
            $0.cache = inFlight
            $0.loadingSlot = .dinner
            $0.errorMessage = nil
        }

        guard let request = await starts.next() else {
            XCTFail("Expected latest request start")
            controlled.finish()
            return
        }
        XCTAssertEqual(request.id, 0)

        await store.send(.cancelLatest) {
            $0.phase = .idle(destinationDate: date)
            $0.cache = inFlight.invalidate(date)
            $0.loadingSlot = nil
            $0.errorMessage = nil
            $0.review = nil
        }
        await request.waitUntilCancelled()
        controlled.finish()
    }

    func testQuietRefreshCancelPreservesContentAndRejectsLateCompletion() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let sourceDate = self.sourceDate

        var emptyCache = DiaryLatestFeature.Cache()
        let (seedInFlight, seedToken) = emptyCache.request(date)!
        emptyCache = seedInFlight
        let seededCache = emptyCache.settling(date, token: seedToken, result: .success(slots))!

        let controlled = ControlledLatestClient()
        var starts = controlled.starts.makeAsyncIterator()

        let store = TestStore(
            initialState: DiaryLatestFeature.State(
                destinationDate: date,
                today: today,
                sessionGeneration: generation,
                cache: seededCache,
                phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            )
        ) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { before, _, _ in
                try await controlled.latestSlots(before: before, lookbackDays: DiaryLatestFeature.lookbackDays)
            }
        }

        var (refreshInFlight, refreshToken) = seededCache.invalidate(date).request(date)!
        await store.send(.refresh) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .refreshing(token: refreshToken))
            $0.cache = refreshInFlight
            $0.loadingSlot = nil
        }

        guard let request = await starts.next() else {
            XCTFail("Expected refresh request start")
            controlled.finish()
            return
        }

        await store.send(.cancelLatest) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = refreshInFlight.invalidate(date)
            $0.loadingSlot = nil
            $0.review = nil
            $0.errorMessage = nil
        }
        await request.waitUntilCancelled()

        // Late completion from the cancelled refresh must not mutate retained content.
        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: nil,
            token: refreshToken,
            result: .success(makeSlots())
        ))
        if case .loaded(_, let visibleSlots, _, let activity) = store.state.phase {
            XCTAssertEqual(visibleSlots, slots)
            if case .settled = activity {} else {
                XCTFail("expected settled activity after cancel")
            }
        } else {
            XCTFail("expected loaded phase")
        }

        controlled.finish()
    }

    func testDuplicateMealSlotSourceDoesNotCrashAndLastWins() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let first = DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .dinner, logs: [
            DiaryLog(id: "first", mealSlot: .dinner, title: "First", quantity: NutritionQuantity(amount: "1", unit: "g"), logItem: .product(id: "food-1"))
        ])
        let second = DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .dinner, logs: [
            DiaryLog(id: "second", mealSlot: .dinner, title: "Second", quantity: NutritionQuantity(amount: "2", unit: "g"), logItem: .product(id: "food-1"))
        ])
        let slots = [first, second]

        var emptyCache = DiaryLatestFeature.Cache()
        let (inFlight, token) = emptyCache.request(date)!
        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: inFlight,
            phase: .loading(destinationDate: date, slot: .dinner, token: token)
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        let settledCache = inFlight.settling(date, token: token, result: .success(slots))!
        let sourceDate = self.sourceDate
        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: .dinner,
            token: token,
            result: .success(slots)
        )) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = settledCache
            $0.loadingSlot = nil
            $0.errorMessage = nil
            $0.review = DiaryLatestReview(
                destinationDate: date,
                destinationSlot: .dinner,
                sourceDate: sourceDate,
                items: second.logs
            )
        }
    }
    // MARK: - Copy submission

    private func makeReview() -> DiaryLatestReview {
        DiaryLatestReview(
            destinationDate: destinationDate,
            destinationSlot: .dinner,
            sourceDate: sourceDate,
            items: makeSlots().first!.logs
        )
    }

    func testSubmitLatestBuildsExactDraftsAndInvokesHandler() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        var handlerCalls = 0
        let client = DiaryLatestFeature.SubmissionClient { drafts, names, summary, expectedGeneration in
            handlerCalls += 1
            XCTAssertEqual(drafts, expectedDrafts)
            XCTAssertEqual(drafts.map(\.date), [date, date])
            XCTAssertEqual(drafts.map(\.mealSlot), [.dinner, .dinner])
            XCTAssertEqual(drafts.map(\.timeZone), [timeZone, timeZone])
            XCTAssertEqual(names, review.items.map(\.title))
            XCTAssertEqual(summary, "Oats and 1 more")
            XCTAssertEqual(expectedGeneration, generation)
            return .success([])
        }

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }

        await store.receive(.submitCompleted(
            requestID: requestID,
            generation: generation,
            result: .success([])
        )) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(
            requestID: requestID,
            destinationDate: date,
            destinationSlot: .dinner,
            sessionGeneration: generation,
            logs: []
        )))
        XCTAssertEqual(handlerCalls, 1)
    }

    func testReadAndReviewDoNotInvokeSubmissionClient() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()
        let sourceDate = self.sourceDate
        var handlerCalls = 0
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            handlerCalls += 1
            return .success([])
        }

        var cache = DiaryLatestFeature.Cache()
        let (inFlight, token) = cache.request(date)!
        cache = inFlight.settling(date, token: token, result: .success(slots))!

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: cache,
            phase: .idle(destinationDate: date)
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
            $0.diaryLatestSubmissionClient = client
        }

        await store.send(.prepareLatest(.dinner)) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = cache
            $0.loadingSlot = nil
            $0.errorMessage = nil
            $0.review = DiaryLatestReview(
                destinationDate: date,
                destinationSlot: .dinner,
                sourceDate: sourceDate,
                items: slots.first!.logs
            )
        }
        XCTAssertEqual(handlerCalls, 0)
    }

    func testSubmitLatestGenerationGuardPreventsInvocation() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let timeZone = "Europe/Paris"
        var handlerCalls = 0
        let handler: LogSubmissionHandler = { _, _, _, completion in
            handlerCalls += 1
            completion(.success([]))
        }
        let client = DiaryLatestFeature.SubmissionClient.live(
            submissionHandler: handler,
            isCurrentGeneration: { $0 == generation + 1 }
        )

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: review.makeDrafts(timeZone: timeZone)!
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(
            requestID: requestID,
            generation: generation,
            result: .failure(.unauthorized)
        )) {
            $0.isSubmitting = false
            $0.cache = $0.cache.reset()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.phase = .sessionExpired(destinationDate: date)
        }
        await store.receive(.delegate(.sessionExpired(destinationDate: date, generation: generation)))
        XCTAssertEqual(handlerCalls, 0)
    }

    func testDuplicateSubmitTapsAreBlocked() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        let controlled = ControlledSubmissionClient()
        var starts = controlled.starts.makeAsyncIterator()

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { drafts, names, summary, expectedGeneration in
                await controlled.submit(drafts: drafts, names: names, summary: summary, expectedGeneration: expectedGeneration)
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        guard let request = await starts.next() else {
            XCTFail("Expected submission start")
            controlled.finish()
            return
        }

        await store.send(.submitLatest)
        XCTAssertEqual(controlled.invocationCount, 1)

        controlled.resume(request, result: .success([]))
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
        controlled.finish()
    }

    func testSubmitFailureAllowsExplicitRetry() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let idSource = UUIDSequence([firstRequestID, secondRequestID])
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        var calls = 0
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .failure(.failed("boom"))
            }
            return .success([])
        }

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = UUIDGenerator { idSource.next() }
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: firstRequestID, generation: generation, result: .failure(.failed("boom")))) {
            $0.isSubmitting = false
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = "boom"
            $0.copySucceeded = false
            $0.review = review
        }
        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: secondRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        await store.receive(.submitCompleted(requestID: secondRequestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: secondRequestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
        XCTAssertEqual(calls, 2)
    }

    func testFailedRetryIgnoresLateFirstCompletion() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let idSource = UUIDSequence([firstRequestID, secondRequestID])
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        var calls = 0
        let controlled = ControlledSubmissionClient()
        var starts = controlled.starts.makeAsyncIterator()
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .failure(.failed("boom"))
            }
            return await controlled.submit(drafts: [], names: [], summary: "", expectedGeneration: generation)
        }

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = UUIDGenerator { idSource.next() }
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: firstRequestID, generation: generation, result: .failure(.failed("boom")))) {
            $0.isSubmitting = false
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = "boom"
            $0.copySucceeded = false
            $0.review = review
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: secondRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        guard let request = await starts.next() else {
            XCTFail("Expected second submission start")
            controlled.finish()
            return
        }

        // Late completion from the first attempt must not affect the active second attempt.
        await store.send(.submitCompleted(requestID: firstRequestID, generation: generation, result: .success([])))
        XCTAssertTrue(store.state.isSubmitting)

        controlled.resume(request, result: .success([]))
        await store.receive(.submitCompleted(requestID: secondRequestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: secondRequestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
        XCTAssertEqual(calls, 2)
        controlled.finish()
    }

    func testSubmitUncertainFailureAllowsExplicitRetry() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let idSource = UUIDSequence([firstRequestID, secondRequestID])
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        var calls = 0
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .failure(.uncertain("maybe"))
            }
            return .success([])
        }

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = UUIDGenerator { idSource.next() }
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: firstRequestID, generation: generation, result: .failure(.uncertain("maybe")))) {
            $0.isSubmitting = false
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = "maybe"
            $0.copySucceeded = false
            $0.review = review
        }
        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: secondRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        await store.receive(.submitCompleted(requestID: secondRequestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: secondRequestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
        XCTAssertEqual(calls, 2)
    }

    func testUncertainRetryIgnoresLateFirstCompletion() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let idSource = UUIDSequence([firstRequestID, secondRequestID])
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        var calls = 0
        let controlled = ControlledSubmissionClient()
        var starts = controlled.starts.makeAsyncIterator()
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            calls += 1
            if calls == 1 {
                return .failure(.uncertain("maybe"))
            }
            return await controlled.submit(drafts: [], names: [], summary: "", expectedGeneration: generation)
        }

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = UUIDGenerator { idSource.next() }
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: firstRequestID, generation: generation, result: .failure(.uncertain("maybe")))) {
            $0.isSubmitting = false
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: firstRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = "maybe"
            $0.copySucceeded = false
            $0.review = review
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: secondRequestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        guard let request = await starts.next() else {
            XCTFail("Expected second submission start")
            controlled.finish()
            return
        }

        await store.send(.submitCompleted(requestID: firstRequestID, generation: generation, result: .success([])))
        XCTAssertTrue(store.state.isSubmitting)

        controlled.resume(request, result: .success([]))
        await store.receive(.submitCompleted(requestID: secondRequestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: secondRequestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
        XCTAssertEqual(calls, 2)
        controlled.finish()
    }

    func testSubmitUnauthorizedExpiresSessionOnce() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
                .failure(.unauthorized)
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .failure(.unauthorized))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.reset()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.phase = .sessionExpired(destinationDate: date)
        }
        await store.receive(.delegate(.sessionExpired(destinationDate: date, generation: generation)))
        await store.send(.submitCompleted(requestID: UUID(), generation: generation, result: .failure(.unauthorized)))
    }

    func testSubmitSuccessClearsAllDatesCacheAndRejectsOldReadCompletion() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let otherDate1 = destinationDate.addingDays(1)
        let otherDate2 = destinationDate.addingDays(2)
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        var emptyCache = DiaryLatestFeature.Cache()
        let (dateInFlight, dateToken) = emptyCache.request(date)!
        emptyCache = dateInFlight
        let (otherInFlight1, _) = emptyCache.request(otherDate1)!
        emptyCache = otherInFlight1
        let (otherInFlight2, _) = emptyCache.request(otherDate2)!
        emptyCache = otherInFlight2

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: emptyCache,
            phase: .loading(destinationDate: date, slot: nil, token: dateToken),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
                .success([])
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.cache = emptyCache.invalidate(date)
            $0.phase = .idle(destinationDate: date)
            $0.loadingSlot = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
            $0.phase = .idle(destinationDate: date)
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))

        XCTAssertEqual(store.state.cache.entry(for: date), .notRequested)
        XCTAssertEqual(store.state.cache.entry(for: otherDate1), .notRequested)
        XCTAssertEqual(store.state.cache.entry(for: otherDate2), .notRequested)

        // Late completion for the pre-copy read is rejected after all-date invalidation.
        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: nil,
            token: dateToken,
            result: .success(makeSlots())
        ))
        XCTAssertEqual(store.state.phase, .idle(destinationDate: date))
    }

    func testReadCancellationDoesNotCancelSubmission() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()

        let controlled = ControlledSubmissionClient()
        var starts = controlled.starts.makeAsyncIterator()

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { drafts, names, summary, expectedGeneration in
                await controlled.submit(drafts: drafts, names: names, summary: summary, expectedGeneration: expectedGeneration)
            }
            $0.timeZone = TimeZone(identifier: "Europe/Paris")!
            $0.uuid = .constant(requestID)
        }

        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!
        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        guard let request = await starts.next() else {
            XCTFail("Expected submission start")
            controlled.finish()
            return
        }

        await store.send(.cancelLatest)
        XCTAssertEqual(controlled.invocationCount, 1)
        XCTAssertTrue(store.state.isSubmitting)

        controlled.resume(request, result: .success([]))
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
        controlled.finish()
    }

    func testCancelLatestReviewIsNoOpWhileSubmitting() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let review = makeReview()

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review,
            isSubmitting: true
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        }

        await store.send(.cancelLatestReview)
        XCTAssertEqual(store.state.review, review)
        XCTAssertTrue(store.state.isSubmitting)
    }

    func testContextChangeCaptureUsesCapturedDestination() async {
        let originalDate = destinationDate
        let changedDate = destinationDate.addingDays(1)
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = DiaryLatestReview(
            destinationDate: originalDate,
            destinationSlot: .dinner,
            sourceDate: sourceDate,
            items: makeSlots().first!.logs
        )
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        let state = DiaryLatestFeature.State(
            destinationDate: changedDate,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: changedDate),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { drafts, _, _, _ in
                XCTAssertEqual(drafts.map(\.date), [originalDate, originalDate])
                return .success([])
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: originalDate,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: originalDate, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
    }

        func testSubmitSuccessRemovesCopiedSlotPreservingOtherSlots() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!
        let otherSlot = DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .lunch, logs: [
            DiaryLog(id: "lunch-1", mealSlot: .lunch, title: "Salad", quantity: NutritionQuantity(amount: "1", unit: "serving"), logItem: .product(id: "food-2"))
        ])
        let slots = makeSlots() + [otherSlot]

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
                .success([])
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
            $0.phase = .loaded(destinationDate: date, slots: [otherSlot], loadedForDate: date, activity: .settled)
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
    }

    func testLoadIfNeededWithInvalidCachePreservesRetainedContent() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()

        var cache = DiaryLatestFeature.Cache()
        let (inFlight, token) = cache.request(date)!
        cache = inFlight.settling(date, token: token, result: .failure(.server("boom")))!

        var refreshCache = cache.invalidate(date)
        let (refreshInFlight, refreshToken) = refreshCache.request(date)!
        refreshCache = refreshInFlight

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: cache,
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.loadIfNeeded) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .refreshing(token: refreshToken))
            $0.cache = refreshCache
            $0.loadingSlot = nil
            $0.errorMessage = nil
        }
        let settledCache = refreshCache.settling(date, token: refreshToken, result: .success(slots))!
        await store.receive(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: nil,
            token: refreshToken,
            result: .success(slots)
        )) {
            $0.phase = .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled)
            $0.cache = settledCache
            $0.loadingSlot = nil
            $0.errorMessage = nil
        }
    }

    func testWrongDateCompletionDoesNotDropUnrelatedSlot() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots() + [
            DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .lunch, logs: [
                DiaryLog(id: "lunch-1", mealSlot: .lunch, title: "Salad", quantity: NutritionQuantity(amount: "1", unit: "serving"), logItem: .product(id: "food-2"))
            ])
        ]

        var cache = DiaryLatestFeature.Cache()
        let (inFlight, token) = cache.request(date)!
        cache = inFlight

        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled),
            sessionGeneration: generation,
            cache: cache
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date.addingDays(1),
            slot: nil,
            token: token,
            result: .success([])
        ))
        if case .loaded(_, let visibleSlots, _, _) = store.state.phase {
            XCTAssertEqual(visibleSlots, slots)
        } else {
            XCTFail("expected loaded phase")
        }
    }

    func testOldSameDateReadCompletionIsRejected() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let slots = makeSlots()

        var cache = DiaryLatestFeature.Cache()
        let (inFlight, token) = cache.request(date)!
        cache = inFlight
        let (_, staleToken) = DiaryLatestFeature.Cache().request(date)!

        let state = DiaryLatestFeature.State(
            today: today,
            phase: .loaded(destinationDate: date, slots: slots, loadedForDate: date, activity: .settled),
            sessionGeneration: generation,
            cache: cache
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestClient = DiaryLatestFeature.Client { _, _, _ in slots }
        }

        await store.send(.latestSlotsReceived(
            generation: generation,
            destinationDate: date,
            slot: nil,
            token: staleToken,
            result: .success([])
        ))
        if case .loaded(_, let visibleSlots, _, _) = store.state.phase {
            XCTAssertEqual(visibleSlots, slots)
        } else {
            XCTFail("expected loaded phase")
        }
    }

    func testActiveSubmissionWrongGenerationCompletionIsIgnored() async {
        let date = destinationDate
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = makeReview()
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!

        let state = DiaryLatestFeature.State(
            destinationDate: date,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: date),
            review: review,
            copyRequest: DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: date,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            ),
            isSubmitting: true
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
                .success([])
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitCompleted(requestID: requestID, generation: generation + 1, result: .success([])))
        XCTAssertTrue(store.state.isSubmitting)

        await store.send(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: date, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
    }

    func testLoadedPhaseOnAnotherDateRetainsAllSlotsOnCapturedCopySuccess() async {
        let originalDate = destinationDate
        let otherDate = destinationDate.addingDays(1)
        let today = today
        let generation = generation
        let requestID = UUID()
        let review = DiaryLatestReview(
            destinationDate: originalDate,
            destinationSlot: .dinner,
            sourceDate: sourceDate,
            items: makeSlots().first!.logs
        )
        let timeZone = "Europe/Paris"
        let expectedDrafts = review.makeDrafts(timeZone: timeZone)!
        let slots = makeSlots() + [
            DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .lunch, logs: [
                DiaryLog(id: "lunch-1", mealSlot: .lunch, title: "Salad", quantity: NutritionQuantity(amount: "1", unit: "serving"), logItem: .product(id: "food-2"))
            ])
        ]

        let state = DiaryLatestFeature.State(
            destinationDate: otherDate,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .loaded(destinationDate: otherDate, slots: slots, loadedForDate: otherDate, activity: .settled),
            review: review
        )
        let store = TestStore(initialState: state) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
                .success([])
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = DiaryLatestFeature.CopyRequest(
                requestID: requestID,
                sessionGeneration: generation,
                destinationDate: originalDate,
                destinationSlot: .dinner,
                review: review,
                timeZone: timeZone,
                drafts: expectedDrafts
            )
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
            $0.review = review
        }
        await store.receive(.submitCompleted(requestID: requestID, generation: generation, result: .success([]))) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
            $0.phase = .loaded(destinationDate: otherDate, slots: slots, loadedForDate: otherDate, activity: .settled)
        }
        await store.receive(.delegate(.copied(requestID: requestID, destinationDate: originalDate, destinationSlot: .dinner, sessionGeneration: generation, logs: [])))
    }

    private final class ControlledSubmissionClient {
        struct Request: Sendable {
            let id: UUID
            let resume: @Sendable (LogSubmissionServiceResult) -> Void
        }

        private let lock = NSLock()
        private var nextID = UUID()
        private let startContinuation: AsyncStream<Request>.Continuation
        let starts: AsyncStream<Request>
        private(set) var invocationCount = 0

        init() {
            var continuation: AsyncStream<Request>.Continuation?
            self.starts = AsyncStream<Request> { continuation = $0 }
            self.startContinuation = continuation!
        }

        func submit(drafts: [LogSubmissionDraft], names: [String], summary: String, expectedGeneration: UInt64) async -> LogSubmissionServiceResult {
            lock.lock()
            invocationCount += 1
            let id = UUID()
            lock.unlock()
            return await withCheckedContinuation { continuation in
                startContinuation.yield(Request(id: id, resume: { result in
                    continuation.resume(returning: result)
                }))
            }
        }

        func resume(_ request: Request, result: LogSubmissionServiceResult) {
            request.resume(result)
        }

        func finish() {
            startContinuation.finish()
        }
    }
}

private final class UUIDSequence {
    private var ids: [UUID]
    private var index = 0

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    func next() -> UUID {
        let id = ids[index]
        index += 1
        return id
    }
}

private extension DiaryLatestFeature.Cache.Entry {
    var inFlightToken: DiaryLatestFeature.Token? {
        if case .inFlight(let token) = self { return token }
        return nil
    }
}
