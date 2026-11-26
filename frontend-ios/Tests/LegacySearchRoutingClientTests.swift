import XCTest

@testable import CalCo

/// Behavioural tests for the legacy routing seam. The narrow `guarded` factory
/// keeps authority/route callbacks explicit so generation denial, origin
/// routing, and captured-context forwarding can be verified without a session
/// or auth framework and without any network access. The live tests at the
/// bottom install a real signed-in `AppShellCoordinator` graph and drive the
/// real `LegacySearchRoutingClient.live(coordinator:)` against it.
@MainActor
final class LegacySearchRoutingClientTests: XCTestCase {
    private let foodID = "food-1"
    private let mealID = "meal-1"
    private let capturedDate = LocalDiaryDate(year: 2026, month: 11, day: 20)
    private let capturedSlot: MealSlot = .lunch
    private let capturedGeneration: UInt64 = 42
    private let quantity = NutritionQuantity(amount: "1.5", unit: "serving")

    // Fixtures that deliberately disagree with the captured routing context.
    // The live tests below fail if a route re-reads navigation state or the
    // legacy SearchViewModel instead of forwarding the captured arguments.
    private let navigationDate = LocalDiaryDate(year: 2026, month: 11, day: 1)
    private let legacyContextDate = LocalDiaryDate(year: 2026, month: 11, day: 2)
    private let legacyContextSlot: MealSlot = .snack

    // MARK: - Food routing

    func testDiaryPushFoodRoutesToDiaryWithCapturedContext() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        let client = recorder.client()

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .diaryPush, capturedGeneration
        )

        XCTAssertEqual(
            recorder.diaryFoodRoutes,
            [FoodRoute(id: foodID, date: capturedDate, mealSlot: capturedSlot)]
        )
        XCTAssertTrue(recorder.searchTabFoodRoutes.isEmpty)
    }

    func testSearchTabFoodRoutesToSearchTabWithCapturedContext() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        let client = recorder.client()

        client.openFoodDetail(
            foodID, capturedDate, .dinner, .searchTab, capturedGeneration
        )

        XCTAssertEqual(
            recorder.searchTabFoodRoutes,
            [FoodRoute(id: foodID, date: capturedDate, mealSlot: .dinner)]
        )
        XCTAssertTrue(recorder.diaryFoodRoutes.isEmpty)
    }

    // MARK: - Meal routing

    func testMealDetailForwardsCapturedContextAndOrigin() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        let client = recorder.client()

        client.openMealDetail(
            mealID, capturedDate, .dinner, quantity, .searchTab, capturedGeneration
        )

        XCTAssertEqual(
            recorder.mealRoutes,
            [MealRoute(
                id: mealID,
                date: capturedDate,
                mealSlot: .dinner,
                quantity: quantity,
                origin: .searchTab
            )]
        )
    }

    func testMealsListForwardsCapturedDateAndSlot() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        let client = recorder.client()

        client.openMeals(capturedDate, .breakfast, capturedGeneration)

        XCTAssertEqual(
            recorder.mealsRoutes,
            [MealsRoute(date: capturedDate, mealSlot: .breakfast)]
        )
    }

    // MARK: - Generation / phase denial

    func testStaleCapturedGenerationDeniesEveryRoute() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration + 1)
        let client = recorder.client()

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .diaryPush, capturedGeneration
        )
        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .searchTab, capturedGeneration
        )
        client.openMealDetail(
            mealID, capturedDate, capturedSlot, quantity, .diaryPush, capturedGeneration
        )
        client.openMeals(capturedDate, capturedSlot, capturedGeneration)

        XCTAssertTrue(recorder.diaryFoodRoutes.isEmpty)
        XCTAssertTrue(recorder.searchTabFoodRoutes.isEmpty)
        XCTAssertTrue(recorder.mealRoutes.isEmpty)
        XCTAssertTrue(recorder.mealsRoutes.isEmpty)
    }

    func testUnsupportedSessionPhaseDeniesEveryRoute() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        recorder.phaseSupported = false
        let client = recorder.client()

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .searchTab, capturedGeneration
        )
        client.openMealDetail(
            mealID, capturedDate, capturedSlot, quantity, .searchTab, capturedGeneration
        )
        client.openMeals(capturedDate, capturedSlot, capturedGeneration)

        XCTAssertTrue(recorder.searchTabFoodRoutes.isEmpty)
        XCTAssertTrue(recorder.mealRoutes.isEmpty)
        XCTAssertTrue(recorder.mealsRoutes.isEmpty)
    }

    // MARK: - Live wiring fails closed before a ready graph exists

    func testLiveClientFailsClosedWithoutSignedInReadyGraph() {
        // An idle coordinator has no ready graph and no signed-in phase; every
        // live command must be denied before it can mutate legacy navigation.
        let coordinator = AppShellCoordinator()
        let client = LegacySearchRoutingClient.live(coordinator: coordinator)
        let initialPane = coordinator.navigationState.activePane

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .diaryPush, capturedGeneration
        )
        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .searchTab, capturedGeneration
        )
        client.openMealDetail(
            mealID, capturedDate, capturedSlot, quantity, .diaryPush, capturedGeneration
        )
        client.openMeals(capturedDate, capturedSlot, capturedGeneration)

        XCTAssertEqual(coordinator.navigationState.activePane, initialPane)
        XCTAssertTrue(coordinator.searchTabPath.isEmpty)
        XCTAssertTrue(coordinator.featureSheet == nil)
    }

    // MARK: - Live wiring against a real signed-in, ready graph
    //
    // These tests drive `LegacySearchRoutingClient.live(coordinator:)` itself,
    // not a recorder that reimplements its origin/date logic. The coordinator
    // is brought up through the real `SessionCoordinator.start()` / restore
    // path with a fake `SessionServicing` outcome; there is no polling, no
    // sleep, and no network. `await start()` returning is the ready handshake:
    // the signed-in phase synchronously installs the feature graph.

    func testLiveDiaryPushRoutesToDiaryDetailWithCapturedContext() async throws {
        let (coordinator, generation) = await makeReadyCoordinator()
        let client = LegacySearchRoutingClient.live(coordinator: coordinator)

        // Point the legacy SearchViewModel and the navigation state at values
        // that all differ from the captured routing arguments.
        coordinator.searchViewModel?.updateContext(
            date: legacyContextDate, mealSlot: legacyContextSlot
        )
        XCTAssertNotEqual(capturedDate, coordinator.navigationState.selectedDate)
        XCTAssertNotEqual(capturedDate, coordinator.searchViewModel?.originDate)
        XCTAssertNotEqual(capturedSlot, coordinator.searchViewModel?.originMealSlot)

        // The captured origin wins even when the visible tab says otherwise.
        coordinator.selectedTab = .search
        XCTAssertEqual(coordinator.selectedTab, .search)

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .diaryPush, generation
        )

        // Diary push mutates the diary detail pane only; the Search tab stack
        // stays empty despite selectedTab being `.search`.
        XCTAssertEqual(
            coordinator.navigationState.activePane, .foodDetail(foodID: foodID)
        )
        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: foodID)]
        )
        XCTAssertEqual(coordinator.navigationState.selectedDate, capturedDate)
        XCTAssertEqual(coordinator.navigationState.mealSlot, capturedSlot)
        XCTAssertTrue(coordinator.searchTabPath.isEmpty)

        // The real food-detail view model in the ready graph was created from
        // the captured arguments (the diary stack syncs its legacy VM context
        // to those same arguments afterwards, so it cannot mask a bad route).
        let detail = try XCTUnwrap(coordinator.foodDetailViewModel(for: foodID))
        XCTAssertEqual(detail.originDate, capturedDate)
        XCTAssertEqual(detail.originMealSlot, capturedSlot)
    }

    func testLiveSearchTabRoutesOnlySearchStackWithCapturedContext() async throws {
        let (coordinator, generation) = await makeReadyCoordinator()
        let client = LegacySearchRoutingClient.live(coordinator: coordinator)

        coordinator.searchViewModel?.updateContext(
            date: legacyContextDate, mealSlot: legacyContextSlot
        )
        let diaryStateBefore = coordinator.navigationState
        XCTAssertNotEqual(capturedDate, diaryStateBefore.selectedDate)
        XCTAssertNotEqual(capturedDate, coordinator.searchViewModel?.originDate)
        XCTAssertNotEqual(capturedSlot, coordinator.searchViewModel?.originMealSlot)

        // The captured origin wins even when the visible tab says otherwise.
        coordinator.selectedTab = .diary
        XCTAssertEqual(coordinator.selectedTab, .diary)

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .searchTab, generation
        )

        // Search-tab routing touches only its own native detail stack; the
        // hidden diary navigation and selectedTab are left intact.
        XCTAssertEqual(coordinator.searchTabPath, [.foodDetail(foodID: foodID)])
        XCTAssertEqual(coordinator.navigationState, diaryStateBefore)
        XCTAssertEqual(coordinator.selectedTab, .diary)

        // The no-context `openSearchTabFoodDetail(_:)` overload would have
        // used `navigationState.selectedDate`/`mealSlot`. The real VM context
        // proves the captured-argument overload was used instead.
        let detail = try XCTUnwrap(coordinator.foodDetailViewModel(for: foodID))
        XCTAssertEqual(detail.originDate, capturedDate)
        XCTAssertEqual(detail.originMealSlot, capturedSlot)
        XCTAssertNotEqual(detail.originDate, diaryStateBefore.selectedDate)
        XCTAssertNotEqual(detail.originDate, coordinator.searchViewModel?.originDate)
        XCTAssertNotEqual(detail.originMealSlot, coordinator.searchViewModel?.originMealSlot)
    }

    func testLiveStaleGenerationAfterSessionTransitionDeniesEveryRoute() async {
        let (coordinator, staleGeneration) = await makeReadyCoordinator()

        // Real session transition: sign out and restore into a new ready graph
        // with a new generation. Phase is signed in again, so denial below can
        // only come from the live client's real generation authority check —
        // not from a fake phase/gate and not from an idle coordinator.
        await coordinator.signOut()
        // start() would early-return from .signedOut, so drive the real restore
        // path explicitly to reach the next generation's ready graph.
        let currentPhase = await coordinator.retryRestore()
        guard case .signedIn = currentPhase else {
            XCTFail("Expected signed-in phase after restore; got \(currentPhase)")
            return
        }
        XCTAssertNotEqual(coordinator.session.sessionGeneration, staleGeneration)
        XCTAssertTrue(coordinator.session.isSignedIn)
        XCTAssertTrue(coordinator.isCurrentSearchGeneration(
            coordinator.session.sessionGeneration
        ))

        let client = LegacySearchRoutingClient.live(coordinator: coordinator)
        let initialState = coordinator.navigationState

        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .diaryPush, staleGeneration
        )
        client.openFoodDetail(
            foodID, capturedDate, capturedSlot, .searchTab, staleGeneration
        )
        client.openMealDetail(
            mealID, capturedDate, capturedSlot, quantity, .searchTab, staleGeneration
        )
        client.openMeals(capturedDate, capturedSlot, staleGeneration)

        XCTAssertEqual(coordinator.navigationState, initialState)
        XCTAssertTrue(coordinator.searchTabPath.isEmpty)
        XCTAssertNil(coordinator.foodDetailViewModel(for: foodID))
        XCTAssertTrue(coordinator.featureSheet == nil)
    }

    // MARK: - Live coordinator harness

    /// Real `SessionCoordinator` + `AppShellCoordinator` composition, brought
    /// to a signed-in ready graph via the actual `start()` / restore path.
    /// The fake service's restore outcome is the only controlled input; no
    /// sleeps, yields, or polling loops are used.
    @MainActor
    private func makeReadyCoordinator() async -> (AppShellCoordinator, UInt64) {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-routing", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-routing", displayName: "Alice")
        )
        let sessionService = RoutingSessionService(session: session)
        let coordinatorSession = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: routingBaseURL,
            cookieClearer: RoutingCookieClearer()
        )
        let coordinator = AppShellCoordinator(
            client: CalCoAPIClient(baseURL: routingBaseURL),
            session: coordinatorSession,
            diaryService: RoutingDiaryService(),
            searchService: RoutingSearchService(),
            logSubmissionStore: makeIsolatedStore(),
            todayProvider: { self.navigationDate }
        )

        let phase = await coordinator.start()
        XCTAssertTrue(
            coordinator.session.isSignedIn,
            "Controlled restore should reach signed in, got \(phase)"
        )
        // Ready-graph proof: the phase sink installed the signed-in feature
        // graph synchronously before start() returned.
        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertNotNil(coordinator.searchViewModel)
        let generation = coordinator.session.sessionGeneration
        XCTAssertTrue(coordinator.isCurrentSearchGeneration(generation))
        XCTAssertEqual(coordinator.navigationState.selectedDate, navigationDate)
        XCTAssertNil(coordinator.navigationState.mealSlot)
        return (coordinator, generation)
    }

    @MainActor
    private func makeIsolatedStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-legacy-routing-\(UUID().uuidString)", isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }
}

// MARK: - Narrow test doubles

private struct FoodRoute: Equatable {
    let id: String
    let date: LocalDiaryDate
    let mealSlot: MealSlot?
}

private struct MealRoute: Equatable {
    let id: String
    let date: LocalDiaryDate
    let mealSlot: MealSlot?
    let quantity: NutritionQuantity?
    let origin: LegacySearchRoutingClient.Origin
}

private struct MealsRoute: Equatable {
    let date: LocalDiaryDate
    let mealSlot: MealSlot?
}

@MainActor
private final class RouteRecorder {
    var currentGeneration: UInt64
    var phaseSupported = true

    var diaryFoodRoutes: [FoodRoute] = []
    var searchTabFoodRoutes: [FoodRoute] = []
    var mealRoutes: [MealRoute] = []
    var mealsRoutes: [MealsRoute] = []

    init(currentGeneration: UInt64) {
        self.currentGeneration = currentGeneration
    }

    func client() -> LegacySearchRoutingClient {
        .guarded(
            isCurrentGeneration: { [weak self] generation in
                self?.currentGeneration == generation
            },
            isSupportedPhase: { [weak self] in
                self?.phaseSupported == true
            },
            routeFoodDetail: { [weak self] id, date, mealSlot, origin in
                let route = FoodRoute(id: id, date: date, mealSlot: mealSlot)
                switch origin {
                case .diaryPush: self?.diaryFoodRoutes.append(route)
                case .searchTab: self?.searchTabFoodRoutes.append(route)
                }
            },
            routeMealDetail: { [weak self] id, date, mealSlot, quantity, origin in
                self?.mealRoutes.append(MealRoute(
                    id: id,
                    date: date,
                    mealSlot: mealSlot,
                    quantity: quantity,
                    origin: origin
                ))
            },
            routeMeals: { [weak self] date, mealSlot in
                self?.mealsRoutes.append(MealsRoute(date: date, mealSlot: mealSlot))
            }
        )
    }
}

// MARK: - Minimal live-harness fakes (no network, no keychain, no polling)

private let routingBaseURL = URL(string: "https://calco.example.com")!

private final class RoutingSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession

    init(session: LoginSession) { self.session = session }

    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout() async throws {}
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class RoutingCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private struct RoutingDiaryService: DiaryServicing {
    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        DiaryDay(date: date, logs: [])
    }
}

private struct RoutingSearchService: FoodSearchServicing {
    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult] {
        []
    }
}
