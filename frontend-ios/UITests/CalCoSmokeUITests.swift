import XCTest

#if os(iOS) && targetEnvironment(simulator)
import UIKit
#endif

// CalCo E2E harness for the shared CalCo-E2E scheme. It launches only the
// isolated Test app (dev.calco.CalCo.Test) against http://127.0.0.1:3002.
// Credentials come only from the private per-run xctestrun environment and are
// never written to source, logs, assertions, or attachments. Passwords are
// entered only through the simulator shared pasteboard plus Cmd+V; if that
// path cannot be verified the test skips instead of using typeText.

enum CalCoE2E {
    static let appBundleIdentifier = "dev.calco.CalCo.Test"
    static let defaultBaseURL = "http://127.0.0.1:3002"
    static let baseURLEnvironmentKey = "CALCO_E2E_BASE_URL"
    static let appBaseURLEnvironmentKey = "CALCO_API_BASE_URL"
    static let credentialsEnvironmentKey = "CALCO_E2E_CREDENTIALS_JSON"

    struct ConfigurationError: Error, CustomStringConvertible {
        let description: String
    }

    static let supportsSecurePasswordEntry: Bool = {
#if os(iOS) && targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }()

    struct Credentials {
        let username: String
        let password: String
    }

    struct StateError: Error, CustomStringConvertible {
        let description: String
    }

    static func credentials(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Credentials? {
        guard let json = environment[credentialsEnvironmentKey],
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = object["username"] as? String,
              let password = object["password"] as? String,
              !username.isEmpty,
              !password.isEmpty else {
            return nil
        }
        return Credentials(username: username, password: password)
    }

    static func makeApp(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> XCUIApplication {
        let baseURL = try resolvedBaseURL(environment: environment)
        let app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchEnvironment[appBaseURLEnvironmentKey] = baseURL.absoluteString
        return app
    }

    /// The default isolated Test app backend is loopback port 3002. A runner may
    /// inject another isolated backend, but only on an explicit loopback host:
    /// credential-bearing tests must never be pointed at a LAN or Internet URL.
    static func resolvedBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let override = environment[baseURLEnvironmentKey] else {
            return URL(string: defaultBaseURL)!
        }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = validatedBaseURL(trimmed) else {
            throw ConfigurationError(
                description: "\(baseURLEnvironmentKey) must be an explicit loopback "
                    + "http(s) base URL without user info, a query, or a fragment. "
                    + "Allowed hosts: localhost, 127.0.0.1, ::1."
            )
        }
        return url
    }

    /// Validates before any app launch or credential use. This intentionally
    /// rejects remote and LAN hosts even when they use HTTPS.
    static func validatedBaseURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              isLoopbackHost(host),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: NSObject())
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func isLoginFormVisible(in app: XCUIApplication) -> Bool {
        app.textFields["auth.login.username"].exists
            && app.secureTextFields["auth.login.password"].exists
            && app.buttons["auth.login.submit"].exists
    }

    static func waitForLogin(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { isLoginFormVisible(in: app) }
    }

    static func isLoadedDiary(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["diary.summary.calories"].exists
    }

    static func waitForLoadedDiary(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { isLoadedDiary(in: app) }
    }

    static func requireFreshLogin(in app: XCUIApplication, timeout: TimeInterval = 20) throws {
        dismissSavePasswordPrompt(in: app)
        if waitForLogin(in: app, timeout: timeout) { return }

        let signOut = app.buttons["auth.signOut"]
        if signOut.waitForExistence(timeout: 10) {
            signOut.tap()
            guard waitForLogin(in: app, timeout: timeout) else {
                throw StateError(description: "Sign Out did not return to the login form.")
            }
            return
        }

        let observed = [
            "auth.session.restoreFailed",
            "app.configuration.error",
            "diary.sessionExpired",
            "diary.error",
        ].filter { app.descendants(matching: .any)[$0].exists }
        throw StateError(
            description: "No login form or signed-in shell after launch. Observed: "
                + (observed.isEmpty ? "neither state" : observed.joined(separator: ", "))
        )
    }

    static func dismissSavePasswordPrompt(in app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        if notNow.exists, notNow.isHittable {
            notNow.tap()
        }
    }

    static func dismissSavePasswordPromptWhenPresent(
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: timeout), notNow.isHittable {
            notNow.tap()
        }
    }

    static func signIn(_ credentials: Credentials, in app: XCUIApplication) throws {
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        let submit = app.buttons["auth.login.submit"]

        guard username.waitForExistence(timeout: 20),
              password.waitForExistence(timeout: 20),
              submit.waitForExistence(timeout: 20) else {
            throw StateError(description: "The login form disappeared before credential entry.")
        }

        username.tap()
        username.typeText(credentials.username)
        try pastePassword(credentials.password, into: password, in: app)
        submit.tap()
    }

    /// iOS can ask whether the app may paste from another process. Approving
    /// that system prompt still uses the secure pasteboard path and never types
    /// the password; declining means the test skips as before.
    private static func approvePastePromptIfPresent(in app: XCUIApplication) {
        let candidates = [
            app,
            XCUIApplication(bundleIdentifier: "com.apple.springboard"),
        ]
        for candidate in candidates {
            let alert = candidate.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { continue }
            for label in ["Allow Paste", "Paste", "Allow"] {
                let button = alert.buttons[label]
                if button.exists, button.isHittable {
                    button.tap()
                    return
                }
            }
        }

        // Some iOS 26 builds expose a keyboard assistant paste control instead
        // of a permission alert. It still uses the secure pasteboard path.
        let assistant = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "assistantPaste")
        ).firstMatch
        if assistant.waitForExistence(timeout: 2), assistant.isHittable {
            assistant.tap()
        }
    }

    static func pastePassword(
        _ password: String,
        into field: XCUIElement,
        in app: XCUIApplication
    ) throws {
#if os(iOS) && targetEnvironment(simulator)
        let pasteboard = UIPasteboard.general
        defer { pasteboard.items = [] }

        field.tap()

        guard app.keyboards.firstMatch.waitForExistence(timeout: 8) else {
            throw XCTSkip(
                "The iOS software keyboard did not appear; refusing password entry "
                    + "without secure paste verification."
            )
        }

        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        let before = field.value as? String ?? ""

        pasteboard.items = []
        pasteboard.string = password
        field.typeKey("v", modifierFlags: .command)
        approvePastePromptIfPresent(in: app)
        let pasted = waitUntil(timeout: 10) {
            let value = field.value as? String ?? ""
            return !value.isEmpty && value != before
        }
        guard pasted else {
            throw XCTSkip(
                "Cmd+V did not populate the password field; refusing to fall back "
                    + "to typeText for a secret."
            )
        }

        let masked = field.value as? String ?? ""
        guard !masked.isEmpty, masked != before, !masked.contains(password) else {
            throw XCTSkip(
                "The password field did not mask the pasted value; refusing "
                    + "credentialed E2E."
            )
        }
#else
        throw XCTSkip(
            "Credentialed E2E requires the iOS Simulator shared pasteboard and "
                + "Cmd+V path; macOS secure password entry is not supported/verified by this simulator-only E2E harness."
        )
#endif
    }
}

final class CalCoSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try CalCoE2E.makeApp()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLaunchShowsLoginOrDiary() throws {
        app.launch()

        let reached = CalCoE2E.waitUntil(timeout: 20) {
            CalCoE2E.isLoginFormVisible(in: self.app)
                || CalCoE2E.isLoadedDiary(in: self.app)
        }
        guard reached else {
            let observed = [
                "auth.session.restoreFailed",
                "app.configuration.error",
                "diary.sessionExpired",
                "diary.error",
                "diary.retry",
                "diary.loading",
            ].filter { app.descendants(matching: .any)[$0].exists }
            XCTFail(
                "Expected the sign-in form or a loaded diary after launch. Observed: "
                    + (observed.isEmpty ? "neither state" : observed.joined(separator: ", "))
            )
            return
        }
    }

    func testE2EBaseURLOverridePolicy() throws {
        XCTAssertEqual(
            try CalCoE2E.resolvedBaseURL(environment: [:]).absoluteString,
            CalCoE2E.defaultBaseURL
        )
        XCTAssertEqual(
            try CalCoE2E.resolvedBaseURL(
                environment: [CalCoE2E.baseURLEnvironmentKey: "http://127.0.0.1:3902"]
            ).port,
            3902
        )
        XCTAssertNotNil(CalCoE2E.validatedBaseURL("http://localhost:3902"))
        XCTAssertNotNil(CalCoE2E.validatedBaseURL("http://[::1]:3902"))
        XCTAssertNotNil(CalCoE2E.validatedBaseURL("https://127.0.0.1:3902"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("http://192.168.1.10:3902"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("https://example.com"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("https://localhost.example.com"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("http://127.0.0.1.example.com:3902"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("ftp://127.0.0.1:3902"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("http://user:pass@127.0.0.1:3902"))
        XCTAssertNil(CalCoE2E.validatedBaseURL("http://127.0.0.1:3902?next=https://example.com"))
        XCTAssertThrowsError(
            try CalCoE2E.resolvedBaseURL(
                environment: [CalCoE2E.baseURLEnvironmentKey: "https://example.com"]
            )
        )
    }

    func testSignInWhenCredentialsAvailable() throws {
        guard CalCoE2E.supportsSecurePasswordEntry else {
            throw XCTSkip(
                "Credentialed E2E requires the iOS Simulator secure paste path; "
                    + "macOS secure password entry is not supported/verified by this simulator-only E2E harness."
            )
        }
        guard let credentials = CalCoE2E.credentials() else {
            throw XCTSkip(
                "No private E2E credentials were supplied; skipping the authenticated smoke."
            )
        }

        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)
        try CalCoE2E.signIn(credentials, in: app)
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)

        let loginError = app.descendants(matching: .any)["auth.login.error"]
        let loaded = CalCoE2E.waitForLoadedDiary(in: app, timeout: 30)
        if loaded {
            CalCoE2E.dismissSavePasswordPrompt(in: app)
        }
        XCTAssertTrue(
            loaded,
            loginError.exists
                ? "Login failed: \(loginError.label)"
                : "Signed in but the diary did not load."
        )
    }
}
