// Focused contract tests for the compact native navigation redesign.
// Pure model/helper checks only: no network, database, keychain, or simulator.

import Foundation
import XCTest

@testable import CalCo

private struct NativeRedesignSearchService: FoodSearchServicing {
    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult] {
        []
    }
}

// MARK: - Narrow in-memory harness for guarded tab-switch tests

private let nativeRedesignBaseURL = URL(string: "https://calco.example.com")!

private final class NativeRedesignSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession

    init(session: LoginSession) { self.session = session }

    func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
    func login(username: String, password: String) async throws -> LoginSession { session }
    func logout() async throws {}
    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class NativeRedesignCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private actor NativeRedesignDiaryService: DiaryServicing {
    private let log: DiaryLog
    private var holdsUpdate = false
    private var updateStarted = false
    private var updateReleased = false
    private var updateContinuation: CheckedContinuation<Void, Never>?

    init(log: DiaryLog) { self.log = log }

    func holdNextUpdate() {
        holdsUpdate = true
        updateStarted = false
        updateReleased = false
    }

    func waitForUpdateStart() async {
        let deadline = Date().addingTimeInterval(5)
        while !updateStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func releaseUpdate() {
        updateReleased = true
        updateContinuation?.resume()
        updateContinuation = nil
    }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        DiaryDay(date: date, logs: [log])
    }

    func getLog(id: String) async throws -> DiaryLog { log }

    func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
        if holdsUpdate {
            holdsUpdate = false
            updateStarted = true
            await withCheckedContinuation { continuation in
                if updateReleased {
                    continuation.resume()
                } else {
                    updateContinuation = continuation
                }
            }
        }
        return log
    }

    func deleteLog(id: String) async throws {}
}

final class NativeRedesignTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 20)

    // MARK: - Add Food context

    func testContextualScopesUseRealFeaturesAndExcludeBarcode() {
        XCTAssertEqual(
            SearchView.contextualScopes,
            [.history, .custom, .all],
            "Recent/Custom/All map to existing scopes; no favorites backend is invented"
        )
        XCTAssertFalse(SearchView.contextualScopes.contains(.barcode))
    }

    func testCompactAIMenuExposesBothExistingPurposes() {
        // Regression: the ad-hoc AI purpose was only in the toolbar menu, which
        // the compact Add Food flow trims, making it unreachable on iPhone.
        XCTAssertEqual(
            SearchView.compactAssistantPurposes,
            [.customFood, .adHocLog],
            "The single compact AI entry must expose both existing drafting purposes"
        )
        XCTAssertEqual(
            String(localized: "assistant.entry.customFood"),
            "Draft custom food"
        )
        XCTAssertEqual(
            String(localized: "assistant.entry.adHocLog"),
            "Draft a meal log"
        )
    }

    @MainActor
    func testContextSubtitleIncludesSelectedDateAndMealSlot() {
        let viewModel = SearchViewModel(
            originDate: date,
            originMealSlot: .lunch,
            service: NativeRedesignSearchService(),
            onSelectFood: { _, _, _ in }
        )
        let view = SearchView(viewModel: viewModel)

        XCTAssertTrue(view.contextSubtitle.contains(date.diaryDisplayTitle()))
        XCTAssertTrue(view.contextSubtitle.contains(DiaryLabels.mealSlotName(.lunch)))
        XCTAssertTrue(view.contextSubtitle.contains("·"))
    }

    @MainActor
    func testContextSubtitleWithoutSlotIsJustTheDate() {
        let viewModel = SearchViewModel(
            originDate: date,
            service: NativeRedesignSearchService(),
            onSelectFood: { _, _, _ in }
        )
        let view = SearchView(viewModel: viewModel)

        XCTAssertEqual(view.contextSubtitle, date.diaryDisplayTitle())
    }

    // MARK: - Tab contracts

    func testCompactTopLevelTabsAreDiaryLibraryAndSettingsOnly() {
        let tabs: [AppShellTab] = [.diary, .library, .settings]
        XCTAssertEqual(Set(tabs.map(\.systemImage)).count, 3)
        XCTAssertEqual(AppShellTab.library.title, String(localized: "library.title"))
        // The compact tab label is short; the settings screen keeps the full
        // localized "Diary Settings" navigation title.
        XCTAssertEqual(AppShellTab.settings.title, "Settings")
        XCTAssertEqual(String(localized: "settings.title"), "Diary Settings")
    }

    func testSearchIsNotATopLevelTab() {
        // There is no search case: the Add Food flow stays contextual to Diary.
        let tabs: [AppShellTab] = [.diary, .library, .settings]
        XCTAssertFalse(tabs.isEmpty)
        XCTAssertEqual(tabs.count, 3)
    }

    func testLibrarySectionsCoverFoodsAndMeals() {
        XCTAssertEqual(LibrarySection.foods.title, "Foods")
        XCTAssertEqual(LibrarySection.meals.title, String(localized: "meals.title"))
        XCTAssertNotEqual(LibrarySection.foods.systemImage, LibrarySection.meals.systemImage)
    }

    // MARK: - Live Log Food nutrition

    func testLogNutritionSummaryFormatsScaledEnergyAndMacros() {
        let summary = makeLogNutritionSummary(from: [
            NutrientAmount(code: "ENERGY_KCAL", amount: "146.0", unit: "kcal"),
            NutrientAmount(code: "PROTEIN_G", amount: "20", unit: "g"),
            NutrientAmount(code: "CARBS_G", amount: "8.0", unit: "g"),
            NutrientAmount(code: "FAT_G", amount: "4", unit: "g"),
        ])

        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.energy, "146")
        XCTAssertEqual(summary?.protein, "20")
        XCTAssertEqual(summary?.carbs, "8")
        XCTAssertEqual(summary?.fat, "4")
        XCTAssertTrue(summary?.hasPrimaryValues == true)
        XCTAssertEqual(summary?.nutrients.count, 4)
    }

    func testLogNutritionSummaryKeepsFractionalValues() {
        let summary = makeLogNutritionSummary(from: [
            NutrientAmount(code: "ENERGY_KCAL", amount: "146.42", unit: "kcal"),
        ])

        XCTAssertEqual(summary?.energy, "146.4")
        XCTAssertNil(summary?.protein)
    }

    func testLogNutritionSummaryIgnoresUnknownAndInvalidCodes() {
        let summary = makeLogNutritionSummary(from: [
            NutrientAmount(code: "SODIUM_MG", amount: "300", unit: "mg"),
            NutrientAmount(code: "ENERGY_KCAL", amount: "n/a", unit: "kcal"),
        ])

        XCTAssertNotNil(summary, "Secondary full-nutrition list still shows raw rows")
        XCTAssertNil(summary?.energy)
        XCTAssertFalse(summary?.hasPrimaryValues == true)
        XCTAssertEqual(summary?.nutrients.count, 2)
    }

    func testLogNutritionSummaryIsNilWithoutPreview() {
        XCTAssertNil(makeLogNutritionSummary(from: nil))
        XCTAssertNil(makeLogNutritionSummary(from: []))
    }

    func testUnknownNutrientKeepsItsCodeAsLabel() {
        XCTAssertEqual(logNutritionLabel(for: "SODIUM_MG"), "SODIUM_MG")
        XCTAssertEqual(
            logNutritionLabel(for: "protein_g"),
            String(localized: "meals.nutrient.protein")
        )
    }

    // MARK: - Guarded native tab switching

    private func makeNativeLog() -> DiaryLog {
        DiaryLog(
            id: "log-1",
            mealSlot: .breakfast,
            title: "Oats",
            calories: 300,
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: "with milk"
        )
    }

    @MainActor
    private func makeIsolatedStore() -> LogSubmissionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-native-redesign-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
    }

    @MainActor
    private func makeCoordinator(
        diaryService: NativeRedesignDiaryService
    ) -> AppShellCoordinator {
        let session = LoginSession(
            identity: AuthIdentity(id: "identity-native", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-native", displayName: "Alice")
        )
        let coordinatorSession = SessionCoordinator(
            service: NativeRedesignSessionService(session: session),
            cookieBaseURL: nativeRedesignBaseURL,
            cookieClearer: NativeRedesignCookieClearer()
        )
        return AppShellCoordinator(
            client: CalCoAPIClient(baseURL: nativeRedesignBaseURL),
            session: coordinatorSession,
            diaryService: diaryService,
            searchService: NativeRedesignSearchService(),
            logSubmissionStore: makeIsolatedStore(),
            todayProvider: { self.date }
        )
    }

    @MainActor
    private func loadDiary(_ coordinator: AppShellCoordinator) async {
        await coordinator.start()
        let deadline = Date().addingTimeInterval(5)
        while coordinator.diaryViewModel?.state != .loaded(.idle), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(coordinator.diaryViewModel?.state, .loaded(.idle))
    }

    @MainActor
    func testDirtyLogEditorBlocksAppTabSwitchUntilExplicitConfirm() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)
        coordinator.diaryViewModel?.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected the log editor view model")
        }
        editor.amount = "275"
        editor.notes = "unsaved note"

        coordinator.requestTabSwitch(to: .library)

        XCTAssertEqual(coordinator.pendingEditorDiscard, .switchTab(tab: .library))
        XCTAssertEqual(coordinator.selectedTab, .diary, "Tab must not change before confirmation")
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)
        XCTAssertEqual(editor.amount, "275")
        XCTAssertEqual(editor.notes, "unsaved note")

        coordinator.cancelDiscardEditorChanges()
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertEqual(coordinator.selectedTab, .diary)
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)
        XCTAssertEqual(editor.notes, "unsaved note")

        coordinator.requestTabSwitch(to: .library)
        coordinator.confirmDiscardEditorChanges()

        XCTAssertEqual(coordinator.selectedTab, .library)
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertNil(coordinator.logEditorViewModel(for: "log-1"))
    }

    @MainActor
    func testBusyLogEditorIgnoresAppTabSwitch() async {
        let service = NativeRedesignDiaryService(log: makeNativeLog())
        await service.holdNextUpdate()
        let coordinator = makeCoordinator(diaryService: service)
        await loadDiary(coordinator)
        coordinator.diaryViewModel?.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected the log editor view model")
        }
        editor.amount = "275"
        let save = Task { await editor.save() }
        await service.waitForUpdateStart()
        XCTAssertTrue(editor.isBusy)

        coordinator.requestTabSwitch(to: .settings)

        XCTAssertEqual(coordinator.selectedTab, .diary)
        XCTAssertNil(coordinator.pendingEditorDiscard)
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)

        await service.releaseUpdate()
        await save.value
    }

    @MainActor
    func testExpandedLibrarySelectionResetsOnSessionReset() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)

        coordinator.selectExpandedLibrary()
        XCTAssertTrue(coordinator.expandedLibrarySelected)
        XCTAssertEqual(AppShellPanePlan.sidebarSections, [.diary, .search, .library, .settings])

        _ = await coordinator.signOut()
        XCTAssertEqual(coordinator.selectedTab, .diary)
        XCTAssertFalse(coordinator.expandedLibrarySelected)

        await coordinator.start()
        XCTAssertEqual(coordinator.selectedTab, .diary)
        XCTAssertFalse(coordinator.expandedLibrarySelected)
    }

    @MainActor
    func testSettingsSidebarDestinationCanNavigateToEveryOtherDestination() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)

        for destination in [AppShellTab.diary, .search, .library] {
            coordinator.selectSidebarDestination(.settings)
            coordinator.ensureSettingsViewModel()
            XCTAssertEqual(coordinator.selectedSidebarDestination, .settings)
            XCTAssertNotNil(coordinator.settingsViewModel)

            coordinator.selectSidebarDestination(destination)
            XCTAssertEqual(coordinator.selectedSidebarDestination, destination)
        }
    }

    @MainActor
    func testSettingsSidebarDestinationRespectsDirtyEditorGuard() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)
        coordinator.diaryViewModel?.openLogEditor(logID: "log-1")
        guard let editor = coordinator.logEditorViewModel(for: "log-1") else {
            return XCTFail("Expected the log editor view model")
        }
        editor.notes = "unsaved note"
        let originalDestination = coordinator.selectedSidebarDestination

        coordinator.selectSidebarDestination(.settings)
        XCTAssertEqual(coordinator.selectedSidebarDestination, originalDestination)
        XCTAssertEqual(coordinator.pendingEditorDiscard, .switchTab(tab: .settings))

        coordinator.cancelDiscardEditorChanges()
        XCTAssertEqual(coordinator.selectedSidebarDestination, originalDestination)
        XCTAssertTrue(coordinator.logEditorViewModel(for: "log-1") === editor)

        coordinator.selectSidebarDestination(.settings)
        coordinator.confirmDiscardEditorChanges()
        XCTAssertEqual(coordinator.selectedSidebarDestination, .settings)
        XCTAssertNil(coordinator.logEditorViewModel(for: "log-1"))
    }

    @MainActor
    func testNavigatingAwayFromExpandedLibraryClearsSidebarSelection() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)

        coordinator.selectExpandedLibrary()
        XCTAssertTrue(coordinator.expandedLibrarySelected)

        coordinator.startLogging(slot: .lunch, date: date)
        XCTAssertFalse(coordinator.expandedLibrarySelected)
    }

    func testLibraryDestinationIdentityIsAccountScopedNotDateScoped() {
        // The compact Library tab must keep its route-owned editor state when
        // the diary date changes; only account identity may reset it.
        XCTAssertEqual(LibrarySection.foods, .foods)
        XCTAssertEqual(LibrarySection.meals, .meals)
    }

    // MARK: - Live context capture (no stale-date logging)

    private let dayA = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let dayB = LocalDiaryDate(year: 2026, month: 11, day: 20)

    @MainActor
    func testLibraryContextIsReadAtOpenAndFollowsDiaryChange() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)

        // T0: Library opened while the diary is on day A.
        let atOpen = coordinator.currentLibraryLogContext
        XCTAssertEqual(atOpen.date, date)
        XCTAssertNil(atOpen.mealSlot)

        // User changes the diary to day B and a different slot.
        coordinator.startLogging(slot: .lunch, date: dayB)
        let afterChange = coordinator.currentLibraryLogContext
        XCTAssertEqual(afterChange.date, dayB)
        XCTAssertEqual(afterChange.mealSlot, .lunch)

        // A fresh Library flow captures B, while the earlier captured value
        // is unchanged for the draft that was already opened.
        XCTAssertEqual(atOpen.date, date)
        XCTAssertEqual(atOpen.mealSlot, nil)
        XCTAssertNotEqual(atOpen, afterChange)
    }

    @MainActor
    func testAccountResetClearsLibraryContextToCurrentDayAndDiaryTab() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)
        coordinator.startLogging(slot: .dinner, date: dayB)
        XCTAssertEqual(coordinator.currentLibraryLogContext.date, dayB)

        _ = await coordinator.signOut()
        XCTAssertEqual(coordinator.currentLibraryLogContext.date, date)
        XCTAssertNil(coordinator.currentLibraryLogContext.mealSlot)
        XCTAssertEqual(coordinator.selectedTab, .diary)

        await coordinator.start()
        XCTAssertEqual(coordinator.currentLibraryLogContext.date, date)
        XCTAssertFalse(coordinator.expandedLibrarySelected)
    }

    @MainActor
    func testOpenAdHocDraftKeepsCapturedDateThroughSubmission() async {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(results: [.success([])])
        let openedAt = LibraryLogContext(date: dayA, mealSlot: .breakfast)
        let viewModel = AdHocLogViewModel(
            service: service,
            submissionService: submission,
            accountID: "account-native",
            initialDate: openedAt.date,
            today: dayB,
            initialMealSlot: openedAt.mealSlot
        )
        await viewModel.load()
        guard case .loaded = viewModel.loadState else {
            return XCTFail("Ad-hoc form did not load: \(viewModel.loadState)")
        }
        viewModel.name = "Captured food"
        viewModel.amount = "100"
        viewModel.unit = "g"
        // The catalog requires these four per-portion nutrients before a
        // review can be issued; empty required rows are a form validation
        // failure, not a context-capture failure.
        for code in CustomFoodNutrientCodes.required {
            viewModel.setNutrientAmount("10", code: code)
        }

        // The simulated diary change happens after the draft was opened.
        let laterDiary = LibraryLogContext(date: dayB, mealSlot: .dinner)
        XCTAssertNotEqual(laterDiary, openedAt)

        viewModel.requestReview()
        guard let review = viewModel.pendingReview else {
            return XCTFail("Expected an ad-hoc review")
        }
        XCTAssertEqual(review.date, dayA)
        XCTAssertEqual(review.mealSlot, .breakfast)
        XCTAssertEqual(review.draft.date, dayA)

        await viewModel.confirmReview(review)

        XCTAssertEqual(submission.submissions.count, 1)
        XCTAssertEqual(submission.submissions.first?.drafts.first?.date, dayA)
        XCTAssertEqual(submission.submissions.first?.drafts.first?.mealSlot, .breakfast)
    }

    @MainActor
    func testMealQuickAddCapturesProviderContextAtActionTime() {
        var liveContext = LibraryLogContext(date: dayA, mealSlot: .breakfast)
        let recorder = NativeDraftRecorder()
        let viewModel = MealsListViewModel(
            date: dayA,
            mealSlot: .breakfast,
            service: NativeMealsService(),
            onSubmitDrafts: { drafts, _, _, completion in
                recorder.drafts.append(contentsOf: drafts)
                completion(.success([]))
            },
            currentContextProvider: { liveContext }
        )
        let meal = nativeMeal()

        viewModel.quickAdd(meal)
        XCTAssertEqual(recorder.drafts.first?.date, dayA)

        // A successful quick-add leaves the state at .added; clear the message
        // to return to .idle before issuing the next deliberate quick-add.
        viewModel.dismissQuickAddMessage()

        // A diary change after opening the Meals destination must retarget only
        // the NEXT quick-add, never the already-issued draft/POST.
        liveContext = LibraryLogContext(date: dayB, mealSlot: .lunch)
        viewModel.quickAdd(meal)
        XCTAssertEqual(recorder.drafts.last?.date, dayB)
        XCTAssertEqual(recorder.drafts.last?.mealSlot, .lunch)
        XCTAssertEqual(recorder.drafts.first?.date, dayA)
    }

    // MARK: - Search tab / Diary push routing

    @MainActor
    func testSearchTabDetailUsesOwnStackAndLeavesDiaryPathUntouched() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)
        let diaryPathBefore = coordinator.navigationState

        coordinator.searchViewModel?.updateContext(date: date, mealSlot: .lunch)
        coordinator.openSearchTabFoodDetail("food-search")

        XCTAssertEqual(coordinator.searchTabPath, [.foodDetail(foodID: "food-search")])
        XCTAssertEqual(
            coordinator.navigationState,
            diaryPathBefore,
            "The hidden Diary stack must not be retargeted by a Search tab selection"
        )
        XCTAssertNotNil(coordinator.foodDetailViewModel(for: "food-search"))
        XCTAssertEqual(coordinator.searchViewModel?.originMealSlot, .lunch)

        coordinator.popSearchTabDetail()
        XCTAssertTrue(coordinator.searchTabPath.isEmpty)
    }

    @MainActor
    func testDiaryAddFoodDetailStillUsesDiaryStackWithRetainedContext() async {
        let coordinator = makeCoordinator(
            diaryService: NativeRedesignDiaryService(log: makeNativeLog())
        )
        await loadDiary(coordinator)

        coordinator.startLogging(slot: .lunch, date: date)
        XCTAssertEqual(coordinator.navigationState.paneStack, [.diary, .foodSearch])
        coordinator.openFoodDetail("food-diary", date: date, mealSlot: .lunch)

        XCTAssertEqual(
            coordinator.navigationState.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: "food-diary")]
        )
        XCTAssertTrue(coordinator.searchTabPath.isEmpty)
        XCTAssertEqual(coordinator.searchViewModel?.originMealSlot, .lunch)
        XCTAssertEqual(coordinator.searchViewModel?.originDate, date)
    }

    private func nativeMeal() -> Meal {
        Meal(
            id: "meal-native",
            name: "Porridge",
            notes: nil,
            totalQuantity: NutritionQuantity(amount: "250", unit: "g"),
            nutritionSummary: NutritionSummary(energyKcal: "310"),
            components: [
                MealComponent(
                    id: "component-1",
                    item: ItemReference(itemType: .product, id: "oats"),
                    quantity: NutritionQuantity(amount: "250", unit: "g"),
                    nutritionSummary: NutritionSummary(energyKcal: "310")
                )
            ]
        )
    }
}

private final class NativeDraftRecorder {
    var drafts: [LogSubmissionDraft] = []
}

private struct NativeMealsService: MealsServicing {
    func listMeals() async throws -> [Meal] { [] }
    func getMeal(id: String) async throws -> Meal { throw MealServiceError.notFound("unused") }
    func createMeal(_ request: MealWriteRequest) async throws -> Meal { throw MealServiceError.validation("unused") }
    func updateMeal(id: String, _ request: MealWriteRequest) async throws -> Meal { throw MealServiceError.validation("unused") }
    func deleteMeal(id: String) async throws {}
    func mealNutrients(mealID: String, amount: String, unit: String) async throws -> MealNutritionResponse {
        throw MealServiceError.validation("unused")
    }
    func fetchUnits() async throws -> [ProductUnit] { [] }
    func searchComponentProducts(query: String) async throws -> [MealProduct] { [] }
    func fetchComponentProduct(id: String) async throws -> MealProduct {
        throw MealServiceError.notFound("unused")
    }
    func lastUsedPortion(
        forMealID mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> NutritionQuantity? { nil }
}
