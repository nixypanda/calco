import XCTest

@testable import CalCo

final class LogCreateRequestBuilderTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let key = "b6b1f5a4-3c2e-4a7e-9f6d-1a2b3c4d5e6f"

    private func prepare(notes: String?) throws -> (
        draft: LogSubmissionDraft,
        request: FoodLogCreateRequest,
        body: Data
    ) {
        try LogCreateRequestBuilder.prepare(
            foodID: "food-1",
            foodName: "Oats",
            date: date,
            mealSlot: .lunch,
            amount: "150",
            unit: "g",
            notes: notes,
            timeZoneIdentifier: "America/New_York",
            baseURL: URL(string: "https://calco.example.com")!,
            idempotencyKey: key
        )
    }

    func testNFDAndNFCNotesProduceByteIdenticalBodies() throws {
        let nfd = try prepare(notes: "Cafe\u{301}")
        let nfc = try prepare(notes: "Café")

        XCTAssertEqual(nfd.draft, nfc.draft)
        XCTAssertEqual(nfd.body, nfc.body, "Retries must send identical UTF-8 bytes")
    }

    func testBodyEmbedsTheSameKeyAndRequestCarriesExactBytes() throws {
        let prepared = try prepare(notes: "note")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: prepared.body) as? [String: Any]
        )

        XCTAssertEqual(object["idempotency_key"] as? String, key)
        XCTAssertEqual(prepared.request.idempotencyKey, key)
        XCTAssertEqual(prepared.request.encodedBody, prepared.body)
        XCTAssertEqual(
            prepared.request.baseURLString,
            "https://calco.example.com"
        )
    }

    func testEncodingIsDeterministic() throws {
        let first = try prepare(notes: "café")
        let second = try prepare(notes: "café")

        XCTAssertEqual(first.body, second.body)
        XCTAssertEqual(first.request, second.request)
    }

    func testEmptyNotesBecomeNil() throws {
        let prepared = try prepare(notes: "   ")

        XCTAssertNil(prepared.draft.notes)
    }

    func testInvalidKeysAreRejected() {
        for key in ["", "   ", "line\nbreak", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(
                try LogCreateRequestBuilder.prepare(
                    foodID: "food-1",
                    foodName: "Oats",
                    date: date,
                    mealSlot: nil,
                    amount: "1",
                    unit: "g",
                    notes: nil,
                    timeZoneIdentifier: "UTC",
                    baseURL: nil,
                    idempotencyKey: key
                )
            )
        }
    }
}
