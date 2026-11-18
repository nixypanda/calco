//
//  AppShell.swift
//
//  Root SwiftUI shell and coordinator for the signed-in CalCo experience. The
//  coordinator owns all feature view models, scopes them to a session generation
//  so stale 401s cannot invalidate a newer session, and preserves them across
//  compact/expanded layout changes. The shell fails closed without a valid
//  HTTPS API URL and projects phase into a pure screen, keeping restore
//  retryable and unsupported accounts out of signed-in content.
//

import Combine
import SwiftUI

// MARK: - Coordinator

public enum EditorDiscardRequest: Equatable, Sendable {
    case back
    case openLogEditor(logID: String, date: LocalDiaryDate)
    case showDiary
    case showSearch
    case startLogging(slot: MealSlot, date: LocalDiaryDate)
    case openFoodDetail(foodID: String, date: LocalDiaryDate, mealSlot: MealSlot?)
}

@MainActor
public final class AppShellCoordinator: ObservableObject, AuthFeatureCoordinating {
    public let client: CalCoAPIClient
    public let session: SessionCoordinator
    public let diaryService: any DiaryServicing
    public let searchService: any FoodSearchServicing
    public let foodDetailService: any FoodDetailServicing
    public let logSubmissionStore: LogSubmissionStore
    public let todayProvider: () -> LocalDiaryDate

    public let configurationError: String?

    @Published public var navigationState: NavigationState
    @Published public private(set) var pendingSubmission: PendingLogSubmission?
    /// All recoverable entries in most-recent-first order. The banner shows a
    /// count and lets the user review each entry instead of hiding all but one.
    @Published public private(set) var pendingSubmissions: [PendingLogSubmission] = []
    /// Set when a dirty editor would otherwise be closed, replaced, or left
    /// behind. The shell asks for explicit discard confirmation.
    @Published public private(set) var pendingEditorDiscard: EditorDiscardRequest?
    @Published private var featureGraph: FeatureGraph = .absent

    private var cancellables: Set<AnyCancellable> = []
    private var deliveredSubmissionIDs: Set<String> = []
    /// Dismissal applies to the exact entry version the user saw. Any state
    /// change (for example a new conflict) makes it visible again.
    private var dismissedSubmissions: [String: Date] = [:]
    /// Bounded by log ID rather than growing once per editor instance.
    private var deliveredLogEditorSuccesses: [String: ObjectIdentifier] = [:]

    public var currentUser: AuthUser? { featureGraph.readyState?.user }
    public var diaryViewModel: DiaryViewModel? { featureGraph.readyState?.diary }
    public var searchViewModel: SearchViewModel? { featureGraph.readyState?.search }

    public var phase: SessionCoordinator.Phase { session.phase }

    public var screen: AppShellScreen {
        AppShellScreen(phase: session.phase, configurationError: configurationError)
    }

    public init(
        client: CalCoAPIClient? = nil,
        session: SessionCoordinator? = nil,
        diaryService: (any DiaryServicing)? = nil,
        searchService: (any FoodSearchServicing)? = nil,
        foodDetailService: (any FoodDetailServicing)? = nil,
        logSubmissionStore: LogSubmissionStore? = nil,
        todayProvider: (() -> LocalDiaryDate)? = nil
    ) {
        let resolvedClient: CalCoAPIClient
        let resolvedTodayProvider = todayProvider ?? { Self.today() }
        let configurationError: String?

        if let client {
            resolvedClient = client
            configurationError = nil
        } else if let url = CalCoRuntimeConfiguration.baseURL {
            resolvedClient = CalCoAPIClient(baseURL: url)
            configurationError = nil
        } else {
            resolvedClient = CalCoAPIClient(
                baseURL: URL(string: "https://calco.invalid")!
            )
            configurationError = String(
                localized: "app.configuration.missingAPIURL",
                comment: "Shown when the app has no valid API base URL"
            )
        }

        let resolvedSession = session ?? SessionCoordinator(client: resolvedClient)
        self.client = resolvedClient
        self.configurationError = configurationError
        self.session = resolvedSession
        self.diaryService = diaryService ?? CalCoDiaryServiceAdapter(client: resolvedClient)
        self.searchService = searchService ?? CalCoFoodSearchServiceAdapter(client: resolvedClient)
        self.foodDetailService = foodDetailService
            ?? CalCoFoodDetailServiceAdapter(client: resolvedClient)
        // Every WindowGroup scene gets its own coordinator, but all windows
        // must share one journal cache so a live POST in one window blocks a
        // delete in another. Tests can still inject an isolated store.
        self.logSubmissionStore = logSubmissionStore ?? .shared
        self.todayProvider = resolvedTodayProvider
        self.navigationState = NavigationState(date: resolvedTodayProvider())

        resolvedSession.registerSessionStateReset { [weak self] in
            self?.resetSessionScopedState()
        }

        resolvedSession.$phase
            .sink { [weak self] phase in
                self?.synchronizeFeatureGraph(with: phase)
            }
            .store(in: &cancellables)

        self.logSubmissionStore.$revision
            .sink { [weak self] _ in
                self?.refreshPendingSubmission()
            }
            .store(in: &cancellables)

        resolvedSession.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        synchronizeFeatureGraph(with: resolvedSession.phase)
    }

    // MARK: - AuthFeatureCoordinating

    nonisolated public func authFeatureDidSignIn(_ user: AuthUser) {}

    nonisolated public func authFeatureDidRejectAdmin(_ user: AuthUser) {
        Task { @MainActor [weak self] in
            guard let self,
                  case .unsupportedAccount(let current) = self.session.phase,
                  current == user else { return }
            self.resetSessionScopedState()
        }
    }

    nonisolated public func authFeatureDidRequestSignOut() {
        Task { @MainActor [weak self] in
            await self?.signOut()
        }
    }

    nonisolated public func authFeatureDidReportSessionUnavailable(
        _ reason: SessionUnavailableReason
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.session.isSignedIn else { return }
            self.session.handleUnauthorized(reason: reason)
        }
    }

    // MARK: - Session lifecycle

    @discardableResult
    public func start() async -> SessionCoordinator.Phase {
        await session.start()
    }

    @discardableResult
    public func retryRestore() async -> SessionCoordinator.Phase {
        await session.restore()
    }

    @discardableResult
    public func signOut() async -> SessionCoordinator.SignOutResult {
        await session.signOut()
    }

    // MARK: - Session-scoped feature state

    private enum FeatureGraph {
        struct Ready {
            let user: AuthUser
            let generation: UInt64
            let diary: DiaryViewModel
            let search: SearchViewModel
            var foodDetails: [String: FoodDetailViewModel]
            var logEditors: [String: LogEditorViewModel]
        }

        case absent
        case ready(Ready)

        var readyState: Ready? {
            guard case .ready(let ready) = self else { return nil }
            return ready
        }
    }

    private func synchronizeFeatureGraph(with phase: SessionCoordinator.Phase) {
        guard case .signedIn(let user) = phase else { return }
        installFeatureGraph(for: user)
    }

    private func resetSessionScopedState() {
        let previous = featureGraph
        featureGraph = .absent
        deliveredSubmissionIDs.removeAll()
        deliveredLogEditorSuccesses.removeAll()
        dismissedSubmissions.removeAll()
        pendingSubmission = nil
        pendingSubmissions = []
        pendingEditorDiscard = nil
        previous.readyState?.diary.resetForSessionChange()
        previous.readyState?.search.invalidateSession()
        navigationState = NavigationState(date: todayProvider())
    }

    private func installFeatureGraph(for user: AuthUser) {
        let generation = session.sessionGeneration
        if let ready = featureGraph.readyState,
           ready.user == user,
           ready.generation == generation {
            return
        }

        let previous = featureGraph
        featureGraph = .absent
        deliveredSubmissionIDs.removeAll()
        deliveredLogEditorSuccesses.removeAll()
        dismissedSubmissions.removeAll()
        previous.readyState?.diary.resetForSessionChange()
        previous.readyState?.search.invalidateSession()
        pendingSubmission = nil
        pendingSubmissions = []
        pendingEditorDiscard = nil

        let today = todayProvider()
        navigationState = NavigationState(date: today)

        let diaryVM = DiaryViewModel(
            service: diaryService,
            today: today,
            initialDate: today,
            todayProvider: todayProvider,
            onAddFood: { [weak self] slot, date in
                self?.startLoggingIfCurrent(
                    slot: slot,
                    date: date,
                    generation: generation
                )
            },
            onDateChange: { [weak self] date in
                self?.synchronizeNavigationDate(
                    date,
                    generation: generation
                )
            },
            onOpenLogEditor: { [weak self] logID, date in
                self?.openLogEditor(logID: logID, date: date, generation: generation)
            },
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            }
        )

        let searchVM = SearchViewModel(
            originDate: today,
            originMealSlot: nil,
            service: searchService,
            onSelectFood: { [weak self] foodID, date, mealSlot in
                self?.openFoodDetailIfCurrent(
                    foodID,
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation
                )
            },
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            }
        )

        featureGraph = .ready(FeatureGraph.Ready(
            user: user,
            generation: generation,
            diary: diaryVM,
            search: searchVM,
            foodDetails: [:],
            logEditors: [:]
        ))
        refreshPendingSubmission()

        Task { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            await diaryVM.load()
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        guard generation == session.sessionGeneration,
              let ready = featureGraph.readyState else { return false }
        return ready.generation == generation
    }

    private func synchronizeNavigationDate(
        _ date: LocalDiaryDate,
        generation: UInt64
    ) {
        guard isCurrent(generation),
              navigationState.selectedDate != date else { return }
        var state = navigationState
        state.updateSelectedDate(date)
        navigationState = state
        searchViewModel?.updateContext(date: date, mealSlot: state.mealSlot)
    }

    private func startLoggingIfCurrent(
        slot: MealSlot,
        date: LocalDiaryDate,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        startLogging(slot: slot, date: date)
    }

    private func openFoodDetailIfCurrent(
        _ foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        openFoodDetail(foodID, date: date, mealSlot: mealSlot)
    }

    private func handleSessionExpired(generation: UInt64) {
        session.handleUnauthorized(atGeneration: generation, reason: .expired)
    }

    // MARK: - Signed-in orchestration

    public func startLogging(slot: MealSlot, date: LocalDiaryDate) {
        guard !requestDiscardIfNeeded(for: .startLogging(slot: slot, date: date)) else {
            return
        }
        performStartLogging(slot: slot, date: date)
    }

    private func performStartLogging(slot: MealSlot, date: LocalDiaryDate) {
        var state = navigationState
        state.selectDate(date)
        state.startLogging(mealSlot: slot)
        navigationState = state
        searchViewModel?.updateContext(date: date, mealSlot: slot)
    }

    public func openFoodDetail(_ foodID: String, date: LocalDiaryDate, mealSlot: MealSlot?) {
        guard !requestDiscardIfNeeded(
            for: .openFoodDetail(foodID: foodID, date: date, mealSlot: mealSlot)
        ) else {
            return
        }
        performOpenFoodDetail(foodID, date: date, mealSlot: mealSlot)
    }

    private func performOpenFoodDetail(
        _ foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
        var state = navigationState
        state.showDetail(foodID: foodID, date: date, mealSlot: mealSlot)
        navigationState = state
        searchViewModel?.updateContext(date: state.selectedDate, mealSlot: state.mealSlot)

        guard var ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        let generation = ready.generation

        // Re-tapping the same row while its log is in flight must not replace
        // the live view model (and lose its callback/recovery state).
        if let existing = ready.foodDetails[foodID],
           existing.originDate == date,
           existing.originMealSlot == mealSlot,
           existing.isBusy {
            return
        }

        let identity = FoodDetailSuccessIdentity()
        let viewModel = FoodDetailViewModel(
            foodID: foodID,
            originDate: date,
            originMealSlot: mealSlot,
            service: foodDetailService,
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            },
            onSubmissionSuccess: { [weak self, identity] success in
                guard let source = identity.viewModel else { return }
                self?.handleFoodDetailSuccess(
                    success,
                    expectedGeneration: generation,
                    source: source
                )
            },
            onCheckDiary: { [weak self] diaryDate in
                self?.showDiary(
                    date: diaryDate,
                    generation: generation
                )
            },
            accountID: ready.user.id,
            baseURL: client.configuration.baseURL,
            submissionStore: logSubmissionStore
        )
        identity.viewModel = viewModel
        ready.foodDetails[foodID] = viewModel
        featureGraph = .ready(ready)
    }

    private final class FoodDetailSuccessIdentity {
        weak var viewModel: FoodDetailViewModel?
    }

    public func foodDetailViewModel(for foodID: String) -> FoodDetailViewModel? {
        featureGraph.readyState?.foodDetails[foodID]
    }

    // MARK: - Log editor

    private final class LogEditorSuccessIdentity {
        weak var viewModel: LogEditorViewModel?
    }

    public func logEditorViewModel(for logID: String) -> LogEditorViewModel? {
        featureGraph.readyState?.logEditors[logID]
    }

    public func openLogEditor(logID: String, date: LocalDiaryDate) {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        openLogEditor(logID: logID, date: date, generation: ready.generation)
    }

    private func openLogEditor(logID: String, date: LocalDiaryDate, generation: UInt64) {
        guard isCurrent(generation),
              let ready = featureGraph.readyState,
              let log = ready.diary.log(withID: logID) else { return }

        // Tapping the same row must preserve its editor in every state,
        // including while a PUT is in flight. Only terminal editors are
        // replaced by a fresh edit session.
        if let existing = ready.logEditors[logID], existing.date == date,
           !existing.isTerminal {
            var currentState = navigationState
            if currentState.activePane != .logEditor(logID: logID) {
                currentState.openLogEditor(logID: logID)
                navigationState = currentState
            }
            return
        }

        // A saving/deleting editor must stay visible until the operation
        // resolves, even when the user taps a different diary row.
        if let active = activeEditor, active.isBusy {
            return
        }

        // Switching directly from a dirty editor to another row must not throw
        // away the first row's edits without an explicit decision.
        if let active = activeDirtyEditor,
           active.logID != logID,
           requestDiscardIfNeeded(for: .openLogEditor(logID: logID, date: date)) {
            return
        }

        performOpenLogEditor(log, logID: logID, date: date, generation: generation)
    }

    private func performOpenLogEditor(
        _ log: DiaryLog,
        logID: String,
        date: LocalDiaryDate,
        generation: UInt64
    ) {
        guard isCurrent(generation),
              let ready = featureGraph.readyState else { return }

        let editor = LogEditorViewModel(
            log: log,
            date: date,
            service: diaryService,
            accountID: ready.user.id,
            submissionStore: logSubmissionStore,
            matchingPendingCount: { [weak self] in
                guard let self,
                      let productID = log.productID else {
                    return 0
                }
                return self.logSubmissionStore.unresolved(
                    accountID: ready.user.id,
                    foodID: productID,
                    date: date
                ).count
            }
        )
        let identity = LogEditorSuccessIdentity()
        identity.viewModel = editor

        editor.onSaved = { [weak self, identity] editedDate in
            guard let self, let editor = identity.viewModel else { return }
            self.handleLogEditorMutation(
                editor,
                date: editedDate,
                kind: .saved,
                generation: generation
            )
        }
        editor.onDeleted = { [weak self, identity] editedDate in
            guard let self, let editor = identity.viewModel else { return }
            self.handleLogEditorMutation(
                editor,
                date: editedDate,
                kind: .deleted,
                generation: generation
            )
        }
        editor.onSessionExpired = { [weak self] in
            self?.handleSessionExpired(generation: generation)
        }

        var updated = ready
        updated.logEditors[logID] = editor
        featureGraph = .ready(updated)

        var state = navigationState
        state.openLogEditor(logID: logID)
        navigationState = state
    }

    private func handleLogEditorMutation(
        _ viewModel: LogEditorViewModel,
        date: LocalDiaryDate,
        kind: DiaryMutationKind,
        generation: UInt64
    ) {
        guard isCurrent(generation),
              let ready = featureGraph.readyState,
              ready.logEditors[viewModel.logID] === viewModel else { return }

        let identifier = ObjectIdentifier(viewModel)
        guard deliveredLogEditorSuccesses[viewModel.logID] != identifier else { return }
        deliveredLogEditorSuccesses[viewModel.logID] = identifier
        pendingEditorDiscard = nil

        var blockedPendingCount = 0
        if kind == .deleted {
            // The PUT/DELETE response is authoritative. Apply it locally before
            // any refetch so an older in-flight GET cannot reopen stale values.
            ready.diary.applyDeletedLog(logID: viewModel.logID, on: date)
            // The editor durably blocked matching journal entries before it
            // sent DELETE, using the account captured when it was opened.
            blockedPendingCount = viewModel.blockedPendingCount
        } else if kind == .saved, let saved = viewModel.lastSavedLog {
            ready.diary.applySavedLog(
                saved,
                replacing: viewModel.logID,
                on: date
            )
        }

        var state = navigationState
        let wasActiveEditor = state.activePane == .logEditor(logID: viewModel.logID)
        if wasActiveEditor {
            _ = state.back()
            navigationState = state
        }

        let title = viewModel.title
        Task { [weak self] in
            guard let self,
                  let current = self.featureGraph.readyState,
                  current.generation == generation,
                  generation == self.session.sessionGeneration else { return }
            let diary = current.diary
            guard diary.selectedDate == date else {
                // A late success after the user moved to another day must
                // never pull their current date back to the edited log.
                return
            }
            await diary.refresh()
            guard self.diaryViewModel === diary, diary.selectedDate == date else {
                return
            }
            diary.showMutationNotice(
                DiaryMutationNotice(
                    kind: kind,
                    title: title,
                    blockedPendingCount: blockedPendingCount
                )
            )
        }
    }

    private var activeEditor: LogEditorViewModel? {
        guard case .logEditor(let logID) = navigationState.activePane else {
            return nil
        }
        return featureGraph.readyState?.logEditors[logID]
    }

    private var activeDirtyEditor: LogEditorViewModel? {
        guard let editor = activeEditor, editor.hasUnsavedChanges else {
            return nil
        }
        return editor
    }

    /// Returns true when the action was deferred or blocked instead of being
    /// performed. A saving/deleting editor cannot be discarded or navigated
    /// away from, even if it was dirty when the request began.
    @discardableResult
    private func requestDiscardIfNeeded(for request: EditorDiscardRequest) -> Bool {
        guard let editor = activeEditor else { return false }
        if editor.isBusy { return true }
        guard editor.hasUnsavedChanges else { return false }
        pendingEditorDiscard = request
        return true
    }

    public func requestBack() {
        guard !requestDiscardIfNeeded(for: .back) else { return }
        back()
    }

    public func confirmDiscardEditorChanges() {
        guard let request = pendingEditorDiscard else { return }
        guard let editor = activeEditor, !editor.isBusy else {
            pendingEditorDiscard = nil
            return
        }
        pendingEditorDiscard = nil
        // Remove the dirty editor before navigating. Keeping it in the graph
        // would let a later tap reopen the same discarded values.
        discardActiveEditor()
        switch request {
        case .back:
            back()
        case .openLogEditor(let logID, let date):
            guard let ready = featureGraph.readyState,
                  ready.generation == session.sessionGeneration,
                  let log = ready.diary.log(withID: logID) else { return }
            performOpenLogEditor(
                log,
                logID: logID,
                date: date,
                generation: ready.generation
            )
        case .showDiary:
            performShowDiary()
        case .showSearch:
            performShowSearch()
        case .startLogging(let slot, let date):
            performStartLogging(slot: slot, date: date)
        case .openFoodDetail(let foodID, let date, let mealSlot):
            performOpenFoodDetail(foodID, date: date, mealSlot: mealSlot)
        }
    }

    private func discardActiveEditor() {
        guard case .logEditor(let logID) = navigationState.activePane,
              var ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        ready.logEditors.removeValue(forKey: logID)
        featureGraph = .ready(ready)
        deliveredLogEditorSuccesses.removeValue(forKey: logID)
    }

    public func cancelDiscardEditorChanges() {
        pendingEditorDiscard = nil
    }

    public func showDiary() {
        guard !requestDiscardIfNeeded(for: .showDiary) else { return }
        performShowDiary()
    }

    private func performShowDiary() {
        var state = navigationState
        state.finishLogging()
        navigationState = state
        searchViewModel?.clearSelection()
    }

    private func showDiary(date: LocalDiaryDate, generation: UInt64) {
        guard isCurrent(generation) else { return }
        var state = navigationState
        state.selectDate(date)
        navigationState = state
        searchViewModel?.clearSelection()
        searchViewModel?.updateContext(date: date, mealSlot: state.mealSlot)

        Task { [weak self] in
            guard let self,
                  let current = self.featureGraph.readyState,
                  current.generation == generation,
                  generation == self.session.sessionGeneration else { return }
            let diary = current.diary
            if diary.selectedDate == date {
                await diary.refresh()
            } else {
                await diary.selectDate(date)
            }
        }
    }

    public func reviewPendingSubmission() {
        guard let pendingSubmission else { return }
        reviewPendingSubmission(pendingSubmission)
    }

    public func reviewPendingSubmission(_ pending: PendingLogSubmission) {
        guard pending.accountID == currentUser?.id else { return }
        openFoodDetail(
            pending.draft.foodID,
            date: pending.draft.date,
            mealSlot: pending.draft.mealSlot
        )
    }

    /// Hides the global banner for the entries it currently shows. This is a
    /// UI preference only; the journal and inline recovery remain untouched.
    public func dismissPendingSubmissionBanner() {
        for pending in pendingSubmissions {
            dismissedSubmissions[pending.id] = pending.updatedAt
        }
        refreshPendingSubmission()
    }

    /// Explicitly resolves a definitively conflicted journal row. The caller
    /// must obtain confirmation before invoking it.
    @discardableResult
    public func discardPendingSubmission(_ pending: PendingLogSubmission) -> Bool {
        guard pending.accountID == currentUser?.id,
              pending.state == .conflicted
        else { return false }
        do {
            try logSubmissionStore.remove(id: pending.id, accountID: pending.accountID)
        } catch {
            return false
        }
        dismissedSubmissions.removeValue(forKey: pending.id)
        refreshPendingSubmission()
        return true
    }

    private func refreshPendingSubmission() {
        guard let user = currentUser else {
            pendingSubmissions = []
            pendingSubmission = nil
            return
        }
        let visible = logSubmissionStore
            .attentionEntries(accountID: user.id)
            .filter { dismissedSubmissions[$0.id] != $0.updatedAt }
        pendingSubmissions = visible
        pendingSubmission = visible.first
    }

    public func showSearch() {
        guard !requestDiscardIfNeeded(for: .showSearch) else { return }
        performShowSearch()
    }

    private func performShowSearch() {
        var state = navigationState
        while state.hasDetail {
            _ = state.back()
        }
        if state.activePane != .foodSearch {
            state.pushSearch()
        }
        navigationState = state
        searchViewModel?.clearSelection()
        searchViewModel?.updateContext(date: state.selectedDate, mealSlot: state.mealSlot)
    }

    public func back() {
        var state = navigationState
        // Only a *food* detail owns search selection. The log editor is also an
        // inspector pane but has nothing to do with the search flow.
        let wasShowingFoodDetail = state.activePane.contextualFoodID != nil
        guard state.back() else { return }
        navigationState = state
        if wasShowingFoodDetail {
            searchViewModel?.clearSelection()
        }
        searchViewModel?.updateContext(date: state.selectedDate, mealSlot: state.mealSlot)
    }

    func handleFoodDetailSuccess(_ viewModel: FoodDetailViewModel) {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        let success = viewModel.lastSubmissionSuccess ?? FoodLogSubmissionSuccess(
            submissionID: "legacy-\(viewModel.foodID)-\(viewModel.originDate.formatted)",
            accountID: viewModel.accountID,
            foodID: viewModel.foodID,
            foodName: viewModel.food?.name ?? viewModel.foodID,
            date: viewModel.originDate,
            mealSlot: viewModel.mealSlot,
            logID: nil,
            replayed: false
        )
        handleFoodDetailSuccess(
            success,
            expectedGeneration: ready.generation,
            source: viewModel
        )
    }

    private func handleFoodDetailSuccess(
        _ success: FoodLogSubmissionSuccess,
        expectedGeneration: UInt64,
        source: FoodDetailViewModel?
    ) {
        guard expectedGeneration == session.sessionGeneration,
              let ready = featureGraph.readyState,
              ready.generation == expectedGeneration,
              success.accountID == ready.user.id,
              deliveredSubmissionIDs.insert(success.submissionID).inserted
        else { return }

        let generation = ready.generation
        let originDate = success.date
        let mealSlot = success.mealSlot
        // A late callback from a replaced detail may refresh the diary, but it
        // must not navigate away from the replacement the user is editing.
        let isCurrentSource = source.map {
            ready.foodDetails[success.foodID] === $0
        } ?? true
        let isActiveDetail = isCurrentSource
            && navigationState.activePane.contextualFoodID == success.foodID
            && navigationState.selectedDate == originDate

        if isActiveDetail {
            var state = navigationState
            state.selectDate(originDate)
            if state.mealSlot != mealSlot {
                state.setMealSlot(mealSlot)
            }
            navigationState = state
            searchViewModel?.clearSelection()
            searchViewModel?.updateContext(
                date: originDate,
                mealSlot: mealSlot
            )
        }

        Task { [weak self] in
            guard let self,
                  let current = self.featureGraph.readyState,
                  current.generation == generation,
                  generation == self.session.sessionGeneration else { return }
            let diary = current.diary
            if diary.selectedDate == originDate {
                await diary.refresh()
            } else if isActiveDetail {
                await diary.selectDate(originDate)
            }
        }
    }

    private static func today() -> LocalDiaryDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return LocalDiaryDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }
}

// MARK: - Login view model factory

public extension AppShellCoordinator {
    var loginViewModel: LoginViewModel {
        LoginViewModel(
            authenticator: SessionLoginAuthenticator(session: session),
            coordinator: self
        )
    }
}

// MARK: - Login authentication adapter

public struct SessionLoginAuthenticator: AuthAuthenticating {
    public let session: SessionCoordinator

    public init(session: SessionCoordinator) {
        self.session = session
    }

    public func signIn(username: String, password: String) async throws -> SignInOutcome {
        switch await session.signIn(username: username, password: password) {
        case .signedIn(let user):
            return .supported(user)
        case .rejectedUnsupportedRole(let user):
            return .admin(user)
        case .failed(let failure):
            throw authFeatureError(from: failure)
        }
    }

    private func authFeatureError(
        from failure: SessionCoordinator.Failure
    ) -> AuthFeatureError {
        switch failure {
        case .invalidCredentials:
            return .invalidCredentials
        case .networkUnavailable, .timedOut:
            return .networkUnavailable
        case .server(let message):
            return .server(message)
        case .cancelled, .unknown:
            return .unknown
        }
    }
}

// MARK: - Screen projection

public enum AppShellScreen: Equatable {
    case restoring
    case login
    case main(AuthUser)
    case restoreFailed(SessionCoordinator.Failure)
    case configurationError(String)

    public init(
        phase: SessionCoordinator.Phase,
        configurationError: String? = nil
    ) {
        if let configurationError {
            self = .configurationError(configurationError)
            return
        }

        switch phase {
        case .idle, .restoring:
            self = .restoring
        case .signingIn, .signedOut, .unsupportedAccount:
            self = .login
        case .signedIn(let user):
            self = .main(user)
        case .restoreFailed(let failure):
            self = .restoreFailed(failure)
        }
    }
}

// MARK: - Pane plan

enum AppShellPanePlan: Equatable {
    case stack(root: Pane, path: [Pane])

    case split(primary: Pane, inspector: Pane?)

    static let sidebarSections: [PrimarySection] = [.diary, .search]

    static func plan(for state: NavigationState, layout: PaneLayout) -> AppShellPanePlan {
        switch layout {
        case .compact:
            return .stack(root: .diary, path: Array(state.paneStack.dropFirst()))

        case .expanded:
            let primary: Pane
            switch state.primarySection {
            case .diary:
                primary = .diary
            case .search:
                primary = .foodSearch
            }
            return .split(
                primary: primary,
                inspector: state.activePane.contextualFoodPane
            )
        }
    }

    var rootPane: Pane {
        switch self {
        case .stack(let root, _):
            return root
        case .split(let primary, _):
            return primary
        }
    }

    var navigationPath: [Pane] {
        switch self {
        case .stack(_, let path):
            return path
        case .split:
            return []
        }
    }

    var primaryPane: Pane {
        switch self {
        case .stack(let root, let path):
            return path.last ?? root
        case .split(let primary, _):
            return primary
        }
    }

    var inspectorPane: Pane? {
        switch self {
        case .stack:
            return nil
        case .split(_, let inspector):
            return inspector
        }
    }
}

private extension Pane {
    var contextualFoodPane: Pane? {
        switch self {
        case .foodDetail, .foodLog, .logEditor:
            return self
        case .diary, .foodSearch:
            return nil
        }
    }

    var contextualFoodID: String? {
        switch self {
        case .foodDetail(let foodID), .foodLog(let foodID):
            return foodID
        case .diary, .foodSearch, .logEditor:
            return nil
        }
    }
}

// MARK: - View

public struct AppShell: View {
    @StateObject private var coordinator: AppShellCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingBannerDiscard: PendingLogSubmission?

    public init() {
        _coordinator = StateObject(wrappedValue: AppShellCoordinator())
    }

    public init(coordinator: AppShellCoordinator) {
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    public var body: some View {
        Group {
            switch coordinator.screen {
            case .restoring:
                SessionStatusView(status: .restoring)
            case .login:
                LoginView(viewModel: coordinator.loginViewModel)
            case .main:
                signedInShell
            case .restoreFailed(let failure):
                restoreFailedView(failure)
            case .configurationError(let message):
                configurationErrorView(message)
            }
        }
        .task {
            await coordinator.start()
        }
    }

    // MARK: Restore / configuration states

    private func restoreFailedView(
        _ failure: SessionCoordinator.Failure
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(
                String(localized: "auth.session.restoreFailed.title",
                       comment: "Title shown when a stored session could not be restored")
            )
            .font(.title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)

            Text(restoreFailureMessage(failure))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(
                String(localized: "auth.session.retry",
                       comment: "Retries restoring the session after a transport failure")
            ) {
                Task { await coordinator.retryRestore() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("auth.session.retry")
        }
        .padding()
        .accessibilityIdentifier("auth.session.restoreFailed")
    }

    private func restoreFailureMessage(
        _ failure: SessionCoordinator.Failure
    ) -> String {
        switch failure {
        case .networkUnavailable, .timedOut:
            return String(localized: "auth.session.restoreFailed.message",
                          comment: "Explains that session restore failed while offline")
        case .server(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? String(localized: "auth.session.restoreFailed.message",
                         comment: "Explains that session restore failed")
                : trimmed
        case .invalidCredentials, .cancelled, .unknown:
            return String(localized: "auth.session.restoreFailed.message",
                          comment: "Explains that session restore failed")
        }
    }

    private func configurationErrorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .accessibilityIdentifier("app.configuration.error")
    }

    @ViewBuilder
    private var signedInShell: some View {
        GeometryReader { proxy in
            let layout = AppShellLayout.resolve(
                isCompactSizeClass: horizontalSizeClass == .compact,
                width: Double(proxy.size.width)
            )
            VStack(spacing: 0) {
                if let pending = coordinator.pendingSubmission {
                    pendingSubmissionBanner(pending)
                }
                if layout == .compact {
                    compactShell
                } else {
                    expandedShell
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(item: $pendingBannerDiscard) { pending in
            Alert(
                title: Text(String(localized: "foodDetail.pending.discard.confirmTitle")),
                message: Text(String(localized: "foodDetail.pending.discard.confirmMessage")),
                primaryButton: .destructive(
                    Text(String(localized: "foodDetail.pending.discard.confirmAction"))
                ) {
                    coordinator.discardPendingSubmission(pending)
                },
                secondaryButton: .cancel(
                    Text(String(localized: "foodDetail.pending.cancel"))
                )
            )
        }
        .confirmationDialog(
            String(localized: "diary.editor.discard.title"),
            isPresented: discardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "diary.editor.discard.action"), role: .destructive) {
                coordinator.confirmDiscardEditorChanges()
            }
            .accessibilityIdentifier("diary.editor.discard.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {
                coordinator.cancelDiscardEditorChanges()
            }
        } message: {
            Text(String(localized: "diary.editor.discard.message"))
        }
    }

    private var discardConfirmationPresented: Binding<Bool> {
        Binding(
            get: { coordinator.pendingEditorDiscard != nil },
            set: { isPresented in
                if !isPresented {
                    coordinator.cancelDiscardEditorChanges()
                }
            }
        )
    }

    private func pendingSubmissionBanner(
        _ pending: PendingLogSubmission
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerTitle(count: coordinator.pendingSubmissions.count))
                        .font(.footnote.weight(.semibold))
                    Text("\(pending.foodName) · \(pending.draft.date.formatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)

                if coordinator.pendingSubmissions.count > 1 {
                    Menu {
                        ForEach(coordinator.pendingSubmissions) { entry in
                            Button {
                                coordinator.reviewPendingSubmission(entry)
                            } label: {
                                Text("\(entry.foodName) · \(entry.draft.date.formatted)")
                            }
                        }
                    } label: {
                        Text(String(localized: "foodDetail.pending.reviewAll"))
                            .font(.footnote.weight(.semibold))
                    }
                    .accessibilityIdentifier("foodDetail.pending.reviewAll")
                }

                Button(String(localized: "foodDetail.pending.review")) {
                    coordinator.reviewPendingSubmission(pending)
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("foodDetail.pending.review")

                Button {
                    coordinator.dismissPendingSubmissionBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "foodDetail.pending.dismissBanner"))
                .accessibilityIdentifier("foodDetail.pending.dismiss")
            }

            if pending.state == .conflicted {
                HStack(spacing: 8) {
                    Text(String(localized: "foodDetail.pending.conflicted"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(String(localized: "foodDetail.pending.discard")) {
                        pendingBannerDiscard = pending
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("foodDetail.pending.banner.discard")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("foodDetail.pending.banner")
    }

    private func bannerTitle(count: Int) -> String {
        if count <= 1 {
            return String(localized: "foodDetail.pending.banner")
        }
        return String(
            format: String(localized: "foodDetail.pending.banner.count"),
            count
        )
    }

    // MARK: Compact

    private var compactShell: some View {
        let plan = AppShellPanePlan.plan(
            for: coordinator.navigationState,
            layout: .compact
        )
        return NavigationStack(path: compactPath) {
            paneView(plan.rootPane)
                .toolbar { signOutToolbar }
                .navigationDestination(for: Pane.self) { pane in
                    compactDestination(pane)
                }
        }
    }

    @ViewBuilder
    private func compactDestination(_ pane: Pane) -> some View {
        let isLogEditor = isLogEditorPane(pane)
        paneView(pane)
            // Replace the system back gesture/button consistently on iOS and
            // macOS compact windows. Otherwise a system back action can bypass
            // the dirty/busy editor guard.
            .navigationBarBackButtonHidden(isLogEditor)
            .toolbar {
                signOutToolbar
                if isLogEditor {
                    ToolbarItem(placement: editorBackPlacement) {
                        editorBackButton
                    }
                }
            }
    }

    private func isLogEditorPane(_ pane: Pane) -> Bool {
        if case .logEditor = pane {
            return true
        }
        return false
    }

    private var editorBackPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private var editorBackButton: some View {
        Button {
            coordinator.requestBack()
        } label: {
            Label(String(localized: "diary.editor.back"), systemImage: "chevron.left")
        }
        .accessibilityIdentifier("diary.editor.back")
    }

    private var compactPath: Binding<[Pane]> {
        Binding(
            get: {
                AppShellPanePlan.plan(
                    for: coordinator.navigationState,
                    layout: .compact
                ).navigationPath
            },
            set: { newPath in
                let currentPath = AppShellPanePlan.plan(
                    for: coordinator.navigationState,
                    layout: .compact
                ).navigationPath
                guard newPath.count < currentPath.count,
                      Array(currentPath.prefix(newPath.count)) == newPath
                else { return }
                for _ in 0..<(currentPath.count - newPath.count) {
                    coordinator.requestBack()
                }
            }
        )
    }

    // MARK: Expanded

    private var expandedShell: some View {
        let plan = AppShellPanePlan.plan(
            for: coordinator.navigationState,
            layout: .expanded
        )
        return NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                paneView(plan.primaryPane)
                    .toolbar { signOutToolbar }
            }
        }
        .inspector(isPresented: inspectorPresented) {
            inspectorContent(for: plan.inspectorPane)
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            ForEach(AppShellPanePlan.sidebarSections, id: \.self) { section in
                sidebarLabel(for: section)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "CalCo"))
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    @ViewBuilder
    private func sidebarLabel(for section: PrimarySection) -> some View {
        switch section {
        case .diary:
            Label("Diary", systemImage: "book.closed")
        case .search:
            Label(String(localized: "search.title"), systemImage: "magnifyingglass")
        }
    }

    private var sidebarSelection: Binding<PrimarySection?> {
        Binding(
            get: { coordinator.navigationState.primarySection },
            set: { section in
                guard let section else { return }
                switch section {
                case .diary:
                    coordinator.showDiary()
                case .search:
                    coordinator.showSearch()
                }
            }
        )
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { coordinator.navigationState.activePane.contextualFoodPane != nil },
            set: { isPresented in
                guard !isPresented,
                      coordinator.navigationState.activePane.contextualFoodPane != nil
                else { return }
                coordinator.requestBack()
            }
        )
    }

    @ViewBuilder
    private func inspectorContent(for pane: Pane?) -> some View {
        if let pane {
            NavigationStack {
                paneView(pane)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                coordinator.requestBack()
                            }
                        }
                    }
            }
            .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
    }

    // MARK: Sign out

    @ToolbarContentBuilder
    private var signOutToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            signOutButton
        }
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            Task { await coordinator.signOut() }
        } label: {
            Label(
                String(localized: "auth.signOut",
                       comment: "Toolbar action that signs the user out"),
                systemImage: "rectangle.portrait.and.arrow.right"
            )
        }
        .accessibilityIdentifier("auth.signOut")
        .help(String(localized: "auth.signOut",
                     comment: "Toolbar action that signs the user out"))
    }

    // MARK: Panes

    @ViewBuilder
    private func paneView(_ pane: Pane) -> some View {
        switch pane {
        case .diary:
            if let vm = coordinator.diaryViewModel {
                DiaryView(viewModel: vm)
            } else {
                ProgressView()
            }
        case .foodSearch:
            if let vm = coordinator.searchViewModel {
                SearchView(viewModel: vm)
            } else {
                ProgressView()
            }
        case .foodDetail(let foodID), .foodLog(let foodID):
            if let vm = coordinator.foodDetailViewModel(for: foodID) {
                FoodDetailView(viewModel: vm)
            } else {
                ProgressView()
            }
        case .logEditor(let logID):
            if let vm = coordinator.logEditorViewModel(for: logID) {
                LogEditorView(viewModel: vm)
            } else {
                ProgressView()
            }
        }
    }
}

// MARK: - Aliases

public typealias AppShellModel = AppShellCoordinator
public typealias AppShellViewModel = AppShellCoordinator
