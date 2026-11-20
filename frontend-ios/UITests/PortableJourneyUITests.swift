import Foundation
import XCTest

#if os(iOS)
import UIKit
#endif

// Portable device acceptance for native macOS and iPad Air.
//
// This suite intentionally has no 375x812 guard and no skip path. A fixture
// or launch problem is a failure, never a skipped pass. It drives the real
// isolated Test app against the QA-owned loopback fixture on a dynamic port.
//
// The mini-only NativeCompletionUITests suite remains authoritative for its
// fixed-size journeys. Do not reuse that suite as larger-device evidence.

final class PortableJourneyUITests: XCTestCase {
    private enum Fixture {
        static let username = "native-qa"
        static let password = "native-qa"
        static let baseURLKey = "CALCO_PORTABLE_UI_BASE_URL"
        static let marker = "native-completion-qa"
        static let accountHeader = "X-CalCo-Account-ID"
        static let profileID = "22222222-2222-4222-8222-222222222222"
    }

    private enum Timeout {
        static let short: TimeInterval = 5
        static let normal: TimeInterval = 20
        static let long: TimeInterval = 45
    }

    private enum HarnessError: Error, CustomStringConvertible {
        case missingBaseURL
        case badResponse(String)

        var description: String {
            switch self {
            case .missingBaseURL:
                return "CALCO_PORTABLE_UI_BASE_URL is missing or not loopback-only."
            case .badResponse(let message):
                return message
            }
        }
    }

    private var app: XCUIApplication!
    private var baseURL: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        guard let raw = ProcessInfo.processInfo.environment[Fixture.baseURLKey],
              let url = URL(string: raw),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw HarnessError.missingBaseURL
        }
        baseURL = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        try resetFixture(assistantEnabled: false)
        _ = try mockState()
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
    }

    // MARK: - Acceptance journeys

    func testPortableDiaryNavigationSelectedDateAndSettings() throws {
        try launchSignedIn()
        XCTAssertTrue(waitFor("diary.summary.calories"), "The diary did not load.")

        XCTAssertTrue(
            tapToolbarAction("diary.previousDay"),
            "Previous Day is not reachable."
        )
        XCTAssertTrue(
            waitForHistoricalLog(),
            "Previous Day did not expose the historical fixture log."
        )
        let historicalSummary = summaryLabel()
        XCTAssertFalse(historicalSummary.isEmpty, "The historical summary is empty.")

        XCTAssertTrue(openSettings(), "Settings did not open.")
        XCTAssertTrue(
            waitFor("settings.goals.calories"),
            "The settings goals form did not load."
        )
        guard let calories = scrollTo(
            "settings.goals.calories",
            marker: "settings.sheet",
            direction: .down
        ) else {
            XCTFail("The calorie target is not reachable.")
            return
        }
        replaceText(in: calories, with: "2230")
        dismissKeyboard(identifier: "settings.keyboard.done")
        guard let save = scrollTo(
            "settings.goals.save",
            marker: "settings.sheet",
            direction: .up
        ), save.isEnabled else {
            XCTFail("Save Goals is not enabled and reachable.")
            return
        }
        save.tap()
        XCTAssertTrue(
            waitFor("settings.goals.saved", timeout: Timeout.long),
            "The goal save did not complete."
        )
        XCTAssertEqual(
            try mockState().goalCalories,
            2230,
            "The fixture did not record the goal update."
        )
        XCTAssertTrue(tap("settings.cancel"), "Settings did not close.")
        XCTAssertTrue(waitFor("diary.summary.calories"), "The diary did not return.")
        XCTAssertTrue(waitForHistoricalLog(), "The historical date was lost.")
        XCTAssertEqual(
            summaryLabel(),
            historicalSummary,
            "Returning from Settings changed the historical summary."
        )
        assertAccountBinding("diary/settings")
    }

    func testPortableLibraryCRUDAndAdHocLog() throws {
        try launchSignedIn()
        XCTAssertTrue(openLibrary(), "Library did not open.")
        XCTAssertTrue(waitForLibraryList(), "The Library list did not load.")
        let baseline = try mockState()

        tap("library.add")
        tap("library.add.custom")
        guard let name = waitForElement("library.editor.name") else {
            XCTFail("The custom-food editor did not open.")
            return
        }
        name.tap()
        name.typeText("Portable QA Custom Food")
        dismissKeyboard(identifier: "library.editor.keyboard.done")
        fillRequiredNutrients(
            marker: "library.editor.name",
            doneIdentifier: "library.editor.keyboard.done"
        )
        let save = app.buttons["library.editor.save"]
        XCTAssertTrue(
            save.waitForExistence(timeout: Timeout.normal),
            "Custom-food Save does not exist after valid input."
        )
        XCTAssertTrue(
            save.isEnabled,
            "Custom-food Save is disabled after valid input."
        )
        if save.isHittable {
            save.tap()
        } else {
            let navigationSave = app.navigationBars.buttons["Save"]
            XCTAssertTrue(
                navigationSave.waitForExistence(timeout: Timeout.short)
                    && navigationSave.isHittable,
                "Custom-food Save exists but is not hittable "
                    + "(frame \(save.frame), enabled \(save.isEnabled))."
            )
            navigationSave.tap()
        }
        guard let row = waitForLibraryRow() else {
            XCTFail("The created custom food did not appear.")
            return
        }
        XCTAssertTrue(
            row.label.localizedCaseInsensitiveContains("Portable QA Custom Food")
        )
        let foodID = row.identifier.replacingOccurrences(of: "library.row.", with: "")
        row.tap()

        XCTAssertTrue(waitFor("library.detail"), "The food detail did not open.")
        XCTAssertTrue(tap("library.detail.edit"), "The food edit form did not open.")
        guard let brand = waitForElement("library.editor.brand") else {
            XCTFail("The brand field is missing.")
            return
        }
        replaceText(in: brand, with: "Portable QA Brand")
        dismissKeyboard(identifier: "library.editor.keyboard.done")
        guard let editSave = hittable("library.editor.save"), editSave.isEnabled else {
            XCTFail("Edit Save is not reachable.")
            return
        }
        editSave.tap()
        XCTAssertTrue(waitForLibraryRow() != nil, "The edited food did not return.")
        app.buttons["library.row.\(foodID)"].tap()
        XCTAssertTrue(waitFor("library.detail"), "The edited detail did not open.")
        XCTAssertTrue(
            app.staticTexts["Portable QA Brand"].waitForExistence(timeout: Timeout.long),
            "The edited brand is not visible."
        )
        guard let delete = scrollTo(
            "library.detail.delete",
            marker: "library.detail",
            direction: .up
        ), delete.isHittable else {
            XCTFail("The custom-food delete action is not reachable.")
            return
        }
        delete.tap()
        guard let deleteConfirm = waitForConfirmationButton(
            identifier: "library.detail.delete.confirm"
        ) else {
            XCTFail("The delete confirmation did not appear.")
            return
        }
        deleteConfirm.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.buttons["library.row.\(foodID)"].exists
            },
            "The deleted custom food remained in Library."
        )

        let crud = try mockState()
        XCTAssertEqual(crud.customFoodCreateCount, baseline.customFoodCreateCount + 1)
        XCTAssertEqual(crud.customFoodUpdateCount, baseline.customFoodUpdateCount + 1)
        XCTAssertEqual(crud.customFoodDeleteCount, baseline.customFoodDeleteCount + 1)
        XCTAssertEqual(crud.customFoodCount, baseline.customFoodCount)

        let adHocBaseline = try mockState()
        tap("library.add")
        tap("library.add.adhoc")
        guard let adHocName = waitForElement("library.adHoc.name") else {
            XCTFail("The ad-hoc form did not open.")
            return
        }
        adHocName.tap()
        adHocName.typeText("Portable QA Ad Hoc")
        dismissKeyboard(identifier: "library.adHoc.keyboard.done")
        guard let mode = hittable("library.adHoc.mode"),
              selectOption("Save food and log", from: mode) else {
            XCTFail("Save food and log is not selectable.")
            return
        }
        fillRequiredNutrients(
            marker: "library.adHoc.name",
            doneIdentifier: "library.adHoc.keyboard.done"
        )
        guard let review = scrollTo(
            "library.adHoc.submit",
            marker: "library.adHoc.name",
            direction: .up
        ), review.isEnabled else {
            XCTFail("Ad-hoc Review is not reachable.")
            return
        }
        review.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: Timeout.normal))
        let confirm = alert.buttons["Save and log"]
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(
            waitFor("library.adHoc.logged", timeout: Timeout.long),
            "Ad-hoc save-and-log did not report success."
        )
        XCTAssertEqual(app.buttons.matching(identifier: "library.adHoc.done").count, 1)
        if app.buttons["library.adHoc.done"].exists {
            app.buttons["library.adHoc.done"].tap()
        }
        let final = try mockState()
        XCTAssertEqual(final.customFoodCreateCount, adHocBaseline.customFoodCreateCount + 1)
        XCTAssertEqual(final.logPostAttempts, adHocBaseline.logPostAttempts + 1)
        XCTAssertEqual(final.logCount, adHocBaseline.logCount + 1)
        XCTAssertEqual(final.customFoodCount, adHocBaseline.customFoodCount + 1)
        assertAccountBinding("Library/ad-hoc")
    }

    func testPortableMealsPreviewLogAndNotes() throws {
        try launchSignedIn()
        XCTAssertTrue(goToHistoricalDay(), "The historical fixture day did not load.")
        XCTAssertTrue(openMeals(), "Meals did not open.")
        guard let mealRow = waitForElement("meals.list.row.qa-meal-1") else {
            XCTFail("The fixture meal row did not appear.")
            return
        }
        mealRow.tap()
        XCTAssertTrue(waitFor("meals.detail"), "The meal detail did not open.")
        XCTAssertTrue(
            app.staticTexts["Fixture meal"].waitForExistence(timeout: Timeout.normal),
            "The seeded meal notes are missing."
        )
        let baseline = try mockState()

        tap("meals.detail.edit")
        guard let notes = waitForElement("meals.editor.notes") else {
            XCTFail("The meal notes field did not open.")
            return
        }
        replaceText(in: notes, with: "Portable QA meal notes")
        if app.keyboards.firstMatch.exists {
            app.swipeUp()
        }
        guard let save = hittable("meals.editor.save") else {
            XCTFail("Meal Save is not reachable.")
            return
        }
        save.tap()
        XCTAssertTrue(waitFor("meals.detail", timeout: Timeout.long))
        XCTAssertTrue(
            app.staticTexts["Portable QA meal notes"]
                .waitForExistence(timeout: Timeout.long),
            "The edited meal notes are missing."
        )
        guard let previewHeader = scrollTo(
            "meals.detail.preview.header",
            marker: "meals.detail",
            direction: .down,
            requireHittable: false,
            requireFullyVisible: true
        ) else {
            XCTFail("The meal preview header is not visibly reachable.")
            return
        }
        assertVisibleStaticText(previewHeader, label: "meal preview header")
        for code in ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"] {
            guard let nutrient = scrollTo(
                "meals.detail.preview.nutrient.\(code)",
                marker: "meals.detail.preview.header",
                direction: .down,
                requireHittable: false,
                requireFullyVisible: true
            ) else {
                XCTFail("The \(code) preview nutrient is not visibly reachable.")
                return
            }
            assertVisibleStaticText(nutrient, label: "meal preview \(code)")
        }
        guard let log = scrollTo(
            "meals.detail.log",
            marker: "meals.detail",
            direction: .down
        ), log.isEnabled else {
            XCTFail("Log Meal is not reachable.")
            return
        }
        log.tap()
        XCTAssertTrue(
            waitFor("meals.detail.log.success", timeout: Timeout.long),
            "Meal logging did not succeed."
        )
        let final = try mockState()
        XCTAssertEqual(final.mealUpdateCount, baseline.mealUpdateCount + 1)
        XCTAssertEqual(final.logCount, baseline.logCount + 1)
        XCTAssertEqual(final.logPostAttempts, baseline.logPostAttempts + 1)
        assertAccountBinding("meals")
        tap("meals.close")
    }

    func testPortableNutritionReportAndManualBarcode() throws {
        try launchSignedIn()
        XCTAssertTrue(goToHistoricalDay(), "The historical fixture day did not load.")
        XCTAssertTrue(openNutrition(), "Nutrition did not open.")
        guard let coverage = scrollTo(
            "nutrition.coverage",
            marker: "nutrition.details",
            direction: .up,
            requireHittable: false,
            requireFullyVisible: true
        ) else {
            XCTFail("The nutrition coverage is not visibly reachable.")
            return
        }
        assertVisibleStaticText(coverage, label: "nutrition coverage")
        guard let date = scrollTo(
            "nutrition.date",
            marker: "nutrition.details",
            direction: .up,
            requireHittable: false,
            requireFullyVisible: true
        ) else {
            XCTFail("The nutrition date is not visibly reachable.")
            return
        }
        assertVisibleStaticText(date, label: "nutrition date")
        guard let energy = scrollTo(
            "nutrition.overview.ENERGY_KCAL",
            marker: "nutrition.overview",
            direction: .up,
            requireHittable: false,
            requireFullyVisible: true
        ) else {
            XCTFail("The energy overview tile is not visibly reachable.")
            return
        }
        assertVisibleStaticText(energy, label: "nutrition energy overview")
        tap("nutrition.close")
        XCTAssertTrue(waitFor("diary.summary.calories"), "The diary did not return.")

        XCTAssertTrue(openSearchFromDiary(), "Search did not open.")
        let scope = app.segmentedControls["search.scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: Timeout.normal))
        scope.buttons["Barcode"].tap()
        guard let barcode = waitForElement("search.barcode.field") else {
            XCTFail("The manual barcode field did not appear.")
            return
        }
        barcode.tap()
        barcode.typeText("0012345")
        XCTAssertEqual(barcode.value as? String, "0012345")
        tap("search.barcode.lookupButton")
        XCTAssertTrue(
            waitFor("search.barcode.notFound", timeout: Timeout.long),
            "The reviewed not-found state is missing."
        )
        var create = element("search.barcode.create")
        if !create.exists {
            create = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Create")
            ).firstMatch
        }
        if !create.exists {
            _ = scrollTo(
                "search.barcode.notFound",
                marker: "search.barcode.notFound",
                direction: .up,
                requireHittable: false
            )
        }
        XCTAssertTrue(
            create.waitForExistence(timeout: Timeout.normal),
            "The barcode custom-food path is missing."
        )
        guard create.isHittable else {
            XCTFail("The barcode custom-food action is not hittable.")
            return
        }
        create.tap()
        XCTAssertTrue(
            waitFor("library.editor.name", timeout: Timeout.long),
            "The barcode create path did not open the editor."
        )
        cancelLibraryEditor()
        assertAccountBinding("nutrition/barcode")
    }

    func testPortableAssistantDisabledAndEnabledReview() throws {
        try launchSignedIn()
        XCTAssertTrue(openSearchFromDiary(), "Search did not open.")
        XCTAssertTrue(openAssistant("search.assistant.customFood"), "Assistant did not open.")
        XCTAssertTrue(
            waitFor("assistant.status.disabled", timeout: Timeout.long),
            "The disabled assistant gate is missing."
        )
        XCTAssertFalse(
            app.buttons["assistant.send"].exists,
            "The disabled assistant exposed a send control."
        )
        tap("assistant.cancel")

        try resetFixture(assistantEnabled: true)
        app.terminate()
        try launchSignedIn()
        XCTAssertTrue(openSearchFromDiary(), "Search did not reopen.")
        XCTAssertTrue(openAssistant("search.assistant.customFood"), "Assistant did not reopen.")
        guard let composer = waitForElement("assistant.composer") else {
            XCTFail("The assistant composer is missing.")
            return
        }
        composer.tap()
        composer.typeText("Draft a 100 g oat food for review.")
        guard let send = hittable("assistant.send"), send.isEnabled else {
            XCTFail("Assistant Send is not enabled.")
            return
        }
        send.tap()
        XCTAssertTrue(
            waitFor("assistant.draft", timeout: Timeout.long),
            "The assistant draft did not arrive."
        )
        XCTAssertTrue(
            app.staticTexts["Native QA AI Oats"].exists,
            "The draft name is not visible."
        )
        XCTAssertTrue(
            waitFor("assistant.draft.warnings"),
            "The draft warnings are missing."
        )
        let beforeAccept = try mockState()
        tap("assistant.draft.accept")
        XCTAssertTrue(
            waitFor("library.editor.name", timeout: Timeout.long),
            "Draft acceptance did not open the review editor."
        )
        XCTAssertEqual(
            app.textFields["library.editor.name"].value as? String,
            "Native QA AI Oats"
        )
        XCTAssertEqual(
            try mockState().customFoodCreateCount,
            beforeAccept.customFoodCreateCount,
            "Accepting the draft wrote a food before explicit save."
        )
        guard let save = scrollTo(
            "library.editor.save",
            marker: "library.editor.name",
            direction: .up
        ), save.isEnabled else {
            XCTFail("The reviewed assistant food cannot be saved.")
            return
        }
        save.tap()
        XCTAssertTrue(
            waitForLibraryRow(timeout: Timeout.long) != nil,
            "The reviewed assistant food did not save."
        )
        XCTAssertEqual(
            try mockState().customFoodCreateCount,
            beforeAccept.customFoodCreateCount + 1
        )
        XCTAssertEqual(
            try mockState().assistantDraftRequestCount,
            beforeAccept.assistantDraftRequestCount
        )
        assertAccountBinding("assistant")
    }

    func testPortableAPIKeyCreateRevealCopyRevoke() throws {
        try launchSignedIn()
        XCTAssertTrue(openSettings(), "Settings did not open.")
        XCTAssertTrue(openAPIKeys(), "API keys did not open.")
        let baseline = try mockState()
        tap("settings.apiKeys.create")
        guard let name = waitForElement("settings.apiKeys.create.name") else {
            XCTFail("The API-key create form did not open.")
            return
        }
        name.tap()
        name.typeText("Portable QA Key")
        if app.buttons["settings.apiKeys.create.keyboard.done"].exists {
            app.buttons["settings.apiKeys.create.keyboard.done"].tap()
        }
        guard let submit = firstHittable([
            "settings.apiKeys.create.submit",
            "settings.apiKeys.create.submitBottom",
        ]) ?? scrollTo(
            "settings.apiKeys.create.submitBottom",
            marker: "settings.apiKeys.create.name",
            direction: .up
        ) else {
            XCTFail("Create API Key is not reachable.")
            return
        }
        submit.tap()
        XCTAssertTrue(
            waitFor("settings.apiKeys.secret", timeout: Timeout.long),
            "The one-time secret did not appear."
        )
        XCTAssertTrue(
            waitFor("settings.apiKeys.secret.warning"),
            "The one-time secret warning is missing."
        )
        tap("settings.apiKeys.secret.copy")
        XCTAssertTrue(
            waitFor("settings.apiKeys.secret.copied"),
            "Copy did not confirm."
        )
        tap("settings.apiKeys.secret.done")
        let created = try mockState()
        XCTAssertEqual(created.apiKeyCount, baseline.apiKeyCount + 1)

        guard let revoke = hittable("settings.apiKeys.revoke.qa-api-key-1")
            ?? scrollTo(
                "settings.apiKeys.revoke.qa-api-key-1",
                marker: "settings.apiKeys.list",
                direction: .up
            ) else {
            XCTFail("The fixture key is not listed for revocation.")
            return
        }
        revoke.tap()
        guard let confirm = confirmationButton(label: "Revoke key") else {
            XCTFail("The revoke confirmation is missing.")
            return
        }
        confirm.tap()
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.long) {
                !self.app.buttons["settings.apiKeys.revoke.qa-api-key-1"].exists
            },
            "The revoked key remained listed."
        )
        let final = try mockState()
        XCTAssertEqual(final.apiKeyCount, baseline.apiKeyCount)
        assertAccountBinding("API keys")
    }

    func testPortableLayoutAdaptation() throws {
        try launchSignedIn()
        XCTAssertTrue(waitFor("diary.summary.calories"), "The diary did not load.")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Timeout.normal))
        XCTAssertGreaterThan(window.frame.width, 300)
        XCTAssertGreaterThan(window.frame.height, 300)

#if os(macOS)
        exerciseMacNarrowWindow(window: window)
#else
        exerciseIPadOrientations(window: window)
#endif
        assertAccountBinding("layout")
    }

    // MARK: - Platform layout

#if os(macOS)
    private func exerciseMacNarrowWindow(window: XCUIElement) {
        if window.frame.width >= 900 {
            shrinkMacWindow()
            XCTAssertTrue(
                CalCoE2E.waitUntil(timeout: Timeout.normal) {
                    window.frame.width < 900
                },
                "The Mac window could not be narrowed below the 900-point split threshold."
            )
        }
        XCTAssertLessThan(window.frame.width, 900)
        XCTAssertTrue(openLibrary(), "Library did not open in the narrow Mac window.")
        XCTAssertTrue(waitForLibraryList(), "The Library list did not load in the narrow window.")
        tap("library.add")
        tap("library.add.custom")
        guard let name = waitForElement("library.editor.name") else {
            XCTFail("The narrow-window editor did not open.")
            return
        }
        name.tap()
        name.typeText("Portable Mac Layout Food")
        assertWithinWindow(name, label: "custom-food name")
        assertWithinWindow(app.buttons["library.editor.save"], label: "custom-food Save")
        cancelLibraryEditor()
        tap("library.close")
        XCTAssertTrue(waitFor("diary.summary.calories"), "The diary did not return.")
    }

    private func shrinkMacWindow() {
        let window = app.windows.firstMatch
        for _ in 0..<5 where window.frame.width >= 900 {
            let start = window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995)
            )
            let end = window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.58, dy: 0.72)
            )
            start.press(forDuration: 0.25, thenDragTo: end)
        }
    }
#else
    private func exerciseIPadOrientations(window: XCUIElement) {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                window.frame.width > window.frame.height
            },
            "The iPad did not enter landscape."
        )
        XCTAssertGreaterThan(
            window.frame.width,
            900,
            "iPad Air landscape did not reach the expanded layout width."
        )
        XCTAssertTrue(openLibrary(), "Library did not open in landscape.")
        XCTAssertTrue(waitForLibraryList(), "The Library list did not load in landscape.")
        assertMinimumTouchTarget(app.buttons["library.add"], label: "Library add")
        tap("library.close")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: Timeout.normal) {
                window.frame.height > window.frame.width
            },
            "The iPad did not return to portrait."
        )
        XCTAssertLessThan(window.frame.width, 900)
        XCTAssertTrue(openLibrary(), "Library did not open in portrait.")
        XCTAssertTrue(waitForLibraryList(), "The Library list did not load in portrait.")
        assertMinimumTouchTarget(app.buttons["library.add"], label: "Library add")
        tap("library.close")
        XCTAssertTrue(waitFor("diary.summary.calories"), "The diary did not return.")
    }

    private func assertMinimumTouchTarget(
        _ element: XCUIElement,
        label: String
    ) {
        XCTAssertTrue(element.exists && element.isHittable, "\(label) is not hittable.")
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            44,
            "\(label) is narrower than the 44-point touch target."
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height,
            44,
            "\(label) is shorter than the 44-point touch target."
        )
    }
#endif

    // MARK: - Launch and fixture

    private func launchSignedIn() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = baseURL
        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)
        try signInFixture()
        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long) else {
            XCTFail("The diary did not load after fixture sign-in.")
            return
        }
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)
    }

    private func signInFixture() throws {
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        guard username.waitForExistence(timeout: Timeout.normal),
              password.waitForExistence(timeout: Timeout.normal) else {
            throw HarnessError.badResponse("The login form did not appear.")
        }
        username.tap()
        username.typeText(Fixture.username)
        password.tap()
        password.typeText(Fixture.password)
        XCTAssertFalse(
            (password.value as? String ?? "").isEmpty,
            "The nonsecret fixture password did not populate the secure field."
        )

        let accessory = app.buttons["auth.login.keyboard.submit"]
        if accessory.exists, accessory.isHittable {
            accessory.tap()
        } else {
            let submit = app.buttons["auth.login.submit"]
            if submit.exists, submit.isHittable {
                submit.tap()
            } else {
                app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
            }
        }
    }

    private func resetFixture(assistantEnabled: Bool) throws {
        var request = URLRequest(url: URL(string: baseURL + "/__qa/reset")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .current
        let body: [String: Any] = [
            "today": day.string(from: Date()),
            "log_post": "success",
            "seed_logs": true,
            "assistant_enabled": assistantEnabled,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try syncRequest(request)
        guard response.status == 200 else {
            throw HarnessError.badResponse(
                "fixture reset returned HTTP \(response.status)"
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: response.data)
            as? [String: Any] else {
            throw HarnessError.badResponse("fixture reset summary was not readable")
        }
        try validateFixtureSummary(object)
    }

    private func validateFixtureSummary(_ object: [String: Any]) throws {
        guard object["ok"] as? Bool == true,
              object["fixture"] as? String == Fixture.marker else {
            throw HarnessError.badResponse(
                "fixture marker is not native-completion-qa"
            )
        }
        guard object["profile_id"] as? String == Fixture.profileID else {
            throw HarnessError.badResponse(
                "fixture profile UUID is not the contract value"
            )
        }
        guard object["account_header"] as? String == Fixture.accountHeader else {
            throw HarnessError.badResponse(
                "fixture account header is not the contract value"
            )
        }
        guard let identity = object["identity_id"] as? String,
              let identityUUID = UUID(uuidString: identity),
              let profileUUID = UUID(uuidString: Fixture.profileID),
              identityUUID != profileUUID else {
            throw HarnessError.badResponse(
                "fixture identity UUID is missing, malformed, or equals the profile UUID"
            )
        }
    }

    private func mockState() throws -> MockState {
        let request = URLRequest(url: URL(string: baseURL + "/__qa/state")!)
        let response = try syncRequest(request)
        guard response.status == 200,
              let object = try JSONSerialization.jsonObject(with: response.data)
                as? [String: Any] else {
            throw HarnessError.badResponse("fixture state was not readable")
        }
        func integer(_ key: String) -> Int {
            object[key] as? Int ?? -1
        }
        return MockState(
            goalCalories: integer("goal_calories"),
            logCount: integer("log_count"),
            logPostAttempts: integer("log_post_attempts"),
            customFoodCount: integer("custom_food_count"),
            customFoodCreateCount: integer("custom_food_create_count"),
            customFoodUpdateCount: integer("custom_food_update_count"),
            customFoodDeleteCount: integer("custom_food_delete_count"),
            mealUpdateCount: integer("meal_update_count"),
            assistantDraftRequestCount: integer("assistant_draft_request_count"),
            apiKeyCount: integer("api_key_count"),
            boundRequestCount: integer("bound_request_count"),
            unboundProtectedRequestCount: integer("unbound_protected_request_count")
        )
    }

    private struct HTTPResponse {
        let status: Int
        let data: Data
    }

    private func syncRequest(_ request: URLRequest) throws -> HTTPResponse {
        let expectation = expectation(description: "fixture request")
        var status = -1
        var data = Data()
        var failure: Error?
        URLSession.shared.dataTask(with: request) { body, response, error in
            if let error {
                failure = error
            } else {
                status = (response as? HTTPURLResponse)?.statusCode ?? -1
                data = body ?? Data()
            }
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 15)
        if let failure {
            throw HarnessError.badResponse("fixture request failed: \(failure)")
        }
        return HTTPResponse(status: status, data: data)
    }

    // MARK: - Feature entry

    private func openLibrary() -> Bool {
        guard tap("diary.library") else { return false }
        return waitFor("library.list") || waitFor("library.empty") || waitFor("library.add")
    }

    private func openMeals() -> Bool {
        guard tap("diary.meals") else { return false }
        return waitFor("meals.list") || waitFor("meals.list.row.qa-meal-1")
    }

    private func openNutrition() -> Bool {
        guard tap("diary.nutrition") else { return false }
        return waitFor("nutrition.details") || waitFor("nutrition.date")
    }

    private func openSettings() -> Bool {
        for _ in 0..<2 {
            guard tapToolbarAction("diary.settings") else { continue }
            if waitFor("settings.sheet", timeout: 10)
                || waitFor("settings.goals.calories", timeout: 10) {
                return true
            }
        }
        return false
    }

    private func openAPIKeys() -> Bool {
        guard waitFor("settings.sheet") || waitFor("settings.apiKeys.entry") else {
            return false
        }
        guard let entry = scrollTo(
            "settings.apiKeys.entry",
            marker: "settings.sheet",
            direction: .up
        ), entry.isHittable else {
            return false
        }
        entry.tap()
        return waitFor("settings.apiKeys.list") || waitFor("settings.apiKeys.create")
    }

    private func openSearchFromDiary() -> Bool {
        let prefix = "diary.addFood."
        for _ in 0..<3 {
            let add = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", prefix)
            ).allElementsBoundByIndex.first(where: {
                isGenuinelyVisible($0, requireHittable: true)
            }) ?? scrollToButton(
                prefix: prefix,
                marker: "diary.summary.calories"
            )
            guard let add else { return false }
            add.tap()
            if waitFor("search.field", timeout: 8) { return true }
            if tapVisibleLabel("Search"), waitFor("search.field", timeout: 8) {
                return true
            }
        }
        return false
    }

    private func tapVisibleLabel(_ label: String) -> Bool {
        let predicate = NSPredicate(format: "label ==[c] %@", label)
        guard let target = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
            .first(where: { isGenuinelyVisible($0, requireHittable: true) }) else {
            return false
        }
        target.tap()
        return true
    }

    private func openAssistant(_ purposeIdentifier: String) -> Bool {
        guard waitFor("search.assistant") else { return false }
        guard tapAny("search.assistant") else { return false }
        if tapAny(purposeIdentifier) { return true }
        let labels = purposeIdentifier.hasSuffix("adHocLog")
            ? ["Draft a meal log"]
            : ["Draft custom food"]
        for label in labels {
            let predicate = NSPredicate(format: "label ==[c] %@", label)
            for query in [
                app.buttons.matching(predicate),
                app.menuItems.matching(predicate),
            ] {
                let candidate = query.firstMatch
                if candidate.waitForExistence(timeout: Timeout.short),
                   candidate.isHittable {
                    candidate.tap()
                    return true
                }
            }
        }
        return false
    }

    private func waitForLibraryList() -> Bool {
        waitFor("library.list") || waitFor("library.empty") || waitForLibraryRow() != nil
    }

    private func waitForLibraryRow(timeout: TimeInterval = Timeout.long) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let row = app.buttons.matching(predicate).allElementsBoundByIndex
                .first(where: { $0.exists && $0.isHittable }) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return app.buttons.matching(predicate).firstMatch.exists
            ? app.buttons.matching(predicate).firstMatch
            : nil
    }

    private func goToHistoricalDay() -> Bool {
        scrollDiaryToTop()
        if visibleHistoricalLog() != nil { return true }
        guard tapToolbarAction("diary.previousDay") else { return false }
        return waitForHistoricalLog()
    }

    private func scrollDiaryToTop() {
        let container = scrollContainer(marker: "diary.summary.calories")
        for _ in 0..<6 {
            container.swipeDown()
        }
    }

    private func waitForHistoricalLog(timeout: TimeInterval = Timeout.long) -> Bool {
        if visibleHistoricalLog() != nil { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            scrollDiary()
            if visibleHistoricalLog() != nil { return true }
        }
        return false
    }

    private func visibleHistoricalLog() -> XCUIElement? {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@",
            "diary.log.hist-log-"
        )
        return app.descendants(matching: .any).matching(predicate)
            .allElementsBoundByIndex
            .first { isGenuinelyVisible($0, requireHittable: false) }
    }

    private func scrollDiary() {
        scrollContainer(marker: "diary.summary.calories").swipeUp()
    }

    private func summaryLabel() -> String {
        app.descendants(matching: .any)
            .matching(identifier: "diary.summary.calories")
            .allElementsBoundByIndex
            .map(\.label)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func cancelLibraryEditor() {
        if app.buttons["diary.common.cancel"].exists {
            app.buttons["diary.common.cancel"].tap()
        } else if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        }
        if app.buttons["library.editor.discard.confirm"].waitForExistence(timeout: 2) {
            app.buttons["library.editor.discard.confirm"].tap()
        }
    }

    // MARK: - Fields

    private func fillRequiredNutrients(
        marker: String,
        doneIdentifier: String
    ) {
        let values = [
            ("ENERGY_KCAL", "100"),
            ("PROTEIN_G", "10"),
            ("CARBS_G", "20"),
            ("FAT_G", "5"),
        ]
        for (code, amount) in values {
            guard let field = scrollTo(
                "library.nutrient.\(code).field",
                marker: marker,
                direction: .down
            ) else {
                XCTFail("The \(code) nutrient field is not reachable.")
                return
            }
            replaceText(in: field, with: amount)
            XCTAssertEqual(
                field.value as? String,
                amount,
                "The \(code) nutrient field did not retain \(amount)."
            )
            dismissKeyboard(identifier: doneIdentifier)
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

    private func dismissKeyboard(identifier: String) {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons[identifier]
        if done.exists, done.isHittable {
            done.tap()
            return
        }
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }

    // MARK: - Element helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func waitForElement(
        _ identifier: String,
        timeout: TimeInterval = Timeout.normal
    ) -> XCUIElement? {
        let target = element(identifier)
        return target.waitForExistence(timeout: timeout) ? target : nil
    }

    private func waitFor(
        _ identifier: String,
        timeout: TimeInterval = Timeout.normal
    ) -> Bool {
        waitForElement(identifier, timeout: timeout) != nil
    }

    private func hittable(_ identifier: String) -> XCUIElement? {
        let target = element(identifier)
        if target.waitForExistence(timeout: Timeout.normal), target.isHittable {
            return target
        }
        return nil
    }

    private func tap(_ identifier: String) -> Bool {
        guard let target = hittable(identifier) else { return false }
        target.tap()
        return true
    }

    private func tapToolbarAction(_ identifier: String) -> Bool {
        if let direct = hittable(identifier) {
            direct.tap()
            return true
        }
        for overflow in toolbarOverflowControls() where overflow.exists && overflow.isHittable {
            overflow.tap()
            if let revealed = hittable(identifier) {
                revealed.tap()
                return true
            }
        }
        return false
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

    private func tapAny(_ identifier: String) -> Bool {
        if tap(identifier) { return true }
        let menuItem = app.menuItems[identifier]
        if menuItem.waitForExistence(timeout: Timeout.short), menuItem.isHittable {
            menuItem.tap()
            return true
        }
        return false
    }

    private func firstHittable(_ identifiers: [String]) -> XCUIElement? {
        for identifier in identifiers {
            if let target = hittable(identifier) { return target }
        }
        return nil
    }

    private func scrollToButton(
        prefix: String,
        marker: String
    ) -> XCUIElement? {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        if let button = app.buttons.matching(predicate).allElementsBoundByIndex
            .first(where: { $0.exists && $0.isHittable }) {
            return button
        }
        for _ in 0..<16 {
            scrollContainer(marker: marker).swipeUp()
            if let button = app.buttons.matching(predicate).allElementsBoundByIndex
                .first(where: { $0.exists && $0.isHittable }) {
                return button
            }
        }
        for _ in 0..<16 {
            scrollContainer(marker: marker).swipeDown()
            if let button = app.buttons.matching(predicate).allElementsBoundByIndex
                .first(where: { $0.exists && $0.isHittable }) {
                return button
            }
        }
        return nil
    }

    private enum ScrollDirection {
        case up
        case down
    }

    private func scrollTo(
        _ identifier: String,
        marker: String,
        direction: ScrollDirection,
        maxSwipes: Int = 12,
        requireHittable: Bool = true,
        requireFullyVisible: Bool = false
    ) -> XCUIElement? {
        let target = element(identifier)
        if isGenuinelyVisible(
            target,
            requireHittable: requireHittable,
            requireFullyVisible: requireFullyVisible
        ) {
            return target
        }
        switch direction {
        case .down:
            for _ in 0..<maxSwipes {
                scrollContainer(marker: marker).swipeDown()
                if isGenuinelyVisible(
                    target,
                    requireHittable: requireHittable,
                    requireFullyVisible: requireFullyVisible
                ) {
                    return target
                }
            }
            for _ in 0..<maxSwipes {
                scrollContainer(marker: marker).swipeUp()
                if isGenuinelyVisible(
                    target,
                    requireHittable: requireHittable,
                    requireFullyVisible: requireFullyVisible
                ) {
                    return target
                }
            }
        case .up:
            for _ in 0..<maxSwipes {
                scrollContainer(marker: marker).swipeUp()
                if isGenuinelyVisible(
                    target,
                    requireHittable: requireHittable,
                    requireFullyVisible: requireFullyVisible
                ) {
                    return target
                }
            }
            for _ in 0..<maxSwipes {
                scrollContainer(marker: marker).swipeDown()
                if isGenuinelyVisible(
                    target,
                    requireHittable: requireHittable,
                    requireFullyVisible: requireFullyVisible
                ) {
                    return target
                }
            }
        }
        return isGenuinelyVisible(
            target,
            requireHittable: requireHittable,
            requireFullyVisible: requireFullyVisible
        ) ? target : nil
    }

    private func isGenuinelyVisible(
        _ element: XCUIElement,
        requireHittable: Bool,
        requireFullyVisible: Bool = false
    ) -> Bool {
        guard element.exists else { return false }
        let window = app.windows.firstMatch
        guard window.exists else { return false }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        let windowFrame = window.frame
        let intersection = windowFrame.intersection(frame)
        guard !intersection.isNull,
              intersection.width > 1,
              intersection.height > 1 else {
            return false
        }
        if requireFullyVisible {
            guard frame.minX >= windowFrame.minX - 1,
                  frame.maxX <= windowFrame.maxX + 1,
                  frame.minY >= windowFrame.minY - 1,
                  frame.maxY <= windowFrame.maxY + 1 else {
                return false
            }
        }
        if requireHittable, !element.isHittable { return false }
        return true
    }

    private func scrollContainer(marker: String) -> XCUIElement {
        let markerElement = element(marker)
        let candidates = app.scrollViews.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
        if let containing = candidates.first(where: {
            $0.exists && markerElement.exists && $0.frame.intersects(markerElement.frame)
        }) {
            return containing
        }
        if let largest = candidates.filter({ $0.exists }).max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) {
            return largest
        }
        return app
    }

    private func selectOption(_ label: String, from control: XCUIElement) -> Bool {
        control.tap()
        let predicate = NSPredicate(format: "label ==[c] %@", label)
        for query in [app.buttons.matching(predicate), app.menuItems.matching(predicate)] {
            let option = query.firstMatch
            if option.waitForExistence(timeout: Timeout.short), option.isHittable {
                option.tap()
                return true
            }
        }
        return false
    }

    private func confirmationButton(identifier: String) -> XCUIElement? {
        for query in [
            app.alerts.buttons.matching(identifier: identifier),
            app.sheets.buttons.matching(identifier: identifier),
            app.buttons.matching(identifier: identifier),
        ] where query.count > 0 {
            return query.firstMatch
        }
        return nil
    }

    private func confirmationButton(label: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label ==[c] %@", label)
        for query in [
            app.alerts.buttons.matching(predicate),
            app.sheets.buttons.matching(predicate),
            app.buttons.matching(predicate),
        ] where query.count > 0 {
            return query.firstMatch
        }
        return nil
    }

    private func waitForConfirmationButton(
        identifier: String,
        timeout: TimeInterval = Timeout.long
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = confirmationButton(identifier: identifier) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func assertWithinWindow(
        _ element: XCUIElement,
        label: String,
        requireHittable: Bool = true
    ) {
        let window = app.windows.firstMatch
        XCTAssertTrue(element.exists, "\(label) does not exist.")
        let frame = element.frame
        let windowFrame = window.frame
        let intersection = windowFrame.intersection(frame)
        XCTAssertFalse(intersection.isNull, "\(label) does not intersect the window.")
        XCTAssertGreaterThan(
            intersection.width,
            1,
            "\(label) has no positive visible width."
        )
        XCTAssertGreaterThan(
            intersection.height,
            1,
            "\(label) has no positive visible height."
        )
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            windowFrame.minX - 1,
            "\(label) overflows the left window edge."
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            windowFrame.maxX + 1,
            "\(label) overflows the right window edge."
        )
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            windowFrame.minY - 1,
            "\(label) overflows the top window edge."
        )
        XCTAssertLessThanOrEqual(
            frame.maxY,
            windowFrame.maxY + 1,
            "\(label) overflows the bottom window edge."
        )
        XCTAssertGreaterThan(frame.width, 1, "\(label) has no width.")
        XCTAssertGreaterThan(frame.height, 1, "\(label) has no height.")
        if requireHittable {
            XCTAssertTrue(element.isHittable, "\(label) is not hittable.")
        }
    }

    private func assertVisibleStaticText(
        _ element: XCUIElement,
        label: String
    ) {
        assertWithinWindow(element, label: label, requireHittable: false)
        XCTAssertFalse(element.label.isEmpty, "\(label) has no readable label.")
    }

    // MARK: - Fixture state

    private struct MockState {
        let goalCalories: Int
        let logCount: Int
        let logPostAttempts: Int
        let customFoodCount: Int
        let customFoodCreateCount: Int
        let customFoodUpdateCount: Int
        let customFoodDeleteCount: Int
        let mealUpdateCount: Int
        let assistantDraftRequestCount: Int
        let apiKeyCount: Int
        let boundRequestCount: Int
        let unboundProtectedRequestCount: Int
    }

    private func assertAccountBinding(_ context: String) {
        guard let state = try? mockState() else {
            XCTFail("\(context): fixture binding counters are unreadable.")
            return
        }
        XCTAssertGreaterThan(
            state.boundRequestCount,
            0,
            "\(context): no protected request carried \(Fixture.accountHeader)."
        )
        XCTAssertEqual(
            state.unboundProtectedRequestCount,
            0,
            "\(context): protected requests were unbound."
        )
    }
}
