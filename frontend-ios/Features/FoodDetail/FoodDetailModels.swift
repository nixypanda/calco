import Foundation

// MARK: - Food detail models

public struct FoodUnit: Equatable, Hashable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public let kind: String

    public var id: String { code }

    public init(code: String, name: String, kind: String = "unit") {
        self.code = code
        self.name = name
        self.kind = kind
    }
}

public struct FoodServing: Equatable, Hashable, Sendable {
    public let unit: String
    public let gramsPerUnit: String

    public init(unit: String, gramsPerUnit: String) {
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }
}

public struct FoodNutrient: Equatable, Hashable, Sendable {
    public let code: String
    public let amountPer100g: String
    public let unit: String

    public init(code: String, amountPer100g: String, unit: String) {
        self.code = code
        self.amountPer100g = amountPer100g
        self.unit = unit
    }
}

public struct FoodDetail: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let brand: String?
    public let categories: [String]
    public let defaultQuantity: String?
    public let defaultUnit: String?
    public let nutrients: [FoodNutrient]
    public let servings: [FoodServing]
    public let allowedUnits: [FoodUnit]

    public init(
        id: String,
        name: String,
        brand: String? = nil,
        categories: [String] = [],
        defaultQuantity: String? = nil,
        defaultUnit: String? = nil,
        nutrients: [FoodNutrient] = [],
        servings: [FoodServing] = [],
        allowedUnits: [FoodUnit] = []
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.categories = categories
        self.defaultQuantity = defaultQuantity
        self.defaultUnit = defaultUnit
        self.nutrients = nutrients
        self.servings = servings
        self.allowedUnits = allowedUnits
    }

    public var defaultLogQuantity: (amount: String, unit: String) {
        if let amount = defaultQuantity, let unit = defaultUnit {
            return (amount, unit)
        }
        if let serving = servings.first {
            return ("1", serving.unit)
        }
        return ("100", "g")
    }
}

public struct NutrientAmount: Equatable, Sendable {
    public let code: String
    public let amount: String
    public let unit: String

    public init(code: String, amount: String, unit: String) {
        self.code = code
        self.amount = amount
        self.unit = unit
    }
}

public struct FoodLogCreateRequest: Equatable, Sendable {
    public let date: LocalDiaryDate
    public let timeZone: String?
    public let mealSlot: MealSlot?
    public let foodID: String
    public let amount: String
    public let unit: String
    public let notes: String?
    /// Stable identifier for retrying the same logical create. Reuse it only
    /// while every other field is unchanged.
    public let idempotencyKey: String?
    /// Exact encoded body retained by the durable submission journal. When set,
    /// the adapter must send these bytes without re-encoding.
    public let encodedBody: Data?
    /// Server the encoded body belongs to; retries are refused elsewhere.
    public let baseURLString: String?

    public init(
        date: LocalDiaryDate,
        timeZone: String? = nil,
        mealSlot: MealSlot? = nil,
        foodID: String,
        amount: String,
        unit: String,
        notes: String? = nil,
        idempotencyKey: String? = nil,
        encodedBody: Data? = nil,
        baseURLString: String? = nil
    ) {
        self.date = date
        self.timeZone = timeZone
        self.mealSlot = mealSlot
        self.foodID = foodID
        self.amount = amount
        self.unit = unit
        self.notes = notes
        self.idempotencyKey = idempotencyKey
        self.encodedBody = encodedBody
        self.baseURLString = baseURLString
    }

    public func withIdempotencyKey(_ key: String?) -> FoodLogCreateRequest {
        FoodLogCreateRequest(
            date: date,
            timeZone: timeZone,
            mealSlot: mealSlot,
            foodID: foodID,
            amount: amount,
            unit: unit,
            notes: notes,
            idempotencyKey: key,
            encodedBody: key == idempotencyKey ? encodedBody : nil,
            baseURLString: key == idempotencyKey ? baseURLString : nil
        )
    }

    public func withEncodedBody(_ body: Data) -> FoodLogCreateRequest {
        FoodLogCreateRequest(
            date: date,
            timeZone: timeZone,
            mealSlot: mealSlot,
            foodID: foodID,
            amount: amount,
            unit: unit,
            notes: notes,
            idempotencyKey: idempotencyKey,
            encodedBody: body,
            baseURLString: baseURLString
        )
    }
}

public struct CreatedFoodLog: Equatable, Sendable {
    public let id: String?
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    /// True when the server replayed an existing log with HTTP 200.
    public let replayed: Bool

    public init(
        id: String? = nil,
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        replayed: Bool = false
    ) {
        self.id = id
        self.date = date
        self.mealSlot = mealSlot
        self.replayed = replayed
    }
}

public enum FoodDetailServiceError: Error, Equatable, Sendable {
    case unauthorized
    /// Definitive rejection: the request was not applied.
    case failed(String)
    /// Transport/server ambiguity: the request may have been applied.
    case uncertain(String)
    /// The server rejected the idempotency key with a different request.
    case conflict(String)
    case rateLimited(retryAfterSeconds: Int?)
}

// MARK: - Helpers

public func sourceUnits(food: FoodDetail?, units: [FoodUnit]) -> [FoodUnit] {
    guard let food else { return units }
    return food.allowedUnits.isEmpty ? units : food.allowedUnits
}

public func positiveAmount(_ raw: String) -> Double? {
    guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return value > 0 ? value : nil
}

public func servingGrams(amount: String, unit: String, servings: [FoodServing]) -> Double? {
    guard let amountValue = positiveAmount(amount) else { return nil }
    if unit == "g" {
        return amountValue
    }
    guard let serving = servings.first(where: { $0.unit == unit }),
          let gramsPerUnit = positiveAmount(serving.gramsPerUnit) else {
        return nil
    }
    return amountValue * gramsPerUnit
}

public func makeNutritionPreview(for food: FoodDetail, amount: String, unit: String) -> [NutrientAmount]? {
    guard let grams = servingGrams(amount: amount, unit: unit, servings: food.servings) else {
        return nil
    }
    let factor = grams / 100.0
    let nutrients = food.nutrients.map { nutrient in
        NutrientAmount(
            code: nutrient.code,
            amount: String((Double(nutrient.amountPer100g) ?? 0) * factor),
            unit: nutrient.unit
        )
    }
    return nutrients
}

// MARK: - Service protocol

public protocol FoodDetailServicing: Sendable {
    func fetchFoodDetail(id: String) async throws -> FoodDetail
    func fetchUnits() async throws -> [FoodUnit]
    func createLog(_ request: FoodLogCreateRequest) async throws -> CreatedFoodLog
    /// Most recent matching log for prefilling the amount. Optional so simple
    /// test doubles keep compiling; a failure must not block the detail screen.
    func lastUsed(
        for item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> RecentLogItem?
}

public extension FoodDetailServicing {
    func fetchUnits() async throws -> [FoodUnit] { [] }
    func lastUsed(
        for item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> RecentLogItem? { nil }
}

public func isUnauthorizedFoodDetailError(_ error: Error) -> Bool {
    if let serviceError = error as? FoodDetailServiceError, serviceError == .unauthorized {
        return true
    }
    let nsError = error as NSError
    return nsError.code == 401
}

public func foodDetailErrorMessage(_ error: Error) -> String {
    if let serviceError = error as? FoodDetailServiceError {
        switch serviceError {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .failed(let message), .uncertain(let message), .conflict(let message):
            return message
        case .rateLimited:
            return String(localized: "foodDetail.error.rateLimited")
        }
    }
    return (error as NSError).localizedDescription
}
