import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class AppFeatureTests: XCTestCase {
    private final class RoutingRecorder: @unchecked Sendable {
        var foodID: String?
        var foodDate: LocalDiaryDate?
        var foodSlot: MealSlot?
        var foodOrigin: SearchScreenFeature.NavigationOrigin?
        var foodGeneration: UInt64?
        var mealID: String?
        var mealDate: LocalDiaryDate?
        var mealSlot: MealSlot?
        var mealQuantity: NutritionQuantity?
        var mealOrigin: SearchScreenFeature.NavigationOrigin?
        var mealGeneration: UInt64?
        var mealsDate: LocalDiaryDate?
        var mealsSlot: MealSlot?
        var mealsGeneration: UInt64?
        var diarySlot: MealSlot?
        var diaryDate: LocalDiaryDate?
        var diaryGeneration: UInt64?
    }

    private let requestID = UUID()
    private let user = AuthUser(
        id: "user-1",
        username: "user",
        role: .user,
        displayName: "User"
    )
    private let otherUser = AuthUser(
        id: "user-2",
        username: "other",
        role: .user,
        displayName: "Other"
    )
    private let admin = AuthUser(
        id: "admin-1",
        username: "admin",
        role: .admin,
        displayName: "Admin"
    )
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private var todayDate: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19))!
    }

    private func makeClient(
        start: @escaping @Sendable () async -> SessionCoordinator.Phase = { .signedOut(.signedOut) },
        restore: @escaping @Sendable () async -> SessionCoordinator.Phase = { .signedOut(.signedOut) },
        dismiss: @escaping @Sendable () async -> Void = {},
        handleUnauthorized: @escaping @Sendable (UInt64?, SessionUnavailableReason) async -> Bool = { _, _ in false },
        events: @escaping @Sendable () async -> AsyncStream<SessionSnapshot>
    ) -> SessionClient {
        SessionClient(
            restore: restore,
            start: start,
            signIn: { _, _ in .failed(.invalidCredentials) },
            signOut: { .completed },
            handleUnauthorized: handleUnauthorized,
            dismissUnsupportedAccount: dismiss,
            snapshot: { SessionSnapshot(phase: .idle, generation: 0) },
            events: events
        )
    }

    private func signedInState(
        user: AuthUser = AuthUser(id: "user-1", username: "user", role: .user, displayName: "User"),
        generation: UInt64 = 0,
        nutrition: NutritionDetailsFeature.State? = nil
    ) -> AppFeature.SignedInState {
        AppFeature.SignedInState(
            user: user,
            window: WindowFeature.State(
                sessionGeneration: generation,
                today: today,
                nutrition: nutrition
            )
        )
    }

    func testBootstrapInitialSnapshotTransitionsToSignedOut() async {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
        continuation.yield(SessionSnapshot(phase: .idle, generation: 0))
        continuation.yield(SessionSnapshot(phase: .signedOut(.signedOut), generation: 1))
        continuation.finish()

        let client = makeClient(
            start: { .signedOut(.signedOut) },
            restore: { fatalError("startup must use guarded start, not restore") },
            events: { stream }
        )
        let store = TestStore(initialState: AppFeature.State.initial) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = client
            $0.date = .constant(todayDate)
        }

        await store.send(.task)
        await store.receive(\.sessionSnapshot)
        await store.receive(\.sessionSnapshot) {
            $0.phase = .signedOut(.signedOut, LoginFeature.State())
            $0.sessionGeneration = 1
        }
        await store.finish()
    }

    func testActiveSecondWindowStartupDoesNotResetGeneration() async {
        let signedInUser = user
        let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
        continuation.yield(SessionSnapshot(phase: .signedIn(signedInUser), generation: 5))
        continuation.finish()

        let client = makeClient(
            start: { .signedIn(signedInUser) },
            restore: { fatalError("startup must not call unguarded restore") },
            events: { stream }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: signedInUser, generation: 5)),
                sessionGeneration: 5
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = client
            $0.date = .constant(todayDate)
        }

        await store.send(.task)
        await store.receive(\.sessionSnapshot)
        XCTAssertEqual(store.state.sessionGeneration, 5)
        await store.finish()
    }

    func testSignedInSnapshotTeardownsLoginState() async {
        let user = self.user
        final class StateBox { var value: AppFeature.State? }
        let box = StateBox()
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedOut(nil, LoginFeature.State(username: "user", password: "secret")),
                sessionGeneration: 0
            )
        ) {
            CombineReducers {
                AppFeature()
                Reduce { state, action in
                    box.value = state
                    return .none
                }
            }
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .signedIn(user), generation: 1))) {
            let actual = box.value!
            guard case .signedIn(let actualSignedIn) = actual.phase else {
                fatalError("expected signed-in state")
            }
            let actualWindow = actualSignedIn.window
            $0.phase = .signedIn(AppFeature.SignedInState(
                user: user,
                window: WindowFeature.State(
                    sessionGeneration: 1,
                    today: self.today,
                    nutrition: nil,
                    diary: DiaryScreenFeature.State(
                        date: self.today,
                        today: self.today,
                        sessionGeneration: 1,
                        diaryCache: actualWindow.diary.diary.cache,
                        latestCache: actualWindow.diary.latest.cache
                    )
                )
            ))
            $0.sessionGeneration = 1
        }

        let priorSelectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let actualPost = store.state
        guard case .signedIn(let actualPostSignedIn) = actualPost.phase else {
            fatalError("expected signed-in state")
        }
        let actualPostWindow = actualPostSignedIn.window
        XCTAssertEqual(actualPostWindow.diary.diary.cache.generation, 0)
        XCTAssertEqual(actualPostWindow.diary.latest.cache.generation, 0)
        for key in [self.today, priorSelectedDate] {
            XCTAssertEqual(actualPostWindow.diary.diary.cache.entry(for: key), .notRequested)
            XCTAssertNil(actualPostWindow.diary.diary.cache.cached(key))
            XCTAssertEqual(actualPostWindow.diary.latest.cache.entry(for: key), .notRequested)
            XCTAssertNil(actualPostWindow.diary.latest.cache.cached(key))
        }
        var diaryProbe = actualPostWindow.diary.diary.cache
        XCTAssertNotNil(diaryProbe.request(self.today))
        var latestProbe = actualPostWindow.diary.latest.cache
        XCTAssertNotNil(latestProbe.request(self.today))
    }

    func testUnsupportedSnapshotTeardownsLoginState() async {
        let admin = self.admin
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedOut(nil, LoginFeature.State(username: "admin", password: "secret")),
                sessionGeneration: 0
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .unsupportedAccount(admin), generation: 1))) {
            $0.phase = .unsupportedAccount(admin)
            $0.sessionGeneration = 1
        }
    }

    func testOldGenerationSnapshotIsIgnored() async {
        let user = self.user
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: 2)),
                sessionGeneration: 2
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .signedOut(.expired), generation: 1)))
    }

    func testSubscriptionCancellationFinishesCleanly() async {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
        continuation.yield(SessionSnapshot(phase: .idle, generation: 0))

        let client = makeClient(
            start: { .signedOut(.signedOut) },
            events: { stream }
        )
        let store = TestStore(initialState: AppFeature.State.initial) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = client
            $0.date = .constant(todayDate)
        }

        let task = await store.send(.task)
        await store.receive(\.sessionSnapshot)
        await task.cancel()
        continuation.finish()
        await store.finish()
    }

    func testDismissUnsupportedAccountUsesClientAndUpdatesFromSnapshot() async {
        let admin = self.admin
        let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
        continuation.yield(SessionSnapshot(phase: .unsupportedAccount(admin), generation: 1))

        let client = makeClient(
            dismiss: {
                continuation.yield(SessionSnapshot(phase: .signedOut(.signedOut), generation: 1))
            },
            events: { stream }
        )

        let store = TestStore(
            initialState: AppFeature.State(
                phase: .unsupportedAccount(admin),
                sessionGeneration: 1
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = client
            $0.date = .constant(todayDate)
        }

        let task = await store.send(.task)
        await store.receive(\.sessionSnapshot)

        await store.send(.dismissUnsupportedAccount)
        await store.receive(\.sessionSnapshot) {
            $0.phase = .signedOut(.signedOut, LoginFeature.State())
            $0.sessionGeneration = 1
        }

        continuation.finish()
        await task.finish()
        await store.finish()
    }

    func testSigningInSnapshotPreservesLoginStateAndTypedFailure() async {
        let loginState = LoginFeature.State(
            username: "user",
            password: "secret",
            phase: .failed(.authentication(.invalidCredentials))
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signingIn(loginState),
                sessionGeneration: 1
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .signedOut(.signedOut), generation: 2))) {
            $0.phase = .signedOut(.signedOut, LoginFeature.State(
                username: "user",
                password: "secret",
                phase: .failed(.authentication(.invalidCredentials))
            ))
            $0.sessionGeneration = 2
        }
    }

    func testSignedInSnapshotPreservesWindowForSameUserAndGeneration() async {
        let user = self.user
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: 5)),
                sessionGeneration: 5
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .signedIn(user), generation: 5)))
        XCTAssertEqual(store.state.sessionGeneration, 5)
        await store.finish()
    }

    func testSignedInSnapshotRebuildsWindowForNewGeneration() async {
        let user = self.user
        let priorSelectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)

        var priorDiaryCache = DiaryFeature.Cache().reset()
        guard let (priorDiaryInFlight, priorDiaryToken) = priorDiaryCache.request(priorSelectedDate) else {
            fatalError("prior diary cache request should succeed")
        }
        priorDiaryCache = priorDiaryInFlight.settling(priorSelectedDate, token: priorDiaryToken, result: .failure(.unknown))!

        var priorLatestCache = DiaryLatestFeature.Cache().reset()
        guard let (priorLatestInFlight, priorLatestToken) = priorLatestCache.request(priorSelectedDate) else {
            fatalError("prior latest cache request should succeed")
        }
        priorLatestCache = priorLatestInFlight.settling(priorSelectedDate, token: priorLatestToken, result: .failure(.unknown))!

        final class StateBox { var value: AppFeature.State? }
        let box = StateBox()
        let priorWindow = WindowFeature.State(
            sessionGeneration: 5,
            today: self.today,
            nutrition: nil,
            diary: DiaryScreenFeature.State(
                date: self.today,
                today: self.today,
                sessionGeneration: 5,
                diaryCache: priorDiaryCache,
                latestCache: priorLatestCache
            )
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(AppFeature.SignedInState(user: user, window: priorWindow)),
                sessionGeneration: 5
            )
        ) {
            CombineReducers {
                AppFeature()
                Reduce { state, action in
                    box.value = state
                    return .none
                }
            }
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .signedIn(user), generation: 6))) {
            let actual = box.value!
            guard case .signedIn(let actualSignedIn) = actual.phase else {
                fatalError("expected signed-in state")
            }
            let actualWindow = actualSignedIn.window
            $0.phase = .signedIn(AppFeature.SignedInState(
                user: user,
                window: WindowFeature.State(
                    sessionGeneration: 6,
                    today: self.today,
                    nutrition: nil,
                    diary: DiaryScreenFeature.State(
                        date: self.today,
                        today: self.today,
                        sessionGeneration: 6,
                        diaryCache: actualWindow.diary.diary.cache,
                        latestCache: actualWindow.diary.latest.cache
                    )
                )
            ))
            $0.sessionGeneration = 6
        }

        let actualPost = store.state
        guard case .signedIn(let actualPostSignedIn) = actualPost.phase else {
            fatalError("expected signed-in state")
        }
        let actualPostWindow = actualPostSignedIn.window
        XCTAssertEqual(actualPostWindow.diary.diary.cache.generation, 0)
        XCTAssertEqual(actualPostWindow.diary.latest.cache.generation, 0)
        for key in [self.today, priorSelectedDate] {
            XCTAssertEqual(actualPostWindow.diary.diary.cache.entry(for: key), .notRequested)
            XCTAssertNil(actualPostWindow.diary.diary.cache.cached(key))
            XCTAssertEqual(actualPostWindow.diary.latest.cache.entry(for: key), .notRequested)
            XCTAssertNil(actualPostWindow.diary.latest.cache.cached(key))
        }
        var diaryProbe = actualPostWindow.diary.diary.cache
        XCTAssertNotNil(diaryProbe.request(self.today))
        var latestProbe = actualPostWindow.diary.latest.cache
        XCTAssertNotNil(latestProbe.request(self.today))
    }

    func testSignedInSnapshotRebuildsWindowForAccountChange() async {
        let priorSelectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)

        var priorDiaryCache = DiaryFeature.Cache().reset()
        guard let (priorDiaryInFlight, priorDiaryToken) = priorDiaryCache.request(priorSelectedDate) else {
            fatalError("prior diary cache request should succeed")
        }
        priorDiaryCache = priorDiaryInFlight.settling(priorSelectedDate, token: priorDiaryToken, result: .failure(.unknown))!

        var priorLatestCache = DiaryLatestFeature.Cache().reset()
        guard let (priorLatestInFlight, priorLatestToken) = priorLatestCache.request(priorSelectedDate) else {
            fatalError("prior latest cache request should succeed")
        }
        priorLatestCache = priorLatestInFlight.settling(priorSelectedDate, token: priorLatestToken, result: .failure(.unknown))!

        final class StateBox { var value: AppFeature.State? }
        let box = StateBox()
        let priorWindow = WindowFeature.State(
            sessionGeneration: 5,
            today: self.today,
            nutrition: nil,
            diary: DiaryScreenFeature.State(
                date: self.today,
                today: self.today,
                sessionGeneration: 5,
                diaryCache: priorDiaryCache,
                latestCache: priorLatestCache
            )
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(AppFeature.SignedInState(user: user, window: priorWindow)),
                sessionGeneration: 5
            )
        ) {
            CombineReducers {
                AppFeature()
                Reduce { state, action in
                    box.value = state
                    return .none
                }
            }
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(todayDate)
        }

        await store.send(.sessionSnapshot(SessionSnapshot(phase: .signedIn(otherUser), generation: 5))) {
            let actual = box.value!
            guard case .signedIn(let actualSignedIn) = actual.phase else {
                fatalError("expected signed-in state")
            }
            let actualWindow = actualSignedIn.window
            $0.phase = .signedIn(AppFeature.SignedInState(
                user: self.otherUser,
                window: WindowFeature.State(
                    sessionGeneration: 5,
                    today: self.today,
                    nutrition: nil,
                    diary: DiaryScreenFeature.State(
                        date: self.today,
                        today: self.today,
                        sessionGeneration: 5,
                        diaryCache: actualWindow.diary.diary.cache,
                        latestCache: actualWindow.diary.latest.cache
                    )
                )
            ))
            $0.sessionGeneration = 5
        }

        let actualPost = store.state
        guard case .signedIn(let actualPostSignedIn) = actualPost.phase else {
            fatalError("expected signed-in state")
        }
        let actualPostWindow = actualPostSignedIn.window
        XCTAssertEqual(actualPostWindow.diary.diary.cache.generation, 0)
        XCTAssertEqual(actualPostWindow.diary.latest.cache.generation, 0)
        for key in [self.today, priorSelectedDate] {
            XCTAssertEqual(actualPostWindow.diary.diary.cache.entry(for: key), .notRequested)
            XCTAssertNil(actualPostWindow.diary.diary.cache.cached(key))
            XCTAssertEqual(actualPostWindow.diary.latest.cache.entry(for: key), .notRequested)
            XCTAssertNil(actualPostWindow.diary.latest.cache.cached(key))
        }
        var diaryProbe = actualPostWindow.diary.diary.cache
        XCTAssertNotNil(diaryProbe.request(self.today))
        var latestProbe = actualPostWindow.diary.latest.cache
        XCTAssertNotNil(latestProbe.request(self.today))
    }

    func testWindowSessionExpiredForwardsCapturedGeneration() async {
        let user = self.user
        let generation = UInt64(5)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let child = NutritionDetailsFeature.State(
            today: today,
            phase: .loading(requestDate: selectedDate, requestID: requestID),
            sessionGeneration: generation
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation, nutrition: child)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = makeClient(
                handleUnauthorized: { receivedGeneration, _ in
                    XCTAssertEqual(receivedGeneration, generation)
                    return true
                },
                events: { AsyncStream { $0.finish() } }
            )
            $0.date = .constant(todayDate)
        }

        await store.send(.window(.nutrition(.reportFailed(
            requestDate: selectedDate,
            requestID: requestID,
            failure: .unauthorized
        )))) {
            if case .signedIn(let signedIn) = $0.phase {
                var window = signedIn.window
                window.nutrition = NutritionDetailsFeature.State(
                    today: self.today,
                    phase: .sessionExpired(requestDate: selectedDate),
                    sessionGeneration: generation
                )
                $0.phase = .signedIn(AppFeature.SignedInState(user: signedIn.user, window: window))
            }
            $0.sessionGeneration = generation
        }
        await store.receive(\.window) {
            if case .signedIn(let signedIn) = $0.phase {
                var window = signedIn.window
                window.nutrition = nil
                $0.phase = .signedIn(AppFeature.SignedInState(user: signedIn.user, window: window))
            }
            $0.sessionGeneration = generation
        }
        await store.receive(\.window)
        await store.finish()
    }

    func testWindowStaleSessionExpiredIsIgnored() async {
        let user = self.user
        let windowGeneration = UInt64(5)
        let staleChildGeneration = UInt64(3)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let child = NutritionDetailsFeature.State(
            today: today,
            phase: .loading(requestDate: selectedDate, requestID: requestID),
            sessionGeneration: staleChildGeneration
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: windowGeneration, nutrition: child)),
                sessionGeneration: windowGeneration
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = makeClient(
                handleUnauthorized: { _, _ in
                    XCTFail("stale expiry must not call session authority")
                    return false
                },
                events: { AsyncStream { $0.finish() } }
            )
            $0.date = .constant(todayDate)
        }

        await store.send(.window(.nutrition(.reportFailed(
            requestDate: selectedDate,
            requestID: requestID,
            failure: .unauthorized
        )))) {
            if case .signedIn(let signedIn) = $0.phase {
                var window = signedIn.window
                window.nutrition = NutritionDetailsFeature.State(
                    today: self.today,
                    phase: .sessionExpired(requestDate: selectedDate),
                    sessionGeneration: staleChildGeneration
                )
                $0.phase = .signedIn(AppFeature.SignedInState(user: signedIn.user, window: window))
            }
            $0.sessionGeneration = windowGeneration
        }
        await store.receive(\.window)
        await store.finish()
    }

    func testWindowSelectedFoodForwardsCapturedGeneration() async {
        let user = self.user
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let recorder = RoutingRecorder()
        let client = LegacySearchRoutingClient(
            openFoodDetail: { id, date, mealSlot, origin, generation in
                recorder.foodID = id
                recorder.foodDate = date
                recorder.foodSlot = mealSlot
                recorder.foodOrigin = origin
                recorder.foodGeneration = generation
            },
            openMealDetail: { _, _, _, _, _, _ in },
            openMeals: { _, _, _ in }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacySearchRoutingClient = client
        }

        await store.send(.window(.delegate(.selectedFood(
            id: "food-42",
            date: selectedDate,
            mealSlot: .dinner,
            generation: generation,
            origin: .searchTab
        ))))
        await store.finish()

        XCTAssertEqual(recorder.foodID, "food-42")
        XCTAssertEqual(recorder.foodDate, selectedDate)
        XCTAssertEqual(recorder.foodSlot, .dinner)
        XCTAssertEqual(recorder.foodOrigin, .searchTab)
        XCTAssertEqual(recorder.foodGeneration, generation)
    }

    func testWindowSelectedFoodStaleGenerationIsIgnored() async {
        let user = self.user
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let recorder = RoutingRecorder()
        let client = LegacySearchRoutingClient(
            openFoodDetail: { id, date, mealSlot, origin, generation in
                recorder.foodID = id
                recorder.foodDate = date
                recorder.foodSlot = mealSlot
                recorder.foodOrigin = origin
                recorder.foodGeneration = generation
            },
            openMealDetail: { _, _, _, _, _, _ in },
            openMeals: { _, _, _ in }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacySearchRoutingClient = client
        }

        await store.send(.window(.delegate(.selectedFood(
            id: "food-stale",
            date: selectedDate,
            mealSlot: .dinner,
            generation: UInt64(7),
            origin: .searchTab
        ))))
        await store.finish()

        XCTAssertNil(recorder.foodID)
    }


    func testWindowSelectedMealForwardsCapturedGeneration() async {
        let user = self.user
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let quantity = NutritionQuantity(amount: "2", unit: "serving")
        let recorder = RoutingRecorder()
        let client = LegacySearchRoutingClient(
            openFoodDetail: { _, _, _, _, _ in },
            openMealDetail: { id, date, mealSlot, quantity, origin, generation in
                recorder.mealID = id
                recorder.mealDate = date
                recorder.mealSlot = mealSlot
                recorder.mealQuantity = quantity
                recorder.mealOrigin = origin
                recorder.mealGeneration = generation
            },
            openMeals: { _, _, _ in }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacySearchRoutingClient = client
        }

        await store.send(.window(.delegate(.selectedMeal(
            id: "meal-42",
            date: selectedDate,
            mealSlot: .lunch,
            quantity: quantity,
            generation: generation,
            origin: .diaryPush
        ))))
        await store.finish()

        XCTAssertEqual(recorder.mealID, "meal-42")
        XCTAssertEqual(recorder.mealDate, selectedDate)
        XCTAssertEqual(recorder.mealSlot, .lunch)
        XCTAssertEqual(recorder.mealQuantity, quantity)
        XCTAssertEqual(recorder.mealOrigin, .diaryPush)
        XCTAssertEqual(recorder.mealGeneration, generation)
    }

    func testWindowSelectedMealStaleGenerationIsIgnored() async {
        let user = self.user
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let quantity = NutritionQuantity(amount: "2", unit: "serving")
        let recorder = RoutingRecorder()
        let client = LegacySearchRoutingClient(
            openFoodDetail: { _, _, _, _, _ in },
            openMealDetail: { id, date, mealSlot, quantity, origin, generation in
                recorder.mealID = id
            },
            openMeals: { _, _, _ in }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacySearchRoutingClient = client
        }

        await store.send(.window(.delegate(.selectedMeal(
            id: "meal-stale",
            date: selectedDate,
            mealSlot: .lunch,
            quantity: quantity,
            generation: UInt64(7),
            origin: .diaryPush
        ))))
        await store.finish()

        XCTAssertNil(recorder.mealID)
    }

    func testWindowOpenMealsForwardsCapturedGeneration() async {
        let user = self.user
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let recorder = RoutingRecorder()
        let client = LegacySearchRoutingClient(
            openFoodDetail: { _, _, _, _, _ in },
            openMealDetail: { _, _, _, _, _, _ in },
            openMeals: { date, mealSlot, generation in
                recorder.mealsDate = date
                recorder.mealsSlot = mealSlot
                recorder.mealsGeneration = generation
            }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacySearchRoutingClient = client
        }

        await store.send(.window(.delegate(.openMeals(
            date: selectedDate,
            mealSlot: .breakfast,
            generation: generation
        ))))
        await store.finish()

        XCTAssertEqual(recorder.mealsDate, selectedDate)
        XCTAssertEqual(recorder.mealsSlot, .breakfast)
        XCTAssertEqual(recorder.mealsGeneration, generation)
    }

    func testWindowOpenMealsStaleGenerationIsIgnored() async {
        let user = self.user
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let recorder = RoutingRecorder()
        let client = LegacySearchRoutingClient(
            openFoodDetail: { _, _, _, _, _ in },
            openMealDetail: { _, _, _, _, _, _ in },
            openMeals: { date, mealSlot, generation in
                recorder.mealsDate = date
            }
        )
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacySearchRoutingClient = client
        }

        await store.send(.window(.delegate(.openMeals(
            date: selectedDate,
            mealSlot: .breakfast,
            generation: UInt64(7)
        ))))
        await store.finish()

        XCTAssertNil(recorder.mealsDate)
    }

    // MARK: - Diary Add Food routing

    private func diaryRoutingClient(_ recorder: RoutingRecorder) -> LegacyDiaryRoutingClient {
        LegacyDiaryRoutingClient { slot, date, generation in
            recorder.diarySlot = slot
            recorder.diaryDate = date
            recorder.diaryGeneration = generation
        }
    }

    func testWindowDiaryAddFoodForwardsCapturedPayload() async {
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 15)
        let recorder = RoutingRecorder()
        let client = diaryRoutingClient(recorder)
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacyDiaryRoutingClient = client
        }

        await store.send(.window(.delegate(.addFood(
            slot: .breakfast,
            date: selectedDate,
            generation: generation
        ))))
        await store.finish()

        XCTAssertEqual(recorder.diarySlot, .breakfast)
        XCTAssertEqual(recorder.diaryDate, selectedDate)
        XCTAssertEqual(recorder.diaryGeneration, generation)
    }

    func testWindowDiaryAddFoodStaleGenerationIsIgnored() async {
        let generation = UInt64(42)
        let recorder = RoutingRecorder()
        let client = diaryRoutingClient(recorder)
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(self.signedInState(user: user, generation: generation)),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacyDiaryRoutingClient = client
        }

        await store.send(.window(.delegate(.addFood(
            slot: .breakfast,
            date: LocalDiaryDate(year: 2026, month: 11, day: 15),
            generation: generation + 1
        ))))
        await store.finish()

        XCTAssertNil(recorder.diarySlot)
        XCTAssertNil(recorder.diaryDate)
        XCTAssertNil(recorder.diaryGeneration)
    }

    func testWindowDiaryAddFoodRequiresSignedInMatchingWindowGeneration() async {
        let generation = UInt64(42)
        let recorder = RoutingRecorder()
        let mismatchedWindow = AppFeature.SignedInState(
            user: user,
            window: WindowFeature.State(sessionGeneration: generation + 1, today: today)
        )
        let client = diaryRoutingClient(recorder)
        let store = TestStore(
            initialState: AppFeature.State(
                phase: .signedIn(mismatchedWindow),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = SessionClient.unimplemented
            $0.date = .constant(self.todayDate)
            $0.legacyDiaryRoutingClient = client
        }

        await store.send(.window(.delegate(.addFood(
            slot: .breakfast,
            date: LocalDiaryDate(year: 2026, month: 11, day: 15),
            generation: generation
        ))))
        await store.finish()

        XCTAssertNil(recorder.diarySlot)
    }
}
