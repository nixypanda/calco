// Native Library tab root. The Library is a hub with two destinations:
// My Foods and My Meals. Each destination owns its own navigation stack and
// returns to this hub through the single back control provided here.

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
    @State private var destination: LibraryDestination?
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
        Group {
            if let destination {
                // Each destination owns its NavigationStack (My Foods /
                // My Meals list -> detail -> editor). The single Back control
                // is wired INSIDE that stack on the list screen and calls this
                // root callback. A toolbar applied here would sit outside the
                // active stack and never render — the original gap.
                destinationView(destination)
            } else {
                // Only the hub is wrapped. It gets its own "Library" large
                // title; the child stacks stay independent (no nested stacks).
                NavigationStack {
                    hubView
                        .navigationTitle(String(localized: "library.title"))
#if os(iOS)
                        .navigationBarTitleDisplayMode(.large)
#endif
                }
            }
        }
    }

    /// Shared root callback for both destinations' native Back control. A
    /// dirty/busy editor keeps its own Cancel/Save, so Back is gated here and
    /// at the toolbar item; there is no second Close/Done control.
    private func returnToHub() {
        guard !hasDirtyEditor else { return }
        destination = nil
        hasDirtyEditor = false
    }

    private var hubView: some View {
        List {
            Section {
                Button {
                    destination = .foods
                    hasDirtyEditor = false
                } label: {
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

                Button {
                    destination = .meals
                    hasDirtyEditor = false
                } label: {
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
                onClose: { self.destination = nil },
                onBack: { self.returnToHub() },
                backDisabled: hasDirtyEditor,
                onDirtyChange: { self.hasDirtyEditor = $0 },
                onCreateWithAI: onCreateWithAI,
                currentContextProvider: currentContextProvider
            )
            .accessibilityIdentifier("library.foods")
        case .meals:
            MealsFlowView(
                date: date,
                mealSlot: mealSlot,
                accountID: accountID,
                service: mealsService,
                onSubmitDrafts: nil,
                onSessionExpired: onSessionExpired,
                onLogged: onLogged,
                onClose: { self.destination = nil },
                onBack: { self.returnToHub() },
                backDisabled: hasDirtyEditor,
                currentContextProvider: currentContextProvider,
                onDirtyChange: { self.hasDirtyEditor = $0 }
            )
            .accessibilityIdentifier("library.meals")
        }
    }
}

public typealias LibrarySection = LibraryDestination
