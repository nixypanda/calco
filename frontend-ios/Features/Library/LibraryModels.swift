// Library service contracts and shared error vocabulary.

import Foundation

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
        if case .unauthorized = self { return true }
        return false
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

/// Thin async seam over the app shell's shared log submission handler. The
/// feature never posts logs directly and keeps no pending-operation state.
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

/// Safe default until the app shell wires the shared handler. It never writes a
/// log and never attempts a fallback POST.
@MainActor
public final class UnavailableLibraryLogSubmissionService: LibraryLogSubmitting {
    nonisolated public init() {}

    public func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        .failure(.failed(String(localized: "library.submission.unavailable")))
    }
}

/// Adapts the app shell's `LogSubmissionHandler` (the same callback used by
/// quick-add, repeat, and batch review) to an async call. The handler must
/// call its completion exactly once on every path.
@MainActor
public final class HandlerLibraryLogSubmissionService: LibraryLogSubmitting {
    private let handler: LogSubmissionHandler

    public init(handler: @escaping LogSubmissionHandler) {
        self.handler = handler
    }

    public func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        await withCheckedContinuation { continuation in
            handler(drafts, itemNames, summary) { result in
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - Load state

public enum LibraryLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

public enum CustomFoodDetailLoadState: Equatable, Sendable {
    case loading
    case loaded(CustomFood)
    case removed
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

public enum LibraryLogIntentFormat {
    public static func summary(
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String
    ) -> String {
        String(
            format: String(localized: "library.log.intent"),
            amount,
            unit,
            date.formatted,
            slotLabel(mealSlot)
        )
    }

    public static func slotLabel(_ slot: MealSlot?) -> String {
        switch slot {
        case .none:
            return String(localized: "foodDetail.mealSlot.none")
        case .breakfast:
            return String(localized: "foodDetail.mealSlot.breakfast")
        case .lunch:
            return String(localized: "foodDetail.mealSlot.lunch")
        case .dinner:
            return String(localized: "foodDetail.mealSlot.dinner")
        case .snack:
            return String(localized: "foodDetail.mealSlot.snack")
        case .lateNightSnack:
            return String(localized: "foodDetail.mealSlot.lateNightSnack")
        }
    }
}
