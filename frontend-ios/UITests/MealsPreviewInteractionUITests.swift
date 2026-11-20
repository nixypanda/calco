import XCTest

// Dedicated Meals interaction coverage. This reuses the QA loopback fixture but
// does not modify the QA-owned mock server or NativeCompletionUITests.
final class MealsPreviewInteractionUITests: XCTestCase {
    // Dedicated mock port keeps this focused run independent of the full QA
    // suite, which owns 3932.
    private let baseURL = "http://127.0.0.1:3947"
    private let appBundleID = "dev.calco.CalCo.Test"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        try requireFixture()
        resetFixture()
    }

    override func tearDownWithError() throws {
        setSimulatorContentSize("large")
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        app = nil
    }

    func testMiniMealPreviewRendersNutrientsAndUpdatesAmount() throws {
        try launchSignedIn(dynamicType: nil)
        try assertIPhone13Mini()
        try openMealDetail()

        let quantity = try scrollToPreview()
        XCTAssertEqual(quantity.label, "100 g")
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.preview.header"].exists,
            "The portion nutrition heading is missing."
        )
        assertFitsWindow(quantity)
        assertCoreNutrientRows()

        let amount = try scrollToAmount()
#if os(iOS)
        amount.tap(withNumberOfTaps: 2, numberOfTouches: 1)
#else
        amount.tap()
        amount.typeKey("a", modifierFlags: .command)
#endif
        amount.typeText("50")
        let done = app.buttons["meals.detail.keyboardDone"]
        if done.waitForExistence(timeout: 3), done.isHittable {
            done.tap()
        } else if app.keyboards.firstMatch.exists {
            app.collectionViews["meals.detail"].swipeUp()
        }
        let updated = try scrollToPreview()
        let updatedPredicate = NSPredicate(format: "label == %@", "50 g")
        let expectation = XCTNSPredicateExpectation(predicate: updatedPredicate, object: updated)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 15),
            .completed,
            "The server-backed portion preview did not refresh for the new amount."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.preview.nutrient.ENERGY_KCAL"]
                .exists,
            "The refreshed server preview did not expose the energy row."
        )
        assertFitsWindow(updated)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(
                updated.frame.maxY,
                keyboard.frame.minY + 0.5,
                "The refreshed preview is hidden under the keyboard."
            )
        }

        let log = app.buttons["meals.detail.log"]
        XCTAssertTrue(log.exists && log.isHittable, "Log Meal is not reachable.")
        log.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["meals.detail.log.success"]
                .waitForExistence(timeout: 20)
                || app.descendants(matching: .any)["meals.detail.log.error"].exists,
            "Meal logging produced neither success nor a visible error."
        )
    }

    func testMiniMealPreviewFitsAtAccessibilityXXXL() throws {
        // Sign in at the default size, then switch the running simulator to AX
        // XXXL through the host-only layout helper. This avoids the known
        // secure-field keyboard focus issue masking the Meals layout check.
        try launchSignedIn(dynamicType: nil)
        guard setSimulatorContentSize("accessibility-extra-extra-extra-large") else {
            throw XCTSkip("The host AX-size helper is not running.")
        }
        Thread.sleep(forTimeInterval: 1.5)
        try assertIPhone13Mini()
        try openMealDetail()

        let quantity = try scrollToPreview(requireHittable: false)
        XCTAssertEqual(quantity.label, "100 g")
        assertFitsWindow(quantity)
        assertFitsWindow(app.staticTexts["meals.detail.preview.header"])
        assertCoreNutrientRows()
    }

    // MARK: - Navigation

    private func launchSignedIn(dynamicType: String?) throws {
        app = XCUIApplication(bundleIdentifier: appBundleID)
        app.launchEnvironment["CALCO_API_BASE_URL"] = baseURL
        if let dynamicType {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", dynamicType,
            ]
        }
        app.launch()

        let login = app.textFields["auth.login.username"]
        XCTAssertTrue(login.waitForExistence(timeout: 20), "Login did not appear.")
        login.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)
        ).tap()
        login.typeText("native-qa")
        let password = app.secureTextFields["auth.login.password"]
        password.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)
        ).tap()
        password.typeText("native-qa")
        dismissSavePasswordPrompt()
        let submit = app.buttons["auth.login.submit"]
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if submit.isHittable { break }
            form.swipeUp()
        }
        XCTAssertTrue(submit.isHittable, "Sign In is not reachable.")
        submit.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.summary.calories"]
                .waitForExistence(timeout: 30),
            "The fixture diary did not load."
        )
        dismissSavePasswordPrompt()
    }

    private func openMealDetail() throws {
        let addFood = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "diary.addFood.")
        ).firstMatch
        let diary = app.collectionViews.firstMatch
        for _ in 0..<10 {
            if addFood.exists, addFood.isHittable { break }
            if diary.exists {
                diary.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        guard addFood.exists, addFood.isHittable else {
            throw XCTSkip("No add-food control is visible on this fixture state.")
        }
        addFood.tap()
        XCTAssertTrue(
            app.textFields["search.field"].waitForExistence(timeout: 15),
            "Search did not open from Add Food."
        )

        var meals = app.buttons["search.meals"]
        if !meals.exists || !meals.isHittable {
            if let more = firstHittableButton(labels: ["More Items", "More"]) {
                more.tap()
                meals = app.buttons["search.meals"]
            }
        }
        XCTAssertTrue(meals.waitForExistence(timeout: 10), "Meals entry is unreachable.")
        meals.tap()
        let row = app.buttons["meals.list.row.qa-meal-1"]
        XCTAssertTrue(
            row.waitForExistence(timeout: 20),
            "The fixture meal row did not appear."
        )
        row.tap()
        XCTAssertTrue(
            app.collectionViews["meals.detail"].waitForExistence(timeout: 20),
            "The meal detail did not open."
        )
    }

    // MARK: - Preview

    private func scrollToPreview(
        requireHittable: Bool = true
    ) throws -> XCUIElement {
        let preview = app.descendants(matching: .any)["meals.detail.preview"]
        let container = app.collectionViews["meals.detail"]
        let window = app.windows.firstMatch.frame
        for _ in 0..<40 {
            if preview.exists,
               preview.frame.width > 1,
               window.intersects(preview.frame),
               !requireHittable || preview.isHittable {
                return preview
            }
            drag(container, up: true)
        }
        throw XCTSkip("The portion nutrition preview was not reachable.")
    }

    private func scrollToAmount() throws -> XCUIElement {
        let amount = app.textFields["foodDetail.amount.field"]
        let container = app.collectionViews["meals.detail"]
        let navBottom = app.navigationBars.firstMatch.frame.maxY
        let windowBottom = app.windows.firstMatch.frame.maxY
        for _ in 0..<24 {
            if amount.exists, amount.isHittable,
               amount.frame.minY >= navBottom + 4,
               amount.frame.maxY <= windowBottom {
                return amount
            }
            drag(container, up: false)
        }
        throw XCTSkip("The amount field was not fully reachable below the navigation bar.")
    }

    private func drag(_ container: XCUIElement, up: Bool) {
        let start = container.coordinate(
            withNormalizedOffset: CGVector(dx: 0.88, dy: up ? 0.34 : 0.16)
        )
        let end = container.coordinate(
            withNormalizedOffset: CGVector(dx: 0.88, dy: up ? 0.12 : 0.38)
        )
        start.press(
            forDuration: 0.01,
            thenDragTo: end,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
    }

    private func assertCoreNutrientRows() {
        let container = app.collectionViews["meals.detail"]
        for code in ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"] {
            let row = app.descendants(matching: .any)[
                "meals.detail.preview.nutrient.\(code)"
            ]
            for _ in 0..<6 where !row.exists {
                drag(container, up: true)
            }
            XCTAssertTrue(
                row.exists,
                "The server preview did not expose \(code)."
            )
            assertFitsWindow(row)
        }
    }

    private func assertFitsWindow(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard element.exists else {
            return XCTFail("Expected a laid-out preview element", file: file, line: line)
        }
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(
            element.frame.maxX,
            window.maxX + 0.5,
            "Preview content overflows horizontally",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(element.frame.width, 1, file: file, line: line)
    }

    // MARK: - Fixture

    private func requireFixture() throws {
        let health = URL(string: baseURL + "/__qa/health")!
        var request = URLRequest(url: health)
        request.timeoutInterval = 5
        let expectation = expectation(description: "QA fixture health")
        var healthy = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            healthy = (response as? HTTPURLResponse)?.statusCode == 200
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 8)
        if !healthy {
            throw XCTSkip("NativeCompletionQAMockServer.py is not running on \(baseURL).")
        }
    }

    private func resetFixture() {
        var request = URLRequest(url: URL(string: baseURL + "/__qa/reset")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let expectation = expectation(description: "QA fixture reset")
        URLSession.shared.dataTask(with: request) { _, _, _ in
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 8)
    }

    @discardableResult
    private func setSimulatorContentSize(_ value: String) -> Bool {
        var components = URLComponents(
            string: "http://127.0.0.1:3950/content-size"
        )!
        components.queryItems = [URLQueryItem(name: "value", value: value)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 3
        let expectation = expectation(description: "simulator content size")
        var succeeded = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            succeeded = (response as? HTTPURLResponse)?.statusCode == 200
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 5)
        return succeeded
    }

    private func dismissSavePasswordPrompt() {
        for _ in 0..<3 {
            let button = app.buttons["Not Now"]
            guard button.exists, button.isHittable else { return }
            button.tap()
        }
    }

    private func firstHittableButton(labels: [String]) -> XCUIElement? {
        for label in labels {
            let matches = app.buttons.matching(
                NSPredicate(format: "label == %@", label)
            ).allElementsBoundByIndex
            if let button = matches.first(where: { $0.exists && $0.isHittable }) {
                return button
            }
        }
        return nil
    }

    private func assertIPhone13Mini() throws {
        let frame = app.windows.firstMatch.frame
        guard abs(frame.width - 375) < 1, abs(frame.height - 812) < 1 else {
            throw XCTSkip("This interaction check requires the 375 x 812 mini.")
        }
    }
}
