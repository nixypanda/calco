// Reusable nutrient editor used by custom-food create/edit and ad-hoc logging.

import SwiftUI

public struct NutrientEditorView: View {
    public let title: String
    public let help: String?
    public let state: NutrientEditorState
    public let isDisabled: Bool
    public let onAmountChange: (String, String) -> Void
    public let onAddOptional: (String) -> Void
    public let onRemove: (String) -> Void

    public init(
        title: String,
        help: String? = nil,
        state: NutrientEditorState,
        isDisabled: Bool = false,
        onAmountChange: @escaping (String, String) -> Void,
        onAddOptional: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.title = title
        self.help = help
        self.state = state
        self.isDisabled = isDisabled
        self.onAmountChange = onAmountChange
        self.onAddOptional = onAddOptional
        self.onRemove = onRemove
    }

    public var body: some View {
        Section {
            ForEach(state.rows) { row in
                rowView(row)
            }

            if !state.availableOptionalDefinitions.isEmpty && !isDisabled {
                Menu {
                    ForEach(state.availableOptionalDefinitions) { definition in
                        Button {
                            onAddOptional(definition.code)
                        } label: {
                            Text("\(definition.name) (\(definition.unit))")
                        }
                    }
                } label: {
                    Label(
                        String(localized: "library.editor.optionalAdd"),
                        systemImage: "plus.circle"
                    )
                }
                .accessibilityIdentifier("library.nutrient.add")
            }
        } header: {
            Text(title)
        } footer: {
            if let help {
                Text(help)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: NutrientEditorRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .fixedSize(horizontal: false, vertical: true)
                if row.isRequired {
                    Text(String(localized: "library.common.required"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel(String(localized: "library.common.required"))
                }
                Spacer(minLength: 8)
                if !row.isRequired && !isDisabled {
                    Button(role: .destructive) {
                        onRemove(row.code)
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        String(
                            format: String(localized: "library.nutrient.remove"),
                            row.name
                        )
                    )
                    .accessibilityIdentifier("library.nutrient.\(row.code).remove")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(
                    "0",
                    text: Binding(
                        get: { row.amount },
                        set: { onAmountChange($0, row.code) }
                    )
                )
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
                .multilineTextAlignment(.trailing)
                .disabled(isDisabled)
                .accessibilityLabel("\(row.name), \(row.unit)")
                .accessibilityIdentifier("library.nutrient.\(row.code).field")

                Text(row.unit)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
    }
}
