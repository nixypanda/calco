// Durable single-log submission records. The encoded request body is stored
// verbatim so a user-triggered retry cannot re-encode different bytes.

import Foundation

public struct LogSubmissionDraft: Codable, Equatable, Sendable {
    public let foodID: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let amount: String
    public let unit: String
    public let notes: String?
    /// Frozen at first submit so a device timezone change cannot alter a retry.
    public let timeZone: String

    public init(
        foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZone: String
    ) {
        self.foodID = foodID
        self.date = date
        self.mealSlot = mealSlot
        self.amount = amount
        self.unit = unit
        self.notes = notes
        self.timeZone = timeZone
    }
}

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
