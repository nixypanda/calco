// Settings sheet state. Goal edits always target the device-local today; the
// selected diary date is context only and is never changed here.

import Combine
import Foundation

public enum DiaryGoalSettingsState: Equatable, Sendable {
    case loading
    case loaded(GoalSnapshot)
    case failed(String)
}

public enum DiaryPreferencesSettingsState: Equatable, Sendable {
    case loading
    case loaded(DiaryPreferences)
    case failed(String)
}

public enum DiarySettingsSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)

    public var isSaving: Bool { self == .saving }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@MainActor
public final class DiarySettingsViewModel: ObservableObject, Identifiable {
    private enum GoalField: CaseIterable {
        case calories
        case protein
        case carbs
        case fat
    }

    public let id = UUID()
    public let accountID: String

    @Published public private(set) var goalState: DiaryGoalSettingsState = .loading
    @Published public private(set) var preferencesState: DiaryPreferencesSettingsState = .loading
    @Published public var calorieTarget = "" { didSet { goalFieldChanged(.calories) } }
    @Published public var proteinTargetG = "" { didSet { goalFieldChanged(.protein) } }
    @Published public var carbsTargetG = "" { didSet { goalFieldChanged(.carbs) } }
    @Published public var fatTargetG = "" { didSet { goalFieldChanged(.fat) } }
    @Published public private(set) var selectedSlots: Set<MealSlot> = []
    @Published public private(set) var goalSaveState: DiarySettingsSaveState = .idle
    @Published public private(set) var preferencesSaveState: DiarySettingsSaveState = .idle
    /// A timed-out PUT must be reconciled against the server before a newer
    /// changed payload is allowed. This is last-write-wins, not conflict
    /// detection.
    @Published public private(set) var goalNeedsReconciliation = false
    @Published public private(set) var preferencesNeedsReconciliation = false
    @Published public private(set) var goalNeedsDayReview = false
    @Published public var isDiscardConfirmationPresented = false

    public var onGoalSaved: ((GoalSnapshot) -> Void)?
    public var onPreferencesSaved: ((DiaryPreferences) -> Void)?
    public var onSessionExpired: (() -> Void)?

    public let service: any DiarySettingsServicing
    public let locale: Locale
    private let todayProvider: () -> LocalDiaryDate
    private let timeZoneProvider: () -> String

    private struct GoalReconciliation {
        let attempted: GoalTargetsDecimal
        let previous: GoalSnapshot
        let requestedDate: LocalDiaryDate
    }

    private struct PreferencesReconciliation {
        let requested: DiaryPreferences
        let previous: DiaryPreferences
    }

    private var goalLoadToken = 0
    private var preferencesLoadToken = 0
    private var hasStartedLoad = false
    private var isApplyingGoalState = false
    @Published public private(set) var isReconciling = false
    private var isSessionExpired = false
    private var sessionExpiryDelivered = false
    private var discardApproved = false
    private var pendingGoalReconciliation: GoalReconciliation?
    private var pendingPreferencesReconciliation: PreferencesReconciliation?
    private var unsupportedGoalFields: Set<GoalField> = []
    private var loadedGoalTexts: [GoalField: String] = [:]

    public init(
        service: any DiarySettingsServicing,
        accountID: String,
        todayProvider: @escaping () -> LocalDiaryDate,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        locale: Locale = .current
    ) {
        self.service = service
        self.accountID = accountID
        self.todayProvider = todayProvider
        self.timeZoneProvider = timeZoneProvider
        self.locale = locale
    }

    public var today: LocalDiaryDate { todayProvider() }

    public var isSaving: Bool {
        goalSaveState.isSaving || preferencesSaveState.isSaving || isReconciling
    }

    public var canEditForm: Bool {
        !isSaving && !isSessionExpired
    }

    public var canSaveGoals: Bool {
        guard canEditForm,
              !goalNeedsReconciliation,
              !goalNeedsDayReview,
              unsupportedGoalFields.isEmpty,
              hasUnsavedGoalChanges else {
            return false
        }
        if case .loaded = goalState { return true }
        return false
    }

    public var canSavePreferences: Bool {
        guard canEditForm,
              !preferencesNeedsReconciliation,
              hasUnsavedPreferencesChanges else {
            return false
        }
        if case .loaded = preferencesState { return true }
        return false
    }

    public var canEditGoalFields: Bool {
        canEditForm && !goalNeedsReconciliation
    }

    public var canEditPreferenceFields: Bool {
        canEditForm && !preferencesNeedsReconciliation
    }

    public var hasUnsavedGoalChanges: Bool {
        guard case .loaded = goalState, !isApplyingGoalState else {
            return false
        }
        return calorieTarget != (loadedGoalTexts[.calories] ?? "")
            || proteinTargetG != (loadedGoalTexts[.protein] ?? "")
            || carbsTargetG != (loadedGoalTexts[.carbs] ?? "")
            || fatTargetG != (loadedGoalTexts[.fat] ?? "")
    }

    public var hasUnsavedPreferencesChanges: Bool {
        guard case .loaded(let preferences) = preferencesState else { return false }
        return selectedSlots != preferences.enabledSlots
    }

    public var hasUnsavedChanges: Bool {
        hasUnsavedGoalChanges || hasUnsavedPreferencesChanges
    }

    public var goalValidationMessage: String? {
        guard case .loaded = goalState, unsupportedGoalFields.isEmpty else { return nil }
        guard hasUnsavedGoalChanges || goalSaveState.errorMessage != nil else {
            return nil
        }
        if case .failure(let error) = DiaryGoalForm.validate(
            calories: calorieTarget,
            protein: proteinTargetG,
            carbs: carbsTargetG,
            fat: fatTargetG,
            locale: locale
        ) {
            return error.message
        }
        return nil
    }

    public var goalSaveErrorMessage: String? {
        guard let message = goalSaveState.errorMessage else { return nil }
        return message == goalValidationMessage ? nil : message
    }

    public var preferencesValidationMessage: String? {
        guard case .loaded = preferencesState else { return nil }
        return selectedSlots.isEmpty ? String(localized: "settings.slots.error.empty") : nil
    }

    public var preferencesSaveErrorMessage: String? {
        guard let message = preferencesSaveState.errorMessage else { return nil }
        return message == preferencesValidationMessage ? nil : message
    }

    public var goalStatusMessage: String? {
        guard case .loaded(let snapshot) = goalState else { return nil }
        switch (snapshot.source, snapshot.effectiveFrom) {
        case (.default, _):
            return String(localized: "settings.goals.status.default")
        case (.saved, let effectiveFrom?):
            return String(
                format: String(localized: "settings.goals.status.savedFrom"),
                effectiveFrom.formatted
            )
        case (.saved, nil):
            return String(localized: "settings.goals.status.savedToday")
        }
    }

    public var goalUnsupportedMessage: String? {
        unsupportedGoalFields.isEmpty
            ? nil
            : String(localized: "settings.goals.error.unsupported")
    }

    public func loadIfNeeded() async {
        guard !hasStartedLoad else { return }
        hasStartedLoad = true
        await load()
    }

    public func load() async {
        hasStartedLoad = true
        let goalToken = nextGoalToken()
        let preferencesToken = nextPreferencesToken()
        goalState = .loading
        preferencesState = .loading
        goalSaveState = .idle
        preferencesSaveState = .idle
        isReconciling = false

        let service = self.service
        let date = todayProvider()
        let goalTask = Task { [weak self] in
            let result = await Task { try await service.fetchGoal(on: date) }.result
            self?.applyGoalResult(result, token: goalToken, expectedDate: date)
        }
        let preferencesTask = Task { [weak self] in
            let result = await Task { try await service.fetchDiaryPreferences() }.result
            self?.applyPreferencesResult(result, token: preferencesToken)
        }
        await goalTask.value
        await preferencesTask.value
    }

    public func retryGoals() async {
        guard !isSaving, !isSessionExpired else { return }
        let token = nextGoalToken()
        goalState = .loading
        goalSaveState = .idle
        let service = self.service
        let date = todayProvider()
        let result = await Task { try await service.fetchGoal(on: date) }.result
        applyGoalResult(result, token: token, expectedDate: date)
    }

    public func retryPreferences() async {
        guard !isSaving, !isSessionExpired else { return }
        let token = nextPreferencesToken()
        preferencesState = .loading
        preferencesSaveState = .idle
        let service = self.service
        let result = await Task { try await service.fetchDiaryPreferences() }.result
        applyPreferencesResult(result, token: token)
    }

    public func toggleSlot(_ slot: MealSlot, enabled: Bool) {
        guard canEditPreferenceFields else { return }
        if enabled {
            selectedSlots.insert(slot)
        } else {
            selectedSlots.remove(slot)
        }
        if preferencesSaveState == .saved || preferencesSaveState.errorMessage != nil {
            preferencesSaveState = .idle
        }
    }

    public func saveGoals() async {
        guard !isSessionExpired,
              !isSaving,
              !goalNeedsReconciliation,
              !goalNeedsDayReview,
              unsupportedGoalFields.isEmpty,
              hasUnsavedGoalChanges,
              case .loaded(let previousSnapshot) = goalState else {
            return
        }

        let targets: GoalTargetsDecimal
        switch DiaryGoalForm.validate(
            calories: calorieTarget,
            protein: proteinTargetG,
            carbs: carbsTargetG,
            fat: fatTargetG,
            locale: locale
        ) {
        case .success(let value):
            targets = value
        case .failure(let error):
            goalSaveState = .failed(error.message)
            return
        }

        let currentToday = todayProvider()
        guard previousSnapshot.requestedDate == currentToday else {
            goalNeedsDayReview = true
            goalSaveState = .failed(String(localized: "settings.goals.error.dayChanged"))
            await reloadGoalForNewToday()
            return
        }

        let token = goalLoadToken
        let request = SaveGoalRequest(
            localDate: currentToday,
            deviceTimeZone: timeZoneProvider(),
            exactTargets: targets
        )
        goalSaveState = .saving
        do {
            let snapshot = try await service.saveGoal(request)
            guard !isSessionExpired, token == goalLoadToken else { return }
            applySavedGoal(snapshot)
        } catch {
            guard !isSessionExpired, token == goalLoadToken else { return }
            if isUnauthorizedDiarySettingsError(error) {
                goalSaveState = .failed(String(localized: "diary.error.sessionExpired"))
                expireSession()
                return
            }
            goalSaveState = .failed(diarySettingsErrorMessage(error))
            if isAmbiguousDiarySettingsError(error) {
                let pending = GoalReconciliation(
                    attempted: targets,
                    previous: previousSnapshot,
                    requestedDate: request.localDate
                )
                pendingGoalReconciliation = pending
                await performGoalReconciliation(pending, token: token)
            }
        }
    }

    public func savePreferences() async {
        guard !isSessionExpired,
              !isSaving,
              !preferencesNeedsReconciliation,
              hasUnsavedPreferencesChanges,
              case .loaded(let previousPreferences) = preferencesState else {
            return
        }
        guard !selectedSlots.isEmpty else {
            preferencesSaveState = .failed(String(localized: "settings.slots.error.empty"))
            return
        }

        let token = preferencesLoadToken
        let canonical = MealSlot.allCases.filter { selectedSlots.contains($0) }
        let request = DiaryPreferences(enabledMealSlots: canonical)
        preferencesSaveState = .saving
        do {
            let preferences = try await service.updateDiaryPreferences(request)
            guard !isSessionExpired, token == preferencesLoadToken else { return }
            applySavedPreferences(preferences)
        } catch {
            guard !isSessionExpired, token == preferencesLoadToken else { return }
            if isUnauthorizedDiarySettingsError(error) {
                preferencesSaveState = .failed(String(localized: "diary.error.sessionExpired"))
                expireSession()
                return
            }
            preferencesSaveState = .failed(diarySettingsErrorMessage(error))
            if isAmbiguousDiarySettingsError(error) {
                let pending = PreferencesReconciliation(
                    requested: request,
                    previous: previousPreferences
                )
                pendingPreferencesReconciliation = pending
                await performPreferencesReconciliation(pending, token: token)
            }
        }
    }

    /// Midnight crossed since this form was loaded. Never silently PUT or
    /// discard the old form: fetch the new day's baseline while preserving the
    /// typed draft, then require an explicit review before any PUT.
    @discardableResult
    private func reloadGoalForNewToday(preserveDraft: Bool = true) async -> Bool {
        let newToday = todayProvider()
        let token = nextGoalToken()
        goalNeedsReconciliation = false
        let previousLoaded: GoalSnapshot? = {
            if case .loaded(let snapshot) = goalState { return snapshot }
            return nil
        }()
        let service = self.service
        let result = await Task { try await service.fetchGoal(on: newToday) }.result
        guard token == goalLoadToken, !isSessionExpired else { return false }
        switch result {
        case .success(let snapshot) where snapshot.requestedDate == newToday:
            if preserveDraft {
                // Baseline changes; the typed field values are intentionally kept.
                goalState = .loaded(snapshot)
                goalNeedsDayReview = true
                goalSaveState = .failed(String(localized: "settings.goals.error.dayChanged"))
            } else {
                applyLoadedGoal(snapshot)
            }
            return true
        case .success:
            if let previousLoaded {
                goalState = .loaded(previousLoaded)
            } else {
                goalState = .failed(String(localized: "settings.goals.error.dayChanged"))
            }
            goalNeedsDayReview = true
            goalSaveState = .failed(String(localized: "settings.goals.error.dayChanged"))
            return false
        case .failure(let error):
            if isUnauthorizedDiarySettingsError(error) {
                goalState = .failed(String(localized: "diary.error.sessionExpired"))
                expireSession()
                return false
            }
            if let previousLoaded {
                goalState = .loaded(previousLoaded)
            } else {
                goalState = .failed(diarySettingsErrorMessage(error))
            }
            goalNeedsDayReview = true
            goalSaveState = .failed(String(localized: "settings.goals.error.dayChanged"))
            return false
        }
    }

    /// Explicit acknowledgement that the preserved draft is now being edited
    /// against the new device-local day. Until this succeeds, saves stay gated.
    public func reviewNewDayGoal() async {
        guard !isSessionExpired, !isSaving, goalNeedsDayReview else { return }
        let currentToday = todayProvider()
        if case .loaded(let snapshot) = goalState, snapshot.requestedDate == currentToday {
            goalNeedsDayReview = false
            goalSaveState = .idle
            return
        }
        let loaded = await reloadGoalForNewToday()
        if loaded,
           case .loaded(let snapshot) = goalState,
           snapshot.requestedDate == todayProvider() {
            goalNeedsDayReview = false
            goalSaveState = .idle
        }
    }

    /// Manual "Check Saved Goal" action. It reuses the frozen attempted
    /// payload from the ambiguous PUT and never reloads the editable form as a
    /// generic GET would.
    public func checkSavedGoal() async {
        guard !isSessionExpired,
              !isSaving,
              goalNeedsReconciliation,
              let pending = pendingGoalReconciliation else { return }
        await performGoalReconciliation(pending, token: goalLoadToken)
    }

    /// Manual "Check Saved Meal Slots" action, matching the goal flow.
    public func checkSavedPreferences() async {
        guard !isSessionExpired,
              !isSaving,
              preferencesNeedsReconciliation,
              let pending = pendingPreferencesReconciliation else { return }
        await performPreferencesReconciliation(pending, token: preferencesLoadToken)
    }

    private func performGoalReconciliation(
        _ pending: GoalReconciliation,
        token: Int
    ) async {
        guard !isReconciling else { return }
        goalNeedsReconciliation = true
        isReconciling = true
        defer { isReconciling = false }
        do {
            let snapshot = try await service.fetchGoal(on: pending.requestedDate)
            guard !isSessionExpired, token == goalLoadToken else { return }
            goalNeedsReconciliation = false
            pendingGoalReconciliation = nil
            if matches(snapshot.targets, pending.attempted) {
                applySavedGoal(snapshot)
                return
            }
            // The write did not land (or another writer won). Keep the user's
            // exact draft and its dirty warning; only the comparison baseline
            // moves to the freshly read server value.
            goalState = .loaded(snapshot)
            if matches(snapshot.targets, pending.previous.targets) {
                goalSaveState = .failed(String(localized: "settings.goals.error.reconciled"))
            } else {
                goalSaveState = .failed(String(localized: "settings.goals.error.reconciledChanged"))
            }
        } catch {
            guard !isSessionExpired, token == goalLoadToken else { return }
            if isUnauthorizedDiarySettingsError(error) {
                goalSaveState = .failed(String(localized: "diary.error.sessionExpired"))
                pendingGoalReconciliation = nil
                expireSession()
                return
            }
            goalNeedsReconciliation = true
            goalSaveState = .failed(String(localized: "settings.goals.error.reconcileFailed"))
        }
    }

    private func performPreferencesReconciliation(
        _ pending: PreferencesReconciliation,
        token: Int
    ) async {
        guard !isReconciling else { return }
        preferencesNeedsReconciliation = true
        isReconciling = true
        defer { isReconciling = false }
        do {
            let preferences = try await service.fetchDiaryPreferences()
            guard !isSessionExpired, token == preferencesLoadToken else { return }
            guard !preferences.enabledSlots.isEmpty else {
                preferencesNeedsReconciliation = true
                preferencesSaveState = .failed(
                    String(localized: "settings.slots.error.reconcileFailed")
                )
                return
            }
            preferencesNeedsReconciliation = false
            pendingPreferencesReconciliation = nil
            let canonical = DiaryPreferences(enabledSlots: preferences.enabledSlots)
            if canonical == pending.requested {
                applySavedPreferences(canonical)
                return
            }
            preferencesState = .loaded(canonical)
            if canonical == pending.previous {
                preferencesSaveState = .failed(
                    String(localized: "settings.slots.error.reconciled")
                )
            } else {
                preferencesSaveState = .failed(
                    String(localized: "settings.slots.error.reconciledChanged")
                )
            }
        } catch {
            guard !isSessionExpired, token == preferencesLoadToken else { return }
            if isUnauthorizedDiarySettingsError(error) {
                preferencesSaveState = .failed(String(localized: "diary.error.sessionExpired"))
                pendingPreferencesReconciliation = nil
                expireSession()
                return
            }
            preferencesNeedsReconciliation = true
            preferencesSaveState = .failed(
                String(localized: "settings.slots.error.reconcileFailed")
            )
        }
    }

    /// Returns false when the sheet must stay open: a save is in flight, or
    /// unsaved edits need explicit discard confirmation.
    public func requestDismissal() -> Bool {
        guard !isSaving else { return false }
        if discardApproved || !hasUnsavedChanges {
            return true
        }
        isDiscardConfirmationPresented = true
        return false
    }

    public func confirmDiscard() {
        discardApproved = true
        isDiscardConfirmationPresented = false
    }

    public func cancelDiscard() {
        isDiscardConfirmationPresented = false
    }

    private func goalFieldChanged(_ field: GoalField) {
        guard !isApplyingGoalState else { return }
        if unsupportedGoalFields.contains(field),
           let value = DiaryGoalForm.decimal(currentText(for: field), locale: locale),
           DiaryGoalForm.isSupportedDecimal(value) {
            unsupportedGoalFields.remove(field)
        }
        if goalSaveState == .saved || goalSaveState.errorMessage != nil {
            goalSaveState = .idle
        }
    }

    private func currentText(for field: GoalField) -> String {
        switch field {
        case .calories: return calorieTarget
        case .protein: return proteinTargetG
        case .carbs: return carbsTargetG
        case .fat: return fatTargetG
        }
    }

    private func applyGoalResult(
        _ result: Result<GoalSnapshot, Error>,
        token: Int,
        expectedDate: LocalDiaryDate
    ) {
        guard token == goalLoadToken, !isSessionExpired else { return }
        switch result {
        case .success(let snapshot):
            guard snapshot.requestedDate == expectedDate, expectedDate == todayProvider() else {
                goalState = .failed(String(localized: "settings.goals.error.dayChanged"))
                Task { [weak self] in
                    await self?.reloadGoalForNewToday(preserveDraft: false)
                }
                return
            }
            applyLoadedGoal(snapshot)
        case .failure(let error):
            if isUnauthorizedDiarySettingsError(error) {
                goalState = .failed(String(localized: "diary.error.sessionExpired"))
                expireSession()
            } else {
                goalState = .failed(diarySettingsErrorMessage(error))
            }
        }
    }

    private func applyPreferencesResult(
        _ result: Result<DiaryPreferences, Error>,
        token: Int
    ) {
        guard token == preferencesLoadToken, !isSessionExpired else { return }
        switch result {
        case .success(let preferences):
            guard !preferences.enabledSlots.isEmpty else {
                preferencesState = .failed(String(localized: "settings.error.generic"))
                return
            }
            let canonical = DiaryPreferences(enabledSlots: preferences.enabledSlots)
            preferencesState = .loaded(canonical)
            selectedSlots = canonical.enabledSlots
            preferencesSaveState = .idle
            preferencesNeedsReconciliation = false
        case .failure(let error):
            if isUnauthorizedDiarySettingsError(error) {
                preferencesState = .failed(String(localized: "diary.error.sessionExpired"))
                expireSession()
            } else {
                preferencesState = .failed(diarySettingsErrorMessage(error))
            }
        }
    }

    private func applyLoadedGoal(_ snapshot: GoalSnapshot) {
        let exact = snapshot.exactTargets ?? exactTargets(from: snapshot.targets)
        let values: [GoalField: Decimal] = [
            .calories: exact.calorieTarget,
            .protein: exact.proteinTargetG,
            .carbs: exact.carbsTargetG,
            .fat: exact.fatTargetG,
        ]
        let texts = values.mapValues {
            DiaryGoalForm.text(forDecimal: $0, locale: locale)
        }
        unsupportedGoalFields = Set(values.compactMap { field, value in
            DiaryGoalForm.isSupportedDecimal(value) ? nil : field
        })
        loadedGoalTexts = texts

        isApplyingGoalState = true
        goalState = .loaded(snapshot)
        calorieTarget = texts[.calories] ?? ""
        proteinTargetG = texts[.protein] ?? ""
        carbsTargetG = texts[.carbs] ?? ""
        fatTargetG = texts[.fat] ?? ""
        isApplyingGoalState = false
        goalSaveState = .idle
        goalNeedsReconciliation = false
        goalNeedsDayReview = false
    }

    private func exactTargets(from targets: GoalTargets) -> GoalTargetsDecimal {
        GoalTargetsDecimal(
            calorieTarget: GoalDecimalMath.exactDecimal(for: targets.calorieTarget) ?? .zero,
            proteinTargetG: GoalDecimalMath.exactDecimal(for: targets.proteinTargetG) ?? .zero,
            carbsTargetG: GoalDecimalMath.exactDecimal(for: targets.carbsTargetG) ?? .zero,
            fatTargetG: GoalDecimalMath.exactDecimal(for: targets.fatTargetG) ?? .zero
        )
    }

    private func matches(_ targets: GoalTargets, _ exact: GoalTargetsDecimal) -> Bool {
        DiaryGoalForm.matches(targets.calorieTarget, exact.calorieTarget, locale: locale)
            && DiaryGoalForm.matches(targets.proteinTargetG, exact.proteinTargetG, locale: locale)
            && DiaryGoalForm.matches(targets.carbsTargetG, exact.carbsTargetG, locale: locale)
            && DiaryGoalForm.matches(targets.fatTargetG, exact.fatTargetG, locale: locale)
    }

    private func matches(_ targets: GoalTargets, _ other: GoalTargets) -> Bool {
        DiaryGoalForm.matches(targets.calorieTarget, decimal(other.calorieTarget), locale: locale)
            && DiaryGoalForm.matches(targets.proteinTargetG, decimal(other.proteinTargetG), locale: locale)
            && DiaryGoalForm.matches(targets.carbsTargetG, decimal(other.carbsTargetG), locale: locale)
            && DiaryGoalForm.matches(targets.fatTargetG, decimal(other.fatTargetG), locale: locale)
    }

    private func decimal(_ value: Double) -> Decimal {
        GoalDecimalMath.exactDecimal(for: value) ?? .zero
    }

    private func applySavedGoal(_ snapshot: GoalSnapshot) {
        applyLoadedGoal(snapshot)
        goalSaveState = .saved
        onGoalSaved?(snapshot)
    }

    private func applySavedPreferences(_ preferences: DiaryPreferences) {
        guard !preferences.enabledSlots.isEmpty else {
            preferencesSaveState = .failed(String(localized: "settings.error.generic"))
            return
        }
        let canonical = DiaryPreferences(enabledSlots: preferences.enabledSlots)
        preferencesState = .loaded(canonical)
        selectedSlots = canonical.enabledSlots
        preferencesSaveState = .saved
        preferencesNeedsReconciliation = false
        onPreferencesSaved?(canonical)
    }

    private func expireSession() {
        guard !isSessionExpired else { return }
        isSessionExpired = true
        let message = String(localized: "diary.error.sessionExpired")
        goalState = .failed(message)
        preferencesState = .failed(message)
        if goalSaveState.isSaving {
            goalSaveState = .failed(message)
        }
        if preferencesSaveState.isSaving {
            preferencesSaveState = .failed(message)
        }
        guard !sessionExpiryDelivered else { return }
        sessionExpiryDelivered = true
        onSessionExpired?()
    }

    private func nextGoalToken() -> Int {
        goalLoadToken += 1
        return goalLoadToken
    }

    private func nextPreferencesToken() -> Int {
        preferencesLoadToken += 1
        return preferencesLoadToken
    }
}
