import Foundation
import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit
#endif

// iPhone 13 mini acceptance coverage for docs/native-completion-plan.md.
//
// These tests are intentionally independent of the credentialed E2E fixture.
// They require the optional loopback-only NativeCompletionQAMockServer.py,
// which serves fake credentials, fake diary rows, and in-memory log state on
// 127.0.0.1. The app under test is still the real Test app
// (dev.calco.CalCo.Test); only the network fixture is fake. Nothing here talks
// to a live CalCo server, writes user data, or contains a real credential.
//
// Run on the booted iPhone 13 mini (375 x 812 points). Tests skip, rather than
// pass, when the mock fixture is absent or the destination is too wide.
// Feature-destination tests also skip until the corresponding native screen
// exists; the QA report records those gaps explicitly.

final class NativeCompletionUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum QA {
        static let baseURL = "http://127.0.0.1:3932"
        static let fixtureMarker = "native-completion-qa"
        static let username = "native-qa"
        static let password = "native-qa"
        static let dynamicTypeAccessibility = "UICTContentSizeCategoryAccessibilityXXXL"

        static var credentials: CalCoE2E.Credentials {
            CalCoE2E.Credentials(username: username, password: password)
        }
    }

    private enum Identifier {
        static let diarySummary = "diary.summary.calories"
        static let macros = "diary.summary.macroMode"
        static let macroMode = "diary.summary.macroMode"
        static let fetchCompletionCount = "diary.fetchCompletionCount"
        static let settings = "diary.settings"
        static let calendar = "diary.calendar"
        static let refresh = "diary.refresh"
        static let previousDay = "diary.previousDay"
        static let nextDay = "diary.nextDay"
        static let addFoodPrefix = "diary.addFood."
        static let historicalLog = "diary.log.hist-log-001"
        static let searchField = "search.field"
        static let searchResult = "search.result.qa-apple"
        static let amountField = "foodDetail.amount.field"
        static let notesField = "foodDetail.notes.field"
        static let submit = "foodDetail.submit"
        static let submitWarning = "foodDetail.submit.warning"
        static let submitError = "foodDetail.submit.error"
        static let submitSuccess = "foodDetail.submit.success"
        static let pendingBanner = "foodDetail.pending.banner"
        static let pendingBannerDiscard = "foodDetail.pending.banner.discard"
        static let pendingReview = "foodDetail.pending.review"
        static let pendingDismiss = "foodDetail.pending.dismiss"
        static let pendingRetry = "foodDetail.pending.retry"
        static let pendingDiscard = "foodDetail.pending.discard"
        static let pendingNotice = "foodDetail.pending.notice"
        static let editorAmount = "diary.editor.amount"
        static let editorUnit = "diary.editor.unit"
        static let editorNotes = "diary.editor.notes"
        static let editorKeyboardDone = "diary.editor.keyboardDone"
        static let editorSave = "diary.editor.save"
        static let editorDelete = "diary.editor.delete"
        static let editorDeleteConfirm = "diary.editor.delete.confirm"
        static let editorDeleteCancel = "diary.editor.delete.cancel"
        static let settingsSheet = "settings.sheet"
        static let settingsCancel = "settings.cancel"
        static let settingsKeyboardDone = "settings.keyboard.done"
        static let goalCalories = "settings.goals.calories"
        static let goalProtein = "settings.goals.protein"
        static let goalCarbs = "settings.goals.carbs"
        static let goalFat = "settings.goals.fat"
        static let goalsSave = "settings.goals.save"
        static let slotsSave = "settings.slots.save"
        static let breakfastToggle = "settings.slots.breakfast"
        static let lateNightToggle = "settings.slots.late_night_snack"
    }

    private enum Timeout {
        static let short: TimeInterval = 8
        static let normal: TimeInterval = 20
        static let long: TimeInterval = 40
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        try requireMockFixture()
    }

    override func tearDownWithError() throws {
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        app = nil
    }

    // MARK: - iPhone 13 mini toolbar

    func testMiniToolbarActionsStayReachableWhenCollapsed() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        let actions = [
            Identifier.settings,
            Identifier.calendar,
            Identifier.refresh,
            Identifier.previousDay,
            Identifier.nextDay,
            "auth.signOut",
        ]
        assertToolbarActionsReachable(actions)

        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The diary summary is missing on the mini."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.macroMode].exists,
            "The macro display picker is missing on the mini."
        )
        attachScreenshot(named: "iPhone-13-mini-diary-toolbar")
    }

    // MARK: - Keyboard entry

    func testMiniQuantityKeyboardEntryKeepsSubmitReachable() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        guard let addFood = scrollToElement(
            matchingPrefix: Identifier.addFoodPrefix,
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("No diary.addFood.* control was reachable on the mini.")
            return
        }
        addFood.tap()

        let search = app.descendants(matching: .any)[Identifier.searchField]
        XCTAssertTrue(search.waitForExistence(timeout: Timeout.normal), "Search did not open.")
        typeSearchQuery("Native QA", in: search)

        let result = app.buttons[Identifier.searchResult]
        XCTAssertTrue(
            result.waitForExistence(timeout: Timeout.normal),
            "The fixture search result did not appear."
        )
        XCTAssertTrue(result.isHittable, "The fixture search result is not hittable.")
        selectFixtureSearchResult()
        let amount = app.descendants(matching: .any)[Identifier.amountField]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.normal),
            "foodDetail.amount.field did not appear after selecting the fixture food."
        )
        amount.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The decimal keyboard did not appear for the quantity field."
        )

        replaceText(in: amount, with: "12.5")
        XCTAssertEqual(amount.value as? String, "12.5", "The amount field did not retain 12.5.")
        XCTAssertFalse(
            app.descendants(matching: .any)["foodDetail.amount.error"].exists,
            "A valid decimal quantity produced a validation error."
        )

        let submit = app.buttons[Identifier.submit]
        XCTAssertTrue(
            submit.exists && submit.isHittable,
            "The Log action is not hittable while the decimal keyboard is up on the mini."
        )
        XCTAssertTrue(
            app.keyboards.firstMatch.exists,
            "The keyboard disappeared before the keyboard-up reachability assertion."
        )
        attachScreenshot(named: "iPhone-13-mini-keyboard-quantity")
    }

    func testMiniSearchResultBackgroundRemainsSelectable() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        guard let addFood = scrollToElement(
            matchingPrefix: Identifier.addFoodPrefix,
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("No diary.addFood.* control was reachable on the mini.")
            return
        }
        addFood.tap()

        let search = app.descendants(matching: .any)[Identifier.searchField]
        XCTAssertTrue(search.waitForExistence(timeout: Timeout.normal), "Search did not open.")
        typeSearchQuery("Native QA", in: search)
        let result = app.buttons[Identifier.searchResult]
        XCTAssertTrue(
            result.waitForExistence(timeout: Timeout.normal),
            "The fixture search result did not appear."
        )
        let amount = app.descendants(matching: .any)[Identifier.amountField]

        // The integrator added a full-row content shape. Tap the center of the
        // accessibility frame (blank space to the right of the labels) and
        // require navigation; this is the prior F1 regression check.
        result.tap()
        XCTAssertTrue(
            amount.waitForExistence(timeout: 10),
            "A center-of-row tap did not open the fixture food."
        )
    }

    func testMiniDiaryLogRowBackgroundRemainsSelectable() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()

        guard let row = scrollToElement(
            Identifier.historicalLog,
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("The historical fixture log is not reachable on the mini.")
            return
        }
        let editor = app.descendants(matching: .any)[Identifier.editorAmount]
        row.tap()
        XCTAssertTrue(
            editor.waitForExistence(timeout: 10),
            "A center-of-row tap did not open the log editor."
        )
    }

    func testMiniLogEditorKeyboardDoneAndDeleteConfirmation() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()

        guard scrollToElement(
            Identifier.historicalLog,
            marker: Identifier.diarySummary,
            direction: .up
        ) != nil else {
            XCTFail("The historical fixture log is not reachable on the mini.")
            return
        }
        openHistoricalLogRow()

        let amount = app.descendants(matching: .any)[Identifier.editorAmount]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.normal),
            "The log editor did not open from the historical row."
        )
        amount.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The keyboard did not appear in the log editor."
        )
        replaceText(in: amount, with: "125")
        XCTAssertEqual(amount.value as? String, "125", "The log editor amount did not retain 125.")

        let keyboardDone = app.buttons[Identifier.editorKeyboardDone]
        XCTAssertTrue(
            keyboardDone.exists && keyboardDone.isHittable,
            "diary.editor.keyboardDone is not reachable above the keyboard on the mini."
        )
        keyboardDone.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                !self.app.keyboards.firstMatch.exists
            },
            "The keyboard stayed visible after tapping Done."
        )

        // Keep the journey usable by label while the identifier collision is
        // reported by testMiniLogEditorActionIdentifiersRemainDistinct.

        let save = app.buttons[Identifier.editorSave].exists
            ? app.buttons[Identifier.editorSave]
            : app.buttons["Save"]
        let delete = app.buttons[Identifier.editorDelete].exists
            ? app.buttons[Identifier.editorDelete]
            : app.buttons["Delete Food"]
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                save.exists && save.isHittable
            },
            "Save is not reachable in the editor after the keyboard dismisses."
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                delete.exists && delete.isHittable
            },
            "Delete is not reachable in the editor after the keyboard dismisses."
        )

        let unit = app.buttons[Identifier.editorUnit]
        XCTAssertTrue(unit.exists, "The editor unit picker is missing.")
        XCTAssertTrue(selectOption("Millilitre", from: unit), "The Millilitre unit was not offered.")
        let meal = app.buttons["diary.editor.mealSlot"]
        XCTAssertTrue(meal.exists, "The editor meal picker is missing.")
        XCTAssertTrue(selectOption("Lunch", from: meal), "Lunch was not offered in the editor.")
        let notes = app.descendants(matching: .any)[Identifier.editorNotes]
        XCTAssertTrue(notes.exists, "The editor notes field is missing.")
        notes.tap()
        replaceText(in: notes, with: "Mini QA updated notes")
        let notesDone = app.buttons[Identifier.editorKeyboardDone]
        if notesDone.exists, notesDone.isHittable {
            notesDone.tap()
        }
        save.tap()
        XCTAssertTrue(
            CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long),
            "The edited log did not return to the diary after saving."
        )
        guard scrollToElement(
            Identifier.historicalLog,
            marker: Identifier.diarySummary,
            direction: .up
        ) != nil else {
            XCTFail("The edited historical row disappeared after saving.")
            return
        }
        openHistoricalLogRow()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.editorAmount]
                .waitForExistence(timeout: Timeout.normal),
            "The edited log did not reopen."
        )
        XCTAssertEqual(app.descendants(matching: .any)[Identifier.editorAmount].value as? String, "125")
        XCTAssertTrue(app.buttons[Identifier.editorUnit].label.contains("Millilitre"))
        XCTAssertTrue(app.buttons["diary.editor.mealSlot"].label.contains("Lunch"))
        XCTAssertTrue(
            (app.descendants(matching: .any)[Identifier.editorNotes].value as? String ?? "")
                .contains("Mini QA updated notes")
        )

        let deleteAfterEdit = app.buttons["Delete Food"]
        XCTAssertTrue(deleteAfterEdit.exists && deleteAfterEdit.isHittable)
        deleteAfterEdit.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.confirmationButton(Identifier.editorDeleteConfirm)?.isHittable == true
            },
            "Delete did not present an explicit confirmation."
        )
        let sheetCancel = app.sheets.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "Cancel")
        ).firstMatch
        let popoverDismiss = app.otherElements["PopoverDismissRegion"]
        let cancel = sheetCancel.exists
            ? sheetCancel
            : (confirmationButton(Identifier.editorDeleteCancel)
                ?? confirmationButton(label: "Cancel")
                ?? (popoverDismiss.exists ? popoverDismiss : nil))
        XCTAssertNotNil(cancel, "The delete confirmation has no Cancel or dismiss action.")
        cancel?.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.editorAmount].exists,
            "Cancel closed the editor instead of returning to the draft."
        )

        delete.tap()
        guard CalCoE2E.waitUntil(timeout: Timeout.short, condition: {
            self.confirmationButton(Identifier.editorDeleteConfirm)?.isHittable == true
        }), let confirm = confirmationButton(Identifier.editorDeleteConfirm) else {
            XCTFail("The second delete attempt did not present its confirmation.")
            return
        }
        confirm.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.mutationNotice"]
                .waitForExistence(timeout: Timeout.long),
            "The app did not return to the diary with a deletion notice."
        )
        scrollDiaryToTop()
        XCTAssertFalse(
            scrollToElement(
                Identifier.historicalLog,
                marker: Identifier.diarySummary,
                direction: .up
            ) != nil,
            "The confirmed-deleted historical log is still rendered."
        )
        XCTAssertTrue(
            isHistoricalDateVisible(),
            "The diary left the historical date after deleting one historical log."
        )
        assertMockLogCount(7)
    }

    // MARK: - Dynamic Type and small-screen reachability

    func testMiniLogEditorActionIdentifiersRemainDistinct() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        openHistoricalLogRow()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.editorAmount]
                .waitForExistence(timeout: Timeout.normal)
        )
        XCTAssertTrue(
            app.buttons[Identifier.editorSave].exists,
            "diary.editor.save must identify the Save button."
        )
        XCTAssertTrue(
            app.buttons[Identifier.editorDelete].exists,
            "diary.editor.delete must identify the Delete button."
        )
    }

    func testMiniAccessibilityDynamicTypeDiaryAndSettingsRemainReachable() throws {
        try resetFixture()
        XCTAssertTrue(
            try launchSignedIn(dynamicType: QA.dynamicTypeAccessibility),
            "The diary did not load at the accessibility content size."
        )
        try assertIPhone13Mini()

        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The calorie summary is missing at the accessibility size."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.macros].exists,
            "The macro section is missing at the accessibility size."
        )

        let actions = [
            Identifier.settings,
            Identifier.calendar,
            Identifier.refresh,
            Identifier.previousDay,
            Identifier.nextDay,
            "auth.signOut",
        ]
        assertToolbarActionsReachable(actions)

        openSettings()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.goalCalories]
                .waitForExistence(timeout: Timeout.normal),
            "Settings goals did not load at the accessibility size."
        )

        for identifier in [
            Identifier.goalCalories,
            Identifier.goalProtein,
            Identifier.goalCarbs,
            Identifier.goalFat,
            Identifier.goalsSave,
            Identifier.breakfastToggle,
            Identifier.lateNightToggle,
            Identifier.slotsSave,
        ] {
            XCTAssertNotNil(
                scrollToElement(identifier, marker: Identifier.settingsSheet, direction: .up),
                "\(identifier) is not reachable at the accessibility size on the mini."
            )
        }

        guard let calories = scrollToElement(
            Identifier.goalCalories,
            marker: Identifier.settingsSheet,
            direction: .down
        ) else {
            XCTFail("The calories field could not be returned to.")
            return
        }
        XCTAssertTrue(calories.isHittable, "The calories goal field is not hittable.")
        // At accessibility sizes this TextField's AX frame expands across most
        // of the row. Try the visible label/value corners rather than assuming
        // the frame center is the editable control.
        for normalized in [
            CGVector(dx: 0.85, dy: 0.15),
            CGVector(dx: 0.85, dy: 0.5),
            CGVector(dx: 0.5, dy: 0.85),
            CGVector(dx: 0.5, dy: 0.5),
        ] {
            calories.coordinate(withNormalizedOffset: normalized).tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 1.5) {
                break
            }
        }
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The keyboard did not appear for a goal field at the accessibility size."
        )
        let done = app.buttons[Identifier.settingsKeyboardDone]
        XCTAssertTrue(
            done.exists && done.isHittable,
            "settings.keyboard.done is not reachable at the accessibility size."
        )
        done.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                !self.app.keyboards.firstMatch.exists
            },
            "The settings keyboard did not dismiss."
        )

        let close = app.buttons[Identifier.settingsCancel]
        XCTAssertTrue(close.exists && close.isHittable, "Settings Cancel is not reachable.")
        close.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "Settings stayed open after Cancel."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The diary did not remain available after closing settings."
        )
        attachScreenshot(named: "iPhone-13-mini-dynamic-type-settings")
    }

    // MARK: - Pending retry UI

    func testMiniUncertainSubmissionShowsRetryAndRetriesExactlyOnce() throws {
        try resetFixture(logPost: "fail_once")
        XCTAssertTrue(
            try launchSignedIn(),
            "The diary did not load for the pending-retry journey."
        )
        try assertIPhone13Mini()

        let baselineState = try mockState()
        XCTAssertEqual(baselineState.logCount, 8, "Unexpected fixture log baseline.")

        submitFixtureFood()
        if !app.descendants(matching: .any)[Identifier.submitWarning]
            .waitForExistence(timeout: Timeout.long) {
            print("NATIVE_QA_NO_WARNING_AX\n\(app.debugDescription)")
        }
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.submitWarning].exists,
            "The ambiguous 503 did not surface a warning."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.pendingBanner].exists,
            "The global pending-submission banner is missing after an ambiguous write."
        )

        guard let retry = scrollToButton(
            labelPrefix: "Retry",
            marker: "foodDetail.mealSlot.picker",
            direction: .up
        ) else {
            print("NATIVE_QA_PENDING_AX\n\(app.debugDescription)")
            XCTFail("The inline pending retry action is not reachable.")
            return
        }
        XCTAssertTrue(retry.isHittable, "The pending retry action is not hittable.")
        retry.tap()

        let success = app.descendants(matching: .any)[Identifier.submitSuccess]
            .waitForExistence(timeout: Timeout.long)
        let leftDetail = app.descendants(matching: .any)[Identifier.diarySummary].exists
        XCTAssertTrue(
            success || leftDetail,
            "The retry neither reported success nor returned to the diary."
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.pendingBanner].exists
            },
            "The pending banner stayed visible after a successful retry."
        )

        let finalState = try mockState()
        XCTAssertEqual(
            finalState.logCount,
            9,
            "The retry did not persist exactly one new fixture log."
        )
        XCTAssertEqual(
            finalState.logPostAttempts,
            2,
            "Expected the original POST and one replay; observed a different attempt count."
        )
        XCTAssertEqual(
            finalState.idempotencyKeys,
            1,
            "The two attempts did not share exactly one idempotency key."
        )
        attachScreenshot(named: "iPhone-13-mini-pending-retry")
    }

    func testMiniAccessibilityPendingBannerAndRecoveryRemainUsable() throws {
        try resetFixture(logPost: "fail_once")
        XCTAssertTrue(
            try launchSignedIn(dynamicType: QA.dynamicTypeAccessibility),
            "The diary did not load at AX XXXL."
        )
        try assertIPhone13Mini()
        let baseline = try mockState()
        submitFixtureFood()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.submitWarning]
                .waitForExistence(timeout: Timeout.long),
            "The ambiguous write did not surface a warning."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.pendingBanner].exists,
            "The pending banner is missing at AX XXXL."
        )
        guard let review = app.buttons[Identifier.pendingReview].firstMatch as XCUIElement?,
              review.exists else {
            XCTFail("The pending banner has no Review action at AX XXXL.")
            return
        }
        XCTAssertTrue(review.isHittable, "The pending banner Review action is not hittable.")
        XCTAssertEqual(
            review.frame.width,
            app.windows.firstMatch.frame.width - 32,
            accuracy: 1,
            "The pending banner Review action is not full width at AX XXXL."
        )
        XCTAssertLessThanOrEqual(
            review.frame.height,
            120,
            "The pending banner Review action is excessively tall at AX XXXL."
        )
        let dismiss = app.buttons[Identifier.pendingDismiss]
        XCTAssertTrue(dismiss.exists, "The pending banner dismiss action is missing at AX XXXL.")
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)

        // At AX XXXL the banner plus the wrapped navigation title leave no
        // usable form strip. The user-visible escape path is the 44-point
        // dismiss control, after which the detail form can be scrolled.
        dismiss.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.pendingBanner].exists
            },
            "Dismissing the pending banner at AX XXXL did not clear it."
        )
        guard let retry = scrollToButton(
            labelPrefix: "Retry",
            marker: "foodDetail.mealSlot.picker",
            direction: .up
        ) else {
            print("NATIVE_QA_PENDING_AX\n\(app.debugDescription)")
            XCTFail("Inline pending recovery is not reachable at AX XXXL after dismissing the banner.")
            return
        }
        XCTAssertTrue(retry.isHittable, "The pending retry action is not hittable at AX XXXL.")
        retry.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                ((try? self.mockState().logCount) ?? -1) == baseline.logCount + 1
            },
            "The AX XXXL retry did not persist the fixture log."
        )
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.descendants(matching: .any)["foodDetail.pending.notice"].exists
                    && !self.app.descendants(matching: .any)[Identifier.submitWarning].exists
            },
            "The AX XXXL retry left the pending recovery or warning UI visible."
        )
        let finalState = try mockState()
        XCTAssertEqual(
            finalState.logCount,
            baseline.logCount + 1,
            "The AX XXXL retry did not persist exactly one new fixture log."
        )
        XCTAssertEqual(
            finalState.logPostAttempts,
            baseline.logPostAttempts + 2,
            "The AX XXXL retry did not share one idempotent replay."
        )
        XCTAssertEqual(
            finalState.idempotencyKeys,
            baseline.idempotencyKeys + 1,
            "The AX XXXL retry did not share exactly one idempotency key."
        )
    }

    func testMiniConflictedPendingReviewRequiresDestructiveConfirmation() throws {
        try resetFixture(logPost: "conflict")
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        submitFixtureFood()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.submitWarning]
                .waitForExistence(timeout: Timeout.long),
            "The 409 conflict did not surface a warning."
        )
        guard scrollToButton(
            labelPrefix: "Discard attempt",
            marker: Identifier.amountField,
            direction: .up
        ) != nil else {
            XCTFail("The conflict recovery section is not reachable.")
            return
        }
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.pendingBanner].exists,
            "The conflict banner is missing."
        )

        guard let bannerDiscard = hittablePrefixButton(labelPrefix: "Discard attempt") else {
            XCTFail("The reviewed conflict does not offer a reachable discard action.")
            return
        }
        bannerDiscard.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: Timeout.short),
            "Discarding a conflicted pending submission did not ask for confirmation."
        )
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.exists, "The conflict discard alert has no Cancel action.")
        cancel.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.pendingBanner].exists,
            "Cancel removed the pending conflict instead of leaving it in place."
        )

        bannerDiscard.tap()
        guard alert.waitForExistence(timeout: Timeout.short) else {
            XCTFail("The second discard attempt did not ask for confirmation.")
            return
        }
        let destructive = alert.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Discard")
        ).firstMatch
        XCTAssertTrue(destructive.exists, "The conflict discard alert has no destructive action.")
        destructive.tap()

        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.pendingNotice].exists
                    && !self.app.descendants(matching: .any)[Identifier.pendingBanner].exists
            },
            "Confirmed discard left the conflicted pending entry visible."
        )
        let finalState = try mockState()
        XCTAssertEqual(
            finalState.logCount,
            8,
            "A conflicted submission unexpectedly created a log."
        )
        XCTAssertEqual(finalState.logPostAttempts, 1, "The conflict should not be retried implicitly.")
    }

    // MARK: - Calendar, macro, and transient review controls

    func testMiniCalendarAndMacroModeRemainInteractive() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        guard tapToolbarAction(Identifier.calendar) else {
            XCTFail("The calendar toolbar action is not reachable.")
            return
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.datePicker"]
                .waitForExistence(timeout: Timeout.normal),
            "The graphical date picker did not open."
        )
        app.buttons["diary.datePicker.cancel"].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)["diary.datePicker"].exists
            },
            "The date picker did not dismiss."
        )

        navigateToHistoricalFixtureDay()
        let macroMode = app.segmentedControls["diary.summary.macroMode"]
        XCTAssertTrue(macroMode.exists, "The macro mode picker is missing.")
        macroMode.buttons["Percent"].tap()
        let protein = app.descendants(matching: .any)["diary.summary.protein"]
        XCTAssertTrue(protein.waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(
            protein.label.contains("%"),
            "Macro labels did not switch to percent: \(protein.label)"
        )
    }

    func testMiniBarcodeLeadingZerosAndNotFoundRemainReviewed() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        openSearchFromDiary()

        let scope = app.segmentedControls["search.scope"]
        XCTAssertTrue(scope.exists, "The search scope picker is missing.")
        scope.buttons["Barcode"].tap()
        let field = app.textFields["search.barcode.field"]
        XCTAssertTrue(
            field.waitForExistence(timeout: Timeout.normal),
            "The manual barcode field did not appear."
        )
        field.tap()
        field.typeText("0012345")
        XCTAssertEqual(field.value as? String, "0012345", "Leading zeros were stripped from input.")
        app.buttons["search.barcode.lookupButton"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["search.barcode.notFound"]
                .waitForExistence(timeout: Timeout.long),
            "The fixture 404 did not show the reviewed not-found state."
        )
        var create = app.buttons["search.barcode.create"]
        if !create.exists {
            create = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Create")
            ).firstMatch
        }
        for _ in 0..<4 where !create.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            create.exists,
            "The not-found review does not offer a reachable custom-food path."
        )
        create.tap()
        XCTAssertTrue(
            app.textFields["library.editor.name"]
                .waitForExistence(timeout: Timeout.long),
            "The barcode create path did not open the Library custom-food editor."
        )
        let editorNameValue = app.textFields["library.editor.name"].value as? String ?? ""
        XCTAssertTrue(
            editorNameValue.isEmpty || editorNameValue == "Food name",
            "The Library editor unexpectedly prefilled a name: \(editorNameValue)"
        )
        // Leave no draft behind; a dirty draft asks for explicit discard.
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
            let discard = app.buttons["library.editor.discard.confirm"]
            if discard.waitForExistence(timeout: 2) {
                discard.tap()
            }
        }
    }

    func testMiniAssistantGatePreventsDraftingWhenDisabled() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        openSearchFromDiary()

        guard let assistant = laidOutElement(identifier: "search.assistant") else {
            XCTFail("The assistant menu is not present in Search.")
            return
        }
        assistant.tap()
        let customFood = app.buttons["search.assistant.customFood"]
        XCTAssertTrue(
            customFood.waitForExistence(timeout: Timeout.normal),
            "The assistant custom-food action is missing."
        )
        customFood.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["assistant.status.disabled"]
                .waitForExistence(timeout: Timeout.long),
            "The disabled assistant gate did not render its explicit disabled state."
        )
        XCTAssertFalse(
            app.buttons["assistant.send"].exists,
            "A disabled assistant still exposed a draft-send control."
        )
    }

    func testMiniAPIKeyCreateRevealCopyAndRevoke() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        openSettings()
        XCTAssertTrue(waitForSettingsGoals())
        guard let entry = scrollToElement(
            "settings.apiKeys.entry",
            marker: Identifier.settingsSheet,
            direction: .up
        ) else {
            XCTFail("The API-key entry is not reachable in Settings.")
            return
        }
        entry.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.apiKeys.list"]
                .waitForExistence(timeout: Timeout.normal),
            "The API-key list did not load."
        )

        app.buttons["settings.apiKeys.create"].tap()
        let name = app.textFields["settings.apiKeys.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.normal))
        name.tap()
        name.typeText("Mini QA key")
        let keyboardDone = app.buttons["settings.apiKeys.create.keyboard.done"]
        if keyboardDone.exists, keyboardDone.isHittable {
            keyboardDone.tap()
        }
        var submit = app.buttons["settings.apiKeys.create.submit"]
        if !submit.isHittable {
            submit = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Create API Key")
            ).firstMatch
        }
        for _ in 0..<5 where !submit.isHittable {
            let forms = app.collectionViews.allElementsBoundByIndex
            guard let createForm = forms.last, createForm.exists else { break }
            createForm.swipeUp()
        }
        if !submit.exists || !submit.isHittable {
            print("NATIVE_QA_APIKEY_CREATE_AX\n\(app.debugDescription)")
        }
        XCTAssertTrue(submit.exists && submit.isHittable, "Create API key is not reachable.")
        submit.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.apiKeys.secret"]
                .waitForExistence(timeout: Timeout.long),
            "The one-time secret reveal did not appear."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.apiKeys.secret.warning"].exists,
            "The secret reveal is missing its warning."
        )
        app.buttons["settings.apiKeys.secret.copy"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.apiKeys.secret.copied"]
                .waitForExistence(timeout: Timeout.normal),
            "Copy did not confirm the fixture secret copy."
        )
        app.buttons["settings.apiKeys.secret.done"].tap()

        let revoke = app.buttons["settings.apiKeys.revoke.qa-api-key-1"]
        XCTAssertTrue(
            revoke.waitForExistence(timeout: Timeout.normal),
            "The fixture API key was not listed for revocation."
        )
        revoke.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: Timeout.normal) {
            let confirm = alert.buttons["Revoke key"]
            XCTAssertTrue(confirm.exists, "Revocation alert has no Revoke key action.")
            confirm.tap()
        } else {
            let sheet = app.sheets.firstMatch
            let confirm = sheet.buttons["Revoke key"]
            XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.normal), "Revocation did not ask for confirmation.")
            confirm.tap()
        }
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.buttons["settings.apiKeys.revoke.qa-api-key-1"].exists
            },
            "The revoked fixture key remained listed."
        )
        assertFixtureAccountBinding("API-key management")
    }

    func testMiniQuickAddAndBatchSubmitWithoutDoublePOST() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        openSearchFromDiary()

        let quickAdd = app.buttons["search.quickAdd.product:qa-apple.100.g"]
        XCTAssertTrue(
            quickAdd.waitForExistence(timeout: Timeout.long),
            "The fixture recent quantity chip did not appear."
        )
        quickAdd.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["search.quickAdd.added"]
                .waitForExistence(timeout: Timeout.long),
            "Quick add did not report success."
        )
        assertMockLogCount(9)

        app.buttons["search.recent.select.product:qa-apple"].tap()
        app.buttons["search.recent.select.product:qa-pear"].tap()
        let review = app.buttons["search.batch.reviewButton"]
        XCTAssertTrue(
            review.waitForExistence(timeout: Timeout.normal),
            "Batch review did not appear after selecting two rows."
        )
        review.tap()
        let submit = app.buttons["search.batch.submit"]
        XCTAssertTrue(
            submit.waitForExistence(timeout: Timeout.normal),
            "The batch review sheet did not expose Submit."
        )
        submit.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                self.tryLogCount() >= 11
            },
            "The batch did not write both selected items."
        )
        XCTAssertEqual(
            try mockState().logPostAttempts,
            2,
            "Quick add plus batch should be exactly two POST operations."
        )
        assertFixtureAccountBinding("quick-add/batch")
    }

    func testMiniRepeatLatestRequiresReviewAndWritesOnce() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        guard let latest = scrollToElement(
            "diary.latest.breakfast",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("Log latest is not reachable for Breakfast.")
            return
        }
        latest.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.latest.review"]
                .waitForExistence(timeout: Timeout.long),
            "Log latest did not open its review step."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.latest.item.hist-log-001"].exists,
            "The review did not show the source item."
        )
        app.buttons["diary.latest.submit"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.latestNotice"]
                .waitForExistence(timeout: Timeout.long),
            "Log latest did not report success."
        )
        XCTAssertEqual(
            try mockState().logCount,
            10,
            "Log latest should copy exactly the two Breakfast rows."
        )
    }

    // MARK: - Historical-date retention across existing and new destinations

    func testMiniHistoricalDateSurvivesSettingsRoundTrip() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        let summaryBefore = summaryLabel()

        openSettings()
        XCTAssertTrue(waitForSettingsGoals(), "Settings did not load from the historical date.")
        guard let calories = scrollToElement(
            Identifier.goalCalories,
            marker: Identifier.settingsSheet,
            direction: .down
        ) else {
            XCTFail("The goal calories field is not reachable.")
            return
        }
        // The fixture macros are 150 g protein, 250 g carbs, and 70 g fat,
        // which require 2230 kcal. Saving an inconsistent target is correctly
        // blocked by the live macro equation validation.
        replaceText(in: calories, with: "2230")
        XCTAssertEqual(calories.value as? String, "2230")
        XCTAssertFalse(
            app.descendants(matching: .any)["settings.goals.validationError"].exists,
            "A macro-consistent calorie target was rejected by validation."
        )
        let keyboardDone = app.buttons[Identifier.settingsKeyboardDone]
        if keyboardDone.exists, keyboardDone.isHittable {
            keyboardDone.tap()
        }
        guard let goalsSave = scrollToElement(
            Identifier.goalsSave,
            marker: Identifier.settingsSheet,
            direction: .up
        ) else {
            XCTFail("Save Goals is not reachable.")
            return
        }
        let saveByLabel = app.buttons["Save Goals"]
        XCTAssertTrue(goalsSave.isEnabled, "Save Goals stayed disabled after a valid edit.")
        XCTAssertTrue(goalsSave.isHittable, "Save Goals is not hittable.")
        if saveByLabel.exists, saveByLabel.isHittable {
            saveByLabel.tap()
        } else {
            goalsSave.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if !app.descendants(matching: .any)["settings.goals.saved"]
            .waitForExistence(timeout: Timeout.long) {
            print("NATIVE_QA_GOAL_SAVE_AX\n\(app.debugDescription)")
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.goals.saved"].exists,
            "The goal save did not complete."
        )
        XCTAssertEqual(
            try mockState().goalCalories,
            2230,
            "The fixture did not record the saved calorie target."
        )
        app.buttons[Identifier.settingsCancel].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "Settings did not close."
        )
        // Goal changes are effective from today; the historical selected day
        // must keep the goal that was effective for it.
        assertHistoricalContext(retainedSummary: summaryBefore)
        assertFixtureAccountBinding("settings goals")
    }

    func testMiniHistoricalLoggingRetainsDateAndMealSlot() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        scrollDiaryToTop()
        guard let baselineCalories = displayedCalories() else {
            XCTFail("Could not read the historical calorie summary.")
            return
        }

        guard let addFood = scrollToElement(
            Identifier.addFoodPrefix + "breakfast",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("The historical Breakfast Add Food action is not reachable.")
            return
        }
        addFood.tap()

        let search = app.descendants(matching: .any)[Identifier.searchField]
        XCTAssertTrue(search.waitForExistence(timeout: Timeout.normal), "Search did not open.")
        typeSearchQuery("Native QA", in: search)
        XCTAssertTrue(
            app.buttons[Identifier.searchResult].waitForExistence(timeout: Timeout.normal),
            "The fixture search result did not appear."
        )
        selectFixtureSearchResult()

        let submit = app.buttons[Identifier.submit]
        XCTAssertTrue(
            submit.waitForExistence(timeout: Timeout.normal),
            "Food detail did not load from the historical Breakfast slot."
        )
        let meal = app.buttons["foodDetail.mealSlot.picker"]
        if meal.exists {
            XCTAssertTrue(
                meal.label.localizedCaseInsensitiveContains("Breakfast"),
                "The historical Breakfast slot was not carried into the log form."
            )
        }
        XCTAssertTrue(submit.isHittable, "The historical Log action is not hittable.")
        submit.tap()

        let successLabel = app.descendants(matching: .any)[Identifier.submitSuccess]
            .waitForExistence(timeout: Timeout.short)
        XCTAssertTrue(
            returnToDiaryFromFlow(),
            "The app did not return to the diary after historical logging."
        )
        XCTAssertTrue(
            successLabel || app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The historical log neither reported success nor returned to the diary."
        )
        scrollDiaryToTop()
        XCTAssertTrue(
            isHistoricalDateVisible(),
            "The diary left the historical date after logging."
        )
        XCTAssertEqual(
            displayedCalories(),
            baselineCalories + 100,
            "The historical summary did not add exactly 100 kcal for the 100 g fixture."
        )

        let state: MockState
        do {
            state = try mockState()
        } catch {
            XCTFail("Could not read fixture state after historical logging: \(error)")
            return
        }
        guard let created = state.logs.first(where: { $0.id.hasPrefix("new-log-") }) else {
            XCTFail("The fixture did not record the historical create.")
            return
        }
        XCTAssertEqual(
            created.date,
            Self.isoDay(
                Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            ),
            "The submitted log date is not the selected historical date."
        )
        XCTAssertEqual(created.mealSlot, "breakfast", "The submitted meal slot is not Breakfast.")
        XCTAssertEqual(created.amount, "100", "The submitted fixture quantity is not 100.")
        XCTAssertEqual(created.unit, "g", "The submitted fixture unit is not grams.")
        assertFixtureAccountBinding("historical logging")
    }

    func testMiniHistoricalDateSurvivesLibraryDestination() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        let summaryBefore = summaryLabel()

        guard openDirectFeatureDestination(.library) else {
            XCTFail("Library has no direct reachable native entry; the normal feature is unreachable.")
            return
        }
        XCTAssertTrue(waitForFeatureSurface(), "Library did not present a destination surface.")
        dismissToDiary()
        assertHistoricalContext(retainedSummary: summaryBefore)
    }

    func testMiniLibraryCustomFoodAndAdHocSaveAndLog() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        guard openDirectFeatureDestination(.library) else {
            XCTFail("Library has no direct reachable entry.")
            return
        }
        let libraryLoaded = CalCoE2E.waitUntil(timeout: Timeout.long) {
            self.app.descendants(matching: .any)["library.empty"].exists
                || self.app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
                ).count > 0
        }
        XCTAssertTrue(libraryLoaded, "The Library list did not load.")
        let baseline = try mockState()

        app.buttons["library.add"].tap()
        app.buttons["library.add.custom"].tap()
        let name = app.textFields["library.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.long), "The custom-food editor did not open.")
        name.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) { name.exists },
            "The custom-food name field disappeared after focus."
        )
        name.typeText("Native QA Custom Food")
        dismissLibraryKeyboard("library.editor.keyboard.done")
        // Refocus must retain the same editor, value, and form state.
        name.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                name.exists && (name.value as? String) == "Native QA Custom Food"
            },
            "The custom-food name field lost its value after refocus."
        )
        dismissLibraryKeyboard("library.editor.keyboard.done")
        fillRequiredNutrients(
            [
                (code: "ENERGY_KCAL", amount: "100"),
                (code: "PROTEIN_G", amount: "10"),
                (code: "CARBS_G", amount: "20"),
                (code: "FAT_G", amount: "5"),
            ],
            marker: "library.editor.name",
            doneIdentifier: "library.editor.keyboard.done"
        )
        let save = app.buttons["library.editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: Timeout.normal), "The custom-food Save action is missing.")
        XCTAssertTrue(save.isEnabled, "The custom-food Save action is disabled after valid input.")
        save.tap()
        let createdRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
        ).firstMatch
        XCTAssertTrue(
            createdRow.waitForExistence(timeout: Timeout.long),
            "The created custom food did not appear in the Library list."
        )
        XCTAssertTrue(
            createdRow.label.localizedCaseInsensitiveContains("Native QA Custom Food"),
            "The Library list did not show the created name."
        )
        createdRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.detail"]
                .waitForExistence(timeout: Timeout.long),
            "The created custom food did not open its detail view."
        )
        XCTAssertTrue(app.staticTexts["Native QA Custom Food"].exists)

        app.buttons["library.detail.edit"].tap()
        let editBrand = app.textFields["library.editor.brand"]
        XCTAssertTrue(
            editBrand.waitForExistence(timeout: Timeout.long),
            "The custom-food edit form did not open."
        )
        replaceText(in: editBrand, with: "Native QA Edited Brand")
        XCTAssertEqual(editBrand.value as? String, "Native QA Edited Brand")
        dismissLibraryKeyboard("library.editor.keyboard.done")
        let editSave = app.buttons["library.editor.save"]
        XCTAssertTrue(editSave.waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(editSave.isEnabled, "The edit Save action is disabled for a loaded custom food.")
        editSave.tap()
        let editedRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
        ).firstMatch
        XCTAssertTrue(
            editedRow.waitForExistence(timeout: Timeout.long),
            "The edited custom food did not return to the Library list."
        )
        let foodID = editedRow.identifier.replacingOccurrences(of: "library.row.", with: "")
        editedRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.detail"]
                .waitForExistence(timeout: Timeout.long)
        )
        XCTAssertTrue(
            app.staticTexts["Native QA Edited Brand"].waitForExistence(timeout: Timeout.normal),
            "The detail view did not show the edited brand."
        )
        app.buttons["library.detail.delete"].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.confirmationButton("library.detail.delete.confirm")?.isHittable == true
            },
            "The custom-food delete confirmation did not appear."
        )
        confirmationButton("library.detail.delete.confirm")?.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.buttons["library.row.\(foodID)"].exists
                    && self.app.descendants(matching: .any)["library.empty"].exists
            },
            "The deleted custom food remained in Library."
        )
        let crudState = try mockState()
        XCTAssertEqual(
            crudState.customFoodCreateCount,
            baseline.customFoodCreateCount + 1,
            "Custom-food create did not issue exactly one POST."
        )
        XCTAssertEqual(
            crudState.customFoodUpdateCount,
            baseline.customFoodUpdateCount + 1,
            "Custom-food edit did not issue exactly one PUT."
        )
        XCTAssertEqual(
            crudState.customFoodDeleteCount,
            baseline.customFoodDeleteCount + 1,
            "Custom-food delete did not issue exactly one DELETE."
        )
        XCTAssertEqual(
            crudState.customFoodCount,
            baseline.customFoodCount,
            "Custom-food delete did not remove exactly the created food."
        )

        let adHocBaseline = try mockState()
        app.buttons["library.add"].tap()
        app.buttons["library.add.adhoc"].tap()
        let adHocName = app.textFields["library.adHoc.name"]
        XCTAssertTrue(adHocName.waitForExistence(timeout: Timeout.long), "The ad-hoc form did not open.")
        adHocName.tap()
        adHocName.typeText("Native QA Ad Hoc Food")
        dismissLibraryKeyboard("library.adHoc.keyboard.done")
        guard let mode = hittableElement(identifier: "library.adHoc.mode"),
              selectOption("Save food and log", from: mode) else {
            XCTFail("The ad-hoc save-and-log mode was not selectable.")
            return
        }
        guard let amount = scrollToElement(
            "foodDetail.amount.field",
            marker: "library.adHoc.name",
            direction: .down
        ) else {
            XCTFail("The ad-hoc quantity field is not reachable.")
            return
        }
        XCTAssertEqual(amount.value as? String, "100")
        let unit = app.buttons["foodDetail.unit.picker"]
        XCTAssertTrue(
            unit.exists && unit.label.localizedCaseInsensitiveContains("g"),
            "The ad-hoc quantity unit is not grams."
        )
        fillRequiredNutrients(
            [
                (code: "ENERGY_KCAL", amount: "100"),
                (code: "PROTEIN_G", amount: "10"),
                (code: "CARBS_G", amount: "20"),
                (code: "FAT_G", amount: "5"),
            ],
            marker: "library.adHoc.name",
            doneIdentifier: "library.adHoc.keyboard.done"
        )
        let review = app.buttons["library.adHoc.submit"]
        XCTAssertTrue(review.waitForExistence(timeout: Timeout.normal), "The ad-hoc Review action is missing.")
        XCTAssertTrue(review.isEnabled, "The ad-hoc Review action is disabled after valid input.")
        review.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: Timeout.normal),
            "The ad-hoc review confirmation did not appear."
        )
        XCTAssertTrue(
            alert.staticTexts.allElementsBoundByIndex.contains {
                $0.label.contains("100") && $0.label.localizedCaseInsensitiveContains("g")
            },
            "The ad-hoc review did not show the selected quantity and unit."
        )
        let confirm = alert.buttons["Save and log"]
        XCTAssertTrue(confirm.exists && confirm.isHittable, "The ad-hoc Save and log confirmation is missing.")
        confirm.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.adHoc.logged"]
                .waitForExistence(timeout: Timeout.long),
            "Ad-hoc save-and-log did not report success."
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: "library.adHoc.done").count,
            1,
            "The saved-and-logged completion must expose exactly one canonical Done action."
        )
        let final = try mockState()
        XCTAssertEqual(
            final.customFoodCreateCount,
            adHocBaseline.customFoodCreateCount + 1,
            "Ad-hoc save-and-log did not create exactly one food."
        )
        XCTAssertEqual(
            final.logPostAttempts,
            adHocBaseline.logPostAttempts + 1,
            "Ad-hoc save-and-log did not issue exactly one log POST."
        )
        XCTAssertEqual(
            final.logCount,
            adHocBaseline.logCount + 1,
            "Ad-hoc save-and-log did not create exactly one fixture log."
        )
        XCTAssertEqual(
            final.customFoodCount,
            adHocBaseline.customFoodCount + 1,
            "Ad-hoc save-and-log did not retain exactly one new custom food."
        )
        guard let createdLog = final.logs.first(where: { $0.id.hasPrefix("new-log-") }) else {
            XCTFail("The fixture did not record the ad-hoc save-and-log entry.")
            return
        }
        XCTAssertEqual(createdLog.amount, "100")
        XCTAssertEqual(createdLog.unit, "g")
        assertFixtureAccountBinding("Library/ad-hoc")
    }

    func testMiniHistoricalDateSurvivesMealsDestination() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        let summaryBefore = summaryLabel()

        guard openFeatureDestination(.meals) else {
            XCTFail("Meals is unreachable through its normal entry points.")
            return
        }
        XCTAssertTrue(waitForFeatureSurface(), "Meals did not present a destination surface.")
        let mealRow = app.buttons["meals.list.row.qa-meal-1"]
        XCTAssertTrue(
            mealRow.waitForExistence(timeout: Timeout.long),
            "The fixture meal row did not appear."
        )
        mealRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail"]
                .waitForExistence(timeout: Timeout.long),
            "The meal detail did not open."
        )
        let previewEnergy = app.descendants(matching: .any)[
            "meals.detail.preview.nutrient.ENERGY_KCAL"
        ]
        if !previewEnergy.waitForExistence(timeout: Timeout.long) {
            _ = scrollToElement(
                "meals.detail.preview",
                marker: "meals.detail",
                direction: .up,
                maxSwipes: 4
            )
        }
        XCTAssertTrue(
            previewEnergy.waitForExistence(timeout: Timeout.normal),
            "The loaded portion nutrient preview did not appear."
        )
        for code in ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"] {
            XCTAssertTrue(
                app.descendants(matching: .any)[
                    "meals.detail.preview.nutrient.\(code)"
                ].exists,
                "The \(code) preview nutrient row is missing."
            )
        }
        let baseline = try mockState()
        let logMeal = app.buttons["meals.detail.log"]
        XCTAssertTrue(logMeal.exists && logMeal.isHittable, "Log meal is not reachable.")
        logMeal.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.log.success"]
                .waitForExistence(timeout: Timeout.long),
            "Meal logging did not report success."
        )
        XCTAssertEqual(
            try mockState().logCount,
            baseline.logCount + 1,
            "Meal logging did not create exactly one fixture log."
        )
        assertFixtureAccountBinding("meals")
        dismissToDiary()
        assertHistoricalContext(retainedSummary: "Calories 900 / 2000")
    }

    func testMiniHistoricalDateSurvivesNutritionDestination() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        let summaryBefore = summaryLabel()

        guard openFeatureDestination(.nutrition) else {
            XCTFail("Nutrition details is unreachable through its normal entry point.")
            return
        }
        XCTAssertTrue(
            waitForFeatureSurface(),
            "Nutrition details did not present a destination surface."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nutrition.date"]
                .waitForExistence(timeout: Timeout.normal),
            "The nutrition date context is missing."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nutrition.coverage"].exists,
            "The nutrition coverage notice is missing."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nutrition.nutrient.ENERGY_KCAL"].exists
                || app.descendants(matching: .any)["nutrition.overview.ENERGY_KCAL"].exists,
            "The energy nutrient report row is missing."
        )
        dismissToDiary()
        assertHistoricalContext(retainedSummary: summaryBefore)
    }

    func testMiniHistoricalDateSurvivesAPIKeysDestination() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        let summaryBefore = summaryLabel()

        guard openFeatureDestination(.apiKeys) else {
            XCTFail("Personal API keys is unreachable through Settings.")
            return
        }
        XCTAssertTrue(
            waitForFeatureSurface(),
            "API-key settings did not present a destination surface."
        )
        dismissToDiary()
        assertHistoricalContext(retainedSummary: summaryBefore)
    }

    // MARK: - Enabled assistant and full meal lifecycle

    func testMiniAssistantEnabledCustomDraftRequiresExplicitSave() throws {
        try resetFixture(assistantEnabled: true)
        XCTAssertTrue(try launchSignedIn(), "The diary did not load with the enabled fixture.")
        try assertIPhone13Mini()
        let baseline = try mockState()
        openAssistant("search.assistant.customFood")
        sendAssistantPrompt(
            "Draft a 100 g oat food with four macros for review.",
            draftTimeout: Timeout.long
        )
        XCTAssertTrue(app.staticTexts["Native QA AI Oats"].exists)
        XCTAssertEqual(
            try mockState().assistantDraftRequestCount,
            baseline.assistantDraftRequestCount + 1
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["assistant.draft.warnings"].exists,
            "The assistant warning was not shown for review."
        )
        let beforeAccept = try mockState()
        app.buttons["assistant.draft.accept"].tap()
        let name = app.textFields["library.editor.name"]
        XCTAssertTrue(
            name.waitForExistence(timeout: Timeout.long),
            "Assistant acceptance did not open the Library review editor."
        )
        XCTAssertEqual(name.value as? String, "Native QA AI Oats")
        XCTAssertEqual(
            app.textFields["library.editor.brand"].value as? String,
            "Native QA"
        )
        guard let energy = scrollToElement(
            "library.nutrient.ENERGY_KCAL.field",
            marker: "library.editor.name",
            direction: .down
        ) else {
            XCTFail("The assistant macro prefill is not reachable.")
            return
        }
        XCTAssertEqual(energy.value as? String, "380")
        XCTAssertEqual(
            try mockState().customFoodCreateCount,
            beforeAccept.customFoodCreateCount,
            "Accepting the assistant draft must not write a food."
        )
        XCTAssertEqual(
            try mockState().logPostAttempts,
            beforeAccept.logPostAttempts,
            "Accepting the assistant draft must not write a log."
        )

        guard let brand = scrollToElement(
            "library.editor.brand",
            marker: "library.editor.name",
            direction: .up
        ) else {
            XCTFail("The assistant brand field is not reachable.")
            return
        }
        replaceText(in: brand, with: "Native QA AI Brand")
        XCTAssertEqual(brand.value as? String, "Native QA AI Brand")
        dismissLibraryKeyboard("library.editor.keyboard.done")
        app.buttons["library.editor.save"].tap()
        let created = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
        ).firstMatch
        XCTAssertTrue(
            created.waitForExistence(timeout: Timeout.long),
            "The reviewed assistant food did not save to Library."
        )
        XCTAssertEqual(
            try mockState().customFoodCreateCount,
            beforeAccept.customFoodCreateCount + 1,
            "Explicit review/save did not issue exactly one food POST."
        )
        XCTAssertEqual(
            try mockState().logPostAttempts,
            beforeAccept.logPostAttempts,
            "A custom-food save must not write a log."
        )
        created.tap()
        XCTAssertTrue(
            app.staticTexts["Native QA AI Brand"].waitForExistence(timeout: Timeout.long),
            "The edited assistant brand was not saved."
        )
        assertFixtureAccountBinding("assistant custom food")
    }

    func testMiniAssistantEnabledAdHocDraftRequiresReviewConfirm() throws {
        try resetFixture(assistantEnabled: true)
        XCTAssertTrue(try launchSignedIn(), "The diary did not load with the enabled fixture.")
        try assertIPhone13Mini()
        let baseline = try mockState()
        openAssistant("search.assistant.adHocLog")
        sendAssistantPrompt(
            "Draft one bowl of oats for an ad-hoc log.",
            draftTimeout: Timeout.long
        )
        XCTAssertTrue(
            app.staticTexts["1 bowl (40 g)"].waitForExistence(timeout: Timeout.normal),
            "The suggested ad-hoc log was not displayed."
        )
        let beforeAccept = try mockState()
        app.buttons["assistant.draft.accept"].tap()
        let name = app.textFields["library.adHoc.name"]
        XCTAssertTrue(
            name.waitForExistence(timeout: Timeout.long),
            "Assistant acceptance did not open the ad-hoc review form."
        )
        XCTAssertEqual(name.value as? String, "Native QA AI Oats")
        XCTAssertEqual(app.textFields["foodDetail.amount.field"].value as? String, "1")
        XCTAssertTrue(
            app.buttons["foodDetail.unit.picker"].label.localizedCaseInsensitiveContains("bowl")
        )
        guard let energy = scrollToElement(
            "library.nutrient.ENERGY_KCAL.field",
            marker: "library.adHoc.name",
            direction: .down
        ) else {
            XCTFail("The scaled assistant nutrients are not reachable.")
            return
        }
        XCTAssertEqual(energy.value as? String, "152")
        XCTAssertEqual(
            try mockState().logPostAttempts,
            beforeAccept.logPostAttempts,
            "Accepting the ad-hoc draft must not write before explicit review."
        )
        XCTAssertEqual(
            try mockState().customFoodCreateCount,
            beforeAccept.customFoodCreateCount,
            "Ad-hoc assistant logging must not create a food."
        )

        app.buttons["library.adHoc.submit"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(alert.buttons["Log food"].exists)
        let beforeConfirm = try mockState()
        alert.buttons["Log food"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.adHoc.logged"]
                .waitForExistence(timeout: Timeout.long),
            "Ad-hoc assistant log did not complete."
        )
        let final = try mockState()
        XCTAssertEqual(final.logPostAttempts, beforeConfirm.logPostAttempts + 1)
        XCTAssertEqual(final.logCount, beforeConfirm.logCount + 1)
        XCTAssertEqual(final.customFoodCreateCount, beforeConfirm.customFoodCreateCount)
        guard let log = final.logs.first(where: { $0.id.hasPrefix("adhoc-log-") }) else {
            XCTFail("The fixture did not record the assistant ad-hoc log.")
            return
        }
        XCTAssertEqual(log.amount, "1")
        XCTAssertEqual(log.unit, "bowl")
        assertFixtureAccountBinding("assistant ad-hoc")
    }

    func testMiniMealsCreateEditDeleteAndMissingRepair() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        let baseline = try mockState()
        guard openFeatureDestination(.meals) else {
            XCTFail("Meals is unreachable through its normal entry points.")
            return
        }
        XCTAssertTrue(
            app.buttons["meals.list.row.qa-meal-1"].waitForExistence(timeout: Timeout.long)
        )
        app.buttons["meals.list.add"].tap()
        let name = app.textFields["meals.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.long), "Meal editor did not open.")
        replaceText(in: name, with: "Native QA Built Meal")
        replaceText(in: app.textFields["meals.editor.notes"], with: "Native QA meal notes")
        replaceText(in: app.textFields["meals.editor.total.amount"], with: "150")
        let search = app.textFields.matching(
            NSPredicate(format: "label == %@", "Search Food")
        ).firstMatch
        XCTAssertTrue(
            search.waitForExistence(timeout: Timeout.normal),
            "The meal component picker is not reachable."
        )
        search.tap()
        search.typeText("Native QA")
        let apple = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Native QA Apple")
        ).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: Timeout.normal))
        apple.tap()
        XCTAssertEqual(
            app.textFields.matching(NSPredicate(format: "label == %@", "Quantity"))
                .firstMatch.value as? String,
            "100"
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Gram"))
                .firstMatch.exists
        )
        app.buttons["meals.editor.save"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail"]
                .waitForExistence(timeout: Timeout.long),
            "The created meal did not open its detail."
        )
        XCTAssertTrue(app.staticTexts["Native QA meal notes"].exists)
        XCTAssertNotNil(
            revealMealPreview("meals.detail.preview.nutrient.ENERGY_KCAL"),
            "The created meal preview did not load."
        )
        XCTAssertEqual(
            try mockState().mealCreateCount,
            baseline.mealCreateCount + 1
        )

        try removeFixtureFood("qa-apple")
        app.buttons["meals.close"].tap()
        guard openFeatureDestination(.meals) else {
            XCTFail("Meals could not be reopened after the ingredient removal.")
            return
        }
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                self.app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH %@", "meals.list.missing."))
                    .count > 0
            },
            "The degraded meal warning was not shown in the list."
        )
        let mealRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Native QA Built Meal")
        ).firstMatch
        XCTAssertTrue(mealRow.waitForExistence(timeout: Timeout.long))
        mealRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.missing"]
                .waitForExistence(timeout: Timeout.long),
            "The degraded meal did not expose the missing-ingredient warning."
        )
        XCTAssertNotNil(
            revealMealPreview("meals.detail.preview.unavailable"),
            "A degraded meal must not show a false preview."
        )
        XCTAssertFalse(
            app.buttons["meals.detail.log"].exists,
            "A degraded meal must not offer a log action."
        )
        let beforeRepair = try mockState()
        XCTAssertEqual(
            beforeRepair.logPostAttempts,
            baseline.logPostAttempts,
            "A degraded meal must not issue a log POST."
        )
        app.buttons["meals.detail.edit"].tap()
        XCTAssertTrue(
            app.textFields["meals.editor.name"].waitForExistence(timeout: Timeout.long)
        )
        let remove = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove Component")
        ).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: Timeout.normal))
        remove.tap()
        let repairSearch = app.textFields.matching(
            NSPredicate(format: "label == %@", "Search Food")
        ).firstMatch
        XCTAssertTrue(
            repairSearch.waitForExistence(timeout: Timeout.normal),
            "The repaired component picker is not reachable."
        )
        repairSearch.tap()
        repairSearch.typeText("Native QA Pear")
        let pear = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Native QA Pear")
        ).firstMatch
        XCTAssertTrue(pear.waitForExistence(timeout: Timeout.normal))
        pear.tap()
        app.buttons["meals.editor.save"].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.descendants(matching: .any)["meals.detail.missing"].exists
                    && self.app.buttons["meals.detail.log"].isEnabled
            },
            "The repaired meal did not return to a loggable state."
        )
        XCTAssertNotNil(
            revealMealPreview("meals.detail.preview.nutrient.ENERGY_KCAL"),
            "The repaired meal preview did not load."
        )
        let beforeLog = try mockState()
        app.buttons["meals.detail.log"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.log.success"]
                .waitForExistence(timeout: Timeout.long),
            "The repaired meal did not log."
        )
        let afterLog = try mockState()
        XCTAssertEqual(afterLog.logPostAttempts, beforeLog.logPostAttempts + 1)
        XCTAssertEqual(afterLog.logCount, beforeLog.logCount + 1)
        app.buttons["meals.detail.delete"].tap()
        let deleteAlert = app.alerts.firstMatch
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: Timeout.normal))
        deleteAlert.buttons["Delete Meal"].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                self.app.descendants(matching: .any)["meals.list"].exists
                    && self.app.buttons.matching(
                        NSPredicate(format: "label CONTAINS %@", "Native QA Built Meal")
                    ).count == 0
            },
            "The deleted meal remained in the list."
        )
        let final = try mockState()
        XCTAssertEqual(final.mealUpdateCount, baseline.mealUpdateCount + 1)
        XCTAssertEqual(final.mealDeleteCount, baseline.mealDeleteCount + 1)
        XCTAssertEqual(final.mealCount, baseline.mealCount)
        app.buttons["meals.close"].tap()
        scrollDiaryToTop()
        XCTAssertTrue(isHistoricalDateVisible(), "The selected historical date was not held.")
        assertFixtureAccountBinding("meals CRUD")
    }

    // MARK: - Feature destination discovery

    private enum FeatureDestination {
        case library
        case meals
        case nutrition
        case apiKeys

        var identifier: String {
            switch self {
            case .library:
                return "diary.library"
            case .meals:
                return "diary.meals"
            case .nutrition:
                return "diary.nutrition"
            case .apiKeys:
                return "settings.apiKeys.entry"
            }
        }
    }

    /// The persistent feature bar exposes Library, Meals, and Nutrition
    /// directly. The old `diary.more` overflow was removed, so these journeys
    /// must never depend on a private menu that XCUITest cannot observe.
    private func openDirectFeatureDestination(_ destination: FeatureDestination) -> Bool {
        guard let entry = hittableElement(identifier: destination.identifier) else {
            return false
        }
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return waitForFeatureSurface()
    }

    private func openFeatureDestination(_ destination: FeatureDestination) -> Bool {
        if destination == .apiKeys {
            return openAPIKeysFromSettings()
        }
        guard openDirectFeatureDestination(destination) else {
            print("NATIVE_QA_FEATURE_MISS \(destination.identifier)\n\(app.debugDescription)")
            return false
        }
        return true
    }

    private func openAPIKeysFromSettings() -> Bool {
        if !app.descendants(matching: .any)[Identifier.settingsSheet].exists {
            openSettings()
            guard app.descendants(matching: .any)[Identifier.goalCalories]
                .waitForExistence(timeout: Timeout.normal) else {
                return false
            }
        }
        guard let entry = scrollToElement(
            "settings.apiKeys.entry",
            marker: Identifier.settingsSheet,
            direction: .up
        ), entry.isHittable else {
            print("NATIVE_QA_FEATURE_MISS settings.apiKeys.entry\n\(app.debugDescription)")
            return false
        }
        entry.tap()
        return CalCoE2E.waitUntil(timeout: Timeout.normal) {
            self.app.descendants(matching: .any)["settings.apiKeys"].exists
                || self.app.descendants(matching: .any)["settings.apiKeys.list"].exists
        }
    }

    // MARK: - Signed-in fixture

    private func launchSignedIn(dynamicType: String? = nil) throws -> Bool {
        app = makeApp(dynamicType: dynamicType)
        var launched = false
        for _ in 0..<2 {
            app.launch()
            launched = CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.app.state == .runningForeground
                    && (CalCoE2E.isLoginFormVisible(in: self.app)
                        || CalCoE2E.isLoadedDiary(in: self.app)
                        || self.app.descendants(matching: .any)["auth.session.restoreFailed"].exists
                        || self.app.descendants(matching: .any)["app.configuration.error"].exists)
            }
            if launched { break }
            app.terminate()
        }
        XCTAssertTrue(launched, "The Test app did not reach a live launch surface.")
        try CalCoE2E.requireFreshLogin(in: app)
        try signInFixture()
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)

        // At accessibility sizes the first Sign In tap can land during the
        // secure-field paste animation. Retry only while the login form is
        // still visible and the submit control is enabled.
        if !CalCoE2E.waitForLoadedDiary(in: app, timeout: 8),
           CalCoE2E.isLoginFormVisible(in: app),
           !app.descendants(matching: .any)["auth.login.error"].exists {
            tapSignInAboveKeyboard()
        }

        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long) else {
            let observed = [
                "auth.login.error",
                "auth.session.restoreFailed",
                "app.configuration.error",
                "diary.sessionExpired",
                "diary.error",
            ].filter { app.descendants(matching: .any)[$0].exists }
            let loginError = app.descendants(matching: .any)["auth.login.error"]
            let detail = loginError.exists ? ": \(loginError.label)" : ""
            XCTFail(
                "Fixture sign-in did not reach the diary. Observed: "
                    + (observed.isEmpty ? "neither diary nor error" : observed.joined(separator: ", "))
                    + detail
                    + "\n\(app.debugDescription)"
            )
            return false
        }
        CalCoE2E.dismissSavePasswordPrompt(in: app)
        guard waitForFetchCount(atLeast: 1) else {
            XCTFail("The diary never completed its initial fixture fetch.")
            return false
        }
        return true
    }

    /// Fixture-only sign-in. The password is the nonsecret `native-qa` fixture
    /// value. Avoid Cmd+A on the SecureField because the iOS 26 runner can be
    /// killed by the secure text permission/selection path; use delete keys and
    /// the keyboard accessory Sign In instead.
    private func signInFixture() throws {
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        guard username.waitForExistence(timeout: Timeout.normal),
              password.waitForExistence(timeout: Timeout.normal) else {
            throw CalCoE2E.StateError(description: "The login form did not appear.")
        }
        username.tap()
        username.typeText(QA.username)
        // At AX XXXL the secure field's expanded row can place its frame center
        // under the keyboard. Tap the visible text baseline, then retry once
        // before typing.
        password.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)
        ).tap()
        if !app.keyboards.firstMatch.exists {
            password.tap()
        }
        guard app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short) else {
            throw CalCoE2E.StateError(description: "The login keyboard did not appear.")
        }
        // The fixture password is deliberately nonsecret. Direct typing avoids
        // the iOS 26 SecureField Cmd+A/paste permission path that can kill the
        // test runner; no real credential ever enters this harness.
        password.typeText(QA.password)
        if (password.value as? String ?? "").isEmpty {
            password.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
                password.typeText(QA.password)
            }
        }
        XCTAssertFalse(
            (password.value as? String ?? "").isEmpty,
            "The nonsecret fixture password did not populate the secure field."
        )

        let accessorySignIn = app.buttons["auth.login.keyboard.submit"]
        if accessorySignIn.exists, accessorySignIn.isHittable {
            accessorySignIn.tap()
        } else {
            tapSignInAboveKeyboard()
        }
        _ = CalCoE2E.waitForLoadedDiary(in: app, timeout: 10)
        if CalCoE2E.isLoginFormVisible(in: app),
           !app.descendants(matching: .any)["auth.login.error"].exists {
            approveFixturePastePrompt()
            tapSignInAboveKeyboard()
        }
    }

    private func approveFixturePastePrompt() {
        let candidates = [
            app!,
            XCUIApplication(bundleIdentifier: "com.apple.springboard"),
        ]
        for candidate in candidates {
            let alert = candidate.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { continue }
            for label in ["Allow Paste", "Paste", "Allow"] {
                let button = alert.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    return
                }
            }
        }
    }

    /// At accessibility sizes the login Form can place Sign In behind the
    /// software keyboard. Scroll the form until the button clears the keyboard
    /// before tapping; this is the user-visible escape path, not a private hook.
    private func tapSignInAboveKeyboard() {
        let submit = app.buttons["auth.login.submit"]
        guard submit.exists, submit.isEnabled else { return }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            for _ in 0..<4 {
                if submit.frame.maxY <= keyboard.frame.minY - 4 { break }
                let form = app.collectionViews.firstMatch
                if form.exists {
                    form.swipeUp()
                } else {
                    app.swipeUp()
                }
            }
        }
        if submit.isHittable {
            submit.tap()
        }
    }

    private func makeApp(dynamicType: String?) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        if let dynamicType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", dynamicType]
        }
        return app
    }

    private func assertIPhone13Mini() throws {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("No app window is visible.")
            return
        }
        let width = window.frame.width
        let height = window.frame.height
        guard abs(width - 375) <= 1, abs(height - 812) <= 1 else {
            throw XCTSkip(
                "This acceptance test requires the iPhone 13 mini 375x812-point "
                    + "window; observed \(Int(width))x\(Int(height))."
            )
        }
    }

    // MARK: - Diary navigation and assertions

    private func navigateToHistoricalFixtureDay() {
        scrollDiaryToTop()
        let startingTitle = app.navigationBars.firstMatch.identifier
        for attempt in 0..<3 {
            let before = fetchCount() ?? 0
            guard tapToolbarAction(Identifier.previousDay) else {
                XCTFail("Previous Day is not reachable on the mini.")
                return
            }
            XCTAssertTrue(
                waitForFetchCount(greaterThan: before),
                "Previous Day did not complete a diary fetch."
            )
            let changed = CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.app.navigationBars.firstMatch.identifier != startingTitle
            }
            if scrollToElement(
                Identifier.historicalLog,
                marker: Identifier.diarySummary,
                direction: .up
            ) != nil {
                scrollDiaryToTop()
                return
            }
            // A transition tap can be swallowed once; retry only if the title
            // did not change, so we never navigate two days back accidentally.
            if changed { break }
            _ = attempt
        }
        XCTFail(
            "The historical fixture log is not visible after Previous Day. "
                + "The fixture date and the app's local today may disagree."
        )
    }

    private func isHistoricalDateVisible() -> Bool {
        guard app.descendants(matching: .any)[Identifier.diarySummary].exists else {
            return false
        }
        if historicalLogCount() > 0 {
            return true
        }
        guard let container = diaryContainer() else { return false }
        for _ in 0..<16 {
            container.swipeUp()
            if historicalLogCount() > 0 { return true }
        }
        return false
    }

    private func historicalLogCount() -> Int {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "diary.log.hist-log-")
        ).count
    }

    private func assertHistoricalContext(retainedSummary: String?) {
        scrollDiaryToTop()
        XCTAssertTrue(
            isHistoricalDateVisible(),
            "The historical fixture log is no longer rendered after the round trip."
        )
        XCTAssertEqual(
            summaryLabel(),
            retainedSummary,
            "The historical summary changed after returning from the destination."
        )
    }

    private func summaryLabel() -> String? {
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.diarySummary)
            .allElementsBoundByIndex
        let labels = summaries.map(\.label).filter { !$0.isEmpty }
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }

    private func displayedCalories() -> Int? {
        guard let label = summaryLabel() else { return nil }
        let current = label.split(separator: "/", maxSplits: 1).first.map(String.init) ?? label
        let digits = current.filter(\.isNumber)
        return Int(digits)
    }

    /// The diary row is a plain-style Button with combined accessibility
    /// children. Its row center is blank space, so tap the visible title.
    private func openHistoricalLogRow() {
        let title = app.staticTexts["Historical Oats"]
        if title.exists, title.isHittable {
            title.tap()
        } else {
            app.buttons[Identifier.historicalLog].tap()
        }
    }

    /// Taps the visible food name rather than the plain-style row center. The
    /// latter currently falls in non-hit-testable blank space on the mini; see
    /// testMiniSearchResultBackgroundRemainsSelectable.
    /// Bounded AX-observed retry for the search field. The app can briefly have
    /// the keyboard focused on a different control after a sheet transition;
    /// typeText without focus raises a synthesis failure.
    private func typeSearchQuery(_ text: String, in search: XCUIElement) {
        for _ in 0..<3 {
            if !app.keyboards.firstMatch.exists {
                search.tap()
            }
            guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else {
                continue
            }
            search.typeText(text)
            if CalCoE2E.waitUntil(timeout: 3, condition: {
                let value = search.value as? String ?? ""
                return value == text || value.contains(text)
            }) {
                return
            }
        }
        XCTFail("The search field never accepted the query with keyboard focus.")
    }

    private func selectFixtureSearchResult() {
        let name = app.staticTexts["Native QA Apple"]
        let results = app.collectionViews["search.results"]
        for _ in 0..<6 {
            guard name.exists else { break }
            let keyboardTop = app.keyboards.firstMatch.exists
                ? app.keyboards.firstMatch.frame.minY
                : app.windows.firstMatch.frame.maxY
            if name.isHittable, name.frame.minY < keyboardTop - 8 {
                let visibleFraction = min(
                    0.9,
                    max(
                        0.15,
                        (keyboardTop - 12 - name.frame.minY)
                            / max(name.frame.height, 1)
                    )
                )
                name.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: visibleFraction * 0.5)
                ).tap()
                return
            }
            if results.exists {
                results.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        if name.exists, name.isHittable {
            name.tap()
        } else {
            app.buttons[Identifier.searchResult].tap()
        }
    }

    private func submitFixtureFood() {
        guard let addFood = scrollToElement(
            matchingPrefix: Identifier.addFoodPrefix,
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("No diary.addFood.* control was reachable.")
            return
        }
        addFood.tap()

        let search = app.descendants(matching: .any)[Identifier.searchField]
        guard search.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("Search did not open after Add Food.")
            return
        }
        typeSearchQuery("Native QA", in: search)

        let result = app.buttons[Identifier.searchResult]
        guard result.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("The fixture search result did not appear.")
            return
        }
        selectFixtureSearchResult()

        let submit = app.buttons[Identifier.submit]
        guard submit.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("Food detail did not load for the fixture food.")
            return
        }
        if !submit.isHittable {
            _ = scrollToElement(
                Identifier.amountField,
                marker: Identifier.amountField,
                direction: .down
            )
        }
        XCTAssertTrue(submit.isHittable, "The Log action was not reachable.")
        submit.tap()
    }

    private func openSearchFromDiary() {
        guard let addFood = scrollToElement(
            matchingPrefix: Identifier.addFoodPrefix,
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("No diary.addFood.* control was reachable.")
            return
        }
        addFood.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.searchField]
                .waitForExistence(timeout: Timeout.normal),
            "Search did not open."
        )
    }

    private func waitForSettingsGoals() -> Bool {
        app.descendants(matching: .any)[Identifier.goalCalories]
            .waitForExistence(timeout: Timeout.normal)
    }

    private func tryLogCount() -> Int {
        (try? mockState().logCount) ?? -1
    }

    private func openSettings() {
        guard tapToolbarAction(Identifier.settings) else {
            XCTFail("The diary settings action is not reachable on the mini.")
            return
        }
        _ = app.descendants(matching: .any)[Identifier.settingsSheet]
            .waitForExistence(timeout: Timeout.normal)
    }

    private func waitForFeatureSurface() -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.short) {
            !self.app.descendants(matching: .any)[Identifier.diarySummary].exists
                || self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
                || self.app.navigationBars.count > 1
        }
    }

    private func dismissToDiary() {
        XCTAssertTrue(
            returnToDiaryFromFlow(),
            "Could not return to the diary from the destination."
        )
    }

    /// A pushed compact stack can keep the diary summary in the accessibility
    /// tree behind Search/FoodDetail. Check the top navigation surface and pop
    /// up to three destinations instead of trusting `exists` alone.
    private func returnToDiaryFromFlow() -> Bool {
        for _ in 0..<4 {
            let navBar = app.navigationBars.firstMatch
            let topIsNotDiary = navBar.exists
                && (navBar.identifier == "Search" || navBar.identifier.contains("Native QA"))
            if !topIsNotDiary,
               app.descendants(matching: .any)[Identifier.diarySummary].exists,
               app.buttons[Identifier.settings].exists {
                return true
            }
            if app.descendants(matching: .any)[Identifier.settingsSheet].exists {
                let cancel = app.buttons[Identifier.settingsCancel]
                if cancel.exists, cancel.isHittable {
                    cancel.tap()
                    _ = CalCoE2E.waitUntil(timeout: Timeout.normal) {
                        !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
                    }
                    continue
                }
            }
            if let close = hittableButton(labels: ["Close", "Done", "Cancel"]) {
                close.tap()
                _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                    !self.app.descendants(matching: .any)[Identifier.diarySummary].exists
                        || !self.app.buttons[Identifier.settings].exists
                }
                continue
            }
            if let back = leftmostNavigationBackButton() {
                back.tap()
                _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                    self.app.buttons[Identifier.settings].exists
                        && self.app.descendants(matching: .any)[Identifier.diarySummary].exists
                }
                continue
            }
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                self.app.descendants(matching: .any)[Identifier.diarySummary].exists
            }
        }
        return app.descendants(matching: .any)[Identifier.diarySummary].exists
            && app.buttons[Identifier.settings].exists
    }

    private func leftmostNavigationBackButton() -> XCUIElement? {
        let window = app.windows.firstMatch
        let navBars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists }
        let buttons = navBars.flatMap { bar in
            bar.buttons.allElementsBoundByIndex.filter {
                $0.exists
                    && $0.isHittable
                    && $0.frame.midX < window.frame.midX
                    && $0.identifier != "auth.signOut"
            }
        }
        return buttons.min { $0.frame.minX < $1.frame.minX }
    }

    // MARK: - Toolbar

    private func assertToolbarActionsReachable(_ identifiers: [String]) {
        let direct = identifiers.filter { visibleElement(identifier: $0) != nil }
        let missing = identifiers.filter { !direct.contains($0) }
        if missing.isEmpty { return }

        guard let overflow = toolbarOverflowControls().first(where: {
            $0.exists && $0.isHittable
        }) else {
            XCTFail(
                "Toolbar actions \(missing.joined(separator: ", ")) are hidden on the mini "
                    + "and no hittable overflow control exists."
            )
            return
        }
        overflow.tap()
        attachScreenshot(named: "iPhone-13-mini-toolbar-overflow")
        let revealed = missing.filter { visibleElement(identifier: $0) != nil }
        let unverified = missing.filter { !revealed.contains($0) }
        print(
            "NATIVE_QA_TOOLBAR_MENU_AX_GAP hidden=\(missing.joined(separator: ",")) "
                + "ax_revealed=\(revealed.joined(separator: ","))"
        )
        XCTAssertTrue(
            unverified.isEmpty,
            "iOS 26 toolbar overflow items are not exposed in the app AX tree; "
                + "cannot verify \(unverified.joined(separator: ", "))."
        )
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)
        ).tap()
    }

    private func tapToolbarAction(_ identifier: String) -> Bool {
        let direct = CalCoE2E.waitUntil(timeout: Timeout.short) {
            self.laidOutElement(identifier: identifier) != nil
        }
        if direct, let element = laidOutElement(identifier: identifier) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        for overflow in toolbarOverflowControls() where overflow.exists && overflow.isHittable {
            overflow.tap()
            if let revealed = laidOutElement(identifier: identifier) {
                revealed.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
                return true
            }
        }
        return false
    }

    private func laidOutElement(identifier: String) -> XCUIElement? {
        let window = app.windows.firstMatch
        return app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .first {
                $0.exists
                    && $0.isHittable
                    && $0.frame.width > 1
                    && $0.frame.height > 1
                    && window.frame.intersects($0.frame)
            }
    }

    private func toolbarOverflowControls() -> [XCUIElement] {
        let predicates = [
            NSPredicate(format: "label BEGINSWITH[c] %@", "More"),
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

    private func hittableElement(identifier: String) -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .first {
                $0.exists
                    && $0.isHittable
                    && $0.frame.width > 1
                    && $0.frame.height > 1
            }
    }

    private func hittableElement(matchingPrefixes prefixes: [String]) -> XCUIElement? {
        for prefix in prefixes {
            if let element = app.descendants(matching: .any)
                .matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", prefix)
                )
                .allElementsBoundByIndex
                .first(where: { $0.exists && $0.isHittable }) {
                return element
            }
        }
        return nil
    }

    private func visibleElement(identifier: String) -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
            .first {
                $0.exists && $0.frame.width > 0 && $0.frame.height > 0
            }
    }

    private func hittableButton(labels: [String]) -> XCUIElement? {
        for label in labels {
            if let button = app.buttons.matching(
                NSPredicate(format: "label ==[c] %@", label)
            ).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return button
            }
        }
        return nil
    }

    private func tapButton(label: String) -> Bool {
        guard let button = hittableButton(labels: [label]) else { return false }
        button.tap()
        return true
    }

    // MARK: - Scrolling and fields

    private enum ScrollDirection {
        case up
        case down
    }

    private func scrollToElement(
        _ identifier: String,
        marker: String,
        direction: ScrollDirection,
        maxSwipes: Int = 16
    ) -> XCUIElement? {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists, element.isHittable { return element }
        guard let container = scrollContainer(marker: marker) else {
            return element.exists ? element : nil
        }
        switch direction {
        case .up:
            for _ in 0..<maxSwipes {
                if container.exists { container.swipeUp() } else { app.swipeUp() }
                if element.exists, element.isHittable { return element }
            }
            for _ in 0..<maxSwipes {
                if container.exists { container.swipeDown() } else { app.swipeDown() }
                if element.exists, element.isHittable { return element }
            }
        case .down:
            for _ in 0..<maxSwipes {
                if container.exists { container.swipeDown() } else { app.swipeDown() }
                if element.exists, element.isHittable { return element }
            }
            for _ in 0..<maxSwipes {
                if container.exists { container.swipeUp() } else { app.swipeUp() }
                if element.exists, element.isHittable { return element }
            }
        }
        return element.exists ? element : nil
    }

    private func scrollToElement(
        matchingPrefix prefix: String,
        marker: String,
        direction: ScrollDirection,
        maxSwipes: Int = 20
    ) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        if let element = app.buttons.matching(predicate).allElementsBoundByIndex
            .first(where: { $0.exists && $0.isHittable }) {
            return element
        }
        guard let container = scrollContainer(marker: marker) else { return nil }
        switch direction {
        case .up:
            for _ in 0..<maxSwipes {
                container.swipeUp()
                if let element = app.buttons.matching(predicate).allElementsBoundByIndex
                    .first(where: { $0.exists && $0.isHittable }) {
                    return element
                }
            }
        case .down:
            for _ in 0..<maxSwipes {
                container.swipeDown()
                if let element = app.buttons.matching(predicate).allElementsBoundByIndex
                    .first(where: { $0.exists && $0.isHittable }) {
                    return element
                }
            }
        }
        return nil
    }

    private func hittablePrefixButton(labelPrefix: String) -> XCUIElement? {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", labelPrefix)
        ).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    private func scrollToButton(
        labelPrefix: String,
        marker: String,
        direction: ScrollDirection,
        maxSwipes: Int = 16
    ) -> XCUIElement? {
        if let button = hittablePrefixButton(labelPrefix: labelPrefix) {
            return button
        }
        let container = scrollContainer(marker: marker)
        switch direction {
        case .up:
            for _ in 0..<maxSwipes {
                if let container {
                    container.swipeUp()
                } else {
                    app.swipeUp()
                }
                if let button = hittablePrefixButton(labelPrefix: labelPrefix) {
                    return button
                }
            }
        case .down:
            for _ in 0..<maxSwipes {
                if let container {
                    container.swipeDown()
                } else {
                    app.swipeDown()
                }
                if let button = hittablePrefixButton(labelPrefix: labelPrefix) {
                    return button
                }
            }
        }
        if direction == .up {
            for _ in 0..<8 {
                app.swipeUp()
                if let button = hittablePrefixButton(labelPrefix: labelPrefix) {
                    return button
                }
            }
            // At AX XXXL the global pending banner can cover most of the
            // window, so full-window swipes never reach the form. Drag inside
            // the remaining visible strip below the banner instead.
            let window = app.windows.firstMatch
            let start = window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)
            )
            let end = window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78)
            )
            for _ in 0..<12 {
                start.press(forDuration: 0.05, thenDragTo: end)
                if let button = hittablePrefixButton(labelPrefix: labelPrefix) {
                    return button
                }
            }
        }
        return hittablePrefixButton(labelPrefix: labelPrefix)
    }

    private func scrollContainer(marker: String) -> XCUIElement? {
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        let existing = candidates.filter { $0.exists }
        return existing.first { container in
            container.descendants(matching: .any)[marker].exists
                || container.descendants(matching: .any)
                    .matching(
                        NSPredicate(format: "identifier BEGINSWITH %@", marker)
                    ).count > 0
        } ?? existing.first
    }

    private func diaryContainer() -> XCUIElement? {
        scrollContainer(marker: Identifier.diarySummary)
    }

    private func scrollDiaryToTop() {
        let window = app.windows.firstMatch
        for _ in 0..<12 {
            guard let summary = visibleElement(identifier: Identifier.diarySummary) else {
                return
            }
            // A swipe-down at the top triggers SwiftUI pull-to-refresh, whose
            // indeterminate spinner stops XCUITest from ever seeing idle. If
            // the summary is already on screen anywhere, do not swipe.
            if window.frame.intersects(summary.frame), summary.frame.minY >= 0 {
                return
            }
            diaryContainer()?.swipeDown()
        }
    }

    private func selectOption(_ label: String, from control: XCUIElement) -> Bool {
        control.tap()
        let option = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", label)
        ).firstMatch
        guard option.waitForExistence(timeout: Timeout.short) else { return false }
        option.tap()
        return true
    }

    private func revealMealPreview(_ identifier: String) -> XCUIElement? {
        let element = app.descendants(matching: .any)[identifier]
        if element.exists { return element }
        let container = app.collectionViews["meals.detail"]
        for _ in 0..<4 {
            if container.exists {
                container.swipeUp()
            } else {
                app.swipeUp()
            }
            if element.exists { return element }
        }
        return element.exists ? element : nil
    }

    private func dismissLibraryKeyboard(_ identifier: String) {
        let done = app.buttons[identifier]
        XCTAssertTrue(
            done.waitForExistence(timeout: Timeout.short),
            "\(identifier) is missing while the keyboard is up."
        )
        XCTAssertTrue(done.isHittable, "\(identifier) is not hittable while the keyboard is up.")
        done.tap()
    }

    private func fillRequiredNutrients(
        _ values: [(code: String, amount: String)],
        marker: String,
        doneIdentifier: String
    ) {
        for entry in values {
            guard let field = scrollToElement(
                "library.nutrient.\(entry.code).field",
                marker: marker,
                direction: .down
            ) else {
                XCTFail("The required \(entry.code) field is not reachable.")
                return
            }
            field.tap()
            replaceText(in: field, with: entry.amount)
            XCTAssertEqual(
                field.value as? String,
                entry.amount,
                "The required \(entry.code) field did not replace its value."
            )
            dismissLibraryKeyboard(doneIdentifier)
        }
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.tap()
        let current = element.value as? String ?? ""
        let placeholder = element.placeholderValue ?? ""
        if !current.isEmpty, current != placeholder {
            element.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            )
        }
        element.typeText(value)
    }

    private func confirmationButton(_ identifier: String) -> XCUIElement? {
        let alerts = app.alerts.buttons.matching(identifier: identifier)
        if alerts.count > 0 { return alerts.firstMatch }
        let sheets = app.sheets.buttons.matching(identifier: identifier)
        if sheets.count > 0 { return sheets.firstMatch }
        let query = app.buttons.matching(identifier: identifier)
        if query.count > 0 { return query.firstMatch }
        return nil
    }

    private func confirmationButton(label: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label ==[c] %@", label)
        let queries = [
            app.buttons.matching(predicate),
            app.sheets.buttons.matching(predicate),
            app.alerts.buttons.matching(predicate),
        ]
        for query in queries where query.count > 0 {
            return query.firstMatch
        }
        return nil
    }

    // MARK: - Fetch marker

    private func fetchCount() -> Int? {
        let marker = app.descendants(matching: .any)[Identifier.fetchCompletionCount]
        guard marker.exists else { return nil }
        let raw = (marker.value as? String) ?? marker.label
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForFetchCount(atLeast minimum: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.long) {
            (self.fetchCount() ?? -1) >= minimum
        }
    }

    private func waitForFetchCount(greaterThan previous: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.long) {
            (self.fetchCount() ?? -1) > previous
        }
    }

    // MARK: - Loopback QA fixture

    private struct MockLog {
        let id: String
        let date: String
        let mealSlot: String?
        let amount: String
        let unit: String
    }

    private struct MockState {
        let logCount: Int
        let logPostAttempts: Int
        let idempotencyKeys: Int
        let protectedRequestCount: Int
        let boundRequestCount: Int
        let unboundProtectedRequestCount: Int
        let goalCalories: Int
        let customFoodCount: Int
        let customFoodCreateCount: Int
        let customFoodUpdateCount: Int
        let customFoodDeleteCount: Int
        let assistantDraftRequestCount: Int
        let mealCount: Int
        let mealCreateCount: Int
        let mealUpdateCount: Int
        let mealDeleteCount: Int
        let logs: [MockLog]
    }

    private struct MockResponse {
        let status: Int
        let data: Data
    }

    private func requireMockFixture() throws {
        let response: MockResponse
        do {
            response = try mockRequest(method: "GET", path: "/__qa/health")
        } catch {
            throw XCTSkip(
                "NativeCompletionQAMockServer.py is not running at \(QA.baseURL); "
                    + "start it with the command in docs/native-completion-qa.md."
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

    private func resetFixture(
        logPost: String = "success",
        assistantEnabled: Bool = false
    ) throws {
        let body: [String: Any] = [
            "today": Self.isoDay(Date()),
            "log_post": logPost,
            "seed_logs": true,
            "assistant_enabled": assistantEnabled,
        ]
        let response = try mockRequest(method: "POST", path: "/__qa/reset", json: body)
        XCTAssertEqual(
            response.status,
            200,
            "The native QA fixture rejected its reset request."
        )
    }

    private func removeFixtureFood(_ foodID: String) throws {
        let response = try mockRequest(
            method: "POST",
            path: "/__qa/remove-food",
            json: ["id": foodID]
        )
        XCTAssertEqual(response.status, 200, "The fixture could not remove \(foodID).")
    }

    private func sendAssistantPrompt(_ text: String, draftTimeout: TimeInterval) {
        let composer = app.descendants(matching: .any)["assistant.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: Timeout.normal), "Assistant composer missing.")
        composer.tap()
        composer.typeText(text)
        app.buttons["assistant.send"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["assistant.draft"]
                .waitForExistence(timeout: draftTimeout),
            "Assistant draft did not appear."
        )
    }

    private func openAssistant(_ purposeIdentifier: String) {
        openSearchFromDiary()
        guard let assistant = hittableElement(identifier: "search.assistant") else {
            XCTFail("Assistant entry is not reachable from Search.")
            return
        }
        assistant.tap()
        let purpose = app.buttons[purposeIdentifier]
        XCTAssertTrue(
            purpose.waitForExistence(timeout: Timeout.normal),
            "Assistant purpose \(purposeIdentifier) is missing."
        )
        purpose.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["assistant.composer"]
                .waitForExistence(timeout: Timeout.normal),
            "Assistant did not become enabled."
        )
    }

    private func mockState() throws -> MockState {
        let response = try mockRequest(method: "GET", path: "/__qa/state")
        XCTAssertEqual(response.status, 200, "The native QA fixture state is unavailable.")
        guard let object = try JSONSerialization.jsonObject(with: response.data)
            as? [String: Any] else {
            throw StateError(description: "The native QA fixture returned malformed state.")
        }
        let logs = (object["logs"] as? [[String: Any]] ?? []).map { log in
            MockLog(
                id: log["id"] as? String ?? "",
                date: log["date"] as? String ?? "",
                mealSlot: log["meal_slot"] as? String,
                amount: log["amount"] as? String ?? "",
                unit: log["unit"] as? String ?? ""
            )
        }
        return MockState(
            logCount: object["log_count"] as? Int ?? -1,
            logPostAttempts: object["log_post_attempts"] as? Int ?? -1,
            idempotencyKeys: object["idempotency_keys"] as? Int ?? -1,
            protectedRequestCount: object["protected_request_count"] as? Int ?? -1,
            boundRequestCount: object["bound_request_count"] as? Int ?? -1,
            unboundProtectedRequestCount: object["unbound_protected_request_count"] as? Int ?? -1,
            goalCalories: object["goal_calories"] as? Int ?? -1,
            customFoodCount: object["custom_food_count"] as? Int ?? -1,
            customFoodCreateCount: object["custom_food_create_count"] as? Int ?? -1,
            customFoodUpdateCount: object["custom_food_update_count"] as? Int ?? -1,
            customFoodDeleteCount: object["custom_food_delete_count"] as? Int ?? -1,
            assistantDraftRequestCount: object["assistant_draft_request_count"] as? Int ?? -1,
            mealCount: object["meal_count"] as? Int ?? -1,
            mealCreateCount: object["meal_create_count"] as? Int ?? -1,
            mealUpdateCount: object["meal_update_count"] as? Int ?? -1,
            mealDeleteCount: object["meal_delete_count"] as? Int ?? -1,
            logs: logs
        )
    }

    private func assertFixtureAccountBinding(_ context: String) {
        do {
            let state = try mockState()
            XCTAssertGreaterThan(
                state.boundRequestCount,
                0,
                "\(context): no protected request carried \(mockAccountHeader)."
            )
            XCTAssertEqual(
                state.unboundProtectedRequestCount,
                0,
                "\(context): \(state.unboundProtectedRequestCount) protected requests "
                    + "were still unbound."
            )
        } catch {
            XCTFail("Could not read fixture binding counters for \(context): \(error)")
        }
    }

    private var mockAccountHeader: String { "X-CalCo-Account-ID" }

    private func assertMockLogCount(_ expected: Int) {
        let count: Int
        do {
            count = try mockState().logCount
        } catch {
            XCTFail("Could not read fixture record count: \(error)")
            return
        }
        XCTAssertEqual(
            count,
            expected,
            "The fixture record count does not match the expected value."
        )
    }

    private struct StateError: Error, CustomStringConvertible {
        let description: String
    }

    private func mockRequest(
        method: String,
        path: String,
        json: [String: Any]? = nil
    ) throws -> MockResponse {
        guard let url = URL(string: QA.baseURL + path) else {
            throw StateError(description: "Invalid QA fixture URL: \(QA.baseURL + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let box = MockResponseBox()
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

    private final class MockResponseBox: @unchecked Sendable {
        var status = -1
        var data = Data()
        var error: Error?
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Evidence

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
