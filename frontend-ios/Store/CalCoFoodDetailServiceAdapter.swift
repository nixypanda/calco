// Bridges food detail, units, and log creation; createLog preserves caller date/timezone/slot/notes.
import Foundation

public struct CalCoFoodDetailServiceAdapter: FoodDetailServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func fetchFoodDetail(id: String) async throws -> FoodDetail {
        try await fetchFoodDetail(id: id, using: client)
    }

    public func fetchFoodDetail(
        id: String,
        expectedAccountID: String
    ) async throws -> FoodDetail {
        try await fetchFoodDetail(
            id: id,
            using: client.bound(toAccountID: expectedAccountID)
        )
    }

    public func fetchUnits() async throws -> [FoodUnit] {
        try await fetchUnits(using: client)
    }

    public func fetchUnits(expectedAccountID: String) async throws -> [FoodUnit] {
        try await fetchUnits(
            using: client.bound(toAccountID: expectedAccountID)
        )
    }

    public func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog {
        try await createLog(request, using: client)
    }

    public func createLog(
        _ request: FoodLogCreateRequest,
        expectedAccountID: String
    ) async throws -> CreatedFoodLog {
        try await createLog(
            request,
            using: client.bound(toAccountID: expectedAccountID)
        )
    }

    public func lastUsed(
        for item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> RecentLogItem? {
        try await lastUsed(
            for: item,
            date: date,
            mealSlot: mealSlot,
            using: client
        )
    }

    public func lastUsed(
        for item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        expectedAccountID: String
    ) async throws -> RecentLogItem? {
        try await lastUsed(
            for: item,
            date: date,
            mealSlot: mealSlot,
            using: client.bound(toAccountID: expectedAccountID)
        )
    }

    private func fetchFoodDetail(
        id: String,
        using client: CalCoAPIClient
    ) async throws -> FoodDetail {
        do {
            let product = try await client.getFoodDetail(id: id)
            return CalCoStoreMapping.foodDetail(from: product)
        } catch {
            throw CalCoStoreMapping.foodDetailError(from: error)
        }
    }

    private func fetchUnits(using client: CalCoAPIClient) async throws -> [FoodUnit] {
        do {
            let units = try await client.listUnits()
            return units.map(CalCoStoreMapping.foodUnit(from:))
        } catch {
            throw CalCoStoreMapping.foodDetailError(from: error)
        }
    }

    private func createLog(
        _ request: FoodLogCreateRequest,
        using client: CalCoAPIClient
    ) async throws -> CreatedFoodLog {
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

    private func lastUsed(
        for item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        using client: CalCoAPIClient
    ) async throws -> RecentLogItem? {
        do {
            let items = try await client.lastUsedItems(
                LastUsedItemsRequest(
                    fromDate: date.addingDays(-30),
                    toDate: date,
                    mealSlot: mealSlot,
                    items: [item]
                )
            )
            return items.first { candidate in
                LogSubmissionItem(logItem: candidate.item) == item
            }
        } catch {
            throw CalCoStoreMapping.foodDetailError(from: error)
        }
    }
}
