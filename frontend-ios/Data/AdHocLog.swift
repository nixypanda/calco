// Low-level request shape for `POST /api/logs/ad-hoc`.
//
// Library screens submit through the shared typed log handler. This request
// type exists for API contract tests and for a future adapter; the UI must
// never POST it directly. Current writes carry no idempotency key.

import Foundation

public enum AdHocLogRequestError: Error, Equatable, Sendable {
    case notAdHoc
    case invalidNutrients
}

public struct AdHocLogWriteRequest: Encodable, Equatable, Sendable {
    public let logDate: LocalDiaryDate
    public let deviceTimeZone: String?
    public let mealSlot: MealSlot?
    public let name: String
    public let brand: String?
    public let quantity: NutritionQuantity
    public let nutrients: [NutrientAmountValue]
    public let notes: String?

    public init(
        logDate: LocalDiaryDate,
        deviceTimeZone: String?,
        mealSlot: MealSlot?,
        name: String,
        brand: String?,
        quantity: NutritionQuantity,
        nutrients: [NutrientAmountValue],
        notes: String?
    ) {
        self.logDate = logDate
        self.deviceTimeZone = deviceTimeZone
        self.mealSlot = mealSlot
        self.name = name
        self.brand = brand
        self.quantity = quantity
        self.nutrients = nutrients
        self.notes = notes
    }

    public init(draft: LogSubmissionDraft) throws {
        guard case .adHoc(let name, let brand) = draft.item else {
            throw AdHocLogRequestError.notAdHoc
        }
        guard let nutrients = draft.nutrients, !nutrients.isEmpty else {
            throw AdHocLogRequestError.invalidNutrients
        }
        self.init(
            logDate: draft.date,
            deviceTimeZone: draft.timeZone,
            mealSlot: draft.mealSlot,
            name: name,
            brand: brand,
            quantity: NutritionQuantity(amount: draft.amount, unit: draft.unit),
            nutrients: nutrients.sorted { $0.code < $1.code },
            notes: draft.notes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case deviceTimeZone = "device_timezone"
        case mealSlot = "meal_slot"
        case name
        case brand
        case quantity
        case nutrients
        case notes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encodeIfPresent(deviceTimeZone, forKey: .deviceTimeZone)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(nutrients, forKey: .nutrients)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

public enum AdHocLogRequestBuilder {
    public static func makeRequest(
        draft: LogSubmissionDraft
    ) throws -> AdHocLogWriteRequest {
        try AdHocLogWriteRequest(draft: draft)
    }
}
