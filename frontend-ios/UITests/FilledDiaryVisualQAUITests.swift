// ONE visual capture case: the final Diary Daily Brief with genuinely non-zero
// fixture logs, so the calorie and all three macro progress bars are filled.
// No date/menus/callback interactions and no assertions on passive hittability.
// All totals are computed here from declared per-100g food nutrition and real
// gram quantities — no presentation values are hard-coded.

#if os(iOS)

import Foundation
import UIKit
import XCTest

final class FilledDiaryVisualQAUITests: XCTestCase {
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

    private struct SeedFood {
        let name: String
        let mealSlot: String
        let kcalPer100g: Double
        let proteinPer100g: Double
        let carbsPer100g: Double
        let fatPer100g: Double
        let grams: Double

        var factor: Double { grams / 100.0 }
        var kcal: Double { kcalPer100g * factor }
        var protein: Double { proteinPer100g * factor }
        var carbs: Double { carbsPer100g * factor }
        var fat: Double { fatPer100g * factor }
    }

    // Two ordinary foods with plausible per-100g nutrition. Totals are derived
    // from these values at runtime: 1420 kcal / 92 g / 164 g / 48 g.
    private let seedFoods: [SeedFood] = [
        SeedFood(name: "Fixture Oats", mealSlot: "breakfast",
                 kcalPer100g: 380, proteinPer100g: 25, carbsPer100g: 40, fatPer100g: 12, grams: 200),
        SeedFood(name: "Fixture Rice Bowl", mealSlot: "lunch",
                 kcalPer100g: 330, proteinPer100g: 21, carbsPer100g: 42, fatPer100g: 12, grams: 200),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        try seedFixtureWithRealLogs()
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    // MARK: - Fixture seeding (loopback only)

    private func requireFixture() throws -> String {
        let url = URL(string: QA.baseURL + "/__qa/health")!
        let (data, response) = try URLSession.shared.filledDiarySyncData(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["fixture"] as? String == QA.fixtureMarker else {
            XCTFail("NativeCompletionQAMockServer fixture is not available.")
            throw NSError(domain: "FilledDiaryVisualQA", code: 1)
        }
        return try XCTUnwrap(object["today"] as? String)
    }

    private func loginCookie() throws -> String {
        var request = URLRequest(url: URL(string: QA.baseURL + "/api/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": QA.username, "password": QA.password
        ])
        let (_, response) = try URLSession.shared.filledDiarySyncData(from: request.url!, request: request)
        let header = (response as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String ?? ""
        return header.components(separatedBy: ";").first ?? header
    }

    private func seedFixtureWithRealLogs() throws {
        // Local calendar day (not UTC) — the same date the app's todayProvider uses.
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let localToday = String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970, components.month ?? 1, components.day ?? 1
        )
        let fixtureToday = try requireFixture()
        XCTAssertEqual(localToday, fixtureToday, "Fixture today and local calendar day disagree.")

        var reset = URLRequest(url: URL(string: QA.baseURL + "/__qa/reset")!)
        reset.httpMethod = "POST"
        reset.setValue("application/json", forHTTPHeaderField: "Content-Type")
        reset.httpBody = try JSONSerialization.data(withJSONObject: [
            "today": localToday, "seed_logs": false, "log_post": "success", "assistant_enabled": false
        ])
        let (_, resetResponse) = try URLSession.shared.filledDiarySyncData(from: reset.url!, request: reset)
        XCTAssertEqual((resetResponse as? HTTPURLResponse)?.statusCode, 200, "Fixture reset failed.")

        let cookie = try loginCookie()
        for food in seedFoods {
            var request = URLRequest(url: URL(string: QA.baseURL + "/api/logs/ad-hoc")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "log_date": localToday,
                "meal_slot": food.mealSlot,
                "name": food.name,
                "brand": "Fixture Nutrition",
                "quantity": ["amount": "\(food.grams)", "unit": "g"],
                "notes": "Filled Daily Brief visual QA",
                "nutrients": [
                    ["code": "ENERGY_KCAL", "amount": "\(food.kcal)", "unit": "kcal"],
                    ["code": "PROTEIN_G", "amount": "\(food.protein)", "unit": "g"],
                    ["code": "CARBS_G", "amount": "\(food.carbs)", "unit": "g"],
                    ["code": "FAT_G", "amount": "\(food.fat)", "unit": "g"],
                ],
            ])
            let (data, response) = try URLSession.shared.filledDiarySyncData(from: request.url!, request: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            XCTAssertEqual(status, 201, "Seed log POST failed for \(food.name): \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    // MARK: - App / capture helpers

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
        submit.tap()
        dismissNotNowIfNeeded()
    }

    private func dismissNotNowIfNeeded() {
        let alertButton = app.alerts.buttons["Not Now"].firstMatch
        if alertButton.waitForExistence(timeout: 1), alertButton.isHittable { alertButton.tap() }
        let fallback = app.buttons["Not Now"].firstMatch
        if fallback.waitForExistence(timeout: 1), fallback.isHittable { fallback.tap() }
    }

    private func numericValue(_ label: String) -> Double? {
        let digits = label.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard !digits.isEmpty else { return nil }
        return Double(String(String.UnicodeScalarView(digits)))
    }

    private func capture(_ name: String, targetPredicate: () -> Bool) {
        XCTAssertTrue(targetPredicate(), "Target predicate failed before '\(name)' capture.")
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

    // MARK: - Single capture case

    func testFilledDailyBriefVisualCapture() throws {
        try signIn()
        dismissNotNowIfNeeded()

        let expectedKcal = seedFoods.reduce(0.0) { $0 + $1.kcal }
        let expectedProtein = seedFoods.reduce(0.0) { $0 + $1.protein }
        let expectedCarbs = seedFoods.reduce(0.0) { $0 + $1.carbs }
        let expectedFat = seedFoods.reduce(0.0) { $0 + $1.fat }
        XCTAssertGreaterThan(expectedKcal, 0, "Seed produced no calories.")

        // Required Diary calendar/date trigger. In the reference-driven design
        // the centre date button carries the shared `diary.dateNavigation`
        // identifier and the label "Today"; the old `diary.calendar` id is gone.
        let dateTrigger = app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", "diary.dateNavigation", "Today")
        ).firstMatch
        XCTAssertTrue(dateTrigger.waitForExistence(timeout: Timeout.normal),
                      "Diary date/calendar trigger is missing.")
        XCTAssertTrue(dateTrigger.isHittable, "Diary date/calendar trigger is not hittable.")

        // Mandatory numeric logged value: passive StaticText, existence/value only.
        let calorieLabels = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@", "diary.summary.calories")
        )
        var foundLoggedValue = false
        for index in 0..<calorieLabels.count {
            let label = calorieLabels.element(boundBy: index).label
            if let value = numericValue(label), abs(value - expectedKcal) < 1 {
                foundLoggedValue = true
                break
            }
        }
        XCTAssertTrue(foundLoggedValue,
                      "Diary did not show the seeded logged calories (\(expectedKcal)).")

        // Capture first: the PNG is the primary deliverable for visual review.
        capture("FDB01-filled-daily-brief-top", targetPredicate: {
            dateTrigger.exists
                && app.staticTexts.matching(
                    NSPredicate(format: "identifier == %@", "diary.summary.calories")
                ).count > 0
        })

        // Non-zero filled progress: passive indicators, value only. Reported as
        // an observation after the capture so a brittle AX value cannot hide it.
        let indicators = app.progressIndicators
        var filled = 0
        for index in 0..<indicators.count {
            let indicator = indicators.element(boundBy: index)
            if let value = numericValue(indicator.value as? String ?? ""), value > 0 { filled += 1 }
        }
        XCTAssertGreaterThanOrEqual(filled, 4,
                                    "Expected calorie + three macro bars to be filled; got \(filled).")

        // One additional full PNG of the first illustrated Breakfast card.
        let breakfastAdd = app.buttons["diary.addFood.breakfast"].firstMatch
        var swipes = 0
        while swipes < 4 && !breakfastAdd.isHittable {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(breakfastAdd.waitForExistence(timeout: Timeout.short),
                      "Breakfast card Add Food control is missing.")
        capture("FDB02-breakfast-card-filled", targetPredicate: {
            app.buttons["diary.addFood.breakfast"].firstMatch.exists
        })
    }
}

// MARK: - Uniquely named synchronous loopback helper.
private extension URLSession {
    func filledDiarySyncData(
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
