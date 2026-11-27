import ComposableArchitecture
import Foundation

/// Settings sheet reducer. Goal edits always target the device-local today; the
/// selected diary date is context only and is never changed here. Goal and
/// meal-slot preference loading/saving are independent sibling state machines:
/// one can be loading or failed while the other is being edited or saved.
///
/// All service seams live in `DependencyValues`. `State` holds only captured
/// context (account, generation, settings ID, today/timezone/locale), domain
/// values and request identity. Successful writes are delivered to exactly one
/// parent owner as typed, authoritative server payloads — no Diary GET, no
/// notice, no dual apply.
@Reducer
public struct SettingsFeature {
    /// Immutable session identity captured at every async boundary. Value only —
    /// never a service or authority. The wiring owner verifies current
    /// account/generation BEFORE transport; each reply is checked against the
    /// receiving store's captured context BEFORE token checks, state mutation
    /// or delegate emission.
    public struct RequestContext: Equatable, Sendable {
        public let accountID: String
        public let generation: UInt64
        public let settingsID: UUID
    }

    // MARK: - Lifecycle payloads

    public enum SettingsPhase<Value: Equatable & Sendable>: Equatable, Sendable {
        case idle
        case loading
        case loaded(Value)
        case failed(String)
    }

    public enum GoalSaveState: Equatable, Sendable {
        case idle
        case saving
        case saved
        case failed(String)
        case needsReconciliation(String, GoalReconciliation)
        case reconciling(String, GoalReconciliation)

        public var isSaving: Bool {
            switch self {
            case .saving, .reconciling: return true
            default: return false
            }
        }

        public var isReconciliation: Bool {
            switch self {
            case .needsReconciliation, .reconciling: return true
            default: return false
            }
        }

        public var errorMessage: String? {
            switch self {
            case .failed(let message),
                 .needsReconciliation(let message, _),
                 .reconciling(let message, _):
                return message
            default:
                return nil
            }
        }
    }

    public enum PreferencesSaveState: Equatable, Sendable {
        case idle
        case saving
        case saved
        case failed(String)
        case needsReconciliation(String, PreferencesReconciliation)
        case reconciling(String, PreferencesReconciliation)

        public var isSaving: Bool {
            switch self {
            case .saving, .reconciling: return true
            default: return false
            }
        }

        public var isReconciliation: Bool {
            switch self {
            case .needsReconciliation, .reconciling: return true
            default: return false
            }
        }

        public var errorMessage: String? {
            switch self {
            case .failed(let message),
                 .needsReconciliation(let message, _),
                 .reconciling(let message, _):
                return message
            default:
                return nil
            }
        }
    }

    /// Midnight crossed while the form was open: the typed draft is preserved
    /// and no PUT is allowed until the user explicitly reviews the new day.
    public enum DayReview: Equatable, Sendable {
        case none
        case required(String)
    }

    /// One-shot session boundary. A retained completion from an expired session
    /// cannot mutate state or emit a second expiry delegate.
    public enum Lifecycle: Equatable, Sendable {
        case active
        case expired
    }

    public enum Confirmation: Equatable, Sendable {
        case none
        case discardPrompt
        case discardConfirmed
    }

    public enum GoalField: String, CaseIterable, Equatable, Sendable {
        case calories
        case protein
        case carbs
        case fat
    }

    public struct GoalTexts: Equatable, Sendable {
        public var calories = ""
        public var protein = ""
        public var carbs = ""
        public var fat = ""

        public init() {}

        public subscript(field: GoalField) -> String {
            get {
                switch field {
                case .calories: return calories
                case .protein: return protein
                case .carbs: return carbs
                case .fat: return fat
                }
            }
            set {
                switch field {
                case .calories: calories = newValue
                case .protein: protein = newValue
                case .carbs: carbs = newValue
                case .fat: fat = newValue
                }
            }
        }
    }

    /// Frozen payload of an ambiguous PUT, reused verbatim by reconciliation.
    public struct GoalReconciliation: Equatable, Sendable {
        public let context: RequestContext
        public let attempted: GoalTargetsDecimal
        public let previous: GoalSnapshot
        public let requestedDate: LocalDiaryDate
    }

    public struct PreferencesReconciliation: Equatable, Sendable {
        public let context: RequestContext
        public let requested: DiaryPreferences
        public let previous: DiaryPreferences
    }

    public enum Failure: Error, Equatable, Sendable {
        case unauthorized
        /// A transport/server outcome that may or may not have applied.
        case ambiguous(String)
        /// A definitive client rejection (validation, rate limit, conflict).
        case rejected(String)
        case cancelled
        case message(String)

        public var message: String {
            switch self {
            case .unauthorized: return String(localized: "diary.error.sessionExpired")
            case .ambiguous(let message), .rejected(let message), .message(let message):
                return message
            case .cancelled: return String(localized: "settings.error.cancelled")
            }
        }
    }

    // MARK: - State

    @ObservableState
    public struct State: Equatable {
        public let id: UUID
        public let accountID: String
        public let sessionGeneration: UInt64
        public let timeZone: TimeZone
        public let locale: Locale

        /// Device-local today. Updated by parent authority via `.todayChanged`.
        public var today: LocalDiaryDate

        // Goal sibling.
        public var goalPhase: SettingsPhase<GoalSnapshot> = .idle
        public var goalTexts = GoalTexts()
        public var loadedGoalTexts: [GoalField: String] = [:]
        public var unsupportedGoalFields: Set<GoalField> = []
        public var goalSave: GoalSaveState = .idle
        public var goalDayReview: DayReview = .none
        public var goalLoadToken = 0

        // Preferences sibling — independent lifecycle.
        public var prefsPhase: SettingsPhase<DiaryPreferences> = .idle
        public var selectedSlots: Set<MealSlot> = []
        public var prefsSave: PreferencesSaveState = .idle
        public var prefsLoadToken = 0

        // Session / dismissal lifecycle.
        public var lifecycle: Lifecycle = .active
        public var confirmation: Confirmation = .none

        public init(
            accountID: String,
            today: LocalDiaryDate,
            timeZone: TimeZone = .current,
            sessionGeneration: UInt64,
            id: UUID = UUID(),
            locale: Locale = .current
        ) {
            self.id = id
            self.accountID = accountID
            self.sessionGeneration = sessionGeneration
            self.today = today
            self.timeZone = timeZone
            self.locale = locale
        }

        public var isSaving: Bool {
            goalSave.isSaving || prefsSave.isSaving
        }

        public var isSessionExpired: Bool { lifecycle == .expired }

        public var canEditForm: Bool {
            lifecycle == .active && !isSaving
        }

        public var canSaveGoals: Bool {
            guard canEditForm, goalDayReview == .none, unsupportedGoalFields.isEmpty else { return false }
            switch goalSave {
            case .idle, .saved, .failed:
                break
            case .saving, .needsReconciliation, .reconciling:
                return false
            }
            guard hasUnsavedGoalChanges else { return false }
            if case .loaded = goalPhase { return true } else { return false }
        }

        public var canSavePreferences: Bool {
            guard canEditForm, hasUnsavedPreferencesChanges else { return false }
            switch prefsSave {
            case .idle, .saved, .failed:
                break
            case .saving, .needsReconciliation, .reconciling:
                return false
            }
            if case .loaded = prefsPhase { return true } else { return false }
        }

        public var canEditGoalFields: Bool {
            canEditForm && !goalSave.isReconciliation
        }

        public var canEditPreferenceFields: Bool {
            canEditForm && !prefsSave.isReconciliation
        }

        public var hasUnsavedGoalChanges: Bool {
            guard case .loaded = goalPhase else { return false }
            return goalTexts.calories != (loadedGoalTexts[.calories] ?? "")
                || goalTexts.protein != (loadedGoalTexts[.protein] ?? "")
                || goalTexts.carbs != (loadedGoalTexts[.carbs] ?? "")
                || goalTexts.fat != (loadedGoalTexts[.fat] ?? "")
        }

        public var hasUnsavedPreferencesChanges: Bool {
            guard case .loaded(let preferences) = prefsPhase else { return false }
            return selectedSlots != preferences.enabledSlots
        }

        public var hasUnsavedChanges: Bool {
            hasUnsavedGoalChanges || hasUnsavedPreferencesChanges
        }

        public var goalValidationMessage: String? {
            guard case .loaded = goalPhase, unsupportedGoalFields.isEmpty else { return nil }
            guard hasUnsavedGoalChanges || goalSave.errorMessage != nil else { return nil }
            if case .failure(let error) = DiaryGoalForm.validate(
                calories: goalTexts.calories,
                protein: goalTexts.protein,
                carbs: goalTexts.carbs,
                fat: goalTexts.fat,
                locale: locale
            ) {
                return error.message
            }
            return nil
        }

        public var goalSaveErrorMessage: String? {
            guard let message = goalSave.errorMessage else { return nil }
            return message == goalValidationMessage ? nil : message
        }

        public var preferencesValidationMessage: String? {
            guard case .loaded = prefsPhase else { return nil }
            return selectedSlots.isEmpty ? String(localized: "settings.slots.error.empty") : nil
        }

        public var preferencesSaveErrorMessage: String? {
            guard let message = prefsSave.errorMessage else { return nil }
            return message == preferencesValidationMessage ? nil : message
        }

        public var goalStatusMessage: String? {
            guard case .loaded(let snapshot) = goalPhase else { return nil }
            switch (snapshot.source, snapshot.effectiveFrom) {
            case (.default, _):
                return String(localized: "settings.goals.status.default")
            case (.saved, let effectiveFrom?):
                return String(format: String(localized: "settings.goals.status.savedFrom"), effectiveFrom.formatted)
            case (.saved, nil):
                return String(localized: "settings.goals.status.savedToday")
            }
        }

        public var goalUnsupportedMessage: String? {
            unsupportedGoalFields.isEmpty
                ? nil
                : String(localized: "settings.goals.error.unsupported")
        }

        public var requestContext: RequestContext {
            RequestContext(
                accountID: accountID,
                generation: sessionGeneration,
                settingsID: id
            )
        }
    }

    // MARK: - Action

    public enum Action: Equatable, Sendable {
        case task
        case load
        case todayChanged(LocalDiaryDate)

        case requestDismiss
        case confirmDiscard
        case cancelDiscard
        case presentAccountSettings
        case accountSettingsDismissed

        case retryGoals
        case retryPreferences
        case goalFieldChanged(GoalField, String)
        case toggleSlot(MealSlot, Bool)
        case saveGoals
        case savePreferences
        case reviewNewDayGoal
        case checkSavedGoal
        case checkSavedPreferences

        case goalReceived(context: RequestContext, token: Int, date: LocalDiaryDate, result: Result<GoalSnapshot, Failure>)
        case prefsReceived(context: RequestContext, token: Int, result: Result<DiaryPreferences, Failure>)
        case goalSaveReceived(context: RequestContext, token: Int, result: Result<GoalSnapshot, Failure>)
        case prefsSaveReceived(context: RequestContext, token: Int, result: Result<DiaryPreferences, Failure>)
        case goalReconcileReceived(context: RequestContext, token: Int, result: Result<GoalSnapshot, Failure>)
        case prefsReconcileReceived(context: RequestContext, token: Int, result: Result<DiaryPreferences, Failure>)
        case goalReloadedForNewDay(
            context: RequestContext,
            token: Int,
            preserveDraft: Bool,
            result: Result<GoalSnapshot, Failure>
        )

        case delegate(Delegate)
    }

    /// Typed authoritative server callbacks for the single parent owner.
    public enum Delegate: Equatable, Sendable {
        case goalSaved(
            settingsID: UUID,
            generation: UInt64,
            targets: DiaryGoalTargets,
            effectiveDate: LocalDiaryDate
        )
        case preferencesSaved(
            settingsID: UUID,
            generation: UInt64,
            prefs: DiaryPrefs
        )
        case sessionExpired(settingsID: UUID, generation: UInt64)
        case openAccountSettings(settingsID: UUID)
        case accountSettingsDismissed(settingsID: UUID)
        case dismiss(settingsID: UUID)
    }

    // MARK: - Client

    public struct Client: Sendable {
        public var fetchGoal: @Sendable (RequestContext, LocalDiaryDate) async throws -> GoalSnapshot
        public var saveGoal: @Sendable (RequestContext, SaveGoalRequest) async throws -> GoalSnapshot
        public var fetchPreferences: @Sendable (RequestContext) async throws -> DiaryPreferences
        public var updatePreferences: @Sendable (RequestContext, DiaryPreferences) async throws -> DiaryPreferences
        /// The current-session guard is mandatory: there is deliberately no
        /// always-true default. Every closure checks the captured context before
        /// transport and maps a stale identity to an unauthorized failure.
        public static func live(
            service: any DiarySettingsServicing,
            isCurrent: @escaping @MainActor @Sendable (RequestContext) -> Bool
        ) -> Self {
            return Self(
                fetchGoal: { context, date in
                    guard await MainActor.run(body: { isCurrent(context) }) else {
                        throw DiarySettingsServiceError.unauthorized
                    }
                    return try await service.fetchGoal(on: date)
                },
                saveGoal: { context, request in
                    guard await MainActor.run(body: { isCurrent(context) }) else {
                        throw DiarySettingsServiceError.unauthorized
                    }
                    return try await service.saveGoal(request)
                },
                fetchPreferences: { context in
                    guard await MainActor.run(body: { isCurrent(context) }) else {
                        throw DiarySettingsServiceError.unauthorized
                    }
                    return try await service.fetchDiaryPreferences()
                },
                updatePreferences: { context, preferences in
                    guard await MainActor.run(body: { isCurrent(context) }) else {
                        throw DiarySettingsServiceError.unauthorized
                    }
                    return try await service.updateDiaryPreferences(preferences)
                }
            )
        }
    }

    @Dependency(\.diarySettingsClient) private var client

    public init() {}

    // MARK: - Reducer

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                guard state.goalPhase == .idle, state.prefsPhase == .idle else { return .none }
                return .send(.load)

            case .load:
                state.goalLoadToken += 1
                state.prefsLoadToken += 1
                let goalToken = state.goalLoadToken
                let prefsToken = state.prefsLoadToken
                let today = state.today
                state.goalPhase = .loading
                state.prefsPhase = .loading
                state.goalSave = .idle
                state.prefsSave = .idle
                let context = state.requestContext
                return .merge(
                    fetchGoal(context: context, token: goalToken, date: today),
                    fetchPreferences(context: context, token: prefsToken)
                )

            case let .todayChanged(date):
                state.today = date
                return .none

            case .requestDismiss:
                guard !state.isSaving else { return .none }
                if state.confirmation == .discardConfirmed || !state.hasUnsavedChanges {
                    return .send(.delegate(.dismiss(settingsID: state.id)))
                }
                state.confirmation = .discardPrompt
                return .none

            case .confirmDiscard:
                state.confirmation = .discardConfirmed
                return .send(.delegate(.dismiss(settingsID: state.id)))

            case .cancelDiscard:
                state.confirmation = .none
                return .none

            case .presentAccountSettings:
                return .send(.delegate(.openAccountSettings(settingsID: state.id)))

            case .accountSettingsDismissed:
                return .send(.delegate(.accountSettingsDismissed(settingsID: state.id)))

            case .retryGoals:
                guard state.canEditForm else { return .none }
                state.goalLoadToken += 1
                let token = state.goalLoadToken
                let date = state.today
                state.goalPhase = .loading
                state.goalSave = .idle
                return fetchGoal(context: state.requestContext, token: token, date: date)

            case .retryPreferences:
                guard state.canEditForm else { return .none }
                state.prefsLoadToken += 1
                let token = state.prefsLoadToken
                state.prefsPhase = .loading
                state.prefsSave = .idle
                return fetchPreferences(context: state.requestContext, token: token)

            case let .goalFieldChanged(field, text):
                guard state.canEditGoalFields else { return .none }
                state.goalTexts[field] = text
                if state.unsupportedGoalFields.contains(field),
                   let value = DiaryGoalForm.decimal(state.goalTexts[field], locale: state.locale),
                   DiaryGoalForm.isSupportedDecimal(value) {
                    state.unsupportedGoalFields.remove(field)
                }
                switch state.goalSave {
                case .saved, .failed:
                    state.goalSave = .idle
                default:
                    break
                }
                return .none

            case let .toggleSlot(slot, enabled):
                guard state.canEditPreferenceFields else { return .none }
                if enabled {
                    state.selectedSlots.insert(slot)
                } else {
                    state.selectedSlots.remove(slot)
                }
                switch state.prefsSave {
                case .saved, .failed:
                    state.prefsSave = .idle
                default:
                    break
                }
                return .none

            case .saveGoals:
                guard state.canSaveGoals,
                      case .loaded(let previous) = state.goalPhase else { return .none }

                switch DiaryGoalForm.validate(
                    calories: state.goalTexts.calories,
                    protein: state.goalTexts.protein,
                    carbs: state.goalTexts.carbs,
                    fat: state.goalTexts.fat,
                    locale: state.locale
                ) {
                case .failure(let error):
                    state.goalSave = .failed(error.message)
                    return .none
                case .success(let targets):
                    let currentToday = state.today
                    guard previous.requestedDate == currentToday else {
                        state.goalDayReview = .required(String(localized: "settings.goals.error.dayChanged"))
                        state.goalSave = .failed(String(localized: "settings.goals.error.dayChanged"))
                        let reloadToken = Self.next(&state.goalLoadToken)
                        return reloadGoal(
                            context: state.requestContext,
                            token: reloadToken,
                            preserveDraft: true,
                            date: state.today
                        )
                    }

                    let token = state.goalLoadToken
                    let context = state.requestContext
                    let request = SaveGoalRequest(
                        localDate: currentToday,
                        deviceTimeZone: state.timeZone.identifier,
                        exactTargets: targets
                    )
                    state.goalSave = .saving
                    let client = self.client
                    return .run { send in
                        do {
                            let snapshot = try await client.saveGoal(context, request)
                            await send(.goalSaveReceived(context: context, token: token, result: .success(snapshot)))
                        } catch {
                            await send(.goalSaveReceived(context: context, token: token, result: .failure(Self.mapFailure(error))))
                        }
                    }
                }

            case .savePreferences:
                guard state.canSavePreferences,
                      case .loaded(let previous) = state.prefsPhase else { return .none }
                guard !state.selectedSlots.isEmpty else {
                    state.prefsSave = .failed(String(localized: "settings.slots.error.empty"))
                    return .none
                }

                let token = state.prefsLoadToken
                let context = state.requestContext
                let request = DiaryPreferences(enabledSlots: state.selectedSlots)
                state.prefsSave = .saving
                let client = self.client
                return .run { send in
                    do {
                        let preferences = try await client.updatePreferences(context, request)
                        await send(.prefsSaveReceived(context: context, token: token, result: .success(preferences)))
                    } catch {
                        await send(.prefsSaveReceived(context: context, token: token, result: .failure(Self.mapFailure(error))))
                    }
                }

            case .reviewNewDayGoal:
                guard state.lifecycle == .active,
                      !state.isSaving,
                      case .required = state.goalDayReview else { return .none }
                if case .loaded(let snapshot) = state.goalPhase,
                   snapshot.requestedDate == state.today {
                    state.goalDayReview = .none
                    state.goalSave = .idle
                    return .none
                }
                let token = Self.next(&state.goalLoadToken)
                return reloadGoal(
                    context: state.requestContext,
                    token: token,
                    preserveDraft: true,
                    date: state.today
                )

            case .checkSavedGoal:
                guard state.lifecycle == .active,
                      !state.isSaving,
                      case .needsReconciliation(let message, let pending) = state.goalSave else {
                    return .none
                }
                return performGoalReconciliation(
                    pending,
                    token: state.goalLoadToken,
                    message: message,
                    state: &state
                )

            case .checkSavedPreferences:
                guard state.lifecycle == .active,
                      !state.isSaving,
                      case .needsReconciliation(let message, let pending) = state.prefsSave else {
                    return .none
                }
                return performPreferencesReconciliation(
                    pending,
                    token: state.prefsLoadToken,
                    message: message,
                    state: &state
                )

            case let .goalReceived(context, token, date, result):
                guard Self.isCurrent(context, in: state),
                      token == state.goalLoadToken,
                      state.lifecycle == .active else { return .none }
                switch result {
                case .failure(let failure):
                    if failure == .unauthorized {
                        return expire(state: &state)
                    }
                    state.goalPhase = .failed(failure.message)
                    return .none
                case .success(let snapshot):
                    guard snapshot.requestedDate == date, date == state.today else {
                        state.goalPhase = .failed(String(localized: "settings.goals.error.dayChanged"))
                        let reloadToken = Self.next(&state.goalLoadToken)
                        return reloadGoal(
                            context: context,
                            token: reloadToken,
                            preserveDraft: false,
                            date: state.today
                        )
                    }
                    applyLoadedGoal(state: &state, snapshot: snapshot)
                    return .none
                }

            case let .prefsReceived(context, token, result):
                guard Self.isCurrent(context, in: state),
                      token == state.prefsLoadToken,
                      state.lifecycle == .active else { return .none }
                switch result {
                case .failure(let failure):
                    if failure == .unauthorized {
                        return expire(state: &state)
                    }
                    state.prefsPhase = .failed(failure.message)
                    return .none
                case .success(let preferences):
                    guard !preferences.enabledSlots.isEmpty else {
                        state.prefsPhase = .failed(String(localized: "settings.error.generic"))
                        return .none
                    }
                    applyLoadedPreferences(state: &state, preferences: preferences)
                    state.prefsSave = .idle
                    return .none
                }

            case let .goalSaveReceived(context, token, result):
                guard Self.isCurrent(context, in: state),
                      token == state.goalLoadToken,
                      state.lifecycle == .active else { return .none }
                switch result {
                case .success(let snapshot):
                    return applySavedGoal(state: &state, snapshot: snapshot)
                case .failure(let failure):
                    switch failure {
                    case .unauthorized:
                        state.goalSave = .failed(failure.message)
                        return expire(state: &state)
                    case .rejected(let message), .message(let message):
                        state.goalSave = .failed(message)
                        return .none
                    case .ambiguous, .cancelled:
                        let message = failure.message
                        guard case .loaded(let previous) = state.goalPhase else {
                            state.goalSave = .failed(message)
                            return .none
                        }
                        let attempt = GoalReconciliation(
                            context: context,
                            attempted: SettingsFeature.exactTargets(from: state.goalTexts, locale: state.locale),
                            previous: previous,
                            requestedDate: state.today
                        )
                        state.goalSave = .needsReconciliation(message, attempt)
                        return performGoalReconciliation(
                            attempt,
                            token: token,
                            message: message,
                            state: &state
                        )
                    }
                }

            case let .prefsSaveReceived(context, token, result):
                guard Self.isCurrent(context, in: state),
                      token == state.prefsLoadToken,
                      state.lifecycle == .active else { return .none }
                switch result {
                case .success(let preferences):
                    return applySavedPreferences(state: &state, preferences: preferences)
                case .failure(let failure):
                    switch failure {
                    case .unauthorized:
                        state.prefsSave = .failed(failure.message)
                        return expire(state: &state)
                    case .rejected(let message), .message(let message):
                        state.prefsSave = .failed(message)
                        return .none
                    case .ambiguous, .cancelled:
                        let message = failure.message
                        guard case .loaded(let previous) = state.prefsPhase else {
                            state.prefsSave = .failed(message)
                            return .none
                        }
                        let attempt = PreferencesReconciliation(
                            context: context,
                            requested: DiaryPreferences(enabledSlots: state.selectedSlots),
                            previous: previous
                        )
                        state.prefsSave = .needsReconciliation(message, attempt)
                        return performPreferencesReconciliation(
                            attempt,
                            token: token,
                            message: message,
                            state: &state
                        )
                    }
                }

            case let .goalReconcileReceived(context, token, result):
                guard Self.isCurrent(context, in: state),
                      token == state.goalLoadToken,
                      state.lifecycle == .active else { return .none }
                guard case .reconciling(_, let pending) = state.goalSave,
                      pending.context == context else { return .none }
                switch result {
                case .failure(let failure):
                    if failure == .unauthorized {
                        state.goalSave = .failed(failure.message)
                        return expire(state: &state)
                    }
                    state.goalSave = .needsReconciliation(
                        String(localized: "settings.goals.error.reconcileFailed"),
                        pending
                    )
                    return .none
                case .success(let snapshot):
                    if Self.matches(snapshot.targets, pending.attempted, locale: state.locale) {
                        return applySavedGoal(state: &state, snapshot: snapshot)
                    }
                    // The write did not land (or another writer won). Keep the
                    // user's exact draft; only the comparison baseline moves.
                    state.goalPhase = .loaded(snapshot)
                    state.goalSave = .failed(Self.matches(snapshot.targets, pending.previous.targets, locale: state.locale)
                        ? String(localized: "settings.goals.error.reconciled")
                        : String(localized: "settings.goals.error.reconciledChanged"))
                    return .none
                }

            case let .prefsReconcileReceived(context, token, result):
                guard Self.isCurrent(context, in: state),
                      token == state.prefsLoadToken,
                      state.lifecycle == .active else { return .none }
                guard case .reconciling(_, let pending) = state.prefsSave,
                      pending.context == context else { return .none }
                switch result {
                case .failure(let failure):
                    if failure == .unauthorized {
                        state.prefsSave = .failed(failure.message)
                        return expire(state: &state)
                    }
                    state.prefsSave = .needsReconciliation(
                        String(localized: "settings.slots.error.reconcileFailed"),
                        pending
                    )
                    return .none
                case .success(let preferences):
                    guard !preferences.enabledSlots.isEmpty else {
                        state.prefsSave = .needsReconciliation(
                            String(localized: "settings.slots.error.reconcileFailed"),
                            pending
                        )
                        return .none
                    }
                    let canonical = DiaryPreferences(enabledSlots: preferences.enabledSlots)
                    if canonical == pending.requested {
                        return applySavedPreferences(state: &state, preferences: canonical)
                    }
                    state.prefsPhase = .loaded(canonical)
                    state.prefsSave = .failed(canonical == pending.previous
                        ? String(localized: "settings.slots.error.reconciled")
                        : String(localized: "settings.slots.error.reconciledChanged"))
                    return .none
                }

            case let .goalReloadedForNewDay(context, token, preserveDraft, result):
                guard Self.isCurrent(context, in: state),
                      token == state.goalLoadToken,
                      state.lifecycle == .active else { return .none }
                let previous: GoalSnapshot? = {
                    if case .loaded(let snapshot) = state.goalPhase { snapshot } else { nil }
                }()
                switch result {
                case .failure(let failure):
                    if failure == .unauthorized {
                        return expire(state: &state)
                    }
                    state.goalPhase = previous.map { .loaded($0) } ?? .failed(failure.message)
                    state.goalDayReview = .required(String(localized: "settings.goals.error.dayChanged"))
                    state.goalSave = .failed(String(localized: "settings.goals.error.dayChanged"))
                case .success(let snapshot) where snapshot.requestedDate == state.today:
                    if preserveDraft {
                        // Baseline changes; the typed field values are kept.
                        state.goalPhase = .loaded(snapshot)
                        state.goalDayReview = .required(String(localized: "settings.goals.error.dayChanged"))
                        state.goalSave = .failed(String(localized: "settings.goals.error.dayChanged"))
                    } else {
                        applyLoadedGoal(state: &state, snapshot: snapshot)
                    }
                case .success:
                    state.goalPhase = previous.map { .loaded($0) } ?? .failed(String(localized: "settings.goals.error.dayChanged"))
                    state.goalDayReview = .required(String(localized: "settings.goals.error.dayChanged"))
                    state.goalSave = .failed(String(localized: "settings.goals.error.dayChanged"))
                }
                return .none

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Effects

    private func fetchGoal(context: RequestContext, token: Int, date: LocalDiaryDate) -> Effect<Action> {
        let client = self.client
        return .run { send in
            do {
                let snapshot = try await client.fetchGoal(context, date)
                await send(.goalReceived(context: context, token: token, date: date, result: .success(snapshot)))
            } catch {
                await send(.goalReceived(context: context, token: token, date: date, result: .failure(Self.mapFailure(error))))
            }
        }
    }

    private func fetchPreferences(context: RequestContext, token: Int) -> Effect<Action> {
        let client = self.client
        return .run { send in
            do {
                let preferences = try await client.fetchPreferences(context)
                await send(.prefsReceived(context: context, token: token, result: .success(preferences)))
            } catch {
                await send(.prefsReceived(context: context, token: token, result: .failure(Self.mapFailure(error))))
            }
        }
    }

    private func reloadGoal(
        context: RequestContext,
        token: Int,
        preserveDraft: Bool,
        date: LocalDiaryDate
    ) -> Effect<Action> {
        let client = self.client
        return .run { send in
            do {
                let snapshot = try await client.fetchGoal(context, date)
                await send(.goalReloadedForNewDay(
                    context: context,
                    token: token,
                    preserveDraft: preserveDraft,
                    result: .success(snapshot)
                ))
            } catch {
                await send(.goalReloadedForNewDay(
                    context: context,
                    token: token,
                    preserveDraft: preserveDraft,
                    result: .failure(Self.mapFailure(error))
                ))
            }
        }
    }

    private func performGoalReconciliation(
        _ pending: GoalReconciliation,
        token: Int,
        message: String,
        state: inout State
    ) -> Effect<Action> {
        state.goalSave = .reconciling(message, pending)
        let client = self.client
        let context = pending.context
        return .run { send in
            do {
                let snapshot = try await client.fetchGoal(context, pending.requestedDate)
                await send(.goalReconcileReceived(context: context, token: token, result: .success(snapshot)))
            } catch {
                await send(.goalReconcileReceived(context: context, token: token, result: .failure(Self.mapFailure(error))))
            }
        }
    }

    private func performPreferencesReconciliation(
        _ pending: PreferencesReconciliation,
        token: Int,
        message: String,
        state: inout State
    ) -> Effect<Action> {
        state.prefsSave = .reconciling(message, pending)
        let client = self.client
        let context = pending.context
        return .run { send in
            do {
                let preferences = try await client.fetchPreferences(context)
                await send(.prefsReconcileReceived(context: context, token: token, result: .success(preferences)))
            } catch {
                await send(.prefsReconcileReceived(context: context, token: token, result: .failure(Self.mapFailure(error))))
            }
        }
    }

    // MARK: - State transitions

    private func expire(state: inout State) -> Effect<Action> {
        guard state.lifecycle == .active else { return .none }
        state.lifecycle = .expired
        let message = String(localized: "diary.error.sessionExpired")
        state.goalPhase = .failed(message)
        state.prefsPhase = .failed(message)
        if state.goalSave.isSaving { state.goalSave = .failed(message) }
        if state.prefsSave.isSaving { state.prefsSave = .failed(message) }
        return .send(.delegate(.sessionExpired(
            settingsID: state.id,
            generation: state.sessionGeneration
        )))
    }

    private func applyLoadedGoal(state: inout State, snapshot: GoalSnapshot) {
        let exact = snapshot.exactTargets ?? SettingsFeature.exactTargets(from: snapshot.targets)
        let values: [GoalField: Decimal] = [
            .calories: exact.calorieTarget,
            .protein: exact.proteinTargetG,
            .carbs: exact.carbsTargetG,
            .fat: exact.fatTargetG,
        ]
        let texts = values.mapValues { DiaryGoalForm.text(forDecimal: $0, locale: state.locale) }
        state.unsupportedGoalFields = Set(values.compactMap { field, value in
            DiaryGoalForm.isSupportedDecimal(value) ? nil : field
        })
        state.loadedGoalTexts = texts
        state.goalPhase = .loaded(snapshot)
        state.goalTexts.calories = texts[.calories] ?? ""
        state.goalTexts.protein = texts[.protein] ?? ""
        state.goalTexts.carbs = texts[.carbs] ?? ""
        state.goalTexts.fat = texts[.fat] ?? ""
        state.goalSave = .idle
        state.goalDayReview = .none
    }

    private func applyLoadedPreferences(state: inout State, preferences: DiaryPreferences) {
        let canonical = DiaryPreferences(enabledSlots: preferences.enabledSlots)
        state.prefsPhase = .loaded(canonical)
        state.selectedSlots = canonical.enabledSlots
    }

    private func applySavedGoal(state: inout State, snapshot: GoalSnapshot) -> Effect<Action> {
        applyLoadedGoal(state: &state, snapshot: snapshot)
        state.goalSave = .saved
        return .send(.delegate(.goalSaved(
            settingsID: state.id,
            generation: state.sessionGeneration,
            targets: CalCoStoreMapping.diaryGoal(from: snapshot),
            effectiveDate: snapshot.requestedDate
        )))
    }

    private func applySavedPreferences(state: inout State, preferences: DiaryPreferences) -> Effect<Action> {
        guard !preferences.enabledSlots.isEmpty else {
            state.prefsSave = .failed(String(localized: "settings.error.generic"))
            return .none
        }
        let canonical = DiaryPreferences(enabledSlots: preferences.enabledSlots)
        state.prefsPhase = .loaded(canonical)
        state.selectedSlots = canonical.enabledSlots
        state.prefsSave = .saved
        return .send(.delegate(.preferencesSaved(
            settingsID: state.id,
            generation: state.sessionGeneration,
            prefs: CalCoStoreMapping.diaryPrefs(from: canonical)
        )))
    }

    // MARK: - Pure helpers

    /// Captured identity from a reply must equal the receiving store's account,
    /// generation and settings ID before token checks, mutation or delegation.
    private static func isCurrent(_ context: RequestContext, in state: State) -> Bool {
        context == state.requestContext
    }

    private static func next(_ token: inout Int) -> Int {
        token += 1
        return token
    }

    private static func mapFailure(_ error: Error) -> Failure {
        if isUnauthorizedDiarySettingsError(error) { return .unauthorized }
        if isAmbiguousDiarySettingsError(error) {
            return .ambiguous(diarySettingsErrorMessage(error))
        }
        return .rejected(diarySettingsErrorMessage(error))
    }

    private static func exactTargets(from texts: GoalTexts, locale: Locale) -> GoalTargetsDecimal {
        GoalTargetsDecimal(
            calorieTarget: DiaryGoalForm.decimal(texts.calories, locale: locale) ?? .zero,
            proteinTargetG: DiaryGoalForm.decimal(texts.protein, locale: locale) ?? .zero,
            carbsTargetG: DiaryGoalForm.decimal(texts.carbs, locale: locale) ?? .zero,
            fatTargetG: DiaryGoalForm.decimal(texts.fat, locale: locale) ?? .zero
        )
    }

    private static func exactTargets(from targets: GoalTargets) -> GoalTargetsDecimal {
        GoalTargetsDecimal(
            calorieTarget: GoalDecimalMath.exactDecimal(for: targets.calorieTarget) ?? .zero,
            proteinTargetG: GoalDecimalMath.exactDecimal(for: targets.proteinTargetG) ?? .zero,
            carbsTargetG: GoalDecimalMath.exactDecimal(for: targets.carbsTargetG) ?? .zero,
            fatTargetG: GoalDecimalMath.exactDecimal(for: targets.fatTargetG) ?? .zero
        )
    }

    private static func matches(_ targets: GoalTargets, _ exact: GoalTargetsDecimal, locale: Locale) -> Bool {
        DiaryGoalForm.matches(targets.calorieTarget, exact.calorieTarget, locale: locale)
            && DiaryGoalForm.matches(targets.proteinTargetG, exact.proteinTargetG, locale: locale)
            && DiaryGoalForm.matches(targets.carbsTargetG, exact.carbsTargetG, locale: locale)
            && DiaryGoalForm.matches(targets.fatTargetG, exact.fatTargetG, locale: locale)
    }

    private static func matches(_ targets: GoalTargets, _ other: GoalTargets, locale: Locale) -> Bool {
        DiaryGoalForm.matches(targets.calorieTarget, decimal(other.calorieTarget), locale: locale)
            && DiaryGoalForm.matches(targets.proteinTargetG, decimal(other.proteinTargetG), locale: locale)
            && DiaryGoalForm.matches(targets.carbsTargetG, decimal(other.carbsTargetG), locale: locale)
            && DiaryGoalForm.matches(targets.fatTargetG, decimal(other.fatTargetG), locale: locale)
    }

    private static func decimal(_ value: Double) -> Decimal {
        GoalDecimalMath.exactDecimal(for: value) ?? .zero
    }
}

extension DependencyValues {
    public var diarySettingsClient: SettingsFeature.Client {
        get { self[SettingsClientKey.self] }
        set { self[SettingsClientKey.self] = newValue }
    }
}

private enum SettingsClientKey: DependencyKey {
    static let liveValue: SettingsFeature.Client = .init(
        fetchGoal: { _, _ in throw DiarySettingsServiceError.unknown },
        saveGoal: { _, _ in throw DiarySettingsServiceError.unknown },
        fetchPreferences: { _ in throw DiarySettingsServiceError.unknown },
        updatePreferences: { _, _ in throw DiarySettingsServiceError.unknown }
    )
    static let testValue: SettingsFeature.Client = liveValue
}
