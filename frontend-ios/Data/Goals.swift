// Goal wire models.

import Foundation

public enum GoalSource: String, Codable, Sendable {
    case `default`
    case saved
}

public struct GoalTargets: Codable, Equatable, Sendable {
    public let calorieTarget: Double
    public let proteinTargetG: Double
    public let carbsTargetG: Double
    public let fatTargetG: Double

    public init(
        calorieTarget: Double,
        proteinTargetG: Double,
        carbsTargetG: Double,
        fatTargetG: Double
    ) {
        self.calorieTarget = calorieTarget
        self.proteinTargetG = proteinTargetG
        self.carbsTargetG = carbsTargetG
        self.fatTargetG = fatTargetG
    }

    private enum CodingKeys: String, CodingKey {
        case calorieTarget = "calorie_target"
        case proteinTargetG = "protein_target_g"
        case carbsTargetG = "carbs_target_g"
        case fatTargetG = "fat_target_g"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calorieTarget = try container.decodeFlexibleDouble(forKey: .calorieTarget)
        proteinTargetG = try container.decodeFlexibleDouble(forKey: .proteinTargetG)
        carbsTargetG = try container.decodeFlexibleDouble(forKey: .carbsTargetG)
        fatTargetG = try container.decodeFlexibleDouble(forKey: .fatTargetG)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(calorieTarget, forKey: .calorieTarget)
        try container.encode(proteinTargetG, forKey: .proteinTargetG)
        try container.encode(carbsTargetG, forKey: .carbsTargetG)
        try container.encode(fatTargetG, forKey: .fatTargetG)
    }
}

/// Exact decimal representation used by settings writes. `GoalTargets` remains
/// the display/reading model for compatibility; this type prevents JSONEncoder
/// from introducing binary residuals into the backend's exact equation.
public struct GoalTargetsDecimal: Equatable, Sendable {
    public let calorieTarget: Decimal
    public let proteinTargetG: Decimal
    public let carbsTargetG: Decimal
    public let fatTargetG: Decimal

    public init(
        calorieTarget: Decimal,
        proteinTargetG: Decimal,
        carbsTargetG: Decimal,
        fatTargetG: Decimal
    ) {
        self.calorieTarget = calorieTarget
        self.proteinTargetG = proteinTargetG
        self.carbsTargetG = carbsTargetG
        self.fatTargetG = fatTargetG
    }

    public var doubleTargets: GoalTargets {
        GoalTargets(
            calorieTarget: NSDecimalNumber(decimal: calorieTarget).doubleValue,
            proteinTargetG: NSDecimalNumber(decimal: proteinTargetG).doubleValue,
            carbsTargetG: NSDecimalNumber(decimal: carbsTargetG).doubleValue,
            fatTargetG: NSDecimalNumber(decimal: fatTargetG).doubleValue
        )
    }
}

public enum GoalDecimalMath {
    public static func exactDecimal(for value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        let raw = String(value)
        if let decimal = Decimal(
            string: raw,
            locale: Locale(identifier: "en_US_POSIX")
        ) {
            return decimal
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 28
        formatter.generatesDecimalNumbers = true
        guard let text = formatter.string(from: NSNumber(value: value)) else {
            return nil
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct GoalSnapshot: Codable, Equatable, Sendable {
    public let requestedDate: LocalDiaryDate
    public let effectiveFrom: LocalDiaryDate?
    public let source: GoalSource
    public let targets: GoalTargets
    /// Exact decimal values when the server supplied decimal strings. Settings
    /// uses this to avoid rounding unsupported precision through Double.
    public let exactTargets: GoalTargetsDecimal?

    public init(
        requestedDate: LocalDiaryDate,
        effectiveFrom: LocalDiaryDate? = nil,
        source: GoalSource,
        targets: GoalTargets,
        exactTargets: GoalTargetsDecimal? = nil
    ) {
        self.requestedDate = requestedDate
        self.effectiveFrom = effectiveFrom
        self.source = source
        self.targets = targets
        self.exactTargets = exactTargets
    }

    public var isSaved: Bool { source == .saved }

    private enum CodingKeys: String, CodingKey {
        case requestedDate = "requested_date"
        case effectiveFrom = "effective_from"
        case source
        case calorieTarget = "calorie_target"
        case proteinTargetG = "protein_target_g"
        case carbsTargetG = "carbs_target_g"
        case fatTargetG = "fat_target_g"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedDate = try container.decodeLocalDiaryDate(forKey: .requestedDate)
        effectiveFrom = try container.decodeLocalDiaryDateIfPresent(forKey: .effectiveFrom)
        source = try container.decode(GoalSource.self, forKey: .source)
        targets = try GoalTargets(from: decoder)
        let calorie = Self.decodeExactDecimal(from: container, forKey: .calorieTarget)
        let protein = Self.decodeExactDecimal(from: container, forKey: .proteinTargetG)
        let carbs = Self.decodeExactDecimal(from: container, forKey: .carbsTargetG)
        let fat = Self.decodeExactDecimal(from: container, forKey: .fatTargetG)
        if let calorie, let protein, let carbs, let fat {
            exactTargets = GoalTargetsDecimal(
                calorieTarget: calorie,
                proteinTargetG: protein,
                carbsTargetG: carbs,
                fatTargetG: fat
            )
        } else {
            exactTargets = nil
        }
    }

    private static func decodeExactDecimal(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Decimal? {
        if let raw = try? container.decode(String.self, forKey: key) {
            return Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let raw = try? container.decode(Double.self, forKey: key) {
            return GoalDecimalMath.exactDecimal(for: raw)
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(requestedDate, forKey: .requestedDate)
        if let effectiveFrom {
            try container.encodeLocalDiaryDate(effectiveFrom, forKey: .effectiveFrom)
        } else {
            try container.encodeNil(forKey: .effectiveFrom)
        }
        try container.encode(source, forKey: .source)
        try targets.encode(to: encoder)
    }
}

public struct SaveGoalRequest: Encodable, Equatable, Sendable {
    public let localDate: LocalDiaryDate
    public let deviceTimeZone: String
    public let targets: GoalTargets
    /// Present for settings edits. Encoded as decimal strings so the backend
    /// receives the exact user equation, not a binary floating-point residual.
    public let exactTargets: GoalTargetsDecimal?

    public init(
        localDate: LocalDiaryDate,
        deviceTimeZone: String = TimeZone.current.identifier,
        targets: GoalTargets
    ) {
        self.localDate = localDate
        self.deviceTimeZone = deviceTimeZone
        self.targets = targets
        self.exactTargets = nil
    }

    public init(
        localDate: LocalDiaryDate,
        deviceTimeZone: String = TimeZone.current.identifier,
        exactTargets: GoalTargetsDecimal
    ) {
        self.localDate = localDate
        self.deviceTimeZone = deviceTimeZone
        self.targets = exactTargets.doubleTargets
        self.exactTargets = exactTargets
    }

    private enum CodingKeys: String, CodingKey {
        case localDate = "local_date"
        case deviceTimeZone = "device_timezone"
        case calorieTarget = "calorie_target"
        case proteinTargetG = "protein_target_g"
        case carbsTargetG = "carbs_target_g"
        case fatTargetG = "fat_target_g"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(localDate, forKey: .localDate)
        try container.encode(deviceTimeZone, forKey: .deviceTimeZone)
        if let exactTargets {
            try container.encode(exactTargets.calorieTarget, forKey: .calorieTarget)
            try container.encode(exactTargets.proteinTargetG, forKey: .proteinTargetG)
            try container.encode(exactTargets.carbsTargetG, forKey: .carbsTargetG)
            try container.encode(exactTargets.fatTargetG, forKey: .fatTargetG)
        } else {
            try container.encode(targets.calorieTarget, forKey: .calorieTarget)
            try container.encode(targets.proteinTargetG, forKey: .proteinTargetG)
            try container.encode(targets.carbsTargetG, forKey: .carbsTargetG)
            try container.encode(targets.fatTargetG, forKey: .fatTargetG)
        }
    }
}
