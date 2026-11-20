// Library list and custom-food detail view models.

import Combine
import Foundation

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var state: LibraryLoadState = .loading
    @Published public private(set) var foods: [CustomFood] = []
    @Published public private(set) var refreshError: String?
    @Published public private(set) var pendingCreateAttempt: CustomFoodCreateAttempt?
    @Published public private(set) var pendingCreateError: String?
    @Published public var searchText: String = ""

    public let accountID: String

    private let service: any LibraryServicing
    private let reconciliationStore: CustomFoodReconciliationStore
    private let onSessionExpired: () -> Void
    private var loadGeneration = 0

    public init(
        service: any LibraryServicing,
        reconciliationStore: CustomFoodReconciliationStore,
        accountID: String,
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.service = service
        self.reconciliationStore = reconciliationStore
        self.accountID = accountID
        self.onSessionExpired = onSessionExpired
    }

    public var filteredFoods: [CustomFood] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return foods }
        return foods.filter { food in
            food.name.localizedCaseInsensitiveContains(query)
                || (food.brand?.localizedCaseInsensitiveContains(query) ?? false)
                || food.categories.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    public var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if foods.isEmpty {
            state = .loading
        }
        refreshError = nil
        reloadPendingCreate()
        do {
            let fetched = try await service.listCustomFoods()
            guard generation == loadGeneration, !Task.isCancelled else { return }
            foods = fetched.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            state = .loaded
        } catch let error as CustomFoodServiceError {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if error.isUnauthorized {
                onSessionExpired()
            }
            if foods.isEmpty {
                state = .failed(error.message)
            } else {
                refreshError = error.message
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if foods.isEmpty {
                state = .failed(String(localized: "library.error.load"))
            } else {
                refreshError = String(localized: "library.error.load")
            }
        }
        reloadPendingCreate()
    }

    public func refresh() async {
        await load()
    }

    public func removeFood(id: String) {
        foods.removeAll { $0.id == id }
        if foods.isEmpty, state == .loaded {
            state = .loaded
        }
    }

    public func reloadPendingCreate() {
        do {
            pendingCreateAttempt = try reconciliationStore.attempt(accountID: accountID)
            pendingCreateError = nil
        } catch {
            pendingCreateAttempt = nil
            pendingCreateError = String(localized: "library.reconcile.storeUnavailable")
        }
    }
}

// MARK: - Detail

public enum CustomFoodDeleteState: Equatable, Sendable {
    case idle
    case deleting
    case failed(String)
}

@MainActor
public final class CustomFoodDetailViewModel: ObservableObject {
    @Published public private(set) var state: CustomFoodDetailLoadState = .loading
    @Published public private(set) var deleteState: CustomFoodDeleteState = .idle

    public let foodID: String

    private let service: any LibraryServicing
    private let onDeleted: (String) -> Void
    private let onSessionExpired: () -> Void
    private var loadGeneration = 0

    public init(
        foodID: String,
        service: any LibraryServicing,
        onDeleted: @escaping (String) -> Void = { _ in },
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.foodID = foodID
        self.service = service
        self.onDeleted = onDeleted
        self.onSessionExpired = onSessionExpired
    }

    public var food: CustomFood? {
        if case .loaded(let food) = state { return food }
        return nil
    }

    public var isDeleting: Bool {
        if case .deleting = deleteState { return true }
        return false
    }

    public var deleteErrorMessage: String? {
        if case .failed(let message) = deleteState { return message }
        return nil
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading
        do {
            let food = try await service.customFood(id: foodID)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            state = .loaded(food)
        } catch let error as CustomFoodServiceError {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if error.isUnauthorized {
                onSessionExpired()
            }
            switch error {
            case .notFound:
                state = .removed
            default:
                state = .failed(error.message)
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            state = .failed(String(localized: "library.detail.loadFailed"))
        }
    }

    public func delete() async {
        guard !isDeleting, food != nil else { return }
        deleteState = .deleting
        do {
            try await service.deleteCustomFood(id: foodID)
            deleteState = .idle
            onDeleted(foodID)
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                deleteState = .failed(error.message)
                onSessionExpired()
                return
            }
            switch error {
            case .unauthorized:
                deleteState = .failed(error.message)
            case .notFound:
                // A second DELETE after a lost success response is a success
                // for this screen.
                deleteState = .idle
                onDeleted(foodID)
            case .uncertain(let message):
                await resolveUncertainDelete(message: message)
            case .failed(let message), .conflict(let message):
                deleteState = .failed(message)
            case .rateLimited:
                deleteState = .failed(error.message)
            }
        } catch {
            deleteState = .failed(String(localized: "library.detail.deleteFailed"))
        }
    }

    private func resolveUncertainDelete(message: String) async {
        // The delete may have committed. Refresh the authoritative list before
        // offering another destructive action.
        do {
            let foods = try await service.listCustomFoods()
            if foods.contains(where: { $0.id == foodID }) {
                deleteState = .failed(String(localized: "library.detail.deleteUncertain"))
            } else {
                deleteState = .idle
                onDeleted(foodID)
            }
        } catch {
            deleteState = .failed(message)
        }
    }

    public func clearDeleteError() {
        if case .failed = deleteState {
            deleteState = .idle
        }
    }
}
