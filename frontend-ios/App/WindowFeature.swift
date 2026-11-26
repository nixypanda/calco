import ComposableArchitecture
import Foundation

/// Pure TCA-owned presentation payload for search-originated custom food
/// creation. It captures the exact search context so stale dismissals/completions
/// cannot clear or overwrite a newer presentation.
public struct SearchFoodCreationPresentation: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let barcode: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let generation: UInt64
    public let origin: SearchScreenFeature.NavigationOrigin

    public init(
        id: UUID,
        barcode: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        generation: UInt64,
        origin: SearchScreenFeature.NavigationOrigin
    ) {
        self.id = id
        self.barcode = barcode
        self.date = date
        self.mealSlot = mealSlot
        self.generation = generation
        self.origin = origin
    }
}

/// Window owns signed-in destination state for migrated screens.
///
/// The window owns nutrition and search destinations, their selected/today
/// context, and a single TCA-owned custom-food-creation presentation. It does
/// not own services, closures, or legacy shell routing.
@Reducer
public struct WindowFeature {
    @ObservableState
    public struct State: Equatable {
        public let sessionGeneration: UInt64
        public var today: LocalDiaryDate
        public var nutrition: NutritionDetailsFeature.State?
        public var search: SearchScreenFeature.State
        public var diary: DiaryScreenFeature.State
        public var foodCreation: SearchFoodCreationPresentation?

        public init(
            sessionGeneration: UInt64,
            today: LocalDiaryDate,
            nutrition: NutritionDetailsFeature.State? = nil,
            search: SearchScreenFeature.State? = nil,
            diary: DiaryScreenFeature.State? = nil,
            foodCreation: SearchFoodCreationPresentation? = nil
        ) {
            self.sessionGeneration = sessionGeneration
            self.today = today
            self.nutrition = nutrition
            self.search = search ?? SearchScreenFeature.State(
                date: today,
                mealSlot: nil,
                generation: sessionGeneration
            )
            self.diary = diary ?? DiaryScreenFeature.State(
                date: today,
                today: today,
                sessionGeneration: sessionGeneration
            )
            self.foodCreation = foodCreation
        }
    }

    // Not Equatable: SearchScreenFeature.Action is not Equatable, and a hand-written
    // `==` cannot represent it without breaking reflexivity. Tests assert receives
    // through case paths with Equatable delegate payloads, or through predicates.
    public enum Action: Sendable {
        case nutrition(NutritionDetailsFeature.Action)
        case search(SearchScreenFeature.Action)
        case diary(DiaryScreenFeature.Action)
        case openNutrition(selectedDate: LocalDiaryDate, today: LocalDiaryDate)
        case closeNutrition
        case todayChanged(LocalDiaryDate)
        case openSearchMeals(date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64)
        case searchRecentsInvalidated(generation: UInt64)
        case closeFoodCreation(expectedPresentationID: UUID)
        case foodCreationCompleted(expectedPresentationID: UUID)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case sessionExpired(selectedDate: LocalDiaryDate, generation: UInt64, reason: SessionUnavailableReason)
        case addFood(slot: MealSlot, date: LocalDiaryDate, generation: UInt64)
        case selectedFood(
            id: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            generation: UInt64,
            origin: SearchScreenFeature.NavigationOrigin
        )
        case selectedMeal(
            id: String,
            date: LocalDiaryDate,
            mealSlot: MealSlot?,
            quantity: NutritionQuantity,
            generation: UInt64,
            origin: SearchScreenFeature.NavigationOrigin
        )
        case openMeals(date: LocalDiaryDate, mealSlot: MealSlot?, generation: UInt64)
        case openLogEditor(id: String, date: LocalDiaryDate, generation: UInt64)
    }

    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Scope(state: \.search, action: \.search) {
            SearchScreenFeature()
        }
        Scope(state: \.diary, action: \.diary) {
            DiaryScreenFeature()
        }
        Reduce { state, action in
            switch action {
            case let .openNutrition(selectedDate, today):
                state.today = today
                let requestedDate = min(selectedDate, today)

                // Reopening the same date preserves an in-flight or loaded
                // report, including expanded guidance. A different date creates a
                // distinct destination and request identity.
                if let existing = state.nutrition,
                   existing.selectedDate == requestedDate,
                   existing.today == today {
                    return .none
                }

                state.nutrition = NutritionDetailsFeature.State(
                    date: selectedDate,
                    today: today,
                    sessionGeneration: state.sessionGeneration
                )
                return .none

            case .closeNutrition:
                state.nutrition = nil
                return .none

            case let .todayChanged(today):
                state.today = today
                guard state.nutrition != nil else { return .none }
                return .send(.nutrition(.todayChanged(today)))

            case let .nutrition(.delegate(.sessionExpired(selectedDate, generation))):
                // A stale child cannot invalidate a newer session.
                guard generation == state.sessionGeneration else { return .none }
                state.nutrition = nil
                return .send(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .search(.delegate(.selectedFood(id, date, mealSlot, generation, origin))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.selectedFood(
                    id: id,
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation,
                    origin: origin
                )))

            case let .search(.delegate(.selectedMeal(id, date, mealSlot, quantity, generation, origin))):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.selectedMeal(
                    id: id,
                    date: date,
                    mealSlot: mealSlot,
                    quantity: quantity,
                    generation: generation,
                    origin: origin
                )))

            case let .search(.delegate(.createCustomFoodDraft(barcode, date, mealSlot, generation, origin))):
                guard generation == state.sessionGeneration else { return .none }
                // Duplicate open must not overwrite or discard an existing
                // presentation silently.
                guard state.foodCreation == nil else { return .none }
                state.foodCreation = SearchFoodCreationPresentation(
                    id: uuid(),
                    barcode: barcode,
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation,
                    origin: origin
                )
                return .none

            case let .search(.delegate(.sessionExpired(generation))):
                guard generation == state.sessionGeneration else { return .none }
                let selectedDate = state.search.originDate
                state.foodCreation = nil
                return .send(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .diary(.delegate(.sessionExpired(selectedDate, generation))):
                // DiaryScreenFeature already latches and expires its own children;
                // Window only forwards the single session-expired delegate.
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.sessionExpired(
                    selectedDate: selectedDate,
                    generation: generation,
                    reason: .expired
                )))

            case let .diary(.delegate(.addFood(slot, date, generation))):
                // Add Food is the one diary delegate Window routes onward. The
                // child already checks generation/session, but Window repeats the
                // authority check so a stale or expired child can never navigate.
                guard generation == state.sessionGeneration else { return .none }
                guard !state.diary.diary.isSessionExpired else { return .none }
                return .send(.delegate(.addFood(
                    slot: slot,
                    date: date,
                    generation: generation
                )))

            case let .diary(.delegate(.openLogEditor(id, date, generation))):
                // The editor destination is still owned by the legacy shell.
                // Window only forwards it after repeating the same authority
                // checks Add Food uses, so a stale/expired child can never
                // navigate a newer session into an editor.
                guard generation == state.sessionGeneration else { return .none }
                guard !state.diary.diary.isSessionExpired else { return .none }
                return .send(.delegate(.openLogEditor(
                    id: id,
                    date: date,
                    generation: generation
                )))

            case .diary(.delegate(.openMeals(_, _))),
                 .diary(.delegate(.copied(_, _, _, _, _))):
                // Deferred destinations/copy remain owned by the legacy shell;
                // Window does not refresh on them (no duplicate GET).
                return .none

            case let .search(.delegate(.diaryChanged(_, generation))):
                // Diary refresh is owned by the handler that already performed the
                // mutation; forwarding or refreshing here would double work.
                guard generation == state.sessionGeneration else { return .none }
                return .none

            case let .openSearchMeals(date, mealSlot, generation):
                guard generation == state.sessionGeneration else { return .none }
                return .send(.delegate(.openMeals(
                    date: date,
                    mealSlot: mealSlot,
                    generation: generation
                )))

            case let .searchRecentsInvalidated(generation):
                guard generation == state.sessionGeneration else { return .none }
                guard state.search.catalog.scope == .all || state.search.catalog.scope == .history else {
                    return .none
                }
                return .send(.search(.history(.refreshRecents)))

            case let .closeFoodCreation(expectedPresentationID):
                guard state.foodCreation?.id == expectedPresentationID else { return .none }
                state.foodCreation = nil
                return .none

            case let .foodCreationCompleted(expectedPresentationID):
                guard state.foodCreation?.id == expectedPresentationID else { return .none }
                state.foodCreation = nil
                guard state.search.catalog.scope == .all || state.search.catalog.scope == .history else {
                    return .none
                }
                return .send(.search(.history(.refreshRecents)))

            case .nutrition, .search, .diary, .delegate:
                return .none
            }
        }
        .ifLet(\.nutrition, action: \.nutrition) {
            NutritionDetailsFeature()
        }
    }
}
