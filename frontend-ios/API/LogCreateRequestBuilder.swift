// Builds the single-log JSON body once. Retries must send this Data unchanged.

import Foundation

public enum LogCreateRequestBuilderError: Error, Equatable, Sendable {
    case invalidKey
    case bodyTooLarge
    case encoding(String)
}

public enum LogCreateRequestBuilder {
    public static let maxBodyBytes = 32_768

    public static func prepare(
        foodID: String,
        foodName: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZoneIdentifier: String,
        baseURL: URL?,
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) throws -> (draft: LogSubmissionDraft, request: FoodLogCreateRequest, body: Data) {
        let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.count <= 128,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw LogCreateRequestBuilderError.invalidKey
        }

        let draft = makeDraft(
            foodID: foodID,
            date: date,
            mealSlot: mealSlot,
            amount: amount,
            unit: unit,
            notes: notes,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let request = FoodLogCreateRequest(
            date: draft.date,
            timeZone: draft.timeZone,
            mealSlot: draft.mealSlot,
            foodID: draft.foodID,
            amount: draft.amount,
            unit: draft.unit,
            notes: draft.notes,
            idempotencyKey: key,
            baseURLString: baseURL?.absoluteString
        )
        let body = try encode(request)
        let preparedRequest = request.withEncodedBody(body)
        return (draft, preparedRequest, body)
    }

    public static func makeDraft(
        foodID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZoneIdentifier: String
    ) -> LogSubmissionDraft {
        LogSubmissionDraft(
            foodID: foodID,
            date: date,
            mealSlot: mealSlot,
            amount: amount.trimmingCharacters(in: .whitespacesAndNewlines),
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: canonicalNotes(notes),
            timeZone: timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public static func encode(_ request: FoodLogCreateRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body: Data
        do {
            body = try encoder.encode(CreateLogRequest(
                logDate: request.date,
                deviceTimeZone: request.timeZone,
                mealSlot: request.mealSlot,
                productID: request.foodID,
                quantity: NutritionQuantity(amount: request.amount, unit: request.unit),
                notes: request.notes,
                idempotencyKey: request.idempotencyKey
            ))
        } catch {
            throw LogCreateRequestBuilderError.encoding(error.localizedDescription)
        }
        guard body.count <= maxBodyBytes else {
            throw LogCreateRequestBuilderError.bodyTooLarge
        }
        return body
    }

    public static func canonicalNotes(_ notes: String?) -> String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.precomposedStringWithCanonicalMapping
    }
}
