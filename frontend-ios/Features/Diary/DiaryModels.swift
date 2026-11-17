import Foundation


public struct DiaryLog: Equatable, Identifiable, Sendable {
    public let id: String
    public let mealSlot: MealSlot?
    public let title: String
    public let calories: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double

    public init(
        id: String,
        mealSlot: MealSlot? = nil,
        title: String,
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0
    ) {
        self.id = id
        self.mealSlot = mealSlot
        self.title = title
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }
}

public struct DiaryGoalTargets: Equatable, Sendable {
    public let calorieTarget: Double
    public let proteinTargetG: Double
    public let carbsTargetG: Double
    public let fatTargetG: Double

    public init(
        calorieTarget: Double = 0,
        proteinTargetG: Double = 0,
        carbsTargetG: Double = 0,
        fatTargetG: Double = 0
    ) {
        self.calorieTarget = calorieTarget
        self.proteinTargetG = proteinTargetG
        self.carbsTargetG = carbsTargetG
        self.fatTargetG = fatTargetG
    }
}

public struct DiaryPrefs: Equatable, Sendable {
    public let enabledSlots: Set<MealSlot>

    public init(enabledSlots: Set<MealSlot> = Set(MealSlot.allCases)) {
        self.enabledSlots = enabledSlots
    }

    public func isEnabled(_ slot: MealSlot) -> Bool {
        enabledSlots.contains(slot)
    }
}

public struct DiaryDay: Equatable, Sendable {
    public let date: LocalDiaryDate
    public let logs: [DiaryLog]
    public let goal: DiaryGoalTargets
    public let prefs: DiaryPrefs

    public init(
        date: LocalDiaryDate,
        logs: [DiaryLog] = [],
        goal: DiaryGoalTargets = DiaryGoalTargets(),
        prefs: DiaryPrefs = DiaryPrefs()
    ) {
        self.date = date
        self.logs = logs
        self.goal = goal
        self.prefs = prefs
    }
}

public struct DiarySection: Equatable, Identifiable, Sendable {
    public let id: String
    public let slot: MealSlot?
    public let logs: [DiaryLog]

    public init(id: String, slot: MealSlot?, logs: [DiaryLog]) {
        self.id = id
        self.slot = slot
        self.logs = logs
    }
}

public enum DiaryRefreshState: Equatable, Sendable {
    case idle
    case refreshing
    case failed(String)
}

public enum DiaryLoadState: Equatable, Sendable {
    case loading
    case loaded(DiaryRefreshState = .idle)
    case failed(String)
    case sessionExpired
}

public enum DiaryServiceError: Error, Equatable, Sendable {
    case unauthorized
    case cancelled
    case networkUnavailable
    case server(String)
    case unknown
}


public protocol DiaryServicing: Sendable {
    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay
}


public func isUnauthorizedDiaryError(_ error: Error) -> Bool {
    if let serviceError = error as? DiaryServiceError {
        return serviceError == .unauthorized
    }
    return (error as NSError).code == 401
}

public func isCancelledDiaryError(_ error: Error) -> Bool {
    if let serviceError = error as? DiaryServiceError {
        return serviceError == .cancelled
    }
    if error is CancellationError {
        return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

public func diaryErrorMessage(_ error: Error) -> String {
    let generic = String(localized: "diary.error.generic")
    if let serviceError = error as? DiaryServiceError {
        switch serviceError {
        case .unauthorized:
            return String(localized: "diary.error.sessionExpired")
        case .cancelled:
            return generic
        case .networkUnavailable:
            return String(localized: "diary.error.network")
        case .server(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? generic : trimmed
        case .unknown:
            return generic
        }
    }

    if isUnauthorizedDiaryError(error) {
        return String(localized: "diary.error.sessionExpired")
    }
    if isCancelledDiaryError(error) {
        return generic
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return String(localized: "diary.error.network")
        default:
            break
        }
    }
    if (error as NSError).domain == NSURLErrorDomain {
        return String(localized: "diary.error.network")
    }
    return generic
}


public enum DiaryValueFormat {
    public static func amount(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded()
        guard rounded != 0 else { return "0" }
        if abs(rounded) < 9_000_000_000_000_000 {
            return String(Int64(rounded))
        }
        return String(format: "%.0f", rounded)
    }
}

public struct DiaryGoalProgress: Equatable, Sendable {
    public let current: Double
    public let target: Double

    public init(current: Double, target: Double) {
        self.current = current
        self.target = target
    }

    public var hasTarget: Bool {
        target.isFinite && target > 0
    }

    public var currentText: String {
        DiaryValueFormat.amount(current)
    }

    public var targetText: String? {
        hasTarget ? DiaryValueFormat.amount(target) : nil
    }

    public var summary: String {
        guard let targetText else { return currentText }
        return "\(currentText) / \(targetText)"
    }

    public var fraction: Double? {
        guard current.isFinite, hasTarget else { return nil }
        return min(max(current / target, 0), 1)
    }
}


extension LocalDiaryDate {
    public func addingDays(_ days: Int) -> LocalDiaryDate {
        var year = self.year
        var month = self.month
        var day = self.day + days
        while day > Self.daysInMonth(year: year, month: month) {
            day -= Self.daysInMonth(year: year, month: month)
            month += 1
            if month > 12 {
                month = 1
                year += 1
            }
        }
        while day < 1 {
            month -= 1
            if month < 1 {
                month = 12
                year -= 1
            }
            day += Self.daysInMonth(year: year, month: month)
        }
        return LocalDiaryDate(year: year, month: month, day: day)
    }

    fileprivate static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    fileprivate static func isLeapYear(_ year: Int) -> Bool {
        (year % 400 == 0) || (year % 4 == 0 && year % 100 != 0)
    }
}

extension LocalDiaryDate: Comparable {
    public static func < (lhs: LocalDiaryDate, rhs: LocalDiaryDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}
