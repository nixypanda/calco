// Reusable nutrient editor used by custom-food create/edit and ad-hoc logging.

import SwiftUI

public struct NutrientEditorView: View {
    @FocusState private var focusedNutrient: String?
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                nutrientLabel(row)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                amountField(row)
                    .frame(width: 96)
            }
            VStack(alignment: .leading, spacing: 8) {
                nutrientLabel(row)
                amountField(row)
            }
        }
#if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !row.isRequired && !isDisabled {
                Button(role: .destructive) {
                    onRemove(row.code)
                } label: {
                    Label(
                        String(format: String(localized: "library.nutrient.remove"), row.name),
                        systemImage: "trash"
                    )
                }
                .labelStyle(.iconOnly)
                .tint(.red)
                .accessibilityIdentifier("library.nutrient.\(row.code).remove")
            }
        }
#endif
    }

    private func nutrientLabel(_ row: NutrientEditorRow) -> some View {
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
#if os(macOS)
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
#endif
        }
    }

    private func amountField(_ row: NutrientEditorRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField(
                "0",
                text: Binding(
                    get: {
                        guard focusedNutrient != row.code, !row.amount.isEmpty else {
                            return row.amount
                        }
                        let formatted = DisplayNumberFormat.decimal(row.amount)
                        return formatted == "—" ? row.amount : formatted
                    },
                    set: { onAmountChange($0, row.code) }
                )
            )
#if os(iOS)
            .keyboardType(.decimalPad)
#endif
            .multilineTextAlignment(.trailing)
            .focused($focusedNutrient, equals: row.code)
            .disabled(isDisabled)
            .accessibilityLabel("\(row.name), \(row.unit)")
            .accessibilityIdentifier("library.nutrient.\(row.code).field")

            Text(row.unit)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
