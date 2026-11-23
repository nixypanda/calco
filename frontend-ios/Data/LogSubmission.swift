// Typed log drafts plus the preexisting durable single-log submission records.
// The encoded request body is stored verbatim so a user-triggered retry cannot
// re-encode different bytes.

import Foundation

// MARK: - Typed item reference

public enum LogSubmissionItem: Equatable, Hashable, Sendable {
    case product(id: String)
    case meal(id: String)
    case adHoc(name: String, brand: String?)

    public var itemType: String {
        switch self {
        case .product: return "product"
        case .meal: return "meal"
        case .adHoc: return "ad_hoc"
        }
    }

    public var identifier: String? {
        switch self {
        case .product(let id), .meal(let id): return id
        case .adHoc: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .product, .meal: return identifier ?? ""
        case .adHoc(let name, _): return name
        }
    }

    public var productID: String? {
        guard case .product(let id) = self else { return nil }
        return id
    }

    public init?(logItem: FoodLogItem) {
        switch logItem {
        case .product(let product):
            self = .product(id: product.id)
        case .meal(let meal):
            self = .meal(id: meal.id)
        case .adHoc(let adHoc):
            self = .adHoc(name: adHoc.name, brand: adHoc.brand)
        }
    }
}

extension LogSubmissionItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case brand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "product":
            self = .product(id: try container.decode(String.self, forKey: .id))
        case "meal":
            self = .meal(id: try container.decode(String.self, forKey: .id))
        case "ad_hoc":
            self = .adHoc(
                name: try container.decode(String.self, forKey: .name),
                brand: try container.decodeIfPresent(String.self, forKey: .brand)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown submission item type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .product(let id):
            try container.encode("product", forKey: .type)
            try container.encode(id, forKey: .id)
        case .meal(let id):
            try container.encode("meal", forKey: .type)
            try container.encode(id, forKey: .id)
        case .adHoc(let name, let brand):
            try container.encode("ad_hoc", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(brand, forKey: .brand)
        }
    }
}

// MARK: - Draft

public struct LogSubmissionDraft: Equatable, Sendable {
    public let item: LogSubmissionItem
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let amount: String
    public let unit: String
    public let notes: String?
    /// Frozen at first submit so a device timezone change cannot alter a retry.
    public let timeZone: String
    /// Required only for ad-hoc logs; omitted from product and meal bodies.
    public let nutrients: [NutrientAmountValue]?

    public init(
        item: LogSubmissionItem,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZone: String,
        nutrients: [NutrientAmountValue]? = nil
    ) {
        self.item = item
        self.date = date
        self.mealSlot = mealSlot
        self.amount = amount
        self.unit = unit
        self.notes = notes
        self.timeZone = timeZone
        self.nutrients = nutrients
    }

    /// Source-compatible product initializer used by the legacy single-food
    /// journal.
    public init(
        foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZone: String
    ) {
        self.init(
            item: .product(id: foodID),
            date: date,
            mealSlot: mealSlot,
            amount: amount,
            unit: unit,
            notes: notes,
            timeZone: timeZone
        )
    }

    /// Product or meal ID for legacy product matching. Ad-hoc logs have no ID.
    public var foodID: String {
        switch item {
        case .product(let id), .meal(let id): return id
        case .adHoc(let name, _): return name
        }
    }

    public var productID: String? { item.productID }
}

extension LogSubmissionDraft: Codable {
    private enum CodingKeys: String, CodingKey {
        case item
        case foodID
        case date
        case mealSlot
        case amount
        case unit
        case notes
        case timeZone
        case nutrients
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let item = try container.decodeIfPresent(LogSubmissionItem.self, forKey: .item) {
            self.item = item
        } else {
            // The preexisting journal stored only a product ID.
            self.item = .product(id: try container.decode(String.self, forKey: .foodID))
        }
        date = try container.decode(LocalDiaryDate.self, forKey: .date)
        mealSlot = try container.decodeIfPresent(MealSlot.self, forKey: .mealSlot)
        amount = try container.decode(String.self, forKey: .amount)
        unit = try container.decode(String.self, forKey: .unit)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        timeZone = try container.decode(String.self, forKey: .timeZone)
        nutrients = try container.decodeIfPresent(
            [NutrientAmountValue].self,
            forKey: .nutrients
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(item, forKey: .item)
        // Keep the preexisting key so the legacy single-food journal can still
        // decode records written by this build.
        try container.encode(foodID, forKey: .foodID)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(mealSlot, forKey: .mealSlot)
        try container.encode(amount, forKey: .amount)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encodeIfPresent(nutrients, forKey: .nutrients)
    }
}

// MARK: - Legacy single-log journal records

public enum LogSubmissionState: String, Codable, Equatable, Sendable {
    case inFlight
    case uncertain
    case succeeded
    case rejected
    case conflicted
    /// Terminal, never-retryable record for an attempt whose log was
    /// explicitly deleted. The backend may free the idempotency key after a
    /// delete, so replaying this entry could recreate a log the user removed.
    case invalidated
}

public struct PendingLogSubmission: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let foodName: String
    public let draft: LogSubmissionDraft
    public let idempotencyKey: String
    /// Exact HTTP body. Cleared for terminal states that must never be retried.
    public var body: Data?
    public let baseURLString: String
    public let requestPath: String
    public var state: LogSubmissionState
    public var attemptCount: Int
    public let createdAt: Date
    public var updatedAt: Date
    public var lastStatus: Int?
    public var lastMessage: String?
    public var retryAfterSeconds: Int?
    public var resultLogID: String?
    public var resultDate: LocalDiaryDate?
    public var resultMealSlot: MealSlot?
    public var replayed: Bool

    public init(
        id: String,
        accountID: String,
        foodName: String,
        draft: LogSubmissionDraft,
        idempotencyKey: String,
        body: Data?,
        baseURLString: String,
        requestPath: String = "/api/logs",
        state: LogSubmissionState,
        attemptCount: Int = 0,
        createdAt: Date,
        updatedAt: Date,
        lastStatus: Int? = nil,
        lastMessage: String? = nil,
        retryAfterSeconds: Int? = nil,
        resultLogID: String? = nil,
        resultDate: LocalDiaryDate? = nil,
        resultMealSlot: MealSlot? = nil,
        replayed: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.foodName = foodName
        self.draft = draft
        self.idempotencyKey = idempotencyKey
        self.body = body
        self.baseURLString = baseURLString
        self.requestPath = requestPath
        self.state = state
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastStatus = lastStatus
        self.lastMessage = lastMessage
        self.retryAfterSeconds = retryAfterSeconds
        self.resultLogID = resultLogID
        self.resultDate = resultDate
        self.resultMealSlot = resultMealSlot
        self.replayed = replayed
    }

    /// Rebuilds the request wrapper around the stored key and bytes. It does
    /// not re-encode the body.
    public var request: FoodLogCreateRequest? {
        guard let body else { return nil }
        return FoodLogCreateRequest(
            date: draft.date,
            timeZone: draft.timeZone,
            mealSlot: draft.mealSlot,
            foodID: draft.foodID,
            amount: draft.amount,
            unit: draft.unit,
            notes: draft.notes,
            idempotencyKey: idempotencyKey,
            encodedBody: body,
            baseURLString: baseURLString.isEmpty ? nil : baseURLString
        )
    }
}

public struct FoodLogSubmissionSuccess: Equatable, Sendable {
    public let submissionID: String
    public let accountID: String
    public let foodID: String
    public let foodName: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let logID: String?
    public let replayed: Bool

    public init(
        submissionID: String,
        accountID: String,
        foodID: String,
        foodName: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        logID: String?,
        replayed: Bool
    ) {
        self.submissionID = submissionID
        self.accountID = accountID
        self.foodID = foodID
        self.foodName = foodName
        self.date = date
        self.mealSlot = mealSlot
        self.logID = logID
        self.replayed = replayed
    }
}
