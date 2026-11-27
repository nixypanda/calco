import ComposableArchitecture
import Foundation
import XCTest

@testable import CalCo

/// Migration of the retired `AppShellCoordinator`-driven log-editor harness.
/// The editor VM/dirty/back/row-switch/save/delete/unauthorized flows are now
/// owned by `LogEditorFeatureTests` (A) and the Window's typed destination
/// stack (`WindowTypedNavigationTests`); see `test-migration/test-mapping.md`
/// for every old scenario. The pure navigation-value assertions and the
/// account-scoped journal barrier are preserved below against the surviving
/// frozen APIs (`NavigationState`, `LogSubmissionStore`).
@MainActor
final class LogEditorNavigationTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let yesterday = LocalDiaryDate(year: 2026, month: 11, day: 16)
    private let baseURL = URL(string: "https://calco.example.com")!

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

    private func seedUncertainSubmission(
        in store: LogSubmissionStore,
        accountID: String
    ) throws -> PendingLogSubmission {
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: "food-1",
            foodName: "Oats",
            date: date,
            mealSlot: .breakfast,
            amount: "150",
            unit: "g",
            notes: "with milk",
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: baseURL,
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

    // MARK: - Pure navigation (unchanged behavior, surviving value type)

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

    /// Old `testLogEditorPanePlanIsConsistentAcrossLayouts`: the deleted
    /// `AppShellPanePlan` is replaced by `NavigationState.visiblePanes`, with
    /// the same compact-detail / expanded-split projection.
    func testLogEditorPaneProjectionIsConsistentAcrossLayouts() {
        var state = NavigationState(date: yesterday)
        state.openLogEditor(logID: "log-1")

        XCTAssertEqual(
            state.visiblePanes(for: .compact),
            [VisiblePane(role: .detail, pane: .logEditor(logID: "log-1"))]
        )
        XCTAssertEqual(
            state.visiblePanes(for: .expanded),
            [
                VisiblePane(role: .main, pane: .diary),
                VisiblePane(role: .detail, pane: .logEditor(logID: "log-1")),
            ]
        )
    }

    func testReselectingOpenEditorPaneIsANoOp() {
        var state = NavigationState(date: yesterday)
        state.openLogEditor(logID: "log-1")
        state.openLogEditor(logID: "log-1")

        XCTAssertEqual(state.paneStack, [.diary, .logEditor(logID: "log-1")])
        XCTAssertEqual(state.selectedDate, yesterday)
    }

    // MARK: - Frozen journal barrier (no VM, no coordinator)

    /// Old `testSignOutDuringHeldDeleteKeepsCapturedAccountBarrier`, reduced
    /// to the frozen journal invariant it asserted: an account-scoped reset
    /// invalidates only that account's uncertain entries and erases their
    /// bodies, leaving another account's entry untouched. No new writer/retry.
    func testEditorJournalBarrierIsAccountScopedAndFailClosed() throws {
        let store = makeIsolatedSubmissionStore()
        let matching = try seedUncertainSubmission(in: store, accountID: "identity-1")
        let other = try seedUncertainSubmission(in: store, accountID: "identity-2")

        try store.invalidateUnresolved(
            accountID: "identity-1",
            foodID: "food-1",
            date: date,
            reason: "session ended"
        )

        let blocked = try XCTUnwrap(store.entry(id: matching.id, accountID: "identity-1"))
        XCTAssertEqual(blocked.state, .invalidated)
        XCTAssertNil(blocked.body)
        let untouched = try XCTUnwrap(store.entry(id: other.id, accountID: "identity-2"))
        XCTAssertEqual(untouched.state, .uncertain)
        XCTAssertNotNil(untouched.body)
    }

    // MARK: - Parent navigation gating (D's deferred-confirmation API)

    private func makeLog() -> DiaryLog {
        DiaryLog(
            id: "log-1", mealSlot: .breakfast, title: "Oats", calories: 300,
            quantity: NutritionQuantity(amount: "150", unit: "g"), notes: "with milk"
        )
    }

    private func windowState(
        phase: LogEditorFeature.Phase = .editing,
        amount: String = "150"
    ) -> WindowFeature.State {
        let pid = UUID()
        let context = WindowCaptureContext(
            date: date, slot: nil, accountID: "acct-1", generation: 42,
            origin: .diary, presentationID: pid
        )
        var editor = LogEditorFeature.State(
            log: makeLog(), date: date, accountID: "acct-1",
            sessionGeneration: 42, presentationID: pid
        )
        editor.phase = phase
        editor.amount = amount
        return WindowFeature.State(
            sessionGeneration: 42,
            today: date,
            sessionAccountID: "acct-1",
            destinationStack: [.logEditor(id: "log-1", context: context)],
            logEditor: editor
        )
    }

    /// Old `testBackAndRowSwitchAreBlockedWhileEditorIsSaving` and
    /// `...WhileEditorIsDeleting`: a busy editor blocks both Back and tab
    /// switching without opening a discard prompt.
    func testWindowBlocksBackAndTabSwitchWhileEditorIsBusy() async {
        for phase in [LogEditorFeature.Phase.saving(requestID: UUID()), .deleting(requestID: UUID())] {
            let store = TestStore(initialState: windowState(phase: phase)) {
                WindowFeature()
            }
            let before = store.state

            await store.send(.requestPopDestination)
            await store.send(.requestSelectTab(.search))
            XCTAssertEqual(store.state, before)
        }
    }

    /// Old `testDirtyBackRequiresExplicitDiscardAndKeepsEditsUntilConfirmed`:
    /// Back defers to an explicit confirmation, cancel keeps the editor, and
    /// confirm drops it before navigating to root.
    func testWindowDirtyBackRequiresExplicitDiscard() async {
        let store = TestStore(initialState: windowState(amount: "275")) {
            WindowFeature()
        }

        await store.send(.requestPopDestination) {
            $0.pendingEditorDiscard = .popDestination
        }
        XCTAssertEqual(store.state.logEditor?.amount, "275")
        await store.send(.cancelEditorDiscard) {
            $0.pendingEditorDiscard = nil
        }
        await store.send(.requestPopDestination) {
            $0.pendingEditorDiscard = .popDestination
        }
        await store.send(.confirmEditorDiscard) {
            $0.pendingEditorDiscard = nil
            $0.logEditor = nil
        }
        await store.receive({ action in
            if case .popDestinationToRoot = action { return true }
            return false
        }, assert: {
            $0.destinationStack = []
        })
    }

    /// Old `testDirtyRowSwitchDiscardsFirstEditorOnlyAfterConfirmation`:
    /// a tab switch from a dirty editor defers until confirmed; a fresh editor
    /// is then created from the captured row, not from discarded edits.
    func testWindowDirtyRowSwitchDefersUntilConfirmation() async {
        let store = TestStore(initialState: windowState(amount: "175")) {
            WindowFeature()
        }

        await store.send(.requestSelectTab(.search)) {
            $0.pendingEditorDiscard = .tab(.search)
        }
        XCTAssertEqual(store.state.selectedTab, .diary)
        XCTAssertEqual(store.state.logEditor?.amount, "175")
        await store.send(.confirmEditorDiscard) {
            $0.pendingEditorDiscard = nil
            $0.logEditor = nil
        }
        await store.receive({ action in
            if case let .selectTab(tab) = action, tab == .search { return true }
            return false
        }, assert: {
            $0.selectedTab = .search
            $0.destinationStack = []
            $0.presentation = nil
        })
    }

    /// Old `testReselectingSameLogKeepsUnsavedEdits`: the identity-matched
    /// destination is not replaced while the live editor holds edits.
    func testWindowRetapsMatchingEditorKeepLiveEdits() async {
        let store = TestStore(initialState: windowState(amount: "275")) {
            WindowFeature()
        }
        let before = store.state
        guard case let .logEditor(_, capturedContext) = before.destinationStack[0] else {
            return XCTFail("Expected a log editor destination")
        }
        let destination = WindowDestination.logEditor(
            id: "log-1",
            context: capturedContext
        )

        await store.send(.pushDestination(destination))
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(store.state.logEditor?.amount, "275")
    }

    /// Old `testBackAndRowSwitchAreBlockedWhileEditorIsSaving` /
    /// `...WhileEditorIsDeleting` (row-switch half, previously only proven for
    /// Back/tab switching): opening a DIFFERENT row while the live editor is
    /// busy must not replace the child, append a second destination, or drop
    /// the unsaved edits. Loops both busy phases with distinct presentation IDs.
    func testWindowOpenNewRowWhileEditorIsBusyKeepsLiveEditor() async throws {
        for phase in [LogEditorFeature.Phase.saving(requestID: UUID()), .deleting(requestID: UUID())] {
            let store = TestStore(initialState: windowState(phase: phase, amount: "275")) {
                WindowFeature()
            }
            let before = store.state
            let liveEditorID = try XCTUnwrap(before.destinationStack.first?.id)
            let newContext = WindowCaptureContext(
                date: date, slot: nil, accountID: "acct-1", generation: 42,
                origin: .diary, presentationID: UUID()
            )

            await store.send(.pushDestination(.logEditor(id: "log-2", context: newContext)))

            XCTAssertEqual(store.state, before, "A busy editor must block a new-row push entirely")
            XCTAssertEqual(store.state.destinationStack.count, 1)
            XCTAssertEqual(store.state.destinationStack.first?.id, liveEditorID)
            XCTAssertEqual(store.state.logEditor?.logID, "log-1")
            XCTAssertEqual(store.state.logEditor?.amount, "275")
            XCTAssertEqual(store.state.logEditor?.phase, phase)
        }
    }
}
