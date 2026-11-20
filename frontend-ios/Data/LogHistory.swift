// Read models for recent usage, latest slots, categories, and barcode lookup.

import Foundation

public struct QuantityLogUsage: Equatable, Sendable {
    public let quantity: NutritionQuantity
    public let logCount: Int

    public init(quantity: NutritionQuantity, logCount: Int) {
        self.quantity = quantity
        self.logCount = logCount
    }
}

public struct RecentLogItem: Equatable, Identifiable, Sendable {
    public let item: FoodLogItem
    public let lastUsedDate: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let quantity: NutritionQuantity
    public let nutritionSummary: NutritionSummary
    public let topQuantities: [QuantityLogUsage]

    public init(
        item: FoodLogItem,
        lastUsedDate: LocalDiaryDate,
        mealSlot: MealSlot?,
        quantity: NutritionQuantity,
        nutritionSummary: NutritionSummary = .empty,
        topQuantities: [QuantityLogUsage] = []
    ) {
        self.item = item
        self.lastUsedDate = lastUsedDate
        self.mealSlot = mealSlot
        self.quantity = quantity
        self.nutritionSummary = nutritionSummary
        self.topQuantities = topQuantities
    }

    public var id: String {
        switch item {
        case .product(let product): return "product:\(product.id)"
        case .meal(let meal): return "meal:\(meal.id)"
        case .adHoc(let adHoc): return "ad_hoc:\(adHoc.name)"
        }
    }

    public var name: String { item.name }
    public var brand: String? { item.brand }

    public var submissionItem: LogSubmissionItem? {
        LogSubmissionItem(logItem: item)
    }
}

public struct RecentItemsResponse: Decodable, Equatable, Sendable {
    public let items: [RecentLogItem]

    public init(items: [RecentLogItem]) {
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([RecentLogItem].self, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}

extension RecentLogItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case item
        case lastUsedDate = "last_used_date"
        case mealSlot = "meal_slot"
        case quantity
        case nutritionSummary = "nutrition_summary"
        case topQuantities = "top_quantities"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decode(FoodLogItem.self, forKey: .item)
        lastUsedDate = try container.decodeLocalDiaryDate(forKey: .lastUsedDate)
        if let rawSlot = try container.decodeIfPresent(String.self, forKey: .mealSlot) {
            mealSlot = MealSlot(rawValue: rawSlot)
        } else {
            mealSlot = nil
        }
        quantity = try container.decode(NutritionQuantity.self, forKey: .quantity)
        nutritionSummary = try container.decodeIfPresent(
            NutritionSummary.self,
            forKey: .nutritionSummary
        ) ?? .empty
        topQuantities = try container.decodeIfPresent(
            [QuantityLogUsage].self,
            forKey: .topQuantities
        ) ?? []
    }
}

extension QuantityLogUsage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case quantity
        case logCount = "log_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quantity = try container.decode(NutritionQuantity.self, forKey: .quantity)
        logCount = try container.decode(Int.self, forKey: .logCount)
    }
}

public struct LatestSlotLogs: Equatable, Identifiable, Sendable {
    public let sourceDate: LocalDiaryDate
    public let mealSlot: MealSlot
    public let items: [FoodLog]

    public init(sourceDate: LocalDiaryDate, mealSlot: MealSlot, items: [FoodLog]) {
        self.sourceDate = sourceDate
        self.mealSlot = mealSlot
        self.items = items
    }

    public var id: String { "\(sourceDate.formatted):\(mealSlot.rawValue)" }
}

public struct LatestSlotsResponse: Decodable, Equatable, Sendable {
    public let slots: [LatestSlotLogs]

    public init(slots: [LatestSlotLogs]) {
        self.slots = slots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slots = try container.decode([LatestSlotLogs].self, forKey: .slots)
    }

    private enum CodingKeys: String, CodingKey {
        case slots
    }
}

extension LatestSlotLogs: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sourceDate = "source_date"
        case mealSlot = "meal_slot"
        case items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceDate = try container.decodeLocalDiaryDate(forKey: .sourceDate)
        let rawSlot = try container.decode(String.self, forKey: .mealSlot)
        guard let slot = MealSlot(rawValue: rawSlot) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mealSlot,
                in: container,
                debugDescription: "Unknown meal slot: \(rawSlot)"
            )
        }
        mealSlot = slot
        items = try container.decode([FoodLog].self, forKey: .items)
    }
}

public struct BatchLogResponse: Decodable, Equatable, Sendable {
    public let items: [FoodLog]

    public init(items: [FoodLog]) {
        self.items = items
    }
}

public struct LastUsedItemsRequest: Encodable, Equatable, Sendable {
    public let fromDate: LocalDiaryDate
    public let toDate: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let items: [LogSubmissionItem]

    public init(
        fromDate: LocalDiaryDate,
        toDate: LocalDiaryDate,
        mealSlot: MealSlot?,
        items: [LogSubmissionItem]
    ) {
        self.fromDate = fromDate
        self.toDate = toDate
        self.mealSlot = mealSlot
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case fromDate = "from_date"
        case toDate = "to_date"
        case mealSlot = "meal_slot"
        case items
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(fromDate, forKey: .fromDate)
        try container.encodeLocalDiaryDate(toDate, forKey: .toDate)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(items, forKey: .items)
    }
}

public struct CategorySuggestion: Codable, Equatable, Identifiable, Sendable {
    public let value: String
    public let count: Int

    public var id: String { value }

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

public struct CategorySuggestionResponse: Decodable, Equatable, Sendable {
    public let items: [CategorySuggestion]

    public init(items: [CategorySuggestion]) {
        self.items = items
    }
}

public enum BarcodeLookupOrigin: String, Decodable, Equatable, Sendable {
    case local
    case openFoodFacts = "open_food_facts"
}

public struct BarcodeLookupMeta: Decodable, Equatable, Sendable {
    public let origin: BarcodeLookupOrigin
    public let note: String?

    public init(origin: BarcodeLookupOrigin, note: String? = nil) {
        self.origin = origin
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .origin)
        switch raw {
        case "local":
            origin = .local
        case "open_food_facts":
            origin = .openFoodFacts
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .origin,
                in: container,
                debugDescription: "Unknown barcode origin: \(raw)"
            )
        }
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

public struct BarcodeLookup: Decodable, Equatable, Sendable {
    public let product: ProductDetail
    public let lookup: BarcodeLookupMeta

    public init(product: ProductDetail, lookup: BarcodeLookupMeta) {
        self.product = product
        self.lookup = lookup
    }

    public init(from decoder: Decoder) throws {
        product = try ProductDetail(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lookup = try container.decode(BarcodeLookupMeta.self, forKey: .lookup)
    }

    private enum CodingKeys: String, CodingKey {
        case lookup
    }
}
