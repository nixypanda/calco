// Value-type dependency client for the TCA Meals features. It wraps the frozen
// `MealsServicing` contract and the existing shared log-submission writer; it is
// never stored in feature State and introduces no second writer or journal.
//
// EVERY transport carries a captured `MealsRequestContext` (account ID,
// generation, owning presentation and per-call request token). The live client
// checks that context against the CURRENT session authority on the main actor
// before every RPC, including reads and metadata writes. No default-true guard
// and no generation frozen at client construction are possible.

import ComposableArchitecture
import Foundation

public struct MealsCaptureContext: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let accountID: String
    public let generation: UInt64
    public let origin: MealsPresentationOrigin
    /// Captured at intent time so an immutable context travels with every
    /// request and completion; a later state change cannot retarget it.
    public let timeZone: String

    public init(
        id: UUID,
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        accountID: String,
        generation: UInt64,
        origin: MealsPresentationOrigin,
        timeZone: String = TimeZone.current.identifier
    ) {
        self.id = id
        self.date = date
        self.mealSlot = mealSlot
        self.accountID = accountID
        self.generation = generation
        self.origin = origin
        self.timeZone = timeZone
    }

    /// Recipes-only Library embedding and log-only sheets never expose logging
    /// controls. Logging deliveries always carry this immutable context.
    public var allowsLogging: Bool {
        switch origin {
        case .library: return false
        case .sheet, .embedded, .logSheet: return true
        }
    }

    /// Immutable diary target carried into a draft and its completion callback.
    public func loggingContext() -> LibraryLogContext {
        LibraryLogContext(date: date, mealSlot: mealSlot)
    }

    public func requestContext(requestID: UUID) -> MealsRequestContext {
        MealsRequestContext(
            accountID: accountID,
            generation: generation,
            ownerID: id,
            requestID: requestID
        )
    }
}

public enum MealsPresentationOrigin: String, Equatable, Sendable {
    case sheet
    case embedded
    case library
    case logSheet
}

/// Captured authority for one logical request. `requestID` is a per-call token,
/// not a presentation-level deduplication key: the same Meals presentation can
/// legitimately perform several writes.
public struct MealsRequestContext: Equatable, Sendable {
    public let accountID: String
    public let generation: UInt64
    public let ownerID: UUID
    public let requestID: UUID
}

/// One logical submit request. It carries the authoritative server rows, the
/// original drafts and the immutable capture so the parent can build exactly one
/// `DiaryMutationDelivery`.
public struct MealsLoggedPayload: Equatable, Sendable {
    public let requestID: UUID
    public let drafts: [LogSubmissionDraft]
    public let context: LibraryLogContext
    public let accountID: String
    public let generation: UInt64
    public let presentationID: UUID
    public let result: LogSubmissionServiceResult

    public var logs: [FoodLog] { result.createdLogs }
}

public struct MealsFeatureClient: Sendable {
    public var listMeals: @Sendable (MealsRequestContext) async throws -> [Meal]
    public var getMeal: @Sendable (String, MealsRequestContext) async throws -> Meal
    public var createMeal: @Sendable (MealWriteRequest, MealsRequestContext) async throws -> Meal
    public var updateMeal: @Sendable (String, MealWriteRequest, MealsRequestContext) async throws -> Meal
    public var deleteMeal: @Sendable (String, MealsRequestContext) async throws -> Void
    public var mealNutrients: @Sendable (
        String, String, String, MealsRequestContext
    ) async throws -> MealNutritionResponse
    public var fetchUnits: @Sendable (MealsRequestContext) async throws -> [ProductUnit]
    public var searchProducts: @Sendable (String, MealsRequestContext) async throws -> [MealProduct]
    public var fetchProduct: @Sendable (String, MealsRequestContext) async throws -> MealProduct
    public var lastUsedPortion: @Sendable (
        String, LocalDiaryDate, MealSlot?, MealsRequestContext
    ) async throws -> NutritionQuantity?

    /// Wraps the existing writer with an async result; the captured session is
    /// checked on the main actor before the handler is invoked.
    public var submitDraft: @MainActor @Sendable (
        _ drafts: [LogSubmissionDraft],
        _ itemNames: [String],
        _ summary: String,
        _ context: MealsRequestContext
    ) async -> LogSubmissionServiceResult

    /// Current authority. Host wires this against the live window/root session;
    /// it is evaluated on the main actor at every guard, never cached here.
    public var isCurrentSession: @MainActor @Sendable (String, UInt64) -> Bool
    public var timezoneIdentifier: @Sendable () -> String
    public var debounceNanoseconds: UInt64

    public init(
        listMeals: @escaping @Sendable (MealsRequestContext) async throws -> [Meal],
        getMeal: @escaping @Sendable (String, MealsRequestContext) async throws -> Meal,
        createMeal: @escaping @Sendable (MealWriteRequest, MealsRequestContext) async throws -> Meal,
        updateMeal: @escaping @Sendable (String, MealWriteRequest, MealsRequestContext) async throws -> Meal,
        deleteMeal: @escaping @Sendable (String, MealsRequestContext) async throws -> Void,
        mealNutrients: @escaping @Sendable (
            String, String, String, MealsRequestContext
        ) async throws -> MealNutritionResponse,
        fetchUnits: @escaping @Sendable (MealsRequestContext) async throws -> [ProductUnit],
        searchProducts: @escaping @Sendable (String, MealsRequestContext) async throws -> [MealProduct],
        fetchProduct: @escaping @Sendable (String, MealsRequestContext) async throws -> MealProduct,
        lastUsedPortion: @escaping @Sendable (
            String, LocalDiaryDate, MealSlot?, MealsRequestContext
        ) async throws -> NutritionQuantity?,
        submitDraft: @escaping @MainActor @Sendable (
            [LogSubmissionDraft], [String], String, MealsRequestContext
        ) async -> LogSubmissionServiceResult,
        isCurrentSession: @escaping @MainActor @Sendable (String, UInt64) -> Bool,
        timezoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier },
        debounceNanoseconds: UInt64 = 300_000_000
    ) {
        self.listMeals = listMeals
        self.getMeal = getMeal
        self.createMeal = createMeal
        self.updateMeal = updateMeal
        self.deleteMeal = deleteMeal
        self.mealNutrients = mealNutrients
        self.fetchUnits = fetchUnits
        self.searchProducts = searchProducts
        self.fetchProduct = fetchProduct
        self.lastUsedPortion = lastUsedPortion
        self.submitDraft = submitDraft
        self.isCurrentSession = isCurrentSession
        self.timezoneIdentifier = timezoneIdentifier
        self.debounceNanoseconds = debounceNanoseconds
    }

    /// The host MUST supply a live main-actor session check. Every transport is
    /// preceded by `guardCurrent`; failures throw the frozen unauthorized error
    /// so no RPC is sent with cookies/credentials from a newer account.
    public static func live(
        service: any MealsServicing,
        submissionHandler: LogSubmissionHandler?,
        isCurrentSession: @escaping @MainActor @Sendable (String, UInt64) -> Bool,
        timezoneIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier },
        debounceNanoseconds: UInt64 = 300_000_000
    ) -> Self {
        return Self(
            listMeals: { context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.listMeals()
            },
            getMeal: { id, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.getMeal(id: id)
            },
            createMeal: { request, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.createMeal(request)
            },
            updateMeal: { id, request, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.updateMeal(id: id, request)
            },
            deleteMeal: { id, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                try await service.deleteMeal(id: id)
            },
            mealNutrients: { id, amount, unit, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.mealNutrients(mealID: id, amount: amount, unit: unit)
            },
            fetchUnits: { context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.fetchUnits()
            },
            searchProducts: { query, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.searchComponentProducts(query: query)
            },
            fetchProduct: { id, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.fetchComponentProduct(id: id)
            },
            lastUsedPortion: { id, date, slot, context in
                try await Self.guardCurrent(context, isCurrentSession: isCurrentSession)
                return try await service.lastUsedPortion(forMealID: id, date: date, mealSlot: slot)
            },
            submitDraft: { drafts, names, summary, context in
                guard isCurrentSession(context.accountID, context.generation) else {
                    return .failure(.unauthorized)
                }
                guard let submissionHandler else {
                    return .failure(.failed(String(localized: "foodDetail.error.saveFailed")))
                }
                return await withCheckedContinuation { continuation in
                    submissionHandler(drafts, names, summary) { result in
                        continuation.resume(returning: result)
                    }
                }
            },
            isCurrentSession: isCurrentSession,
            timezoneIdentifier: timezoneIdentifier,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    /// Main-actor-safe guard; no `MainActor.assumeIsolated` and no cached result.
    private static func guardCurrent(
        _ context: MealsRequestContext,
        isCurrentSession: @MainActor @Sendable (String, UInt64) -> Bool
    ) async throws {
        let current = await MainActor.run {
            isCurrentSession(context.accountID, context.generation)
        }
        guard current else { throw MealServiceError.unauthorized }
    }
}

public extension DependencyValues {
    var mealsClient: MealsFeatureClient {
        get { self[MealsFeatureClientKey.self] }
        set { self[MealsFeatureClientKey.self] = newValue }
    }
}

private enum MealsFeatureClientKey: DependencyKey {
    // Fail closed: a host that forgets to wire the client must never send an RPC.
    static let liveValue: MealsFeatureClient = .init(
        listMeals: { _ in throw MealServiceError.unauthorized },
        getMeal: { _, _ in throw MealServiceError.unauthorized },
        createMeal: { _, _ in throw MealServiceError.unauthorized },
        updateMeal: { _, _, _ in throw MealServiceError.unauthorized },
        deleteMeal: { _, _ in throw MealServiceError.unauthorized },
        mealNutrients: { _, _, _, _ in throw MealServiceError.unauthorized },
        fetchUnits: { _ in throw MealServiceError.unauthorized },
        searchProducts: { _, _ in throw MealServiceError.unauthorized },
        fetchProduct: { _, _ in throw MealServiceError.unauthorized },
        lastUsedPortion: { _, _, _, _ in throw MealServiceError.unauthorized },
        submitDraft: { _, _, _, _ in .failure(.unauthorized) },
        isCurrentSession: { _, _ in false },
        timezoneIdentifier: { "UTC" }
    )
    static let testValue: MealsFeatureClient = liveValue
}
