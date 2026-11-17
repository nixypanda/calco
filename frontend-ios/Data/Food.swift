// Food search and product wire models.

import Foundation

public enum SearchScope: String, Codable, CaseIterable, Sendable {
    case all
    case history
    case custom
}

public struct ProductUnit: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public let kind: String

    public init(code: String, name: String, kind: String) {
        self.code = code
        self.name = name
        self.kind = kind
    }

    public var id: String { code }
}

public struct ProductUnitListResponse: Codable, Equatable, Sendable {
    public let items: [ProductUnit]

    public init(items: [ProductUnit]) {
        self.items = items
    }
}

public struct ProductServing: Codable, Equatable, Hashable, Sendable {
    public let unit: String
    public let gramsPerUnit: String

    public init(unit: String, gramsPerUnit: String) {
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }

    private enum CodingKeys: String, CodingKey {
        case unit
        case gramsPerUnit = "grams_per_unit"
    }
}

public struct ProductNutrient: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let amountPer100g: String
    public let unit: String
    public let source: String?
    public let confidence: String?

    public init(
        code: String,
        amountPer100g: String,
        unit: String,
        source: String? = nil,
        confidence: String? = nil
    ) {
        self.code = code
        self.amountPer100g = amountPer100g
        self.unit = unit
        self.source = source
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case amountPer100g = "amount_per_100g"
        case unit
        case source
        case confidence
    }
}

public struct ProductNutritionSummary: Codable, Equatable, Hashable, Sendable {
    public let per100g: NutritionSummary

    public init(per100g: NutritionSummary) {
        self.per100g = per100g
    }

    private enum CodingKeys: String, CodingKey {
        case per100g = "per_100g"
    }
}

public struct ProductDetail: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let source: String
    public let sourceID: String?
    public let visibility: String
    public let barcode: String?
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let defaultQuantity: String?
    public let defaultUnit: String?
    public let nutritionSummary: ProductNutritionSummary
    public let nutrients: [ProductNutrient]
    public let servings: [ProductServing]
    public let allowedUnits: [ProductUnit]

    public init(
        id: String,
        source: String,
        sourceID: String? = nil,
        visibility: String,
        barcode: String? = nil,
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        defaultQuantity: String? = nil,
        defaultUnit: String? = nil,
        nutritionSummary: ProductNutritionSummary = ProductNutritionSummary(per100g: .empty),
        nutrients: [ProductNutrient] = [],
        servings: [ProductServing] = [],
        allowedUnits: [ProductUnit] = []
    ) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.visibility = visibility
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.categories = categories
        self.defaultQuantity = defaultQuantity
        self.defaultUnit = defaultUnit
        self.nutritionSummary = nutritionSummary
        self.nutrients = nutrients
        self.servings = servings
        self.allowedUnits = allowedUnits
    }

    public var nutrientsPer100g: [NutrientAmountValue] {
        nutrients.map { nutrient in
            NutrientAmountValue(
                code: nutrient.code,
                amount: nutrient.amountPer100g,
                unit: nutrient.unit
            )
        }
    }

    public var defaultLogQuantity: NutritionQuantity {
        if let amount = defaultQuantity, let unit = defaultUnit {
            return NutritionQuantity(amount: amount, unit: unit)
        }
        if let serving = servings.first {
            return NutritionQuantity(amount: "1", unit: serving.unit)
        }
        return NutritionQuantity(amount: "100", unit: "g")
    }

    public func nutrients(for quantity: NutritionQuantity) -> [NutrientAmountValue]? {
        NutritionMath.nutrients(
            for: quantity,
            servings: servings,
            nutrients: nutrientsPer100g
        )
    }

    public func nutritionSummary(for quantity: NutritionQuantity) -> NutritionSummary? {
        guard let values = nutrients(for: quantity) else { return nil }
        return NutritionSummary.from(nutrients: values)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case sourceID = "source_id"
        case visibility
        case barcode
        case name
        case brand
        case categories
        case defaultQuantity = "default_quantity"
        case defaultUnit = "default_unit"
        case nutritionSummary = "nutrition_summary"
        case nutrients
        case servings
        case allowedUnits = "allowed_units"
    }
}

public struct FoodSearchItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let source: String
    public let sourceID: String?
    public let barcode: String?
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let nutritionSummary: ProductNutritionSummary

    public init(
        id: String,
        source: String,
        sourceID: String? = nil,
        barcode: String? = nil,
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        nutritionSummary: ProductNutritionSummary
    ) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.categories = categories
        self.nutritionSummary = nutritionSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case sourceID = "source_id"
        case barcode
        case name
        case brand
        case categories
        case nutritionSummary = "nutrition_summary"
    }
}

public struct FoodSearchResponse: Codable, Equatable, Sendable {
    public let items: [FoodSearchItem]

    public init(items: [FoodSearchItem]) {
        self.items = items
    }
}
