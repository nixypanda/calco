import Combine
import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class NativeWindowRuntimeTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!
    private let initialDate = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let fixedDate = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 24)
    )!
    private let initialGoalTargets = DiaryGoalTargets(
        calorieTarget: 2_000, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
    )
    private let savedGoalTargets = DiaryGoalTargets(
        calorieTarget: 2_230, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
    )

    private func makeAuthority() -> (CalCoSessionAuthority, CountingSessionService) {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-runtime", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-runtime", displayName: "Alice")
        )
        let service = CountingSessionService(session: session)
        let coordinatorSession = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: TestCookieClearer()
        )
        return (
            CalCoSessionAuthority(
                client: CalCoAPIClient(baseURL: baseURL),
                session: coordinatorSession
            ),
            service
        )
    }

    private final class SessionStreamBox: @unchecked Sendable {
        var continuation: AsyncStream<SessionSnapshot>.Continuation?
    }

    private func makeFiniteSessionClient(
        authority: CalCoSessionAuthority,
        box: SessionStreamBox
    ) -> SessionClient {
        SessionClient(
            restore: { await authority.session.restore() },
            start: {
                let phase = await authority.session.start()
                let snapshot = await MainActor.run {
                    SessionSnapshot(
                        phase: phase,
                        generation: authority.session.sessionGeneration
                    )
                }
                box.continuation?.yield(snapshot)
                box.continuation?.finish()
                return phase
            },
            signIn: { _, _ in .failed(.invalidCredentials) },
            signOut: { .completed },
            handleUnauthorized: { _, _ in false },
            dismissUnsupportedAccount: {},
            snapshot: {
                await MainActor.run {
                    SessionSnapshot(
                        phase: authority.session.phase,
                        generation: authority.session.sessionGeneration
                    )
                }
            },
            events: {
                let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
                box.continuation = continuation
                return stream
            }
        )
    }

    private func ensureSignedIn(_ runtime: NativeWindowRuntime) async {
        await runtime.store.send(.task).finish()
    }

    private func applyStableDependencies(
        _ dependencies: inout DependencyValues,
        authority: CalCoSessionAuthority,
        box: SessionStreamBox,
        overrideClients: Bool
    ) {
        dependencies.date = .constant(fixedDate)
        dependencies.uuid = .incrementing
        dependencies.calendar = Calendar(identifier: .gregorian)
        dependencies.timeZone = TimeZone(identifier: "UTC")!
        dependencies.sessionClient = makeFiniteSessionClient(authority: authority, box: box)
        if overrideClients {
            dependencies.continuousClock = TestClock()
            dependencies.foodSearchClient = .unimplemented
            dependencies.searchHistoryClient = SearchHistoryClient(
                recentItems: { _, _, _ in [] },
                categorySuggestions: { _, _ in [] }
            )
            dependencies.barcodeClient = .unimplemented
            dependencies.searchQuickAddClient = SearchQuickAddFeature.Client(
                submit: { @MainActor _, _, _, _ in .failure(.failed("unimplemented")) }
            )
            dependencies.legacySearchRoutingClient = .unimplemented
        }
    }

    func testSharedAuthorityDoesNotDuplicateSessionRestoreAcrossWindows() async {
        let (authority, service) = makeAuthority()
        let firstBox = SessionStreamBox()
        let secondBox = SessionStreamBox()

        let first = NativeWindowRuntime(
            sessionAuthority: authority,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies,
                    authority: authority,
                    box: firstBox,
                    overrideClients: false
                )
            }
        )
        let second = NativeWindowRuntime(
            sessionAuthority: authority,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies,
                    authority: authority,
                    box: secondBox,
                    overrideClients: false
                )
            }
        )

        XCTAssertFalse(first.coordinator === second.coordinator)
        XCTAssertFalse(first.store === second.store)
        XCTAssertTrue(first.coordinator.session === authority.session)
        XCTAssertTrue(second.coordinator.session === authority.session)

        await ensureSignedIn(first)
        XCTAssertEqual(service.restoreCount, 1)

        await ensureSignedIn(second)
        XCTAssertEqual(service.restoreCount, 1)
    }

    func testPerWindowSearchStateRemainsDistinct() async {
        let (authority, _) = makeAuthority()
        let firstBox = SessionStreamBox()
        let secondBox = SessionStreamBox()

        let first = NativeWindowRuntime(
            sessionAuthority: authority,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies,
                    authority: authority,
                    box: firstBox,
                    overrideClients: true
                )
            }
        )
        let second = NativeWindowRuntime(
            sessionAuthority: authority,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies,
                    authority: authority,
                    box: secondBox,
                    overrideClients: true
                )
            }
        )

        await ensureSignedIn(first)
        await ensureSignedIn(second)

        let firstTask = first.store.send(.window(.search(.queryChanged("alpha"))))
        firstTask.cancel()
        let secondTask = second.store.send(.window(.search(.queryChanged("beta"))))
        secondTask.cancel()

        XCTAssertEqual(first.store.state.window?.search.catalog.phase.query, "alpha")
        XCTAssertEqual(second.store.state.window?.search.catalog.phase.query, "beta")
    }

    // MARK: - Store-backed Diary mutation delivery

    private func makeLog(id: String, date: LocalDiaryDate) -> FoodLog {
        FoodLog(
            id: id,
            logDate: date,
            mealSlot: .breakfast,
            item: .product(ProductLogItemSnapshot(id: "qa-apple", name: "Apple")),
            quantity: NutritionQuantity(amount: "100", unit: "g"),
            nutrients: [
                NutrientAmountValue(code: NutrientCodes.energyKcal, amount: "100", unit: "kcal")
            ]
        )
    }

    private func makeDraft(date: LocalDiaryDate) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: .product(id: "qa-apple"),
            date: date,
            mealSlot: .breakfast,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "UTC"
        )
    }

    private func fetchCount(in runtime: NativeWindowRuntime) -> Int {
        runtime.store.state.window?.diary.diary.completedFetchCount ?? -1
    }

    private func makeStoreBackedRuntime(
        authority: CalCoSessionAuthority,
        box: SessionStreamBox,
        logs: [FoodLog],
        diaryService: (any DiaryServicing)? = nil
    ) -> NativeWindowRuntime {
        NativeWindowRuntime(
            sessionAuthority: authority,
            makeDiaryService: { _ in diaryService ?? EmptyDiaryService() },
            logSubmissionService: LogSubmissionService(
                sender: RecordingLogSender(logs: logs)
            ),
            diaryScreenOwnership: .storeBackedScreen,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies,
                    authority: authority,
                    box: box,
                    overrideClients: true
                )
            }
        )
    }

    /// Load the TCA owner explicitly; the transitional legacy bootstrap is not
    /// evidence that the Store has loaded or that a mutation refreshed it.
    private func loadMutationDiary(_ runtime: NativeWindowRuntime) async {
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialLegacyFetch(runtime)
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        await awaitSettledVisibleDay(runtime, date: initialDate)
        XCTAssertEqual(fetchCount(in: runtime), 1)
    }

    func testFoodDetailVisibleDateInvalidatesAndRefreshesStoreOnceWithoutLegacyRead() async throws {
        let (authority, _) = makeAuthority()
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority, box: SessionStreamBox(), logs: [], diaryService: service
        )
        await loadMutationDiary(runtime)
        let legacy = try XCTUnwrap(runtime.coordinator.diaryViewModel)
        let legacyReads = legacy.completedFetchCount
        let reads = service.fetchCallCount
        var recents = 0
        runtime.coordinator.installTCASearchHandlers(
            contextChanged: { _, _, _ in }, recentsInvalidated: { _ in recents += 1 }
        )
        runtime.coordinator.openFoodDetail("qa-apple", date: initialDate, mealSlot: .breakfast)
        let source = try XCTUnwrap(runtime.coordinator.foodDetailViewModel(for: "qa-apple"))
        let delivery = try XCTUnwrap(runtime.coordinator.handleFoodDetailSuccess(source))
        await delivery.value
        XCTAssertEqual(fetchCount(in: runtime), 2)
        XCTAssertEqual(service.fetchCallCount, reads + 1)
        XCTAssertEqual(legacy.completedFetchCount, legacyReads)
        XCTAssertEqual(recents, 1)
        XCTAssertNil(runtime.store.state.window?.diary.diary.mutationNotice)
        XCTAssertNil(runtime.coordinator.handleFoodDetailSuccess(source))
        XCTAssertEqual(fetchCount(in: runtime), 2)
        XCTAssertEqual(service.fetchCallCount, reads + 1)
        XCTAssertEqual(recents, 1)
    }

    func testFoodDetailNonvisibleDateInvalidatesWithoutFetchingOrMovingReplacement() async throws {
        let (authority, _) = makeAuthority()
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority, box: SessionStreamBox(), logs: [], diaryService: service
        )
        await loadMutationDiary(runtime)
        let historical = initialDate.addingDays(-7)
        await runtime.store.send(.window(.diary(.diary(.selectDate(historical))))).finish()
        await runtime.store.send(.window(.diary(.latest(.loadIfNeeded)))).finish()
        await runtime.store.send(.window(.diary(.diary(.selectDate(initialDate))))).finish()
        await runtime.store.send(.window(.diary(.latest(.loadIfNeeded)))).finish()
        let latestBefore = try XCTUnwrap(runtime.store.state.window?.diary.latest)
        for date in [historical, initialDate] {
            if case .settled(.success) = latestBefore.cache.entry(for: date) {} else {
                XCTFail("Latest cache must be seeded before mutation")
            }
        }
        runtime.coordinator.openFoodDetail("qa-apple", date: historical, mealSlot: .breakfast)
        let old = try XCTUnwrap(runtime.coordinator.foodDetailViewModel(for: "qa-apple"))
        runtime.coordinator.openFoodDetail("qa-other", date: initialDate, mealSlot: .dinner)
        let replacement = try XCTUnwrap(runtime.coordinator.foodDetailViewModel(for: "qa-other"))
        XCTAssertFalse(old === replacement)
        let navigation = runtime.coordinator.navigationState
        let reads = service.fetchCallCount
        let storeReads = fetchCount(in: runtime)
        let delivery = try XCTUnwrap(runtime.coordinator.handleFoodDetailSuccess(old))
        await delivery.value
        guard let diary = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing Diary owner")
        }
        if case .notRequested = diary.cache.entry(for: historical) {} else {
            XCTFail("Nonvisible affected date retained its pre-mutation cache")
        }
        let latestAfter = try XCTUnwrap(runtime.store.state.window?.diary.latest)
        for date in [historical, initialDate] {
            if case .notRequested = latestAfter.cache.entry(for: date) {} else {
                XCTFail("Mutation retained stale latest-slot suggestions for \(date)")
            }
        }
        XCTAssertEqual(latestAfter.phase, .idle(destinationDate: initialDate))
        XCTAssertEqual(diary.selectedDate, initialDate)
        XCTAssertEqual(runtime.coordinator.navigationState, navigation)
        XCTAssertTrue(runtime.coordinator.foodDetailViewModel(for: "qa-other") === replacement)
        XCTAssertEqual(fetchCount(in: runtime), storeReads)
        XCTAssertEqual(service.fetchCallCount, reads)
    }

    func testFoodDetailDeliveryIsRejectedByNewerStoreGeneration() async throws {
        let (authority, _) = makeAuthority()
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority, box: SessionStreamBox(), logs: [], diaryService: service
        )
        await loadMutationDiary(runtime)
        runtime.coordinator.openFoodDetail("qa-apple", date: initialDate, mealSlot: .breakfast)
        let detail = try XCTUnwrap(runtime.coordinator.foodDetailViewModel(for: "qa-apple"))
        let generation = runtime.coordinator.session.sessionGeneration
        runtime.store.send(.sessionSnapshot(SessionSnapshot(
            phase: .signedOut(.signedOut), generation: generation + 1
        )))
        let reads = service.fetchCallCount
        let delivery = try XCTUnwrap(runtime.coordinator.handleFoodDetailSuccess(detail))
        await delivery.value
        XCTAssertNil(runtime.store.state.window)
        XCTAssertEqual(service.fetchCallCount, reads)
    }

    func testMealsAndLibrarySharedSubmissionThenLoggedDoesNotDeliverTwice() async {
        let (authority, _) = makeAuthority()
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority, box: SessionStreamBox(), logs: [], diaryService: service
        )
        await loadMutationDiary(runtime)
        let generation = runtime.coordinator.session.sessionGeneration
        let submit = runtime.coordinator.featureSubmissionHandler(expectedGeneration: generation)
        let logged = runtime.coordinator.featureLoggedHandler(expectedGeneration: generation)
        let legacyReads = runtime.coordinator.diaryViewModel?.completedFetchCount
        var recents = 0
        runtime.coordinator.installTCASearchHandlers(
            contextChanged: { _, _, _ in }, recentsInvalidated: { _ in recents += 1 }
        )
        // Meals list/direct hosts and the Library adapter use this same writer.
        let completion = SubmissionCompletionGate()
        submit([makeDraft(date: initialDate)], ["Apple"], "Apple", completion.record)
        await completion.wait()
        XCTAssertEqual(completion.results, [.success([])])
        XCTAssertEqual(fetchCount(in: runtime), 2)
        logged(initialDate, .breakfast)
        XCTAssertEqual(fetchCount(in: runtime), 2)
        XCTAssertEqual(recents, 1)
        XCTAssertEqual(runtime.coordinator.diaryViewModel?.completedFetchCount, legacyReads)

        // Nonvisible writes still invalidate recents even though the hidden
        // legacy Diary has never selected that date. They must not read Today.
        let historical = initialDate.addingDays(-7)
        let library = HandlerLibraryLogSubmissionService(handler: submit)
        let result = await library.submit(
            accountID: runtime.coordinator.currentUser?.id ?? "", drafts: [makeDraft(date: historical)],
            itemNames: ["Apple"], summary: "Apple", baseURL: baseURL
        )
        XCTAssertEqual(result, .success([]))
        logged(historical, .breakfast)
        XCTAssertEqual(fetchCount(in: runtime), 2)
        XCTAssertEqual(recents, 2)
        XCTAssertEqual(runtime.coordinator.diaryViewModel?.completedFetchCount, legacyReads)
    }

    func testLegacyMealsListAndDirectLibraryKeepTheirExistingRefreshCounts() async throws {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let service = StoreBackedDiaryService(logs: [])
        let runtime = NativeWindowRuntime(
            sessionAuthority: authority, makeDiaryService: { _ in service },
            logSubmissionService: LogSubmissionService(sender: RecordingLogSender(logs: [])),
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies, authority: authority, box: box, overrideClients: true
                )
            }
        )
        await loadMutationDiary(runtime)
        let generation = runtime.coordinator.session.sessionGeneration
        let legacy = try XCTUnwrap(runtime.coordinator.diaryViewModel)
        let target = legacy.selectedDate
        XCTAssertEqual(legacy.completedFetchCount, 1)
        XCTAssertNil(runtime.coordinator.mealsListLoggedHandler(expectedGeneration: generation))
        let completion = SubmissionCompletionGate()
        runtime.coordinator.featureSubmissionHandler(expectedGeneration: generation)(
            [makeDraft(date: target)], ["Apple"], "Apple", completion.record
        )
        await completion.wait()
        XCTAssertEqual(completion.results, [.success([])])
        XCTAssertEqual(legacy.completedFetchCount, 2, "Legacy list shared writer refreshes once")
        var recents = 0
        runtime.coordinator.installTCASearchHandlers(
            contextChanged: { _, _, _ in }, recentsInvalidated: { _ in recents += 1 }
        )
        runtime.coordinator.featureLoggedHandler(expectedGeneration: generation)(target, .breakfast)
        await awaitLegacyFetchCount(legacy, equals: 3)
        XCTAssertEqual(recents, 1, "Existing direct Meals/Library post-log hook remains")
        XCTAssertEqual(fetchCount(in: runtime), 1, "Legacy delivery never refreshes Store")
        runtime.coordinator.featureLoggedHandler(expectedGeneration: generation)(target.addingDays(-7), nil)
        XCTAssertEqual(legacy.completedFetchCount, 3)
        XCTAssertEqual(recents, 1, "Legacy nonvisible-date behavior remains unchanged")
    }

    func testLibraryLogOnlyAndSaveAndLogEachRefreshOnceAndNotifyRecentsOnce() async {
        for mode in [AdHocSaveMode.logOnly, .saveAndLog] {
            let (authority, _) = makeAuthority()
            let service = StoreBackedDiaryService(logs: [])
            let runtime = makeStoreBackedRuntime(
                authority: authority, box: SessionStreamBox(), logs: [], diaryService: service
            )
            await loadMutationDiary(runtime)
            let generation = runtime.coordinator.session.sessionGeneration
            let library = FakeLibraryService()
            library.enqueueCreate(.success("saved-bowl"))
            var recents = 0
            runtime.coordinator.installTCASearchHandlers(
                contextChanged: { _, _, _ in }, recentsInvalidated: { _ in recents += 1 }
            )
            let legacyReads = runtime.coordinator.diaryViewModel?.completedFetchCount
            let reads = service.fetchCallCount
            let editor = AdHocLogViewModel(
                service: library,
                submissionService: HandlerLibraryLogSubmissionService(
                    handler: runtime.coordinator.featureSubmissionHandler(expectedGeneration: generation)
                ),
                accountID: runtime.coordinator.currentUser?.id ?? "",
                initialDate: initialDate, today: initialDate, initialMealSlot: .breakfast,
                onLogged: runtime.coordinator.featureLoggedHandler(expectedGeneration: generation)
            )
            await editor.load()
            editor.name = "Bowl"
            editor.amount = "100"
            editor.unit = "g"
            editor.mode = mode
            editor.setNutrientAmount("250", code: NutrientCodes.energyKcal)
            editor.setNutrientAmount("10", code: NutrientCodes.proteinG)
            editor.setNutrientAmount("40", code: NutrientCodes.carbsG)
            editor.setNutrientAmount("5", code: NutrientCodes.fatG)
            editor.requestReview()
            await editor.confirmReview()
            XCTAssertTrue(editor.isSubmissionCompleted)
            XCTAssertEqual(fetchCount(in: runtime), 2)
            XCTAssertEqual(service.fetchCallCount, reads + 1)
            XCTAssertEqual(recents, 1)
            XCTAssertEqual(runtime.coordinator.diaryViewModel?.completedFetchCount, legacyReads)
            XCTAssertEqual(library.createCallCount, mode == .saveAndLog ? 1 : 0)
        }
    }

    func testLibraryMetadataSaveDoesNotMutateDiaryOrRecents() async {
        let (authority, _) = makeAuthority()
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority, box: SessionStreamBox(), logs: [], diaryService: service
        )
        await loadMutationDiary(runtime)
        let library = FakeLibraryService()
        library.enqueueCreate(.success("metadata-food"))
        var recents = 0
        var saved = 0
        runtime.coordinator.installTCASearchHandlers(
            contextChanged: { _, _, _ in }, recentsInvalidated: { _ in recents += 1 }
        )
        let reads = service.fetchCallCount
        let editor = CustomFoodEditorViewModel(
            mode: .create, service: library, accountID: runtime.coordinator.currentUser?.id ?? "",
            onSaved: { _ in saved += 1 }
        )
        await editor.load()
        editor.name = "Metadata only"
        editor.defaultQuantity = "100"
        editor.defaultUnit = "g"
        editor.setNutrientAmount("250", code: NutrientCodes.energyKcal)
        editor.setNutrientAmount("10", code: NutrientCodes.proteinG)
        editor.setNutrientAmount("40", code: NutrientCodes.carbsG)
        editor.setNutrientAmount("5", code: NutrientCodes.fatG)
        await editor.submit()
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(library.createCallCount, 1)
        XCTAssertEqual(fetchCount(in: runtime), 1)
        XCTAssertEqual(service.fetchCallCount, reads)
        XCTAssertEqual(recents, 0)
    }

    func testStoreBackedCallbackAppliesAcrossDatesAndRefreshesVisibleOnlyOnce() async {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let historical = initialDate.addingDays(-7)
        let noValid = initialDate.addingDays(-9)
        let service = StoreBackedDiaryService(logs: [
            makeLog(id: "log-today", date: initialDate),
            makeLog(id: "log-historical", date: historical),
        ])
        let runtime = makeStoreBackedRuntime(
            authority: authority,
            box: box,
            logs: [
                makeLog(id: "log-today", date: initialDate),
                makeLog(id: "log-historical", date: historical),
            ],
            diaryService: service
        )
        await ensureSignedIn(runtime)

        // Seed a third date, then return to the visible day. Its cache must be
        // explicitly invalidated by the callback because no valid row arrived.
        await runtime.store.send(.window(.diary(.diary(.selectDate(noValid))))).finish()
        await runtime.store.send(.window(.diary(.diary(.selectDate(initialDate))))).finish()
        let baseline = fetchCount(in: runtime)
        XCTAssertGreaterThanOrEqual(baseline, 1)

        let generation = runtime.coordinator.session.sessionGeneration
        let completion = SubmissionCompletionGate()
        runtime.coordinator.submitDraftsForFeature(
            [
                makeDraft(date: initialDate),
                makeDraft(date: historical),
                makeDraft(date: noValid),
            ],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: generation,
            completion: completion.record
        )
        await completion.wait()

        guard let screen = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing store-backed diary state")
        }
        // The visible date is authoritatively re-fetched by the single refresh,
        // which legitimately prunes its local override once the server row has
        // caught up. Assert the returned row itself, exactly once, in both the
        // visible day and the settled cache — never a relaxed "anything goes".
        XCTAssertEqual(
            screen.visibleDay?.logs.filter { $0.id == "log-today" }.count, 1,
            "The visible day must show the returned row exactly once"
        )
        if case .settled(.success(let visibleCached)) = screen.cache.entry(for: initialDate) {
            XCTAssertEqual(
                visibleCached.logs.filter { $0.id == "log-today" }.count, 1,
                "The settled visible cache must hold the returned row exactly once"
            )
        } else {
            XCTFail("The visible cache was not settled by the refresh")
        }
        // The non-visible date has no refresh: its local override is preserved.
        XCTAssertEqual(
            screen.savedLogOverrides[historical]?["log-historical"]?.id,
            "log-historical"
        )
        if case .notRequested = screen.cache.entry(for: noValid) {
            // expected: non-visible date with no valid rows was invalidated
        } else {
            XCTFail("A no-valid-row affected date kept a stale cache entry")
        }
        XCTAssertEqual(
            fetchCount(in: runtime), baseline + 1,
            "Only the visible affected date may trigger exactly one read"
        )
        XCTAssertEqual(
            screen.completedFetchCount, baseline + 1,
            "Search.diaryChanged must not cause a second refresh"
        )
    }

    /// A store that has moved to a newer session must ignore a delivery captured
    /// under the old generation, even when the coordinator writer is still
    /// current. No rows are applied and no read is issued.
    func testStoreBackedCallbackIgnoresStaleStoreGeneration() async {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let historical = initialDate.addingDays(-7)
        let service = StoreBackedDiaryService(logs: [
            makeLog(id: "log-stale", date: historical)
        ])
        let runtime = makeStoreBackedRuntime(
            authority: authority,
            box: box,
            logs: [makeLog(id: "log-stale", date: historical)],
            diaryService: service
        )
        await ensureSignedIn(runtime)

        guard let signedInUser = runtime.coordinator.currentUser else {
            return XCTFail("Missing signed-in user before the generation flip")
        }
        let generation = runtime.coordinator.session.sessionGeneration
        // The store moves to a newer session: AppFeature legitimately tears down
        // the signed-in window. The captured delivery is now stale.
        runtime.store.send(
            .sessionSnapshot(SessionSnapshot(phase: .signedOut(.signedOut), generation: generation + 1))
        )
        XCTAssertEqual(runtime.store.state.sessionGeneration, generation + 1)
        guard case .signedOut = runtime.store.state.phase else {
            return XCTFail("Expected the root to be signed out after the new snapshot")
        }
        XCTAssertNil(runtime.store.state.window, "A newer generation must tear down the window")
        let baselineGET = service.fetchCallCount

        let completion = SubmissionCompletionGate()
        runtime.coordinator.submitDraftsForFeature(
            [makeDraft(date: historical)],
            itemNames: ["Apple"],
            summary: "Apple",
            expectedGeneration: generation,
            completion: completion.record
        )
        await completion.wait()

        XCTAssertEqual(completion.results.count, 1)
        XCTAssertEqual(service.fetchCallCount, baselineGET, "A stale delivery must issue no GET")

        // A fresh session installed with the new generation must not inherit any
        // row or read from the stale delivery.
        runtime.store.send(
            .sessionSnapshot(SessionSnapshot(phase: .signedIn(signedInUser), generation: generation + 1))
        )
        guard let fresh = runtime.store.state.window?.diary.diary else {
            return XCTFail("Expected a fresh window for the new generation")
        }
        XCTAssertNil(fresh.savedLogOverrides[historical]?["log-stale"])
        XCTAssertEqual(fresh.completedFetchCount, 0, "The new session performed no stale refresh")
    }

    /// ALL affected dates have zero valid rows. Every affected cache entry is
    /// invalidated through the feature-owned action, and the one visible
    /// affected date is re-fetched exactly once — no date is silently dropped.
    func testStoreBackedCallbackInvalidatesAllNoValidDatesAndRefreshesVisibleOnce() async {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let first = initialDate.addingDays(-5)
        let second = initialDate.addingDays(-6)
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority,
            box: box,
            logs: [],
            diaryService: service
        )
        await ensureSignedIn(runtime)

        // Seed every affected entry through the real runtime diary client/GET
        // path, then return to the visible day. No private cache mutation.
        await runtime.store.send(.window(.diary(.diary(.selectDate(first))))).finish()
        await runtime.store.send(.window(.diary(.diary(.selectDate(second))))).finish()
        await runtime.store.send(.window(.diary(.diary(.selectDate(initialDate))))).finish()
        guard let before = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing seeded store-backed diary state")
        }
        let baselineFetch = before.completedFetchCount
        let baselineGET = service.fetchCallCount
        for date in [first, second] {
            if case .settled = before.cache.entry(for: date) {
                // seeded
            } else {
                XCTFail("Could not seed cache for \(date.formatted)")
            }
        }

        let generation = runtime.coordinator.session.sessionGeneration
        let completion = SubmissionCompletionGate()
        runtime.coordinator.submitDraftsForFeature(
            [
                makeDraft(date: initialDate),
                makeDraft(date: first),
                makeDraft(date: second),
            ],
            itemNames: ["Apple", "Apple", "Apple"],
            summary: "Three",
            expectedGeneration: generation,
            completion: completion.record
        )
        await completion.wait()

        guard let after = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing store-backed diary state after delivery")
        }
        for date in [first, second] {
            if case .notRequested = after.cache.entry(for: date) {
                // explicit invalidation, not a dropped date
            } else {
                XCTFail("Affected date \(date.formatted) kept a stale cache entry")
            }
            var probe = after.cache
            XCTAssertNotNil(
                probe.request(date),
                "The pre-write token must no longer settle after invalidation"
            )
        }
        if case .settled(.success(let settledVisible)) = after.cache.entry(for: initialDate) {
            XCTAssertEqual(settledVisible.date, initialDate)
        } else {
            XCTFail("The visible affected date was not re-settled by its single GET")
        }
        XCTAssertTrue(
            after.visibleDay?.logs.isEmpty ?? false,
            "No local stale row may survive a zero-valid-row delivery"
        )
        XCTAssertEqual(after.completedFetchCount, baselineFetch + 1, "Exactly one visible read")
        XCTAssertEqual(service.fetchCallCount, baselineGET + 1, "Exactly one GET after the write")
    }

    /// When no affected date is visible, the owner must invalidate all of them
    /// without issuing any authoritative read at all.
    func testStoreBackedCallbackWithOnlyNonVisibleDatesIssuesNoGet() async {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let first = initialDate.addingDays(-5)
        let second = initialDate.addingDays(-6)
        let service = StoreBackedDiaryService(logs: [])
        let runtime = makeStoreBackedRuntime(
            authority: authority,
            box: box,
            logs: [],
            diaryService: service
        )
        await ensureSignedIn(runtime)

        await runtime.store.send(.window(.diary(.diary(.selectDate(first))))).finish()
        await runtime.store.send(.window(.diary(.diary(.selectDate(second))))).finish()
        await runtime.store.send(.window(.diary(.diary(.selectDate(initialDate))))).finish()
        guard let before = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing seeded store-backed diary state")
        }
        let baselineFetch = before.completedFetchCount
        let baselineGET = service.fetchCallCount

        let generation = runtime.coordinator.session.sessionGeneration
        let completion = SubmissionCompletionGate()
        runtime.coordinator.submitDraftsForFeature(
            [makeDraft(date: first), makeDraft(date: second)],
            itemNames: ["Apple", "Apple"],
            summary: "Two",
            expectedGeneration: generation,
            completion: completion.record
        )
        await completion.wait()

        guard let after = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing store-backed diary state after delivery")
        }
        for date in [first, second] {
            if case .notRequested = after.cache.entry(for: date) {
                // expected
            } else {
                XCTFail("Non-visible affected date \(date.formatted) was not invalidated")
            }
        }
        XCTAssertEqual(service.fetchCallCount, baselineGET, "No affected date was visible")
        XCTAssertEqual(after.completedFetchCount, baselineFetch, "No refresh was issued")
    }

    /// The installed callback captures the store weakly; releasing the runtime
    /// must release both store and coordinator with no manual teardown.
    func testStoreBackedCallbackDoesNotRetainStoreOrCoordinator() async {
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        var runtime: NativeWindowRuntime? = makeStoreBackedRuntime(
            authority: authority,
            box: box,
            logs: []
        )
        var store: StoreOf<AppFeature>? = runtime!.store
        var coordinator: AppShellCoordinator? = runtime!.coordinator
        weak var weakStore = store
        weak var weakCoordinator = coordinator

        await ensureSignedIn(runtime!)
        XCTAssertNotNil(weakStore)
        XCTAssertNotNil(weakCoordinator)

        runtime = nil
        store = nil
        coordinator = nil
        XCTAssertNil(weakStore, "The installed callback retained the store")
        XCTAssertNil(weakCoordinator, "The installed callback retained the coordinator")
    }

    // MARK: - Installed settings-goal handler (real SettingsVM.saveGoals)

    private func makeGoalRuntime(
        authority: CalCoSessionAuthority,
        box: SessionStreamBox,
        diaryService: GoalAwareDiaryService,
        settingsService: GoalSaveSettingsService
    ) -> NativeWindowRuntime {
        NativeWindowRuntime(
            sessionAuthority: authority,
            makeDiaryService: { _ in diaryService },
            makeSettingsService: { _ in settingsService },
            diaryScreenOwnership: .storeBackedScreen,
            configureDependencies: { dependencies, _ in
                self.applyStableDependencies(
                    &dependencies,
                    authority: authority,
                    box: box,
                    overrideClients: true
                )
            }
        )
    }

    /// Absolute bootstrap contract: the legacy VM's first fetch completes
    /// before any later counter is measured. No relative baseline or sleep.
    private func awaitAbsoluteInitialLegacyFetch(_ runtime: NativeWindowRuntime) async {
        guard let viewModel = runtime.coordinator.diaryViewModel else {
            XCTFail("Missing legacy diary view model for bootstrap")
            return
        }
        if viewModel.completedFetchCount >= 1 { return }
        await awaitLegacyFetchCount(viewModel, equals: 1)
    }

    private func awaitLegacyFetchCount(_ viewModel: DiaryViewModel, equals target: Int) async {
        if viewModel.completedFetchCount == target { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = RuntimeWaitBox()
            box.continuation = continuation
            box.cancellable = viewModel.$completedFetchCount.sink { count in
                guard !box.fulfilled, count == target else { return }
                box.fulfilled = true
                let pending = box.continuation
                box.continuation = nil
                box.cancellable?.cancel()
                box.cancellable = nil
                pending?.resume()
            }
        }
    }

    /// Deterministic rendezvous on store state (never objectWillChange), with
    /// no sleep, yield, poll, or disabled test.
    private func awaitStoreCondition(
        _ store: StoreOf<AppFeature>,
        condition: @escaping @MainActor (AppFeature.State) -> Bool
    ) async {
        if condition(store.state) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = RuntimeWaitBox()
            box.continuation = continuation
            box.cancellable = store.publisher.sink { _ in
                Task { @MainActor in
                    guard !box.fulfilled, condition(store.state) else { return }
                    box.fulfilled = true
                    let pending = box.continuation
                    box.continuation = nil
                    box.cancellable?.cancel()
                    box.cancellable = nil
                    pending?.resume()
                }
            }
        }
    }

    private func awaitSettledVisibleDay(
        _ runtime: NativeWindowRuntime,
        date: LocalDiaryDate
    ) async {
        await awaitStoreCondition(runtime.store) { state in
            guard let diary = state.window?.diary.diary,
                  diary.selectedDate == date,
                  diary.visibleDay?.date == date,
                  case .loaded(_, .settled) = diary.phase else { return false }
            return true
        }
    }

    private func awaitGoalSettingsLoaded(_ settings: DiarySettingsViewModel) async {
        if case .loaded = settings.goalState { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = RuntimeWaitBox()
            box.continuation = continuation
            box.cancellable = settings.$goalState.sink { state in
                guard !box.fulfilled, case .loaded = state else { return }
                box.fulfilled = true
                let pending = box.continuation
                box.continuation = nil
                box.cancellable?.cancel()
                box.cancellable = nil
                pending?.resume()
            }
        }
    }

    /// Deterministic rendezvous on the settings view model's own published
    /// preferences state — no sleep, yield, poll or duration.
    private func awaitPreferencesSettingsLoaded(_ settings: DiarySettingsViewModel) async {
        if case .loaded = settings.preferencesState { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = RuntimeWaitBox()
            box.continuation = continuation
            box.cancellable = settings.$preferencesState.sink { state in
                guard !box.fulfilled, case .loaded = state else { return }
                box.fulfilled = true
                let pending = box.continuation
                box.continuation = nil
                box.cancellable?.cancel()
                box.cancellable = nil
                pending?.resume()
            }
        }
    }

    /// Drives the real settings view model. The draft disables breakfast only;
    /// the server response deliberately disables lunch as well.
    private func saveDifferentPreferencesDraft(in runtime: NativeWindowRuntime) async {
        runtime.coordinator.showSettings()
        guard let settings = runtime.coordinator.settingsViewModel else {
            XCTFail("The settings view model was not installed")
            return
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()
    }

    /// Drives the real settings view model. The typed draft is valid
    /// (170*4 + 210*4 + 70*9 = 2150) and differs from the server response.
    private func saveDifferentGoalDraft(in runtime: NativeWindowRuntime) async {
        runtime.coordinator.showSettings()
        guard let settings = runtime.coordinator.settingsViewModel else {
            XCTFail("The settings view model was not installed")
            return
        }
        await awaitGoalSettingsLoaded(settings)
        settings.calorieTarget = "2150"
        settings.proteinTargetG = "170"
        settings.carbsTargetG = "210"
        settings.fatTargetG = "70"
        await settings.saveGoals()
    }

    func testInstalledGoalHandlerUpdatesVisibleTodayWithoutFetchOrNotice() async {
        let goalBox = GoalStateBox(targets: initialGoalTargets)
        let diaryService = GoalAwareDiaryService(goalBox: goalBox)
        let settingsService = GoalSaveSettingsService(
            goalBox: goalBox, initialDate: initialDate
        )
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let runtime = makeGoalRuntime(
            authority: authority,
            box: box,
            diaryService: diaryService,
            settingsService: settingsService
        )
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialLegacyFetch(runtime)

        // Load the actual TCA screen before measuring the goal-writeback baseline.
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        await awaitSettledVisibleDay(runtime, date: initialDate)
        guard let before = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing TCA diary state before the save")
        }
        let baselineFetch = before.completedFetchCount
        let baselineGET = diaryService.fetchCallCount
        let baselineOverrides = before.savedLogOverrides
        let baselineTombstones = before.deletedIDs
        XCTAssertNil(before.mutationNotice, "No notice before the save")
        XCTAssertNil(before.pendingGoalOverride, "No in-flight goal override at baseline")

        await saveDifferentGoalDraft(in: runtime)

        guard let after = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing TCA diary state after the save")
        }
        XCTAssertEqual(after.visibleDay?.goal, savedGoalTargets)
        XCTAssertEqual(after.completedFetchCount, baselineFetch, "No local refetch")
        XCTAssertEqual(diaryService.fetchCallCount, baselineGET, "No authoritative GET")
        XCTAssertNil(after.mutationNotice, "A goal save issues no mutation notice")
        XCTAssertNil(after.pendingGoalOverride, "A settled day needs no pending override")
        XCTAssertEqual(after.savedLogOverrides, baselineOverrides, "Row overrides preserved")
        XCTAssertEqual(after.deletedIDs, baselineTombstones, "Tombstones preserved")
        // Cache lineage: applySavedGoal updates the visible day only; the
        // settled cache entry is not reseeded because no GET happened.
        if case .settled(.success(let cached)) = after.cache.entry(for: initialDate) {
            XCTAssertEqual(cached.goal, initialGoalTargets)
        } else {
            XCTFail("The visible day's settled cache entry was lost")
        }
    }

    func testInstalledGoalHandlerOnHistoryIsInertUntilReturnToToday() async {
        let historical = initialDate.addingDays(-1)
        let goalBox = GoalStateBox(targets: initialGoalTargets)
        let diaryService = GoalAwareDiaryService(goalBox: goalBox)
        let settingsService = GoalSaveSettingsService(
            goalBox: goalBox, initialDate: initialDate
        )
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let runtime = makeGoalRuntime(
            authority: authority,
            box: box,
            diaryService: diaryService,
            settingsService: settingsService
        )
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialLegacyFetch(runtime)

        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        await awaitSettledVisibleDay(runtime, date: initialDate)
        await runtime.store.send(.window(.diary(.diary(.selectDate(historical))))).finish()
        await awaitSettledVisibleDay(runtime, date: historical)

        // Baseline is captured AFTER the previous-day read, so the next-day
        // assertion is exactly +1 (two navigations total, not an ambiguous +1).
        guard let atHistory = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing historical TCA diary state")
        }
        let baselineAfterPrevious = atHistory.completedFetchCount
        let baselineGET = diaryService.fetchCallCount

        await saveDifferentGoalDraft(in: runtime)

        guard let afterSave = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing TCA diary state after the save")
        }
        XCTAssertEqual(afterSave.visibleDay?.goal, initialGoalTargets, "History unaffected")
        XCTAssertEqual(afterSave.completedFetchCount, baselineAfterPrevious, "No GET on history")
        XCTAssertEqual(diaryService.fetchCallCount, baselineGET, "No GET on history")

        await runtime.store.send(.window(.diary(.diary(.selectDate(initialDate))))).finish()
        await awaitSettledVisibleDay(runtime, date: initialDate)
        guard let backToday = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing today TCA diary state after returning")
        }
        XCTAssertEqual(backToday.visibleDay?.goal, savedGoalTargets, "Server goal on revisit")
        XCTAssertEqual(backToday.completedFetchCount, baselineAfterPrevious + 1)
        XCTAssertEqual(diaryService.fetchCallCount, baselineGET + 1)
    }

    /// The goal handler is installed once by the runtime with a weak store
    /// capture. Releasing the sole optional owner must release both store and
    /// coordinator; the handler under test is never replaced by a test closure.
    func testInstalledGoalHandlerDoesNotRetainStoreOrCoordinator() async {
        let goalBox = GoalStateBox(targets: initialGoalTargets)
        let diaryService = GoalAwareDiaryService(goalBox: goalBox)
        let settingsService = GoalSaveSettingsService(
            goalBox: goalBox, initialDate: initialDate
        )
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        var runtime: NativeWindowRuntime? = makeGoalRuntime(
            authority: authority,
            box: box,
            diaryService: diaryService,
            settingsService: settingsService
        )
        var store: StoreOf<AppFeature>? = runtime!.store
        var coordinator: AppShellCoordinator? = runtime!.coordinator
        weak var weakStore = store
        weak var weakCoordinator = coordinator

        await ensureSignedIn(runtime!)
        await awaitAbsoluteInitialLegacyFetch(runtime!)
        await saveDifferentGoalDraft(in: runtime!)
        XCTAssertNotNil(weakStore)
        XCTAssertNotNil(weakCoordinator)

        runtime = nil
        store = nil
        coordinator = nil
        XCTAssertNil(weakStore, "The installed goal handler retained the store")
        XCTAssertNil(weakCoordinator, "The installed goal handler retained the coordinator")
    }

    // MARK: - Installed settings-preferences handler (real SettingsVM.savePreferences)

    func testInstalledPreferencesHandlerUpdatesVisiblePrefsWithoutFetchOrNotice() async {
        let goalBox = GoalStateBox(targets: initialGoalTargets)
        let prefsBox = PreferencesStateBox(
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        )
        let diaryService = GoalAwareDiaryService(goalBox: goalBox, prefsBox: prefsBox)
        // The server response differs from the typed draft: only the mapped
        // server prefs may reach the store-backed owner.
        let authoritative = DiaryPreferences(enabledSlots: [.dinner, .snack, .lateNightSnack])
        let settingsService = GoalSaveSettingsService(
            goalBox: goalBox,
            initialDate: initialDate,
            prefsBox: prefsBox,
            authoritativePreferencesSave: authoritative
        )
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        let runtime = makeGoalRuntime(
            authority: authority,
            box: box,
            diaryService: diaryService,
            settingsService: settingsService
        )
        await ensureSignedIn(runtime)
        await awaitAbsoluteInitialLegacyFetch(runtime)

        // Load the actual TCA screen before measuring the writeback baseline.
        await runtime.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        await awaitSettledVisibleDay(runtime, date: initialDate)
        guard let before = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing TCA diary state before the save")
        }
        let baselineFetch = before.completedFetchCount
        let baselineGET = diaryService.fetchCallCount
        let baselineLogs = before.visibleDay?.logs ?? []
        let baselineGoal = before.visibleDay?.goal
        let baselineOverrides = before.savedLogOverrides
        let baselineTombstones = before.deletedIDs
        let baselineMacro = before.macroMode
        XCTAssertNil(before.mutationNotice, "No notice before the save")
        XCTAssertEqual(
            before.visibleDay?.prefs, DiaryPrefs(enabledSlots: Set(MealSlot.allCases)),
            "Unexpected baseline prefs"
        )

        await saveDifferentPreferencesDraft(in: runtime)

        guard let after = runtime.store.state.window?.diary.diary else {
            return XCTFail("Missing TCA diary state after the save")
        }
        let mapped = CalCoStoreMapping.diaryPrefs(from: authoritative)
        XCTAssertEqual(after.visibleDay?.prefs, mapped)
        XCTAssertFalse(after.visibleDay?.prefs.isEnabled(.lunch) ?? true, "The server response must win")
        XCTAssertEqual(after.completedFetchCount, baselineFetch, "No local refetch")
        XCTAssertEqual(diaryService.fetchCallCount, baselineGET, "No authoritative GET")
        XCTAssertNil(after.mutationNotice, "A preference save issues no mutation notice")
        XCTAssertEqual(after.visibleDay?.logs, baselineLogs, "Logs preserved")
        XCTAssertEqual(after.visibleDay?.goal, baselineGoal, "Goals preserved")
        XCTAssertEqual(after.savedLogOverrides, baselineOverrides, "Row overrides preserved")
        XCTAssertEqual(after.deletedIDs, baselineTombstones, "Tombstones preserved")
        XCTAssertEqual(after.macroMode, baselineMacro, "Macro mode preserved")
        // Cache lineage: applySavedPreferences updates the visible day only;
        // the settled cache entry is not reseeded because no GET happened.
        if case .settled(.success(let cached)) = after.cache.entry(for: initialDate) {
            XCTAssertEqual(
                cached.prefs, DiaryPrefs(enabledSlots: Set(MealSlot.allCases)),
                "The historical cache must not be rewritten"
            )
        } else {
            XCTFail("The visible day's settled cache entry was lost")
        }
    }

    /// The preferences handler is installed once by the runtime with a weak
    /// store capture. Releasing the sole optional owner must release both store
    /// and coordinator; the handler under test is never replaced by a test
    /// closure.
    func testInstalledPreferencesHandlerDoesNotRetainStoreOrCoordinator() async {
        let goalBox = GoalStateBox(targets: initialGoalTargets)
        let prefsBox = PreferencesStateBox(
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        )
        let diaryService = GoalAwareDiaryService(goalBox: goalBox, prefsBox: prefsBox)
        let settingsService = GoalSaveSettingsService(
            goalBox: goalBox,
            initialDate: initialDate,
            prefsBox: prefsBox,
            authoritativePreferencesSave: DiaryPreferences(enabledSlots: [.dinner])
        )
        let (authority, _) = makeAuthority()
        let box = SessionStreamBox()
        var runtime: NativeWindowRuntime? = makeGoalRuntime(
            authority: authority,
            box: box,
            diaryService: diaryService,
            settingsService: settingsService
        )
        var store: StoreOf<AppFeature>? = runtime!.store
        var coordinator: AppShellCoordinator? = runtime!.coordinator
        weak var weakStore = store
        weak var weakCoordinator = coordinator

        await ensureSignedIn(runtime!)
        await awaitAbsoluteInitialLegacyFetch(runtime!)
        await runtime!.store.send(.window(.diary(.diary(.loadIfNeeded)))).finish()
        await awaitSettledVisibleDay(runtime!, date: initialDate)
        await saveDifferentPreferencesDraft(in: runtime!)
        XCTAssertNotNil(weakStore)
        XCTAssertNotNil(weakCoordinator)

        runtime = nil
        store = nil
        coordinator = nil
        XCTAssertNil(weakStore, "The installed preferences handler retained the store")
        XCTAssertNil(weakCoordinator, "The installed preferences handler retained the coordinator")
    }
}

// MARK: - Store-backed test doubles

private final class EmptyDiaryService: DiaryServicing, @unchecked Sendable {
    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        DiaryDay(date: date, logs: [])
    }
}

/// Real GET seam for the runtime-installed callback tests: it returns the
/// committed rows for each date (as a server would after a successful POST) and
/// counts every authoritative read so extra GETs are observable.
private final class StoreBackedDiaryService: DiaryServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let logs: [FoodLog]
    private var count = 0

    init(logs: [FoodLog]) { self.logs = logs }

    var fetchCallCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        lock.lock(); count += 1; lock.unlock()
        return DiaryDay(
            date: date,
            logs: logs.filter { $0.logDate == date }.map(CalCoStoreMapping.diaryLog(from:))
        )
    }
}

private final class RecordingLogSender: LogSubmissionSending, @unchecked Sendable {
    private let logs: [FoodLog]
    init(logs: [FoodLog]) { self.logs = logs }
    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] { logs }
}

private final class SubmissionCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resultsStorage: [LogSubmissionServiceResult] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var results: [LogSubmissionServiceResult] {
        lock.lock(); defer { lock.unlock() }; return resultsStorage
    }

    func record(_ result: LogSubmissionServiceResult) {
        lock.lock()
        resultsStorage.append(result)
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        lock.lock()
        let alreadyDone = !resultsStorage.isEmpty
        lock.unlock()
        guard !alreadyDone else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.install(c)
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resultsStorage.isEmpty {
            self.continuation = continuation
            lock.unlock()
        } else {
            lock.unlock()
            continuation.resume()
        }
    }
}

// MARK: - Fakes

private final class CountingSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession
    private let lock = NSLock()
    private var restoreCountStorage = 0

    var restoreCount: Int { lock.withLock { restoreCountStorage } }

    init(session: LoginSession) { self.session = session }

    func restoreSession() async throws -> SessionRestoreOutcome {
        lock.withLock { restoreCountStorage += 1 }
        return .authenticated(session)
    }

    func login(username: String, password: String) async throws -> LoginSession {
        session
    }

    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class TestCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

// MARK: - Settings-goal writeback fakes

private final class RuntimeWaitBox: @unchecked Sendable {
    var fulfilled = false
    var continuation: CheckedContinuation<Void, Never>?
    var cancellable: AnyCancellable?
}

/// Shared server-side goal state. The settings save writes here, and the diary
/// GET reads from here, so a later authoritative fetch faithfully returns the
/// saved target without any manual mutation of production state.
private final class GoalStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: DiaryGoalTargets

    init(targets: DiaryGoalTargets) { self.targets = targets }

    var current: DiaryGoalTargets { lock.withLock { targets } }

    func update(_ value: DiaryGoalTargets) {
        lock.withLock { targets = value }
    }
}

/// Shared server-side preference state. The settings save writes here and the
/// diary GET reads from here, so a later authoritative fetch returns the saved
/// slots without any manual mutation of production state.
private final class PreferencesStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var prefs: DiaryPrefs

    init(prefs: DiaryPrefs) { self.prefs = prefs }

    var current: DiaryPrefs { lock.withLock { prefs } }

    func update(_ value: DiaryPrefs) { lock.withLock { prefs = value } }
}

private final class GoalAwareDiaryService: DiaryServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let goalBox: GoalStateBox
    private let prefsBox: PreferencesStateBox?
    private var count = 0

    init(goalBox: GoalStateBox, prefsBox: PreferencesStateBox? = nil) {
        self.goalBox = goalBox
        self.prefsBox = prefsBox
    }

    var fetchCallCount: Int { lock.withLock { count } }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        lock.withLock { count += 1 }
        return DiaryDay(
            date: date,
            logs: [],
            goal: goalBox.current,
            prefs: prefsBox?.current ?? DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        )
    }
}

private final class GoalSaveSettingsService: DiarySettingsServicing, @unchecked Sendable {
    private let goalBox: GoalStateBox
    private let initialDate: LocalDiaryDate
    // Preference knobs default to the original pass-through behaviour.
    private let prefsBox: PreferencesStateBox?
    private let authoritativePreferencesSave: DiaryPreferences?

    init(
        goalBox: GoalStateBox,
        initialDate: LocalDiaryDate,
        prefsBox: PreferencesStateBox? = nil,
        authoritativePreferencesSave: DiaryPreferences? = nil
    ) {
        self.goalBox = goalBox
        self.initialDate = initialDate
        self.prefsBox = prefsBox
        self.authoritativePreferencesSave = authoritativePreferencesSave
    }

    func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
        GoalSnapshot(
            requestedDate: date,
            effectiveFrom: nil,
            source: .default,
            targets: GoalTargets(
                calorieTarget: 2_000,
                proteinTargetG: 150,
                carbsTargetG: 250,
                fatTargetG: 70
            )
        )
    }

    func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot {
        // The server response deliberately differs from the typed draft and is
        // persisted for the next authoritative diary read.
        let saved = GoalSnapshot(
            requestedDate: initialDate,
            effectiveFrom: initialDate,
            source: .saved,
            targets: GoalTargets(
                calorieTarget: 2_230,
                proteinTargetG: 150,
                carbsTargetG: 250,
                fatTargetG: 70
            )
        )
        goalBox.update(CalCoStoreMapping.diaryGoal(from: saved))
        return saved
    }

    func fetchDiaryPreferences() async throws -> DiaryPreferences {
        guard let prefsBox else {
            return DiaryPreferences(enabledSlots: Set(MealSlot.allCases))
        }
        return DiaryPreferences(enabledSlots: prefsBox.current.enabledSlots)
    }

    func updateDiaryPreferences(_ preferences: DiaryPreferences) async throws -> DiaryPreferences {
        let saved = authoritativePreferencesSave ?? preferences
        prefsBox?.update(CalCoStoreMapping.diaryPrefs(from: saved))
        return saved
    }
}
