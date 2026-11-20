// Durable typed submission records. The encoded request body is stored
// verbatim so a user-triggered retry cannot re-encode different bytes.

import CryptoKit
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

    /// Source-compatible product initializer used by the single-food flow.
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
    public var foodID: String { item.identifier ?? "" }

    public var productID: String? { item.productID }
}

extension LogSubmissionDraft: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
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
            // Schema v1 stored only a product ID.
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
        try container.encode(2, forKey: .schemaVersion)
        try container.encode(item, forKey: .item)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(mealSlot, forKey: .mealSlot)
        try container.encode(amount, forKey: .amount)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encodeIfPresent(nutrients, forKey: .nutrients)
    }
}

// MARK: - State and records

public enum LogSubmissionState: String, Codable, Equatable, Sendable {
    case inFlight
    case uncertain
    case succeeded
    case rejected
    case conflicted
    /// The request was never sent because the configured API origin changed.
    /// The stored exact body/key remain for manual recovery/discard, but the
    /// operation must never be replayed against the new server.
    case serverChanged
    /// Created before the current server's batch/ad-hoc journal capability was
    /// verified (or migrated from a pre-v2 journal). Never replay it silently;
    /// only explicit reconciliation/discard is allowed.
    case reconciliationOnly
    /// Terminal, never-retryable record for an attempt whose log was
    /// explicitly deleted. The backend may free the idempotency key after a
    /// delete, so replaying this entry could recreate a log the user removed.
    case invalidated
}

public enum LogSubmissionRoute: String, Codable, Equatable, Sendable {
    case single
    case batch
    case adHoc

    public var requestPath: String {
        switch self {
        case .single: return "/api/logs"
        case .batch: return "/api/logs/batch"
        case .adHoc: return "/api/logs/ad-hoc"
        }
    }

    public static func route(for drafts: [LogSubmissionDraft]) -> LogSubmissionRoute {
        guard drafts.count > 1 else {
            if drafts.count == 1, case .adHoc = drafts[0].item {
                return .adHoc
            }
            return .single
        }
        return .batch
    }
}

public struct LogSubmissionRequest: Equatable, Sendable {
    public let requestPath: String
    public let idempotencyKey: String
    public let body: Data
    public let baseURLString: String?

    public init(
        requestPath: String,
        idempotencyKey: String,
        body: Data,
        baseURLString: String? = nil
    ) {
        self.requestPath = requestPath
        self.idempotencyKey = idempotencyKey
        self.body = body
        self.baseURLString = baseURLString
    }

    /// Stable identity for exact request bytes. The journal keeps this after
    /// terminal states clear the body so a changed payload cannot be mistaken
    /// for a replay of the original operation.
    public static func bodySHA256(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LogSubmissionCreatedLog: Codable, Equatable, Sendable {
    public let id: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let item: LogSubmissionItem

    public init(
        id: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        item: LogSubmissionItem
    ) {
        self.id = id
        self.date = date
        self.mealSlot = mealSlot
        self.item = item
    }
}

public struct PendingLogSubmission: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let foodName: String
    /// First draft. Kept as the primary compatibility field for the existing
    /// single-food recovery surface.
    public let draft: LogSubmissionDraft
    /// Populated only for batch submissions; `draft` is the first item.
    public let batchDrafts: [LogSubmissionDraft]?
    /// Human labels in draft order. Optional for journals written before this
    /// field existed; recovery falls back to the summary.
    public let itemNames: [String]?
    /// Version of the idempotency journal capability verified when a non-single
    /// operation was reserved. Nil for legacy/single entries.
    public let capabilityVersion: Int?
    public let idempotencyKey: String
    /// Exact HTTP body. Cleared for terminal states that must never be retried.
    public var body: Data?
    /// SHA-256 of the exact reserved request body, retained after terminal
    /// states clear `body`. Nil on legacy terminal rows that predate it.
    public var requestSHA256: String?
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
    public var resultLogs: [LogSubmissionCreatedLog]?
    public var replayed: Bool

    public init(
        id: String,
        accountID: String,
        foodName: String,
        draft: LogSubmissionDraft,
        batchDrafts: [LogSubmissionDraft]? = nil,
        itemNames: [String]? = nil,
        capabilityVersion: Int? = nil,
        idempotencyKey: String,
        body: Data?,
        requestSHA256: String? = nil,
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
        resultLogs: [LogSubmissionCreatedLog]? = nil,
        replayed: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.foodName = foodName
        self.draft = draft
        self.batchDrafts = batchDrafts
        self.itemNames = itemNames
        self.capabilityVersion = capabilityVersion
        self.idempotencyKey = idempotencyKey
        self.body = body
        self.requestSHA256 = requestSHA256
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
        self.resultLogs = resultLogs
        self.replayed = replayed
    }

    public var allDrafts: [LogSubmissionDraft] {
        batchDrafts ?? [draft]
    }

    /// Durable identity check used by handoff adapters before replaying a
    /// terminal or pending operation for the same key. Compares origin, path,
    /// typed drafts, key, and the exact request bytes. A legacy terminal row
    /// with neither body nor retained hash cannot claim a match.
    public func matchesRequest(
        _ request: LogSubmissionRequest,
        drafts: [LogSubmissionDraft]
    ) -> Bool {
        guard idempotencyKey == request.idempotencyKey,
              requestPath == request.requestPath,
              baseURLString == (request.baseURLString ?? ""),
              allDrafts == drafts else {
            return false
        }
        if let requestSHA256 {
            return requestSHA256 == LogSubmissionRequest.bodySHA256(request.body)
        }
        if let body {
            return body == request.body
        }
        return false
    }

    /// Label for the draft at `index`, or a stable positional fallback.
    public func itemName(at index: Int) -> String {
        if let itemNames, itemNames.indices.contains(index),
           !itemNames[index].isEmpty {
            return itemNames[index]
        }
        if index == 0, !foodName.isEmpty {
            return foodName
        }
        return String(
            format: String(localized: "submission.itemNumber"),
            index + 1
        )
    }

    public var isBatch: Bool {
        requestPath == LogSubmissionRoute.batch.requestPath
    }

    /// Generic request rebuilt around the stored key and exact bytes.
    public var submissionRequest: LogSubmissionRequest? {
        guard let body else { return nil }
        return LogSubmissionRequest(
            requestPath: requestPath,
            idempotencyKey: idempotencyKey,
            body: body,
            baseURLString: baseURLString.isEmpty ? nil : baseURLString
        )
    }

    /// Compatibility wrapper for the existing single-product sender.
    public var request: FoodLogCreateRequest? {
        guard requestPath == "/api/logs", let body else { return nil }
        guard case .product(let foodID) = draft.item else { return nil }
        return FoodLogCreateRequest(
            date: draft.date,
            timeZone: draft.timeZone,
            mealSlot: draft.mealSlot,
            foodID: foodID,
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
    public let logs: [LogSubmissionCreatedLog]
    public let replayed: Bool

    public init(
        submissionID: String,
        accountID: String,
        foodID: String,
        foodName: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        logID: String?,
        logs: [LogSubmissionCreatedLog] = [],
        replayed: Bool
    ) {
        self.submissionID = submissionID
        self.accountID = accountID
        self.foodID = foodID
        self.foodName = foodName
        self.date = date
        self.mealSlot = mealSlot
        self.logID = logID
        self.logs = logs
        self.replayed = replayed
    }
}
