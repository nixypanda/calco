import Foundation
import XCTest

// QA-gated native Diary acceptance slice.
//
// This class is the ONLY place that sets `CALCO_NATIVE_DIARY_QA=1` in the
// launched app environment. The flag is compiled into the Test app only
// (`CALCO_TEST`); Debug/Release builds have no environment activation path and
// keep the legacy Diary. The app under test is the real Test app
// (dev.calco.CalCo.Test); only the loopback fixture is fake. The fixture is the
// unchanged NativeCompletionQAMockServer on 127.0.0.1:3932.
//
// Tests skip only when the fixture health check does not identify the expected
// QA fixture. Every other unmet expectation fails. There are no sleeps, no
// index-based AX assumptions, and no direct DB/private routes — fixture state is
// read through the fixture's /__qa/state endpoint with URLSession.

final class NativeDiaryScreenUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ownedBatchHold = false

    private enum QA {
        static let baseURL = "http://127.0.0.1:3932"
        static let fixtureMarker = "native-completion-qa"
        static let username = "native-qa"
        static let password = "native-qa"
        static let nativeFlag = "CALCO_NATIVE_DIARY_QA"
    }

    private enum Identifier {
        static let nativeMarker = "diary.screen.native"
        static let calories = "diary.summary.calories"
        static let remaining = "diary.summary.remaining"
        static let progress = "diary.summary.progress"
        static let protein = "diary.summary.protein"
        static let carbs = "diary.summary.carbs"
        static let fat = "diary.summary.fat"
        static let macroMode = "diary.summary.macroMode"
        static let calendar = "diary.calendar"
        static let previousDay = "diary.previousDay"
        static let nextDay = "diary.nextDay"
        static let manageSlots = "diary.manageSlots"
        static let editGoals = "diary.editGoals"
        static let fetchCount = "diary.fetchCompletionCount"
        static let datePicker = "diary.datePicker"
        static let datePickerCancel = "diary.datePicker.cancel"
        static let datePickerDone = "diary.datePicker.done"
        static let latestBreakfast = "diary.latest.breakfast"
        static let addFoodBreakfast = "diary.addFood.breakfast"
        static let latestReview = "diary.latest.review"
        static let latestCancel = "diary.latest.cancel"
        static let latestSubmit = "diary.latest.submit"
        static let sheetLatestError = "diary.latest.error"
        static let inlineLatestError = "diary.latestError"

        static let historicalLogIDs = (1...8).map { String(format: "diary.log.hist-log-%03d", $0) }
        static let historicalItemIDs = ["diary.latest.item.hist-log-001", "diary.latest.item.hist-log-002"]

        // Settings surface (11th test only; old cases keep their bodies).
        static let settingsSheet = "settings.sheet"
        static let settingsCalories = "settings.goals.calories"
        static let settingsProtein = "settings.goals.protein"
        static let settingsCarbs = "settings.goals.carbs"
        static let settingsFat = "settings.goals.fat"
        static let settingsSave = "settings.goals.save"
        static let settingsSaved = "settings.goals.saved"
        static let mutationNotice = "diary.mutationNotice"
        static let diaryTab = "app.tab.diary"

        // 12th test: meal-slot preference writeback (row-toggles + bounded scroll).
        static let settingsSlotsSave = "settings.slots.save"
        static let settingsSlotsSaved = "settings.slots.saved"
        static let settingsBreakfast = "settings.slots.breakfast"
        static let settingsLunch = "settings.slots.lunch"
        static let settingsDinner = "settings.slots.dinner"
        static let settingsSnack = "settings.slots.snack"
        static let settingsLateNightSnack = "settings.slots.late_night_snack"
        static let addFoodDinner = "diary.addFood.dinner"
        static let addFoodSnack = "diary.addFood.snack"
        static let addFoodLunch = "diary.addFood.lunch"
        static let addFoodLateNightSnack = "diary.addFood.late_night_snack"
        static let latestLunch = "diary.latest.lunch"
    }

    private enum Timeout {
        static let short: TimeInterval = 8
        static let normal: TimeInterval = 20
        static let long: TimeInterval = 40
    }

    private enum ScrollDirection {
        case up
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
    }

    private struct MockResponse {
        let status: Int
        let data: Data
    }

    private final class ResponseBox: @unchecked Sendable {
        var status = -1
        var data = Data()
        var error: Error?
    }

    private struct CalorieSummary {
        let logged: Int
        let remaining: Int
        let goal: Int
    }

    /// Semantic, typed fixture fields — never AX labels or grouped strings.
    private struct FixtureLog: Decodable {
        let id: String
        let date: String
        let mealSlot: String?
        let amount: String
        let unit: String

        enum CodingKeys: String, CodingKey {
            case id, date, amount, unit
            case mealSlot = "meal_slot"
        }
    }

    private struct FixtureStatePayload: Decodable {
        let today: String
        let logCount: Int
        let logPostAttempts: Int
        let logBatchPostCommits: Int
        let logBatchPostInFlight: Int
        let failBatchOnce: Bool
        let batchFailOnceArmed: Bool
        let logPostHold: Bool
        let fixtureEpoch: Int
        let logs: [FixtureLog]
        /// Additive typed read of the existing `goal_calories` fixture field.
        /// It never replaces the canonical full-state comparison.
        let typedGoalCalories: Int?

        enum CodingKeys: String, CodingKey {
            case today, logs
            case typedGoalCalories = "goal_calories"
            case logCount = "log_count"
            case logPostAttempts = "log_post_attempts"
            case logBatchPostCommits = "log_batch_post_commits"
            case logBatchPostInFlight = "log_batch_post_in_flight"
            case failBatchOnce = "fail_batch_once"
            case batchFailOnceArmed = "batch_fail_once_armed"
            case logPostHold = "log_post_hold"
            case fixtureEpoch = "fixture_epoch"
        }
    }

    private struct FixtureState {
        let canonical: String
        let today: String
        let logCount: Int
        let logPostAttempts: Int
        let batchCommits: Int
        let batchInFlight: Int
        let failBatchOnce: Bool
        let batchFailOnceArmed: Bool
        let holdEnabled: Bool
        let epoch: Int
        let logs: [FixtureLog]
        let typedGoalCalories: Int?
    }

    private struct FixtureHealth: Decodable {
        let fixture: String
        let capabilities: [String: Bool]
        let injectedTransientMessage: String

        enum CodingKeys: String, CodingKey {
            case fixture, capabilities
            case injectedTransientMessage = "injected_transient_message"
        }
    }

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        try requireMockFixture()
    }

    override func tearDownWithError() throws {
        // Best effort: release a hold this test armed BEFORE terminating the
        // app so no request is left parked against the next test's fixture.
        if ownedBatchHold {
            try? mockRequest(method: "POST", path: "/__qa/log-post/release")
            ownedBatchHold = false
        }
        app = nil
    }

    // MARK: - Tests

    /// 1. Initial native render: marker + exact semantic summary values, macro
    /// targets, a fetch counter baseline (>= 1, not exactly 1), and the stable
    /// control identifiers.
    func testNativeDiaryInitialRenderExactSummaryAndControls() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.nativeMarker].exists,
            "The native screen marker is missing; the QA host is not active."
        )

        let summary = try XCTUnwrap(readCalorieSummary(), "The calorie summary was not readable.")
        XCTAssertEqual(summary.logged, 0, "Today must start with 0 kcal logged.")
        XCTAssertEqual(summary.remaining, 2000, "Today must show 2000 kcal remaining.")
        XCTAssertEqual(summary.goal, 2000, "Today must show a 2000 kcal goal.")

        for (identifier, target) in [
            (Identifier.protein, 150),
            (Identifier.carbs, 250),
            (Identifier.fat, 70),
        ] {
            let macro = try XCTUnwrap(readMacroNumbers(identifier), "\(identifier) was not readable.")
            XCTAssertEqual(macro.current, 0, "\(identifier) must start at 0 g.")
            XCTAssertEqual(macro.target, target, "\(identifier) has the wrong macro target.")
        }

        let baselineCount = try XCTUnwrap(fetchCount(), "The fetch counter marker is missing.")
        XCTAssertGreaterThanOrEqual(baselineCount, 1, "No initial fetch was counted.")

        for identifier in [
            Identifier.nativeMarker,
            Identifier.calories,
            Identifier.remaining,
            Identifier.progress,
            Identifier.protein,
            Identifier.carbs,
            Identifier.fat,
            Identifier.macroMode,
            Identifier.calendar,
            Identifier.previousDay,
            Identifier.nextDay,
            Identifier.manageSlots,
            Identifier.editGoals,
            Identifier.fetchCount,
            Identifier.latestBreakfast,
            Identifier.addFoodBreakfast,
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].exists,
                "Stable control \(identifier) is missing from the native diary."
            )
        }
    }

    /// 2. Graphical picker Cancel/Done keep the date and counter monotonic;
    /// Previous Day performs a real fetch to the historical day (800 / 1200 /
    /// 2000 with all eight visible logs), and Next Day fetches back to Today.
    func testNativeDiaryPickerAndAdjacentDayRefetch() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        let baselineCount = try XCTUnwrap(fetchCount(), "The fetch counter marker is missing.")

        XCTAssertTrue(tap(Identifier.calendar), "The calendar control is not reachable.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.datePicker]
                .waitForExistence(timeout: Timeout.normal),
            "The native graphical date picker did not open."
        )
        XCTAssertTrue(app.buttons[Identifier.datePickerCancel].exists, "Picker Cancel is missing.")
        app.buttons[Identifier.datePickerCancel].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.datePicker].exists
            },
            "Cancel did not dismiss the picker."
        )
        XCTAssertTrue(isTodaySelected(), "Cancel changed the diary date.")
        XCTAssertGreaterThanOrEqual(
            fetchCount() ?? -1, baselineCount,
            "Cancel reset or rewound the fetch counter."
        )

        XCTAssertTrue(tap(Identifier.calendar), "The calendar control is not reachable.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.datePicker]
                .waitForExistence(timeout: Timeout.normal),
            "The native graphical date picker did not reopen."
        )
        XCTAssertTrue(app.buttons[Identifier.datePickerDone].exists, "Picker Done is missing.")
        app.buttons[Identifier.datePickerDone].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.datePicker].exists
            },
            "Done did not dismiss the picker."
        )
        XCTAssertTrue(isTodaySelected(), "Done with no changed date changed the diary date.")
        XCTAssertGreaterThanOrEqual(
            fetchCount() ?? -1, baselineCount,
            "Done reset or rewound the fetch counter."
        )

        // Capture immediately before the date change: a foreground refresh is
        // legitimate, so the assertion is relative to this baseline.
        let beforePrevious = fetchCount() ?? -1
        XCTAssertTrue(tap(Identifier.previousDay), "Previous Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: beforePrevious),
            "Previous Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical day did not settle at 800 logged / 1200 remaining / 2000 goal."
        )
        XCTAssertFalse(isTodaySelected(), "Previous Day did not leave Today.")
        let foundLogs = collectHistoricalLogIDs()
        for identifier in Identifier.historicalLogIDs {
            XCTAssertTrue(
                foundLogs.contains(identifier),
                "\(identifier) is not visible on the historical day (bounded scroll)."
            )
        }

        let beforeNext = fetchCount() ?? -1
        XCTAssertTrue(tap(Identifier.nextDay), "Next Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: beforeNext),
            "Next Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 0, remaining: 2000, goal: 2000),
            "Returning to Today did not restore the empty-day summary."
        )
        XCTAssertTrue(isTodaySelected(), "Next Day did not return to Today.")
    }

    /// 3. Macro mode is a real Menu with English option labels. Selection uses
    /// exact label predicates, never AX ordering. Source is 0 g; the Percent
    /// option switches each macro to a percent reading, and Grams restores it.
    func testNativeDiaryMacroModeMenuSwitchesGramsToPercent() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        let initialMenu = app.descendants(matching: .any)[Identifier.macroMode]
        XCTAssertTrue(initialMenu.waitForExistence(timeout: Timeout.normal), "Macro menu is missing.")
        XCTAssertTrue(
            initialMenu.label.localizedCaseInsensitiveContains("Grams"),
            "The source macro mode is not Grams: \(initialMenu.label)"
        )
        for identifier in [Identifier.protein, Identifier.carbs, Identifier.fat] {
            let macro = try XCTUnwrap(readMacroNumbers(identifier), "\(identifier) was not readable.")
            XCTAssertEqual(macro.current, 0, "\(identifier) source value must be 0.")
        }

        initialMenu.tap()
        XCTAssertTrue(selectMenuOption("Percent"), "The Percent option was not selectable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.app.descendants(matching: .any)[Identifier.macroMode]
                    .label.localizedCaseInsensitiveContains("Percent")
            },
            "The macro menu did not switch its label to Percent."
        )
        for identifier in [Identifier.protein, Identifier.carbs, Identifier.fat] {
            let label = try XCTUnwrap(readMacroLabel(identifier), "\(identifier) label is missing.")
            XCTAssertTrue(label.contains("%"), "\(identifier) did not switch to percent: \(label)")
            XCTAssertFalse(label.contains(" g"), "\(identifier) still shows a gram target: \(label)")
        }

        let percentMenu = app.descendants(matching: .any)[Identifier.macroMode]
        percentMenu.tap()
        XCTAssertTrue(selectMenuOption("Grams"), "The Grams option was not selectable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.app.descendants(matching: .any)[Identifier.macroMode]
                    .label.localizedCaseInsensitiveContains("Grams")
            },
            "The macro menu did not switch its label back to Grams."
        )
        for (identifier, target) in [
            (Identifier.protein, 150),
            (Identifier.carbs, 250),
            (Identifier.fat, 70),
        ] {
            let macro = try XCTUnwrap(readMacroNumbers(identifier), "\(identifier) was not readable.")
            XCTAssertEqual(macro.current, 0, "\(identifier) gram value was not restored.")
            XCTAssertEqual(macro.target, target, "\(identifier) gram target was not restored.")
        }
    }

    /// 4. Latest Breakfast review is preview-only. The server state (8 logs,
    /// 0 POST attempts) is byte-for-byte identical before preview, while the
    /// preview is open, and after cancel — no automatic write of any kind.
    func testNativeDiaryLatestBreakfastPreviewNeverWrites() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        let before = try fixtureState()
        XCTAssertEqual(before.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertEqual(before.logPostAttempts, 0, "The fixture already saw a log write.")

        guard let latest = scrollToElement(
            Identifier.latestBreakfast,
            marker: Identifier.calories,
            direction: .up
        ) else {
            XCTFail("The Breakfast Log latest control is not reachable.")
            return
        }
        latest.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.latestReview]
                .waitForExistence(timeout: Timeout.long),
            "Log latest did not open its review step."
        )
        for identifier in Identifier.historicalItemIDs {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].exists,
                "The review is missing source item \(identifier)."
            )
        }
        XCTAssertEqual(
            try fixtureState().canonical, before.canonical,
            "Opening the review wrote to the fixture."
        )

        XCTAssertTrue(app.buttons[Identifier.latestCancel].exists, "Review Cancel is missing.")
        app.buttons[Identifier.latestCancel].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.latestReview].exists
            },
            "Cancel did not dismiss the review."
        )

        let after = try fixtureState()
        XCTAssertEqual(after.canonical, before.canonical, "Cancelling the review wrote to the fixture.")
        XCTAssertEqual(after.logCount, 8, "The fixture log count changed without a save.")
        XCTAssertEqual(after.logPostAttempts, 0, "The fixture saw a write without an explicit save.")
    }

    /// 5. Explicit submit of the two-item Breakfast review parks the batch POST
    /// on an opt-in fixture gate. The busy barrier is the fixture's in-flight
    /// counter plus disabled buttons — never a duration. Releasing the gate
    /// commits exactly two 100 kcal logs into Today and reconciles the summary.
    func testNativeDiaryLatestBreakfastSubmitHoldsThenCommitsExactBatch() throws {
        try requireBatchWriteCapabilities()
        try resetFixture(holdBatchPost: true)
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        let before = try fixtureState()
        XCTAssertEqual(before.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertEqual(before.logPostAttempts, 0, "The fixture already saw a write.")
        XCTAssertEqual(before.batchCommits, 0, "The fixture already committed a batch.")
        XCTAssertEqual(before.batchInFlight, 0, "The fixture already has a parked POST.")

        try openLatestBreakfastReview()
        assertHistoricalReviewItems()
        XCTAssertEqual(
            try fixtureState().canonical, before.canonical,
            "Opening the review wrote to the fixture."
        )

        XCTAssertTrue(submitLatest(), "The review Log all button is not reachable.")
        XCTAssertTrue(
            waitForFixtureState { $0.batchInFlight == 1 },
            "The batch POST never parked on the fixture gate."
        )
        XCTAssertTrue(waitForSubmitBusy(), "Both review buttons stayed enabled while busy.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.latestReview].exists,
            "The review sheet closed before the write completed."
        )
        assertHistoricalReviewItems()

        let parked = try fixtureState()
        XCTAssertEqual(parked.logPostAttempts, 1, "The batch must count as one attempt.")
        XCTAssertEqual(parked.batchCommits, 0, "No batch may commit while parked.")
        XCTAssertEqual(parked.logCount, 8, "No log may be appended before release.")
        XCTAssertEqual(parked.batchInFlight, 1, "The parked request was not registered.")

        let release = try mockRequest(method: "POST", path: "/__qa/log-post/release")
        XCTAssertEqual(release.status, 200, "The fixture gate could not be released.")

        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.latestReview].exists
            },
            "The review sheet did not dismiss after the batch committed."
        )
        XCTAssertTrue(
            waitForFixtureState {
                $0.batchCommits == 1 && $0.batchInFlight == 0
                    && $0.logPostAttempts == 1 && $0.logCount == 10
            },
            "The fixture did not settle at one commit and ten logs."
        )
        XCTAssertTrue(
            waitForSummary(logged: 200, remaining: 1800, goal: 2000),
            "The reconciled summary is not 200 / 1800 / 2000."
        )
        assertExactMacroTotals(protein: 2, carbs: 40, fat: 1)
        assertCreatedBatchLogs(try fixtureState(), day: before.today)
    }

    /// 6. One fail-once batch returns the API-mapped transient error and keeps
    /// the review (and both buttons) usable. No second POST happens without an
    /// explicit second tap; that second tap commits the same captured payload.
    func testNativeDiaryLatestBreakfastFailOnceThenExplicitRetryCommits() throws {
        try requireBatchWriteCapabilities()
        let expectedMessage = try injectedTransientMessage()
        try resetFixture(failBatchOnce: true)
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        let before = try fixtureState()
        XCTAssertEqual(before.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertEqual(before.logPostAttempts, 0, "The fixture already saw a write.")

        try openLatestBreakfastReview()
        assertHistoricalReviewItems()

        XCTAssertTrue(submitLatest(), "The review Log all button is not reachable.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.sheetLatestError]
                .waitForExistence(timeout: Timeout.normal),
            "The failed batch did not surface the review error."
        )
        let message = try XCTUnwrap(readSheetError(), "The review error has no text.")
        XCTAssertFalse(message.isEmpty, "The review error text is empty.")
        XCTAssertEqual(
            message, expectedMessage,
            "A 503 must surface the API/LogSubmissionService mapped message."
        )
        XCTAssertTrue(waitForSubmitEnabled(), "The review stayed busy after the failure.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.latestReview].exists,
            "The failed review was discarded; explicit retry is impossible."
        )
        assertHistoricalReviewItems()

        // Assert immediately after the error state: no arbitrary wait window,
        // and no automatic second POST before the explicit retry below.
        let failed = try fixtureState()
        XCTAssertEqual(failed.logPostAttempts, 1, "A single tap made more than one POST.")
        XCTAssertEqual(failed.batchCommits, 0, "The failed batch committed logs.")
        XCTAssertEqual(failed.logCount, 8, "The failed batch appended logs.")
        XCTAssertFalse(failed.batchFailOnceArmed, "The fail-once arm was not consumed.")

        XCTAssertTrue(submitLatest(), "The explicit retry button is not reachable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.latestReview].exists
            },
            "The review sheet did not dismiss after the explicit retry."
        )
        XCTAssertTrue(
            waitForFixtureState {
                $0.batchCommits == 1 && $0.logPostAttempts == 2 && $0.logCount == 10
            },
            "The retry did not commit exactly one batch of two logs."
        )
        XCTAssertTrue(
            waitForSummary(logged: 200, remaining: 1800, goal: 2000),
            "The retried summary is not 200 / 1800 / 2000."
        )
        assertExactMacroTotals(protein: 2, carbs: 40, fat: 1)
        assertCreatedBatchLogs(try fixtureState(), day: before.today)
    }

    /// 7. Cancelling a failed review clears both the sheet error and the inline
    /// error, keeps the single attempt, and does not auto-retry on reopen.
    func testNativeDiaryLatestBreakfastFailureCancelClearsErrorWithoutRetry() throws {
        try requireBatchWriteCapabilities()
        try resetFixture(failBatchOnce: true)
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")

        try openLatestBreakfastReview()
        assertHistoricalReviewItems()
        XCTAssertTrue(submitLatest(), "The review Log all button is not reachable.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.sheetLatestError]
                .waitForExistence(timeout: Timeout.normal),
            "The failed batch did not surface the review error."
        )
        let failed = try fixtureState()
        XCTAssertEqual(failed.logPostAttempts, 1, "A single tap made more than one POST.")
        XCTAssertEqual(failed.batchCommits, 0, "The failed batch committed logs.")
        XCTAssertEqual(failed.logCount, 8, "The failed batch appended logs.")

        XCTAssertTrue(app.buttons[Identifier.latestCancel].isEnabled, "Cancel is disabled.")
        app.buttons[Identifier.latestCancel].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.latestReview].exists
            },
            "Cancel did not dismiss the failed review."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.sheetLatestError].exists,
            "The dismissed sheet still advertises its error."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.inlineLatestError].exists,
            "Cancel left an inline latest error behind."
        )
        let afterCancel = try fixtureState()
        XCTAssertEqual(afterCancel.logPostAttempts, 1, "Cancel caused another POST.")
        XCTAssertEqual(afterCancel.batchCommits, 0, "Cancel committed a batch.")
        XCTAssertEqual(afterCancel.logCount, 8, "Cancel appended logs.")

        try openLatestBreakfastReview()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.latestReview].exists,
            "The review could not be reopened after cancel."
        )
        assertHistoricalReviewItems()
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.sheetLatestError].exists,
            "Reopening a review replayed the stale error."
        )
        let afterReopen = try fixtureState()
        XCTAssertEqual(afterReopen.logPostAttempts, 1, "Reopening auto-retried the write.")
        XCTAssertEqual(afterReopen.batchCommits, 0, "Reopening committed a batch.")
        XCTAssertEqual(afterReopen.logCount, 8, "Reopening appended logs.")
    }

    /// 11. Settings goal writeback in the store-backed host. The fixture default
    /// stays 2000; only the typed calorie value becomes 2230, the exact value
    /// validated by macros 150/250/70. Today updates with no GET, no notice and
    /// no log write; the historical day keeps 2000, and returning to Today
    /// fetches the server's saved 2230 exactly once.
    func testNativeDiarySettingsGoalWritebackUpdatesTodayWithoutFetch() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.nativeMarker].exists,
            "The native screen marker is missing; the QA host is not active."
        )
        let baselineCount = try XCTUnwrap(fetchCount(), "The fetch counter marker is missing.")
        XCTAssertGreaterThanOrEqual(baselineCount, 1, "No initial fetch was counted.")
        let stateBefore = try fixtureState()
        XCTAssertEqual(stateBefore.typedGoalCalories, 2000, "The fixture default goal must stay 2000.")

        XCTAssertTrue(tap(Identifier.editGoals), "Edit Goals is not reachable.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSheet]
                .waitForExistence(timeout: Timeout.normal),
            "settings.sheet is missing."
        )
        let caloriesField = app.textFields.matching(
            NSPredicate(format: "identifier ==[c] %@", Identifier.settingsCalories)
        ).firstMatch
        XCTAssertTrue(
            caloriesField.waitForExistence(timeout: Timeout.normal),
            "settings.goals.calories is missing."
        )
        // Macros stay at the loaded 150/250/70; 2230 is the only valid calorie
        // value for that formula, so validation is exercised, not bypassed.
        XCTAssertEqual(goalFieldValue(Identifier.settingsProtein), "150")
        XCTAssertEqual(goalFieldValue(Identifier.settingsCarbs), "250")
        XCTAssertEqual(goalFieldValue(Identifier.settingsFat), "70")
        XCTAssertTrue(
            replaceGoalField(Identifier.settingsCalories, with: "2230"),
            "The exact 2230 calorie draft was not typed."
        )

        let save = app.buttons[Identifier.settingsSave]
        XCTAssertTrue(save.waitForExistence(timeout: Timeout.normal), "settings.goals.save is missing.")
        XCTAssertTrue(save.isEnabled, "Save is disabled for a valid 2230 goal.")
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSaved]
                .waitForExistence(timeout: Timeout.long),
            "The settings save barrier never settled."
        )
        XCTAssertTrue(
            waitForFixtureState(timeout: Timeout.long) { $0.typedGoalCalories == 2230 },
            "The fixture did not persist goal_calories 2230."
        )

        // Dismiss the settings surface itself, then require the Diary summary
        // (and its counter) to be visible before reading any counter value.
        XCTAssertTrue(tap(Identifier.diaryTab), "The Diary destination is not reachable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "settings.sheet was not dismissed."
        )
        XCTAssertTrue(
            waitForSummary(logged: 0, remaining: 2230, goal: 2230),
            "Today did not settle at 0 logged / 2230 remaining / 2230 goal."
        )
        assertExactMacroTotals(protein: 0, carbs: 0, fat: 0)
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.mutationNotice].exists,
            "A goal save must not show a mutation notice."
        )
        let afterSaveCount = try requireVisibleFetchCount(
            "The fetch counter was not readable after the goal save."
        )
        XCTAssertEqual(afterSaveCount, baselineCount, "The local goal save must not fetch.")
        let stateAfterSave = try fixtureState()
        XCTAssertEqual(stateAfterSave.typedGoalCalories, 2230)
        XCTAssertEqual(stateAfterSave.logCount, stateBefore.logCount, "Goal save appended logs.")
        XCTAssertEqual(
            stateAfterSave.logPostAttempts, stateBefore.logPostAttempts,
            "Goal save posted logs."
        )

        // Historical day keeps its own 2000 goal; one real read is added.
        let beforePrevious = try requireVisibleFetchCount(
            "The fetch counter was not readable before Previous Day."
        )
        XCTAssertTrue(tap(Identifier.previousDay), "Previous Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: beforePrevious),
            "Previous Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical day did not keep its 2000 goal."
        )
        // Separate baseline captured AFTER the previous-day read, so the next
        // day's single read is measured exactly (+1), not against the launch.
        let counterAfterPrevious = try requireVisibleFetchCount(
            "The fetch counter was not readable on the historical day."
        )
        XCTAssertTrue(tap(Identifier.nextDay), "Next Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: counterAfterPrevious),
            "Next Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 0, remaining: 2230, goal: 2230),
            "Returning to Today did not show the saved 2230 goal."
        )
        let counterAfterNext = try requireVisibleFetchCount(
            "The fetch counter was not readable after Next Day."
        )
        XCTAssertEqual(counterAfterNext, counterAfterPrevious + 1, "Next Day added more than one read.")
    }

    /// 12. Settings preference writeback in the store-backed host. Preferences
    /// are global/date-free: disabling two slots while a historical day is
    /// visible keeps that day's logged rows (native parity) with no refetch,
    /// while the disabled *empty* sections stay hidden on Today after exactly
    /// one legitimate GET. Persistence is proved by reopening Settings (a real
    /// GET), never by a QA state field.
    func testNativeDiarySettingsPreferencesWritebackKeepsHistoryAndHidesEmptyTodaySections() throws {
        try resetFixture()
        let initial = try fixtureState()
        XCTAssertEqual(initial.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertEqual(initial.logPostAttempts, 0, "The fixture already saw a log write.")
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.nativeMarker].exists,
            "The native screen marker is missing; the QA host is not active."
        )

        // Historical day with the fixture's exact 800/1200/2000 summary.
        XCTAssertTrue(tap(Identifier.previousDay), "Previous Day is not reachable.")
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical day did not settle at 800/1200/2000."
        )

        // Macro mode is a global UI setting; switch to Percent here and require
        // it to survive both the save and the later date change.
        let macroMenu = app.descendants(matching: .any)[Identifier.macroMode]
        XCTAssertTrue(macroMenu.waitForExistence(timeout: Timeout.normal), "Macro menu is missing.")
        macroMenu.tap()
        XCTAssertTrue(selectMenuOption("Percent"), "The Percent option was not selectable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) { self.assertMacroModePercent() },
            "Macro mode did not switch to Percent."
        )

        // Capture the visible counter BEFORE opening settings. A nil read is a
        // hard failure, never a fabricated sentinel.
        guard let baselineCount = fetchCount(), baselineCount >= 0 else {
            XCTFail("The diary fetch counter was not readable before Settings.")
            return
        }

        // Open the real settings surface through the diary's Manage Slots route.
        XCTAssertTrue(tap(Identifier.manageSlots), "Manage Slots is not reachable.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSheet]
                .waitForExistence(timeout: Timeout.normal),
            "settings.sheet is missing."
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                self.settingsRow(Identifier.settingsCalories) != nil
                    && self.settingsRow(Identifier.settingsBreakfast) != nil
            },
            "Settings did not load both the goal and meal-slot sections."
        )

        // Disable breakfast and lunch; leave dinner, snack and late-night on.
        setSlotToggle(Identifier.settingsBreakfast, on: false)
        setSlotToggle(Identifier.settingsLunch, on: false)
        setSlotToggle(Identifier.settingsDinner, on: true)
        setSlotToggle(Identifier.settingsSnack, on: true)
        setSlotToggle(Identifier.settingsLateNightSnack, on: true)

        // Save preferences independently of goal validation: the 2000 goal is
        // untouched and no macro field is edited.
        let save = app.buttons[Identifier.settingsSlotsSave]
        XCTAssertTrue(save.waitForExistence(timeout: Timeout.normal), "settings.slots.save is missing.")
        XCTAssertTrue(save.isEnabled, "Save is disabled for a valid preference draft.")
        save.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSlotsSaved]
                .waitForExistence(timeout: Timeout.long),
            "The preferences save barrier never settled."
        )

        // Return through the real Diary tab (there is no fabricated Cancel).
        XCTAssertTrue(tap(Identifier.diaryTab), "The Diary destination is not reachable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "settings.sheet was not dismissed."
        )

        // History is unchanged: same summary/date, all eight log rows, and the
        // logged breakfast section still renders with its Add Food control.
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical summary changed after the preference save."
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) { self.assertMacroModePercent() },
            "Macro mode did not survive on history."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.mutationNotice].exists,
            "A preference save must not show a mutation notice."
        )
        let afterSaveCount = try requireVisibleFetchCount(
            "The fetch counter was not readable after the save."
        )
        XCTAssertEqual(afterSaveCount, baselineCount, "The save must not issue a diary GET.")
        XCTAssertEqual(
            collectHistoricalLogIDs(), Set(Identifier.historicalLogIDs),
            "The historical log rows were not all retained."
        )
        // Start at the summary after collecting all rows, then visit both
        // disabled-but-logged slots in their rendered order. Latest buttons
        // belong only to empty sections; retained log rows prove these sections.
        XCTAssertTrue(
            revealDiaryTopControl(Identifier.calendar), "The historical date control is unreachable."
        )
        for identifier in [
            "diary.log.hist-log-001", Identifier.addFoodBreakfast,
            "diary.log.hist-log-003", Identifier.addFoodLunch,
        ] {
            guard let control = scrollToElement(
                identifier, marker: Identifier.calories, direction: .up
            ) else {
                XCTFail("The retained historical control \(identifier) was hidden.")
                return
            }
            XCTAssertTrue(control.isHittable, "The retained historical control is not reachable.")
        }

        // Navigate to Today: one legitimate GET, measured as an exact +1.
        XCTAssertTrue(revealDiaryTopControl(Identifier.nextDay), "Next Day could not be revealed.")
        XCTAssertTrue(tap(Identifier.nextDay), "Next Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: afterSaveCount),
            "Today did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 0, remaining: 2000, goal: 2000),
            "Today did not settle at 0/2000/2000."
        )
        let todayCount = try requireVisibleFetchCount("Today's fetch counter was not readable.")
        XCTAssertEqual(todayCount, afterSaveCount + 1, "Today added more than one read.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) { self.assertMacroModePercent() },
            "Macro mode did not survive on Today."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.mutationNotice].exists,
            "A date change must not show a mutation notice."
        )
        // Disabled *empty* sections are not rendered; an enabled section still
        // is. The bounded absence check runs on the loaded viewport.
        XCTAssertTrue(
            assertDisabledEmptySectionsAbsentOnToday(),
            "A disabled empty breakfast/lunch section was rendered on Today."
        )

        // Persistence is proved by reopening Settings (a real GET), not by a
        // QA state field.
        XCTAssertTrue(
            revealDiaryTopControl(Identifier.manageSlots), "Today's Manage Slots could not be revealed."
        )
        XCTAssertTrue(tap(Identifier.manageSlots), "Manage Slots is not reachable on Today.")
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSheet]
                .waitForExistence(timeout: Timeout.normal),
            "settings.sheet did not reopen."
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                self.settingsRow(Identifier.settingsBreakfast) != nil
            },
            "The meal-slot section did not reload."
        )
        XCTAssertEqual(slotToggleIsOn(Identifier.settingsBreakfast), false, "Breakfast did not persist OFF.")
        XCTAssertEqual(slotToggleIsOn(Identifier.settingsLunch), false, "Lunch did not persist OFF.")
        XCTAssertEqual(slotToggleIsOn(Identifier.settingsDinner), true, "Dinner did not persist ON.")
        XCTAssertEqual(slotToggleIsOn(Identifier.settingsSnack), true, "Snack did not persist ON.")
        XCTAssertEqual(slotToggleIsOn(Identifier.settingsLateNightSnack), true, "Late-night did not persist ON.")

        // Returning to Diary performs no additional diary GET.
        XCTAssertTrue(tap(Identifier.diaryTab), "The Diary destination is not reachable.")
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "settings.sheet was not dismissed after the persistence check."
        )
        let afterReturn = try requireVisibleFetchCount("The counter was not readable after return.")
        XCTAssertEqual(afterReturn, todayCount, "Returning from Settings fetched the diary.")

        // No log write and no fake cache row: the fixture log set is byte-equal.
        let final = try fixtureState()
        XCTAssertEqual(final.logCount, initial.logCount)
        XCTAssertEqual(final.logPostAttempts, initial.logPostAttempts)
        XCTAssertEqual(final.logs.map(\.id), initial.logs.map(\.id))
    }

    // MARK: - App launch / sign-in

    /// Derives the historical day from the fixture's stable `today` field when
    /// it is published, so a reset at local midnight cannot race the wall clock.
    /// Older fixtures that omit the field keep the previous wall-date fallback.
    private func historicalDayDate(fromFixtureToday fixtureToday: String) -> Date {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd"
        guard !fixtureToday.isEmpty, let anchor = parser.date(from: fixtureToday) else {
            return Date()
        }
        return Calendar.current.date(byAdding: .day, value: -1, to: anchor) ?? anchor
    }

    /// Brings the diary summary counter back into view with bounded swipes and
    /// an explicit AX existence check — no sleep, no time-based polling. Used
    /// only by journey 8, immediately before its pre/post-write reads.
    private func waitForDiaryCounterVisible() -> Bool {
        let marker = app.descendants(matching: .any)[Identifier.fetchCount]
        if marker.exists, marker.frame.width > 0, marker.frame.height > 0 { return true }
        guard let container = scrollContainer(marker: Identifier.calories) else {
            return marker.waitForExistence(timeout: Timeout.normal)
        }
        for _ in 0..<8 {
            container.swipeDown()
            if marker.exists, marker.frame.width > 0, marker.frame.height > 0 { return true }
        }
        return marker.waitForExistence(timeout: Timeout.normal)
    }

    /// 8. Historical-day Add Food routes the captured date through the legacy
    /// logging seam into the existing Search recents quick-add control. One
    /// chip tap is one POST on that captured day; returning to Diary shows the
    /// new row and exactly one authoritative read after the write (Search's
    /// diaryChanged delegate must not trigger a second refresh).
    func testNativeDiaryAddFoodQuickAddReturnsToHistoricalDayWithOneWriteAndRead() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")
        let baseline = try fixtureState()
        XCTAssertEqual(baseline.logPostAttempts, 0, "The fixture already saw a log write.")

        let beforePrevious = fetchCount() ?? -1
        XCTAssertTrue(tap(Identifier.previousDay), "Previous Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: beforePrevious),
            "Previous Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical day did not settle at 800 logged / 1200 remaining."
        )

        // Capture the pre-write counter HERE, while the Diary summary is still
        // on screen. It is absent once Add Food scrolls/navigates to Search, so
        // a later `fetchCount() ?? -1` would fabricate a baseline of -1.
        guard waitForDiaryCounterVisible(),
              let prewriteCount = fetchCount() else {
            XCTFail("The diary fetch counter was not readable before Add Food")
            return
        }
        XCTAssertGreaterThanOrEqual(prewriteCount, 1, "No settled fetch before the write")
        XCTAssertGreaterThan(prewriteCount, beforePrevious, "The historical fetch had not settled")

        let historicalDate = historicalDayDate(fromFixtureToday: baseline.today)
        let historicalDay = Self.isoDay(historicalDate)

        // Add Food pushes the shared Search screen with the captured historical
        // date and Breakfast slot, not the live tab's navigation state.
        guard let addFood = scrollToElement(
            Identifier.addFoodBreakfast,
            marker: Identifier.calories,
            direction: .up
        ) else {
            XCTFail("The historical Breakfast Add Food control is not reachable.")
            return
        }
        addFood.tap()

        let context = app.descendants(matching: .any)["search.loggingContext"]
        XCTAssertTrue(
            context.waitForExistence(timeout: Timeout.long),
            "Add Food did not open the shared Search screen."
        )
        // Mirrors the app's own `LocalDiaryDate.diaryDisplayTitle()` used by
        // `SearchScreenView.contextSubtitle`: a gregorian calendar formatted
        // with wide weekday, wide month, default day and the current locale.
        // That contract renders e.g. "Wednesday, 25 November · Breakfast";
        // a fixed `EEEE, MMMM d` formatter reverses day/month for this locale.
        let components = Calendar.current.dateComponents([.year, .month, .day], from: historicalDate)
        var displayCalendar = Calendar(identifier: .gregorian)
        displayCalendar.locale = .current
        guard let displayDate = displayCalendar.date(from: DateComponents(
            year: components.year,
            month: components.month,
            day: components.day
        )) else {
            XCTFail("Could not build the expected diary display date")
            return
        }
        let expectedContextDate = displayDate.formatted(
            Date.FormatStyle()
                .weekday(.wide)
                .month(.wide)
                .day(.defaultDigits)
                .locale(.current)
        )
        XCTAssertTrue(
            context.label.localizedCaseInsensitiveContains(expectedContextDate),
            "The Search logging context did not carry the captured historical date: \(context.label), expected \(expectedContextDate)"
        )

        let chip = app.buttons["search.quickAdd.product:qa-apple.100.g"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: Timeout.long),
            "The existing Search recents quick-add chip did not appear."
        )
        chip.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["search.quickAdd.added"]
                .waitForExistence(timeout: Timeout.long),
            "Quick add did not report success."
        )

        // Return through the system Back affordance, selected by its semantic
        // label rather than an AX index/order assumption.
        let back = app.navigationBars.buttons.matching(
            NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Back", "Diary")
        ).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: Timeout.normal), "No Back affordance reached Diary.")
        back.tap()

        let after = try fixtureState()
        XCTAssertEqual(
            after.logPostAttempts, baseline.logPostAttempts + 1,
            "One quick-add chip must be exactly one POST."
        )
        XCTAssertEqual(after.logCount, baseline.logCount + 1, "Quick add must create exactly one row.")
        guard let created = after.logs.last else {
            XCTFail("The quick-added row was not written to the fixture.")
            return
        }
        XCTAssertEqual(created.date, historicalDay, "The write lost the captured historical date.")
        XCTAssertEqual(created.mealSlot, "breakfast", "The write lost the captured meal slot.")
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.log.\(created.id)"]
                .waitForExistence(timeout: Timeout.long),
            "The new row is not visible on the returned historical diary."
        )
        XCTAssertTrue(
            waitForSummary(logged: 900, remaining: 1100, goal: 2000),
            "The historical summary did not include the newly logged 100 kcal."
        )
        XCTAssertTrue(
            waitForDiaryCounterVisible(),
            "The diary fetch counter was not readable after returning from Search"
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                guard let count = self.fetchCount() else { return false }
                return count == prewriteCount + 1
            },
            "The post-write read did not settle at exactly one above the pre-write count"
        )
        guard let postwriteCount = fetchCount() else {
            XCTFail("The diary fetch counter vanished after the write")
            return
        }
        XCTAssertEqual(
            postwriteCount, prewriteCount + 1,
            "The store-backed owner must issue exactly one read after the write."
        )
    }

    /// 9. Store-backed editor saves a row created by the accepted historical
    /// quick-add path. The fresh row is absent from the stale legacy VM but is
    /// resolved from the TCA owner; the authoritative PUT is applied with the
    /// same server ID and one visible read, and the notice carries that row's
    /// own title. The counter delta is measured from the visible pre-save read.
    func testNativeDiaryEditorSaveFreshQuickAddedRowAppliesOnce() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")
        let seed = try fixtureState()
        XCTAssertEqual(seed.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertEqual(seed.logPostAttempts, 0, "The fixture already saw a log write.")

        let created = try quickAddHistoricalBreakfastApple(baseline: seed)
        XCTAssertTrue(
            created.id.contains("new-log-"),
            "The accepted quick-add path did not create a fresh row."
        )

        // Capture the visible counter after the quick-add read settled, while
        // the summary is still on screen and BEFORE the editor opens.
        guard waitForDiaryCounterVisible(), let preSaveCount = fetchCount() else {
            XCTFail("The diary fetch counter was not readable before the editor")
            return
        }

        let row = app.descendants(matching: .any)["diary.log.\(created.id)"]
        guard scrollToElement(
            "diary.log.\(created.id)",
            marker: Identifier.calories,
            direction: .up
        ) != nil else {
            XCTFail("The fresh quick-added row is not visible on the diary.")
            return
        }
        XCTAssertTrue(row.exists, "The fresh row lost its stable AX identity.")
        row.tap()

        let amount = app.descendants(matching: .textField)["diary.editor.amount"]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.long),
            "The legacy editor amount field did not open."
        )
        XCTAssertTrue(
            amount.label.localizedCaseInsensitiveContains("Amount"),
            "The amount field lost its AX label."
        )
        XCTAssertTrue(replaceAmount(with: "200"), "Could not set the editor amount to 200.")

        let save = app.descendants(matching: .any)["diary.editor.save"]
        XCTAssertTrue(
            save.waitForExistence(timeout: Timeout.normal)
                && save.label.localizedCaseInsensitiveContains("Save"),
            "The editor Save control is not reachable by label."
        )
        save.tap()

        // The same server ID now carries 200 kcal: 8 historical rows x 100 +
        // 200 = 1000 logged, 1000 remaining. No second POST is expected.
        XCTAssertTrue(
            waitForSummary(logged: 1000, remaining: 1000, goal: 2000),
            "The saved row did not reconcile to 1000 / 1000 / 2000."
        )
        let after = try fixtureState()
        XCTAssertEqual(
            after.logPostAttempts, seed.logPostAttempts + 1,
            "Editing must not add a POST."
        )
        XCTAssertEqual(after.logCount, seed.logCount + 1, "Editing must not add a row.")
        guard let savedRow = after.logs.first(where: { $0.id == created.id }) else {
            XCTFail("The edited row lost its original server ID.")
            return
        }
        XCTAssertEqual(savedRow.amount, "200", "The PUT did not persist the new amount.")
        XCTAssertEqual(savedRow.date, created.date, "The PUT changed the captured date.")

        // Bring the summary/notice band back into the rendered AX tree before
        // reading either the notice or the counter.
        XCTAssertTrue(
            waitForDiaryCounterVisible(),
            "The summary/notice band did not return into view after Save."
        )
        assertNotice(message: "Food saved", title: "Native QA Apple")

        // The counter view is scrolled back into view and read with a hard
        // guard — no sentinel fallback — then compared to the pre-save read.
        guard waitForDiaryCounterVisible(), let postSaveCount = fetchCount() else {
            XCTFail("The diary fetch counter was not readable after the save")
            return
        }
        XCTAssertEqual(
            postSaveCount, preSaveCount + 1,
            "The store-backed editor must issue exactly one visible read after Save."
        )
    }

    /// 10. Store-backed editor deletes an existing historical row. The actual
    /// destructive confirmation is used, the tombstone survives the follow-up
    /// read, and exactly one read is counted from the visible pre-editor value.
    func testNativeDiaryEditorDeleteHistoricalRowAppliesOnce() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The QA-gated native diary did not load.")
        let seed = try fixtureState()
        XCTAssertEqual(seed.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertEqual(seed.logPostAttempts, 0, "The fixture already saw a log write.")

        guard let beforePrevious = fetchCount() else {
            XCTFail("The initial fetch counter is missing.")
            return
        }
        XCTAssertTrue(tap(Identifier.previousDay), "Previous Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: beforePrevious),
            "Previous Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical day did not settle at 800 / 1200 / 2000."
        )

        guard waitForDiaryCounterVisible(), let preDeleteCount = fetchCount() else {
            XCTFail("The diary fetch counter was not readable before the editor")
            return
        }

        let rowID = "diary.log.hist-log-001"
        guard scrollToElement(
            rowID, marker: Identifier.calories, direction: .up
        ) != nil else {
            XCTFail("The historical row hist-log-001 is not visible.")
            return
        }
        app.descendants(matching: .any)[rowID].tap()

        // Editor-open barrier: the amount field is present with the historical
        // row's unchanged 100 before any scroll. Never mutate it for Delete.
        let amount = app.textFields["diary.editor.amount"]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.long),
            "The editor amount field did not open for the historical row."
        )
        XCTAssertEqual(
            (amount.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "100",
            "The historical row's amount was expected to remain 100 before Delete."
        )

        // Capture the UNIQUE editor CollectionView while its amount/header
        // marker is still on screen — never the diary summary's scroll
        // container and never a global "first pane" fallback.
        guard let editorList = editorCollectionView() else {
            XCTFail("The editor CollectionView is not uniquely reachable; cannot reveal Delete.")
            return
        }
        // Bounded reveal INSIDE the captured editor list only.
        guard let delete = revealEditorDeleteButton(in: editorList) else {
            XCTFail("The typed editor Delete button did not become present and hittable.")
            return
        }
        XCTAssertEqual(
            delete.label, "Delete Food",
            "The editor Delete button label is not the exact English Delete Food string."
        )
        delete.tap()

        // The confirmation Sheet exposes two NESTED Buttons sharing the
        // `diary.editor.delete.confirm` id and "Delete" label. Select the
        // UNIQUE innermost leaf (no descendant Button with the same id) inside
        // the actual sheet — never a blind firstMatch/index pick, and never the
        // pre-confirmation Delete Food button or the Cancel action.
        guard let confirm = uniqueDeleteConfirmationButton() else {
            XCTFail("The unique destructive Delete confirmation leaf was not found in the sheet.")
            return
        }
        XCTAssertTrue(
            confirm.waitForExistence(timeout: Timeout.normal),
            "The destructive Delete confirmation did not appear."
        )
        XCTAssertTrue(
            confirm.isHittable,
            "The destructive Delete confirmation leaf is not hittable."
        )
        XCTAssertTrue(
            confirm.label.localizedCaseInsensitiveContains("Delete"),
            "The confirm action lost its AX label: \(confirm.label)"
        )
        confirm.tap()

        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.descendants(matching: .any)[rowID].exists
            },
            "The deleted row is still visible."
        )
        XCTAssertTrue(
            waitForSummary(logged: 700, remaining: 1300, goal: 2000),
            "The historical day did not settle at 700 / 1300 / 2000."
        )
        XCTAssertTrue(
            waitForFixtureState { $0.logCount == 7 && !$0.logs.contains { $0.id == "hist-log-001" } },
            "The fixture still contains the deleted row."
        )
        XCTAssertEqual(
            try fixtureState().logPostAttempts, seed.logPostAttempts,
            "A delete must not issue a POST."
        )

        XCTAssertTrue(
            waitForDiaryCounterVisible(),
            "The summary/notice band did not return into view after Delete."
        )
        assertNotice(message: "Food deleted", title: "Historical Oats")

        guard waitForDiaryCounterVisible(), let postDeleteCount = fetchCount() else {
            XCTFail("The diary fetch counter was not readable after the delete")
            return
        }
        XCTAssertEqual(
            postDeleteCount, preDeleteCount + 1,
            "The store-backed editor must issue exactly one visible read after Delete."
        )
    }

    /// Reuses the accepted historical quick-add journey to create one fresh
    /// row and return to the diary. Kept as a helper so tests 9 and 8 share the
    /// same canonical AX path without changing test 8's body.
    private func quickAddHistoricalBreakfastApple(baseline: FixtureState) throws -> FixtureLog {
        guard let beforePrevious = fetchCount() else {
            throw HarnessError(description: "The initial fetch counter is missing.")
        }
        XCTAssertTrue(tap(Identifier.previousDay), "Previous Day is not reachable.")
        XCTAssertTrue(
            waitForFetchCount(greaterThan: beforePrevious),
            "Previous Day did not complete a real fetch."
        )
        XCTAssertTrue(
            waitForSummary(logged: 800, remaining: 1200, goal: 2000),
            "The historical day did not settle at 800 / 1200 / 2000."
        )

        guard let addFood = scrollToElement(
            Identifier.addFoodBreakfast,
            marker: Identifier.calories,
            direction: .up
        ) else {
            throw HarnessError(description: "The historical Breakfast Add Food control is missing.")
        }
        addFood.tap()
        let context = app.descendants(matching: .any)["search.loggingContext"]
        guard context.waitForExistence(timeout: Timeout.long) else {
            throw HarnessError(description: "Add Food did not open the shared Search screen.")
        }
        let chip = app.buttons["search.quickAdd.product:qa-apple.100.g"]
        guard chip.waitForExistence(timeout: Timeout.long) else {
            throw HarnessError(description: "The quick-add chip did not appear.")
        }
        chip.tap()
        guard app.descendants(matching: .any)["search.quickAdd.added"]
            .waitForExistence(timeout: Timeout.long) else {
            throw HarnessError(description: "Quick add did not report success.")
        }

        let back = app.navigationBars.buttons.matching(
            NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Back", "Diary")
        ).firstMatch
        guard back.waitForExistence(timeout: Timeout.normal) else {
            throw HarnessError(description: "No Back affordance reached Diary.")
        }
        back.tap()

        XCTAssertTrue(
            waitForSummary(logged: 900, remaining: 1100, goal: 2000),
            "The quick-added row did not reconcile to 900 / 1100 / 2000."
        )
        let after = try fixtureState()
        XCTAssertEqual(after.logPostAttempts, baseline.logPostAttempts + 1)
        XCTAssertEqual(after.logCount, baseline.logCount + 1)
        guard let created = after.logs.last else {
            throw HarnessError(description: "The quick-added row was not written.")
        }
        return created
    }

    /// Replaces the numeric editor amount via the field's AX label, using a
    /// double tap to select the whole token before typing the replacement.
    private func replaceAmount(with value: String) -> Bool {
        let field = app.textFields.matching(
            NSPredicate(
                format: "identifier ==[c] %@ AND label ==[c] %@",
                "diary.editor.amount", "Amount"
            )
        ).firstMatch
        guard field.waitForExistence(timeout: Timeout.normal), field.isHittable else {
            return false
        }
        field.tap()
        field.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        field.typeText(value)
        return (field.value as? String ?? "") == value
    }

    /// Captures the UNIQUE editor CollectionView by its editor-specific marker
    /// while that marker is still on screen — never the diary summary's scroll
    /// container and never a global "first pane" fallback. A non-unique or
    /// absent marker yields nil so the caller fails fast.
    private func editorCollectionView() -> XCUIElement? {
        let byAmount = app.collectionViews.containing(
            .textField, identifier: "diary.editor.amount"
        )
        if byAmount.count == 1, byAmount.element.exists { return byAmount.element }
        let byHeader = app.collectionViews.containing(
            .staticText, identifier: "diary.editor.header"
        )
        if byHeader.count == 1, byHeader.element.exists { return byHeader.element }
        return nil
    }

    /// Reveals the editor's Delete Food row by swiping INSIDE the captured
    /// editor list only, bounded to 8 swipes, until the typed Delete button is
    /// both present and hittable. The diary summary scroll container is never
    /// touched; no arbitrary "any container" fallback is used.
    private func revealEditorDeleteButton(in editorList: XCUIElement) -> XCUIElement? {
        let delete = app.buttons["diary.editor.delete"]
        if delete.exists, delete.isHittable { return delete }
        for _ in 0..<8 {
            editorList.swipeUp()
            if delete.exists, delete.isHittable { return delete }
        }
        return nil
    }

    /// Selects the UNIQUE innermost destructive confirm Button of the actual
    /// confirmation Sheet. SwiftUI renders two nested Buttons sharing the
    /// `diary.editor.delete.confirm` id and "Delete" label; only the leaf with
    /// no same-id descendant Button is the actionable one. The sheet container
    /// is waited for first; candidates are filtered structurally by descendants
    /// (never by AX order/index), and `.first` is used only after a count==1
    /// uniqueness guard. No role/order inference and no tap of the Cancel or
    /// pre-confirmation Delete Food button (both have different identifiers).
    private func uniqueDeleteConfirmationButton() -> XCUIElement? {
        let confirmID = "diary.editor.delete.confirm"
        func leafConfirm() -> XCUIElement? {
            let sheets = app.sheets
            guard sheets.count == 1, sheets.element.exists else { return nil }
            let candidates = sheets.element.descendants(matching: .button)
                .matching(identifier: confirmID).allElementsBoundByIndex
            let leaves = candidates.filter { candidate in
                candidate.descendants(matching: .button)
                    .matching(identifier: confirmID).count == 0
            }
            guard leaves.count == 1, let leaf = leaves.first, leaf.exists else { return nil }
            return leaf
        }
        guard CalCoE2E.waitUntil(timeout: Timeout.normal, condition: {
            leafConfirm() != nil
        }) else { return nil }
        return leafConfirm()
    }

    /// Asserts a mutation notice against the ACTUAL exported AX hierarchy: the
    /// message is the unique typed StaticText carrying `diary.mutationNotice`
    /// (the Image sibling shares the ID, so an untyped `.any` query is
    /// ambiguous), and the title is the parent Other's AX value, selected by a
    /// containing/matching query — never a broad title match that could hit a
    /// log row. Polling happens only in waitUntil; every check is an XCT assert.
    private func assertNotice(message: String, title: String) {
        let noticeID = "diary.mutationNotice"
        let messageQuery = app.staticTexts.matching(identifier: noticeID)
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                messageQuery.count == 1 && messageQuery.element.exists
            },
            "The mutation notice message did not appear as a unique static text."
        )
        XCTAssertEqual(
            messageQuery.count, 1,
            "Expected exactly one mutation notice message static text."
        )
        let messageText = messageQuery.element.label.isEmpty
            ? (messageQuery.element.value as? String ?? "")
            : messageQuery.element.label
        XCTAssertTrue(
            messageText.localizedCaseInsensitiveContains(message),
            "The notice is not the localized \(message) message: \(messageText)"
        )

        let titleQuery = app.otherElements
            .containing(.staticText, identifier: noticeID)
            .matching(NSPredicate(format: "value == %@", title))
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                titleQuery.count == 1 && titleQuery.element.exists
            },
            "The mutation notice title did not appear as a unique parent value."
        )
        XCTAssertEqual(
            titleQuery.count, 1,
            "Expected exactly one mutation notice parent with title \(title)."
        )
        XCTAssertEqual(
            titleQuery.element.value as? String ?? "", title,
            "The notice title is not \(title)."
        )
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        app.launchEnvironment[QA.nativeFlag] = "1"
        return app
    }

    private func launchSignedIn() throws -> Bool {
        app = makeApp()
        app.launch()
        guard CalCoE2E.waitUntil(timeout: Timeout.short, condition: {
            self.app.state == .runningForeground
                && (CalCoE2E.isLoginFormVisible(in: self.app)
                    || CalCoE2E.isLoadedDiary(in: self.app)
                    || self.app.descendants(matching: .any)["auth.session.restoreFailed"].exists)
        }) else {
            XCTFail("The Test app did not reach a live launch surface.")
            return false
        }
        try CalCoE2E.requireFreshLogin(in: app)
        try signInFixture()
        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long) else {
            XCTFail(
                "Fixture sign-in did not reach the diary. \(app.debugDescription)"
            )
            return false
        }
        guard app.descendants(matching: .any)[Identifier.nativeMarker]
            .waitForExistence(timeout: Timeout.normal) else {
            XCTFail("The native diary marker is absent; CALCO_NATIVE_DIARY_QA was not honored.")
            return false
        }
        guard waitForFetchCount(atLeast: 1) else {
            XCTFail("The diary never completed its initial fixture fetch.")
            return false
        }
        return true
    }

    /// The fixture password is a published nonsecret value. Direct typing keeps
    /// this harness free of the simulator paste-permission skip path.
    private func signInFixture() throws {
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        guard username.waitForExistence(timeout: Timeout.normal),
              password.waitForExistence(timeout: Timeout.normal) else {
            throw HarnessError(description: "The fixture login form did not appear.")
        }
        username.tap()
        username.typeText(QA.username)
        password.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short) else {
            throw HarnessError(description: "The login keyboard did not appear.")
        }
        password.typeText(QA.password)
        XCTAssertFalse(
            (password.value as? String ?? "").isEmpty,
            "The fixture password did not populate the secure field."
        )
        let keyboardSubmit = app.buttons["auth.login.keyboard.submit"]
        if keyboardSubmit.exists, keyboardSubmit.isHittable {
            keyboardSubmit.tap()
        } else {
            app.buttons["auth.login.submit"].tap()
        }
    }

    // MARK: - Stable AX readers

    private func tap(_ identifier: String) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        guard element.waitForExistence(timeout: Timeout.normal), element.isHittable else {
            return false
        }
        element.tap()
        return true
    }

    private func isTodaySelected() -> Bool {
        let label = app.descendants(matching: .any)[Identifier.calendar].label
        return label.localizedCaseInsensitiveContains("today")
    }

    private func readCalorieSummary() -> CalorieSummary? {
        guard app.descendants(matching: .any)[Identifier.calories].exists else { return nil }
        let remainingNode = app.descendants(matching: .any)[Identifier.remaining]
        let remainingFrame = remainingNode.exists
            && remainingNode.frame.width > 0
            && remainingNode.frame.height > 0
            ? remainingNode.frame.insetBy(dx: -1, dy: -1)
            : nil

        // Logged is the only standalone integer leaf outside the remaining
        // subtree. The goal caption ("of 2,000 kcal") is not a pure integer.
        var loggedCandidates: [Int] = []
        var goalCandidates: [Int] = []
        let texts = app.descendants(matching: .any)[Identifier.calories]
            .descendants(matching: .staticText).allElementsBoundByIndex
        for text in texts {
            let label = text.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.identifier == Identifier.remaining { continue }
            if let frame = remainingFrame, frame.contains(text.frame) { continue }
            if label.localizedCaseInsensitiveContains("kcal"),
               label.localizedCaseInsensitiveContains("of ") {
                goalCandidates.append(contentsOf: Self.formattedIntegers(in: label))
                continue
            }
            if let value = Self.parseFormattedInteger(label) {
                loggedCandidates.append(value)
            }
        }
        guard loggedCandidates.count == 1, goalCandidates.count == 1 else { return nil }
        let remainingLabel = remainingNode.label.isEmpty
            ? (remainingNode.value as? String ?? "")
            : remainingNode.label
        guard let remaining = Self.formattedIntegers(in: remainingLabel).first else { return nil }
        return CalorieSummary(
            logged: loggedCandidates[0],
            remaining: remaining,
            goal: goalCandidates[0]
        )
    }

    private func readMacroLabel(_ identifier: String) -> String? {
        let node = app.descendants(matching: .any)[identifier]
        guard node.exists else { return nil }
        let label = node.label.isEmpty ? (node.value as? String ?? "") : node.label
        return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
    }

    private func readMacroNumbers(_ identifier: String) -> (current: Int, target: Int)? {
        guard let label = readMacroLabel(identifier) else { return nil }
        let values = Self.formattedIntegers(in: label)
        guard values.count == 2 else { return nil }
        return (values[0], values[1])
    }

    /// Extracts every grouped-integer run from an AX label, independent of word
    /// boundaries (SwiftUI may combine children without an intervening space).
    private static func formattedIntegers(in text: String) -> [Int] {
        let separators: Set<Character> = [",", ".", " ", "\u{00A0}", "\u{202F}", "'"]
        var result: [Int] = []
        var current = ""
        for character in text {
            if ("0"..."9").contains(character) || separators.contains(character) {
                current.append(character)
            } else {
                if let value = parseFormattedInteger(current) { result.append(value) }
                current = ""
            }
        }
        if let value = parseFormattedInteger(current) { result.append(value) }
        return result
    }

    /// Strip locale grouping separators, then parse the exact integer value.
    /// Only digits and grouping separators are accepted; decimals and values
    /// with surrounding words are rejected so exact boundaries are retained.
    private static func parseFormattedInteger(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separators: Set<Character> = [",", ".", " ", "\u{00A0}", "\u{202F}", "'"]
        guard trimmed.allSatisfy({ ("0"..."9").contains($0) || separators.contains($0) }) else {
            return nil
        }
        let digits = trimmed.filter { ("0"..."9").contains($0) }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private func fetchCount() -> Int? {
        let marker = app.descendants(matching: .any)[Identifier.fetchCount]
        guard marker.exists else { return nil }
        let raw = ((marker.value as? String) ?? marker.label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(raw)
    }

    private func waitForFetchCount(atLeast minimum: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.long) { (self.fetchCount() ?? -1) >= minimum }
    }

    private func waitForFetchCount(greaterThan previous: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.long) { (self.fetchCount() ?? -1) > previous }
    }

    private func waitForSummary(logged: Int, remaining: Int, goal: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.long) {
            guard let summary = self.readCalorieSummary() else { return false }
            return summary.logged == logged
                && summary.remaining == remaining
                && summary.goal == goal
        }
    }

    private func selectMenuOption(_ label: String) -> Bool {
        let option = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", label)
        ).firstMatch
        guard option.waitForExistence(timeout: Timeout.short), option.isHittable else {
            return false
        }
        option.tap()
        return true
    }

    // MARK: - Write helpers (explicit barriers, typed fixture state)

    private func openLatestBreakfastReview() throws {
        guard let latest = scrollToElement(
            Identifier.latestBreakfast,
            marker: Identifier.calories,
            direction: .up
        ) else {
            throw HarnessError(description: "The Breakfast Log latest control is not reachable.")
        }
        latest.tap()
        guard app.descendants(matching: .any)[Identifier.latestReview]
            .waitForExistence(timeout: Timeout.long) else {
            throw HarnessError(description: "Log latest did not open its review step.")
        }
    }

    private func assertHistoricalReviewItems() {
        for identifier in Identifier.historicalItemIDs {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].exists,
                "The review is missing source item \(identifier)."
            )
        }
    }

    private func submitLatest() -> Bool {
        let button = app.buttons[Identifier.latestSubmit]
        guard button.waitForExistence(timeout: Timeout.normal),
              button.isHittable, button.isEnabled else {
            return false
        }
        button.tap()
        return true
    }

    /// The busy barrier is explicit state, never a sleep or duration guess.
    private func waitForSubmitBusy() -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.normal) {
            let submit = self.app.buttons[Identifier.latestSubmit]
            let cancel = self.app.buttons[Identifier.latestCancel]
            return submit.exists && cancel.exists && !submit.isEnabled && !cancel.isEnabled
        }
    }

    private func waitForSubmitEnabled() -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.normal) {
            let submit = self.app.buttons[Identifier.latestSubmit]
            let cancel = self.app.buttons[Identifier.latestCancel]
            return submit.exists && cancel.exists && submit.isEnabled && cancel.isEnabled
        }
    }

    private func readSheetError() -> String? {
        // SwiftUI propagates the error ID to both an Image and a StaticText.
        // Query the text type only and require exactly one match before read.
        let matches = app.staticTexts.matching(identifier: Identifier.sheetLatestError)
        XCTAssertEqual(
            matches.count, 1,
            "Expected exactly one review-error static text, not an inherited ID."
        )
        guard matches.count == 1 else { return nil }
        let node = matches.element
        guard node.exists, node.frame.width > 0, node.frame.height > 0 else { return nil }
        let label = node.label.isEmpty ? (node.value as? String ?? "") : node.label
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func waitForFixtureState(
        timeout: TimeInterval = Timeout.normal,
        condition: @escaping (FixtureState) -> Bool
    ) -> Bool {
        CalCoE2E.waitUntil(timeout: timeout) {
            guard let state = try? self.fixtureState() else { return false }
            return condition(state)
        }
    }

    private func assertExactMacroTotals(protein: Int, carbs: Int, fat: Int) {
        let expectations: [(String, Int, Int)] = [
            (Identifier.protein, protein, 150),
            (Identifier.carbs, carbs, 250),
            (Identifier.fat, fat, 70),
        ]
        for (identifier, current, target) in expectations {
            XCTAssertTrue(
                CalCoE2E.waitUntil(timeout: Timeout.normal) {
                    guard let macro = self.readMacroNumbers(identifier) else { return false }
                    return macro.current == current && macro.target == target
                },
                "\(identifier) did not settle at \(current)/\(target) g."
            )
        }
    }

    private func assertCreatedBatchLogs(_ state: FixtureState, day: String) {
        // Baseline fixture IDs: len(state.logs)+index+1 is evaluated after each
        // append, so two items on an 8-log seed are batch-log-9 and batch-log-11.
        let expectedIDs = ["batch-log-9", "batch-log-11"]
        for identifier in expectedIDs {
            XCTAssertTrue(
                state.logs.contains { $0.id == identifier },
                "\(identifier) was not created by the batch."
            )
        }
        let created = state.logs.filter { expectedIDs.contains($0.id) }
        XCTAssertEqual(created.count, 2, "Expected exactly two created batch logs.")
        for log in created {
            XCTAssertEqual(log.date, day, "\(log.id) was not written to Today.")
            XCTAssertEqual(log.mealSlot, "breakfast", "\(log.id) used the wrong meal slot.")
            XCTAssertEqual(log.amount, "100", "\(log.id) lost the captured quantity.")
            XCTAssertEqual(log.unit, "g", "\(log.id) lost the captured unit.")
        }
    }

    // MARK: - Bounded scroll (no combined-text equality over the whole screen)

    private func scrollContainer(marker: String) -> XCUIElement? {
        let candidates = app.scrollViews.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
        return candidates.first { $0.exists && $0.descendants(matching: .any)[marker].exists }
            ?? candidates.first { $0.exists }
    }

    private func scrollToElement(
        _ identifier: String,
        marker: String,
        direction: ScrollDirection,
        maxSwipes: Int = 14
    ) -> XCUIElement? {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists, element.isHittable { return element }
        guard let container = scrollContainer(marker: marker) else {
            return element.exists ? element : nil
        }
        for _ in 0..<maxSwipes {
            switch direction {
            case .up: container.swipeUp()
            }
            if element.exists, element.isHittable { return element }
        }
        return element.exists ? element : nil
    }

    private func collectHistoricalLogIDs(maxSwipes: Int = 18) -> Set<String> {
        let wanted = Set(Identifier.historicalLogIDs)
        var found: Set<String> = []
        guard let container = scrollContainer(marker: Identifier.calories) else { return found }
        for _ in 0..<maxSwipes {
            for identifier in wanted where !found.contains(identifier) {
                if app.descendants(matching: .any)[identifier].exists {
                    found.insert(identifier)
                }
            }
            if found == wanted { break }
            container.swipeUp()
        }
        return found
    }

    /// Replaces a settings goal field with an exact typed value. A double tap
    /// selects the whole numeric token so no stale default digits survive.
    private func replaceGoalField(_ identifier: String, with value: String) -> Bool {
        let field = app.textFields.matching(
            NSPredicate(format: "identifier ==[c] %@", identifier)
        ).firstMatch
        guard field.waitForExistence(timeout: Timeout.normal), field.isHittable else {
            return false
        }
        field.tap()
        field.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        field.typeText(value)
        return (field.value as? String ?? "") == value
    }

    private func goalFieldValue(_ identifier: String) -> String? {
        let field = app.textFields.matching(
            NSPredicate(format: "identifier ==[c] %@", identifier)
        ).firstMatch
        guard field.exists else { return nil }
        let value = (field.value as? String ?? field.label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Counter reads come only from the visible Diary summary marker. A hidden
    /// surface is never reported as a fabricated sentinel.
    private func requireVisibleFetchCount(_ message: String) throws -> Int {
        guard waitForDiaryCounterVisible(), let count = fetchCount(), count >= 0 else {
            throw HarnessError(description: message)
        }
        return count
    }

    // MARK: - Settings meal-slot helpers (12th test only)

    /// An off-screen AX node may still have a nonzero frame. Scroll only until
    /// the actual top-of-diary control is hittable; never overscroll a visible
    /// control and accidentally trigger pull-to-refresh.
    private func revealDiaryTopControl(_ identifier: String) -> Bool {
        let control = app.descendants(matching: .any)[identifier]
        if control.exists, control.isHittable { return true }
        guard let container = scrollContainer(marker: Identifier.calories) else { return false }
        for _ in 0..<14 {
            container.swipeDown()
            if control.exists, control.isHittable { return true }
        }
        return false
    }

    /// The settings Form is a collection/table/scroll view carrying both the
    /// goal fields and the meal-slot rows. Bounded scrolls stay inside it.
    private func settingsForm() -> XCUIElement? {
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        return candidates.first { container in
            container.descendants(matching: .any)[Identifier.settingsCalories].exists
                || container.descendants(matching: .any)[Identifier.settingsBreakfast].exists
        }
    }

    /// SwiftUI can expose both the Form row and an inherited child under the
    /// same identifier. The row is the element carrying a boolean value; a
    /// scoped identifier predicate keeps this out of label-based heuristics.
    private func settingsRow(_ identifier: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier ==[c] %@", identifier)
        let matches = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
            .filter { $0.exists }
        guard !matches.isEmpty else { return nil }
        if let valued = matches.first(where: { slotToggleValue($0) != nil && $0.isHittable }) {
            return valued
        }
        return matches.first(where: { $0.isHittable }) ?? matches.first
    }

    private func slotToggleValue(_ element: XCUIElement) -> Bool? {
        let value = (element.value as? String ?? "").lowercased()
        if value == "1" || value == "true" || value == "on" { return true }
        if value == "0" || value == "false" || value == "off" { return false }
        return nil
    }

    @discardableResult
    private func scrollSettingsTo(_ identifier: String) -> XCUIElement? {
        if let row = settingsRow(identifier), row.exists, row.isHittable { return row }
        guard let form = settingsForm() else { return settingsRow(identifier) }
        for _ in 0..<12 {
            form.swipeUp()
            if let row = settingsRow(identifier), row.exists, row.isHittable { return row }
        }
        for _ in 0..<12 {
            form.swipeDown()
            if let row = settingsRow(identifier), row.exists, row.isHittable { return row }
        }
        return settingsRow(identifier)
    }

    private func slotToggleIsOn(_ identifier: String) -> Bool? {
        guard let toggle = scrollSettingsTo(identifier) else { return nil }
        return slotToggleValue(toggle)
    }

    private func setSlotToggle(_ identifier: String, on desired: Bool) {
        guard let toggle = scrollSettingsTo(identifier) else {
            XCTFail("The settings row \(identifier) is not reachable.")
            return
        }
        XCTAssertTrue(toggle.isEnabled, "The settings row \(identifier) is disabled.")
        guard let current = slotToggleValue(toggle) else {
            XCTFail("The settings row \(identifier) has no readable boolean value.")
            return
        }
        if current != desired {
            // The accessibility element spans the Form row; tap the trailing
            // switch side explicitly, as in SettingsUITests.setToggle.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                self.slotToggleIsOn(identifier) == desired
            },
            "The settings row \(identifier) did not reach \(desired)."
        )
    }

    /// Percent is a global UI setting; both the menu label and the macro rows
    /// must agree, on either date.
    private func assertMacroModePercent() -> Bool {
        _ = waitForDiaryCounterVisible()
        let menu = app.descendants(matching: .any)[Identifier.macroMode]
        guard menu.exists, menu.label.localizedCaseInsensitiveContains("Percent") else {
            return false
        }
        for identifier in [Identifier.protein, Identifier.carbs, Identifier.fat] {
            guard let label = readMacroLabel(identifier), label.contains("%") else { return false }
        }
        return true
    }

    /// Inspect successive materialized viewports from the summary to the last
    /// slot. Every enabled slot must be reachable, and neither disabled slot
    /// may expose its Add Food or latest control anywhere along that traversal.
    private func assertDisabledEmptySectionsAbsentOnToday() -> Bool {
        guard revealDiaryTopControl(Identifier.calendar) else { return false }
        guard let container = scrollContainer(marker: Identifier.calories) else { return false }
        let disabled = [
            Identifier.addFoodBreakfast, Identifier.addFoodLunch,
            Identifier.latestBreakfast, Identifier.latestLunch,
        ]
        let enabled = Set([
            Identifier.addFoodDinner, Identifier.addFoodSnack, Identifier.addFoodLateNightSnack,
        ])
        var found: Set<String> = []
        for _ in 0..<14 {
            for identifier in disabled where app.descendants(matching: .any)[identifier].exists {
                return false
            }
            for identifier in enabled {
                let control = app.descendants(matching: .any)[identifier]
                if control.exists, control.isHittable { found.insert(identifier) }
            }
            if found == enabled { return true }
            container.swipeUp()
        }
        return false
    }

    // MARK: - Loopback fixture helpers (small, scoped clones)

    private func requireMockFixture() throws {
        let response: MockResponse
        do {
            response = try mockRequest(method: "GET", path: "/__qa/health")
        } catch {
            throw XCTSkip(
                "NativeCompletionQAMockServer.py is not running at \(QA.baseURL): \(error)"
            )
        }
        guard response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.data)
                as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            throw XCTSkip(
                "A service is listening at \(QA.baseURL) but it is not the "
                    + "NativeCompletionQAMockServer fixture."
            )
        }
    }

    /// Write tests skip on an older fixture; the current fixture advertises
    /// both opt-in names so no capability is inferred from a response shape.
    private func requireBatchWriteCapabilities() throws {
        let response = try mockRequest(method: "GET", path: "/__qa/health")
        guard response.status == 200,
              let health = try? JSONDecoder().decode(FixtureHealth.self, from: response.data),
              health.fixture == QA.fixtureMarker,
              health.capabilities["fail_batch_once"] == true,
              health.capabilities["log_post_hold"] == true,
              !health.injectedTransientMessage.isEmpty else {
            throw XCTSkip(
                "The QA fixture does not advertise fail_batch_once and "
                    + "log_post_hold write capabilities."
            )
        }
    }

    private func injectedTransientMessage() throws -> String {
        let response = try mockRequest(method: "GET", path: "/__qa/health")
        let health = try JSONDecoder().decode(FixtureHealth.self, from: response.data)
        guard !health.injectedTransientMessage.isEmpty else {
            throw HarnessError(description: "The fixture did not publish its transient message.")
        }
        return health.injectedTransientMessage
    }

    /// Default arguments reproduce the historical reset body exactly; write
    /// tests opt in explicitly. `ownedBatchHold` is armed only for a held test.
    private func resetFixture(failBatchOnce: Bool = false, holdBatchPost: Bool = false) throws {
        var body: [String: Any] = [
            "today": Self.isoDay(Date()),
            "log_post": "success",
            "seed_logs": true,
            "assistant_enabled": false,
        ]
        if failBatchOnce { body["fail_batch_once"] = true }
        if holdBatchPost { body["log_post_hold"] = true }
        ownedBatchHold = holdBatchPost
        let response = try mockRequest(method: "POST", path: "/__qa/reset", json: body)
        XCTAssertEqual(response.status, 200, "The native QA fixture rejected its reset.")
    }

    private func fixtureState() throws -> FixtureState {
        let response = try mockRequest(method: "GET", path: "/__qa/state")
        XCTAssertEqual(response.status, 200, "The fixture state endpoint is unavailable.")
        guard let object = try JSONSerialization.jsonObject(with: response.data)
                as? [String: Any],
              let canonicalData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys]
              ),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            throw HarnessError(description: "The fixture returned malformed state.")
        }
        // The preexisting three fields keep their original JSONSerialization
        // source; the additive fields are decoded only when advertised.
        let payload = try? JSONDecoder().decode(FixtureStatePayload.self, from: response.data)
        return FixtureState(
            canonical: canonical,
            today: payload?.today ?? "",
            logCount: object["log_count"] as? Int ?? -1,
            logPostAttempts: object["log_post_attempts"] as? Int ?? -1,
            batchCommits: payload?.logBatchPostCommits ?? -1,
            batchInFlight: payload?.logBatchPostInFlight ?? -1,
            failBatchOnce: payload?.failBatchOnce ?? false,
            batchFailOnceArmed: payload?.batchFailOnceArmed ?? false,
            holdEnabled: payload?.logPostHold ?? false,
            epoch: payload?.fixtureEpoch ?? -1,
            logs: payload?.logs ?? [],
            typedGoalCalories: payload?.typedGoalCalories
        )
    }

    private func mockRequest(
        method: String,
        path: String,
        json: [String: Any]? = nil
    ) throws -> MockResponse {
        guard let url = URL(string: QA.baseURL + path) else {
            throw HarnessError(description: "Invalid QA fixture URL: \(QA.baseURL + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let box = ResponseBox()
        let expectation = expectation(description: "QA fixture \(method) \(path)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data ?? Data()
            box.status = (response as? HTTPURLResponse)?.statusCode ?? -1
            box.error = error
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 15)
        if let error = box.error { throw error }
        return MockResponse(status: box.status, data: box.data)
    }

    // MARK: - External mutation fanout journeys (13–15)

    private struct FanoutBaseline {
        let state: FixtureState
        let day: String
        let calendarLabel: String
        let fetches: Int
    }

    private struct FanoutLibraryCounters: Decodable, Equatable {
        let foods: Int
        let creates: Int
        let updates: Int
        let deletes: Int

        enum CodingKeys: String, CodingKey {
            case foods = "custom_food_count"
            case creates = "custom_food_create_count"
            case updates = "custom_food_update_count"
            case deletes = "custom_food_delete_count"
        }
    }

    func testNativeDiaryFoodDetailMutationRefreshesHistoricalOwnerExactlyOnce() throws {
        let baseline = try prepareHistoricalFanout()
        try openHistoricalFanoutSearch()
        // Select the actual recent food row (not its quick-add chip). This
        // journey proves FoodDetail mutation fanout, not query/debounce.
        try tapFanoutButton("search.recent.product:qa-apple")
        XCTAssertTrue(app.textFields["foodDetail.amount.field"].waitForExistence(timeout: Timeout.long),
                      "FoodDetail amount field did not load.\n\(app.debugDescription)")
        XCTAssertEqual(app.textFields["foodDetail.amount.field"].value as? String, "100",
                       "FoodDetail must retain the fixture's default 100 quantity.")
        try selectFanoutGramUnit()
        assertFanoutBreakfastSelection("FoodDetail")
        XCTAssertEqual(try fixtureState().canonical, baseline.state.canonical,
                       "Opening FoodDetail must not write.")
        try tapFanoutButton("foodDetail.submit")
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.nativeMarker]
            .waitForExistence(timeout: Timeout.long), "FoodDetail did not return to the QA Diary.")
        try assertHistoricalFanout(baseline, addedCalories: 100)
    }

    func testNativeDiaryMealsMutationRefreshesHistoricalOwnerExactlyOnce() throws {
        let baseline = try prepareHistoricalFanout()
        try openHistoricalFanoutSearch()
        try tapFanoutButton("search.openMeals")
        try tapFanoutButton("meals.list.row.qa-meal-1")
        try tapFanoutButton("meals.detail.openLog")
        let sheet = app.descendants(matching: .any)["meals.log.sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: Timeout.long),
                      "Meals log sheet did not open.\n\(app.debugDescription)")
        XCTAssertEqual(app.textFields["foodDetail.amount.field"].value as? String, "100",
                       "Meals must retain the fixture's default 100 quantity.")
        try selectFanoutGramUnit()
        assertFanoutBreakfastSelection("Meals")

        // The existing fixture previews 200 kcal, but its generic POST handler
        // authoritatively persists 100 kcal for this default 100 g quantity.
        // Do not conflate the preview with the returned server log nutrition.
        let nutrients = [("Calories", "200.00", "kcal"), ("Protein", "2.00", "g"),
                         ("Carbohydrates", "40.00", "g"), ("Fat", "1.00", "g")]
        func previewVisible() -> Bool {
            nutrients.allSatisfy { nutrient in
                [nutrient.0, nutrient.1, nutrient.2].allSatisfy { label in
                    sheet.descendants(matching: .staticText)
                        .matching(NSPredicate(format: "label == %@", label))
                        .allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
                }
            }
        }
        let container = try XCTUnwrap(scrollContainer(marker: "foodDetail.amount.field"))
        for _ in 0..<6 where !previewVisible() { container.swipeUp() }
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) { previewVisible() },
                      "The four exact meal preview nutrients are missing.")
        XCTAssertEqual(try fixtureState().canonical, baseline.state.canonical,
                       "Opening the Meals preview must not write.")
        try tapFanoutButton("meals.detail.log")
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) { !sheet.exists },
                       "The meal log task did not dismiss after submission.")
        // Successful logging dismisses only the task sheet. Close belongs to
        // the Meals list root, so first leave the recipe via its semantic Back.
        let recipeBacks = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@", "My Meals")
        ).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        XCTAssertEqual(recipeBacks.count, 1,
                       "Expected one recipe Back action labelled My Meals.\n\(app.debugDescription)")
        try XCTUnwrap(recipeBacks.count == 1 ? recipeBacks.first : nil).tap()
        XCTAssertTrue(app.descendants(matching: .any)["meals.list"]
            .waitForExistence(timeout: Timeout.normal),
                      "Recipe Back did not reach the Meals list root.\n\(app.debugDescription)")
        try tapFanoutButton("meals.close")
        try returnFromFanoutSearch()
        try assertHistoricalFanout(baseline, addedCalories: 100)
    }

    /// Library's current UI manages food metadata; it has no logging entry.
    /// A genuine manual create must therefore leave the Diary owner untouched.
    /// This is not GUI evidence for the separate Library logging callback.
    func testNativeDiaryLibraryMetadataSaveDoesNotRefreshOrMutateDiary() throws {
        let baseline = try prepareHistoricalFanout()
        let counters = try fanoutLibraryCounters()
        try tapFanoutButton("app.tab.library")
        try tapFanoutButton("library.foods")
        XCTAssertTrue(app.descendants(matching: .any)["library.empty"]
            .waitForExistence(timeout: Timeout.long), "The reset Library should be empty.")
        try tapFanoutButton("library.add")
        try tapFanoutButton("library.add.custom")
        let name = app.textFields["library.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.long),
                      "Manual Library editor did not open.\n\(app.debugDescription)")
        name.tap()
        name.typeText("Historical metadata food")
        XCTAssertEqual(name.value as? String, "Historical metadata food",
                       "The manual editor did not retain the food name.")
        try dismissFanoutLibraryKeyboard()
        for (code, value) in [("ENERGY_KCAL", "175"), ("PROTEIN_G", "10"),
                              ("CARBS_G", "20"), ("FAT_G", "5")] {
            let field = try revealFanoutControl("library.nutrient.\(code).field",
                                               marker: "library.editor.name")
            field.tap()
            let oldValue = try XCTUnwrap(field.value as? String)
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + value)
            XCTAssertEqual(field.value as? String, value, "Manual Library nutrient \(code) was not retained.")
            try dismissFanoutLibraryKeyboard()
        }
        XCTAssertEqual(try fixtureState().canonical, baseline.state.canonical,
                       "Editing metadata must not persist anything before Save.")
        XCTAssertEqual(try fanoutLibraryCounters(), counters, "The unsaved editor wrote custom-food metadata.")
        try tapFanoutButton("library.editor.save")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.row."))
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) {
            rows.count == 1 && rows.element.exists
                && rows.element.label.contains("Historical metadata food")
        }, "Exactly one named saved metadata row did not return to Library.\n\(app.debugDescription)")
        let saved = try fanoutLibraryCounters()
        XCTAssertEqual(saved.foods, counters.foods + 1, "Manual Save must retain exactly one custom food.")
        XCTAssertEqual(saved.creates, counters.creates + 1, "Manual Save must issue exactly one create.")
        XCTAssertEqual(saved.updates, counters.updates, "Manual create must not update an existing food.")
        XCTAssertEqual(saved.deletes, counters.deletes, "Manual create must not delete any food.")
        try tapFanoutButton(Identifier.diaryTab)
        try assertHistoricalMetadataUnchanged(baseline)
        XCTAssertEqual(try fanoutLibraryCounters(), saved,
                       "Returning to Diary and inspecting Settings must not rewrite metadata.")
    }

    /// Establish a nondefault global macro mode and persisted slot preference
    /// before measuring the mutation. No Settings save is a log write.
    private func prepareHistoricalFanout() throws -> FanoutBaseline {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        XCTAssertTrue(tap(Identifier.previousDay))
        XCTAssertTrue(waitForSummary(logged: 800, remaining: 1200, goal: 2000))
        XCTAssertTrue(tap(Identifier.macroMode))
        XCTAssertTrue(selectMenuOption("Percent"))
        XCTAssertTrue(assertMacroModePercent())
        XCTAssertTrue(tap(Identifier.manageSlots))
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.settingsSheet]
            .waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) {
            self.settingsRow(Identifier.settingsBreakfast) != nil
        })
        for identifier in [Identifier.settingsBreakfast, Identifier.settingsLunch,
                           Identifier.settingsDinner, Identifier.settingsSnack] {
            setSlotToggle(identifier, on: true)
        }
        setSlotToggle(Identifier.settingsLateNightSnack, on: false)
        try tapFanoutButton(Identifier.settingsSlotsSave)
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.settingsSlotsSaved]
            .waitForExistence(timeout: Timeout.long))
        try tapFanoutButton(Identifier.diaryTab)
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.normal) {
            !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
        })
        XCTAssertTrue(waitForSummary(logged: 800, remaining: 1200, goal: 2000))
        let fetches = try requireVisibleFetchCount("Missing pre-mutation Diary fetch count.")
        let state = try fixtureState()
        XCTAssertEqual(state.logCount, 8)
        XCTAssertEqual(state.logs.count, 8)
        XCTAssertEqual(state.logPostAttempts, 0)
        XCTAssertEqual(state.typedGoalCalories, 2000)
        let day = Self.isoDay(historicalDayDate(fromFixtureToday: state.today))
        XCTAssertTrue(state.logs.allSatisfy { $0.date == day })
        let calendarLabel = app.descendants(matching: .any)[Identifier.calendar].label
        XCTAssertFalse(calendarLabel.isEmpty)
        XCTAssertFalse(isTodaySelected())
        return FanoutBaseline(state: state, day: day, calendarLabel: calendarLabel, fetches: fetches)
    }

    private func openHistoricalFanoutSearch() throws {
        let add = try revealFanoutControl(Identifier.addFoodBreakfast, marker: Identifier.calories)
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["search.loggingContext"]
            .waitForExistence(timeout: Timeout.long))
        XCTAssertTrue(app.descendants(matching: .any)["search.loggingContext"].label.contains("Breakfast"))
    }

    private func returnFromFanoutSearch() throws {
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: Timeout.normal))
        let backs = app.navigationBars.buttons.matching(
            NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Back", "Diary")
        ).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        XCTAssertEqual(backs.count, 1, "Expected one semantic Search Back action.")
        try XCTUnwrap(backs.count == 1 ? backs.first : nil).tap()
    }

    private func assertHistoricalFanout(_ baseline: FanoutBaseline, addedCalories: Int) throws {
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.nativeMarker]
            .waitForExistence(timeout: Timeout.long))
        XCTAssertTrue(revealDiaryTopControl(Identifier.calendar))
        XCTAssertTrue(waitForSummary(logged: 800 + addedCalories,
                                    remaining: 1200 - addedCalories, goal: 2000))
        XCTAssertEqual(app.descendants(matching: .any)[Identifier.calendar].label, baseline.calendarLabel)
        XCTAssertTrue(assertMacroModePercent(), "The mutation reset Percent macro mode.")
        let count = try requireVisibleFetchCount("Missing post-mutation Diary fetch count.")
        XCTAssertEqual(count, baseline.fetches + 1, "External mutation must refresh Diary exactly once.")
        let after = try fixtureState()
        XCTAssertEqual(after.logPostAttempts, baseline.state.logPostAttempts + 1,
                       "One external log submission must issue exactly one POST.")
        XCTAssertEqual(after.logCount, baseline.state.logCount + 1,
                       "One external log submission must persist exactly one row.")
        XCTAssertEqual(after.typedGoalCalories, baseline.state.typedGoalCalories,
                       "External logging changed the persisted goal.")
        XCTAssertEqual(after.batchCommits, baseline.state.batchCommits, "Expected an individual log write.")
        let originalIDs = Set(baseline.state.logs.map(\.id))
        let created = after.logs.filter { !originalIDs.contains($0.id) }
        XCTAssertEqual(created.count, 1)
        let log = try XCTUnwrap(created.count == 1 ? created.first : nil)
        XCTAssertEqual(log.date, baseline.day, "The POST lost the captured historical date.")
        XCTAssertEqual(log.mealSlot, "breakfast", "The POST lost exact captured slot breakfast.")
        XCTAssertEqual(log.amount, "100", "The POST lost exact quantity 100.")
        XCTAssertEqual(log.unit, "g", "The POST did not persist exact Gram code g.")
        for old in baseline.state.logs {
            let retained = try XCTUnwrap(after.logs.first { $0.id == old.id })
            XCTAssertEqual(retained.date, old.date)
            XCTAssertEqual(retained.mealSlot, old.mealSlot)
            XCTAssertEqual(retained.amount, old.amount)
            XCTAssertEqual(retained.unit, old.unit)
        }
        XCTAssertEqual(collectHistoricalLogIDs(), Set(Identifier.historicalLogIDs))
        XCTAssertTrue(revealDiaryTopControl(Identifier.calendar))
        let row = try revealFanoutControl("diary.log.\(log.id)", marker: Identifier.calories)
        XCTAssertTrue(row.exists && row.isHittable, "The authoritative new row is missing.")
        try assertFanoutSettingsPreserved(baseline, addedCalories: addedCalories,
                                         expectedFetches: baseline.fetches + 1, state: after)
    }

    private func assertHistoricalMetadataUnchanged(_ baseline: FanoutBaseline) throws {
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.nativeMarker]
            .waitForExistence(timeout: Timeout.long), "Metadata Save did not return to the QA Diary.")
        XCTAssertTrue(revealDiaryTopControl(Identifier.calendar), "Historical calendar is unreachable.")
        XCTAssertTrue(waitForSummary(logged: 800, remaining: 1200, goal: 2000),
                      "Metadata Save changed the historical 800/1200/2000 summary.")
        XCTAssertEqual(app.descendants(matching: .any)[Identifier.calendar].label, baseline.calendarLabel,
                       "Metadata Save changed the selected historical date.")
        XCTAssertTrue(assertMacroModePercent(), "Metadata Save reset Percent mode.")
        XCTAssertEqual(try requireVisibleFetchCount("Missing metadata return fetch count."), baseline.fetches,
                       "A metadata-only Save must not refresh Diary.")
        let after = try fixtureState()
        XCTAssertEqual(after.logPostAttempts, baseline.state.logPostAttempts,
                       "Metadata Save must issue zero log POSTs.")
        XCTAssertEqual(after.logCount, 8, "Metadata Save must not add or remove a log.")
        XCTAssertEqual(after.logs.map(\.id), baseline.state.logs.map(\.id),
                       "Metadata Save changed the original eight log identities or order.")
        for old in baseline.state.logs {
            let retained = try XCTUnwrap(after.logs.first { $0.id == old.id }, "Missing history row \(old.id).")
            XCTAssertEqual(retained.date, old.date, "Metadata Save changed \(old.id)'s date.")
            XCTAssertEqual(retained.mealSlot, old.mealSlot, "Metadata Save changed \(old.id)'s slot.")
            XCTAssertEqual(retained.amount, old.amount, "Metadata Save changed \(old.id)'s amount.")
            XCTAssertEqual(retained.unit, old.unit, "Metadata Save changed \(old.id)'s unit.")
        }
        XCTAssertEqual(after.batchCommits, baseline.state.batchCommits, "Metadata Save committed a log batch.")
        XCTAssertEqual(after.typedGoalCalories, baseline.state.typedGoalCalories, "Metadata Save changed the goal.")
        XCTAssertEqual(collectHistoricalLogIDs(), Set(Identifier.historicalLogIDs),
                       "Metadata Save did not retain all eight rendered historical rows.")
        try assertFanoutSettingsPreserved(baseline, addedCalories: 0,
                                         expectedFetches: baseline.fetches, state: after)
    }

    private func assertFanoutSettingsPreserved(
        _ baseline: FanoutBaseline, addedCalories: Int, expectedFetches: Int, state: FixtureState
    ) throws {
        XCTAssertTrue(revealDiaryTopControl(Identifier.manageSlots))
        XCTAssertTrue(tap(Identifier.manageSlots))
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.settingsSheet]
            .waitForExistence(timeout: Timeout.normal))
        // Settings retains its previous scroll position near meal slots. Each
        // goal must be materialized before reading its exact value; nil is not
        // an acceptable substitute for a preserved goal.
        for (identifier, expected) in [
            (Identifier.settingsCalories, "2000"), (Identifier.settingsProtein, "150"),
            (Identifier.settingsCarbs, "250"), (Identifier.settingsFat, "70"),
        ] {
            let field = try XCTUnwrap(scrollSettingsTo(identifier),
                                     "Cannot reveal goal \(identifier).\n\(app.debugDescription)")
            XCTAssertTrue(field.exists && field.isHittable,
                          "Goal \(identifier) is not reachable.\n\(app.debugDescription)")
            XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) {
                self.goalFieldValue(identifier) == expected
            }, "Goal \(identifier) must remain exactly \(expected); "
                + "actual=\(String(describing: goalFieldValue(identifier))).\n" + app.debugDescription)
            XCTAssertEqual(goalFieldValue(identifier), expected,
                           "Goal \(identifier) changed.\n\(app.debugDescription)")
        }
        for identifier in [Identifier.settingsBreakfast, Identifier.settingsLunch,
                           Identifier.settingsDinner, Identifier.settingsSnack] {
            XCTAssertEqual(slotToggleIsOn(identifier), true)
        }
        XCTAssertEqual(slotToggleIsOn(Identifier.settingsLateNightSnack), false)
        try tapFanoutButton(Identifier.diaryTab)
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.normal) {
            !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
        })
        XCTAssertTrue(revealDiaryTopControl(Identifier.calendar))
        XCTAssertTrue(waitForSummary(logged: 800 + addedCalories,
                                    remaining: 1200 - addedCalories, goal: 2000))
        XCTAssertEqual(try requireVisibleFetchCount("Missing final Diary fetch count."), expectedFetches,
                       "Inspecting persisted Settings changed the expected Diary fetch count.")
        XCTAssertEqual(app.descendants(matching: .any)[Identifier.calendar].label, baseline.calendarLabel)
        XCTAssertTrue(assertMacroModePercent())
        XCTAssertEqual(try fixtureState().canonical, state.canonical,
                       "Inspecting persisted Settings must not cause another mutation.")
    }

    private func fanoutLibraryCounters() throws -> FanoutLibraryCounters {
        let response = try mockRequest(method: "GET", path: "/__qa/state")
        XCTAssertEqual(response.status, 200)
        return try JSONDecoder().decode(FanoutLibraryCounters.self, from: response.data)
    }

    /// The fixture's code `g` is displayed as the exact name `Gram`. Both
    /// FoodDetailView and shared LogFormView render Text(unit.name), tagged by
    /// unit.code. Select the real menu option, then verify its semantic token;
    /// the authoritative POST unit is still asserted as exactly `g` separately.
    private func selectFanoutGramUnit() throws {
        let identifier = "foodDetail.unit.picker"
        try tapFanoutButton(identifier)
        let option = app.buttons.matching(NSPredicate(format: "label == %@", "Gram"))
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.normal) {
            option.allElementsBoundByIndex.contains { $0.exists && $0.isHittable && $0.isEnabled }
        }, "Expected exact fixture unit option Gram (code g). Picker: "
            + fanoutPickerDescription(identifier) + "\n" + app.debugDescription)
        XCTAssertTrue(selectMenuOption("Gram"),
                      "Could not select exact Gram option.\n\(app.debugDescription)")
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.short) {
            let picker = self.app.buttons[identifier]
            guard picker.exists else { return false }
            let text = picker.label + " " + (picker.value as? String ?? "")
            return text.range(of: "(?:^|\\W)Gram(?:$|\\W)", options: .regularExpression) != nil
        }, "Unit selection did not settle at Gram (code g): " + fanoutPickerDescription(identifier))
    }

    private func fanoutPickerDescription(_ identifier: String) -> String {
        let picker = app.buttons[identifier]
        guard picker.exists else { return "\(identifier): missing" }
        return "\(identifier): label=\(picker.label), value=\(String(describing: picker.value)), "
            + "hittable=\(picker.isHittable), enabled=\(picker.isEnabled)"
    }

    private func assertFanoutBreakfastSelection(_ family: String) {
        let identifier = "foodDetail.mealSlot.picker"
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.normal) {
            let picker = self.app.buttons[identifier]
            guard picker.exists else { return false }
            return [picker.label, picker.value as? String ?? ""].contains { text in
                text.range(of: "(?:^|\\W)Breakfast(?:$|\\W)", options: .regularExpression) != nil
            }
        }, "\(family) must retain exact Breakfast selection: " + fanoutPickerDescription(identifier)
            + "\n" + app.debugDescription)
    }

    private func tapFanoutButton(_ identifier: String) throws {
        let query = app.buttons.matching(identifier: identifier)
        func leaves() -> [XCUIElement] {
            query.allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && $0.isEnabled
                    && $0.descendants(matching: .button).matching(identifier: identifier).count == 0
            }
        }
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) { leaves().count == 1 },
                      "Expected one actionable leaf button: \(identifier); "
                        + "matches=\(query.count), actionableLeaves=\(leaves().count).\n"
                        + app.debugDescription)
        let buttons = leaves()
        try XCTUnwrap(buttons.count == 1 ? buttons.first : nil).tap()
    }

    private func revealFanoutControl(_ identifier: String, marker: String) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists && element.isHittable { return element }
        let container = try XCTUnwrap(scrollContainer(marker: marker))
        for _ in 0..<14 {
            container.swipeUp()
            if element.exists && element.isHittable { return element }
        }
        for _ in 0..<14 {
            container.swipeDown()
            if element.exists && element.isHittable { return element }
        }
        throw HarnessError(description: "Control \(identifier) is not reachable.")
    }

    private func dismissFanoutLibraryKeyboard() throws {
        guard app.keyboards.firstMatch.exists else { return }
        try tapFanoutButton("library.editor.keyboard.done")
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.short) { !self.app.keyboards.firstMatch.exists },
                      "The manual Library editor keyboard did not dismiss.\n\(app.debugDescription)")
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
