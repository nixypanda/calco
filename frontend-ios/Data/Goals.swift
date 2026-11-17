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

public struct GoalSnapshot: Codable, Equatable, Sendable {
    public let requestedDate: LocalDiaryDate
    public let effectiveFrom: LocalDiaryDate?
    public let source: GoalSource
    public let targets: GoalTargets

    public init(
        requestedDate: LocalDiaryDate,
        effectiveFrom: LocalDiaryDate? = nil,
        source: GoalSource,
        targets: GoalTargets
    ) {
        self.requestedDate = requestedDate
        self.effectiveFrom = effectiveFrom
        self.source = source
        self.targets = targets
    }

    public var isSaved: Bool { source == .saved }

    private enum CodingKeys: String, CodingKey {
        case requestedDate = "requested_date"
        case effectiveFrom = "effective_from"
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedDate = try container.decodeLocalDiaryDate(forKey: .requestedDate)
        effectiveFrom = try container.decodeLocalDiaryDateIfPresent(forKey: .effectiveFrom)
        source = try container.decode(GoalSource.self, forKey: .source)
        targets = try GoalTargets(from: decoder)
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

    public init(
        localDate: LocalDiaryDate,
        deviceTimeZone: String = TimeZone.current.identifier,
        targets: GoalTargets
    ) {
        self.localDate = localDate
        self.deviceTimeZone = deviceTimeZone
        self.targets = targets
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
        try container.encode(targets.calorieTarget, forKey: .calorieTarget)
        try container.encode(targets.proteinTargetG, forKey: .proteinTargetG)
        try container.encode(targets.carbsTargetG, forKey: .carbsTargetG)
        try container.encode(targets.fatTargetG, forKey: .fatTargetG)
    }
}
