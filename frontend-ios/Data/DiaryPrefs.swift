// Diary preferences wire model.

import Foundation

public struct DiaryPreferences: Codable, Equatable, Sendable {
    public let enabledMealSlots: [MealSlot]

    public init(enabledMealSlots: [MealSlot]) {
        self.enabledMealSlots = enabledMealSlots
    }

    public init(enabledSlots: Set<MealSlot>) {
        self.enabledMealSlots = MealSlot.allCases.filter { enabledSlots.contains($0) }
    }

    public var enabledSlots: Set<MealSlot> {
        Set(enabledMealSlots)
    }

    public func isEnabled(_ slot: MealSlot) -> Bool {
        enabledMealSlots.contains(slot)
    }

    private enum CodingKeys: String, CodingKey {
        case enabledMealSlots = "enabled_meal_slots"
    }
}
