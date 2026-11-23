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
        return try await createLogRaw(data).0
    }

    /// Sends bytes prepared and persisted by the submission journal verbatim.
    func createLogRaw(_ body: Data) async throws -> (FoodLog, Int) {
        let request = try makeRequest(
            method: .post,
            path: ["api", "logs"],
            body: body
        )
        return try await sendWithStatus(request, as: FoodLog.self)
    }

    func getLog(id: String) async throws -> FoodLog {
        let request = try makeRequest(
            method: .get,
            path: ["api", "logs", id]
        )
        return try await send(request, as: FoodLog.self)
    }

    func updateLog(id: String, body: UpdateLogRequest) async throws -> FoodLog {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .put,
            path: ["api", "logs", id],
            body: data
        )
        return try await send(request, as: FoodLog.self)
    }

    func deleteLog(id: String) async throws {
        let request = try makeRequest(
            method: .delete,
            path: ["api", "logs", id]
        )
        // DELETE /api/logs/{id} responds 204 with no body. `send` would reject
        // an empty body, so use the no-content path (which also maps 401/429).
        try await sendVoidWithoutRedirects(request)
    }
}
