// Daily summary wire models.

import Foundation

public struct DaySummary: Codable, Equatable, Hashable, Sendable {
    public let date: LocalDiaryDate
    public let energyKcal: Double
    public let proteinG: Double
    public let carbsG: Double
    public let fatG: Double

    public init(
        date: LocalDiaryDate,
        energyKcal: Double,
        proteinG: Double,
        carbsG: Double,
        fatG: Double
    ) {
        self.date = date
        self.energyKcal = energyKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case energyKcal = "energy_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeLocalDiaryDate(forKey: .date)
        energyKcal = try container.decodeFlexibleDouble(forKey: .energyKcal)
        proteinG = try container.decodeFlexibleDouble(forKey: .proteinG)
        carbsG = try container.decodeFlexibleDouble(forKey: .carbsG)
        fatG = try container.decodeFlexibleDouble(forKey: .fatG)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(date, forKey: .date)
        try container.encode(String(energyKcal), forKey: .energyKcal)
        try container.encode(String(proteinG), forKey: .proteinG)
        try container.encode(String(carbsG), forKey: .carbsG)
        try container.encode(String(fatG), forKey: .fatG)
    }
}

public struct LogSummaryResponse: Codable, Equatable, Sendable {
    public let days: [DaySummary]

    public init(days: [DaySummary]) {
        self.days = days
    }
}
