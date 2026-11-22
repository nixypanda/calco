import Foundation
import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit
#endif

final class WebParityMiniQAUITests: XCTestCase {
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

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        return app
    }

    private func requireMockFixture() throws {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.synchronousData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer fixture is not available.")
            throw NSError(domain: "WebParityMiniQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture unavailable"])
        }
    }

    private func signIn() throws {
        app = makeApp()
        app.launch()
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        XCTAssertTrue(username.waitForExistence(timeout: Timeout.normal), "Login username field did not appear.")
        XCTAssertTrue(password.waitForExistence(timeout: Timeout.normal), "Login password field did not appear.")
        username.tap()
        username.typeText(QA.username)
        password.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        if !app.keyboards.firstMatch.exists { password.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short), "Keyboard did not appear.")
        password.typeText(QA.password)
        let submit = app.buttons["auth.login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: Timeout.short), "Login submit button did not appear.")
        XCTAssertTrue(submit.isHittable, "Login submit button is not hittable.")
        submit.tap()
        dismissPasswordPromptIfNeeded()
        XCTAssertTrue(app.descendants(matching: .any)["diary.summary.calories"].waitForExistence(timeout: Timeout.normal),
                      "Diary did not load after sign-in.")
        dismissPasswordPromptIfNeeded()
    }

    private func dismissPasswordPromptIfNeeded() {
        for _ in 0..<3 {
            let notNow = app.alerts.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 1), notNow.isHittable {
                notNow.tap()
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            let fallback = app.buttons["Not Now"]
            if fallback.waitForExistence(timeout: 1), fallback.isHittable {
                fallback.tap()
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            break
        }
    }

    private func capture(_ name: String) {
        dismissPasswordPromptIfNeeded()
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func requiredElement(_ identifier: String, timeout: TimeInterval = Timeout.short) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Required element '\(identifier)' did not appear.")
        return element
    }

    private func tapRequired(_ identifier: String, timeout: TimeInterval = Timeout.short) {
        let element = requiredElement(identifier, timeout: timeout)
        XCTAssertTrue(element.isHittable, "Required element '\(identifier)' is not hittable.")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// StaticText headings carry a label, not an accessibilityIdentifier, so
    /// match on label explicitly instead of the identifier subscript.
    private func labeledText(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func mockCookie() throws -> String {
        let url = URL(string: QA.baseURL + "/api/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": QA.username, "password": QA.password])
        let (data, response) = try URLSession.shared.synchronousData(from: url, request: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        _ = data
        let header = try XCTUnwrap(http.allHeaderFields["Set-Cookie"] as? String)
        return header.components(separatedBy: ";").first ?? header
    }

    private func seedCustomFood() throws -> String {
        let cookie = try mockCookie()
        let url = URL(string: QA.baseURL + "/api/foods/custom")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let body: [String: Any] = [
            "name": "Native QA Custom Food",
            "brand": "Native QA",
            "categories": ["Fixture"],
            "default_quantity": "100",
            "default_unit": "g",
            "nutrients": [
                ["code": "ENERGY_KCAL", "amount_per_100g": "100", "unit": "kcal"],
                ["code": "PROTEIN_G", "amount_per_100g": "1", "unit": "g"],
                ["code": "CARBS_G", "amount_per_100g": "20", "unit": "g"],
                ["code": "FAT_G", "amount_per_100g": "0.5", "unit": "g"],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try URLSession.shared.synchronousData(from: url, request: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["id"] as? String)
    }

    private func seedLog() throws -> String {
        let cookie = try mockCookie()
        let url = URL(string: QA.baseURL + "/api/logs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let logDate = String(format: "%04d-%02d-%02d",
                             components.year ?? 1970,
                             components.month ?? 1,
                             components.day ?? 1)
        let body: [String: Any] = [
            "log_date": logDate,
            "meal_slot": "breakfast",
            "item": ["type": "product", "id": "qa-apple", "name": "Native QA Apple"],
            "quantity": ["amount": "100", "unit": "g"],
            "notes": "QA edit-log fixture",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try URLSession.shared.synchronousData(from: url, request: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 201)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["id"] as? String)
    }

    func testDiaryEmptyLatestAddFood() throws {
        try signIn()
        requiredElement("diary.summary.calories")
        capture("01-diary")
    }

    func testCalendarOpened() throws {
        try signIn()
        tapRequired("diary.calendar")
        requiredElement("diary.datePicker")
        capture("02-calendar")
    }

    func testLibraryHub() throws {
        try signIn()
        tapRequired("app.tab.library")
        requiredElement("library.foods")
        requiredElement("library.meals")
        capture("03-library-hub")
    }

    func testMyFoodsCreateChoices() throws {
        try signIn()
        tapRequired("app.tab.library")

        // Persistent Library tab hub (not the contextual Library feature sheet).
        capture("03a-library-hub")
        XCTAssertTrue(app.buttons["app.tab.library"].isSelected, "Library tab is not selected.")
        XCTAssertTrue(labeledText("Library").waitForExistence(timeout: Timeout.short),
                      "Library hub heading is missing.")
        XCTAssertTrue(app.buttons["library.foods"].waitForExistence(timeout: Timeout.short),
                      "Library hub 'My Foods' entry is missing.")
        XCTAssertTrue(app.buttons["library.meals"].waitForExistence(timeout: Timeout.short),
                      "Library hub 'My Meals' entry is missing.")
        XCTAssertTrue(labeledText("My Meals").waitForExistence(timeout: Timeout.short),
                      "Library hub 'My Meals' label is missing.")

        // My Foods: the native Back control must return to the Library hub.
        tapRequired("library.foods")
        capture("03b-my-foods-list")
        let foodsBack = app.buttons["library.back"]
        XCTAssertTrue(foodsBack.waitForExistence(timeout: Timeout.short),
                      "My Foods native Back-to-Library control is missing.")
        XCTAssertTrue(foodsBack.isHittable, "My Foods native Back-to-Library control is not hittable.")
        XCTAssertTrue(labeledText("My Foods").waitForExistence(timeout: Timeout.short),
                      "My Foods list title is missing.")
        XCTAssertEqual(app.buttons["library.createWithAI"].label, "Create with AI")
        XCTAssertEqual(app.buttons["library.add.custom"].label, "Enter manually")
        foodsBack.tap()
        XCTAssertTrue(labeledText("Library").waitForExistence(timeout: Timeout.short),
                      "My Foods native Back did not return to the Library hub.")

        // My Meals: the native Back control must return to the hub as well.
        tapRequired("library.meals")
        capture("03d-my-meals-list")
        XCTAssertTrue(labeledText("My Meals").waitForExistence(timeout: Timeout.short),
                      "My Meals list title is missing.")
        let mealsBack = app.buttons["library.back"]
        XCTAssertTrue(mealsBack.waitForExistence(timeout: Timeout.short),
                      "My Meals native Back-to-Library control is missing.")
        XCTAssertTrue(mealsBack.isHittable, "My Meals native Back-to-Library control is not hittable.")
        mealsBack.tap()
        XCTAssertTrue(labeledText("Library").waitForExistence(timeout: Timeout.short),
                      "My Meals native Back did not return to the Library hub.")

        // Reopen My Foods for the AI-cancel -> manual-editor proof.
        tapRequired("library.foods")
        tapRequired("library.createWithAI")
        let assistantState = app.descendants(matching: .any)["assistant.composer"]
        let disabledState = app.descendants(matching: .any)["assistant.status.disabled"]
        XCTAssertTrue(assistantState.waitForExistence(timeout: Timeout.normal) || disabledState.waitForExistence(timeout: Timeout.normal),
                      "AI assistant did not open from My Foods.")
        // The assistant is a modal sheet. Its real cancellation control is
        // `app.assistant.close` ("Cancel request"); `assistant.cancel` exists
        // only in the in-flight sending row, which is absent when the fixture
        // reports AI drafting unavailable. Tapping the Library tab does not
        // dismiss the sheet, so do not fall back to it.
        let closeAssistant = app.buttons["app.assistant.close"]
        XCTAssertTrue(closeAssistant.waitForExistence(timeout: Timeout.short),
                      "Assistant sheet cancellation control 'app.assistant.close' did not appear.")
        XCTAssertTrue(closeAssistant.isHittable, "Assistant sheet cancellation control is not hittable.")
        closeAssistant.tap()

        // Re-evaluate the condition in a closure instead of an isHittable key
        // path on XCUIElement, which does not reliably re-poll the element.
        let modalDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.app.buttons.matching(NSPredicate(format: "identifier == %@", "app.assistant.close")).count == 0
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [modalDismissed], timeout: Timeout.normal), .completed,
                       "Assistant modal sheet was not dismissed after cancellation.")

        capture("03c-my-foods-after-cancel")
        let addCustomFood = app.buttons["library.add.custom"]
        XCTAssertTrue(addCustomFood.waitForExistence(timeout: Timeout.short),
                      "Manual choice 'library.add.custom' did not appear.")
        XCTAssertTrue(addCustomFood.isEnabled, "Manual choice 'library.add.custom' is not enabled.")
        let manualReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let button = self.app.buttons["library.add.custom"]
                return button.exists && button.isEnabled && button.isHittable
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [manualReady], timeout: Timeout.normal), .completed,
                       "Manual choice 'library.add.custom' did not become hittable after the sheet dismissed.")
        XCTAssertTrue(addCustomFood.isHittable, "Manual choice 'library.add.custom' is not hittable.")

        let aiChoice = app.buttons["library.createWithAI"]
        XCTAssertTrue(aiChoice.isHittable, "AI choice 'library.createWithAI' is not hittable.")

        // Real AX tap on the enabled, hittable button (not a coordinate guess
        // at a disabled or covered element) and assert the editor actually opens.
        addCustomFood.tap()
        let nameField = app.textFields["library.editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: Timeout.normal),
                      "Tapping 'library.add.custom' did not open the manual create editor.")
        capture("04-manual-editor-open")
    }

    func testCustomFoodDetail() throws {
        let foodID = try seedCustomFood()
        try signIn()
        tapRequired("app.tab.library")
        tapRequired("library.foods")
        let row = app.descendants(matching: .any)["library.row.\(foodID)"]
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.normal), "Seeded custom food row did not appear.")
        tapRequired("library.row.\(foodID)")
        requiredElement("library.detail")
        requiredElement("library.detail.edit")
        requiredElement("library.detail.delete")
        capture("05-custom-food-detail")
    }

    func testMealLibraryDetail() throws {
        try signIn()
        tapRequired("app.tab.library")
        tapRequired("library.meals")
        requiredElement("meals.list")

        // My Meals root owns the custom Back control.
        capture("06a-my-meals-root")
        let mealsRootBack = app.buttons["library.back"]
        XCTAssertTrue(mealsRootBack.waitForExistence(timeout: Timeout.short),
                      "My Meals root 'library.back' control is missing.")
        XCTAssertTrue(mealsRootBack.isHittable, "My Meals root 'library.back' is not hittable.")
        XCTAssertTrue(labeledText("My Meals").waitForExistence(timeout: Timeout.short),
                      "My Meals list title is missing.")

        let row = app.descendants(matching: .any)["meals.list.row.qa-meal-1"]
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.normal), "Fixture meal row did not appear.")
        tapRequired("meals.list.row.qa-meal-1")
        requiredElement("meals.detail")
        for _ in 0..<4 where !app.descendants(matching: .any)["meals.detail.delete"].isHittable {
            app.swipeUp()
        }
        requiredElement("meals.detail.edit")
        requiredElement("meals.detail.delete")

        // Guard: the root-only custom Back must not persist on the pushed
        // detail; exactly one native NavigationStack Back remains and pops.
        XCTAssertFalse(app.buttons["library.back"].exists,
                       "Custom 'library.back' persisted on pushed meal detail.")
        let systemBacks = app.navigationBars.buttons.matching(
            NSPredicate(format: "NOT (identifier BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)",
                        "meals.detail", "library")
        )
        XCTAssertEqual(systemBacks.count, 1,
                       "Expected exactly one native Back on meal detail, got \(systemBacks.count).")
        let systemBack = systemBacks.firstMatch
        XCTAssertTrue(systemBack.isHittable, "Native Back on meal detail is not hittable.")
        capture("06b-meal-detail-one-back")
        systemBack.tap()

        XCTAssertTrue(labeledText("My Meals").waitForExistence(timeout: Timeout.short),
                      "Native Back did not return to My Meals.")
        XCTAssertTrue(app.buttons["library.back"].waitForExistence(timeout: Timeout.short),
                      "My Meals root Back did not reappear after pop.")
        app.buttons["library.back"].tap()
        XCTAssertTrue(labeledText("Library").waitForExistence(timeout: Timeout.short),
                      "My Meals root Back did not return to the Library hub.")
        capture("06c-library-hub-after-meal-back")
    }

    func testEditLog() throws {
        _ = try seedLog()
        try signIn()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "diary.log.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.normal), "Seeded diary log row did not appear.")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        requiredElement("diary.editor.header")
        requiredElement("diary.editor.save")
        requiredElement("diary.editor.delete")
        capture("07-edit-log")
    }

    func testSettings() throws {
        try signIn()
        let settingsTab = app.tabBars.buttons["app.tab.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: Timeout.short), "Settings tab did not appear.")
        settingsTab.tap()
        requiredElement("settings.sheet")
        capture("08-settings")
    }

    func testSearch() throws {
        try signIn()
        tapRequired("app.tab.search")
        requiredElement("search.field")
        capture("09-search")
    }
}

extension URLSession {
    struct SyncResult { let data: Data; let response: URLResponse }
    func synchronousData(from url: URL, request: URLRequest? = nil) throws -> (Data, URLResponse) {
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
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}
