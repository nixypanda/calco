// Focused, bounded iPhone 13 mini QA for the latest user-UX refinements.
//
// Scope (deliberately small — NOT the full device/journey matrix):
//   * two Search entry paths (Search tab + Diary Add Food push)
//   * result detail VISIBLE on the CURRENT tab, Back to the correct screen
//   * historical Diary date/meal-slot context retained when logging
//   * stable search field / scroll offset across multiple query edits
//   * search field + scope tabs scroll away (not pinned) with results
//   * My Foods native "+" Menu: manual editor + real assistant close
//   * "+" / root Back only where appropriate (absent on pushed editor)
//   * Settings native Back dismisses without sign-out, dirty guard preserved
//   * nutrition report has no date arrows; Close returns to Diary
//
// Rules enforced here:
//   * required controls are REQUIRED (fail hard, no XCTSkip, no optional taps)
//   * no Thread.sleep / unbounded polling — only bounded XCTWaiter conditions
//   * screenshots are real XCUIScreen PNGs, taken only after a target predicate
//   * `app.assistant.close` is the only assistant dismissal control used
//
// This file is added alongside (never replaces) all existing QA test files.

#if os(iOS)

import Foundation
import UIKit
import XCTest

final class LatestMiniUXRefinementQAUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum QA {
        static let baseURL = "http://127.0.0.1:3932"
        static let fixtureMarker = "native-completion-qa"
        static let username = "native-qa"
        static let password = "native-qa"
    }

    private enum Timeout {
        static let short: TimeInterval = 8
        static let normal: TimeInterval = 20
    }

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        try requireMockFixture()
        try resetFixture()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    // MARK: - Fixture plumbing

    private func requireMockFixture() throws {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.miniUXSynchronousData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer fixture is not available at \(QA.baseURL).")
            throw NSError(domain: "LatestMiniUXQA", code: 1)
        }
    }

    private func resetFixture(searchRows: Int? = nil) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var body: [String: Any] = [
            "today": formatter.string(from: Date()),
            "seed_logs": true,
            "log_post": "success",
            "assistant_enabled": false,
        ]
        // Only the non-pinned-header case asks for a genuinely scrollable
        // result list; every other case keeps the fixture's default two rows.
        if let searchRows { body["search_rows"] = searchRows }
        var request = URLRequest(url: URL(string: QA.baseURL + "/__qa/reset")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try URLSession.shared.miniUXSynchronousData(from: request.url!, request: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "The native QA fixture rejected its reset request.")
    }

    private func healthInfo() throws -> [String: Any] {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, _) = try URLSession.shared.miniUXSynchronousData(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func mockState() throws -> [String: Any] {
        let url = URL(string: QA.baseURL + "/__qa/state")!
        let (data, response) = try URLSession.shared.miniUXSynchronousData(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "The native QA fixture state is unavailable.")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - App / sign-in

    private func signIn() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        app.launch()

        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        XCTAssertTrue(username.waitForExistence(timeout: Timeout.normal), "Login username field missing.")
        XCTAssertTrue(password.waitForExistence(timeout: Timeout.normal), "Login password field missing.")
        username.tap()
        username.typeText(QA.username)
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short), "Keyboard missing on password.")
        password.typeText(QA.password)
        let submit = app.buttons["auth.login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: Timeout.short), "Login submit missing.")
        XCTAssertTrue(submit.isHittable, "Login submit not hittable.")
        submit.tap()
        dismissNotNowIfNeeded()
        XCTAssertTrue(app.descendants(matching: .any)["diary.summary.calories"]
                        .waitForExistence(timeout: Timeout.normal), "Diary did not load after sign-in.")
        dismissNotNowIfNeeded()
    }

    private func dismissNotNowIfNeeded() {
        let alertButton = app.alerts.buttons["Not Now"]
        if alertButton.waitForExistence(timeout: 1), alertButton.isHittable { alertButton.tap() }
        let fallback = app.buttons["Not Now"]
        if fallback.waitForExistence(timeout: 1), fallback.isHittable { fallback.tap() }
    }

    // MARK: - Element helpers (fail hard)

    @discardableResult
    private func requireElement(
        _ identifier: String,
        timeout: TimeInterval = Timeout.short
    ) -> XCUIElement {
        // AX frequently duplicates identifiers (container + control). Passive
        // existence/value/frame assertions only need one stable match.
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Required control '\(identifier)' did not appear.")
        return element
    }

    /// Every tappable control in these cases is a real Button. Query the typed
    /// collection and disambiguate to the first visible match (duplicate AX
    /// artifacts were proven in diagnostics).
    private func tapRequired(_ identifier: String, timeout: TimeInterval = Timeout.short) {
        let element = app.buttons[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Required button '\(identifier)' did not appear.")
        XCTAssertTrue(element.isHittable, "Required button '\(identifier)' is not hittable.")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @discardableResult
    private func requireButton(
        _ identifier: String,
        timeout: TimeInterval = Timeout.short
    ) -> XCUIElement {
        let element = app.buttons[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Required button '\(identifier)' did not appear.")
        return element
    }

    /// System Back is found by its real, non-empty AX label. The empty-
    /// identifier query was a wrong assumption in the first baseline run.
    private func requireSystemBack(_ message: String) -> XCUIElement {
        let buttons = app.navigationBars.buttons
        let knownLabels = ["Back", "Search", "Diary", "Log Food"]
        for index in 0..<buttons.count {
            let candidate = buttons.element(boundBy: index)
            if knownLabels.contains(candidate.label), candidate.isHittable {
                return candidate
            }
        }
        XCTFail(message)
        return buttons.firstMatch
    }

    /// Bounded scroll: at most `maxSwipes` swipes, waiting with a bounded
    /// predicate after each. No Thread.sleep and no unbounded polling.
    @discardableResult
    private func scrollToHittable(_ identifier: String, maxSwipes: Int = 4) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        var swipes = 0
        while swipes < maxSwipes && !element.isHittable {
            app.swipeUp()
            swipes += 1
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"),
                object: element
            )
            _ = XCTWaiter.wait(for: [hittable], timeout: 1)
        }
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.short),
                      "Required control '\(identifier)' did not appear after scrolling.")
        XCTAssertTrue(element.isHittable,
                      "Required control '\(identifier)' is not hittable after scrolling.")
        return element
    }

    // MARK: - Screenshots (real PNG, target-gated)

    private func capture(_ name: String, target: String) {
        // Mandatory target predicate: the named control must exist before the
        // shot is taken. (Existence, not hittability, also covers targets that
        // are legitimately scrolled out of view.)
        _ = requireElement(target)
        dismissNotNowIfNeeded()
        let shot = XCUIScreen.main.screenshot()
        let png = shot.image.pngData()
        XCTAssertNotNil(png, "Screenshot '\(name)' produced no PNG data.")
        if let png {
            let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47] // \x89PNG
            XCTAssertEqual(Array(png.prefix(4)), magic,
                           "Screenshot '\(name)' is not a real PNG (AX snapshot mislabeled as PNG?).")
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Cases

    /// Search TAB entry: selecting a result must show the detail on the CURRENT
    /// tab and Back must return to the SAME search screen with the query intact
    /// (not a silent jump to the Diary path).
    func testSearchTabResultDetailVisibleThenBackRetainsQuery() throws {
        try signIn()
        tapRequired("app.tab.search")
        XCTAssertTrue(app.tabBars.buttons["app.tab.search"].isSelected,
                      "Search tab did not become selected.")

        let field = requireElement("search.field")
        XCTAssertTrue(field.isHittable, "Search field is not hittable on the Search tab.")
        field.tap()
        field.typeText("apple")
        let result = requireElement("search.result.qa-apple", timeout: Timeout.normal)
        XCTAssertTrue(result.isHittable, "Search result is not hittable.")
        capture("01-search-tab-results", target: "search.result.qa-apple")

        result.tap()
        // Static text is passive: assert value/label, never isHittable.
        let detail = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@", "foodDetail.foodName")
        ).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: Timeout.normal),
                      "Detail name is missing on the current Search tab.")
        XCTAssertEqual(detail.label, "Native QA Apple",
                       "Detail did not load on the current Search tab after selecting a result.")
        capture("02-search-tab-detail-visible-on-current-tab", target: "foodDetail.foodName")

        requireSystemBack("No native Back on the pushed Search-tab detail.").tap()
        let returnedField = requireElement("search.field", timeout: Timeout.normal)
        XCTAssertEqual(returnedField.value as? String, "apple",
                       "Search query was not retained after Back from detail.")
        XCTAssertTrue(app.tabBars.buttons["app.tab.search"].isSelected,
                      "Back from detail did not return to the Search tab.")
        capture("03-search-tab-back-query-retained", target: "search.field")
    }

    /// Diary ADD FOOD push entry: one native Back, no redundant Cancel/header,
    /// detail context visible, and logging keeps the historical date + slot.
    func testDiaryAddFoodResultDetailBackAndHistoricalLogContext() throws {
        let health = try healthInfo()
        let historical = try XCTUnwrap(health["historical"] as? String,
                                       "Fixture did not publish a historical date.")

        try signIn()
        tapRequired("diary.previousDay")
        let dateButton = requireElement("diary.calendar")
        XCTAssertNotEqual(dateButton.label, "Today",
                          "Diary did not move off today before opening Add Food.")

        let addFood = scrollToHittable("diary.addFood.breakfast")
        addFood.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let field = requireElement("search.field", timeout: Timeout.normal)
        XCTAssertTrue(field.isHittable, "Shared Add Food search screen did not open.")
        XCTAssertFalse(app.descendants(matching: .any)["search.cancel"].exists,
                       "A redundant Add Food Cancel control was reintroduced.")
        _ = requireSystemBack("The Diary Add Food push must have one native Back.")

        field.tap()
        field.typeText("apple")
        let result = requireElement("search.result.qa-apple", timeout: Timeout.normal)
        capture("04-diary-addfood-results", target: "search.result.qa-apple")
        result.tap()
        let detail = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@", "foodDetail.foodName")
        ).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: Timeout.normal),
                      "Detail name is missing from the Diary Add Food push.")
        XCTAssertEqual(detail.label, "Native QA Apple",
                       "Detail did not load with the expected food from the Diary push.")
        let detailDate = requireElement("foodDetail.date")
        XCTAssertTrue(detailDate.exists, "Detail did not carry the origin date context.")
        capture("05-diary-addfood-detail-context", target: "foodDetail.date")

        requireSystemBack("No native Back from the Diary-pushed detail.").tap()
        let returnedField = requireElement("search.field", timeout: Timeout.normal)
        XCTAssertEqual(returnedField.value as? String, "apple",
                       "Query was lost when backing out of the Diary-pushed detail.")

        // Re-select and actually log; the POST must carry the historical date + slot.
        requireElement("search.result.qa-apple", timeout: Timeout.normal)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        requireElement("foodDetail.foodName", timeout: Timeout.normal)
        let submit = requireElement("foodDetail.submit")
        XCTAssertTrue(submit.isHittable, "Detail submit is not hittable.")
        submit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let loggedWithContext = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let state = try? self.mockState(),
                      let logs = state["logs"] as? [[String: Any]] else { return false }
                return logs.contains { log in
                    (log["id"] as? String ?? "").hasPrefix("new-log-")
                        && log["date"] as? String == historical
                        && (log["meal_slot"] as? String) == "breakfast"
                }
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loggedWithContext], timeout: Timeout.normal), .completed,
                       "Logging from the Diary Add Food push did not retain \(historical)/breakfast.")
        capture("06-diary-addfood-logged-historical-context", target: "diary.summary.calories")
    }

    /// Multiple query edits must keep the field anchored — no layout reflow or
    /// scroll jump. A completed response may legitimately remove an old result,
    /// so this case deliberately does NOT require any particular result row to
    /// survive across different queries; only field/scroll stability is asserted.
    func testSearchTypingKeepsFieldFrameAndScrollStable() throws {
        try signIn()
        tapRequired("app.tab.search")
        let field = requireElement("search.field")
        field.tap()
        field.typeText("ap")
        let fieldFrame0 = field.frame
        capture("07-search-typing-first-query", target: "search.field")

        field.typeText("pl")
        assertFieldFrameStable(field, against: fieldFrame0, phase: "second edit")
        field.typeText("e")
        assertFieldFrameStable(field, against: fieldFrame0, phase: "final edit")
        XCTAssertEqual(field.value as? String, "apple",
                       "The typed query was not retained in the search field.")

        capture("08-search-typing-field-stable", target: "search.field")
    }

    private func assertFieldFrameStable(
        _ field: XCUIElement,
        against original: CGRect,
        phase: String
    ) {
        let current = field.frame
        XCTAssertEqual(current.origin.x, original.origin.x, accuracy: 1.0,
                       "Search field moved horizontally during \(phase).")
        XCTAssertEqual(current.origin.y, original.origin.y, accuracy: 1.0,
                       "Search field jumped vertically during \(phase).")
        XCTAssertEqual(current.size.height, original.size.height, accuracy: 1.0,
                       "Search field resized during \(phase) (list-reflow jump).")
    }

    /// The field and scope tabs are ordinary scroll content, not a pinned
    /// header. With the keyboard reducing the visible area, an actual swipe
    /// must carry them OUT of the viewport (no longer hittable / maxY < 0).
    /// No threshold tuning: if the fixture cannot supply enough genuine rows,
    /// add bounded fixture content — never weaken this assertion.
    func testSearchFieldAndScopesScrollAwayNotPinned() throws {
        // Bounded fixture content, orthogonal to the assertion: enough real
        // result rows to make the ScrollView genuinely scrollable.
        try resetFixture(searchRows: 12)
        try signIn()
        tapRequired("app.tab.search")
        let scope = requireElement("search.scope")
        let field = requireElement("search.field")
        XCTAssertTrue(field.isHittable, "Search field is not hittable.")
        field.tap()
        field.typeText("a")
        XCTAssertTrue(requireElement("search.result.qa-scroll-0", timeout: Timeout.normal).exists,
                      "Fixture did not supply the bounded scrollable result rows.")
        capture("09-search-before-scroll", target: "search.result.qa-scroll-0")

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
                      "Keyboard did not appear; no genuine scroll room.")
        for _ in 0..<3 { app.swipeUp() }

        let fieldAway = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !field.isHittable || field.frame.maxY < 0 },
            object: nil
        )
        let scopeAway = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !scope.isHittable || scope.frame.maxY < 0 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [fieldAway], timeout: Timeout.short), .completed,
                       "Search field did not scroll out of the viewport (pinned).")
        XCTAssertEqual(XCTWaiter.wait(for: [scopeAway], timeout: Timeout.short), .completed,
                       "Scope tabs did not scroll out of the viewport (pinned).")
        capture("10-search-after-scroll-not-pinned", target: "search.field")
    }

    /// My Foods create actions live in the native "+" Menu (no inline buttons).
    /// Both entries perform real work; the real assistant dismissal control is
    /// `app.assistant.close` and closing it returns to the list.
    func testMyFoodsPlusMenuManualEditorAndAssistantClose() throws {
        try signIn()
        tapRequired("app.tab.library")
        tapRequired("library.foods")

        let plus = requireElement("library.add")
        XCTAssertTrue(plus.isHittable, "My Foods '+' menu is not hittable.")
        XCTAssertFalse(app.buttons["library.add.custom"].isHittable,
                       "Create choices are rendered inline instead of inside the + menu.")
        capture("11-myfoods-plus-menu-closed", target: "library.add")

        plus.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let manual = requireElement("library.add.custom")
        let ai = requireElement("library.createWithAI")
        XCTAssertTrue(manual.isHittable, "Manual create menu item is not hittable.")
        XCTAssertTrue(ai.isHittable, "Create with AI menu item is not hittable.")
        capture("12-myfoods-plus-menu-open", target: "library.add.custom")

        manual.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let nameField = requireElement("library.editor.name", timeout: Timeout.normal)
        XCTAssertTrue(nameField.isHittable, "Manual entry did not open the create editor.")
        capture("13-myfoods-manual-editor", target: "library.editor.name")

        // The editor hides the system Back; its real dismissal control is the
        // toolbar Cancel. A pristine editor must not raise a discard guard.
        tapRequired("diary.common.cancel")
        XCTAssertFalse(app.descendants(matching: .any)["library.editor.discard.confirm"].exists,
                       "A pristine create editor raised a discard confirmation.")
        let plusAgain = requireElement("library.add")
        plusAgain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        tapRequired("library.createWithAI")

        let composer = app.descendants(matching: .any)["assistant.composer"]
        let disabled = app.descendants(matching: .any)["assistant.status.disabled"]
        XCTAssertTrue(composer.waitForExistence(timeout: Timeout.normal)
                        || disabled.waitForExistence(timeout: Timeout.normal),
                      "Create with AI did not open the assistant.")
        capture("14-myfoods-assistant-open", target: "app.assistant.close")

        let close = app.buttons["app.assistant.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: Timeout.short),
                      "Assistant close control is missing.")
        XCTAssertTrue(close.isHittable, "Assistant close control is not hittable.")
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.app.buttons.matching(
                    NSPredicate(format: "identifier == %@", "app.assistant.close")
                ).count == 0
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: Timeout.normal), .completed,
                       "Assistant sheet was not dismissed via app.assistant.close.")
        let plusAfterClose = requireElement("library.add")
        XCTAssertTrue(plusAfterClose.isHittable,
                      "Closing the assistant did not return to the My Foods list.")
        capture("15-myfoods-after-assistant-close", target: "library.add")
    }

    /// The "+" menu and the root Back belong only to the list root. The pushed
    /// editor hides the system Back and dismisses through its real Cancel /
    /// discard-confirmation flow; unsaved work is never discarded naively.
    func testMyFoodsEditorCancelGuardAndRootControls() throws {
        try signIn()
        tapRequired("app.tab.library")
        tapRequired("library.foods")
        tapRequired("library.add")
        tapRequired("library.add.custom")

        let name = requireElement("library.editor.name", timeout: Timeout.normal)
        XCTAssertTrue(name.isHittable)
        name.tap()
        name.typeText("Dirty QA Food")
        XCTAssertFalse(app.buttons["library.add"].exists,
                       "The + menu persisted on the pushed editor.")
        XCTAssertFalse(app.buttons["library.back"].exists,
                       "The root-only Back persisted on the pushed editor.")
        capture("16-myfoods-editor-root-controls-hidden", target: "library.editor.name")

        // Real editor semantics: Cancel on a dirty editor raises the guard.
        tapRequired("diary.common.cancel")
        let confirm = requireElement("library.editor.discard.confirm")
        XCTAssertTrue(confirm.isHittable, "Dirty editor Cancel did not raise the discard guard.")
        capture("17-myfoods-editor-discard-guard", target: "library.editor.discard.confirm")

        // Cancelling the guard keeps the unsaved editor intact.
        let alertCancel = app.alerts.buttons["diary.common.cancel"].firstMatch
        XCTAssertTrue(alertCancel.waitForExistence(timeout: Timeout.short),
                      "The discard alert has no Cancel action.")
        XCTAssertTrue(alertCancel.isHittable, "The discard alert Cancel is not hittable.")
        alertCancel.tap()
        XCTAssertTrue(requireElement("library.editor.name").exists,
                      "Cancelling the discard guard closed the editor.")

        // Explicit discard is the only way back to the list.
        tapRequired("diary.common.cancel")
        tapRequired("library.editor.discard.confirm")
        let plus = requireElement("library.add")
        XCTAssertTrue(plus.isHittable, "+ menu did not return after discarding the editor.")
        XCTAssertTrue(requireElement("library.back").isHittable,
                      "Root Back did not return after discarding the editor.")
        capture("18-myfoods-list-root-controls-restored", target: "library.add")
    }

    /// Settings uses a native back arrow (not a modal Cancel). Back dismisses
    /// the tab to Diary without signing out, and the dirty-discard guard still
    /// fires before dismissal.
    func testSettingsBackDismissesWithoutSignOutAndKeepsGuard() throws {
        try signIn()
        tapRequired("app.tab.settings")
        XCTAssertTrue(requireElement("settings.sheet").exists, "Settings sheet missing.")
        let back = requireElement("settings.back")
        XCTAssertTrue(back.isHittable, "Settings native Back is not hittable.")
        XCTAssertFalse(app.buttons["settings.cancel"].exists,
                       "The removed Settings Cancel control was reintroduced.")
        capture("19-settings-native-back-arrow", target: "settings.back")

        let calories = requireElement("settings.goals.calories", timeout: Timeout.normal)
        calories.tap()
        calories.typeText("1")
        back.tap()
        let confirm = requireElement("settings.discard.confirm")
        XCTAssertTrue(confirm.isHittable, "Dirty Settings Back did not raise the discard guard.")
        capture("20-settings-discard-guard", target: "settings.discard.confirm")

        tapRequired("settings.discard.cancel")
        XCTAssertTrue(requireElement("settings.sheet").exists,
                      "Cancelling the discard dialog closed Settings.")
        back.tap()
        tapRequired("settings.discard.confirm")

        // Entry route: the Settings tab. Assert the view actually dismissed and
        // did not sign out; do not hard-code which persistent tab ends up selected.
        let settingsGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["settings.sheet"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settingsGone], timeout: Timeout.normal), .completed,
                       "Settings Back did not dismiss the Settings screen.")
        XCTAssertTrue(requireElement("diary.summary.calories", timeout: Timeout.normal).exists,
                      "Settings Back did not return to the signed-in content.")
        XCTAssertFalse(app.textFields["auth.login.username"].exists,
                       "Settings Back signed the user out instead of dismissing.")
        capture("21-settings-back-returned", target: "diary.summary.calories")
    }

    /// The nutrition report keeps its navigation Close but has no previous/next
    /// date arrows or date header; Close returns to the Diary.
    func testNutritionReportHasNoDateArrowsAndCloseReturnsDiary() throws {
        try signIn()
        tapRequired("diary.nutrition")
        XCTAssertTrue(requireElement("nutrition.details", timeout: Timeout.normal).exists,
                      "Nutrition report did not open.")

        let close = app.buttons["nutrition.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: Timeout.short),
                      "Nutrition retained Back/Close control is missing.")
        XCTAssertTrue(close.isHittable, "Nutrition retained Back/Close control is not hittable.")
        XCTAssertFalse(app.buttons["nutrition.previousDay"].exists,
                       "Nutrition previous-date arrow was reintroduced.")
        XCTAssertFalse(app.buttons["nutrition.nextDay"].exists,
                       "Nutrition next-date arrow was reintroduced.")
        XCTAssertFalse(app.descendants(matching: .any)["nutrition.date"].exists,
                       "Nutrition date header was reintroduced.")
        capture("22-nutrition-no-date-arrows", target: "nutrition.details")

        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(requireElement("diary.summary.calories", timeout: Timeout.normal).exists,
                      "Nutrition Close did not return to the Diary.")
        capture("23-nutrition-closed-back-to-diary", target: "diary.summary.calories")
    }
}

// MARK: - Synchronous loopback helper (uniquely named to avoid collisions with
// other UI test files in the same target).
private extension URLSession {
    func miniUXSynchronousData(
        from url: URL,
        request: URLRequest? = nil
    ) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = dataTask(with: request ?? URLRequest(url: url)) { data, response, error in
            if let error { result = .failure(error) }
            else if let data, let response { result = .success((data, response)) }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        switch result! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

#endif
