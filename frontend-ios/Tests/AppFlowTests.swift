import Combine
import Foundation
import SwiftUI
import XCTest

@testable import CalCo

// MARK: - Session / feature doubles for app-flow tests
//
// These are deliberately narrow in-memory fakes: no URLSession, database,
// keychain, or real credentials. They let AppFlowTests drive the real
// SessionCoordinator and the real AppShellCoordinator composition together.
//
// Security invariant: a request that began under an earlier session and
// completes after a new user has entered the app carries the old generation,
// so its 401 must not advance the live session generation or invalidate the
// newer session.

private let appFlowBaseURL = URL(string: "https://calco.example.com")!
private let appFlowWaitTimeout: TimeInterval = 5

private actor AppFlowSubmissionSender: LogSubmissionSending {
    private var requests: [LogSubmissionRequest] = []

    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] {
        requests.append(request)
        return []
    }

    func recordedRequests() -> [LogSubmissionRequest] {
        requests
    }
}

private final class AppFlowSessionService: SessionServicing, @unchecked Sendable {
    typealias RestoreHandler = @Sendable () async throws -> SessionRestoreOutcome
    typealias LoginHandler =
        @Sendable (_ username: String, _ password: String) async throws -> LoginSession
    typealias LogoutHandler = @Sendable () async throws -> Void

    private let lock = NSLock()
    private var restoreHandler: RestoreHandler
    private var loginHandler: LoginHandler
    private var logoutHandler: LogoutHandler
    private var restoreCallCount = 0
    private var loginCallCount = 0
    private var logoutCallCount = 0

    init(
        restore: @escaping RestoreHandler = { .unauthenticated(.signedOut) },
        login: @escaping LoginHandler = { _, _ in
            throw CalCoAPIError.unauthorized(nil)
        },
        logout: @escaping LogoutHandler = {}
    ) {
        self.restoreHandler = restore
        self.loginHandler = login
        self.logoutHandler = logout
    }

    var restoreCalls: Int { lock.withLock { restoreCallCount } }
    var loginCalls: Int { lock.withLock { loginCallCount } }
    var logoutCalls: Int { lock.withLock { logoutCallCount } }

    func setRestoreHandler(_ handler: @escaping RestoreHandler) {
        lock.withLock { restoreHandler = handler }
    }

    func setLoginHandler(_ handler: @escaping LoginHandler) {
        lock.withLock { loginHandler = handler }
    }

    func setLogoutHandler(_ handler: @escaping LogoutHandler) {
        lock.withLock { logoutHandler = handler }
    }

    func restoreSession() async throws -> SessionRestoreOutcome {
        let handler = lock.withLock {
            restoreCallCount += 1
            return restoreHandler
        }
        return try await handler()
    }

    func login(username: String, password: String) async throws -> LoginSession {
        let handler = lock.withLock {
            loginCallCount += 1
            return loginHandler
        }
        return try await handler(username, password)
    }

    func logout() async throws {
        let handler = lock.withLock {
            logoutCallCount += 1
            return logoutHandler
        }
        try await handler()
    }

    func logout(sessionCookies: [HTTPCookie]) async throws {
        try await logout()
    }
}

private final class AppFlowCookieClearer: SessionCookieClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }

    func clearCookies(for baseURL: URL) {
        lock.withLock { storage.append(baseURL) }
    }

    var calls: [URL] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }
}

private actor AppFlowDiaryService: DiaryServicing {
    private var days: [LocalDiaryDate: DiaryDay] = [:]
    private var configuredError: DiaryServiceError?
    private var calls: [LocalDiaryDate] = []
    private var deletedLogIDs: Set<String> = []

    func setDay(_ day: DiaryDay) {
        days[day.date] = day
    }

    func setError(_ error: DiaryServiceError?) {
        configuredError = error
    }

    func callCount(for date: LocalDiaryDate) -> Int {
        calls.filter { $0 == date }.count
    }

    func waitForCallCount(_ date: LocalDiaryDate, atLeast count: Int) async {
        let deadline = Date().addingTimeInterval(appFlowWaitTimeout)
        while calls.filter({ $0 == date }).count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            calls.filter { $0 == date }.count,
            count,
            "Timed out waiting for \(count) diary fetches on \(date.formatted)"
        )
    }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        calls.append(date)
        if let configuredError {
            throw configuredError
        }
        let day = days[date] ?? DiaryDay(date: date)
        return DiaryDay(
            date: day.date,
            logs: day.logs.filter { !deletedLogIDs.contains($0.id) },
            goal: day.goal,
            prefs: day.prefs
        )
    }

    func deleteLog(id: String) async throws {
        deletedLogIDs.insert(id)
    }
}

private final class AppFlowSearchService: FoodSearchServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [FoodSearchResult]

    init(results: [FoodSearchResult] = []) {
        self.results = results
    }

    func setResults(_ results: [FoodSearchResult]) {
        lock.withLock { self.results = results }
    }

    func searchFoods(
        query: String,
        scope: FoodSearchScope
    ) async throws -> [FoodSearchResult] {
        lock.withLock { results }
    }
}

private final class AppFlowSettingsService: DiarySettingsServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var goal: GoalSnapshot
    private var preferences: DiaryPreferences
    private var goalRequests: [LocalDiaryDate] = []
    private var savedGoals: [SaveGoalRequest] = []
    private var savedPreferences: [DiaryPreferences] = []

    init(
        goal: GoalSnapshot,
        preferences: DiaryPreferences
    ) {
        self.goal = goal
        self.preferences = preferences
    }

    func setGoal(_ value: GoalSnapshot) {
        lock.withLock { goal = value }
    }

    func setPreferences(_ value: DiaryPreferences) {
        lock.withLock { preferences = value }
    }

    func goalRequestDates() -> [LocalDiaryDate] { lock.withLock { goalRequests } }
    func goalSaveRequests() -> [SaveGoalRequest] { lock.withLock { savedGoals } }
    func preferenceSaveRequests() -> [DiaryPreferences] { lock.withLock { savedPreferences } }

    func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
        lock.withLock {
            goalRequests.append(date)
            return goal
        }
    }

    func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot {
        lock.withLock {
            savedGoals.append(request)
            let saved = GoalSnapshot(
                requestedDate: request.localDate,
                effectiveFrom: request.localDate,
                source: .saved,
                targets: request.targets
            )
            goal = saved
            return saved
        }
    }

    func fetchDiaryPreferences() async throws -> DiaryPreferences {
        lock.withLock { preferences }
    }

    func updateDiaryPreferences(_ value: DiaryPreferences) async throws -> DiaryPreferences {
        lock.withLock {
            savedPreferences.append(value)
            preferences = value
            return value
        }
    }
}

/// Goal-writeback fake. `authoritativeSave` is the server response returned by
/// `saveGoal`, deliberately allowed to differ from the submitted draft so a
/// test can prove the coordinator maps the *server* snapshot, not the draft.
/// `armHold` / `waitForSaveStarted` / `releaseSave` let a save begin under one
/// session and resolve after a real 401, without any sleep or polling.
private actor AppFlowGoalSettingsService: DiarySettingsServicing {
    private var goal: GoalSnapshot
    private let preferences: DiaryPreferences
    private let authoritativeSave: GoalSnapshot?
    private var saveRequests: [SaveGoalRequest] = []
    private var goalFetchDates: [LocalDiaryDate] = []
    private var holdNextSave = false
    private var saveStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    // Preferences knobs. All default to the original pass-through behaviour,
    // so the existing goal-writeback tests are unaffected.
    private let authoritativePreferencesSave: DiaryPreferences?
    private let preferencesSaveError: Error?
    private var savedPreferenceRequests: [DiaryPreferences] = []
    private var holdNextPreferencesSave = false
    private var preferencesSaveStarted = false
    private var preferencesReleased = false
    private var preferencesStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var preferencesReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        goal: GoalSnapshot,
        preferences: DiaryPreferences,
        authoritativeSave: GoalSnapshot? = nil,
        authoritativePreferencesSave: DiaryPreferences? = nil,
        preferencesSaveError: Error? = nil
    ) {
        self.goal = goal
        self.preferences = preferences
        self.authoritativeSave = authoritativeSave
        self.authoritativePreferencesSave = authoritativePreferencesSave
        self.preferencesSaveError = preferencesSaveError
    }

    func armHold() {
        holdNextSave = true
        saveStarted = false
        released = false
    }

    func waitForSaveStarted() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseSave() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func armPreferencesHold() {
        holdNextPreferencesSave = true
        preferencesSaveStarted = false
        preferencesReleased = false
    }

    func waitForPreferencesSaveStarted() async {
        guard !preferencesSaveStarted else { return }
        await withCheckedContinuation { preferencesStartWaiters.append($0) }
    }

    func releasePreferencesSave() {
        preferencesReleased = true
        let waiters = preferencesReleaseWaiters
        preferencesReleaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func requests() -> [SaveGoalRequest] { saveRequests }
    func preferenceRequests() -> [DiaryPreferences] { savedPreferenceRequests }
    func fetchDates() -> [LocalDiaryDate] { goalFetchDates }

    func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
        goalFetchDates.append(date)
        return goal
    }

    func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot {
        saveRequests.append(request)
        saveStarted = true
        let started = startWaiters
        startWaiters = []
        for waiter in started { waiter.resume() }
        if holdNextSave {
            holdNextSave = false
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        if let authoritativeSave { return authoritativeSave }
        let saved = GoalSnapshot(
            requestedDate: request.localDate,
            effectiveFrom: request.localDate,
            source: .saved,
            targets: request.targets
        )
        goal = saved
        return saved
    }

    func fetchDiaryPreferences() async throws -> DiaryPreferences { preferences }

    func updateDiaryPreferences(_ value: DiaryPreferences) async throws -> DiaryPreferences {
        savedPreferenceRequests.append(value)
        preferencesSaveStarted = true
        let started = preferencesStartWaiters
        preferencesStartWaiters = []
        for waiter in started { waiter.resume() }
        if let preferencesSaveError { throw preferencesSaveError }
        if holdNextPreferencesSave {
            holdNextPreferencesSave = false
            if !preferencesReleased {
                await withCheckedContinuation { preferencesReleaseWaiters.append($0) }
            }
        }
        return authoritativePreferencesSave ?? value
    }
}

/// Main-actor capture of the installed store-backed preferences callback.
private final class PreferencesCallbackBox: @unchecked Sendable {
    struct Call: Equatable {
        let generation: UInt64
        let prefs: DiaryPrefs
    }

    private(set) var calls: [Call] = []

    func record(_ generation: UInt64, _ prefs: DiaryPrefs) {
        calls.append(Call(generation: generation, prefs: prefs))
    }
}

/// Main-actor capture of the installed store-backed goal callback.
private final class GoalCallbackBox: @unchecked Sendable {
    struct Call: Equatable {
        let generation: UInt64
        let targets: DiaryGoalTargets
        let date: LocalDiaryDate
    }

    private(set) var calls: [Call] = []

    func record(_ generation: UInt64, _ targets: DiaryGoalTargets, _ date: LocalDiaryDate) {
        calls.append(Call(generation: generation, targets: targets, date: date))
    }
}

private final class SettingsLoadBox: @unchecked Sendable {
    var fulfilled = false
    var continuation: CheckedContinuation<Void, Never>?
    var cancellable: AnyCancellable?
}

private actor AppFlowFoodDetailService: FoodDetailServicing {
    private let food: FoodDetail
    private var holdsNextLog = false
    private var logStarted = false
    private var logReleased = false
    private var logContinuation: CheckedContinuation<Void, Never>?
    private var requests: [FoodLogCreateRequest] = []
    private var createError: FoodDetailServiceError?
    private var createdLogID = "created-log"

    init(
        food: FoodDetail = FoodDetail(
            id: "food-1",
            name: "Test Food",
            defaultQuantity: "100",
            defaultUnit: "g"
        )
    ) {
        self.food = food
    }

    func holdNextLog() {
        holdsNextLog = true
        logStarted = false
        logReleased = false
    }

    func waitForLogStart() async {
        let deadline = Date().addingTimeInterval(appFlowWaitTimeout)
        while !logStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(logStarted, "Timed out waiting for the log request to start")
    }

    func loggedRequests() -> [FoodLogCreateRequest] {
        requests
    }

    func setCreateError(_ error: FoodDetailServiceError?) {
        createError = error
    }

    func setCreatedLogID(_ id: String) {
        createdLogID = id
    }

    func releaseLog() {
        logReleased = true
        logContinuation?.resume()
        logContinuation = nil
    }

    func fetchFoodDetail(id: String) async throws -> FoodDetail {
        food
    }

    func fetchUnits() async throws -> [FoodUnit] {
        [FoodUnit(code: "g", name: "Gram")]
    }

    func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        requests.append(request)
        if holdsNextLog {
            holdsNextLog = false
            logStarted = true
            await withCheckedContinuation { continuation in
                if logReleased {
                    continuation.resume()
                } else {
                    logContinuation = continuation
                }
            }
        }
        if let createError {
            throw createError
        }
        return CreatedFoodLog(id: createdLogID, date: request.date, mealSlot: request.mealSlot)
    }
}

private func appFlowSession(
    id: String = "identity-a",
    username: String = "alice",
    role: IdentityRole = .user,
    displayName: String = "Alice",
    hasProfile: Bool = true
) -> LoginSession {
    LoginSession(
        identity: AuthIdentity(id: id, username: username, role: role),
        profile: hasProfile
            ? AuthProfile(id: "profile-\(id)", displayName: displayName)
            : nil
    )
}

private func appFlowUser(
    from session: LoginSession
) -> AuthUser {
    let role: AuthRole
    switch session.identity.role {
    case .user: role = .user
    case .admin: role = .admin
    case .other: role = .other
    }
    return AuthUser(
        id: session.identity.id,
        username: session.identity.username,
        role: role,
        displayName: session.profile?.displayName
    )
}

@MainActor
final class AppFlowTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let yesterday = LocalDiaryDate(year: 2026, month: 11, day: 16)

    private func makeIsolatedSubmissionStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-appflow-default-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    @discardableResult
    private func seedSubmission(
        in store: LogSubmissionStore,
        accountID: String,
        foodID: String,
        foodName: String = "Test Food",
        amount: String,
        mealSlot: MealSlot = .lunch,
        state: LogSubmissionState = .uncertain
    ) throws -> PendingLogSubmission {
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: foodID,
            foodName: foodName,
            date: date,
            mealSlot: mealSlot,
            amount: amount,
            unit: "g",
            notes: nil,
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: appFlowBaseURL,
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let entry = try store.reserve(
            accountID: accountID,
            foodName: foodName,
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )
        switch state {
        case .uncertain:
            try store.markUncertain(
                id: entry.id,
                accountID: accountID,
                status: nil,
                message: "offline"
            )
        case .conflicted:
            try store.markConflicted(
                id: entry.id,
                accountID: accountID,
                message: "conflict"
            )
        case .succeeded:
            try store.markSucceeded(
                id: entry.id,
                accountID: accountID,
                logID: "seeded-log",
                date: date,
                mealSlot: mealSlot,
                replayed: false
            )
        case .rejected:
            try store.markRejected(
                id: entry.id,
                accountID: accountID,
                status: 400,
                message: "rejected"
            )
        case .inFlight:
            try store.markInFlight(id: entry.id, accountID: accountID)
        case .invalidated:
            _ = try store.invalidateUnresolved(
                accountID: accountID,
                foodID: foodID,
                date: date,
                reason: "deleted"
            )
        }
        return store.entry(id: entry.id, accountID: accountID) ?? entry
    }

    private func makeCoordinator(
        sessionService: AppFlowSessionService,
        diaryService: AppFlowDiaryService,
        cookieClearer: AppFlowCookieClearer,
        searchService: AppFlowSearchService = AppFlowSearchService(),
        foodDetailService: AppFlowFoodDetailService = AppFlowFoodDetailService(),
        settingsService: (any DiarySettingsServicing)? = nil,
        logSubmissionStore: LogSubmissionStore? = nil,
        logSubmissionService: LogSubmissionService? = nil,
        searchOwnership: SearchOwnership = .legacy,
        diaryScreenOwnership: DiaryScreenOwnership = .legacy,
        todayProvider: (() -> LocalDiaryDate)? = nil
    ) -> AppShellCoordinator {
        let client = CalCoAPIClient(baseURL: appFlowBaseURL)
        let session = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: appFlowBaseURL,
            cookieClearer: cookieClearer
        )
        return AppShellCoordinator(
            client: client,
            session: session,
            diaryService: diaryService,
            searchService: searchService,
            foodDetailService: foodDetailService,
            settingsService: settingsService ?? AppFlowSettingsService(
                goal: GoalSnapshot(
                    requestedDate: date,
                    effectiveFrom: nil,
                    source: .default,
                    targets: GoalTargets(
                        calorieTarget: 2_100,
                        proteinTargetG: 150,
                        carbsTargetG: 240,
                        fatTargetG: 60
                    )
                ),
                preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases))
            ),
            logSubmissionStore: logSubmissionStore ?? makeIsolatedSubmissionStore(),
            logSubmissionService: logSubmissionService,
            searchOwnership: searchOwnership,
            diaryScreenOwnership: diaryScreenOwnership,
            todayProvider: todayProvider ?? { self.date }
        )
    }

    private func waitForLoadedDiary(
        _ coordinator: AppShellCoordinator
    ) async {
        await waitUntil {
            coordinator.diaryViewModel?.state == .loaded(.idle)
        }
    }

    private func waitForSettingsLoaded(
        _ coordinator: AppShellCoordinator
    ) async {
        await waitUntil {
            guard let settings = coordinator.settingsViewModel else { return false }
            guard case .loaded = settings.goalState else { return false }
            guard case .loaded = settings.preferencesState else { return false }
            return true
        }
    }

    /// Deterministic rendezvous on the settings view model's own published
    /// goal state. No sleep, yield, poll or duration — the sink fires on the
    /// MainActor change itself.
    private func awaitGoalSettingsLoaded(_ settings: DiarySettingsViewModel) async {
        if case .loaded = settings.goalState { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = SettingsLoadBox()
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
            let box = SettingsLoadBox()
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

    /// Deterministic rendezvous on the diary's own published load state.
    private func awaitLoadedDiary(_ coordinator: AppShellCoordinator) async {
        guard let diary = coordinator.diaryViewModel else {
            XCTFail("Expected a diary view model")
            return
        }
        if diary.state == .loaded(.idle) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = SettingsLoadBox()
            box.continuation = continuation
            box.cancellable = diary.$state.sink { state in
                guard !box.fulfilled, state == .loaded(.idle) else { return }
                box.fulfilled = true
                let pending = box.continuation
                box.continuation = nil
                box.cancellable?.cancel()
                box.cancellable = nil
                pending?.resume()
            }
        }
    }

    func testRetainedMealsAndLibraryCallbacksCannotRebindToAnotherAccount() async {
        let first = appFlowSession()
        let second = appFlowSession(id: "identity-b", username: "bob", displayName: "Bob")
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(first) }, login: { _, _ in second }
        )
        let sender = AppFlowSubmissionSender()
        let diaryService = AppFlowDiaryService()
        let coordinator = makeCoordinator(
            sessionService: sessionService, diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            logSubmissionService: LogSubmissionService(sender: sender),
            searchOwnership: .tca, diaryScreenOwnership: .storeBackedScreen
        )
        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        coordinator.openMeals(date: date, mealSlot: .lunch)
        guard case .meals(let request) = coordinator.featureSheet else {
            return XCTFail("Missing originating Meals request")
        }
        XCTAssertEqual(request.generation, coordinator.session.sessionGeneration)
        let submit = coordinator.featureSubmissionHandler(expectedGeneration: request.generation)
        let logged = coordinator.featureLoggedHandler(expectedGeneration: request.generation)
        let expired = coordinator.featureSessionExpiredHandler(expectedGeneration: request.generation)
        let librarySubmission = HandlerLibraryLogSubmissionService(handler: submit)
        var recents = 0
        var mutations = 0
        coordinator.installTCASearchHandlers(contextChanged: { _, _, _ in }, recentsInvalidated: { _ in
            recents += 1
        })
        coordinator.installDiaryMutationCallback { _ in mutations += 1 }

        let login = coordinator.loginViewModel
        login.username = "bob"
        login.password = "pw"
        await login.submit()
        await awaitLoadedDiary(coordinator)
        let generation = coordinator.session.sessionGeneration
        let before = await diaryService.callCount(for: date)
        let draft = LogSubmissionDraft(
            item: .product(id: "food-1"), date: date, mealSlot: .lunch,
            amount: "100", unit: "g", notes: nil, timeZone: "UTC"
        )
        var completions: [LogSubmissionServiceResult] = []
        submit([draft], ["Food"], "Food") { completions.append($0) }
        let libraryResult = await librarySubmission.submit(
            accountID: first.identity.id, drafts: [draft], itemNames: ["Food"],
            summary: "Food", baseURL: appFlowBaseURL
        )
        logged(date, .lunch)
        expired()

        XCTAssertEqual(completions, [.failure(.unauthorized)])
        XCTAssertEqual(libraryResult, .failure(.unauthorized))
        XCTAssertEqual(coordinator.session.sessionGeneration, generation)
        XCTAssertEqual(coordinator.currentUser?.id, second.identity.id)
        XCTAssertEqual(recents, 0)
        XCTAssertEqual(mutations, 0)
        let requests = await sender.recordedRequests()
        let after = await diaryService.callCount(for: date)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(after, before)
    }

    func testFoodDetailStoreSuccessDeliversDateOnlyOnceWithoutResending() async throws {
        let account = appFlowSession()
        let service = AppFlowFoodDetailService()
        let diaryService = AppFlowDiaryService()
        let coordinator = makeCoordinator(
            sessionService: AppFlowSessionService(restore: { .authenticated(account) }),
            diaryService: diaryService, cookieClearer: AppFlowCookieClearer(),
            foodDetailService: service, searchOwnership: .tca,
            diaryScreenOwnership: .storeBackedScreen
        )
        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        var recents = 0
        var deliveries: [DiaryMutationDelivery] = []
        let (stream, continuation) = AsyncStream.makeStream(of: DiaryMutationDelivery.self)
        defer { continuation.finish() }
        coordinator.installTCASearchHandlers(contextChanged: { _, _, _ in }, recentsInvalidated: { _ in
            recents += 1
        })
        coordinator.installDiaryMutationCallback { delivery in
            deliveries.append(delivery)
            continuation.yield(delivery)
        }
        coordinator.openFoodDetail("food-1", date: yesterday, mealSlot: .lunch)
        let detail = try XCTUnwrap(coordinator.foodDetailViewModel(for: "food-1"))
        await detail.load()
        detail.amountChanged("100")
        detail.unitChanged("g")
        let before = await diaryService.callCount(for: date)
        await detail.submit()
        var iterator = stream.makeAsyncIterator()
        let delivery = await iterator.next()
        XCTAssertEqual(delivery, DiaryMutationDelivery(
            generation: coordinator.session.sessionGeneration, invalidating: yesterday
        ))
        XCTAssertNil(coordinator.handleFoodDetailSuccess(detail), "Duplicate must not schedule delivery")
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(recents, 1)
        let requests = await service.loggedRequests()
        let after = await diaryService.callCount(for: date)
        XCTAssertEqual(requests.count, 1, "Fanout must not resend the frozen journal request")
        XCTAssertEqual(after, before, "Store ownership must not refresh the hidden legacy Diary")
    }

    func testReplacedFoodDetailCapturedSuccessDeliversWithoutNavigatingReplacement() async throws {
        let account = appFlowSession()
        let coordinator = makeCoordinator(
            sessionService: AppFlowSessionService(restore: { .authenticated(account) }),
            diaryService: AppFlowDiaryService(), cookieClearer: AppFlowCookieClearer(),
            diaryScreenOwnership: .storeBackedScreen
        )
        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        let (stream, continuation) = AsyncStream.makeStream(of: DiaryMutationDelivery.self)
        defer { continuation.finish() }
        coordinator.installDiaryMutationCallback { _ = continuation.yield($0) }
        coordinator.openFoodDetail("food-1", date: yesterday, mealSlot: .lunch)
        let old = try XCTUnwrap(coordinator.foodDetailViewModel(for: "food-1"))
        await old.load()
        old.amountChanged("100")
        old.unitChanged("g")
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .dinner)
        let replacement = try XCTUnwrap(coordinator.foodDetailViewModel(for: "food-1"))
        XCTAssertFalse(old === replacement)
        let navigation = coordinator.navigationState
        await old.submit()
        var iterator = stream.makeAsyncIterator()
        let delivery = await iterator.next()
        XCTAssertEqual(delivery?.affectedDates, [yesterday])
        XCTAssertTrue(coordinator.foodDetailViewModel(for: "food-1") === replacement)
        XCTAssertEqual(coordinator.navigationState, navigation)
    }

    func testFoodDetailOldGenerationAndForeignAccountSuccessDoNotFanOut() async throws {
        let first = appFlowSession()
        for second in [first, appFlowSession(id: "identity-b", username: "bob", displayName: "Bob")] {
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(first) }, login: { _, _ in second }
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService, diaryService: AppFlowDiaryService(),
            cookieClearer: AppFlowCookieClearer(), searchOwnership: .tca,
            diaryScreenOwnership: .storeBackedScreen
        )
        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        let oldDetail = try XCTUnwrap(coordinator.foodDetailViewModel(for: "food-1"))
        await oldDetail.load()
        oldDetail.amountChanged("100")
        oldDetail.unitChanged("g")
        let originatingGeneration = coordinator.session.sessionGeneration
        var mutations = 0
        var recents = 0
        coordinator.installDiaryMutationCallback { _ in mutations += 1 }
        coordinator.installTCASearchHandlers(contextChanged: { _, _, _ in }, recentsInvalidated: { _ in
            recents += 1
        })
        let login = coordinator.loginViewModel
        login.username = "bob"
        login.password = "pw"
        await login.submit()
        await awaitLoadedDiary(coordinator)
        XCTAssertGreaterThan(coordinator.session.sessionGeneration, originatingGeneration)
        let expectedNavigation = coordinator.navigationState
        // The real retained callback carries the old generation.
        await oldDetail.submit()
        // The compatibility entry also rejects the foreign account synchronously.
        XCTAssertNil(coordinator.handleFoodDetailSuccess(oldDetail))
        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(recents, 0)
        XCTAssertEqual(coordinator.navigationState, expectedNavigation)
        XCTAssertEqual(coordinator.currentUser?.id, second.identity.id)
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(appFlowWaitTimeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition")
    }

    func testAppShellInstantiates() {
        let shell = AppShell()
        XCTAssertNotNil(shell)
    }

    func testAppShellWindowsShareOneSubmissionStore() {
        func makeWindowCoordinator() -> AppShellCoordinator {
            let session = SessionCoordinator(
                service: AppFlowSessionService(),
                cookieBaseURL: appFlowBaseURL,
                cookieClearer: AppFlowCookieClearer()
            )
            return AppShellCoordinator(
                client: CalCoAPIClient(baseURL: appFlowBaseURL),
                session: session,
                diaryService: AppFlowDiaryService(),
                searchService: AppFlowSearchService(),
                foodDetailService: AppFlowFoodDetailService(),
                todayProvider: { self.date }
            )
        }

        let first = makeWindowCoordinator()
        let second = makeWindowCoordinator()
        XCTAssertTrue(first.logSubmissionStore === second.logSubmissionStore)
        XCTAssertTrue(first.logSubmissionStore === LogSubmissionStore.shared)
    }

    func testFeatureSubmissionNeedsNoProfileBindingAndUsesPlainPOST() async throws {
        let userSession = appFlowSession(hasProfile: false)
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let sender = AppFlowSubmissionSender()
        let submissionService = LogSubmissionService(sender: sender)
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: AppFlowDiaryService(),
            cookieClearer: AppFlowCookieClearer(),
            logSubmissionService: submissionService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        XCTAssertEqual(coordinator.currentUser?.id, "identity-a")
        XCTAssertNil(coordinator.currentUser?.displayName)

        var received: LogSubmissionServiceResult?
        coordinator.submitDraftsForFeature(
            [
                LogSubmissionDraft(
                    item: .product(id: "food-1"),
                    date: date,
                    mealSlot: .lunch,
                    amount: "100",
                    unit: "g",
                    notes: nil,
                    timeZone: "Asia/Kolkata"
                )
            ],
            itemNames: ["Oats"],
            summary: "Oats"
        ) { result in
            received = result
        }
        await waitUntil { received != nil }

        XCTAssertEqual(received, .success([]))
        let requests = await sender.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.requestPath, "/api/logs")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertNil(object["idempotency_key"])
    }

    // MARK: - Compact pane plan

    func testCompactPlanUsesStableDiaryRootForInitialState() {
        let state = NavigationState(date: date)

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .compact),
            .stack(root: .diary, path: [])
        )
    }

    func testCompactPlanAddsOnePathEntryPerPushedPane() {
        var state = NavigationState(date: date)

        state.startLogging(mealSlot: .lunch)
        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .compact),
            .stack(root: .diary, path: [.foodSearch])
        )

        state.pushFoodDetail(foodID: "food-1")
        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .compact),
            .stack(root: .diary, path: [
                .foodSearch,
                .foodDetail(foodID: "food-1"),
            ])
        )

        state.pushFoodLog(foodID: "food-1")
        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .compact),
            .stack(root: .diary, path: [
                .foodSearch,
                .foodDetail(foodID: "food-1"),
                .foodLog(foodID: "food-1"),
            ])
        )
    }

    // MARK: - Expanded pane plan

    func testExpandedPlanUsesDiaryAsFullWidthPrimaryWithNoInspector() {
        let state = NavigationState(date: date)

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(primary: .diary, inspector: nil)
        )
    }

    func testExpandedPlanUsesSearchAsFullWidthPrimaryWithNoEmptyDetail() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .lunch)

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(primary: .foodSearch, inspector: nil)
        )
    }

    func testExpandedPlanShowsSelectedFoodOnlyAsContextualInspector() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .lunch)
        state.pushFoodDetail(foodID: "food-1")

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(
                primary: .foodSearch,
                inspector: .foodDetail(foodID: "food-1")
            )
        )
    }

    func testExpandedPlanReturnsToFullWidthSearchAfterClosingDetail() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .lunch)
        state.pushFoodDetail(foodID: "food-1")

        state.back()

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(primary: .foodSearch, inspector: nil)
        )
    }

    func testExpandedPlanNeverPlacesDiaryAndSearchInTwoColumns() {
        var state = NavigationState(date: date)

        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(primary: .diary, inspector: nil)
        )

        state.startLogging(mealSlot: .lunch)
        XCTAssertEqual(
            AppShellPanePlan.plan(for: state, layout: .expanded),
            .split(primary: .foodSearch, inspector: nil)
        )
    }

    func testSidebarSectionsContainOnlyTopLevelNavigationDestinations() {
        XCTAssertEqual(AppShellPanePlan.sidebarSections, [.diary, .search, .library, .settings])
        XCTAssertEqual(AppShellPanePlan.sidebarSections, AppShellTab.allCases)
    }

    func testPanePlanDoesNotMutateDateOrMealSlotContext() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .lateNightSnack)
        state.pushFoodDetail(foodID: "food-1")

        _ = AppShellPanePlan.plan(for: state, layout: .compact)
        _ = AppShellPanePlan.plan(for: state, layout: .expanded)

        XCTAssertEqual(state.selectedDate, date)
        XCTAssertEqual(state.mealSlot, .lateNightSnack)
    }

    // MARK: - Coordinator layout transitions

    func testShowSearchClosesDetailAndKeepsDateAndMealSlot() {
        let coordinator = AppShellCoordinator()
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)

        coordinator.showSearch()

        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary, .foodSearch])
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .lunch)
    }

    func testShowDiaryClearsPushedPanesAndKeepsDateAndMealSlot() {
        let coordinator = AppShellCoordinator()
        coordinator.startLogging(slot: .dinner, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .dinner)

        coordinator.showDiary()

        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .dinner)
    }

    func testOpeningAnotherFoodReplacesContextualDetail() {
        let coordinator = AppShellCoordinator()
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)

        coordinator.openFoodDetail("food-2", date: date, mealSlot: .lunch)

        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: "food-2")]
        )
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .lunch)
    }

    func testBackFromDetailMovesInspectorPlanBackToSearch() {
        let coordinator = AppShellCoordinator()
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)

        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .expanded),
            .split(
                primary: .foodSearch,
                inspector: .foodDetail(foodID: "food-1")
            )
        )

        coordinator.back()

        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .expanded),
            .split(primary: .foodSearch, inspector: nil)
        )
    }

    // MARK: - Compact back and log completion regressions

    func testCompactBackFromDetailReturnsToSearchThenDiaryWithoutBlankRoot() {
        let coordinator = AppShellCoordinator()
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)

        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [
                .foodSearch,
                .foodDetail(foodID: "food-1"),
            ])
        )

        coordinator.back()
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [.foodSearch])
        )

        coordinator.back()
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [])
        )
    }

    func testLogSuccessDismissesDetailImmediatelyAndKeepsContext() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: AppFlowDiaryService(),
            cookieClearer: AppFlowCookieClearer()
        )
        await coordinator.start()
        await waitForLoadedDiary(coordinator)

        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amount = "100"
        detail.unit = "g"
        detail.mealSlot = .lunch

        await detail.submit()

        XCTAssertEqual(detail.submitState, .succeeded)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [])
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .expanded),
            .split(primary: .diary, inspector: nil)
        )
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .lunch)
    }

    // MARK: - Session ownership

    func testPreSignedInSessionInjectionInstallsFeatureGraphOnInit() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "a-log", mealSlot: .lunch, title: "Alice lunch")]
        ))
        let session = SessionCoordinator(
            service: sessionService,
            cookieBaseURL: appFlowBaseURL,
            cookieClearer: AppFlowCookieClearer()
        )

        await session.restore()
        let user = appFlowUser(from: userSession)
        XCTAssertEqual(session.phase, .signedIn(user))

        let coordinator = AppShellCoordinator(
            client: CalCoAPIClient(baseURL: appFlowBaseURL),
            session: session,
            diaryService: diaryService,
            searchService: AppFlowSearchService(),
            foodDetailService: AppFlowFoodDetailService(),
            todayProvider: { self.date }
        )

        XCTAssertEqual(coordinator.phase, .signedIn(user))
        XCTAssertEqual(coordinator.currentUser, user)
        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertNotNil(coordinator.searchViewModel)
        await waitForLoadedDiary(coordinator)
        XCTAssertEqual(coordinator.diaryViewModel?.logs.map(\.id), ["a-log"])
    }

    func testStaleFoodLogSuccessAfterUserBLoginCannotReachUserBGraph() async {
        let firstSession = appFlowSession()
        let secondSession = appFlowSession(
            id: "identity-b",
            username: "bob",
            displayName: "Bob"
        )
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(firstSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "a-log", mealSlot: .lunch, title: "Alice lunch")]
        ))
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let firstDiary = coordinator.diaryViewModel else {
            return XCTFail("Expected the first user's diary")
        }

        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let staleDetail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await staleDetail.load()
        staleDetail.amount = "100"
        staleDetail.unit = "g"
        staleDetail.mealSlot = .lunch

        await foodDetailService.holdNextLog()
        let staleSubmit = Task { await staleDetail.submit() }
        await foodDetailService.waitForLogStart()
        XCTAssertEqual(staleDetail.submitState, .submitting)

        let secondUser = appFlowUser(from: secondSession)
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "b-log", mealSlot: .lunch, title: "Bob lunch")]
        ))
        sessionService.setLoginHandler { _, _ in secondSession }
        let login = coordinator.loginViewModel
        login.username = "bob"
        login.password = "pw"
        await login.submit()

        XCTAssertEqual(coordinator.phase, .signedIn(secondUser))
        await waitForLoadedDiary(coordinator)
        guard let secondDiary = coordinator.diaryViewModel else {
            return XCTFail("Expected the second user's diary")
        }
        XCTAssertFalse(firstDiary === secondDiary)
        XCTAssertEqual(coordinator.currentUser, secondUser)
        XCTAssertNil(coordinator.foodDetailViewModel(for: "food-1"))
        XCTAssertTrue(firstDiary.logs.isEmpty)

        coordinator.startLogging(slot: .dinner, date: date)
        coordinator.openFoodDetail("food-b", date: date, mealSlot: .dinner)
        let secondUserPaneStack = coordinator.navigationState.paneStack
        XCTAssertNotNil(coordinator.foodDetailViewModel(for: "food-b"))
        let fetchesBeforeStaleSuccess = await diaryService.callCount(for: date)

        await foodDetailService.releaseLog()
        await staleSubmit.value
        XCTAssertEqual(staleDetail.submitState, .succeeded)
        for _ in 0..<20 { await Task.yield() }

        let fetchesAfterStaleSuccess = await diaryService.callCount(for: date)
        XCTAssertEqual(fetchesAfterStaleSuccess, fetchesBeforeStaleSuccess)
        XCTAssertEqual(coordinator.phase, .signedIn(secondUser))
        XCTAssertEqual(coordinator.screen, .main(secondUser))
        XCTAssertEqual(coordinator.currentUser, secondUser)
        XCTAssertTrue(coordinator.diaryViewModel === secondDiary)
        XCTAssertEqual(secondDiary.logs.map(\.id), ["b-log"])
        XCTAssertEqual(coordinator.navigationState.paneStack, secondUserPaneStack)
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .dinner)
        XCTAssertNil(coordinator.foodDetailViewModel(for: "food-1"))
        XCTAssertNotNil(coordinator.foodDetailViewModel(for: "food-b"))
    }

    func testOfflineSignOutClearsFeatureStateAndCookies() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let cookies = AppFlowCookieClearer()
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "a-log", mealSlot: .lunch, title: "Alice lunch")],
            goal: DiaryGoalTargets(calorieTarget: 2_000)
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: cookies
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)

        XCTAssertEqual(coordinator.phase, .signedIn(appFlowUser(from: userSession)))
        XCTAssertEqual(coordinator.currentUser, appFlowUser(from: userSession))
        XCTAssertEqual(coordinator.diaryViewModel?.logs.map(\.id), ["a-log"])

        sessionService.setLogoutHandler {
            throw CalCoAPIError.network("offline")
        }
        let result = await coordinator.signOut()

        XCTAssertEqual(result, .completedWithServerFailure(.networkUnavailable))
        XCTAssertEqual(coordinator.phase, .signedOut(.signedOut))
        XCTAssertEqual(coordinator.screen, .login)
        XCTAssertNil(coordinator.currentUser)
        XCTAssertNil(coordinator.diaryViewModel)
        XCTAssertNil(coordinator.searchViewModel)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(sessionService.logoutCalls, 1)
        XCTAssertEqual(cookies.calls, [appFlowBaseURL])
    }

    func testDelayedUnauthorizedFromPreviousUserCannotInvalidateNewSession() async {
        let firstSession = appFlowSession()
        let secondSession = appFlowSession(
            id: "identity-b",
            username: "bob",
            displayName: "Bob"
        )
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(firstSession) }
        )
        let cookies = AppFlowCookieClearer()
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "a-log", mealSlot: .lunch, title: "Alice lunch")]
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: cookies
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let firstDiary = coordinator.diaryViewModel else {
            return XCTFail("Expected the first user's diary")
        }

        sessionService.setLoginHandler { _, _ in secondSession }
        let login = coordinator.loginViewModel
        login.username = "bob"
        login.password = "pw"
        await login.submit()

        let secondUser = appFlowUser(from: secondSession)
        XCTAssertEqual(coordinator.phase, .signedIn(secondUser))
        await waitForLoadedDiary(coordinator)
        guard let secondDiary = coordinator.diaryViewModel else {
            return XCTFail("Expected the second user's diary")
        }
        XCTAssertFalse(
            firstDiary === secondDiary,
            "A new user must get a new diary view model"
        )

        let generationBeforeStale401 = coordinator.session.sessionGeneration
        let cookiesBeforeStale401 = cookies.count
        await diaryService.setError(.unauthorized)

        await firstDiary.refresh()

        XCTAssertEqual(
            coordinator.session.sessionGeneration,
            generationBeforeStale401,
            "A stale 401 must not advance the live session generation"
        )
        XCTAssertEqual(coordinator.phase, .signedIn(secondUser))
        XCTAssertEqual(coordinator.screen, .main(secondUser))
        XCTAssertTrue(coordinator.diaryViewModel === secondDiary)
        XCTAssertEqual(coordinator.currentUser, secondUser)
        XCTAssertEqual(cookies.count, cookiesBeforeStale401)
    }

    func testCurrentDiary401SignsOutAndClearsCookies() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let cookies = AppFlowCookieClearer()
        let diaryService = AppFlowDiaryService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: cookies
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        await diaryService.setError(.unauthorized)
        await diary.refresh()

        XCTAssertEqual(coordinator.phase, .signedOut(.expired))
        XCTAssertEqual(coordinator.screen, .login)
        XCTAssertNil(coordinator.currentUser)
        XCTAssertNil(coordinator.diaryViewModel)
        XCTAssertNil(coordinator.searchViewModel)
        XCTAssertEqual(cookies.calls, [appFlowBaseURL])
    }

    func testAdminSignInIsRejectedThroughSessionCoordinator() async {
        let adminSession = appFlowSession(
            id: "identity-admin",
            username: "root",
            role: .admin,
            displayName: "Root"
        )
        let sessionService = AppFlowSessionService(
            login: { _, _ in adminSession }
        )
        let cookies = AppFlowCookieClearer()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: AppFlowDiaryService(),
            cookieClearer: cookies
        )
        let admin = appFlowUser(from: adminSession)

        let login = coordinator.loginViewModel
        login.username = "root"
        login.password = "pw"
        await login.submit()

        XCTAssertEqual(login.unsupportedAdmin, admin)
        XCTAssertEqual(coordinator.session.phase, .unsupportedAccount(admin))
        XCTAssertEqual(coordinator.screen, .login)
        XCTAssertNil(coordinator.currentUser)
        XCTAssertNil(coordinator.diaryViewModel)
        XCTAssertNil(coordinator.searchViewModel)
        XCTAssertEqual(cookies.count, 2, "Pre-login cleanup plus rejected-role cleanup")
    }

    func testRestoreOfflineIsRetryableAndNotSignedOut() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { throw CalCoAPIError.network("offline") }
        )
        let cookies = AppFlowCookieClearer()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: AppFlowDiaryService(),
            cookieClearer: cookies
        )

        await coordinator.start()

        XCTAssertEqual(
            coordinator.session.phase,
            .restoreFailed(.networkUnavailable)
        )
        XCTAssertEqual(
            coordinator.screen,
            .restoreFailed(.networkUnavailable)
        )
        XCTAssertNil(coordinator.currentUser)
        XCTAssertNil(coordinator.diaryViewModel)
        XCTAssertEqual(
            cookies.count,
            0,
            "A transport failure must not clear a possibly valid cookie"
        )

        sessionService.setRestoreHandler { .authenticated(userSession) }
        await coordinator.retryRestore()

        XCTAssertEqual(coordinator.phase, .signedIn(appFlowUser(from: userSession)))
        await waitForLoadedDiary(coordinator)
        XCTAssertNotNil(coordinator.diaryViewModel)
        XCTAssertEqual(cookies.count, 0)
    }

    func testLoginTransportFailureIsRetryable() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            login: { _, _ in throw CalCoAPIError.network("offline") }
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: AppFlowDiaryService(),
            cookieClearer: AppFlowCookieClearer()
        )
        let login = coordinator.loginViewModel
        login.username = "alice"
        login.password = "pw"

        await login.submit()

        XCTAssertEqual(
            login.phase,
            .failed(.authentication(.networkUnavailable))
        )
        XCTAssertEqual(coordinator.screen, .login)
        XCTAssertNil(coordinator.diaryViewModel)

        sessionService.setLoginHandler { _, _ in userSession }
        await login.submit()

        XCTAssertEqual(login.phase, .editing)
        XCTAssertEqual(coordinator.phase, .signedIn(appFlowUser(from: userSession)))
        await waitForLoadedDiary(coordinator)
        XCTAssertNotNil(coordinator.diaryViewModel)
    }

    func testAppShellScreenFailsClosedWithoutConfiguration() {
        let user = appFlowUser(from: appFlowSession())

        XCTAssertEqual(
            AppShellScreen(
                phase: .signedIn(user),
                configurationError: "No API URL"
            ),
            .configurationError("No API URL")
        )
    }

    // MARK: - Log success and diary content lifecycle

    func testLogSuccessImmediatelyReturnsToLoadedDiaryAndRefreshesContent() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch")],
            goal: DiaryGoalTargets(calorieTarget: 2_000)
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        XCTAssertEqual(diary.logs.map(\.id), ["old-log"])

        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        XCTAssertEqual(detail.loadState, .loaded)
        detail.amount = "100"
        detail.unit = "g"
        detail.mealSlot = .lunch

        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch"),
                DiaryLog(id: "new-log", mealSlot: .lunch, title: "New lunch"),
            ],
            goal: DiaryGoalTargets(calorieTarget: 2_000)
        ))

        await detail.submit()
        XCTAssertEqual(detail.submitState, .succeeded)

        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [])
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .expanded),
            .split(primary: .diary, inspector: nil)
        )
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .lunch)
        XCTAssertTrue(
            coordinator.diaryViewModel === diary,
            "Log success must keep the same diary view model"
        )
        XCTAssertEqual(diary.state, .loaded(.idle))
        XCTAssertFalse(
            diary.logs.isEmpty,
            "The diary must show loaded/refreshing content, never a blank root"
        )

        await waitUntil {
            diary.logs.map(\.id).sorted() == ["new-log", "old-log"]
        }
        XCTAssertEqual(diary.logs.map(\.id).sorted(), ["new-log", "old-log"])
        XCTAssertEqual(diary.state, .loaded(.idle))
        XCTAssertNil(diary.errorMessage)
    }

    func testBackFromDetailReturnsToSearchThenLoadedDiary() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch")]
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [
                .foodSearch,
                .foodDetail(foodID: "food-1"),
            ])
        )

        coordinator.back()
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [.foodSearch])
        )
        XCTAssertEqual(diary.state, .loaded(.idle))
        XCTAssertEqual(diary.logs.map(\.id), ["old-log"])

        coordinator.back()
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [])
        )
        XCTAssertEqual(diary.state, .loaded(.idle))
        XCTAssertEqual(diary.logs.map(\.id), ["old-log"])
        XCTAssertNil(diary.errorMessage)
    }

    // MARK: - Single authoritative event paths

    func testSignInInstallsExactlyOneFeatureGraph() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)

        let user = appFlowUser(from: userSession)
        XCTAssertEqual(coordinator.currentUser, user)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let initialFetches = await diaryService.callCount(for: date)
        XCTAssertEqual(initialFetches, 1)

        coordinator.authFeatureDidSignIn(user)
        await Task.yield()

        XCTAssertTrue(coordinator.diaryViewModel === diary)
        let fetchesAfterCallback = await diaryService.callCount(for: date)
        XCTAssertEqual(fetchesAfterCallback, 1)
    }

    func testSuccessfulPostCausesExactlyOneNavigationAndOneDiaryRefresh() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch")]
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        let fetchesBeforePost = await diaryService.callCount(for: date)

        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amount = "100"
        detail.unit = "g"
        detail.mealSlot = .lunch

        var navigationChanges = 0
        let cancellable = coordinator.$navigationState
            .dropFirst()
            .sink { _ in navigationChanges += 1 }

        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch"),
                DiaryLog(id: "new-log", mealSlot: .lunch, title: "New lunch"),
            ]
        ))

        await detail.submit()
        XCTAssertEqual(detail.submitState, .succeeded)
        XCTAssertEqual(navigationChanges, 1)

        await diaryService.waitForCallCount(date, atLeast: fetchesBeforePost + 1)
        for _ in 0..<20 { await Task.yield() }

        let fetchesAfterPost = await diaryService.callCount(for: date)
        XCTAssertEqual(navigationChanges, 1)
        XCTAssertEqual(fetchesAfterPost, fetchesBeforePost + 1)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(coordinator.diaryViewModel?.logs.map(\.id).sorted(), ["new-log", "old-log"])
        withExtendedLifetime(cancellable) {}
    }

    func testSuccessAfterBackRefreshesOriginDiaryWithoutLeavingSearch() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch")]
        ))
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amount = "100"
        detail.unit = "g"
        detail.mealSlot = .lunch
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch"),
                DiaryLog(id: "new-log", mealSlot: .lunch, title: "New lunch"),
            ]
        ))
        let fetchesBeforePost = await diaryService.callCount(for: date)

        await foodDetailService.holdNextLog()
        let submit = Task { await detail.submit() }
        await foodDetailService.waitForLogStart()
        XCTAssertEqual(detail.submitState, .submitting)

        coordinator.back()
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary, .foodSearch])

        await foodDetailService.releaseLog()
        await submit.value
        XCTAssertEqual(detail.submitState, .succeeded)

        await diaryService.waitForCallCount(date, atLeast: fetchesBeforePost + 1)
        for _ in 0..<20 { await Task.yield() }

        let fetchesAfterPost = await diaryService.callCount(for: date)
        XCTAssertEqual(
            fetchesAfterPost,
            fetchesBeforePost + 1,
            "A background success must refresh the origin date exactly once"
        )
        XCTAssertTrue(coordinator.diaryViewModel === diary)
        XCTAssertEqual(diary.logs.map(\.id).sorted(), ["new-log", "old-log"])
        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch],
            "A background success must not pull the user back to the diary"
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [.foodSearch])
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .expanded),
            .split(primary: .foodSearch, inspector: nil)
        )
        XCTAssertEqual(coordinator.searchViewModel?.originDate, date)
        XCTAssertEqual(coordinator.searchViewModel?.originMealSlot, .lunch)
    }

    func testLateSuccessAfterBackPersistsOnceAndRefreshesDiaryWithoutDuplicate() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch")]
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-appflow-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService,
            logSubmissionStore: store
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amountChanged("100")
        detail.unitChanged("g")
        detail.mealSlotChanged(.lunch)

        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch"),
                DiaryLog(id: "new-log", mealSlot: .lunch, title: "New lunch"),
            ]
        ))
        let fetchesBeforePost = await diaryService.callCount(for: date)

        await foodDetailService.holdNextLog()
        let submit = Task { await detail.submit() }
        await foodDetailService.waitForLogStart()
        coordinator.back()
        await foodDetailService.releaseLog()
        await submit.value

        await diaryService.waitForCallCount(date, atLeast: fetchesBeforePost + 1)
        for _ in 0..<20 { await Task.yield() }
        let fetchesAfterSuccess = await diaryService.callCount(for: date)
        XCTAssertEqual(fetchesAfterSuccess, fetchesBeforePost + 1)
        XCTAssertEqual(coordinator.diaryViewModel?.logs.map(\.id).sorted(), ["new-log", "old-log"])
        XCTAssertTrue(store.attentionEntries(accountID: userSession.identity.id).isEmpty)
        XCTAssertEqual(
            store.entries(accountID: userSession.identity.id).filter {
                $0.state == .succeeded
            }.count,
            1
        )

        coordinator.handleFoodDetailSuccess(detail)
        for _ in 0..<20 { await Task.yield() }
        let fetchesAfterDuplicateCallback = await diaryService.callCount(for: date)
        XCTAssertEqual(
            fetchesAfterDuplicateCallback,
            fetchesAfterSuccess,
            "A repeated success callback must not refresh or notify twice"
        )
    }

    func testRelaunchSurfacePendingSubmissionAndReviewOpensDetail() async throws {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-relaunch-banner-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let prepared = try LogCreateRequestBuilder.prepare(
            foodID: "food-1",
            foodName: "Test Food",
            date: date,
            mealSlot: .lunch,
            amount: "150",
            unit: "g",
            notes: nil,
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: appFlowBaseURL,
            idempotencyKey: "b6b1f5a4-3c2e-4a7e-9f6d-1a2b3c4d5e6f"
        )
        let entry = try store.reserve(
            accountID: userSession.identity.id,
            foodName: "Test Food",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body
        )

        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            logSubmissionStore: store
        )
        await coordinator.start()
        await waitForLoadedDiary(coordinator)

        XCTAssertEqual(coordinator.pendingSubmission?.id, entry.id)
        XCTAssertEqual(coordinator.pendingSubmissions.map(\.id), [entry.id])
        coordinator.reviewPendingSubmission()
        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: "food-1")]
        )
    }

    func testReopeningSameContextWhileInFlightKeepsLiveViewModel() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amount = "100"
        detail.unit = "g"

        await foodDetailService.holdNextLog()
        let submit = Task { await detail.submit() }
        await foodDetailService.waitForLogStart()
        XCTAssertEqual(detail.submitState, .submitting)

        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)

        XCTAssertTrue(
            coordinator.foodDetailViewModel(for: "food-1") === detail,
            "Re-opening the same in-flight context must not replace its view model"
        )
        XCTAssertEqual(detail.submitState, .submitting)

        await foodDetailService.releaseLog()
        await submit.value
        XCTAssertEqual(detail.submitState, .succeeded)
    }

    func testLateSuccessFromReplacedDetailDoesNotCloseEditsAndStillRefreshesDiary() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch")]
        ))
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let oldDetail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected the first detail view model")
        }
        await oldDetail.load()
        oldDetail.amount = "100"
        oldDetail.unit = "g"

        await foodDetailService.holdNextLog()
        let oldSubmit = Task { await oldDetail.submit() }
        await foodDetailService.waitForLogStart()

        // A different meal slot is a different logical context, so this
        // intentionally replaces the live detail with its own draft.
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .dinner)
        guard let replacement = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a replacement detail view model")
        }
        XCTAssertFalse(replacement === oldDetail)
        await replacement.load()
        replacement.amount = "7"
        replacement.unit = "g"
        replacement.mealSlot = .dinner

        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .lunch, title: "Old lunch"),
                DiaryLog(id: "new-log", mealSlot: .lunch, title: "New lunch"),
            ]
        ))
        let fetchesBeforeRelease = await diaryService.callCount(for: date)

        await foodDetailService.releaseLog()
        await oldSubmit.value
        XCTAssertEqual(oldDetail.submitState, .succeeded)
        await diaryService.waitForCallCount(date, atLeast: fetchesBeforeRelease + 1)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(
            coordinator.foodDetailViewModel(for: "food-1") === replacement,
            "A late callback must not replace the current detail"
        )
        XCTAssertEqual(replacement.amount, "7", "The replacement's edits must survive")
        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: "food-1")],
            "A late callback must not close the replacement detail"
        )
        XCTAssertEqual(coordinator.navigationState.mealSlot, .dinner)
        let fetchesAfterRelease = await diaryService.callCount(for: date)
        XCTAssertEqual(
            fetchesAfterRelease,
            fetchesBeforeRelease + 1,
            "The old success must still refresh the origin diary once"
        )
    }

    func testBannerCountsAllRecoveryEntriesButNotLiveInFlightAndCanDismiss() async throws {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-banner-multi-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let first = try seedSubmission(
            in: store,
            accountID: userSession.identity.id,
            foodID: "food-1",
            amount: "10"
        )
        let second = try seedSubmission(
            in: store,
            accountID: userSession.identity.id,
            foodID: "food-2",
            amount: "20"
        )
        let live = try seedSubmission(
            in: store,
            accountID: userSession.identity.id,
            foodID: "food-3",
            amount: "30",
            state: .inFlight
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            logSubmissionStore: store
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)

        XCTAssertEqual(
            Set(coordinator.pendingSubmissions.map(\.id)),
            [first.id, second.id]
        )
        XCTAssertFalse(
            coordinator.pendingSubmissions.contains { $0.id == live.id },
            "A live in-flight attempt must not be presented as stale attention"
        )

        coordinator.reviewPendingSubmission(second)
        XCTAssertEqual(
            coordinator.navigationState.paneStack.last,
            .foodDetail(foodID: "food-2")
        )

        coordinator.dismissPendingSubmissionBanner()
        XCTAssertNil(coordinator.pendingSubmission)
        XCTAssertTrue(coordinator.pendingSubmissions.isEmpty)

        let third = try seedSubmission(
            in: store,
            accountID: userSession.identity.id,
            foodID: "food-4",
            amount: "40"
        )
        await waitUntil {
            coordinator.pendingSubmission?.id == third.id
        }
        XCTAssertEqual(
            coordinator.pendingSubmissions.map(\.id),
            [third.id],
            "Dismissal applies only to entries the user already saw"
        )
    }

    func testConflictedBannerEntryIsResolvedOnlyByExplicitDiscard() async throws {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-banner-conflict-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let conflicted = try seedSubmission(
            in: store,
            accountID: userSession.identity.id,
            foodID: "food-1",
            amount: "10",
            state: .conflicted
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            logSubmissionStore: store
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        XCTAssertEqual(coordinator.pendingSubmission?.state, .conflicted)
        XCTAssertEqual(
            store.attentionEntries(accountID: userSession.identity.id).map(\.id),
            [conflicted.id],
            "Opening the banner must not resolve the conflict implicitly"
        )

        XCTAssertTrue(coordinator.discardPendingSubmission(conflicted))
        XCTAssertTrue(store.attentionEntries(accountID: userSession.identity.id).isEmpty)
    }

    func testDeletingFoundAmbiguousLogInvalidatesRetryAndCannotResurrect() async throws {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        let foodDetailService = AppFlowFoodDetailService()
        await foodDetailService.setCreateError(.uncertain("timeout"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-delete-pending-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService,
            logSubmissionStore: store
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amount = "150"
        detail.unit = "g"
        detail.mealSlot = .lunch
        await detail.submit()

        XCTAssertEqual(detail.submitState, .uncertain("timeout"))
        let pending = try XCTUnwrap(
            store.attentionEntries(accountID: userSession.identity.id).first
        )
        XCTAssertEqual(pending.state, .uncertain)

        // The user finds the ambiguous log in the diary and deletes it.
        let foundLog = DiaryLog(
            id: "created-log",
            mealSlot: .lunch,
            title: "Test Food",
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            itemReference: ItemReference(itemType: .product, id: "food-1")
        )
        await diaryService.setDay(DiaryDay(date: date, logs: [foundLog]))
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        await diary.refresh()
        XCTAssertEqual(diary.logs.map(\.id), ["created-log"])

        coordinator.openLogEditor(logID: "created-log", date: date)
        guard let editor = coordinator.logEditorViewModel(for: "created-log") else {
            return XCTFail("Expected a log editor")
        }
        XCTAssertEqual(editor.productID, "food-1")
        XCTAssertEqual(
            editor.deleteConfirmationMessage,
            String(localized: "diary.editor.delete.confirmWithPending"),
            "Deleting a found ambiguous log must warn before disabling retry"
        )
        await editor.delete()
        XCTAssertEqual(editor.state, .deleted)

        let invalidated = try XCTUnwrap(
            store.entry(id: pending.id, accountID: userSession.identity.id)
        )
        XCTAssertEqual(invalidated.state, .invalidated)
        XCTAssertNil(invalidated.body)
        XCTAssertEqual(
            invalidated.lastMessage,
            String(localized: "foodDetail.pending.invalidated")
        )
        XCTAssertTrue(
            store.attentionEntries(accountID: userSession.identity.id).isEmpty,
            "A deleted log must not leave a retry banner"
        )
        XCTAssertNil(coordinator.pendingSubmission)
        XCTAssertTrue(detail.visiblePendingSubmissions.isEmpty)

        await waitUntil { diary.mutationNotice?.kind == .deleted }
        XCTAssertEqual(diary.mutationNotice?.blockedPendingCount, 1)

        // Even a stale in-memory retry reference must not send the old key.
        await foodDetailService.setCreateError(nil)
        await detail.retryPending(pending)
        let calls = await foodDetailService.loggedRequests()
        XCTAssertEqual(
            calls.count,
            1,
            "Retry after deleting the found log must not send the idempotency key again"
        )
        XCTAssertEqual(
            detail.submitErrorMessage,
            String(localized: "foodDetail.pending.invalidated")
        )
    }

    func testHistoricalDiaryDateDrivesSearchDetailAndLogDateAndSlot() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: yesterday,
            logs: [
                DiaryLog(id: "yesterday-log", mealSlot: .breakfast, title: "Yesterday breakfast"),
            ]
        ))
        let searchService = AppFlowSearchService(results: [
            FoodSearchResult(id: "food-1", name: "Test Food"),
        ])
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            searchService: searchService,
            foodDetailService: foodDetailService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        await diary.previousDay()
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])

        coordinator.showSearch()
        XCTAssertEqual(coordinator.searchViewModel?.originDate, yesterday)
        coordinator.showDiary()

        diary.addFood(for: .breakfast)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .breakfast)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary, .foodSearch])
        XCTAssertEqual(coordinator.searchViewModel?.originDate, yesterday)
        XCTAssertEqual(coordinator.searchViewModel?.originMealSlot, .breakfast)

        coordinator.searchViewModel?.search("test")
        await waitUntil {
            coordinator.searchViewModel?.results.first?.id == "food-1"
        }
        guard let result = coordinator.searchViewModel?.results.first else {
            return XCTFail("Expected a search result")
        }
        coordinator.searchViewModel?.selectResult(result)

        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: "food-1")]
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .compact),
            .stack(root: .diary, path: [
                .foodSearch,
                .foodDetail(foodID: "food-1"),
            ])
        )
        XCTAssertEqual(
            AppShellPanePlan.plan(for: coordinator.navigationState, layout: .expanded),
            .split(
                primary: .foodSearch,
                inspector: .foodDetail(foodID: "food-1")
            )
        )
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        XCTAssertEqual(detail.originDate, yesterday)
        XCTAssertEqual(detail.originMealSlot, .breakfast)

        await detail.load()
        detail.amount = "100"
        detail.unit = "g"
        detail.mealSlot = .lunch
        await detail.submit()

        XCTAssertEqual(detail.submitState, .succeeded)
        let requests = await foodDetailService.loggedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.date, yesterday)
        XCTAssertEqual(requests.first?.mealSlot, .lunch)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary])
        XCTAssertEqual(coordinator.navigationState.mealSlot, .lunch)
    }

    func testLateSuccessWhileViewingAnotherDateKeepsCurrentDiaryUntilRevisit() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .breakfast, title: "Old breakfast"),
            ]
        ))
        await diaryService.setDay(DiaryDay(
            date: yesterday,
            logs: [
                DiaryLog(id: "yesterday-log", mealSlot: .lunch, title: "Yesterday lunch"),
            ]
        ))
        let foodDetailService = AppFlowFoodDetailService()
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            foodDetailService: foodDetailService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        coordinator.startLogging(slot: .breakfast, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .breakfast)
        guard let detail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }
        await detail.load()
        detail.amount = "100"
        detail.unit = "g"
        detail.mealSlot = .lunch

        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [
                DiaryLog(id: "old-log", mealSlot: .breakfast, title: "Old breakfast"),
                DiaryLog(id: "new-log", mealSlot: .lunch, title: "New lunch"),
            ]
        ))

        await foodDetailService.holdNextLog()
        let submit = Task { await detail.submit() }
        await foodDetailService.waitForLogStart()
        XCTAssertEqual(detail.submitState, .submitting)

        coordinator.back()
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary, .foodSearch])

        await diary.selectDate(yesterday)
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary, .foodSearch])
        XCTAssertEqual(diary.logs.map(\.id), ["yesterday-log"])

        let originFetchesBeforeRelease = await diaryService.callCount(for: date)
        let currentFetchesBeforeRelease = await diaryService.callCount(for: yesterday)

        await foodDetailService.releaseLog()
        await submit.value
        XCTAssertEqual(detail.submitState, .succeeded)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(diary.logs.map(\.id), ["yesterday-log"])
        XCTAssertEqual(diary.state, .loaded(.idle))
        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch]
        )
        let originFetchesAfterRelease = await diaryService.callCount(for: date)
        let currentFetchesAfterRelease = await diaryService.callCount(for: yesterday)
        XCTAssertEqual(
            originFetchesAfterRelease,
            originFetchesBeforeRelease,
            "A background success must not refetch another day's origin"
        )
        XCTAssertEqual(
            currentFetchesAfterRelease,
            currentFetchesBeforeRelease,
            "A background success must not fetch the currently viewed day"
        )

        await diary.selectDate(date)
        XCTAssertEqual(diary.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(diary.logs.map(\.id).sorted(), ["new-log", "old-log"])
        let originFetchesAfterRevisit = await diaryService.callCount(for: date)
        XCTAssertEqual(originFetchesAfterRevisit, originFetchesBeforeRelease + 1)
    }

    func testStaleFoodDetailSuccessCallbackIsIgnored() async {
        let firstSession = appFlowSession()
        let secondSession = appFlowSession(
            id: "identity-b",
            username: "bob",
            displayName: "Bob"
        )
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(firstSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [DiaryLog(id: "a-log", mealSlot: .lunch, title: "Alice lunch")]
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.startLogging(slot: .lunch, date: date)
        coordinator.openFoodDetail("food-1", date: date, mealSlot: .lunch)
        guard let staleDetail = coordinator.foodDetailViewModel(for: "food-1") else {
            return XCTFail("Expected a food detail view model")
        }

        sessionService.setLoginHandler { _, _ in secondSession }
        let login = coordinator.loginViewModel
        login.username = "bob"
        login.password = "pw"
        await login.submit()

        let secondUser = appFlowUser(from: secondSession)
        XCTAssertEqual(coordinator.phase, .signedIn(secondUser))
        await waitForLoadedDiary(coordinator)
        guard let secondDiary = coordinator.diaryViewModel else {
            return XCTFail("Expected the second user's diary")
        }
        let fetchesAfterLogin = await diaryService.callCount(for: date)

        coordinator.startLogging(slot: .dinner, date: date)
        coordinator.openFoodDetail("food-b", date: date, mealSlot: .dinner)
        let expectedStack = coordinator.navigationState.paneStack

        coordinator.handleFoodDetailSuccess(staleDetail)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(coordinator.phase, .signedIn(secondUser))
        XCTAssertTrue(coordinator.diaryViewModel === secondDiary)
        XCTAssertEqual(coordinator.navigationState.paneStack, expectedStack)
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .dinner)
        let fetchesAfterStaleCallback = await diaryService.callCount(for: date)
        XCTAssertEqual(fetchesAfterStaleCallback, fetchesAfterLogin)
        XCTAssertNil(coordinator.foodDetailViewModel(for: "food-1"))
    }

    func testInjectedFixedTodayProviderUsesFixedDateAndSelectedPreviousDay() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        await diaryService.setDay(DiaryDay(date: yesterday))

        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            todayProvider: { self.date }
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        XCTAssertEqual(diary.today, date)
        XCTAssertEqual(diary.selectedDate, date)
        XCTAssertEqual(coordinator.navigationState.selectedDate, date)

        await diary.previousDay()
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
    }

    func testSettingsPreserveSelectedDateAndKeepDisabledSlotLogs() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            logs: [],
            goal: DiaryGoalTargets(calorieTarget: 2_140),
            prefs: DiaryPrefs(enabledSlots: [.breakfast, .lunch])
        ))
        await diaryService.setDay(DiaryDay(
            date: yesterday,
            logs: [
                DiaryLog(id: "breakfast-log", mealSlot: .breakfast, title: "Oats"),
                DiaryLog(id: "lunch-log", mealSlot: .lunch, title: "Soup"),
            ],
            goal: DiaryGoalTargets(calorieTarget: 2_100),
            prefs: DiaryPrefs(enabledSlots: [.breakfast, .lunch])
        ))
        let settingsService = AppFlowSettingsService(
            goal: GoalSnapshot(
                requestedDate: date,
                effectiveFrom: nil,
                source: .default,
                targets: GoalTargets(
                    calorieTarget: 2_100,
                    proteinTargetG: 150,
                    carbsTargetG: 240,
                    fatTargetG: 60
                )
            ),
            preferences: DiaryPreferences(enabledSlots: [.breakfast, .lunch])
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            settingsService: settingsService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        await diary.selectDate(yesterday)
        XCTAssertEqual(diary.selectedDate, yesterday)

        coordinator.showSettings()
        await waitForSettingsLoaded(coordinator)
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        XCTAssertEqual(settings.accountID, userSession.identity.id)
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        var contextState = coordinator.navigationState
        contextState.setMealSlot(.breakfast)
        coordinator.navigationState = contextState
        coordinator.searchViewModel?.updateContext(date: yesterday, mealSlot: .breakfast)
        let goalDates = settingsService.goalRequestDates()
        XCTAssertEqual(goalDates, [date], "Settings always load the device-local today goal")

        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()

        XCTAssertEqual(diary.enabledSlots, [.lunch])
        XCTAssertNil(coordinator.navigationState.mealSlot)
        XCTAssertNil(coordinator.searchViewModel?.originMealSlot)
        XCTAssertEqual(coordinator.searchViewModel?.originDate, yesterday)
        XCTAssertEqual(diary.logs.map(\.id).sorted(), ["breakfast-log", "lunch-log"])
        XCTAssertTrue(diary.groupedSections.contains {
            $0.slot == .breakfast && !$0.logs.isEmpty
        })
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(settingsService.preferenceSaveRequests().first?.enabledMealSlots, [.lunch])

        coordinator.dismissSettings()
        XCTAssertNil(coordinator.settingsViewModel)
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
    }

    func testSettingsGoalSaveAppliesTodayButNotHistoricalDiaryGoal() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        let historicalGoal = DiaryGoalTargets(calorieTarget: 2_100)
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: DiaryGoalTargets(calorieTarget: 2_140),
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        await diaryService.setDay(DiaryDay(
            date: yesterday,
            goal: historicalGoal,
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        let settingsService = AppFlowSettingsService(
            goal: GoalSnapshot(
                requestedDate: date,
                effectiveFrom: nil,
                source: .default,
                targets: GoalTargets(
                    calorieTarget: 2_140,
                    proteinTargetG: 160,
                    carbsTargetG: 240,
                    fatTargetG: 60
                )
            ),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            settingsService: settingsService
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }

        coordinator.showSettings()
        await waitForSettingsLoaded(coordinator)
        guard let todaySettings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        todaySettings.calorieTarget = "2150"
        todaySettings.proteinTargetG = "170"
        todaySettings.carbsTargetG = "210"
        todaySettings.fatTargetG = "70"
        await todaySettings.saveGoals()

        XCTAssertEqual(diary.goal.calorieTarget, 2_150)
        XCTAssertEqual(diary.selectedDate, date)
        coordinator.dismissSettings()

        await diary.selectDate(yesterday)
        XCTAssertEqual(diary.goal, historicalGoal)
        coordinator.showSettings()
        await waitForSettingsLoaded(coordinator)
        guard let historicalSettings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        historicalSettings.calorieTarget = "2290"
        historicalSettings.proteinTargetG = "160"
        historicalSettings.carbsTargetG = "255"
        historicalSettings.fatTargetG = "70"
        await historicalSettings.saveGoals()

        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(diary.goal, historicalGoal)
        XCTAssertEqual(settingsService.goalSaveRequests().count, 2)
    }

    func testSupersededSettingsViewModelCannotApplyLateSaveCallback() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        let baselineGoal = DiaryGoalTargets(calorieTarget: 2_100)
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: baselineGoal,
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.showSettings()
        await waitForSettingsLoaded(coordinator)
        guard let oldSettings = coordinator.settingsViewModel else {
            return XCTFail("Expected the first settings view model")
        }
        coordinator.dismissSettings()
        XCTAssertNil(coordinator.settingsViewModel)

        coordinator.showSettings()
        await waitForSettingsLoaded(coordinator)
        guard let newSettings = coordinator.settingsViewModel else {
            return XCTFail("Expected the replacement settings view model")
        }
        XCTAssertFalse(oldSettings.id == newSettings.id)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let before = diary.goal

        oldSettings.onGoalSaved?(
            GoalSnapshot(
                requestedDate: date,
                effectiveFrom: date,
                source: .saved,
                targets: GoalTargets(
                    calorieTarget: 2_300,
                    proteinTargetG: 200,
                    carbsTargetG: 225,
                    fatTargetG: 50
                )
            )
        )

        XCTAssertEqual(diary.goal, before)
    }

    func testSettingsViewModelIsClearedOnSignOut() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(
            restore: { .authenticated(userSession) }
        )
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(date: date))
        let coordinator = makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer()
        )

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        coordinator.showSettings()
        await waitForSettingsLoaded(coordinator)
        XCTAssertNotNil(coordinator.settingsViewModel)

        await coordinator.signOut()

        XCTAssertNil(coordinator.settingsViewModel)
    }

    // MARK: - Real SettingsVM.saveGoals writeback (server snapshot authoritative)

    private func goalWritebackCoordinator(
        sessionService: AppFlowSessionService,
        diaryService: AppFlowDiaryService,
        settingsService: AppFlowGoalSettingsService,
        ownership: DiaryScreenOwnership
    ) -> AppShellCoordinator {
        makeCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            cookieClearer: AppFlowCookieClearer(),
            settingsService: settingsService,
            diaryScreenOwnership: ownership
        )
    }

    private func defaultGoalSnapshot() -> GoalSnapshot {
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

    /// The draft satisfies the exact formula (170*4 + 210*4 + 70*9 = 2150).
    private func typeDifferentDraft(into settings: DiarySettingsViewModel) async {
        // Let the real load settle before typing; otherwise applyLoadedGoal
        // would overwrite the draft after it was entered.
        await awaitGoalSettingsLoaded(settings)
        settings.calorieTarget = "2150"
        settings.proteinTargetG = "170"
        settings.carbsTargetG = "210"
        settings.fatTargetG = "70"
    }

    func testStoreBackedGoalSaveMapsServerSnapshotAndDeliversCallbackOnce() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        let loadedGoal = DiaryGoalTargets(
            calorieTarget: 2_000, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
        )
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: loadedGoal,
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        // The server response differs from the typed draft on purpose: only the
        // mapped server snapshot may reach the store-backed owner.
        let authoritative = GoalSnapshot(
            requestedDate: date,
            effectiveFrom: date,
            source: .saved,
            targets: GoalTargets(
                calorieTarget: 2_230, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
            )
        )
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: [.lunch]),
            authoritativeSave: authoritative
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = GoalCallbackBox()
        coordinator.installSettingsGoalCallback { generation, targets, savedDate in
            callback.record(generation, targets, savedDate)
        }

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        let generation = coordinator.session.sessionGeneration
        let baselineFetches = await diaryService.callCount(for: date)

        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await typeDifferentDraft(into: settings)
        await settings.saveGoals()

        XCTAssertEqual(callback.calls.count, 1, "Exactly one store-backed handoff")
        guard let call = callback.calls.first else { return }
        XCTAssertEqual(call.generation, generation)
        XCTAssertEqual(call.date, date)
        XCTAssertEqual(call.targets, CalCoStoreMapping.diaryGoal(from: authoritative))
        XCTAssertEqual(call.targets.calorieTarget, 2_230, "The server snapshot must win over the draft")
        // No legacy apply and no extra authoritative read on this path.
        XCTAssertEqual(coordinator.diaryViewModel?.goal, loadedGoal)
        let requests = await settingsService.requests()
        XCTAssertEqual(requests.count, 1)
        let fetchesAfterSave = await diaryService.callCount(for: date)
        XCTAssertEqual(
            fetchesAfterSave, baselineFetches,
            "The settings save must not issue an additional diary fetch"
        )
    }

    func testLegacyGoalSaveAppliesToLegacyDiaryWithoutStoreCallback() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        let loadedGoal = DiaryGoalTargets(
            calorieTarget: 2_000, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
        )
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: loadedGoal,
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .legacy
        )
        let callback = GoalCallbackBox()
        coordinator.installSettingsGoalCallback { generation, targets, savedDate in
            callback.record(generation, targets, savedDate)
        }

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await typeDifferentDraft(into: settings)
        await settings.saveGoals()

        XCTAssertEqual(callback.calls.count, 0, "Legacy mode must not invoke the store callback")
        XCTAssertEqual(diary.goal.calorieTarget, 2_150)
        XCTAssertEqual(diary.goal.proteinTargetG, 170)
        XCTAssertEqual(diary.goal.carbsTargetG, 210)
        XCTAssertEqual(diary.goal.fatTargetG, 70)
    }

    func testStoreBackedGoalSaveFromHistoricalDayDeliversTodayDateAndKeepsHistory() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        let historicalGoal = DiaryGoalTargets(
            calorieTarget: 2_100, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
        )
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: DiaryGoalTargets(calorieTarget: 2_000),
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        await diaryService.setDay(DiaryDay(
            date: yesterday,
            goal: historicalGoal,
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        // The server snapshot still names today: settings always target today,
        // even while a historical day is visible.
        let authoritative = GoalSnapshot(
            requestedDate: date,
            effectiveFrom: date,
            source: .saved,
            targets: GoalTargets(
                calorieTarget: 2_230, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
            )
        )
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: [.lunch]),
            authoritativeSave: authoritative
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = GoalCallbackBox()
        coordinator.installSettingsGoalCallback { generation, targets, savedDate in
            callback.record(generation, targets, savedDate)
        }

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        await diary.selectDate(yesterday)
        XCTAssertEqual(diary.goal, historicalGoal)

        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await typeDifferentDraft(into: settings)
        await settings.saveGoals()

        XCTAssertEqual(callback.calls.count, 1)
        guard let call = callback.calls.first else { return }
        XCTAssertEqual(call.date, date, "The callback must carry the server-requested today")
        XCTAssertEqual(call.targets, CalCoStoreMapping.diaryGoal(from: authoritative))
        XCTAssertEqual(diary.selectedDate, yesterday)
        XCTAssertEqual(diary.goal, historicalGoal, "A historical day must keep its own goal")
    }

    func testStaleSaveAfterRealSessionExpiryDeliversNoCallbackOrMutation() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        let loadedGoal = DiaryGoalTargets(
            calorieTarget: 2_000, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
        )
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: loadedGoal,
            prefs: DiaryPrefs(enabledSlots: [.lunch])
        ))
        let authoritative = GoalSnapshot(
            requestedDate: date,
            effectiveFrom: date,
            source: .saved,
            targets: GoalTargets(
                calorieTarget: 2_230, proteinTargetG: 150, carbsTargetG: 250, fatTargetG: 70
            )
        )
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: [.lunch]),
            authoritativeSave: authoritative
        )
        await settingsService.armHold()
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = GoalCallbackBox()
        coordinator.installSettingsGoalCallback { generation, targets, savedDate in
            callback.record(generation, targets, savedDate)
        }

        await coordinator.start()
        await waitForLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await typeDifferentDraft(into: settings)

        let saveTask = Task { await settings.saveGoals() }
        await settingsService.waitForSaveStarted()
        // A real 401 on the live session, while the PUT is still held.
        XCTAssertTrue(coordinator.session.handleUnauthorized(reason: .expired))
        // The real 401 resets the legacy VM and clears its content, so the
        // pre-expiry 2000 target is already gone BEFORE the held PUT resolves.
        let afterResetGoal = diary.goal
        XCTAssertEqual(afterResetGoal, DiaryGoalTargets(), "The stale VM was not cleared")
        await settingsService.releaseSave()
        await saveTask.value

        XCTAssertEqual(callback.calls.count, 0, "A stale success must reach no owner")
        XCTAssertEqual(diary.goal, afterResetGoal, "A late server payload restored a cleared goal")
        XCTAssertNil(coordinator.settingsViewModel, "The expired session cleared settings")
    }

    // MARK: - Real SettingsVM.savePreferences writeback (server response authoritative)

    func testStoreBackedPreferencesSaveMapsServerResponseAndDeliversCallbackOnce() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        let allSlots = DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        await diaryService.setDay(DiaryDay(date: date, prefs: allSlots))
        // Draft disables only breakfast; the server response disables lunch too.
        // Only the mapped server prefs may reach the store-backed owner.
        let authoritative = DiaryPreferences(enabledSlots: [.dinner, .snack, .lateNightSnack])
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases)),
            authoritativePreferencesSave: authoritative
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = PreferencesCallbackBox()
        coordinator.installSettingsPreferencesCallback { generation, prefs in
            callback.record(generation, prefs)
        }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        let generation = coordinator.session.sessionGeneration
        let baselineFetches = await diaryService.callCount(for: date)

        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()

        XCTAssertEqual(callback.calls.count, 1, "Exactly one store-backed handoff")
        guard let call = callback.calls.first else { return }
        XCTAssertEqual(call.generation, generation)
        XCTAssertEqual(call.prefs, CalCoStoreMapping.diaryPrefs(from: authoritative))
        XCTAssertFalse(call.prefs.isEnabled(.breakfast))
        XCTAssertFalse(call.prefs.isEnabled(.lunch), "The server response must win over the draft")
        // No legacy apply and no extra authoritative read on this path.
        XCTAssertEqual(coordinator.diaryViewModel?.enabledSlots, allSlots.enabledSlots)
        let requests = await settingsService.preferenceRequests()
        XCTAssertEqual(requests.count, 1, "Exactly one PUT")
        let fetchesAfterSave = await diaryService.callCount(for: date)
        XCTAssertEqual(fetchesAfterSave, baselineFetches, "The save must not issue a diary GET")
    }

    func testLegacyPreferencesSaveAppliesToLegacyDiaryWithoutStoreCallback() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        ))
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases))
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .legacy
        )
        let callback = PreferencesCallbackBox()
        coordinator.installSettingsPreferencesCallback { generation, prefs in
            callback.record(generation, prefs)
        }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let baselineFetches = await diaryService.callCount(for: date)

        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()

        XCTAssertEqual(callback.calls.count, 0, "Legacy mode must not invoke the store callback")
        XCTAssertFalse(diary.enabledSlots.contains(.breakfast), "The legacy VM was not applied to")
        XCTAssertTrue(diary.enabledSlots.contains(.lunch))
        let fetchesAfterSave = await diaryService.callCount(for: date)
        XCTAssertEqual(fetchesAfterSave, baselineFetches)
    }

    func testStoreBackedHistoricalPreferencesSaveKeepsDateGoalLogsAndCache() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        let historicalPrefs = DiaryPrefs(enabledSlots: [.lunch])
        let historicalGoal = DiaryGoalTargets(
            calorieTarget: 2_100, proteinTargetG: 160, carbsTargetG: 260, fatTargetG: 65
        )
        let historicalLogs = [
            DiaryLog(id: "hist-a", mealSlot: .breakfast, title: "Historical breakfast"),
            DiaryLog(id: "hist-b", mealSlot: .lunch, title: "Historical lunch"),
        ]
        await diaryService.setDay(DiaryDay(
            date: date,
            goal: DiaryGoalTargets(calorieTarget: 2_000),
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        ))
        await diaryService.setDay(DiaryDay(
            date: yesterday,
            logs: historicalLogs,
            goal: historicalGoal,
            prefs: historicalPrefs
        ))
        let authoritative = DiaryPreferences(enabledSlots: [.dinner, .snack])
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases)),
            authoritativePreferencesSave: authoritative
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = PreferencesCallbackBox()
        coordinator.installSettingsPreferencesCallback { generation, prefs in
            callback.record(generation, prefs)
        }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        await diary.selectDate(yesterday)
        XCTAssertEqual(diary.selectedDate, yesterday)

        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()

        XCTAssertEqual(callback.calls.count, 1)
        XCTAssertEqual(callback.calls.first?.prefs, CalCoStoreMapping.diaryPrefs(from: authoritative))
        XCTAssertEqual(diary.selectedDate, yesterday, "The selected date is preserved")
        XCTAssertEqual(coordinator.navigationState.selectedDate, yesterday)
        XCTAssertEqual(diary.goal, historicalGoal, "The historical goal is unchanged")
        XCTAssertEqual(diary.logs, historicalLogs, "The historical logs are unchanged")
        XCTAssertEqual(
            diary.enabledSlots, historicalPrefs.enabledSlots,
            "The historical legacy prefs were not rewritten by a global save"
        )
    }

    func testStalePreferencesSaveAfterRealSessionExpiryDeliversNoCallbackOrMutation() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        ))
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases)),
            authoritativePreferencesSave: DiaryPreferences(enabledSlots: [.dinner])
        )
        await settingsService.armPreferencesHold()
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = PreferencesCallbackBox()
        coordinator.installSettingsPreferencesCallback { generation, prefs in
            callback.record(generation, prefs)
        }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)

        let saveTask = Task { await settings.savePreferences() }
        await settingsService.waitForPreferencesSaveStarted()
        // A real 401 on the live session, while the PUT is still held.
        XCTAssertTrue(coordinator.session.handleUnauthorized(reason: .expired))
        // The real 401 resets the legacy VM to all slots BEFORE the held PUT
        // resolves: the combined stale guard must suppress the late payload.
        let afterResetSlots = diary.enabledSlots
        XCTAssertEqual(afterResetSlots, Set(MealSlot.allCases), "The stale VM was not cleared")
        await settingsService.releasePreferencesSave()
        await saveTask.value

        XCTAssertEqual(callback.calls.count, 0, "A stale success must reach no owner")
        XCTAssertEqual(diary.enabledSlots, afterResetSlots, "A late payload restored cleared prefs")
        XCTAssertNil(coordinator.settingsViewModel, "The expired session cleared settings")
    }

    func testSupersededSettingsViewModelCannotApplyLatePreferencesCallback() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        ))
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases))
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = PreferencesCallbackBox()
        coordinator.installSettingsPreferencesCallback { generation, prefs in
            callback.record(generation, prefs)
        }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        coordinator.showSettings()
        guard let oldSettings = coordinator.settingsViewModel else {
            return XCTFail("Expected the first settings view model")
        }
        await awaitPreferencesSettingsLoaded(oldSettings)
        coordinator.dismissSettings()
        XCTAssertNil(coordinator.settingsViewModel)

        coordinator.showSettings()
        guard let newSettings = coordinator.settingsViewModel else {
            return XCTFail("Expected the replacement settings view model")
        }
        XCTAssertNotEqual(oldSettings.id, newSettings.id)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        let before = diary.enabledSlots

        oldSettings.onPreferencesSaved?(DiaryPreferences(enabledSlots: [.dinner]))

        XCTAssertEqual(callback.calls.count, 0, "A replaced VM must reach no owner")
        XCTAssertEqual(diary.enabledSlots, before)
    }

    func testDefinitivePreferencesFailureDeliversNoCallback() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        ))
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases)),
            preferencesSaveError: DiarySettingsServiceError.rejected("invalid slots")
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        let callback = PreferencesCallbackBox()
        coordinator.installSettingsPreferencesCallback { generation, prefs in
            callback.record(generation, prefs)
        }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        guard let diary = coordinator.diaryViewModel else {
            return XCTFail("Expected a diary view model")
        }
        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()

        XCTAssertEqual(callback.calls.count, 0, "A definitive failure reaches no owner")
        XCTAssertNotNil(settings.preferencesSaveState.errorMessage)
        XCTAssertFalse(settings.preferencesNeedsReconciliation, "A rejection is not ambiguous")
        XCTAssertEqual(diary.enabledSlots, Set(MealSlot.allCases), "No prefs were applied")
    }

    func testDisabledContextualMealSlotClearedAndSearchUpdatedInBothModes() async {
        for ownership in [DiaryScreenOwnership.legacy, .storeBackedScreen] {
            let userSession = appFlowSession()
            let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
            let diaryService = AppFlowDiaryService()
            await diaryService.setDay(DiaryDay(
                date: date,
                prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
            ))
            let settingsService = AppFlowGoalSettingsService(
                goal: defaultGoalSnapshot(),
                preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases)),
                authoritativePreferencesSave: DiaryPreferences(
                    enabledSlots: [.dinner, .snack, .lateNightSnack]
                )
            )
            let coordinator = goalWritebackCoordinator(
                sessionService: sessionService,
                diaryService: diaryService,
                settingsService: settingsService,
                ownership: ownership
            )
            let callback = PreferencesCallbackBox()
            coordinator.installSettingsPreferencesCallback { generation, prefs in
                callback.record(generation, prefs)
            }

            await coordinator.start()
            await awaitLoadedDiary(coordinator)

            // A real navigation origin sets the contextual meal slot.
            coordinator.startLogging(slot: .breakfast, date: date)
            XCTAssertEqual(coordinator.navigationState.mealSlot, .breakfast)
            XCTAssertEqual(coordinator.searchViewModel?.originMealSlot, .breakfast)

            coordinator.showSettings()
            guard let settings = coordinator.settingsViewModel else {
                return XCTFail("Expected settings")
            }
            await awaitPreferencesSettingsLoaded(settings)
            settings.toggleSlot(.breakfast, enabled: false)
            await settings.savePreferences()

            XCTAssertNil(coordinator.navigationState.mealSlot, "The disabled slot must be cleared")
            XCTAssertEqual(coordinator.navigationState.selectedDate, date, "The date is preserved")
            XCTAssertNil(
                coordinator.searchViewModel?.originMealSlot,
                "Search must inherit the cleared context"
            )
            switch ownership {
            case .legacy:
                XCTAssertEqual(callback.calls.count, 0)
                XCTAssertFalse(coordinator.diaryViewModel?.enabledSlots.contains(.breakfast) ?? true)
            case .storeBackedScreen:
                XCTAssertEqual(callback.calls.count, 1)
                XCTAssertEqual(
                    coordinator.diaryViewModel?.enabledSlots, Set(MealSlot.allCases),
                    "No legacy apply in store-backed mode"
                )
            }
        }
    }

    func testContextualSlotDecisionUsesAuthoritativePrefsNotDraft() async {
        let userSession = appFlowSession()
        let sessionService = AppFlowSessionService(restore: { .authenticated(userSession) })
        let diaryService = AppFlowDiaryService()
        await diaryService.setDay(DiaryDay(
            date: date,
            prefs: DiaryPrefs(enabledSlots: Set(MealSlot.allCases))
        ))
        // The draft disables breakfast but the authoritative server response
        // keeps every slot enabled. Only a stale-draft implementation clears the
        // contextual slot here; authoritative prefs must leave it intact.
        let settingsService = AppFlowGoalSettingsService(
            goal: defaultGoalSnapshot(),
            preferences: DiaryPreferences(enabledSlots: Set(MealSlot.allCases)),
            authoritativePreferencesSave: DiaryPreferences(
                enabledSlots: Set(MealSlot.allCases)
            )
        )
        let coordinator = goalWritebackCoordinator(
            sessionService: sessionService,
            diaryService: diaryService,
            settingsService: settingsService,
            ownership: .storeBackedScreen
        )
        coordinator.installSettingsPreferencesCallback { _, _ in }

        await coordinator.start()
        await awaitLoadedDiary(coordinator)
        coordinator.startLogging(slot: .breakfast, date: date)
        XCTAssertEqual(coordinator.navigationState.mealSlot, .breakfast)

        coordinator.showSettings()
        guard let settings = coordinator.settingsViewModel else {
            return XCTFail("Expected settings")
        }
        await awaitPreferencesSettingsLoaded(settings)
        settings.toggleSlot(.breakfast, enabled: false)
        await settings.savePreferences()

        XCTAssertEqual(
            coordinator.navigationState.mealSlot, .breakfast,
            "The decision must use authoritative prefs, never the stale draft"
        )
    }
}
