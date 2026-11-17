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
    @Published public private(set) var logs: [DiaryLog] = []
    @Published public private(set) var goal: DiaryGoalTargets = DiaryGoalTargets()
    @Published public private(set) var enabledSlots: Set<MealSlot> = Set(MealSlot.allCases)

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

    private let todayProvider: () -> LocalDiaryDate
    private let onSessionExpired: () -> Void

    private var currentToken: Int = 0

    public init(
        service: DiaryServicing,
        today: LocalDiaryDate,
        initialDate: LocalDiaryDate? = nil,
        todayProvider: (() -> LocalDiaryDate)? = nil,
        onAddFood: ((MealSlot, LocalDiaryDate) -> Void)? = nil,
        onDateChange: ((LocalDiaryDate) -> Void)? = nil,
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.service = service
        self.today = today
        self.selectedDate = min(initialDate ?? today, today)
        self.todayProvider = todayProvider ?? { LocalDiaryDate.diaryToday() }
        self.onAddFood = onAddFood
        self.onDateChange = onDateChange
        self.onSessionExpired = onSessionExpired
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

        let token = nextToken()
        if preservingContent && hasLoadedContent {
            state = .loaded(.refreshing)
        } else {
            state = .loading
        }

        do {
            let day = try await service.fetchDiary(for: date)
            guard token == currentToken, selectedDate == date else { return }
            logs = day.logs
            goal = day.goal
            enabledSlots = day.prefs.enabledSlots
            state = .loaded(.idle)
            completedFetchCount += 1
        } catch {
            guard token == currentToken, selectedDate == date else { return }

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

        selectedDate = clamped
        clearContent()
        state = .loading
        await load(for: clamped, preservingContent: false)
    }

    public func refreshToday() async {
        let newToday = todayProvider()
        guard newToday != today else { return }

        let wasViewingToday = selectedDate == today
        today = newToday

        guard wasViewingToday || selectedDate > newToday else { return }
        selectedDate = newToday
        guard !isSessionExpired else { return }

        clearContent()
        state = .loading
        await load(for: newToday, preservingContent: false)
    }

    public func resetForSessionChange() {
        currentToken += 1
        clearContent()
        state = .loading

        let newToday = todayProvider()
        today = newToday
        selectedDate = newToday
    }

    public func addFood(for slot: MealSlot) {
        guard !isSessionExpired else { return }
        onAddFood?(slot, selectedDate)
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
        clearContent()
        state = .sessionExpired
        onSessionExpired()
    }

    private func clearContent() {
        logs = []
        goal = DiaryGoalTargets()
        enabledSlots = Set(MealSlot.allCases)
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
