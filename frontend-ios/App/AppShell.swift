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

@MainActor
public final class AppShellCoordinator: ObservableObject, AuthFeatureCoordinating {
    public let client: CalCoAPIClient
    public let session: SessionCoordinator
    public let diaryService: any DiaryServicing
    public let searchService: any FoodSearchServicing
    public let foodDetailService: any FoodDetailServicing
    public let todayProvider: () -> LocalDiaryDate

    public let configurationError: String?

    @Published public var navigationState: NavigationState
    @Published private var featureGraph: FeatureGraph = .absent

    private var cancellables: Set<AnyCancellable> = []
    private var deliveredFoodDetailSuccesses: [String: ObjectIdentifier] = [:]

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
        }

        case absent
        case ready(Ready)

        var readyState: Ready? {
            guard case .ready(let ready) = self else { return nil }
            return ready
        }
    }

    private final class FoodDetailSuccessIdentity {
        weak var viewModel: FoodDetailViewModel?
    }

    private func synchronizeFeatureGraph(with phase: SessionCoordinator.Phase) {
        guard case .signedIn(let user) = phase else { return }
        installFeatureGraph(for: user)
    }

    private func resetSessionScopedState() {
        let previous = featureGraph
        featureGraph = .absent
        deliveredFoodDetailSuccesses.removeAll()
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
        deliveredFoodDetailSuccesses.removeAll()
        previous.readyState?.diary.resetForSessionChange()
        previous.readyState?.search.invalidateSession()

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
            foodDetails: [:]
        ))

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
        var state = navigationState
        state.selectDate(date)
        state.startLogging(mealSlot: slot)
        navigationState = state
        searchViewModel?.updateContext(date: date, mealSlot: slot)
    }

    public func openFoodDetail(_ foodID: String, date: LocalDiaryDate, mealSlot: MealSlot?) {
        var state = navigationState
        state.showDetail(foodID: foodID, date: date, mealSlot: mealSlot)
        navigationState = state
        searchViewModel?.updateContext(date: state.selectedDate, mealSlot: state.mealSlot)

        guard var ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        let generation = ready.generation
        let identity = FoodDetailSuccessIdentity()
        let viewModel = FoodDetailViewModel(
            foodID: foodID,
            originDate: date,
            originMealSlot: mealSlot,
            service: foodDetailService,
            onSuccess: { [weak self, identity] _, _ in
                guard let self,
                      let viewModel = identity.viewModel else { return }
                self.handleFoodDetailSuccess(
                    viewModel,
                    expectedGeneration: generation
                )
            },
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            }
        )
        identity.viewModel = viewModel
        deliveredFoodDetailSuccesses.removeValue(forKey: foodID)
        ready.foodDetails[foodID] = viewModel
        featureGraph = .ready(ready)
    }

    public func foodDetailViewModel(for foodID: String) -> FoodDetailViewModel? {
        featureGraph.readyState?.foodDetails[foodID]
    }

    public func showDiary() {
        var state = navigationState
        state.finishLogging()
        navigationState = state
        searchViewModel?.clearSelection()
    }

    public func showSearch() {
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
        let wasShowingFoodDetail = state.activePane.contextualFoodPane != nil
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
        handleFoodDetailSuccess(
            viewModel,
            expectedGeneration: ready.generation
        )
    }

    private func handleFoodDetailSuccess(
        _ viewModel: FoodDetailViewModel,
        expectedGeneration: UInt64
    ) {
        guard expectedGeneration == session.sessionGeneration,
              let ready = featureGraph.readyState,
              ready.generation == expectedGeneration,
              ready.foodDetails[viewModel.foodID] === viewModel
        else { return }

        let identifier = ObjectIdentifier(viewModel)
        guard deliveredFoodDetailSuccesses[viewModel.foodID] != identifier else {
            return
        }
        deliveredFoodDetailSuccesses[viewModel.foodID] = identifier

        let generation = ready.generation
        let originDate = viewModel.originDate
        let mealSlot = viewModel.mealSlot
        let isActiveDetail = navigationState.activePane.contextualFoodID
            == viewModel.foodID
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
        case .foodDetail, .foodLog:
            return self
        case .diary, .foodSearch:
            return nil
        }
    }

    var contextualFoodID: String? {
        switch self {
        case .foodDetail(let foodID), .foodLog(let foodID):
            return foodID
        case .diary, .foodSearch:
            return nil
        }
    }
}

// MARK: - View

public struct AppShell: View {
    @StateObject private var coordinator: AppShellCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        if horizontalSizeClass == .compact {
            compactShell
        } else {
            expandedShell
        }
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
                    paneView(pane)
                        .toolbar { signOutToolbar }
                }
        }
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
                    coordinator.back()
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
                coordinator.back()
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
                                coordinator.back()
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
        }
    }
}

// MARK: - Aliases

public typealias AppShellModel = AppShellCoordinator
public typealias AppShellViewModel = AppShellCoordinator
