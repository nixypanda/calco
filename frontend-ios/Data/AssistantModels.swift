// Wire and reviewed models for server-gated AI food drafting. The assistant
// only proposes data: nothing in this file writes a catalog product or a log.

import Foundation

public struct AssistantStatus: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let supportsImages: Bool

    public init(enabled: Bool, supportsImages: Bool) {
        self.enabled = enabled
        self.supportsImages = supportsImages
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case supportsImages = "supports_images"
    }
}

public enum AssistantConversationRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public enum AssistantConversationError: Error, Equatable, Sendable {
    case empty
    case tooManyTurns
    case emptyMessage
    case messageTooLong

    public var message: String {
        switch self {
        case .empty, .emptyMessage:
            return String(localized: "assistant.error.conversationEmpty")
        case .tooManyTurns:
            return String(localized: "assistant.error.conversationFull")
        case .messageTooLong:
            return String(localized: "assistant.error.conversationTooLong")
        }
    }
}

public struct AssistantConversationTurn: Codable, Equatable, Sendable {
    public static let maximumMessageCharacters = 4_000

    public let role: AssistantConversationRole
    public let text: String

    public init(role: AssistantConversationRole, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AssistantConversationError.emptyMessage }
        guard trimmed.count <= Self.maximumMessageCharacters else {
            throw AssistantConversationError.messageTooLong
        }
        self.role = role
        self.text = trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(AssistantConversationRole.self, forKey: .role)
        let text = try container.decode(String.self, forKey: .text)
        try self.init(role: role, text: text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
    }
}

public struct AssistantConversation: Equatable, Sendable {
    public static let maximumTurns = 20

    public let turns: [AssistantConversationTurn]

    public init(turns: [AssistantConversationTurn]) throws {
        guard !turns.isEmpty else { throw AssistantConversationError.empty }
        guard turns.count <= Self.maximumTurns else {
            throw AssistantConversationError.tooManyTurns
        }
        self.turns = turns
    }
}

public struct AssistantDraftNutrient: Decodable, Equatable, Sendable {
    public let code: String
    public let amountPer100g: String

    public init(code: String, amountPer100g: String) {
        self.code = code
        self.amountPer100g = amountPer100g
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case amountPer100g = "amount_per_100g"
    }
}

public struct AssistantDraftServing: Decodable, Equatable, Sendable {
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

public struct AssistantSuggestedLog: Decodable, Equatable, Sendable {
    public let amount: String
    public let unit: String
    public let totalWeightGrams: String

    public init(amount: String, unit: String, totalWeightGrams: String) {
        self.amount = amount
        self.unit = unit
        self.totalWeightGrams = totalWeightGrams
    }

    private enum CodingKeys: String, CodingKey {
        case amount
        case unit
        case totalWeightGrams = "total_weight_grams"
    }
}

/// The draft exactly as the server serialised it. Decimal values are strings,
/// matching the web contract and avoiding binary floating-point rounding.
public struct AssistantFoodDraftPayload: Decodable, Equatable, Sendable {
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let defaultQuantity: String?
    public let defaultUnit: String?
    public let nutrients: [AssistantDraftNutrient]
    public let servings: [AssistantDraftServing]

    public init(
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        defaultQuantity: String? = nil,
        defaultUnit: String? = nil,
        nutrients: [AssistantDraftNutrient] = [],
        servings: [AssistantDraftServing] = []
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
}

public enum AssistantDraftTurn: Equatable, Sendable {
    case needsClarification(assistantMessage: String)
    case draftReady(
        assistantMessage: String,
        draft: AssistantFoodDraftPayload,
        suggestedLog: AssistantSuggestedLog?,
        warnings: [String]
    )

    public var assistantMessage: String {
        switch self {
        case .needsClarification(let message):
            return message
        case .draftReady(let message, _, _, _):
            return message
        }
    }
}

public enum AssistantDraftResponseError: Error, Equatable, Sendable {
    case invalidResponse
    case unsupportedStatus
    case missingDraft
    case unexpectedDraft
    case missingSuggestedLog
    case unexpectedSuggestedLog
}

/// The shared wire shape for every draft-ready or clarification response.
struct AssistantDraftResponseEnvelope: Decodable {
    let assistantMessage: String
    let status: String
    let draft: AssistantFoodDraftPayload?
    let suggestedLog: AssistantSuggestedLog?
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case status
        case draft
        case suggestedLog = "suggested_log"
        case warnings
    }
}

extension AssistantDraftTurn {
    /// Decodes one endpoint response and enforces the purpose-specific shape
    /// documented by the web client and backend handler.
    public static func decodeResponse(
        _ data: Data,
        purpose: AssistantDraftPurpose
    ) throws -> AssistantDraftTurn {
        let envelope: AssistantDraftResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(AssistantDraftResponseEnvelope.self, from: data)
        } catch {
            throw AssistantDraftResponseError.invalidResponse
        }
        return try decode(envelope: envelope, purpose: purpose)
    }

    static func decode(
        envelope: AssistantDraftResponseEnvelope,
        purpose: AssistantDraftPurpose
    ) throws -> AssistantDraftTurn {
        let message = envelope.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              message.count <= AssistantConversationTurn.maximumMessageCharacters else {
            throw AssistantDraftResponseError.invalidResponse
        }
        let warnings = envelope.warnings.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard warnings.count <= 20,
              warnings.allSatisfy({ $0.count <= 500 }) else {
            throw AssistantDraftResponseError.invalidResponse
        }

        switch envelope.status {
        case "needs_clarification":
            guard envelope.draft == nil else {
                throw AssistantDraftResponseError.unexpectedDraft
            }
            guard envelope.suggestedLog == nil else {
                throw AssistantDraftResponseError.unexpectedSuggestedLog
            }
            guard warnings.allSatisfy(\.isEmpty) else {
                throw AssistantDraftResponseError.invalidResponse
            }
            return .needsClarification(assistantMessage: message)
        case "draft_ready":
            guard let draft = envelope.draft else {
                throw AssistantDraftResponseError.missingDraft
            }
            switch purpose {
            case .customFood:
                guard envelope.suggestedLog == nil else {
                    throw AssistantDraftResponseError.unexpectedSuggestedLog
                }
            case .adHocLog:
                guard envelope.suggestedLog != nil else {
                    throw AssistantDraftResponseError.missingSuggestedLog
                }
            }
            return .draftReady(
                assistantMessage: message,
                draft: draft,
                suggestedLog: envelope.suggestedLog,
                warnings: warnings.filter { !$0.isEmpty }
            )
        default:
            throw AssistantDraftResponseError.unsupportedStatus
        }
    }
}

public enum AssistantDraftValidationError: Error, Equatable, Sendable {
    case invalidName
    case invalidBrand
    case invalidCategories
    case invalidNutrient
    case duplicateNutrient
    case missingCoreNutrients
    case invalidServing
    case duplicateServing
    case invalidDefaultPortion
    case missingSuggestedLog
    case invalidSuggestedLog
    case invalidBarcode

    public var message: String {
        switch self {
        case .missingCoreNutrients:
            return String(localized: "assistant.draft.missingNutrients")
        default:
            return String(localized: "assistant.draft.invalid")
        }
    }
}

/// Validated, editable-by-the-caller draft data. The purpose tells the
/// Library/ad-hoc editor whether to prefill a reusable custom food or a
/// one-off log. `nutrientsPer100g` preserves the server's decimal strings;
/// the Library editor resolves nutrient units from its catalog, as the web
/// editor does.
public struct AssistantReviewedDraft: Equatable, Sendable {
    public static let coreNutrientCodes = [
        NutrientCodes.energyKcal,
        NutrientCodes.proteinG,
        NutrientCodes.carbsG,
        NutrientCodes.fatG,
    ]

    public let purpose: AssistantDraftPurpose
    public let assistantMessage: String
    public let name: String
    public let brand: String?
    public let barcode: String?
    public let categories: [String]
    public let defaultQuantity: String?
    public let defaultUnit: String?
    public let nutrientsPer100g: [AssistantDraftNutrient]
    public let servings: [AssistantDraftServing]
    public let suggestedLog: AssistantSuggestedLog?
    public let warnings: [String]

    public init(
        purpose: AssistantDraftPurpose,
        assistantMessage: String,
        draft: AssistantFoodDraftPayload,
        suggestedLog: AssistantSuggestedLog?,
        warnings: [String],
        barcode: String? = nil
    ) throws {
        self.purpose = purpose
        self.assistantMessage = assistantMessage
        self.name = try Self.validatedName(draft.name)
        self.brand = try Self.validatedBrand(draft.brand)
        self.barcode = try Self.validatedBarcode(barcode)
        self.categories = try Self.validatedCategories(draft.categories)
        self.nutrientsPer100g = try Self.validatedNutrients(draft.nutrients)
        self.servings = try Self.validatedServings(draft.servings)
        let portion = try Self.validatedDefaultPortion(
            quantity: draft.defaultQuantity,
            unit: draft.defaultUnit,
            servings: servings
        )
        self.defaultQuantity = portion?.quantity
        self.defaultUnit = portion?.unit
        self.suggestedLog = try Self.validatedSuggestedLog(
            purpose: purpose,
            suggestedLog: suggestedLog,
            servings: servings
        )
        self.warnings = Self.validatedWarnings(warnings)
    }

    /// Per-100 g values required by the custom-food create contract.
    public var hasCoreNutrients: Bool {
        let codes = Set(nutrientsPer100g.map(\.code))
        return Self.coreNutrientCodes.allSatisfy(codes.contains)
    }

    /// Per-100 g values with units resolved from the caller's nutrient catalog.
    /// Missing units return nil rather than guessing one.
    public func per100gNutrients(
        unitsByCode: [String: String]
    ) -> [NutrientAmountValue]? {
        var values: [NutrientAmountValue] = []
        values.reserveCapacity(nutrientsPer100g.count)
        for nutrient in nutrientsPer100g {
            guard let unit = unitsByCode[nutrient.code] else { return nil }
            values.append(
                NutrientAmountValue(
                    code: nutrient.code,
                    amount: nutrient.amountPer100g,
                    unit: unit
                )
            )
        }
        return values
    }

    /// The suggested log as an editable quantity. The editor can keep the
    /// original unit; nutrient totals must still be derived from the validated
    /// total weight, not from the unit alone.
    public var suggestedLogQuantity: NutritionQuantity? {
        guard let suggestedLog else { return nil }
        return NutritionQuantity(
            amount: suggestedLog.amount,
            unit: suggestedLog.unit
        )
    }

    /// Scales the draft to the suggested log quantity for the ad-hoc endpoint.
    /// Units must come from the caller's nutrient catalog; missing units return
    /// nil rather than guessing a unit.
    public func scaledNutrientsForSuggestedLog(
        unitsByCode: [String: String]
    ) -> [NutrientAmountValue]? {
        guard let suggestedLog,
              let grams = Self.decimal(suggestedLog.totalWeightGrams),
              grams > 0 else { return nil }
        let factor = grams / 100
        var values: [NutrientAmountValue] = []
        values.reserveCapacity(nutrientsPer100g.count)
        for nutrient in nutrientsPer100g {
            guard let unit = unitsByCode[nutrient.code],
                  let amount = Self.decimal(nutrient.amountPer100g) else { return nil }
            values.append(
                NutrientAmountValue(
                    code: nutrient.code,
                    amount: Self.scaledString(amount * factor),
                    unit: unit
                )
            )
        }
        return values
    }

    /// Projection onto the app-shell handoff. `unitsByCode` is required because
    /// the assistant response intentionally contains only per-100 g amounts.
    /// For ad-hoc logs the quantity is expressed in grams using the server's
    /// validated total weight, so the handoff never loses the amount.
    public func basicHandoff(unitsByCode: [String: String]) -> AssistantFoodDraft? {
        guard let nutrients = per100gNutrients(unitsByCode: unitsByCode) else {
            return nil
        }

        let quantity: NutritionQuantity?
        switch purpose {
        case .adHocLog:
            guard let suggestedLog else { return nil }
            quantity = NutritionQuantity(amount: suggestedLog.totalWeightGrams, unit: "g")
        case .customFood:
            if let defaultQuantity, let defaultUnit {
                quantity = NutritionQuantity(amount: defaultQuantity, unit: defaultUnit)
            } else {
                quantity = nil
            }
        }
        return AssistantFoodDraft(
            purpose: purpose,
            name: name,
            brand: brand,
            barcode: barcode,
            quantity: quantity,
            nutrients: nutrients
        )
    }

    // MARK: - Validation

    private static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw AssistantDraftValidationError.invalidName }
        return name
    }

    private static func validatedBrand(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let brand = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if brand.isEmpty { return nil }
        guard brand.count <= 200 else { throw AssistantDraftValidationError.invalidBrand }
        return brand
    }

    private static func validatedBarcode(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard case .success(let barcode) = BarcodeValidation.validated(raw) else {
            throw AssistantDraftValidationError.invalidBarcode
        }
        return barcode
    }

    private static func validatedCategories(_ raw: [String]) throws -> [String] {
        guard raw.count <= 20 else { throw AssistantDraftValidationError.invalidCategories }
        var categories: [String] = []
        for category in raw {
            let value = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { continue }
            guard value.count <= 200 else { throw AssistantDraftValidationError.invalidCategories }
            if !categories.contains(value) {
                categories.append(value)
            }
        }
        return categories
    }

    private static func validatedNutrients(
        _ raw: [AssistantDraftNutrient]
    ) throws -> [AssistantDraftNutrient] {
        guard raw.count <= 100 else { throw AssistantDraftValidationError.invalidNutrient }
        var codes = Set<String>()
        var nutrients: [AssistantDraftNutrient] = []
        for nutrient in raw {
            let code = nutrient.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, code.count <= 100 else {
                throw AssistantDraftValidationError.invalidNutrient
            }
            guard codes.insert(code).inserted else {
                throw AssistantDraftValidationError.duplicateNutrient
            }
            let amount = nutrient.amountPer100g.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = decimal(amount), value >= 0 else {
                throw AssistantDraftValidationError.invalidNutrient
            }
            nutrients.append(AssistantDraftNutrient(code: code, amountPer100g: amount))
        }
        guard coreNutrientCodes.allSatisfy(codes.contains) else {
            throw AssistantDraftValidationError.missingCoreNutrients
        }
        return nutrients
    }

    private static func validatedServings(
        _ raw: [AssistantDraftServing]
    ) throws -> [AssistantDraftServing] {
        guard raw.count <= 20 else { throw AssistantDraftValidationError.invalidServing }
        var units = Set<String>()
        var servings: [AssistantDraftServing] = []
        for serving in raw {
            let unit = serving.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unit.isEmpty, unit.count <= 100 else {
                throw AssistantDraftValidationError.invalidServing
            }
            guard units.insert(unit).inserted else {
                throw AssistantDraftValidationError.duplicateServing
            }
            let grams = serving.gramsPerUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = decimal(grams), value > 0, value <= 100_000 else {
                throw AssistantDraftValidationError.invalidServing
            }
            servings.append(AssistantDraftServing(unit: unit, gramsPerUnit: grams))
        }
        return servings
    }

    private static func validatedDefaultPortion(
        quantity: String?,
        unit: String?,
        servings: [AssistantDraftServing]
    ) throws -> (quantity: String, unit: String)? {
        switch (quantity, unit) {
        case (nil, nil):
            return nil
        case let (quantity?, unit?):
            let quantityValue = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            let unitValue = unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = decimal(quantityValue), value > 0, value <= 100_000,
                  !unitValue.isEmpty, unitValue.count <= 100 else {
                throw AssistantDraftValidationError.invalidDefaultPortion
            }
            guard unitValue == "g" || servings.contains(where: { $0.unit == unitValue }) else {
                throw AssistantDraftValidationError.invalidDefaultPortion
            }
            return (quantityValue, unitValue)
        default:
            throw AssistantDraftValidationError.invalidDefaultPortion
        }
    }

    private static func validatedSuggestedLog(
        purpose: AssistantDraftPurpose,
        suggestedLog: AssistantSuggestedLog?,
        servings: [AssistantDraftServing]
    ) throws -> AssistantSuggestedLog? {
        guard purpose == .adHocLog else { return nil }
        guard let suggestedLog else { throw AssistantDraftValidationError.missingSuggestedLog }

        let amountText = suggestedLog.amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = suggestedLog.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalText = suggestedLog.totalWeightGrams
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = decimal(amountText), amount > 0, amount <= 100_000,
              !unit.isEmpty, unit.count <= 100,
              let total = decimal(totalText), total > 0, total <= 100_000 else {
            throw AssistantDraftValidationError.invalidSuggestedLog
        }

        let expected: Decimal
        if unit == "g" {
            expected = amount
        } else if let serving = servings.first(where: { $0.unit == unit }),
                  let gramsPerUnit = decimal(serving.gramsPerUnit) {
            expected = amount * gramsPerUnit
        } else {
            throw AssistantDraftValidationError.invalidSuggestedLog
        }
        guard rounded6(expected) == rounded6(total) else {
            throw AssistantDraftValidationError.invalidSuggestedLog
        }
        return AssistantSuggestedLog(
            amount: amountText,
            unit: unit,
            totalWeightGrams: totalText
        )
    }

    private static func validatedWarnings(_ raw: [String]) -> [String] {
        raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 500 }
            .prefix(20)
            .map { $0 }
    }

    private static func decimal(_ raw: String) -> Decimal? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func rounded6(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 6, .plain)
        return result
    }

    private static func scaledString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: rounded6(value)).stringValue
    }
}

public enum AssistantServiceError: Error, Equatable, Sendable {
    case disabled
    case rateLimited(retryAfterSeconds: Int?)
    case invalidInput(String)
    case providerUnavailable
    case sessionExpired
    case networkUnavailable
    case timedOut
    case server(String)
    case invalidResponse
    case cancelled

    public var message: String {
        switch self {
        case .disabled:
            return String(localized: "assistant.status.disabled.message")
        case .rateLimited(let seconds):
            if let seconds {
                return String(
                    format: String(localized: "assistant.error.rateLimited"),
                    seconds
                )
            }
            return String(localized: "assistant.error.rateLimitedShort")
        case .invalidInput:
            return String(localized: "assistant.error.invalid")
        case .providerUnavailable:
            return String(localized: "assistant.error.provider")
        case .sessionExpired:
            return String(localized: "foodDetail.error.sessionExpired")
        case .networkUnavailable:
            return String(localized: "assistant.error.network")
        case .timedOut:
            return String(localized: "assistant.error.timeout")
        case .server:
            return String(localized: "assistant.error.server")
        case .invalidResponse:
            return String(localized: "assistant.error.generic")
        case .cancelled:
            return ""
        }
    }

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
