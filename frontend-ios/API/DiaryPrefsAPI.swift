// Diary preferences endpoint calls.

import Foundation

public extension CalCoAPIClient {
    static let diaryPreferencesTimeout: TimeInterval = 10

    func getDiaryPreferences() async throws -> DiaryPreferences {
        let request = try makeRequest(
            method: .get,
            path: ["api", "diary-preferences"],
            timeout: Self.diaryPreferencesTimeout
        )
        return try await send(request, as: DiaryPreferences.self)
    }

    func updateDiaryPreferences(_ preferences: DiaryPreferences) async throws -> DiaryPreferences {
        let body = try encodeBody(preferences)
        let request = try makeRequest(
            method: .put,
            path: ["api", "diary-preferences"],
            body: body,
            timeout: Self.diaryPreferencesTimeout
        )
        return try await send(request, as: DiaryPreferences.self)
    }
}
