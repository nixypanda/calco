// Bounded QA diagnostics for the four unresolved baseline failure groups.
// This file collects POST-tap / post-action state BEFORE any assertion fails.
// It deliberately does NOT assert the expected outcome and is NOT acceptance.
// The 8-case baseline file and artifacts remain immutable.

#if os(iOS)

import Foundation
import UIKit
import XCTest

final class BaselineFailureDiagnosticUITests: XCTestCase {
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
        let (data, response) = try URLSession.shared.baselineDiagSyncData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer fixture is not available.")
            throw NSError(domain: "BaselineFailureDiagnostic", code: 1)
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
        let (_, response) = try URLSession.shared.baselineDiagSyncData(from: request.url!, request: request)
        print("QA_DIAG fixture reset status=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
    }

    /// Group 1 evidence: the fixture's raw food-detail GET response, so its JSON
    /// can be compared against production decoding without instrumenting source.
    private func dumpFoodDetailFixtureResponse() {
        do {
            var login = URLRequest(url: URL(string: QA.baseURL + "/api/auth/login")!)
            login.httpMethod = "POST"
            login.setValue("application/json", forHTTPHeaderField: "Content-Type")
            login.httpBody = try JSONSerialization.data(withJSONObject: [
                "username": QA.username, "password": QA.password
            ])
            let (_, loginResponse) = try URLSession.shared.baselineDiagSyncData(from: login.url!, request: login)
            let header = (loginResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String ?? ""
            let cookie = header.components(separatedBy: ";").first ?? header
            var detail = URLRequest(url: URL(string: QA.baseURL + "/api/foods/qa-apple")!)
            detail.setValue(cookie, forHTTPHeaderField: "Cookie")
            let (data, response) = try URLSession.shared.baselineDiagSyncData(from: detail.url!, request: detail)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            print("QA_DIAG fixture GET /api/foods/qa-apple status=\(status)")
            print("QA_DIAG fixture GET /api/foods/qa-apple body=\(raw)")
        } catch {
            print("QA_DIAG fixture GET failed: \(error)")
        }
    }

    // MARK: - App / helpers

    private func signIn() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        app.launch()
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        XCTAssertTrue(username.waitForExistence(timeout: Timeout.normal), "login username")
        XCTAssertTrue(password.waitForExistence(timeout: Timeout.normal), "login password")
        username.tap()
        username.typeText(QA.username)
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short), "keyboard")
        password.typeText(QA.password)
        let submit = app.buttons["auth.login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: Timeout.short), "submit")
        XCTAssertTrue(submit.isHittable, "submit hittable")
        submit.tap()
        dismissNotNowIfNeeded()
        XCTAssertTrue(app.descendants(matching: .any)["diary.summary.calories"]
                        .waitForExistence(timeout: Timeout.normal), "diary after sign-in")
        dismissNotNowIfNeeded()
    }

    private func dismissNotNowIfNeeded() {
        let alertButton = app.alerts.buttons["Not Now"]
        if alertButton.waitForExistence(timeout: 1), alertButton.isHittable { alertButton.tap() }
        let fallback = app.buttons["Not Now"]
        if fallback.waitForExistence(timeout: 1), fallback.isHittable { fallback.tap() }
    }

    @discardableResult
    private func requireElement(_ identifier: String, timeout: TimeInterval = Timeout.short) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing required '\(identifier)'.")
        return element
    }

    private func tapRequired(_ identifier: String, timeout: TimeInterval = Timeout.short) {
        let element = requireElement(identifier, timeout: timeout)
        XCTAssertTrue(element.isHittable, "Not hittable: '\(identifier)'.")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func describe(_ identifier: String, phase: String) {
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let any = app.descendants(matching: .any).matching(predicate)
        print("QA_DIAG [\(phase)] \(identifier) any.count=\(any.count)")
        for index in 0..<any.count {
            let element = any.element(boundBy: index)
            print("QA_DIAG [\(phase)]   any[\(index)] type=\(element.elementType.rawValue) label='\(element.label)' value='\(String(describing: element.value))' exists=\(element.exists) hittable=\(element.isHittable) enabled=\(element.isEnabled) frame=\(element.frame)")
        }
        let buttons = app.buttons.matching(predicate)
        print("QA_DIAG [\(phase)]   buttons.count=\(buttons.count)")
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            print("QA_DIAG [\(phase)]   button[\(index)] label='\(button.label)' hittable=\(button.isHittable) enabled=\(button.isEnabled) frame=\(button.frame)")
        }
    }

    private func dumpAX(_ phase: String) {
        print("QA_DIAG [\(phase)] windows=\(app.windows.count) sheets=\(app.sheets.count) alerts=\(app.alerts.count) navbars=\(app.navigationBars.count) activityIndicators=\(app.activityIndicators.count) keyboards=\(app.keyboards.count)")
        let navs = app.navigationBars
        for index in 0..<navs.count {
            let bar = navs.element(boundBy: index)
            print("QA_DIAG [\(phase)] navbar[\(index)] id='\(bar.identifier)' label='\(bar.label)' hittable=\(bar.isHittable) frame=\(bar.frame)")
            let buttons = bar.buttons
            for b in 0..<buttons.count {
                let button = buttons.element(boundBy: b)
                print("QA_DIAG [\(phase)] navbar[\(index)].button[\(b)] id='\(button.identifier)' label='\(button.label)' hittable=\(button.isHittable) enabled=\(button.isEnabled) frame=\(button.frame)")
            }
            let texts = bar.staticTexts
            for t in 0..<texts.count {
                print("QA_DIAG [\(phase)] navbar[\(index)].staticText[\(t)] id='\(texts.element(boundBy: t).identifier)' label='\(texts.element(boundBy: t).label)'")
            }
        }
        let texts = app.staticTexts
        let textLimit = min(texts.count, 80)
        for index in 0..<textLimit {
            let text = texts.element(boundBy: index)
            if !text.label.isEmpty {
                print("QA_DIAG [\(phase)] staticText[\(index)] id='\(text.identifier)' label='\(text.label)' frame=\(text.frame)")
            }
        }
        let buttons = app.buttons
        let buttonLimit = min(buttons.count, 120)
        for index in 0..<buttonLimit {
            let button = buttons.element(boundBy: index)
            print("QA_DIAG [\(phase)] button[\(index)] id='\(button.identifier)' label='\(button.label)' hittable=\(button.isHittable) enabled=\(button.isEnabled) frame=\(button.frame)")
        }
        for identifier in ["foodDetail.foodName", "foodDetail.submit", "search.field", "search.field.error",
                           "search.error", "search.loading", "search.loading.inline", "settings.sheet",
                           "settings.goals.calories", "settings.discard.confirm", "settings.discard.cancel",
                           "nutrition.details", "nutrition.close", "app.assistant.close",
                           "library.add", "library.add.custom", "library.createWithAI"] {
            let element = app.descendants(matching: .any)[identifier]
            if element.exists {
                print("QA_DIAG [\(phase)] PRESENT \(identifier) type=\(element.elementType.rawValue) hittable=\(element.isHittable) enabled=\(element.isEnabled) frame=\(element.frame) label='\(element.label)'")
            }
        }
        print("QA_DIAG [\(phase)] app.debugDescription=\(app.debugDescription)")
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let png = shot.image.pngData()
        XCTAssertNotNil(png, "screenshot \(name) had no PNG data")
        if let png {
            let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            XCTAssertEqual(Array(png.prefix(4)), magic, "screenshot \(name) is not a real PNG")
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("QA_DIAG captured \(name) bytes=\(png?.count ?? 0)")
    }

    // MARK: - 1. Search tab result tap

    func testDiagSearchTabResultTapState() throws {
        try signIn()
        dumpFoodDetailFixtureResponse()
        tapRequired("app.tab.search")
        let field = requireElement("search.field")
        field.tap()
        field.typeText("apple")
        let result = requireElement("search.result.qa-apple", timeout: Timeout.normal)
        print("QA_DIAG G1 preTap result=\(result.frame) hittable=\(result.isHittable)")
        capture("DG1-01-before-result-tap")
        result.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        capture("DG1-02-immediately-after-result-tap")
        dumpAX("G1_IMMEDIATE")
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.app.descendants(matching: .any)["foodDetail.foodName"].exists
                    || self.app.descendants(matching: .any)["search.error"].exists
                    || self.app.activityIndicators.count > 0
            },
            object: nil
        )
        print("QA_DIAG G1 settledWait=\(XCTWaiter.wait(for: [settled], timeout: Timeout.normal).rawValue)")
        capture("DG1-03-settled-after-result-tap")
        dumpAX("G1_SETTLED")
        describe("foodDetail.foodName", phase: "G1_SETTLED")
    }

    // MARK: - 2. Settings dirty Back

    func testDiagSettingsDirtyBack() throws {
        try signIn()
        tapRequired("app.tab.settings")
        let sheet = requireElement("settings.sheet", timeout: Timeout.normal)
        print("QA_DIAG G2 sheet exists=\(sheet.exists) hittable=\(sheet.isHittable)")
        let field = requireElement("settings.goals.calories", timeout: Timeout.normal)
        XCTAssertTrue(field.isHittable, "settings.goals.calories not hittable after load")
        let before = field.value as? String ?? ""
        print("QA_DIAG G2 valueBEFORE='\(before)'")
        capture("DG2-01-settings-loaded-before-typing")
        field.tap()
        field.typeText("1")
        let after = field.value as? String ?? ""
        print("QA_DIAG G2 valueAFTER='\(after)'")
        if app.buttons["settings.keyboard.done"].exists {
            print("QA_DIAG G2 settings.keyboard.done exists hittable=\(app.buttons["settings.keyboard.done"].isHittable)")
            if app.buttons["settings.keyboard.done"].isHittable { app.buttons["settings.keyboard.done"].tap() }
        } else {
            print("QA_DIAG G2 settings.keyboard.done absent")
        }
        dumpAX("G2_BEFORE_BACK")
        describe("settings.back", phase: "G2_BEFORE_BACK")
        let back = app.buttons["settings.back"]
        if back.exists && back.isHittable {
            back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            print("QA_DIAG G2 tapped settings.back")
        } else {
            print("QA_DIAG G2 settings.back NOT tappable exists=\(back.exists) hittable=\(back.isHittable)")
        }
        capture("DG2-02-after-settings-back")
        dumpAX("G2_AFTER_BACK")
        for identifier in ["settings.discard.confirm", "settings.discard.cancel", "diary.editor.discard.confirm", "diary.editor.discard.cancel"] {
            describe(identifier, phase: "G2_AFTER_BACK")
        }
        let alert = app.alerts.firstMatch
        print("QA_DIAG G2 alert.exists=\(alert.exists) label='\(alert.label)'")
    }

    // MARK: - 3. Nutrition close control

    func testDiagNutritionCloseAX() throws {
        try signIn()
        tapRequired("diary.nutrition")
        XCTAssertTrue(requireElement("nutrition.details", timeout: Timeout.normal).exists,
                      "nutrition.details did not open")
        capture("DG3-01-nutrition-open")
        describe("nutrition.close", phase: "G3_OPEN")
        let anyClose = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "nutrition.close")
        )
        print("QA_DIAG G3 anyClose.count=\(anyClose.count)")
        for index in 0..<anyClose.count {
            let element = anyClose.element(boundBy: index)
            print("QA_DIAG G3 anyClose[\(index)] type=\(element.elementType.rawValue) label='\(element.label)' value='\(String(describing: element.value))' hittable=\(element.isHittable) enabled=\(element.isEnabled) frame=\(element.frame)")
        }
        for sheetIndex in 0..<app.sheets.count {
            let sheet = app.sheets.element(boundBy: sheetIndex)
            let contained = sheet.descendants(matching: .any)["nutrition.close"]
            print("QA_DIAG G3 sheet[\(sheetIndex)] id='\(sheet.identifier)' hittable=\(sheet.isHittable) frame=\(sheet.frame) containsClose=\(contained.exists)")
        }
        dumpAX("G3_OPEN")
    }

    // MARK: - 4. Library persistent tab plus menu

    func testDiagLibraryPlusMenuAX() throws {
        try signIn()
        tapRequired("app.tab.library")
        tapRequired("library.foods")
        capture("DG4-01-myfoods-list")
        describe("library.add", phase: "G4_LIST")
        let anyAdd = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "library.add")
        )
        print("QA_DIAG G4 anyAdd.count=\(anyAdd.count)")
        for index in 0..<anyAdd.count {
            let element = anyAdd.element(boundBy: index)
            print("QA_DIAG G4 anyAdd[\(index)] type=\(element.elementType.rawValue) label='\(element.label)' hittable=\(element.isHittable) enabled=\(element.isEnabled) frame=\(element.frame)")
        }
        dumpAX("G4_LIST")
        let add = app.buttons["library.add"]
        if add.exists && add.isHittable {
            add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            print("QA_DIAG G4 tapped library.add")
            capture("DG4-02-after-plus-tap")
            dumpAX("G4_AFTER_PLUS_TAP")
            describe("library.add.custom", phase: "G4_AFTER_PLUS_TAP")
            describe("library.createWithAI", phase: "G4_AFTER_PLUS_TAP")
        } else {
            print("QA_DIAG G4 library.add NOT tappable exists=\(add.exists) hittable=\(add.isHittable)")
            capture("DG4-02-plus-not-hittable")
        }
    }
}

// MARK: - Uniquely named synchronous loopback helper.
private extension URLSession {
    func baselineDiagSyncData(
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
