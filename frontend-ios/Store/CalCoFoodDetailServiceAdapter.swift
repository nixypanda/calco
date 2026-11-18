// Bridges food detail, units, and log creation; createLog preserves caller date/timezone/slot/notes.
import Foundation

public struct CalCoFoodDetailServiceAdapter: FoodDetailServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func fetchFoodDetail(id: String) async throws -> FoodDetail {
        do {
            let product = try await client.getFoodDetail(id: id)
            return CalCoStoreMapping.foodDetail(from: product)
        } catch {
            throw CalCoStoreMapping.foodDetailError(from: error)
        }
    }

    public func fetchUnits() async throws -> [FoodUnit] {
        do {
            let units = try await client.listUnits()
            return units.map(CalCoStoreMapping.foodUnit(from:))
        } catch {
            throw CalCoStoreMapping.foodDetailError(from: error)
        }
    }

    public func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        let body: Data
        if let encoded = request.encodedBody {
            if let expectedBaseURL = request.baseURLString {
                guard expectedBaseURL == client.configuration.baseURL.absoluteString else {
                    throw FoodDetailServiceError.failed(
                        String(localized: "foodDetail.error.differentServer")
                    )
                }
            }
            body = encoded
        } else {
            let legacy = CreateLogRequest(
                logDate: request.date,
                deviceTimeZone: request.timeZone,
                mealSlot: request.mealSlot,
                productID: request.foodID,
                quantity: NutritionQuantity(amount: request.amount, unit: request.unit),
                notes: request.notes,
                idempotencyKey: request.idempotencyKey
            )
            do {
                body = try client.encodeBody(legacy)
            } catch {
                throw CalCoStoreMapping.foodLogSubmitError(from: error)
            }
        }

        do {
            let (log, statusCode) = try await client.createLogRaw(body)
            return CreatedFoodLog(
                id: log.id,
                date: log.logDate,
                mealSlot: log.mealSlot,
                replayed: statusCode == 200
            )
        } catch {
            throw CalCoStoreMapping.foodLogSubmitError(from: error)
        }
    }
}
