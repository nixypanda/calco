// Meal list loading and journal-backed quick add.

import Combine
import Foundation

@MainActor
public final class MealsListViewModel: ObservableObject {
    @Published public private(set) var state: MealsListLoadState = .idle
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var transientError: String?
    @Published public private(set) var quickAddState: MealQuickAddState = .idle

    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?

    private let service: MealsServicing
    private let onSubmitDrafts: LogSubmissionHandler?
    private let onSessionExpired: () -> Void
    private let onLogged: ((LocalDiaryDate, MealSlot?) -> Void)?
    private let timeZoneProvider: () -> String
    private var loadToken = 0

    public init(
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        service: MealsServicing,
        onSubmitDrafts: LogSubmissionHandler? = nil,
        onSessionExpired: @escaping () -> Void = {},
        onLogged: ((LocalDiaryDate, MealSlot?) -> Void)? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier }
    ) {
        self.date = date
        self.mealSlot = mealSlot
        self.service = service
        self.onSubmitDrafts = onSubmitDrafts
        self.onSessionExpired = onSessionExpired
        self.onLogged = onLogged
        self.timeZoneProvider = timeZoneProvider
    }

    public var meals: [Meal] { state.meals }

    public var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    public var isEmpty: Bool {
        guard case .loaded(let meals) = state else { return false }
        return meals.isEmpty
    }

    public var quickAddMessage: String? {
        switch quickAddState {
        case .idle, .submitting:
            return nil
        case .added:
            return String(localized: "meals.list.quickAdd.added")
        case .failed(let message):
            return message
        }
    }

    public func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    public func load() async {
        if isLoading { return }
        loadToken += 1
        let token = loadToken
        let hadContent = !meals.isEmpty
        if !hadContent {
            state = .loading
        } else {
            isRefreshing = true
        }
        transientError = nil

        do {
            let loaded = try await service.listMeals()
            guard token == loadToken else { return }
            state = .loaded(loaded)
            isRefreshing = false
        } catch {
            guard token == loadToken else { return }
            isRefreshing = false
            if isUnauthorizedMealError(error) {
                onSessionExpired()
                state = .failed(String(localized: "meals.error.sessionExpired"))
                return
            }
            if let mealError = error as? MealServiceError,
               case .cancelled = mealError {
                if hadContent {
                    state = .loaded(meals)
                } else {
                    state = .idle
                }
                return
            }
            let message = mealServiceMessage(error)
            if hadContent {
                transientError = message.isEmpty
                    ? String(localized: "meals.error.loadFailed")
                    : message
            } else {
                state = .failed(
                    message.isEmpty
                        ? String(localized: "meals.error.loadFailed")
                        : message
                )
            }
        }
    }

    public func refresh() async {
        await load()
    }

    public func dismissTransientError() {
        transientError = nil
    }

    public func canQuickAdd(_ meal: Meal) -> Bool {
        guard onSubmitDrafts != nil,
              !meal.isDegraded,
              !isSubmittingQuickAdd else { return false }
        return MealLogDraftBuilder.makeDraft(
            meal: meal,
            date: date,
            mealSlot: mealSlot,
            timeZone: timeZoneProvider()
        ) != nil
    }

    public func quickAdd(_ meal: Meal, portion: NutritionQuantity? = nil) {
        guard let onSubmitDrafts, case .idle = quickAddState else { return }
        guard !meal.isDegraded else {
            quickAddState = .failed(String(localized: "meals.error.missingComponents"))
            return
        }
        guard let draft = MealLogDraftBuilder.makeDraft(
            meal: meal,
            date: date,
            mealSlot: mealSlot,
            amount: portion?.amount,
            unit: portion?.unit,
            timeZone: timeZoneProvider()
        ) else {
            quickAddState = .failed(String(localized: "meals.error.invalidPortion"))
            return
        }

        quickAddState = .submitting(mealID: meal.id)
        onSubmitDrafts([draft], [meal.name], meal.name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.quickAddState = .added(mealID: meal.id)
                self.onLogged?(self.date, self.mealSlot)
            case .failure(let failure):
                if failure == .unauthorized {
                    self.onSessionExpired()
                }
                self.quickAddState = .failed(failure.message)
            }
        }
    }

    public func dismissQuickAddMessage() {
        guard case .submitting = quickAddState else {
            quickAddState = .idle
            return
        }
    }

    private var isSubmittingQuickAdd: Bool {
        if case .submitting = quickAddState { return true }
        return false
    }
}
