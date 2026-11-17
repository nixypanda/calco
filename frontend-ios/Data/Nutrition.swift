// Nutrient and quantity wire models with display math.

import Foundation

public enum NutrientCodes {
    public static let energyKcal = "ENERGY_KCAL"
    public static let proteinG = "PROTEIN_G"
    public static let carbsG = "CARBS_G"
    public static let fatG = "FAT_G"
    public static let fiberG = "FIBER_G"
}

public struct NutrientAmountValue: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let amount: String
    public let unit: String

    public init(code: String, amount: String, unit: String) {
        self.code = code
        self.amount = amount
        self.unit = unit
    }

    public var amountValue: Double {
        NutritionMath.safeAmount(amount)
    }
}

public struct NutritionSummary: Codable, Equatable, Hashable, Sendable {
    public let energyKcal: String?
    public let proteinG: String?
    public let carbsG: String?
    public let fatG: String?
    public let fiberG: String?

    public init(
        energyKcal: String? = nil,
        proteinG: String? = nil,
        carbsG: String? = nil,
        fatG: String? = nil,
        fiberG: String? = nil
    ) {
        self.energyKcal = energyKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
    }

    public static let empty = NutritionSummary()

    public var energyKcalValue: Double {
        NutritionMath.safeAmount(energyKcal)
    }

    public var proteinGValue: Double {
        NutritionMath.safeAmount(proteinG)
    }

    public var carbsGValue: Double {
        NutritionMath.safeAmount(carbsG)
    }

    public var fatGValue: Double {
        NutritionMath.safeAmount(fatG)
    }

    public var fiberGValue: Double {
        NutritionMath.safeAmount(fiberG)
    }

    public var isEmpty: Bool {
        energyKcal == nil
            && proteinG == nil
            && carbsG == nil
            && fatG == nil
            && fiberG == nil
    }

    public func amount(for code: String) -> String? {
        switch code {
        case NutrientCodes.energyKcal: return energyKcal
        case NutrientCodes.proteinG: return proteinG
        case NutrientCodes.carbsG: return carbsG
        case NutrientCodes.fatG: return fatG
        case NutrientCodes.fiberG: return fiberG
        default: return nil
        }
    }

    public static func from(nutrients: [NutrientAmountValue]) -> NutritionSummary {
        let byCode = Dictionary(
            nutrients.map { ($0.code, $0.amount) },
            uniquingKeysWith: { first, _ in first }
        )
        return NutritionSummary(
            energyKcal: byCode[NutrientCodes.energyKcal],
            proteinG: byCode[NutrientCodes.proteinG],
            carbsG: byCode[NutrientCodes.carbsG],
            fatG: byCode[NutrientCodes.fatG],
            fiberG: byCode[NutrientCodes.fiberG]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case energyKcal = "energy_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case fiberG = "fiber_g"
    }
}

public struct NutritionQuantity: Codable, Equatable, Hashable, Sendable {
    public let amount: String
    public let unit: String

    public init(amount: String, unit: String) {
        self.amount = amount
        self.unit = unit
    }

    public var amountValue: Double {
        NutritionMath.safeAmount(amount)
    }

    public var described: String {
        "\(amount) \(unit)"
    }
}

public enum NutritionMath {
    public static func safeAmount(_ raw: String) -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return max(0, value)
    }

    public static func safeAmount(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        return safeAmount(raw)
    }

    public static func positiveAmount(_ raw: String) -> Double? {
        let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return value > 0 ? value : nil
    }

    public static func servingGrams(
        quantity: NutritionQuantity,
        servings: [ProductServing]
    ) -> Double? {
        guard let amount = positiveAmount(quantity.amount) else { return nil }
        if quantity.unit == "g" {
            return amount
        }
        guard let serving = servings.first(where: { $0.unit == quantity.unit }),
              let gramsPerUnit = positiveAmount(serving.gramsPerUnit) else {
            return nil
        }
        return amount * gramsPerUnit
    }

    public static func scalePer100g(
        grams: Double,
        nutrients: [NutrientAmountValue]
    ) -> [NutrientAmountValue] {
        let factor = grams / 100
        return nutrients.map { nutrient in
            NutrientAmountValue(
                code: nutrient.code,
                amount: String(NutritionMath.safeAmount(nutrient.amount) * factor),
                unit: nutrient.unit
            )
        }
    }

    public static func nutrients(
        for quantity: NutritionQuantity,
        servings: [ProductServing],
        nutrients: [NutrientAmountValue]
    ) -> [NutrientAmountValue]? {
        guard let grams = servingGrams(quantity: quantity, servings: servings) else {
            return nil
        }
        return scalePer100g(grams: grams, nutrients: nutrients)
    }

    public static func scaledSnapshot(
        savedQuantity: NutritionQuantity,
        currentQuantity: NutritionQuantity,
        nutrients: [NutrientAmountValue]
    ) -> [NutrientAmountValue]? {
        guard savedQuantity.unit == currentQuantity.unit,
              let savedAmount = positiveAmount(savedQuantity.amount),
              let currentAmount = positiveAmount(currentQuantity.amount) else {
            return nil
        }
        let factor = currentAmount / savedAmount
        return nutrients.map { nutrient in
            NutrientAmountValue(
                code: nutrient.code,
                amount: String(NutritionMath.safeAmount(nutrient.amount) * factor),
                unit: nutrient.unit
            )
        }
    }
}
