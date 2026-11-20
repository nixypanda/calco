// Custom-food catalog wire models and validated write requests.
//
// The backend serializes decimals as JSON strings on reads but accepts either
// strings or numbers on writes. All request amounts are rounded to six decimal
// places here to match the catalog's stored nutrient scale.

import Foundation

// MARK: - Shared decimal input

public enum CatalogDecimal {
    /// Parses non-negative decimal text. A single comma is accepted as the
    /// decimal separator because some regions expose it on the decimal keypad.
    public static func parseNonNegative(_ raw: String) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains(",") {
            guard !text.contains("."), text.filter({ $0 == "," }).count == 1 else {
                return nil
            }
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        guard text.filter({ $0 == "." }).count <= 1,
              text.contains(where: { $0.isASCII && $0.isNumber }),
              text.allSatisfy({ $0 == "." || ($0.isASCII && $0.isNumber) }),
              let value = Decimal(
                string: text,
                locale: Locale(identifier: "en_US_POSIX")
              )
        else { return nil }
        return value
    }

    public static func round(_ value: Decimal, scale: Int = 6) -> Decimal {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, scale, .plain)
        return rounded
    }

    /// Canonical text for comparison and persistence. Six fractional digits
    /// retain the catalog's nutrient resolution without depending on the scale
    /// of the incoming decimal.
    public static func canonical(_ value: Decimal, scale: Int = 6) -> String {
        NSDecimalNumber(decimal: round(value, scale: scale)).stringValue
    }

    public static func canonical(_ value: Decimal?, scale: Int = 6) -> String? {
        value.map { canonical($0, scale: scale) }
    }
}
public enum CustomFoodNutrientCodes {
    /// Required by the catalog for every custom food, in display order.
    public static let required = [
        NutrientCodes.energyKcal,
        NutrientCodes.proteinG,
        NutrientCodes.carbsG,
        NutrientCodes.fatG,
    ]
}

// MARK: - Definitions

public struct NutrientDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public let unit: String
    public let category: String

    public var id: String { code }

    public init(code: String, name: String, unit: String, category: String) {
        self.code = code
        self.name = name
        self.unit = unit
        self.category = category
    }
}

public struct NutrientDefinitionListResponse: Decodable, Equatable, Sendable {
    public let items: [NutrientDefinition]

    public init(items: [NutrientDefinition]) {
        self.items = items
    }
}

// MARK: - Managed food

public struct CustomFoodNutrient: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let code: String
    public let amountPer100g: String
    public let unit: String

    public var id: String { code }

    public init(code: String, amountPer100g: String, unit: String) {
        self.code = code
        self.amountPer100g = amountPer100g
        self.unit = unit
    }

    public init(_ productNutrient: ProductNutrient) {
        self.init(
            code: productNutrient.code,
            amountPer100g: productNutrient.amountPer100g,
            unit: productNutrient.unit
        )
    }

    public var amountValue: Double {
        NutritionMath.safeAmount(amountPer100g)
    }
}

public struct CustomFoodServing: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let unit: String
    public let gramsPerUnit: String

    public var id: String { unit }

    public init(unit: String, gramsPerUnit: String) {
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }

    public init(_ productServing: ProductServing) {
        self.init(unit: productServing.unit, gramsPerUnit: productServing.gramsPerUnit)
    }

    public var gramsValue: Double {
        NutritionMath.safeAmount(gramsPerUnit)
    }
}

public struct CustomFood: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let defaultQuantity: String?
    public let defaultUnit: String?
    public let nutrients: [CustomFoodNutrient]
    public let servings: [CustomFoodServing]
    public let allowedUnits: [ProductUnit]

    public init(
        id: String,
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        defaultQuantity: String? = nil,
        defaultUnit: String? = nil,
        nutrients: [CustomFoodNutrient] = [],
        servings: [CustomFoodServing] = [],
        allowedUnits: [ProductUnit] = []
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.categories = categories
        self.defaultQuantity = defaultQuantity
        self.defaultUnit = defaultUnit
        self.nutrients = nutrients
        self.servings = servings
        self.allowedUnits = allowedUnits
    }

    public init(product: ProductDetail) {
        self.init(
            id: product.id,
            name: product.name,
            brand: product.brand,
            categories: product.categories,
            defaultQuantity: product.defaultQuantity,
            defaultUnit: product.defaultUnit,
            nutrients: product.nutrients.map(CustomFoodNutrient.init),
            servings: product.servings.map(CustomFoodServing.init),
            allowedUnits: product.allowedUnits
        )
    }

    public var nutrientsPer100g: [NutrientAmountValue] {
        nutrients.map {
            NutrientAmountValue(code: $0.code, amount: $0.amountPer100g, unit: $0.unit)
        }
    }

    public var energyKcalValue: Double {
        nutrients.first { $0.code == NutrientCodes.energyKcal }?.amountValue ?? 0
    }

    public var proteinGValue: Double {
        nutrients.first { $0.code == NutrientCodes.proteinG }?.amountValue ?? 0
    }

    public var carbsGValue: Double {
        nutrients.first { $0.code == NutrientCodes.carbsG }?.amountValue ?? 0
    }

    public var fatGValue: Double {
        nutrients.first { $0.code == NutrientCodes.fatG }?.amountValue ?? 0
    }
}

public struct CustomFoodListResponse: Decodable, Equatable, Sendable {
    public let items: [ProductDetail]

    public init(items: [ProductDetail]) {
        self.items = items
    }
}

public struct CustomFoodIDResponse: Decodable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: - Write request

public struct CustomFoodNutrientWrite: Codable, Equatable, Sendable {
    public let code: String
    public let amountPer100g: Decimal

    public init(code: String, amountPer100g: Decimal) {
        self.code = code
        self.amountPer100g = CatalogDecimal.round(amountPer100g)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case amountPer100g = "amount_per_100g"
    }
}

public struct CustomFoodServingWrite: Codable, Equatable, Sendable {
    public let unit: String
    public let gramsPerUnit: Decimal

    public init(unit: String, gramsPerUnit: Decimal) {
        self.unit = unit
        self.gramsPerUnit = CatalogDecimal.round(gramsPerUnit)
    }

    private enum CodingKeys: String, CodingKey {
        case unit
        case gramsPerUnit = "grams_per_unit"
    }
}

/// Full aggregate replacement body accepted by `POST /api/foods/custom` and
/// `PUT /api/foods/custom/{id}`. Creation may omit servings and a default
/// portion; editing supports both.
public struct CustomFoodWriteRequest: Codable, Equatable, Sendable {
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let defaultQuantity: Decimal?
    public let defaultUnit: String?
    public let nutrients: [CustomFoodNutrientWrite]
    public let servings: [CustomFoodServingWrite]

    public init(
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        defaultQuantity: Decimal? = nil,
        defaultUnit: String? = nil,
        nutrients: [CustomFoodNutrientWrite] = [],
        servings: [CustomFoodServingWrite] = []
    ) {
        self.name = name
        self.brand = brand
        self.categories = categories
        self.defaultQuantity = defaultQuantity
        self.defaultUnit = defaultUnit
        self.nutrients = nutrients
        self.servings = servings
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case brand
        case categories
        case defaultQuantity = "default_quantity"
        case defaultUnit = "default_unit"
        case nutrients
        case servings
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encode(categories, forKey: .categories)
        try container.encodeIfPresent(defaultQuantity, forKey: .defaultQuantity)
        try container.encodeIfPresent(defaultUnit, forKey: .defaultUnit)
        try container.encode(nutrients, forKey: .nutrients)
        try container.encode(servings, forKey: .servings)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        defaultQuantity = try container.decodeIfPresent(Decimal.self, forKey: .defaultQuantity)
        defaultUnit = try container.decodeIfPresent(String.self, forKey: .defaultUnit)
        nutrients = try container.decodeIfPresent(
            [CustomFoodNutrientWrite].self,
            forKey: .nutrients
        ) ?? []
        servings = try container.decodeIfPresent(
            [CustomFoodServingWrite].self,
            forKey: .servings
        ) ?? []
    }
}
