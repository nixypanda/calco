// Native Library tab root. The Library is a hub with two destinations:
// My Foods and My Meals. One stack owns the hub and every pushed destination,
// preserving native transitions, back gestures, and route-owned editors.

import SwiftUI

public enum LibraryDestination: Hashable, Sendable {
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

public struct LibraryRootView: View {
    @State private var path = NavigationPath()
    @State private var hasDirtyEditor = false

    private let service: any LibraryServicing
    private let mealsService: any MealsServicing
    private let accountID: String
    private let date: LocalDiaryDate
    private let mealSlot: MealSlot?
    private let today: LocalDiaryDate
    private let submitDrafts: LogSubmissionHandler
    private let onLogged: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void
    private let onClose: (() -> Void)?
    private let currentContextProvider: () -> LibraryLogContext
    private let onCreateWithAI: (() -> Void)?

    public init(
        service: any LibraryServicing,
        mealsService: any MealsServicing,
        accountID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        today: LocalDiaryDate,
        submitDrafts: @escaping LogSubmissionHandler,
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil,
        currentContextProvider: @escaping () -> LibraryLogContext,
        onCreateWithAI: (() -> Void)? = nil
    ) {
        self.service = service
        self.mealsService = mealsService
        self.accountID = accountID
        self.date = date
        self.mealSlot = mealSlot
        self.today = today
        self.submitDrafts = submitDrafts
        self.onLogged = onLogged
        self.onSessionExpired = onSessionExpired
        self.onClose = onClose
        self.currentContextProvider = currentContextProvider
        self.onCreateWithAI = onCreateWithAI
    }

    public var body: some View {
        NavigationStack(path: $path) {
            hubView
                .navigationTitle(String(localized: "library.title"))
#if os(iOS)
                .navigationBarTitleDisplayMode(.large)
#endif
                .navigationDestination(for: LibraryDestination.self) { destination in
                    destinationView(destination)
                }
        }
        .interactiveDismissDisabled(hasDirtyEditor)
    }

    private var hubView: some View {
        List {
            Section {
                NavigationLink(value: LibraryDestination.foods) {
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

                NavigationLink(value: LibraryDestination.meals) {
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
    }

    @ViewBuilder
    private func destinationView(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .foods:
            LibraryView(
                service: service,
                submissionService: HandlerLibraryLogSubmissionService(handler: submitDrafts),
                accountID: accountID,
                today: today,
                initialDate: date,
                initialMealSlot: mealSlot,
                onLogged: onLogged,
                onSessionExpired: onSessionExpired,
                onDirtyChange: { self.hasDirtyEditor = $0 },
                onCreateWithAI: onCreateWithAI,
                currentContextProvider: currentContextProvider,
                navigationPath: $path
            )
            .accessibilityIdentifier("library.foods")
        case .meals:
            // Library manages recipes only. Omitting submission callbacks keeps
            // both list quick-add and detail logging unavailable.
            MealsFlowView(
                date: date,
                mealSlot: mealSlot,
                accountID: accountID,
                service: mealsService,
                onSessionExpired: onSessionExpired,
                onDirtyChange: { self.hasDirtyEditor = $0 },
                navigationPath: $path
            )
            .accessibilityIdentifier("library.meals")
        }
    }
}

public typealias LibrarySection = LibraryDestination
