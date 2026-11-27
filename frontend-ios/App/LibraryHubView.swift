import ComposableArchitecture
import SwiftUI

/// Production Library hub replacement for the retired `LibraryRootView`.
/// One stack owns the hub and its two destinations; both child stores are
/// scoped from the single Window store, with no fresh Store or view model.
public enum LibraryHubDestination: Hashable, Sendable {
    case foods
    case meals

    public var title: String {
        switch self {
        case .foods: return "Foods"
        case .meals: return String(localized: "meals.title")
        }
    }

    public var systemImage: String {
        switch self {
        case .foods: return "books.vertical"
        case .meals: return "fork.knife"
        }
    }
}

public struct LibraryHubView: View {
    @Bindable private var store: StoreOf<WindowFeature>
    private let destinationView: ((WindowDestination) -> AnyView)?

    public init(
        store: StoreOf<WindowFeature>,
        destinationView: ((WindowDestination) -> AnyView)? = nil
    ) {
        self.store = store
        self.destinationView = destinationView
    }

    public var body: some View {
        NavigationStack(path: path) {
            List {
                Section {
                    NavigationLink(value: LibraryRoute.hub(.foods)) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "library.hub.foods"))
                                    .font(.headline)
                                Text("Browse and manage your saved foods.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "books.vertical")
                        }
                    }
                    .accessibilityIdentifier("library.foods")

                    NavigationLink(value: LibraryRoute.hub(.meals)) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "library.hub.meals"))
                                    .font(.headline)
                                Text("Browse and manage your saved meals.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "fork.knife")
                        }
                    }
                    .accessibilityIdentifier("library.meals")
                }
            }
            .navigationTitle(String(localized: "library.title"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
#endif
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .hub(.foods):
                    if let child = store.scope(state: \.library, action: \.library) {
                        LibraryFeatureView(store: child)
                    }
                case .hub(.meals):
                    if let child = store.scope(state: \.meals, action: \.meals) {
                        MealsFlowFeatureView(store: child)
                    }
                case let .global(destination):
                    if let destinationView { destinationView(destination) }
                }
            }
        }
        .task {
            store.send(.ensureLibraryChildren)
        }
    }

    private var path: Binding<[LibraryRoute]> {
        Binding(
            get: {
                store.libraryHubPath.map(LibraryRoute.hub)
                    + (store.selectedTab == .library ? store.destinationStack.map(LibraryRoute.global) : [])
            },
            set: { desired in
                guard store.selectedTab == .library else { return }
                let current = store.libraryHubPath.map(LibraryRoute.hub)
                    + store.destinationStack.map(LibraryRoute.global)
                if current.isEmpty, desired.count == 1, case let .hub(hub) = desired[0] {
                    store.send(.openLibraryHub(hub))
                    return
                }
                guard desired.count < current.count,
                      Array(current.prefix(desired.count)) == desired else { return }
                let hubs = desired.compactMap { route -> LibraryHubDestination? in
                    if case let .hub(hub) = route { return hub }
                    return nil
                }
                let globals = desired.compactMap { route -> WindowDestination? in
                    if case let .global(destination) = route { return destination }
                    return nil
                }
                store.send(.requestPathChange(WindowPathChange(
                    tab: .library, expected: store.destinationStack, desired: globals,
                    expectedHub: store.libraryHubPath, desiredHub: hubs
                )))
            }
        )
    }
}
