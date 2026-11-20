// Self-contained Library navigation: list, detail, create/edit, one-off log.

import SwiftUI

public struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @State private var path: [LibraryRoute] = []
    @State private var hasDirtyEditor = false
    @State private var initialRouteToken: UUID?

    private let service: any LibraryServicing
    private let submissionService: any LibraryLogSubmitting
    private let accountID: String
    private let baseURL: URL?
    private let initialDate: LocalDiaryDate
    private let initialMealSlot: MealSlot?
    private let today: LocalDiaryDate
    private let onLogged: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void
    private let onClose: (() -> Void)?
    private let initialAssistantDraft: AssistantReviewedDraft?
    private let initialBarcode: String?

    @MainActor
    public init(
        service: any LibraryServicing,
        submissionService: any LibraryLogSubmitting = UnavailableLibraryLogSubmissionService(),
        accountID: String,
        today: LocalDiaryDate,
        initialDate: LocalDiaryDate,
        initialMealSlot: MealSlot? = nil,
        baseURL: URL? = nil,
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil,
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil
    ) {
        self.service = service
        self.submissionService = submissionService
        self.accountID = accountID
        self.today = today
        self.initialDate = min(initialDate, today)
        self.initialMealSlot = initialMealSlot
        self.baseURL = baseURL
        self.onLogged = onLogged
        self.onSessionExpired = onSessionExpired
        self.onClose = onClose
        self.initialAssistantDraft = assistantDraft
        self.initialBarcode = initialBarcode
        let initialRoute: [LibraryRoute]
        let initialToken: UUID?
        switch assistantDraft?.purpose {
        case .customFood:
            let token = UUID()
            initialRoute = [.create(token: token)]
            initialToken = token
        case .adHocLog:
            let token = UUID()
            initialRoute = [.adHoc(token: token)]
            initialToken = token
        case nil:
            if initialBarcode == nil {
                initialRoute = []
                initialToken = nil
            } else {
                let token = UUID()
                initialRoute = [.create(token: token)]
                initialToken = token
            }
        }
        _path = State(initialValue: initialRoute)
        _initialRouteToken = State(initialValue: initialToken)
        _viewModel = StateObject(
            wrappedValue: LibraryViewModel(
                service: service,
                accountID: accountID,
                onSessionExpired: onSessionExpired
            )
        )
    }

    public var body: some View {
        NavigationStack(path: $path) {
            listView
                .navigationTitle(Text(String(localized: "library.title")))
#if os(iOS)
                .navigationBarTitleDisplayMode(.large)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if path.isEmpty, let onClose {
                            Button(String(localized: "library.common.done")) {
                                onClose()
                            }
                            .accessibilityIdentifier("library.close")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
#if os(iOS)
                        Menu {
                            Button {
                                path.append(.create(token: UUID()))
                            } label: {
                                Label(
                                    String(localized: "library.add.custom"),
                                    systemImage: "plus.circle"
                                )
                            }
                            .accessibilityIdentifier("library.add.custom")

                            Button {
                                path.append(.adHoc(token: UUID()))
                            } label: {
                                Label(
                                    String(localized: "library.add.adhoc"),
                                    systemImage: "fork.knife"
                                )
                            }
                            .accessibilityIdentifier("library.add.adhoc")
                        } label: {
                            Label(
                                String(localized: "library.add"),
                                systemImage: "plus"
                            )
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .fixedSize()
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("library.add")
#else
                        Menu {
                            Button {
                                path.append(.create(token: UUID()))
                            } label: {
                                Label(
                                    String(localized: "library.add.custom"),
                                    systemImage: "plus.circle"
                                )
                            }
                            .accessibilityIdentifier("library.add.custom")

                            Button {
                                path.append(.adHoc(token: UUID()))
                            } label: {
                                Label(
                                    String(localized: "library.add.adhoc"),
                                    systemImage: "fork.knife"
                                )
                            }
                            .accessibilityIdentifier("library.add.adhoc")
                        } label: {
                            Label(
                                String(localized: "library.add"),
                                systemImage: "plus"
                            )
                        }
                        .accessibilityIdentifier("library.add")
#endif
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .interactiveDismissDisabled(hasDirtyEditor)
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty {
                hasDirtyEditor = false
                Task { await viewModel.refresh() }
            }
        }
    }

    @ViewBuilder
    private var listView: some View {
        List {
            if let refreshError = viewModel.refreshError {
                Section {
                    Text(refreshError)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch viewModel.state {
            case .loading where viewModel.foods.isEmpty:
                Section {
                    ProgressView(String(localized: "library.loading"))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("library.loading")
                }
            case .failed(let message) where viewModel.foods.isEmpty:
                Section {
                    VStack(spacing: 12) {
                        Text(message)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "foodDetail.retry")) {
                            Task { await viewModel.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("foodDetail.retry")
                    }
                    .frame(maxWidth: .infinity)
                }
            default:
                if viewModel.foods.isEmpty {
                    Section {
                        ContentUnavailableView(
                            String(localized: "library.empty.title"),
                            systemImage: "books.vertical",
                            description: Text(String(localized: "library.empty.message"))
                        )
                        .accessibilityIdentifier("library.empty")
                    }
                } else if viewModel.filteredFoods.isEmpty {
                    Section {
                        ContentUnavailableView.search(
                            text: viewModel.searchText
                        )
                        .accessibilityIdentifier("library.search.empty")
                    }
                } else {
                    Section {
                        ForEach(viewModel.filteredFoods) { food in
                            Button {
                                path.append(
                                    .detail(foodID: food.id, token: UUID())
                                )
                            } label: {
                                HStack(spacing: 8) {
                                    LibraryFoodRow(food: food)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.row.\(food.id)")
                        }
                    }
                }
            }
        }
#if os(macOS)
        .listStyle(.inset)
#else
        .listStyle(.insetGrouped)
#endif
        .searchable(
            text: $viewModel.searchText,
            prompt: Text(String(localized: "library.search.placeholder"))
        )
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            if case .loading = viewModel.state, viewModel.foods.isEmpty {
                await viewModel.load()
            }
        }
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        Group {
            switch route {
            case .detail(let foodID, _):
                CustomFoodDetailRouteView(
                    foodID: foodID,
                    service: service,
                    onEdit: {
                        path.append(.edit(foodID: $0, token: UUID()))
                    },
                    onDeleted: { id in
                        viewModel.removeFood(id: id)
                        path.removeAll()
                    },
                    onSessionExpired: onSessionExpired
                )
            case .create(let token):
                let isInitialRoute = token == initialRouteToken
                CustomFoodEditorRouteView(
                    mode: .create,
                    service: service,
                    accountID: accountID,
                    onSaved: { _ in
                        path.removeAll()
                    },
                    onSessionExpired: onSessionExpired,
                    assistantDraft: isInitialRoute
                        && initialAssistantDraft?.purpose == .customFood
                        ? initialAssistantDraft
                        : nil,
                    initialBarcode: isInitialRoute ? initialBarcode : nil,
                    onDirtyChange: { hasDirtyEditor = $0 }
                )
            case .edit(let foodID, _):
                CustomFoodEditorRouteView(
                    mode: .edit(id: foodID),
                    service: service,
                    accountID: accountID,
                    onSaved: { _ in
                        path.removeAll()
                    },
                    onSessionExpired: onSessionExpired,
                    assistantDraft: nil,
                    initialBarcode: nil,
                    onDirtyChange: { hasDirtyEditor = $0 }
                )
            case .adHoc(let token):
                AdHocRouteView(
                    service: service,
                    submissionService: submissionService,
                    accountID: accountID,
                    initialDate: initialDate,
                    today: today,
                    initialMealSlot: initialMealSlot,
                    baseURL: baseURL,
                    onLogged: onLogged,
                    onSessionExpired: onSessionExpired,
                    assistantDraft: token == initialRouteToken
                        && initialAssistantDraft?.purpose == .adHocLog
                        ? initialAssistantDraft
                        : nil,
                    onDirtyChange: { hasDirtyEditor = $0 }
                )
            }
        }
        .id(LibraryRouteIdentity(accountID: accountID, route: route))
    }
}

private enum LibraryRoute: Hashable {
    case detail(foodID: String, token: UUID)
    case create(token: UUID)
    case edit(foodID: String, token: UUID)
    case adHoc(token: UUID)
}

private struct LibraryRouteIdentity: Hashable {
    let accountID: String
    let route: LibraryRoute
}

// MARK: - Route-owned view models

/// Owns the create/edit view model for one navigation route. `StateObject`
/// receives a lazy autoclosure, so focusing a text field or re-evaluating the
/// parent body cannot construct a replacement editor or repeat its nutrient
/// load. A new route/account changes the surrounding identity and gets a fresh
/// model.
private struct CustomFoodEditorRouteView: View {
    @StateObject private var viewModel: CustomFoodEditorViewModel
    private let onDirtyChange: (Bool) -> Void

    init(
        mode: CustomFoodEditorMode,
        service: any LibraryServicing,
        accountID: String,
        onSaved: @escaping (String) -> Void,
        onSessionExpired: @escaping () -> Void,
        assistantDraft: AssistantReviewedDraft?,
        initialBarcode: String?,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        self.onDirtyChange = onDirtyChange
        _viewModel = StateObject(
            wrappedValue: CustomFoodEditorViewModel(
                mode: mode,
                service: service,
                accountID: accountID,
                onSaved: onSaved,
                onSessionExpired: onSessionExpired,
                assistantDraft: assistantDraft,
                initialBarcode: initialBarcode
            )
        )
    }

    var body: some View {
        DirtyTrackingEditorRoute(
            viewModel: viewModel,
            onDirtyChange: onDirtyChange
        )
    }
}

/// Ad-hoc counterpart to `CustomFoodEditorRouteView`; the view model is created
/// once for this route instead of on every destination-builder evaluation.
private struct AdHocRouteView: View {
    @StateObject private var viewModel: AdHocLogViewModel
    private let onDirtyChange: (Bool) -> Void

    init(
        service: any LibraryServicing,
        submissionService: any LibraryLogSubmitting,
        accountID: String,
        initialDate: LocalDiaryDate,
        today: LocalDiaryDate,
        initialMealSlot: MealSlot?,
        baseURL: URL?,
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void,
        onSessionExpired: @escaping () -> Void,
        assistantDraft: AssistantReviewedDraft?,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        self.onDirtyChange = onDirtyChange
        _viewModel = StateObject(
            wrappedValue: AdHocLogViewModel(
                service: service,
                submissionService: submissionService,
                accountID: accountID,
                initialDate: initialDate,
                today: today,
                initialMealSlot: initialMealSlot,
                baseURL: baseURL,
                onLogged: onLogged,
                onSessionExpired: onSessionExpired,
                assistantDraft: assistantDraft
            )
        )
    }

    var body: some View {
        DirtyTrackingAdHocRoute(
            viewModel: viewModel,
            onDirtyChange: onDirtyChange
        )
    }
}

// MARK: - Row

private struct LibraryFoodRow: View {
    let food: CustomFood

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(food.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let brand = food.brand, !brand.isEmpty {
                Text(brand)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                String(
                    format: String(localized: "library.row.calories"),
                    formatted(food.energyKcalValue)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if !food.categories.isEmpty {
                Text(food.categories.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Detail route

private struct CustomFoodDetailRouteView: View {
    @StateObject private var viewModel: CustomFoodDetailViewModel
    @State private var confirmingDelete = false

    private let onEdit: (String) -> Void
    private let onDeleted: (String) -> Void

    init(
        foodID: String,
        service: any LibraryServicing,
        onEdit: @escaping (String) -> Void,
        onDeleted: @escaping (String) -> Void,
        onSessionExpired: @escaping () -> Void
    ) {
        self.onEdit = onEdit
        self.onDeleted = onDeleted
        _viewModel = StateObject(
            wrappedValue: CustomFoodDetailViewModel(
                foodID: foodID,
                service: service,
                onDeleted: onDeleted,
                onSessionExpired: onSessionExpired
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView(String(localized: "foodDetail.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .removed:
                ContentUnavailableView(
                    String(localized: "library.detail.notFound"),
                    systemImage: "questionmark.folder"
                )
            case .failed(let message):
                Form {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "foodDetail.retry")) {
                            Task { await viewModel.load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .loaded(let food):
                detail(food)
            }
        }
        .navigationTitle(Text(viewModel.food?.name ?? String(localized: "foodDetail.title")))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            if case .loading = viewModel.state {
                await viewModel.load()
            }
        }
        .alert(
            String(localized: "library.detail.delete.confirmTitle"),
            isPresented: $confirmingDelete
        ) {
            Button(String(localized: "library.detail.delete.confirmAction"), role: .destructive) {
                Task { await viewModel.delete() }
            }
            .accessibilityIdentifier("library.detail.delete.confirm")
            Button(String(localized: "diary.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "library.detail.delete.confirmMessage"))
        }
    }

    private func detail(_ food: CustomFood) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(food.name)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let brand = food.brand, !brand.isEmpty {
                        Text(brand)
                            .foregroundStyle(.secondary)
                    }
                    if !food.categories.isEmpty {
                        Text(food.categories.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("library.detail")
            }

            Section {
                ForEach(food.nutrients) { nutrient in
                    HStack(alignment: .firstTextBaseline) {
                        Text(nutrient.code)
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text("\(nutrient.amountPer100g) \(nutrient.unit)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "library.detail.nutrients"))
            }

            if let amount = food.defaultQuantity, let unit = food.defaultUnit {
                Section {
                    HStack {
                        Text(String(localized: "library.detail.defaultPortion"))
                        Spacer(minLength: 8)
                        Text("\(amount) \(unit)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !food.servings.isEmpty {
                Section {
                    ForEach(food.servings) { serving in
                        HStack {
                            Text(serving.unit)
                            Spacer(minLength: 8)
                            Text(
                                String(
                                    format: String(localized: "library.detail.gramsPerServing"),
                                    serving.gramsPerUnit
                                )
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "library.detail.servings"))
                }
            }

            if let error = viewModel.deleteErrorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("library.detail.delete.error")
                }
            }

            Section {
                Button {
                    onEdit(food.id)
                } label: {
                    Label(
                        String(localized: "library.detail.edit"),
                        systemImage: "pencil"
                    )
                }
                .disabled(viewModel.isDeleting)
                .accessibilityIdentifier("library.detail.edit")

                Button(role: .destructive) {
                    viewModel.clearDeleteError()
                    confirmingDelete = true
                } label: {
                    if viewModel.isDeleting {
                        HStack {
                            ProgressView()
                            Text(String(localized: "library.detail.deleting"))
                        }
                    } else {
                        Label(
                            String(localized: "library.detail.delete"),
                            systemImage: "trash"
                        )
                    }
                }
                .disabled(viewModel.isDeleting)
                .accessibilityIdentifier("library.detail.delete")
            } footer: {
                Text(String(localized: "library.detail.delete.footnote"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


// MARK: - Dirty tracking wrappers

private struct DirtyTrackingEditorRoute: View {
    @ObservedObject var viewModel: CustomFoodEditorViewModel
    let onDirtyChange: (Bool) -> Void

    var body: some View {
        CustomFoodEditorView(viewModel: viewModel)
            .onAppear { onDirtyChange(viewModel.hasUnsavedChanges) }
            .onChange(of: viewModel.hasUnsavedChanges) { _, dirty in
                onDirtyChange(dirty)
            }
            .onDisappear { onDirtyChange(false) }
    }
}

private struct DirtyTrackingAdHocRoute: View {
    @ObservedObject var viewModel: AdHocLogViewModel
    let onDirtyChange: (Bool) -> Void

    var body: some View {
        AdHocLogView(viewModel: viewModel)
            .onAppear { onDirtyChange(viewModel.hasUnsavedChanges) }
            .onChange(of: viewModel.hasUnsavedChanges) { _, dirty in
                onDirtyChange(dirty)
            }
            .onDisappear { onDirtyChange(false) }
    }
}
