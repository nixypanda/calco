// Durable uncertain-custom-food-create record.
//
// `POST /api/foods/custom` is not idempotent. Once a create response is lost,
// the client must refresh the library and let the user pick the matching food
// instead of posting the same body again. These values are persisted outside
// the food-log submission journal because a catalog create cannot be replayed
// by that journal.

import Foundation

public struct CustomFoodJournalRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let requestPath: String
    public let body: Data
    public let baseURLString: String?

    public init(
        operationID: String,
        requestPath: String,
        body: Data,
        baseURLString: String?
    ) {
        self.operationID = operationID
        self.requestPath = requestPath
        self.body = body
        self.baseURLString = baseURLString
    }

    public var submissionRequest: LogSubmissionRequest {
        LogSubmissionRequest(
            requestPath: requestPath,
            idempotencyKey: operationID,
            body: body,
            baseURLString: baseURLString
        )
    }
}

public struct CustomFoodLogIntent: Codable, Equatable, Sendable {
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let amount: String
    public let unit: String
    public let notes: String?
    public let timeZone: String

    public init(
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZone: String
    ) {
        self.date = date
        self.mealSlot = mealSlot
        self.amount = amount
        self.unit = unit
        self.notes = notes
        self.timeZone = timeZone
    }

    public func logSubmissionDraft(productID: String) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: .product(id: productID),
            date: date,
            mealSlot: mealSlot,
            amount: amount,
            unit: unit,
            notes: notes,
            timeZone: timeZone
        )
    }
}

public struct CustomFoodCreateAttempt: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let draft: CustomFoodWriteRequest
    /// Library IDs observed immediately before the create was sent. A
    /// reconciled match must not be one of these older foods.
    public let baselineFoodIDs: [String]
    /// Present for "save food and log" so the log can resume once the saved
    /// food is identified.
    public let logIntent: CustomFoodLogIntent?
    /// Returned by the catalog POST. This is persisted before the log journal
    /// is touched so a process kill in the gap resumes the existing food.
    public let foodID: String?
    /// Durable journal operation identity. Persisted before the catalog POST so
    /// a relaunch reuses the same backend idempotency key.
    public let journalOperationID: String?
    /// Server origin this log intent belongs to.
    public let journalBaseURLString: String?
    /// Exact serialized journal request. Persisted before the journal is
    /// touched so retries preserve the original key and body even if the
    /// journal prunes the terminal entry.
    public let journalRequest: CustomFoodJournalRequest?
    public let createdAt: Date
    public let message: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        accountID: String,
        draft: CustomFoodWriteRequest,
        baselineFoodIDs: [String],
        logIntent: CustomFoodLogIntent? = nil,
        foodID: String? = nil,
        journalOperationID: String? = nil,
        journalBaseURLString: String? = nil,
        journalRequest: CustomFoodJournalRequest? = nil,
        createdAt: Date = Date(),
        message: String
    ) {
        self.id = id
        self.accountID = accountID
        self.draft = draft
        self.baselineFoodIDs = baselineFoodIDs
        self.logIntent = logIntent
        self.foodID = foodID
        self.journalOperationID = journalOperationID
        self.journalBaseURLString = journalBaseURLString
        self.journalRequest = journalRequest
        self.createdAt = createdAt
        self.message = message
    }

    public var isAwaitingLogHandoff: Bool {
        foodID != nil && logIntent != nil
    }

    /// Records the catalog result without changing the operation identity.
    public func withReturnedFoodID(_ foodID: String) -> CustomFoodCreateAttempt {
        CustomFoodCreateAttempt(
            id: id,
            accountID: accountID,
            draft: draft,
            baselineFoodIDs: baselineFoodIDs,
            logIntent: logIntent,
            foodID: foodID,
            journalOperationID: journalOperationID,
            journalBaseURLString: journalBaseURLString,
            journalRequest: journalRequest,
            createdAt: createdAt,
            message: String(localized: "library.log.resumeMessage")
        )
    }

    public func withJournalRequest(
        _ request: CustomFoodJournalRequest
    ) -> CustomFoodCreateAttempt {
        CustomFoodCreateAttempt(
            id: id,
            accountID: accountID,
            draft: draft,
            baselineFoodIDs: baselineFoodIDs,
            logIntent: logIntent,
            foodID: foodID,
            journalOperationID: request.operationID,
            journalBaseURLString: request.baseURLString,
            journalRequest: request,
            createdAt: createdAt,
            message: String(localized: "library.log.resumeMessage")
        )
    }

    public var displayName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isSaveAndLog: Bool {
        logIntent != nil
    }

    /// Candidates are newly listed foods that normalize to exactly the
    /// attempted aggregate. The caller still asks the user to confirm a match.
    public func matches(in foods: [CustomFood]) -> [CustomFood] {
        let baseline = Set(baselineFoodIDs)
        return foods.filter { food in
            !baseline.contains(food.id)
                && food.asWriteRequest().map(draft.matches) == true
        }
    }
}
