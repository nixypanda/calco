// Standalone Meals flow. The shared app shell can present this as a sheet or
// full-screen destination, or embed `MealsListView`/`MealDetailView` directly in
// its own NavigationStack.

import SwiftUI

private enum MealRoute: Hashable {
    /// The diary target is captured when the detail flow opens and kept for the
    /// route's whole life; a later diary change cannot retarget an open draft.
    case detail(mealID: String, context: LibraryLogContext)
    case editor(MealEditorTarget)
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
    @State private var localPath: NavigationPath
    @Binding private var sharedPath: NavigationPath
    private let usesSharedPath: Bool
    // The shared path includes the hub; standalone flows start at depth zero.
    @State private var rootPathCount: Int
    @State private var detailRefreshToken = 0
    @State private var hasDirtyEditor = false

    private var path: NavigationPath {
        get { usesSharedPath ? sharedPath : localPath }
        nonmutating set {
            if usesSharedPath { sharedPath = newValue }
            else { localPath = newValue }
        }
    }

    private let date: LocalDiaryDate
    private let mealSlot: MealSlot?
    private let initialPortion: NutritionQuantity?
    private let accountID: String
    private let service: MealsServicing
    private let onSubmitDrafts: LogSubmissionHandler?
    private let onSessionExpired: () -> Void
    private let onLogged: ((LocalDiaryDate, MealSlot?) -> Void)?
    private let onClose: (() -> Void)?
    /// Legacy standalone back action. Shared-path destinations use the system
    /// Back button instead, never an additional toolbar action.
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
        onDirtyChange: ((Bool) -> Void)? = nil,
        navigationPath: Binding<NavigationPath>? = nil
    ) {
        self.date = date
        _sharedPath = navigationPath ?? .constant(NavigationPath())
        usesSharedPath = navigationPath != nil
        _rootPathCount = State(initialValue: navigationPath == nil ? 0 : 1)
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
        _localPath = State(initialValue: NavigationPath(initialMealID.map {
            [MealRoute.detail(mealID: $0, context: initialContext)]
        } ?? []))
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
        Group {
            if usesSharedPath {
                navigationContent
            } else {
                NavigationStack(path: $localPath) {
                    navigationContent
                }
            }
        }
    }

    private var navigationContent: some View {
            MealsListView(
                viewModel: listViewModel,
                onOpenMeal: { meal in
                    path.append(MealRoute.detail(mealID: meal.id, context: captureContext()))
                },
                onCreateMeal: {
                    path.append(MealRoute.editor(.create))
                },
                showsAddButton: path.count == rootPathCount
            )
            // An explicit Back is only for legacy standalone hosting. The hub
            // and all pushed detail screens keep the system back chevron.
            .toolbar {
                if let onBack, path.count == rootPathCount, !usesSharedPath {
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
                            path.append(MealRoute.editor(.edit(id: meal.id, name: meal.name)))
                        },
                        onDeleted: {
                            if path.count > rootPathCount { path.removeLast() }
                            Task { await listViewModel.refresh() }
                        }
                    )
                case .editor(let target):
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
                if path.count > rootPathCount { path.removeLast() }
                onDirtyChange?(false)
            },
            onSaved: { meal in
                let wasEditing = target.mode.mealID != nil
                onDirtyChange?(false)
                var nextPath = path
                if nextPath.count > rootPathCount { nextPath.removeLast() }
                Task { await listViewModel.refresh() }
                if wasEditing {
                    detailRefreshToken += 1
                } else {
                    nextPath.append(
                        MealRoute.detail(mealID: meal.id, context: captureContext())
                    )
                }
                path = nextPath
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
