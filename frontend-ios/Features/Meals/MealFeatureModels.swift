// Feature states, validation, and display helpers shared by the Meals screens.

import Foundation

public enum MealsListLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded([Meal])
    case failed(String)

    public var meals: [Meal] {
        guard case .loaded(let meals) = self else { return [] }
        return meals
    }
}

public enum MealDetailLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(message: String, missingComponents: Bool)
}

public enum MealPortionPreviewState: Equatable, Sendable {
    case idle
    case loading
    case loaded(MealNutritionResponse)
    case unavailable(String)
    case failed(String)
}

public enum MealDeleteState: Equatable, Sendable {
    case idle
    case deleting
    case failed(String)
    case deleted
}

public enum MealLogState: Equatable, Sendable {
    case idle
    case submitting
    case succeeded(logID: String?)
    case failed(String)
}

public enum MealQuickAddState: Equatable, Sendable {
    case idle
    case submitting(mealID: String)
    case added(mealID: String)
    case failed(String)
}

public enum MealEditorMode: Equatable, Sendable {
    case create
    case edit(id: String)

    public var mealID: String? {
        guard case .edit(let id) = self else { return nil }
        return id
    }
}

public enum MealEditorLoadState: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

public enum MealEditorSaveState: Equatable, Sendable {
    case idle
    case saving
    case failed(String)
    case saved
}

public enum MealComponentSearchState: Equatable, Sendable {
    case idle
    case loading
    case results([MealProduct])
    case empty
    case failed(String)
}

public struct MealComponentRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public var productID: String
    public var productName: String?
    public var query: String
    public var amount: String
    public var unit: String
    public var searchState: MealComponentSearchState
    public var isMissing: Bool
    public var isResolvingName: Bool

    public init(
        id: Int,
        productID: String = "",
        productName: String? = nil,
        query: String = "",
        amount: String = "100",
        unit: String = "g",
        searchState: MealComponentSearchState = .idle,
        isMissing: Bool = false,
        isResolvingName: Bool = false
    ) {
        self.id = id
        self.productID = productID
        self.productName = productName
        self.query = query
        self.amount = amount
        self.unit = unit
        self.searchState = searchState
        self.isMissing = isMissing
        self.isResolvingName = isResolvingName
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasSelection: Bool {
        !productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var displayName: String {
        if isMissing {
            return String(localized: "meals.editor.missingFood")
        }
        if let productName, !productName.isEmpty {
            return productName
        }
        if isResolvingName {
            return String(localized: "meals.editor.loadingFood")
        }
        return String(localized: "meals.editor.unknownFood")
    }
}

public enum MealEditorValidationError: Equatable, Sendable {
    case nameRequired
    case componentsRequired
    case componentUnselected
    case componentMissing
    case quantityInvalid
    case unitRequired
    case totalQuantityInvalid

    public var message: String {
        switch self {
        case .nameRequired:
            return String(localized: "meals.editor.error.nameRequired")
        case .componentsRequired:
            return String(localized: "meals.editor.error.componentRequired")
        case .componentUnselected:
            return String(localized: "meals.editor.error.componentUnselected")
        case .componentMissing:
            return String(localized: "meals.editor.error.componentMissing")
        case .quantityInvalid:
            return String(localized: "meals.editor.error.quantityInvalid")
        case .unitRequired:
            return String(localized: "meals.editor.error.unitRequired")
        case .totalQuantityInvalid:
            return String(localized: "meals.editor.error.totalInvalid")
        }
    }
}

public enum MealNutrientDisplay {
    public static func label(for code: String) -> String {
        switch code {
        case NutrientCodes.energyKcal:
            return String(localized: "meals.nutrient.energy")
        case NutrientCodes.proteinG:
            return String(localized: "meals.nutrient.protein")
        case NutrientCodes.carbsG:
            return String(localized: "meals.nutrient.carbs")
        case NutrientCodes.fatG:
            return String(localized: "meals.nutrient.fat")
        case NutrientCodes.fiberG:
            return String(localized: "meals.nutrient.fiber")
        default:
            return code
        }
    }

    public static func value(_ nutrient: NutrientAmountValue) -> String {
        "\(DisplayNumberFormat.decimal(nutrient.amount, fixed: true)) \(nutrient.unit)"
    }

    public static func kcal(_ summary: NutritionSummary?) -> String? {
        guard let amount = summary?.energyKcal,
              let value = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return String(format: String(localized: "meals.value.kcal"), Int(value.rounded()))
    }

    public static func quantity(_ quantity: NutritionQuantity?) -> String? {
        guard let quantity else { return nil }
        let amount = quantity.amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = quantity.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !amount.isEmpty, !unit.isEmpty else { return nil }
        return "\(DisplayNumberFormat.decimal(amount)) \(unit)"
    }
}
