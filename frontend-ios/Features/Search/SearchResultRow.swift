import SwiftUI

struct SearchResultRow: View {
    let result: FoodSearchResult
    let isSelected: Bool
    let onSelect: () -> Void

    init(
        result: FoodSearchResult,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void
    ) {
        self.result = result
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let brand = result.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !result.categories.isEmpty {
                    Text(result.categories.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.result.\(result.id)")
    }
}
