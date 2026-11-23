// File-level note: `completedFetchCount` increments only after a real fetch resolves
// and supports the CALCO_TEST-only accessibility marker in DiaryView.swift, letting
// UI tests observe that a specific refresh finished.

import Combine
import Foundation

@MainActor
public final class DiaryViewModel: ObservableObject {
    @Published public private(set) var selectedDate: LocalDiaryDate {
        didSet {
            guard selectedDate != oldValue else { return }
            onDateChange?(selectedDate)
        }
    }
    @Published public private(set) var today: LocalDiaryDate
    @Published public private(set) var state: DiaryLoadState = .loading

    /// True only while a previous/next/picker date-change fetch is in flight.
    /// This is deliberately separate from `state`: a date change keeps the
    /// loaded content mounted (no full-screen skeleton swap, no collapsed meal
    /// groups, no lost scroll position) and surfaces only a compact inline
    /// indicator. Quiet refreshes never set it.
    @Published public private(set) var isChangingDate = false

    @Published public private(set) var logs: [DiaryLog] = []
    @Published public private(set) var goal: DiaryGoalTargets = DiaryGoalTargets()
    @Published public private(set) var enabledSlots: Set<MealSlot> = Set(MealSlot.allCases)
    @Published public private(set) var macroMode: DiaryMacroDisplayMode = .grams
    @Published public private(set) var mutationNotice: DiaryMutationNotice?

    /// Empty-slot "Log latest" flow. Loading is per tapped slot; the review is
    /// shown before any write and keeps the destination date/slot explicit.
    @Published public private(set) var latestLoadingSlot: MealSlot?
    @Published public private(set) var latestReview: DiaryLatestReview?
    @Published public private(set) var latestErrorMessage: String?
    @Published public private(set) var latestIsSubmitting = false

    @Published public private(set) var completedFetchCount: Int = 0

    public var isSessionExpired: Bool {
        state == .sessionExpired
    }

    public var isRefreshing: Bool {
        if case .loaded(.refreshing) = state {
            return true
        }
        return false
    }

    public var errorMessage: String? {
        switch state {
        case .failed(let message):
            return message
        case .loaded(.failed(let message)):
            return message
        case .sessionExpired:
            return String(localized: "diary.error.sessionExpired")
        default:
            return nil
        }
    }

    public let service: DiaryServicing
    public var onAddFood: ((MealSlot, LocalDiaryDate) -> Void)?
    public var onDateChange: ((LocalDiaryDate) -> Void)?
    public var onOpenLogEditor: ((String, LocalDiaryDate) -> Void)?

    private let todayProvider: () -> LocalDiaryDate
    private let onSessionExpired: () -> Void
    private let latestSubmissionHandler: LogSubmissionHandler?
    private let timeZoneProvider: () -> String

    private var latestSlotsBySlot: [MealSlot: DiaryLatestSlot] = [:]
    private var latestLoadedForDate: LocalDiaryDate?
    private var latestFetchToken = 0

    private var currentToken: Int = 0
    /// Guards the inline date-change indicator against overlapping rapid taps:
    /// only the newest date change may clear it when its fetch resolves.
    private var dateChangeToken: Int = 0
    /// Authoritative local rows from successful PUT responses. A refetch that
    /// still returns an older row must not silently revert the saved value.
    private var savedLogOverrides: [LocalDiaryDate: [String: DiaryLog]] = [:]
    /// Settings saves can land while a date load is still in flight. The load
    /// token cannot be invalidated without leaving `.loading` stuck, so keep
    /// local wins until a fetch actually returns the saved value.
    private struct PendingGoalOverride {
        let targets: DiaryGoalTargets
        let date: LocalDiaryDate
        /// The one diary fetch that was in flight when the settings save
        /// landed. Future refreshes must accept authoritative server state.
        let token: Int
    }

    private struct PendingPreferencesOverride {
        let preferences: DiaryPrefs
        let token: Int
    }

    private var pendingGoalOverride: PendingGoalOverride?
    private var pendingPreferencesOverride: PendingPreferencesOverride?
    /// Recently deleted IDs guard against an older in-flight fetch reopening a
    /// row after DELETE succeeded. A later fetch that no longer contains the ID
    /// retires the tombstone.
    private var deletedLogIDs: [LocalDiaryDate: Set<String>] = [:]

    public init(
        service: DiaryServicing,
        today: LocalDiaryDate,
        initialDate: LocalDiaryDate? = nil,
        todayProvider: (() -> LocalDiaryDate)? = nil,
        onAddFood: ((MealSlot, LocalDiaryDate) -> Void)? = nil,
        onDateChange: ((LocalDiaryDate) -> Void)? = nil,
        onOpenLogEditor: ((String, LocalDiaryDate) -> Void)? = nil,
        onSessionExpired: @escaping () -> Void = {},
        latestSubmissionHandler: LogSubmissionHandler? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier }
    ) {
        self.service = service
        self.today = today
        self.selectedDate = min(initialDate ?? today, today)
        self.todayProvider = todayProvider ?? { LocalDiaryDate.diaryToday() }
        self.onAddFood = onAddFood
        self.onDateChange = onDateChange
        self.onOpenLogEditor = onOpenLogEditor
        self.onSessionExpired = onSessionExpired
        self.latestSubmissionHandler = latestSubmissionHandler
        self.timeZoneProvider = timeZoneProvider
    }

    public func load() async {
        await load(for: selectedDate, preservingContent: hasLoadedContent)
    }

    public func refresh() async {
        guard !isSessionExpired else { return }
        await load(for: selectedDate, preservingContent: hasLoadedContent)
    }

    private func load(for date: LocalDiaryDate, preservingContent: Bool) async {
        guard !isSessionExpired else { return }
        guard date == selectedDate else { return }

        // Overrides only protect the fetch that was already in flight when a
        // settings save happened. A new load is a fresh authoritative read.
        clearPendingOverrides()
        let token = nextToken()
        if preservingContent && hasLoadedContent {
            state = .loaded(.refreshing)
        } else {
            state = .loading
        }

        do {
            let day = try await service.fetchDiary(for: date)
            guard token == currentToken, selectedDate == date else { return }
            logs = resolvedLogs(from: day.logs, for: date)
            let goalOverride = pendingGoalOverride
            let preferencesOverride = pendingPreferencesOverride
            pendingGoalOverride = nil
            pendingPreferencesOverride = nil
            if let goalOverride, goalOverride.token == token, goalOverride.date == date {
                goal = goalOverride.targets
            } else {
                goal = day.goal
            }
            if let preferencesOverride, preferencesOverride.token == token {
                enabledSlots = preferencesOverride.preferences.enabledSlots
            } else {
                enabledSlots = day.prefs.enabledSlots
            }
            state = .loaded(.idle)
            completedFetchCount += 1
        } catch {
            guard token == currentToken, selectedDate == date else { return }
            if pendingGoalOverride?.token == token { pendingGoalOverride = nil }
            if pendingPreferencesOverride?.token == token { pendingPreferencesOverride = nil }

            if Task.isCancelled || isCancelledDiaryError(error) {
                if hasLoadedContent {
                    state = .loaded(.idle)
                } else {
                    state = .loading
                }
                return
            }

            if isUnauthorizedDiaryError(error) {
                expireSession()
                return
            }

            let message = diaryErrorMessage(error)
            if hasLoadedContent {
                state = .loaded(.failed(message))
            } else {
                state = .failed(message)
            }
        }
    }

    public var canGoNext: Bool {
        selectedDate < today
    }

    public func previousDay() async {
        guard !isSessionExpired else { return }
        await selectDate(selectedDate.addingDays(-1))
    }

    public func nextDay() async {
        guard canGoNext, !isSessionExpired else { return }
        await selectDate(selectedDate.addingDays(1))
    }

    public func selectDate(_ date: LocalDiaryDate) async {
        guard !isSessionExpired else { return }
        let clamped = min(date, today)
        guard clamped != selectedDate else {
            if case .loaded = state {
                return
            }
            await load(for: clamped, preservingContent: false)
            return
        }

        mutationNotice = nil
        // The target date updates immediately, before the fetch resolves, so
        // the date label changes on the same frame as the tap.
        selectedDate = clamped

        // Keep the previously loaded day on screen while the new one loads.
        // `clearContent()` + `state = .loading` used to swap the entire diary
        // for a small spinner, collapsing every meal group and destroying the
        // ScrollView identity (and its scroll position). Only per-date "Log
        // latest" state is invalidated here; the brief and cards stay mounted.
        clearLatestSlotState()

        dateChangeToken += 1
        let changeToken = dateChangeToken
        isChangingDate = true
        defer {
            // Rapid taps overlap. An older fetch finishing later must not turn
            // off the indicator while a newer date change is still in flight.
            if changeToken == dateChangeToken { isChangingDate = false }
        }
        await load(for: clamped, preservingContent: true)
    }

    public func refreshToday() async {
        let newToday = todayProvider()
        let wasViewingToday = selectedDate == today

        if newToday != today {
            today = newToday

            if wasViewingToday || selectedDate > newToday {
                mutationNotice = nil
                selectedDate = newToday
                guard !isSessionExpired else { return }

                clearContent()
                state = .loading
                await load(for: newToday, preservingContent: false)
            }
            return
        }

        // Same-day foreground return: refresh quietly so a log changed on
        // another device appears without waiting for a manual pull.
        guard wasViewingToday else { return }
        await refresh()
    }

    public func resetForSessionChange() {
        currentToken += 1
        dateChangeToken += 1
        isChangingDate = false
        clearContent()
        mutationNotice = nil
        savedLogOverrides.removeAll()
        deletedLogIDs.removeAll()
        state = .loading

        let newToday = todayProvider()
        today = newToday
        selectedDate = newToday
    }

    public func addFood(for slot: MealSlot) {
        // Old rows/cards stay visible during a date change while `selectedDate`
        // is already the NEW date. Any entry point must not log against it.
        guard !isSessionExpired, !isChangingDate else { return }
        onAddFood?(slot, selectedDate)
    }

    // MARK: - Log latest

    public var isLatestLoggingAvailable: Bool {
        latestSubmissionHandler != nil
    }

    /// Shown only for empty, enabled slots. No latest lookup is made until the
    /// user taps, so an untouched diary never pays for an extra request.
    public func canLogLatest(for slot: MealSlot) -> Bool {
        guard isLatestLoggingAvailable,
              !isSessionExpired,
              !isChangingDate,
              enabledSlots.contains(slot) else { return false }
        return !logs.contains { $0.mealSlot == slot }
    }

    public func prepareLatest(for slot: MealSlot) async {
        // Defense in depth: `canLogLatest` already blocks this while a date
        // change is pending, but this is public and may be called directly.
        guard !isChangingDate, canLogLatest(for: slot), latestLoadingSlot == nil else { return }
        let date = selectedDate
        latestErrorMessage = nil
        latestLoadingSlot = slot

        if latestLoadedForDate != date {
            await loadLatestSlots(before: date)
        }
        guard selectedDate == date, latestLoadingSlot == slot else { return }
        latestLoadingSlot = nil
        guard latestLoadedForDate == date else { return }

        guard let source = latestSlotsBySlot[slot], !source.logs.isEmpty else {
            latestErrorMessage = String(
                format: String(localized: "diary.latest.empty"),
                DiaryLabels.mealSlotName(slot)
            )
            return
        }
        guard source.logs.count <= LogSubmissionRequestBuilder.maxDrafts else {
            latestErrorMessage = String(
                format: String(localized: "diary.latest.tooMany"),
                LogSubmissionRequestBuilder.maxDrafts
            )
            return
        }
        latestReview = DiaryLatestReview(
            destinationDate: date,
            destinationSlot: slot,
            sourceDate: source.sourceDate,
            items: source.logs
        )
    }

    private func loadLatestSlots(before date: LocalDiaryDate) async {
        latestFetchToken += 1
        let token = latestFetchToken
        do {
            let slots = try await service.latestSlots(
                before: date,
                lookbackDays: 30
            )
            guard token == latestFetchToken, selectedDate == date else { return }
            var bySlot: [MealSlot: DiaryLatestSlot] = [:]
            for slot in slots {
                bySlot[slot.mealSlot] = slot
            }
            latestSlotsBySlot = bySlot
            latestLoadedForDate = date
        } catch {
            guard token == latestFetchToken, selectedDate == date else { return }
            if isCancelledDiaryError(error) || error is CancellationError {
                return
            }
            if isUnauthorizedDiaryError(error) {
                expireSession()
                return
            }
            latestErrorMessage = diaryErrorMessage(error)
        }
    }

    public func cancelLatestReview() {
        guard !latestIsSubmitting else { return }
        latestReview = nil
        latestErrorMessage = nil
    }

    public func submitLatest() {
        guard let review = latestReview,
              !latestIsSubmitting,
              let handler = latestSubmissionHandler else { return }
        guard let drafts = review.makeDrafts(timeZone: timeZoneProvider()) else {
            latestErrorMessage = String(localized: "diary.latest.invalid")
            return
        }
        latestIsSubmitting = true
        latestErrorMessage = nil
        let summary = LogSubmissionSummary.text(
            for: drafts,
            names: review.items.map(\.title)
        )
        handler(drafts, review.items.map(\.title), summary) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestIsSubmitting = false
                switch result {
                case .success:
                    self.latestReview = nil
                    await self.refresh()
                case .failure(let failure):
                    if failure == .unauthorized {
                        self.expireSession()
                        return
                    }
                    self.latestErrorMessage = failure.message
                }
            }
        }
    }

    public func dismissLatestError() {
        latestErrorMessage = nil
    }

    public func log(withID id: String) -> DiaryLog? {
        logs.first { $0.id == id }
    }

    /// Applies a successful PUT response immediately. This is the local source
    /// of truth until a later fetch returns the same values.
    public func applySavedLog(
        _ log: DiaryLog,
        replacing originalID: String,
        on date: LocalDiaryDate
    ) {
        let effectiveID = log.id.isEmpty ? originalID : log.id
        var overrides = savedLogOverrides[date] ?? [:]
        overrides.removeValue(forKey: originalID)
        overrides[effectiveID] = log
        savedLogOverrides[date] = overrides
        deletedLogIDs[date]?.remove(effectiveID)

        guard date == selectedDate else { return }
        if let index = logs.firstIndex(where: {
            $0.id == originalID || $0.id == effectiveID
        }) {
            logs[index] = log
        } else {
            logs.append(log)
        }
    }

    /// Applies a saved goal only when the selected diary day is the day the
    /// backend saved (device-local today). Historical days keep the goal that
    /// was effective for them, and the selected date never changes here.
    public func applySavedGoal(_ targets: DiaryGoalTargets, effectiveOn date: LocalDiaryDate) {
        guard !isSessionExpired, selectedDate == date else { return }
        if case .loading = state {
            // Protect only this already-in-flight fetch. The next load starts
            // with authoritative server state.
            pendingGoalOverride = PendingGoalOverride(
                targets: targets,
                date: date,
                token: currentToken
            )
        } else {
            // A loaded/refreshing screen can be fenced directly; no future
            // refresh may be masked by an old local value.
            fenceStaleDiaryFetch()
        }
        goal = targets
    }

    /// Applies saved meal-slot preferences without refetching or changing the
    /// date. Logs already loaded for now-hidden slots remain in `logs` and
    /// still render through `groupedSections`.
    public func applySavedPreferences(_ preferences: DiaryPrefs) {
        guard !isSessionExpired, !preferences.enabledSlots.isEmpty else { return }
        if case .loading = state {
            pendingPreferencesOverride = PendingPreferencesOverride(
                preferences: preferences,
                token: currentToken
            )
        } else {
            fenceStaleDiaryFetch()
        }
        enabledSlots = preferences.enabledSlots
    }

    /// Applies a successful DELETE immediately and remembers a tombstone so a
    /// stale fetch cannot reopen the row before the next refetch.
    public func applyDeletedLog(logID: String, on date: LocalDiaryDate) {
        savedLogOverrides[date]?.removeValue(forKey: logID)
        if savedLogOverrides[date]?.isEmpty == true {
            savedLogOverrides[date] = nil
        }
        deletedLogIDs[date, default: []].insert(logID)
        guard date == selectedDate else { return }
        logs.removeAll { $0.id == logID }
    }

    private func resolvedLogs(
        from fetched: [DiaryLog],
        for date: LocalDiaryDate
    ) -> [DiaryLog] {
        let fetchedIDs = Set(fetched.map(\.id))
        var overrides = savedLogOverrides[date] ?? [:]
        overrides = overrides.filter { fetchedIDs.contains($0.key) }
        savedLogOverrides[date] = overrides.isEmpty ? nil : overrides

        let tombstones = deletedLogIDs[date] ?? []
        let stillStale = tombstones.intersection(fetchedIDs)
        deletedLogIDs[date] = stillStale.isEmpty ? nil : stillStale

        return fetched
            .filter { !tombstones.contains($0.id) }
            .map { row in
                guard let saved = overrides[row.id] else { return row }
                if saved == row {
                    overrides.removeValue(forKey: row.id)
                    savedLogOverrides[date] = overrides.isEmpty ? nil : overrides
                    return row
                }
                return saved
            }
    }

    public func openLogEditor(logID: String) {
        // A visible row from the retained previous day must not open an editor
        // stamped with the already-updated `selectedDate`.
        guard !isSessionExpired, !isChangingDate else { return }
        guard log(withID: logID) != nil else { return }
        onOpenLogEditor?(logID, selectedDate)
    }

    public func setMacroMode(_ mode: DiaryMacroDisplayMode) {
        guard macroMode != mode else { return }
        macroMode = mode
    }

    public func showMutationNotice(_ notice: DiaryMutationNotice) {
        mutationNotice = notice
    }

    public func clearMutationNotice() {
        guard mutationNotice != nil else { return }
        mutationNotice = nil
    }

    public var groupedSections: [DiarySection] {
        var sections: [DiarySection] = []
        for slot in MealSlot.allCases {
            let slotLogs = logs.filter { $0.mealSlot == slot }
            if enabledSlots.contains(slot) || !slotLogs.isEmpty {
                sections.append(DiarySection(
                    id: slot.rawValue,
                    slot: slot,
                    logs: slotLogs
                ))
            }
        }
        let unslotted = logs.filter { $0.mealSlot == nil }
        if !unslotted.isEmpty {
            sections.append(DiarySection(id: "unslotted", slot: nil, logs: unslotted))
        }
        return sections
    }

    public var totalCalories: Double {
        logs.reduce(0) { $0 + $1.calories }
    }

    public var totalProteinG: Double {
        logs.reduce(0) { $0 + $1.proteinG }
    }

    public var totalCarbsG: Double {
        logs.reduce(0) { $0 + $1.carbsG }
    }

    public var totalFatG: Double {
        logs.reduce(0) { $0 + $1.fatG }
    }

    public var calorieProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalCalories, target: goal.calorieTarget)
    }

    public var proteinProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalProteinG, target: goal.proteinTargetG)
    }

    public var carbsProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalCarbsG, target: goal.carbsTargetG)
    }

    public var fatProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalFatG, target: goal.fatTargetG)
    }

    private var hasLoadedContent: Bool {
        if case .loaded = state {
            return true
        }
        return false
    }

    private func expireSession() {
        currentToken += 1
        dateChangeToken += 1
        isChangingDate = false
        clearContent()
        mutationNotice = nil
        state = .sessionExpired
        onSessionExpired()
    }

    private func clearContent() {
        logs = []
        goal = DiaryGoalTargets()
        enabledSlots = Set(MealSlot.allCases)
        clearPendingOverrides()
        clearLatestSlotState()
    }

    private func clearLatestSlotState() {
        latestFetchToken += 1
        latestSlotsBySlot = [:]
        latestLoadedForDate = nil
        latestLoadingSlot = nil
        latestReview = nil
        latestErrorMessage = nil
        latestIsSubmitting = false
    }

    private func clearPendingOverrides() {
        pendingGoalOverride = nil
        pendingPreferencesOverride = nil
    }

    /// A settings save is an authoritative local update. Invalidate any diary
    /// fetch that started before it so a late response cannot clobber the new
    /// goal or enabled-slot set. Only loaded states are fenced; a fresh date
    /// load is not turned into a permanently stuck loading state.
    private func fenceStaleDiaryFetch() {
        switch state {
        case .loaded(.refreshing):
            currentToken += 1
            state = .loaded(.idle)
        case .loaded:
            currentToken += 1
        case .loading, .failed, .sessionExpired:
            break
        }
    }

    private func nextToken() -> Int {
        currentToken += 1
        return currentToken
    }
}

public enum DiaryLabels {
    public static func mealSlotName(_ slot: MealSlot) -> String {
        switch slot {
        case .breakfast:
            return String(localized: "foodDetail.mealSlot.breakfast")
        case .lunch:
            return String(localized: "foodDetail.mealSlot.lunch")
        case .dinner:
            return String(localized: "foodDetail.mealSlot.dinner")
        case .snack:
            return String(localized: "foodDetail.mealSlot.snack")
        case .lateNightSnack:
            return String(localized: "foodDetail.mealSlot.lateNightSnack")
        }
    }

    public static func addFood(for slot: MealSlot) -> String {
        "\(String(localized: "diary.addFood")), \(mealSlotName(slot))"
    }
}

public extension LocalDiaryDate {
    func diaryDisplayTitle(locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let components = DateComponents(year: year, month: month, day: day)
        guard let foundationDate = calendar.date(from: components) else { return formatted }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: foundationDate)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return formatted
        }
        return foundationDate.formatted(
            Date.FormatStyle()
                .weekday(.wide)
                .month(.wide)
                .day(.defaultDigits)
                .locale(locale)
        )
    }
}

private extension LocalDiaryDate {
    static func diaryToday(calendar: Calendar = .current, now: Date = Date()) -> LocalDiaryDate {
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        return LocalDiaryDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }
}
