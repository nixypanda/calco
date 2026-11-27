import ComposableArchitecture
import Foundation

/// Pure plan for the ONE Diary fanout after an authoritative typed submission.
///
/// This extracts the coordinator's former `installDiaryMutationCallback` work
/// into a value the Window owns. It never writes, never retries, and never
/// creates a service; it only derives the ordered set of Window actions from an
/// existing `DiaryMutationDelivery` and the current visible date.
public struct DiaryMutationFanoutPlan: Sendable {
    public let generation: UInt64
    public let affectedDates: [LocalDiaryDate]
    public let actions: [WindowFeature.Action]
    public let invalidatesLatestSuggestions: Bool
    public let refreshesVisibleDate: Bool

    public static func make(
        delivery: DiaryMutationDelivery,
        visibleDate: LocalDiaryDate?,
        sessionGeneration: UInt64
    ) -> DiaryMutationFanoutPlan? {
        // A stale delivery can never refresh or mutate a newer session.
        guard delivery.generation == sessionGeneration else { return nil }

        var actions: [WindowFeature.Action] = []

        if let editor = delivery.editor {
            // Editor writes apply on their captured date regardless of what is
            // visible; the read and notice are visible-gated only.
            switch editor {
            case let .saved(originalID, date, log, _):
                actions.append(.diary(.diary(.applySavedLog(
                    generation: delivery.generation,
                    log: log,
                    replacingID: originalID,
                    onDate: date
                ))))
            case let .deleted(id, date, _):
                actions.append(.diary(.diary(.applyDeletedLog(
                    generation: delivery.generation,
                    id: id,
                    onDate: date
                ))))
            }
            let isVisible = visibleDate == editor.date
            if isVisible {
                // Hold the notice; the Diary feature releases it only after the
                // authoritative read actually settles.
                actions.append(.diary(.diary(.queueMutationNotice(
                    generation: delivery.generation,
                    date: editor.date,
                    notice: editor.notice
                ))))
                actions.append(.diary(.diary(.refresh)))
            }
            return DiaryMutationFanoutPlan(
                generation: delivery.generation,
                affectedDates: delivery.affectedDates,
                actions: actions,
                invalidatesLatestSuggestions: false,
                refreshesVisibleDate: isVisible
            )
        }

        // A changed source date makes every destination's lookback stale. Only
        // feature-owned cache/tokens are invalidated; retained review/copy
        // intents are untouched and no nonvisible date is fetched.
        let invalidatesLatest = !delivery.affectedDates.isEmpty

        for date in delivery.affectedDates {
            let converted = delivery.logs.compactMap { log -> DiaryLog? in
                guard log.logDate == date, !log.id.isEmpty else { return nil }
                return CalCoStoreMapping.diaryLog(from: log)
            }
            if converted.isEmpty {
                actions.append(.diary(.diary(.invalidateCachedDay(
                    generation: delivery.generation,
                    date: date
                ))))
            } else {
                for log in converted {
                    // `applySavedLog` replaces by ID, so a same-ID copy is
                    // idempotent and never produces a second refresh.
                    actions.append(.diary(.diary(.applySavedLog(
                        generation: delivery.generation,
                        log: log,
                        replacingID: log.id,
                        onDate: date
                    ))))
                }
            }
        }

        let visible = visibleDate.map { delivery.affectedDates.contains($0) } ?? false
        if visible {
            // Exactly one authoritative read, after all local rows are applied.
            actions.append(.diary(.diary(.refresh)))
        }
        return DiaryMutationFanoutPlan(
            generation: delivery.generation,
            affectedDates: delivery.affectedDates,
            actions: actions,
            invalidatesLatestSuggestions: invalidatesLatest,
            refreshesVisibleDate: visible
        )
    }
}
