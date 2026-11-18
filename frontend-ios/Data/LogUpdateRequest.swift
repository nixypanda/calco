// Wire model for PUT /api/logs/{id}.
//
// Meal slot and notes are "clearable": the backend distinguishes an absent key
// (leave unchanged) from an explicit JSON null (clear the value). `OptionalField`
// makes that distinction expressible in a typed Swift model.

import Foundation

public enum OptionalField<Value> {
    /// Omit the key entirely; the server leaves the field unchanged.
    case absent
    /// Encode an explicit JSON `null`; the server clears the field.
    case null
    /// Encode the supplied value.
    case value(Value)
}

extension OptionalField: Equatable where Value: Equatable {}
extension OptionalField: Sendable where Value: Sendable {}

public struct UpdateLogRequest: Encodable, Equatable, Sendable {
    public let logDate: LocalDiaryDate?
    public let mealSlot: OptionalField<MealSlot>
    public let deviceTimeZone: OptionalField<String>
    public let quantity: NutritionQuantity?
    public let notes: OptionalField<String>

    public init(
        logDate: LocalDiaryDate? = nil,
        mealSlot: OptionalField<MealSlot> = .absent,
        deviceTimeZone: OptionalField<String> = .absent,
        quantity: NutritionQuantity? = nil,
        notes: OptionalField<String> = .absent
    ) {
        self.logDate = logDate
        self.mealSlot = mealSlot
        self.deviceTimeZone = deviceTimeZone
        self.quantity = quantity
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case mealSlot = "meal_slot"
        case deviceTimeZone = "device_timezone"
        case quantity
        case notes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if let logDate {
            try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        }
        if let quantity {
            try container.encode(quantity, forKey: .quantity)
        }

        switch mealSlot {
        case .absent:
            break
        case .null:
            try container.encodeNil(forKey: .mealSlot)
        case .value(let slot):
            try container.encode(slot.rawValue, forKey: .mealSlot)
        }

        switch deviceTimeZone {
        case .absent:
            break
        case .null:
            try container.encodeNil(forKey: .deviceTimeZone)
        case .value(let identifier):
            try container.encode(identifier, forKey: .deviceTimeZone)
        }

        switch notes {
        case .absent:
            break
        case .null:
            try container.encodeNil(forKey: .notes)
        case .value(let text):
            try container.encode(text, forKey: .notes)
        }
    }
}
