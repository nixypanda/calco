import ComposableArchitecture
import SwiftUI

@MainActor
public final class NativeWindowRuntime: ObservableObject {
    public let coordinator: AppShellCoordinator
    public let store: StoreOf<AppFeature>

    public init(
        sessionAuthority: CalCoSessionAuthority,
        makeDiaryService: ((CalCoAPIClient) -> any DiaryServicing)? = nil,
        makeSettingsService: ((CalCoAPIClient) -> any DiarySettingsServicing)? = nil,
        logSubmissionService: LogSubmissionService? = nil,
        diaryScreenOwnership: DiaryScreenOwnership = .legacy,
        configureDependencies: ((inout DependencyValues, AppShellCoordinator) -> Void)? = nil
    ) {
        let coordinator = AppShellCoordinator(
            client: sessionAuthority.client,
            session: sessionAuthority.session,
            diaryService: makeDiaryService?(sessionAuthority.client),
            settingsService: makeSettingsService?(sessionAuthority.client),
            logSubmissionService: logSubmissionService,
            logSubmissionSessionContextProvider: { [weak sessionAuthority] in
                guard let sessionAuthority,
                      case .signedIn(let user) = sessionAuthority.session.phase
                else {
                    return nil
                }
                return LogSubmissionSessionContext(
                    accountID: user.id,
                    generation: sessionAuthority.session.sessionGeneration,
                    baseURL: sessionAuthority.client.configuration.baseURL
                )
            },
            searchOwnership: .tca,
            diaryScreenOwnership: diaryScreenOwnership
        )
        self.coordinator = coordinator

        let store = Store(
            initialState: AppFeature.State.initial
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.live(authority: sessionAuthority)
            $0.nutritionDetailsClient = NutritionDetailsFeature.Client.live(
                service: CalCoNutritionDetailsServiceAdapter(client: sessionAuthority.client)
            )
            let foodSearchService = CalCoFoodSearchServiceAdapter(client: sessionAuthority.client)
            $0.foodSearchClient = FoodSearchClient.live(service: foodSearchService)
            $0.searchHistoryClient = SearchHistoryClient.live(service: foodSearchService)
            $0.barcodeClient = BarcodeClient.live(
                service: CalCoBarcodeServiceAdapter(client: sessionAuthority.client)
            )
            $0.searchQuickAddClient = SearchQuickAddFeature.Client.live(
                submissionHandler: { drafts, itemNames, summary, completion in
                    MainActor.assumeIsolated {
                        coordinator.submitDraftsForFeature(
                            drafts,
                            itemNames: itemNames,
                            summary: summary,
                            completion: completion
                        )
                    }
                },
                isCurrentGeneration: { generation in
                    coordinator.isCurrentSearchGeneration(generation)
                }
            )
            $0.diaryClient = DiaryFeature.Client.guarded(
                base: { [weak coordinator] date, expectedGeneration in
                    guard let coordinator else { throw DiaryServiceError.cancelled }
                    let isCurrent = await MainActor.run {
                        coordinator.isCurrentDiaryGeneration(expectedGeneration)
                    }
                    guard isCurrent else { throw DiaryServiceError.cancelled }
                    let service = await MainActor.run { coordinator.currentDiaryService }
                    return try await service.fetchDiary(for: date)
                },
                isCurrentGeneration: { [weak coordinator] expectedGeneration in
                    coordinator?.isCurrentDiaryGeneration(expectedGeneration) ?? false
                }
            )
            $0.diaryLatestClient = DiaryLatestFeature.Client.guarded(
                base: { [weak coordinator] before, lookbackDays, expectedGeneration in
                    guard let coordinator else { throw DiaryServiceError.cancelled }
                    let isCurrent = await MainActor.run {
                        coordinator.isCurrentDiaryGeneration(expectedGeneration)
                    }
                    guard isCurrent else { throw DiaryServiceError.cancelled }
                    let service = await MainActor.run { coordinator.currentDiaryService }
                    return try await service.latestSlots(before: before, lookbackDays: lookbackDays)
                },
                isCurrentGeneration: { [weak coordinator] expectedGeneration in
                    coordinator?.isCurrentDiaryGeneration(expectedGeneration) ?? false
                }
            )
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { [weak coordinator] drafts, itemNames, summary, expectedGeneration in
                guard let coordinator else { return .failure(.unauthorized) }
                let isCurrent = await MainActor.run {
                    coordinator.isCurrentDiaryGeneration(expectedGeneration)
                }
                guard isCurrent else { return .failure(.unauthorized) }
                return await withCheckedContinuation { continuation in
                    MainActor.assumeIsolated {
                        coordinator.submitDraftsForFeature(
                            drafts,
                            itemNames: itemNames,
                            summary: summary,
                            expectedGeneration: expectedGeneration,
                            completion: { result in
                                continuation.resume(returning: result)
                            }
                        )
                    }
                }
            }
            $0.legacySearchRoutingClient = LegacySearchRoutingClient.live(coordinator: coordinator)
            $0.legacyDiaryRoutingClient = LegacyDiaryRoutingClient.live(coordinator: coordinator)
            configureDependencies?(&$0, coordinator)
        }
        self.store = store

        coordinator.installTCASearchHandlers(
            contextChanged: { [weak store] (date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64) in
                guard let store else { return }
                guard generation == store.state.sessionGeneration else { return }
                guard case .signedIn(let signedIn) = store.state.phase,
                      signedIn.window.sessionGeneration == generation else {
                    return
                }
                store.send(.window(.search(.updateContext(date: date, mealSlot: mealSlot))))
            },
            recentsInvalidated: { [weak store] (generation: UInt64) in
                guard let store else { return }
                guard generation == store.state.sessionGeneration else { return }
                guard case .signedIn(let signedIn) = store.state.phase,
                      signedIn.window.sessionGeneration == generation else {
                    return
                }
                store.send(.window(.searchRecentsInvalidated(generation: generation)))
            }
        )

        // Transitional log editor reads its row from the TCA owner only: the
        // visible day, then a saved override, then a settled cache entry. A
        // deleted tombstone, expired/stale session, changed selected date, or
        // deallocated store all fail closed — there is no legacy VM fallback,
        // so a freshly written row is provably the authoritative one.
        coordinator.installStoreLogResolver { [weak store] logID, date, generation in
            guard let store,
                  Self.diaryAuthorityIsCurrent(generation, in: store),
                  let diary = store.state.window?.diary.diary,
                  !diary.isSessionExpired,
                  diary.selectedDate == date,
                  !(diary.deletedIDs[date]?.contains(logID) ?? false)
            else { return nil }
            if let day = diary.visibleDay, day.date == date,
               let log = day.logs.first(where: { $0.id == logID }) {
                return log
            }
            if let log = diary.savedLogOverrides[date]?[logID] { return log }
            if case .settled(.success(let day)) = diary.cache.entry(for: date),
               let log = day.logs.first(where: { $0.id == logID }) {
                return log
            }
            return nil
        }

        // Store-backed Diary owns mutation delivery. The weak store capture is
        // deliberate: the coordinator holds this callback for the window's
        // lifetime and must not become a retention path back to the store.
        coordinator.installDiaryMutationCallback { [weak store] delivery in
            guard let store else { return }
            let generation = delivery.generation
            guard Self.diaryAuthorityIsCurrent(generation, in: store) else { return }

            if let editor = delivery.editor {
                // Editor writes are applied on their captured date regardless
                // of what is visible. A cross-date write still caches its row
                // or tombstone; only the read and the notice are visible-gated.
                switch editor {
                case let .saved(originalID, date, log, _):
                    await store.send(
                        .window(.diary(.diary(.applySavedLog(
                            generation: generation,
                            log: log,
                            replacingID: originalID,
                            onDate: date
                        ))))
                    ).finish()
                case let .deleted(id, date, _):
                    await store.send(
                        .window(.diary(.diary(.applyDeletedLog(
                            generation: generation,
                            id: id,
                            onDate: date
                        ))))
                    ).finish()
                }

                // Exactly one authoritative read, only after the local row is
                // applied and only while the captured date is still selected.
                guard Self.diaryAuthorityIsCurrent(generation, in: store),
                      store.state.window?.diary.diary.selectedDate == editor.date else {
                    return
                }
                await store.send(.window(.diary(.diary(.refresh)))).finish()

                // Re-check both authorities after the await: a mid-read
                // generation/date change suppresses the notice and any pullback
                // to an edited date the user has since left.
                guard Self.diaryAuthorityIsCurrent(generation, in: store),
                      store.state.window?.diary.diary.selectedDate == editor.date else {
                    return
                }
                await store.send(
                    .window(.diary(.diary(.showMutationNotice(
                        generation: generation,
                        date: editor.date,
                        notice: editor.notice
                    ))))
                ).finish()
                return
            }

            // Every affected date is handled, not only the visible one. Valid
            // rows update that date's cache/overrides; a date with no valid row
            // is explicitly invalidated so a later visit refetches it.
            for date in delivery.affectedDates {
                let converted = delivery.logs.compactMap { log -> DiaryLog? in
                    guard log.logDate == date, !log.id.isEmpty else { return nil }
                    return CalCoStoreMapping.diaryLog(from: log)
                }
                if converted.isEmpty {
                    await store.send(
                        .window(.diary(.diary(.invalidateCachedDay(
                            generation: generation,
                            date: date
                        ))))
                    ).finish()
                } else {
                    for log in converted {
                        // `applySavedLog` replaces by ID, so a later own-screen
                        // copy reconciliation of the same IDs is idempotent.
                        await store.send(
                            .window(.diary(.diary(.applySavedLog(
                                generation: generation,
                                log: log,
                                replacingID: log.id,
                                onDate: date
                            ))))
                        ).finish()
                    }
                }
            }

            // Re-check after all awaited effects: a write captured under an old
            // generation must never refresh a newer session.
            guard Self.diaryAuthorityIsCurrent(generation, in: store) else { return }
            guard let visibleDate = store.state.window?.diary.diary.selectedDate,
                  delivery.affectedDates.contains(visibleDate) else { return }
            // Exactly one authoritative read, after all local rows are applied.
            await store.send(.window(.diary(.diary(.refresh)))).finish()
        }

        // Store-backed Diary owns the saved-goal writeback too. The mapped
        // server targets update only the visible day through the feature-owned
        // action, which returns no effects — so this send is synchronous and
        // needs no await/finish/Task. The weak store capture cannot retain the
        // window graph; no legacy VM apply, GET, or notice is issued here.
        coordinator.installSettingsGoalCallback { [weak store] generation, targets, date in
            guard let store,
                  Self.diaryAuthorityIsCurrent(generation, in: store) else { return }
            store.send(.window(.diary(.diary(.applySavedGoal(
                generation: generation,
                targets: targets,
                effectiveDate: date
            )))))
        }

        // Store-backed Diary owns the saved-preferences writeback too. The
        // mapped server prefs update only the visible day through the
        // feature-owned action, which returns no effects — so this send is
        // synchronous and needs no await/finish/Task. The weak store capture
        // cannot retain the window graph; no legacy VM apply, GET, or notice is
        // issued here.
        coordinator.installSettingsPreferencesCallback { [weak store] generation, prefs in
            guard let store,
                  Self.diaryAuthorityIsCurrent(generation, in: store) else { return }
            store.send(.window(.diary(.diary(.applySavedPreferences(
                generation: generation,
                prefs: prefs
            )))))
        }
    }

    private static func diaryAuthorityIsCurrent(
        _ generation: UInt64,
        in store: StoreOf<AppFeature>
    ) -> Bool {
        guard generation == store.state.sessionGeneration else { return false }
        guard case .signedIn(let signedIn) = store.state.phase,
              signedIn.window.sessionGeneration == generation else { return false }
        return true
    }
}
