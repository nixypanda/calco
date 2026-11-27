import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class AppFeatureTests: XCTestCase {
    // The former `RoutingRecorder` captured values passed to the deleted
    // `LegacySearchRoutingClient`/`LegacyDiaryRoutingClient`. Those assertions
    // now read the typed `WindowDestination`/`WindowPresentation` created by
    // the root reducer, so no recorder/client fake is needed.

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
                    sessionAccountID: user.id,
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
                    sessionAccountID: user.id,
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
                    sessionAccountID: self.otherUser.id,
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

    // MARK: - Typed navigation delegates (formerly legacy routing clients)
    //
    // The recorder-based assertions below are replaced with assertions on the
    // typed `WindowDestination`/`WindowPresentation` the root now builds. The
    // captured date, slot, account, generation, origin and quantity are checked
    // on the actual navigation payload, not on a fake closure.

    private let presentationID = UUID()

    private func typedStore(
        generation: UInt64,
        windowGeneration: UInt64? = nil,
        phase: AppFeature.Phase? = nil
    ) -> TestStore<AppFeature.State, AppFeature.Action> {
        let signedIn = AppFeature.SignedInState(
            user: user,
            window: WindowFeature.State(
                sessionGeneration: windowGeneration ?? generation,
                today: today,
                sessionAccountID: user.id
            )
        )
        return TestStore(
            initialState: AppFeature.State(
                phase: phase ?? .signedIn(signedIn),
                sessionGeneration: generation
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.sessionClient = .unimplemented
            $0.date = .constant(self.todayDate)
            $0.uuid = .constant(self.presentationID)
        }
    }

    private func context(
        date: LocalDiaryDate,
        slot: MealSlot?,
        generation: UInt64,
        origin: WindowNavOrigin
    ) -> WindowCaptureContext {
        WindowCaptureContext(
            date: date,
            slot: slot,
            accountID: user.id,
            generation: generation,
            origin: origin,
            presentationID: presentationID
        )
    }

    private func appendDestination(
        _ destination: WindowDestination,
        foodDetail: FoodDetailFeature.State? = nil,
        meals: MealsFlowFeature.State? = nil,
        state: inout AppFeature.State
    ) {
        guard case .signedIn(var signedIn) = state.phase else {
            XCTFail("Expected signed-in root")
            return
        }
        var resolvedMeals = meals
        if case let .mealDetail(id, context) = destination, resolvedMeals == nil {
            let mealContext = MealsCaptureContext(
                id: context.presentationID,
                date: context.date,
                mealSlot: context.slot,
                accountID: context.accountID,
                generation: context.generation,
                origin: .sheet
            )
            resolvedMeals = MealsFlowFeature.State(context: mealContext)
            var path = StackState<MealsPath.State>()
            path[id: 0] = .detail(
                MealDetailFeature.State(context: mealContext, mealID: id)
            )
            resolvedMeals?.path = path
        }
        signedIn.window.destinationStack.append(destination)
        signedIn.window.foodDetail = foodDetail
        signedIn.window.meals = resolvedMeals
        state.phase = .signedIn(signedIn)
    }

    func testWindowSelectedFoodForwardsCapturedGeneration() async {
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let captured = context(
            date: selectedDate, slot: .dinner, generation: generation, origin: .search
        )
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.selectedFood(
            id: "food-42", date: selectedDate, mealSlot: .dinner,
            generation: generation, origin: .searchTab
        ))))
        await store.receive({ action in
            guard case let .window(childAction) = action else { return false }
            guard case let .pushDestination(destination) = childAction else { return false }
            guard case let .foodDetail(id, context) = destination else { return false }
            return id == "food-42" && context == captured
        }) {
            self.appendDestination(
                .foodDetail(id: "food-42", context: captured),
                foodDetail: FoodDetailFeature.State(
                    foodID: "food-42", date: selectedDate, slot: .dinner,
                    generation: generation, accountID: self.user.id,
                    presentationID: self.presentationID
                ),
                state: &$0
            )
        }

        guard case .signedIn(let signedIn) = store.state.phase,
              case let .foodDetail(id, routeContext) = signedIn.window.destinationStack[0] else {
            return XCTFail("Expected a typed food detail destination")
        }
        XCTAssertEqual(id, "food-42")
        XCTAssertEqual(routeContext.date, selectedDate)
        XCTAssertEqual(routeContext.slot, .dinner)
        XCTAssertEqual(routeContext.accountID, user.id)
        XCTAssertEqual(routeContext.generation, generation)
        XCTAssertEqual(routeContext.origin, .search)
    }

    func testWindowSelectedFoodStaleGenerationIsIgnored() async {
        let generation = UInt64(42)
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.selectedFood(
            id: "food-stale", date: LocalDiaryDate(year: 2026, month: 11, day: 17),
            mealSlot: .dinner, generation: UInt64(7), origin: .searchTab
        ))))
        guard case .signedIn(let signedIn) = store.state.phase else {
            return XCTFail("Expected signed-in root")
        }
        XCTAssertTrue(signedIn.window.destinationStack.isEmpty)
    }

    func testWindowSelectedMealForwardsCapturedGeneration() async {
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let quantity = NutritionQuantity(amount: "2", unit: "serving")
        let captured = context(
            date: selectedDate, slot: .lunch, generation: generation, origin: .diary
        )
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.selectedMeal(
            id: "meal-42", date: selectedDate, mealSlot: .lunch, quantity: quantity,
            generation: generation, origin: .diaryPush
        ))))
        await store.receive({ action in
            guard case let .window(childAction) = action else { return false }
            guard case let .pushDestination(destination) = childAction else { return false }
            guard case let .mealDetail(id, context) = destination else { return false }
            return id == "meal-42" && context == captured
        }) {
            self.appendDestination(.mealDetail(id: "meal-42", context: captured), state: &$0)
        }

        guard case .signedIn(let signedIn) = store.state.phase,
              case let .mealDetail(id, routeContext) = signedIn.window.destinationStack[0] else {
            return XCTFail("Expected a typed meal detail destination")
        }
        XCTAssertEqual(id, "meal-42")
        XCTAssertEqual(routeContext.date, selectedDate)
        XCTAssertEqual(routeContext.slot, .lunch)
        XCTAssertEqual(routeContext.accountID, user.id)
        XCTAssertEqual(routeContext.generation, generation)
        XCTAssertEqual(routeContext.origin, .diary)
    }

    func testWindowSelectedMealStaleGenerationIsIgnored() async {
        let generation = UInt64(42)
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.selectedMeal(
            id: "meal-stale", date: LocalDiaryDate(year: 2026, month: 11, day: 17),
            mealSlot: .lunch, quantity: NutritionQuantity(amount: "2", unit: "serving"),
            generation: UInt64(7), origin: .diaryPush
        ))))
        guard case .signedIn(let signedIn) = store.state.phase else {
            return XCTFail("Expected signed-in root")
        }
        XCTAssertTrue(signedIn.window.destinationStack.isEmpty)
    }

    func testWindowOpenMealsForwardsCapturedGeneration() async {
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
        let captured = context(
            date: selectedDate, slot: .breakfast, generation: generation, origin: .diary
        )
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.openMeals(
            date: selectedDate, mealSlot: .breakfast, generation: generation
        ))))
        await store.receive({ action in
            guard case let .window(childAction) = action else { return false }
            guard case let .pushDestination(destination) = childAction else { return false }
            guard case let .meals(context) = destination else { return false }
            return context == captured
        }) {
            self.appendDestination(
                .meals(context: captured),
                meals: MealsFlowFeature.State(
                    context: MealsCaptureContext(
                        id: self.presentationID, date: selectedDate, mealSlot: .breakfast,
                        accountID: self.user.id, generation: generation, origin: .sheet
                    )
                ),
                state: &$0
            )
        }

        guard case .signedIn(let signedIn) = store.state.phase,
              case let .meals(routeContext) = signedIn.window.destinationStack[0] else {
            return XCTFail("Expected a typed meals destination")
        }
        XCTAssertEqual(routeContext.date, selectedDate)
        XCTAssertEqual(routeContext.slot, .breakfast)
        XCTAssertEqual(routeContext.accountID, user.id)
        XCTAssertEqual(routeContext.generation, generation)
    }

    func testWindowOpenMealsStaleGenerationIsIgnored() async {
        let generation = UInt64(42)
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.openMeals(
            date: LocalDiaryDate(year: 2026, month: 11, day: 17),
            mealSlot: .breakfast, generation: UInt64(7)
        ))))
        guard case .signedIn(let signedIn) = store.state.phase else {
            return XCTFail("Expected signed-in root")
        }
        XCTAssertTrue(signedIn.window.destinationStack.isEmpty)
    }

    // MARK: - Diary Add Food routing

    func testWindowDiaryAddFoodForwardsCapturedPayload() async {
        let generation = UInt64(42)
        let selectedDate = LocalDiaryDate(year: 2026, month: 11, day: 15)
        let captured = context(
            date: selectedDate, slot: .breakfast, generation: generation, origin: .diary
        )
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.addFood(
            slot: .breakfast, date: selectedDate, generation: generation
        ))))
        await store.receive({ action in
            guard case let .window(childAction) = action else { return false }
            guard case let .pushDestination(destination) = childAction else { return false }
            guard case let .search(context) = destination else { return false }
            return context == captured
        }) {
            guard case .signedIn(var signedIn) = $0.phase else {
                XCTFail("Expected signed-in root")
                return
            }
            signedIn.window.destinationStack = [.search(context: captured)]
            // Search entry context is bound from the SAME immutable captured
            // payload as the pushed Search route: a historical Diary Add Food
            // logs into that day/slot, not Today. The old expectation only
            // asserted the route and left this context stale at `today`.
            signedIn.window.search.catalog.originDate = selectedDate
            signedIn.window.search.catalog.originMealSlot = .breakfast
            signedIn.window.search.history.contextDate = selectedDate
            signedIn.window.search.history.contextMealSlot = .breakfast
            signedIn.window.search.quickAdd.originDate = selectedDate
            signedIn.window.search.quickAdd.originMealSlot = .breakfast
            $0.phase = .signedIn(signedIn)
        }

        guard case .signedIn(let signedIn) = store.state.phase,
              let routeContext = signedIn.window.destinationStack.last.flatMap({ destination in
                  if case let .search(context) = destination { return context } else { return nil }
              }) else {
            return XCTFail("Expected a typed search destination")
        }
        XCTAssertEqual(signedIn.window.destinationStack, [.search(context: captured)])
        XCTAssertEqual(routeContext.slot, .breakfast)
        XCTAssertEqual(routeContext.date, selectedDate)
        XCTAssertEqual(routeContext.generation, generation)
        XCTAssertEqual(routeContext.accountID, user.id)
        XCTAssertEqual(routeContext.origin, .diary)
        XCTAssertEqual(routeContext.presentationID, presentationID)
        XCTAssertEqual(signedIn.window.search.originDate, selectedDate)
        XCTAssertEqual(signedIn.window.search.originMealSlot, .breakfast)
    }

    func testWindowDiaryAddFoodStaleGenerationIsIgnored() async {
        let generation = UInt64(42)
        let store = typedStore(generation: generation)

        await store.send(.window(.delegate(.addFood(
            slot: .breakfast, date: LocalDiaryDate(year: 2026, month: 11, day: 15),
            generation: generation + 1
        ))))
        guard case .signedIn(let signedIn) = store.state.phase else {
            return XCTFail("Expected signed-in root")
        }
        XCTAssertNil(signedIn.window.presentation)
        XCTAssertTrue(signedIn.window.destinationStack.isEmpty)
    }

    func testWindowDiaryAddFoodRequiresSignedInMatchingWindowGeneration() async {
        let generation = UInt64(42)
        let store = typedStore(generation: generation, windowGeneration: generation + 1)

        await store.send(.window(.delegate(.addFood(
            slot: .breakfast, date: LocalDiaryDate(year: 2026, month: 11, day: 15),
            generation: generation
        ))))
        guard case .signedIn(let signedIn) = store.state.phase else {
            return XCTFail("Expected signed-in root")
        }
        XCTAssertNil(signedIn.window.presentation)
        XCTAssertTrue(signedIn.window.destinationStack.isEmpty)
    }
}
