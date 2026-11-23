// Food log wire models.

import Foundation

public enum FoodItemType: String, Codable, CaseIterable, Sendable {
    case product
    case meal
}

public struct ItemReference: Codable, Equatable, Hashable, Sendable {
    public let itemType: FoodItemType
    public let id: String

    public init(itemType: FoodItemType, id: String) {
        self.itemType = itemType
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case itemType = "type"
        case id
    }
}

public struct ProductLogItemSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let brand: String?

    public init(id: String, name: String, brand: String? = nil) {
        self.id = id
        self.name = name
        self.brand = brand
    }
}

public struct MealLogItemSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AdHocLogItemSnapshot: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let brand: String?

    public init(name: String, brand: String? = nil) {
        self.name = name
        self.brand = brand
    }
}

public enum FoodLogItem: Equatable, Hashable, Sendable {
    case product(ProductLogItemSnapshot)
    case meal(MealLogItemSnapshot)
    case adHoc(AdHocLogItemSnapshot)

    public var name: String {
        switch self {
        case .product(let item): return item.name
        case .meal(let item): return item.name
        case .adHoc(let item): return item.name
        }
    }

    public var brand: String? {
        switch self {
        case .product(let item): return item.brand
        case .meal: return nil
        case .adHoc(let item): return item.brand
        }
    }

    public var reference: ItemReference? {
        switch self {
        case .product(let item): return ItemReference(itemType: .product, id: item.id)
        case .meal(let item): return ItemReference(itemType: .meal, id: item.id)
        case .adHoc: return nil
        }
    }
}

extension FoodLogItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case brand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "product":
            self = .product(
                ProductLogItemSnapshot(
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    brand: try container.decodeIfPresent(String.self, forKey: .brand)
                )
            )
        case "meal":
            self = .meal(
                MealLogItemSnapshot(
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name)
                )
            )
        case "ad_hoc":
            self = .adHoc(
                AdHocLogItemSnapshot(
                    name: try container.decode(String.self, forKey: .name),
                    brand: try container.decodeIfPresent(String.self, forKey: .brand)
                )
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown food log item type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .product(let item):
            try container.encode("product", forKey: .type)
            try container.encode(item.id, forKey: .id)
            try container.encode(item.name, forKey: .name)
            try container.encodeIfPresent(item.brand, forKey: .brand)
        case .meal(let item):
            try container.encode("meal", forKey: .type)
            try container.encode(item.id, forKey: .id)
            try container.encode(item.name, forKey: .name)
        case .adHoc(let item):
            try container.encode("ad_hoc", forKey: .type)
            try container.encode(item.name, forKey: .name)
            try container.encodeIfPresent(item.brand, forKey: .brand)
        }
    }
}

public struct FoodLog: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let logDate: LocalDiaryDate
    public let deviceTimeZone: String?
    public let mealSlot: MealSlot?
    public let item: FoodLogItem
    public let quantity: NutritionQuantity
    public let nutrients: [NutrientAmountValue]
    public let notes: String?

    public init(
        id: String,
        logDate: LocalDiaryDate,
        deviceTimeZone: String? = nil,
        mealSlot: MealSlot? = nil,
        item: FoodLogItem,
        quantity: NutritionQuantity,
        nutrients: [NutrientAmountValue] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.logDate = logDate
        self.deviceTimeZone = deviceTimeZone
        self.mealSlot = mealSlot
        self.item = item
        self.quantity = quantity
        self.nutrients = nutrients
        self.notes = notes
    }

    public var itemName: String { item.name }
    public var itemBrand: String? { item.brand }
    public var itemReference: ItemReference? { item.reference }

    public var calories: Double {
        nutrientAmount(NutrientCodes.energyKcal)
    }

    public var proteinG: Double {
        nutrientAmount(NutrientCodes.proteinG)
    }

    public var carbsG: Double {
        nutrientAmount(NutrientCodes.carbsG)
    }

    public var fatG: Double {
        nutrientAmount(NutrientCodes.fatG)
    }

    public var fiberG: Double {
        nutrientAmount(NutrientCodes.fiberG)
    }

    public func nutrientAmount(_ code: String) -> Double {
        guard let nutrient = nutrients.first(where: { $0.code == code }) else {
            return 0
        }
        return NutritionMath.safeAmount(nutrient.amount)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case logDate = "log_date"
        case deviceTimeZone = "device_timezone"
        case mealSlot = "meal_slot"
        case item
        case quantity
        case nutrients
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        logDate = try container.decodeLocalDiaryDate(forKey: .logDate)
        deviceTimeZone = try container.decodeIfPresent(String.self, forKey: .deviceTimeZone)
        mealSlot = try Self.decodeMealSlot(from: container)
        item = try container.decode(FoodLogItem.self, forKey: .item)
        quantity = try container.decode(NutritionQuantity.self, forKey: .quantity)
        nutrients = try container.decode([NutrientAmountValue].self, forKey: .nutrients)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encodeIfPresent(deviceTimeZone, forKey: .deviceTimeZone)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(item, forKey: .item)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(nutrients, forKey: .nutrients)
        try container.encodeIfPresent(notes, forKey: .notes)
    }

    private static func decodeMealSlot(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> MealSlot? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: .mealSlot) else {
            return nil
        }
        return MealSlot(rawValue: raw)
    }
}

public struct FoodLogListResponse: Codable, Equatable, Sendable {
    public let logDate: LocalDiaryDate
    public let items: [FoodLog]

    public init(logDate: LocalDiaryDate, items: [FoodLog]) {
        self.logDate = logDate
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logDate = try container.decodeLocalDiaryDate(forKey: .logDate)
        items = try container.decode([FoodLog].self, forKey: .items)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encode(items, forKey: .items)
    }
}

public struct CreateLogRequest: Encodable, Equatable, Sendable {
    public let logDate: LocalDiaryDate
    public let deviceTimeZone: String?
    public let mealSlot: MealSlot?
    public let item: ItemReference
    public let quantity: NutritionQuantity
    public let notes: String?
    /// Optional single-create retry key sent as `idempotency_key`. Omitted when nil.
    public let idempotencyKey: String?

    public init(
        logDate: LocalDiaryDate,
        deviceTimeZone: String? = TimeZone.current.identifier,
        mealSlot: MealSlot? = nil,
        item: ItemReference,
        quantity: NutritionQuantity,
        notes: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.logDate = logDate
        self.deviceTimeZone = deviceTimeZone
        self.mealSlot = mealSlot
        self.item = item
        self.quantity = quantity
        self.notes = notes
        self.idempotencyKey = idempotencyKey
    }

    public init(
        logDate: LocalDiaryDate,
        deviceTimeZone: String? = TimeZone.current.identifier,
        mealSlot: MealSlot? = nil,
        productID: String,
        quantity: NutritionQuantity,
        notes: String? = nil,
        idempotencyKey: String? = nil
    ) {
        self.init(
            logDate: logDate,
            deviceTimeZone: deviceTimeZone,
            mealSlot: mealSlot,
            item: ItemReference(itemType: .product, id: productID),
            quantity: quantity,
            notes: notes,
            idempotencyKey: idempotencyKey
        )
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case deviceTimeZone = "device_timezone"
        case mealSlot = "meal_slot"
        case item
        case quantity
        case notes
        case idempotencyKey = "idempotency_key"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encodeIfPresent(deviceTimeZone, forKey: .deviceTimeZone)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(item, forKey: .item)
        try container.encode(quantity, forKey: .quantity)
        if let notes {
            try container.encode(notes, forKey: .notes)
        } else {
            try container.encodeNil(forKey: .notes)
        }
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    }
}
