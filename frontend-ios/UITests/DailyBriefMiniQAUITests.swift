// ONE focused iPhone 13 mini QA case for the final Daily Brief Diary screen.
//
// Selector inventory was resolved against captured AX BEFORE this compile:
//   * date controls: Buttons, identifier `diary.dateNavigation`, labels
//     "Previous day" / "Today" / "Next day" (container overrides child IDs)
//   * calorie captions/values: passive StaticTexts sharing
//     `diary.summary.calories`; progress is a ProgressIndicator (passive)
//   * macro columns: passive combined elements `diary.summary.protein/carbs/fat`
//   * buttons: `diary.summary.macroMode`, `diary.manageSlots`, `diary.editGoals`,
//     `diary.nutrition`, `diary.addFood.breakfast`, `settings.back`,
//     `nutrition.close` — all queried via typed app.buttons[...].firstMatch
// Only buttons get isHittable assertions; passive nodes use existence/value/label.

#if os(iOS)

import Foundation
import UIKit
import XCTest

final class DailyBriefMiniQAUITests: XCTestCase {
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

    // MARK: - Fixture

    private func requireMockFixture() throws {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.dailyBriefFinalSyncData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer fixture is not available.")
            throw NSError(domain: "DailyBriefFinalQA", code: 1)
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
        let (_, response) = try URLSession.shared.dailyBriefFinalSyncData(from: request.url!, request: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "Fixture reset failed.")
    }

    // MARK: - App / typed helpers

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
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short), "Keyboard missing.")
        password.typeText(QA.password)
        let submit = app.buttons["auth.login.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: Timeout.short), "Submit missing.")
        XCTAssertTrue(submit.isHittable, "Submit not hittable.")
        submit.tap()
        dismissNotNowIfNeeded()
        XCTAssertTrue(passive("diary.summary.calories").waitForExistence(timeout: Timeout.normal),
                      "Diary Daily Brief did not load.")
        dismissNotNowIfNeeded()
    }

    private func dismissNotNowIfNeeded() {
        let alertButton = app.alerts.buttons["Not Now"].firstMatch
        if alertButton.waitForExistence(timeout: 1), alertButton.isHittable { alertButton.tap() }
        let fallback = app.buttons["Not Now"].firstMatch
        if fallback.waitForExistence(timeout: 1), fallback.isHittable { fallback.tap() }
    }

    /// Passive nodes (static text, progress, containers): existence/value/label
    /// only. Never call isHittable on these.
    private func passive(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Interactive nodes are real Buttons. firstMatch is required because AX
    /// duplicates identifiers (container + control) on this screen.
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
        let element = requireButton(identifier, timeout: timeout)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func dateControl(_ label: String) -> XCUIElement {
        let element = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "diary.dateNavigation", label)
        ).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.short),
                      "Date control '\(label)' is missing.")
        return element
    }

    /// Bounded scroll in either direction; no sleeps or unbounded polling.
    @discardableResult
    private func scrollToHittable(
        _ identifier: String,
        maxSwipes: Int = 6,
        swipeUp: Bool = true
    ) -> XCUIElement {
        let element = button(identifier)
        var swipes = 0
        while swipes < maxSwipes && !element.isHittable {
            if swipeUp { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
            let hit = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"),
                object: element
            )
            _ = XCTWaiter.wait(for: [hit], timeout: 1)
        }
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.short),
                      "Button '\(identifier)' is missing after scrolling.")
        XCTAssertTrue(element.isHittable,
                      "Button '\(identifier)' is not hittable after scrolling.")
        return element
    }

    /// Real screen PNG, gated on a target predicate, magic-byte verified.
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

    // MARK: - Single case

    func testDailyBriefFinalLayoutAndActionsOnMini() throws {
        try signIn()

        // Target predicate: the Daily Brief card is present.
        let caloriesCaption = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "diary.summary.calories", "Calories")
        ).firstMatch
        XCTAssertTrue(caloriesCaption.waitForExistence(timeout: Timeout.normal),
                      "Daily Brief Calories caption is missing.")
        capture("DBF01-daily-brief-top", target: "diary.dateNavigation")

        // Date controls above the card: typed buttons, real non-empty labels.
        let previous = dateControl("Previous day")
        let centeredDate = dateControl("Today")
        let next = dateControl("Next day")
        XCTAssertTrue(previous.isHittable && centeredDate.isHittable,
                      "Previous-day or centered date button is not hittable.")
        XCTAssertLessThan(previous.frame.maxX, centeredDate.frame.minX,
                          "Previous-day button is not left of the centered date.")
        XCTAssertLessThan(centeredDate.frame.maxX, next.frame.minX,
                          "Next-day button is not right of the centered date.")
        XCTAssertLessThan(centeredDate.frame.maxY, caloriesCaption.frame.minY,
                          "Date controls are not above the Daily Brief card.")

        // Passive calorie block: caption, remaining value, eaten, goal, progress.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "kcal eaten"))
                        .firstMatch.exists, "'kcal eaten' caption missing.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "kcal left"))
                        .firstMatch.exists, "Remaining value missing.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "of "))
                        .firstMatch.exists, "Goal line missing.")
        let progress = app.progressIndicators.matching(
            NSPredicate(format: "identifier == %@", "diary.summary.calories")
        ).firstMatch
        XCTAssertTrue(progress.exists, "Calorie progress indicator missing (passive query).")

        // Three passive macro columns; no redundant Macros heading.
        let protein = passive("diary.summary.protein")
        let carbs = passive("diary.summary.carbs")
        let fat = passive("diary.summary.fat")
        XCTAssertTrue(protein.exists && carbs.exists && fat.exists, "A macro column is missing.")
        XCTAssertLessThan(protein.frame.minX, carbs.frame.minX, "Macro columns out of order.")
        XCTAssertLessThan(carbs.frame.minX, fat.frame.minX, "Macro columns out of order.")
        XCTAssertEqual(protein.frame.minY, carbs.frame.minY, accuracy: 2.0, "Macro columns not on one row.")
        XCTAssertEqual(carbs.frame.minY, fat.frame.minY, accuracy: 2.0, "Macro columns not on one row.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Protein, carbs and fat")).count, 0,
                       "Redundant Macros heading present.")
        XCTAssertTrue(protein.label.contains(" g"), "Gram value missing in protein column: \(protein.label)")

        // Manage meal slots: right-aligned button above the first illustrated card.
        let manageSlots = requireButton("diary.manageSlots")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Manage meal slots"))
                        .firstMatch.exists, "Manage meal slots label missing.")
        let firstCardAdd = scrollToHittable("diary.addFood.breakfast")
        XCTAssertGreaterThan(firstCardAdd.frame.minY, manageSlots.frame.maxY,
                             "Manage meal slots is not above the first meal card.")
        XCTAssertGreaterThan(manageSlots.frame.minX, firstCardAdd.frame.midX,
                             "Manage meal slots is not right-aligned.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Breakfast"))
                        .firstMatch.exists, "Breakfast illustrated card header missing.")
        capture("DBF02-first-breakfast-card", target: "diary.addFood.breakfast")

        // Date behaviour: previous -> non-Today, single calendar, next -> Today.
        _ = scrollToHittable("diary.dateNavigation", swipeUp: false)
        previous.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let leftToday = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "Today"), object: centeredDate
        )
        XCTAssertEqual(XCTWaiter.wait(for: [leftToday], timeout: Timeout.short), .completed,
                       "Previous day did not change the date.")
        centeredDate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(passive("diary.datePicker").waitForExistence(timeout: Timeout.normal),
                      "Calendar trigger did not open the date picker.")
        tapButton("diary.datePicker.cancel")
        next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let backToday = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Today"), object: centeredDate
        )
        XCTAssertEqual(XCTWaiter.wait(for: [backToday], timeout: Timeout.short), .completed,
                       "Next day did not return to Today.")

        // Grams / Percent native Menu toggle, verified on passive column labels.
        tapButton("diary.summary.macroMode")
        let percentItem = app.buttons.matching(NSPredicate(format: "label == %@", "Percent")).firstMatch
        XCTAssertTrue(percentItem.waitForExistence(timeout: Timeout.short), "Percent menu item missing.")
        XCTAssertTrue(percentItem.isHittable, "Percent menu item not hittable.")
        percentItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let percentProtein = passive("diary.summary.protein")
        XCTAssertTrue(percentProtein.label.contains("%"),
                      "Percent mode did not update macro value: \(percentProtein.label)")
        tapButton("diary.summary.macroMode")
        let gramsItem = app.buttons.matching(NSPredicate(format: "label == %@", "Grams")).firstMatch
        XCTAssertTrue(gramsItem.waitForExistence(timeout: Timeout.short), "Grams menu item missing.")
        XCTAssertTrue(gramsItem.isHittable, "Grams menu item not hittable.")
        gramsItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(passive("diary.summary.protein").label.contains(" g"),
                      "Grams mode did not restore macro value.")

        // Edit goals -> real Settings, guarded Back (pristine, no edits made).
        tapButton("diary.editGoals")
        XCTAssertTrue(passive("settings.sheet").waitForExistence(timeout: Timeout.normal),
                      "Edit goals did not open Settings.")
        _ = requireButton("settings.back")
        tapButton("settings.back")
        let settingsGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["settings.sheet"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settingsGone], timeout: Timeout.normal), .completed,
                       "Settings Back did not dismiss.")

        // Nutrition details -> real report, known-hittable Close, Diary return.
        _ = scrollToHittable("diary.nutrition", swipeUp: false)
        tapButton("diary.nutrition")
        XCTAssertTrue(passive("nutrition.details").waitForExistence(timeout: Timeout.normal),
                      "Nutrition details report did not open.")
        let nutritionClose = requireButton("nutrition.close")
        nutritionClose.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let nutritionGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any)["nutrition.details"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [nutritionGone], timeout: Timeout.normal), .completed,
                       "Nutrition Close did not return to the Diary.")
        XCTAssertTrue(passive("diary.summary.calories").exists,
                      "Diary Daily Brief missing after nutrition return.")
    }
}

// MARK: - Uniquely named synchronous loopback helper.
private extension URLSession {
    func dailyBriefFinalSyncData(
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
