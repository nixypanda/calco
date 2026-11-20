import Foundation
import XCTest

// Focused regression for the Library destination-builder defect. The QA-owned
// NativeCompletionUITests suite remains authoritative for the full mini gate;
// this test keeps a small, deterministic check that route identity survives
// field focus and that the corrected create/ad-hoc journeys can complete.

final class LibraryRouteStabilityUITests: XCTestCase {
    private var baseURL: String {
        ProcessInfo.processInfo.environment["CALCO_PORTABLE_UI_BASE_URL"]
            ?? "http://127.0.0.1:3932"
    }
    private let username = "native-qa"
    private let password = "native-qa"
    private var app: XCUIApplication!

    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        try requireMockFixture()
        try resetFixture()
    }

    override func tearDownWithError() throws {
#if os(iOS)
        XCUIDevice.shared.orientation = .portrait
#endif
        app = nil
    }

    func testCustomFoodAndAdHocKeepFormAcrossFocus() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = baseURL
        app.launch()

        try signIn()
        openLibrary()

        app.buttons["library.add"].tap()
        XCTAssertTrue(
            app.buttons["library.add.custom"].waitForExistence(timeout: 10)
        )
        app.buttons["library.add.custom"].tap()

        let name = app.textFields["library.editor.name"]
        XCTAssertTrue(
            name.waitForExistence(timeout: 40),
            "The custom-food editor did not open."
        )
        name.tap()
        XCTAssertTrue(
            name.waitForExistence(timeout: 10),
            "The custom-food name field disappeared after focus."
        )
        name.typeText("Native QA Stable Custom")

        dismissKeyboard(identifier: "library.editor.keyboard.done")
        name.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "Re-focusing the name field did not reopen the keyboard."
        )
        dismissKeyboard(identifier: "library.editor.keyboard.done")
        fillRequiredNutrients(doneIdentifier: "library.editor.keyboard.done", energy: "100")

        let save = app.buttons["library.editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 40),
            "The created custom food did not return to the Library list."
        )

        let baseline = try mockStateLogCount()

        app.buttons["library.add"].tap()
        XCTAssertTrue(
            app.buttons["library.add.adhoc"].waitForExistence(timeout: 10)
        )
        app.buttons["library.add.adhoc"].tap()

        let adHocName = app.textFields["library.adHoc.name"]
        XCTAssertTrue(
            adHocName.waitForExistence(timeout: 40),
            "The ad-hoc form did not open."
        )
        adHocName.tap()
        XCTAssertTrue(
            adHocName.waitForExistence(timeout: 10),
            "The ad-hoc name field disappeared after focus."
        )
        adHocName.typeText("Native QA Stable Ad Hoc")

        dismissKeyboard(identifier: "library.adHoc.keyboard.done")
        fillRequiredNutrients(
            doneIdentifier: "library.adHoc.keyboard.done",
            energy: "0"
        )

        let submit = app.buttons["library.adHoc.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The review alert did not appear.")
        let confirm = alert.buttons["Log food"]
        if confirm.exists {
            confirm.tap()
        } else {
            alert.buttons.element(boundBy: 0).tap()
        }

        XCTAssertTrue(
            app.descendants(matching: .any)["library.adHoc.logged"]
                .waitForExistence(timeout: 40),
            "Ad-hoc logging did not complete."
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: "library.adHoc.done").count,
            1,
            "Ad-hoc completion must expose exactly one canonical Done action."
        )
        XCTAssertEqual(
            try mockStateLogCount(),
            baseline + 1,
            "Ad-hoc logging must create exactly one fixture log."
        )
    }

    func testLibraryAddToolbarTargetIsAtLeast44Points() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = baseURL
        app.launch()

        try signIn()
        openLibrary()

        let add = app.buttons["library.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        print(
            "NATIVE_QA_LIBRARY_ADD_FRAME="
                + "\(add.frame.width)x\(add.frame.height) @ \(add.frame)"
        )
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertTrue(add.isHittable)
    }

    private func signIn() throws {
        if app.buttons["auth.signOut"].waitForExistence(timeout: 5) {
            app.buttons["auth.signOut"].tap()
        }
        let usernameField = app.textFields["auth.login.username"]
        let passwordField = app.secureTextFields["auth.login.password"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 20))
        XCTAssertTrue(passwordField.waitForExistence(timeout: 20))
        usernameField.tap()
        usernameField.typeText(username)
        passwordField.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 8),
            "The login keyboard did not appear."
        )
        passwordField.typeText(password)

        let accessorySubmit = app.buttons["auth.login.keyboard.submit"]
        if accessorySubmit.exists, accessorySubmit.isHittable {
            accessorySubmit.tap()
        } else {
            let submit = app.buttons["auth.login.submit"]
            XCTAssertTrue(submit.waitForExistence(timeout: 10))
            submit.tap()
        }
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)
        XCTAssertTrue(
            CalCoE2E.waitForLoadedDiary(in: app, timeout: 40),
            "Fixture sign-in did not reach the diary."
        )
    }

    private func openLibrary() {
        let library = app.buttons["diary.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let empty = app.descendants(matching: .any)["library.empty"]
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.row.")
        ).firstMatch
        XCTAssertTrue(
            CalCoE2E.waitUntil(timeout: 40) { empty.exists || row.exists },
            "The Library list did not load."
        )
    }

    private func fillRequiredNutrients(
        doneIdentifier: String,
        energy: String
    ) {
        setNutrient("ENERGY_KCAL", value: energy, doneIdentifier: doneIdentifier)
        setNutrient("PROTEIN_G", value: "0", doneIdentifier: doneIdentifier)
        setNutrient("CARBS_G", value: "0", doneIdentifier: doneIdentifier)
        setNutrient("FAT_G", value: "0", doneIdentifier: doneIdentifier)
    }

    private func dismissKeyboard(identifier: String) {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.buttons[identifier]
        if done.exists, done.isHittable {
            done.tap()
        }
    }

    private func setNutrient(
        _ code: String,
        value: String,
        doneIdentifier: String
    ) {
        let field = app.textFields["library.nutrient.\(code).field"]
        let scroll = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if field.exists, field.isHittable { break }
            if scroll.exists {
                scroll.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(
            field.waitForExistence(timeout: 10),
            "The \(code) nutrient field is missing."
        )
        field.tap()
        replaceText(in: field, with: value)
        let done = app.buttons[doneIdentifier]
        if app.keyboards.firstMatch.exists, done.exists, done.isHittable {
            done.tap()
        }
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        let current = element.value as? String ?? ""
        let placeholder = element.placeholderValue ?? ""
        if !current.isEmpty, current != placeholder {
            element.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            )
        }
        element.typeText(value)
    }

    private func requireMockFixture() throws {
        guard let health = try? mockRequest(method: "GET", path: "/__qa/health"),
              health["fixture"] as? String == "native-completion-qa" else {
            throw XCTSkip(
                "LibraryRouteStabilityUITests requires NativeCompletionQAMockServer.py "
                    + "on 127.0.0.1:3932."
            )
        }
    }

    private func resetFixture() throws {
        let body: [String: Any] = [
            "today": Self.isoDay(Date()),
            "log_post": "success",
            "seed_logs": true,
        ]
        _ = try mockRequest(method: "POST", path: "/__qa/reset", body: body)
    }

    private func mockStateLogCount() throws -> Int {
        let state = try mockRequest(method: "GET", path: "/__qa/state")
        guard let count = state["log_count"] as? Int else {
            throw CalCoE2E.StateError(description: "The fixture state has no log count.")
        }
        return count
    }

    private func mockRequest(
        method: String,
        path: String,
        body: [String: Any]? = nil
    ) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let box = ResponseBox()
        let finished = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode
            box.error = error
            finished.signal()
        }.resume()
        guard finished.wait(timeout: .now() + 10) == .success else {
            throw CalCoE2E.StateError(description: "The QA fixture timed out.")
        }
        if let error = box.error {
            throw error
        }
        guard box.status == 200,
              let data = box.data,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw CalCoE2E.StateError(
                description: "The QA fixture returned an invalid response."
            )
        }
        return object
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
