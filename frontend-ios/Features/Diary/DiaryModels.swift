import Foundation


public struct DiaryLog: Equatable, Identifiable, Sendable {
    public let id: String
    public let mealSlot: MealSlot?
    public let title: String
    public let calories: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double

    // Full log fields retained so a tap can open the editor without a refetch.
    // Defaults keep hand-built fixtures (tests, previews) source-compatible.
    public let quantity: NutritionQuantity?
    public let notes: String?
    public let brand: String?
    /// Backend item identity retained so deletion can match journal entries
    /// that may have created this log. Nil for legacy/hand-built fixtures.
    public let itemReference: ItemReference?

    public init(
        id: String,
        mealSlot: MealSlot? = nil,
        title: String,
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        quantity: NutritionQuantity? = nil,
        notes: String? = nil,
        brand: String? = nil,
        itemReference: ItemReference? = nil
    ) {
        self.id = id
        self.mealSlot = mealSlot
        self.title = title
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.quantity = quantity
        self.notes = notes
        self.brand = brand
        self.itemReference = itemReference
    }

    public var productID: String? {
        guard let itemReference, itemReference.itemType == .product else { return nil }
        return itemReference.id
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

    // Log editing. Default implementations keep simpler fakes source-compatible;
    // the real adapter implements all of them.
    func getLog(id: String) async throws -> DiaryLog
    func fetchUnits() async throws -> [FoodUnit]
    func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog
    func deleteLog(id: String) async throws
}

public extension DiaryServicing {
    func getLog(id: String) async throws -> DiaryLog { throw DiaryServiceError.unknown }
    func fetchUnits() async throws -> [FoodUnit] { [] }
    func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
        throw DiaryServiceError.unknown
    }
    func deleteLog(id: String) async throws { throw DiaryServiceError.unknown }
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

public enum DiaryMacroDisplayMode: String, Equatable, Sendable {
    case grams
    case percent
}

public enum DiaryMacroKind: String, Sendable {
    case protein
    case carbs
    case fat

    /// Compact glyph used where horizontal space is tight (narrow phones).
    public var shortLabel: String {
        switch self {
        case .protein: return "P"
        case .carbs: return "C"
        case .fat: return "F"
        }
    }

    /// Full localized name used in wide layouts and always for VoiceOver.
    public var fullLabel: String {
        switch self {
        case .protein: return String(localized: "diary.macro.protein")
        case .carbs: return String(localized: "diary.macro.carbs")
        case .fat: return String(localized: "diary.macro.fat")
        }
    }

    /// VoiceOver label that always includes both the full nutrient name and
    /// the displayed value, even when the visual column uses a short glyph.
    public func voiceOverLabel(
        progress: DiaryGoalProgress,
        mode: DiaryMacroDisplayMode
    ) -> String {
        "\(fullLabel), \(DiaryMacroDisplay.text(for: progress, mode: mode))"
    }
}

public enum DiaryMutationKind: String, Equatable, Sendable {
    case saved
    case deleted
}

public struct DiaryMutationNotice: Equatable, Sendable {
    public let kind: DiaryMutationKind
    public let title: String
    /// Non-zero when deleting the log also disabled attempts that could have
    /// recreated it. The notice then explains why retry is no longer offered.
    public let blockedPendingCount: Int

    public init(
        kind: DiaryMutationKind,
        title: String,
        blockedPendingCount: Int = 0
    ) {
        self.kind = kind
        self.title = title
        self.blockedPendingCount = blockedPendingCount
    }

    public var message: String {
        switch kind {
        case .saved:
            return String(localized: "diary.mutation.saved")
        case .deleted:
            guard blockedPendingCount > 0 else {
                return String(localized: "diary.mutation.deleted")
            }
            return String(
                format: String(localized: "diary.mutation.deleted.blockedPending"),
                blockedPendingCount
            )
        }
    }
}

public enum DiaryMacroDisplay {
    public static func text(for progress: DiaryGoalProgress, mode: DiaryMacroDisplayMode) -> String {
        switch mode {
        case .grams:
            return "\(progress.summary) g"
        case .percent:
            guard let fraction = progress.fraction else { return "—" }
            return "\(Int((fraction * 100).rounded()))%"
        }
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

// MARK: - Calendar picker bridge
//
// Date-only values are represented at local noon so daylight-saving transitions
// cannot shift the day when a `DatePicker` hands a `Date` back.

public enum DiaryDateConversion {
    public static func date(from day: LocalDiaryDate, calendar: Calendar = diaryCalendar) -> Date? {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: day.year,
            month: day.month,
            day: day.day,
            hour: 12
        )
        return components.date
    }

    public static func day(from date: Date, calendar: Calendar = diaryCalendar) -> LocalDiaryDate? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return LocalDiaryDate(year: year, month: month, day: day)
    }

    public static var diaryCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}
