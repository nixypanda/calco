// ONE focused iPhone 13 mini case for the latest Recents batch removal.
//
// Reuses the existing bounded loopback fixture (NativeCompletionQAMockServer,
// 127.0.0.1:3932) and the same fake credentials/date/rows as the other focused
// QA files. No global fixture changes, no other UI test file is widened.
//
// The frozen SearchView/SearchViewModel/SearchModels removed every batch-
// selection surface (checkbox circles, review toolbar, submit sheet, batch
// state/methods/struct). Recents are now a plain coherent list; a row tap opens
// individual food detail and a quantity chip submits exactly ONE log intent.
// The underlying shared submit transport is deliberately NOT asserted here —
// only the visible Recents entries and the resulting single row/POST.
//
// Selectors are resolved from the frozen source (hashes recorded in the static
// handoff). Interactive controls are queried with typed, unique button IDs;
// passive text gets existence/label only and is never probed with isHittable.

#if os(iOS)

import Foundation
import XCTest

final class RecentBatchRemovalMiniQAUITests: XCTestCase {
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

    // MARK: - Bounded loopback fixture

    private func requireMockFixture() throws {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.recentQASyncData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer is not available at \(QA.baseURL).")
            throw NSError(domain: "RecentBatchRemovalQA", code: 1)
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
        let (_, response) = try URLSession.shared.recentQASyncData(from: request.url!, request: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "The bounded QA fixture rejected its reset request.")
    }

    private func fixtureHealth() throws -> [String: Any] {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, _) = try URLSession.shared.recentQASyncData(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Nonsecret counters and the new log's date/slot/amount only — never a
    /// credential or token is read, printed, or attached.
    private func fixtureState() throws -> [String: Any] {
        let url = URL(string: QA.baseURL + "/__qa/state")!
        let (data, response) = try URLSession.shared.recentQASyncData(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "The QA fixture state is unavailable.")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - App / helpers

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

    private func passive(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func requiredButton(_ identifier: String, timeout: TimeInterval = Timeout.short) -> XCUIElement {
        // Typed query + firstMatch tolerates duplicate AX artifacts; collect
        // the element before any tap.
        let element = app.buttons[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Required button '\(identifier)' did not appear.")
        XCTAssertTrue(element.isHittable, "Required button '\(identifier)' is not hittable.")
        return element
    }

    private func tapButton(_ identifier: String, timeout: TimeInterval = Timeout.short) {
        requiredButton(identifier, timeout: timeout)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func systemBack() -> XCUIElement {
        let buttons = app.navigationBars.buttons
        for index in 0..<buttons.count {
            let candidate = buttons.element(boundBy: index)
            if ["Back", "Search", "Diary"].contains(candidate.label), candidate.isHittable {
                return candidate
            }
        }
        XCTFail("No native Back on the pushed food detail.")
        return buttons.firstMatch
    }

    /// Real XCUIScreen PNG, target-gated and magic-byte checked.
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

    // MARK: - The single case

    func testRecentsHaveNoBatchUI_IndividualDetailAndOneQuickAddLog() throws {
        let baseline = try fixtureState()
        let baselineAttempts = (baseline["log_post_attempts"] as? Int) ?? -1
        let baselineCount = (baseline["log_count"] as? Int) ?? -1
        let expectedDate = try fixtureHealth()["today"] as? String

        try signIn()
        tapButton("app.tab.search")
        XCTAssertTrue(app.tabBars.buttons["app.tab.search"].isSelected,
                      "Search tab did not become selected.")
        XCTAssertTrue(passive("search.recents").waitForExistence(timeout: Timeout.normal),
                      "Recents list is missing on the Search tab.")

        // No batch-selection surface survives: no circles, no review toolbar,
        // no sheet. Two finite fixture rows remain as a coherent plain list.
        for removed in [
            "search.recent.select.product:qa-apple",
            "search.recent.select.product:qa-pear",
            "search.batch.reviewButton", "search.batch.submit", "search.batch.cancel",
            "search.recents.selectAll"
        ] {
            XCTAssertFalse(app.descendants(matching: .any)[removed].exists,
                           "Removed Recents batch entry '\(removed)' was reintroduced.")
        }
        let appleRow = requiredButton("search.recent.product:qa-apple")
        let pearRow = requiredButton("search.recent.product:qa-pear")
        XCTAssertEqual(appleRow.frame.minX, pearRow.frame.minX, accuracy: 1.0,
                       "Recents rows are not left-aligned.")
        XCTAssertEqual(appleRow.frame.width, pearRow.frame.width, accuracy: 1.0,
                       "Recents rows do not share one full-width geometry.")
        capture("RR01-recents-coherent-no-batch-ui", target: "search.recents")

        // Real row tap opens individual food detail with fixture context.
        appleRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let name = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "foodDetail.foodName", "Native QA Apple")
        ).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: Timeout.normal),
                      "Row tap did not open the individual food detail.")
        XCTAssertTrue(passive("foodDetail.date").exists,
                      "Detail did not carry the fixture date context.")
        capture("RR02-recent-row-opened-detail", target: "foodDetail.foodName")

        systemBack().tap()
        XCTAssertTrue(passive("search.recents").waitForExistence(timeout: Timeout.normal),
                      "Back from detail did not return to Recents.")
        XCTAssertTrue(requiredButton("search.recent.product:qa-apple").exists,
                      "The tapped recent row is gone after Back.")

        // One quantity chip: exactly ONE log intent/row, never a batch, and it
        // must NOT also trigger the enclosing row's detail navigation.
        tapButton("search.quickAdd.product:qa-apple.100.g")
        XCTAssertTrue(passive("search.quickAdd.added").waitForExistence(timeout: Timeout.normal),
                      "Quick add did not report success.")
        XCTAssertFalse(passive("foodDetail.foodName").exists,
                       "The quantity chip also triggered the parent row's detail tap.")
        capture("RR03-recent-quickadd-one-log", target: "search.quickAdd.added")

        let final = try fixtureState()
        XCTAssertEqual((final["log_post_attempts"] as? Int) ?? -1, baselineAttempts + 1,
                       "One quantity chip must issue exactly one log POST (not a batch).")
        XCTAssertEqual((final["log_count"] as? Int) ?? -1, baselineCount + 1,
                       "One quantity chip must create exactly one log row.")
        guard let logs = final["logs"] as? [[String: Any]], let created = logs.last else {
            return XCTFail("The fixture did not expose the newly created log row.")
        }
        XCTAssertEqual(created["date"] as? String, expectedDate,
                       "The log lost the fixture's today date.")
        XCTAssertEqual(created["meal_slot"] as? String, "breakfast",
                       "The log lost the recent item's Breakfast slot (originMealSlot is nil on Search).")
        XCTAssertEqual(created["amount"] as? String, "100", "The chip amount was not carried.")
        XCTAssertEqual(created["unit"] as? String, "g", "The chip unit was not carried.")
    }
}

// Uniquely named synchronous loopback helper (no collision with other UI files).
private extension URLSession {
    func recentQASyncData(
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
