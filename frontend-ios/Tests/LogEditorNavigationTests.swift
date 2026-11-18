import Foundation
import XCTest

@testable import CalCo

private let editorFlowBaseURL = URL(string: "https://calco.example.com")!
private let editorFlowWaitTimeout: TimeInterval = 5

private final class EditorFlowSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession

    init(session: LoginSession) { self.session = session }

    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class EditorFlowCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private actor EditorFlowDiaryService: DiaryServicing {
    var logs: [DiaryLog]
    var updateError: DiaryServiceError?
    var updateResult: DiaryLog?
    var fetchLogs: [DiaryLog]?
    var fetchCounts: [LocalDiaryDate: Int] = [:]
    var updateCount = 0
    var deleteCount = 0
    private var holdsNextUpdate = false
    private var updateStarted = false
    private var updateReleased = false
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private var holdsNextDelete = false
    private var deleteStarted = false
    private var deleteReleased = false
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    init(log: DiaryLog) {
        self.logs = [log]
    }

    func setUpdateError(_ error: DiaryServiceError?) { updateError = error }
    func setUpdateResult(_ log: DiaryLog?) { updateResult = log }
    func setFetchLogs(_ logs: [DiaryLog]?) { fetchLogs = logs }
    func appendLog(_ log: DiaryLog) { logs.append(log) }
    func calls(for date: LocalDiaryDate) -> Int { fetchCounts[date] ?? 0 }
    func updates() -> Int { updateCount }
    func deletes() -> Int { deleteCount }

    func holdNextUpdate() {
        holdsNextUpdate = true
        updateStarted = false
        updateReleased = false
    }

    func holdNextDelete() {
        holdsNextDelete = true
        deleteStarted = false
        deleteReleased = false
    }

    func waitForUpdateStart() async {
        let deadline = Date().addingTimeInterval(editorFlowWaitTimeout)
        while !updateStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(updateStarted, "Timed out waiting for the save request")
    }

    func waitForDeleteStart() async {
        let deadline = Date().addingTimeInterval(editorFlowWaitTimeout)
        while !deleteStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(deleteStarted, "Timed out waiting for the delete request")
    }

    func releaseUpdate() {
        updateReleased = true
        updateContinuation?.resume()
        updateContinuation = nil
    }

    func releaseDelete() {
        deleteReleased = true
        deleteContinuation?.resume()
        deleteContinuation = nil
    }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        fetchCounts[date, default: 0] += 1
        return DiaryDay(date: date, logs: fetchLogs ?? logs)
    }

    func getLog(id: String) async throws -> DiaryLog {
        logs.first { $0.id == id } ?? logs[0]
    }

    func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
        updateCount += 1
        if holdsNextUpdate {
            holdsNextUpdate = false
            updateStarted = true
            await withCheckedContinuation { continuation in
                if updateReleased {
                    continuation.resume()
                } else {
                    updateContinuation = continuation
                }
            }
        }
        if let updateError { throw updateError }
        return updateResult ?? logs.first { $0.id == id } ?? logs[0]
    }

    func deleteLog(id: String) async throws {
        deleteCount += 1
        if holdsNextDelete {
            holdsNextDelete = false
            deleteStarted = true
            await withCheckedContinuation { continuation in
                if deleteReleased {
                    continuation.resume()
                } else {
                    deleteContinuation = continuation
                }
            }
        }
        logs.removeAll { $0.id == id }
    }
}

@MainActor
final class LogEditorNavigationTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let yesterday = LocalDiaryDate(year: 2026, month: 11, day: 16)

    private func makeLog() -> DiaryLog {
        DiaryLog(
            id: "log-1",
            mealSlot: .breakfast,
            title: "Oats",
            calories: 300,
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: "with milk"
        )
    }

    private func makeProductLog(foodID: String = "food-1") -> DiaryLog {
        DiaryLog(
            id: "log-1",
            mealSlot: .breakfast,
            title: "Oats",
            calories: 300,
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: "with milk",
            itemReference: ItemReference(itemType: .product, id: foodID)
        )
    }

    private func makeIsolatedSubmissionStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-editor-flow-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    private func seedSubmission(
        in store: LogSubmissionStore,
        accountID: String,
        foodID: String = "food-1"
    ) throws -> PendingLogSubmission {
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: foodID,
            foodName: "Oats",
            date: date,
            mealSlot: .breakfast,
            amount: "150",
            unit: "g",
            notes: "with milk",
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: editorFlowBaseURL,
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let entry = try store.reserve(
            accountID: accountID,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )
        try store.markUncertain(
            id: entry.id,
            accountID: accountID,
            status: nil,
            message: "offline"
        )
        return try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
    }

    private func makeSession() -> LoginSession {
        LoginSession(
            identity: AuthIdentity(id: "identity-1", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-1", displayName: "Alice")
        )
    }

    private func makeCoordinator(
        diaryService: EditorFlowDiaryService,
        logSubmissionStore: LogSubmissionStore? = nil
    ) -> AppShellCoordinator {
        let session = SessionCoordinator(
            service: EditorFlowSessionService(session: makeSession()),
            cookieBaseURL: editorFlowBaseURL,
            cookieClearer: EditorFlowCookieClearer()
        )
        return AppShellCoordinator(
            client: CalCoAPIClient(baseURL: editorFlowBaseURL),
            session: session,
            diaryService: diaryService,
            searchService: SearchServiceStub(),
            foodDetailService: FoodDetailServiceStub(),
            logSubmissionStore: logSubmissionStore ?? makeIsolatedSubmissionStore(),
            todayProvider: { self.date }
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(editorFlowWaitTimeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition")
    }

    private func waitForFetchCount(
        _ service: EditorFlowDiaryService,
        date: LocalDiaryDate,
        greaterThan count: Int
    ) async {
        let deadline = Date().addingTimeInterval(editorFlowWaitTimeout)
        while Date() < deadline {
            if await service.calls(for: date) > count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let actual = await service.calls(for: date)
        XCTAssertGreaterThan(actual, count, "Timed out waiting for a diary refresh")
    }

    // MARK: - Pure navigation

    func testOpenLogEditorKeepsDateAndAddsOneDetailPane() {
        var state = NavigationState(date: yesterday, mealSlot: .breakfast)
        state.openLogEditor(logID: "log-1")

        XCTAssertEqual(state.selectedDate, yesterday)
        XCTAssertEqual(state.mealSlot, .breakfast)
        XCTAssertEqual(state.paneStack, [.diary, .logEditor(logID: "log-1")])
        XCTAssertEqual(state.editingLogID, "log-1")
        XCTAssertEqual(state.primarySection, .diary)
        XCTAssertTrue(state.hasDetail)
    }

    func testBackFromLogEditorReturnsToDiaryKeepingDate() {
        var state = NavigationState(date: yesterday)
        state.openLogEditor(logID: "log-1")

        XCTAssertTrue(state.back())
        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertEqual(state.selectedDate, yesterday)
    }

    func testLogEditorPanePlanIsConsistentAcrossLayouts() {
        var state = NavigationState(date: yesterday)
        state.openLogEditor(logID: "log-1")

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .compact),
            .stack(root: .diary, path: [.logEditor(logID: "log-1")])
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(primary: .diary, inspector: .logEditor(logID: "log-1"))
        )
    }

    func testReselectingOpenEditorPaneIsANoOp() {
        var state = NavigationState(date: yesterday)
        state.openLogEditor(logID: "log-1")
        state.openLogEditor(logID: "log-1")

        XCTAssertEqual(state.paneStack, [.diary, .logEditor(logID: "log-1")])
        XCTAssertEqual(state.selectedDate, yesterday)
    }

    func testReselectingSameLogKeepsUnsavedEdits() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let first = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        first.amount = "275"
        first.notes = "unsaved note"

        // Simulates tapping the same diary row again while the iPad inspector
        // is already showing this editor.
        diary.openLogEditor(logID: "log-1")
        guard let second = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected the log editor view model to survive")
        }

        XCTAssertTrue(first === second)
        XCTAssertEqual(second.amount, "275")
        XCTAssertEqual(second.notes, "unsaved note")
        XCTAssertEqual(coordinator.navigationState.activePane, .logEditor(logID: "log-1"))
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
    }

    func testDirtyBackRequiresExplicitDiscardAndKeepsEditsUntilConfirmed() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        editor.amount = "275"
        editor.notes = "unsaved note"

        coordinator.requestBack()
        XCTAssertEqual(coordinator.pendingEditorDiscard, .back)
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-1"),
            "A dirty editor must not close before confirmation"
        )
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)
        XCTAssertEqual(editor.amount, "275")
        XCTAssertEqual(editor.notes, "unsaved note")

        coordinator.cancelDiscardEditorChanges()
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertEqual(coordinator.navigationState.activePane, .logEditor(logID: "log-1"))

        coordinator.requestBack()
        coordinator.confirmDiscardEditorChanges()
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertNil(
            coordinator.logEditorViewModel(for: "log-1"),
            "The discarded editor must be removed before navigating"
        )

        diary.openLogEditor(logID: "log-1")
        guard let reopened = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a fresh log editor view model")
        }
        XCTAssertFalse(reopened === editor)
        XCTAssertEqual(reopened.amount, "150", "Reopening must not restore discarded edits")
        XCTAssertEqual(reopened.notes, "with milk")
    }

    func testDirtyRowSwitchDiscardsFirstEditorOnlyAfterConfirmation() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        await diaryService.appendLog(
            DiaryLog(
                id: "log-2",
                mealSlot: .dinner,
                title: "Rice",
                quantity: NutritionQuantity(amount: "200", unit: "g")
            )
        )
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        XCTAssertEqual(Set(diary.logs.map(\.id)), ["log-1", "log-2"])

        diary.openLogEditor(logID: "log-1")
        guard let first = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected the first log editor view model")
        }
        first.amount = "175"

        coordinator.openLogEditor(logID: "log-2", date: date)
        XCTAssertEqual(
            coordinator.pendingEditorDiscard,
            .openLogEditor(logID: "log-2", date: date)
        )
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-1"),
            "A dirty row switch must wait for explicit confirmation"
        )
        XCTAssertEqual(first.amount, "175")

        coordinator.confirmDiscardEditorChanges()
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-2")
        )
        XCTAssertNil(
            coordinator.logEditorViewModel(for: "log-1"),
            "Confirming a discard must remove the dirty editor, not park it"
        )
        XCTAssertNotNil(coordinator.logEditorViewModel(for: "log-2"))

        diary.openLogEditor(logID: "log-1")
        XCTAssertEqual(
            coordinator.logEditorViewModel(for: "log-1")?.amount,
            "150",
            "Reopening the discarded row must reload the saved values"
        )
    }

    func testSaveUsesAuthoritativePUTResponseWhenRefetchIsStale() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        let saved = DiaryLog(
            id: "log-1",
            mealSlot: .lunch,
            title: "Oats",
            calories: 400,
            quantity: NutritionQuantity(amount: "200", unit: "g"),
            notes: "after workout"
        )
        await diaryService.setUpdateResult(saved)
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let fetchesBeforeSave = await diaryService.calls(for: date)

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        editor.amount = "200"
        editor.mealSlot = .lunch
        editor.notes = "after workout"
        await editor.save()
        XCTAssertEqual(editor.state, .saved)
        XCTAssertEqual(editor.lastSavedLog?.quantity?.amount, "200")

        await waitForFetchCount(diaryService, date: date, greaterThan: fetchesBeforeSave)
        await waitUntil { diary.mutationNotice?.kind == .saved }

        // The fake fetch still returns the old 150 g row. The successful PUT
        // response must remain visible instead of silently reverting.
        XCTAssertEqual(diary.log(withID: "log-1")?.quantity?.amount, "200")
        XCTAssertEqual(diary.log(withID: "log-1")?.mealSlot, .lunch)
        XCTAssertEqual(diary.log(withID: "log-1")?.notes, "after workout")
        XCTAssertEqual(diary.selectedDate, date)
    }

    func testRetappingSameRowDuringSaveKeepsLiveEditor() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        editor.amount = "275"

        await diaryService.holdNextUpdate()
        let save = Task { await editor.save() }
        await diaryService.waitForUpdateStart()
        XCTAssertEqual(editor.state, .saving)
        XCTAssertFalse(editor.canEdit)

        diary.openLogEditor(logID: "log-1")
        XCTAssertTrue(
            coordinator.logEditorViewModel(for: "log-1") === editor,
            "Re-tapping the row must not replace an editor whose PUT is in flight"
        )
        XCTAssertEqual(editor.amount, "275")
        XCTAssertEqual(editor.state, .saving)

        await diaryService.releaseUpdate()
        await save.value
        XCTAssertEqual(editor.state, .saved)
    }

    func testLateSaveSuccessAfterDateChangeDoesNotMoveCurrentDate() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        await diaryService.setFetchLogs([makeLog()])
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let originFetches = await diaryService.calls(for: date)

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        editor.amount = "275"
        await diaryService.holdNextUpdate()
        let save = Task { await editor.save() }
        await diaryService.waitForUpdateStart()

        await diary.selectDate(yesterday)
        await waitUntil { diary.selectedDate == self.yesterday && diary.state == .loaded(.idle) }
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)

        await diaryService.releaseUpdate()
        await save.value

        XCTAssertEqual(editor.state, .saved)
        XCTAssertEqual(
            coordinator.navigationState.selectedDate,
            yesterday,
            "A late save success must not pull the user back to the edited date"
        )
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        let originFetchesAfterSave = await diaryService.calls(for: date)
        XCTAssertEqual(
            originFetchesAfterSave,
            originFetches,
            "A late success for another date must not refetch or navigate that date"
        )
    }

    func testBackFromLogEditorDoesNotClearSearchSelection() async {
        let coordinator = makeCoordinator(diaryService: EditorFlowDiaryService(log: makeLog()))
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let search = coordinator.searchViewModel else {
            return XCTFail("Expected a search view model")
        }

        search.selectResult(FoodSearchResult(id: "food-1", name: "Oats"))
        XCTAssertEqual(search.selectedResultID, "food-1")

        coordinator.diaryViewModel?.openLogEditor(logID: "log-1")
        XCTAssertEqual(coordinator.navigationState.activePane, .logEditor(logID: "log-1"))
        coordinator.back()

        XCTAssertEqual(search.selectedResultID, "food-1")
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
    }

    func testBackAndRowSwitchAreBlockedWhileEditorIsSaving() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        await diaryService.appendLog(
            DiaryLog(
                id: "log-2",
                mealSlot: .dinner,
                title: "Rice",
                quantity: NutritionQuantity(amount: "200", unit: "g")
            )
        )
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        editor.amount = "275"
        await diaryService.holdNextUpdate()
        let save = Task { await editor.save() }
        await diaryService.waitForUpdateStart()
        XCTAssertEqual(editor.state, .saving)

        coordinator.requestBack()
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-1"),
            "A saving editor must not be discarded or closed"
        )
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)

        coordinator.openLogEditor(logID: "log-2", date: date)
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-1"),
            "A row switch must not replace a saving editor"
        )
        XCTAssertNil(coordinator.logEditorViewModel(for: "log-2"))

        await diaryService.releaseUpdate()
        await save.value
        XCTAssertEqual(editor.state, .saved)
    }

    func testBackAndRowSwitchAreBlockedWhileEditorIsDeleting() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        await diaryService.appendLog(
            DiaryLog(
                id: "log-2",
                mealSlot: .dinner,
                title: "Rice",
                quantity: NutritionQuantity(amount: "200", unit: "g")
            )
        )
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        await diaryService.holdNextDelete()
        let deletion = Task { await editor.delete() }
        await diaryService.waitForDeleteStart()
        XCTAssertEqual(editor.state, .deleting)

        coordinator.requestBack()
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-1"),
            "A deleting editor must stay visible until DELETE resolves"
        )
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)

        coordinator.openLogEditor(logID: "log-2", date: date)
        XCTAssertEqual(
            coordinator.navigationState.activePane,
            .logEditor(logID: "log-1")
        )
        XCTAssertNil(coordinator.logEditorViewModel(for: "log-2"))

        await diaryService.releaseDelete()
        await deletion.value
        XCTAssertEqual(editor.state, .deleted)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
    }

    func testSignOutDuringHeldDeleteKeepsCapturedAccountBarrier() async throws {
        let diaryService = EditorFlowDiaryService(log: makeProductLog())
        let store = makeIsolatedSubmissionStore()
        let matching = try seedSubmission(
            in: store,
            accountID: "identity-1",
            foodID: "food-1"
        )
        let otherAccount = try seedSubmission(
            in: store,
            accountID: "identity-2",
            foodID: "food-1"
        )
        let coordinator = makeCoordinator(
            diaryService: diaryService,
            logSubmissionStore: store
        )
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        await diaryService.holdNextDelete()
        let deletion = Task { await editor.delete() }
        await diaryService.waitForDeleteStart()

        // The delete outlives the session. Its captured account, not the
        // now-reset feature graph, must remain the barrier's scope.
        let signOutResult = await coordinator.signOut()
        XCTAssertEqual(signOutResult, .completed)
        XCTAssertNil(coordinator.logEditorViewModel(for: "log-1"))

        await diaryService.releaseDelete()
        await deletion.value

        let blocked = try XCTUnwrap(
            store.entry(id: matching.id, accountID: "identity-1")
        )
        XCTAssertEqual(blocked.state, .invalidated)
        XCTAssertNil(blocked.body)
        let untouched = try XCTUnwrap(
            store.entry(id: otherAccount.id, accountID: "identity-2")
        )
        XCTAssertEqual(untouched.state, .uncertain)
        XCTAssertNotNil(untouched.body)
        let deletes = await diaryService.deletes()
        XCTAssertEqual(deletes, 1)
    }

    // MARK: - Coordinator integration

    func testSaveFromHistoricalDayReturnsToDiaryAndRefreshesThatDate() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        await diary.previousDay()
        await waitUntil { diary.selectedDate == self.yesterday && diary.state == .loaded(.idle) }
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        let fetchesBeforeEdit = await diaryService.calls(for: yesterday)

        diary.openLogEditor(logID: "log-1")
        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .logEditor(logID: "log-1")]
        )
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }

        editor.amount = "200"
        await editor.save()

        let updateCount = await diaryService.updates()
        XCTAssertEqual(editor.state, .saved)
        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertTrue(coordinator.diaryViewModel === diary)

        await waitForFetchCount(diaryService, date: yesterday, greaterThan: fetchesBeforeEdit)
        await waitUntil { diary.mutationNotice?.kind == .saved }
        XCTAssertEqual(diary.mutationNotice?.title, "Oats")
        XCTAssertEqual(diary.mutationNotice?.message, String(localized: "diary.mutation.saved"))
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(diary.state, .loaded(.idle))

        diary.clearMutationNotice()
        XCTAssertNil(diary.mutationNotice)
    }

    func testDeleteFromEditorReturnsToDiaryAndRefreshesSelectedDate() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let fetchesBeforeDelete = await diaryService.calls(for: date)

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        await editor.delete()

        let deleteCount = await diaryService.deletes()
        XCTAssertEqual(editor.state, .deleted)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        await waitForFetchCount(diaryService, date: date, greaterThan: fetchesBeforeDelete)
        await waitUntil { diary.mutationNotice?.kind == .deleted }
        XCTAssertEqual(diary.mutationNotice?.message, String(localized: "diary.mutation.deleted"))
        XCTAssertEqual(diary.selectedDate, date)

        // Changing date clears stale feedback.
        await diary.previousDay()
        XCTAssertNil(diary.mutationNotice)
    }

    func testUnauthorizedFromEditorExpiresSession() async {
        let diaryService = EditorFlowDiaryService(log: makeLog())
        await diaryService.setUpdateError(.unauthorized)
        let coordinator = makeCoordinator(diaryService: diaryService)
        await coordinator.start()
        await waitUntil { coordinator.diaryViewModel?.state == .loaded(.idle) }
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        diary.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected a log editor view model")
        }
        await editor.save()

        XCTAssertEqual(editor.state, .sessionExpired)
        XCTAssertEqual(coordinator.phase, .signedOut(.expired))
        XCTAssertEqual(coordinator.screen, .login)
    }
}

private struct SearchServiceStub: FoodSearchServicing {
    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult] { [] }
}

private struct FoodDetailServiceStub: FoodDetailServicing {
    func fetchFoodDetail(id: String) async throws -> FoodDetail {
        FoodDetail(id: id, name: "Food")
    }

    func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        CreatedFoodLog(date: request.date, mealSlot: request.mealSlot)
    }
}
