import ComposableArchitecture
import SwiftUI

public struct LibraryFeatureView: View {
    @Bindable public var store: StoreOf<LibraryFeature>
    public var body: some View {
        List {
            if let error = store.refreshError {
                Section {
                    Text(error).foregroundStyle(.orange)
                }
            }
            if store.isLoading && store.foods.isEmpty {
                HStack {
                    ProgressView()
                    Text(String(localized: "library.loading"))
                }
                .accessibilityIdentifier("library.loading")
            } else if case let .failed(message) = store.phase, store.foods.isEmpty {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button(String(localized: "foodDetail.retry")) { store.send(.load) }
                        .accessibilityIdentifier("foodDetail.retry")
                }
            } else if store.foods.isEmpty {
                Text(String(localized: "library.empty"))
                    .accessibilityIdentifier("library.empty")
            } else if store.filteredFoods.isEmpty {
                Text(String(localized: "library.search.empty"))
                    .accessibilityIdentifier("library.search.empty")
            } else {
                ForEach(store.filteredFoods) { food in
                    Button {
                        store.send(.openDetail(id: food.id))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(food.name)
                            if let brand = food.brand, !brand.isEmpty {
                                Text(brand).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("library.row.\(food.id)")
                }
            }
        }
        .searchable(
            text: Binding(
                get: { store.searchText },
                set: { store.send(.searchChanged($0)) }
            ),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(String(localized: "library.search.placeholder"))
        )
        .navigationTitle(String(localized: "library.title"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "library.add.custom")) {
                        store.send(.openCustomFoodEditor)
                    }
                    .accessibilityIdentifier("library.add.custom")
                    Button(String(localized: "library.createWithAI")) {
                        store.send(.openCreation(
                            entry: .assistant(purpose: .customFood, barcode: nil)
                        ))
                    }
                    .accessibilityIdentifier("library.createWithAI")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "library.add"))
                .accessibilityIdentifier("library.add")
            }
        }
        .refreshable { store.send(.refresh) }
        .onAppear { store.send(.load) }
        .navigationDestination(
            isPresented: Binding(
                get: { store.detail != nil },
                set: { if !$0 { store.send(.detailDismissed) } }
            )
        ) {
            IfLetStore(store.scope(state: \.detail, action: \.detail)) { detailStore in
                CustomFoodDetailFeatureView(store: detailStore)
            }
        }
    }
}

public struct CustomFoodDetailFeatureView: View {
    @Bindable public var store: StoreOf<CustomFoodDetailFeature>
    public var body: some View {
        Form {
            switch store.phase {
            case .loading:
                HStack {
                    ProgressView()
                    Text(String(localized: "library.detail.loading"))
                }
            case .removed:
                Text(String(localized: "library.detail.removed"))
            case let .failed(message):
                Text(message).foregroundStyle(.red)
                Button(String(localized: "foodDetail.retry")) { store.send(.load) }
            case let .loaded(food):
                Section {
                    Text(food.name)
                    if let brand = food.brand { Text(brand).foregroundStyle(.secondary) }
                }
                Section {
                    Button(String(localized: "library.detail.edit")) {
                        store.send(.delegate(.edit(
                            id: food.id, generation: store.sessionGeneration
                        )))
                    }
                    .accessibilityIdentifier("library.detail.edit")

                    Button(String(localized: "library.detail.delete"), role: .destructive) {
                        store.send(.delete)
                    }
                    .disabled(store.isDeleting)
                    .accessibilityIdentifier("library.detail.delete")

                    if let error = store.deleteErrorMessage {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("library.detail.delete.error")
                        Button(String(localized: "diary.common.dismiss")) {
                            store.send(.clearDeleteError)
                        }
                    }
                }
            }
        }
        .navigationTitle(store.food?.name ?? String(localized: "library.detail.title"))
        .onAppear { store.send(.load) }
        .accessibilityIdentifier("library.detail")
    }
}
