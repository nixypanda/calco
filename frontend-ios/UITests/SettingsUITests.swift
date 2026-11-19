import Foundation
import XCTest

// Credentialed settings journey against the isolated Test app. It uses only
// identifier-based locators and nonsecret fixture ids from the isolated seed.
// The historical date, goal scope, slot retention, discard behaviour and
// persistence assertions are all made through the rendered UI.
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var didReachDiary = false
    private var initialGoalFields: [String]?
    private var initialDinnerEnabled: Bool?

    private enum Identifier {
        static let settingsEntry = "diary.settings"
        static let sheet = "settings.sheet"
        static let close = "settings.cancel"
        static let discardConfirm = "settings.discard.confirm"
        static let discardCancel = "settings.discard.cancel"
        static let keyboardDone = "settings.keyboard.done"

        static let calories = "settings.goals.calories"
        static let protein = "settings.goals.protein"
        static let carbs = "settings.goals.carbs"
        static let fat = "settings.goals.fat"
        static let goalsSave = "settings.goals.save"
        static let goalsSaved = "settings.goals.saved"
        static let goalsStatus = "settings.goals.status"
        static let goalsValidation = "settings.goals.validationError"
        static let goalsReconcile = "settings.goals.reconcile"

        static let slotsSave = "settings.slots.save"
        static let slotsSaved = "settings.slots.saved"
        static let slotsError = "settings.slots.error"
        static let slotsValidation = "settings.slots.validationError"
        static let slotsReconcile = "settings.slots.reconcile"
        static let breakfast = "settings.slots.breakfast"
        static let lunch = "settings.slots.lunch"
        static let dinner = "settings.slots.dinner"
        static let snack = "settings.slots.snack"
        static let lateNightSnack = "settings.slots.late_night_snack"

        static let summary = "diary.summary.calories"
        static let previousDay = "diary.previousDay"
        static let nextDay = "diary.nextDay"
        static let fetchCompletionCount = "diary.fetchCompletionCount"

        // Nonsecret ids from the isolated seed report. A regenerated fixture
        // can override them through the UI-test runner environment.
        static var historicalBreakfastLog: String {
            "diary.log." + (
                ProcessInfo.processInfo.environment["CALCO_E2E_FIXTURE_BREAKFAST_LOG_ID"]
                    ?? "7162a79b-9843-45dd-bbc2-86898568bed5"
            )
        }

        static var historicalLateNightLog: String {
            "diary.log." + (
                ProcessInfo.processInfo.environment["CALCO_E2E_FIXTURE_LATE_NIGHT_LOG_ID"]
                    ?? "c0abfdab-f6ae-4260-8cf2-a9139acf4a33"
            )
        }
    }

    private enum Fixture {
        static var baselineGoal: [String] {
            goalValues("CALCO_E2E_FIXTURE_BASELINE_GOAL", fallback: "2140,160,240,60")
        }

        static var editedGoal: [String] {
            goalValues("CALCO_E2E_FIXTURE_EDITED_GOAL", fallback: "2180,160,250,60")
        }

        static var historicalCalories: String {
            environment("CALCO_E2E_FIXTURE_HISTORICAL_CALORIES", fallback: "1629")
        }

        static var historicalGoal: String {
            environment("CALCO_E2E_FIXTURE_HISTORICAL_GOAL", fallback: "2100")
        }

        static var editedGoalCalories: String { editedGoal.first ?? "" }
        static var baselineGoalCalories: String { baselineGoal.first ?? "" }

        static let todayEnvironmentKey = "CALCO_E2E_FIXTURE_TODAY"
        static let historicalDateEnvironmentKey = "CALCO_E2E_FIXTURE_HISTORICAL_DATE"
        static let defaultToday = "2026-11-19"
        static let defaultHistoricalDate = "2026-11-17"

        private static func environment(_ key: String, fallback: String) -> String {
            let value = ProcessInfo.processInfo.environment[key] ?? fallback
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func goalValues(_ key: String, fallback: String) -> [String] {
            environment(key, fallback: fallback)
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try CalCoE2E.makeApp()
    }

    override func tearDownWithError() throws {
        // continueAfterFailure=false still runs tearDown. Restore mutations
        // before releasing the app so a failed journey does not leave the
        // isolated account with edited goals or meal slots.
        if didReachDiary {
            restoreFixtureBestEffort()
        }
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testHistoricalDateRetentionGoalAndSlotSettings() throws {
        guard CalCoE2E.supportsSecurePasswordEntry else {
            throw XCTSkip(
                "Credentialed settings E2E requires the iOS Simulator secure paste path; "
                    + "macOS secure password entry is not supported by this harness."
            )
        }
        guard let credentials = CalCoE2E.credentials() else {
            throw XCTSkip("No private E2E credentials were supplied.")
        }

        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)
        try CalCoE2E.signIn(credentials, in: app)
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)

        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: 40) else {
            XCTFail("The diary did not load after sign-in.")
            return
        }
        didReachDiary = true
        CalCoE2E.dismissSavePasswordPrompt(in: app)
        XCTAssertTrue(waitForFetchCount(atLeast: 1), "Initial diary fetch was not observed.")

        guard let fixtureToday = configuredDay(
            Fixture.todayEnvironmentKey,
            fallback: Fixture.defaultToday
        ),
        let fixtureHistoricalDate = configuredDay(
            Fixture.historicalDateEnvironmentKey,
            fallback: Fixture.defaultHistoricalDate
        ),
        let daysBack = daysBetween(fixtureHistoricalDate, and: fixtureToday),
        (1...30).contains(daysBack) else {
            XCTFail(
                "Fixture dates are invalid. Set "
                    + "\(Fixture.todayEnvironmentKey) and "
                    + "\(Fixture.historicalDateEnvironmentKey) to ISO YYYY-MM-DD "
                    + "values with the historical date 1-30 days before today."
            )
            return
        }

        let baselineGoal = Fixture.baselineGoal
        let editedGoal = Fixture.editedGoal
        guard baselineGoal.count == 4,
              editedGoal.count == 4,
              baselineGoal != editedGoal,
              baselineGoal.allSatisfy({ !$0.isEmpty }),
              editedGoal.allSatisfy({ !$0.isEmpty }),
              !Fixture.historicalCalories.isEmpty,
              !Fixture.historicalGoal.isEmpty else {
            XCTFail(
                "Fixture goal/calorie prerequisites are invalid. Set "
                    + "CALCO_E2E_FIXTURE_BASELINE_GOAL and "
                    + "CALCO_E2E_FIXTURE_EDITED_GOAL as four comma-separated "
                    + "numbers, and set the historical summary values."
            )
            return
        }

        if ProcessInfo.processInfo.environment[Fixture.todayEnvironmentKey] == nil {
            guard hostDay() == fixtureToday else {
                XCTFail(
                    "The default fixture dates are only valid on 2026-11-19. "
                        + "Set \(Fixture.todayEnvironmentKey) and "
                        + "\(Fixture.historicalDateEnvironmentKey) for the current "
                        + "isolated seed, or regenerate the seed."
                )
                return
            }
        }

        navigateToHistoricalDate(daysBack: daysBack)
        scrollDiaryToTop()
        let historicalSummary = summaryText()
        XCTAssertTrue(
            historicalSummary?.contains(Fixture.historicalCalories) == true,
            "Expected historical calories in the summary, got: \(historicalSummary ?? "nil")"
        )
        XCTAssertTrue(
            historicalSummary?.contains(Fixture.historicalGoal) == true,
            "Expected the historical default goal, got: \(historicalSummary ?? "nil")"
        )
        XCTAssertTrue(
            scrollDiaryTo(Identifier.historicalBreakfastLog),
            "Fixture prerequisite failed: the historical log for "
                + "\(Fixture.historicalDateEnvironmentKey) was not reachable. "
                + "Verify the seed dates match the app's device-local today and "
                + "set/regenerate the fixture dates and log ids."
        )
        XCTAssertTrue(
            scrollDiaryTo(Identifier.historicalLateNightLog),
            "The retained late-night log was not visible while its slot is disabled."
        )
        scrollDiaryToTop()

        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        initialGoalFields = readGoalFields()
        initialDinnerEnabled = toggleIsOn(Identifier.dinner)
        XCTAssertEqual(initialGoalFields, Fixture.baselineGoal)
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.goalsStatus].exists,
            "Goal status/effective-date text is missing."
        )
        XCTAssertTrue(toggleIsOn(Identifier.breakfast))
        XCTAssertTrue(toggleIsOn(Identifier.lunch))
        XCTAssertTrue(toggleIsOn(Identifier.dinner))
        XCTAssertTrue(toggleIsOn(Identifier.snack))
        // The late-night slot is disabled but its historical log is retained
        // and must already be visible in the diary, not waiting for re-enable.
        XCTAssertFalse(toggleIsOn(Identifier.lateNightSnack))

        // Unsaved edits must not be written; cancellation returns to the draft,
        // and explicit discard closes without saving.
        setGoalFields(Fixture.editedGoal)
        tapSettingsClose()
        let discardCancel = alertButton(Identifier.discardCancel)
        XCTAssertTrue(
            discardCancel.waitForExistence(timeout: 10),
            "Closing a dirty settings sheet did not ask for discard confirmation."
        )
        discardCancel.tap()
        XCTAssertTrue(settingsSheetExists(), "Cancel in the discard alert closed the sheet.")
        XCTAssertEqual(fieldValue(Identifier.calories), Fixture.editedGoal[0])

        tapSettingsClose()
        let discardConfirm = alertButton(Identifier.discardConfirm)
        XCTAssertTrue(
            discardConfirm.waitForExistence(timeout: 10),
            "The second close did not present the discard confirmation."
        )
        discardConfirm.tap()
        XCTAssertTrue(waitForSettingsToClose(), "The settings sheet stayed open after discard.")

        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        assertGoalFields(Fixture.baselineGoal)

        // Disable a slot, persist it, reopen, then restore it. The historical
        // late-night log remains rendered because its slot still owns logs.
        setToggle(Identifier.dinner, on: false)
        tapSave(Identifier.slotsSave)
        XCTAssertTrue(
            waitForElement(Identifier.slotsSaved),
            "The meal-slot save did not report success."
        )
        tapSettingsClose()
        XCTAssertTrue(waitForSettingsToClose(), "Settings did not close after saving slots.")

        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        XCTAssertFalse(
            toggleIsOn(Identifier.dinner),
            "The disabled dinner slot did not persist after reopening settings."
        )
        setToggle(Identifier.dinner, on: true)
        tapSave(Identifier.slotsSave)
        XCTAssertTrue(
            waitForElement(Identifier.slotsSaved),
            "Restoring the dinner slot did not report success."
        )
        tapSettingsClose()
        XCTAssertTrue(waitForSettingsToClose(), "Settings did not close after restoring slots.")

        scrollDiaryToTop()
        if summaryText() == nil {
            print("DIARY_TREE_AFTER_SETTINGS\n\(app.debugDescription)")
        }
        XCTAssertEqual(summaryText(), historicalSummary)
        XCTAssertTrue(
            scrollDiaryTo(Identifier.historicalLateNightLog),
            "The late-night log disappeared while its disabled slot was retained."
        )
        scrollDiaryToTop()

        // Goals are always saved for device-local today even when the diary is
        // showing a historical date. The historical summary must not change.
        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        setGoalFields(Fixture.editedGoal)
        tapSave(Identifier.goalsSave)
        XCTAssertTrue(
            waitForElement(Identifier.goalsSaved),
            "The goal save did not report success."
        )
        tapSettingsClose()
        XCTAssertTrue(waitForSettingsToClose(), "Settings did not close after saving goals.")

        scrollDiaryToTop()
        XCTAssertEqual(summaryText(), historicalSummary)

        navigateToToday(daysForward: daysBack)
        scrollDiaryToTop()
        XCTAssertTrue(
            summaryText()?.contains(Fixture.editedGoalCalories) == true,
            "Today's diary did not show the newly saved goal."
        )

        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        setGoalFields(initialGoalFields ?? Fixture.baselineGoal)
        tapSave(Identifier.goalsSave)
        XCTAssertTrue(
            waitForElement(Identifier.goalsSaved),
            "Restoring the baseline goal did not report success."
        )
        tapSettingsClose()
        XCTAssertTrue(waitForSettingsToClose(), "Settings did not close after restoring goals.")

        scrollDiaryToTop()
        XCTAssertTrue(
            summaryText()?.contains(Fixture.baselineGoalCalories) == true,
            "Today's diary did not return to the baseline goal."
        )

        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        assertGoalFields(initialGoalFields ?? Fixture.baselineGoal)
        XCTAssertTrue(toggleIsOn(Identifier.dinner))
        XCTAssertFalse(toggleIsOn(Identifier.lateNightSnack))
    }

    // MARK: - Additional device checks

    /// iPad mini portrait is the compact shell; landscape crosses the 900 pt
    /// breakpoint. The settings sheet is owned by the signed-in root, so a
    /// dirty draft must survive both presenter-layout changes.
    func testDirtySettingsDraftSurvivesRotation() throws {
        guard try launchSignedInForSettings() else { return }
        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())
        setGoalFields(Fixture.editedGoal)
        let draftCalories = fieldValue(Identifier.calories)
        XCTAssertEqual(draftCalories, Fixture.editedGoal[0])

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitForSettingsLoaded(),
            "Settings did not survive rotation to landscape."
        )
        XCTAssertTrue(settingsSheetExists(), "The settings sheet disappeared in landscape.")
        XCTAssertEqual(
            fieldValue(Identifier.calories),
            draftCalories,
            "The dirty goal draft changed across rotation."
        )

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitForSettingsLoaded(),
            "Settings did not survive rotation back to portrait."
        )
        XCTAssertTrue(settingsSheetExists(), "The settings sheet disappeared in portrait.")
        XCTAssertEqual(
            fieldValue(Identifier.calories),
            draftCalories,
            "The dirty goal draft changed after rotating back."
        )

        tapSettingsClose()
        let discardConfirm = alertButton(Identifier.discardConfirm)
        XCTAssertTrue(
            discardConfirm.waitForExistence(timeout: 10),
            "The rotated dirty sheet did not present discard confirmation."
        )
        discardConfirm.tap()
        XCTAssertTrue(waitForSettingsToClose(), "The rotated settings sheet did not close.")
    }

    /// Run this method on iPhone with an accessibility content size. It does
    /// not save anything; it verifies the keyboard Done control and scrolling
    /// reachability of both action sections and all five toggles.
    func testAccessibilityKeyboardReachability() throws {
        guard try launchSignedInForSettings() else { return }
        openSettings()
        XCTAssertTrue(waitForSettingsLoaded())

        guard let calories = scrollSettingsTo(Identifier.calories) else {
            XCTFail("Accessibility-size goal field is not reachable.")
            return
        }
        calories.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 10),
            "The decimal keyboard did not appear at the accessibility content size."
        )
        let keyboardDone = app.buttons[Identifier.keyboardDone]
        XCTAssertTrue(
            keyboardDone.waitForExistence(timeout: 10),
            "settings.keyboard.done is missing at the accessibility content size."
        )
        keyboardDone.tap()
        _ = CalCoE2E.waitUntil(timeout: 5) { !self.app.keyboards.firstMatch.exists }

        XCTAssertNotNil(
            scrollSettingsTo(Identifier.goalsSave),
            "Save Goals is not reachable at the accessibility content size."
        )
        XCTAssertNotNil(
            scrollSettingsTo(Identifier.slotsSave),
            "Save Meal Slots is not reachable at the accessibility content size."
        )
        XCTAssertNotNil(
            scrollSettingsTo(Identifier.lateNightSnack),
            "The late-night toggle is not reachable at the accessibility content size."
        )

        tapSettingsClose()
        XCTAssertTrue(waitForSettingsToClose(), "Settings did not close after accessibility checks.")
    }

    private func launchSignedInForSettings() throws -> Bool {
        guard CalCoE2E.supportsSecurePasswordEntry else {
            throw XCTSkip(
                "Credentialed settings E2E requires the iOS Simulator secure paste path; "
                    + "macOS secure password entry is not supported by this harness."
            )
        }
        guard let credentials = CalCoE2E.credentials() else {
            throw XCTSkip("No private E2E credentials were supplied.")
        }
        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)
        try CalCoE2E.signIn(credentials, in: app)
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)
        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: 40) else {
            XCTFail("The diary did not load after sign-in.")
            return false
        }
        didReachDiary = true
        CalCoE2E.dismissSavePasswordPrompt(in: app)
        return true
    }

    // MARK: - Navigation and fixture dates

    private func configuredDay(_ key: String, fallback: String) -> DateComponents? {
        let raw = ProcessInfo.processInfo.environment[key] ?? fallback
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return DateComponents(year: year, month: month, day: day)
    }

    private func hostDay() -> DateComponents? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        return DateComponents(
            year: components.year,
            month: components.month,
            day: components.day
        )
    }

    private func daysBetween(_ earlier: DateComponents, and later: DateComponents) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let start = calendar.date(from: earlier),
              let end = calendar.date(from: later) else {
            return nil
        }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    private func navigateToHistoricalDate(daysBack: Int) {
        for _ in 0..<daysBack {
            let before = fetchCount() ?? 0
            guard tapToolbarAction(Identifier.previousDay) else {
                XCTFail("Previous Day is not reachable while navigating to the fixture date.")
                return
            }
            XCTAssertTrue(
                waitForFetchCount(greaterThan: before),
                "Previous Day did not complete a diary fetch."
            )
        }
    }

    private func navigateToToday(daysForward: Int) {
        for _ in 0..<daysForward {
            let before = fetchCount() ?? 0
            guard tapToolbarAction(Identifier.nextDay) else {
                XCTFail("Next Day is not reachable while returning to today.")
                return
            }
            XCTAssertTrue(
                waitForFetchCount(greaterThan: before),
                "Next Day did not complete a diary fetch."
            )
        }
    }

    // MARK: - Diary markers

    private func fetchCount() -> Int? {
        let marker = app.descendants(matching: .any)[Identifier.fetchCompletionCount]
        guard marker.exists else { return nil }
        let raw = (marker.value as? String) ?? marker.label
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForFetchCount(atLeast minimum: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: 40) {
            (self.fetchCount() ?? -1) >= minimum
        }
    }

    private func waitForFetchCount(greaterThan previous: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: 40) {
            (self.fetchCount() ?? -1) > previous
        }
    }

    private func summaryText() -> String? {
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.summary)
            .allElementsBoundByIndex
        let labels = summaries.map(\.label).filter { !$0.isEmpty }
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }

    private func diaryContainer() -> XCUIElement? {
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        return candidates.first { container in
            container.descendants(matching: .any)[Identifier.summary].exists
                || container.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "diary.log.")
                ).count > 0
        }
    }

    private func scrollDiaryToTop() {
        for _ in 0..<20 {
            if summaryText() != nil, summaryIsNearTop() {
                return
            }
            if let container = diaryContainer() {
                container.swipeDown()
            } else {
                // Sheet dismissal can temporarily remove the diary collection
                // view from the accessibility tree. Wait for it to return.
                _ = CalCoE2E.waitUntil(timeout: 1) {
                    self.diaryContainer() != nil
                }
            }
        }
    }

    private func summaryIsNearTop() -> Bool {
        // The identifier is on both the "Calories" label and its value, so a
        // singular XCUIElement query is ambiguous.
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.summary)
            .allElementsBoundByIndex
        return summaries.contains { summary in
            summary.exists
                && summary.frame.minY >= 0
                && summary.frame.minY < 160
        }
    }

    @discardableResult
    private func scrollDiaryTo(_ identifier: String) -> Bool {
        let target = app.descendants(matching: .any)[identifier]
        if target.exists, target.isHittable { return true }
        guard let container = diaryContainer() else { return false }
        for _ in 0..<20 {
            container.swipeUp()
            if target.exists, target.isHittable { return true }
        }
        return target.exists
    }

    // MARK: - Settings entry / sheet

    private func openSettings() {
        if settingsSheetExists() { return }
        guard tapToolbarAction(Identifier.settingsEntry) else {
            XCTFail("The diary settings entry was not reachable.")
            return
        }
    }

    private func tapToolbarAction(_ identifier: String) -> Bool {
        if let direct = hittableElement(identifier) {
            direct.tap()
            return true
        }
        for overflow in toolbarOverflowControls() {
            guard overflow.exists, overflow.isHittable else { continue }
            overflow.tap()
            if let revealed = hittableElement(identifier) {
                revealed.tap()
                return true
            }
        }
        return false
    }

    private func toolbarOverflowControls() -> [XCUIElement] {
        let predicates = [
            NSPredicate(format: "label BEGINSWITH[c] %@", "more"),
            NSPredicate(format: "identifier CONTAINS[c] %@", "overflow"),
            NSPredicate(format: "identifier CONTAINS[c] %@", "toolbaritemmenu"),
            NSPredicate(format: "identifier CONTAINS[c] %@", "moreitems"),
        ]
        var controls: [XCUIElement] = []
        for predicate in predicates {
            controls.append(contentsOf: app.descendants(matching: .any)
                .matching(predicate)
                .allElementsBoundByIndex
                .filter { $0.exists })
        }
        return controls
    }

    private func settingsSheetExists() -> Bool {
        app.descendants(matching: .any)[Identifier.sheet].exists
            || app.buttons[Identifier.close].exists
            || app.descendants(matching: .any)[Identifier.calories].exists
    }

    private func waitForSettingsLoaded() -> Bool {
        let goalsLoaded = CalCoE2E.waitUntil(timeout: 30) {
            self.app.descendants(matching: .any)[Identifier.calories].exists
        }
        guard goalsLoaded else {
            reportSettingsLoadFailure()
            return false
        }

        // Preferences load concurrently with goals. Require a real meal-slot
        // row, not just the goal field, so the first toggle read cannot race
        // the preferences response. Form is lazy; scroll to make the row exist.
        let preferencesLoaded = CalCoE2E.waitUntil(timeout: 20) {
            self.app.descendants(matching: .any)[Identifier.breakfast].exists
                || self.app.descendants(matching: .any)[Identifier.slotsError].exists
        }
        if !preferencesLoaded {
            _ = scrollSettingsTo(Identifier.breakfast)
        }
        if app.descendants(matching: .any)[Identifier.slotsError].exists {
            reportSettingsLoadFailure()
            return false
        }
        guard app.descendants(matching: .any)[Identifier.breakfast].exists else {
            reportSettingsLoadFailure()
            return false
        }
        return true
    }

    private func reportSettingsLoadFailure() {
        let observed = [
            "settings.goals.loading",
            "settings.goals.error",
            "settings.slots.loading",
            "settings.slots.error",
            "diary.sessionExpired",
        ].filter { app.descendants(matching: .any)[$0].exists }
        XCTFail(
            "Settings did not finish loading both goals and meal slots. Observed: "
                + (observed.isEmpty ? "neither loaded nor error" : observed.joined(separator: ", "))
        )
    }

    private func waitForSettingsToClose() -> Bool {
        CalCoE2E.waitUntil(timeout: 15) { !self.settingsSheetExists() }
    }

    private func tapSettingsClose() {
        dismissSettingsKeyboard()
        let close = app.buttons[Identifier.close]
        guard close.waitForExistence(timeout: 10) else {
            XCTFail("settings.cancel is not reachable.")
            return
        }
        guard CalCoE2E.waitUntil(timeout: 10, condition: { close.isHittable }) else {
            print("CANCEL_NOT_HITTABLE\n\(app.debugDescription)")
            XCTFail("settings.cancel did not become hittable.")
            return
        }
        close.tap()
    }

    private func settingsForm() -> XCUIElement? {
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        return candidates.first { container in
            container.descendants(matching: .any)[Identifier.calories].exists
                || container.descendants(matching: .any)[Identifier.breakfast].exists
        }
    }

    @discardableResult
    private func scrollSettingsTo(_ identifier: String) -> XCUIElement? {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists, element.isHittable { return element }
        guard let form = settingsForm() else { return nil }
        for _ in 0..<12 {
            form.swipeUp()
            if element.exists, element.isHittable { return element }
        }
        for _ in 0..<12 {
            form.swipeDown()
            if element.exists, element.isHittable { return element }
        }
        return element.exists ? element : nil
    }

    // MARK: - Goals

    private func assertGoalFields(_ expected: [String]) {
        let identifiers = [
            Identifier.calories,
            Identifier.protein,
            Identifier.carbs,
            Identifier.fat,
        ]
        for (identifier, value) in zip(identifiers, expected) {
            XCTAssertEqual(
                fieldValue(identifier),
                value,
                "Unexpected value for \(identifier)."
            )
        }
    }

    private func readGoalFields() -> [String]? {
        let identifiers = [
            Identifier.calories,
            Identifier.protein,
            Identifier.carbs,
            Identifier.fat,
        ]
        let values = identifiers.map(fieldValue)
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }
    }

    private func fieldValue(_ identifier: String) -> String? {
        guard let field = scrollSettingsTo(identifier) else { return nil }
        return field.value as? String
    }

    private func setGoalFields(_ values: [String]) {
        let identifiers = [
            Identifier.calories,
            Identifier.protein,
            Identifier.carbs,
            Identifier.fat,
        ]
        for (identifier, value) in zip(identifiers, values) {
            guard let field = scrollSettingsTo(identifier) else {
                XCTFail("The goal field \(identifier) is not reachable.")
                return
            }
            field.tap()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            field.typeText(value)
            // iPad form sheets can leave the next field unhittable while the
            // keyboard remains up; dismiss it before moving to the next field.
            dismissSettingsKeyboard()
        }
        dismissSettingsKeyboard()
    }

    private func dismissSettingsKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let candidates = [
            app.keyboards.buttons[Identifier.keyboardDone],
            app.buttons[Identifier.keyboardDone],
        ]
        for done in candidates where done.exists && done.isHittable {
            done.tap()
            if CalCoE2E.waitUntil(timeout: 5, condition: {
                !self.app.keyboards.firstMatch.exists
            }) {
                return
            }
        }

        // A visible keyboard-toolbar button can briefly report no hit point on
        // iPad. Try its center directly before giving up.
        let done = app.buttons[Identifier.keyboardDone]
        if done.exists {
            done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = CalCoE2E.waitUntil(timeout: 5) {
                !self.app.keyboards.firstMatch.exists
            }
        }
    }

    private func tapSave(_ identifier: String) {
        dismissSettingsKeyboard()
        guard let save = scrollSettingsTo(identifier) else {
            XCTFail("The save button \(identifier) is not reachable.")
            return
        }
        save.tap()
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.goalsValidation].exists,
            "Goal validation blocked the save unexpectedly."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.slotsValidation].exists,
            "Meal-slot validation blocked the save unexpectedly."
        )
    }

    private func waitForElement(_ identifier: String) -> Bool {
        app.descendants(matching: .any)[identifier].waitForExistence(timeout: 30)
    }

    // MARK: - Best-effort fixture restoration

    /// Runs from tearDown even when an assertion aborted the journey. It never
    /// reports a second failure and never blocks the test result on cleanup.
    /// The isolated fixture is still the source of truth if cleanup cannot run.
    private func restoreFixtureBestEffort() {
        guard let goals = initialGoalFields,
              let dinner = initialDinnerEnabled,
              app.state == .runningForeground else {
            return
        }

        let discardCancel = alertButton(Identifier.discardCancel)
        if discardCancel.exists, discardCancel.isHittable {
            discardCancel.tap()
        }
        if !settingsSheetExists() {
            guard tapToolbarAction(Identifier.settingsEntry) else { return }
        }
        guard app.descendants(matching: .any)[Identifier.calories]
            .waitForExistence(timeout: 12) else {
            return
        }
        // Cancel is disabled while a write is in flight. Let any aborted-save
        // operation settle before attempting a compensating save.
        if app.buttons[Identifier.close].exists {
            _ = CalCoE2E.waitUntil(timeout: 30) {
                self.app.buttons[Identifier.close].isEnabled
                    || !self.app.buttons[Identifier.close].exists
            }
        }

        restoreReconciledSectionIfNeeded(
            reconcile: Identifier.goalsReconcile,
            save: Identifier.goalsSave
        )
        if readGoalFields() != goals {
            guard setGoalFieldsBestEffort(goals) else { return }
            saveSettingsBestEffort(
                save: Identifier.goalsSave,
                saved: Identifier.goalsSaved
            )
        }

        restoreReconciledSectionIfNeeded(
            reconcile: Identifier.slotsReconcile,
            save: Identifier.slotsSave
        )
        if let currentDinner = toggleStateBestEffort(Identifier.dinner),
           currentDinner != dinner {
            if let toggle = scrollSettingsTo(Identifier.dinner),
               toggle.isEnabled, toggle.isHittable {
                toggle.tap()
            }
            saveSettingsBestEffort(
                save: Identifier.slotsSave,
                saved: Identifier.slotsSaved
            )
        }

        let close = app.buttons[Identifier.close]
        if close.exists, close.isEnabled, close.isHittable {
            close.tap()
            let discardConfirm = alertButton(Identifier.discardConfirm)
            if discardConfirm.waitForExistence(timeout: 3) {
                discardConfirm.tap()
            }
        }
    }

    private func restoreReconciledSectionIfNeeded(reconcile: String, save: String) {
        let reconciler = app.buttons[reconcile]
        guard reconciler.exists, reconciler.isEnabled, reconciler.isHittable else { return }
        reconciler.tap()
        _ = app.descendants(matching: .any)[save].waitForExistence(timeout: 20)
    }

    private func setGoalFieldsBestEffort(_ values: [String]) -> Bool {
        let identifiers = [
            Identifier.calories,
            Identifier.protein,
            Identifier.carbs,
            Identifier.fat,
        ]
        for (identifier, value) in zip(identifiers, values) {
            guard let field = scrollSettingsTo(identifier),
                  field.isEnabled,
                  field.isHittable else {
                return false
            }
            field.tap()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            field.typeText(value)
            dismissSettingsKeyboard()
        }
        dismissSettingsKeyboard()
        return true
    }

    private func saveSettingsBestEffort(save: String, saved: String) {
        guard let button = scrollSettingsTo(save),
              button.isEnabled,
              button.isHittable else {
            return
        }
        button.tap()
        _ = app.descendants(matching: .any)[saved].waitForExistence(timeout: 30)
    }

    private func toggleStateBestEffort(_ identifier: String) -> Bool? {
        guard let toggle = scrollSettingsTo(identifier) else { return nil }
        let value = (toggle.value as? String ?? "").lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    // MARK: - Meal slots

    private func toggleIsOn(_ identifier: String) -> Bool {
        guard let toggle = scrollSettingsTo(identifier) else {
            XCTFail("The meal-slot toggle \(identifier) is not reachable.")
            return false
        }
        let value = (toggle.value as? String ?? "").lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    private func setToggle(_ identifier: String, on desired: Bool) {
        guard let toggle = scrollSettingsTo(identifier) else {
            XCTFail("The meal-slot toggle \(identifier) is not reachable.")
            return
        }
        XCTAssertTrue(
            toggle.isEnabled,
            "The meal-slot toggle \(identifier) is disabled before the tap."
        )
        if toggleIsOn(identifier) != desired {
            // The accessibility element spans the Form row; the row label is
            // not the switch control. Tap the trailing switch side explicitly.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let changed = CalCoE2E.waitUntil(timeout: 5) {
            self.toggleIsOn(identifier) == desired
        }
        XCTAssertTrue(
            changed,
            "The meal-slot toggle \(identifier) did not change. "
                + "enabled=\(toggle.isEnabled) value=\(toggle.value as? String ?? "nil")"
        )
    }

    private func hittableElement(_ identifier: String) -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .first(where: { $0.exists && $0.isHittable })
    }

    private func alertButton(_ identifier: String) -> XCUIElement {
        // SwiftUI alerts expose the same identifier on a nested button pair.
        app.buttons.matching(identifier: identifier).firstMatch
    }
}
