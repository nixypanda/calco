// Typed log-history and direct submission endpoint calls.

import Foundation

public extension CalCoAPIClient {
    func recentItems(
        from fromDate: LocalDiaryDate,
        to toDate: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> [RecentLogItem] {
        var query = [
            URLQueryItem(name: "from_date", value: fromDate.formatted),
            URLQueryItem(name: "to_date", value: toDate.formatted),
        ]
        if let mealSlot {
            query.append(URLQueryItem(name: "meal_slot", value: mealSlot.rawValue))
        }
        let request = try makeRequest(
            method: .get,
            path: ["api", "logs", "recent-items"],
            queryItems: query
        )
        return try await send(request, as: RecentItemsResponse.self).items
    }

    func lastUsedItems(_ body: LastUsedItemsRequest) async throws -> [RecentLogItem] {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .post,
            path: ["api", "logs", "last-used"],
            body: data
        )
        return try await send(request, as: RecentItemsResponse.self).items
    }

    func latestSlots(
        before date: LocalDiaryDate,
        lookbackDays: Int
    ) async throws -> [LatestSlotLogs] {
        let request = try makeRequest(
            method: .get,
            path: ["api", "logs", "latest-slots"],
            queryItems: [
                URLQueryItem(name: "before", value: date.formatted),
                URLQueryItem(name: "lookback_days", value: String(lookbackDays)),
            ]
        )
        return try await send(request, as: LatestSlotsResponse.self).slots
    }

    /// Sends one plain request body. The path allowlist keeps this seam limited
    /// to the three existing log-create endpoints.
    func createSubmissionRaw(
        _ submission: LogSubmissionRequest
    ) async throws -> (logs: [FoodLog], statusCode: Int) {
        guard let route = Self.submissionRoute(for: submission.requestPath) else {
            throw CalCoAPIError.invalidURL
        }
        let request = try makeRequest(
            method: .post,
            path: ["api", "logs"] + (route == .single ? [] : [route.pathSuffix]),
            body: submission.body
        )
        switch route {
        case .single, .adHoc:
            let (log, status) = try await sendWithStatus(request, as: FoodLog.self)
            return ([log], status)
        case .batch:
            let (response, status) = try await sendWithStatus(
                request,
                as: BatchLogResponse.self
            )
            return (response.items, status)
        }
    }

    private static func submissionRoute(
        for path: String
    ) -> LogSubmissionRoute? {
        switch path {
        case LogSubmissionRoute.single.requestPath: return .single
        case LogSubmissionRoute.batch.requestPath: return .batch
        case LogSubmissionRoute.adHoc.requestPath: return .adHoc
        default: return nil
        }
    }
}

private extension LogSubmissionRoute {
    var pathSuffix: String {
        switch self {
        case .single: return ""
        case .batch: return "batch"
        case .adHoc: return "ad-hoc"
        }
    }
}
