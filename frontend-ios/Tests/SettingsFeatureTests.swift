import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class SettingsFeatureTests: XCTestCase {
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let nextDay = LocalDiaryDate(year: 2026, month: 11, day: 25)
    private let generation = UInt64(42)
    private let accountID = "user-1"
    private let settingsID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let locale = Locale(identifier: "en_US_POSIX")

    private var context: SettingsFeature.RequestContext {
        SettingsFeature.RequestContext(
            accountID: accountID,
            generation: generation,
            settingsID: settingsID
        )
    }

    private func goalSnapshot(
        date: LocalDiaryDate? = nil,
        calories: Double = 2000,
        protein: Double = 150,
        carbs: Double = 200,
        fat: Double = 70
    ) -> GoalSnapshot {
        GoalSnapshot(
            requestedDate: date ?? today,
            effectiveFrom: nil,
            source: .saved,
            targets: GoalTargets(
                calorieTarget: calories,
                proteinTargetG: protein,
                carbsTargetG: carbs,
                fatTargetG: fat
            ),
            exactTargets: GoalTargetsDecimal(
                calorieTarget: Decimal(Int(calories)),
                proteinTargetG: Decimal(Int(protein)),
                carbsTargetG: Decimal(Int(carbs)),
                fatTargetG: Decimal(Int(fat))
            )
        )
    }

    private func allSlots() -> Set<MealSlot> { Set(MealSlot.allCases) }

    private func texts(
        calories: String = "2000",
        protein: String = "150",
        carbs: String = "200",
        fat: String = "70"
    ) -> SettingsFeature.GoalTexts {
        var value = SettingsFeature.GoalTexts()
        value[.calories] = calories
        value[.protein] = protein
        value[.carbs] = carbs
        value[.fat] = fat
        return value
    }

    private func loadedBaseline(_ snapshot: GoalSnapshot) -> [SettingsFeature.GoalField: String] {
        let exact = snapshot.exactTargets!
        return [
            .calories: DiaryGoalForm.text(forDecimal: exact.calorieTarget, locale: locale),
            .protein: DiaryGoalForm.text(forDecimal: exact.proteinTargetG, locale: locale),
            .carbs: DiaryGoalForm.text(forDecimal: exact.carbsTargetG, locale: locale),
            .fat: DiaryGoalForm.text(forDecimal: exact.fatTargetG, locale: locale),
        ]
    }

    private func initialState() -> SettingsFeature.State {
        var state = SettingsFeature.State(
            accountID: accountID,
            today: today,
            timeZone: TimeZone(identifier: "America/New_York")!,
            sessionGeneration: generation,
            id: settingsID,
            locale: locale
        )
        state.goalLoadToken = 1
        state.prefsLoadToken = 1
        return state
    }

    private func loadedGoalState(
        snapshot: GoalSnapshot? = nil,
        texts edited: SettingsFeature.GoalTexts? = nil
    ) -> SettingsFeature.State {
        let snapshot = snapshot ?? goalSnapshot()
        var state = initialState()
        state.goalPhase = .loaded(snapshot)
        state.loadedGoalTexts = loadedBaseline(snapshot)
        state.goalTexts = edited ?? texts()
        return state
    }

    private func makeStore(
        state: SettingsFeature.State,
        fetchGoal: @escaping @Sendable (SettingsFeature.RequestContext, LocalDiaryDate) async throws -> GoalSnapshot = { _, _ in
            XCTFail("unexpected fetchGoal")
            throw DiarySettingsServiceError.unknown
        },
        saveGoal: @escaping @Sendable (SettingsFeature.RequestContext, SaveGoalRequest) async throws -> GoalSnapshot = { _, _ in
            XCTFail("unexpected saveGoal")
            throw DiarySettingsServiceError.unknown
        },
        fetchPreferences: @escaping @Sendable (SettingsFeature.RequestContext) async throws -> DiaryPreferences = { _ in
            XCTFail("unexpected fetchPreferences")
            throw DiarySettingsServiceError.unknown
        },
        updatePreferences: @escaping @Sendable (SettingsFeature.RequestContext, DiaryPreferences) async throws -> DiaryPreferences = { _, _ in
            XCTFail("unexpected updatePreferences")
            throw DiarySettingsServiceError.unknown
        }
    ) -> TestStore<SettingsFeature.State, SettingsFeature.Action> {
        TestStore(initialState: state) {
            SettingsFeature()
        } withDependencies: {
            $0.diarySettingsClient = SettingsFeature.Client(
                fetchGoal: fetchGoal,
                saveGoal: saveGoal,
                fetchPreferences: fetchPreferences,
                updatePreferences: updatePreferences
            )
        }
    }

    func testTaskLoadsGoalAndPreferencesAsIndependentSiblings() async {
        let gate = Gate()
        let goal = goalSnapshot()
        let prefs = DiaryPreferences(enabledSlots: allSlots())

        let store = makeStore(
            state: initialState(),
            fetchGoal: { _, _ in goal },
            fetchPreferences: { _ in
                await gate.wait()
                return prefs
            }
        )

        // `.task` delegates to `.load`; the state changes belong to the
        // received `.load` action, not to the `.task` send itself.
        await store.send(.task)
        await store.receive(.load) {
            $0.goalLoadToken = 2
            $0.prefsLoadToken = 2
            $0.goalPhase = .loading
            $0.prefsPhase = .loading
        }
        await store.receive(.goalReceived(context: context, token: 2, date: today, result: .success(goal))) {
            $0.goalPhase = .loaded(goal)
            $0.goalTexts = self.texts()
            $0.loadedGoalTexts = self.loadedBaseline(goal)
        }
        await gate.release()
        await store.receive(.prefsReceived(context: context, token: 2, result: .success(prefs))) {
            $0.prefsPhase = .loaded(prefs)
            $0.selectedSlots = self.allSlots()
            $0.prefsSave = .idle
        }
    }

    func testStaleLoadCompletionCannotClobberNewerToken() async {
        let goal = goalSnapshot()
        var loading = initialState()
        loading.goalPhase = .loading
        let loadingStore = makeStore(state: loading)

        await loadingStore.send(.goalReceived(context: context, token: 0, date: today, result: .success(goal)))
        XCTAssertEqual(loadingStore.state.goalPhase, .loading)
        await loadingStore.send(.goalReceived(context: context, token: 1, date: today, result: .success(goal))) {
            $0.goalPhase = .loaded(goal)
            $0.goalTexts = self.texts()
            $0.loadedGoalTexts = self.loadedBaseline(goal)
        }
    }

    func testGoalSaveUsesExactDecimalAndDelegatesMappedTargets() async {
        let baseline = goalSnapshot()
        let authoritative = goalSnapshot(calories: 2075, protein: 150, carbs: 200, fat: 75)
        let captured = SaveCapture()
        let edited = texts(calories: "2075", fat: "75")

        let store = makeStore(
            state: loadedGoalState(snapshot: baseline, texts: edited),
            saveGoal: { _, request in
                await captured.record(request)
                return authoritative
            }
        )
        XCTAssertTrue(store.state.canSaveGoals)

        await store.send(.saveGoals) {
            $0.goalSave = .saving
        }
        await captured.wait()
        let savedRequest = await captured.snapshot()
        XCTAssertEqual(savedRequest?.localDate, today)
        XCTAssertEqual(savedRequest?.deviceTimeZone, "America/New_York")
        XCTAssertEqual(savedRequest?.exactTargets?.calorieTarget, Decimal(2075))
        XCTAssertEqual(savedRequest?.exactTargets?.proteinTargetG, Decimal(150))
        XCTAssertEqual(savedRequest?.exactTargets?.carbsTargetG, Decimal(200))
        XCTAssertEqual(savedRequest?.exactTargets?.fatTargetG, Decimal(75))

        await store.receive(.goalSaveReceived(context: context, token: 1, result: .success(authoritative))) {
            $0.goalPhase = .loaded(authoritative)
            $0.goalTexts = self.texts(calories: "2075", fat: "75")
            $0.loadedGoalTexts = self.loadedBaseline(authoritative)
            $0.goalSave = .saved
            $0.goalDayReview = .none
        }
        await store.receive(.delegate(.goalSaved(
            settingsID: settingsID,
            generation: generation,
            targets: CalCoStoreMapping.diaryGoal(from: authoritative),
            effectiveDate: today
        )))
    }

    func testAmbiguousGoalSaveReconcilesFromFrozenAttempt() async {
        let baseline = goalSnapshot()
        let authoritative = goalSnapshot(calories: 2075, protein: 150, carbs: 200, fat: 75)
        let edited = texts(calories: "2075", fat: "75")
        let freeze = SettingsFeature.GoalReconciliation(
            context: context,
            attempted: GoalTargetsDecimal(
                calorieTarget: Decimal(2075),
                proteinTargetG: Decimal(150),
                carbsTargetG: Decimal(200),
                fatTargetG: Decimal(75)
            ),
            previous: baseline,
            requestedDate: today
        )

        let store = makeStore(
            state: loadedGoalState(snapshot: baseline, texts: edited),
            fetchGoal: { _, _ in authoritative },
            saveGoal: { _, _ in throw DiarySettingsServiceError.server("timeout") }
        )

        await store.send(.saveGoals) {
            $0.goalSave = .saving
        }
        await store.receive(.goalSaveReceived(
            context: context,
            token: 1,
            result: .failure(.ambiguous("timeout"))
        )) {
            $0.goalSave = .reconciling("timeout", freeze)
        }
        await store.receive(.goalReconcileReceived(context: context, token: 1, result: .success(authoritative))) {
            $0.goalPhase = .loaded(authoritative)
            $0.goalTexts = self.texts(calories: "2075", fat: "75")
            $0.loadedGoalTexts = self.loadedBaseline(authoritative)
            $0.goalSave = .saved
            $0.goalDayReview = .none
        }
        await store.receive(.delegate(.goalSaved(
            settingsID: settingsID,
            generation: generation,
            targets: CalCoStoreMapping.diaryGoal(from: authoritative),
            effectiveDate: today
        )))
    }

    func testPreferencesSaveDelegatesAuthoritativePrefs() async {
        let original = DiaryPreferences(enabledSlots: allSlots())
        let selected = allSlots().subtracting([.snack])
        let authoritative = DiaryPreferences(enabledSlots: selected)
        let captured = PrefsCapture()
        var state = initialState()
        state.prefsPhase = .loaded(original)
        state.selectedSlots = selected

        let store = makeStore(
            state: state,
            updatePreferences: { _, request in
                await captured.record(request)
                return authoritative
            }
        )
        XCTAssertTrue(store.state.canSavePreferences)

        await store.send(.savePreferences) {
            $0.prefsSave = .saving
        }
        await captured.wait()
        let savedPrefs = await captured.snapshot()
        XCTAssertEqual(savedPrefs, DiaryPreferences(enabledSlots: selected))

        await store.receive(.prefsSaveReceived(context: context, token: 1, result: .success(authoritative))) {
            $0.prefsPhase = .loaded(authoritative)
            $0.selectedSlots = selected
            $0.prefsSave = .saved
        }
        await store.receive(.delegate(.preferencesSaved(
            settingsID: settingsID,
            generation: generation,
            prefs: CalCoStoreMapping.diaryPrefs(from: authoritative)
        )))
    }

    func testEmptySlotSelectionCannotBeSaved() async {
        let original = DiaryPreferences(enabledSlots: allSlots())
        var state = initialState()
        state.prefsPhase = .loaded(original)
        state.selectedSlots = []
        let store = makeStore(state: state)

        await store.send(.savePreferences) {
            $0.prefsSave = .failed(String(localized: "settings.slots.error.empty"))
        }
        // The action refuses the empty selection; the reducer intentionally
        // keeps canSavePreferences true so the user can correct the selection.
        XCTAssertEqual(
            store.state.prefsSave.errorMessage,
            String(localized: "settings.slots.error.empty")
        )
    }

    func testDayChangePreservesDraftAndGatesSaveUntilReview() async {
        let baseline = goalSnapshot()
        let changedDay = self.nextDay
        let newDay = goalSnapshot(date: changedDay)
        let edited = texts(calories: "2075", fat: "75")
        let store = makeStore(
            state: loadedGoalState(snapshot: baseline, texts: edited),
            fetchGoal: { _, _ in newDay }
        )

        await store.send(.todayChanged(changedDay)) {
            $0.today = changedDay
        }
        await store.send(.saveGoals) {
            $0.goalDayReview = .required(String(localized: "settings.goals.error.dayChanged"))
            $0.goalSave = .failed(String(localized: "settings.goals.error.dayChanged"))
            $0.goalLoadToken = 2
        }
        await store.receive(.goalReloadedForNewDay(
            context: context,
            token: 2,
            preserveDraft: true,
            result: .success(newDay)
        )) {
            $0.goalPhase = .loaded(newDay)
            $0.goalDayReview = .required(String(localized: "settings.goals.error.dayChanged"))
            $0.goalSave = .failed(String(localized: "settings.goals.error.dayChanged"))
        }
        XCTAssertEqual(store.state.goalTexts, edited)
        XCTAssertFalse(store.state.canSaveGoals)

        await store.send(.reviewNewDayGoal) {
            $0.goalDayReview = .none
            $0.goalSave = .idle
        }
        XCTAssertTrue(store.state.canSaveGoals)
    }

    func testUnauthorizedSaveExpiresSessionOnce() async {
        let baseline = goalSnapshot()
        let edited = texts(calories: "2075", fat: "75")
        let message = String(localized: "diary.error.sessionExpired")
        let store = makeStore(
            state: loadedGoalState(snapshot: baseline, texts: edited),
            saveGoal: { _, _ in throw DiarySettingsServiceError.unauthorized }
        )

        await store.send(.saveGoals) {
            $0.goalSave = .saving
        }
        await store.receive(.goalSaveReceived(context: context, token: 1, result: .failure(.unauthorized))) {
            $0.goalSave = .failed(message)
            $0.goalPhase = .failed(message)
            $0.prefsPhase = .failed(message)
            $0.lifecycle = .expired
        }
        await store.receive(.delegate(.sessionExpired(settingsID: settingsID, generation: generation)))
        // Retained completions cannot emit a second expiry.
        await store.send(.goalReceived(context: context, token: 1, date: today, result: .success(baseline)))
    }

    func testDirtyDismissalRequiresExplicitDiscardConfirmation() async {
        let edited = texts(calories: "2075", fat: "75")
        let store = makeStore(state: loadedGoalState(texts: edited))

        await store.send(.requestDismiss) {
            $0.confirmation = .discardPrompt
        }
        await store.send(.cancelDiscard) {
            $0.confirmation = .none
        }
        await store.send(.requestDismiss) {
            $0.confirmation = .discardPrompt
        }
        await store.send(.confirmDiscard) {
            $0.confirmation = .discardConfirmed
        }
        await store.receive(.delegate(.dismiss(settingsID: settingsID)))
    }

    func testAccountSettingsIsDelegatedNotCreatedLocally() async {
        let store = makeStore(state: initialState())
        await store.send(.presentAccountSettings)
        await store.receive(.delegate(.openAccountSettings(settingsID: settingsID)))
        await store.send(.accountSettingsDismissed)
        await store.receive(.delegate(.accountSettingsDismissed(settingsID: settingsID)))
    }

    func testStaleAccountContextCannotClobberNewerGoalSave() async {
        let baseline = goalSnapshot()
        let authoritative = goalSnapshot(calories: 2075, protein: 150, carbs: 200, fat: 75)
        let edited = texts(calories: "2075", fat: "75")
        let foreign = SettingsFeature.RequestContext(
            accountID: "other-account",
            generation: generation,
            settingsID: settingsID
        )
        let gate = Gate()
        let store = makeStore(
            state: loadedGoalState(snapshot: baseline, texts: edited),
            saveGoal: { _, _ in
                await gate.wait()
                return authoritative
            }
        )

        await store.send(.saveGoals) {
            $0.goalSave = .saving
        }
        let staleSnapshot = goalSnapshot(calories: 1, protein: 1, carbs: 1, fat: 1)
        await store.send(.goalSaveReceived(context: foreign, token: 1, result: .success(staleSnapshot)))
        XCTAssertEqual(store.state.goalSave, .saving)
        XCTAssertEqual(store.state.goalPhase, .loaded(baseline))

        await gate.release()
        await store.receive(.goalSaveReceived(context: context, token: 1, result: .success(authoritative))) {
            $0.goalPhase = .loaded(authoritative)
            $0.goalTexts = self.texts(calories: "2075", fat: "75")
            $0.loadedGoalTexts = self.loadedBaseline(authoritative)
            $0.goalSave = .saved
            $0.goalDayReview = .none
        }
        await store.receive(.delegate(.goalSaved(
            settingsID: settingsID,
            generation: generation,
            targets: CalCoStoreMapping.diaryGoal(from: authoritative),
            effectiveDate: today
        )))
    }

    func testStaleOwnerContextCannotApplyPreferencesSave() async {
        let original = DiaryPreferences(enabledSlots: allSlots())
        let selected = allSlots().subtracting([.snack])
        let authoritative = DiaryPreferences(enabledSlots: selected)
        let foreign = SettingsFeature.RequestContext(
            accountID: accountID,
            generation: generation,
            settingsID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let foreignPrefs = DiaryPreferences(enabledSlots: [.breakfast])
        var state = initialState()
        state.prefsPhase = .loaded(original)
        state.selectedSlots = selected

        let gate = Gate()
        let store = makeStore(state: state, updatePreferences: { _, _ in
            await gate.wait()
            return authoritative
        })
        await store.send(.savePreferences) {
            $0.prefsSave = .saving
        }
        await store.send(.prefsSaveReceived(context: foreign, token: 1, result: .success(foreignPrefs)))
        XCTAssertEqual(store.state.prefsSave, .saving)
        XCTAssertEqual(store.state.selectedSlots, selected)

        await gate.release()
        await store.receive(.prefsSaveReceived(context: context, token: 1, result: .success(authoritative))) {
            $0.prefsPhase = .loaded(authoritative)
            $0.selectedSlots = selected
            $0.prefsSave = .saved
        }
        await store.receive(.delegate(.preferencesSaved(
            settingsID: settingsID,
            generation: generation,
            prefs: CalCoStoreMapping.diaryPrefs(from: authoritative)
        )))
    }

    func testLiveClientRejectsStaleGenerationBeforeTransport() async {
        let flag = Flag()
        let acceptedGeneration = generation + 1
        let service = ProbeService { await flag.mark() }
        let live = SettingsFeature.Client.live(
            service: service,
            isCurrent: { $0.generation == acceptedGeneration }
        )
        let edited = texts(calories: "2075", fat: "75")
        let message = String(localized: "diary.error.sessionExpired")

        let store = TestStore(initialState: loadedGoalState(texts: edited)) {
            SettingsFeature()
        } withDependencies: {
            $0.diarySettingsClient = live
        }

        await store.send(.saveGoals) {
            $0.goalSave = .saving
        }
        await store.receive(.goalSaveReceived(context: context, token: 1, result: .failure(.unauthorized))) {
            $0.goalSave = .failed(message)
            $0.goalPhase = .failed(message)
            $0.prefsPhase = .failed(message)
            $0.lifecycle = .expired
        }
        await store.receive(.delegate(.sessionExpired(settingsID: settingsID, generation: generation)))
        let reachedTransport = await flag.value
        XCTAssertFalse(reachedTransport, "Stale generation must be rejected before PUT")
    }

    // MARK: - Helpers

    private actor Flag {
        private var marked = false
        func mark() { marked = true }
        var value: Bool { marked }
    }

    private struct ProbeService: DiarySettingsServicing {
        let mark: @Sendable () async -> Void

        func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
            await mark()
            throw DiarySettingsServiceError.unknown
        }
        func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot {
            await mark()
            throw DiarySettingsServiceError.unknown
        }
        func fetchDiaryPreferences() async throws -> DiaryPreferences {
            await mark()
            throw DiarySettingsServiceError.unknown
        }
        func updateDiaryPreferences(_ preferences: DiaryPreferences) async throws -> DiaryPreferences {
            await mark()
            throw DiarySettingsServiceError.unknown
        }
    }

    private actor Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor SaveCapture {
        private var request: SaveGoalRequest?
        private var recorded = false
        private var continuation: CheckedContinuation<Void, Never>?

        func record(_ request: SaveGoalRequest) {
            self.request = request
            recorded = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            if recorded { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func snapshot() -> SaveGoalRequest? { request }
    }

    private actor PrefsCapture {
        private var request: DiaryPreferences?
        private var recorded = false
        private var continuation: CheckedContinuation<Void, Never>?

        func record(_ request: DiaryPreferences) {
            self.request = request
            recorded = true
            continuation?.resume()
            continuation = nil
        }

        func wait() async {
            if recorded { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func snapshot() -> DiaryPreferences? { request }
    }
}
