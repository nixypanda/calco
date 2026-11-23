// Low-level ad-hoc log endpoint.

import Foundation

public extension CalCoAPIClient {
    /// Sends an unkeyed ad-hoc request and returns the created log plus HTTP
    /// status. The shared log transport owns user-initiated submission state;
    /// this method never retries or replays a request.
    func createAdHocLogRaw(_ body: Data) async throws -> (FoodLog, Int) {
        let request = try makeRequest(
            method: .post,
            path: ["api", "logs", "ad-hoc"],
            body: body
        )
        return try await sendWithStatus(request, as: FoodLog.self)
    }

    func createAdHocLog(
        _ body: AdHocLogWriteRequest
    ) async throws -> (FoodLog, Int) {
        let data = try encodeBody(body)
        return try await createAdHocLogRaw(data)
    }
}
