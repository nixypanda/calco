import ComposableArchitecture
import Foundation

/// Pure TCA-owned presentation payload for search-originated custom food
/// creation. It captures the exact search context so stale dismissals/completions
/// cannot clear or overwrite a newer presentation.
public struct SearchFoodCreationPresentation: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let barcode: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let generation: UInt64
    public let origin: SearchScreenFeature.NavigationOrigin

    public init(
        id: UUID,
        barcode: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        generation: UInt64,
        origin: SearchScreenFeature.NavigationOrigin
    ) {
        self.id = id
        self.barcode = barcode
        self.date = date
        self.mealSlot = mealSlot
        self.generation = generation
        self.origin = origin
    }
}

/// Window owns signed-in destination state for migrated screens.
///
/// The window owns nutrition and search destinations, their selected/today
/// context, and a single TCA-owned custom-food-creation presentation. It does
/// not own services, closures, or legacy shell routing.
@Reducer
public struct WindowFeature {
    @ObservableState
    public struct State: Equatable {
        public let sessionGeneration: UInt64
        /// Account identity for the current session; captured into every typed
        /// navigation payload and re-checked before acting on a delegate.
        public var sessionAccountID: String
        public var today: LocalDiaryDate
        public var nutrition: NutritionDetailsFeature.State?
        public var search: SearchScreenFeature.State
        public var diary: DiaryScreenFeature.State
        public var searchFoodCreation: SearchFoodCreationPresentation?

        /// Whole-port typed navigation authority. Legacy routing/shell ownership
        /// is retired once every feature is composed from this state.
        public var selectedTab: WindowTab
        public var destinationStack: [WindowDestination]
        public var libraryHubPath: [LibraryHubDestination] = []
        public var presentation: WindowPresentation?

        /// Composed child reducer state. Every screen is scoped from this one
        /// window store; no feature creates its own Store/vm wrapper.
        public var foodDetail: FoodDetailFeature.State?
        public var logEditor: LogEditorFeature.State?
        public var library: LibraryFeature.State?
        public var meals: MealsFlowFeature.State?
        public var settings: SettingsFeature.State?
        public var accountSettings: AccountSettingsFeature.State?
        public var foodCreation: FoodCreationFeature.State?
        public var barcode: BarcodeFeature.State?
        public var assistant: AssistantFeature.State?

        /// Global frozen-journal recovery banner state (migrated from the
        /// retired shell). Derived from the shared journal; no new cache.
        public var pendingSubmissions: [PendingLogSubmission] = []
        public var dismissedSubmissionUpdatedAt: [String: Date] = [:]
        public var pendingBannerDiscard: PendingLogSubmission?
        public var pendingSubmission: PendingLogSubmission? { pendingSubmissions.first }

        /// A dirty/busy log editor defers navigation until the user confirms.
        public var pendingEditorDiscard: WindowNavigationIntent?

        public enum WindowNavigationIntent: Equatable, Sendable {
            case tab(WindowTab)
            case popDestination
            case path(WindowPathChange)
            case dismissPresentation(UUID)
            case openLogEditor(id: String, context: WindowCaptureContext)
        }

        public init(
            sessionGeneration: UInt64,
            today: LocalDiaryDate,
            sessionAccountID: String = "",
            nutrition: NutritionDetailsFeature.State? = nil,
            search: SearchScreenFeature.State? = nil,
            diary: DiaryScreenFeature.State? = nil,
            searchFoodCreation: SearchFoodCreationPresentation? = nil,
            selectedTab: WindowTab = .diary,
            destinationStack: [WindowDestination] = [],
            presentation: WindowPresentation? = nil,
            foodDetail: FoodDetailFeature.State? = nil,
            logEditor: LogEditorFeature.State? = nil,
            library: LibraryFeature.State? = nil,
            meals: MealsFlowFeature.State? = nil,
            settings: SettingsFeature.State? = nil,
            accountSettings: AccountSettingsFeature.State? = nil,
            foodCreation: FoodCreationFeature.State? = nil,
            barcode: BarcodeFeature.State? = nil,
            assistant: AssistantFeature.State? = nil
        ) {
            self.sessionGeneration = sessionGeneration
            self.sessionAccountID = sessionAccountID
            self.today = today
            self.nutrition = nutrition
            self.search = search ?? SearchScreenFeature.State(
                date: today,
                mealSlot: nil,
                generation: sessionGeneration
            )
            self.diary = diary ?? DiaryScreenFeature.State(
                date: today,
                today: today,
                sessionGeneration: sessionGeneration
            )
            self.searchFoodCreation = searchFoodCreation
            self.selectedTab = selectedTab
            self.destinationStack = destinationStack
            self.presentation = presentation
            self.foodDetail = foodDetail
            self.logEditor = logEditor
            self.library = library
            self.meals = meals
            self.settings = settings
            self.accountSettings = accountSettings
            self.foodCreation = foodCreation
            self.barcode = barcode
            self.assistant = assistant
        }
    }

    // Not Equatable: SearchScreenFeature.Action is not Equatable, and a hand-written
    // `==` cannot represent it without breaking reflexivity. Tests assert receives
    // through case paths with Equatable delegate payloads, or through predicates.
    public enum Action: Sendable {
        case nutrition(NutritionDetailsFeature.Action)
        case search(SearchScreenFeature.Action)
        case diary(DiaryScreenFeature.Action)
        case openNutrition(selectedDate: LocalDiaryDate, today: LocalDiaryDate)
        case closeNutrition
        case todayChanged(LocalDiaryDate)
        /// Typed replacement for the coordinator's `contextChanged` handler:
        /// selected date/slot context flows into Search with a generation guard.
        case syncSearchContext(date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64)
        /// Typed replacements for the coordinator's settings writeback callbacks:
        /// authority-server values are applied once, store-only, no Diary GET.
        case applySavedGoalWriteback(
            generation: UInt64,
            targets: DiaryGoalTargets,
            effectiveDate: LocalDiaryDate
        )
        case applySavedPreferencesWriteback(generation: UInt64, prefs: DiaryPrefs)

        // Whole-port typed navigation actions.
        case selectTab(WindowTab)
        case pushDestination(WindowDestination)
        case popDestination
        case popDestinationToRoot
        case present(WindowPresentation)
        case dismissPresentation(expectedPresentationID: UUID)

        // Composed child reducers (one window store, no per-feature Store).
        case foodDetail(FoodDetailFeature.Action)
        case logEditor(LogEditorFeature.Action)
        case library(LibraryFeature.Action)
        case meals(MealsFlowFeature.Action)
        case settings(SettingsFeature.Action)
        case accountSettings(AccountSettingsFeature.Action)
        case foodCreation(FoodCreationFeature.Action)
        case barcode(BarcodeFeature.Action)
        case assistant(AssistantFeature.Action)

        /// The single authoritative Diary fanout, built once from a typed
        /// delegate's existing server rows/drafts and captured context.
        case applyAuthoritativeMutation(DiaryMutationDelivery)

        /// Creates the Library hub's foods + recipes-only meals children from
        /// this window store. No separate Store or view model is made.
        case ensureLibraryChildren

        // Global recovery + navigation guard (typed, parent-owned).
        case refreshPendingSubmissions(accountID: String)
        case dismissPendingBanner
        case requestDiscardPending(PendingLogSubmission)
        case confirmDiscardPending
        case cancelDiscardPending
        case reviewPendingSubmission(PendingLogSubmission)
        case requestSelectTab(WindowTab)
        case requestPopDestination
        case requestPathChange(WindowPathChange)
        case applyPathChange(WindowPathChange)
        case openLibraryHub(LibraryHubDestination)
        case requestDismissPresentation(UUID)
        case confirmEditorDiscard
        case cancelEditorDiscard

        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(selectedDate: LocalDiaryDate, generation: UInt64, reason: SessionUnavailableReason)
        case addFood(slot: MealSlot, date: LocalDiaryDate, generation: UInt64)
        case selectedFood(
            id: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            generation: UInt64,
            origin: SearchScreenFeature.NavigationOrigin
        )
        case selectedMeal(
            id: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            quantity: NutritionQuantity,
            generation: UInt64,
            origin: SearchScreenFeature.NavigationOrigin
        )
        case openMeals(date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64)
        case openLogEditor(id: String, date: LocalDiaryDate, generation: UInt64)
    }

    @Dependency(\.uuid) var uuid
    @Dependency(\.logSubmissionStore) var logSubmissionStore

    /// Runs the account child's cleanup synchronously BEFORE the parent removes
    /// it, so an owned clipboard receipt cannot outlive the child. The effect
    /// carries its own captured receipt and is not cancelled by child removal.
    private static func clearAccountSettingsClipboard(_ state: inout State) -> Effect<Action> {
        guard var child = state.accountSettings else { return .none }
        let effect = AccountSettingsFeature().reduce(into: &child, action: .clearOnDismiss)
        return effect.map(Action.accountSettings)
    }

    /// The single owner of the Search *entry* context. Every production route
    /// into the shared Search screen (the `.logFood` presentation from a Diary
    /// Add Food, a `.selectTab(.search)` entry, and the typed
    /// `syncSearchContext` replacement for the retired coordinator handler)
    /// funnels through here, so the logging date/slot always come from one
    /// immutable captured context rather than a stale global root-date copy.
    ///
    /// The capture is bound only once per Search entry: a stale generation or
    /// a still-submitting quick-add child is never silently rebound to a newer
    /// Diary date mid-write. Presented food/meal/log-editor children keep their
    /// own immutable `WindowCaptureContext` and are untouched by this binding.
    private static func bindSearchEntryContext(
        _ state: inout State,
        date: LocalDiaryDate,
        slot: MealSlot?,
        generation: UInt64
    ) {
        guard generation == state.sessionGeneration,
              !state.search.quickAdd.isBusy else { return }
        state.search.catalog.originDate = date
        state.search.catalog.originMealSlot = slot
        state.search.history.contextDate = date
        state.search.history.contextMealSlot = slot
        state.search.quickAdd.originDate = date
        state.search.quickAdd.originMealSlot = slot
    }

    // Large switch extracted for tractable type-checking; semantics unchanged.
    private func reduceCore(_ state: inout State, action: Action) -> Effect<Action> {
            switch action {
            case let .openNutrition(selectedDate, today):
                state.today = today
                let requestedDate = min(selectedDate, today)

                // Reopening the same date preserves an in-flight or loaded
                // report, including expanded guidance. A different date creates a
                // distinct destination and request identity.
                if let existing = state.nutrition,
                   existing.selectedDate == requestedDate,
                   existing.today == today {
                    return .none
                }

                state.nutrition = NutritionDetailsFeature.State(
                    date: selectedDate,
                    today: today,
                    sessionGeneration: state.sessionGeneration
                )
                return .none

            case .closeNutrition:
                state.nutrition = nil
                return .none

            case let .todayChanged(today):
                state.today = today
                // Root day-change authority owns the single Diary foreground/
                // rollover read. Nutrition receives the derived day change.
                let nutritionEffect: Effect<Action> = state.nutrition != nil
                    ? .send(.nutrition(.todayChanged(today)))
                    : .none
                return .merge(
                    nutritionEffect,
                    .send(.diary(.diary(.foregroundRefresh(newToday: today))))
                )

            case let .nutrition(.delegate(.sessionExpired(selectedDate, generation))):
                // A stale child cannot invalidate a newer session.
                guard generation == state.sessionGeneration else { return .none }
                state.nutrition = nil
                return .send(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .search(.delegate(.selectedFood(id, date, mealSlot, generation, origin))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.selectedFood(
                    id: id,
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation,
                    origin: origin
                )))

            case let .search(.delegate(.selectedMeal(id, date, mealSlot, quantity, generation, origin))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.selectedMeal(
                    id: id,
                    date: date,
                    mealSlot: mealSlot,
                    quantity: quantity,
                    generation: generation,
                    origin: origin
                )))

            case let .search(.delegate(.createCustomFoodDraft(barcode, date, mealSlot, generation, origin))):
                guard generation == state.sessionGeneration else { return .none }
                // Duplicate open must not overwrite or discard an existing
                // presentation silently.
                guard state.searchFoodCreation == nil, state.presentation == nil else { return .none }
                let presentationID = uuid()
                state.searchFoodCreation = SearchFoodCreationPresentation(
                    id: presentationID,
                    barcode: barcode,
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation,
                    origin: origin
                )
                state.foodCreation = FoodCreationFeature.State(
                    entry: .assistant(purpose: .customFood, barcode: barcode),
                    accountID: state.sessionAccountID,
                    generation: generation,
                    today: state.today,
                    logContext: LibraryLogContext(date: date, mealSlot: mealSlot),
                    presentationID: presentationID
                )
                state.presentation = .foodCreation(context: WindowCaptureContext(
                    date: date,
                    slot: mealSlot,
                    accountID: state.sessionAccountID,
                    generation: generation,
                    origin: .search,
                    presentationID: presentationID
                ))
                return .none

            case let .search(.delegate(.sessionExpired(generation))):
                guard generation == state.sessionGeneration else { return .none }
                let selectedDate = state.search.originDate
                state.searchFoodCreation = nil
                return .send(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .diary(.delegate(.sessionExpired(selectedDate, generation))):
                // DiaryScreenFeature already latches and expires its own children;
                // Window only forwards the single session-expired delegate.
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .diary(.delegate(.addFood(slot, date, generation))):
                // Add Food is the one diary delegate Window routes onward. The
                // child already checks generation/session, but Window repeats the
                // authority check so a stale or expired child can never navigate.
                guard generation == state.sessionGeneration else { return .none }
                guard !state.diary.diary.isSessionExpired else { return .none }
                return .send(.delegate(.addFood(
                    slot: slot,
                    date: date,
                    generation: generation
                )))

            case let .diary(.delegate(.mutationNoticeReady(generation, date, notice))):
                // Emitted by Diary only after the authoritative read settled.
                // Re-check both authorities here before projecting the notice.
                guard generation == state.sessionGeneration,
                      state.diary.diary.selectedDate == date,
                      !state.diary.diary.isSessionExpired else { return .none }
                return .send(.diary(.diary(.showMutationNotice(
                    generation: generation,
                    date: date,
                    notice: notice
                ))))

            case let .diary(.delegate(.openLogEditor(id, date, generation))):
                // The editor destination is still owned by the legacy shell.
                // Window only forwards it after repeating the same authority
                // checks Add Food uses, so a stale/expired child can never
                // navigate a newer session into an editor.
                guard generation == state.sessionGeneration else { return .none }
                guard !state.diary.diary.isSessionExpired else { return .none }
                return .send(.delegate(.openLogEditor(
                    id: id,
                    date: date,
                    generation: generation
                )))

            case .diary(.delegate(.openMeals(_, _))),
                 .diary(.delegate(.copied(_, _, _, _, _))):
                // Deferred destinations/copy remain owned by the legacy shell;
                // Window does not refresh on them (no duplicate GET).
                return .none

            case let .search(.delegate(.diaryChanged(_, generation))):
                // Diary refresh is owned by the handler that already performed the
                // mutation; forwarding or refreshing here would double work.
                guard generation == state.sessionGeneration else { return .none }
                return .none

            case let .syncSearchContext(date, mealSlot, generation):
                Self.bindSearchEntryContext(
                    &state,
                    date: date,
                    slot: mealSlot,
                    generation: generation
                )
                return .none

            case let .applySavedGoalWriteback(generation, targets, effectiveDate):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.diary(.diary(.applySavedGoal(
                    generation: generation,
                    targets: targets,
                    effectiveDate: effectiveDate
                ))))

            case let .applySavedPreferencesWriteback(generation, prefs):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.diary(.diary(.applySavedPreferences(
                    generation: generation,
                    prefs: prefs
                ))))

            case let .selectTab(tab):
                guard tab != state.selectedTab else { return .none }
                let clear = Self.clearAccountSettingsClipboard(&state)
                state.selectedTab = tab
                state.destinationStack = []
                state.presentation = nil
                state.barcode = nil
                state.assistant = nil
                state.foodCreation = nil
                if tab == .account, state.settings == nil {
                    state.settings = SettingsFeature.State(
                        accountID: state.sessionAccountID,
                        today: state.today,
                        timeZone: .current,
                        sessionGeneration: state.sessionGeneration,
                        id: uuid(),
                        locale: .current
                    )
                }
                if tab == .search {
                    // A newly entered Search tab logs into the currently
                    // selected Diary day, not the global `today`. Capture the
                    // value before the inout binding call (exclusivity).
                    let selectedDate = state.diary.diary.selectedDate
                    let generation = state.sessionGeneration
                    Self.bindSearchEntryContext(
                        &state,
                        date: selectedDate,
                        slot: nil,
                        generation: generation
                    )
                }
                return clear

            case let .pushDestination(destination):
                // A stale or wrong-account destination can never navigate a
                // newer session. Request identity dedup prevents double push.
                guard destination.generation == state.sessionGeneration else { return .none }
                if !state.sessionAccountID.isEmpty, let accountID = destination.accountID {
                    guard accountID == state.sessionAccountID else { return .none }
                }
                guard !state.destinationStack.contains(where: { $0.id == destination.id }) else {
                    return .none
                }
                // A live editor must never be replaced by a new-row open.
                // Same-row retap retains its edits; busy is ignored; dirty
                // defers the exact intent until the user confirms discard.
                if case let .logEditor(id, context) = destination,
                   let active = state.logEditor {
                    if active.logID == id || active.presentationID == context.presentationID {
                        return .none
                    }
                    if active.isBusy { return .none }
                    if active.hasUnsavedChanges {
                        state.pendingEditorDiscard = .openLogEditor(id: id, context: context)
                        return .none
                    }
                }
                // Compose the child reducer state from the same typed payload;
                // there is exactly one Store for the whole window.
                switch destination {
                case let .foodDetail(id, context):
                    state.foodDetail = FoodDetailFeature.State(
                        foodID: id,
                        date: context.date,
                        slot: context.slot,
                        generation: context.generation,
                        accountID: context.accountID,
                        presentationID: context.presentationID
                    )
                case let .meals(context):
                    state.meals = MealsFlowFeature.State(
                        context: MealsCaptureContext(
                            id: context.presentationID,
                            date: context.date,
                            mealSlot: context.slot,
                            accountID: context.accountID,
                            generation: context.generation,
                            origin: .sheet
                        )
                    )
                case let .search(context):
                    Self.bindSearchEntryContext(
                        &state,
                        date: context.date,
                        slot: context.slot,
                        generation: context.generation
                    )
                case .library:
                    // The Library hub creates and retains its scoped child on
                    // appearance; a typed destination must not mint a second one.
                    break
                case let .settings(context):
                    state.settings = SettingsFeature.State(
                        accountID: context.accountID,
                        today: state.today,
                        timeZone: .current,
                        sessionGeneration: context.generation,
                        id: context.presentationID,
                        locale: .current
                    )
                case let .accountSettings(accountID, generation, _, _):
                    state.accountSettings = AccountSettingsFeature.State(
                        accountID: accountID,
                        generation: generation
                    )
                case let .mealDetail(id, context):
                    state.meals = MealsFlowFeature.State(
                        context: MealsCaptureContext(
                            id: context.presentationID,
                            date: context.date,
                            mealSlot: context.slot,
                            accountID: context.accountID,
                            generation: context.generation,
                            origin: .sheet
                        ),
                        initialMealID: id
                    )
                case let .logEditor(id, context):
                    if let day = state.diary.diary.visibleDay,
                       let log = day.logs.first(where: { $0.id == id }) {
                        state.logEditor = LogEditorFeature.State(
                            log: log,
                            date: context.date,
                            accountID: context.accountID,
                            sessionGeneration: context.generation,
                            presentationID: context.presentationID
                        )
                    }
                case .mealEditor, .nutrition:
                    // Editor children are created when their authoritative row
                    // is available; meal editor lives in the MealsFlow stack.
                    break
                }
                state.destinationStack.append(destination)
                return .none

            case .popDestination:
                guard !state.destinationStack.isEmpty else { return .none }
                state.destinationStack.removeLast()
                return .none

            case .popDestinationToRoot:
                state.destinationStack = []
                return .none

            case let .openLibraryHub(destination):
                guard state.selectedTab == .library, state.destinationStack.isEmpty,
                      state.libraryHubPath.isEmpty else { return .none }
                state.libraryHubPath = [destination]
                return .none

            case let .requestPathChange(change):
                guard Self.isValidPathChange(change, in: state) else { return .none }
                if let editor = state.logEditor {
                    if editor.isBusy { return .none }
                    if editor.hasUnsavedChanges {
                        if state.pendingEditorDiscard == nil { state.pendingEditorDiscard = .path(change) }
                        return .none
                    }
                }
                return .send(.applyPathChange(change))

            case let .applyPathChange(change):
                guard Self.isValidPathChange(change, in: state) else { return .none }
                let removed = state.destinationStack.dropFirst(change.desired.count)
                var clear: Effect<Action> = .none
                for destination in removed.reversed() {
                    switch destination {
                    case .accountSettings:
                        clear = Self.clearAccountSettingsClipboard(&state)
                        state.accountSettings = nil
                    case .logEditor: state.logEditor = nil
                    case .foodDetail: state.foodDetail = nil
                    case .nutrition: state.nutrition = nil
                    case .meals, .mealDetail, .mealEditor:
                        if !change.desiredHub.contains(.meals) { state.meals = nil }
                    default: break
                    }
                }
                state.destinationStack = change.desired
                if change.tab == .library { state.libraryHubPath = change.desiredHub }
                return clear

            case let .present(presentation):
                guard presentation.context.generation == state.sessionGeneration else { return .none }
                if !state.sessionAccountID.isEmpty {
                    guard presentation.context.accountID == state.sessionAccountID else { return .none }
                }
                let context = presentation.context
                switch presentation {
                case .foodCreation:
                    state.foodCreation = FoodCreationFeature.State(
                        entry: .assistant(purpose: .customFood, barcode: nil),
                        accountID: context.accountID,
                        generation: context.generation,
                        today: state.today,
                        logContext: LibraryLogContext(
                            date: context.date,
                            mealSlot: context.slot
                        ),
                        presentationID: context.presentationID
                    )
                case .barcode:
                    state.barcode = BarcodeFeature.State(
                        sessionGeneration: context.generation
                    )
                case .assistant:
                    state.assistant = AssistantFeature.State(
                        purpose: .customFood,
                        sessionGeneration: context.generation
                    )
                case let .settings(context):
                    guard state.settings == nil else { return .none }
                    state.settings = SettingsFeature.State(
                        accountID: state.sessionAccountID,
                        today: state.today,
                        timeZone: .current,
                        sessionGeneration: state.sessionGeneration,
                        id: context.presentationID,
                        locale: .current
                    )
                case .logFood:
                    // The presented Search screen is scoped from `state.search`.
                    // Bind its entry context from the immutable captured
                    // presentation payload so Add Food on a historical Diary
                    // day logs into that day (old-UX parity), not Today.
                    Self.bindSearchEntryContext(
                        &state,
                        date: context.date,
                        slot: context.slot,
                        generation: context.generation
                    )
                case .quickAdd:
                    break
                }
                state.presentation = presentation
                return .none

            case let .dismissPresentation(expectedPresentationID):
                guard state.presentation?.id == expectedPresentationID else { return .none }
                switch state.presentation {
                case .foodCreation: state.foodCreation = nil
                case .barcode: state.barcode = nil
                case .assistant: state.assistant = nil
                case .settings: state.settings = nil
                default: break
                }
                state.presentation = nil
                return .none

            // MARK: Composed child delegates — one authoritative fanout owner.

            case let .foodDetail(.delegate(.logged(date, _, generation, _))):
                // The frozen journal carries its own authoritative record but no
                // full server row; keep captured-date-only invalidation.
                guard generation == state.sessionGeneration else { return .none }
                return .send(.applyAuthoritativeMutation(
                    DiaryMutationDelivery(generation: generation, invalidating: date)
                ))

            case let .foodDetail(.delegate(.checkDiary(date, generation))):
                guard generation == state.sessionGeneration,
                      state.diary.diary.selectedDate == date else { return .none }
                return .send(.diary(.diary(.refresh)))

            case let .foodDetail(.delegate(.sessionExpired(generation))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.sessionExpired(
                    selectedDate: state.search.originDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .foodDetail(.delegate(.dismiss(generation))):
                guard generation == state.sessionGeneration else { return .none }
                state.foodDetail = nil
                state.destinationStack.removeAll {
                    if case .foodDetail = $0 { return true }
                    return false
                }
                return .none

            case let .logEditor(.delegate(.saved(presentationID, logID, date, log, notice, generation))):
                guard generation == state.sessionGeneration else { return .none }
                state.logEditor = nil
                state.destinationStack.removeAll { $0.id == presentationID }
                return .send(.applyAuthoritativeMutation(
                    DiaryMutationDelivery(
                        generation: generation,
                        editor: .saved(
                            originalID: logID,
                            date: date,
                            log: log,
                            notice: notice
                        )
                    )
                ))

            case let .logEditor(.delegate(.deleted(presentationID, logID, date, notice, generation))):
                guard generation == state.sessionGeneration else { return .none }
                state.logEditor = nil
                state.destinationStack.removeAll { $0.id == presentationID }
                return .send(.applyAuthoritativeMutation(
                    DiaryMutationDelivery(
                        generation: generation,
                        editor: .deleted(id: logID, date: date, notice: notice)
                    )
                ))

            case let .logEditor(.delegate(.sessionExpired(generation))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.sessionExpired(
                    selectedDate: state.diary.diary.selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .settings(.delegate(.goalSaved(_, generation, targets, effectiveDate))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.applySavedGoalWriteback(
                    generation: generation,
                    targets: targets,
                    effectiveDate: effectiveDate
                ))

            case let .settings(.delegate(.preferencesSaved(_, generation, prefs))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.applySavedPreferencesWriteback(generation: generation, prefs: prefs))

            case let .settings(.delegate(.sessionExpired(_, generation))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.sessionExpired(
                    selectedDate: state.diary.diary.selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .settings(.delegate(.openAccountSettings(settingsID))):
                let generation = state.sessionGeneration
                let presentationID = uuid()
                state.accountSettings = AccountSettingsFeature.State(
                    accountID: state.sessionAccountID,
                    generation: generation
                )
                state.destinationStack.append(.accountSettings(
                    accountID: state.sessionAccountID,
                    generation: generation,
                    settingsID: settingsID,
                    presentationID: presentationID
                ))
                return .none

            case let .settings(.delegate(.dismiss(settingsID))),
                 let .settings(.delegate(.accountSettingsDismissed(settingsID))):
                state.settings = nil
                let clear = Self.clearAccountSettingsClipboard(&state)
                state.accountSettings = nil
                state.presentation = nil
                state.destinationStack.removeAll {
                    if case .accountSettings(_, _, let id, _) = $0, id == settingsID { return true }
                    return false
                }
                return clear

            case let .meals(.delegate(.logged(payload))):
                guard payload.generation == state.sessionGeneration,
                      payload.accountID == state.sessionAccountID else { return .none }
                return .send(.applyAuthoritativeMutation(
                    DiaryMutationDelivery(
                        generation: payload.generation,
                        drafts: payload.drafts,
                        logs: payload.logs
                    )
                ))

            case let .meals(.delegate(.sessionExpired(generation, _))),
                 let .meals(.delegate(.close(generation, _))),
                 let .meals(.delegate(.back(generation, _))):
                guard generation == state.sessionGeneration else { return .none }
                state.meals = nil
                state.destinationStack.removeAll {
                    if case .meals = $0 { return true }
                    return false
                }
                state.presentation = nil
                return .none

            case let .library(.delegate(.sessionExpired(generation))),
                 let .library(.delegate(.dismiss(generation))):
                guard generation == state.sessionGeneration else { return .none }
                state.library = nil
                state.presentation = nil
                return .none

            case let .accountSettings(.delegate(.sessionExpired(generation))),
                 let .accountSettings(.delegate(.dismiss(generation))):
                guard generation == state.sessionGeneration else { return .none }
                let clear = Self.clearAccountSettingsClipboard(&state)
                state.accountSettings = nil
                state.destinationStack.removeAll {
                    if case .accountSettings = $0 { return true }
                    return false
                }
                return clear

            case let .applyAuthoritativeMutation(delivery):
                guard let plan = DiaryMutationFanoutPlan.make(
                    delivery: delivery,
                    visibleDate: state.diary.diary.selectedDate,
                    sessionGeneration: state.sessionGeneration
                ) else { return .none }
                var effects: [Effect<Action>] = plan.actions.map { .send($0) }
                if plan.invalidatesLatestSuggestions {
                    effects.insert(
                        .send(.diary(.latest(.invalidateCachedSuggestions(
                            generation: delivery.generation
                        )))),
                        at: 0
                    )
                }
                return .concatenate(effects)

            case let .foodCreation(.delegate(.finished(generation, presentationID))):
                guard generation == state.sessionGeneration else { return .none }
                state.foodCreation = nil
                state.presentation = nil
                state.destinationStack.removeAll { $0.id == presentationID }
                return .none

            case let .foodCreation(.delegate(.logged(event))):
                guard event.generation == state.sessionGeneration,
                      event.accountID == state.sessionAccountID else { return .none }
                return .send(.applyAuthoritativeMutation(
                    DiaryMutationDelivery(
                        generation: event.generation,
                        drafts: event.drafts,
                        logs: event.logs
                    )
                ))

            case let .foodCreation(.delegate(.sessionExpired(generation))),
                 let .barcode(.delegate(.sessionExpired(_, generation))),
                 let .assistant(.delegate(.sessionExpired(generation))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.sessionExpired(
                    selectedDate: state.search.originDate,
                    generation: generation,
                    reason: .expired
                )))

            case .barcode(.delegate(.selectedProduct)),
                 .barcode(.delegate(.createCustomFoodDraft)),
                 .assistant(.delegate(.acceptedReviewedDraft)):
                // Consumed by the composing FoodCreationFeature, not a separate
                // Window route; no new write or presentation is created here.
                return .none

            case let .refreshPendingSubmissions(accountID):
                // UI preference only: dismissed entries remain in the frozen
                // journal and inline recovery. No new writer or cache.
                let journal = logSubmissionStore
                let attention = MainActor.assumeIsolated {
                    journal.attentionEntries(accountID: accountID)
                }
                state.pendingSubmissions = attention
                    .filter { dismissed in
                        guard let stamped = state.dismissedSubmissionUpdatedAt[dismissed.id] else {
                            return true
                        }
                        return stamped != dismissed.updatedAt
                    }
                return .none

            case .dismissPendingBanner:
                for pending in state.pendingSubmissions {
                    state.dismissedSubmissionUpdatedAt[pending.id] = pending.updatedAt
                }
                state.pendingSubmissions = []
                return .none

            case let .requestDiscardPending(pending):
                guard pending.state == .conflicted,
                      pending.accountID == state.sessionAccountID else { return .none }
                state.pendingBannerDiscard = pending
                return .none

            case .cancelDiscardPending:
                state.pendingBannerDiscard = nil
                return .none

            case .confirmDiscardPending:
                guard let pending = state.pendingBannerDiscard,
                      pending.state == .conflicted,
                      pending.accountID == state.sessionAccountID else {
                    state.pendingBannerDiscard = nil
                    return .none
                }
                state.pendingBannerDiscard = nil
                let journal = logSubmissionStore
                MainActor.assumeIsolated {
                    try? journal.remove(id: pending.id, accountID: pending.accountID)
                }
                state.dismissedSubmissionUpdatedAt.removeValue(forKey: pending.id)
                return .send(.refreshPendingSubmissions(accountID: pending.accountID))

            case let .reviewPendingSubmission(pending):
                guard pending.accountID == state.sessionAccountID else { return .none }
                let context = WindowCaptureContext(
                    date: pending.draft.date,
                    slot: pending.draft.mealSlot,
                    accountID: pending.accountID,
                    generation: state.sessionGeneration,
                    origin: .diary,
                    presentationID: uuid()
                )
                return .send(.pushDestination(.foodDetail(id: pending.draft.foodID, context: context)))

            case let .requestSelectTab(tab):
                if let editor = state.logEditor {
                    if editor.isBusy { return .none }
                    if editor.hasUnsavedChanges {
                        state.pendingEditorDiscard = .tab(tab)
                        return .none
                    }
                }
                return .send(.selectTab(tab))

            case .requestPopDestination:
                if let editor = state.logEditor {
                    if editor.isBusy { return .none }
                    if editor.hasUnsavedChanges {
                        state.pendingEditorDiscard = .popDestination
                        return .none
                    }
                }
                return .send(.popDestination)

            case let .requestDismissPresentation(id):
                if let editor = state.logEditor {
                    if editor.isBusy { return .none }
                    if editor.hasUnsavedChanges {
                        state.pendingEditorDiscard = .dismissPresentation(id)
                        return .none
                    }
                }
                return .send(.dismissPresentation(expectedPresentationID: id))

            case .confirmEditorDiscard:
                guard let intent = state.pendingEditorDiscard else { return .none }
                guard state.logEditor?.isBusy != true else { return .none }
                if case let .path(change) = intent {
                    state.pendingEditorDiscard = nil
                    guard Self.isValidPathChange(change, in: state) else { return .none }
                    return .send(.applyPathChange(change))
                }
                state.pendingEditorDiscard = nil
                state.logEditor = nil
                switch intent {
                case let .tab(tab): return .send(.selectTab(tab))
                case .popDestination: return .send(.popDestinationToRoot)
                case .path: return .none
                case let .dismissPresentation(id):
                    return .send(.dismissPresentation(expectedPresentationID: id))
                case let .openLogEditor(id, context):
                    return .send(.pushDestination(.logEditor(id: id, context: context)))
                }

            case .cancelEditorDiscard:
                state.pendingEditorDiscard = nil
                return .none

            case .ensureLibraryChildren:
                let generation = state.sessionGeneration
                let accountID = state.sessionAccountID
                if state.library == nil {
                    state.library = LibraryFeature.State(
                        accountID: accountID,
                        generation: generation,
                        logContext: LibraryLogContext(
                            date: state.today,
                            mealSlot: nil
                        ),
                        today: state.today
                    )
                }
                if state.meals == nil {
                    state.meals = MealsFlowFeature.State(
                        context: MealsCaptureContext(
                            id: UUID(),
                            date: state.today,
                            mealSlot: nil,
                            accountID: accountID,
                            generation: generation,
                            origin: .library
                        )
                    )
                }
                return .none

            case let .library(.delegate(.openEditor(mode, date, slot, generation, presentationID))):
                guard generation == state.sessionGeneration else { return .none }
                var foodCreation = FoodCreationFeature.State(
                    entry: .barcode(""),
                    accountID: state.sessionAccountID,
                    generation: generation,
                    today: state.today,
                    logContext: LibraryLogContext(date: date, mealSlot: slot),
                    presentationID: presentationID
                )
                foodCreation.editor = CustomFoodEditorFeature.State(
                    mode: mode,
                    accountID: state.sessionAccountID,
                    generation: generation,
                    presentationID: presentationID
                )
                state.foodCreation = foodCreation
                state.presentation = .foodCreation(context: WindowCaptureContext(
                    date: date,
                    slot: slot,
                    accountID: state.sessionAccountID,
                    generation: generation,
                    origin: .library,
                    presentationID: presentationID
                ))
                return .none

            case let .library(.delegate(.openCreation(entry, date, slot, generation, presentationID))):
                guard generation == state.sessionGeneration else { return .none }
                state.foodCreation = FoodCreationFeature.State(
                    entry: entry,
                    accountID: state.sessionAccountID,
                    generation: generation,
                    today: state.today,
                    logContext: LibraryLogContext(date: date, mealSlot: slot),
                    presentationID: presentationID
                )
                state.presentation = .foodCreation(context: WindowCaptureContext(
                    date: date,
                    slot: slot,
                    accountID: state.sessionAccountID,
                    generation: generation,
                    origin: .library,
                    presentationID: presentationID
                ))
                return .none

            case .nutrition, .search, .diary, .foodDetail, .logEditor, .library,
                 .meals, .settings, .accountSettings, .foodCreation, .barcode,
                 .assistant, .delegate:
                return .none
            }
        }

    public init() {}

    private static func isValidPathChange(_ change: WindowPathChange, in state: State) -> Bool {
        guard change.tab == state.selectedTab, change.expected == state.destinationStack,
              change.desired.count <= change.expected.count,
              Array(change.expected.prefix(change.desired.count)) == change.desired else { return false }
        if change.tab == .library {
            guard change.expectedHub == state.libraryHubPath,
                  change.desiredHub.count <= change.expectedHub.count,
                  Array(change.expectedHub.prefix(change.desiredHub.count)) == change.desiredHub,
                  change.desiredHub == change.expectedHub || change.desired.isEmpty else { return false }
        }
        return change.desired != change.expected || change.desiredHub != change.expectedHub
    }

    public var body: some Reducer<State, Action> {
        Scope(state: \.search, action: \.search) {
            SearchScreenFeature()
        }
        Scope(state: \.diary, action: \.diary) {
            DiaryScreenFeature()
        }
        Reduce<State, Action> { state, action in
            reduceCore(&state, action: action)
        }
        .ifLet(\.nutrition, action: \.nutrition) {
            NutritionDetailsFeature()
        }
        .ifLet(\.foodDetail, action: \.foodDetail) {
            FoodDetailFeature()
        }
        .ifLet(\.logEditor, action: \.logEditor) {
            LogEditorFeature()
        }
        .ifLet(\.library, action: \.library) {
            LibraryFeature()
        }
        .ifLet(\.meals, action: \.meals) {
            MealsFlowFeature()
        }
        .ifLet(\.settings, action: \.settings) {
            SettingsFeature()
        }
        .ifLet(\.accountSettings, action: \.accountSettings) {
            AccountSettingsFeature()
        }
        .ifLet(\.foodCreation, action: \.foodCreation) {
            FoodCreationFeature()
        }
        .ifLet(\.barcode, action: \.barcode) {
            BarcodeFeature()
        }
        .ifLet(\.assistant, action: \.assistant) {
            AssistantFeature()
        }
    }
}
