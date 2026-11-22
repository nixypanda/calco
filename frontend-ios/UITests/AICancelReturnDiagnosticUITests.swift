import Foundation
import XCTest

#if os(iOS)
import UIKit
#endif

/// Focused, isolated diagnostic for the one unresolved Mini QA case:
/// Library -> My Foods -> Create with AI -> (assistant) -> Cancel -> is
/// `library.add.custom` actually hittable and usable?
///
/// This file is deliberately separate from WebParityMiniQAUITests so existing
/// evidence is never overwritten. It only reads the public accessibility
/// tree, takes real XCUIScreen screenshots, and performs real user taps.
final class AICancelReturnDiagnosticUITests: XCTestCase {
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

    private func diag(_ message: String) {
        print("AICANCELDIAG \(message)")
    }

    private func requireMockFixture() throws {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.synchronousDataDiag(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer fixture is not available.")
            throw NSError(domain: "AICancelReturnDiagnostic", code: 1)
        }
    }

    /// Real screen image via XCUIScreen (not an AX snapshot).
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        diag("captured screenshot '\(name)' bytes=\(shot.image.pngData()?.count ?? 0)")
    }

    /// Enumerate EVERY accessibility element carrying the identifier (any
    /// type), plus the typed Button/StaticText subsets, with frame/enabled/
    /// hittable. This distinguishes a wrong-query problem from a real block.
    private func describe(_ identifier: String, phase: String) {
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let any = app.descendants(matching: .any).matching(predicate)
        diag("[\(phase)] '\(identifier)' any.count=\(any.count)")
        for i in 0..<any.count {
            let e = any.element(boundBy: i)
            diag("[\(phase)]   any[\(i)] type=\(e.elementType.rawValue) exists=\(e.exists) hittable=\(e.isHittable) enabled=\(e.isEnabled) frame=\(e.frame) label='\(e.label)'")
        }
        let buttons = app.buttons.matching(predicate)
        diag("[\(phase)]   buttons.count=\(buttons.count)")
        for i in 0..<buttons.count {
            let b = buttons.element(boundBy: i)
            diag("[\(phase)]   button[\(i)] exists=\(b.exists) hittable=\(b.isHittable) enabled=\(b.isEnabled) frame=\(b.frame)")
        }
        let texts = app.staticTexts.matching(predicate)
        diag("[\(phase)]   staticTexts.count=\(texts.count)")
        for i in 0..<texts.count {
            let t = texts.element(boundBy: i)
            diag("[\(phase)]   staticText[\(i)] exists=\(t.exists) hittable=\(t.isHittable) frame=\(t.frame) label='\(t.label)'")
        }
    }

    private func signIn() throws {
        app = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        app.launchEnvironment["CALCO_API_BASE_URL"] = QA.baseURL
        app.launch()

        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        XCTAssertTrue(username.waitForExistence(timeout: Timeout.normal), "username field")
        XCTAssertTrue(password.waitForExistence(timeout: Timeout.normal), "password field")
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
        XCTAssertTrue(app.descendants(matching: .any)["diary.summary.calories"].waitForExistence(timeout: Timeout.normal), "diary after sign-in")
        dismissNotNowIfNeeded()
    }

    private func dismissNotNowIfNeeded() {
        let alertButton = app.alerts.buttons["Not Now"]
        if alertButton.waitForExistence(timeout: 2), alertButton.isHittable {
            alertButton.tap()
        }
        let fallback = app.buttons["Not Now"]
        if fallback.waitForExistence(timeout: 1), fallback.isHittable {
            fallback.tap()
        }
    }

    private func tapButton(_ identifier: String) {
        let element = app.buttons[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.normal), "\(identifier) exists")
        XCTAssertTrue(element.isHittable, "\(identifier) hittable")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testDiagnosticAIAssistantCancelThenManualHit() throws {
        try signIn()

        tapButton("app.tab.library")
        tapButton("library.foods")
        XCTAssertTrue(app.buttons["library.createWithAI"].waitForExistence(timeout: Timeout.normal))
        XCTAssertTrue(app.buttons["library.add.custom"].waitForExistence(timeout: Timeout.normal))

        // 1. Before opening the assistant.
        describe("library.add.custom", phase: "PRE_AI")
        describe("library.createWithAI", phase: "PRE_AI")
        capture("diag-01-pre-ai")

        // 2. Open the AI assistant sheet through the real visible button.
        tapButton("library.createWithAI")
        let composer = app.descendants(matching: .any)["assistant.composer"]
        let disabled = app.descendants(matching: .any)["assistant.status.disabled"]
        let assistantOpened = composer.waitForExistence(timeout: Timeout.normal)
            || disabled.waitForExistence(timeout: Timeout.normal)
        XCTAssertTrue(assistantOpened, "assistant did not open")
        diag("assistant opened: composer=\(composer.exists) disabled=\(disabled.exists)")

        // 3. Compare the identifier the old test used vs the real sheet cancel.
        describe("assistant.cancel", phase: "ASSISTANT_OPEN")
        describe("app.assistant.close", phase: "ASSISTANT_OPEN")
        capture("diag-02-assistant-open")

        // 4. Dismiss via the REAL cancellation control of the assistant sheet.
        let close = app.buttons["app.assistant.close"]
        XCTAssertTrue(close.waitForExistence(timeout: Timeout.short), "app.assistant.close button exists")
        diag("close hittable=\(close.isHittable) frame=\(close.frame)")
        XCTAssertTrue(close.isHittable, "app.assistant.close hittable")
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["app.assistant.close"]
        )
        let dismissResult = XCTWaiter.wait(for: [closed], timeout: Timeout.normal).rawValue
        diag("sheet-dismiss predicate wait result=\(dismissResult) (0=completed)")
        describe("app.assistant.close", phase: "AFTER_CANCEL")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == %@", "app.assistant.close")).count, 0, "assistant sheet was not dismissed")

        // 5. Is the manual choice really hittable after the sheet is gone?
        describe("library.add.custom", phase: "AFTER_CANCEL")
        capture("diag-03-after-cancel")

        let manual = app.buttons["library.add.custom"]
        XCTAssertTrue(manual.waitForExistence(timeout: Timeout.normal), "manual button exists")
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: manual
        )
        let hitResult = XCTWaiter.wait(for: [hittable], timeout: Timeout.normal).rawValue
        diag("manual hittable predicate wait result=\(hitResult) (0=completed), direct isHittable=\(manual.isHittable)")
        XCTAssertTrue(manual.isHittable, "manual choice is not hittable after the sheet was dismissed")

        // 6. Perform the REAL manual creation action and assert the editor opens.
        manual.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let nameField = app.textFields["library.editor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: Timeout.normal), "manual editor did not open")
        diag("manual editor opened; nameField hittable=\(nameField.isHittable) frame=\(nameField.frame)")
        capture("diag-04-manual-editor-open")
    }
}

extension URLSession {
    func synchronousDataDiag(from url: URL, request: URLRequest? = nil) throws -> (Data, URLResponse) {
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
