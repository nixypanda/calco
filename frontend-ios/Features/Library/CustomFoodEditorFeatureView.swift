import ComposableArchitecture
import SwiftUI

public struct CustomFoodEditorFeatureView: View {
    @Bindable public var store: StoreOf<CustomFoodEditorFeature>
    public var body: some View {
        Form {
            switch store.loadPhase {
            case .loading:
                HStack {
                    ProgressView()
                    Text(String(localized: "library.editor.loading"))
                }
            case let .failed(message):
                Text(message).foregroundStyle(.red)
                Button(String(localized: "foodDetail.retry")) { store.send(.load) }
            case .loaded:
                editorContent
            }
        }
        .navigationTitle(Text(LocalizedStringKey(store.titleKey)))
        .onAppear { store.send(.load) }
        .accessibilityIdentifier("library.editor")
    }

    @ViewBuilder
    private var editorContent: some View {
        Section {
            TextField(String(localized: "library.editor.name"), text: Binding(
                get: { store.name },
                set: { store.send(.nameChanged($0)) }
            ))
            .disabled(!store.isFormEditable)
            .accessibilityIdentifier("library.editor.name")
            TextField(String(localized: "library.editor.brand"), text: Binding(
                get: { store.brand },
                set: { store.send(.brandChanged($0)) }
            ))
            .disabled(!store.isFormEditable)
            TextField(String(localized: "library.editor.categories"), text: Binding(
                get: { store.categoriesText },
                set: { store.send(.categoriesChanged($0)) }
            ))
            .disabled(!store.isFormEditable)
        }

        Section {
            TextField(String(localized: "library.editor.quantity"), text: Binding(
                get: { store.defaultQuantity },
                set: { store.send(.defaultQuantityChanged($0)) }
            ))
            .disabled(!store.isFormEditable)
            TextField(String(localized: "library.editor.unit"), text: Binding(
                get: { store.defaultUnit },
                set: { store.send(.defaultUnitChanged($0)) }
            ))
            .disabled(!store.isFormEditable)
        }

        if !store.mode.isCreate {
            Section {
                ForEach(store.servings) { row in
                    HStack {
                        TextField(String(localized: "library.editor.serving.unit"), text: Binding(
                            get: { row.unit },
                            set: { store.send(.servingUpdated(id: row.id, unit: $0, gramsPerUnit: nil)) }
                        ))
                        TextField(String(localized: "library.editor.serving.grams"), text: Binding(
                            get: { row.gramsPerUnit },
                            set: { store.send(.servingUpdated(id: row.id, unit: nil, gramsPerUnit: $0)) }
                        ))
                        Button(role: .destructive) {
                            store.send(.servingRemoved(id: row.id))
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                Button(String(localized: "library.editor.serving.add")) {
                    store.send(.servingAdded)
                }
                .disabled(!store.isFormEditable)
            } header: {
                Text(String(localized: "library.editor.servings"))
            }
        }

        NutrientEditorView(
            title: String(localized: "library.editor.nutrients"),
            state: store.nutrientEditor,
            isDisabled: !store.isFormEditable,
            onAmountChange: { code, amount in
                store.send(.nutrientAmountChanged(code: code, amount: amount))
            },
            onAddOptional: { store.send(.nutrientAdded(code: $0)) },
            onRemove: { store.send(.nutrientRemoved(code: $0)) }
        )

        if let notice = store.barcodeNotice {
            Section {
                Text(notice).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("library.editor.barcodeNotice")
        }

        Section {
            if let error = store.submitError {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("library.editor.error")
            }
            if let id = store.savedFoodID {
                Text(String(format: String(localized: "library.editor.saved"), id))
            }
            Button(String(localized: "library.editor.save")) {
                store.send(.submit)
            }
            .disabled(!store.canSubmit)
            .accessibilityIdentifier("library.editor.save")
        }
    }
}
