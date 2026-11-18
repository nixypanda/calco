//
//  Navigation.swift
//
//  A tiny, pure navigation / pane-context model for the CalCo native vertical
//  slice: diary -> food search -> food detail -> log -> diary. It tracks the
//  active pane and the shared diary-date / meal-slot context.
//

import Foundation

// MARK: - Context value types

public struct LocalDiaryDate: Equatable, Hashable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              Self.isValid(year: year, month: month, day: day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public var formatted: String {
        Self.pad(year, width: 4) + "-" + Self.pad(month, width: 2) + "-" + Self.pad(day, width: 2)
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(abs(value))
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        return day <= daysInMonth(year: year, month: month)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 400 == 0) || (year % 4 == 0 && year % 100 != 0)
    }
}

public enum MealSlot: String, Codable, CaseIterable, Hashable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack
    case lateNightSnack = "late_night_snack"
}

// MARK: - Panes and layout

public enum Pane: Equatable, Hashable, Codable, Sendable {
    case diary
    case foodSearch
    case foodDetail(foodID: String)
    case foodLog(foodID: String)
    case logEditor(logID: String)
}

public enum PaneRole: String, Codable, Hashable, Sendable {
    case main
    case detail
}

public struct VisiblePane: Equatable, Hashable, Sendable {
    public let role: PaneRole
    public let pane: Pane

    public init(role: PaneRole, pane: Pane) {
        self.role = role
        self.pane = pane
    }
}

public enum PaneLayout: Equatable, Hashable, Sendable {
    case compact
    case expanded
}

/// Chooses the pane presentation from the actual available width, not only the
/// size class. iPad mini portrait and narrow macOS windows report a regular
/// size class but cannot fit a usable three-column split.
public enum AppShellLayout {
    public static let expandedMinimumWidth: Double = 900

    public static func resolve(
        isCompactSizeClass: Bool,
        width: Double
    ) -> PaneLayout {
        if isCompactSizeClass {
            return .compact
        }
        guard width > 0 else {
            // Before GeometryReader reports a size, keep the established split
            // so the first frame does not flash a compact stack.
            return .expanded
        }
        return width < expandedMinimumWidth ? .compact : .expanded
    }
}

public enum PrimarySection: Equatable, Hashable, Sendable {
    case diary
    case search
}

// MARK: - Navigation state

public struct NavigationState: Equatable, Codable, Sendable {
    public private(set) var selectedDate: LocalDiaryDate

    public private(set) var mealSlot: MealSlot?

    private var panesStorage: [Pane]

    public init(date: LocalDiaryDate, mealSlot: MealSlot? = nil, panes: [Pane] = [.diary]) {
        self.selectedDate = date
        self.mealSlot = mealSlot
        self.panesStorage = Self.normalized(panes)
    }

    private static func normalized(_ panes: [Pane]) -> [Pane] {
        panes.isEmpty ? [.diary] : panes
    }

    private enum CodingKeys: String, CodingKey {
        case selectedDate
        case mealSlot
        case panes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedDate = try container.decode(LocalDiaryDate.self, forKey: .selectedDate)
        self.mealSlot = try container.decodeIfPresent(MealSlot.self, forKey: .mealSlot)
        let decodedPanes = try container.decodeIfPresent([Pane].self, forKey: .panes) ?? [.diary]
        self.panesStorage = Self.normalized(decodedPanes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedDate, forKey: .selectedDate)
        try container.encodeIfPresent(mealSlot, forKey: .mealSlot)
        try container.encode(panesStorage, forKey: .panes)
    }

    // MARK: Inspection

    public var paneStack: [Pane] { panesStorage }

    public var activePane: Pane { panesStorage.last! }

    public var hasDetail: Bool { panesStorage.count > 1 }

    public var editingLogID: String? {
        switch activePane {
        case .logEditor(let logID): return logID
        default: return nil
        }
    }

    public var primarySection: PrimarySection {
        switch activePane {
        case .diary, .logEditor: return .diary
        case .foodSearch, .foodDetail, .foodLog: return .search
        }
    }

    public func paneLimit(for layout: PaneLayout) -> Int {
        layout == .compact ? 1 : 2
    }

    public func visiblePanes(for layout: PaneLayout) -> [VisiblePane] {
        switch layout {
        case .compact:
            return [VisiblePane(role: hasDetail ? .detail : .main, pane: activePane)]

        case .expanded:
            guard panesStorage.count > 1 else {
                return [VisiblePane(role: .main, pane: .diary)]
            }
            return [
                VisiblePane(role: .main, pane: panesStorage[panesStorage.count - 2]),
                VisiblePane(role: .detail, pane: panesStorage[panesStorage.count - 1]),
            ]
        }
    }

    // MARK: Context changes

    public mutating func selectDate(_ date: LocalDiaryDate) {
        selectedDate = date
        panesStorage = [.diary]
    }

    public mutating func updateSelectedDate(_ date: LocalDiaryDate) {
        selectedDate = date
    }

    public mutating func setMealSlot(_ slot: MealSlot?) {
        mealSlot = slot
    }

    // MARK: Flow transitions

    public mutating func startLogging(mealSlot slot: MealSlot? = nil) {
        if let slot { mealSlot = slot }
        panesStorage = [.diary, .foodSearch]
    }

    public mutating func pushSearch() {
        guard activePane != .foodSearch else { return }
        panesStorage.append(.foodSearch)
    }

    public mutating func pushFoodDetail(foodID: String) {
        panesStorage.append(.foodDetail(foodID: foodID))
    }

    public mutating func pushFoodLog(foodID: String) {
        panesStorage.append(.foodLog(foodID: foodID))
    }

    /// Opens the log editor over the diary without touching the selected date,
    /// so backing out returns to the same day the log was tapped from.
    public mutating func openLogEditor(logID: String) {
        guard activePane != .logEditor(logID: logID) else { return }
        panesStorage = [.diary, .logEditor(logID: logID)]
    }

    @discardableResult
    public mutating func back() -> Bool {
        guard panesStorage.count > 1 else { return false }
        panesStorage.removeLast()
        return true
    }

    public mutating func finishLogging() {
        panesStorage = [.diary]
    }

    public mutating func showDetail(foodID: String, date: LocalDiaryDate, mealSlot: MealSlot?) {
        selectedDate = date
        self.mealSlot = mealSlot
        panesStorage = [.diary, .foodSearch, .foodDetail(foodID: foodID)]
    }
}
