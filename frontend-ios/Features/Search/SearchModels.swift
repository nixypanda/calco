import Foundation

public struct FoodSearchResult: Equatable, Identifiable, Sendable {
    public let id: String
    public let source: String
    public let sourceID: String?
    public let barcode: String?
    public let name: String
    public let brand: String?
    public let categories: [String]

    public init(
        id: String,
        source: String = "local",
        sourceID: String? = nil,
        barcode: String? = nil,
        name: String,
        brand: String? = nil,
        categories: [String] = []
    ) {
        self.id = id
        self.source = source
        self.sourceID = sourceID
        self.barcode = barcode
        self.name = name
        self.brand = brand
        self.categories = categories
    }

    public var displayName: String { name }
}

public struct FoodSearchResults: Equatable, Sendable {
    public let items: [FoodSearchResult]

    public init?(_ items: [FoodSearchResult]) {
        guard !items.isEmpty else { return nil }
        self.items = items
    }
}

public enum SearchLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(FoodSearchResults)
    case empty
    case failed(String)
}

public extension SearchLoadState {
    var results: [FoodSearchResult] {
        guard case .loaded(let loaded) = self else { return [] }
        return loaded.items
    }
}

public enum FoodSearchScope: String, CaseIterable, Sendable {
    case all
    case history
    case custom
}

/// Modes exposed by the native search screen. Barcode is a lookup mode rather
/// than a catalog text-search scope.
public enum SearchScopeOption: String, CaseIterable, Sendable {
    case all
    case history
    case custom
    case barcode

    public var foodSearchScope: FoodSearchScope? {
        switch self {
        case .all: return .all
        case .history: return .history
        case .custom: return .custom
        case .barcode: return nil
        }
    }

    public var title: String {
        switch self {
        case .all: return String(localized: "search.scope.all")
        case .history: return String(localized: "search.scope.history")
        case .custom: return String(localized: "search.scope.custom")
        case .barcode: return String(localized: "search.scope.barcode")
        }
    }
}

public protocol FoodSearchHistoryServicing: Sendable {
    func recentItems(
        from: LocalDiaryDate,
        to: LocalDiaryDate,
        mealSlot: MealSlot?
    ) async throws -> [RecentLogItem]
    func categorySuggestions(query: String, limit: Int) async throws -> [CategorySuggestion]
    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup
}

public extension FoodSearchHistoryServicing {
    func categorySuggestions(query: String, limit: Int) async throws -> [CategorySuggestion] {
        []
    }
}

public protocol FoodSearchServicing: Sendable {
    func searchFoods(query: String, scope: FoodSearchScope) async throws -> [FoodSearchResult]
}

public struct FoodSearchServiceError: Error, Equatable, Sendable {
    public let message: String
    public let isUnauthorized: Bool

    public init(_ message: String, isUnauthorized: Bool = false) {
        self.message = message
        self.isUnauthorized = isUnauthorized
    }

    public static let unauthorized = FoodSearchServiceError("", isUnauthorized: true)
}

public func isUnauthorizedFoodSearchError(_ error: Error) -> Bool {
    if let serviceError = error as? FoodSearchServiceError, serviceError.isUnauthorized {
        return true
    }
    if let apiError = error as? CalCoAPIError, apiError.isUnauthorized {
        return true
    }
    return false
}

public func isCancelledFoodSearchError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if let apiError = error as? CalCoAPIError, case .cancelled = apiError {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

public func foodSearchErrorMessage(_ error: Error) -> String {
    let rawMessage: String
    if let serviceError = error as? FoodSearchServiceError {
        rawMessage = serviceError.message
    } else if let apiError = error as? CalCoAPIError,
              let message = apiError.payload?.message {
        rawMessage = message
    } else {
        rawMessage = (error as NSError).localizedDescription
    }
    return rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
}
