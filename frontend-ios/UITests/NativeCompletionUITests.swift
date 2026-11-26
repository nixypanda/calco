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
        static let latestPrefix = "diary.latest."
        static let addFoodLabel = "Add food"
        static let latestLabel = "Log latest"
        static let nutritionDetails = "nutrition.details"
        static let nutritionClose = "nutrition.close"
        static let historicalLog = "diary.log.hist-log-001"
        static let searchField = "search.field"
        static let searchResult = "search.result.qa-apple"
        static let amountField = "foodDetail.amount.field"
        static let notesField = "foodDetail.notes.field"
        static let submit = "foodDetail.submit"
        static let submitWarning = "foodDetail.submit.warning"
        static let submitError = "foodDetail.submit.error"
        static let submitSuccess = "foodDetail.submit.success"
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
        static let settingsDiscardConfirm = "settings.discard.confirm"
        static let settingsDiscardCancel = "settings.discard.cancel"
        static let editorDiscardConfirm = "diary.editor.discard.confirm"
        static let editorDiscardCancel = "diary.editor.discard.cancel"
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

    func testPagePlanLogEditorKeepsDeleteOutOfTheSaveBar() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        XCTAssertTrue(tapToolbarAction(Identifier.previousDay))
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.historicalLog]
            .waitForExistence(timeout: Timeout.long))
        let row = try XCTUnwrap(scrollToElement(Identifier.historicalLog,
                                              marker: Identifier.diarySummary, direction: .up))
        row.tap()
        let save = app.buttons[Identifier.editorSave]
        XCTAssertTrue(save.waitForExistence(timeout: Timeout.normal))
        XCTAssertFalse(save.isEnabled)
        XCTAssertGreaterThan(save.frame.width, app.frame.width - 60)
        let delete = try XCTUnwrap(scrollToElement(Identifier.editorDelete,
                                                 marker: Identifier.editorAmount, direction: .up))
        XCTAssertTrue(delete.isEnabled)
        let bar = app.descendants(matching: .any)["diary.editor.actions"]
        XCTAssertFalse(bar.buttons[Identifier.editorDelete].exists)
        XCTAssertLessThan(delete.frame.maxY, save.frame.minY)
        XCTAssertEqual(app.sheets.count, 0)
    }

    func testPagePlanFoodAndMealEditorsUseBackAndSave() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        XCTAssertTrue(tapFirstReachable(["app.tab.library"], labels: ["Library"]))
        XCTAssertTrue(selectLibrarySection("Foods", identifier: "library.foods"))
        app.buttons["library.add"].tap()
        app.buttons["library.add.custom"].tap()
        let foodName = app.descendants(matching: .any)["library.editor.name"]
        XCTAssertTrue(foodName.waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(app.buttons["library.editor.save"].exists)
        XCTAssertEqual(app.sheets.count, 0, "The custom-food editor must be a page.")
        XCTAssertFalse(app.buttons["diary.common.cancel"].exists)
        replaceText(in: foodName, with: "Page QA Food")
        dismissLibraryKeyboard("library.editor.keyboard.done")
        app.buttons["library.editor.back"].tap()
        let discardFood = app.alerts.firstMatch.buttons
            .matching(NSPredicate(format: "label == %@", "Discard changes")).firstMatch
        XCTAssertTrue(discardFood.waitForExistence(timeout: Timeout.normal))
        discardFood.tap()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: Timeout.normal))
        app.navigationBars.buttons["Library"].tap()

        XCTAssertTrue(selectLibrarySection("Meals", identifier: "library.meals"))
        app.buttons["meals.list.add"].tap()
        let mealName = app.descendants(matching: .any)["meals.editor.name"]
        XCTAssertTrue(mealName.waitForExistence(timeout: Timeout.normal))
        XCTAssertEqual(app.sheets.count, 0, "The meal editor must be a page.")
        XCTAssertFalse(app.buttons["meals.list.add"].exists)
        replaceText(in: mealName, with: "Page QA Meal")
        if app.keyboards.firstMatch.exists { app.swipeUp() }
        let choose = try XCTUnwrap(scrollToElement("meals.editor.component.1.choose",
                                                 marker: "meals.editor.name", direction: .up))
        choose.tap()
        let search = app.textFields["meals.editor.component.1.search"]
        XCTAssertTrue(search.waitForExistence(timeout: Timeout.normal))
        XCTAssertFalse(app.buttons["meals.editor.save"].exists,
                       "Save belongs to the editor, not the ingredient picker.")
        search.tap()
        search.typeText("apple")
        let result = app.buttons["meals.editor.component.1.result.qa-apple"]
        XCTAssertTrue(result.waitForExistence(timeout: Timeout.long))
        result.tap()
        XCTAssertTrue(app.buttons["meals.editor.save"].waitForExistence(timeout: Timeout.normal))
        app.buttons["meals.editor.save"].tap()
        XCTAssertTrue(app.buttons["meals.detail.edit"].waitForExistence(timeout: Timeout.long))
        XCTAssertEqual(app.buttons.matching(identifier: "meals.detail.edit").count, 1)
        app.buttons["meals.detail.edit"].tap()
        XCTAssertTrue(app.buttons["meals.editor.save"].waitForExistence(timeout: Timeout.normal))
        XCTAssertEqual(app.sheets.count, 0)
    }

    func testPagePlanSettingsPushesKeysAndCreationRemainsASheet() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        XCTAssertTrue(tapFirstReachable(["app.tab.settings"], labels: ["Settings"]))
        XCTAssertTrue(app.descendants(matching: .any)["settings.goals.calories"]
            .waitForExistence(timeout: Timeout.normal))
        XCTAssertFalse(app.buttons["settings.back"].exists)
        let keys = try XCTUnwrap(scrollToElement("settings.apiKeys.entry",
                                               marker: "settings.sheet", direction: .up))
        keys.tap()
        let add = app.buttons["settings.apiKeys.create"]
        XCTAssertTrue(add.waitForExistence(timeout: Timeout.normal))
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertNotNil(leftmostNavigationBackButton())
        XCTAssertFalse(app.buttons["settings.apiKeys.close"].exists)
        add.tap()
        let cancel = app.buttons["settings.apiKeys.create.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Timeout.normal))
        XCTAssertEqual(cancel.label, "Cancel")
        cancel.tap()
        try XCTUnwrap(leftmostNavigationBackButton()).tap()
        XCTAssertTrue(app.buttons["settings.apiKeys.entry"].waitForExistence(timeout: Timeout.normal))
        XCTAssertFalse(app.buttons["settings.back"].exists)
    }

    func testPagePlanFoodLoggingIsACancellableTaskSheet() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        let baseline = try mockState()
        openSearchFromDiary()
        let field = app.textFields["search.field"]
        field.tap()
        field.typeText("apple")
        let result = app.buttons[Identifier.searchResult]
        XCTAssertTrue(result.waitForExistence(timeout: Timeout.long))
        result.tap()
        let cancel = app.buttons["foodDetail.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: Timeout.normal))
        XCTAssertEqual(app.buttons.matching(identifier: "foodDetail.submit").count, 1)
        cancel.tap()
        XCTAssertTrue(result.waitForExistence(timeout: Timeout.normal))
        XCTAssertEqual(field.value as? String, "apple")
        XCTAssertEqual(try mockState().logPostAttempts, baseline.logPostAttempts)
        result.tap()
        let log = app.buttons["foodDetail.submit"]
        XCTAssertTrue(log.waitForExistence(timeout: Timeout.normal))
        log.tap()
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.diarySummary]
            .waitForExistence(timeout: Timeout.long))
        XCTAssertFalse(app.buttons["foodDetail.cancel"].exists)
        assertMockLogCount(baseline.logCount + 1)
    }

    func testPagePlanNutritionIsAPageAndLibraryMealsAreManagementOnly() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        let nutrition = app.buttons["diary.nutrition"]
        XCTAssertTrue(nutrition.waitForExistence(timeout: Timeout.normal))
        nutrition.tap()
        XCTAssertTrue(app.descendants(matching: .any)["nutrition.details"]
            .waitForExistence(timeout: Timeout.long))
        XCTAssertFalse(app.buttons["nutrition.close"].exists)
        XCTAssertEqual(app.sheets.count, 0)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)[Identifier.diarySummary]
            .waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(tapFirstReachable(["app.tab.library"], labels: ["Library"]))
        XCTAssertTrue(selectLibrarySection("Meals", identifier: "library.meals"))
        let meal = app.buttons["meals.list.row.qa-meal-1"]
        XCTAssertTrue(meal.waitForExistence(timeout: Timeout.long))
        XCTAssertFalse(app.buttons["meals.list.quickAdd.qa-meal-1"].exists)
        meal.tap()
        XCTAssertTrue(app.buttons["meals.detail.edit"]
            .waitForExistence(timeout: Timeout.long))
        XCTAssertTrue(app.buttons["meals.detail.delete"].exists)
        XCTAssertFalse(app.buttons["meals.detail.openLog"].exists)
        XCTAssertFalse(app.buttons["meals.detail.log"].exists)
        XCTAssertEqual(app.sheets.count, 0)
    }

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

    // MARK: - TCA search cutover acceptance

    func testMiniSearchPreservesTrailingSpaceAcrossCompletedResults() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        openSearchFromDiary()

        let field = app.descendants(matching: .any)[Identifier.searchField]
        XCTAssertTrue(
            field.waitForExistence(timeout: Timeout.normal),
            "Search did not open."
        )

        let rawQuery = "Native "
        replaceText(in: field, with: rawQuery)
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) {
                (field.value as? String) == rawQuery
            },
            "The search field did not retain the raw query with its trailing space."
        )

        let result = app.buttons[Identifier.searchResult]
        XCTAssertTrue(
            result.waitForExistence(timeout: Timeout.long),
            "The fixture search result did not appear after the debounced search."
        )

        // The completed search must keep the exact raw field value, including the
        // trailing space that the API query trims for transport.
        XCTAssertEqual(
            field.value as? String,
            rawQuery,
            "The completed search trimmed the raw trailing space from the search field."
        )

        if !app.keyboards.firstMatch.exists {
            field.tap()
        }
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The keyboard did not remain available for continued typing."
        )

        field.typeText("QA")

        let combined = "Native QA"
        let settled = CalCoE2E.waitUntil(timeout: Timeout.long) {
            let value = field.value as? String ?? ""
            return value == combined || value.contains(combined)
        }
        XCTAssertTrue(
            settled,
            "The follow-up debounced search did not settle in the search field."
        )

        let finalValue = field.value as? String ?? ""
        XCTAssertTrue(
            finalValue.contains(combined),
            "Continued typing did not preserve the space between words: \(finalValue)"
        )
        XCTAssertFalse(
            finalValue.contains("NativeQA"),
            "Continued typing concatenated the words, losing the preserved space: \(finalValue)"
        )
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
        let save = app.buttons[Identifier.editorSave]
        let delete = app.buttons[Identifier.editorDelete]
        XCTAssertFalse(save.isEnabled, "An unchanged log must not be saved.")
        XCTAssertTrue(delete.isEnabled, "An unchanged log can still be deleted.")
        XCTAssertGreaterThan(
            save.frame.width,
            app.frame.width - 60,
            "Save must be the single full-width bottom action."
        )
        XCTAssertFalse(app.descendants(matching: .any)["diary.editor.actions"]
            .buttons[Identifier.editorDelete].exists, "Delete belongs in the form, not beside Save.")
        let amount = app.descendants(matching: .any)[Identifier.editorAmount]
        let originalAmount = try XCTUnwrap(amount.value as? String)
        replaceText(in: amount, with: originalAmount == "175" ? "200" : "175")
        XCTAssertTrue(save.isEnabled)
        replaceText(in: amount, with: originalAmount)
        XCTAssertFalse(save.isEnabled, "Reverting the change must disable Save again.")
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
        attachScreenshot(named: "iPhone-13-mini-dynamic-type-diary")

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

    // MARK: - Ordinary transient submission errors

    func testMiniTransientSubmissionErrorAllowsManualResubmission() throws {
        try resetFixture(logPost: "fail_once")
        XCTAssertTrue(
            try launchSignedIn(),
            "The diary did not load for the transient-error journey."
        )
        try assertIPhone13Mini()

        let baseline = try mockState()
        XCTAssertEqual(baseline.logCount, 8, "Unexpected fixture log baseline.")

        submitFixtureFood()
        let surfaced = CalCoE2E.waitUntil(timeout: Timeout.long) {
            self.app.descendants(matching: .any)[Identifier.submitError].exists
                || self.app.descendants(matching: .any)[Identifier.submitWarning].exists
        }
        XCTAssertTrue(
            surfaced,
            "The transient 503 did not surface an ordinary submission error."
        )

        // A transient failure must not trigger an automatic retry or write.
        let afterFailure = try mockState()
        XCTAssertEqual(
            afterFailure.logPostAttempts,
            baseline.logPostAttempts + 1,
            "The transient failure issued more than the one user-initiated submission."
        )
        XCTAssertEqual(
            afterFailure.logCount,
            baseline.logCount,
            "The transient failure wrote a log without a manual resubmission."
        )

        let submit = app.buttons[Identifier.submit]
        XCTAssertTrue(
            submit.waitForExistence(timeout: Timeout.normal),
            "The ordinary Log action disappeared after the transient failure."
        )
        if !submit.isHittable {
            _ = scrollToElement(
                Identifier.amountField,
                marker: Identifier.amountField,
                direction: .down
            )
        }
        XCTAssertTrue(
            submit.isHittable,
            "The ordinary Log action is not reachable for manual resubmission."
        )
        XCTAssertTrue(
            submit.isEnabled,
            "The ordinary Log action is disabled for manual resubmission."
        )
        submit.tap()

        // The pre-existing single-attempt journal may offer "Log as new…"
        // followed by a confirm dialog. That is ordinary explicit consent,
        // never an automatic replay.
        let logAsNew = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Log as new")
        ).firstMatch
        if logAsNew.waitForExistence(timeout: 2), logAsNew.isHittable {
            logAsNew.tap()
        }

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: Timeout.short) {
            let create = alert.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Create")
            ).firstMatch
            XCTAssertTrue(
                create.exists && create.isHittable,
                "The confirm-new-log alert has no reachable create action."
            )
            create.tap()
        }

        let success = app.descendants(matching: .any)[Identifier.submitSuccess]
            .waitForExistence(timeout: Timeout.long)
        let leftDetail = app.descendants(matching: .any)[Identifier.diarySummary].exists
        XCTAssertTrue(
            success || leftDetail,
            "The manual resubmission neither reported success nor returned to the diary."
        )

        let final = try mockState()
        XCTAssertEqual(
            final.logPostAttempts,
            baseline.logPostAttempts + 2,
            "Manual resubmission should make exactly one additional POST."
        )
        XCTAssertEqual(
            final.logCount,
            baseline.logCount + 1,
            "The manual resubmission did not persist exactly one log."
        )
        attachScreenshot(named: "iPhone-13-mini-manual-resubmission")
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
        // The compact summary renders the macro mode as a Menu, not a
        // SegmentedControl; query the stable identifier on any AX type.
        let macroMode = app.descendants(matching: .any)[Identifier.macros]
        XCTAssertTrue(
            macroMode.waitForExistence(timeout: Timeout.normal),
            "The macro mode picker is missing."
        )
        XCTAssertTrue(selectOption("Percent", from: macroMode), "Percent mode was not selectable.")
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

        // Barcode is a native Search scope segment, not a legacy lookup card.
        let barcodeScope = app.segmentedControls["search.scope"].firstMatch.buttons["Barcode"]
        XCTAssertTrue(
            barcodeScope.waitForExistence(timeout: Timeout.normal) && barcodeScope.isHittable,
            "The Barcode scope is missing."
        )
        barcodeScope.tap()
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
        // Leave no draft behind; scope Cancel to the presented sheet/alert.
        if let cancel = confirmationButton(label: "Cancel"), cancel.isHittable {
            cancel.tap()
            if let discard = confirmationButton("library.editor.discard.confirm"),
               discard.isHittable {
                discard.tap()
            }
        }
    }

    func testMiniAssistantGatePreventsDraftingWhenDisabled() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        // The native app exposes the custom-food Assistant through the
        // Library add menu, not a standalone Search AI entry.
        XCTAssertTrue(tapFirstReachable(["app.tab.library"], labels: ["Library"]))
        XCTAssertTrue(selectLibrarySection("Foods", identifier: "library.foods"))
        app.buttons["library.add"].tap()
        let createWithAI = app.buttons["library.createWithAI"]
        XCTAssertTrue(
            createWithAI.waitForExistence(timeout: Timeout.normal),
            "Create with AI is missing from the Library add menu."
        )
        createWithAI.tap()
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
    }

    /// Recents no longer expose batch selection. One quantity chip is a single
    /// individual log intent: one POST, one row, carrying the fixture's date
    /// and meal slot. (The shared submit transport is irrelevant here; this
    /// case asserts the removed UI entries are gone and one row was written.)
    func testMiniRecentQuickAddWritesExactlyOneLogIntent() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        let baseline = try mockState()
        openSearchFromDiary()

        // Removed recent-batch surface must not be rendered.
        XCTAssertFalse(
            app.descendants(matching: .any)["search.recent.select.product:qa-apple"].exists,
            "A removed recent-row select control was reintroduced."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["search.batch.reviewButton"].exists,
            "The removed batch review toolbar was reintroduced."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["search.batch.submit"].exists,
            "The removed batch submit sheet was reintroduced."
        )

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
        assertMockLogCount(baseline.logCount + 1)

        let final = try mockState()
        XCTAssertEqual(
            final.logPostAttempts,
            baseline.logPostAttempts + 1,
            "One quantity chip must be exactly one log POST, not a batch."
        )
        let created = final.logs.last
        XCTAssertNotNil(created, "The quick-add row was not written to the fixture.")
        XCTAssertEqual(created?.date, Self.isoDay(Date()),
                       "The quick-added log lost the fixture's today date.")
        XCTAssertNotNil(created?.mealSlot,
                        "The quick-added log lost its origin meal slot.")
    }

    func testMiniRepeatLatestRequiresReviewAndWritesOnce() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        // The approved Diary design keeps "Log latest" only for an empty,
        // enabled slot that has earlier history. The fixture's selected day is
        // empty while the previous day carries the seeded Breakfast rows.
        let baseline = try mockState()
        XCTAssertEqual(baseline.logCount, 8, "Unexpected fixture log baseline.")
        XCTAssertTrue(
            baseline.logs.allSatisfy { $0.date != Self.isoDay(Date()) },
            "The selected day was not empty at the start of the journey."
        )

        guard let latest = scrollToElement(
            "\(Identifier.latestPrefix)breakfast",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("Log latest is not reachable for an empty Breakfast with history.")
            return
        }
        XCTAssertTrue(
            latest.label.localizedCaseInsensitiveContains(Identifier.latestLabel),
            "The empty slot's repeat control is not labelled \(Identifier.latestLabel)."
        )
        guard let addFood = scrollToElement(
            "\(Identifier.addFoodPrefix)breakfast",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("The labelled Add food action is not reachable for Breakfast.")
            return
        }
        XCTAssertTrue(
            addFood.label.localizedCaseInsensitiveContains(Identifier.addFoodLabel),
            "The Add food control is not labelled with text \(Identifier.addFoodLabel)."
        )
        attachScreenshot(named: "iPhone-13-mini-diary-empty-slot-with-history")

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
        XCTAssertTrue(CalCoE2E.waitUntil(timeout: Timeout.long) {
            !self.app.descendants(matching: .any)["diary.latest.review"].exists
                && !self.app.descendants(matching: .any)["\(Identifier.latestPrefix)breakfast"].exists
        }, "Log latest did not return to the updated diary.")
        XCTAssertFalse(app.descendants(matching: .any)["diary.latestNotice"].exists)
        XCTAssertEqual(
            try mockState().logCount,
            10,
            "Log latest should copy exactly the two Breakfast rows."
        )

        // Once the slot is populated, its repeat control must disappear while
        // the still-empty Lunch slot keeps its own "Log latest" affordance.
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)["\(Identifier.latestPrefix)breakfast"].exists
            },
            "Log latest stayed visible after the slot was populated."
        )
        guard let lunchLatest = scrollToElement(
            "\(Identifier.latestPrefix)lunch",
            marker: Identifier.diarySummary,
            direction: .up
        ), lunchLatest.isHittable else {
            XCTFail("An untouched empty slot lost its visible Log latest affordance.")
            return
        }
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertTrue(
            lunchLatest.frame.width > 0 && lunchLatest.frame.height > 0
                && lunchLatest.frame.minY >= windowFrame.minY - 1
                && lunchLatest.frame.maxY <= windowFrame.maxY + 1,
            "The Lunch Log latest control is offscreen or has an empty frame."
        )
        attachScreenshot(named: "iPhone-13-mini-diary-latest-hidden-after-log")
    }

    func testMiniQuickAddCanLogAgainWithoutDismissingSuccess() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        let baseline = try mockState()
        openSearchFromDiary()

        let context = app.descendants(matching: .any)["search.loggingContext"]
        XCTAssertTrue(context.waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(context.label.contains("Logging to"))
        let chip = app.buttons["search.quickAdd.product:qa-apple.100.g"]
        XCTAssertTrue(chip.waitForExistence(timeout: Timeout.long))
        chip.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["search.quickAdd.added"]
                .waitForExistence(timeout: Timeout.long)
        )
        assertMockLogCount(baseline.logCount + 1)
        XCTAssertTrue(chip.isEnabled)
        chip.tap()
        assertMockLogCount(baseline.logCount + 2)
        XCTAssertEqual(try mockState().logPostAttempts, baseline.logPostAttempts + 2)
    }

    func testMiniLibraryUsesNativeBackFromBothDestinations() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        XCTAssertTrue(tapFirstReachable(["app.tab.library"], labels: ["Library"]))

        for (title, identifier, root) in [
            ("Foods", "library.foods", "library.add"),
            ("Meals", "library.meals", "meals.list.add"),
        ] {
            XCTAssertTrue(selectLibrarySection(title, identifier: identifier))
            let back = app.navigationBars.buttons["Library"]
            XCTAssertTrue(back.waitForExistence(timeout: Timeout.normal))
            XCTAssertEqual(app.buttons.matching(identifier: "library.back").count, 0,
                           "A custom Back must not duplicate the native Back.")
            XCTAssertTrue(app.buttons[root].waitForExistence(timeout: Timeout.normal))
            back.tap()
            XCTAssertTrue(app.buttons["library.foods"].waitForExistence(timeout: Timeout.normal))
            XCTAssertTrue(app.buttons["library.meals"].exists)
        }
    }

    func testMiniAccessibleNutritionUsesStackedFiguresAndMacros() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(dynamicType: QA.dynamicTypeAccessibility))
        try assertIPhone13Mini()
        let loggedCaption = app.staticTexts["kcal logged"]
        let remaining = app.descendants(matching: .any)["diary.summary.remaining"]
        XCTAssertTrue(loggedCaption.waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(remaining.exists)
        XCTAssertGreaterThanOrEqual(remaining.frame.minY, loggedCaption.frame.maxY,
                                    "Accessibility figures must stack instead of shrinking side by side.")

        openSearchFromDiary()
        let field = app.descendants(matching: .any)[Identifier.searchField]
        field.tap()
        field.typeText("apple")
        let result = app.buttons[Identifier.searchResult]
        XCTAssertTrue(result.waitForExistence(timeout: Timeout.long))
        result.tap()
        let energy = app.staticTexts["foodDetail.liveNutrition.energy"]
        XCTAssertNotNil(scrollToElement("foodDetail.liveNutrition.energy",
                                       marker: "foodDetail.foodName", direction: .up))
        XCTAssertGreaterThan(energy.frame.height, 40, "The energy font must scale with Dynamic Type.")
        let protein = app.staticTexts["Protein"]
        let carbs = app.staticTexts["Carbohydrates"]
        let fat = app.staticTexts["Fat"]
        XCTAssertTrue(protein.exists && carbs.exists && fat.exists)
        XCTAssertGreaterThan(carbs.frame.minY, protein.frame.minY)
        XCTAssertGreaterThan(fat.frame.minY, carbs.frame.minY)
    }

    func testMiniAssistantDraftReviewWorksFromNativeLibraryEntry() throws {
        try resetFixture(assistantEnabled: true)
        XCTAssertTrue(try launchSignedIn())
        try assertIPhone13Mini()
        let baseline = try mockState()
        XCTAssertTrue(tapFirstReachable(["app.tab.library"], labels: ["Library"]))
        XCTAssertTrue(selectLibrarySection("Foods", identifier: "library.foods"))
        app.buttons["library.add"].tap()
        let createWithAI = app.buttons["library.createWithAI"]
        XCTAssertTrue(createWithAI.waitForExistence(timeout: Timeout.normal))
        createWithAI.tap()
        sendAssistantPrompt("Draft plain oats", draftTimeout: Timeout.long)
        XCTAssertTrue(app.buttons["assistant.draft.accept"].exists)
        XCTAssertEqual(try mockState().customFoodCreateCount, baseline.customFoodCreateCount,
                       "Generating a draft must not save a food.")
        XCTAssertEqual(try mockState().logCount, baseline.logCount,
                       "Generating a draft must not log food.")
    }

    func testMiniDiarySummaryNutritionAndContextualSearchRetainTarget() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()

        // The summary is the entry point for the selected-day nutrition report.
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The Diary summary is missing."
        )
        guard let nutrition = scrollToElement(
            "diary.nutrition",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("The nutrition entry is not reachable from the Diary.")
            return
        }
        nutrition.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.nutritionDetails]
                .waitForExistence(timeout: Timeout.normal),
            "The selected-day nutrition report did not open."
        )
        attachScreenshot(named: "iPhone-13-mini-nutrition-details")
        XCTAssertFalse(app.buttons[Identifier.nutritionClose].exists, "The nutrition report still exposes a legacy Close action.")
        XCTAssertEqual(app.sheets.count, 0, "The nutrition report opened a legacy sheet.")
        let nutritionBack = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(
            nutritionBack.waitForExistence(timeout: Timeout.normal) && nutritionBack.isHittable,
            "The nutrition report has no reachable native back action."
        )
        nutritionBack.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary]
                .waitForExistence(timeout: Timeout.normal),
            "Closing nutrition did not return to the Diary."
        )

        // Starting from a historical slot must carry the date/slot target into
        // the contextual Search surface and then into Food Detail.
        navigateToHistoricalFixtureDay()
        guard let addFood = scrollToElement(
            "\(Identifier.addFoodPrefix)lunch",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("The historical Lunch Add food action is not reachable.")
            return
        }
        addFood.tap()
        let search = app.descendants(matching: .any)[Identifier.searchField]
        XCTAssertTrue(
            search.waitForExistence(timeout: Timeout.normal),
            "Search did not open for the selected slot."
        )

        // New native navigation exposes the origin date and slot as a labelled
        // context strip. Use the shipped identifier; never treat a missing strip
        // as a pass.
        let contextIdentifiers = ["search.loggingContext"]
        let context = contextIdentifiers.first {
            app.descendants(matching: .any)[$0].exists
        }.map { app.descendants(matching: .any)[$0] }
        XCTAssertNotNil(
            context,
            "No \(contextIdentifiers.joined(separator: " / ")) context was exposed; "
                + "the selected date/slot target is not observable."
        )
        XCTAssertTrue(
            (context?.label ?? "").localizedCaseInsensitiveContains("Lunch"),
            "The contextual Search strip did not retain the Lunch slot target."
        )
        attachScreenshot(named: "iPhone-13-mini-contextual-search")

        typeSearchQuery("Native QA", in: search)
        selectFixtureSearchResult()
        let slotPicker = app.descendants(matching: .any)["foodDetail.mealSlot.picker"]
        XCTAssertTrue(
            slotPicker.waitForExistence(timeout: Timeout.normal),
            "Food Detail did not open with a meal-slot picker."
        )
        let slotValue = (slotPicker.value as? String ?? "") + slotPicker.label
        XCTAssertTrue(
            slotValue.localizedCaseInsensitiveContains("Lunch"),
            "Food Detail did not retain the Lunch slot target."
        )
        attachScreenshot(named: "iPhone-13-mini-contextual-food-detail")

        dismissToDiary()
        XCTAssertTrue(isHistoricalDateVisible(), "The historical date was not retained.")
    }

    func testMiniMealCardHeaderTitleAndSubtotalStayVisible() throws {
        // Default text size, populated historical day: the card header title
        // and kcal subtotal must be visible and inside their card viewport.
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        assertVisibleMealHeadersInsideCards(variant: "default")
        attachScreenshot(named: "iPhone-13-mini-meal-card-header-visible")

        // Largest accessibility text size: a fixed-height header used to crop
        // the title/subtotal. Require the grown header to stay inside the card.
        XCTAssertTrue(
            try launchSignedIn(dynamicType: QA.dynamicTypeAccessibility),
            "The diary did not load at the accessibility content size."
        )
        assertVisibleMealHeadersInsideCards(variant: "AX5")
        attachScreenshot(named: "iPhone-13-mini-meal-card-header-accessibility")
    }

    func testMiniDirtyLogEditorNativeTabDiscardGuard() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        openHistoricalLogRow()

        let amount = app.descendants(matching: .any)[Identifier.editorAmount]
        XCTAssertTrue(amount.waitForExistence(timeout: Timeout.normal), "The log editor did not open.")
        replaceText(in: amount, with: "175")
        XCTAssertEqual(amount.value as? String, "175", "The editor was not made dirty.")

        // The pushed editor hides the native tab bar; its visible exit is the
        // back button. The shell guard must still require explicit discard.
        let editorBack = app.buttons["diary.editor.back"]
        XCTAssertTrue(
            editorBack.waitForExistence(timeout: Timeout.normal) && editorBack.isHittable,
            "The dirty editor has no reachable back action."
        )
        editorBack.tap()
        // SwiftUI exposes a nested duplicate of the destructive button; use
        // the single outer match for both existence and the tap.
        let discard = app.buttons.matching(identifier: Identifier.editorDiscardConfirm).firstMatch
        XCTAssertTrue(
            discard.waitForExistence(timeout: Timeout.normal),
            "The dirty editor was left without an explicit discard confirmation."
        )
        // Scope Cancel to the presented confirmation, not every button on
        // the screen (the editor and tab bar also expose Cancel-like labels).
        // The discard action sheet exposes only the destructive
        // "Discard changes" node in AX (verified via live hierarchy); its
        // cancel-role button has no AX node. The faithful cancel path for this
        // native confirmationDialog is a tap outside the sheet.
        XCTAssertTrue(
            app.sheets.firstMatch.waitForExistence(timeout: Timeout.short),
            "The discard confirmation sheet is not presented."
        )
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)
        ).tap()
        XCTAssertTrue(amount.waitForExistence(timeout: Timeout.normal), "Cancel left the dirty editor.")
        XCTAssertEqual(amount.value as? String, "175", "Cancel discarded the edited value.")

        editorBack.tap()
        XCTAssertTrue(discard.waitForExistence(timeout: Timeout.normal), "The discard dialog did not reappear.")
        discard.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary]
                .waitForExistence(timeout: Timeout.normal),
            "Confirming discard did not return to the diary."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.editorAmount].exists,
            "The discarded editor remained open."
        )
    }

    func testMiniSettingsDirtyCancelGuard() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        openSettings()
        guard let calories = scrollToElement(
            Identifier.goalCalories,
            marker: Identifier.settingsSheet,
            direction: .up
        ) else {
            XCTFail("The calorie goal field is not reachable.")
            return
        }
        replaceText(in: calories, with: "2230")
        XCTAssertEqual(calories.value as? String, "2230", "The Settings draft was not made dirty.")

        app.buttons[Identifier.settingsCancel].tap()
        guard let confirm = confirmationButton(Identifier.settingsDiscardConfirm) else {
            XCTFail("Dirty Settings closed without an explicit discard confirmation.")
            return
        }
        guard let cancel = confirmationButton(Identifier.settingsDiscardCancel) else {
            XCTFail("The Settings discard dialog has no scoped Cancel.")
            return
        }
        XCTAssertTrue(cancel.isHittable, "The Settings discard Cancel is not hittable.")
        cancel.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSheet]
                .waitForExistence(timeout: Timeout.normal),
            "Cancel closed dirty Settings."
        )
        XCTAssertEqual(calories.value as? String, "2230", "Cancel lost the dirty Settings value.")

        app.buttons[Identifier.settingsCancel].tap()
        guard let confirmAgain = confirmationButton(Identifier.settingsDiscardConfirm) else {
            XCTFail("The discard dialog did not reappear.")
            return
        }
        confirmAgain.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "Confirming discard did not close Settings."
        )
    }

    func testMiniLibraryDraftSurvivesTabAndDateChange() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.library", "library.tab", "tab.library", "diary.library"],
                labels: ["Library"]
            ),
            "The native Library tab is not reachable."
        )
        XCTAssertTrue(selectLibrarySection("Foods", identifier: "library.foods"), "Foods did not open.")
        // `library.add` is the Menu label button; selecting the custom-food
        // editor requires tapping the `library.add.custom` menu item it opens.
        let addButton = app.buttons["library.add"]
        XCTAssertTrue(
            addButton.waitForExistence(timeout: Timeout.normal) && addButton.isHittable,
            "The Library Add menu is not reachable."
        )
        addButton.tap()
        let customItem = app.buttons["library.add.custom"]
        XCTAssertTrue(
            customItem.waitForExistence(timeout: Timeout.normal) && customItem.isHittable,
            "The custom-food Add menu item is not reachable."
        )
        customItem.tap()
        let name = app.descendants(matching: .any)["library.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.normal), "The custom-food editor did not open.")
        replaceText(in: name, with: "QA Draft Food")
        XCTAssertEqual(name.value as? String, "QA Draft Food", "The draft name was not entered.")

        XCTAssertTrue(tapFirstReachable(["app.tab.diary", "diary.tab", "tab.diary"], labels: ["Diary"]), "Could not return to Diary.")
        XCTAssertTrue(tapToolbarAction(Identifier.previousDay), "Could not change the selected date.")
        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.library", "library.tab", "tab.library", "diary.library"],
                labels: ["Library"]
            ),
            "Could not return to Library."
        )
        let retained = app.descendants(matching: .any)["library.editor.name"]
        XCTAssertTrue(retained.waitForExistence(timeout: Timeout.normal), "The Library draft was recreated after the tab/date change.")
        XCTAssertEqual(
            (retained.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            "QA Draft Food",
            "The Library draft value was lost."
        )

        let libraryCancel = app.buttons["diary.common.cancel"]
        if libraryCancel.exists, libraryCancel.isHittable { libraryCancel.tap() }
        let discard = app.buttons["library.editor.discard.confirm"]
        if discard.waitForExistence(timeout: 2), discard.isHittable { discard.tap() }
    }

    func testMiniLibraryLogDraftKeepsCapturedDateAfterDiaryDateChange() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()

        // The log flow captures the date/slot when it is opened. Changing the
        // Diary date afterwards must not retarget an already-open draft.
        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.library", "library.tab", "tab.library", "diary.library"],
                labels: ["Library"]
            ),
            "The native Library tab is not reachable."
        )
        XCTAssertTrue(selectLibrarySection("Foods", identifier: "library.foods"), "Foods did not open.")
        app.buttons["library.add"].tap()
        app.buttons["library.add.adhoc"].tap()
        let dateField = app.descendants(matching: .any)["library.adHoc.date"]
        XCTAssertTrue(dateField.waitForExistence(timeout: Timeout.normal), "The ad-hoc date control is missing.")
        let originalDate = (dateField.value as? String ?? dateField.label)
        XCTAssertFalse(originalDate.isEmpty, "The ad-hoc date control has no value.")

        let name = app.textFields["library.adHoc.name"]
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.normal), "The ad-hoc form did not open.")
        name.tap()
        name.typeText("QA Ad hoc Draft")
        dismissLibraryKeyboard("library.adHoc.keyboard.done")

        XCTAssertTrue(tapFirstReachable(["app.tab.diary", "diary.tab", "tab.diary"], labels: ["Diary"]), "Could not return to Diary.")
        XCTAssertTrue(tapToolbarAction(Identifier.nextDay), "Could not change the Diary date.")
        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.library", "library.tab", "tab.library", "diary.library"],
                labels: ["Library"]
            ),
            "Could not return to Library."
        )
        let retained = app.descendants(matching: .any)["library.adHoc.date"]
        XCTAssertTrue(retained.waitForExistence(timeout: Timeout.normal), "The open ad-hoc draft was recreated.")
        let retainedDate = (retained.value as? String ?? retained.label)
        XCTAssertEqual(retainedDate, originalDate, "An open log draft was retargeted by a Diary date change.")
        XCTAssertEqual(
            (app.textFields["library.adHoc.name"].value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "QA Ad hoc Draft",
            "The open log draft lost its name."
        )

        app.buttons["library.adHoc.cancel"].tap()
        let discard = app.buttons["library.editor.discard.confirm"]
        if discard.waitForExistence(timeout: 2), discard.isHittable { discard.tap() }
    }

    func testMiniSignOutReloginLandsFreshDiary() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        XCTAssertTrue(isHistoricalDateVisible(), "Prerequisite historical selection was not active.")
        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.settings", "settings.tab", "tab.settings", Identifier.settings],
                labels: ["Settings"]
            ),
            "The native Settings tab is not reachable on the mini."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSheet]
                .waitForExistence(timeout: Timeout.normal),
            "The Settings surface did not open."
        )
        let signOut = scrollToElement("auth.signOut", marker: Identifier.settingsSheet, direction: .down)
            ?? app.buttons["auth.signOut"]
        XCTAssertTrue(signOut.exists && signOut.isHittable, "Sign Out is not reachable.")
        signOut.tap()
        XCTAssertTrue(
            CalCoE2E.waitForLogin(in: app, timeout: Timeout.normal),
            "Sign Out did not return to the login form."
        )
        // The login form must be the live surface, and no session-sensitive
        // diary rows may survive Sign Out. The username may legitimately be
        // remembered, so it is deliberately not asserted as empty.
        XCTAssertTrue(
            app.textFields["auth.login.username"].waitForExistence(timeout: Timeout.short),
            "The login form is not actually visible after Sign Out."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "A diary summary survived Sign Out."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.historicalLog].exists,
            "Session-sensitive historical rows survived Sign Out."
        )

        try signInFixture()
        XCTAssertTrue(
            CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long),
            "Re-login did not reach the diary."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The diary summary is missing after re-login."
        )
        XCTAssertTrue(waitForFetchCount(atLeast: 1), "Re-login did not fetch a fresh diary.")
        XCTAssertFalse(isHistoricalDateVisible(), "Re-login restored the previous historical selection.")
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.historicalLog].exists,
            "The prior session's historical rows reappeared after re-login."
        )
    }

    func testMiniInvalidLoginPreservesFormAndCanRetry() throws {
        try resetFixture()
        app = makeApp(dynamicType: nil)
        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)

        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        guard username.waitForExistence(timeout: Timeout.normal),
              password.waitForExistence(timeout: Timeout.normal),
              app.buttons["auth.login.submit"].exists else {
            XCTFail("The fixture login form did not appear.")
            return
        }

        username.tap()
        username.typeText(QA.username)
        let wrongPassword = "wrong-password"
        password.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The login keyboard did not appear."
        )
        password.typeText(wrongPassword)
        tapSignInAboveKeyboard()

        let loginError = app.descendants(matching: .any)["auth.login.error"]
        XCTAssertTrue(
            loginError.waitForExistence(timeout: Timeout.normal),
            "Wrong fixture credentials did not show auth.login.error."
        )
        XCTAssertTrue(username.exists, "The username field disappeared after a failed sign-in.")
        XCTAssertTrue(username.isEnabled, "The username field is not usable after a failed sign-in.")
        XCTAssertEqual(username.value as? String, QA.username, "The username was not retained.")
        XCTAssertTrue(password.exists, "The password field disappeared after a failed sign-in.")
        XCTAssertTrue(password.isEnabled, "The password field is not usable after a failed sign-in.")
        XCTAssertFalse(
            (password.value as? String ?? "").isEmpty,
            "The intended password retention after a failed sign-in did not occur."
        )

        // Use the existing placeholder-aware replacement helper: its Select All
        // edit-menu path (or typeText fallback) replaces a retained SecureField
        // value without Cmd+A or absolute coordinates. The server-backed sign-in
        // below is the real proof that the correct password was submitted.
        replaceText(in: password, with: QA.password)
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.short) { !loginError.exists },
            "Editing the password did not clear the authentication error."
        )
        tapSignInAboveKeyboard()

        let reached = CalCoE2E.waitUntil(timeout: Timeout.long) {
            CalCoE2E.isLoadedDiary(in: self.app) || loginError.exists
        }
        XCTAssertFalse(loginError.exists, "The retry produced a second login error.")
        XCTAssertTrue(
            reached && CalCoE2E.isLoadedDiary(in: app),
            "Correcting the password did not reach the diary."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.diarySummary].exists,
            "The diary summary is missing after the successful retry."
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
    }

    func testMiniHistoricalDateSurvivesMealsDestination() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()

        guard let addFood = scrollToElement(
            "\(Identifier.addFoodPrefix)breakfast",
            marker: Identifier.diarySummary,
            direction: .up
        ) else {
            XCTFail("The historical Breakfast Add food control is not reachable.")
            return
        }
        addFood.tap()
        let searchField = app.descendants(matching: .any)[Identifier.searchField]
        XCTAssertTrue(
            searchField.waitForExistence(timeout: Timeout.normal),
            "Search did not open from the historical Breakfast Add food control."
        )

        let openMeals = app.buttons["search.openMeals"]
        XCTAssertTrue(
            openMeals.waitForExistence(timeout: Timeout.normal),
            "The search Meals toolbar action is missing."
        )
        openMeals.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["meals.list"]
                .waitForExistence(timeout: Timeout.long),
            "The logging-capable Meals flow did not open from Search."
        )
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
        let baseline = try mockState()
        let openLog = app.buttons["meals.detail.openLog"]
        XCTAssertTrue(
            openLog.waitForExistence(timeout: Timeout.normal) && openLog.isHittable,
            "Log meal is not reachable."
        )
        openLog.tap()

        let logSheet = app.descendants(matching: .any)["meals.log.sheet"]
        XCTAssertTrue(
            logSheet.waitForExistence(timeout: Timeout.long),
            "The meal log sheet did not open."
        )

        // Fixture: NativeCompletionQAMockServer.py qa-meal-1 nutrition_summary
        // (route /api/meals/{id}/nutrients, default 100 g) returns ENERGY_KCAL 200 kcal,
        // PROTEIN_G 2 g, CARBS_G 40 g, FAT_G 1 g. MealLogView renders these via
        // NutritionTable (GridRow, .accessibilityElement(children: .combine)) with
        // MealNutrientDisplay.label(for:) and DisplayNumberFormat.decimal(..., fixed: true).
        let expectedNutrients: [(name: String, value: String, unit: String)] = [
            ("Calories", "200.00", "kcal"),
            ("Protein", "2.00", "g"),
            ("Carbohydrates", "40.00", "g"),
            ("Fat", "1.00", "g"),
        ]
        func visibleNutrientRow(_ nutrient: (name: String, value: String, unit: String)) -> Bool {
            func hasExactVisible(_ label: String) -> Bool {
                logSheet.descendants(matching: .staticText)
                    .matching(NSPredicate(format: "label == %@", label))
                    .allElementsBoundByIndex
                    .contains { $0.exists && $0.isHittable }
            }
            return hasExactVisible(nutrient.name)
                && hasExactVisible(nutrient.value)
                && hasExactVisible(nutrient.unit)
        }
        let sheetScroll = scrollContainer(marker: "foodDetail.amount.field")
        for _ in 0..<6 where !expectedNutrients.allSatisfy(visibleNutrientRow) {
            if let sheetScroll, sheetScroll.exists {
                sheetScroll.swipeUp()
            } else {
                logSheet.swipeUp()
            }
        }
        for nutrient in expectedNutrients {
            let found = visibleNutrientRow(nutrient)
            if !found {
                let keywords = [
                    "Calories", "Protein", "Carbohydrates", "Fat", "kcal", "200",
                    "No nutrition", "Retry", "Loading", "nutrition",
                ]
                var lines: [String] = ["NATIVE_QA_MEAL_PREVIEW_DIAGNOSTIC"]
                lines.append("missing=\(nutrient.name) \(nutrient.value) \(nutrient.unit)")
                lines.append("sheet.exists=\(logSheet.exists) isHittable=\(logSheet.isHittable) frame=\(logSheet.frame)")
                let amountField = logSheet.descendants(matching: .any)["foodDetail.amount.field"]
                if amountField.exists {
                    lines.append(
                        "amountField.value=\(String(describing: amountField.value)) label=\(amountField.label) enabled=\(amountField.isEnabled)"
                    )
                }
                let unitPicker = logSheet.descendants(matching: .any)["foodDetail.unit.picker"]
                if unitPicker.exists {
                    lines.append(
                        "unitPicker.value=\(String(describing: unitPicker.value)) label=\(unitPicker.label) enabled=\(unitPicker.isEnabled)"
                    )
                }
                let candidates = logSheet.descendants(matching: .any).allElementsBoundByIndex
                var dumped = 0
                for element in candidates where dumped < 120 {
                    let label = element.label
                    let value = String(describing: element.value ?? "")
                    let identifier = element.identifier
                    let shouldDump = !label.isEmpty
                        || !identifier.isEmpty
                        || keywords.contains(where: { label.contains($0) || value.contains($0) || identifier.contains($0) })
                    guard shouldDump else { continue }
                    lines.append(
                        "element type=\(element.elementType.rawValue) id=\(identifier) label=\(label) value=\(value) exists=\(element.exists) hittable=\(element.isHittable) frame=\(element.frame)"
                    )
                    dumped += 1
                }
                let diagnostic = XCTAttachment(string: lines.joined(separator: "\n"))
                diagnostic.name = "NATIVE_QA_MEAL_PREVIEW_DIAGNOSTIC"
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
                let screenshot = XCUIScreen.main.screenshot()
                let screenshotAttachment = XCTAttachment(screenshot: screenshot)
                screenshotAttachment.name = "NATIVE_QA_MEAL_PREVIEW_DIAGNOSTIC"
                screenshotAttachment.lifetime = .keepAlways
                add(screenshotAttachment)
                XCTAssertTrue(
                    found,
                    "Loaded meal log preview is missing \(nutrient.name) \(nutrient.value) \(nutrient.unit)."
                )
                guard found else { return }
            }
        }

        let beforeSubmit = try mockState()
        XCTAssertEqual(
            beforeSubmit.logCount,
            baseline.logCount,
            "Opening the meal log preview must not create a log."
        )
        XCTAssertEqual(
            beforeSubmit.logPostAttempts,
            baseline.logPostAttempts,
            "Opening the meal log preview must not issue a log POST."
        )

        let logMeal = app.buttons["meals.detail.log"]
        XCTAssertTrue(
            logMeal.waitForExistence(timeout: Timeout.normal) && logMeal.isHittable,
            "The meal log submit action is not reachable."
        )
        logMeal.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                (try? self.mockState().logCount) == baseline.logCount + 1
            },
            "Meal logging did not create exactly one fixture log."
        )
        let afterLog = try mockState()
        XCTAssertEqual(
            afterLog.logPostAttempts,
            baseline.logPostAttempts + 1,
            "Meal logging did not issue exactly one log POST."
        )

        dismissToDiary()
        scrollDiaryToTop()
        XCTAssertTrue(
            isHistoricalDateVisible(),
            "The historical fixture log is no longer rendered after the round trip."
        )
        guard let finalSummary = summaryLabel(), !finalSummary.isEmpty else {
            XCTFail("The post-return historical summary is missing or empty.")
            return
        }
        let requiredPhrases = ["900 kcal logged", "1100 remaining", "of 2000 kcal"]
        for phrase in requiredPhrases {
            let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: phrase) + "(?:\\s|$)"
            let range = finalSummary.range(of: pattern, options: .regularExpression)
            XCTAssertNotNil(
                range,
                "Post-return historical summary missing exact phrase '\(phrase)': \(finalSummary)"
            )
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.numberOfMatches(
                    in: finalSummary,
                    range: NSRange(finalSummary.startIndex..., in: finalSummary)
                )
                XCTAssertEqual(
                    matches,
                    1,
                    "Post-return historical summary should contain '\(phrase)' exactly once: \(finalSummary)"
                )
            }
        }
        XCTAssertEqual(
            displayedCalories(),
            900,
            "The historical logged calories changed after returning from Meals."
        )
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
        // Reach the custom-food Assistant through the real Library entry;
        // the Search tab no longer hosts a standalone AI entry.
        XCTAssertTrue(tapFirstReachable(["app.tab.library"], labels: ["Library"]))
        XCTAssertTrue(selectLibrarySection("Foods", identifier: "library.foods"))
        app.buttons["library.add"].tap()
        let createWithAI = app.buttons["library.createWithAI"]
        XCTAssertTrue(
            createWithAI.waitForExistence(timeout: Timeout.normal),
            "Create with AI is missing from the Library add menu."
        )
        createWithAI.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["assistant.composer"]
                .waitForExistence(timeout: Timeout.normal),
            "Assistant did not become enabled from the Library entry."
        )
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
    }

    func testMiniMealsCreateEditDeleteAndLog() throws {
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

        app.buttons["meals.detail.edit"].tap()
        XCTAssertTrue(
            app.textFields["meals.editor.name"].waitForExistence(timeout: Timeout.long),
            "The meal edit form did not open."
        )
        let notes = app.textFields["meals.editor.notes"]
        let currentNotes = notes.value as? String ?? ""
        // Tap at the trailing edge so backspaces delete the existing notes;
        // a centre tap can put the cursor before the text and prepend instead.
        notes.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        notes.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentNotes.count)
        )
        notes.typeText("Native QA edited meal notes")
        if app.keyboards.firstMatch.exists {
            app.swipeUp()
        }
        let editSave = app.buttons["meals.editor.save"]
        XCTAssertTrue(
            editSave.waitForExistence(timeout: Timeout.normal) && editSave.isHittable,
            "Meal edit Save is not reachable."
        )
        editSave.tap()
        XCTAssertTrue(
            app.staticTexts["Native QA edited meal notes"]
                .waitForExistence(timeout: Timeout.long),
            "The edited meal notes are missing."
        )
        XCTAssertEqual(
            try mockState().mealUpdateCount,
            baseline.mealUpdateCount + 1
        )

        let beforeLog = try mockState()
        app.buttons["meals.detail.log"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.log.success"]
                .waitForExistence(timeout: Timeout.long),
            "The meal did not log."
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
    }

    func testMiniNativeLibraryMealsAndSettingsAccess() throws {
        try resetFixture()
        XCTAssertTrue(try launchSignedIn(), "The diary did not load after fixture sign-in.")
        try assertIPhone13Mini()
        navigateToHistoricalFixtureDay()
        attachScreenshot(named: "iPhone-13-mini-diary-populated-meal-cards")

        // Three native tabs replace the old in-diary feature bar. Library owns
        // Foods and Meals as two sections of a single root.
        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.library", "library.tab", "tab.library", "diary.library"],
                labels: ["Library"]
            ),
            "The native Library tab is not reachable on the mini."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["library.section"]
                .waitForExistence(timeout: Timeout.normal),
            "The Library Foods/Meals segmented control is missing."
        )
        XCTAssertTrue(
            selectLibrarySection("Foods", identifier: "library.foods"),
            "The Library Foods section did not open."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["library.foods"].exists,
            "The Foods surface is not present."
        )
        attachScreenshot(named: "iPhone-13-mini-library-foods")

        XCTAssertTrue(
            selectLibrarySection("Meals", identifier: "library.meals"),
            "The Library Meals section did not open."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.list"]
                .waitForExistence(timeout: Timeout.normal),
            "The Meals list did not open inside Library."
        )
        attachScreenshot(named: "iPhone-13-mini-library-meals")

        XCTAssertTrue(
            tapFirstReachable(
                ["app.tab.settings", "settings.tab", "tab.settings", Identifier.settings],
                labels: ["Settings"]
            ),
            "The native Settings tab is not reachable on the mini."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[Identifier.settingsSheet]
                .waitForExistence(timeout: Timeout.normal),
            "The Settings surface did not open."
        )
        attachScreenshot(named: "iPhone-13-mini-settings")
        app.buttons[Identifier.settingsCancel].tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                !self.app.descendants(matching: .any)[Identifier.settingsSheet].exists
            },
            "Settings did not close."
        )
        XCTAssertTrue(
            tapFirstReachable(["app.tab.diary", "diary.tab", "tab.diary"], labels: ["Diary"]),
            "Could not return to the Diary tab."
        )
        XCTAssertTrue(isHistoricalDateVisible(), "The selected date was lost across native tabs.")
    }

    /// Tap the first reachable entry from a list of current/legacy identifiers.
    /// The bounded second pass covers in-list entries without an unbounded swipe.
    private func tapFirstReachable(
        _ identifiers: [String],
        labels: [String] = []
    ) -> Bool {
        for identifier in identifiers {
            let element = app.descendants(matching: .any)[identifier]
            if element.exists, element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
        }
        for identifier in identifiers {
            guard let element = scrollToElement(
                identifier,
                marker: Identifier.diarySummary,
                direction: .up,
                maxSwipes: 6
            ), element.isHittable else { continue }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        for label in labels {
            let candidate = app.buttons.matching(
                NSPredicate(format: "label ==[c] %@", label)
            ).firstMatch
            if candidate.waitForExistence(timeout: 3), candidate.isHittable {
                candidate.tap()
                return true
            }
        }
        print("NATIVE_QA_NAV_MISS \(identifiers.joined(separator: ","))\n\(app.debugDescription)")
        return false
    }

    // MARK: - Feature destination discovery

    private enum FeatureDestination {
        case library
        case meals
        case nutrition
        case apiKeys

        /// Native tab-bar spellings are tried first; the old in-diary feature
        /// bar identifiers are kept only as a fallback for older builds.
        var identifiers: [String] {
            switch self {
            case .library:
                return ["app.tab.library", "library.tab", "tab.library", "diary.library"]
            case .meals:
                return ["app.tab.library", "meals.tab", "tab.meals", "diary.meals"]
            case .nutrition:
                return ["diary.nutrition"]
            case .apiKeys:
                return ["settings.apiKeys.entry"]
            }
        }
    }

    /// The native tab bar (or the Diary summary for Nutrition) exposes these
    /// destinations directly. Library owns Foods and Meals, so Meals journeys
    /// switch that segmented control after entering the Library tab.
    private func openDirectFeatureDestination(_ destination: FeatureDestination) -> Bool {
        guard tapFirstReachable(
            destination.identifiers,
            labels: destination == .library || destination == .meals ? ["Library"] : []
        ) else {
            return false
        }
        if app.descendants(matching: .any)["library.section"].exists {
            switch destination {
            case .library:
                guard selectLibrarySection("Foods", identifier: "library.foods") else {
                    return false
                }
            case .meals:
                guard selectLibrarySection("Meals", identifier: "library.meals") else {
                    return false
                }
            case .nutrition, .apiKeys:
                break
            }
        }
        return waitForFeatureSurface()
    }

    /// Select a Library section via the native segmented control. Its AX
    /// type is a SegmentedControl whose options are buttons, so query that
    /// type before falling back to a generic labelled button.
    private func selectLibrarySection(_ label: String, identifier: String) -> Bool {
        // The native hub link and its destination share a feature identifier.
        // Existence at the hub is not evidence that the destination is open.
        if app.navigationBars["Library"].exists {
            let link = app.buttons[identifier]
            guard link.waitForExistence(timeout: Timeout.normal), link.isHittable else {
                return false
            }
            link.tap()
            return CalCoE2E.waitUntil(timeout: Timeout.normal) {
                self.app.buttons["library.add"].exists
                    || self.app.buttons["meals.list.add"].exists
            }
        }
        if app.descendants(matching: .any)[identifier].exists { return true }
        let optionPredicate = NSPredicate(format: "label ==[c] %@", label)
        let segmented = app.segmentedControls["library.section"]
        var option: XCUIElement?
        if segmented.exists {
            option = segmented.buttons.matching(optionPredicate)
                .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
        }
        if option == nil {
            guard let section = hittableElement(identifier: "library.section") else { return false }
            option = app.buttons.matching(optionPredicate)
                .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
            if option == nil {
                section.tap()
                option = app.buttons.matching(optionPredicate)
                    .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
            }
        }
        guard let choice = option, choice.isHittable else { return false }
        choice.tap()
        return CalCoE2E.waitUntil(timeout: Timeout.short) {
            self.app.descendants(matching: .any)[identifier].exists
        }
    }

    private func openFeatureDestination(_ destination: FeatureDestination) -> Bool {
        if destination == .apiKeys {
            return openAPIKeysFromSettings()
        }
        guard openDirectFeatureDestination(destination) else {
            print(
                "NATIVE_QA_FEATURE_MISS \(destination.identifiers.joined(separator: ","))"
                    + "\n\(app.debugDescription)"
            )
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
        let dateNav = app.descendants(matching: .any)["diary.dateNavigation"]
        func currentDateText() -> String? {
            guard dateNav.exists else { return nil }
            let label = dateNav.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { return label }
            let value = (dateNav.value as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let startingDateText = currentDateText()
        // A compact NavigationStack with an empty title exposes no NavigationBar
        // element, so treat any title comparison as optional evidence only.
        let navBar = app.navigationBars.firstMatch
        let startingNavTitle: String? = navBar.exists ? navBar.identifier : nil

        for _ in 0..<3 {
            let before = fetchCount() ?? 0
            guard tapToolbarAction(Identifier.previousDay) else {
                XCTFail("Previous Day is not reachable on the mini.")
                return
            }
            XCTAssertTrue(
                waitForFetchCount(greaterThan: before),
                "Previous Day did not complete a diary fetch."
            )
            let dateChanged = CalCoE2E.waitUntil(timeout: Timeout.short) {
                guard let current = currentDateText() else { return false }
                return current != startingDateText
            }
            let navChanged = CalCoE2E.waitUntil(timeout: Timeout.short) {
                guard navBar.exists else { return false }
                return navBar.identifier != startingNavTitle
            }
            if scrollToElement(
                Identifier.historicalLog,
                marker: Identifier.diarySummary,
                direction: .up
            ) != nil {
                if let starting = startingDateText, let current = currentDateText() {
                    XCTAssertNotEqual(
                        current, starting,
                        "Previous Day did not change the accessible diary date."
                    )
                }
                scrollDiaryToTop()
                return
            }
            // A transition tap can be swallowed once; stop if the accessible
            // date/title already changed so we never navigate two days back.
            if dateChanged || navChanged { break }
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
        let currentSummary = summaryLabel()
        guard let retainedSummary, !retainedSummary.isEmpty else {
            XCTFail("The retained historical summary is missing or empty.")
            return
        }
        guard let currentSummary, !currentSummary.isEmpty else {
            XCTFail("The current historical summary is missing or empty.")
            return
        }
        XCTAssertEqual(
            currentSummary,
            retainedSummary,
            "The historical summary changed after returning from the destination."
        )
    }

    private func leafStaticTexts(in elements: [XCUIElement]) -> [XCUIElement] {
        elements.filter { element in
            if element.identifier == "diary.summary.remaining" {
                return false
            }
            let frame = element.frame
            guard frame.width > 0, frame.height > 0, frame.width.isFinite, frame.height.isFinite else {
                return true
            }
            return !elements.contains { other in
                guard other !== element else { return false }
                if other.identifier == "diary.summary.remaining" {
                    return false
                }
                let otherFrame = other.frame
                guard otherFrame.width > 0, otherFrame.height > 0,
                      otherFrame.width.isFinite, otherFrame.height.isFinite else {
                    return false
                }
                return element.frame.contains(otherFrame)
                    && !element.frame.equalTo(otherFrame)
            }
        }
    }

    private func summaryLabel() -> String? {
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.diarySummary)
            .allElementsBoundByIndex
        // Backwards-compatible combined container label.
        let containerLabels = summaries.map(\.label).filter { !$0.isEmpty }
        if !containerLabels.isEmpty {
            return containerLabels.joined(separator: " ")
        }
        // Native SwiftUI exposes the calorie brief as contained leaf children.
        guard let summary = summaries.first else { return nil }
        let leaves = leafStaticTexts(
            in: summary.descendants(matching: .staticText).allElementsBoundByIndex
        )
        let labels = leaves.map { leaf in
            let label = leaf.label
            if Self.isValidFormattedInteger(label),
               let value = Self.parseFormattedInteger(label) {
                return String(value)
            }
            return label
        }.filter { !$0.isEmpty }
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }

    private func loggedCalorieText() -> String? {
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.diarySummary)
            .allElementsBoundByIndex
        guard let summary = summaries.first else { return nil }
        let leaves = leafStaticTexts(
            in: summary.descendants(matching: .staticText).allElementsBoundByIndex
        )
        let remainingContainer = app.descendants(matching: .any)
            .matching(identifier: "diary.summary.remaining")
            .allElementsBoundByIndex
            .first
        let remainingFrame = remainingContainer?.frame
        let hasRemainingFrame = remainingFrame.map {
            $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite
        } ?? false

        let candidates = leaves.compactMap { leaf -> String? in
            let label = leaf.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }

            // Prefer structural exclusion of the remaining subtree. When no
            // reliable frame is available, fall back to label exclusion and let
            // ambiguity fail closed below.
            if hasRemainingFrame, let frame = remainingFrame,
               frame.insetBy(dx: -0.5, dy: -0.5).contains(leaf.frame) {
                return nil
            }
            if !hasRemainingFrame {
                let lower = label.lowercased()
                if lower.contains("remaining") { return nil }
            }

            guard Self.isValidFormattedInteger(label),
                  let value = Self.parseFormattedInteger(label) else {
                return nil
            }
            return String(value)
        }

        // A unique logged value is required; equal or ambiguous values fail closed.
        return candidates.count == 1 ? candidates.first : nil
    }

    private func displayedCalories() -> Int? {
        let result: Int?
        if let logged = loggedCalorieText(), let value = Int(logged) {
            result = value
        } else if let label = summaryLabel(), label.contains("/") {
            let firstOperand = label.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let numericTokens = firstOperand
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { Self.isValidFormattedInteger($0) }
            if numericTokens.count == 1,
               let value = Self.parseFormattedInteger(numericTokens[0]) {
                result = value
            } else {
                result = nil
            }
        } else {
            result = nil
        }

        if result == nil {
            diagnoseHistoricalCalorieSummary()
        }
        return result
    }

    private func diagnoseHistoricalCalorieSummary() {
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.diarySummary)
            .allElementsBoundByIndex
        let remainingMatches = app.descendants(matching: .any)
            .matching(identifier: "diary.summary.remaining")
            .allElementsBoundByIndex
        let remainingFrame = remainingMatches.first?.frame
        let hasRemainingFrame = remainingFrame.map {
            $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite
        } ?? false

        var lines: [String] = []
        lines.append("NATIVE_QA_SUMMARY_DIAGNOSTIC")
        lines.append("capturedAt=\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("summaryMatchCount=\(summaries.count)")
        for (index, summary) in summaries.enumerated() {
            lines.append("summary[\(index)] identifier=\(summary.identifier) label=\(summary.label) value=\(summary.value ?? "") frame=\(summary.frame) exists=\(summary.exists) hittable=\(summary.isHittable)")
            let staticTexts = summary.descendants(matching: .staticText).allElementsBoundByIndex
            for (textIndex, text) in staticTexts.enumerated() {
                lines.append("  staticText[\(textIndex)] identifier=\(text.identifier) label=\(text.label) value=\(text.value ?? "") frame=\(text.frame) exists=\(text.exists) hittable=\(text.isHittable)")
            }
        }

        lines.append("remainingMatchCount=\(remainingMatches.count)")
        for (index, remaining) in remainingMatches.enumerated() {
            lines.append("remaining[\(index)] identifier=\(remaining.identifier) label=\(remaining.label) value=\(remaining.value ?? "") frame=\(remaining.frame) exists=\(remaining.exists) hittable=\(remaining.isHittable)")
            let remainingTexts = remaining.descendants(matching: .staticText).allElementsBoundByIndex
            for (textIndex, text) in remainingTexts.enumerated() {
                lines.append("  remainingStaticText[\(textIndex)] identifier=\(text.identifier) label=\(text.label) value=\(text.value ?? "") frame=\(text.frame) exists=\(text.exists) hittable=\(text.isHittable)")
            }
        }

        if let summary = summaries.first {
            let allStaticTexts = summary.descendants(matching: .staticText).allElementsBoundByIndex
            lines.append("candidateCount=\(allStaticTexts.count)")
            for (index, text) in allStaticTexts.enumerated() {
                let label = text.label.trimmingCharacters(in: .whitespacesAndNewlines)
                var reasons: [String] = []
                if text.identifier == "diary.summary.remaining" {
                    reasons.append("leafRemoved(identifier=diary.summary.remaining)")
                }
                if hasRemainingFrame, let frame = remainingFrame,
                   frame.insetBy(dx: -0.5, dy: -0.5).contains(text.frame) {
                    reasons.append("remainingFrameContains")
                }
                let isContainer = allStaticTexts.indices.contains { otherIndex in
                    guard otherIndex != index else { return false }
                    let other = allStaticTexts[otherIndex]
                    if other.identifier == "diary.summary.remaining" { return false }
                    let otherFrame = other.frame
                    guard otherFrame.width > 0, otherFrame.height > 0,
                          otherFrame.width.isFinite, otherFrame.height.isFinite else {
                        return false
                    }
                    return text.frame.contains(otherFrame) && !text.frame.equalTo(otherFrame)
                }
                if isContainer {
                    reasons.append("leafRemoved(container)")
                }
                if !Self.isValidFormattedInteger(label) {
                    reasons.append("numericParserRejected")
                } else if Self.parseFormattedInteger(label) == nil {
                    reasons.append("numericParserOverflow")
                }
                lines.append("candidate[\(index)] label=\(label) parsed=\(Self.parseFormattedInteger(label).map(String.init) ?? "nil") reasons=\(reasons.isEmpty ? "none" : reasons.joined(separator: ","))")
            }
        }

        let diagnostic = lines.joined(separator: "\n")
        print(diagnostic)
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "NATIVE_QA_SUMMARY_DIAGNOSTIC"
        attachment.lifetime = .keepAlways
        add(attachment)
        attachScreenshot(named: "NATIVE_QA_SUMMARY_DIAGNOSTIC")
    }

    private static func isValidFormattedInteger(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let allowedSeparators: Set<Character> = [
            ",", ".", " ", "\u{00A0}", "\u{202F}", "'", "\u{2009}", "\u{2007}"
        ]
        guard trimmed.allSatisfy({ ("0"..."9").contains($0) || allowedSeparators.contains($0) }) else {
            return false
        }

        let separator = trimmed.first(where: { allowedSeparators.contains($0) })

        if separator == nil {
            return !trimmed.isEmpty && trimmed.allSatisfy { ("0"..."9").contains($0) }
        }

        let groups = trimmed.split(separator: separator!, omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty }) else { return false }
        guard Set(trimmed.filter { allowedSeparators.contains($0) }) == [separator!] else {
            return false
        }

        guard let firstGroup = groups.first, (1...3).contains(firstGroup.count),
              firstGroup.allSatisfy({ ("0"..."9").contains($0) }) else {
            return false
        }
        return groups.dropFirst().allSatisfy { group in
            group.count == 3 && group.allSatisfy({ ("0"..."9").contains($0) })
        }
    }

    private static func parseFormattedInteger(_ text: String) -> Int? {
        guard isValidFormattedInteger(text) else { return nil }
        let digits = text.filter { ("0"..."9").contains($0) }
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
            let ax = self.app.descendants(matching: .any)
            return !ax[Identifier.diarySummary].exists
                || ax[Identifier.settingsSheet].exists
                || ax["nutrition.details"].exists
                || ax["library.section"].exists
                || ax["library.foods"].exists
                || ax["library.meals"].exists
                || ax["library.add"].exists
                || ax["library.detail"].exists
                || ax["meals.list"].exists
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
        func isActiveSurface(_ identifier: String) -> Bool {
            app.descendants(matching: .any)
                .matching(identifier: identifier)
                .allElementsBoundByIndex
                .contains { $0.exists && $0.isHittable }
        }
        func isDiarySemanticRootVisible() -> Bool {
            let summary = app.descendants(matching: .any)[Identifier.diarySummary]
            let dateNavigation = app.descendants(matching: .any)["diary.dateNavigation"]
            let calendar = app.descendants(matching: .any)[Identifier.calendar]
            guard summary.exists,
                  dateNavigation.exists,
                  calendar.exists else {
                return false
            }
            if app.buttons["app.tab.diary"].exists,
               !app.buttons["app.tab.diary"].isSelected {
                return false
            }
            if isActiveSurface("search.field") {
                return false
            }
            if isActiveSurface("foodDetail.submit") {
                return false
            }
            if isActiveSurface("foodDetail.amount.field") {
                return false
            }
            if app.sheets.count > 0 {
                return false
            }
            return true
        }
        func isDiaryRootVisible() -> Bool {
            guard isDiarySemanticRootVisible() else { return false }
            let calendar = app.descendants(matching: .any)[Identifier.calendar]
            guard calendar.exists else { return false }
            let frame = calendar.frame
            let hasValidFrame = frame.minX.isFinite
                && frame.minY.isFinite
                && frame.maxX.isFinite
                && frame.maxY.isFinite
                && frame.width > 0
                && frame.height > 0
            guard hasValidFrame else { return false }
            let window = app.windows.firstMatch
            let viewport = window.exists ? window.frame : app.frame
            let hasValidViewport = viewport.minX.isFinite
                && viewport.minY.isFinite
                && viewport.maxX.isFinite
                && viewport.maxY.isFinite
                && viewport.width > 0
                && viewport.height > 0
            guard hasValidViewport else { return false }
            guard frame.intersects(viewport) else { return false }
            return calendar.isHittable
        }

        for _ in 0..<4 {
            if isDiaryRootVisible() {
                return true
            }
            if isDiarySemanticRootVisible() {
                scrollDiaryToTop()
                if isDiaryRootVisible() {
                    return true
                }
            }
            // Native tab destinations return through the Diary tab. Only do
            // this when a different tab's surface is present; on a pushed
            // Search/FoodDetail screen the tab item is still visible and a
            // tab tap would loop forever without using the real Back button.
            let otherTabSurface = app.descendants(matching: .any)["library.section"].exists
                || app.descendants(matching: .any)["meals.list"].exists
                || app.descendants(matching: .any)[Identifier.settingsSheet].exists
            if otherTabSurface,
               tapFirstReachable(["app.tab.diary", "diary.tab", "tab.diary"], labels: ["Diary"]) {
                _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                    isDiaryRootVisible()
                }
                continue
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
                    isDiaryRootVisible()
                }
                continue
            }
            if let back = leftmostNavigationBackButton() {
                back.tap()
                _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                    isDiaryRootVisible()
                }
                continue
            }
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                isDiaryRootVisible()
            }
        }
        let onDiary: Bool
        if isDiaryRootVisible() {
            onDiary = true
        } else if isDiarySemanticRootVisible() {
            scrollDiaryToTop()
            onDiary = isDiaryRootVisible()
        } else {
            onDiary = false
        }
        if !onDiary {
            diagnoseReturnToDiaryFailure()
            print("NATIVE_QA_RETURN_TO_DIARY_FAILED\n\(app.debugDescription)")
        }
        return onDiary
    }

    private func diagnoseReturnToDiaryFailure() {
        func describe(_ element: XCUIElement, includeSelected: Bool = false) -> String {
            guard element.exists else { return "exists=false" }
            let frame = element.frame
            let hasValidFrame = frame.minX.isFinite
                && frame.minY.isFinite
                && frame.maxX.isFinite
                && frame.maxY.isFinite
                && frame.width > 0
                && frame.height > 0
            let window = app.windows.firstMatch
            let viewport = window.exists ? window.frame : app.frame
            let hasValidViewport = viewport.minX.isFinite
                && viewport.minY.isFinite
                && viewport.maxX.isFinite
                && viewport.maxY.isFinite
                && viewport.width > 0
                && viewport.height > 0
            let isVisibleInViewport = hasValidFrame && hasValidViewport && frame.intersects(viewport)
            var parts = [
                "exists=true",
                "frame=\(frame)",
                "frameValid=\(hasValidFrame)",
                "visibleInViewport=\(isVisibleInViewport)",
            ]
            if isVisibleInViewport {
                parts.append("hittable=\(element.isHittable)")
            } else {
                parts.append("hittable=skipped-invalid-or-offscreen")
            }
            if includeSelected {
                parts.append("selected=\(element.isSelected)")
            }
            return parts.joined(separator: " ")
        }

        let summary = app.descendants(matching: .any)[Identifier.diarySummary]
        let dateNavigation = app.descendants(matching: .any)["diary.dateNavigation"]
        let calendar = app.descendants(matching: .any)[Identifier.calendar]
        let diaryTab = app.buttons["app.tab.diary"]
        let activeSurfaceIdentifiers = ["search.field", "foodDetail.submit", "foodDetail.amount.field"]
        let activeSurfaces = activeSurfaceIdentifiers.map { identifier in
            let isActive = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .allElementsBoundByIndex
                .contains { candidate in
                    guard candidate.exists else { return false }
                    return candidate.isHittable
                }
            return "\(identifier)=\(isActive)"
        }
        let topNavigationBars = app.navigationBars.allElementsBoundByIndex
        let scrollViews = app.scrollViews.allElementsBoundByIndex

        var lines: [String] = []
        lines.append("NATIVE_QA_RETURN_TO_DIARY_DIAGNOSTIC")
        lines.append("capturedAt=\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("summary \(describe(summary))")
        lines.append("dateNavigation \(describe(dateNavigation))")
        lines.append("calendar \(describe(calendar))")
        lines.append("diaryTab \(describe(diaryTab, includeSelected: true))")
        lines.append("activeSurfaces \(activeSurfaces.joined(separator: " "))")
        lines.append("sheetCount=\(app.sheets.count)")
        lines.append("topNavigationBars count=\(topNavigationBars.count)")
        for (index, bar) in topNavigationBars.enumerated() {
            let barState = describe(bar)
            let barIdentifier = bar.exists ? bar.identifier : ""
            let barLabel = bar.exists ? bar.label : ""
            lines.append("  navBar[\(index)] identifier=\(barIdentifier) label=\(barLabel) \(barState)")
        }
        lines.append("scrollViews count=\(scrollViews.count)")
        for (index, scrollView) in scrollViews.enumerated() {
            let scrollState = describe(scrollView)
            let scrollIdentifier = scrollView.exists ? scrollView.identifier : ""
            let scrollLabel = scrollView.exists ? scrollView.label : ""
            lines.append("  scrollView[\(index)] identifier=\(scrollIdentifier) label=\(scrollLabel) \(scrollState)")
        }

        let diagnostic = lines.joined(separator: "\n")
        print(diagnostic)
        let attachment = XCTAttachment(string: diagnostic)
        attachment.name = "NATIVE_QA_RETURN_TO_DIARY_DIAGNOSTIC"
        attachment.lifetime = .keepAlways
        add(attachment)
        attachScreenshot(named: "NATIVE_QA_RETURN_TO_DIARY_DIAGNOSTIC")
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

    /// Existence alone can hide a clipped header: an offscreen label still
    /// appears in the accessibility tree. Require a hittable title and kcal
    /// subtotal whose frames sit inside the meal-slot card viewport.
    private func assertVisibleMealHeadersInsideCards(variant: String) {
        let metadata = [
            "variant=\(variant)",
            "launchArguments=\(app.launchArguments.joined(separator: " "))",
            "capturedAt=\(ISO8601DateFormatter().string(from: Date()))",
        ].joined(separator: "\n")
        let metadataAttachment = XCTAttachment(string: metadata)
        metadataAttachment.name = "visual-metadata-\(variant)"
        metadataAttachment.lifetime = .keepAlways
        add(metadataAttachment)

        // Derive header geometry from leaf text and the artwork image only.
        // Do NOT depend on a card container identifier: the shipped source
        // propagated that identifier to descendants and hid the stable
        // per-leaf IDs. This check must not force reintroducing it.
        let slots: [(String, (String) -> Bool)] = [
            ("Breakfast", { $0.localizedCaseInsensitiveContains("breakfast") }),
            ("Lunch", { $0.localizedCaseInsensitiveContains("lunch") }),
            ("Dinner", { $0.localizedCaseInsensitiveContains("dinner") }),
            ("Snack", { $0.caseInsensitiveCompare("snack") == .orderedSame }),
            ("Late-night snack", {
                $0.localizedCaseInsensitiveContains("late-night snack")
                    || $0.localizedCaseInsensitiveContains("late night snack")
            }),
        ]
        // Spacious layouts allow cards below the fold; bring one into view
        // using a stable leaf ID instead of assuming every card is on screen.
        _ = scrollToElement(
            matchingPrefix: Identifier.addFoodPrefix,
            marker: Identifier.diarySummary,
            direction: .up
        )
        let window = app.windows.firstMatch.frame
        let visibleText = app.staticTexts.allElementsBoundByIndex.filter {
            $0.exists && $0.isHittable && $0.frame.intersects(window)
        }
        let images = app.images.allElementsBoundByIndex.filter { $0.exists }

        var checked = 0
        for (label, matches) in slots {
            guard let title = visibleText.first(where: { matches($0.label) }) else { continue }
            // The approved header places title and kcal side by side on the
            // same baseline, so match by vertical overlap, not horizontal
            // proximity to the title.
            guard let kcal = visibleText.first(where: { text in
                text.label.localizedCaseInsensitiveContains("kcal")
                    && text.frame.maxY >= title.frame.minY - 2
                    && text.frame.minY <= title.frame.maxY + 2
                    && text.frame.minY >= title.frame.minY - 40
            }) else {
                XCTFail("The \(label) header has no visible kcal subtotal.")
                continue
            }
            // Prefer the real artwork frame when it contains the title; fall
            // back to the title+subtotal union if no artwork node is exposed.
            var group = title.frame.union(kcal.frame)
            if let art = images.first(where: { image in
                image.frame.width > 20 && image.frame.height > 20
                    && image.frame.contains(CGPoint(x: title.frame.midX, y: title.frame.midY))
            }) {
                group = art.frame
            }
            for (name, element) in [("title", title), ("subtotal", kcal)] {
                XCTAssertTrue(
                    element.frame.minY >= group.minY - 2,
                    "\(label) \(name) starts above its art header group."
                )
                XCTAssertTrue(
                    element.frame.maxY <= group.maxY + 2,
                    "\(label) \(name) is clipped below its art header group."
                )
                XCTAssertTrue(
                    element.frame.minX >= group.minX - 2,
                    "\(label) \(name) starts left of its art header group."
                )
                XCTAssertTrue(
                    element.frame.maxX <= group.maxX + 2,
                    "\(label) \(name) is clipped right of its art header group."
                )
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "No meal card header was visible and hittable.")
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
            // Select All is the reliable clear path: delete-key counts depend
            // on cursor placement and left "12.5100" in the quantity field.
            let selectAll = app.menuItems.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Select All")
            ).firstMatch
            if selectAll.waitForExistence(timeout: 2), selectAll.isHittable {
                selectAll.tap()
            } else {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                for _ in 0..<current.count {
                    element.typeText(XCUIKeyboardKey.delete.rawValue)
                }
            }
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
        // Native compact Add Food exposes one AI row whose Menu offers the two
        // shipped purposes (search.assistant.customFood / .adHocLog). Open the
        // row, then tap the exact requested purpose; never substitute a
        // different purpose just to reach the composer.
        let entry = hittableElement(identifier: "search.assistant")
            ?? hittableElement(identifier: "search.quickEntry.assistant")
        guard let entry else {
            XCTFail("Assistant entry is not reachable from Search.")
            return
        }
        entry.tap()
        let purpose = app.descendants(matching: .any)[purposeIdentifier]
        XCTAssertTrue(
            purpose.waitForExistence(timeout: Timeout.normal),
            "Assistant purpose \(purposeIdentifier) is missing."
        )
        XCTAssertTrue(purpose.isHittable, "Assistant purpose \(purposeIdentifier) is not hittable.")
        // Evidence of the compact native AI-purpose Menu before selection.
        attachScreenshot(named: "iPhone-13-mini-ai-purpose-menu-\(purposeIdentifier)")
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
