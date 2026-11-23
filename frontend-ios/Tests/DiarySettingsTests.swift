import XCTest

@testable import CalCo

private actor FakeSettingsService: DiarySettingsServicing {
    private var goal: GoalSnapshot
    private var preferences: DiaryPreferences
    private var goalLoadError: DiarySettingsServiceError?
    private var preferencesLoadError: DiarySettingsServiceError?
    private var goalSaveErrors: [DiarySettingsServiceError?] = []
    private var preferencesSaveErrors: [DiarySettingsServiceError?] = []
    private var goalDates: [LocalDiaryDate] = []
    private var goalSaveRequests: [SaveGoalRequest] = []
    private var preferenceSaveRequests: [DiaryPreferences] = []
    private var heldGoalFetches = 0
    private var goalFetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdGoalSave = false
    private var goalSaveStarted = false
    private var goalSaveContinuation: CheckedContinuation<Void, Never>?
    private var holdPreferencesSave = false
    private var preferencesSaveStarted = false
    private var preferencesSaveContinuation: CheckedContinuation<Void, Never>?

    init(goal: GoalSnapshot, preferences: DiaryPreferences) {
        self.goal = goal
        self.preferences = preferences
    }

    func setGoal(_ goal: GoalSnapshot) { self.goal = goal }
    func setPreferences(_ preferences: DiaryPreferences) { self.preferences = preferences }
    func setGoalLoadError(_ error: DiarySettingsServiceError?) { goalLoadError = error }
    func setPreferencesLoadError(_ error: DiarySettingsServiceError?) {
        preferencesLoadError = error
    }
    func setGoalSaveErrors(_ errors: [DiarySettingsServiceError?]) {
        goalSaveErrors = errors
    }
    func setPreferencesSaveErrors(_ errors: [DiarySettingsServiceError?]) {
        preferencesSaveErrors = errors
    }
    func holdNextGoalFetch() { heldGoalFetches += 1 }
    func holdNextGoalSave() {
        holdGoalSave = true
        goalSaveStarted = false
    }
    func holdNextPreferencesSave() {
        holdPreferencesSave = true
        preferencesSaveStarted = false
    }
    func goalFetchCalls() -> [LocalDiaryDate] { goalDates }
    func savedGoalRequests() -> [SaveGoalRequest] { goalSaveRequests }
    func savedPreferenceRequests() -> [DiaryPreferences] { preferenceSaveRequests }

    func waitForGoalFetch(_ index: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while goalDates.count < index, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(goalDates.count, index)
    }

    func waitForGoalSaveStart() async {
        let deadline = Date().addingTimeInterval(5)
        while !goalSaveStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(goalSaveStarted, "Timed out waiting for the goal save")
    }

    func releaseGoalSave() {
        goalSaveContinuation?.resume()
        goalSaveContinuation = nil
    }

    func waitForPreferencesSaveStart() async {
        let deadline = Date().addingTimeInterval(5)
        while !preferencesSaveStarted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(preferencesSaveStarted, "Timed out waiting for the preferences save")
    }

    func releasePreferencesSave() {
        preferencesSaveContinuation?.resume()
        preferencesSaveContinuation = nil
    }

    func releaseHeldGoalFetches() {
        let waiters = goalFetchWaiters
        goalFetchWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func fetchGoal(on date: LocalDiaryDate) async throws -> GoalSnapshot {
        goalDates.append(date)
        if heldGoalFetches > 0 {
            heldGoalFetches -= 1
            await withCheckedContinuation { continuation in
                goalFetchWaiters.append(continuation)
            }
        }
        if let goalLoadError { throw goalLoadError }
        return GoalSnapshot(
            requestedDate: date,
            effectiveFrom: goal.effectiveFrom,
            source: goal.source,
            targets: goal.targets
        )
    }

    func saveGoal(_ request: SaveGoalRequest) async throws -> GoalSnapshot {
        goalSaveRequests.append(request)
        if holdGoalSave {
            holdGoalSave = false
            goalSaveStarted = true
            await withCheckedContinuation { continuation in
                goalSaveContinuation = continuation
            }
        }
        let error = goalSaveErrors.isEmpty ? nil : goalSaveErrors.removeFirst()
        if let error { throw error }
        let saved = GoalSnapshot(
            requestedDate: request.localDate,
            effectiveFrom: request.localDate,
            source: .saved,
            targets: request.targets
        )
        goal = saved
        return saved
    }

    func fetchDiaryPreferences() async throws -> DiaryPreferences {
        if let preferencesLoadError { throw preferencesLoadError }
        return preferences
    }

    func updateDiaryPreferences(_ preferences: DiaryPreferences) async throws -> DiaryPreferences {
        preferenceSaveRequests.append(preferences)
        if holdPreferencesSave {
            holdPreferencesSave = false
            preferencesSaveStarted = true
            await withCheckedContinuation { continuation in
                preferencesSaveContinuation = continuation
            }
        }
        let error = preferencesSaveErrors.isEmpty ? nil : preferencesSaveErrors.removeFirst()
        if let error { throw error }
        self.preferences = preferences
        return preferences
    }
}

@MainActor
final class DiarySettingsTests: XCTestCase {
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let tomorrow = LocalDiaryDate(year: 2026, month: 11, day: 18)

    private func goal(
        source: GoalSource = .saved,
        effectiveFrom: LocalDiaryDate? = LocalDiaryDate(year: 2026, month: 11, day: 1),
        calories: Double = 2_140,
        protein: Double = 160,
        carbs: Double = 240,
        fat: Double = 60
    ) -> GoalSnapshot {
        GoalSnapshot(
            requestedDate: today,
            effectiveFrom: effectiveFrom,
            source: source,
            targets: GoalTargets(
                calorieTarget: calories,
                proteinTargetG: protein,
                carbsTargetG: carbs,
                fatTargetG: fat
            )
        )
    }

    private func makeViewModel(
        service: FakeSettingsService,
        todayProvider: @escaping () -> LocalDiaryDate = { LocalDiaryDate(year: 2026, month: 11, day: 17) },
        timeZone: String = "Asia/Kolkata",
        locale: Locale = Locale(identifier: "en_US")
    ) -> DiarySettingsViewModel {
        DiarySettingsViewModel(
            service: service,
            accountID: "account-a",
            todayProvider: todayProvider,
            timeZoneProvider: { timeZone },
            locale: locale
        )
    }

    func testLoadUsesSettingsOwnTodayGoalAndCanonicalPreferences() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledMealSlots: [.dinner, .breakfast])
        )
        let viewModel = makeViewModel(service: service)

        await viewModel.load()

        let goalDates = await service.goalFetchCalls()
        XCTAssertEqual(goalDates, [today])
        XCTAssertEqual(viewModel.calorieTarget, "2140")
        XCTAssertEqual(viewModel.proteinTargetG, "160")
        XCTAssertEqual(viewModel.carbsTargetG, "240")
        XCTAssertEqual(viewModel.fatTargetG, "60")
        XCTAssertEqual(viewModel.selectedSlots, [.breakfast, .dinner])
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertEqual(
            viewModel.goalStatusMessage,
            String(
                format: String(localized: "settings.goals.status.savedFrom"),
                LocalDiaryDate(year: 2026, month: 11, day: 1).formatted
            )
        )
    }

    func testOneSectionFailureDoesNotBlockTheOtherAndCanRetry() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.setGoalLoadError(.networkUnavailable)
        let viewModel = makeViewModel(service: service)

        await viewModel.load()

        XCTAssertNotNil(viewModel.goalState.failureMessage)
        XCTAssertEqual(viewModel.selectedSlots, [.lunch])
        XCTAssertEqual(viewModel.goalValidationMessage, nil)

        await service.setGoalLoadError(nil)
        await viewModel.retryGoals()

        XCTAssertEqual(viewModel.goalState.loadedSnapshot?.targets.calorieTarget, 2_140)
        XCTAssertEqual(viewModel.selectedSlots, [.lunch])
    }

    func testPreferencesFailureDoesNotBlockGoalSection() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.setPreferencesLoadError(.networkUnavailable)
        let viewModel = makeViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.goalState.loadedSnapshot?.targets.calorieTarget, 2_140)
        XCTAssertEqual(viewModel.calorieTarget, "2140")
        XCTAssertNotNil(viewModel.preferencesState.failureMessage)
    }

    func testGoalValidationUsesExactDecimalFormulaAndRejectsMalformedInput() {
        XCTAssertNoThrow(
            try DiaryGoalForm.validate(
                calories: "2140",
                protein: "160",
                carbs: "240",
                fat: "60"
            ).get()
        )
        XCTAssertEqual(
            failure(DiaryGoalForm.validate(
                calories: "2141",
                protein: "160",
                carbs: "240",
                fat: "60"
            )),
            .formulaMismatch
        )
        XCTAssertEqual(
            failure(DiaryGoalForm.validate(
                calories: "0",
                protein: "0",
                carbs: "0",
                fat: "0"
            )),
            .caloriesNotPositive
        )
        XCTAssertEqual(
            failure(DiaryGoalForm.validate(
                calories: "4",
                protein: "-1",
                carbs: "0",
                fat: "0"
            )),
            .macrosNegative
        )
        for raw in [
            "NaN",
            "Infinity",
            "1e3",
            "1,000",
            "1.2.3",
            " 2 100 ",
            "1.234567",
            "1000000001",
            "1-2",
            "--5",
            "+1-",
            "1.",
        ] {
            XCTAssertEqual(
                failure(DiaryGoalForm.validate(
                    calories: raw,
                    protein: "0",
                    carbs: "0",
                    fat: "0"
                )),
                .invalidNumbers,
                "Expected \(raw) to be rejected"
            )
        }
        XCTAssertEqual(
            DiaryGoalForm.decimal("1.600", locale: Locale(identifier: "de_DE")) == nil,
            true,
            "Grouping separators must not be truncated"
        )
        XCTAssertEqual(DiaryGoalForm.decimal("1,5", locale: Locale(identifier: "de_DE")), Decimal(string: "1.5"))
    }

    func testScaleFiveGermanRoundTripSendsExactDecimalBody() async throws {
        let snapshot = try JSONDecoder().decode(
            GoalSnapshot.self,
            from: Data(
                """
                {
                  "requested_date": "2026-11-17",
                  "effective_from": "2026-11-01",
                  "source": "saved",
                  "calorie_target": "2102.66673",
                  "protein_target_g": "150.12345",
                  "carbs_target_g": "240.54321",
                  "fat_target_g": "60.00001"
                }
                """.utf8
            )
        )
        let service = FakeSettingsService(
            goal: snapshot,
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(
            service: service,
            locale: Locale(identifier: "de_DE")
        )
        await viewModel.load()

        XCTAssertEqual(viewModel.calorieTarget, "2102,66673")
        XCTAssertEqual(viewModel.proteinTargetG, "150,12345")
        XCTAssertEqual(viewModel.carbsTargetG, "240,54321")
        XCTAssertEqual(viewModel.fatTargetG, "60,00001")
        XCTAssertNil(viewModel.goalValidationMessage)
        XCTAssertTrue(viewModel.canEditGoalFields)

        viewModel.fatTargetG = "60,00002"
        viewModel.calorieTarget = "2102,66682"
        await viewModel.saveGoals()

        XCTAssertEqual(viewModel.goalSaveState, .saved)
        let requests = await service.savedGoalRequests()
        let request = try XCTUnwrap(requests.first)
        let requestExact = try XCTUnwrap(request.exactTargets)
        XCTAssertEqual(requestExact.calorieTarget, Decimal(string: "2102.66682")!)
        XCTAssertEqual(requestExact.fatTargetG, Decimal(string: "60.00002")!)
        let data = try JSONEncoder().encode(request)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"calorie_target\":2102.66682"))
        XCTAssertTrue(raw.contains("\"fat_target_g\":60.00002"))
    }

    func testHugeOrNonFiniteGoalValuesNeverCrashFormatter() {
        XCTAssertEqual(DiaryGoalForm.text(for: .infinity), "")
        XCTAssertEqual(DiaryGoalForm.text(for: .nan), "")
        _ = DiaryGoalForm.text(for: .greatestFiniteMagnitude)
        XCTAssertFalse(DiaryGoalForm.isSupported(.greatestFiniteMagnitude))
        XCTAssertTrue(DiaryGoalForm.isSupported(1_000_001))
        XCTAssertEqual(DiaryGoalForm.decimal("+5"), Decimal(5))
        XCTAssertEqual(DiaryGoalForm.decimal("-5"), Decimal(-5))
        XCTAssertNil(DiaryGoalForm.decimal("1-2"))
        XCTAssertNil(DiaryGoalForm.decimal("--5"))
    }

    func testNonLatinDigitLocalesRoundTripThroughGoalFormatterAndParser() {
        for identifier in ["ar_SA", "fa_IR"] {
            let locale = Locale(identifier: identifier)
            let expected = Decimal(string: "2102.66673")!
            let text = DiaryGoalForm.text(for: 2_102.66673, locale: locale)
            XCTAssertEqual(
                DiaryGoalForm.decimal(text, locale: locale),
                expected,
                "\(identifier) formatted text did not parse back exactly: \(text)"
            )
        }
    }

    func testNonLatinDigitLocaleLoadHasNoValidationResidual() async {
        let locale = Locale(identifier: "ar_SA")
        let targets = GoalTargetsDecimal(
            calorieTarget: Decimal(string: "2102.66673")!,
            proteinTargetG: Decimal(string: "150.12345")!,
            carbsTargetG: Decimal(string: "240.54321")!,
            fatTargetG: Decimal(string: "60.00001")!
        ).doubleTargets
        let service = FakeSettingsService(
            goal: goal(
                calories: targets.calorieTarget,
                protein: targets.proteinTargetG,
                carbs: targets.carbsTargetG,
                fat: targets.fatTargetG
            ),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(service: service, locale: locale)
        await viewModel.load()

        XCTAssertNil(viewModel.goalValidationMessage)
        XCTAssertTrue(viewModel.canEditGoalFields)
    }

    func testGoalSaveUsesTodayAndTimezoneAtTapAndDoesNotTouchPreferences() async {
        var currentToday = today
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(
            service: service,
            todayProvider: { currentToday },
            timeZone: "Asia/Kolkata"
        )
        await viewModel.load()
        viewModel.calorieTarget = "2150"
        viewModel.proteinTargetG = "170"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"
        currentToday = tomorrow

        await viewModel.saveGoals()

        let requestsAfterChange = await service.savedGoalRequests()
        XCTAssertEqual(requestsAfterChange.count, 0, "Midnight must not retarget the old form")
        let goalFetchDates = await service.goalFetchCalls()
        XCTAssertEqual(goalFetchDates.last, tomorrow)
        XCTAssertEqual(
            viewModel.goalSaveState.errorMessage,
            String(localized: "settings.goals.error.dayChanged")
        )
        XCTAssertEqual(viewModel.calorieTarget, "2150")
        XCTAssertEqual(viewModel.proteinTargetG, "170")
        XCTAssertTrue(viewModel.hasUnsavedGoalChanges)
        XCTAssertTrue(viewModel.goalNeedsDayReview)
        XCTAssertFalse(viewModel.canSaveGoals)

        await viewModel.saveGoals()
        let stillBlocked = await service.savedGoalRequests()
        XCTAssertTrue(stillBlocked.isEmpty, "A day review must gate the PUT")

        await viewModel.reviewNewDayGoal()
        XCTAssertFalse(viewModel.goalNeedsDayReview)
        XCTAssertEqual(viewModel.calorieTarget, "2150")
        XCTAssertTrue(viewModel.canSaveGoals)

        await viewModel.saveGoals()

        let requests = await service.savedGoalRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.localDate, tomorrow)
        XCTAssertEqual(requests.first?.deviceTimeZone, "Asia/Kolkata")
        XCTAssertEqual(requests.first?.targets.calorieTarget, 2_150)
        XCTAssertEqual(viewModel.goalSaveState, .saved)
        let preferenceRequests = await service.savedPreferenceRequests()
        XCTAssertEqual(preferenceRequests.count, 0)
    }

    func testGoalSaveDoubleTapSubmitsOnce() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.calorieTarget = "2150"
        viewModel.proteinTargetG = "170"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"
        await service.holdNextGoalSave()

        let first = Task { await viewModel.saveGoals() }
        await service.waitForGoalSaveStart()
        XCTAssertTrue(viewModel.goalSaveState.isSaving)
        XCTAssertFalse(viewModel.canEditForm)
        XCTAssertFalse(viewModel.requestDismissal(), "A busy save must keep the sheet open")
        await viewModel.saveGoals()
        await service.releaseGoalSave()
        await first.value

        let requests = await service.savedGoalRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(viewModel.goalSaveState, .saved)
    }

    func testAmbiguousGoalSaveReconcilesBeforeChangedPayloadCanBeSavedAgain() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.setGoalSaveErrors([.networkUnavailable])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.calorieTarget = "2150"
        viewModel.proteinTargetG = "170"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"

        await viewModel.saveGoals()

        XCTAssertFalse(viewModel.goalNeedsReconciliation)
        XCTAssertNotNil(viewModel.goalSaveState.errorMessage)
        XCTAssertEqual(viewModel.calorieTarget, "2150")
        XCTAssertTrue(viewModel.canSaveGoals, "A reconciled old server value may be saved again explicitly")

        await viewModel.saveGoals()
        let requests = await service.savedGoalRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(viewModel.goalSaveState, .saved)
    }

    func testHeldGoalReconciliationDisablesFieldsAndDismissal() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.setGoalSaveErrors([.networkUnavailable])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        await service.holdNextGoalFetch()
        viewModel.calorieTarget = "2150"
        viewModel.proteinTargetG = "170"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"

        let save = Task { await viewModel.saveGoals() }
        await service.waitForGoalFetch(2)
        XCTAssertTrue(viewModel.isSaving)
        XCTAssertFalse(viewModel.canEditGoalFields)
        XCTAssertFalse(viewModel.canEditForm)
        XCTAssertFalse(viewModel.requestDismissal())
        XCTAssertTrue(viewModel.goalNeedsReconciliation)

        await service.releaseHeldGoalFetches()
        await save.value
        XCTAssertFalse(viewModel.isSaving)
        XCTAssertFalse(viewModel.goalNeedsReconciliation)
        XCTAssertTrue(viewModel.canEditGoalFields)
        XCTAssertEqual(viewModel.calorieTarget, "2150")
    }

    func testUnsupportedServerPrecisionBlocksSaveUntilEveryFieldIsCorrected() async {
        let exact = GoalTargetsDecimal(
            calorieTarget: Decimal(string: "2102.666709")!,
            proteinTargetG: Decimal(string: "150.123456")!,
            carbsTargetG: Decimal(string: "240.543219")!,
            fatTargetG: Decimal(string: "60.000001")!
        )
        let snapshot = GoalSnapshot(
            requestedDate: today,
            effectiveFrom: today,
            source: .saved,
            targets: exact.doubleTargets,
            exactTargets: exact
        )
        let service = FakeSettingsService(
            goal: snapshot,
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        XCTAssertEqual(viewModel.calorieTarget, "2102.666709")
        XCTAssertEqual(viewModel.fatTargetG, "60.000001")
        XCTAssertNotNil(viewModel.goalUnsupportedMessage)
        XCTAssertFalse(viewModel.canSaveGoals)

        // An unrelated edit must not bypass the unsupported fields.
        viewModel.proteinTargetG = "151"
        await viewModel.saveGoals()
        let blocked = await service.savedGoalRequests()
        XCTAssertTrue(blocked.isEmpty)
        XCTAssertNotNil(viewModel.goalUnsupportedMessage)

        viewModel.calorieTarget = "2140"
        viewModel.proteinTargetG = "160"
        viewModel.carbsTargetG = "240"
        viewModel.fatTargetG = "60"
        XCTAssertNil(viewModel.goalUnsupportedMessage)
        XCTAssertTrue(viewModel.canSaveGoals)
        await viewModel.saveGoals()
        let saved = await service.savedGoalRequests()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(viewModel.goalSaveState, .saved)
    }

    func testTinyUnsupportedDecimalIsFlaggedRatherThanRoundedToZero() {
        let text = DiaryGoalForm.text(for: 0.00000001)
        XCTAssertTrue(text.contains("0.00000001"), text)
        XCTAssertFalse(DiaryGoalForm.isSupported(0.00000001))
    }

    func testGoalAndPreferenceSavesCannotOverlap() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.calorieTarget = "2150"
        viewModel.proteinTargetG = "170"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"

        await service.holdNextGoalSave()
        let goalSave = Task { await viewModel.saveGoals() }
        await service.waitForGoalSaveStart()

        viewModel.toggleSlot(.breakfast, enabled: true)
        await viewModel.savePreferences()
        let preferencesDuringGoal = await service.savedPreferenceRequests()
        XCTAssertTrue(preferencesDuringGoal.isEmpty)

        await service.releaseGoalSave()
        await goalSave.value
        XCTAssertEqual(viewModel.goalSaveState, .saved)

        viewModel.toggleSlot(.dinner, enabled: true)
        await service.holdNextPreferencesSave()
        let preferenceSave = Task { await viewModel.savePreferences() }
        await service.waitForPreferencesSaveStart()

        viewModel.calorieTarget = "2170"
        viewModel.proteinTargetG = "175"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"
        await viewModel.saveGoals()
        let goalRequests = await service.savedGoalRequests()
        XCTAssertEqual(goalRequests.count, 1)

        await service.releasePreferencesSave()
        await preferenceSave.value
        XCTAssertEqual(viewModel.preferencesSaveState, .saved)
    }

    func testManualGoalCheckPublishesMatchingSavedStateAndKeepsDraftWhenNotApplied() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.setGoalSaveErrors([.networkUnavailable])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        await service.setGoalLoadError(.networkUnavailable)
        viewModel.calorieTarget = "2150"
        viewModel.proteinTargetG = "170"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"

        await viewModel.saveGoals()
        XCTAssertTrue(viewModel.goalNeedsReconciliation)
        XCTAssertEqual(viewModel.calorieTarget, "2150")
        XCTAssertFalse(viewModel.canSaveGoals)

        await service.setGoalLoadError(nil)
        await service.setGoal(goal(
            calories: 2_150,
            protein: 170,
            carbs: 210,
            fat: 70
        ))
        var savedCallbacks = 0
        viewModel.onGoalSaved = { _ in savedCallbacks += 1 }

        await viewModel.checkSavedGoal()

        XCTAssertEqual(savedCallbacks, 1)
        XCTAssertFalse(viewModel.goalNeedsReconciliation)
        XCTAssertEqual(viewModel.goalSaveState, .saved)
        XCTAssertEqual(viewModel.calorieTarget, "2150")

        // A second ambiguous check that did not apply must keep the draft and
        // its warning rather than replacing the form with a generic reload.
        await service.setGoalSaveErrors([.networkUnavailable])
        await service.setGoalLoadError(.networkUnavailable)
        viewModel.calorieTarget = "2170"
        viewModel.proteinTargetG = "175"
        viewModel.carbsTargetG = "210"
        viewModel.fatTargetG = "70"
        await viewModel.saveGoals()
        XCTAssertTrue(viewModel.goalNeedsReconciliation)
        await service.setGoalLoadError(nil)
        await service.setGoal(goal())
        await viewModel.checkSavedGoal()
        XCTAssertEqual(viewModel.calorieTarget, "2170")
        XCTAssertNotNil(viewModel.goalSaveState.errorMessage)
        XCTAssertTrue(viewModel.canSaveGoals)
    }

    func testManualPreferenceCheckPublishesMatchingSavedState() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.breakfast, .lunch])
        )
        await service.setPreferencesSaveErrors([.networkUnavailable])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        await service.setPreferencesLoadError(.networkUnavailable)
        viewModel.toggleSlot(.breakfast, enabled: false)

        await viewModel.savePreferences()
        XCTAssertTrue(viewModel.preferencesNeedsReconciliation)
        XCTAssertEqual(viewModel.selectedSlots, [.lunch])

        await service.setPreferencesLoadError(nil)
        await service.setPreferences(DiaryPreferences(enabledSlots: [.lunch]))
        var savedCallbacks = 0
        viewModel.onPreferencesSaved = { _ in savedCallbacks += 1 }

        await viewModel.checkSavedPreferences()

        XCTAssertEqual(savedCallbacks, 1)
        XCTAssertFalse(viewModel.preferencesNeedsReconciliation)
        XCTAssertEqual(viewModel.preferencesSaveState, .saved)
        XCTAssertEqual(viewModel.selectedSlots, [.lunch])
    }

    func testPristineSectionSavesDoNotSendRequests() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        await viewModel.saveGoals()
        await viewModel.savePreferences()

        let goalRequests = await service.savedGoalRequests()
        let preferenceRequests = await service.savedPreferenceRequests()
        XCTAssertTrue(goalRequests.isEmpty)
        XCTAssertTrue(preferenceRequests.isEmpty)
    }

    func testReconciliationUnauthorizedExpiresSessionForBothSections() async {
        for section in ["goal", "preferences"] {
            let service = FakeSettingsService(
                goal: goal(),
                preferences: DiaryPreferences(enabledSlots: [.lunch])
            )
            var expired = 0
            let viewModel = makeViewModel(service: service)
            viewModel.onSessionExpired = { expired += 1 }
            await viewModel.load()
            if section == "goal" {
                await service.setGoalSaveErrors([.networkUnavailable])
                await service.setGoalLoadError(.unauthorized)
                viewModel.calorieTarget = "2150"
                viewModel.proteinTargetG = "170"
                viewModel.carbsTargetG = "210"
                viewModel.fatTargetG = "70"
                await viewModel.saveGoals()
            } else {
                await service.setPreferencesSaveErrors([.networkUnavailable])
                await service.setPreferencesLoadError(.unauthorized)
                viewModel.toggleSlot(.breakfast, enabled: true)
                await viewModel.savePreferences()
            }
            XCTAssertEqual(expired, 1, "\(section) reconciliation should expire the session")
        }
    }

    func testAmbiguousPreferencesSaveReconcilesBeforeChangedPayloadCanBeSavedAgain() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.breakfast, .lunch])
        )
        await service.setPreferencesSaveErrors([.networkUnavailable])
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.toggleSlot(.breakfast, enabled: false)

        await viewModel.savePreferences()

        XCTAssertFalse(viewModel.preferencesNeedsReconciliation)
        XCTAssertNotNil(viewModel.preferencesSaveState.errorMessage)
        XCTAssertEqual(viewModel.selectedSlots, [.lunch])
        XCTAssertTrue(viewModel.canSavePreferences)

        await viewModel.savePreferences()
        let requests = await service.savedPreferenceRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(viewModel.preferencesSaveState, .saved)
    }

    func testPreferencesRequireAtLeastOneSlotAndSaveCanonicalOrder() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledMealSlots: [.dinner, .breakfast])
        )
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        for slot in MealSlot.allCases {
            viewModel.toggleSlot(slot, enabled: false)
        }

        await viewModel.savePreferences()
        XCTAssertEqual(
            viewModel.preferencesSaveState,
            .failed(String(localized: "settings.slots.error.empty"))
        )
        let emptyRequests = await service.savedPreferenceRequests()
        XCTAssertEqual(emptyRequests.count, 0)

        viewModel.toggleSlot(.dinner, enabled: true)
        viewModel.toggleSlot(.lunch, enabled: true)
        await viewModel.savePreferences()

        let requests = await service.savedPreferenceRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.enabledMealSlots, [.lunch, .dinner])
        XCTAssertEqual(viewModel.preferencesSaveState, .saved)
    }

    func testStaleGoalLoadCannotOverwriteNewerSelection() async {
        let service = FakeSettingsService(
            goal: goal(calories: 2_000, protein: 150, carbs: 230, fat: 60),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.holdNextGoalFetch()
        let viewModel = makeViewModel(service: service)

        let firstLoad = Task { await viewModel.load() }
        await service.waitForGoalFetch(1)
        await service.setGoal(goal(calories: 2_200, protein: 160, carbs: 240, fat: 60))
        let forcedRetry = Task { await viewModel.retryGoals() }
        await forcedRetry.value
        await service.releaseHeldGoalFetches()
        await firstLoad.value

        XCTAssertEqual(viewModel.calorieTarget, "2200")
        XCTAssertFalse(viewModel.hasUnsavedGoalChanges)
    }

    func testGoalLoadCompletionAcrossMidnightRefetchesNewDay() async {
        var currentToday = today
        let service = FakeSettingsService(
            goal: goal(calories: 2_100, protein: 150, carbs: 240, fat: 60),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        await service.holdNextGoalFetch()
        let viewModel = makeViewModel(
            service: service,
            todayProvider: { currentToday }
        )

        let load = Task { await viewModel.load() }
        await service.waitForGoalFetch(1)
        await service.setGoal(goal(calories: 2_200, protein: 160, carbs: 240, fat: 60))
        currentToday = tomorrow
        await service.releaseHeldGoalFetches()
        await load.value

        await service.waitForGoalFetch(2)
        for _ in 0..<100 where viewModel.calorieTarget != "2200" {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(viewModel.calorieTarget, "2200")
        let fetchDates = await service.goalFetchCalls()
        XCTAssertEqual(fetchDates.last, tomorrow)
    }

    func testDirtyDismissalRequiresExplicitDiscard() async {
        let service = FakeSettingsService(
            goal: goal(),
            preferences: DiaryPreferences(enabledSlots: [.lunch])
        )
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        XCTAssertTrue(viewModel.requestDismissal())
        viewModel.calorieTarget = "2150"
        XCTAssertFalse(viewModel.requestDismissal())
        XCTAssertTrue(viewModel.isDiscardConfirmationPresented)

        viewModel.cancelDiscard()
        XCTAssertFalse(viewModel.requestDismissal())
        viewModel.confirmDiscard()
        XCTAssertTrue(viewModel.requestDismissal())
    }

    private func failure(
        _ result: Result<GoalTargetsDecimal, DiaryGoalValidationError>
    ) -> DiaryGoalValidationError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

private extension DiaryGoalSettingsState {
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var loadedSnapshot: GoalSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

private extension DiaryPreferencesSettingsState {
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
