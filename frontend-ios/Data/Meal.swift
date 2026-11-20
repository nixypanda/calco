// Meal wire models for GET/POST/PUT /api/meals and GET /api/meals/{id}/nutrients.
//
// Contract notes (backend `journal/meal/api/http.rs`):
// - Decimal amounts are JSON strings in responses (for example "250.5"), and
//   requests accept decimal strings.
// - `notes` and `total_quantity` are nullable, including on update. Sending an
//   explicit null clears the stored value; omitting them would leave it alone.
// - Components are products only. The backend rejects any other `item.type`.
// - A meal always has a non-empty name and at least one component.

import Foundation

public struct MealComponent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let item: ItemReference
    public let quantity: NutritionQuantity
    public let nutritionSummary: NutritionSummary?
    /// Present on a degraded meal when the referenced product no longer exists.
    public let missing: Bool
    public let missingReason: String?
    /// Server-provided display label for a missing component ("Unavailable food").
    public let name: String?

    public init(
        id: String,
        item: ItemReference,
        quantity: NutritionQuantity,
        nutritionSummary: NutritionSummary? = nil,
        missing: Bool = false,
        missingReason: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.item = item
        self.quantity = quantity
        self.nutritionSummary = nutritionSummary
        self.missing = missing
        self.missingReason = missingReason
        self.name = name
    }

    public var productID: String? {
        guard item.itemType == .product else { return nil }
        return item.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case item
        case quantity
        case nutritionSummary = "nutrition_summary"
        case missing
        case missingReason = "missing_reason"
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        item = try container.decode(ItemReference.self, forKey: .item)
        quantity = try container.decode(NutritionQuantity.self, forKey: .quantity)
        nutritionSummary = try container.decodeIfPresent(
            NutritionSummary.self,
            forKey: .nutritionSummary
        )
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
        missingReason = try container.decodeIfPresent(String.self, forKey: .missingReason)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}

public struct Meal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let notes: String?
    public let totalQuantity: NutritionQuantity?
    public let nutritionSummary: NutritionSummary?
    public let components: [MealComponent]
    /// True when the server returned a degraded meal because at least one
    /// referenced product is unavailable. Healthy responses omit the field.
    public let hasMissingComponents: Bool
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        name: String,
        notes: String? = nil,
        totalQuantity: NutritionQuantity? = nil,
        nutritionSummary: NutritionSummary? = nil,
        components: [MealComponent] = [],
        hasMissingComponents: Bool = false,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.totalQuantity = totalQuantity
        self.nutritionSummary = nutritionSummary
        self.components = components
        self.hasMissingComponents = hasMissingComponents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isDegraded: Bool {
        hasMissingComponents || components.contains(where: \.missing)
    }

    public var trimmedNotes: String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Default portion for quick-add and detail preview.
    ///
    /// Meal nutrient calculation converts the requested portion to grams via the
    /// unit converter. Only registered mass units are guaranteed to work, so a
    /// non-mass total falls back to a valid 100 g portion instead of surfacing a
    /// server error. The declared total is otherwise used as the default.
    public var defaultPortion: NutritionQuantity {
        if let totalQuantity,
           MealQuantityRules.isMassUnit(totalQuantity.unit),
           MealQuantityRules.normalizedPositiveDecimal(totalQuantity.amount) != nil {
            return totalQuantity
        }
        return NutritionQuantity(amount: "100", unit: "g")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case notes
        case totalQuantity = "total_quantity"
        case nutritionSummary = "nutrition_summary"
        case components
        case hasMissingComponents = "has_missing_components"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        totalQuantity = try container.decodeIfPresent(
            NutritionQuantity.self,
            forKey: .totalQuantity
        )
        nutritionSummary = try container.decodeIfPresent(
            NutritionSummary.self,
            forKey: .nutritionSummary
        )
        components = try container.decode([MealComponent].self, forKey: .components)
        hasMissingComponents = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasMissingComponents
        ) ?? false
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }
}

public struct MealListResponse: Codable, Equatable, Sendable {
    public let items: [Meal]

    public init(items: [Meal]) {
        self.items = items
    }
}

public struct MealNutritionResponse: Codable, Equatable, Sendable {
    public let mealID: String
    public let quantity: NutritionQuantity
    public let nutritionSummary: NutritionSummary
    public let nutrients: [NutrientAmountValue]

    public init(
        mealID: String,
        quantity: NutritionQuantity,
        nutritionSummary: NutritionSummary,
        nutrients: [NutrientAmountValue]
    ) {
        self.mealID = mealID
        self.quantity = quantity
        self.nutritionSummary = nutritionSummary
        self.nutrients = nutrients
    }

    private enum CodingKeys: String, CodingKey {
        case mealID = "meal_id"
        case quantity
        case nutritionSummary = "nutrition_summary"
        case nutrients
    }
}

public struct MealComponentWriteRequest: Codable, Equatable, Sendable {
    public let item: ItemReference
    public let quantity: NutritionQuantity

    public init(item: ItemReference, quantity: NutritionQuantity) {
        self.item = item
        self.quantity = quantity
    }

    public init(productID: String, quantity: NutritionQuantity) {
        self.init(
            item: ItemReference(itemType: .product, id: productID),
            quantity: quantity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case item
        case quantity
    }
}

public struct MealWriteRequest: Codable, Equatable, Sendable {
    public let name: String
    public let notes: String?
    public let totalQuantity: NutritionQuantity?
    public let components: [MealComponentWriteRequest]

    public init(
        name: String,
        notes: String? = nil,
        totalQuantity: NutritionQuantity? = nil,
        components: [MealComponentWriteRequest]
    ) {
        self.name = name
        self.notes = notes
        self.totalQuantity = totalQuantity
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case notes
        case totalQuantity = "total_quantity"
        case components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        totalQuantity = try container.decodeIfPresent(
            NutritionQuantity.self,
            forKey: .totalQuantity
        )
        components = try container.decode(
            [MealComponentWriteRequest].self,
            forKey: .components
        )
    }

    /// Full replacement of the editable fields. Explicit nulls are significant
    /// for PUT: they clear notes/total_quantity instead of preserving them.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let notes {
            try container.encode(notes, forKey: .notes)
        } else {
            try container.encodeNil(forKey: .notes)
        }
        if let totalQuantity {
            try container.encode(totalQuantity, forKey: .totalQuantity)
        } else {
            try container.encodeNil(forKey: .totalQuantity)
        }
        try container.encode(components, forKey: .components)
    }
}

public enum MealQuantityRules {
    /// Units the backend's meal calculation can convert to grams for portions.
    public static let massUnitCodes: Set<String> = ["g", "kg", "mg", "ug"]

    public static func isMassUnit(_ code: String) -> Bool {
        massUnitCodes.contains(code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Returns a backend-safe decimal string, or nil when the value is not a
    /// finite positive plain decimal. Scientific notation, signs, comma
    /// decimals, zero, and negatives are rejected before a request is built.
    public static func normalizedPositiveDecimal(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        let pattern = #"^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        var normalized = trimmed
        if normalized.hasPrefix(".") {
            normalized = "0" + normalized
        }
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value > 0 else {
            return nil
        }
        return normalized
    }

    public static func massUnits(from units: [ProductUnit]) -> [ProductUnit] {
        let mass = units.filter { $0.kind == "mass" || isMassUnit($0.code) }
        return mass.isEmpty ? [ProductUnit(code: "g", name: "Gram", kind: "mass")] : mass
    }

    /// Units used by the editor. The server list is preferred, with a safe gram
    /// fallback so a failed unit fetch cannot create a blank picker.
    public static func editorUnits(from units: [ProductUnit]) -> [ProductUnit] {
        units.isEmpty ? [ProductUnit(code: "g", name: "Gram", kind: "mass")] : units
    }

    /// Preserve an existing meal unit that the current server unit list does not
    /// contain, so editing does not silently rewrite the value.
    public static func merging(_ unit: String?, into units: [ProductUnit]) -> [ProductUnit] {
        guard let unit else { return units }
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !units.contains(where: { $0.code == trimmed }) else {
            return units
        }
        return units + [ProductUnit(code: trimmed, name: trimmed, kind: "")]
    }
}
