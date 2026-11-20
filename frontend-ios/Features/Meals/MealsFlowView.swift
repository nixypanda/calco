// Standalone Meals flow. The shared app shell can present this as a sheet or
// full-screen destination, or embed `MealsListView`/`MealDetailView` directly in
// its own NavigationStack.

import SwiftUI

private enum MealRoute: Hashable {
    case detail(mealID: String)
}

private enum MealEditorTarget: Identifiable {
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
    @State private var detailRefreshToken = 0

    private let date: LocalDiaryDate
    private let mealSlot: MealSlot?
    private let initialPortion: NutritionQuantity?
    private let accountID: String
    private let service: MealsServicing
    private let onSubmitDrafts: LogSubmissionHandler?
    private let onSessionExpired: () -> Void
    private let onLogged: ((LocalDiaryDate, MealSlot?) -> Void)?
    private let onClose: (() -> Void)?

    public init(
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        accountID: String = "",
        service: MealsServicing,
        onSubmitDrafts: LogSubmissionHandler? = nil,
        onSessionExpired: @escaping () -> Void = {},
        onLogged: ((LocalDiaryDate, MealSlot?) -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        initialMealID: String? = nil,
        initialPortion: NutritionQuantity? = nil
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
        _listViewModel = StateObject(
            wrappedValue: MealsListViewModel(
                date: date,
                mealSlot: mealSlot,
                service: service,
                onSubmitDrafts: onSubmitDrafts,
                onSessionExpired: onSessionExpired,
                onLogged: onLogged
            )
        )
        _path = State(
            initialValue: initialMealID.map { [.detail(mealID: $0)] } ?? []
        )
    }

    private var closeButton: some View {
        Button {
            onClose?()
        } label: {
            Label(String(localized: "meals.common.close"), systemImage: "xmark")
        }
        .accessibilityIdentifier("meals.close")
    }

    public var body: some View {
        NavigationStack(path: $path) {
            MealsListView(
                viewModel: listViewModel,
                onOpenMeal: { meal in
                    path.append(.detail(mealID: meal.id))
                },
                onCreateMeal: {
                    editorTarget = .create
                }
            )
            .toolbar {
                if onClose != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        closeButton
                    }
                }
            }
            .navigationDestination(for: MealRoute.self) { route in
                switch route {
                case .detail(let mealID):
                    MealDetailScreen(
                        mealID: mealID,
                        date: date,
                        mealSlot: mealSlot,
                        initialPortion: initialPortion,
                        service: service,
                        onSubmitDrafts: onSubmitDrafts,
                        onSessionExpired: onSessionExpired,
                        onLogged: onLogged,
                        refreshToken: detailRefreshToken,
                        onEdit: { meal in
                            editorTarget = .edit(id: meal.id, name: meal.name)
                        },
                        onDeleted: {
                            if !path.isEmpty { path.removeLast() }
                            Task { await listViewModel.refresh() }
                        }
                    )
                    .toolbar {
                        if onClose != nil {
                            ToolbarItem(placement: .cancellationAction) {
                                closeButton
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            NavigationStack {
                MealEditorScreen(
                    target: target,
                    accountID: accountID,
                    service: service,
                    onSessionExpired: onSessionExpired,
                    onCancel: {
                        editorTarget = nil
                    },
                    onSaved: { meal in
                        let wasEditing = target.mode.mealID != nil
                        editorTarget = nil
                        Task { await listViewModel.refresh() }
                        if wasEditing {
                            detailRefreshToken += 1
                        } else if !path.contains(.detail(mealID: meal.id)) {
                            path.append(.detail(mealID: meal.id))
                        }
                    }
                )
            }
        }
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

    init(
        target: MealEditorTarget,
        accountID: String,
        service: MealsServicing,
        onSessionExpired: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSaved: @escaping (Meal) -> Void
    ) {
        self.onCancel = onCancel
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
        MealEditorView(viewModel: viewModel, onCancel: onCancel)
    }
}
