// Daily nutrient-report endpoint calls.

import Foundation

public extension CalCoAPIClient {
    /// Fetches the server-computed nutrient report for one diary day. The
    /// response already includes reference amounts, coverage, and status; it
    /// must not be reconstructed from currently loaded diary rows.
    func fetchNutritionDetails(on date: LocalDiaryDate) async throws -> NutritionDetailsReport {
        let request = try makeRequest(
            method: .get,
            path: ["api", "nutrition", "details"],
            queryItems: [URLQueryItem(name: "date", value: date.formatted)]
        )
        return try await send(request, as: NutritionDetailsReport.self)
    }
}
