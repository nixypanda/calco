//
//  LegacySearchRoutingClient.swift
//
//  Typed routing boundary from the migrated TCA search screen back to the
//  window's existing AppShellCoordinator. The client is a pure command value:
//  it creates no transport, session, locator or @StateObject, stores no service
//  objects, and never presents a food-creation flow (that presentation belongs
//  to future TCA Window state). Every live command validates the captured
//  generation and session phase before touching the coordinator, and chooses
//  the destination from the captured origin/context only — never by re-reading
//  `selectedTab`.
//

import ComposableArchitecture
import Foundation

public struct LegacySearchRoutingClient: Sendable {
    public typealias Origin = SearchScreenFeature.NavigationOrigin

    /// Positional (unlabeled) command closures; call sites pass
    /// `(id, date, mealSlot, origin, generation)` and the live implementation
    /// forwards to the coordinator's real public functions with their labels.
    public var openFoodDetail: @MainActor @Sendable (
        _ id: String,
        _ date: LocalDiaryDate,
        _ mealSlot: MealSlot?,
        _ origin: Origin,
        _ generation: UInt64
    ) -> Void

    public var openMealDetail: @MainActor @Sendable (
        _ id: String,
        _ date: LocalDiaryDate,
        _ mealSlot: MealSlot?,
        _ quantity: NutritionQuantity?,
        _ origin: Origin,
        _ generation: UInt64
    ) -> Void

    public var openMeals: @MainActor @Sendable (
        _ date: LocalDiaryDate,
        _ mealSlot: MealSlot?,
        _ generation: UInt64
    ) -> Void

    public init(
        openFoodDetail: @escaping @MainActor @Sendable (
            String, LocalDiaryDate, MealSlot?, Origin, UInt64
        ) -> Void,
        openMealDetail: @escaping @MainActor @Sendable (
            String, LocalDiaryDate, MealSlot?, NutritionQuantity?, Origin, UInt64
        ) -> Void,
        openMeals: @escaping @MainActor @Sendable (
            LocalDiaryDate, MealSlot?, UInt64
        ) -> Void
    ) {
        self.openFoodDetail = openFoodDetail
        self.openMealDetail = openMealDetail
        self.openMeals = openMeals
    }

    /// Fails fast so a feature installed without a real routing seam is caught
    /// at the first delegate action instead of silently dropping a selection.
    public static let unimplemented = Self(
        openFoodDetail: { _, _, _, _, _ in
            fatalError("Unimplemented: LegacySearchRoutingClient.openFoodDetail")
        },
        openMealDetail: { _, _, _, _, _, _ in
            fatalError("Unimplemented: LegacySearchRoutingClient.openMealDetail")
        },
        openMeals: { _, _, _ in
            fatalError("Unimplemented: LegacySearchRoutingClient.openMeals")
        }
    )

    /// Narrow, testable core. Both authority checks run before any route
    /// callback, and the callbacks receive only the captured date/slot/origin.
    /// Tests exercise this with recording closures instead of standing up a
    /// session/auth framework; `.live` supplies the real coordinator-backed
    /// checks and routes.
    static func guarded(
        isCurrentGeneration: @escaping @MainActor (UInt64) -> Bool,
        isSupportedPhase: @escaping @MainActor () -> Bool,
        routeFoodDetail: @escaping @MainActor (
            String, LocalDiaryDate, MealSlot?, Origin
        ) -> Void,
        routeMealDetail: @escaping @MainActor (
            String, LocalDiaryDate, MealSlot?, NutritionQuantity?, Origin
        ) -> Void,
        routeMeals: @escaping @MainActor (LocalDiaryDate, MealSlot?) -> Void
    ) -> Self {
        Self(
            openFoodDetail: { id, date, mealSlot, origin, generation in
                guard isSupportedPhase(), isCurrentGeneration(generation) else { return }
                routeFoodDetail(id, date, mealSlot, origin)
            },
            openMealDetail: { id, date, mealSlot, quantity, origin, generation in
                guard isSupportedPhase(), isCurrentGeneration(generation) else { return }
                routeMealDetail(id, date, mealSlot, quantity, origin)
            },
            openMeals: { date, mealSlot, generation in
                guard isSupportedPhase(), isCurrentGeneration(generation) else { return }
                routeMeals(date, mealSlot)
            }
        )
    }

    /// Binds to the *same* per-window coordinator that owns the legacy feature
    /// graph. Generation validity is delegated to the coordinator's public
    /// `isCurrentSearchGeneration` (which reads its private graph); the phase
    /// check runs first so an unsupported/stale authority cannot route.
    public static func live(coordinator: AppShellCoordinator) -> Self {
        .guarded(
            isCurrentGeneration: { generation in
                coordinator.isCurrentSearchGeneration(generation)
            },
            isSupportedPhase: {
                if case .signedIn = coordinator.session.phase { return true }
                return false
            },
            routeFoodDetail: { id, date, mealSlot, origin in
                switch origin {
                case .diaryPush:
                    // Diary push keeps the existing dirty/busy editor guard.
                    coordinator.openFoodDetail(id, date: date, mealSlot: mealSlot)
                case .searchTab:
                    // Search tab must use the captured context: the legacy
                    // no-context overload re-reads navigation state that will
                    // be stale after the TCA cutover.
                    coordinator.openSearchTabFoodDetail(
                        id,
                        date: date,
                        mealSlot: mealSlot
                    )
                }
            },
            routeMealDetail: { id, date, mealSlot, quantity, _ in
                // Meal detail is a sheet for both origins; use the real
                // openMeals(date:mealSlot:initialMealID:initialPortion:) so its
                // existing feature-sheet/generation guards are preserved.
                coordinator.openMeals(
                    date: date,
                    mealSlot: mealSlot,
                    initialMealID: id,
                    initialPortion: quantity
                )
            },
            routeMeals: { date, mealSlot in
                coordinator.openMeals(date: date, mealSlot: mealSlot)
            }
        )
    }
}

private enum LegacySearchRoutingClientKey: DependencyKey {
    static let liveValue: LegacySearchRoutingClient = .unimplemented
    static let testValue: LegacySearchRoutingClient = .unimplemented
}

extension DependencyValues {
    public var legacySearchRoutingClient: LegacySearchRoutingClient {
        get { self[LegacySearchRoutingClientKey.self] }
        set { self[LegacySearchRoutingClientKey.self] = newValue }
    }
}
