import XCTest

@testable import CalCo

final class LogHistoryContractTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let baseURL = URL(string: "https://calco.example.com")!

    func testRecentItemsDecodeHistoryRankingFields() throws {
        let response = try decode(
            RecentItemsResponse.self,
            """
            {
              "items": [{
                "item": {"type": "product", "id": "food-1", "name": "Oats", "brand": "Acme"},
                "last_used_date": "2026-11-16",
                "meal_slot": "breakfast",
                "quantity": {"amount": "50", "unit": "g"},
                "nutrition_summary": {
                  "energy_kcal": "194", "protein_g": "8.25",
                  "carbs_g": "33", "fat_g": "3.4"
                },
                "top_quantities": [
                  {"quantity": {"amount": "50", "unit": "g"}, "log_count": 4},
                  {"quantity": {"amount": "1", "unit": "serving"}, "log_count": 2}
                ]
              }]
            }
            """
        )

        let item = try XCTUnwrap(response.items.first)
        XCTAssertEqual(item.name, "Oats")
        XCTAssertEqual(item.submissionItem, .product(id: "food-1"))
        XCTAssertEqual(item.lastUsedDate, LocalDiaryDate(year: 2026, month: 11, day: 16))
        XCTAssertEqual(item.mealSlot, .breakfast)
        XCTAssertEqual(item.quantity, NutritionQuantity(amount: "50", unit: "g"))
        XCTAssertEqual(item.topQuantities.map(\.logCount), [4, 2])
        XCTAssertEqual(item.topQuantities[1].quantity.unit, "serving")
        XCTAssertEqual(item.nutritionSummary.proteinG, "8.25")
    }

    func testLatestSlotsDecodeOrderedRowsAndRejectUnknownSlot() throws {
        let response = try decode(
            LatestSlotsResponse.self,
            """
            {
              "slots": [{
                "source_date": "2026-11-15",
                "meal_slot": "dinner",
                "items": [\(logJSON(id: "log-1", slot: "dinner"))]
              }]
            }
            """
        )
        let slot = try XCTUnwrap(response.slots.first)
        XCTAssertEqual(slot.sourceDate, LocalDiaryDate(year: 2026, month: 11, day: 15))
        XCTAssertEqual(slot.mealSlot, .dinner)
        XCTAssertEqual(slot.items.map(\.id), ["log-1"])

        XCTAssertThrowsError(
            try decode(
                LatestSlotsResponse.self,
                #"{"slots":[{"source_date":"2026-11-15","meal_slot":"brunch","items":[]}]}"#
            )
        )
    }

    func testBarcodeLookupUsesFlattenedProductAndLookupMeta() throws {
        let lookup = try decode(
            BarcodeLookup.self,
            """
            {
              "id": "food-1",
              "source": "local",
              "source_id": null,
              "visibility": "private",
              "barcode": "0123456789012",
              "name": "Milk",
              "brand": "Dairy",
              "categories": ["dairy"],
              "default_quantity": "250",
              "default_unit": "ml",
              "nutrition_summary": {"per_100g": {}},
              "nutrients": [],
              "servings": [],
              "allowed_units": [],
              "lookup": {"origin": "open_food_facts", "note": "Imported from OFF"}
            }
            """
        )
        XCTAssertEqual(lookup.product.id, "food-1")
        XCTAssertEqual(lookup.product.barcode, "0123456789012")
        XCTAssertEqual(lookup.lookup.origin, .openFoodFacts)
        XCTAssertEqual(lookup.lookup.note, "Imported from OFF")
    }

    func testCategorySuggestionsDecodeValueAndCount() throws {
        let response = try decode(
            CategorySuggestionResponse.self,
            #"{"items":[{"value":"breakfast cereal","count":12}]}"#
        )
        XCTAssertEqual(response.items.first?.value, "breakfast cereal")
        XCTAssertEqual(response.items.first?.count, 12)
    }

    func testLastUsedRequestUsesTopLevelDatesAndTypedItems() throws {
        let request = LastUsedItemsRequest(
            fromDate: LocalDiaryDate(year: 2026, month: 10, day: 18),
            toDate: date,
            mealSlot: .lateNightSnack,
            items: [.product(id: "food-1"), .meal(id: "meal-9")]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
                as? [String: Any]
        )
        XCTAssertEqual(object["from_date"] as? String, "2026-10-18")
        XCTAssertEqual(object["to_date"] as? String, "2026-11-17")
        XCTAssertEqual(object["meal_slot"] as? String, "late_night_snack")
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["type"] as? String, "product")
        XCTAssertEqual(items[1]["type"] as? String, "meal")
    }

    func testSingleBodyPutsOneTopLevelKeyAndNoItemKey() throws {
        let draft = makeDraft(item: .product(id: "food-1"))
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: baseURL,
            idempotencyKey: "key-1"
        )
        XCTAssertEqual(prepared.route, .single)
        XCTAssertEqual(prepared.request.requestPath, "/api/logs")
        let root = try object(prepared.request.body)
        XCTAssertEqual(root["idempotency_key"] as? String, "key-1")
        let item = try XCTUnwrap(root["item"] as? [String: Any])
        XCTAssertNil(item["idempotency_key"])
        XCTAssertEqual(root["log_date"] as? String, "2026-11-17")
        XCTAssertEqual(root["device_timezone"] as? String, "Europe/Paris")
    }

    func testBatchBodyKeepsOrderAndOnlyTopLevelKey() throws {
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [
                makeDraft(item: .product(id: "food-1"), amount: "50"),
                makeDraft(item: .meal(id: "meal-1"), amount: "1"),
            ],
            baseURL: baseURL,
            idempotencyKey: "batch-key"
        )
        XCTAssertEqual(prepared.route, .batch)
        XCTAssertEqual(prepared.request.requestPath, "/api/logs/batch")
        let root = try object(prepared.request.body)
        XCTAssertEqual(root["idempotency_key"] as? String, "batch-key")
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[0]["idempotency_key"])
        XCTAssertNil(items[1]["idempotency_key"])
        XCTAssertEqual(
            (items[0]["item"] as? [String: Any])?["id"] as? String,
            "food-1"
        )
        XCTAssertEqual(
            (items[1]["item"] as? [String: Any])?["id"] as? String,
            "meal-1"
        )
        XCTAssertEqual(
            (items[0]["quantity"] as? [String: Any])?["amount"] as? String,
            "50"
        )
    }

    func testAdHocBodyUsesTopLevelKeyAndNutrients() throws {
        let draft = LogSubmissionDraft(
            item: .adHoc(name: "Toast", brand: "Bakery"),
            date: date,
            mealSlot: .snack,
            amount: "2",
            unit: "slice",
            notes: nil,
            timeZone: "Europe/Paris",
            nutrients: [
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "80", unit: "kcal")
            ]
        )
        let prepared = try LogSubmissionRequestBuilder.prepare(
            drafts: [draft],
            baseURL: baseURL,
            idempotencyKey: "ad-hoc-key"
        )
        XCTAssertEqual(prepared.route, .adHoc)
        XCTAssertEqual(prepared.request.requestPath, "/api/logs/ad-hoc")
        let root = try object(prepared.request.body)
        XCTAssertEqual(root["idempotency_key"] as? String, "ad-hoc-key")
        XCTAssertEqual(root["name"] as? String, "Toast")
        XCTAssertEqual(root["brand"] as? String, "Bakery")
        XCTAssertNil(root["item"])
        XCTAssertEqual((root["nutrients"] as? [[String: Any]])?.count, 1)
    }

    func testBuilderRejectsBlankControlAndOversizedKeysAndTooManyDrafts() {
        let draft = makeDraft(item: .product(id: "food-1"))
        for key in ["   ", "bad\nkey", String(repeating: "k", count: 129)] {
            XCTAssertThrowsError(
                try LogSubmissionRequestBuilder.prepare(
                    drafts: [draft],
                    baseURL: baseURL,
                    idempotencyKey: key
                )
            ) { error in
                XCTAssertEqual(error as? LogCreateRequestBuilderError, .invalidKey)
            }
        }

        let tooMany = Array(repeating: draft, count: 51)
        XCTAssertThrowsError(
            try LogSubmissionRequestBuilder.prepare(
                drafts: tooMany,
                baseURL: baseURL,
                idempotencyKey: "key"
            )
        ) { error in
            XCTAssertEqual(error as? LogCreateRequestBuilderError, .invalidItem)
        }
    }

    func testBuilderRejectsAdHocItemsOnBatchRoutes() {
        let adHoc = LogSubmissionDraft(
            item: .adHoc(name: "Toast", brand: nil),
            date: date,
            mealSlot: .lunch,
            amount: "1",
            unit: "serving",
            notes: nil,
            timeZone: "Europe/Paris",
            nutrients: []
        )
        let product = makeDraft(item: .product(id: "food-1"))
        for drafts in [[adHoc, adHoc], [adHoc, product], [product, adHoc]] {
            XCTAssertThrowsError(
                try LogSubmissionRequestBuilder.prepare(
                    drafts: drafts,
                    baseURL: baseURL,
                    idempotencyKey: "key"
                )
            ) { error in
                XCTAssertEqual(error as? LogCreateRequestBuilderError, .invalidItem)
            }
        }
    }

    func testBatchResponseDecodesItemsInOriginalOrder() throws {
        let response = try decode(
            BatchLogResponse.self,
            """
            {"items":[\(logJSON(id: "log-2", slot: "lunch")),\(logJSON(id: "log-1", slot: "lunch"))]}
            """
        )
        XCTAssertEqual(response.items.map(\.id), ["log-2", "log-1"])
    }

    // MARK: - Helpers

    private func makeDraft(
        item: LogSubmissionItem,
        amount: String = "100"
    ) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: item,
            date: date,
            mealSlot: .lunch,
            amount: amount,
            unit: "g",
            notes: nil,
            timeZone: "Europe/Paris"
        )
    }

    private func logJSON(id: String, slot: String) -> String {
        """
        {
          "id": "\(id)",
          "log_date": "2026-11-17",
          "device_timezone": "Europe/Paris",
          "meal_slot": "\(slot)",
          "item": {"type": "product", "id": "food-1", "name": "Oats", "brand": null},
          "quantity": {"amount": "50", "unit": "g"},
          "nutrients": [
            {"code": "ENERGY_KCAL", "amount": "194", "unit": "kcal"}
          ],
          "notes": null,
          "created_at": "2026-11-17T10:00:00Z",
          "updated_at": "2026-11-17T10:00:00Z"
        }
        """
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
