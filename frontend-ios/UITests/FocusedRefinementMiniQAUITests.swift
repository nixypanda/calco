// Focused, bounded iPhone 13 mini QA for the latest user refinements.
//
// THREE cases only (not the full suite, not the old 8/9 baseline, no matrix):
//   1. Search: removed AI / barcode-assistant / Library(Meals) entries are
//      absent; Recents render as a coherent list with the SAME row geometry as
//      regular text results (multiple finite fixture rows + screenshots);
//      a typed barcode that is NOT FOUND exposes no assistant entry.
//   2. Diary: date prev/next keeps loaded content mounted (no skeleton swap),
//      rapid navigation is safe, final date/rows are correct, stale date-scoped
//      actions recover. The Daily Brief hierarchy is verified unchanged.
//   3. API Keys: root uses Back (not Done), the create sheet has ONE bottom
//      "Create API Key" and NO visible Done, the Back guard clears the draft,
//      a single FAKE create increments the fixture count, the one-time secret
//      is never printed/captured, and its native Back clears the secret.
//
// All selectors were resolved from the FROZEN source before this file was
// compiled. Identifiers and visible labels are deliberately NOT conflated:
// `settings.apiKeys.secret.done` has the visible label "Back".
//
// Typed queries are used for interactive controls (app.buttons[..].firstMatch);
// passive static text / progress / containers only get existence/value/label
// assertions and are NEVER probed with isHittable. Duplicate AX artifacts are
// tolerated by firstMatch; required buttons are collected before any tap.

#if os(iOS)

import Foundation
import XCTest

final class FocusedRefinementMiniQAUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum QA {
        static let baseURL = "http://127.0.0.1:3932"
        static let fixtureMarker = "native-completion-qa"
        static let username = "native-qa"
        static let password = "native-qa"
        static let fakeKeyName = "QA Focused Key"
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

    // MARK: - Bounded loopback fixture plumbing

    private func requireMockFixture() throws {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.focusedQASyncData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer is not available at \(QA.baseURL).")
            throw NSError(domain: "FocusedRefinementQA", code: 1)
        }
    }

    private func resetFixture() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let body: [String: Any] = [
            "today": formatter.string(from: Date()),
            "seed_logs": true,
            "log_post": "success",
            "assistant_enabled": false,
        ]
        var request = URLRequest(url: URL(string: QA.baseURL + "/__qa/reset")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try URLSession.shared.focusedQASyncData(from: request.url!, request: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "The bounded QA fixture rejected its reset request.")
    }

    /// Only nonsecret counters are ever read. The created token/secret is never
    /// fetched, logged, or attached.
    private func fixtureState() throws -> [String: Any] {
        let url = URL(string: QA.baseURL + "/__qa/state")!
        let (data, response) = try URLSession.shared.focusedQASyncData(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "The QA fixture state is unavailable.")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - App / sign-in

    private func signIn() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        app.launch()

        let username = app.textFields["auth.login.username"].firstMatch
        let password = app.secureTextFields["auth.login.password"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: Timeout.normal), "Login username missing.")
        XCTAssertTrue(password.waitForExistence(timeout: Timeout.normal), "Login password missing.")
        username.tap()
        username.typeText(QA.username)
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
                      "Keyboard missing on password.")
        password.typeText(QA.password)
        let submit = app.buttons["auth.login.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: Timeout.short), "Login submit missing.")
        XCTAssertTrue(submit.isHittable, "Login submit not hittable.")
        submit.tap()
        dismissNotNowIfNeeded()
        XCTAssertTrue(passive("diary.summary.calories").waitForExistence(timeout: Timeout.normal),
                      "Diary did not load after fixture sign-in.")
        dismissNotNowIfNeeded()
    }

    private func dismissNotNowIfNeeded() {
        let alertButton = app.alerts.buttons["Not Now"].firstMatch
        if alertButton.waitForExistence(timeout: 1), alertButton.isHittable { alertButton.tap() }
        let fallback = app.buttons["Not Now"].firstMatch
        if fallback.waitForExistence(timeout: 1), fallback.isHittable { fallback.tap() }
    }

    // MARK: - Typed element helpers

    /// Passive nodes (static text, progress, containers): existence/value/label
    /// only. isHittable is intentionally never called on these.
    private func passive(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func button(_ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    @discardableResult
    private func requireButton(_ identifier: String, timeout: TimeInterval = Timeout.short) -> XCUIElement {
        let element = button(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Required button '\(identifier)' did not appear.")
        XCTAssertTrue(element.isHittable, "Required button '\(identifier)' is not hittable.")
        return element
    }

    private func tapButton(_ identifier: String, timeout: TimeInterval = Timeout.short) {
        requireButton(identifier, timeout: timeout)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Date controls may be exposed either under their own identifiers or with
    /// the inherited `diary.dateNavigation` container identifier plus a real
    /// label. `diary.calendar` is ALSO the toolbar button, so label matching is
    /// required to pick the centered date trigger. Collect candidates, then
    /// tap the first hittable one (never guess a duplicate).
    private func dateButton(_ identifier: String, label: String) -> XCUIElement {
        let exact = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", identifier, label)
        ).firstMatch
        if exact.waitForExistence(timeout: 2), exact.isHittable { return exact }
        let inherited = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "diary.dateNavigation", label)
        ).firstMatch
        if inherited.waitForExistence(timeout: 2), inherited.isHittable { return inherited }
        let direct = button(identifier)
        XCTAssertTrue(direct.waitForExistence(timeout: Timeout.short),
                      "Date control '\(label)' is missing (also tried '\(identifier)').")
        XCTAssertTrue(direct.isHittable, "Date control '\(label)' is not hittable.")
        return direct
    }

    /// Bounded scroll (no sleeps / unbounded polling) for controls that start
    /// below the fold on the mini.
    @discardableResult
    private func scrollToHittable(
        _ identifier: String,
        maxSwipes: Int = 6,
        swipeUp: Bool = true
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        var swipes = 0
        while swipes < maxSwipes && !element.isHittable {
            if swipeUp { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
            let hit = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"), object: element
            )
            _ = XCTWaiter.wait(for: [hit], timeout: 1)
        }
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.short),
                      "Control '\(identifier)' is missing after scrolling.")
        XCTAssertTrue(element.isHittable,
                      "Control '\(identifier)' is not hittable after scrolling.")
        return element
    }

    /// Real XCUIScreen PNG, gated on a target predicate and magic-byte checked.
    private func capture(_ name: String, target: String) {
        XCTAssertTrue(passive(target).waitForExistence(timeout: Timeout.short),
                      "Screenshot target '\(target)' missing for '\(name)'.")
        dismissNotNowIfNeeded()
        let shot = XCUIScreen.main.screenshot()
        let png = shot.image.pngData()
        XCTAssertNotNil(png, "No PNG data for '\(name)'.")
        if let png {
            let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            XCTAssertEqual(Array(png.prefix(4)), magic, "'\(name)' is not a real PNG.")
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Case 1: Search entries + coherent recents + typed barcode

    func testSearchRemovedEntriesCoherentRecentsAndTypedBarcodeNotFound() throws {
        try signIn()
        tapButton("app.tab.search")
        XCTAssertTrue(app.tabBars.buttons["app.tab.search"].isSelected,
                      "Search tab did not become selected.")
        XCTAssertTrue(passive("search.field").waitForExistence(timeout: Timeout.short),
                      "Search field is missing.")

        // Removed product entries: assert by IDENTIFIER and by visible LABEL.
        // `search.meals` was the Library/Meals entry, `search.assistant*` the
        // AI-lookup menu, `search.barcode.assistant` the barcode SCAN/assistant
        // entry. None may be rendered on the shared search screen.
        let removedIDs = [
            "search.meals", "search.assistant", "search.assistant.customFood",
            "search.assistant.adHocLog", "search.barcode.assistant",
        ]
        for identifier in removedIDs {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].exists,
                           "Removed search entry '\(identifier)' was reintroduced.")
        }
        // "Library" is deliberately NOT in this list: the tab bar owns that
        // legitimate visible label. The removed entry is covered by
        // `search.meals` (absence) and the unique "Meals" label below.
        let removedLabels = ["AI food draft", "Meals",
                             "Draft food with assistant", "Draft custom food", "Draft a meal log"]
        for label in removedLabels {
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", label)).count, 0,
                           "A removed search entry is still visible with label '\(label)'.")
        }

        // Recents: the fixture supplies exactly two finite valid rows.
        XCTAssertTrue(passive("search.recents").waitForExistence(timeout: Timeout.normal),
                      "Recents list is missing on the empty Search screen.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Recent foods"))
                        .firstMatch.exists, "Recents section title is missing.")
        // RecentLogItem.id prefixes the item type: "product:<fixture id>".
        let apple = requireButton("search.recent.product:qa-apple")
        let pear = requireButton("search.recent.product:qa-pear")
        let appleSelect = requireButton("search.recent.select.product:qa-apple")
        XCTAssertTrue(requireButton("search.recent.select.product:qa-pear").exists,
                      "Recent row select control is missing.")

        // Coherent list: identical leading edge/width, consistent vertical order
        // and a bounded row pitch — the same geometry used by regular results.
        XCTAssertEqual(apple.frame.minX, pear.frame.minX, accuracy: 1.0,
                       "Recent rows are not left-aligned with each other.")
        XCTAssertEqual(apple.frame.width, pear.frame.width, accuracy: 1.0,
                       "Recent rows do not share one full-width geometry.")
        let pitch = pear.frame.minY - apple.frame.minY
        XCTAssertGreaterThan(pitch, 40, "Recent rows overlap.")
        XCTAssertLessThan(pitch, 260, "Recent rows have an inconsistent gap/separator.")
        // The select control sits at the row's leading padding edge; the name
        // button is intentionally inset by the checkbox, so leading-edge parity
        // with a regular result is measured on the row's first control.
        let recentLeading = appleSelect.frame.minX
        capture("FR01-search-recents-coherent-list", target: "search.recents")

        // Regular results use the same row geometry.
        let field = passive("search.field")
        field.tap()
        field.typeText("apple")
        let result = requireButton("search.result.qa-apple", timeout: Timeout.normal)
        XCTAssertEqual(result.frame.minX, recentLeading, accuracy: 2.0,
                       "Recents are not styled like regular result rows (leading edge).")
        capture("FR02-search-regular-results", target: "search.result.qa-apple")

        // Typed barcode that is NOT FOUND must not surface any assistant entry.
        selectScope("Barcode")
        let barcodeField = app.textFields["search.barcode.field"].firstMatch
        XCTAssertTrue(barcodeField.waitForExistence(timeout: Timeout.short),
                      "Barcode scope field is missing.")
        barcodeField.tap()
        barcodeField.typeText("9999999999999")
        tapButton("search.barcode.lookupButton")
        XCTAssertTrue(passive("search.barcode.notFound").waitForExistence(timeout: Timeout.normal),
                      "Typed barcode did not reach the fixture not-found state.")
        XCTAssertFalse(app.descendants(matching: .any)["search.barcode.assistant"].exists,
                       "Barcode SCAN/assistant entry was reintroduced on not-found.")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == %@", "Draft food with assistant")
        ).count, 0, "A barcode assistant button is visible on not-found.")
        capture("FR03-search-barcode-notfound-no-assistant", target: "search.barcode.notFound")
    }

    private func selectScope(_ label: String) {
        let segmented = app.segmentedControls["search.scope"].firstMatch
        if segmented.waitForExistence(timeout: Timeout.short), segmented.buttons[label].exists {
            segmented.buttons[label].tap()
            return
        }
        let fallback = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: Timeout.short),
                      "Scope segment '\(label)' is missing.")
        XCTAssertTrue(fallback.isHittable, "Scope segment '\(label)' is not hittable.")
        fallback.tap()
    }

    /// The centered date control is looked up FRESH each time: caching an
    /// element bound to `label == "Today"` goes stale the moment the date
    /// changes, and XCTest then fails with "no matching snapshot".
    private func todayControlExists() -> Bool {
        let nav = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "diary.dateNavigation", "Today")
        ).firstMatch
        if nav.exists { return true }
        return app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "diary.calendar", "Today")
        ).firstMatch.exists
    }

    // MARK: - Case 2: Diary date navigation, mounted content, Daily Brief

    func testDiaryDateChangesKeepContentMountedAndRapidNavigationSafe() throws {
        try signIn()

        // Target-gated evidence is captured BEFORE the assertions so a genuine
        // failure still leaves a meaningful destination PNG in the result bundle.
        capture("FR04-daily-brief-state-before-checks", target: "diary.dateNavigation")

        // Daily Brief hierarchy (reference 52/32 bold figures, 10/7 bars,
        // existing palette and meal art is preserved by the frozen source;
        // AX cannot read point sizes, so verify the unchanged node structure).
        // The remaining figure is exposed as its caption static text, not as a
        // standalone container node.
        XCTAssertTrue(passive("diary.summary.calories").exists, "Calorie brief missing.")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label == %@", "remaining")
        ).firstMatch.exists, "Remaining brief caption ('remaining') is missing.")
        // The custom ProgressViewStyle exposes its AX identifier either under
        // its own id or inherited from the enclosing `diary.summary.calories`.
        let calorieBar = app.descendants(matching: .any)["diary.summary.progress"].firstMatch
        let inheritedBar = app.progressIndicators.matching(
            NSPredicate(format: "identifier == %@", "diary.summary.calories")
        ).firstMatch
        XCTAssertTrue(calorieBar.exists || inheritedBar.exists,
                      "Calorie progress bar missing.")
        for id in ["diary.summary.protein", "diary.summary.carbs", "diary.summary.fat"] {
            XCTAssertTrue(passive(id).exists, "Macro column \(id) missing.")
        }
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Protein, carbs and fat")).count, 0,
                       "Redundant Macros heading was reintroduced.")

        let previous = dateButton("diary.previousDay", label: "Previous day")
        let next = dateButton("diary.nextDay", label: "Next day")
        let centered = dateButton("diary.calendar", label: "Today")
        XCTAssertLessThan(previous.frame.maxX, centered.frame.minX,
                          "Previous-day control is not left of the date control.")
        XCTAssertLessThan(centered.frame.maxX, next.frame.minX,
                          "Next-day control is not right of the date control.")

        let beforeFetch = (passive("diary.fetchCompletionCount").value as? String).flatMap(Int.init) ?? -1

        // Rapid prev / prev / next: bounded taps, no sleep. The loaded brief and
        // cards must stay mounted (no `diary.loading` skeleton swap) throughout.
        previous.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(passive("diary.loading").exists,
                       "A full-screen loading skeleton replaced the retained content.")
        XCTAssertTrue(passive("diary.summary.calories").exists,
                       "Daily Brief was unmounted during the date change.")
        previous.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(passive("diary.loading").exists,
                       "A loading skeleton appeared during rapid date navigation.")
        XCTAssertTrue(passive("diary.summary.calories").exists,
                       "Content was lost during rapid date navigation.")

        // Wait for a real fetch to resolve after the last tap, then assert the
        // final date/rows are coherent (two previous + one next == yesterday).
        let fetchDone = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let raw = self.passive("diary.fetchCompletionCount").value as? String,
                      let count = Int(raw) else { return false }
                return count >= beforeFetch + 1
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [fetchDone], timeout: Timeout.normal), .completed,
                       "The date-change fetch did not complete.")
        XCTAssertFalse(todayControlExists(), "Rapid navigation did not leave Today.")
        XCTAssertTrue(passive("diary.log.hist-log-001").waitForExistence(timeout: Timeout.normal),
                      "The correct historical rows were not installed after the date change.")

        // Stale date-scoped actions recover once the new day is installed.
        let addFood = scrollToHittable("diary.addFood.breakfast")
        XCTAssertTrue(addFood.isEnabled, "Add Food stayed disabled after the correct date loaded.")
        capture("FR05-diary-after-rapid-date-navigation", target: "diary.dateNavigation")

        // The Add Food check scrolled the date row off-screen. Bring it back
        // and re-resolve the button so the coordinate tap lands on Next day.
        _ = scrollToHittable("diary.dateNavigation", swipeUp: false)
        let nextAgain = dateButton("diary.nextDay", label: "Next day")
        nextAgain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let backToday = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.todayControlExists() }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [backToday], timeout: Timeout.short), .completed,
                       "Next-day did not return to Today.")
        XCTAssertTrue(passive("diary.summary.calories").exists,
                       "Daily Brief was unmounted on the return to Today.")
    }

    // MARK: - Case 3: API keys root / create form / one-time secret

    func testAPIKeysBackSingleBottomCreateFakeFlowAndSecretCleanup() throws {
        let countBefore = (try fixtureState()["api_key_count"] as? Int) ?? -1
        try signIn()
        tapButton("app.tab.settings")
        XCTAssertTrue(passive("settings.sheet").waitForExistence(timeout: Timeout.normal),
                      "Settings sheet did not open.")
        scrollToHittable("settings.apiKeys.entry")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(passive("settings.apiKeys").waitForExistence(timeout: Timeout.normal),
                      "API Keys screen did not open.")

        // Root: Back arrow, not Done. The root "+" create entry is legitimate.
        let rootClose = requireButton("settings.apiKeys.close")
        XCTAssertEqual(rootClose.label, "Back", "Root API Keys close control must read Back.")
        XCTAssertTrue(requireButton("settings.apiKeys.create").isHittable,
                      "The root create (+) entry is missing.")
        assertNoVisibleDoneControl()
        capture("FR06-apikeys-root-back-and-plus", target: "settings.apiKeys")

        // Create form: ONE bottom Create, no visible Done toolbar action.
        tapButton("settings.apiKeys.create")
        XCTAssertTrue(passive("settings.apiKeys.create.name").waitForExistence(timeout: Timeout.normal),
                      "Create form did not open.")
        let formBack = requireButton("settings.apiKeys.create.cancel")
        XCTAssertEqual(formBack.label, "Back", "Create form cancel must read Back.")
        let bottomCreate = requireButton("settings.apiKeys.create.submitBottom")
        XCTAssertEqual(bottomCreate.label, "Create API Key",
                       "Bottom create action has the wrong visible label.")
        XCTAssertFalse(app.buttons["settings.apiKeys.create.submit"].exists,
                       "A legacy inline create submit was reintroduced.")
        XCTAssertFalse(app.buttons["settings.apiKeys.create.keyboard.done"].exists,
                       "A keyboard Done create control was reintroduced.")
        assertNoVisibleDoneControl()

        // Capture the FORM before any secret exists (no sensitive pixels).
        capture("FR07-apikeys-create-form-before-secret", target: "settings.apiKeys.create.submitBottom")

        // Back guard: backing out clears the draft rather than keeping it.
        let nameField = app.textFields["settings.apiKeys.create.name"].firstMatch
        nameField.tap()
        nameField.typeText(QA.fakeKeyName)
        formBack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(passive("settings.apiKeys").waitForExistence(timeout: Timeout.short),
                      "Create form Back did not return to the API Keys root.")
        tapButton("settings.apiKeys.create")
        let reopenedName = app.textFields["settings.apiKeys.create.name"].firstMatch
        XCTAssertTrue(reopenedName.waitForExistence(timeout: Timeout.normal),
                      "Create form did not reopen.")
        XCTAssertEqual(reopenedName.value as? String, "",
                       "Create form Back guard did not clear the draft.")

        // One FAKE create only: single submit, single POST, count +1.
        reopenedName.tap()
        reopenedName.typeText(QA.fakeKeyName)
        tapButton("settings.apiKeys.create.submitBottom")
        XCTAssertTrue(passive("settings.apiKeys.secret.warning").waitForExistence(timeout: Timeout.normal),
                      "One-time secret reveal did not appear after the fake create.")
        let countAfter = (try fixtureState()["api_key_count"] as? Int) ?? -1
        XCTAssertEqual(countAfter, countBefore + 1,
                       "The fake create must issue exactly one API request (count +1).")

        // Obscure first so no screenshot or log can ever contain the secret.
        let hide = requireButton("settings.apiKeys.secret.hide")
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(passive("settings.apiKeys.secret.hidden").waitForExistence(timeout: Timeout.short),
                      "The secret could not be obscured before capture.")

        // The reveal's dismiss control is labelled Back even though its
        // identifier ends in `.done` — assert the LABEL, never the ID's absence.
        let done = requireButton("settings.apiKeys.secret.done")
        XCTAssertEqual(done.label, "Back",
                       "One-time secret dismiss must read Back, not Done.")
        assertNoVisibleDoneControl()
        capture("FR08-apikeys-secret-obscured-back", target: "settings.apiKeys.secret.hidden")

        // Native back performs finishSecretReveal(): secret cleared, root shown.
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(passive("settings.apiKeys").waitForExistence(timeout: Timeout.normal),
                      "Secret Back did not return to the API Keys root.")
        XCTAssertFalse(passive("settings.apiKeys.secret").exists,
                       "One-time secret was not cleared by finishSecretReveal().")
        XCTAssertFalse(passive("settings.apiKeys.secret.hidden").exists,
                       "Secret reveal UI survived dismissal.")
        capture("FR09-apikeys-secret-cleared", target: "settings.apiKeys")
    }

    /// Checks the NAVIGATION/TOOLBAR area for a visible "Done" action. Keyboard
    /// keys are deliberately excluded (a keyboard "Done" return key is not an
    /// app toolbar action and must not fail this assertion).
    private func assertNoVisibleDoneControl() {
        let navDone = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == %@", "Done")
        )
        XCTAssertEqual(navDone.count, 0, "A visible navigation Done button was reintroduced.")
        let toolbarDone = app.toolbars.buttons.matching(
            NSPredicate(format: "label == %@", "Done")
        )
        XCTAssertEqual(toolbarDone.count, 0, "A visible toolbar Done button was reintroduced.")
    }
}

// MARK: - Uniquely named synchronous loopback helper (no global collisions).
private extension URLSession {
    func focusedQASyncData(
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
