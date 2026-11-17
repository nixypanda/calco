//
//  NavigationTests.swift
//
//  Focused tests for the pure navigation model in `Navigation.swift`.
//  No views, network, or API models are involved.
//

import XCTest

@testable import CalCo

final class NavigationTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)

    // MARK: - Initial state

    func testStartsAtDiaryWithDateAndNoMealSlot() {
        let state = NavigationState(date: date)

        XCTAssertEqual(state.selectedDate, date)
        XCTAssertNil(state.mealSlot)
        XCTAssertEqual(state.activePane, .diary)
        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertFalse(state.hasDetail)
        XCTAssertEqual(state.primarySection, .diary)
    }

    // MARK: - The search -> detail -> log flow

    func testFlowPushesPanesInOrder() {
        var state = NavigationState(date: date)

        state.startLogging(mealSlot: .lunch)
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch])
        XCTAssertEqual(state.activePane, .foodSearch)

        state.pushFoodDetail(foodID: "food-1")
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch, .foodDetail(foodID: "food-1")])

        state.pushFoodLog(foodID: "food-1")
        XCTAssertEqual(
            state.paneStack,
            [.diary, .foodSearch, .foodDetail(foodID: "food-1"), .foodLog(foodID: "food-1")]
        )
        XCTAssertEqual(state.activePane, .foodLog(foodID: "food-1"))
    }

    func testContextIsCarriedThroughEveryStep() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .dinner)
        state.pushFoodDetail(foodID: "food-1")
        state.pushFoodLog(foodID: "food-1")

        XCTAssertEqual(state.selectedDate, date)
        XCTAssertEqual(state.mealSlot, .dinner)
    }

    func testSetMealSlotDoesNotDisturbStack() {
        var state = NavigationState(date: date)
        state.startLogging()
        state.pushFoodDetail(foodID: "food-1")

        state.setMealSlot(.snack)

        XCTAssertEqual(state.mealSlot, .snack)
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch, .foodDetail(foodID: "food-1")])
    }

    // MARK: - Back and completion preserve context

    func testBackPopsOnePaneAtATimeAndPreservesContext() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .breakfast)
        state.pushFoodDetail(foodID: "food-1")
        state.pushFoodLog(foodID: "food-1")

        XCTAssertTrue(state.back())
        XCTAssertEqual(state.activePane, .foodDetail(foodID: "food-1"))
        XCTAssertTrue(state.back())
        XCTAssertEqual(state.activePane, .foodSearch)
        XCTAssertTrue(state.back())
        XCTAssertEqual(state.activePane, .diary)

        XCTAssertFalse(state.hasDetail)
        XCTAssertEqual(state.selectedDate, date)
        XCTAssertEqual(state.mealSlot, .breakfast)
    }

    func testBackAtDiaryIsANoOp() {
        var state = NavigationState(date: date)

        XCTAssertFalse(state.back())
        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertEqual(state.selectedDate, date)
    }

    func testFinishLoggingReturnsToDiaryKeepingContext() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .lateNightSnack)
        state.pushFoodDetail(foodID: "food-1")
        state.pushFoodLog(foodID: "food-1")

        state.finishLogging()

        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertEqual(state.activePane, .diary)
        XCTAssertFalse(state.hasDetail)
        XCTAssertEqual(state.selectedDate, date)
        XCTAssertEqual(state.mealSlot, .lateNightSnack)
        XCTAssertEqual(state.primarySection, .diary)
    }

    func testSelectDateRestartsFlowButKeepsMealSlot() {
        var state = NavigationState(date: date)
        state.startLogging(mealSlot: .lunch)
        state.pushFoodDetail(foodID: "food-1")

        state.selectDate(otherDate)

        XCTAssertEqual(state.selectedDate, otherDate)
        XCTAssertEqual(state.mealSlot, .lunch)
        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertFalse(state.hasDetail)
    }

    // MARK: - Layout

    func testCompactShowsOnlyTheTopPane() {
        var state = NavigationState(date: date)

        XCTAssertEqual(state.visiblePanes(for: .compact), [VisiblePane(role: .main, pane: .diary)])

        state.startLogging()
        XCTAssertEqual(state.visiblePanes(for: .compact), [VisiblePane(role: .detail, pane: .foodSearch)])

        state.pushFoodDetail(foodID: "food-1")
        XCTAssertEqual(
            state.visiblePanes(for: .compact),
            [VisiblePane(role: .detail, pane: .foodDetail(foodID: "food-1"))]
        )

        state.pushFoodLog(foodID: "food-1")
        XCTAssertEqual(
            state.visiblePanes(for: .compact),
            [VisiblePane(role: .detail, pane: .foodLog(foodID: "food-1"))]
        )
    }

    func testExpandedShowsAdjacentMainAndDetail() {
        var state = NavigationState(date: date)

        XCTAssertEqual(state.visiblePanes(for: .expanded), [VisiblePane(role: .main, pane: .diary)])

        state.startLogging()
        XCTAssertEqual(state.visiblePanes(for: .expanded), [
            VisiblePane(role: .main, pane: .diary),
            VisiblePane(role: .detail, pane: .foodSearch),
        ])

        state.pushFoodDetail(foodID: "food-1")
        XCTAssertEqual(state.visiblePanes(for: .expanded), [
            VisiblePane(role: .main, pane: .foodSearch),
            VisiblePane(role: .detail, pane: .foodDetail(foodID: "food-1")),
        ])

        state.pushFoodLog(foodID: "food-1")
        XCTAssertEqual(state.visiblePanes(for: .expanded), [
            VisiblePane(role: .main, pane: .foodDetail(foodID: "food-1")),
            VisiblePane(role: .detail, pane: .foodLog(foodID: "food-1")),
        ])
    }

    func testPaneLimitByLayout() {
        let state = NavigationState(date: date)
        XCTAssertEqual(state.paneLimit(for: .compact), 1)
        XCTAssertEqual(state.paneLimit(for: .expanded), 2)
    }

    // MARK: - Primary section (web primaryRoute behaviour)

    func testPrimarySectionCollapsesFoodPanesToSearch() {
        var state = NavigationState(date: date)
        XCTAssertEqual(state.primarySection, .diary)

        state.startLogging()
        XCTAssertEqual(state.primarySection, .search)

        state.pushFoodDetail(foodID: "food-1")
        XCTAssertEqual(state.primarySection, .search)

        state.pushFoodLog(foodID: "food-1")
        XCTAssertEqual(state.primarySection, .search)

        state.back()
        state.back()
        state.back()
        XCTAssertEqual(state.primarySection, .diary)
    }

    func testPushSearchIsIdempotentWhenAlreadyOnTop() {
        var state = NavigationState(date: date)
        state.startLogging()

        state.pushSearch()

        XCTAssertEqual(state.paneStack, [.diary, .foodSearch])
    }

    // MARK: - Empty pane normalization

    func testInitializingWithEmptyPanesNormalizesToDiary() {
        let state = NavigationState(date: date, mealSlot: .lunch, panes: [])

        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertEqual(state.activePane, .diary)
        XCTAssertEqual(state.selectedDate, date)
        XCTAssertEqual(state.mealSlot, .lunch)
    }

    func testDecodingEmptyPanesNormalizesToDiary() throws {
        let json = """
        {"selectedDate":{"year":2026,"month":11,"day":17},"mealSlot":"lunch","panes":[]}
        """
        let data = Data(json.utf8)
        let state = try JSONDecoder().decode(NavigationState.self, from: data)

        XCTAssertEqual(state.paneStack, [.diary])
        XCTAssertEqual(state.activePane, .diary)
        XCTAssertEqual(state.selectedDate, date)
        XCTAssertEqual(state.mealSlot, .lunch)
    }

    func testShowDetailReplacesDetailWithoutDuplicates() {
        var state = NavigationState(date: date)

        state.showDetail(foodID: "food-1", date: date, mealSlot: .lunch)
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch, .foodDetail(foodID: "food-1")])

        state.showDetail(foodID: "food-2", date: otherDate, mealSlot: .dinner)
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch, .foodDetail(foodID: "food-2")])
        XCTAssertEqual(state.selectedDate, otherDate)
        XCTAssertEqual(state.mealSlot, .dinner)

        XCTAssertTrue(state.back())
        XCTAssertEqual(state.activePane, .foodSearch)
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch])
    }

    func testShowDetailPreservesHistoricalDateAndSlot() {
        var state = NavigationState(date: date, mealSlot: .breakfast)

        state.showDetail(foodID: "food-1", date: otherDate, mealSlot: nil)

        XCTAssertEqual(state.selectedDate, otherDate)
        XCTAssertNil(state.mealSlot)
        XCTAssertEqual(state.paneStack, [.diary, .foodSearch, .foodDetail(foodID: "food-1")])
    }

    // MARK: - Context value types

    func testLocalDiaryDateRoundTripAndValidation() {
        XCTAssertEqual(LocalDiaryDate("2026-11-17")!, date)
        XCTAssertEqual(date.formatted, "2026-11-17")
        XCTAssertEqual(LocalDiaryDate(year: 2024, month: 2, day: 29).formatted, "2024-02-29")
        XCTAssertNotNil(LocalDiaryDate("2024-02-29"))
        XCTAssertNil(LocalDiaryDate("2026-02-29"))
        XCTAssertNil(LocalDiaryDate("2026-13-01"))
        XCTAssertNil(LocalDiaryDate("17-11-2026"))
    }

    func testMealSlotRawValuesMatchWebQueryValues() {
        XCTAssertEqual(MealSlot.breakfast.rawValue, "breakfast")
        XCTAssertEqual(MealSlot.lunch.rawValue, "lunch")
        XCTAssertEqual(MealSlot.dinner.rawValue, "dinner")
        XCTAssertEqual(MealSlot.snack.rawValue, "snack")
        XCTAssertEqual(MealSlot.lateNightSnack.rawValue, "late_night_snack")
    }
}
