// Builds typed single, batch, and ad-hoc request bodies once. Journal retries
// must send the stored bytes unchanged.

import Foundation

public struct LogCreateItemRef: Encodable, Equatable, Sendable {
    public let type: String
    public let id: String?
    public let name: String?
    public let brand: String?

    public init(_ item: LogSubmissionItem) {
        switch item {
        case .product(let id):
            type = "product"
            self.id = id
            name = nil
            brand = nil
        case .meal(let id):
            type = "meal"
            self.id = id
            name = nil
            brand = nil
        case .adHoc(let name, let brand):
            type = "ad_hoc"
            id = nil
            self.name = name
            self.brand = brand
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case brand
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(brand, forKey: .brand)
    }
}

public struct LogCreateLineRequest: Encodable, Equatable, Sendable {
    public let logDate: LocalDiaryDate
    public let deviceTimeZone: String?
    public let mealSlot: MealSlot?
    public let item: LogCreateItemRef
    public let quantity: NutritionQuantity
    public let notes: String?

    public init(draft: LogSubmissionDraft) {
        logDate = draft.date
        deviceTimeZone = draft.timeZone
        mealSlot = draft.mealSlot
        item = LogCreateItemRef(draft.item)
        quantity = NutritionQuantity(amount: draft.amount, unit: draft.unit)
        notes = draft.notes
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case deviceTimeZone = "device_timezone"
        case mealSlot = "meal_slot"
        case item
        case quantity
        case notes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encodeIfPresent(deviceTimeZone, forKey: .deviceTimeZone)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(item, forKey: .item)
        try container.encode(quantity, forKey: .quantity)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

public struct SingleLogSubmissionRequest: Encodable, Equatable, Sendable {
    public let logDate: LocalDiaryDate
    public let deviceTimeZone: String?
    public let mealSlot: MealSlot?
    public let item: LogCreateItemRef
    public let quantity: NutritionQuantity
    public let notes: String?
    public let idempotencyKey: String

    public init(draft: LogSubmissionDraft, idempotencyKey: String) {
        logDate = draft.date
        deviceTimeZone = draft.timeZone
        mealSlot = draft.mealSlot
        item = LogCreateItemRef(draft.item)
        quantity = NutritionQuantity(amount: draft.amount, unit: draft.unit)
        notes = draft.notes
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case deviceTimeZone = "device_timezone"
        case mealSlot = "meal_slot"
        case item
        case quantity
        case notes
        case idempotencyKey = "idempotency_key"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encodeIfPresent(deviceTimeZone, forKey: .deviceTimeZone)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(item, forKey: .item)
        try container.encode(quantity, forKey: .quantity)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
    }
}

public struct AdHocNutrientRequest: Encodable, Equatable, Sendable {
    public let code: String
    public let amount: String
    public let unit: String

    public init(_ nutrient: NutrientAmountValue) {
        code = nutrient.code
        amount = nutrient.amount
        unit = nutrient.unit
    }
}

public struct AdHocLogSubmissionRequest: Encodable, Equatable, Sendable {
    public let logDate: LocalDiaryDate
    public let deviceTimeZone: String?
    public let mealSlot: MealSlot?
    public let name: String
    public let brand: String?
    public let quantity: NutritionQuantity
    public let nutrients: [AdHocNutrientRequest]
    public let notes: String?
    public let idempotencyKey: String

    public init(draft: LogSubmissionDraft, idempotencyKey: String) throws {
        guard case .adHoc(let name, let brand) = draft.item else {
            throw LogCreateRequestBuilderError.invalidItem
        }
        logDate = draft.date
        deviceTimeZone = draft.timeZone
        mealSlot = draft.mealSlot
        self.name = name
        self.brand = brand
        quantity = NutritionQuantity(amount: draft.amount, unit: draft.unit)
        nutrients = (draft.nutrients ?? []).map(AdHocNutrientRequest.init)
        notes = draft.notes
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case logDate = "log_date"
        case deviceTimeZone = "device_timezone"
        case mealSlot = "meal_slot"
        case name
        case brand
        case quantity
        case nutrients
        case notes
        case idempotencyKey = "idempotency_key"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeLocalDiaryDate(logDate, forKey: .logDate)
        try container.encodeIfPresent(deviceTimeZone, forKey: .deviceTimeZone)
        try container.encodeIfPresent(mealSlot?.rawValue, forKey: .mealSlot)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(nutrients, forKey: .nutrients)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
    }
}

public struct BatchLogSubmissionItemRequest: Encodable, Equatable, Sendable {
    public let line: LogCreateLineRequest

    public init(draft: LogSubmissionDraft) {
        line = LogCreateLineRequest(draft: draft)
    }

    public func encode(to encoder: Encoder) throws {
        try line.encode(to: encoder)
    }
}

public struct BatchLogSubmissionRequest: Encodable, Equatable, Sendable {
    public let items: [BatchLogSubmissionItemRequest]
    public let idempotencyKey: String

    public init(drafts: [LogSubmissionDraft], idempotencyKey: String) {
        items = drafts.map(BatchLogSubmissionItemRequest.init)
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case idempotencyKey = "idempotency_key"
    }
}

public enum LogSubmissionRequestBuilder {
    public static let maxDrafts = 50

    public static func prepare(
        drafts: [LogSubmissionDraft],
        baseURL: URL?,
        idempotencyKey: String = UUID().uuidString.lowercased()
    ) throws -> (route: LogSubmissionRoute, request: LogSubmissionRequest) {
        guard !drafts.isEmpty, drafts.count <= maxDrafts else {
            throw LogCreateRequestBuilderError.invalidItem
        }
        let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.count <= 128,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw LogCreateRequestBuilderError.invalidKey
        }

        let route = LogSubmissionRoute.route(for: drafts)
        guard Self.routeMatches(route: route, drafts: drafts) else {
            throw LogCreateRequestBuilderError.invalidItem
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            switch route {
            case .single:
                data = try encoder.encode(
                    SingleLogSubmissionRequest(draft: drafts[0], idempotencyKey: key)
                )
            case .batch:
                data = try encoder.encode(
                    BatchLogSubmissionRequest(drafts: drafts, idempotencyKey: key)
                )
            case .adHoc:
                data = try encoder.encode(
                    AdHocLogSubmissionRequest(draft: drafts[0], idempotencyKey: key)
                )
            }
        } catch let error as LogCreateRequestBuilderError {
            throw error
        } catch {
            throw LogCreateRequestBuilderError.encoding(error.localizedDescription)
        }
        guard data.count <= LogCreateRequestBuilder.maxBodyBytes else {
            throw LogCreateRequestBuilderError.bodyTooLarge
        }
        return (
            route,
            LogSubmissionRequest(
                requestPath: route.requestPath,
                idempotencyKey: key,
                body: data,
                baseURLString: baseURL?.absoluteString
            )
        )
    }

    /// Batch and single lines must reference catalog product/meal IDs. Ad-hoc
    /// data is only valid on its dedicated route, which carries nutrients.
    private static func routeMatches(
        route: LogSubmissionRoute,
        drafts: [LogSubmissionDraft]
    ) -> Bool {
        guard drafts.allSatisfy({
            let validIdentity: Bool
            switch $0.item {
            case .product(let id), .meal(let id):
                validIdentity = !id.isEmpty
            case .adHoc(let name, _):
                validIdentity = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return validIdentity
                && !$0.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.timeZone.isEmpty
                && parsePositiveLogAmount($0.amount) != nil
        }) else { return false }
        switch route {
        case .single:
            guard drafts.count == 1, let item = drafts.first?.item else {
                return false
            }
            if case .adHoc = item { return false }
            return true
        case .batch:
            guard drafts.count >= 2 else { return false }
            return drafts.allSatisfy {
                if case .adHoc = $0.item { return false }
                return true
            }
        case .adHoc:
            guard drafts.count == 1, let item = drafts.first?.item else {
                return false
            }
            if case .adHoc = item { return true }
            return false
        }
    }
}
