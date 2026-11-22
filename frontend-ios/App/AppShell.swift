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
    /// A native tab change is an intent, not a direct selection write. It goes
    /// through the same dirty/busy editor guard as every other route change so
    /// an unsaved log editor cannot be silently discarded by the tab bar.
    case switchTab(tab: AppShellTab)
}

public struct MealsSheetRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let initialMealID: String?
    public let initialPortion: NutritionQuantity?

    public init(
        id: UUID = UUID(),
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        initialMealID: String? = nil,
        initialPortion: NutritionQuantity? = nil
    ) {
        self.id = id
        self.date = date
        self.mealSlot = mealSlot
        self.initialMealID = initialMealID
        self.initialPortion = initialPortion
    }
}

public struct LibrarySheetRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let assistantDraft: AssistantReviewedDraft?
    public let initialBarcode: String?

    public init(
        id: UUID = UUID(),
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil
    ) {
        self.id = id
        self.date = date
        self.mealSlot = mealSlot
        self.assistantDraft = assistantDraft
        self.initialBarcode = initialBarcode
    }
}

/// Compact iPhone top-level destinations. Search is deliberately not a tab:
/// it is the contextual Add Food step pushed from the Diary tab so the selected
/// date and meal slot are never lost.
public enum AppShellTab: Hashable, Sendable {
    case diary
    case search
    case library
    case settings

    public var title: String {
        switch self {
        case .diary: return "Diary"
        case .search: return String(localized: "search.title")
        case .library: return String(localized: "library.title")
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .diary: return "book.closed"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .settings: return "gearshape"
        }
    }
}

public enum AppShellFeatureSheet: Identifiable {
    case nutrition(NutritionDetailsViewModel)
    case meals(MealsSheetRequest)
    case library(LibrarySheetRequest)
    case assistant(AssistantViewModel)

    public var id: String {
        switch self {
        case .nutrition(let viewModel):
            return "nutrition-\(viewModel.id.uuidString)"
        case .meals(let request):
            return "meals-\(request.id.uuidString)"
        case .library(let request):
            return "library-\(request.id.uuidString)"
        case .assistant(let viewModel):
            return "assistant-\(ObjectIdentifier(viewModel).hashValue)"
        }
    }
}

@MainActor
public final class AppShellCoordinator: ObservableObject, AuthFeatureCoordinating {
    public let client: CalCoAPIClient
    public let session: SessionCoordinator
    public let diaryService: any DiaryServicing
    public let searchService: any FoodSearchServicing
    public let foodDetailService: any FoodDetailServicing
    public let settingsService: any DiarySettingsServicing
    public let nutritionDetailsService: any NutritionDetailsServicing
    public let mealsService: any MealsServicing
    public let libraryService: any LibraryServicing
    public let assistantService: any AssistantServicing
    public let apiKeyService: any APIKeyServicing
    public let logSubmissionStore: LogSubmissionStore
    public let logSubmissionService: LogSubmissionService
    public let logSubmissionSessionContextProvider: LogSubmissionSessionContextProvider?
    public let todayProvider: () -> LocalDiaryDate

    public let configurationError: String?

    @Published public var navigationState: NavigationState
    /// Compact tab selection is coordinator-owned so the tab bar can be routed
    /// through `requestTabSwitch` and the existing discard/busy guard.
    @Published public var selectedTab: AppShellTab = .diary
    /// The Search tab owns its own native detail stack. Food detail selected
    /// from the shared Search screen is pushed here so Back returns to Search
    /// with its query, scope and diary context intact. The Diary Add Food push
    /// keeps using `navigationState` and still returns to Diary.
    @Published public private(set) var searchTabPath: [Pane] = []
    /// Expanded layouts use a sidebar Library destination without changing the
    /// established diary/search pane plan.
    @Published public var expandedLibrarySelected: Bool = false
    @Published public private(set) var settingsViewModel: DiarySettingsViewModel?
    @Published public private(set) var accountSettingsViewModel: AccountSettingsViewModel?
    @Published public private(set) var featureSheet: AppShellFeatureSheet?
    @Published public private(set) var pendingSubmission: PendingLogSubmission?
    /// All recoverable entries in most-recent-first order. The banner shows a
    /// count and lets the user review each entry instead of hiding all but one.
    @Published public private(set) var pendingSubmissions: [PendingLogSubmission] = []
    /// Set when a dirty editor would otherwise be closed, replaced, or left
    /// behind. The shell asks for explicit discard confirmation.
    @Published public private(set) var pendingEditorDiscard: EditorDiscardRequest?
    @Published private var featureGraph: FeatureGraph = .absent

    private var cancellables: Set<AnyCancellable> = []
    private let injectedDiaryService: (any DiaryServicing)?
    private let injectedSearchService: (any FoodSearchServicing)?
    private let injectedFoodDetailService: (any FoodDetailServicing)?
    private let injectedSettingsService: (any DiarySettingsServicing)?
    private let injectedNutritionDetailsService: (any NutritionDetailsServicing)?
    private let injectedMealsService: (any MealsServicing)?
    private let injectedLibraryService: (any LibraryServicing)?
    private let injectedAssistantService: (any AssistantServicing)?
    private let injectedAPIKeyService: (any APIKeyServicing)?
    private var deliveredSubmissionIDs: Set<String> = []
    /// Dismissal applies to the exact entry version the user saw. Any state
    /// change (for example a new conflict) makes it visible again.
    private var dismissedSubmissions: [String: Date] = [:]
    /// Bounded by log ID rather than growing once per editor instance.
    private var deliveredLogEditorSuccesses: [String: ObjectIdentifier] = [:]
    /// Assistant acceptance closes its sheet first, then this opens Library from
    /// the sheet's `onDismiss` so two presentations never race.
    private var pendingLibraryAfterAssistant: LibrarySheetRequest?

    public var currentUser: AuthUser? { featureGraph.readyState?.user }
    public var diaryViewModel: DiaryViewModel? { featureGraph.readyState?.diary }
    public var searchViewModel: SearchViewModel? { featureGraph.readyState?.search }
    public var currentMealsService: any MealsServicing {
        featureGraph.readyState?.services.meals ?? mealsService
    }
    public var currentLibraryService: any LibraryServicing {
        featureGraph.readyState?.services.library ?? libraryService
    }
    public var currentDiaryService: any DiaryServicing {
        featureGraph.readyState?.services.diary ?? diaryService
    }
    public var currentSearchService: any FoodSearchServicing {
        featureGraph.readyState?.services.search ?? searchService
    }
    public var currentSettingsService: any DiarySettingsServicing {
        featureGraph.readyState?.services.settings ?? settingsService
    }
    public var currentNutritionService: any NutritionDetailsServicing {
        featureGraph.readyState?.services.nutrition ?? nutritionDetailsService
    }
    public var currentAssistantService: any AssistantServicing {
        featureGraph.readyState?.services.assistant ?? assistantService
    }
    public var currentAPIKeyService: any APIKeyServicing {
        featureGraph.readyState?.services.apiKeys ?? apiKeyService
    }
    public var currentFoodDetailService: any FoodDetailServicing {
        featureGraph.readyState?.services.foodDetail ?? foodDetailService
    }

    public var phase: SessionCoordinator.Phase { session.phase }

    /// Live diary target read only when a new Library/Meals logging flow opens.
    /// Session resets restore it to the current day with no stored target.
    public var currentLibraryLogContext: LibraryLogContext {
        LibraryLogContext(
            date: navigationState.selectedDate,
            mealSlot: navigationState.mealSlot
        )
    }

    public var screen: AppShellScreen {
        AppShellScreen(phase: session.phase, configurationError: configurationError)
    }

    public init(
        client: CalCoAPIClient? = nil,
        session: SessionCoordinator? = nil,
        diaryService: (any DiaryServicing)? = nil,
        searchService: (any FoodSearchServicing)? = nil,
        foodDetailService: (any FoodDetailServicing)? = nil,
        settingsService: (any DiarySettingsServicing)? = nil,
        nutritionDetailsService: (any NutritionDetailsServicing)? = nil,
        mealsService: (any MealsServicing)? = nil,
        libraryService: (any LibraryServicing)? = nil,
        assistantService: (any AssistantServicing)? = nil,
        apiKeyService: (any APIKeyServicing)? = nil,
        logSubmissionStore: LogSubmissionStore? = nil,
        logSubmissionService: LogSubmissionService? = nil,
        logSubmissionSessionContextProvider: LogSubmissionSessionContextProvider? = nil,
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
        self.settingsService = settingsService
            ?? CalCoSettingsServiceAdapter(client: resolvedClient)
        self.nutritionDetailsService = nutritionDetailsService
            ?? CalCoNutritionDetailsServiceAdapter(client: resolvedClient)
        self.mealsService = mealsService
            ?? CalCoMealsServiceAdapter(client: resolvedClient)
        self.libraryService = libraryService
            ?? CalCoLibraryServiceAdapter(client: resolvedClient)
        self.assistantService = assistantService
            ?? CalCoAssistantServiceAdapter(client: resolvedClient)
        self.apiKeyService = apiKeyService
            ?? CalCoAPIKeysServiceAdapter(client: resolvedClient)
        self.injectedDiaryService = diaryService
        self.injectedSearchService = searchService
        self.injectedFoodDetailService = foodDetailService
        self.injectedSettingsService = settingsService
        self.injectedNutritionDetailsService = nutritionDetailsService
        self.injectedMealsService = mealsService
        self.injectedLibraryService = libraryService
        self.injectedAssistantService = assistantService
        self.injectedAPIKeyService = apiKeyService
        // Every WindowGroup scene gets its own coordinator, but all windows
        // must share one journal cache so a live POST in one window blocks a
        // delete in another. Tests can still inject an isolated store.
        self.logSubmissionStore = logSubmissionStore ?? .shared
        self.logSubmissionSessionContextProvider = logSubmissionSessionContextProvider
        self.logSubmissionService = logSubmissionService ?? LogSubmissionService(
            sender: CalCoLogSubmissionSender(client: resolvedClient),
            sessionContextProvider: logSubmissionSessionContextProvider
        )
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
        struct FeatureServices {
            let diary: any DiaryServicing
            let search: any FoodSearchServicing
            let foodDetail: any FoodDetailServicing
            let settings: any DiarySettingsServicing
            let nutrition: any NutritionDetailsServicing
            let meals: any MealsServicing
            let library: any LibraryServicing
            let assistant: any AssistantServicing
            let apiKeys: any APIKeyServicing
        }

        struct Ready {
            let user: AuthUser
            let generation: UInt64
            let services: FeatureServices
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
        settingsViewModel = nil
        clearPresentedFeatures()
        pendingSubmission = nil
        pendingSubmissions = []
        pendingEditorDiscard = nil
        selectedTab = .diary
        searchTabPath = []
        expandedLibrarySelected = false
        previous.readyState?.diary.resetForSessionChange()
        previous.readyState?.search.invalidateSession()
        navigationState = NavigationState(date: todayProvider())
    }

    private func clearPresentedFeatures() {
        if case .nutrition(let viewModel) = featureSheet {
            viewModel.resetForSessionChange()
        }
        if case .assistant(let viewModel) = featureSheet {
            viewModel.resetForSessionChange()
        }
        accountSettingsViewModel?.clearForSignOut()
        accountSettingsViewModel = nil
        featureSheet = nil
        pendingLibraryAfterAssistant = nil
    }

    private func makeFeatureServices() -> FeatureGraph.FeatureServices {
        FeatureGraph.FeatureServices(
            diary: injectedDiaryService ?? CalCoDiaryServiceAdapter(client: client),
            search: injectedSearchService ?? CalCoFoodSearchServiceAdapter(client: client),
            foodDetail: injectedFoodDetailService
                ?? CalCoFoodDetailServiceAdapter(client: client),
            settings: injectedSettingsService
                ?? CalCoSettingsServiceAdapter(client: client),
            nutrition: injectedNutritionDetailsService
                ?? CalCoNutritionDetailsServiceAdapter(client: client),
            meals: injectedMealsService
                ?? CalCoMealsServiceAdapter(client: client),
            library: injectedLibraryService
                ?? CalCoLibraryServiceAdapter(client: client),
            assistant: injectedAssistantService
                ?? CalCoAssistantServiceAdapter(client: client),
            apiKeys: injectedAPIKeyService
                ?? CalCoAPIKeysServiceAdapter(client: client)
        )
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
        settingsViewModel = nil
        clearPresentedFeatures()
        pendingSubmission = nil
        pendingSubmissions = []
        pendingEditorDiscard = nil
        selectedTab = .diary
        searchTabPath = []
        expandedLibrarySelected = false

        let today = todayProvider()
        navigationState = NavigationState(date: today)

        let services = makeFeatureServices()

        let diaryVM = DiaryViewModel(
            service: services.diary,
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
            },
            latestSubmissionHandler: { [weak self] drafts, names, summary, completion in
                self?.submitDrafts(
                    drafts,
                    itemNames: names,
                    summary: summary,
                    generation: generation,
                    completion: completion
                )
            }
        )

        let searchVM = SearchViewModel(
            originDate: today,
            originMealSlot: nil,
            service: services.search,
            onSelectFood: { [weak self] foodID, date, mealSlot in
                self?.openFoodDetailIfCurrent(
                    foodID,
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation
                )
            },
            onSelectMeal: { [weak self] mealID, date, mealSlot, quantity in
                self?.openMealDetailIfCurrent(
                    mealID,
                    date: date,
                    mealSlot: mealSlot,
                    initialPortion: quantity,
                    generation: generation
                )
            },
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            },
            historyService: services.search as? any FoodSearchHistoryServicing,
            onSubmitDrafts: { [weak self] drafts, names, summary, completion in
                self?.submitDrafts(
                    drafts,
                    itemNames: names,
                    summary: summary,
                    generation: generation,
                    completion: completion
                )
            }
        )

        featureGraph = .ready(FeatureGraph.Ready(
            user: user,
            generation: generation,
            services: services,
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

    /// Shared quick-add, batch, and latest-slot path. Completion is delivered
    /// only while the originating session generation is still current.
    /// Shared handler used by Search, Diary latest, and Meals. Completion must
    /// fire exactly once on every path because Library/Meals adapters may await
    /// it and view models keep a busy state until it resolves.
    public func submitDraftsForFeature(
        _ drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        completion: @escaping (LogSubmissionServiceResult) -> Void
    ) {
        submitDrafts(
            drafts,
            itemNames: itemNames,
            summary: summary,
            generation: session.sessionGeneration,
            completion: completion
        )
    }

    private func submitDrafts(
        _ drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        generation: UInt64,
        completion: @escaping (LogSubmissionServiceResult) -> Void
    ) {
        guard isCurrent(generation), let accountID = currentUser?.id else {
            completion(.failure(.unauthorized))
            return
        }

        Task { [weak self] in
            guard let self else {
                completion(.failure(.unauthorized))
                return
            }
            let result = await self.logSubmissionService.submit(
                accountID: accountID,
                summary: summary,
                drafts: drafts,
                itemNames: itemNames,
                generation: generation
            )
            guard self.isCurrent(generation) else {
                completion(.failure(.unauthorized))
                return
            }
            if case .success = result {
                await self.diaryViewModel?.refresh()
            }
            completion(result)
        }
    }

    // MARK: - Signed-in orchestration

    public func startLogging(slot: MealSlot, date: LocalDiaryDate) {
        guard !requestDiscardIfNeeded(for: .startLogging(slot: slot, date: date)) else {
            return
        }
        performStartLogging(slot: slot, date: date)
    }

    private func performStartLogging(slot: MealSlot, date: LocalDiaryDate) {
        clearExpandedLibrarySelection()
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

    /// Diary Add Food push: detail stays on the Diary navigation stack so Back
    /// steps Search -> Diary and the selected date/meal context is retained.
    private func performOpenFoodDetail(
        _ foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
        clearExpandedLibrarySelection()
        var state = navigationState
        state.showDetail(foodID: foodID, date: date, mealSlot: mealSlot)
        navigationState = state
        searchViewModel?.updateContext(date: state.selectedDate, mealSlot: state.mealSlot)
        ensureFoodDetailViewModel(foodID: foodID, date: date, mealSlot: mealSlot)
    }

    /// Search tab selection: detail is pushed on the Search tab's own native
    /// stack. `navigationState` (the hidden Diary stack) is deliberately left
    /// untouched, so Back returns to Search and no hidden stack is stranded.
    public func openSearchTabFoodDetail(_ foodID: String) {
        guard featureGraph.readyState?.generation == session.sessionGeneration else { return }
        searchTabPath = [.foodDetail(foodID: foodID)]
        ensureFoodDetailViewModel(
            foodID: foodID,
            date: navigationState.selectedDate,
            mealSlot: navigationState.mealSlot
        )
    }

    /// The Search tab stack only ever holds one detail; a shorter path is the
    /// system Back gesture/button popping that detail.
    public func popSearchTabDetail() {
        searchTabPath = []
    }

    private func ensureFoodDetailViewModel(
        foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
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
            service: ready.services.foodDetail,
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
        clearExpandedLibrarySelection()
        guard isCurrent(generation),
              let ready = featureGraph.readyState else { return }

        let editor = LogEditorViewModel(
            log: log,
            date: date,
            service: ready.services.diary,
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

    /// Native tab selection must be an intent, never a direct write. A dirty
    /// editor produces the existing discard dialog and keeps the current tab;
    /// a busy editor is ignored. Only confirmation performs the exact target.
    public func requestTabSwitch(to tab: AppShellTab) {
        guard selectedTab != tab else { return }
        guard !requestDiscardIfNeeded(for: .switchTab(tab: tab)) else { return }
        performTabSwitch(to: tab)
    }

    private func performTabSwitch(to tab: AppShellTab) {
        selectedTab = tab
        if tab != .library { expandedLibrarySelected = false }
        // The Search tab shows the same screen as Diary's Add Food push, so it
        // must inherit the selected diary date/meal slot rather than keep a
        // stale origin from an earlier entry.
        if tab == .search {
            searchViewModel?.updateContext(
                date: navigationState.selectedDate,
                mealSlot: navigationState.mealSlot
            )
        }
    }

    /// Selecting a diary/search route always leaves the expanded Library
    /// destination so the sidebar selection cannot disagree with the detail.
    private func clearExpandedLibrarySelection() {
        expandedLibrarySelected = false
    }

    public func selectExpandedLibrary() {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        guard !requestDiscardIfNeeded(for: .switchTab(tab: .library)) else { return }
        expandedLibrarySelected = true
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
        case .switchTab(let tab):
            performTabSwitch(to: tab)
            if tab == .library { expandedLibrarySelected = true }
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
        clearExpandedLibrarySelection()
        var state = navigationState
        state.finishLogging()
        navigationState = state
        searchViewModel?.clearSelection()
    }

    private func showDiary(date: LocalDiaryDate, generation: UInt64) {
        guard isCurrent(generation) else { return }
        // "Check Diary" from a detail opened on the Search tab must actually
        // show Diary: clear that tab's detail so its Back never lands on a
        // hidden stack, then let the tab bar present the updated Diary.
        if !searchTabPath.isEmpty {
            searchTabPath = []
            selectedTab = .diary
        }
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

    // MARK: - Settings

    public func showSettings() {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration,
              ready.diary.state != .loading else { return }
        // Re-tapping the toolbar while the sheet is open must preserve the
        // current draft rather than replace the view model.
        guard settingsViewModel == nil else { return }
        ensureSettingsViewModel()
    }

    /// Creates and loads the one shared settings graph when it is absent. The
    /// compact Settings tab calls this so it is usable even before the diary
    /// finishes loading, while the diary toolbar keeps its original guard.
    public func ensureSettingsViewModel() {
        guard settingsViewModel == nil,
              let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }

        let generation = ready.generation
        let viewModel = DiarySettingsViewModel(
            service: ready.services.settings,
            accountID: ready.user.id,
            todayProvider: todayProvider
        )
        let settingsID = viewModel.id
        viewModel.onGoalSaved = { [weak self] snapshot in
            self?.handleSettingsGoalSaved(
                snapshot,
                settingsID: settingsID,
                generation: generation
            )
        }
        viewModel.onPreferencesSaved = { [weak self] preferences in
            self?.handleSettingsPreferencesSaved(
                preferences,
                settingsID: settingsID,
                generation: generation
            )
        }
        viewModel.onSessionExpired = { [weak self] in
            self?.handleSettingsSessionExpired(settingsID: settingsID, generation: generation)
        }
        settingsViewModel = viewModel
        if accountSettingsViewModel == nil {
            let account = AccountSettingsViewModel(
                service: ready.services.apiKeys,
                accountID: ready.user.id
            )
            account.onSessionExpired = { [weak self] in
                self?.handleSessionExpired(generation: generation)
            }
            accountSettingsViewModel = account
        }
        Task { await viewModel.loadIfNeeded() }
    }

    /// The sheet and toolbar both route here. A dirty draft or an in-flight
    /// save keeps the sheet open; the view presents confirmation for dirty
    /// back/swipe/Escape-style dismissals.
    public func dismissSettings() {
        if let viewModel = settingsViewModel {
            guard viewModel.requestDismissal() else { return }
        }
        settingsViewModel = nil
        dismissAccountSettings()
    }

    public func dismissAccountSettings() {
        accountSettingsViewModel?.shutdown()
        accountSettingsViewModel = nil
    }

    // MARK: - Feature sheets

    public func showNutritionDetails() {
        guard featureSheet == nil,
              let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        let generation = ready.generation
        let viewModel = NutritionDetailsViewModel(
            date: navigationState.selectedDate,
            today: todayProvider(),
            service: ready.services.nutrition,
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            }
        )
        featureSheet = .nutrition(viewModel)
    }

    public func openMealsList() {
        openMeals(
            date: navigationState.selectedDate,
            mealSlot: navigationState.mealSlot
        )
    }

    public func openMeals(
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        initialMealID: String? = nil,
        initialPortion: NutritionQuantity? = nil
    ) {
        guard featureSheet == nil,
              featureGraph.readyState?.generation == session.sessionGeneration else {
            return
        }
        featureSheet = .meals(
            MealsSheetRequest(
                date: date,
                mealSlot: mealSlot,
                initialMealID: initialMealID,
                initialPortion: initialPortion
            )
        )
    }

    private func openMealDetailIfCurrent(
        _ mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        initialPortion: NutritionQuantity?,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        openMeals(
            date: date,
            mealSlot: mealSlot,
            initialMealID: mealID,
            initialPortion: initialPortion
        )
    }

    public func openLibrary(
        date: LocalDiaryDate? = nil,
        mealSlot: MealSlot? = nil,
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil
    ) {
        guard featureSheet == nil,
              featureGraph.readyState?.generation == session.sessionGeneration else {
            return
        }
        featureSheet = .library(
            LibrarySheetRequest(
                date: date ?? navigationState.selectedDate,
                mealSlot: mealSlot ?? navigationState.mealSlot,
                assistantDraft: assistantDraft,
                initialBarcode: initialBarcode
            )
        )
    }

    public func openAssistant(
        purpose: AssistantDraftPurpose,
        initialBarcode: String? = nil
    ) {
        guard featureSheet == nil,
              let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        let generation = ready.generation
        let viewModel = AssistantViewModel(
            purpose: purpose,
            initialBarcode: initialBarcode,
            service: ready.services.assistant,
            onAcceptDraft: { [weak self] draft in
                self?.acceptAssistantDraft(draft, generation: generation)
            },
            onSessionExpired: { [weak self] in
                self?.handleSessionExpired(generation: generation)
            }
        )
        featureSheet = .assistant(viewModel)
    }

    private func acceptAssistantDraft(
        _ draft: AssistantReviewedDraft,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        pendingLibraryAfterAssistant = LibrarySheetRequest(
            date: navigationState.selectedDate,
            mealSlot: navigationState.mealSlot,
            assistantDraft: draft
        )
        featureSheet = nil
    }

    public func dismissFeatureSheet() {
        featureSheet = nil
    }

    /// Called by the single feature-sheet presentation after dismissal. A
    /// follow-up sheet is opened only after the first is gone, avoiding SwiftUI
    /// sibling-sheet races.
    public func featureSheetDidDismiss() {
        if let library = pendingLibraryAfterAssistant {
            pendingLibraryAfterAssistant = nil
            guard featureGraph.readyState?.generation == session.sessionGeneration else {
                return
            }
            featureSheet = .library(library)
        }
    }

    public func libraryDidLog(date: LocalDiaryDate, mealSlot: MealSlot?) {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration,
              ready.diary.selectedDate == date else { return }
        _ = mealSlot
        Task { await ready.diary.refresh() }
    }

    public func featureSessionExpired() {
        handleSessionExpired(generation: session.sessionGeneration)
    }

    private func handleSettingsGoalSaved(
        _ snapshot: GoalSnapshot,
        settingsID: UUID,
        generation: UInt64
    ) {
        guard isCurrent(generation),
              let ready = featureGraph.readyState,
              settingsViewModel?.id == settingsID,
              settingsViewModel?.accountID == ready.user.id else { return }
        ready.diary.applySavedGoal(
            CalCoStoreMapping.diaryGoal(from: snapshot),
            effectiveOn: snapshot.requestedDate
        )
    }

    private func handleSettingsPreferencesSaved(
        _ preferences: DiaryPreferences,
        settingsID: UUID,
        generation: UInt64
    ) {
        guard isCurrent(generation),
              let ready = featureGraph.readyState,
              settingsViewModel?.id == settingsID,
              settingsViewModel?.accountID == ready.user.id else { return }
        let prefs = CalCoStoreMapping.diaryPrefs(from: preferences)
        ready.diary.applySavedPreferences(prefs)

        // The date is preserved; only a now-disabled contextual meal slot is
        // cleared, and search inherits that updated context.
        if let slot = navigationState.mealSlot, !prefs.isEnabled(slot) {
            var state = navigationState
            state.setMealSlot(nil)
            navigationState = state
            searchViewModel?.updateContext(date: state.selectedDate, mealSlot: nil)
        }
    }

    private func handleSettingsSessionExpired(settingsID: UUID, generation: UInt64) {
        guard settingsViewModel?.id == settingsID else { return }
        handleSessionExpired(generation: generation)
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

    /// Explicitly resolves a definitively conflicted legacy journal row. The
    /// caller must obtain confirmation before invoking it.
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
        clearExpandedLibrarySelection()
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

    static let sidebarSections: [PrimarySection] = [.diary, .search, .library]

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
            case .library:
                // Library is a sidebar destination, not a pane in the
                // diary/search stack. The detail column renders it directly.
                primary = .diary
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
    /// Tab selection lives on the coordinator so the native tab bar goes
    /// through the shared discard/busy guard. Each destination still keeps its
    /// own navigation stack and route-owned view models across tab switches.

    public init() {
        _coordinator = StateObject(wrappedValue: AppShellCoordinator())
    }

    public init(sessionAuthority: CalCoSessionAuthority) {
        _coordinator = StateObject(
            wrappedValue: AppShellCoordinator(
                client: sessionAuthority.client,
                session: sessionAuthority.session,
                logSubmissionSessionContextProvider: { [weak sessionAuthority] in
                    guard let sessionAuthority,
                          case .signedIn(let user) = sessionAuthority.session.phase
                    else {
                        return nil
                    }
                    return LogSubmissionSessionContext(
                        accountID: user.id,
                        generation: sessionAuthority.session.sessionGeneration,
                        baseURL: sessionAuthority.client.configuration.baseURL
                    )
                }
            )
        )
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
        // One root application of the branded accent color. The light/dark
        // values come from the asset catalog, so no duplicate color constants
        // or non-semantic background overrides are needed anywhere else.
        .tint(Color.accentColor)
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
                    compactTabShell
                } else {
                    expandedShell
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: settingsSheetBinding(for: layout)) { settings in
                DiarySettingsView(
                    viewModel: settings,
                    accountSettingsViewModel: coordinator.accountSettingsViewModel,
                    onClose: { coordinator.dismissSettings() },
                    onAccountSettingsDismissed: { coordinator.dismissAccountSettings() }
                )
            }
            .sheet(
                item: featureSheetBinding,
                onDismiss: { coordinator.featureSheetDidDismiss() }
            ) { sheet in
                featureSheetView(sheet)
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
                .accessibilityIdentifier("diary.editor.discard.cancel")
            } message: {
                Text(String(localized: "diary.editor.discard.message"))
            }
        }
    }

    /// Compact uses an embedded Settings tab, so the sheet is only available to
    /// expanded layouts. This keeps one settings view model across both paths.
    private func settingsSheetBinding(
        for layout: PaneLayout
    ) -> Binding<DiarySettingsViewModel?> {
        Binding(
            get: { layout == .compact ? nil : coordinator.settingsViewModel },
            set: { newValue in
                if newValue == nil {
                    coordinator.dismissSettings()
                }
            }
        )
    }

    private var featureSheetBinding: Binding<AppShellFeatureSheet?> {
        Binding(
            get: { coordinator.featureSheet },
            set: { newValue in
                if newValue == nil {
                    coordinator.dismissFeatureSheet()
                }
            }
        )
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

    // MARK: Feature sheets

    @ViewBuilder
    private func featureSheetView(_ sheet: AppShellFeatureSheet) -> some View {
        switch sheet {
        case .nutrition(let viewModel):
            NavigationStack {
                NutritionDetailsView(viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "diary.common.close")) {
                                coordinator.dismissFeatureSheet()
                            }
                            .accessibilityIdentifier("nutrition.close")
                        }
                    }
            }
            .presentationDetents([.large])

        case .meals(let request):
            MealsFlowView(
                date: request.date,
                mealSlot: request.mealSlot,
                accountID: coordinator.currentUser?.id ?? "",
                service: coordinator.currentMealsService,
                onSubmitDrafts: { [weak coordinator] drafts, names, summary, completion in
                    coordinator?.submitDraftsForFeature(
                        drafts,
                        itemNames: names,
                        summary: summary,
                        completion: completion
                    )
                },
                onSessionExpired: { [weak coordinator] in
                    coordinator?.featureSessionExpired()
                },
                onLogged: nil,
                onClose: { [weak coordinator] in
                    coordinator?.dismissFeatureSheet()
                },
                initialMealID: request.initialMealID,
                initialPortion: request.initialPortion
            )

        case .library(let request):
            if let accountID = coordinator.currentUser?.id {
                LibraryView(
                    service: coordinator.currentLibraryService,
                    submissionService: HandlerLibraryLogSubmissionService(
                        handler: { [weak coordinator] drafts, names, summary, completion in
                            coordinator?.submitDraftsForFeature(
                                drafts,
                                itemNames: names,
                                summary: summary,
                                completion: completion
                            )
                        }
                    ),
                    accountID: accountID,
                    today: coordinator.todayProvider(),
                    initialDate: request.date,
                    initialMealSlot: request.mealSlot,
                    onLogged: { [weak coordinator] date, slot in
                        coordinator?.libraryDidLog(date: date, mealSlot: slot)
                    },
                    onSessionExpired: { [weak coordinator] in
                        coordinator?.featureSessionExpired()
                    },
                    onClose: { [weak coordinator] in
                        coordinator?.dismissFeatureSheet()
                    },
                    assistantDraft: request.assistantDraft,
                    initialBarcode: request.initialBarcode
                )
            } else {
                ProgressView()
            }

        case .assistant(let viewModel):
            NavigationStack {
                AssistantView(viewModel: viewModel)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "assistant.cancel")) {
                                coordinator.dismissFeatureSheet()
                            }
                            .accessibilityIdentifier("app.assistant.close")
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    // MARK: Compact

    /// Native three-tab iPhone shell. Diary owns the contextual Add Food push;
    /// Library owns Foods and Meals; Settings owns goals, slots, and API keys.
    private var tabSelection: Binding<AppShellTab> {
        Binding(
            get: { coordinator.selectedTab },
            set: { coordinator.requestTabSwitch(to: $0) }
        )
    }

    private var compactTabShell: some View {
        TabView(selection: tabSelection) {
            diaryTab
                .tabItem {
                    Label(AppShellTab.diary.title, systemImage: AppShellTab.diary.systemImage)
                        .accessibilityIdentifier("app.tab.diary")
                }
                .tag(AppShellTab.diary)

            searchTab
                .tabItem {
                    Label(AppShellTab.search.title, systemImage: AppShellTab.search.systemImage)
                        .accessibilityIdentifier("app.tab.search")
                }
                .tag(AppShellTab.search)

            // LibraryView and MealsFlowView own their NavigationStacks; do not
            // wrap them in another one or a second, empty bar appears. Identity
            // is account-scoped only: a diary date change must not destroy an
            // in-progress editor or navigation path. The tab identifier belongs
            // on the tabItem: putting it on the content overrides descendant
            // identifiers such as the Foods/Meals segmented control.
            libraryRoot(onClose: nil)
                .id("library-\(coordinator.currentUser?.id ?? "none")")
                .tabItem {
                    Label(AppShellTab.library.title, systemImage: AppShellTab.library.systemImage)
                        .accessibilityIdentifier("app.tab.library")
                }
                .tag(AppShellTab.library)

            settingsTab
                .tabItem {
                    Label(AppShellTab.settings.title, systemImage: AppShellTab.settings.systemImage)
                        .accessibilityIdentifier("app.tab.settings")
                }
                .tag(AppShellTab.settings)
        }
    }

    private var diaryTab: some View {
        let plan = AppShellPanePlan.plan(
            for: coordinator.navigationState,
            layout: .compact
        )
        return NavigationStack(path: compactPath) {
            paneView(plan.rootPane, compactStyle: true)
                .navigationDestination(for: Pane.self) { pane in
                    compactDestination(pane)
                }
        }
    }

    private var searchTab: some View {
        NavigationStack(path: searchTabPathBinding) {
            searchScreen(compactStyle: true, isSearchTabRoot: true)
                .navigationDestination(for: Pane.self) { pane in
                    searchTabDestination(pane)
                }
        }
    }

    /// System Back pops the Search tab's own detail; it never mutates the Diary
    /// navigation stack, so returning to Search keeps query/scope/context.
    private var searchTabPathBinding: Binding<[Pane]> {
        Binding(
            get: { coordinator.searchTabPath },
            set: { newPath in
                guard newPath.count < coordinator.searchTabPath.count else { return }
                coordinator.popSearchTabDetail()
            }
        )
    }

    @ViewBuilder
    private func searchTabDestination(_ pane: Pane) -> some View {
        switch pane {
        case .foodDetail(let foodID), .foodLog(let foodID):
            if let vm = coordinator.foodDetailViewModel(for: foodID) {
                FoodDetailView(viewModel: vm, compactStyle: true)
                #if os(iOS)
                .toolbar(.hidden, for: .tabBar)
                #endif
            } else {
                ProgressView()
            }
        default:
            EmptyView()
        }
    }

    /// Single owner of the shared Search / Add Food screen. The Search tab and
    /// Diary's Add Food push render this exact view over the one shared
    /// SearchViewModel; only the hosting stack differs. The push gets the
    /// native Back to Diary, the tab root uses its own detail stack with Back
    /// to Search, and neither path strands a hidden stack. There is no Add Food
    /// header, no Cancel, and no duplicate Back.
    @ViewBuilder
    private func searchScreen(compactStyle: Bool, isSearchTabRoot: Bool = false) -> some View {
        if let vm = coordinator.searchViewModel {
            SearchView(
                viewModel: vm,
                onOpenMeals: {
                    if compactStyle {
                        coordinator.requestTabSwitch(to: .library)
                    } else {
                        coordinator.openMealsList()
                    }
                },
                onOpenAssistant: { purpose, barcode in
                    coordinator.openAssistant(
                        purpose: purpose,
                        initialBarcode: barcode
                    )
                },
                onDraftBarcodeWithAssistant: { barcode in
                    coordinator.openAssistant(
                        purpose: .customFood,
                        initialBarcode: barcode
                    )
                },
                onCreateCustomFoodFromBarcode: { barcode in
                    coordinator.openLibrary(
                        date: coordinator.navigationState.selectedDate,
                        mealSlot: coordinator.navigationState.mealSlot,
                        initialBarcode: barcode
                    )
                },
                onSelectFoodID: isSearchTabRoot
                    ? { foodID in coordinator.openSearchTabFoodDetail(foodID) }
                    : nil
            )
        } else {
            ProgressView()
                .accessibilityIdentifier("app.search.loading")
        }
    }

    @ViewBuilder
    private func libraryRoot(onClose: (() -> Void)? = nil) -> some View {
        LibraryRootView(
            service: coordinator.currentLibraryService,
            mealsService: coordinator.currentMealsService,
            accountID: coordinator.currentUser?.id ?? "",
            date: coordinator.navigationState.selectedDate,
            mealSlot: coordinator.navigationState.mealSlot,
            today: coordinator.todayProvider(),
            submitDrafts: { [weak coordinator] drafts, names, summary, completion in
                coordinator?.submitDraftsForFeature(
                    drafts,
                    itemNames: names,
                    summary: summary,
                    completion: completion
                )
            },
            onLogged: { [weak coordinator] date, slot in
                coordinator?.libraryDidLog(date: date, mealSlot: slot)
            },
            onSessionExpired: { [weak coordinator] in
                coordinator?.featureSessionExpired()
            },
            onClose: onClose,
            currentContextProvider: { coordinator.currentLibraryLogContext },
            onCreateWithAI: { [weak coordinator] in
                coordinator?.openAssistant(purpose: .customFood, initialBarcode: nil)
            }
        )
    }

    private func closeSettingsTab() {
        coordinator.dismissSettings()
        coordinator.requestTabSwitch(to: .diary)
    }

    @ViewBuilder
    private var settingsTab: some View {
        if let settings = coordinator.settingsViewModel {
            DiarySettingsView(
                viewModel: settings,
                accountSettingsViewModel: coordinator.accountSettingsViewModel,
                onClose: { closeSettingsTab() },
                onAccountSettingsDismissed: { [weak coordinator] in
                    coordinator?.dismissAccountSettings()
                },
                onSignOut: { [weak coordinator] in
                    Task { await coordinator?.signOut() }
                }
            )
        } else {
            ProgressView()
                .accessibilityIdentifier("app.settings.loading")
                .task { coordinator.ensureSettingsViewModel() }
        }
    }

    private func isContextualPane(_ pane: Pane) -> Bool {
        switch pane {
        case .diary: return false
        case .foodSearch, .foodDetail, .foodLog, .logEditor: return true
        }
    }

    @ViewBuilder
    private func compactDestination(_ pane: Pane) -> some View {
        let isLogEditor = isLogEditorPane(pane)
        paneView(pane, compactStyle: true)
            // Replace the system back gesture/button consistently on iOS and
            // macOS compact windows. Otherwise a system back action can bypass
            // the dirty/busy editor guard.
            .navigationBarBackButtonHidden(isLogEditor)
        #if os(iOS)
            // Contextual Add Food / Log Food / edit steps own the full screen;
            // the root TabView bar must not sit on top of the bottom Log button.
            .toolbar(isContextualPane(pane) ? .hidden : .automatic, for: .tabBar)
        #endif
            .toolbar {
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
            if coordinator.expandedLibrarySelected {
                libraryRoot(onClose: nil)
                    .id("library-\(coordinator.currentUser?.id ?? "none")")
            } else {
                NavigationStack {
                    paneView(plan.primaryPane)
                }
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
                .accessibilityIdentifier("app.sidebar.diary")
        case .search:
            Label(String(localized: "search.title"), systemImage: "magnifyingglass")
                .accessibilityIdentifier("app.sidebar.search")
        case .library:
            Label(String(localized: "library.title"), systemImage: "books.vertical")
                .accessibilityIdentifier("app.sidebar.library")
        }
    }

    private var sidebarSelection: Binding<PrimarySection?> {
        Binding(
            get: {
                coordinator.expandedLibrarySelected
                    ? .library
                    : coordinator.navigationState.primarySection
            },
            set: { section in
                guard let section else { return }
                switch section {
                case .diary:
                    coordinator.showDiary()
                case .search:
                    coordinator.showSearch()
                case .library:
                    coordinator.selectExpandedLibrary()
                }
            }
        )
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: {
                !coordinator.expandedLibrarySelected
                    && coordinator.navigationState.activePane.contextualFoodPane != nil
            },
            set: { isPresented in
                guard !isPresented,
                      !coordinator.expandedLibrarySelected,
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

    // MARK: Panes

    @ViewBuilder
    private func paneView(_ pane: Pane, compactStyle: Bool = false) -> some View {
        switch pane {
        case .diary:
            if let vm = coordinator.diaryViewModel {
                DiaryView(
                    viewModel: vm,
                    onOpenSettings: {
                        coordinator.showSettings()
                        if compactStyle { coordinator.requestTabSwitch(to: .settings) }
                    },
                    onOpenNutrition: { coordinator.showNutritionDetails() },
                    onOpenMeals: {
                        if compactStyle {
                            coordinator.requestTabSwitch(to: .library)
                        } else {
                            coordinator.openMealsList()
                        }
                    },
                    onOpenLibrary: {
                        if compactStyle {
                            coordinator.requestTabSwitch(to: .library)
                        } else {
                            coordinator.openLibrary(
                                date: coordinator.navigationState.selectedDate,
                                mealSlot: coordinator.navigationState.mealSlot
                            )
                        }
                    }
                )
            } else {
                ProgressView()
            }
        case .foodSearch:
            searchScreen(compactStyle: compactStyle)
        case .foodDetail(let foodID), .foodLog(let foodID):
            if let vm = coordinator.foodDetailViewModel(for: foodID) {
                FoodDetailView(viewModel: vm, compactStyle: compactStyle)
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
