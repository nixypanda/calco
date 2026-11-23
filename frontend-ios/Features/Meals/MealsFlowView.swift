// Standalone Meals flow. The shared app shell can present this as a sheet or
// full-screen destination, or embed `MealsListView`/`MealDetailView` directly in
// its own NavigationStack.

import SwiftUI

private enum MealRoute: Hashable {
    /// The diary target is captured when the detail flow opens and kept for the
    /// route's whole life; a later diary change cannot retarget an open draft.
    case detail(mealID: String, context: LibraryLogContext)
}

private enum MealEditorTarget: Identifiable, Hashable {
    case create
    case edit(id: String, name: String)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let id, _): return "edit-\(id)"
        }
    }

    var mode: MealEditorMode {
        switch self {
        case .create: return .create
        case .edit(let id, _): return .edit(id: id)
        }
    }
}

public struct MealsFlowView: View {
    @StateObject private var listViewModel: MealsListViewModel
    @State private var path: [MealRoute]
    @State private var editorTarget: MealEditorTarget?
    @State private var editingTarget: MealEditorTarget?
    @State private var detailRefreshToken = 0
    @State private var hasDirtyEditor = false

    private let date: LocalDiaryDate
    private let mealSlot: MealSlot?
    private let initialPortion: NutritionQuantity?
    private let accountID: String
    private let service: MealsServicing
    private let onSubmitDrafts: LogSubmissionHandler?
    private let onSessionExpired: () -> Void
    private let onLogged: ((LocalDiaryDate, MealSlot?) -> Void)?
    private let onClose: (() -> Void)?
    /// One native Back-to-hub control rendered on the list screen of this
    /// view's own NavigationStack (nil when embedded without a hub owner).
    private let onBack: (() -> Void)?
    private let backDisabled: Bool
    private let currentContextProvider: () -> LibraryLogContext
    private let onDirtyChange: ((Bool) -> Void)?

    public init(
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        accountID: String = "",
        service: MealsServicing,
        onSubmitDrafts: LogSubmissionHandler? = nil,
        onSessionExpired: @escaping () -> Void = {},
        onLogged: ((LocalDiaryDate, MealSlot?) -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        backDisabled: Bool = false,
        initialMealID: String? = nil,
        initialPortion: NutritionQuantity? = nil,
        currentContextProvider: (() -> LibraryLogContext)? = nil,
        onDirtyChange: ((Bool) -> Void)? = nil
    ) {
        self.date = date
        self.mealSlot = mealSlot
        self.initialPortion = initialPortion
        self.accountID = accountID
        self.service = service
        self.onSubmitDrafts = onSubmitDrafts
        self.onSessionExpired = onSessionExpired
        self.onLogged = onLogged
        self.onClose = onClose
        self.onBack = onBack
        self.backDisabled = backDisabled
        let fallbackContext = LibraryLogContext(date: date, mealSlot: mealSlot)
        let resolvedProvider = currentContextProvider ?? { fallbackContext }
        self.currentContextProvider = resolvedProvider
        self.onDirtyChange = onDirtyChange
        _listViewModel = StateObject(
            wrappedValue: MealsListViewModel(
                date: date,
                mealSlot: mealSlot,
                service: service,
                onSubmitDrafts: onSubmitDrafts,
                onSessionExpired: onSessionExpired,
                onLogged: onLogged,
                currentContextProvider: resolvedProvider
            )
        )
        let initialContext = resolvedProvider()
        _path = State(
            initialValue: initialMealID.map {
                [.detail(mealID: $0, context: initialContext)]
            } ?? []
        )
    }

    private func captureContext() -> LibraryLogContext {
        currentContextProvider()
    }

    private var closeButton: some View {
        Button {
            onClose?()
        } label: {
            Label(String(localized: "meals.common.close"), systemImage: "xmark")
        }
        .accessibilityIdentifier("meals.close")
    }

    private var backPlacement: ToolbarItemPlacement {
#if os(iOS)
        .navigationBarLeading
#else
        .navigation
#endif
    }

    public var body: some View {
        NavigationStack(path: $path) {
            MealsListView(
                viewModel: listViewModel,
                onOpenMeal: { meal in
                    path.append(.detail(mealID: meal.id, context: captureContext()))
                },
                onCreateMeal: {
                    editorTarget = .create
                }
            )
            // The Back control belongs to this NavigationStack's list root.
            // `path.isEmpty` matches LibraryView: once a detail is pushed the
            // system back chevron is the only Back, so no duplicate remains.
            .toolbar {
                if let onBack, path.isEmpty {
                    ToolbarItem(placement: backPlacement) {
                        Button {
                            onBack()
                        } label: {
                            Label(
                                String(localized: "library.common.back"),
                                systemImage: "chevron.left"
                            )
                        }
                        .disabled(backDisabled)
                        .accessibilityIdentifier("library.back")
                    }
                }
            }
            .navigationDestination(for: MealRoute.self) { route in
                switch route {
                case .detail(let mealID, let context):
                    MealDetailScreen(
                        mealID: mealID,
                        date: context.date,
                        mealSlot: context.mealSlot,
                        initialPortion: initialPortion,
                        service: service,
                        onSubmitDrafts: onSubmitDrafts,
                        onSessionExpired: onSessionExpired,
                        onLogged: onLogged,
                        refreshToken: detailRefreshToken,
                        onEdit: { meal in
                            editingTarget = .edit(id: meal.id, name: meal.name)
                        },
                        onDeleted: {
                            if !path.isEmpty { path.removeLast() }
                            Task { await listViewModel.refresh() }
                        }
                    )

                }
            }
            .navigationDestination(item: $editingTarget) { target in
                editorScreen(for: target)
                    .navigationBarBackButtonHidden()
            }
        }
        .sheet(item: $editorTarget) { target in
            NavigationStack {
                editorScreen(for: target)
            }
        }
    }

    private func editorScreen(for target: MealEditorTarget) -> some View {
        MealEditorScreen(
            target: target,
            accountID: accountID,
            service: service,
            onSessionExpired: onSessionExpired,
            onCancel: {
                editorTarget = nil
                editingTarget = nil
                onDirtyChange?(false)
            },
            onSaved: { meal in
                let wasEditing = target.mode.mealID != nil
                onDirtyChange?(false)
                editorTarget = nil
                editingTarget = nil
                Task { await listViewModel.refresh() }
                if wasEditing {
                    detailRefreshToken += 1
                } else if !path.contains(where: { route in
                    if case .detail(let id, _) = route { return id == meal.id }
                    return false
                }) {
                    path.append(
                        .detail(mealID: meal.id, context: captureContext())
                    )
                }
            },
            onDirtyChange: { dirty in
                onDirtyChange?(dirty)
            }
        )
    }
}

private struct MealDetailScreen: View {
    @StateObject private var viewModel: MealDetailViewModel
    private let refreshToken: Int
    private let onEdit: (Meal) -> Void

    init(
        mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        initialPortion: NutritionQuantity?,
        service: MealsServicing,
        onSubmitDrafts: LogSubmissionHandler?,
        onSessionExpired: @escaping () -> Void,
        onLogged: ((LocalDiaryDate, MealSlot?) -> Void)?,
        refreshToken: Int,
        onEdit: @escaping (Meal) -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.refreshToken = refreshToken
        self.onEdit = onEdit
        _viewModel = StateObject(
            wrappedValue: MealDetailViewModel(
                mealID: mealID,
                date: date,
                mealSlot: mealSlot,
                initialPortion: initialPortion,
                service: service,
                onSubmitDrafts: onSubmitDrafts,
                onSessionExpired: onSessionExpired,
                onDeleted: onDeleted,
                onLogged: onLogged
            )
        )
    }

    var body: some View {
        MealDetailView(viewModel: viewModel, onEdit: onEdit)
            .onChange(of: refreshToken) { _, _ in
                Task { await viewModel.load() }
            }
    }
}

private struct MealEditorScreen: View {
    @StateObject private var viewModel: MealEditorViewModel
    private let onCancel: () -> Void
    private let onDirtyChange: ((Bool) -> Void)?

    init(
        target: MealEditorTarget,
        accountID: String,
        service: MealsServicing,
        onSessionExpired: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (Meal) -> Void,
        onDirtyChange: ((Bool) -> Void)? = nil
    ) {
        self.onCancel = onCancel
        self.onDirtyChange = onDirtyChange
        _viewModel = StateObject(
            wrappedValue: MealEditorViewModel(
                mode: target.mode,
                accountID: accountID,
                service: service,
                onSessionExpired: onSessionExpired,
                onSaved: onSaved
            )
        )
    }

    var body: some View {
        MealEditorView(viewModel: viewModel, onCancel: onCancel, onDirtyChange: onDirtyChange)
    }
}
