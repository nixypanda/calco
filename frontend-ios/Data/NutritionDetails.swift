// Daily nutrient-report wire models, coverage semantics, and display math.
//
// This mirrors GET /api/nutrition/details and the web's
// frontend-web/src/Data/NutritionDetails.elm contract:
//
// - `known_amount` and `reference_amount` are nullable decimal strings (also
//   accept JSON numbers). A missing amount is unknown; "0" is a real zero.
// - `coverage`, `status`, and `guidance_kind` are server decisions. The client
//   preserves them rather than deriving a replacement report from diary logs.
// - Progress is only defined for non-informational nutrients that have both a
//   known amount and a positive reference.

import Foundation

public enum NutritionDetailsSection: String, Decodable, CaseIterable,
    Equatable, Hashable, Sendable {
    case overview
    case carbohydrates
    case fats
    case limits
    case vitaminsMinerals = "vitamins_minerals"
}

public enum NutritionDetailsGuidanceKind: String, Decodable, Equatable, Sendable {
    case informational
    case adequacy
    case maximum
}

public enum NutritionDetailsCoverage: String, Decodable, Equatable, Sendable {
    case none
    case partial
    case complete
}

public enum NutritionDetailsStatus: String, Decodable, Equatable, Sendable {
    case noData = "no_data"
    case partialData = "partial_data"
    case available
    case belowReference = "below_reference"
    case metReference = "met_reference"
    case withinLimit = "within_limit"
    case overLimit = "over_limit"
}

public struct NutritionDetailsReference: Decodable, Equatable, Sendable {
    public let code: String
    public let name: String
    public let authority: String
    public let jurisdiction: String
    public let populationLabel: String
    public let sourceURL: String

    public init(
        code: String,
        name: String,
        authority: String,
        jurisdiction: String,
        populationLabel: String,
        sourceURL: String
    ) {
        self.code = code
        self.name = name
        self.authority = authority
        self.jurisdiction = jurisdiction
        self.populationLabel = populationLabel
        self.sourceURL = sourceURL
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case authority
        case jurisdiction
        case populationLabel = "population_label"
        case sourceURL = "source_url"
    }
}

/// The amount presentation the web uses for a nutrient row. Keeping this as a
/// value makes the unknown-versus-zero and missing-reference rules testable
/// without coupling them to localized copy.
public enum NutritionDetailsAmountDisplay: Equatable, Sendable {
    case unknown
    case value(Decimal, unit: String)
    case currentAndReference(current: Decimal, reference: Decimal, unit: String)
    case unknownOfReference(reference: Decimal, unit: String)
}

/// The guidance branch for a nutrient, including the exact difference the web
/// displays. `nil` references stay "no daily reference"; a zero reference is
/// still a reference for the guidance copy, but never produces progress.
public enum NutritionDetailsGuidance: Equatable, Sendable {
    case noData
    case noKnownAmount
    case knownMinimum(Decimal)
    case noDailyReference
    case referenceReached
    case toReference(Decimal)
    case overLimit(Decimal)
    case withinLimit(Decimal)
}

public struct NutritionDetailsNutrient: Decodable, Equatable, Sendable {
    public let code: String
    public let name: String
    public let section: NutritionDetailsSection
    public let knownAmount: Decimal?
    public let unit: String
    public let referenceAmount: Decimal?
    public let guidanceKind: NutritionDetailsGuidanceKind
    public let itemsWithData: Int
    public let coverage: NutritionDetailsCoverage
    public let status: NutritionDetailsStatus

    public init(
        code: String,
        name: String,
        section: NutritionDetailsSection,
        knownAmount: Decimal?,
        unit: String,
        referenceAmount: Decimal?,
        guidanceKind: NutritionDetailsGuidanceKind,
        itemsWithData: Int,
        coverage: NutritionDetailsCoverage,
        status: NutritionDetailsStatus
    ) {
        self.code = code
        self.name = name
        self.section = section
        self.knownAmount = knownAmount
        self.unit = unit
        self.referenceAmount = referenceAmount
        self.guidanceKind = guidanceKind
        self.itemsWithData = itemsWithData
        self.coverage = coverage
        self.status = status
    }

    /// The web's `progressPercent`. Informational nutrients and nutrients
    /// without a positive reference have no meaningful percentage.
    public var progressPercent: Double? {
        guard guidanceKind != .informational,
              let knownAmount,
              let referenceAmount,
              referenceAmount > 0 else {
            return nil
        }
        let percent = knownAmount / referenceAmount * 100
        let value = NSDecimalNumber(decimal: percent).doubleValue
        return value.isFinite ? value : nil
    }

    /// The web's danger rule: only a maximum guidance kind that the server
    /// marked over its limit is dangerous. A high adequacy value is not.
    public var isDangerous: Bool {
        guidanceKind == .maximum && status == .overLimit
    }

    public var amountDisplay: NutritionDetailsAmountDisplay {
        if guidanceKind == .informational {
            guard let knownAmount else { return .unknown }
            return .value(knownAmount, unit: unit)
        }

        switch (knownAmount, referenceAmount) {
        case let (known?, reference?):
            return .currentAndReference(
                current: known,
                reference: reference,
                unit: unit
            )
        case let (nil, reference?):
            return .unknownOfReference(reference: reference, unit: unit)
        case let (known?, nil):
            return .value(known, unit: unit)
        case (nil, nil):
            return .unknown
        }
    }

    public var guidance: NutritionDetailsGuidance {
        switch coverage {
        case .none:
            return .noData
        case .partial:
            guard let knownAmount else { return .noKnownAmount }
            return .knownMinimum(knownAmount)
        case .complete:
            switch guidanceKind {
            case .informational:
                return .noDailyReference
            case .adequacy:
                guard let knownAmount, let referenceAmount else {
                    return .noDailyReference
                }
                return knownAmount >= referenceAmount
                    ? .referenceReached
                    : .toReference(referenceAmount - knownAmount)
            case .maximum:
                guard let knownAmount, let referenceAmount else {
                    return .noDailyReference
                }
                return knownAmount > referenceAmount
                    ? .overLimit(knownAmount - referenceAmount)
                    : .withinLimit(referenceAmount - knownAmount)
            }
        }
    }

    /// Overview tiles intentionally show only the known amount, independent of
    /// guidance kind, matching the web's overview card.
    public var overviewAmountDisplay: NutritionDetailsAmountDisplay {
        guard let knownAmount else { return .unknown }
        return .value(knownAmount, unit: unit)
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case section
        case knownAmount = "known_amount"
        case unit
        case referenceAmount = "reference_amount"
        case guidanceKind = "guidance_kind"
        case itemsWithData = "items_with_data"
        case coverage
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decode(String.self, forKey: .name)
        section = try container.decode(NutritionDetailsSection.self, forKey: .section)
        knownAmount = try container.decodeNutritionDetailsDecimalIfPresent(forKey: .knownAmount)
        unit = try container.decode(String.self, forKey: .unit)
        referenceAmount = try container.decodeNutritionDetailsDecimalIfPresent(
            forKey: .referenceAmount
        )
        guidanceKind = try container.decode(
            NutritionDetailsGuidanceKind.self,
            forKey: .guidanceKind
        )
        itemsWithData = try container.decode(Int.self, forKey: .itemsWithData)
        coverage = try container.decode(NutritionDetailsCoverage.self, forKey: .coverage)
        status = try container.decode(NutritionDetailsStatus.self, forKey: .status)
    }
}

public enum NutritionDetailsNoticeSeverity: Equatable, Sendable {
    case info
    case warning
}

public enum NutritionDetailsNotice: Equatable, Sendable {
    case noItemsLogged
    case partialCoverage
    case missingNutrients
    case includedItems(Int)
}

public struct NutritionDetailsCoverageNotice: Equatable, Sendable {
    public let severity: NutritionDetailsNoticeSeverity
    public let notice: NutritionDetailsNotice

    public init(
        severity: NutritionDetailsNoticeSeverity,
        notice: NutritionDetailsNotice
    ) {
        self.severity = severity
        self.notice = notice
    }
}

public struct NutritionDetailsReport: Decodable, Equatable, Sendable {
    public let date: LocalDiaryDate
    public let reference: NutritionDetailsReference
    public let loggedItems: Int
    public let nutrients: [NutritionDetailsNutrient]

    public init(
        date: LocalDiaryDate,
        reference: NutritionDetailsReference,
        loggedItems: Int,
        nutrients: [NutritionDetailsNutrient]
    ) {
        self.date = date
        self.reference = reference
        self.loggedItems = loggedItems
        self.nutrients = nutrients
    }

    public func nutrients(in section: NutritionDetailsSection) -> [NutritionDetailsNutrient] {
        nutrients.filter { $0.section == section }
    }

    public var hasPartialCoverage: Bool {
        nutrients.contains { $0.coverage == .partial }
    }

    public var hasNoCoverage: Bool {
        nutrients.contains { $0.coverage == .none }
    }

    /// Matches the web's coverage banner precedence exactly:
    ///
    /// 1. No logged items is always informational.
    /// 2. Any partial nutrient coverage wins over missing coverage.
    /// 3. Any no-coverage nutrient warns that totals are unavailable.
    /// 4. Complete coverage reports how many items were included.
    ///
    /// `includedItems` carries the count so the view can use the catalog's
    /// English plural variation instead of concatenating grammar in code.
    public var coverageNotice: NutritionDetailsCoverageNotice {
        guard loggedItems > 0 else {
            return NutritionDetailsCoverageNotice(
                severity: .info,
                notice: .noItemsLogged
            )
        }
        if hasPartialCoverage {
            return NutritionDetailsCoverageNotice(
                severity: .warning,
                notice: .partialCoverage
            )
        }
        if hasNoCoverage {
            return NutritionDetailsCoverageNotice(
                severity: .warning,
                notice: .missingNutrients
            )
        }
        return NutritionDetailsCoverageNotice(
            severity: .info,
            notice: .includedItems(loggedItems)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case reference
        case loggedItems = "logged_items"
        case nutrients
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeLocalDiaryDate(forKey: .date)
        reference = try container.decode(NutritionDetailsReference.self, forKey: .reference)
        loggedItems = try container.decode(Int.self, forKey: .loggedItems)
        nutrients = try container.decode([NutritionDetailsNutrient].self, forKey: .nutrients)
    }
}

public enum NutritionDetailsFormat {
    /// One decimal place, trailing zeros removed, using a dot decimal
    /// separator. This is the web's `Number.toFixedTrimmed 1` behavior.
    public static func decimal(_ value: Decimal) -> String {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 1, .plain)
        var text = NSDecimalNumber(decimal: rounded).stringValue
        if text.contains(".") {
            while text.hasSuffix("0") {
                text.removeLast()
            }
            if text.hasSuffix(".") {
                text.removeLast()
            }
        }
        return text == "-0" ? "0" : text
    }

    public static func amount(_ value: Decimal, unit: String) -> String {
        let text = decimal(value)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUnit.isEmpty ? text : "\(text) \(trimmedUnit)"
    }
}

private extension KeyedDecodingContainer {
    /// Accepts the backend's decimal strings and JSON numbers. A present null
    /// (or an absent key) is unknown; an invalid non-null value is a contract
    /// error rather than a silent zero.
    func decodeNutritionDetailsDecimalIfPresent(forKey key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let number = try? decode(Decimal.self, forKey: key) {
            return number
        }
        if let raw = try? decode(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: self,
                    debugDescription: "Expected a decimal string or number"
                )
            }
            if let value = Decimal(
                string: trimmed,
                locale: Locale(identifier: "en_US_POSIX")
            ) {
                return value
            }
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: self,
            debugDescription: "Expected a decimal string or number"
        )
    }
}
