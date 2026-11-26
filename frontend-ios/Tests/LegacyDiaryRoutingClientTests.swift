import XCTest

@testable import CalCo

/// Behavioural tests for the Diary -> legacy-shell routing seam. The narrow
/// `guarded` factory keeps authority and route callbacks explicit so generation
/// denial, phase denial and captured date/slot forwarding are verified without
/// a session/auth framework or network. The live tests drive the real
/// `LegacyDiaryRoutingClient.live(coordinator:)` against a ready coordinator.
@MainActor
final class LegacyDiaryRoutingClientTests: XCTestCase {
    private let capturedDate = LocalDiaryDate(year: 2026, month: 11, day: 15)
    private let capturedSlot: MealSlot = .breakfast
    private let capturedGeneration: UInt64 = 42
    private let navigationDate = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let legacyContextDate = LocalDiaryDate(year: 2026, month: 11, day: 1)

    // MARK: - Guarded authority and capture

    func testCurrentGenerationAndPhaseForwardExactSlotAndDate() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        let client = recorder.client()

        client.startLogging(capturedSlot, capturedDate, capturedGeneration)

        XCTAssertEqual(
            recorder.routes,
            [DiaryLoggingRoute(slot: capturedSlot, date: capturedDate)]
        )
    }

    func testStaleGenerationDeniesRoute() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration + 1)
        recorder.client().startLogging(capturedSlot, capturedDate, capturedGeneration)
        XCTAssertTrue(recorder.routes.isEmpty)
    }

    func testUnsupportedPhaseDeniesRoute() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration)
        recorder.phaseSupported = false
        recorder.client().startLogging(capturedSlot, capturedDate, capturedGeneration)
        XCTAssertTrue(recorder.routes.isEmpty)
    }

    func testUnsupportedPhaseAndStaleGenerationDenyEveryRoute() {
        let recorder = RouteRecorder(currentGeneration: capturedGeneration + 1)
        recorder.phaseSupported = false
        recorder.client().startLogging(capturedSlot, capturedDate, capturedGeneration)
        XCTAssertTrue(recorder.routes.isEmpty)
    }

    // MARK: - Live wiring

    func testLiveClientFailsClosedWithoutSignedInReadyGraph() {
        let coordinator = AppShellCoordinator()
        let client = LegacyDiaryRoutingClient.live(coordinator: coordinator)
        let initialPane = coordinator.navigationState.activePane
        let initialDate = coordinator.navigationState.selectedDate

        client.startLogging(capturedSlot, capturedDate, capturedGeneration)

        XCTAssertEqual(coordinator.navigationState.activePane, initialPane)
        XCTAssertEqual(coordinator.navigationState.selectedDate, initialDate)
    }

    func testLiveClientForwardsCapturedContextNotNavigationOrLegacyVM() async {
        let (coordinator, generation) = await makeReadyCoordinator()
        let client = LegacyDiaryRoutingClient.live(coordinator: coordinator)

        // Every live authority source deliberately disagrees with the captured
        // arguments. The captured slot/date must win.
        coordinator.searchViewModel?.updateContext(
            date: legacyContextDate, mealSlot: .snack
        )
        XCTAssertNotEqual(capturedDate, coordinator.navigationState.selectedDate)
        XCTAssertNotEqual(capturedDate, coordinator.searchViewModel?.originDate)
        XCTAssertNotEqual(capturedSlot, coordinator.searchViewModel?.originMealSlot)

        client.startLogging(capturedSlot, capturedDate, generation)

        XCTAssertEqual(coordinator.navigationState.selectedDate, capturedDate)
        XCTAssertEqual(coordinator.navigationState.mealSlot, capturedSlot)
        XCTAssertEqual(
            coordinator.navigationState.activePane, .foodSearch,
            "startLogging must enter the existing logging flow."
        )
    }

    func testLiveClientStaleGenerationDoesNotMutateNavigation() async {
        let (coordinator, generation) = await makeReadyCoordinator()
        let client = LegacyDiaryRoutingClient.live(coordinator: coordinator)
        let before = coordinator.navigationState

        client.startLogging(capturedSlot, capturedDate, generation + 1)

        XCTAssertEqual(coordinator.navigationState, before)
    }

    /// The live client is installed as a store dependency. It must hold the
    /// coordinator weakly so it cannot keep a released window graph alive.
    func testLiveClientDoesNotRetainCoordinator() async {
        var ready: (AppShellCoordinator, UInt64)? = await makeReadyCoordinator()
        let generation = ready!.1
        var coordinator: AppShellCoordinator? = ready!.0
        let client = LegacyDiaryRoutingClient.live(coordinator: coordinator!)
        weak var weakCoordinator = coordinator
        ready = nil
        XCTAssertNotNil(weakCoordinator)

        coordinator!.startLogging(slot: capturedSlot, date: capturedDate)
        coordinator = nil
        XCTAssertNil(weakCoordinator, "The live client retained the coordinator.")

        // A deallocated coordinator fails closed rather than crashing.
        client.startLogging(capturedSlot, capturedDate, generation)
        XCTAssertNil(weakCoordinator)
    }

    // MARK: - Harness

    @MainActor
    private func makeReadyCoordinator() async -> (AppShellCoordinator, UInt64) {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-diary-routing", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-diary-routing", displayName: "Alice")
        )
        let sessionService = DiaryRoutingSessionService(session: session)
        let coordinatorSession = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: URL(string: "https://calco.example.com")!,
            cookieClearer: DiaryRoutingCookieClearer()
        )
        let coordinator = AppShellCoordinator(
            client: CalCoAPIClient(baseURL: URL(string: "https://calco.example.com")!),
            session: coordinatorSession,
            diaryService: DiaryRoutingDiaryService(),
            logSubmissionStore: makeIsolatedStore(),
            todayProvider: { self.navigationDate }
        )
        let phase = await coordinator.start()
        XCTAssertTrue(coordinator.session.isSignedIn, "Expected signed in, got \(phase)")
        XCTAssertNotNil(coordinator.diaryViewModel)
        let generation = coordinator.session.sessionGeneration
        XCTAssertTrue(coordinator.isCurrentDiaryGeneration(generation))
        return (coordinator, generation)
    }

    @MainActor
    private func makeIsolatedStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-diary-routing-\(UUID().uuidString)", isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }
}

// MARK: - Narrow doubles

private struct DiaryLoggingRoute: Equatable {
    let slot: MealSlot
    let date: LocalDiaryDate
}

@MainActor
private final class RouteRecorder {
    var currentGeneration: UInt64
    var phaseSupported = true
    var routes: [DiaryLoggingRoute] = []

    init(currentGeneration: UInt64) {
        self.currentGeneration = currentGeneration
    }

    func client() -> LegacyDiaryRoutingClient {
        .guarded(
            isCurrentGeneration: { [weak self] generation in
                self?.currentGeneration == generation
            },
            isSupportedPhase: { [weak self] in
                self?.phaseSupported == true
            },
            routeStartLogging: { [weak self] slot, date in
                self?.routes.append(DiaryLoggingRoute(slot: slot, date: date))
            }
        )
    }
}

private final class DiaryRoutingSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession
    init(session: LoginSession) { self.session = session }
    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout() async throws {}
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class DiaryRoutingCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private struct DiaryRoutingDiaryService: DiaryServicing {
    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        DiaryDay(date: date, logs: [])
    }
}
