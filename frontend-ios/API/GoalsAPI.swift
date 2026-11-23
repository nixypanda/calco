// Goal endpoint calls.

import Foundation

public extension CalCoAPIClient {
    func getGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
        let request = try makeRequest(
            method: .get,
            path: ["api", "goal"],
            queryItems: [URLQueryItem(name: "date", value: date.formatted)]
        )
        return try await send(request, as: GoalSnapshot.self)
    }

    func saveGoal(_ body: SaveGoalRequest) async throws -> GoalSnapshot {
        let data = try encodeBody(body)
        let request = try makeRequest(
            method: .put,
            path: ["api", "goal"],
            body: data
        )
        return try await send(request, as: GoalSnapshot.self)
    }
}
