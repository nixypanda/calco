import XCTest

@testable import CalCo

/// One-writer consequence: a log mutation invalidates every date's latest
/// suggestions, while only the visible date receives the single GET.
@MainActor
final class DiaryLatestTests: XCTestCase {
    private let generation: UInt64 = 42
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 15)

    private func log(id: String, date: LocalDiaryDate) -> FoodLog {
        FoodLog(
            id: id, logDate: date, mealSlot: .breakfast,
            item: .product(ProductLogItemSnapshot(id: "food-1", name: "Oats")),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
    }

    func testMutationInvalidatesAllDatesAndRefreshesVisibleOnce() {
        let delivery = DiaryMutationDelivery(
            generation: generation,
            drafts: [],
            logs: [log(id: "log-1", date: otherDate), log(id: "log-2", date: date)]
        )
        let plan = try! XCTUnwrap(DiaryMutationFanoutPlan.make(
            delivery: delivery,
            visibleDate: date,
            sessionGeneration: generation
        ))

        XCTAssertEqual(delivery.affectedDates, [otherDate, date])
        XCTAssertTrue(plan.invalidatesLatestSuggestions)
        XCTAssertTrue(plan.refreshesVisibleDate)
        XCTAssertEqual(plan.actions.filter { action in
            if case .diary(.diary(.refresh)) = action { return true }
            return false
        }.count, 1)
    }

    func testNonVisibleMutationInvalidatesWithoutFetch() {
        let delivery = DiaryMutationDelivery(generation: generation, invalidating: otherDate)
        let plan = try! XCTUnwrap(DiaryMutationFanoutPlan.make(
            delivery: delivery, visibleDate: date, sessionGeneration: generation
        ))

        XCTAssertTrue(plan.invalidatesLatestSuggestions)
        XCTAssertFalse(plan.refreshesVisibleDate)
        XCTAssertFalse(plan.actions.contains { action in
            if case .diary(.diary(.refresh)) = action { return true }
            return false
        })
    }
}
