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

    public func getLog(id: String) async throws -> DiaryLog {
        do {
            return CalCoStoreMapping.diaryLog(from: try await client.getLog(id: id))
        } catch {
            throw CalCoStoreMapping.diaryError(from: error)
        }
    }

    public func fetchUnits() async throws -> [FoodUnit] {
        do {
            return try await client.listUnits().map(CalCoStoreMapping.foodUnit(from:))
        } catch {
            throw CalCoStoreMapping.diaryError(from: error)
        }
    }

    public func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
        do {
            return CalCoStoreMapping.diaryLog(
                from: try await client.updateLog(id: id, body: request)
            )
        } catch {
            throw CalCoStoreMapping.diaryError(from: error)
        }
    }

    public func deleteLog(id: String) async throws {
        do {
            try await client.deleteLog(id: id)
        } catch {
            throw CalCoStoreMapping.diaryError(from: error)
        }
    }

    public func latestSlots(
        before date: LocalDiaryDate,
        lookbackDays: Int
    ) async throws -> [DiaryLatestSlot] {
        do {
            let slots = try await client.latestSlots(
                before: date,
                lookbackDays: lookbackDays
            )
            return slots.map { slot in
                DiaryLatestSlot(
                    sourceDate: slot.sourceDate,
                    mealSlot: slot.mealSlot,
                    logs: slot.items.map(CalCoStoreMapping.diaryLog(from:))
                )
            }
        } catch {
            throw CalCoStoreMapping.diaryError(from: error)
        }
    }
}
