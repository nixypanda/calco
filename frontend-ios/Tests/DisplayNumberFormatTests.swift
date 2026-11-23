import XCTest
@testable import CalCo

final class DisplayNumberFormatTests: XCTestCase {
    func testDisplayRoundsToAtMostTwoPlaces() {
        for (raw, expected) in [
            ("0", "0"), ("12.0000", "12"), ("12.3", "12.3"),
            ("12.345", "12.35"), ("1.005", "1.01"),
            ("99.999", "100"), ("-0.004", "0"), ("-1.235", "-1.24"),
            ("0.30000000000000004", "0.3")
        ] {
            XCTAssertEqual(DisplayNumberFormat.decimal(raw), expected, raw)
        }
    }

    func testTableValuesAlwaysHaveTwoPlaces() {
        for (raw, expected) in [
            ("0", "0.00"), ("12", "12.00"), ("12.3", "12.30"),
            ("12.345", "12.35"), ("99.999", "100.00"), ("-0.004", "0.00")
        ] {
            XCTAssertEqual(DisplayNumberFormat.decimal(raw, fixed: true), expected, raw)
        }
    }

    func testInvalidValuesStayUnknown() {
        XCTAssertEqual(DisplayNumberFormat.decimal(""), "—")
        XCTAssertEqual(DisplayNumberFormat.decimal("unknown"), "—")
        XCTAssertEqual(DisplayNumberFormat.decimal(Double.infinity), "—")
        XCTAssertEqual(DisplayNumberFormat.decimal(Double.nan), "—")
    }

    func testQuantityDisplayDoesNotChangeStoredPrecision() {
        let quantity = NutritionQuantity(amount: "1.234567", unit: "g")
        XCTAssertEqual(quantity.described, "1.23 g")
        XCTAssertEqual(quantity.amount, "1.234567")
    }

    func testNutritionTableFormatsCurrentReferenceAndGuidance() {
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(.currentAndReference(
                current: Decimal(string: "1.234")!, reference: 28, unit: "g"
            )),
            "1.23 / 28.00 g"
        )
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(.unknownOfReference(reference: 28, unit: "g")),
            "— of 28.00 g"
        )
        XCTAssertTrue(NutritionDetailsCopy.guidance(.toReference(2), unit: "g").contains("2.00 g"))
        XCTAssertEqual(NutritionDetailsCopy.amountDisplay(.unknown), "—")
    }

    func testTableNumberColumnExcludesUnitsWithoutChangingPrecision() {
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(.value(100, unit: "g"), includeUnit: false),
            "100.00"
        )
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(
                .value(Decimal(string: "99.8")!, unit: "mg"), includeUnit: false
            ),
            "99.80"
        )
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(
                .currentAndReference(current: 12, reference: 28, unit: "g"), includeUnit: false
            ),
            "12.00 / 28.00"
        )
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(
                .unknownOfReference(reference: 28, unit: "g"), includeUnit: false
            ),
            "— of 28.00"
        )
        XCTAssertEqual(
            NutritionDetailsCopy.amountDisplay(.unknown, includeUnit: false), "—"
        )
    }
}
