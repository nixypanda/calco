// Shared value types used by the assistant and barcode reviewed-draft seams.

import Foundation

public enum AssistantDraftPurpose: String, Codable, Equatable, Sendable {
    case customFood = "custom_food"
    case adHocLog = "ad_hoc_log"
}

/// Editable draft data handed back from barcode or assistant review. Nothing is
/// written until a later screen explicitly saves or logs it.
public struct AssistantFoodDraft: Equatable, Sendable {
    public let purpose: AssistantDraftPurpose
    public let name: String
    public let brand: String?
    public let barcode: String?
    public let quantity: NutritionQuantity?
    public let nutrients: [NutrientAmountValue]

    public init(
        purpose: AssistantDraftPurpose,
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        quantity: NutritionQuantity? = nil,
        nutrients: [NutrientAmountValue] = []
    ) {
        self.purpose = purpose
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.quantity = quantity
        self.nutrients = nutrients
    }
}
