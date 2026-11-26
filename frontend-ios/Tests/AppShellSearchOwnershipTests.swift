import XCTest

@testable import CalCo

/// Bounded ownership tests for the coordinator's Search ownership seam.
/// These tests use real SessionCoordinator + AppShellCoordinator composition
/// with fake SessionServicing/diary/search adapters (no keychain, no network,
/// no polling). They prove ready-graph/generation authority is preserved while
/// `.tca` mode avoids constructing or driving a legacy SearchViewModel.
@MainActor
final class AppShellSearchOwnershipTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!
    private let initialDate = LocalDiaryDate(year: 2026, month: 11, day: 24)

    func testLegacyOwnershipIsDefaultAndCreatesSearchViewModelOnReady() async {
        let coordinator = makeCoordinator()

        XCTAssertEqual(coordinator.searchOwnership, .legacy)

        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            return XCTFail("Expected signed-in phase, got \(phase)")
        }

        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertNotNil(coordinator.searchViewModel)
        let generation = coordinator.session.sessionGeneration
        XCTAssertTrue(coordinator.isCurrentSearchGeneration(generation))
        XCTAssertFalse(coordinator.isCurrentSearchGeneration(generation + 1))
    }

    func testTCADoesNotConstructSearchViewModelButKeepsReadyGenerationGuard() async {
        let coordinator = makeCoordinator(searchOwnership: .tca)

        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            return XCTFail("Expected signed-in phase, got \(phase)")
        }

        XCTAssertEqual(coordinator.searchOwnership, .tca)
        XCTAssertNil(coordinator.searchViewModel, "TCA mode must not construct a legacy SearchViewModel")
        XCTAssertNotNil(coordinator.diaryViewModel, "Ready graph must still exist for non-search features")
        let generation = coordinator.session.sessionGeneration
        XCTAssertTrue(coordinator.isCurrentSearchGeneration(generation))
        XCTAssertFalse(coordinator.isCurrentSearchGeneration(generation + 1))
    }

    func testTCAModeStartContextChangeAndLogDeliveryDoNotIssueLegacySearchCalls() async throws {
        let search = RecordingSearchService()
        let coordinator = makeCoordinator(searchOwnership: .tca, searchService: search)

        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            return XCTFail("Expected signed-in phase, got \(phase)")
        }

        XCTAssertNil(coordinator.searchViewModel)
        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertEqual(search.searchCallCount, 0)
        XCTAssertEqual(search.recentCallCount, 0)
        XCTAssertEqual(search.categoryCallCount, 0)
        XCTAssertEqual(search.barcodeCallCount, 0)

        // Context-changing coordinator actions that would drive a legacy
        // SearchViewModel through legacySearchContextDidChange/ClearSelection.
        // In TCA mode they must not create or use a legacy VM, so no catalog/
        // history service calls can be issued through it.
        coordinator.showSearch()
        coordinator.startLogging(slot: .lunch, date: initialDate.addingDays(1))
        coordinator.showDiary()
        coordinator.openSearchTabFoodDetail(
            "food-1",
            date: initialDate,
            mealSlot: .breakfast
        )
        coordinator.popSearchTabDetail()

        // Log-delivery-like coordinator path: a ready food detail success routes
        // through handleFoodDetailSuccess, which clears/updates legacy search
        // only when a legacy VM exists. Drive the public food-detail path and
        // assert the search service remains untouched.
        coordinator.openFoodDetail(
            "food-1",
            date: initialDate,
            mealSlot: .breakfast
        )
        let detail = try XCTUnwrap(coordinator.foodDetailViewModel(for: "food-1"))
        XCTAssertEqual(detail.foodID, "food-1")

        // Real log-delivery path: handleFoodDetailSuccess clears/updates legacy
        // search when a legacy VM exists. In TCA mode the helpers must no-op and
        // the recording search service must remain untouched.
        coordinator.handleFoodDetailSuccess(detail)

        XCTAssertEqual(search.searchCallCount, 0)
        XCTAssertEqual(search.recentCallCount, 0)
        XCTAssertEqual(search.categoryCallCount, 0)
        XCTAssertEqual(search.barcodeCallCount, 0)
        XCTAssertNotNil(coordinator.diaryViewModel, "Diary remains ready in TCA mode")
        XCTAssertTrue(
            coordinator.isCurrentSearchGeneration(coordinator.session.sessionGeneration)
        )
    }

    // MARK: - Installed TCA handler integration (real coordinator + real session)

    /// The narrow root-bridge seam is installed but never exercised by the three
    /// tests above. This drives a real SessionCoordinator start handshake, then
    /// a public context transition (startLogging -> ready-generation-guarded
    /// context helper) and asserts the installed callback receives the EXACT
    /// historical date + meal slot + original ready generation, with no legacy
    /// VM/catalog/history/category/barcode calls in `.tca` mode.
    func testTCASearchHandlerReceivesExactContextPayloadFromPublicTransition() async {
        let search = RecordingSearchService()
        let coordinator = makeCoordinator(searchOwnership: .tca, searchService: search)
        let recorder = TCAMutationRecorder()
        installTCASearchRecorder(recorder, on: coordinator)

        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            return XCTFail("Expected signed-in phase, got \(phase)")
        }
        // Handlers are installed before start; the start graph build emits no
        // context/invalidation delivery. Clear defensively so the assertions
        // below reflect only the deliberate public transitions.
        recorder.clear()

        let generation = coordinator.session.sessionGeneration
        let historicalDate = initialDate.addingDays(-7)

        // startLogging captures the exact requested date + slot and routes it
        // through the public coordinator into the installed TCA callback.
        coordinator.startLogging(slot: .lunch, date: historicalDate)
        // Additional public context transitions exercise the same seam. Record
        // the trace but do not pin an exact count (legit multi-step nav).
        coordinator.showSearch()
        coordinator.showDiary()

        guard let event = recorder.contexts.first(where: {
            $0.date == historicalDate && $0.slot == .lunch
        }) else {
            return XCTFail(
                "Expected TCA context delivery (date: \(historicalDate.formatted), slot: lunch, gen: \(generation)), got \(recorder.contexts)"
            )
        }
        XCTAssertEqual(event.generation, generation)
        XCTAssertTrue(
            recorder.contexts.allSatisfy { $0.generation == generation },
            "Every TCA context delivery must carry the original ready generation"
        )
        XCTAssertTrue(recorder.recentsGenerations.isEmpty)

        XCTAssertNil(coordinator.searchViewModel, "TCA mode must not construct a legacy SearchViewModel")
        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertEqual(search.searchCallCount, 0)
        XCTAssertEqual(search.recentCallCount, 0)
        XCTAssertEqual(search.categoryCallCount, 0)
        XCTAssertEqual(search.barcodeCallCount, 0)
    }

    /// Real external mutation delivery: an existing public food-detail success
    /// path invokes the recents-invalidation helper. The installed callback must
    /// fire exactly once with the original ready generation, the detail origin
    /// context must reach the context callback, and no legacy search path may
    /// be touched. The ready diary graph stays consistent with the fake.
    func testTCASearchHandlerReceivesRecentsInvalidationOnceFromRealLogDelivery() async throws {
        let search = RecordingSearchService()
        let coordinator = makeCoordinator(searchOwnership: .tca, searchService: search)
        let recorder = TCAMutationRecorder()
        installTCASearchRecorder(recorder, on: coordinator)

        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            return XCTFail("Expected signed-in phase, got \(phase)")
        }
        recorder.clear()

        let generation = coordinator.session.sessionGeneration
        XCTAssertNil(coordinator.searchViewModel)
        XCTAssertEqual(search.recentCallCount, 0)

        // Open a real detail (which may itself update search context), then
        // isolate the recorder so assertions reflect only the mutation delivery.
        coordinator.openFoodDetail("food-2", date: initialDate, mealSlot: .breakfast)
        let detail = try XCTUnwrap(coordinator.foodDetailViewModel(for: "food-2"))
        XCTAssertEqual(detail.foodID, "food-2")
        recorder.clear()

        // Genuine external mutation delivery through the production path.
        coordinator.handleFoodDetailSuccess(detail)

        XCTAssertEqual(
            recorder.recentsGenerations,
            [generation],
            "Recents invalidation must fire exactly once with the ready generation"
        )
        guard let context = recorder.contexts.first(where: {
            $0.date == initialDate && $0.slot == .breakfast
        }) else {
            return XCTFail("Expected detail origin context delivery, got \(recorder.contexts)")
        }
        XCTAssertEqual(context.generation, generation)

        XCTAssertNil(coordinator.searchViewModel)
        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertTrue(coordinator.isCurrentSearchGeneration(generation))
        XCTAssertEqual(search.searchCallCount, 0)
        XCTAssertEqual(search.recentCallCount, 0)
        XCTAssertEqual(search.categoryCallCount, 0)
        XCTAssertEqual(search.barcodeCallCount, 0)
    }

    /// A stale generation must never reach the installed TCA callbacks. The
    /// retained diary `onDateChange` closure delivers context at the current
    /// generation; after a genuine sign-out the SAME retained action (old
    /// closure, old generation) must be rejected by the ready-generation guard.
    /// No callback is invoked manually and no exact count is pinned.
    func testStaleGenerationDeliversNoTCASearchCallbacksAfterSignOut() async throws {
        let coordinator = makeCoordinator(searchOwnership: .tca)
        let recorder = TCAMutationRecorder()
        installTCASearchRecorder(recorder, on: coordinator)

        let phase = await coordinator.start()
        guard case .signedIn = phase else {
            return XCTFail("Expected signed-in phase, got \(phase)")
        }
        recorder.clear()

        let generation = coordinator.session.sessionGeneration
        let oldDiary = try XCTUnwrap(coordinator.diaryViewModel)

        // The retained closure fires with the original generation while current.
        let historicalDate = initialDate.addingDays(-3)
        await oldDiary.selectDate(historicalDate)
        XCTAssertTrue(
            recorder.contexts.contains(where: {
                $0.date == historicalDate && $0.generation == generation
            }),
            "Expected a current-generation context delivery before sign-out, got \(recorder.contexts)"
        )

        // Genuine session transition: sign-out bumps the generation and drops
        // the ready graph.
        _ = await coordinator.session.signOut()
        XCTAssertEqual(coordinator.session.sessionGeneration, generation + 1)
        XCTAssertNil(coordinator.diaryViewModel)
        recorder.clear()

        // Same retained stale action must not reach either TCA callback.
        await oldDiary.selectDate(historicalDate.addingDays(-1))
        XCTAssertTrue(
            recorder.contexts.isEmpty,
            "No context callback for the stale generation, got \(recorder.contexts)"
        )
        XCTAssertTrue(
            recorder.recentsGenerations.isEmpty,
            "No recents callback for the stale generation, got \(recorder.recentsGenerations)"
        )
    }

    // MARK: - Harness

    @MainActor
    private func makeCoordinator(
        searchOwnership: SearchOwnership = .legacy,
        searchService: (any FoodSearchServicing)? = nil
    ) -> AppShellCoordinator {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-search-ownership", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-search-ownership", displayName: "Alice")
        )
        let sessionService = SearchOwnershipSessionService(session: session)
        let coordinatorSession = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: baseURL,
            cookieClearer: SearchOwnershipCookieClearer()
        )
        return AppShellCoordinator(
            client: CalCoAPIClient(baseURL: baseURL),
            session: coordinatorSession,
            diaryService: SearchOwnershipDiaryService(),
            searchService: searchService ?? RecordingSearchService(),
            logSubmissionStore: makeIsolatedStore(),
            searchOwnership: searchOwnership,
            todayProvider: { self.initialDate }
        )
    }

    /// Installs the narrow root-bridge seam with a deterministic, MainActor
    /// recorder. The closures are inferred `@MainActor` from the handler type,
    /// so all captures are synchronous and need no sleeps/polling.
    @MainActor
    private func installTCASearchRecorder(
        _ recorder: TCAMutationRecorder,
        on coordinator: AppShellCoordinator
    ) {
        coordinator.installTCASearchHandlers(
            contextChanged: { date, slot, generation in
                recorder.contextChanged(date: date, slot: slot, generation: generation)
            },
            recentsInvalidated: { generation in
                recorder.recentsInvalidated(generation: generation)
            }
        )
    }

    @MainActor
    private func makeIsolatedStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "calco-search-ownership-\(UUID().uuidString)", isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }
}

// MARK: - Fakes

/// Nonisolated value type so it can conform to CustomStringConvertible while
/// being captured by a @MainActor recorder. Produces a readable trace on failure.
private struct TCACapturedContext: CustomStringConvertible {
    let date: LocalDiaryDate
    let slot: MealSlot?
    let generation: UInt64

    var description: String {
        "Context(date: \(date.formatted), slot: \(slot.map { String(describing: $0) } ?? "nil"), generation: \(generation))"
    }
}

/// Deterministic MainActor recorder for the installed TCA search handlers.
/// No locks, sleeps, Task.yield, or polling — every write happens synchronously
/// inside the @MainActor callback the coordinator invokes.
@MainActor
private final class TCAMutationRecorder {
    private(set) var contexts: [TCACapturedContext] = []
    private(set) var recentsGenerations: [UInt64] = []

    func clear() {
        contexts.removeAll()
        recentsGenerations.removeAll()
    }

    func contextChanged(date: LocalDiaryDate, slot: MealSlot?, generation: UInt64) {
        contexts.append(TCACapturedContext(date: date, slot: slot, generation: generation))
    }

    func recentsInvalidated(generation: UInt64) {
        recentsGenerations.append(generation)
    }
}

private final class RecordingSearchService: FoodSearchServicing, FoodSearchHistoryServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _searchCallCount = 0
    private var _recentCallCount = 0
    private var _categoryCallCount = 0
    private var _barcodeCallCount = 0

    var searchCallCount: Int { { lock.lock(); defer { lock.unlock() }; return _searchCallCount }() }
    var recentCallCount: Int { { lock.lock(); defer { lock.unlock() }; return _recentCallCount }() }
    var categoryCallCount: Int { { lock.lock(); defer { lock.unlock() }; return _categoryCallCount }() }
    var barcodeCallCount: Int { { lock.lock(); defer { lock.unlock() }; return _barcodeCallCount }() }

    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult] {
        lock.lock(); _searchCallCount += 1; lock.unlock()
        return []
    }

    func recentItems(
        from: LocalDiaryDate,
        to: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> [RecentLogItem] {
        lock.lock(); _recentCallCount += 1; lock.unlock()
        return []
    }

    func categorySuggestions(query: String, limit: Int) async throws -> [CategorySuggestion] {
        lock.lock(); _categoryCallCount += 1; lock.unlock()
        return []
    }

    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup {
        lock.lock(); _barcodeCallCount += 1; lock.unlock()
        throw FoodSearchServiceError("not found")
    }
}

private final class SearchOwnershipSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession

    init(session: LoginSession) { self.session = session }

    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout() async throws {}
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class SearchOwnershipCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private struct SearchOwnershipDiaryService: DiaryServicing {
    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        DiaryDay(date: date, logs: [])
    }
}
