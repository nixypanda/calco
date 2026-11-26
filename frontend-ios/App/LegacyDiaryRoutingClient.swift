//
//  LegacyDiaryRoutingClient.swift
//
//  Typed routing boundary from the migrated TCA Diary screen back to the
//  window's existing AppShellCoordinator. It is a pure command value: it creates
//  no transport, session, locator or @StateObject, stores no service objects,
//  and never touches a legacy DiaryViewModel. Every live command validates the
//  captured generation, the ready graph and the session phase before touching
//  the coordinator, then forwards to the existing `startLogging` path or the
//  log-editor open path (both retain the dirty/busy editor guard).
//
//  The live binding captures the coordinator weakly: the runtime installs this
//  client as a dependency, so a strong capture would keep the whole window
//  graph alive through the store's dependency bag.
//

import ComposableArchitecture
import Foundation

public struct LegacyDiaryRoutingClient: Sendable {
    /// Positional command closure; call sites pass `(id, date, generation)`.
    /// Declared before `startLogging` so existing `.init { slot, date, gen }`
    /// trailing-closure call sites still bind to `startLogging`.
    public var openLogEditor: @MainActor @Sendable (
        _ id: String,
        _ date: LocalDiaryDate,
        _ generation: UInt64
    ) -> Void

    /// Positional command closure; call sites pass `(slot, date, generation)`.
    public var startLogging: @MainActor @Sendable (
        _ slot: MealSlot,
        _ date: LocalDiaryDate,
        _ generation: UInt64
    ) -> Void

    public init(
        openLogEditor: @escaping @MainActor @Sendable (
            String, LocalDiaryDate, UInt64
        ) -> Void = { _, _, _ in
            fatalError("Unimplemented: LegacyDiaryRoutingClient.openLogEditor")
        },
        startLogging: @escaping @MainActor @Sendable (
            MealSlot, LocalDiaryDate, UInt64
        ) -> Void
    ) {
        self.openLogEditor = openLogEditor
        self.startLogging = startLogging
    }

    /// Fail closed at the first accidental delegate action. The real runtime
    /// always installs `.live`, so no production event should reach this value.
    public static let unimplemented = Self(
        openLogEditor: { _, _, _ in
            fatalError("Unimplemented: LegacyDiaryRoutingClient.openLogEditor")
        },
        startLogging: { _, _, _ in
            fatalError("Unimplemented: LegacyDiaryRoutingClient.startLogging")
        }
    )

    /// Narrow, testable core. Authority checks run before the route callback,
    /// which receives only the captured slot/date — never live navigation state
    /// or a legacy view model.
    static func guarded(
        isCurrentGeneration: @escaping @MainActor (UInt64) -> Bool,
        isSupportedPhase: @escaping @MainActor () -> Bool,
        routeStartLogging: @escaping @MainActor (MealSlot, LocalDiaryDate) -> Void
    ) -> Self {
        Self { slot, date, generation in
            guard isSupportedPhase(), isCurrentGeneration(generation) else { return }
            routeStartLogging(slot, date)
        }
    }

    /// Binds to the same per-window coordinator that owns the legacy feature
    /// graph. Generation validity uses the coordinator's public diary guard,
    /// which checks both the session authority and the private ready graph.
    /// Both routes capture the coordinator weakly and validate the captured
    /// generation, the ready graph and the signed-in phase before touching it.
    public static func live(coordinator: AppShellCoordinator) -> Self {
        Self(
            openLogEditor: { [weak coordinator] id, date, generation in
                guard let coordinator,
                      case .signedIn = coordinator.session.phase,
                      coordinator.isCurrentDiaryGeneration(generation) else { return }
                // The coordinator applies the store-backed fresh-row lookup /
                // legacy VM lookup and retains the existing dirty/busy guard.
                coordinator.openLogEditor(logID: id, date: date, generation: generation)
            },
            startLogging: { [weak coordinator] slot, date, generation in
                guard let coordinator,
                      case .signedIn = coordinator.session.phase,
                      coordinator.isCurrentDiaryGeneration(generation) else { return }
                // `startLogging` retains the existing discard/busy editor guard
                // and updates the legacy navigation state + search context.
                coordinator.startLogging(slot: slot, date: date)
            }
        )
    }
}

private enum LegacyDiaryRoutingClientKey: DependencyKey {
    static let liveValue: LegacyDiaryRoutingClient = .unimplemented
    static let testValue: LegacyDiaryRoutingClient = .unimplemented
}

extension DependencyValues {
    public var legacyDiaryRoutingClient: LegacyDiaryRoutingClient {
        get { self[LegacyDiaryRoutingClientKey.self] }
        set { self[LegacyDiaryRoutingClientKey.self] = newValue }
    }
}
