// Food log endpoint calls.

import Foundation

public extension CalCoAPIClient {
    func listLogs(on date: LocalDiaryDate) async throws -> [FoodLog] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "logs"],
            queryItems: [URLQueryItem(name: "log_date", value: date.formatted)]
        )
        let response = try await send(request, as: FoodLogListResponse.self)
        return response.items
    }

    func dailySummary(
        from fromDate: LocalDiaryDate,
        to toDate: LocalDiaryDate
    ) async throws -> [DaySummary] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "logs", "summary"],
            queryItems: [
                URLQueryItem(name: "from_date", value: fromDate.formatted),
                URLQueryItem(name: "to_date", value: toDate.formatted),
            ]
        )
        let response = try await send(request, as: LogSummaryResponse.self)
        return response.days
    }

    func createLog(_ body: CreateLogRequest) async throws -> FoodLog {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .post,
            path: ["api", "logs"],
            body: data
        )
        return try await send(request, as: FoodLog.self)
    }
}
