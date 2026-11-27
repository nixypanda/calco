import ComposableArchitecture
import SwiftUI

public struct FoodCreationFeatureView: View {
    @Bindable public var store: StoreOf<FoodCreationFeature>
    public var body: some View {
        Group {
            switch store.entry {
            case .assistant:
                IfLetStore(store.scope(state: \.assistant, action: \.assistant)) { hostStore in
                    AssistantCreationPage(
                        store: hostStore.scope(state: \.assistant, action: \.assistant),
                        onDiscard: { store.send(.delegate(.finished(
                            generation: store.sessionGeneration,
                            presentationID: store.presentationID
                        ))) }
                    )
                }
            case .barcode:
                IfLetStore(store.scope(state: \.editor, action: \.editor)) { editorStore in
                    CustomFoodEditorFeatureView(store: editorStore)
                }
            }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { store.isReviewPresented },
                set: { store.send(.reviewPresentedChanged($0)) }
            )
        ) {
            reviewPage
        }
    }

    @ViewBuilder
    private var reviewPage: some View {
        IfLetStore(store.scope(state: \.editor, action: \.editor)) { editorStore in
            CustomFoodEditorFeatureView(store: editorStore)
        } else: {
            IfLetStore(store.scope(state: \.adHoc, action: \.adHoc)) { adHocStore in
                AdHocLogFeatureView(store: adHocStore)
            }
        }
    }
}

private struct AssistantCreationPage: View {
    let store: StoreOf<AssistantFeature>
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingBack = false

    var body: some View {
        AssistantFeatureView(store: store)
            .onAppear { store.send(.resumeDraftReview) }
            .navigationBarBackButtonHidden(store.canStartOver || store.isSending)
            .toolbar {
                if store.canStartOver || store.isSending {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            confirmingBack = true
                        } label: {
                            Label(
                                String(localized: "library.common.back"),
                                systemImage: "chevron.left"
                            )
                        }
                        .accessibilityIdentifier("assistant.back")
                    }
                }
            }
            .alert(String(localized: "diary.editor.discard.title"), isPresented: $confirmingBack) {
                Button(String(localized: "diary.editor.discard.action"), role: .destructive) {
                    onDiscard()
                    dismiss()
                }
                Button(String(localized: "diary.common.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "diary.editor.discard.message"))
            }
    }
}
