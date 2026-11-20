import XCTest

@testable import CalCo

private struct MealStubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(
        statusCode: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

private final class MealStubRegistry: @unchecked Sendable {
    static let shared = MealStubRegistry()

    private let lock = NSLock()
    private var responses: [String: MealStubResponse] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var nextPort = 34_000

    func register(_ response: MealStubResponse) -> String {
        lock.lock()
        nextPort += 1
        let token = String(nextPort)
        responses[token] = response
        requests[token] = []
        lock.unlock()
        return token
    }

    func response(for token: String) -> MealStubResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[token]
    }

    func record(_ request: URLRequest, for token: String) {
        lock.lock()
        requests[token, default: []].append(request)
        lock.unlock()
    }

    func recordedRequests(for token: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests[token] ?? []
    }
}

private final class MealStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let port = request.url?.port else { return false }
        return MealStubRegistry.shared.response(for: String(port)) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let port = url.port,
              let stub = MealStubRegistry.shared.response(for: String(port)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        MealStubRegistry.shared.record(request, for: String(port))
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MealsAPITests: XCTestCase {
    private func stubClient(
        response: MealStubResponse
    ) -> (client: CalCoAPIClient, token: String) {
        let token = MealStubRegistry.shared.register(response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MealStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = CalCoAPIClient(
            configuration: CalCoAPIConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(token)")!
            ),
            session: session
        )
        return (client, token)
    }

    func testListMealsDecodesNullableFieldsAndComponentSummaries() async throws {
        let body = """
        {
          "items": [
            {
              "id": "meal-1",
              "name": "Porridge",
              "notes": null,
              "total_quantity": {"amount": "250", "unit": "g"},
              "nutrition_summary": {
                "energy_kcal": "310",
                "protein_g": "12.5",
                "carbs_g": null,
                "fat_g": null,
                "fiber_g": null
              },
              "components": [
                {
                  "id": "component-1",
                  "item": {"type": "product", "id": "oats"},
                  "quantity": {"amount": "50", "unit": "g"},
                  "nutrition_summary": {"energy_kcal": "190"}
                },
                {
                  "id": "component-2",
                  "item": {"type": "product", "id": "milk"},
                  "quantity": {"amount": "200.5", "unit": "g"},
                  "nutrition_summary": null
                }
              ],
              "created_at": "2026-11-19T08:00:00Z",
              "updated_at": "2026-11-19T08:05:00Z"
            }
          ]
        }
        """
        let (client, token) = stubClient(
            response: MealStubResponse(body: Data(body.utf8))
        )

        let meals = try await client.listMeals()

        XCTAssertEqual(meals.count, 1)
        let meal = try XCTUnwrap(meals.first)
        XCTAssertEqual(meal.name, "Porridge")
        XCTAssertNil(meal.notes)
        XCTAssertEqual(meal.totalQuantity, NutritionQuantity(amount: "250", unit: "g"))
        XCTAssertEqual(meal.nutritionSummary?.energyKcal, "310")
        XCTAssertEqual(meal.components.count, 2)
        XCTAssertEqual(meal.components[0].productID, "oats")
        XCTAssertEqual(meal.components[0].nutritionSummary?.energyKcal, "190")
        XCTAssertEqual(meal.components[1].quantity.amount, "200.5")
        XCTAssertNil(meal.components[1].nutritionSummary)

        let request = try XCTUnwrap(MealStubRegistry.shared.recordedRequests(for: token).last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/meals")
    }

    func testCreateMealEncodesProductReferencesAndExplicitNulls() throws {
        let request = MealWriteRequest(
            name: "Porridge",
            notes: nil,
            totalQuantity: nil,
            components: [
                MealComponentWriteRequest(
                    productID: "oats",
                    quantity: NutritionQuantity(amount: "50", unit: "g")
                )
            ]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["name"] as? String, "Porridge")
        XCTAssertTrue(object["notes"] is NSNull)
        XCTAssertTrue(object["total_quantity"] is NSNull)
        let components = try XCTUnwrap(object["components"] as? [[String: Any]])
        XCTAssertEqual(components.count, 1)
        let item = try XCTUnwrap(components[0]["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "product")
        XCTAssertEqual(item["id"] as? String, "oats")
        let quantity = try XCTUnwrap(components[0]["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["amount"] as? String, "50")
        XCTAssertEqual(quantity["unit"] as? String, "g")
    }

    func testUpdateMealSendsExplicitNullsToClearFields() async throws {
        let body = """
        {
          "id": "meal-1",
          "name": "Oat Porridge",
          "notes": null,
          "total_quantity": null,
          "nutrition_summary": null,
          "components": [
            {
              "id": "component-1",
              "item": {"type": "product", "id": "oats"},
              "quantity": {"amount": "80", "unit": "g"},
              "nutrition_summary": null
            }
          ],
          "created_at": "2026-11-19T08:00:00Z",
          "updated_at": "2026-11-19T09:00:00Z"
        }
        """
        let (client, token) = stubClient(
            response: MealStubResponse(body: Data(body.utf8))
        )
        let request = MealWriteRequest(
            name: "Oat Porridge",
            notes: nil,
            totalQuantity: nil,
            components: [
                MealComponentWriteRequest(
                    productID: "oats",
                    quantity: NutritionQuantity(amount: "80", unit: "g")
                )
            ]
        )

        let meal = try await client.updateMeal(id: "meal-1", request)
        XCTAssertEqual(meal.name, "Oat Porridge")

        let recorded = try XCTUnwrap(
            MealStubRegistry.shared.recordedRequests(for: token).last
        )
        XCTAssertEqual(recorded.httpMethod, "PUT")
        XCTAssertEqual(recorded.url?.path, "/api/meals/meal-1")
        if let body = recorded.httpBody {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertTrue(object["notes"] is NSNull)
            XCTAssertTrue(object["total_quantity"] is NSNull)
        }
    }

    func testMealNutrientsUsesAmountAndUnitQuery() async throws {
        let body = """
        {
          "meal_id": "meal-1",
          "quantity": {"amount": "250", "unit": "g"},
          "nutrition_summary": {"energy_kcal": "310", "protein_g": "12.5"},
          "nutrients": [
            {"code": "ENERGY_KCAL", "amount": "310", "unit": "kcal"},
            {"code": "PROTEIN_G", "amount": "12.5", "unit": "g"}
          ]
        }
        """
        let (client, token) = stubClient(
            response: MealStubResponse(body: Data(body.utf8))
        )

        let nutrition = try await client.getMealNutrients(
            mealID: "meal-1",
            amount: "250",
            unit: "g"
        )

        XCTAssertEqual(nutrition.mealID, "meal-1")
        XCTAssertEqual(nutrition.quantity, NutritionQuantity(amount: "250", unit: "g"))
        XCTAssertEqual(nutrition.nutrients.map(\.code), ["ENERGY_KCAL", "PROTEIN_G"])
        XCTAssertEqual(nutrition.nutritionSummary.energyKcal, "310")

        let request = try XCTUnwrap(MealStubRegistry.shared.recordedRequests(for: token).last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/meals/meal-1/nutrients")
        let components = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "amount" })?.value,
            "250"
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "unit" })?.value,
            "g"
        )
    }

    func testDeleteMealAcceptsNoContent() async throws {
        let (client, token) = stubClient(
            response: MealStubResponse(statusCode: 204)
        )

        try await client.deleteMeal(id: "meal-1")

        let request = try XCTUnwrap(MealStubRegistry.shared.recordedRequests(for: token).last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/meals/meal-1")
    }

    func testAdapterMapsMissingProduct404ToMissingComponents() async throws {
        let body = """
        {"error":{"code":"not_found","message":
        "product 11111111-1111-1111-1111-111111111111 not found"}}
        """
        let (client, _) = stubClient(
            response: MealStubResponse(statusCode: 404, body: Data(body.utf8))
        )
        let adapter = CalCoMealsServiceAdapter(client: client)

        do {
            _ = try await adapter.getMeal(id: "meal-1")
            XCTFail("Expected a missing-components error")
        } catch let error as MealServiceError {
            guard case .missingComponents(let message) = error else {
                return XCTFail("Expected missingComponents, got \(error)")
            }
            XCTAssertTrue(message.contains("product"))
        }
    }

    func testDegradedMealDTOOmitsHealthyFlagsAndPreservesMissingIdentity() throws {
        let healthyJSON = """
        {"id":"m1","name":"Healthy","notes":null,"total_quantity":{"amount":"100","unit":"g"},
         "nutrition_summary":{"energy_kcal":"100"},"components":[
          {"id":"c1","item":{"type":"product","id":"p1"},"quantity":{"amount":"100","unit":"g"},
           "nutrition_summary":{"energy_kcal":"100"}}],"created_at":"","updated_at":""}
        """
        let healthy = try JSONDecoder().decode(Meal.self, from: Data(healthyJSON.utf8))
        XCTAssertFalse(healthy.hasMissingComponents)
        XCTAssertFalse(healthy.isDegraded)
        XCTAssertFalse(healthy.components[0].missing)

        let brokenJSON = """
        {"id":"m2","name":"Broken","notes":null,"total_quantity":{"amount":"200","unit":"g"},
         "nutrition_summary":null,"has_missing_components":true,"components":[
          {"id":"c2","item":{"type":"product","id":"missing-product"},
           "quantity":{"amount":"200","unit":"g"},"nutrition_summary":null,
           "missing":true,"missing_reason":"product_unavailable","name":"Unavailable food"}],
         "created_at":"","updated_at":""}
        """
        let broken = try JSONDecoder().decode(Meal.self, from: Data(brokenJSON.utf8))
        XCTAssertTrue(broken.hasMissingComponents)
        XCTAssertTrue(broken.isDegraded)
        XCTAssertNil(broken.nutritionSummary)
        XCTAssertEqual(broken.components[0].item.id, "missing-product")
        XCTAssertEqual(broken.components[0].quantity.amount, "200")
        XCTAssertEqual(broken.components[0].missingReason, "product_unavailable")
        XCTAssertEqual(broken.components[0].name, "Unavailable food")
    }

    func testAdapterMapsMissingComponents409ToActionableError() async throws {
        let body = """
        {"error":{"code":"missing_components","message":"replace them before logging",
         "meal_id":"m1","missing_components":[]}}
        """
        let (client, _) = stubClient(
            response: MealStubResponse(statusCode: 409, body: Data(body.utf8))
        )
        let adapter = CalCoMealsServiceAdapter(client: client)
        do {
            _ = try await adapter.mealNutrients(
                mealID: "m1",
                amount: "100",
                unit: "g"
            )
            XCTFail("Expected missing-components rejection")
        } catch let error as MealServiceError {
            guard case .missingComponents(let message) = error else {
                return XCTFail("Expected missingComponents, got \(error)")
            }
            XCTAssertEqual(message, "replace them before logging")
        }
    }

    func testAdapterMapsPlainMeal404ToNotFound() async throws {
        let body = """
        {"error":{"code":"not_found","message":"meal not found"}}
        """
        let (client, _) = stubClient(
            response: MealStubResponse(statusCode: 404, body: Data(body.utf8))
        )
        let adapter = CalCoMealsServiceAdapter(client: client)

        do {
            _ = try await adapter.getMeal(id: "meal-1")
            XCTFail("Expected not-found")
        } catch let error as MealServiceError {
            guard case .notFound(let message) = error else {
                return XCTFail("Expected notFound, got \(error)")
            }
            XCTAssertEqual(message, "meal not found")
        }
    }

    func testAdapterMapsForbiddenValidationAndUnauthorized() async {
        let cases: [(Int, String, (MealServiceError) -> Bool)] = [
            (403, #"{"error":{"code":"forbidden","message":"owner only"}}"#, {
                if case .forbidden = $0 { return true }
                return false
            }),
            (400, #"{"error":{"code":"validation","message":"name required"}}"#, {
                if case .validation = $0 { return true }
                return false
            }),
            (401, #"{"error":{"code":"unauthorized","message":"no"}}"#, {
                if case .unauthorized = $0 { return true }
                return false
            }),
        ]

        for (status, body, matches) in cases {
            let (client, _) = stubClient(
                response: MealStubResponse(statusCode: status, body: Data(body.utf8))
            )
            let adapter = CalCoMealsServiceAdapter(client: client)
            do {
                _ = try await adapter.listMeals()
                XCTFail("Expected mapped error for status \(status)")
            } catch let error as MealServiceError {
                XCTAssertTrue(matches(error), "Unexpected mapping: \(error)")
            } catch {
                XCTFail("Expected MealServiceError, got \(error)")
            }
        }
    }
}
