import SwiftUI

struct NutritionTableRow: Identifiable {
    let id: String
    let name: String
    let amount: String
    let unit: String
}

/// Three independently measured columns, not a trailing-aligned "amount unit" label.
/// The name fills available space, keeping the aligned amount/unit columns trailing.
struct NutritionTable: View {
    let rows: [NutritionTableRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.name)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(DisplayNumberFormat.decimal(row.amount, fixed: true))
                        .monospacedDigit()
                        .fixedSize()
                        .gridColumnAlignment(.trailing)
                        .foregroundStyle(.secondary)
                    Text(row.unit)
                        .fixedSize()
                        .gridColumnAlignment(.leading)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
