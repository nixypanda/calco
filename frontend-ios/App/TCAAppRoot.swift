import ComposableArchitecture
import SwiftUI

/// Production app root. One `NativeWindowRuntime` owns one `Store<AppFeature>`
/// for the window lifetime; all foreground/day-change authority lives here and
/// the signed-in branch is the Store-driven `StoreWindowShell`.
struct TCAAppRoot: View {
    let sessionAuthority: CalCoSessionAuthority

    @StateObject private var runtime: NativeWindowRuntime
    @Environment(\.scenePhase) private var scenePhase

    init(sessionAuthority: CalCoSessionAuthority) {
        self.sessionAuthority = sessionAuthority
        _runtime = StateObject(
            wrappedValue: NativeWindowRuntime(sessionAuthority: sessionAuthority)
        )
    }

    var body: some View {
        let store = runtime.store

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
                StoreWindowShell(store: store)
            }
        }
        .task {
            await store.send(.task).finish()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.send(.foreground)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            store.send(.calendarDayChanged)
        }
    }
}
