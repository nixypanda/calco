import ComposableArchitecture
import SwiftUI

/// Single per-window runtime. It owns exactly one `Store<AppFeature>` for the
/// window lifetime and wires live clients directly from the existing session
/// authority, service adapters and frozen submission/journal infrastructure.
///
/// There is no feature coordinator, no view-model factory, no legacy routing
/// client and no QA ownership mode. The shared writer returns the authoritative
/// result; the Window reducer owns the single Diary fanout from typed delegates.
@MainActor
public final class NativeWindowRuntime: ObservableObject {
    public let store: StoreOf<AppFeature>

    public init(
        sessionAuthority: CalCoSessionAuthority,
        logSubmissionService: LogSubmissionService? = nil,
        configureDependencies: ((inout DependencyValues) -> Void)? = nil
    ) {
        let sessionContextProvider: LogSubmissionSessionContextProvider = { [weak sessionAuthority] in
            guard let sessionAuthority,
                  case .signedIn(let user) = sessionAuthority.session.phase
            else { return nil }
            return LogSubmissionSessionContext(
                accountID: user.id,
                generation: sessionAuthority.session.sessionGeneration,
                baseURL: sessionAuthority.client.configuration.baseURL
            )
        }
        let submissionService = logSubmissionService ?? LogSubmissionService(
            sender: CalCoLogSubmissionSender(client: sessionAuthority.client),
            sessionContextProvider: sessionContextProvider
        )
        let isCurrentGeneration: @MainActor @Sendable (UInt64) -> Bool = { [weak sessionAuthority] generation in
            guard let sessionAuthority else { return false }
            return sessionAuthority.session.sessionGeneration == generation
        }
        let currentAccountID: @MainActor @Sendable () -> String? = { [weak sessionAuthority] in
            guard let sessionAuthority,
                  case .signedIn(let user) = sessionAuthority.session.phase
            else { return nil }
            return user.id
        }
        // One atomic per-call guard against the CURRENT session authority.
        // Never a generation captured at root init; caller-supplied account AND
        // generation must both match the live signed-in session.
        let isCurrentSession: @MainActor @Sendable (String, UInt64) -> Bool = { [weak sessionAuthority] accountID, generation in
            guard let sessionAuthority,
                  case .signedIn(let user) = sessionAuthority.session.phase,
                  user.id == accountID,
                  sessionAuthority.session.sessionGeneration == generation
            else { return false }
            return true
        }
        // Lane B metadata guard (MainActor) and Lane A reply guard (sync).
        let isCurrentFeatureContext: FeatureContextGuard = { context in
            isCurrentSession(context.accountID, context.generation)
        }
        let isCurrentSettingsContext: @MainActor @Sendable (SettingsFeature.RequestContext) -> Bool = { context in
            isCurrentSession(context.accountID, context.generation)
        }
        let editorContextIsCurrent: @MainActor @Sendable (LogEditorFeature.RequestContext) -> Bool = { context in
            isCurrentSession(context.accountID, context.generation)
        }
        // The one existing writer. No fanout, no replay, no automatic retry.
        let submit: LogSubmissionHandler = { drafts, names, summary, completion in
            Task { @MainActor in
                guard let accountID = currentAccountID() else {
                    completion(.failure(.unauthorized))
                    return
                }
                let result = await submissionService.submit(
                    accountID: accountID,
                    summary: summary,
                    drafts: drafts,
                    itemNames: names
                )
                completion(result)
            }
        }

        let store = Store(initialState: AppFeature.State.initial) {
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
                submissionHandler: submit,
                isCurrentGeneration: isCurrentGeneration
            )

            let diaryService = CalCoDiaryServiceAdapter(client: sessionAuthority.client)
            $0.diaryClient = DiaryFeature.Client.guarded(
                base: { date, expectedGeneration in
                    guard await MainActor.run(body: { isCurrentGeneration(expectedGeneration) }) else {
                        throw DiaryServiceError.cancelled
                    }
                    return try await diaryService.fetchDiary(for: date)
                },
                isCurrentGeneration: isCurrentGeneration
            )
            $0.diaryLatestClient = DiaryLatestFeature.Client.guarded(
                base: { before, lookbackDays, expectedGeneration in
                    guard await MainActor.run(body: { isCurrentGeneration(expectedGeneration) }) else {
                        throw DiaryServiceError.cancelled
                    }
                    return try await diaryService.latestSlots(
                        before: before,
                        lookbackDays: lookbackDays
                    )
                },
                isCurrentGeneration: isCurrentGeneration
            )
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient {
                drafts, names, summary, expectedGeneration in
                guard await MainActor.run(body: { isCurrentGeneration(expectedGeneration) }) else {
                    return .failure(.unauthorized)
                }
                return await withCheckedContinuation { continuation in
                    submit(drafts, names, summary) { result in
                        continuation.resume(returning: result)
                    }
                }
            }

            let logStore = LogSubmissionStore.shared
            $0.logEditorClient = LogEditorFeature.Client(
                fetchUnits: { context in
                    guard await MainActor.run(body: { editorContextIsCurrent(context) }) else { throw DiaryServiceError.cancelled }
                    return try await diaryService.fetchUnits()
                },
                updateLog: { context, id, request in
                    guard await MainActor.run(body: { editorContextIsCurrent(context) }) else { throw DiaryServiceError.cancelled }
                    return try await diaryService.updateLog(id: id, request: request)
                },
                deleteLog: { context, id in
                    guard await MainActor.run(body: { editorContextIsCurrent(context) }) else { throw DiaryServiceError.cancelled }
                    try await diaryService.deleteLog(id: id)
                },
                blockBeforeDeleting: { context, foodID, date, reason in
                    guard editorContextIsCurrent(context) else { throw DiaryServiceError.cancelled }
                    // Count the invalidated matches BEFORE the DELETE is sent.
                    return try logStore.blockBeforeDeleting(
                        accountID: context.accountID,
                        foodID: foodID,
                        date: date,
                        reason: reason
                    ).count
                },
                matchingPendingCount: { context, foodID, date in
                    guard editorContextIsCurrent(context) else { return 0 }
                    return logStore.unresolved(
                        accountID: context.accountID,
                        foodID: foodID,
                        date: date
                    ).count
                }
            )
            $0.diarySettingsClient = SettingsFeature.Client.live(
                service: CalCoSettingsServiceAdapter(client: sessionAuthority.client),
                isCurrent: isCurrentSettingsContext
            )

            $0.foodDetailClient = FoodDetailFeature.Client.live(
                service: CalCoFoodDetailServiceAdapter(client: sessionAuthority.client),
                isCurrent: isCurrentFeatureContext
            )
            $0.foodDetailJournalClient = FoodDetailFeature.JournalClient.live(store: logStore)

            let libraryService = CalCoLibraryServiceAdapter(client: sessionAuthority.client)
            let libraryLogClient = LibraryLogClient(
                submit: { drafts, names, summary, accountID, generation, completion in
                    Task { @MainActor in
                        guard isCurrentSession(accountID, generation) else {
                            completion(.failure(.unauthorized))
                            return
                        }
                        let result = await submissionService.submit(
                            accountID: accountID,
                            summary: summary,
                            drafts: drafts,
                            itemNames: names,
                            generation: generation
                        )
                        completion(result)
                    }
                },
                isCurrentOwner: isCurrentSession
            )
            $0.libraryClient = LibraryFeature.Client.live(
                service: libraryService,
                isCurrent: isCurrentFeatureContext
            )
            $0.libraryLogClient = libraryLogClient
            $0.customFoodEditorClient = CustomFoodEditorFeature.Client.live(
                service: libraryService,
                isCurrent: isCurrentFeatureContext
            )
            $0.adHocLogClient = AdHocLogFeature.Client.live(
                service: libraryService,
                log: libraryLogClient,
                isCurrent: isCurrentFeatureContext
            )

            $0.mealsClient = MealsFeatureClient.live(
                service: CalCoMealsServiceAdapter(client: sessionAuthority.client),
                submissionHandler: submit,
                isCurrentSession: isCurrentSession
            )
            $0.apiKeyClient = APIKeyFeatureClient.live(
                service: CalCoAPIKeysServiceAdapter(client: sessionAuthority.client),
                isCurrentSession: isCurrentSession
            )

            configureDependencies?(&$0)
        }
        self.store = store
    }
}
