// Library navigation: standalone hosts own their stack; the Library hub shares
// its path so list, detail, and editors use one continuous native back history.

import SwiftUI

public struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @State private var localPath = NavigationPath()
    @Binding private var sharedPath: NavigationPath
    private let usesSharedPath: Bool
    // Capture once: later pushes must not move the list's return destination.
    @State private var rootPathCount: Int
    @State private var hasDirtyEditor = false
    @State private var initialRouteToken: UUID?
    @State private var detailRefreshToken = 0
    @State private var creationDestination: FoodCreationDestination?

    private var path: NavigationPath {
        get { usesSharedPath ? sharedPath : localPath }
        nonmutating set {
            if usesSharedPath { sharedPath = newValue }
            else { localPath = newValue }
        }
    }

    private var isListRoot: Bool { path.count == rootPathCount }

    private func returnToList() {
        guard path.count > rootPathCount else { return }
        path.removeLast(path.count - rootPathCount)
    }

    private func closeEditorPage() {
        hasDirtyEditor = false
        onDirtyChange?(false)
        if path.count > rootPathCount { path.removeLast() }
    }

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
    /// Legacy standalone back action. Shared-path destinations use the system
    /// Back button instead, never an additional toolbar action.
    private let onBack: (() -> Void)?
    private let backDisabled: Bool
    private let onDirtyChange: ((Bool) -> Void)?
    private let creationContextProvider: (() -> FoodCreationContext)?
    private let initialAssistantDraft: AssistantReviewedDraft?
    private let initialBarcode: String?
    /// Reads the live diary target only when a new logging flow is opened.
    private let currentContextProvider: () -> LibraryLogContext

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
        onBack: (() -> Void)? = nil,
        backDisabled: Bool = false,
        onDirtyChange: ((Bool) -> Void)? = nil,
        creationContextProvider: (() -> FoodCreationContext)? = nil,
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil,
        currentContextProvider: (() -> LibraryLogContext)? = nil,
        navigationPath: Binding<NavigationPath>? = nil
    ) {
        let resolvedDate = min(initialDate, today)
        let resolvedSlot = initialMealSlot
        self.service = service
        _sharedPath = navigationPath ?? .constant(NavigationPath())
        usesSharedPath = navigationPath != nil
        // Shared flows are one level below the Library hub. Destination views
        // may be initialized before SwiftUI publishes that first path element.
        _rootPathCount = State(initialValue: navigationPath == nil ? 0 : 1)
        self.submissionService = submissionService
        self.accountID = accountID
        self.today = today
        self.initialDate = resolvedDate
        self.initialMealSlot = resolvedSlot
        self.baseURL = baseURL
        self.onLogged = onLogged
        self.onSessionExpired = onSessionExpired
        self.onClose = onClose
        self.onBack = onBack
        self.backDisabled = backDisabled
        self.onDirtyChange = onDirtyChange
        self.creationContextProvider = creationContextProvider
        self.initialAssistantDraft = assistantDraft
        self.initialBarcode = initialBarcode
        self.currentContextProvider = currentContextProvider
            ?? { LibraryLogContext(date: resolvedDate, mealSlot: resolvedSlot) }
        let initialRoute: [LibraryRoute]
        let initialToken: UUID?
        switch assistantDraft?.purpose {
        case .customFood:
            let token = UUID()
            initialRoute = [.create(token: token)]
            initialToken = token
        case .adHocLog:
            let token = UUID()
            let captured = currentContextProvider?()
                ?? LibraryLogContext(date: resolvedDate, mealSlot: resolvedSlot)
            initialRoute = [.adHoc(
                token: token,
                context: LibraryLogContext(
                    date: min(captured.date, today),
                    mealSlot: captured.mealSlot
                )
            )]
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
        _localPath = State(initialValue: NavigationPath(initialRoute))
        _initialRouteToken = State(initialValue: initialToken)
        _viewModel = StateObject(
            wrappedValue: LibraryViewModel(
                service: service,
                accountID: accountID,
                onSessionExpired: onSessionExpired
            )
        )
    }

    /// Captures the live diary target at the moment a new logging flow opens.
    /// The returned value is stored in the route and never refreshed, so an
    /// open draft and its awaited POST keep the date/slot the user started with.
    private func captureContext() -> LibraryLogContext {
        let captured = currentContextProvider()
        return LibraryLogContext(date: min(captured.date, today), mealSlot: captured.mealSlot)
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
        .interactiveDismissDisabled(hasDirtyEditor)
        .onChange(of: path.count) { _, count in
            if count == rootPathCount {
                hasDirtyEditor = false
                onDirtyChange?(false)
                Task { await viewModel.refresh() }
            }
        }
    }

    private var navigationContent: some View {
            listView
                .navigationTitle(Text("My Foods"))
#if os(iOS)
                .navigationBarTitleDisplayMode(.large)
#endif
                .toolbar {
                    // Only on the list root: pushed detail/editor screens use
                    // the system back button, so there is never a second Back.
                    if let onBack, isListRoot, !usesSharedPath {
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
                    // One native trailing PLUS menu, matching My Meals. Both
                    // entries push pages on this stack; AI owns its review
                    // draft until the entire creation task completes.
                    if isListRoot, !hasDirtyEditor {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button {
                                    path.append(LibraryRoute.create(token: UUID()))
                                } label: {
                                    Label(
                                        String(localized: "library.create.manually"),
                                        systemImage: "square.and.pencil"
                                    )
                                }
                                .accessibilityIdentifier("library.add.custom")

                                if let creationContextProvider {
                                    Button {
                                        creationDestination = FoodCreationDestination(
                                            request: FoodCreationRequest(
                                                entry: .assistant(.customFood, barcode: nil)
                                            ),
                                            context: creationContextProvider()
                                        )
                                    } label: {
                                        Label(
                                            String(localized: "library.create.withAI"),
                                            systemImage: "sparkles"
                                        )
                                    }
                                    .accessibilityIdentifier("library.createWithAI")
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel(String(localized: "library.add"))
                            .accessibilityIdentifier("library.add")
                        }
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
                .navigationDestination(item: $creationDestination) { destination in
                    FoodCreationFlowView(request: destination.request, context: destination.context) {
                        creationDestination = nil
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
                                    LibraryRoute.detail(foodID: food.id, token: UUID())
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
                    refreshToken: detailRefreshToken,
                    onEdit: {
                        path.append(LibraryRoute.edit(foodID: $0, token: UUID()))
                    },
                    onDeleted: { id in
                        viewModel.removeFood(id: id)
                        returnToList()
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
                        returnToList()
                    },
                    onSessionExpired: onSessionExpired,
                    assistantDraft: isInitialRoute
                        && initialAssistantDraft?.purpose == .customFood
                        ? initialAssistantDraft
                        : nil,
                    initialBarcode: isInitialRoute ? initialBarcode : nil,
                    onBack: closeEditorPage,
                    onDirtyChange: { hasDirtyEditor = $0; onDirtyChange?($0) }
                )
            case .edit(let foodID, _):
                CustomFoodEditorRouteView(
                    mode: .edit(id: foodID),
                    service: service,
                    accountID: accountID,
                    onSaved: { _ in
                        if path.count > rootPathCount { path.removeLast() }
                        detailRefreshToken += 1
                    },
                    onSessionExpired: onSessionExpired,
                    assistantDraft: nil,
                    initialBarcode: nil,
                    onBack: closeEditorPage,
                    onDirtyChange: { hasDirtyEditor = $0; onDirtyChange?($0) }
                )
            case .adHoc(let token, let context):
                AdHocRouteView(
                    service: service,
                    submissionService: submissionService,
                    accountID: accountID,
                    initialDate: context.date,
                    today: today,
                    initialMealSlot: context.mealSlot,
                    baseURL: baseURL,
                    onLogged: onLogged,
                    onSessionExpired: onSessionExpired,
                    assistantDraft: token == initialRouteToken
                        && initialAssistantDraft?.purpose == .adHocLog
                        ? initialAssistantDraft
                        : nil,
                    onDirtyChange: { hasDirtyEditor = $0; onDirtyChange?($0) }
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
    case adHoc(token: UUID, context: LibraryLogContext)
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
    private let onBack: () -> Void

    init(
        mode: CustomFoodEditorMode,
        service: any LibraryServicing,
        accountID: String,
        onSaved: @escaping (String) -> Void,
        onSessionExpired: @escaping () -> Void,
        assistantDraft: AssistantReviewedDraft?,
        initialBarcode: String?,
        onBack: @escaping () -> Void,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        self.onDirtyChange = onDirtyChange
        self.onBack = onBack
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
            onBack: onBack,
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
        DisplayNumberFormat.decimal(value)
    }
}

// MARK: - Detail route

private struct CustomFoodDetailRouteView: View {
    @StateObject private var viewModel: CustomFoodDetailViewModel
    @State private var confirmingDelete = false

    private let onEdit: (String) -> Void
    private let onDeleted: (String) -> Void
    private let refreshToken: Int

    init(
        foodID: String,
        service: any LibraryServicing,
        refreshToken: Int = 0,
        onEdit: @escaping (String) -> Void,
        onDeleted: @escaping (String) -> Void,
        onSessionExpired: @escaping () -> Void
    ) {
        self.onEdit = onEdit
        self.refreshToken = refreshToken
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
        .toolbar {
            if let food = viewModel.food {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "library.detail.edit")) {
                        onEdit(food.id)
                    }
                    .disabled(viewModel.isDeleting)
                    .accessibilityIdentifier("library.detail.edit")
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task(id: refreshToken) {
            await viewModel.load()
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
                NutritionTable(rows: food.nutrients.map { nutrient in
                    NutritionTableRow(
                        id: nutrient.code,
                        name: logNutritionLabel(for: nutrient.code),
                        amount: nutrient.amountPer100g,
                        unit: nutrient.unit
                    )
                })
                .font(.subheadline)
            } header: {
                Text(String(localized: "library.detail.nutrients"))
            }

            if let amount = food.defaultQuantity, let unit = food.defaultUnit {
                Section {
                    HStack {
                        Text(String(localized: "library.detail.defaultPortion"))
                        Spacer(minLength: 8)
                        Text("\(DisplayNumberFormat.decimal(amount)) \(unit)")
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
                                    DisplayNumberFormat.decimal(serving.gramsPerUnit)
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
    let onBack: () -> Void
    let onDirtyChange: (Bool) -> Void

    var body: some View {
        CustomFoodEditorView(viewModel: viewModel, onBack: onBack)
            .onAppear { onDirtyChange(viewModel.hasUnsavedChanges || viewModel.isBusy) }
            .onChange(of: viewModel.hasUnsavedChanges || viewModel.isBusy) { _, dirty in
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
