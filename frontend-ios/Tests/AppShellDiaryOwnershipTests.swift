import Combine
import XCTest

@testable import CalCo

/// Coordinator-side ownership tests. These reuse the existing fake
/// `SessionServicing`/`LogSubmissionSending` shapes: no keychain, no network,
/// no sleeping. They pin the single-writer contract — legacy mode keeps its
/// unchanged `DiaryViewModel.refresh()`, store-backed mode delivers exactly one
/// `DiaryMutationDelivery` and performs no legacy refresh/lookup.
@MainActor
final class AppShellDiaryOwnershipTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let firstDate = LocalDiaryDate(year: 2026, month: 11, day: 15)
    private let secondDate = LocalDiaryDate(year: 2026, month: 11, day: 16)
    private let serverDate = LocalDiaryDate(year: 2026, month: 11, day: 17)

    /// `start()` returns before the detached bootstrap load settles. Wait on the
    /// legacy VM's own completion counter — no sleep, no yield, no polling — so
    /// every later fetch assertion is relative to a real bootstrap baseline.
    private func awaitLegacyBootstrapCompletion(_ coordinator: AppShellCoordinator) async {
        guard let viewModel = coordinator.diaryViewModel else {
            XCTFail("Missing legacy diary view model for bootstrap")
            return
        }
        // Every caller waits for the FIRST authoritative bootstrap read of a
        // fresh coordinator VM — not for "one more" read relative to whatever
        // happened to finish before we subscribed.
        let target = 1
        if viewModel.completedFetchCount >= target { return }

        let box = SinkBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.continuation = continuation
            box.cancellable = viewModel.$completedFetchCount.sink { count in
                guard !box.fulfilled, count >= target else { return }
                // Latch first so a re-entrant emission cannot deliver twice,
                // take the continuation before resuming, and tear down the
                // subscription so box -> cancellable -> sink -> box cannot
                // survive the normal in-flight completion path.
                box.fulfilled = true
                let pending = box.continuation
                box.continuation = nil
                box.cancellable?.cancel()
                box.cancellable = nil
                pending?.resume()
            }
            // `$completedFetchCount.sink` emits the current value synchronously.
            // If that emission already met the target, the continuation was
            // resumed inside the sink; tear the subscription down after the
            // cancellable is assigned.
            if box.fulfilled {
                box.cancellable?.cancel()
                box.cancellable = nil
            }
        }
    }

    /// Direct helper contract: already-settled bootstrap returns immediately
    /// (twice, idempotently) and an in-flight bootstrap waits for exactly its
    /// first completion. Neither branch issues an extra read.
    func testAwaitLegacyBootstrapCompletionCoversBothBranchesWithoutExtraGet() async {
        let fastService = DiaryFetchSpy()
        let fast = makeCoordinator(diaryService: fastService)
        let fastPhase = await fast.start()
        guard case .signedIn = fastPhase else { return XCTFail("Expected signed in, got \(fastPhase)") }
        await awaitLegacyBootstrapCompletion(fast)
        let settledCount = fastService.fetchCount
        XCTAssertGreaterThanOrEqual(settledCount, 1)
        await awaitLegacyBootstrapCompletion(fast)
        XCTAssertEqual(fastService.fetchCount, settledCount, "Helper must not trigger a fetch")

        let held = HeldFirstFetchDiaryService()
        let slow = makeCoordinator(diaryService: held)
        let slowPhase = await slow.start()
        guard case .signedIn = slowPhase else { return XCTFail("Expected signed in, got \(slowPhase)") }
        await held.waitForFirstStart()

        let flag = BootstrapHelperFlag()
        let task = Task { @MainActor in
            await self.awaitLegacyBootstrapCompletion(slow)
            flag.returned = true
        }
        // A MainActor task cannot run until this synchronous scope suspends.
        XCTAssertFalse(flag.returned, "Helper returned before the held bootstrap settled")
        held.finishFirst(day: DiaryDay(date: self.today, logs: []))
        await task.value

        XCTAssertTrue(flag.returned, "Helper did not resume after the first completion")
        XCTAssertEqual(held.fetchCallCount, 1, "Helper must not issue an extra read")
    }

    func testLegacyIsDefaultAndKeepsSingleLegacyRefreshWithoutCallback() async {
        let diary = DiaryFetchSpy()
        let coordinator = makeCoordinator(diaryService: diary)
        let recorder = CallbackRecorder()
        coordinator.installDiaryMutationCallback { delivery in
            recorder.record(delivery)
        }
        XCTAssertEqual(coordinator.diaryScreenOwnership, .legacy)

        let phase = await coordinator.start()
        guard case .signedIn = phase else { return XCTFail("Expected signed in, got \(phase)") }
        await awaitLegacyBootstrapCompletion(coordinator)
        let generation = coordinator.session.sessionGeneration
        let baselineFetches = diary.fetchCount
        XCTAssertGreaterThanOrEqual(baselineFetches, 1)

        let completion = CompletionRecorder()
        coordinator.submitDraftsForFeature(
            [makeDraft(date: firstDate)],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: generation,
            completion: completion.record
        )
        await completion.wait()

        XCTAssertEqual(completion.results.count, 1)
        guard case .success = completion.results[0] else {
            return XCTFail("Expected a successful submission")
        }
        XCTAssertEqual(diary.fetchCount, baselineFetches + 1, "Legacy must refresh exactly once")
        XCTAssertTrue(recorder.deliveries.isEmpty, "Legacy mode must not invoke the callback")
    }

    func testStoreBackedMultiDaySubmissionWritesOneCallbackAndNoLegacyRefresh() async {
        let diary = DiaryFetchSpy()
        let created = [
            makeLog(id: "log-1", date: firstDate),
            makeLog(id: "log-2", date: secondDate),
            makeLog(id: "log-3", date: serverDate),
        ]
        let sender = StubSubmissionSender(logs: created)
        let coordinator = makeCoordinator(
            diaryService: diary,
            ownership: .storeBackedScreen,
            sender: sender
        )
        let recorder = CallbackRecorder()
        coordinator.installDiaryMutationCallback { delivery in
            recorder.record(delivery)
        }

        let phase = await coordinator.start()
        guard case .signedIn = phase else { return XCTFail("Expected signed in, got \(phase)") }
        await awaitLegacyBootstrapCompletion(coordinator)
        let generation = coordinator.session.sessionGeneration
        let baselineFetches = diary.fetchCount

        let completion = CompletionRecorder()
        coordinator.submitDraftsForFeature(
            [makeDraft(date: firstDate), makeDraft(date: secondDate)],
            itemNames: ["Apple", "Pear"],
            summary: "Two",
            expectedGeneration: generation,
            completion: completion.record
        )
        await completion.wait()

        XCTAssertEqual(completion.results.count, 1)
        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(diary.fetchCount, baselineFetches, "Store-backed mode must not refresh legacy VM")
        XCTAssertEqual(recorder.deliveries.count, 1, "Exactly one callback for one write")
        guard let delivery = recorder.deliveries.first else { return }
        XCTAssertEqual(delivery.generation, generation)
        // Union of two draft dates and three server dates, de-duplicated, in
        // first-seen order — no date is silently skipped.
        XCTAssertEqual(delivery.affectedDates, [firstDate, secondDate, serverDate])
        XCTAssertEqual(delivery.logs, created)
    }

    /// A stale captured generation fails closed before the writer and still
    /// completes exactly once. No callback, no write, no refresh.
    func testStoreBackedStaleSubmissionDeliversNoCallbackAndCompletesOnce() async {
        let diary = DiaryFetchSpy()
        let sender = StubSubmissionSender(logs: [makeLog(id: "log-1", date: firstDate)])
        let coordinator = makeCoordinator(
            diaryService: diary,
            ownership: .storeBackedScreen,
            sender: sender
        )
        let recorder = CallbackRecorder()
        coordinator.installDiaryMutationCallback { delivery in
            recorder.record(delivery)
        }

        let phase = await coordinator.start()
        guard case .signedIn = phase else { return XCTFail("Expected signed in, got \(phase)") }
        await awaitLegacyBootstrapCompletion(coordinator)
        let stale = coordinator.session.sessionGeneration + 1
        let baselineFetches = diary.fetchCount

        let completion = CompletionRecorder()
        coordinator.submitDraftsForFeature(
            [makeDraft(date: firstDate)],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: stale,
            completion: completion.record
        )
        await completion.wait()

        XCTAssertEqual(completion.results.count, 1)
        XCTAssertEqual(completion.results.first ?? .success([]), .failure(.unauthorized))
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(diary.fetchCount, baselineFetches)
        XCTAssertTrue(recorder.deliveries.isEmpty)
    }

    /// Completion is delivered only after the awaiting callback has finished,
    /// and never twice. This pins the async handoff ordering of the writer.
    func testStoreBackedCompletionFollowsAwaitingCallbackExactlyOnce() async {
        let coordinator = makeCoordinator(
            ownership: .storeBackedScreen,
            sender: StubSubmissionSender(logs: [])
        )
        let order = CallbackRecorder()
        coordinator.installDiaryMutationCallback { _ in
            order.note("callback")
        }

        let phase = await coordinator.start()
        guard case .signedIn = phase else { return XCTFail("Expected signed in, got \(phase)") }
        let generation = coordinator.session.sessionGeneration
        let completion = CompletionRecorder()
        coordinator.submitDraftsForFeature(
            [makeDraft(date: firstDate)],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: generation,
            completion: { result in
                order.note("completion")
                completion.record(result)
            }
        )
        await completion.wait()

        XCTAssertEqual(order.notes, ["callback", "completion"])
        XCTAssertEqual(completion.results.count, 1)
    }

    /// Generation flips while the POST is held open (after the synchronous
    /// pre-write guard, before the response). The real availability handler
    /// bumps the coordinator generation; the resumed success must not reach the
    /// callback, and completion must fire exactly once as unauthorized.
    func testMidWriteGenerationFlipFailsClosedWithOneCompletionAndNoRetry() async {
        let sender = HeldSubmissionSender()
        let diary = DiaryFetchSpy()
        let coordinator = makeCoordinator(
            diaryService: diary,
            ownership: .storeBackedScreen,
            sender: sender
        )
        let recorder = CallbackRecorder()
        coordinator.installDiaryMutationCallback { delivery in
            recorder.record(delivery)
        }

        let phase = await coordinator.start()
        guard case .signedIn = phase else { return XCTFail("Expected signed in, got \(phase)") }
        await awaitLegacyBootstrapCompletion(coordinator)
        let generation = coordinator.session.sessionGeneration

        let completion = CompletionRecorder()
        coordinator.submitDraftsForFeature(
            [makeDraft(date: firstDate)],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: generation,
            completion: completion.record
        )
        await sender.waitForSendStart()

        let didFlip = coordinator.session.handleUnauthorized(
            atGeneration: generation,
            reason: .expired
        )
        XCTAssertTrue(didFlip, "The real availability handler must accept the captured generation")
        let baselineFetches = diary.fetchCount

        sender.resume(.success([makeLog(id: "log-late", date: firstDate)]))
        await completion.wait()

        XCTAssertEqual(sender.sendCount, 1, "No auto retry after a mid-write generation flip")
        XCTAssertEqual(completion.results.count, 1, "Completion must fire exactly once")
        XCTAssertEqual(completion.results.first ?? .success([]), .failure(.unauthorized))
        XCTAssertTrue(recorder.deliveries.isEmpty, "A stale write must not be delivered")
        XCTAssertEqual(diary.fetchCount, baselineFetches, "No refresh for the wrong session")
    }

    /// If the generation flips while the installed async callback is being
    /// awaited, the coordinator's post-await fence must still complete exactly
    /// once and must not re-enter the writer or refresh a new session.
    func testGenerationFlipWhileAwaitingCallbackDoesNotDoubleComplete() async {
        let coordinator = makeCoordinator(
            ownership: .storeBackedScreen,
            sender: StubSubmissionSender(logs: [])
        )
        let recorder = CallbackRecorder()
        coordinator.installDiaryMutationCallback { _ in
            recorder.note("callback")
            coordinator.session.handleUnauthorized(reason: .expired)
        }

        let phase = await coordinator.start()
        guard case .signedIn = phase else { return XCTFail("Expected signed in, got \(phase)") }
        await awaitLegacyBootstrapCompletion(coordinator)
        let generation = coordinator.session.sessionGeneration
        let completion = CompletionRecorder()
        coordinator.submitDraftsForFeature(
            [makeDraft(date: firstDate)],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: generation,
            completion: { result in
                recorder.note("completion")
                completion.record(result)
            }
        )
        await completion.wait()

        XCTAssertEqual(recorder.notes, ["callback", "completion"])
        XCTAssertEqual(completion.results.count, 1)
    }

    func testDeliveryDedupsDraftAndServerDates() {
        let delivery = DiaryMutationDelivery(
            generation: 1,
            drafts: [
                makeDraft(date: firstDate),
                makeDraft(date: secondDate),
                makeDraft(date: firstDate),
            ],
            logs: [
                makeLog(id: "a", date: secondDate),
                makeLog(id: "b", date: serverDate),
            ]
        )
        XCTAssertEqual(delivery.affectedDates, [firstDate, secondDate, serverDate])
        XCTAssertEqual(delivery.logs.map(\.id), ["a", "b"])
    }

    // MARK: - Harness

    @MainActor
    private func makeCoordinator(
        diaryService: (any DiaryServicing)? = nil,
        ownership: DiaryScreenOwnership = .legacy,
        sender: (any LogSubmissionSending)? = nil
    ) -> AppShellCoordinator {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-diary-ownership", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-diary-ownership", displayName: "Alice")
        )
        let coordinatorSession = SessionCoordinator(
            service: OwnershipSessionService(session: session),
            cookieBaseURL: baseURL,
            cookieClearer: OwnershipCookieClearer()
        )
        return AppShellCoordinator(
            client: CalCoAPIClient(baseURL: baseURL),
            session: coordinatorSession,
            diaryService: diaryService ?? DiaryFetchSpy(),
            logSubmissionStore: makeIsolatedStore(),
            logSubmissionService: LogSubmissionService(
                sender: sender ?? StubSubmissionSender(logs: [])
            ),
            diaryScreenOwnership: ownership,
            todayProvider: { self.today }
        )
    }

    @MainActor
    private func makeIsolatedStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-diary-ownership-\(UUID().uuidString)", isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    private func makeDraft(date: LocalDiaryDate) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: .product(id: "qa-apple"),
            date: date,
            mealSlot: .breakfast,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "UTC"
        )
    }

    private func makeLog(id: String, date: LocalDiaryDate) -> FoodLog {
        FoodLog(
            id: id,
            logDate: date,
            mealSlot: .breakfast,
            item: .product(ProductLogItemSnapshot(id: "qa-apple", name: "Apple")),
            quantity: NutritionQuantity(amount: "100", unit: "g"),
            nutrients: [
                NutrientAmountValue(code: NutrientCodes.energyKcal, amount: "100", unit: "kcal")
            ]
        )
    }
}

// MARK: - Doubles

private final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveriesStorage: [DiaryMutationDelivery] = []
    private var notesStorage: [String] = []

    var deliveries: [DiaryMutationDelivery] {
        lock.lock(); defer { lock.unlock() }; return deliveriesStorage
    }

    var notes: [String] {
        lock.lock(); defer { lock.unlock() }; return notesStorage
    }

    func record(_ delivery: DiaryMutationDelivery) {
        lock.lock(); deliveriesStorage.append(delivery); lock.unlock()
    }

    func note(_ value: String) {
        lock.lock(); notesStorage.append(value); lock.unlock()
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var resultsStorage: [LogSubmissionServiceResult] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var results: [LogSubmissionServiceResult] {
        lock.lock(); defer { lock.unlock() }; return resultsStorage
    }

    func record(_ result: LogSubmissionServiceResult) {
        lock.lock()
        resultsStorage.append(result)
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    /// Continuation gate, never a sleep or duration guess.
    func wait() async {
        lock.lock()
        let alreadyDone = !resultsStorage.isEmpty
        lock.unlock()
        guard !alreadyDone else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.install(c)
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resultsStorage.isEmpty {
            self.continuation = continuation
            lock.unlock()
        } else {
            lock.unlock()
            continuation.resume()
        }
    }
}

/// Holds one POST open so the session generation can flip between the writer's
/// synchronous guard and its response. Start/response rendezvous use
/// continuations only — no sleep, yield polling, or timeout guessing.
private final class HeldSubmissionSender: LogSubmissionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<[FoodLog], Error>?
    private var pendingResult: Result<[FoodLog], Error>?
    private var sendsStorage = 0

    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sendsStorage }

    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] {
        lock.lock()
        sendsStorage += 1
        let starter = startWaiter
        startWaiter = nil
        lock.unlock()
        starter?.resume()

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[FoodLog], Error>) in
            lock.lock()
            if let pending = pendingResult {
                pendingResult = nil
                lock.unlock()
                Self.finish(pending, with: c)
            } else {
                responseWaiter = c
                lock.unlock()
            }
        }
    }

    func waitForSendStart() async {
        lock.lock()
        let alreadyStarted = sendsStorage > 0
        lock.unlock()
        guard !alreadyStarted else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.installStartWaiter(c)
        }
    }

    func resume(_ result: Result<[FoodLog], Error>) {
        lock.lock()
        guard let waiter = responseWaiter else {
            pendingResult = result
            lock.unlock()
            return
        }
        responseWaiter = nil
        lock.unlock()
        Self.finish(result, with: waiter)
    }

    private func installStartWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if sendsStorage > 0 {
            lock.unlock()
            continuation.resume()
        } else {
            startWaiter = continuation
            lock.unlock()
        }
    }

    private static func finish(
        _ result: Result<[FoodLog], Error>,
        with continuation: CheckedContinuation<[FoodLog], Error>
    ) {
        switch result {
        case .success(let logs): continuation.resume(returning: logs)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

private final class SinkBox: @unchecked Sendable {
    var cancellable: AnyCancellable?
    var continuation: CheckedContinuation<Void, Never>?
    var fulfilled = false
}

private final class BootstrapHelperFlag: @unchecked Sendable {
    var returned = false
}

/// Holds the first bootstrap GET open so the helper's in-flight branch can be
/// driven deterministically, with continuation gates instead of sleeps/polls.
private final class HeldFirstFetchDiaryService: DiaryServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<DiaryDay, Error>?
    private var firstStarted = false
    private var count = 0

    var fetchCallCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        lock.lock()
        count += 1
        let isFirst = count == 1
        if isFirst { firstStarted = true }
        let starter = startContinuation
        startContinuation = nil
        lock.unlock()
        starter?.resume()
        guard isFirst else { return DiaryDay(date: date, logs: []) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<DiaryDay, Error>) in
            lock.lock()
            responseContinuation = c
            lock.unlock()
        }
    }

    func waitForFirstStart() async {
        lock.lock()
        let already = firstStarted
        lock.unlock()
        guard !already else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.installStartWaiter(c)
        }
    }

    func finishFirst(day: DiaryDay) {
        lock.lock()
        guard let waiter = responseContinuation else {
            lock.unlock()
            return
        }
        responseContinuation = nil
        lock.unlock()
        waiter.resume(returning: day)
    }

    private func installStartWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if firstStarted {
            lock.unlock()
            continuation.resume()
        } else {
            startContinuation = continuation
            lock.unlock()
        }
    }
}

private final class DiaryFetchSpy: DiaryServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        lock.lock(); count += 1; lock.unlock()
        return DiaryDay(date: date, logs: [])
    }
}

private final class StubSubmissionSender: LogSubmissionSending, @unchecked Sendable {
    private let lock = NSLock()
    private let logs: [FoodLog]
    private var sends = 0

    init(logs: [FoodLog]) { self.logs = logs }

    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sends }

    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] {
        lock.lock(); sends += 1; lock.unlock()
        return logs
    }
}

private final class OwnershipSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession
    init(session: LoginSession) { self.session = session }
    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout() async throws {}
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class OwnershipCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}
