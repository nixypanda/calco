// Bridges goal and diary-preference endpoints to the settings feature.

import Foundation

public struct CalCoSettingsServiceAdapter: DiarySettingsServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
        do {
            return try await client.getGoal(on: date)
        } catch {
            throw settingsError(from: error)
        }
    }

    public func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot {
        do {
            return try await client.saveGoal(request)
        } catch {
            throw settingsError(from: error)
        }
    }

    public func fetchDiaryPreferences() async throws -> DiaryPreferences {
        do {
            return try await client.getDiaryPreferences()
        } catch {
            throw settingsError(from: error)
        }
    }

    public func updateDiaryPreferences(_ preferences: DiaryPreferences) async throws -> DiaryPreferences {
        do {
            return try await client.updateDiaryPreferences(preferences)
        } catch {
            throw settingsError(from: error)
        }
    }

    private func settingsError(from error: Error) -> DiarySettingsServiceError {
        if let featureError = error as? DiarySettingsServiceError {
            return featureError
        }
        guard let apiError = error as? CalCoAPIError else {
            return .unknown
        }

        switch apiError {
        case .unauthorized:
            return .unauthorized
        case .network, .timeout:
            return .networkUnavailable
        case .cancelled:
            return .cancelled
        case .rateLimited:
            return .rejected(String(localized: "settings.error.rateLimited"))
        case .badStatus(let statusCode, let payload):
            let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = message.isEmpty
                ? String(localized: "settings.error.server")
                : message
            switch statusCode {
            case 408, 500...:
                return .server(text)
            case 400..<500:
                return .rejected(text)
            default:
                return .server(text)
            }
        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return .unknown
        }
    }
}
