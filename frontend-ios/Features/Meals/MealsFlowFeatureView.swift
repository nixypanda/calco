
import ComposableArchitecture
import SwiftUI

public struct MealsFlowFeatureView: View {
    @Bindable private var store: StoreOf<MealsFlowFeature>
    /// A modal sheet root owns Close; pushed Library pages keep only system Back.
    private let showsClose: Bool

    public init(
        store: StoreOf<MealsFlowFeature>,
        showsClose: Bool = false
    ) {
        self.store = store
        self.showsClose = showsClose
    }

    public var body: some View {
        NavigationStack(path: $store.scope(\.path, action: \.path)) {
            MealsListFeatureView(
                store: store.scope(state: \.list, action: \.list),
                showsAddButton: store.isAtRoot
            )
            .toolbar {
                if showsClose, store.isAtRoot {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            store.send(.close)
                        } label: {
                            Label(String(localized: "meals.common.close"), systemImage: "xmark")
                        }
                        .accessibilityIdentifier("meals.close")
                    }
                }
            }
        } destination: { store in
            switch store.case {
            case .detail(let detailStore):
                MealDetailFeatureView(store: detailStore)
            case .editor(let editorStore):
                MealEditorFeatureView(store: editorStore)
            }
        }
    }
}
