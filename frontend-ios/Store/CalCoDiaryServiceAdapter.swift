// Bridges API client to Diary; preferences fallback to all slots on failure.
import Foundation

public struct CalCoDiaryServiceAdapter: DiaryServicing {
    public let client: CalCoAPIClient
    private let onPreferencesFallback: @Sendable (String) -> Void

    public init(
        client: CalCoAPIClient,
        onPreferencesFallback: (@Sendable (String) -> Void)? = nil
    ) {
        self.client = client
        self.onPreferencesFallback = onPreferencesFallback ?? { message in
            NSLog("%@", "[CalCo][DiaryServiceAdapter] \(message)")
        }
    }

    public func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        async let logsRequest = client.listLogs(on: date)
        async let goalRequest = client.getGoal(on: date)

        let prefs: DiaryPrefs
        do {
            let preferences = try await client.getDiaryPreferences()
            prefs = CalCoStoreMapping.diaryPrefs(from: preferences)
        } catch {
            onPreferencesFallback(
                "Diary preferences unavailable for \(date.formatted); "
                    + "showing all meal slots. \(error.localizedDescription)"
            )
            prefs = DiaryPrefs()
        }

        do {
            let (logs, goal) = try await (logsRequest, goalRequest)
            return DiaryDay(
                date: date,
                logs: logs.map(CalCoStoreMapping.diaryLog(from:)),
                goal: CalCoStoreMapping.diaryGoal(from: goal),
                prefs: prefs
            )
        } catch {
            throw CalCoStoreMapping.diaryError(from: error)
        }
    }
}
