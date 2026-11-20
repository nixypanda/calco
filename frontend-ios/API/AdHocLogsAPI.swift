// Low-level ad-hoc log endpoint.
//
// The endpoint accepts a top-level idempotency key on the backend, but the app
// must still record the body and key before sending so a retry after relaunch
// replays the same operation. Library screens therefore submit through
// `LibraryLogSubmitting`, not this method.

import Foundation

public extension CalCoAPIClient {
    /// Sends an ad-hoc request and returns the log plus HTTP status. A 201 is a
    /// first create; 200 is an idempotent replay. Callers must retain the same
    /// key and exact body for all retries of one logical log.
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
