import ComposableArchitecture
import XCTest

@testable import CalCo

/// Replacement for the retired coordinator/editor-VM bridge harness. Lane D
/// deleted `AppShellCoordinator`, `DiaryEditorBridge` and the legacy editor VM;
/// the accepted behavior is now owned by the `DiaryFeature` reducer's typed
/// authoritative-apply and mutation-notice actions. These tests keep the old
/// security/content assertions: a successful local row wins over a stale
/// refetch, a delete tombstone survives reconciliation, notices are
/// generation/date guarded, and a stale completion cannot mutate newer state.
/// The held-GET-before-notice sequencing contract is tracked separately in
/// `test-migration/test-mapping.md` until D lands the completion hook.
@MainActor
final class DiaryEditorBridgeTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 16)
    private let generation: UInt64 = 42

    private func log(id: String = "log-1", amount: String) -> DiaryLog {
        DiaryLog(
            id: id,
            mealSlot: .breakfast,
            title: "Oats",
            quantity: NutritionQuantity(amount: amount, unit: "g"),
            notes: "original"
        )
    }

    private func day(logs: [DiaryLog]) -> DiaryDay {
        DiaryDay(
            date: date,
            logs: logs,
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    private func store(day: DiaryDay) -> TestStore<DiaryFeature.State, DiaryFeature.Action> {
        TestStore(
            initialState: DiaryFeature.State(
                today: date,
                phase: .loaded(day: day, activity: .settled),
                sessionGeneration: generation,
                cache: DiaryFeature.Cache().seed(self.date, value: day)
            )
        ) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }
    }

    /// Old bridge assertion: the authoritative PUT row must stay visible when
    /// a later GET still returns the old row.
    func testAuthoritativeSavedLogWinsOverStaleRefetch() async {
        let original = log(amount: "150")
        let saved = log(amount: "200")
        let initialDay = day(logs: [original])
        let store = self.store(day: initialDay)

        await store.send(.applySavedLog(
            generation: generation, log: saved, replacingID: saved.id, onDate: date
        )) {
            let updated = self.day(logs: [saved])
            $0.savedLogOverrides = [self.date: ["log-1": saved]]
            $0.phase = .loaded(day: updated, activity: .settled)
            $0.cache = $0.cache.invalidate(self.date).seed(self.date, value: updated)
        }
        XCTAssertEqual(store.state.visibleDay?.logs.first?.quantity?.amount, "200")

        // A stale refetch returns the old 150 g row; the local override wins.
        // The token must come from the store's live cache, not a fresh one.
        await store.send(.invalidateCachedDay(generation: generation, date: date)) {
            $0.cache = $0.cache.invalidate(self.date)
        }
        guard let (_, token) = store.state.cache.request(date) else {
            return XCTFail("Expected a fresh request token")
        }
        await store.send(DiaryFeature.Action.diaryReceived(
            generation: generation, requestDate: date, token: token, day: initialDay
        ))
        XCTAssertEqual(store.state.visibleDay?.logs.first?.quantity?.amount, "200")
    }

    /// Old bridge assertion: a successful DELETE removes the row and a stale
    /// refetch cannot resurrect it.
    func testAuthoritativeDeleteTombstoneSurvivesStaleRefetch() async {
        let original = log(amount: "150")
        let initialDay = day(logs: [original])
        let store = self.store(day: initialDay)

        await store.send(.applyDeletedLog(
            generation: generation, id: "log-1", onDate: date
        )) {
            let updated = self.day(logs: [])
            $0.deletedIDs = [self.date: ["log-1"]]
            $0.phase = .loaded(day: updated, activity: .settled)
            $0.cache = $0.cache.invalidate(self.date).seed(self.date, value: updated)
        }
        XCTAssertTrue(store.state.visibleDay?.logs.isEmpty ?? false)

        await store.send(.invalidateCachedDay(generation: generation, date: date)) {
            $0.cache = $0.cache.invalidate(self.date)
        }
        guard let (_, token) = store.state.cache.request(date) else {
            return XCTFail("Expected a fresh request token")
        }
        await store.send(DiaryFeature.Action.diaryReceived(
            generation: generation, requestDate: date, token: token, day: initialDay
        ))
        XCTAssertTrue(store.state.visibleDay?.logs.isEmpty ?? false)
    }

    /// Old bridge assertion: mutation feedback belongs to its captured day and
    /// generation; a stale or wrong-day notice can never rewrite current UI.
    func testMutationNoticeIsGenerationAndDateGuarded() async {
        let notice = DiaryMutationNotice(kind: .saved, title: "Oats")
        let store = store(day: day(logs: [log(amount: "150")]))

        await store.send(.showMutationNotice(
            generation: generation + 1, date: date, notice: notice
        ))
        await store.send(.showMutationNotice(
            generation: generation, date: otherDate, notice: notice
        ))
        XCTAssertNil(store.state.mutationNotice)

        await store.send(.showMutationNotice(generation: generation, date: date, notice: notice)) {
            $0.mutationNotice = notice
        }
        await store.send(.clearMutationNotice) {
            $0.mutationNotice = nil
        }
    }

    /// Old bridge assertion: a retained completion from a replaced editor
    /// cannot mutate a newer session/date.
    func testStaleCompletionCannotMutateNewerState() async {
        var cache = DiaryFeature.Cache().reset()
        guard let (inFlight, token) = cache.request(date) else {
            return XCTFail("Expected a fresh request token")
        }
        let store = TestStore(
            initialState: DiaryFeature.State(
                today: date,
                phase: .initialLoading(requestDate: date, token: token),
                sessionGeneration: generation,
                cache: inFlight
            )
        ) {
            DiaryFeature()
        }

        await store.send(DiaryFeature.Action.diaryReceived(
            generation: generation + 1, requestDate: date, token: token, day: day(logs: [])
        ))
        await store.send(DiaryFeature.Action.diaryReceived(
            generation: generation, requestDate: otherDate, token: token, day: day(logs: [])
        ))
        XCTAssertEqual(store.state.completedFetchCount, 0)
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: date, token: token))
    }

    // MARK: - Authoritative-read-before-notice (D's completion hook)

    /// The notice is queued on the reducer but must not be displayed until the
    /// authoritative GET for that date actually settles.
    func testMutationNoticeWaitsForAuthoritativeReadCompletion() async {
        var cache = DiaryFeature.Cache().reset()
        guard let (inFlight, token) = cache.request(date) else {
            return XCTFail("Expected a fresh request token")
        }
        let notice = DiaryMutationNotice(kind: .saved, title: "Oats")
        let store = TestStore(
            initialState: DiaryFeature.State(
                today: date,
                phase: .loaded(
                    day: day(logs: []),
                    activity: .refreshing(requestDate: date, token: token)
                ),
                sessionGeneration: generation,
                cache: inFlight
            )
        ) {
            DiaryFeature()
        }

        await store.send(DiaryFeature.Action.queueMutationNotice(generation: generation, date: date, notice: notice)) {
            $0.pendingMutationNotice = DiaryFeature.PendingMutationNotice(
                generation: self.generation, date: self.date, notice: notice
            )
        }
        XCTAssertNil(store.state.mutationNotice, "A queued notice must not be shown before the GET")

        let fresh = day(logs: [])
        await store.send(DiaryFeature.Action.diaryReceived(
            generation: generation, requestDate: date, token: token, day: fresh
        )) {
            $0.pendingMutationNotice = nil
            $0.completedFetchCount += 1
            $0.cache = inFlight.settling(self.date, token: token, result: .success(fresh)) ?? inFlight
            $0.phase = .loaded(day: fresh, activity: .settled)
        }
        await store.receive(DiaryFeature.Action.delegate(.mutationNoticeReady(
            generation: generation, date: date, notice: notice
        )))
    }

    /// A changed date or generation before the read settles must retire the
    /// held notice rather than showing it on the wrong screen/session.
    func testMutationNoticeReadyIsRecheckedAfterRead() async {
        var cache = DiaryFeature.Cache().reset()
        guard let (inFlight, token) = cache.request(date) else {
            return XCTFail("Expected a fresh request token")
        }
        let notice = DiaryMutationNotice(kind: .saved, title: "Oats")
        let store = TestStore(
            initialState: DiaryFeature.State(
                today: date,
                phase: .loaded(
                    day: day(logs: []),
                    activity: .refreshing(requestDate: date, token: token)
                ),
                sessionGeneration: generation,
                cache: inFlight
            )
        ) {
            DiaryFeature()
        }

        await store.send(DiaryFeature.Action.queueMutationNotice(generation: generation, date: date, notice: notice)) {
            $0.pendingMutationNotice = DiaryFeature.PendingMutationNotice(
                generation: self.generation, date: self.date, notice: notice
            )
        }
        await store.send(DiaryFeature.Action.queueMutationNotice(generation: generation + 1, date: date, notice: notice))
        XCTAssertNotNil(store.state.pendingMutationNotice)

        await store.send(DiaryFeature.Action.diaryReceived(
            generation: generation + 1, requestDate: date, token: token, day: day(logs: [])
        ))
        XCTAssertNil(store.state.mutationNotice)
    }

    /// Window projects the notice only after Diary's real completion delegate,
    /// and re-checks generation/date at that point.
    func testWindowProjectsNoticeOnlyAfterCompletionDelegate() async {
        let notice = DiaryMutationNotice(kind: .saved, title: "Oats")
        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: date,
                sessionAccountID: "acct-1"
            )
        ) {
            WindowFeature()
        }

        await store.send(.diary(.delegate(.mutationNoticeReady(
            generation: generation + 1, date: date, notice: notice
        ))))
        await store.send(.diary(.delegate(.mutationNoticeReady(
            generation: generation, date: otherDate, notice: notice
        ))))
        XCTAssertNil(store.state.diary.diary.mutationNotice)

        await store.send(.diary(.delegate(.mutationNoticeReady(
            generation: generation, date: date, notice: notice
        ))))
        await store.receive({ action in
            guard case let .diary(screenAction) = action,
                  case let .diary(diaryAction) = screenAction,
                  case let .showMutationNotice(receivedGeneration, receivedDate, receivedNotice) = diaryAction
            else { return false }
            return receivedGeneration == self.generation
                && receivedDate == self.date
                && receivedNotice == notice
        }) {
            $0.diary.diary.mutationNotice = notice
        }
    }

    // MARK: - Real held dependency effect (no injected response action)

    /// Deterministic gate on the REAL `diaryClient.fetchDay` dependency. The
    /// editor's authoritative save must enter one GET, hold the notice, and
    /// only display it after the real day reply settles.
    func testWindowEditorSaveWaitsForRealAuthoritativeFetchBeforeNotice() async {
        let held = HeldDiaryFetch()
        let original = log(amount: "150")
        let saved = log(amount: "200")
        let initialDay = day(logs: [original])
        let authoritativeDay = day(logs: [saved])
        var diary = DiaryFeature.State(
            date: date,
            today: date,
            sessionGeneration: generation,
            cache: DiaryFeature.Cache().seed(date, value: initialDay)
        )
        diary.phase = .loaded(day: initialDay, activity: .settled)

        let presentationID = UUID()
        let context = WindowCaptureContext(
            date: date, slot: .breakfast, accountID: "acct-1", generation: generation,
            origin: .diary, presentationID: presentationID
        )
        var editor = LogEditorFeature.State(
            log: original, date: date, accountID: "acct-1",
            sessionGeneration: generation, presentationID: presentationID
        )
        editor.amount = "200"
        let notice = DiaryMutationNotice(kind: .saved, title: "Oats")
        let latest = DiaryLatestFeature.State(
            destinationDate: date, today: date, sessionGeneration: generation,
            phase: .idle(destinationDate: date)
        )

        let store = TestStore(
            initialState: WindowFeature.State(
                sessionGeneration: generation,
                today: date,
                sessionAccountID: "acct-1",
                diary: DiaryScreenFeature.State(diary: diary, latest: latest),
                destinationStack: [.logEditor(id: "log-1", context: context)],
                logEditor: editor
            )
        ) {
            WindowFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { requestedDate, expectedGeneration in
                try await held.fetch(requestedDate, expectedGeneration)
            })
        }

        await store.send(WindowFeature.Action.logEditor(.delegate(.saved(
            presentationID: presentationID,
            logID: "log-1",
            date: date,
            authoritativeDiaryLog: saved,
            notice: notice,
            generation: generation
        )))) {
            $0.logEditor = nil
            $0.destinationStack = []
        }
        await store.receive({ action in
            guard case let .applyAuthoritativeMutation(delivery) = action else { return false }
            return delivery.generation == self.generation
                && delivery.affectedDates == [self.date]
                && delivery.logs.isEmpty
                && delivery.editor == .saved(
                    originalID: "log-1", date: self.date, log: saved, notice: notice
                )
        })

        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .diary(child) = screen,
                  case let .applySavedLog(receivedGeneration, log, replacingID, onDate) = child
            else { return false }
            return receivedGeneration == self.generation
                && log == saved && replacingID == "log-1" && onDate == self.date
        }) {
            let updated = self.day(logs: [saved])
            $0.diary.diary.savedLogOverrides = [self.date: ["log-1": saved]]
            $0.diary.diary.phase = .loaded(day: updated, activity: .settled)
            $0.diary.diary.cache = $0.diary.diary.cache
                .invalidate(self.date)
                .seed(self.date, value: updated)
        }
        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .diary(child) = screen,
                  case let .queueMutationNotice(receivedGeneration, receivedDate, receivedNotice) = child
            else { return false }
            return receivedGeneration == self.generation
                && receivedDate == self.date && receivedNotice == notice
        }) {
            $0.diary.diary.pendingMutationNotice = DiaryFeature.PendingMutationNotice(
                generation: self.generation, date: self.date, notice: notice
            )
        }
        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .diary(child) = screen,
                  case .refresh = child
            else { return false }
            return true
        }) {
            let updated = self.day(logs: [saved])
            var cache = $0.diary.diary.cache.invalidate(self.date)
            guard let (inFlight, token) = cache.request(self.date) else {
                XCTFail("Expected the refresh to issue a fresh token")
                return
            }
            cache = inFlight
            $0.diary.diary.cache = cache
            $0.diary.diary.phase = .loaded(
                day: updated,
                activity: .refreshing(requestDate: self.date, token: token)
            )
            $0.diary.diary.pendingGoalOverride = nil
            $0.diary.diary.pendingPrefsOverride = nil
        }

        // The real dependency has now been entered exactly once with the
        // captured selected date and generation. The notice is still held.
        await held.waitForEntry()
        let recordedCalls = await held.recordedCalls()
        XCTAssertEqual(recordedCalls.count, 1)
        XCTAssertEqual(recordedCalls.first?.0, date)
        XCTAssertEqual(recordedCalls.first?.1, generation)
        XCTAssertNil(store.state.diary.diary.mutationNotice)
        XCTAssertNotNil(store.state.diary.diary.pendingMutationNotice)

        guard case let .inFlight(token) = store.state.diary.diary.cache.entry(for: date) else {
            return XCTFail("Expected an in-flight authoritative read")
        }
        await held.release(authoritativeDay)

        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .diary(child) = screen,
                  case let .diaryReceived(receivedGeneration, receivedDate, receivedToken, receivedDay) = child
            else { return false }
            return receivedGeneration == self.generation
                && receivedDate == self.date
                && receivedToken == token
                && receivedDay == authoritativeDay
        }) {
            $0.diary.diary.pendingMutationNotice = nil
            $0.diary.diary.completedFetchCount += 1
            $0.diary.diary.savedLogOverrides = [:]
            $0.diary.diary.cache = $0.diary.diary.cache.settling(
                self.date, token: token, result: .success(authoritativeDay)
            ) ?? $0.diary.diary.cache
            $0.diary.diary.phase = .loaded(day: authoritativeDay, activity: .settled)
        }
        // The child DiaryFeature emits its notice-ready delegate first; the
        // composed DiaryScreenFeature then forwards the same notice upward.
        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .diary(child) = screen,
                  case let .delegate(delegate) = child,
                  case let .mutationNoticeReady(receivedGeneration, receivedDate, receivedNotice) = delegate
            else { return false }
            return receivedGeneration == self.generation
                && receivedDate == self.date && receivedNotice == notice
        })
        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .delegate(delegate) = screen,
                  case let .mutationNoticeReady(receivedGeneration, receivedDate, receivedNotice) = delegate
            else { return false }
            return receivedGeneration == self.generation
                && receivedDate == self.date && receivedNotice == notice
        })
        await store.receive({ action in
            guard case let .diary(screen) = action,
                  case let .diary(child) = screen,
                  case let .showMutationNotice(receivedGeneration, receivedDate, receivedNotice) = child
            else { return false }
            return receivedGeneration == self.generation
                && receivedDate == self.date && receivedNotice == notice
        }) {
            $0.diary.diary.mutationNotice = notice
        }
        await store.finish()
        XCTAssertEqual(store.state.diary.diary.mutationNotice, notice)
    }
}

private actor HeldDiaryFetch {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<DiaryDay, Error>?
    private var calls: [(LocalDiaryDate, UInt64)] = []

    func fetch(_ date: LocalDiaryDate, _ generation: UInt64) async throws -> DiaryDay {
        calls.append((date, generation))
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release(_ day: DiaryDay) {
        guard let response else {
            XCTFail("No held authoritative fetch to release")
            return
        }
        self.response = nil
        response.resume(returning: day)
    }

    func recordedCalls() -> [(LocalDiaryDate, UInt64)] { calls }
}
