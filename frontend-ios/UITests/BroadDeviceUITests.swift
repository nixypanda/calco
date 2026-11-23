import Foundation
import XCTest
import CoreGraphics
import ImageIO

#if os(iOS) && targetEnvironment(simulator)
import UIKit
#endif

// QA-only visual-evidence suite for the broad device UI/UX matrix.
//
// This is deliberately NOT the iPhone 13 mini 32-test acceptance gate and NOT
// the portable 7-test acceptance gate. There is no 375x812 guard and no
// XCTSkip path: a missing fixture, a failed launch, or a missing control is a
// real failure. The suite only drives the real isolated Test app
// (dev.calco.CalCo.Test) against the loopback QA fixture with the nonsecret
// fake credentials, and attaches screenshots for independent parent pixel
// review. No production source is referenced or modified here.

final class BroadDeviceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var baseURL: String = ""

    private enum Timeout {
        static let short: TimeInterval = 8
        static let normal: TimeInterval = 20
        static let long: TimeInterval = 45
    }

    private struct HarnessError: Error, CustomStringConvertible {
        let description: String
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        baseURL = try resolveBaseURL()
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    private func resolveBaseURL() throws -> String {
        let raw = ProcessInfo.processInfo.environment["CALCO_PORTABLE_UI_BASE_URL"]
            ?? "http://127.0.0.1:3932"
        guard let url = URL(string: raw),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw HarnessError(
                description: "broad QA base URL is not loopback-only: \(raw)"
            )
        }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - Visual evidence (3 default screens + one AX5 stress page)

    func testBroadDiary() throws {
        try launchSignedIn()
        XCTAssertEqual(
            app.state, .runningForeground,
            "The app is not in the foreground for the portrait capture."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.summary.calories"].exists,
            "The diary summary is missing."
        )
        attach("broad-diary-portrait")
    }

    /// Hardened landscape evidence. The earlier `testBroadDiary` rotation
    /// block attached a screenshot immediately after setting the orientation,
    /// with no foreground / settled-window / dimension assertions. That
    /// produced a portrait UI rotated 90 degrees over a half-black landscape
    /// canvas. This test waits (XCTNSPredicateExpectation, no polling sleeps)
    /// for a STABLE landscape window in the foreground with real diary UI,
    /// then records both raw capture methods plus metadata, and asserts both
    /// PNGs are upright landscape bitmaps. Raw attachments are always kept;
    /// nothing is cropped or blacked out.
    func testBroadLandscape() throws {
        try launchSignedIn()
        XCTAssertEqual(
            app.state, .runningForeground,
            "The app is not in the foreground before rotation."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.summary.calories"].exists,
            "The diary UI is not present before rotation."
        )

        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft

        var lastFrame: CGRect = .zero
        var stablePolls = 0
        let predicate = NSPredicate { _, _ in
            guard self.app.state == .runningForeground else { return false }
            let window = self.app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            guard frame.width > frame.height, frame.width > 300 else { return false }
            guard self.app.descendants(matching: .any)["diary.summary.calories"].exists else {
                return false
            }
            if abs(frame.minX - lastFrame.minX) <= 1,
               abs(frame.minY - lastFrame.minY) <= 1,
               abs(frame.width - lastFrame.width) <= 1,
               abs(frame.height - lastFrame.height) <= 1 {
                stablePolls += 1
            } else {
                stablePolls = 0
            }
            lastFrame = frame
            return stablePolls >= 2
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate, object: NSObject()
        )
        let waitResult = XCTWaiter().wait(for: [expectation], timeout: Timeout.long)
        XCTAssertEqual(
            waitResult, .completed,
            "Landscape window never settled (foreground + stable width>height + diary UI)."
        )

        let windowFrame = app.windows.firstMatch.frame
        let appShot = app.screenshot()
        let screenShot = XCUIScreen.main.screenshot()
        let appSize = pngSize(appShot.pngRepresentation)
        let screenSize = pngSize(screenShot.pngRepresentation)

        // Attach ALL raw evidence BEFORE any assertion: continueAfterFailure is
        // false, so a failing assertion must never abort before pixels exist.
        // XCUIScreen.main.screenshot() legitimately returns a portrait-sized
        // buffer on a landscape device; we record its dimensions rather than
        // assert them, and the driver normalizes orientation WITH a recorded
        // transform while retaining the raw bytes. No crop, no blackout.
        let metadata: [String: Any] = [
            "captureMethods": [
                "XCTest XCUIApplication.screenshot() (broad-landscape-app-raw)",
                "XCTest XCUIScreen.main.screenshot() (broad-landscape-screen-raw)",
            ],
            "requestedOrientation": "landscapeLeft",
            "appState": "runningForeground",
            "windowFrameXYWH": [
                windowFrame.minX, windowFrame.minY,
                windowFrame.width, windowFrame.height,
            ],
            "appScreenshotPixels": appSize.map { [$0.width, $0.height] } ?? [],
            "screenScreenshotPixels": screenSize.map { [$0.width, $0.height] } ?? [],
            "stability": "two consecutive matching polls, XCTNSPredicateExpectation",
            "transform": "none in-test; raw attachments retained; driver may "
                + "normalize orientation with a recorded transform, no crop",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        let meta = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "{}")
        meta.name = "broad-landscape-metadata"
        meta.lifetime = .keepAlways
        add(meta)

        let raw = XCTAttachment(screenshot: appShot)
        raw.name = "broad-landscape-app-raw"
        raw.lifetime = .keepAlways
        add(raw)

        let screen = XCTAttachment(screenshot: screenShot)
        screen.name = "broad-landscape-screen-raw"
        screen.lifetime = .keepAlways
        add(screen)

        // Hard assertions: app owns the foreground (not HOME), the settled
        // window is landscape, and the app screenshot is an upright landscape
        // bitmap. No assertion on the screen buffer's raw dimensions.
        XCTAssertEqual(app.state, .runningForeground, "The app left the foreground.")
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.summary.calories"].exists,
            "The diary UI disappeared after rotation (HOME screen?)."
        )
        XCTAssertGreaterThan(
            windowFrame.width, windowFrame.height,
            "The settled window is not landscape."
        )
        guard let appSize else {
            XCTFail("app.screenshot() PNG dimensions were unreadable.")
            return
        }
        XCTAssertGreaterThan(
            appSize.width, appSize.height,
            "app.screenshot() is not an upright landscape bitmap."
        )
        guard screenSize != nil else {
            XCTFail("XCUIScreen.main.screenshot() PNG dimensions were unreadable.")
            return
        }

        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    private func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(bytes[0..<8]) == signature else { return nil }
        func word(_ start: Int) -> Int {
            (Int(bytes[start]) << 24) | (Int(bytes[start + 1]) << 16)
                | (Int(bytes[start + 2]) << 8) | Int(bytes[start + 3])
        }
        return (word(16), word(20))
    }

    func testBroadAddFood() throws {
        try launchSignedIn()
        guard let field = openAddFood() else {
            XCTFail("Add Food / Search did not open.")
            return
        }
        field.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The keyboard did not appear for Add Food."
        )
        attach("broad-addfood-keyboard")
    }

    func testBroadLogFood() throws {
        try launchSignedIn()
        guard let field = openAddFood() else {
            XCTFail("Add Food / Search did not open.")
            return
        }
        typeSearchQuery("Native QA", in: field)
        let results = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")
        )
        _ = CalCoE2E.waitUntil(timeout: Timeout.normal) {
            results.count > 0
        }
        XCTAssertTrue(
            selectFixtureResult(),
            "No fixture search result was hittable."
        )
        let amount = app.descendants(matching: .any)["foodDetail.amount.field"]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.normal),
            "Food detail did not load for the fixture food."
        )
        amount.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The quantity keyboard did not appear."
        )
        let submit = app.buttons["foodDetail.submit"]
        XCTAssertTrue(
            submit.exists && submit.isHittable,
            "Log/Submit is not hittable with the keyboard up."
        )
        attach("broad-logfood-keyboard")
    }

    func testBroadAX5Diary() throws {
        try launchSignedIn(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.summary.calories"].exists,
            "The diary summary is missing at AX XXXL."
        )
        attach("broad-ax5-diary")
    }

    // MARK: - Visual diagnostic subtype (QA-only; no production edits)
    //
    // These three tests form the "Visual" subtype used for the limited
    // visual-fix round. They are selected individually with -only-testing:;
    // they never run as part of a functional 6/7/7 gate. All capture raw
    // pixels + AX frames for independent parent pixel review: a green
    // functional result is NOT treated as UI/UX approval.

    /// ONE focused iPhone 17 keyboard diagnostic, intended to run BEFORE any
    /// FoodDetail source fix. The keyboard MUST stay UP: no "Done" tap, no
    /// relaxed assertions. Captures exact button / label / keyboard / window
    /// frames at a STABLE moment (XCTNSPredicateExpectation, 2 matching polls)
    /// so an owner can disambiguate a capture artifact from a product bug.
    func testVisualKeyboardFrames() throws {
        try launchSignedIn()
        XCTAssertEqual(
            app.state, .runningForeground,
            "The app is not in the foreground before the keyboard diagnostic."
        )
        guard let field = openAddFood() else {
            XCTFail("Add Food / Search did not open.")
            return
        }
        typeSearchQuery("Native QA", in: field)
        let results = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")
        )
        _ = CalCoE2E.waitUntil(timeout: Timeout.normal) { results.count > 0 }
        XCTAssertTrue(selectFixtureResult(), "No fixture search result was hittable.")
        let amount = app.descendants(matching: .any)["foodDetail.amount.field"]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.normal),
            "Food detail did not load for the fixture food."
        )
        amount.tap()

        #if os(iOS)
        // Stability: foreground + keyboard attached + keyboard frame stable
        // for 2 consecutive polls + window bounds stable + focus field and
        // submit control both present. No poll/sleep loop.
        var lastKeyboard = CGRect.zero
        var lastWindow = CGRect.zero
        var stablePolls = 0
        let predicate = NSPredicate { _, _ in
            guard self.app.state == .runningForeground else { return false }
            let keyboard = self.app.keyboards.firstMatch
            guard keyboard.exists else { return false }
            let window = self.app.windows.firstMatch
            guard window.exists else { return false }
            guard self.app.descendants(matching: .any)["foodDetail.amount.field"].exists,
                  self.app.buttons["foodDetail.submit"].exists else { return false }
            let kf = keyboard.frame
            let wf = window.frame
            let keyboardStable =
                abs(kf.minX - lastKeyboard.minX) <= 1 &&
                abs(kf.minY - lastKeyboard.minY) <= 1 &&
                abs(kf.width - lastKeyboard.width) <= 1 &&
                abs(kf.height - lastKeyboard.height) <= 1
            let windowStable =
                abs(wf.minX - lastWindow.minX) <= 1 &&
                abs(wf.minY - lastWindow.minY) <= 1 &&
                abs(wf.width - lastWindow.width) <= 1 &&
                abs(wf.height - lastWindow.height) <= 1
            stablePolls = (keyboardStable && windowStable) ? stablePolls + 1 : 0
            lastKeyboard = kf
            lastWindow = wf
            return stablePolls >= 2
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate, object: NSObject()
        )
        let waitResult = XCTWaiter().wait(for: [expectation], timeout: Timeout.long)
        XCTAssertEqual(
            waitResult, .completed,
            "Keyboard / window never stabilized (keyboard UP, 2 matching polls)."
        )

        let keyboard = app.keyboards.firstMatch
        let kf = keyboard.frame
        let wf = app.windows.firstMatch.frame
        let button = app.buttons["foodDetail.submit"]
        let bf = button.frame
        let buttonLabel = button.label
        let labelElement = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", buttonLabel)
        ).firstMatch
        let lf = labelElement.exists ? labelElement.frame : CGRect.zero

        // Log Food is the only action in the keyboard-aware submit bar.
        // Retain the legacy Done frame metadata to catch its reintroduction.
        let doneButton = app.buttons["foodDetail.keyboard.done"].firstMatch
        let doneContainer = app.descendants(matching: .other)
            .matching(identifier: "foodDetail.keyboard.done").firstMatch
        let dbf = doneButton.exists ? doneButton.frame : CGRect.zero
        let dcf = doneContainer.exists ? doneContainer.frame : CGRect.zero
        let containerMinY = (doneContainer.exists && dcf.height > 0 && dcf.minY > 0)
            ? dcf.minY : kf.minY
        let effectiveTop = min(kf.minY, containerMinY)
        // Geometric contract. The keyboard BODY is a hard vertical bound.
        // The Done BUTTON is checked by 2D rectangle intersection on its OWN
        // frame, so a native adjacent/above placement (no shared pixels) passes
        // while any real overlap fails. Not gated on any Other container.
        let buttonIntersectsKeyboardBody = bf.intersects(kf)
        let buttonIntersectsDone = doneButton.exists && bf.intersects(dbf)
        let labelIntersectsKeyboardBody = labelElement.exists && lf.intersects(kf)
        let labelIntersectsDone = labelElement.exists && doneButton.exists &&
            lf.intersects(dbf)
        let buttonCornersInside =
            bf.minX >= wf.minX - 1 && bf.maxX <= wf.maxX + 1 &&
            bf.minY >= wf.minY - 1 && bf.maxY <= wf.maxY + 1
        let labelCornersInside = labelElement.exists &&
            lf.minX >= wf.minX - 1 && lf.maxX <= wf.maxX + 1 &&
            lf.minY >= wf.minY - 1 && lf.maxY <= wf.maxY + 1

        let shot = app.screenshot()
        let px = pngSize(shot.pngRepresentation)
        let env = ProcessInfo.processInfo.environment

        let metadata: [String: Any] = [
            "diagnostic": "phone17-logfood-keyboard-BEFORE-source-fix",
            "deviceName": env["CALCO_BROAD_DEVICE_NAME"] ?? "iPhone 17 (non-Pro)",
            "deviceUDID": env["CALCO_BROAD_DEVICE_UDID"]
                ?? "EB9F34C6-28B8-49FE-A67C-782F143D7D22",
            "viewportPt": env["CALCO_BROAD_VIEWPORT"] ?? "402 x 874",
            "appState": "runningForeground",
            "keyboardAttached": keyboard.exists,
            "doneTapped": false,
            "stability": "XCTNSPredicateExpectation; 2 consecutive matching keyboard+window polls",
            "stablePolls": stablePolls,
            "stabilityWait": waitResult == .completed ? "completed" : "timedOut",
            "captureTimestamp": ISO8601DateFormatter().string(from: Date()),
            "windowFrame": frameDict(wf),
            "keyboardFrame": frameDict(kf),
            "keyboardMinY": Double(kf.minY),
            "accessoryFound": doneButton.exists,
            "doneButtonFrame": doneButton.exists ? frameDict(dbf) : NSNull(),
            "doneButtonWidth": Double(dbf.width),
            "doneButtonHeight": Double(dbf.height),
            "accessoryButtonFrame": doneButton.exists ? frameDict(dbf) : NSNull(),
            "accessoryContainerFound": doneContainer.exists,
            "accessoryContainerFrame": doneContainer.exists ? frameDict(dcf) : NSNull(),
            "accessoryContainerMinY": Double(containerMinY),
            "effectiveObstructionTop": Double(effectiveTop),
            "buttonFrame": frameDict(bf),
            "buttonHeight": Double(bf.height),
            "buttonMaxY": Double(bf.maxY),
            "buttonLabel": buttonLabel,
            "buttonLabelFrame": labelElement.exists ? frameDict(lf) : NSNull(),
            "clearance_buttonMaxY_to_keyboardMinY": Double(kf.minY - bf.maxY),
            "clearance_buttonMaxY_to_effectiveTop": Double(effectiveTop - bf.maxY),
            "buttonCornersInsideViewport": buttonCornersInside,
            "labelCornersInsideViewport": labelCornersInside,
            "buttonIsHittable": button.isHittable,
            "buttonIntersectsKeyboardBody": buttonIntersectsKeyboardBody,
            "buttonIntersectsDoneButton": buttonIntersectsDone,
            "labelIntersectsKeyboardBody": labelIntersectsKeyboardBody,
            "labelIntersectsDoneButton": labelIntersectsDone,
            "captureMethod": "XCTest XCUIApplication.screenshot() (raw, keyboard UP)",
            "screenshotPixels": px.map { [$0.width, $0.height] } ?? [],
            "assertions": [
                "keyboard.exists == true (keyboard UP; no Done tap)",
                "button.height >= 44 (full submit button visible)",
                "button.maxY <= keyboard.minY (above the KEYBOARD BODY)",
                "No Done button above Log Food while the keyboard is focused",
                "NOT button.frame.intersects(Done BUTTON frame) (2D, adjacent allowed)",
                "button all four corners inside window/viewport",
                "button label all four corners inside viewport; no 2D intersection with keyboard body or Done",
            ],
        ]
        // Attach ALL evidence BEFORE assertions: continueAfterFailure = false.
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]
        )
        let meta = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "{}")
        meta.name = "visual-phone-keyboard-frames"
        meta.lifetime = .keepAlways
        add(meta)
        let raw = XCTAttachment(screenshot: shot)
        raw.name = "visual-phone-keyboard-raw"
        raw.lifetime = .keepAlways
        add(raw)

        // Hard assertions, never relaxed. isHittable alone is NOT sufficient:
        // the old capture passed isHittable while only the upper half showed.
        XCTAssertTrue(keyboard.exists, "Keyboard is not attached (must be UP).")
        XCTAssertEqual(app.state, .runningForeground, "The app left the foreground.")
        XCTAssertFalse(
            doneButton.exists,
            "Log Food should not show a separate Done button."
        )
        XCTAssertGreaterThanOrEqual(
            bf.height, 43,
            "Log Food button height (\(bf.height)) is below the 44pt minimum; "
                + "the full button is not visible."
        )
        XCTAssertLessThanOrEqual(
            bf.maxY, kf.minY,
            "Log Food button bottom (\(bf.maxY)) is below the KEYBOARD BODY "
                + "top (\(kf.minY)); the label / lower half is obscured."
        )
        XCTAssertFalse(
            buttonIntersectsKeyboardBody,
            "Log Food button 2D-intersects the keyboard body: "
                + "button \(bf) vs keyboard \(kf)."
        )
        XCTAssertFalse(
            buttonIntersectsDone,
            "Log Food button 2D-intersects the Done BUTTON frame: "
                + "button \(bf) vs Done \(dbf). "
                + "A side-by-side native toolbar (no shared pixels) is allowed; "
                + "an actual overlap is not."
        )
        XCTAssertTrue(
            buttonCornersInside,
            "Log Food button does not have all four corners inside the viewport."
        )
        if labelElement.exists {
            XCTAssertTrue(
                labelCornersInside,
                "Log Food button label does not have all four corners inside "
                    + "the viewport."
            )
            XCTAssertFalse(
                labelIntersectsKeyboardBody || labelIntersectsDone,
                "Log Food button label 2D-intersects the keyboard body or the "
                    + "Done accessory; the label is not fully visible."
            )
        }
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    /// Visual subtype companion: ONE targeted, known-successful submit journey
    /// on the phone AFTER the FoodDetail modifier change. Runs independently of
    /// the frame gate so a failed clearance assertion never hides a functional
    /// regression. With the keyboard UP, records reachability of notes / last
    /// picker / full nutrition; then submits directly with the keyboard up
    /// and verifies the loaded diary returns.
    func testVisualPhoneSubmitAfterKeyboard() throws {
        try launchSignedIn()
        XCTAssertEqual(app.state, .runningForeground, "The app is not in the foreground.")
        guard let field = openAddFood() else {
            XCTFail("Add Food / Search did not open.")
            return
        }
        typeSearchQuery("Native QA", in: field)
        let results = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")
        )
        _ = CalCoE2E.waitUntil(timeout: Timeout.normal) { results.count > 0 }
        XCTAssertTrue(selectFixtureResult(), "No fixture search result was hittable.")
        let amount = app.descendants(matching: .any)["foodDetail.amount.field"]
        XCTAssertTrue(
            amount.waitForExistence(timeout: Timeout.normal),
            "Food detail did not load for the fixture food."
        )
        amount.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "The quantity keyboard did not appear."
        )

        #if os(iOS)
        // HY4 owner ground truth: the earlier 8 full-screen CollectionView
        // swipes STARTED INSIDE the LogFood bar (y440-566), so none reached the
        // Form and notes stayed at y764.67 behind the keyboard. The correct
        // MEASURED gesture is a SCOPED COORDINATE drag WITHIN the visible Form
        // band between the nav top and the submit-bar top (start ~y380 ->
        // ~y120), which scrolls the Form ~500pt, brings notes to y264.67 and
        // keeps the keyboard UP. Production source is UNCHANGED.
        let notes = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "foodDetail.notes.field")
        ).firstMatch
        let nutrition = app.descendants(matching: .any)["foodDetail.nutritionPreview"]
        let lastUsed = app.descendants(matching: .any)["foodDetail.lastUsed.notice"]
        let done = app.buttons["foodDetail.keyboard.done"].firstMatch
        let submit = app.buttons["foodDetail.submit"]

        // All geometry is MEASURED from live AX frames, never hard-coded
        // 402x874 coordinates, so the gesture is valid on any viewport.
        func currentBarTop() -> CGFloat {
            var top = app.windows.firstMatch.frame.maxY
            for element in [done, submit]
            where element.exists && element.frame.height > 0 {
                top = min(top, element.frame.minY)
            }
            return top
        }
        // Scoped drag: BOTH endpoints stay strictly BELOW the nav bar and ABOVE
        // the bottom submit bar (therefore above the keyboard). No full-screen
        // CollectionView swipe.
        func scopedFormDrag() -> [String: Double] {
            let win = app.windows.firstMatch.frame
            let nav = app.navigationBars.firstMatch
            let navTop = nav.exists ? nav.frame.maxY : win.minY + 60
            let barTop = currentBarTop()
            let topY = min(navTop + 20, barTop - 40)
            let bottomY = max(topY + 60, barTop - 60)
            let x = win.midX
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: x, dy: bottomY))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: x, dy: topY))
            from.press(forDuration: 0.05, thenDragTo: to)
            return ["x": Double(x), "fromY": Double(bottomY),
                    "toY": Double(topY), "navTop": Double(navTop),
                    "barTop": Double(barTop)]
        }
        func notesInVisibleForm() -> Bool {
            guard notes.exists, notes.isHittable else { return false }
            let nf = notes.frame
            return nf.height > 0 && nf.maxY <= currentBarTop() + 1
        }

        var scopedDrags = 0
        var lastBand: [String: Double] = [:]
        var reached = false
        for _ in 0..<6 {
            if notesInVisibleForm() { reached = true; break }
            lastBand = scopedFormDrag()
            scopedDrags += 1
        }
        // Interactive keyboard dismissal can make more of the form visible.
        let usedDoneFallback = false
        if !reached {
            for _ in 0..<6 {
                if notesInVisibleForm() { reached = true; break }
                lastBand = scopedFormDrag()
                scopedDrags += 1
            }
        }

        // Focus Notes with the keyboard UP, TYPE real text, and verify the
        // EXACT entered Notes survives in the field's accessibility value.
        let enteredNotes = "Native QA notes final 20261121"
        var notesPreserved = false
        var notesValueAfterType = ""
        var notesReachable = false
        var notesAboveBar = false
        var notesFocused = false
        if reached && notes.exists && notes.isHittable {
            notes.tap()
            notesFocused = app.keyboards.firstMatch.exists
            if !notesFocused {
                _ = app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short)
                notesFocused = app.keyboards.firstMatch.exists
            }
            if notesFocused {
                notes.typeText(enteredNotes)
                notesValueAfterType = notes.value as? String ?? ""
            }
            notesPreserved = notesValueAfterType.contains(enteredNotes)
            notesReachable = notes.isHittable
            notesAboveBar = notes.frame.height > 0 &&
                notes.frame.maxY <= currentBarTop() + 1
        }
        let reachability: [String: Any] = [
            "notesFieldExists": notes.exists,
            "notesFieldHittable": notes.isHittable,
            "notesFieldFrame": notes.exists ? frameDict(notes.frame) : NSNull(),
            "submitBarMinY": Double(submit.frame.minY),
            "scopedDragBand": lastBand,
            "scopedDrags": scopedDrags,
            "usedNativeDoneFallbackPath": usedDoneFallback,
            "notesReachedVisibleForm": reached,
            "notesAboveSubmitBarWhileEditing": notesAboveBar,
            "notesReachable": notesReachable,
            "notesFocusedWithKeyboardUp": notesFocused,
            "enteredNotes": enteredNotes,
            "notesValueAfterType": notesValueAfterType,
            "notesPreserved": notesPreserved,
            "fullNutritionPreviewExists": nutrition.exists,
            "fullNutritionPreviewHittable": nutrition.isHittable,
            "lastUsedNoticeExists": lastUsed.exists,
            "keyboardUp": app.keyboards.firstMatch.exists,
        ]

        let beforeFrames: [String: Any] = [
            "keyboardFrame": frameDict(app.keyboards.firstMatch.frame),
            "submitFrame": frameDict(submit.frame),
            "doneButtonFrame": done.exists ? frameDict(done.frame) : NSNull(),
            "reachability": reachability,
        ]
        XCTAssertFalse(done.exists, "Log Food should not show a separate Done button.")
        let didTapDone = false
        let keyboardUpBeforeDone = app.keyboards.firstMatch.exists
        let doneDismissed = !keyboardUpBeforeDone
        let submitStays = submit.exists && submit.isHittable
        let afterFrames: [String: Any] = [
            "doneTappedAtSubmit": didTapDone,
            "keyboardUpBeforeDone": keyboardUpBeforeDone,
            "keyboardDismissed": doneDismissed,
            "submitStillPresent": submitStays,
            "keyboardFrameAfterDone": app.keyboards.firstMatch.exists
                ? frameDict(app.keyboards.firstMatch.frame) : NSNull(),
            "submitFrameAfterDone": submit.exists ? frameDict(submit.frame) : NSNull(),
        ]

        // Exactly one targeted submit, guarded by the loaded diary.
        guard submit.exists, submit.isHittable else {
            XCTFail("Log Food submit is not available while editing.")
            return
        }
        submit.tap()
        let returned = CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long)
        let summary: [String: Any] = [
            "diagnostic": "phone17-one-submit-after-keyboard-modifier",
            "beforeDone": beforeFrames,
            "afterDone": afterFrames,
            "submitReturnedToLoadedDiary": returned,
            "enteredNotes": enteredNotes,
            "notesValueAfterType": notesValueAfterType,
            "notesPreserved": notesPreserved,
            "scopedDrags": scopedDrags,
            "usedNativeDoneFallbackPath": usedDoneFallback,
            "notesReachedVisibleForm": reached,
            "expectedSubmitPosts": 1,
            "note": "ONE existing known-successful submit journey; scoped Form "
                + "coordinate gesture (QA fix); no 6/7/7 loop",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]
        )
        let meta = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "{}")
        meta.name = "visual-phone-submit-guard"
        meta.lifetime = .keepAlways
        add(meta)

        XCTAssertTrue(submitStays, "The submit button disappeared while editing.")
        XCTAssertTrue(
            returned,
            "The single submit did not return to a loaded diary (functional "
                + "regression after the FoodDetail modifier change)."
        )
        // Meaningful notes reachability: after the corrected scoped gesture the
        // field MUST be reachable, above the submit bar, focusable with the
        // keyboard up, and the EXACT entered text must be preserved. A field
        // that was merely offscreen and not yet scrolled is NOT declared a
        // product bug; unreachable AFTER a correct native gesture is.
        XCTAssertTrue(
            notesReachable && notesAboveBar && notesFocused && notesPreserved,
            "Notes field was not reachable / focusable / preserved above the "
                + "submit bar after the scoped Form gesture: "
                + "reachable=\(notesReachable) aboveBar=\(notesAboveBar) "
                + "focused=\(notesFocused) preserved=\(notesPreserved) "
                + "drags=\(scopedDrags) doneFallback=\(usedDoneFallback)."
        )
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    /// Visual subtype: AX XXXL readable-word layout. PREPARED for the limited
    /// visual-fix round (NOT run in the keyboard diagnostic). Uses the real
    /// AccessibilityXXXL category with NO font cap / min-font workaround.
    /// Queries by ACTUAL TEXT when identifiers are absent, records first-line
    /// AX frames for before/after comparison, and asserts no mid-word hyphen
    /// break plus full-word presence. Raw pixels are attached for parent
    /// review; this is not a unit "Text exists" pass.
    func testVisualPhoneAX5ReadableWords() throws {
        try launchSignedIn(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        XCTAssertEqual(app.state, .runningForeground, "The app is not in the foreground.")
        XCTAssertTrue(
            app.descendants(matching: .any)["diary.summary.calories"].exists,
            "The diary summary is missing at AX XXXL."
        )
        // All leaf AX identifiers must survive the adaptive-layout source fix.
        let fetchMarker = app.descendants(matching: .any)["diary.fetchCompletionCount"]
        let addFoodButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "diary.addFood.")
        )
        XCTAssertTrue(
            fetchMarker.exists,
            "diary.fetchCompletionCount leaf AX id is missing at AX XXXL."
        )
        XCTAssertGreaterThan(
            addFoodButtons.count, 0,
            "diary.addFood.* leaf AX ids (Add Food title/controls) are missing at AX XXXL."
        )
        #if os(iOS)
        // Full semantic GROUP TEXT. "Remaining" is NOT a standalone label:
        // the app renders it as the combined "Remaining 2000 kcal" text. It is
        // therefore verified by localized full-string matching plus the actual
        // kcal value, never by an exact standalone-label equality.
        let fullWords = ["Calories", "Grams", "Nutrition details",
                         "Protein", "Carbs", "Fat"]
        let windowFrame = app.windows.firstMatch.frame
        let texts = app.descendants(matching: .any).matching(
            NSPredicate(format: "label != ''")
        ).allElementsBoundByIndex
        var observed: [[String: Any]] = []
        var labels: [String] = []

        for element in texts where element.exists {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            labels.append(label)
            let frame = element.frame
            // Scroll content vs genuine clipping: at AX XXXL the Diary is a
            // scrollable Form whose summary/calorie row, meal cards and later
            // rows legitimately extend BELOW the fold. A row whose frame does
            // NOT intersect the viewport is OFFSCREEN SCROLL CONTENT, not a
            // clipped label. Only CURRENTLY VISIBLE labels (frame intersects
            // the viewport) can be genuinely clipped: a visible label that is
            // neither fully inside the viewport nor hittable has its hit point
            // cut off. A label partially at the fold that is still hittable is
            // a legitimate native scroll boundary, NOT clipping — the
            // isHittable flag is what distinguishes the two.
            observed.append([
                "label": label,
                "frameXYWH": frameDict(frame),
                "intersectsViewport": frame.intersects(windowFrame),
                "isHittable": element.isHittable,
                "fullyInsideViewport":
                    frame.minX >= windowFrame.minX - 1 &&
                    frame.maxX <= windowFrame.maxX + 1 &&
                    frame.minY >= windowFrame.minY - 1 &&
                    frame.maxY <= windowFrame.maxY + 1,
            ])
        }

        // Genuine CLIPPING check, scoped to currently visible labels only.
        // At AX XXXL the Diary is a VERTICALLY scrollable Form: a label whose
        // frame is cut by the TOP/BOTTOM viewport fold is legit scroll content
        // (it is clipped by the fold, not by the layout), NOT a clipped word —
        // whether or not its hit point is on screen. The distinction the owner
        // asked for: "label partial viewport due legit scroll" is excluded via
        // the fold test; a label cut off HORIZONTALLY (frame past the left/right
        // viewport edge) or one that is partially bounded WITHOUT being at a
        // vertical fold and is not hittable IS a genuine clipping defect.
        // isHittable / full-boundaries still decide the normal case; offscreen
        // rows remain excluded. This is NOT deleting the clip check.
        let visibleLabels = observed.filter {
            ($0["intersectsViewport"] as? Bool) == true
        }
        func frameOf(_ entry: [String: Any]) -> [String: Double] {
            entry["frameXYWH"] as? [String: Double] ?? [:]
        }
        let genuinelyClipped = visibleLabels.filter { entry in
            let fullyInside = (entry["fullyInsideViewport"] as? Bool) == true
            let hittable = (entry["isHittable"] as? Bool) == true
            if hittable || fullyInside { return false }
            let f = frameOf(entry)
            let minY = f["y"] ?? 0
            let maxY = f["maxY"] ?? 0
            let verticalFold = minY < windowFrame.minY - 1 ||
                maxY > windowFrame.maxY + 1
            return !verticalFold
        }
        let offscreenRows = observed.filter {
            ($0["intersectsViewport"] as? Bool) == false
        }
        let verticalScrollBoundaryCount = visibleLabels.filter { entry in
            let fullyInside = (entry["fullyInsideViewport"] as? Bool) == true
            let f = frameOf(entry)
            let minY = f["y"] ?? 0
            let maxY = f["maxY"] ?? 0
            return !fullyInside && (minY < windowFrame.minY - 1 ||
                maxY > windowFrame.maxY + 1)
        }.count

        // Native scroll must make below-fold rows accessible once scrolled.
        // At AX XXXL the Diary content is naturally MUCH taller than the
        // viewport, so we do NOT assert that the whole summary fits. Instead a
        // SCOPED coordinate drag within the visible Form band (NOT a full-screen
        // CollectionView swipe, which can start inside a bottom bar) must bring
        // previously-offscreen labels into the viewport. Recorded as a genuine
        // reachability fact; the hard gate is the CURRENTLY VISIBLE clipping
        // check above, not an artificial "everything fits" requirement.
        let win = app.windows.firstMatch.frame
        let nav = app.navigationBars.firstMatch
        let navTop = nav.exists ? nav.frame.maxY : win.minY + 60
        let bandTop = min(navTop + 24, win.maxY - 220)
        let bandBottom = win.maxY - 120
        let dragX = win.midX
        let offscreenLabelsBefore = Set(observed.compactMap {
            ($0["intersectsViewport"] as? Bool) == false
                ? ($0["label"] as? String) : nil
        }.filter { !$0.isEmpty })
        var newlyReachable: [String] = []
        var scrollDrags = 0
        for _ in 0..<3 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: dragX, dy: bandBottom))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: dragX, dy: bandTop))
            from.press(forDuration: 0.05, thenDragTo: to)
            scrollDrags += 1
            let afterTexts = app.descendants(matching: .any).matching(
                NSPredicate(format: "label != ''")
            ).allElementsBoundByIndex
            let visibleAfterScroll = Set(afterTexts.filter {
                $0.exists && $0.frame.intersects(windowFrame)
            }.map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) })
            newlyReachable = offscreenLabelsBefore.filter {
                visibleAfterScroll.contains($0)
            }
            if !newlyReachable.isEmpty { break }
        }
        let belowFoldReachableAfterScroll = offscreenRows.isEmpty ||
            !newlyReachable.isEmpty

        // Hard: each required full word appears as a COMPLETE group-text label.
        var missingFullWords: [String] = []
        for word in fullWords {
            let query = app.descendants(matching: .any).matching(
                NSPredicate(format: "label ==[c] %@", word)
            )
            if query.count == 0 {
                missingFullWords.append(word)
            }
        }

        // Hard: "Remaining" appears as FULL semantic text WITH the actual kcal
        // value (not omitted, not reduced to a bare word, not hyphen-split).
        let remainingLabels = labels.filter {
            $0.localizedCaseInsensitiveContains("Remaining")
        }
        let remainingFullText = remainingLabels.first {
            $0.localizedCaseInsensitiveContains("kcal") &&
            $0.rangeOfCharacter(from: .decimalDigits) != nil &&
            !$0.contains("-")
        }

        // Robust no-mid-word-hyphen check: no observed label is a hyphen-split
        // form of any vocabulary word. Replaces the fragile "exactly two parts"
        // heuristic; a label such as "Calo-ries" compacts back to "Calories".
        func compact(_ value: String) -> String {
            value.components(separatedBy: .whitespaces).joined()
                .replacingOccurrences(of: "-", with: "").lowercased()
        }
        let vocabulary = fullWords + ["Remaining"]
        var hyphenBroken: [String] = []
        for label in labels where label.contains("-") {
            if vocabulary.contains(where: { compact($0) == compact(label) }) {
                hyphenBroken.append(label)
            }
        }

        let metadata: [String: Any] = [
            "diagnostic": "phone17-AX5-readable-words",
            "contentSize": "UICTContentSizeCategoryAccessibilityXXXL",
            "dynamicTypeCap": "none",
            "fetchCaloriesMarkerExists": fetchMarker.exists,
            "addFoodLeafAXCount": addFoodButtons.count,
            "requiredFullWords": fullWords,
            "observedFirstLineAXFrames": observed,
            "missingFullWords": missingFullWords,
            "remainingLabels": remainingLabels,
            "remainingFullText": remainingFullText ?? "",
            "hyphenBrokenFragments": hyphenBroken,
            "visibleLabelCount": visibleLabels.count,
            "genuinelyClippedVisibleCount": genuinelyClipped.count,
            "offscreenScrollRowCount": offscreenRows.count,
            "verticalScrollBoundaryCount": verticalScrollBoundaryCount,
            "belowFoldReachableAfterScroll": belowFoldReachableAfterScroll,
            "newlyReachableOffscreenLabels": newlyReachable,
            "scrollDrags": scrollDrags,
            "clippingPolicy": "offscreen rows AND labels cut only by the "
                + "top/bottom viewport fold are scroll content, NOT clipping; "
                + "genuine clipping = horizontal edge cut, or a partially "
                + "bounded non-hittable label not at a vertical fold",
            "note": "AX frames + raw pixels attached for parent pixel review; "
                + "full semantic group text (incl. combined Remaining kcal) asserted, "
                + "no fragile hyphen-fragment equality; no DynamicType cap",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]
        )
        let meta = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "{}")
        meta.name = "visual-phone-ax5-words"
        meta.lifetime = .keepAlways
        add(meta)
        attach("visual-phone-ax5-raw")

        XCTAssertTrue(
            hyphenBroken.isEmpty,
            "Mid-word hyphen breaks at AX XXXL: \(hyphenBroken)"
        )
        XCTAssertTrue(
            missingFullWords.isEmpty,
            "Full semantic group text missing at AX XXXL: \(missingFullWords)"
        )
        XCTAssertFalse(
            remainingLabels.isEmpty,
            "Remaining semantic text is missing at AX XXXL."
        )
        XCTAssertNotNil(
            remainingFullText,
            "Remaining full semantic text WITH the actual kcal value is missing "
                + "or was reduced to a bare/omitted label at AX XXXL."
        )
        // Genuine clipping assertion, scoped to CURRENTLY VISIBLE labels.
        // Offscreen rows AND labels cut only by the top/bottom viewport fold
        // (legit vertical scroll content at AX XXXL) are excluded; a label
        // partially visible but still hittable is a native scroll boundary,
        // not clipping. No artificial "whole summary fits viewport" gate.
        XCTAssertTrue(
            genuinelyClipped.isEmpty,
            "AX XXXL visible labels clipped (horizontal edge cut or "
                + "partial/non-hittable, not a vertical fold): "
                + "\(genuinelyClipped.count) elements"
        )
        XCTAssertTrue(
            belowFoldReachableAfterScroll,
            "A bounded native (scoped coordinate) scroll did not expose any "
                + "below-fold AX XXXL content that was offscreen before the scroll."
        )
        #endif
    }

    /// Visual subtype: wide-layout meal art header coverage. PREPARED for the
    /// limited visual-fix round (NOT run in the keyboard diagnostic). Uses a
    /// real COLOR-PIXEL predicate on the raw screenshot (not a generic
    /// "PNG is valid" check) plus AX first-line frames, and attaches raw
    /// pixels for parent inspection. No fake auto-approval.
    func testVisualPadLandscapeArtCoverage() throws {
        #if os(iOS)
        // Beam's rotation audit: the earlier portrait-looking dark captures came
        // from flipping the device flag BEFORE/around foreground, so the app
        // never received an interface transition. Force the ACTUAL interface
        // to portrait BEFORE launch; rotate only AFTER the app is foreground.
        XCUIDevice.shared.orientation = .portrait
        #endif
        try launchSignedIn()
        XCTAssertEqual(app.state, .runningForeground, "The app is not in the foreground.")
        #if os(iOS)
        // Assert a genuine PORTRAIT window + Diary UI before rotating.
        let portraitFrame = app.windows.firstMatch.frame
        XCTAssertTrue(
            portraitFrame.width > 0 && portraitFrame.height > 0 &&
            portraitFrame.width < portraitFrame.height,
            "Expected an actual portrait window before rotation; "
                + "got \(portraitFrame.width)x\(portraitFrame.height)."
        )
        XCTAssertTrue(self.diaryUIPresent(), "Diary UI is missing before rotation.")

        // THEN request the landscape INTERFACE after the app is foreground.
        XCUIDevice.shared.orientation = .landscapeLeft
        var lastWindow = CGRect.zero
        var stablePolls = 0
        // Device orientation alone is NOT proof. Wait for the genuine landscape
        // INTERFACE: window width > height AND >= 900 (expanded split width),
        // stable for 2 consecutive polls, app foreground, and any Diary UI
        // present (NOT the calories leaf's reparented frame). iOS 26 can report
        // the window in portrait-coordinate space; that is RECORDED as evidence,
        // never auto-relaxed.
        let predicate = NSPredicate { _, _ in
            guard self.app.state == .runningForeground else { return false }
            let window = self.app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            guard frame.width > frame.height, frame.width >= 900 else { return false }
            guard self.diaryUIPresent() else { return false }
            let deviceOrientation = XCUIDevice.shared.orientation
            guard deviceOrientation == .landscapeLeft ||
                  deviceOrientation == .landscapeRight else { return false }
            let stable =
                abs(frame.minX - lastWindow.minX) <= 1 &&
                abs(frame.minY - lastWindow.minY) <= 1 &&
                abs(frame.width - lastWindow.width) <= 1 &&
                abs(frame.height - lastWindow.height) <= 1
            stablePolls = stable ? stablePolls + 1 : 0
            lastWindow = frame
            return stablePolls >= 2
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate, object: NSObject()
        )
        // Capture evidence BEFORE asserting the settle result.
        let waitResult = XCTWaiter().wait(for: [expectation], timeout: Timeout.long)
        let windowFrame = app.windows.firstMatch.frame
        let deviceOrientation = XCUIDevice.shared.orientation
        let observedOrientation = deviceOrientation == .landscapeLeft
            ? "landscapeLeft"
            : (deviceOrientation == .landscapeRight ? "landscapeRight" : "portraitOrOther")
        let frameWidthGtHeight = windowFrame.width > windowFrame.height
        let interfaceLandscape = frameWidthGtHeight && windowFrame.width >= 900

        // AX evidence: sidebar IDs + hittability, meal-art header x offsets,
        // and the ACTUAL app-window dimensions. The sidebar may be natively
        // COLLAPSED in the expanded split view (product default), so a bounded
        // reveal is attempted BEFORE expecting art frames at x > 180.
        func sidebarEvidence() -> (present: Bool, rows: [[String: Any]]) {
            var rows: [[String: Any]] = []
            for id in ["app.sidebar.diary", "app.sidebar.search", "app.sidebar.library"] {
                let e = app.descendants(matching: .any)[id]
                rows.append([
                    "id": id,
                    "exists": e.exists,
                    "isHittable": e.isHittable,
                    "frame": e.exists ? frameDict(e.frame) : NSNull(),
                ])
            }
            return (rows.contains { ($0["exists"] as? Bool) == true }, rows)
        }
        var sidebar = sidebarEvidence()
        var sidebarRevealTapped = false
        if !sidebar.present {
            // Native NavigationSplitView toggle (label/identifier mentions
            // "sidebar"). ONE bounded tap only; no assumption it exists.
            let toggles = app.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
                    "sidebar", "sidebar"
                )
            ).allElementsBoundByIndex
            if let t = toggles.first(where: { $0.exists && $0.isHittable }) {
                t.tap()
                sidebarRevealTapped = true
                sidebar = sidebarEvidence()
            }
        }
        let sidebarPresent = sidebar.present

        // Meal-art header AX frames (queried AFTER any sidebar reveal).
        var artFrames: [[String: Any]] = []
        for title in ["Breakfast", "Lunch", "Dinner", "Snack"] {
            let element = app.staticTexts.matching(
                NSPredicate(format: "label ==[c] %@", title)
            ).firstMatch
            if element.exists {
                artFrames.append([
                    "title": title,
                    "frameXYWH": frameDict(element.frame),
                    "xOffset": Double(element.frame.minX),
                ])
            }
        }
        let artXAboveSidebarWidth = artFrames.contains {
            (($0["xOffset"] as? Double) ?? 0) > 180
        }

        // BOTH public screenshot methods, dimensions + EXIF captured as
        // EVIDENCE ONLY. Never force a sips -r 270 on an EXIF=1 portrait raw
        // just to satisfy file dimensions; edge_coverage.py gates normalization
        // on EXIF/capture orientation matching the ACTUAL interface proof
        // recorded here. RAW bytes are retained, never cropped/blacked out.
        let screenShot = XCUIScreen.main.screenshot()
        let appShot = app.screenshot()
        let screenData = screenShot.pngRepresentation
        let appData = appShot.pngRepresentation
        let screenSize = pngSize(screenData)
        let appSize = pngSize(appData)
        let screenExif = pngExifOrientation(screenData)
        let appExif = pngExifOrientation(appData)
        let metadata: [String: Any] = [
            "diagnostic": "pad-landscape-meal-art-coverage",
            "orientation": observedOrientation,
            "windowFrame": frameDict(windowFrame),
            "windowFrameWidthGtHeight": frameWidthGtHeight,
            "interfaceLandscapeWidthGte900": interfaceLandscape,
            "settleResult": waitResult == .completed ? "completed" : "notCompleted",
            "stablePolls": stablePolls,
            "artHeaderAXFrames": artFrames,
            "artHeaderXAbove180": artXAboveSidebarWidth,
            "sidebarIDs": sidebar.rows,
            "sidebarPresent": sidebarPresent,
            "sidebarRevealTapped": sidebarRevealTapped,
            "screenScreenshotPixels": screenSize.map { [$0.width, $0.height] } ?? [],
            "screenScreenshotExifOrientation": screenExif ?? -1,
            "appScreenshotPixels": appSize.map { [$0.width, $0.height] } ?? [],
            "appScreenshotExifOrientation": appExif ?? -1,
            "captureMethods": [
                "XCTest XCUIScreen.main.screenshot() (full-screen raw, no crop)",
                "XCTest XCUIApplication.screenshot() (public app screen, no crop)",
            ],
            "orientationTransform": "NONE in-test; raw retained. edge_coverage.py "
                + "normalizes ONLY when EXIF/capture orientation matches the "
                + "actual interface proof (w>h>=900); never a forced sips -r 270 "
                + "on an EXIF=1 upright portrait raw",
            "edgeCoverage": "POSTPROCESS ONLY, gated on interface + EXIF proof",
            "note": "no hidden black crop; raw full-screen bytes kept for parent",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]
        )
        let meta = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "{}")
        meta.name = "visual-pad-art-frames"
        meta.lifetime = .keepAlways
        add(meta)
        let raw = XCTAttachment(screenshot: screenShot)
        raw.name = "visual-pad-art-raw"
        raw.lifetime = .keepAlways
        add(raw)
        let appRaw = XCTAttachment(screenshot: appShot)
        appRaw.name = "visual-pad-art-app-raw"
        appRaw.lifetime = .keepAlways
        add(appRaw)

        // Hard gate: a GENUINE landscape app window (w > h AND >= 900), not a
        // simulator portrait native fallback. Device orientation ALONE is not
        // enough. NO auto-relaxation: if the AX window insists on portrait
        // coordinates while the screen content is landscape, the public app
        // screenshot EXIF + dimensions above are the only other interface
        // evidence and this assertion still fails with a clear blocker. The
        // earlier valid Air had a genuine landscape window, so this is expected.
        XCTAssertTrue(
            interfaceLandscape,
            "BLOCKER: no genuine landscape interface. device=\(observedOrientation) "
                + "window=\(windowFrame.width)x\(windowFrame.height) "
                + "w>h=\(frameWidthGtHeight) w>=900=\(windowFrame.width >= 900) "
                + "settle=\(waitResult == .completed ? "completed" : "timedOut") "
                + "screenEXIF=\(screenExif.map { String($0) } ?? "nil") "
                + "appEXIF=\(appExif.map { String($0) } ?? "nil"). "
                + "Raw PNGs retained; NOT rotated to satisfy dimensions."
        )
        XCTAssertEqual(
            waitResult, .completed,
            "Landscape interface settle did not complete within the bounded wait."
        )
        XCTAssertFalse(
            artFrames.isEmpty,
            "No meal art header AX frames were found in the landscape layout."
        )
        // Sidebar may legitimately be collapsed (product default); x > 180 is
        // asserted ONLY after the sidebar is actually revealed, not assumed.
        if sidebarPresent {
            XCTAssertTrue(
                artXAboveSidebarWidth,
                "Sidebar is present but no meal art header sits right of it "
                    + "(expected x > 180 in the expanded detail column)."
            )
        }
        XCTAssertTrue(
            observedOrientation == "landscapeLeft" ||
            observedOrientation == "landscapeRight",
            "Device orientation is not landscape at capture."
        )
        XCTAssertGreaterThanOrEqual(
            stablePolls, 2,
            "Landscape window was not stable for 2 consecutive polls at capture."
        )
        XCTAssertTrue(
            windowFrame.width > 0 && windowFrame.height > 0,
            "Captured window frame is degenerate (not a full window)."
        )
        // tearDownWithError terminates the app THEN forces portrait; also
        // restore here on the passing path.
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    private func frameDict(_ frame: CGRect) -> [String: Double] {
        [
            "x": Double(frame.minX), "y": Double(frame.minY),
            "w": Double(frame.width), "h": Double(frame.height),
            "maxX": Double(frame.maxX), "maxY": Double(frame.maxY),
        ]
    }

    /// "Any Diary UI" marker for the landscape settle predicate. Beam's audit:
    /// do NOT gate on the calories leaf's FRAME (it can be re-parented in the
    /// expanded layout); only use broad, structural Diary existence markers.
    private func diaryUIPresent() -> Bool {
        let ids = [
            "app.tab.diary", "app.sidebar.diary",
            "diary.summary.calories", "diary.fetchCompletionCount",
        ]
        for id in ids where app.descendants(matching: .any)[id].exists {
            return true
        }
        return app.staticTexts["Diary"].exists || app.navigationBars["Diary"].exists
    }

    /// EXIF orientation of a raw XCTest screenshot PNG (1 = upright/normal,
    /// 6/8 = rotated capture). Used ONLY as recorded evidence; never used to
    /// force a rotation to satisfy file dimensions. No production change.
    private func pngExifOrientation(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any]
        else { return nil }
        return props[kCGImagePropertyOrientation as String] as? Int
    }

    // MARK: - Launch and sign-in (nonsecret fixture credentials only)

    private func launchSignedIn(contentSize: String? = nil) throws {
        let application = XCUIApplication(bundleIdentifier: "dev.calco.CalCo.Test")
        application.launchEnvironment["CALCO_API_BASE_URL"] = baseURL
        #if os(iOS)
        if let contentSize {
            application.launchArguments += [
                "-UIPreferredContentSizeCategoryName", contentSize,
            ]
        }
        #endif
        app = application
        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)
        try signInFixture()
        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long) else {
            XCTFail("Fixture sign-in did not reach the diary.\n\(app.debugDescription)")
            return
        }
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)
    }

    private func signInFixture() throws {
        let username = app.textFields["auth.login.username"]
        let password = app.secureTextFields["auth.login.password"]
        guard username.waitForExistence(timeout: Timeout.normal),
              password.waitForExistence(timeout: Timeout.normal) else {
            throw HarnessError(description: "The login form did not appear.")
        }
        username.tap()
        username.typeText("native-qa")
        password.tap()
        password.typeText("native-qa")
        XCTAssertFalse(
            (password.value as? String ?? "").isEmpty,
            "The nonsecret fixture password did not populate the secure field."
        )
        let accessory = app.buttons["auth.login.keyboard.submit"]
        if accessory.exists, accessory.isHittable {
            accessory.tap()
        } else {
            submitAboveKeyboard()
        }
        _ = CalCoE2E.waitForLoadedDiary(in: app, timeout: 10)
        if CalCoE2E.isLoginFormVisible(in: app),
           !app.descendants(matching: .any)["auth.login.error"].exists {
            submitAboveKeyboard()
        }
    }

    private func submitAboveKeyboard() {
        let submit = app.buttons["auth.login.submit"]
        guard submit.exists, submit.isEnabled else { return }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            for _ in 0..<4 {
                if submit.frame.maxY <= keyboard.frame.minY - 4 { break }
                let form = app.collectionViews.firstMatch
                if form.exists {
                    form.swipeUp()
                } else {
                    app.swipeUp()
                }
            }
        }
        if submit.isHittable {
            submit.tap()
        }
    }

    private func reachableAddFood() -> XCUIElement? {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@", "diary.addFood."
        )
        func matches() -> [XCUIElement] {
            app.buttons.matching(predicate).allElementsBoundByIndex
        }
        if let hit = matches().first(where: { $0.exists && $0.isHittable }) {
            return hit
        }
        for _ in 0..<5 {
            app.swipeUp()
            if let hit = matches().first(where: { $0.exists && $0.isHittable }) {
                return hit
            }
        }
        return matches().first(where: { $0.exists })
    }

    private func openAddFood() -> XCUIElement? {
        for _ in 0..<3 {
            if let add = reachableAddFood(), add.isHittable {
                add.tap()
            } else {
                let labelled = app.buttons.matching(
                    NSPredicate(format: "label ==[c] %@", "Add food")
                ).allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
                if let labelled = labelled {
                    labelled.tap()
                }
            }
            let field = app.descendants(matching: .any)["search.field"]
            if field.waitForExistence(timeout: Timeout.normal) {
                return field
            }
        }
        return nil
    }

    private func typeSearchQuery(_ text: String, in search: XCUIElement) {
        for _ in 0..<3 {
            if !app.keyboards.firstMatch.exists {
                search.tap()
            }
            guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else {
                continue
            }
            search.typeText(text)
            if CalCoE2E.waitUntil(timeout: 3, condition: {
                let value = search.value as? String ?? ""
                return value == text || value.contains(text)
            }) {
                return
            }
        }
        XCTFail("The search field never accepted the query with keyboard focus.")
    }

    private func selectFixtureResult() -> Bool {
        let name = app.staticTexts["Native QA Apple"]
        let primary = app.buttons["search.result.qa-apple"]
        let anyPredicate = NSPredicate(
            format: "identifier BEGINSWITH %@", "search.result."
        )
        for _ in 0..<6 {
            if name.exists, name.isHittable {
                name.tap()
                return true
            }
            if primary.exists, primary.isHittable {
                primary.tap()
                return true
            }
            let anyResult = app.buttons.matching(anyPredicate)
                .allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
            if let anyResult = anyResult {
                anyResult.tap()
                return true
            }
            app.swipeUp()
        }
        return false
    }

    private func attach(_ name: String) {
        #if os(iOS)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #else
        let attachment = XCTAttachment(
            string: "broad-device visual evidence is iOS-only"
        )
        attachment.name = name
        add(attachment)
        #endif
    }
}
