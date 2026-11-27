// Library service contracts and shared error vocabulary.

import Foundation

public enum CustomFoodEditorMode: Equatable, Sendable {
    case create
    case edit(id: String)

    public var foodID: String? {
        if case .edit(let id) = self { id } else { nil }
    }

    public var isCreate: Bool {
        if case .create = self { true } else { false }
    }
}

public struct ServingEditorRow: Identifiable, Equatable, Sendable {
    public let id: String
    public var unit: String
    public var gramsPerUnit: String

    public init(id: String = UUID().uuidString.lowercased(), unit: String = "", gramsPerUnit: String = "") {
        self.id = id
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }
}

public enum AdHocSaveMode: String, CaseIterable, Equatable, Sendable {
    case logOnly
    case saveAndLog
}

/// In-memory intent for logging a custom food returned by a successful create.
public struct SavedFoodLogIntent: Equatable, Sendable {
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let amount: String
    public let unit: String
    public let notes: String?
    public let timeZone: String
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

public struct AdHocReview: Equatable, Identifiable, Sendable {
    public let id: String
    public let mode: AdHocSaveMode
    public let name: String
    public let amount: String
    public let unit: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let draft: LogSubmissionDraft
    public let customFood: CustomFoodWriteRequest?
    public let logIntent: SavedFoodLogIntent?

    public init(
        id: String = UUID().uuidString.lowercased(),
        mode: AdHocSaveMode,
        name: String,
        amount: String,
        unit: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        draft: LogSubmissionDraft,
        customFood: CustomFoodWriteRequest?,
        logIntent: SavedFoodLogIntent?
    ) {
        self.id = id
        self.mode = mode
        self.name = name
        self.amount = amount
        self.unit = unit
        self.date = date
        self.mealSlot = mealSlot
        self.draft = draft
        self.customFood = customFood
        self.logIntent = logIntent
    }
}

/// Immutable diary target captured when a Library/Meals logging flow is opened.
/// Routes keep this value for their whole lifetime so a later diary date or
/// slot change cannot silently retarget an already-open draft or its POST.
public struct LibraryLogContext: Equatable, Hashable, Sendable {
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?

    public init(date: LocalDiaryDate, mealSlot: MealSlot? = nil) {
        self.date = date
        self.mealSlot = mealSlot
    }
}

public enum CustomFoodServiceError: Error, Equatable, Sendable {
    case unauthorized
    case notFound(String)
    /// A definitive rejection: the server did not apply the request.
    case failed(String)
    /// Transport or server ambiguity: the request may have been applied.
    case uncertain(String)
    case conflict(String)
    case rateLimited(retryAfterSeconds: Int?)

    public var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .notFound(let message), .failed(let message), .uncertain(let message),
             .conflict(let message):
            return message
        case .rateLimited:
            return String(localized: "foodDetail.error.rateLimited")
        }
    }

    public var isUnauthorized: Bool {
        if case .unauthorized = self { true } else { false }
    }
}

public protocol LibraryServicing: Sendable {
    func listCustomFoods() async throws -> [CustomFood]
    func customFood(id: String) async throws -> CustomFood
    func nutrientDefinitions() async throws -> [NutrientDefinition]
    func units() async throws -> [ProductUnit]
    func createCustomFood(_ request: CustomFoodWriteRequest) async throws -> String
    func updateCustomFood(id: String, request: CustomFoodWriteRequest) async throws -> String
    func deleteCustomFood(id: String) async throws
}

public extension LibraryServicing {
    func nutrientDefinitions() async throws -> [NutrientDefinition] { [] }
    func units() async throws -> [ProductUnit] { [] }
}

// MARK: - Shared safe submission contract

@MainActor
public protocol LibraryLogSubmitting: AnyObject {
    func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult
}

// MARK: - Load state

public enum LibraryLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

public enum LibrarySubmissionState: Equatable, Sendable {
    case idle
    case submitting
    case failed(message: String)
    case completed(logID: String?)
}

/// Logging state after a custom food has already been created. The retained
/// food ID is kept in memory so an explicit user retry logs the existing food
/// instead of creating it again.
public enum SavedFoodLogState: Equatable, Sendable {
    case none
    case logging
    /// The log was not confirmed. The user may check the diary and explicitly
    /// retry the retained food if needed.
    case failed(message: String)
    case logged(logID: String?)
}
