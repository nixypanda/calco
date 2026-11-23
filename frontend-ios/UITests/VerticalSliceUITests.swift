import XCTest

// Authenticated CalCo vertical-slice UI test for the isolated Test app
// (dev.calco.CalCo.Test, http://127.0.0.1:3002). The journey is a fresh sign-in,
// a breakfast search for the seeded E2E food, a 100 Gram log, an immediate
// return to the diary, an explicit refresh, and identifier-based assertions for
// one newly observed UI row and the exact 100 kcal total delta.
//
// Design and security contracts exercised here (all implemented and tested below):
// - Secure password entry uses only the simulator shared pasteboard plus Cmd+V;
//   the test skips rather than falling back to typeText when that path is
//   unverifiable or credentials are absent. Only unmet environmental prerequisites
//   may skip; an incomplete traversal of a diary that did load is a FAILURE.
// - A real fetch is observed through diary.fetchCompletionCount (backed by an
//   actual DiaryViewModel fetch), never an already-idle button; the marker must
//   advance past recorded baselines so the automatic post-submit refresh is not
//   mistaken for the explicit one.
// - The SwiftUI List and its composite summary container are resolved as the AX
//   element that actually hosts diary content; such containers can report exists
//   without being hittable, so top detection uses visible frames, and locators
//   tolerate OS/SwiftUI AX spelling differences.
// - Refresh is found by stable identifier, then English label, then by revealing
//   the toolbar overflow menu, whose AX label/identifier vary across iOS versions.
// - The diary is scanned from an observed top edge until no new rows appear for a
//   few consecutive swipes (bottom edge); a hard swipe ceiling only guards against
//   a broken list looping forever. Labels are captured during traversal and both
//   edges are required, so "exactly one new row" is asserted without offscreen
//   re-query errors and never from a partial view.

final class VerticalSliceUITests: XCTestCase {
    private var app: XCUIApplication!

    private enum Identifier {
        static let searchField = "search.field"
        static let searchResultPrefix = "search.result."
        static let diarySummary = "diary.summary.calories"
        static let diaryLogPrefix = "diary.log."
        static let amountField = "foodDetail.amount.field"
        static let notesField = "foodDetail.notes.field"
        static let amountFieldLabel = "Amount"
        static let notesFieldLabel = "Notes"
        static let mealPicker = "foodDetail.mealSlot.picker"
        static let unitPicker = "foodDetail.unit.picker"
        static let submit = "foodDetail.submit"
        static let submitError = "foodDetail.submit.error"
        static let loginError = "auth.login.error"
        static let refresh = "diary.refresh"
        static let refreshLabel = "Refresh"
        static let refreshError = "diary.refreshError"
        static let fetchCompletionCount = "diary.fetchCompletionCount"
    }

    private enum TopSentinel {
        static let identifiers = [
            Identifier.diarySummary,
            "diary.summary.protein",
            "diary.summary.carbs",
            "diary.summary.fat",
            Identifier.fetchCompletionCount,
        ]
    }

    private enum Fixture {
        static let foodName = "E2E Test Food a2c0252a5298"
        static let amount = "100"
        static let notes = "XCUITest vertical slice log"
        static let meal = "Breakfast"
        static let unit = "Gram"
        static let expectedCalories = 100
    }

    private enum Timeout {
        static let short: TimeInterval = 8
        static let normal: TimeInterval = 20
        static let long: TimeInterval = 40
    }

    private enum Scroll {
        static let maxSwipes = 40
        static let convergenceLimit = 3
        static let topBandFraction: CGFloat = 0.4
    }

    private struct LogSnapshot {
        let entries: [String: String]
        let reachedTop: Bool
        let reachedBottom: Bool
        var isComplete: Bool { reachedTop && reachedBottom }
        var ids: Set<String> { Set(entries.keys) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try CalCoE2E.makeApp()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLogE2ETestFoodFromSelectedDayDiary() throws {
        guard CalCoE2E.supportsSecurePasswordEntry else {
            throw XCTSkip(
                "Credentialed E2E requires the iOS Simulator secure paste path; "
                    + "macOS secure password entry is not supported/verified by this simulator-only E2E harness."
            )
        }
        guard let credentials = CalCoE2E.credentials() else {
            throw XCTSkip(
                "No private E2E credentials were supplied; skipping the authenticated slice."
            )
        }

        app.launch()
        try CalCoE2E.requireFreshLogin(in: app)
        try CalCoE2E.signIn(credentials, in: app)
        CalCoE2E.dismissSavePasswordPromptWhenPresent(in: app)

        let loginError = app.descendants(matching: .any)[Identifier.loginError]
        guard CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long) else {
            XCTFail(
                loginError.exists
                    ? "Login failed: \(loginError.label)"
                    : "The selected-day diary did not load after a fresh sign-in."
            )
            return
        }
        CalCoE2E.dismissSavePasswordPrompt(in: app)

        guard waitForFetchCountAtLeast(1), let initialCount = fetchCount() else {
            XCTFail("diary.fetchCompletionCount never exposed a completed initial fetch (>= 1).")
            return
        }
        let baseline = collectLogSnapshot()
        guard baseline.isComplete else {
            XCTFail(
                "Incomplete baseline diary traversal of a loaded diary "
                    + "(top=\(baseline.reachedTop), bottom=\(baseline.reachedBottom)). "
                    + "This is a test failure, not an inconclusive skip."
            )
            return
        }
        let baselineLogIDs = baseline.ids
        guard let baselineCalories = readCaloriesAtTop() else {
            XCTFail("Could not return to the diary top to read the Calories summary.")
            return
        }

        let addFood = findAddFoodButton()
        guard let addFood else {
            XCTFail("No reachable diary.addFood.* button was found in the loaded diary.")
            return
        }
        addFood.tap()

        let search = app.descendants(matching: .any)[Identifier.searchField]
        guard search.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("search.field did not appear after Add Food.")
            return
        }
        search.tap()
        search.typeText(Fixture.foodName)

        let result = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                Identifier.searchResultPrefix,
                Fixture.foodName
            )
        ).firstMatch
        guard result.waitForExistence(timeout: Timeout.long) else {
            XCTFail("No search.result.* row matched \(Fixture.foodName).")
            return
        }
        result.tap()

        let submit = app.buttons[Identifier.submit]
        guard submit.waitForExistence(timeout: Timeout.long) else {
            XCTFail("FoodDetail did not appear after selecting the search result.")
            return
        }

        let meal = app.buttons[Identifier.mealPicker]
        guard meal.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("foodDetail.mealSlot.picker is missing.")
            return
        }
        guard selectOption(Fixture.meal, from: meal) else {
            XCTFail("The exact Breakfast meal option did not appear.")
            return
        }
        XCTAssertTrue(
            meal.label.contains(Fixture.meal),
            "The meal picker did not retain Breakfast."
        )

        let unit = app.buttons[Identifier.unitPicker]
        guard unit.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("foodDetail.unit.picker is missing.")
            return
        }
        guard selectOption(Fixture.unit, from: unit) else {
            XCTFail("The exact Gram unit option did not appear.")
            return
        }
        XCTAssertTrue(
            unit.label.contains(Fixture.unit),
            "The unit picker did not retain Gram."
        )

        let amount = formField(Identifier.amountField)
        guard amount.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("foodDetail.amount.field is missing.")
            return
        }
        XCTAssertEqual(
            amount.label,
            Identifier.amountFieldLabel,
            "foodDetail.amount.field must expose the semantic 'Amount' label."
        )
        setField(amount, to: Fixture.amount)
        XCTAssertEqual(
            amount.value as? String,
            Fixture.amount,
            "The amount field did not retain 100."
        )

        let notes = formField(Identifier.notesField)
        guard notes.waitForExistence(timeout: Timeout.normal) else {
            XCTFail("foodDetail.notes.field is missing.")
            return
        }
        XCTAssertEqual(
            notes.label,
            Identifier.notesFieldLabel,
            "foodDetail.notes.field must expose the semantic 'Notes' label."
        )
        setField(notes, to: Fixture.notes)
        XCTAssertTrue(
            (notes.value as? String)?.contains("XCUITest") == true,
            "The notes field did not retain the typed marker."
        )
        dismissKeyboardIfPresent()

        guard submit.isHittable else {
            XCTFail("foodDetail.submit is not hittable before submission.")
            return
        }
        submit.tap()

        XCTAssertTrue(
            CalCoE2E.waitForLoadedDiary(in: app, timeout: Timeout.long),
            "The app did not return to the loaded diary immediately after logging."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.submitError].exists,
            "The app showed a submit error instead of logging the food."
        )

        guard waitForFetchCountAtLeast(initialCount + 1) else {
            XCTFail("The automatic post-submit diary refresh never completed.")
            return
        }
        guard let preExplicitCount = fetchCount() else {
            XCTFail("diary.fetchCompletionCount disappeared before the explicit refresh.")
            return
        }

        guard let refresh = waitForHittableRefreshButton(), refresh.isHittable else {
            XCTFail(
                "diary.refresh was neither hittable in the toolbar nor reachable "
                    + "from the toolbar overflow menu."
            )
            return
        }
        refresh.tap()

        guard waitForFetchCountAtLeast(preExplicitCount + 1) else {
            XCTFail("The explicit diary refresh did not complete a real fetch.")
            return
        }
        XCTAssertTrue(refresh.isEnabled, "The refresh button did not return to idle.")
        XCTAssertFalse(
            app.descendants(matching: .any)[Identifier.refreshError].exists,
            "The diary refresh fetch failed."
        )

        let finalScan = collectLogSnapshot()
        guard finalScan.isComplete else {
            XCTFail(
                "Incomplete post-refresh diary traversal of a loaded diary "
                    + "(top=\(finalScan.reachedTop), bottom=\(finalScan.reachedBottom)). "
                    + "This is a test failure, not an inconclusive skip."
            )
            return
        }
        let createdIDs = finalScan.ids.subtracting(baselineLogIDs)
        XCTAssertEqual(
            createdIDs.count,
            1,
            "Expected exactly one newly observed diary.log UI row after the "
                + "explicit refresh, got \(createdIDs.count). This is a statement "
                + "about rendered rows, not the persisted backend count."
        )
        guard let newLogID = createdIDs.first else { return }

        let capturedLabel = finalScan.entries[newLogID] ?? ""
        XCTAssertTrue(
            capturedLabel.contains(Fixture.foodName),
            "The newly observed row's captured label did not contain the food name."
        )

        guard let finalCalories = readCaloriesAtTop() else {
            XCTFail("Could not return to the diary top to read the Calories summary after logging.")
            return
        }
        XCTAssertEqual(
            finalCalories - baselineCalories,
            Fixture.expectedCalories,
            "Expected 100 Gram at 100 kcal/100 g to add exactly 100 kcal."
        )
    }

    // MARK: - Completion marker

    private func fetchCount() -> Int? {
        let marker = app.descendants(matching: .any)[Identifier.fetchCompletionCount]
        guard marker.exists else { return nil }
        let raw = (marker.value as? String) ?? marker.label
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForFetchCountAtLeast(_ minimum: Int) -> Bool {
        CalCoE2E.waitUntil(timeout: Timeout.long) {
            (self.fetchCount() ?? -1) >= minimum
        }
    }

    // MARK: - Toolbar refresh discovery

    private func waitForHittableRefreshButton() -> XCUIElement? {
        var found: XCUIElement?
        _ = CalCoE2E.waitUntil(timeout: Timeout.normal) {
            found = self.findHittableRefreshButton()
            return found != nil
        }
        return found
    }

    private func hittableRefresh() -> XCUIElement? {
        let byIdentifier = app.buttons.matching(
            NSPredicate(format: "identifier == %@", Identifier.refresh)
        )
        if let button = byIdentifier.allElementsBoundByIndex.first(where: {
            $0.exists && $0.isHittable
        }) {
            return button
        }
        let byLabel = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", Identifier.refreshLabel)
        )
        return byLabel.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }

    private func findHittableRefreshButton() -> XCUIElement? {
        if let direct = hittableRefresh() { return direct }

        for overflow in toolbarOverflowControls() {
            guard overflow.exists, overflow.isHittable else { continue }
            overflow.tap()
            var revealed: XCUIElement?
            _ = CalCoE2E.waitUntil(timeout: Timeout.short) {
                revealed = self.hittableRefresh()
                return revealed != nil
            }
            if let revealed { return revealed }
        }
        return nil
    }

    private func toolbarOverflowControls() -> [XCUIElement] {
        let predicates = [
            NSPredicate(format: "label BEGINSWITH[c] %@", "more"),
            NSPredicate(format: "identifier CONTAINS[c] %@", "overflow"),
            NSPredicate(format: "identifier CONTAINS[c] %@", "toolbaritemmenu"),
            NSPredicate(format: "identifier CONTAINS[c] %@", "moreitems"),
        ]
        var controls: [XCUIElement] = []
        for predicate in predicates {
            let matches = app.descendants(matching: .any)
                .matching(predicate).allElementsBoundByIndex
            controls.append(contentsOf: matches.filter { $0.exists })
        }
        return controls
    }

    // MARK: - Field / navigation helpers

    private func formField(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func setField(_ element: XCUIElement, to value: String) {
        element.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: Timeout.short),
            "Tapping the field did not raise the keyboard."
        )
        let current = element.value as? String ?? ""
        let placeholder = element.placeholderValue ?? ""
        if !current.isEmpty, current != placeholder {
            element.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            )
        }
        element.typeText(value)
    }

    private func dismissKeyboardIfPresent() {
        let done = app.buttons.matching(
            NSPredicate(format: "label == %@", "Done")
        ).firstMatch
        if done.exists, done.isHittable {
            done.tap()
            return
        }
        if app.keyboards.firstMatch.exists, let list = diaryList() {
            list.swipeDown()
        }
    }

    private func selectOption(_ label: String, from control: XCUIElement) -> Bool {
        control.tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        guard option.waitForExistence(timeout: Timeout.short) else { return false }
        option.tap()
        return true
    }

    private func diaryList() -> XCUIElement? {
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        let existing = candidates.filter { $0.exists }
        let hasDiaryContent: (XCUIElement) -> Bool = { container in
            container.descendants(matching: .any)[Identifier.diarySummary].exists
                || container.staticTexts.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", Identifier.diaryLogPrefix)
                ).count > 0
        }
        return existing.first(where: hasDiaryContent) ?? existing.first
    }

    // MARK: - Top detection / scrolling

    private var topBandHeight: CGFloat {
        let height = app.windows.firstMatch.frame.height
        return (height > 0 ? height : 844) * Scroll.topBandFraction
    }

    private func visibleTopSentinelMinY() -> CGFloat? {
        let band = topBandHeight
        for identifier in TopSentinel.identifiers {
            let elements = app.descendants(matching: .any)
                .matching(identifier: identifier).allElementsBoundByIndex
            for element in elements where element.exists {
                let frame = element.frame
                guard frame.width > 0, frame.height > 0 else { continue }
                if frame.minY >= 0, frame.minY <= band {
                    return frame.minY
                }
            }
        }
        return nil
    }

    private func isAtTop() -> Bool {
        visibleTopSentinelMinY() != nil
    }

    @discardableResult
    private func scrollToTop() -> Bool {
        if isAtTop() { return true }
        guard let list = diaryList() else { return isAtTop() }

        var lastMinY: CGFloat?
        var stale = 0
        for _ in 0..<Scroll.maxSwipes {
            list.swipeDown()
            if isAtTop() { return true }

            let minY = visibleTopSentinelMinY()
            if let minY, let lastMinY, abs(minY - lastMinY) < 1 {
                stale += 1
                if stale >= Scroll.convergenceLimit { break }
            } else {
                stale = 0
                lastMinY = minY
            }
        }
        return isAtTop()
    }

    private func readCaloriesAtTop() -> Int? {
        guard scrollToTop() else { return nil }
        return currentCalories()
    }

    private func collectLogSnapshot() -> LogSnapshot {
        let reachedTop = scrollToTop()
        var entries = currentLogEntries()
        guard let list = diaryList() else {
            return LogSnapshot(entries: entries, reachedTop: reachedTop, reachedBottom: false)
        }

        var stale = 0
        var reachedBottom = false
        for _ in 0..<Scroll.maxSwipes {
            let previousIDs = Set(entries.keys)
            list.swipeUp()
            let visible = currentLogEntries()
            let newRows = Set(visible.keys).subtracting(previousIDs)
            entries.merge(visible) { _, new in new }

            if newRows.isEmpty {
                stale += 1
            } else {
                stale = 0
            }
            if stale >= Scroll.convergenceLimit {
                reachedBottom = true
                break
            }
        }
        return LogSnapshot(entries: entries, reachedTop: reachedTop, reachedBottom: reachedBottom)
    }

    private func currentLogEntries() -> [String: String] {
        let query = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Identifier.diaryLogPrefix)
        )
        var entries: [String: String] = [:]
        for element in query.allElementsBoundByIndex {
            let identifier = element.identifier
            guard !identifier.isEmpty else { continue }
            let label = element.label
            if !label.isEmpty {
                entries[identifier] = label
            } else if entries[identifier] == nil {
                entries[identifier] = ""
            }
        }
        return entries
    }

    private func findAddFoodButton() -> XCUIElement? {
        let query = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "diary.addFood.")
        )
        if let visible = query.allElementsBoundByIndex.first(where: {
            $0.exists && $0.isHittable
        }) {
            return visible
        }
        guard let list = diaryList() else { return nil }
        var stale = 0
        var lastIDCount = currentLogEntries().count
        for _ in 0..<Scroll.maxSwipes {
            list.swipeUp()
            if let visible = query.allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable
            }) {
                return visible
            }
            let count = currentLogEntries().count
            if count == lastIDCount {
                stale += 1
            } else {
                stale = 0
                lastIDCount = count
            }
            if stale >= Scroll.convergenceLimit { break }
        }
        return nil
    }

    private func currentCalories() -> Int? {
        let summaries = app.descendants(matching: .any)
            .matching(identifier: Identifier.diarySummary)
            .allElementsBoundByIndex
        guard !summaries.isEmpty else { return nil }

        let label = summaries
            .map(\.label)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !label.isEmpty else { return nil }

        let current = label.split(separator: "/", maxSplits: 1).first.map(String.init) ?? label
        let digits = current.filter(\.isNumber)
        return Int(digits)
    }
}
