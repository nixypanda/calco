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
import ComposableArchitecture
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
    public let generation: UInt64
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let initialMealID: String?
    public let initialPortion: NutritionQuantity?

    public init(
        id: UUID = UUID(),
        generation: UInt64 = 0,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        initialMealID: String? = nil,
        initialPortion: NutritionQuantity? = nil
    ) {
        self.id = id
        self.generation = generation
        self.date = date
        self.mealSlot = mealSlot
        self.initialMealID = initialMealID
        self.initialPortion = initialPortion
    }
}

/// Owns whether the Search feature is backed by the legacy SearchViewModel or
/// the migrated TCA feature. The coordinator only constructs and drives the
/// legacy SearchViewModel in `.legacy` mode; `.tca` keeps the ready graph and
/// generation authority intact while leaving Search construction/rendering to
/// the future root-bridge task. The actual renderer is still legacy until that
/// bridge lands, so production callers should keep the default.
public enum SearchOwnership: Sendable, Equatable {
    case legacy
    case tca
}

/// Ownership of Diary *rendering* during the transitional migration. Both modes
/// keep the coordinator's existing ready graph, bootstrap load and legacy
/// `DiaryViewModel` intact; `.storeBackedScreen` only means the native screen is
/// hosted from the TCA window store instead of the legacy `DiaryView`. Production
/// stays on `.legacy`; only the QA-gated test host opts into the store-backed
/// screen.
public enum DiaryScreenOwnership: Sendable, Equatable {
    case legacy
    case storeBackedScreen
}

/// One immutable, typed log-editor mutation handed to the store-backed Diary
/// owner. The localized notice is built by the coordinator *before* the async
/// handoff, so a later generation/date change cannot rewrite what the user did.
/// The editor service already produces a `DiaryLog`; there is no FoodLog
/// conversion on this path.
public enum DiaryEditorMutation: Equatable, Sendable {
    case saved(
        originalID: String,
        date: LocalDiaryDate,
        log: DiaryLog,
        notice: DiaryMutationNotice
    )
    case deleted(
        id: String,
        date: LocalDiaryDate,
        notice: DiaryMutationNotice
    )

    /// The single date this mutation touches (the captured editor date).
    public var date: LocalDiaryDate {
        switch self {
        case .saved(_, let date, _, _), .deleted(_, let date, _):
            return date
        }
    }

    /// The immutable localized notice projected from the captured payload —
    /// never reconstructed at delivery time.
    public var notice: DiaryMutationNotice {
        switch self {
        case .saved(_, _, _, let notice), .deleted(_, _, let notice):
            return notice
        }
    }
}

/// One successful typed submission delivered to the store-backed Diary owner.
/// Affected dates are the de-duplicated union of draft dates and the log dates
/// returned by the server, so a multi-day write can never be silently dropped.
public struct DiaryMutationDelivery: Equatable, Sendable {
    public let generation: UInt64
    public let affectedDates: [LocalDiaryDate]
    /// Original server payload; conversion to a `DiaryLog` belongs to the
    /// receiving owner, which can reject a malformed row per date.
    public let logs: [FoodLog]
    /// Set only by the transitional log-editor slice. It is mutually exclusive
    /// with the created-submission payload: there is no memberwise init, so an
    /// invalid "created + editor" combination cannot be constructed.
    public let editor: DiaryEditorMutation?

    /// Created (quick-add/copy/batch) submission. Preserves the original
    /// signature and behaviour: the editor payload is always `nil`.
    public init(generation: UInt64, drafts: [LogSubmissionDraft], logs: [FoodLog]) {
        self.generation = generation
        self.editor = nil
        var dates: [LocalDiaryDate] = []
        var seen: Set<LocalDiaryDate> = []
        let candidates = drafts.map(\.date) + logs.map(\.logDate)
        for date in candidates where seen.insert(date).inserted {
            dates.append(date)
        }
        self.affectedDates = dates
        self.logs = logs
    }

    /// Log-editor mutation. The captured date is the single affected date and
    /// no created-submission row payload is present.
    public init(generation: UInt64, editor: DiaryEditorMutation) {
        self.generation = generation
        self.editor = editor
        self.affectedDates = [editor.date]
        self.logs = []
    }

    /// FoodDetail's frozen submission callback has no full server row. Let the
    /// existing owner invalidate the captured date and refresh only if visible.
    public init(generation: UInt64, invalidating date: LocalDiaryDate) {
        self.generation = generation
        self.affectedDates = [date]
        self.logs = []
        self.editor = nil
    }
}

/// Shared top-level destinations for the bottom tabs and expanded sidebar.
public enum AppShellTab: Hashable, Sendable, CaseIterable {
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

    public var id: String {
        switch self {
        case .nutrition(let viewModel):
            return "nutrition-\(viewModel.id.uuidString)"
        case .meals(let request):
            return "meals-\(request.id.uuidString)"
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
    /// Read-only ownership mode for the Search feature. The future root bridge
    /// will read this to decide whether to host the TCA search store; the
    /// coordinator never holds a TCA store or event bus.
    public let searchOwnership: SearchOwnership
    /// Transitional rendering owner. Default keeps every existing legacy path.
    public let diaryScreenOwnership: DiaryScreenOwnership

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

    public var currentUser: AuthUser? { featureGraph.readyState?.user }
    public var diaryViewModel: DiaryViewModel? { featureGraph.readyState?.diary }
    public var searchViewModel: SearchViewModel? {
        featureGraph.readyState?.search.legacyViewModel
    }
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
        searchOwnership: SearchOwnership = .legacy,
        diaryScreenOwnership: DiaryScreenOwnership = .legacy,
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
        self.searchOwnership = searchOwnership
        self.diaryScreenOwnership = diaryScreenOwnership
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

        /// Owned Search representation. `.legacy` holds the coordinator-owned
        /// SearchViewModel; `.tca` means the future root bridge owns Search and
        /// this coordinator must not construct or drive a legacy view model.
        enum Search {
            case legacy(SearchViewModel)
            case tca

            var legacyViewModel: SearchViewModel? {
                guard case .legacy(let viewModel) = self else { return nil }
                return viewModel
            }

            @MainActor
            func invalidateIfLegacy() {
                legacyViewModel?.invalidateSession()
            }
        }

        struct Ready {
            let user: AuthUser
            let generation: UInt64
            let services: FeatureServices
            let diary: DiaryViewModel
            let search: Search
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
        previous.readyState?.search.invalidateIfLegacy()
        // TCA mode: eventual invalidation/context delivery is pending a future
        // root-bridge seam that can forward generation resets to the TCA search
        // store. No coordinator-owned store, event bus, or noop callback here.
        navigationState = NavigationState(date: todayProvider())
    }

    private func clearPresentedFeatures() {
        if case .nutrition(let viewModel) = featureSheet {
            viewModel.resetForSessionChange()
        }
        accountSettingsViewModel?.clearForSignOut()
        accountSettingsViewModel = nil
        featureSheet = nil
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
        previous.readyState?.search.invalidateIfLegacy()
        // TCA mode: eventual invalidation/context delivery is pending a future
        // root-bridge seam that can forward generation resets to the TCA search
        // store. No coordinator-owned store, event bus, or noop callback here.
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

        let search: FeatureGraph.Search
        switch searchOwnership {
        case .legacy:
            search = .legacy(SearchViewModel(
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
                    self?.handleSessionExpired(generation: generation
                    )
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
            ))
        case .tca:
            // The TCA root bridge will own SearchViewModel/store construction
            // and receive future context/invalidation deliveries. The coordinator
            // keeps the ready graph and generation authority, but constructs no
            // legacy SearchViewModel and issues no legacy search side effects.
            search = .tca
        }

        featureGraph = .ready(FeatureGraph.Ready(
            user: user,
            generation: generation,
            services: services,
            diary: diaryVM,
            search: search,
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

    /// Narrow, public generation check for the migrated search screen's routing
    /// client. It reads the private feature graph without exposing it, and
    /// validates the captured generation against both the ready graph and the
    /// session authority. Phase eligibility is checked by the caller.
    public func isCurrentSearchGeneration(_ generation: UInt64) -> Bool {
        isCurrent(generation)
    }

    /// Narrow, public generation check for the migrated diary screen's runtime
    /// clients. It mirrors `isCurrentSearchGeneration`: it reads the private
    /// feature graph without exposing it, and validates the captured generation
    /// against both the ready graph and the session authority. Phase
    /// eligibility is checked by the caller.
    public func isCurrentDiaryGeneration(_ generation: UInt64) -> Bool {
        isCurrent(generation)
    }

    /// Resolves the ready-graph-owned diary service only when `generation` is
    /// still current. Returns `nil` for stale, missing, or deallocated graph
    /// state so callers can map the miss to `.cancelled` without touching the
    /// session authority.
    public func currentDiaryServiceIfCurrent(_ generation: UInt64) -> (any DiaryServicing)? {
        guard isCurrent(generation) else { return nil }
        return currentDiaryService
    }

    // MARK: - Search ownership side effects
    //
    // Legacy mode drives the coordinator-owned SearchViewModel. TCA mode has no
    // legacy VM; the root bridge installs narrow closures that forward context
    // and external recents invalidation into the TCA store without giving the
    // coordinator a store reference or event bus.

    private var tcaSearchContextChanged:
        (@MainActor (LocalDiaryDate, MealSlot?, UInt64) -> Void)?
    private var tcaSearchRecentsInvalidated: (@MainActor (UInt64) -> Void)?

    /// Store-backed Diary owns refresh/reconciliation. The runtime installs a
    /// weak-store callback once; the coordinator holds the command value but
    /// never a store, service, or view model of its own.
    private var diaryMutationCallback: (@MainActor (DiaryMutationDelivery) async -> Void)?

    /// Store-backed Diary owns the saved-goal writeback. The runtime installs a
    /// weak-store callback once; the coordinator holds only the command value,
    /// never a store. Legacy mode never invokes this callback.
    private var settingsGoalCallback: (@MainActor (UInt64, DiaryGoalTargets, LocalDiaryDate) -> Void)?

    /// Store-backed Diary owns the saved-preferences writeback. The runtime
    /// installs a weak-store callback once; the coordinator holds only the
    /// command value, never a store. Legacy mode never invokes this callback.
    private var settingsPreferencesCallback: (@MainActor (UInt64, DiaryPrefs) -> Void)?

    /// Weak, store-backed row resolver for the transitional log editor. The
    /// runtime installs a closure that reads only the TCA visible day, its saved
    /// override, or its settled cache. The coordinator never falls back to the
    /// legacy `DiaryViewModel` when the store-backed screen is active, so a
    /// freshly written row is provably read from the authoritative owner.
    private var storeLogResolver: (@MainActor (String, LocalDiaryDate, UInt64) -> DiaryLog?)?

    /// Narrow root-bridge seam for successful typed submissions in
    /// `.storeBackedScreen` mode. Legacy mode never invokes this callback.
    public func installDiaryMutationCallback(
        _ callback: @escaping @MainActor (DiaryMutationDelivery) async -> Void
    ) {
        diaryMutationCallback = callback
    }

    /// Canonical root-bridge seam for successful settings goal saves in
    /// `.storeBackedScreen` mode. The runtime captures its store weakly, so this
    /// command value cannot retain the window graph. Legacy mode never invokes
    /// it: the legacy `DiaryViewModel` stays the sole owner there.
    public func installSettingsGoalCallback(
        _ callback: @escaping @MainActor (UInt64, DiaryGoalTargets, LocalDiaryDate) -> Void
    ) {
        settingsGoalCallback = callback
    }

    /// Canonical root-bridge seam for successful settings preference saves in
    /// `.storeBackedScreen` mode. The runtime captures its store weakly, so this
    /// command value cannot retain the window graph. Legacy mode never invokes
    /// it: the legacy `DiaryViewModel` stays the sole owner there.
    public func installSettingsPreferencesCallback(
        _ callback: @escaping @MainActor (UInt64, DiaryPrefs) -> Void
    ) {
        settingsPreferencesCallback = callback
    }

    /// Narrow root-bridge seam for editor row lookup. The runtime captures the
    /// store weakly, so this command value cannot retain the window graph.
    public func installStoreLogResolver(
        _ resolver: @escaping @MainActor (String, LocalDiaryDate, UInt64) -> DiaryLog?
    ) {
        storeLogResolver = resolver
    }

    /// Narrow root-bridge seam. The runtime installs weak-store closures after
    /// the ready graph exists; the coordinator only invokes them in `.tca` mode
    /// with a current ready generation.
    public func installTCASearchHandlers(
        contextChanged: @escaping @MainActor (LocalDiaryDate, MealSlot?, UInt64) -> Void,
        recentsInvalidated: @escaping @MainActor (UInt64) -> Void
    ) {
        tcaSearchContextChanged = contextChanged
        tcaSearchRecentsInvalidated = recentsInvalidated
    }

    private func legacySearchContextDidChange(
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
        switch searchOwnership {
        case .legacy:
            searchViewModel?.updateContext(date: date, mealSlot: mealSlot)
        case .tca:
            guard let ready = featureGraph.readyState,
                  ready.generation == session.sessionGeneration else { return }
            tcaSearchContextChanged?(date, mealSlot, ready.generation)
        }
    }

    private func legacySearchSelectionDidClear() {
        switch searchOwnership {
        case .legacy:
            searchViewModel?.clearSelection()
        case .tca:
            // TCA SearchScreenFeature clears selection on appearance; no legacy
            // VM exists and no coordinator-to-store selection write is needed.
            break
        }
    }

    private func notifyTCASearchRecentsInvalidatedIfCurrent() {
        guard searchOwnership == .tca,
              let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        tcaSearchRecentsInvalidated?(ready.generation)
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
        legacySearchContextDidChange(date: date, mealSlot: state.mealSlot)
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

    /// Generation-preserving variant used by runtime-injected diary submission
    /// clients. It validates the captured generation synchronously before
    /// delegating to the private writer so a transition between the wrapper
    /// check and the callback cannot rebind to a newer generation.
    public func submitDraftsForFeature(
        _ drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        expectedGeneration: UInt64,
        completion: @escaping (LogSubmissionServiceResult) -> Void
    ) {
        guard isCurrent(expectedGeneration) else {
            completion(.failure(.unauthorized))
            return
        }
        submitDrafts(
            drafts,
            itemNames: itemNames,
            summary: summary,
            generation: expectedGeneration,
            completion: completion
        )
    }

    /// These are captured by Meals/Library presentations, not rebound when an
    /// old view invokes a retained callback after a session transition.
    func featureSubmissionHandler(expectedGeneration: UInt64) -> LogSubmissionHandler {
        { [weak self] drafts, names, summary, completion in
            guard let self else {
                completion(.failure(.unauthorized))
                return
            }
            self.submitDraftsForFeature(
                drafts, itemNames: names, summary: summary,
                expectedGeneration: expectedGeneration, completion: completion
            )
        }
    }

    func featureLoggedHandler(
        expectedGeneration: UInt64
    ) -> (LocalDiaryDate, MealSlot?) -> Void {
        { [weak self] date, slot in
            self?.libraryDidLog(date: date, mealSlot: slot, expectedGeneration: expectedGeneration)
        }
    }

    func featureSessionExpiredHandler(expectedGeneration: UInt64) -> () -> Void {
        { [weak self] in
            self?.handleSessionExpired(generation: expectedGeneration)
        }
    }

    func mealsListLoggedHandler(expectedGeneration: UInt64) -> ((LocalDiaryDate, MealSlot?) -> Void)? {
        // Legacy list logging historically has no post-write hook (the shared
        // writer refreshes once); direct Meals/Library retain their own hook.
        diaryScreenOwnership == .storeBackedScreen
            ? featureLoggedHandler(expectedGeneration: expectedGeneration)
            : nil
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
            if case .success(let logs) = result {
                switch self.diaryScreenOwnership {
                case .legacy:
                    // Unchanged legacy owner: the sole writer refreshes the
                    // coordinator-owned diary once.
                    await self.diaryViewModel?.refresh()

                case .storeBackedScreen:
                    // Re-check immediately before the async handoff so a
                    // generation change during the write cannot route a stale
                    // payload into a newer session.
                    guard self.isCurrent(generation) else {
                        completion(result)
                        return
                    }
                    let delivery = DiaryMutationDelivery(
                        generation: generation,
                        drafts: drafts,
                        logs: logs
                    )
                    await self.diaryMutationCallback?(delivery)
                    // Exactly-once completion survives the async work; the
                    // owning callback performs its own post-await generation
                    // guard, so a new session is never refreshed here.
                    guard self.isCurrent(generation) else {
                        completion(result)
                        return
                    }
                }
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
        legacySearchContextDidChange(date: date, mealSlot: slot)
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
        legacySearchContextDidChange(date: state.selectedDate, mealSlot: state.mealSlot)
        ensureFoodDetailViewModel(foodID: foodID, date: date, mealSlot: mealSlot)
    }

    /// Search tab selection: detail is pushed on the Search tab's own native
    /// stack. `navigationState` (the hidden Diary stack) is deliberately left
    /// untouched, so Back returns to Search and no hidden stack is stranded.
    ///
    /// Legacy fallback derives the target context from the live navigation
    /// state. It delegates to the captured-context overload so there is a
    /// single legacy body; the migrated search screen calls the overload with
    /// its captured date/meal slot, which stays correct after the cutover when
    /// the old `SearchViewModel` context is stale.
    public func openSearchTabFoodDetail(_ foodID: String) {
        openSearchTabFoodDetail(
            foodID,
            date: navigationState.selectedDate,
            mealSlot: navigationState.mealSlot
        )
    }

    /// Search-tab food detail routed with the originating screen's captured
    /// context. The caller (the legacy routing client) has already validated
    /// the captured generation, so this reuses the established graph and dirty
    /// guards without consulting any old/new search view model wrapper.
    public func openSearchTabFoodDetail(
        _ foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
        guard featureGraph.readyState?.generation == session.sessionGeneration else { return }
        searchTabPath = [.foodDetail(foodID: foodID)]
        ensureFoodDetailViewModel(
            foodID: foodID,
            date: date,
            mealSlot: mealSlot
        )
    }

    /// The Search tab stack only ever holds one detail; a shorter path is the
    /// system Back gesture/button popping that detail.
    public func popSearchTabDetail() {
        searchTabPath = []
        legacySearchSelectionDidClear()
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
                _ = self?.handleFoodDetailSuccess(
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

    public func openLogEditor(logID: String, date: LocalDiaryDate, generation: UInt64) {
        guard isCurrent(generation),
              let ready = featureGraph.readyState else { return }
        let log: DiaryLog?
        switch diaryScreenOwnership {
        case .legacy:
            log = ready.diary.log(withID: logID)
        case .storeBackedScreen:
            // Fresh-row proof: with the store-backed screen active the TCA owner
            // is the only source. A stale legacy VM row is never a fallback.
            log = storeLogResolver?(logID, date, generation)
        }
        guard let log else { return }

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

        // Dedup and context identity are shared by both owners: one editor
        // instance may report success exactly once, and only while it is still
        // the editor the coordinator owns.
        let identifier = ObjectIdentifier(viewModel)
        guard deliveredLogEditorSuccesses[viewModel.logID] != identifier else { return }
        deliveredLogEditorSuccesses[viewModel.logID] = identifier
        pendingEditorDiscard = nil

        if diaryScreenOwnership == .storeBackedScreen {
            notifyTCASearchRecentsInvalidatedIfCurrent()
            var state = navigationState
            if state.activePane == .logEditor(logID: viewModel.logID) {
                _ = state.back()
                navigationState = state
            }

            // Build the immutable payload and its localized notice BEFORE the
            // async handoff. The notice title is the edited log's own title;
            // the delete notice carries the editor's blocked-pending count.
            // No legacy applyVM/refreshVM happens on this path.
            let mutation: DiaryEditorMutation
            switch kind {
            case .saved:
                // A save without an authoritative PUT response fails closed;
                // no row is fabricated for the store-backed owner.
                guard let saved = viewModel.lastSavedLog else { return }
                mutation = .saved(
                    originalID: viewModel.logID,
                    date: date,
                    log: saved,
                    notice: DiaryMutationNotice(kind: .saved, title: viewModel.title)
                )
            case .deleted:
                mutation = .deleted(
                    id: viewModel.logID,
                    date: date,
                    notice: DiaryMutationNotice(
                        kind: .deleted,
                        title: viewModel.title,
                        blockedPendingCount: viewModel.blockedPendingCount
                    )
                )
            }
            let delivery = DiaryMutationDelivery(generation: generation, editor: mutation)
            Task { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                await self.diaryMutationCallback?(delivery)
            }
            return
        }

        // Legacy owner keeps the exact established behaviour: apply the
        // response to the VM, go back, refresh once and show the notice.
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

        notifyTCASearchRecentsInvalidatedIfCurrent()

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
            legacySearchContextDidChange(
                date: navigationState.selectedDate,
                mealSlot: navigationState.mealSlot
            )
        }
    }

    /// Selecting a diary/search route always leaves the expanded Library
    /// destination so the sidebar selection cannot disagree with the detail.
    private func clearExpandedLibrarySelection() {
        expandedLibrarySelected = false
        if selectedTab == .settings { selectedTab = .diary }
    }

    public var selectedSidebarDestination: AppShellTab {
        if selectedTab == .settings { return .settings }
        if expandedLibrarySelected { return .library }
        return navigationState.primarySection == .search ? .search : .diary
    }

    public func selectSidebarDestination(_ destination: AppShellTab) {
        switch destination {
        case .diary: showDiary()
        case .search: showSearch()
        case .library: selectExpandedLibrary()
        case .settings: requestTabSwitch(to: .settings)
        }
    }

    public func selectExpandedLibrary() {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        guard !requestDiscardIfNeeded(for: .switchTab(tab: .library)) else { return }
        selectedTab = .library
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
                  ready.generation == session.sessionGeneration else { return }
            let log: DiaryLog?
            switch diaryScreenOwnership {
            case .legacy:
                log = ready.diary.log(withID: logID)
            case .storeBackedScreen:
                log = storeLogResolver?(logID, date, ready.generation)
            }
            guard let log else { return }
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
        legacySearchSelectionDidClear()
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
        legacySearchSelectionDidClear()
        legacySearchContextDidChange(date: date, mealSlot: state.mealSlot)

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
    /// Settings destination calls this so it is usable even before the diary
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

    public func showNutritionDetails(
        onOpen: ((LocalDiaryDate, LocalDiaryDate) -> Void)? = nil
    ) {
        guard featureSheet == nil,
              let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration else { return }
        if let onOpen {
            onOpen(navigationState.selectedDate, todayProvider())
            return
        }
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
                generation: session.sessionGeneration,
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

    public func dismissFeatureSheet() {
        featureSheet = nil
    }

    public func libraryDidLog(date: LocalDiaryDate, mealSlot: MealSlot?) {
        libraryDidLog(date: date, mealSlot: mealSlot, expectedGeneration: session.sessionGeneration)
    }

    func libraryDidLog(date: LocalDiaryDate, mealSlot: MealSlot?, expectedGeneration: UInt64) {
        guard isCurrent(expectedGeneration) else { return }
        guard let ready = featureGraph.readyState,
              ready.generation == expectedGeneration else { return }
        _ = mealSlot
        switch diaryScreenOwnership {
        case .legacy:
            guard ready.diary.selectedDate == date else { return }
            notifyTCASearchRecentsInvalidatedIfCurrent()
            Task { [weak self] in
                guard self?.isCurrent(expectedGeneration) == true else { return }
                await ready.diary.refresh()
            }
        case .storeBackedScreen:
            // The shared writer already delivered to the sole Diary owner.
            // Recents still change for successful writes on nonvisible dates.
            notifyTCASearchRecentsInvalidatedIfCurrent()
        }
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
        // The service response, not the draft, is authoritative. Map it once and
        // deliver to exactly one owner; there is no dual-apply path.
        let targets = CalCoStoreMapping.diaryGoal(from: snapshot)
        switch diaryScreenOwnership {
        case .legacy:
            // Unchanged legacy owner: apply the mapped server values to the
            // coordinator-owned diary, exactly as before.
            ready.diary.applySavedGoal(targets, effectiveOn: snapshot.requestedDate)
        case .storeBackedScreen:
            // Store-backed Diary is the sole owner: forward the mapped values
            // and the server-requested date. No legacy apply, GET, or notice.
            settingsGoalCallback?(generation, targets, snapshot.requestedDate)
        }
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
        switch diaryScreenOwnership {
        case .legacy:
            // Unchanged legacy owner: apply the mapped server values to the
            // coordinator-owned diary, exactly as before.
            ready.diary.applySavedPreferences(prefs)
        case .storeBackedScreen:
            // Store-backed Diary is the sole owner: forward the mapped server
            // prefs. No legacy apply, GET, or notice.
            settingsPreferencesCallback?(generation, prefs)
        }

        // The date is preserved; only a now-disabled contextual meal slot is
        // cleared, and search inherits that updated context.
        if let slot = navigationState.mealSlot, !prefs.isEnabled(slot) {
            var state = navigationState
            state.setMealSlot(nil)
            navigationState = state
            legacySearchContextDidChange(date: state.selectedDate, mealSlot: nil)
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
        legacySearchSelectionDidClear()
        legacySearchContextDidChange(date: state.selectedDate, mealSlot: state.mealSlot)
    }

    public func back() {
        var state = navigationState
        // Only a *food* detail owns search selection. The log editor is also an
        // inspector pane but has nothing to do with the search flow.
        let wasShowingFoodDetail = state.activePane.contextualFoodID != nil
        guard state.back() else { return }
        navigationState = state
        if wasShowingFoodDetail {
            legacySearchSelectionDidClear()
        }
        legacySearchContextDidChange(date: state.selectedDate, mealSlot: state.mealSlot)
    }

    @discardableResult
    func handleFoodDetailSuccess(_ viewModel: FoodDetailViewModel) -> Task<Void, Never>? {
        guard let ready = featureGraph.readyState,
              ready.generation == session.sessionGeneration,
              // Compatibility entry has no captured generation. Only a source
              // still owned by this graph can borrow its generation. Actual
              // submission callbacks use the captured-generation overload below.
              ready.foodDetails[viewModel.foodID] === viewModel else { return nil }
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
        return handleFoodDetailSuccess(
            success,
            expectedGeneration: ready.generation,
            source: viewModel
        )
    }

    private func handleFoodDetailSuccess(
        _ success: FoodLogSubmissionSuccess,
        expectedGeneration: UInt64,
        source: FoodDetailViewModel?
    ) -> Task<Void, Never>? {
        guard expectedGeneration == session.sessionGeneration,
              let ready = featureGraph.readyState,
              ready.generation == expectedGeneration,
              success.accountID == ready.user.id,
              deliveredSubmissionIDs.insert(success.submissionID).inserted
        else { return nil }

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

        notifyTCASearchRecentsInvalidatedIfCurrent()

        if isActiveDetail {
            var state = navigationState
            state.selectDate(originDate)
            if state.mealSlot != mealSlot {
                state.setMealSlot(mealSlot)
            }
            navigationState = state
            legacySearchSelectionDidClear()
            legacySearchContextDidChange(
                date: originDate,
                mealSlot: mealSlot
            )
        }

        return Task { [weak self] in
            guard let self,
                  let current = self.featureGraph.readyState,
                  current.generation == generation,
                  generation == self.session.sessionGeneration else { return }
            if self.diaryScreenOwnership == .storeBackedScreen {
                await self.diaryMutationCallback?(
                    DiaryMutationDelivery(generation: generation, invalidating: originDate)
                )
                return
            }
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

    static let sidebarSections: [AppShellTab] = AppShellTab.allCases

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

/// Narrow live seam for the native Diary screen while the legacy diary shell
/// and the TCA root coexist. A non-nil bridge means TCA owns diary presentation
/// from the persistent Window state; `nil` keeps the legacy `DiaryView` /
/// `DiaryViewModel` path. The bridge only carries the scoped store and the two
/// external navigation callbacks the native screen exposes — no service, store,
/// or view-model construction of its own.
public struct NativeDiaryBridge {
    public let store: StoreOf<DiaryScreenFeature>
    public let onOpenSettings: () -> Void
    public let onOpenNutrition: () -> Void

    public init(
        store: StoreOf<DiaryScreenFeature>,
        onOpenSettings: @escaping () -> Void,
        onOpenNutrition: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenNutrition = onOpenNutrition
    }
}

public struct AppShell: View {
    private enum Modal: Identifiable {
        case feature(AppShellFeatureSheet)
        case food(String)

        var id: String {
            switch self {
            case .feature(let sheet): return sheet.id
            case .food(let id): return "food-log-\(id)"
            }
        }
    }
    @StateObject private var coordinator: AppShellCoordinator
    private let nutritionBridge: NativeNutritionBridge?
    private let searchBridge: NativeSearchBridge?
    private let diaryBridge: NativeDiaryBridge?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingBannerDiscard: PendingLogSubmission?
    /// Tab selection lives on the coordinator so the native tab bar goes
    /// through the shared discard/busy guard. Each destination still keeps its
    /// own navigation stack and route-owned view models across tab switches.

    public init(
        nutritionBridge: NativeNutritionBridge? = nil,
        searchBridge: NativeSearchBridge? = nil,
        diaryBridge: NativeDiaryBridge? = nil
    ) {
        _coordinator = StateObject(wrappedValue: AppShellCoordinator())
        self.nutritionBridge = nutritionBridge
        self.searchBridge = searchBridge
        self.diaryBridge = diaryBridge
    }

    public init(
        sessionAuthority: CalCoSessionAuthority,
        nutritionBridge: NativeNutritionBridge? = nil,
        searchBridge: NativeSearchBridge? = nil,
        diaryBridge: NativeDiaryBridge? = nil
    ) {
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
        self.nutritionBridge = nutritionBridge
        self.searchBridge = searchBridge
        self.diaryBridge = diaryBridge
    }

    public init(
        coordinator: AppShellCoordinator,
        nutritionBridge: NativeNutritionBridge? = nil,
        searchBridge: NativeSearchBridge? = nil,
        diaryBridge: NativeDiaryBridge? = nil
    ) {
        _coordinator = StateObject(wrappedValue: coordinator)
        self.nutritionBridge = nutritionBridge
        self.searchBridge = searchBridge
        self.diaryBridge = diaryBridge
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
            .sheet(item: modalBinding) { sheet in
                switch sheet {
                case .feature(let feature): featureSheetView(feature)
                case .food(let id):
                    if let vm = coordinator.foodDetailViewModel(for: id) {
                        FoodLogTaskView(viewModel: vm, onClose: dismissFoodLog)
                    }
                }
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

    private var loggingFoodID: String? {
        if coordinator.selectedTab == .search {
            return NativePresentation.loggingFoodID(
                in: coordinator.searchTabPath.last ?? coordinator.navigationState.activePane
            )
        }
        guard coordinator.selectedTab == .diary else { return nil }
        return NativePresentation.loggingFoodID(in: coordinator.navigationState.activePane)
    }

    private func dismissFoodLog() {
        guard let id = loggingFoodID,
              coordinator.foodDetailViewModel(for: id)?.isBusy != true else { return }
        if !coordinator.searchTabPath.isEmpty {
            coordinator.popSearchTabDetail()
        } else {
            coordinator.requestBack()
        }
    }

    private var modalBinding: Binding<Modal?> {
        Binding(
            get: {
                if let sheet = coordinator.featureSheet {
                    if case .nutrition = sheet { return nil }
                    return .feature(sheet)
                }
                return loggingFoodID.map(Modal.food)
            },
            set: { newValue in
                if newValue == nil {
                    if coordinator.featureSheet != nil {
                        coordinator.dismissFeatureSheet()
                    } else {
                        dismissFoodLog()
                    }
                }
            }
        )
    }

    private var nutritionPagePresented: Binding<Bool> {
        Binding(
            get: {
                if let nutritionBridge {
                    return nutritionBridge.store != nil
                }
                if case .nutrition = coordinator.featureSheet { return true }
                return false
            },
            set: { isPresented in
                guard !isPresented else { return }
                if let nutritionBridge {
                    nutritionBridge.onDismiss()
                } else {
                    coordinator.dismissFeatureSheet()
                }
            }
        )
    }

    @ViewBuilder
    private var nutritionPage: some View {
        if let nutritionBridge {
            if let store = nutritionBridge.store {
                NutritionDetailsFeatureView(store: store)
            }
        } else if case .nutrition(let vm) = coordinator.featureSheet {
            NutritionDetailsView(viewModel: vm)
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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
                    Button(String(localized: "foodDetail.pending.discard"), role: .destructive) {
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
          if coordinator.isCurrentSearchGeneration(request.generation) {
            if let mealID = request.initialMealID {
                MealLogTaskHost(
                    mealID: mealID,
                    date: request.date,
                    mealSlot: request.mealSlot,
                    initialPortion: request.initialPortion,
                    service: coordinator.currentMealsService,
                    onSubmitDrafts: coordinator.featureSubmissionHandler(
                        expectedGeneration: request.generation
                    ),
                    onSessionExpired: coordinator.featureSessionExpiredHandler(
                        expectedGeneration: request.generation
                    ),
                    onLogged: coordinator.featureLoggedHandler(expectedGeneration: request.generation)
                )
            } else {
              MealsFlowView(
                date: request.date,
                mealSlot: request.mealSlot,
                accountID: coordinator.currentUser?.id ?? "",
                service: coordinator.currentMealsService,
                onSubmitDrafts: coordinator.featureSubmissionHandler(
                    expectedGeneration: request.generation
                ),
                onSessionExpired: coordinator.featureSessionExpiredHandler(
                    expectedGeneration: request.generation
                ),
                onLogged: coordinator.mealsListLoggedHandler(expectedGeneration: request.generation),
                onClose: { [weak coordinator] in
                    guard coordinator?.isCurrentSearchGeneration(request.generation) == true else { return }
                    coordinator?.dismissFeatureSheet()
                },
                initialMealID: request.initialMealID,
                initialPortion: request.initialPortion
              )
            }
          }
        }
    }

    // MARK: Compact

    /// Native iPhone tabs. Diary owns the contextual Add Food push;
    /// Library owns Foods and Meals; Settings owns goals, slots, and API keys.
    private var tabSelection: Binding<AppShellTab> {
        Binding(
            get: { coordinator.selectedTab },
            set: { coordinator.requestTabSwitch(to: $0) }
        )
    }

    private var compactTabShell: some View {
        TabView(selection: tabSelection) {
            ForEach(AppShellTab.allCases, id: \.self) { tab in
                tabContent(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                            .accessibilityIdentifier("app.tab.\(tab)")
                    }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppShellTab) -> some View {
        switch tab {
        case .diary: diaryTab
        case .search: searchTab
        case .library:
            // Library owns its NavigationStack and keeps account-scoped identity
            // so date changes do not destroy an in-progress editor.
            libraryRoot(onClose: nil)
                .id("library-\(coordinator.currentUser?.id ?? "none")")
        case .settings: settingsTab
        }
    }

    private var diaryTab: some View {
        let plan = AppShellPanePlan.plan(
            for: coordinator.navigationState,
            layout: .compact
        )
        return NavigationStack(path: compactPath) {
            paneView(plan.rootPane, compactStyle: true)
                .navigationDestination(isPresented: nutritionPagePresented) { nutritionPage }
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
            get: { NativePresentation.pagePath(coordinator.searchTabPath) },
            set: { newPath in
                guard newPath.count < NativePresentation.pagePath(coordinator.searchTabPath).count else { return }
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

    /// Single owner of the shared Search / Add Food screen. A non-nil
    /// `searchBridge` means TCA owns search presentation; the legacy
    /// SearchViewModel fallback is used only when the bridge is absent.
    @ViewBuilder
    private func searchScreen(compactStyle: Bool, isSearchTabRoot: Bool = false) -> some View {
        if let searchBridge {
            let origin: SearchScreenFeature.NavigationOrigin = isSearchTabRoot ? .searchTab : .diaryPush
            let windowStore = searchBridge.windowStore
            let capturedPresentation = windowStore.foodCreation?.origin == origin
                ? windowStore.foodCreation
                : nil
            let presentedID = capturedPresentation?.id
            SearchScreenView(
                store: windowStore.scope(state: \.search, action: \.search),
                onOpenMeals: {
                    let search = windowStore.search
                    windowStore.send(.openSearchMeals(
                        date: search.originDate,
                        mealSlot: search.originMealSlot,
                        generation: search.sessionGeneration
                    ))
                },
                navigationOrigin: origin
            )
            .navigationDestination(
                isPresented: Binding(
                    get: {
                        guard let presentedID else { return false }
                        let current = windowStore.foodCreation
                        return current?.id == presentedID && current?.origin == origin
                    },
                    set: { isPresented in
                        guard !isPresented, let presentedID else { return }
                        guard windowStore.foodCreation?.id == presentedID else { return }
                        windowStore.send(.closeFoodCreation(expectedPresentationID: presentedID))
                    }
                )
            ) {
                if let capturedPresentation {
                    SearchFoodCreationHostView(
                        presentation: capturedPresentation,
                        context: capturedFoodCreationContext(
                            date: capturedPresentation.date,
                            mealSlot: capturedPresentation.mealSlot,
                            generation: capturedPresentation.generation
                        ),
                        onFinished: {
                            windowStore.send(.foodCreationCompleted(
                                expectedPresentationID: capturedPresentation.id
                            ))
                        }
                    )
                }
            }
        } else if let vm = coordinator.searchViewModel {
            SearchView(
                viewModel: vm,
                onOpenMeals: {
                    if compactStyle {
                        coordinator.requestTabSwitch(to: .library)
                    } else {
                        coordinator.selectExpandedLibrary()
                    }
                },
                onSelectFoodID: isSearchTabRoot
                    ? { foodID in coordinator.openSearchTabFoodDetail(foodID) }
                    : nil,
                creationContextProvider: foodCreationContextProvider()
            )
        } else {
            ProgressView()
                .accessibilityIdentifier("app.search.loading")
        }
    }

    @ViewBuilder
    private func libraryRoot(onClose: (() -> Void)? = nil) -> some View {
        let generation = coordinator.session.sessionGeneration
        let capturedContext = coordinator.currentLibraryLogContext
        LibraryRootView(
            service: coordinator.currentLibraryService,
            mealsService: coordinator.currentMealsService,
            accountID: coordinator.currentUser?.id ?? "",
            date: coordinator.navigationState.selectedDate,
            mealSlot: coordinator.navigationState.mealSlot,
            today: coordinator.todayProvider(),
            submitDrafts: coordinator.featureSubmissionHandler(expectedGeneration: generation),
            onLogged: coordinator.featureLoggedHandler(expectedGeneration: generation),
            onSessionExpired: coordinator.featureSessionExpiredHandler(expectedGeneration: generation),
            onClose: onClose,
            currentContextProvider: {
                guard coordinator.isCurrentSearchGeneration(generation) else { return capturedContext }
                return coordinator.currentLibraryLogContext
            },
            creationContextProvider: foodCreationContextProvider()
        )
    }

    /// Keep context live within the originating session, but never construct a
    /// newer account's creation context from a retained old root callback.
    private func foodCreationContextProvider() -> () -> FoodCreationContext {
        let captured = foodCreationContext()
        return {
            guard coordinator.isCurrentSearchGeneration(captured.sessionGeneration) else { return captured }
            return foodCreationContext()
        }
    }

    private func foodCreationContext() -> FoodCreationContext {
        let generation = coordinator.session.sessionGeneration
        return FoodCreationContext(
            libraryService: coordinator.currentLibraryService,
            assistantService: coordinator.currentAssistantService,
            submissionService: HandlerLibraryLogSubmissionService(
                handler: coordinator.featureSubmissionHandler(expectedGeneration: generation)
            ),
            accountID: coordinator.currentUser?.id ?? "",
            today: coordinator.todayProvider(),
            logContext: coordinator.currentLibraryLogContext,
            sessionGeneration: generation,
            onLogged: coordinator.featureLoggedHandler(expectedGeneration: generation),
            onSessionExpired: coordinator.featureSessionExpiredHandler(expectedGeneration: generation)
        )
    }

    /// Captured-context overload for TCA-owned barcode creation. Returns nil
    /// when the captured generation is no longer current/ready, so a stale
    /// payload cannot render against the wrong account or services.
    private func capturedFoodCreationContext(
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        generation: UInt64
    ) -> FoodCreationContext? {
        guard coordinator.isCurrentSearchGeneration(generation),
              let accountID = coordinator.currentUser?.id else { return nil }
        return FoodCreationContext(
            libraryService: coordinator.currentLibraryService,
            assistantService: coordinator.currentAssistantService,
            submissionService: HandlerLibraryLogSubmissionService(
                handler: coordinator.featureSubmissionHandler(expectedGeneration: generation)
            ),
            accountID: accountID,
            today: coordinator.todayProvider(),
            logContext: LibraryLogContext(date: date, mealSlot: mealSlot),
            sessionGeneration: generation,
            onLogged: coordinator.featureLoggedHandler(expectedGeneration: generation),
            onSessionExpired: coordinator.featureSessionExpiredHandler(expectedGeneration: generation)
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
                    coordinator?.accountSettingsViewModel?.clearSensitiveStateOnDismissal()
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
                ).navigationPath.filter { NativePresentation.loggingFoodID(in: $0) == nil }
            },
            set: { newPath in
                let currentPath = AppShellPanePlan.plan(
                    for: coordinator.navigationState,
                    layout: .compact
                ).navigationPath.filter { NativePresentation.loggingFoodID(in: $0) == nil }
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
            if coordinator.selectedTab == .settings {
                settingsTab
            } else if coordinator.expandedLibrarySelected {
                libraryRoot(onClose: nil)
                    .id("library-\(coordinator.currentUser?.id ?? "none")")
            } else {
                NavigationStack {
                    paneView(plan.primaryPane)
                        .navigationDestination(isPresented: nutritionPagePresented) { nutritionPage }
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

    private func sidebarLabel(for section: AppShellTab) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .accessibilityIdentifier("app.sidebar.\(section)")
    }

    private var sidebarSelection: Binding<AppShellTab?> {
        Binding(
            get: { coordinator.selectedSidebarDestination },
            set: { section in
                guard let section else { return }
                coordinator.selectSidebarDestination(section)
            }
        )
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: {
                coordinator.selectedTab != .settings
                    && !coordinator.expandedLibrarySelected
                    && loggingFoodID == nil
                    && coordinator.navigationState.activePane.contextualFoodPane != nil
            },
            set: { isPresented in
                guard !isPresented,
                      coordinator.selectedTab != .settings,
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
            if let diaryBridge {
                // QA-only native host. The scoped store comes from the persistent
                // Window state; the legacy view model is not constructed or
                // driven on this path, and the same host serves compact/expanded.
                DiaryScreenView(
                    store: diaryBridge.store,
                    onOpenSettings: diaryBridge.onOpenSettings,
                    onOpenNutrition: diaryBridge.onOpenNutrition,
                    todayProvider: { coordinator.todayProvider() }
                )
            } else if let vm = coordinator.diaryViewModel {
                DiaryView(
                    viewModel: vm,
                    onOpenSettings: {
                        coordinator.showSettings()
                        coordinator.requestTabSwitch(to: .settings)
                    },
                    onOpenNutrition: {
                        coordinator.showNutritionDetails(onOpen: nutritionBridge?.onOpen)
                    },
                    onOpenMeals: {
                        if compactStyle {
                            coordinator.requestTabSwitch(to: .library)
                        } else {
                            coordinator.selectExpandedLibrary()
                        }
                    },
                    onOpenLibrary: {
                        if compactStyle {
                            coordinator.requestTabSwitch(to: .library)
                        } else {
                            coordinator.selectExpandedLibrary()
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

private struct SearchFoodCreationHostView: View {
    let presentation: SearchFoodCreationPresentation
    let context: FoodCreationContext?
    let onFinished: () -> Void

    @State private var request: FoodCreationRequest

    init(
        presentation: SearchFoodCreationPresentation,
        context: FoodCreationContext?,
        onFinished: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.context = context
        self.onFinished = onFinished
        _request = State(initialValue: FoodCreationRequest(entry: .barcode(presentation.barcode)))
    }

    var body: some View {
        if let context {
            FoodCreationFlowView(
                request: request,
                context: context,
                onFinished: onFinished
            )
        } else {
            ProgressView()
                .accessibilityIdentifier("search.foodCreation.waiting")
        }
    }
}

// MARK: - Aliases

public typealias AppShellModel = AppShellCoordinator
public typealias AppShellViewModel = AppShellCoordinator
