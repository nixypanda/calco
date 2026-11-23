import XCTest
@testable import CalCo

final class PresentationTests: XCTestCase {
    func testFoodLoggingKeepsSearchAsTheUnderlyingPage() {
        let routes: [Pane] = [.foodSearch, .foodDetail(foodID: "food")]
        XCTAssertEqual(NativePresentation.pagePath(routes), [.foodSearch])
        XCTAssertEqual(NativePresentation.loggingFoodID(in: routes.last), "food")
    }

    func testLogEditorsRemainPagesWhileNewFoodLogsAreTasks() {
        XCTAssertEqual(NativePresentation.pagePath([.logEditor(logID: "log")]), [.logEditor(logID: "log")])
        XCTAssertEqual(NativePresentation.pagePath([.foodLog(foodID: "food")]), [])
        XCTAssertNil(NativePresentation.loggingFoodID(in: .logEditor(logID: "log")))
    }
}
