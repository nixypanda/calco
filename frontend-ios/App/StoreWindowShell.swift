import ComposableArchitecture
import SwiftUI

/// Store-driven signed-in window. Every screen is scoped from the single
/// persistent `AppFeature`/`WindowFeature` store owned by `NativeWindowRuntime`.
/// There is no coordinator, no view-model factory and no per-feature Store.
public struct StoreWindowShell: View {
    private let store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if let windowStore = store.scope(state: \.window, action: \.window) {
                WindowScreen(store: windowStore)
            } else {
                SessionStatusView(status: .restoring)
            }
        }
    }
}

private struct WindowScreen: View {
    @Bindable private var store: StoreOf<WindowFeature>

    init(store: StoreOf<WindowFeature>) {
        self.store = store
    }

    private var tabSelection: Binding<WindowTab> {
        Binding(
            get: { store.selectedTab },
            set: { store.send(.requestSelectTab($0)) }
        )
    }

    private func destinationPath(for tab: WindowTab) -> Binding<[WindowDestination]> {
        Binding(
            get: { store.selectedTab == tab ? store.destinationStack : [] },
            set: { desired in
                guard store.selectedTab == tab else { return }
                store.send(.requestPathChange(WindowPathChange(
                    tab: tab, expected: store.destinationStack, desired: desired
                )))
            }
        )
    }

    private var activePresentation: Binding<WindowPresentation?> {
        Binding(
            get: { store.presentation },
            set: { newValue in
                guard newValue == nil, let id = store.presentation?.id else { return }
                store.send(.requestDismissPresentation(id))
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pending = store.pendingSubmission {
                pendingSubmissionBanner(pending)
            }
            TabView(selection: tabSelection) {
            NavigationStack(path: destinationPath(for: .diary)) {
                DiaryScreenView(
                    store: store.scope(state: \.diary, action: \.diary),
                    onOpenSettings: openSettings,
                    onOpenNutrition: openNutrition
                )
                .navigationDestination(for: WindowDestination.self) { destination in
                    destinationView(destination)
                }
            }
            .tabItem {
                Label(WindowTab.diary.title, systemImage: WindowTab.diary.systemImage)
                    .accessibilityIdentifier("app.tab.diary")
            }
            .tag(WindowTab.diary)

            NavigationStack(path: destinationPath(for: .search)) {
                SearchScreenView(
                    store: store.scope(state: \.search, action: \.search),
                    onOpenMeals: openMeals
                )
                .navigationDestination(for: WindowDestination.self) { destination in
                    destinationView(destination)
                }
            }
            .tabItem {
                Label(WindowTab.search.title, systemImage: WindowTab.search.systemImage)
                    .accessibilityIdentifier("app.tab.search")
            }
            .tag(WindowTab.search)

            LibraryHubView(store: store, destinationView: { destination in
                AnyView(self.destinationView(destination))
            })
            .tabItem {
                Label(WindowTab.library.title, systemImage: WindowTab.library.systemImage)
                    .accessibilityIdentifier("app.tab.library")
            }
            .tag(WindowTab.library)

            NavigationStack(path: destinationPath(for: .account)) {
                Group {
                    if let settingsStore = store.scope(state: \.settings, action: \.settings) {
                        SettingsFeatureView(store: settingsStore)
                    } else {
                        Text("")
                    }
                }
                .navigationDestination(for: WindowDestination.self) { destination in
                    destinationView(destination)
                }
            }
            .tabItem {
                Label(WindowTab.account.title, systemImage: WindowTab.account.systemImage)
                    .accessibilityIdentifier("app.tab.settings")
            }
            .tag(WindowTab.account)
            }
        }
        .sheet(item: activePresentation) { presentation in
            presentationView(presentation)
        }
        .alert(
            String(localized: "foodDetail.pending.discard.confirmTitle"),
            isPresented: Binding(
                get: { store.pendingBannerDiscard != nil },
                set: { if !$0 { store.send(.cancelDiscardPending) } }
            )
        ) {
            Button(String(localized: "foodDetail.pending.discard.confirmAction"), role: .destructive) {
                store.send(.confirmDiscardPending)
            }
            Button(String(localized: "foodDetail.pending.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "foodDetail.pending.discard.confirmMessage"))
        }
        .confirmationDialog(
            String(localized: "diary.editor.discard.title"),
            isPresented: Binding(
                get: { store.pendingEditorDiscard != nil },
                set: { if !$0 { store.send(.cancelEditorDiscard) } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "diary.editor.discard.action"), role: .destructive) {
                store.send(.confirmEditorDiscard)
            }
            Button(String(localized: "foodDetail.pending.cancel"), role: .cancel) {}
        }
        .task {
            store.send(.refreshPendingSubmissions(accountID: store.sessionAccountID))
        }
    }

    @ViewBuilder
    private func pendingSubmissionBanner(_ pending: PendingLogSubmission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.pendingSubmissions.count) pending")
                        .font(.footnote.weight(.semibold))
                    Text("\(pending.foodName) · \(pending.draft.date.formatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(String(localized: "foodDetail.pending.review")) {
                    store.send(.reviewPendingSubmission(pending))
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("foodDetail.pending.review")
                if store.pendingSubmissions.count > 1 {
                    Menu {
                        ForEach(store.pendingSubmissions) { entry in
                            Button {
                                store.send(.reviewPendingSubmission(entry))
                            } label: {
                                Text("\(entry.foodName) · \(entry.draft.date.formatted)")
                            }
                        }
                    } label: {
                        Text(String(localized: "foodDetail.pending.reviewAll"))
                            .font(.footnote.weight(.semibold))
                    }
                    .accessibilityIdentifier("foodDetail.pending.reviewAll")
                }
                Button {
                    store.send(.dismissPendingBanner)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "foodDetail.pending.dismissBanner"))
                .accessibilityIdentifier("foodDetail.pending.dismiss")
            }
            if pending.state == .conflicted {
                HStack(spacing: 8) {
                    Text(String(localized: "foodDetail.pending.conflicted"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(String(localized: "foodDetail.pending.discard"), role: .destructive) {
                        store.send(.requestDiscardPending(pending))
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("foodDetail.pending.banner.discard")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("app.pendingSubmission.banner")
    }

    private func openSettings() {
        store.send(.requestSelectTab(.account))
    }

    private func openNutrition() {
        store.send(.openNutrition(
            selectedDate: store.diary.diary.selectedDate,
            today: store.today
        ))
    }

    private func openMeals() {
        store.send(.pushDestination(.meals(context: captureContext(origin: .diary))))
    }

    private func captureContext(origin: WindowNavOrigin) -> WindowCaptureContext {
        WindowCaptureContext(
            date: store.diary.diary.selectedDate,
            slot: nil,
            accountID: store.sessionAccountID,
            generation: store.sessionGeneration,
            origin: origin,
            presentationID: UUID()
        )
    }

    @ViewBuilder
    private func destinationView(_ destination: WindowDestination) -> some View {
        switch destination {
        case .foodDetail:
            if let child = store.scope(state: \.foodDetail, action: \.foodDetail) {
                FoodDetailFeatureView(store: child)
            }
        case .logEditor:
            if let child = store.scope(state: \.logEditor, action: \.logEditor) {
                LogEditorFeatureView(store: child)
            }
        case .meals:
            if let child = store.scope(state: \.meals, action: \.meals) {
                MealsFlowFeatureView(store: child, showsClose: true)
            }
        case .library:
            if let child = store.scope(state: \.library, action: \.library) {
                LibraryFeatureView(store: child)
            }
        case .search:
            SearchScreenView(
                store: store.scope(state: \.search, action: \.search),
                onOpenMeals: openMeals,
                scopeOptions: SearchScreenView.contextualScopes,
                navigationOrigin: .diaryPush
            )
        case .settings:
            if let child = store.scope(state: \.settings, action: \.settings) {
                SettingsFeatureView(store: child)
            }
        case .accountSettings:
            if let child = store.scope(state: \.accountSettings, action: \.accountSettings) {
                AccountSettingsFeatureView(store: child) {
                    store.send(.popDestinationToRoot)
                }
            }
        case .nutrition:
            if let child = store.scope(state: \.nutrition, action: \.nutrition) {
                NutritionDetailsFeatureView(store: child)
            }
        case .mealDetail, .mealEditor:
            // Rendered by the single composed MealsFlowFeature child, which owns
            // its own typed detail/editor stack. No second Store is created.
            if let child = store.scope(state: \.meals, action: \.meals) {
                MealsFlowFeatureView(store: child)
            }
        }
    }

    @ViewBuilder
    private func presentationView(_ presentation: WindowPresentation) -> some View {
        switch presentation {
        case .logFood, .quickAdd:
            SearchScreenView(
                store: store.scope(state: \.search, action: \.search),
                onOpenMeals: nil,
                scopeOptions: SearchScreenView.contextualScopes,
                navigationOrigin: .diaryPush
            )
        case .settings:
            if let child = store.scope(state: \.settings, action: \.settings) {
                SettingsFeatureView(store: child)
            }
        case .barcode:
            if let child = store.scope(state: \.barcode, action: \.barcode) {
                BarcodeFeatureView(store: child)
            }
        case .assistant:
            if let child = store.scope(state: \.assistant, action: \.assistant) {
                AssistantFeatureView(store: child)
            }
        case .foodCreation:
            if let child = store.scope(state: \.foodCreation, action: \.foodCreation) {
                FoodCreationFeatureView(store: child)
            }
        }
    }
}
