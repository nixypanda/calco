// Shared validated nutrient editor and Library form validation.
//
// "Optional versus zero": an empty optional row is omitted from the request.
// An entered 0 is a known zero and is sent. Required rows must be present but
// may be zero, matching the backend's validation.

import Foundation

public enum NutrientEditorValidationError: Error, Equatable, Sendable {
    case missingRequired([String])
    case invalidAmount(code: String)
    case unknownNutrient(code: String)
    case duplicateNutrient(code: String)
}

public struct NutrientEditorRow: Identifiable, Equatable, Sendable {
    public let code: String
    public let name: String
    public let unit: String
    public let isRequired: Bool
    public var amount: String

    public var id: String { code }

    public init(
        code: String,
        name: String,
        unit: String,
        isRequired: Bool,
        amount: String = ""
    ) {
        self.code = code
        self.name = name
        self.unit = unit
        self.isRequired = isRequired
        self.amount = amount
    }
}

/// Reusable per-amount nutrient editor state. The custom-food editor labels
/// rows "per 100 g"; the ad-hoc screen labels them as totals for the entered
/// quantity. Both use the same parsing, units, required checks, and
/// optional-versus-zero behavior.
public struct NutrientEditorState: Equatable, Sendable {
    public private(set) var rows: [NutrientEditorRow]
    public let definitions: [NutrientDefinition]
    public let requiredCodes: [String]

    private let definitionsByCode: [String: NutrientDefinition]
    private let requiredUnits: [String: String]

    public init(
        definitions: [NutrientDefinition],
        initial: [NutrientAmountValue] = [],
        requiredCodes: [String] = CustomFoodNutrientCodes.required
    ) {
        self.definitions = definitions
        self.requiredCodes = requiredCodes
        self.definitionsByCode = Dictionary(
            definitions.map { ($0.code, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.requiredUnits = [
            NutrientCodes.energyKcal: "kcal",
            NutrientCodes.proteinG: "g",
            NutrientCodes.carbsG: "g",
            NutrientCodes.fatG: "g",
            NutrientCodes.fiberG: "g",
        ]

        let initialByCode = Dictionary(
            initial.map { ($0.code, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [NutrientEditorRow] = []
        var seen = Set<String>()

        for code in requiredCodes where !seen.contains(code) {
            let definition = definitionsByCode[code]
            // A missing definition must not let a malformed initial unit
            // override the canonical unit for a required nutrient.
            let fallbackUnit = requiredUnits[code]
                ?? initialByCode[code]?.unit
                ?? ""
            rows.append(
                NutrientEditorRow(
                    code: code,
                    name: definition?.name ?? code,
                    unit: definition?.unit ?? fallbackUnit,
                    isRequired: true,
                    amount: initialByCode[code]?.amount ?? ""
                )
            )
            seen.insert(code)
        }

        for definition in definitions where !seen.contains(definition.code) {
            guard let value = initialByCode[definition.code] else { continue }
            rows.append(
                NutrientEditorRow(
                    code: definition.code,
                    name: definition.name,
                    unit: definition.unit,
                    isRequired: false,
                    amount: value.amount
                )
            )
            seen.insert(definition.code)
        }

        // Preserve an unknown initial nutrient visibly instead of silently
        // dropping data. Validation blocks saving until the user removes it.
        for value in initial where !seen.contains(value.code) {
            rows.append(
                NutrientEditorRow(
                    code: value.code,
                    name: value.code,
                    unit: value.unit,
                    isRequired: false,
                    amount: value.amount
                )
            )
            seen.insert(value.code)
        }

        self.rows = rows
    }

    public var availableOptionalDefinitions: [NutrientDefinition] {
        let used = Set(rows.map(\.code))
        return definitions
            .filter { !used.contains($0.code) }
            .sorted {
                if $0.category != $1.category { return $0.category < $1.category }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    public func displayName(for code: String) -> String {
        definitionsByCode[code]?.name ?? rows.first(where: { $0.code == code })?.name ?? code
    }

    public func unit(for code: String) -> String {
        definitionsByCode[code]?.unit ?? rows.first(where: { $0.code == code })?.unit ?? ""
    }

    public func amount(for code: String) -> String {
        rows.first(where: { $0.code == code })?.amount ?? ""
    }

    public mutating func setAmount(_ amount: String, for code: String) {
        guard let index = rows.firstIndex(where: { $0.code == code }) else { return }
        rows[index].amount = amount
    }

    @discardableResult
    public mutating func addOptional(code: String) -> Bool {
        guard let definition = definitionsByCode[code],
              !rows.contains(where: { $0.code == code })
        else { return false }
        rows.append(
            NutrientEditorRow(
                code: definition.code,
                name: definition.name,
                unit: definition.unit,
                isRequired: false,
                amount: ""
            )
        )
        return true
    }

    public mutating func remove(code: String) {
        guard let row = rows.first(where: { $0.code == code }), !row.isRequired else {
            return
        }
        rows.removeAll { $0.code == code }
    }

    public func validated() -> Result<[NutrientAmountValue], NutrientEditorValidationError> {
        var seen = Set<String>()
        var values: [NutrientAmountValue] = []
        var missing: [String] = []

        for row in rows {
            guard seen.insert(row.code).inserted else {
                return .failure(.duplicateNutrient(code: row.code))
            }
            // Required rows are created from the client's canonical required
            // set even when a partial nutrient catalog omits a definition.
            // They still carry the fallback unit and are accepted by the
            // catalog write contract; optional unknown rows stay blocked.
            guard definitionsByCode[row.code] != nil || row.isRequired else {
                return .failure(.unknownNutrient(code: row.code))
            }

            let raw = row.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                if row.isRequired {
                    missing.append(row.code)
                }
                continue
            }
            guard let amount = CatalogDecimal.parseNonNegative(raw),
                  row.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return .failure(.invalidAmount(code: row.code))
            }
            values.append(
                NutrientAmountValue(
                    code: row.code,
                    amount: CatalogDecimal.canonical(amount),
                    unit: row.unit
                )
            )
        }

        if !missing.isEmpty {
            return .failure(.missingRequired(missing))
        }
        return .success(values)
    }

    /// Parsed values with decimals for request construction. Uses the same
    /// validation as `validated()`.
    public func validatedDecimals() -> Result<[ValidatedNutrient], NutrientEditorValidationError> {
        switch validated() {
        case .failure(let error):
            return .failure(error)
        case .success(let values):
            let parsed: [ValidatedNutrient] = values.compactMap { value in
                guard let amount = CatalogDecimal.parseNonNegative(value.amount) else {
                    return nil
                }
                return ValidatedNutrient(
                    code: value.code,
                    amount: amount,
                    unit: value.unit
                )
            }
            guard parsed.count == values.count else {
                return .failure(.invalidAmount(code: values.first?.code ?? ""))
            }
            return .success(parsed)
        }
    }
}

public struct ValidatedNutrient: Equatable, Sendable {
    public let code: String
    public let amount: Decimal
    public let unit: String

    public init(code: String, amount: Decimal, unit: String) {
        self.code = code
        self.amount = amount
        self.unit = unit
    }
}

// MARK: - Custom-food form

public struct CustomFoodServingInput: Equatable, Sendable {
    public let unit: String
    public let gramsPerUnit: String

    public init(unit: String, gramsPerUnit: String) {
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }
}

public enum CustomFoodFormError: Error, Equatable, Sendable {
    case nameRequired
    case nutrients(NutrientEditorValidationError)
    case servingUnitRequired
    case servingGramsInvalid(unit: String)
    case servingUnitDuplicate(unit: String)
    case defaultPortionIncomplete
    case defaultAmountInvalid
    case defaultUnitUnsupported(unit: String)
}

public struct CustomFoodFormValues: Equatable, Sendable {
    public var name: String
    public var brand: String
    public var categoriesText: String
    public var defaultQuantity: String
    public var defaultUnit: String
    public var servings: [CustomFoodServingInput]
    public var nutrientEditor: NutrientEditorState

    public init(
        name: String = "",
        brand: String = "",
        categoriesText: String = "",
        defaultQuantity: String = "",
        defaultUnit: String = "",
        servings: [CustomFoodServingInput] = [],
        nutrientEditor: NutrientEditorState
    ) {
        self.name = name
        self.brand = brand
        self.categoriesText = categoriesText
        self.defaultQuantity = defaultQuantity
        self.defaultUnit = defaultUnit
        self.servings = servings
        self.nutrientEditor = nutrientEditor
    }

    public static func parseCategories(_ text: String) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let normalized = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            values.append(normalized)
        }
        return values
    }

    public func validate() -> Result<CustomFoodWriteRequest, CustomFoodFormError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.nameRequired) }

        let validatedNutrients: [ValidatedNutrient]
        switch nutrientEditor.validatedDecimals() {
        case .failure(let error):
            return .failure(.nutrients(error))
        case .success(let values):
            validatedNutrients = values
        }

        var servingWrites: [CustomFoodServingWrite] = []
        var servingUnits = Set<String>()
        for serving in servings {
            let unit = serving.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let gramsText = serving.gramsPerUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            if unit.isEmpty && gramsText.isEmpty { continue }
            guard !unit.isEmpty else { return .failure(.servingUnitRequired) }
            guard servingUnits.insert(unit).inserted else {
                return .failure(.servingUnitDuplicate(unit: unit))
            }
            guard let grams = CatalogDecimal.parseNonNegative(gramsText), grams > 0 else {
                return .failure(.servingGramsInvalid(unit: unit))
            }
            servingWrites.append(
                CustomFoodServingWrite(
                    unit: unit,
                    gramsPerUnit: CatalogDecimal.round(grams)
                )
            )
        }

        let defaultQuantityText = defaultQuantity
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultUnitText = defaultUnit
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultQuantityValue: Decimal?
        let defaultUnitValue: String?
        switch (defaultQuantityText.isEmpty, defaultUnitText.isEmpty) {
        case (true, true):
            defaultQuantityValue = nil
            defaultUnitValue = nil
        case (false, false):
            guard let amount = CatalogDecimal.parseNonNegative(defaultQuantityText),
                  amount > 0
            else {
                return .failure(.defaultAmountInvalid)
            }
            if defaultUnitText != "g"
                && !servingWrites.contains(where: { $0.unit == defaultUnitText }) {
                return .failure(.defaultUnitUnsupported(unit: defaultUnitText))
            }
            defaultQuantityValue = CatalogDecimal.round(amount)
            defaultUnitValue = defaultUnitText
        default:
            return .failure(.defaultPortionIncomplete)
        }

        let brandText = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            CustomFoodWriteRequest(
                name: trimmedName,
                brand: brandText.isEmpty ? nil : brandText,
                categories: Self.parseCategories(categoriesText),
                defaultQuantity: defaultQuantityValue,
                defaultUnit: defaultUnitValue,
                nutrients: validatedNutrients.map {
                    CustomFoodNutrientWrite(
                        code: $0.code,
                        amountPer100g: CatalogDecimal.round($0.amount)
                    )
                },
                servings: servingWrites
            )
        )
    }

    public func errorMessage(
        _ error: CustomFoodFormError,
        definitions: [NutrientDefinition]
    ) -> String {
        let names = Dictionary(
            definitions.map { ($0.code, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        switch error {
        case .nameRequired:
            return String(localized: "library.editor.error.name")
        case .nutrients(let nutrientError):
            return nutrientErrorMessage(nutrientError, names: names)
        case .servingUnitRequired:
            return String(localized: "library.editor.error.servingUnit")
        case .servingGramsInvalid(let unit):
            return String(
                format: String(localized: "library.editor.error.servingGrams"),
                unit
            )
        case .servingUnitDuplicate(let unit):
            return String(
                format: String(localized: "library.editor.error.servingDuplicate"),
                unit
            )
        case .defaultPortionIncomplete:
            return String(localized: "library.editor.error.defaultIncomplete")
        case .defaultAmountInvalid:
            return String(localized: "library.editor.error.defaultAmount")
        case .defaultUnitUnsupported(let unit):
            return String(
                format: String(localized: "library.editor.error.defaultUnit"),
                unit
            )
        }
    }

    public func nutrientErrorMessage(
        _ error: NutrientEditorValidationError,
        names: [String: String]? = nil
    ) -> String {
        let resolved = names ?? Dictionary(
            nutrientEditor.definitions.map { ($0.code, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        switch error {
        case .missingRequired(let codes):
            let labels = codes.map { resolved[$0] ?? $0 }.joined(separator: ", ")
            return String(
                format: String(localized: "library.nutrient.missing"),
                labels
            )
        case .invalidAmount(let code):
            return String(
                format: String(localized: "library.nutrient.invalid"),
                resolved[code] ?? code
            )
        case .unknownNutrient(let code):
            return String(
                format: String(localized: "library.nutrient.unknown"),
                code
            )
        case .duplicateNutrient(let code):
            return String(
                format: String(localized: "library.nutrient.duplicate"),
                resolved[code] ?? code
            )
        }
    }
}

// MARK: - Ad-hoc form

public enum AdHocLogFormError: Error, Equatable, Sendable {
    case nameRequired
    case quantityInvalid
    case unitRequired
    case nutrients(NutrientEditorValidationError)
    case portionWeightRequired
    case portionWeightInvalid

    public func message(definitions: [NutrientDefinition]) -> String {
        let names = Dictionary(
            definitions.map { ($0.code, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        switch self {
        case .nameRequired:
            return String(localized: "library.adHoc.error.name")
        case .quantityInvalid:
            return String(localized: "library.adHoc.error.quantity")
        case .unitRequired:
            return String(localized: "library.adHoc.error.unit")
        case .nutrients(let error):
            switch error {
            case .missingRequired(let codes):
                let labels = codes.map { names[$0] ?? $0 }.joined(separator: ", ")
                return String(
                    format: String(localized: "library.nutrient.missing"),
                    labels
                )
            case .invalidAmount(let code):
                return String(
                    format: String(localized: "library.nutrient.invalid"),
                    names[code] ?? code
                )
            case .unknownNutrient(let code):
                return String(
                    format: String(localized: "library.nutrient.unknown"),
                    code
                )
            case .duplicateNutrient(let code):
                return String(
                    format: String(localized: "library.nutrient.duplicate"),
                    names[code] ?? code
                )
            }
        case .portionWeightRequired:
            return String(localized: "library.adHoc.error.portionWeightRequired")
        case .portionWeightInvalid:
            return String(localized: "library.adHoc.error.portionWeight")
        }
    }
}

public struct AdHocLogFormValues: Equatable, Sendable {
    public var name: String
    public var brand: String
    public var date: LocalDiaryDate
    public var mealSlot: MealSlot?
    public var amount: String
    public var unit: String
    public var notes: String
    public var nutrientEditor: NutrientEditorState

    public init(
        name: String = "",
        brand: String = "",
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        amount: String = "100",
        unit: String = "g",
        notes: String = "",
        nutrientEditor: NutrientEditorState
    ) {
        self.name = name
        self.brand = brand
        self.date = date
        self.mealSlot = mealSlot
        self.amount = amount
        self.unit = unit
        self.notes = notes
        self.nutrientEditor = nutrientEditor
    }

    public func validate(timeZone: String) -> Result<LogSubmissionDraft, AdHocLogFormError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.nameRequired) }
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUnit.isEmpty else { return .failure(.unitRequired) }
        guard let quantity = CatalogDecimal.parseNonNegative(
            amount.trimmingCharacters(in: .whitespacesAndNewlines)
        ), quantity > 0 else {
            return .failure(.quantityInvalid)
        }
        let nutrients: [NutrientAmountValue]
        switch nutrientEditor.validated() {
        case .failure(let error):
            return .failure(.nutrients(error))
        case .success(let values):
            nutrients = values.sorted { $0.code < $1.code }
        }
        let brandText = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            LogSubmissionDraft(
                item: .adHoc(
                    name: trimmedName,
                    brand: brandText.isEmpty ? nil : brandText
                ),
                date: date,
                mealSlot: mealSlot,
                amount: CatalogDecimal.canonical(quantity),
                unit: trimmedUnit,
                notes: notesText.isEmpty ? nil : notesText,
                timeZone: timeZone,
                nutrients: nutrients
            )
        )
    }

    /// Builds the custom-food aggregate for "save food and log". The entered
    /// ad-hoc nutrients are totals for the given quantity, so a portion weight
    /// is required to derive per-100 g values.
    public func makeCustomFoodWriteRequest(
        portionWeightText: String
    ) -> Result<CustomFoodWriteRequest, AdHocLogFormError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.nameRequired) }
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUnit.isEmpty else { return .failure(.unitRequired) }
        guard let quantity = CatalogDecimal.parseNonNegative(
            amount.trimmingCharacters(in: .whitespacesAndNewlines)
        ), quantity > 0 else {
            return .failure(.quantityInvalid)
        }
        let nutrients: [ValidatedNutrient]
        switch nutrientEditor.validatedDecimals() {
        case .failure(let error):
            return .failure(.nutrients(error))
        case .success(let values):
            nutrients = values
        }

        let portionWeight: Decimal
        if trimmedUnit == "g" {
            portionWeight = quantity
        } else {
            let weightText = portionWeightText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !weightText.isEmpty else {
                return .failure(.portionWeightRequired)
            }
            guard let parsedWeight = CatalogDecimal.parseNonNegative(weightText),
                  parsedWeight > 0 else {
                return .failure(.portionWeightInvalid)
            }
            portionWeight = parsedWeight
        }
        guard portionWeight > 0 else { return .failure(.portionWeightInvalid) }

        let per100g = nutrients.map { nutrient in
            CustomFoodNutrientWrite(
                code: nutrient.code,
                amountPer100g: CatalogDecimal.round(nutrient.amount * 100 / portionWeight)
            )
        }

        var servings: [CustomFoodServingWrite] = []
        if trimmedUnit != "g" {
            let gramsPerUnit = CatalogDecimal.round(portionWeight / quantity)
            guard gramsPerUnit > 0 else { return .failure(.portionWeightInvalid) }
            servings = [
                CustomFoodServingWrite(unit: trimmedUnit, gramsPerUnit: gramsPerUnit)
            ]
        }

        let brandText = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            CustomFoodWriteRequest(
                name: trimmedName,
                brand: brandText.isEmpty ? nil : brandText,
                categories: [],
                defaultQuantity: CatalogDecimal.round(quantity),
                defaultUnit: trimmedUnit,
                nutrients: per100g,
                servings: servings
            )
        )
    }

    public func logIntent(
        timeZone: String
    ) -> Result<CustomFoodLogIntent, AdHocLogFormError> {
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUnit.isEmpty else { return .failure(.unitRequired) }
        guard let quantity = CatalogDecimal.parseNonNegative(
            amount.trimmingCharacters(in: .whitespacesAndNewlines)
        ), quantity > 0 else {
            return .failure(.quantityInvalid)
        }
        let notesText = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            CustomFoodLogIntent(
                date: date,
                mealSlot: mealSlot,
                amount: CatalogDecimal.canonical(quantity),
                unit: trimmedUnit,
                notes: notesText.isEmpty ? nil : notesText,
                timeZone: timeZone
            )
        )
    }
}
