import ComposableArchitecture
import SwiftUI

/// Transitional root for the TCA authentication slice.
///
/// The signed-in branch still bridges to the existing `AppShell` and its legacy
/// view models. This is not a claim that the whole app has been migrated.
struct TCAAppRoot: View {
    let sessionAuthority: CalCoSessionAuthority
    /// Single authority for transitional Diary ownership. Test builds opt into
    /// the store-backed screen only with the established QA environment flag;
    /// Debug/Release have no activation path and stay on the legacy screen.
    let diaryScreenOwnership: DiaryScreenOwnership

    @StateObject private var runtime: NativeWindowRuntime

    init(sessionAuthority: CalCoSessionAuthority) {
        self.sessionAuthority = sessionAuthority
        let ownership: DiaryScreenOwnership = {
            #if CALCO_TEST
            guard ProcessInfo.processInfo.environment["CALCO_NATIVE_DIARY_QA"] == "1" else {
                return .legacy
            }
            return .storeBackedScreen
            #else
            return .legacy
            #endif
        }()
        self.diaryScreenOwnership = ownership
        _runtime = StateObject(
            wrappedValue: NativeWindowRuntime(
                sessionAuthority: sessionAuthority,
                diaryScreenOwnership: ownership
            )
        )
    }

    var body: some View {
        let store = runtime.store

        let nutritionBridge: NativeNutritionBridge? = store.scope(
            state: \.window,
            action: \.window
        ).map { windowStore in
            NativeNutritionBridge(
                store: windowStore.scope(
                    state: \.nutrition,
                    action: \.nutrition
                ),
                onOpen: { selectedDate, today in
                    windowStore.send(.openNutrition(
                        selectedDate: selectedDate,
                        today: today
                    ))
                },
                onDismiss: {
                    windowStore.send(.closeNutrition)
                }
            )
        }

        let searchBridge: NativeSearchBridge? = store.scope(
            state: \.window,
            action: \.window
        ).map { windowStore in
            NativeSearchBridge(windowStore: windowStore)
        }

        // QA-only native Diary host. `diaryScreenOwnership` is derived from the
        // same `#if CALCO_TEST` + QA env authority used to initialize the
        // runtime, so rendering and mutation delivery cannot disagree. The store
        // is scoped from the persistent AppFeature -> Window state (normal
        // generation/lifetime); no independent preview store, client, service,
        // or view model is made.
        let diaryBridge: NativeDiaryBridge? = {
            guard diaryScreenOwnership == .storeBackedScreen else { return nil }
            return store.scope(state: \.window, action: \.window).map { windowStore in
                NativeDiaryBridge(
                    store: windowStore.scope(state: \.diary, action: \.diary),
                    onOpenSettings: {
                        runtime.coordinator.showSettings()
                        runtime.coordinator.requestTabSwitch(to: .settings)
                    },
                    onOpenNutrition: {
                        let diary = windowStore.diary
                        windowStore.send(
                            .openNutrition(
                                selectedDate: diary.selectedDate,
                                today: windowStore.today
                            )
                        )
                    }
                )
            }
        }()

        Group {
            switch store.phase {
            case .restoring:
                SessionStatusView(status: .restoring)

            case .signedOut, .signingIn:
                if let loginStore = store.scope(state: \.login, action: \.login) {
                    LoginFeatureView(store: loginStore)
                } else {
                    SessionStatusView(status: .restoring)
                }

            case .unsupportedAccount:
                AdminUnsupportedView {
                    store.send(.dismissUnsupportedAccount)
                }

            case .restoreFailed(let failure):
                AuthRestoreFailureView(
                    failure: failure,
                    onRetry: { store.send(.retryRestore) }
                )

            case .signedIn:
                // Transitional bridge: the signed-in experience still uses the
                // legacy shell while feature migration continues. Nutrition is
                // owned by WindowFeature and projected through the bridge.
                AppShell(
                    coordinator: runtime.coordinator,
                    nutritionBridge: nutritionBridge,
                    searchBridge: searchBridge!,
                    diaryBridge: diaryBridge
                )
            }
        }
        .task {
            await store.send(.task).finish()
        }
    }
}
