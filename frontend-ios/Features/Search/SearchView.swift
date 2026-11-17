import SwiftUI

public struct SearchView: View {
    @ObservedObject private var viewModel: SearchViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(viewModel: SearchViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
        .navigationTitle(String(localized: "search.title"))
        .onAppear {
            viewModel.clearSelection()
        }
        .toolbar {
            if !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button(String(localized: "search.clear")) {
                        viewModel.clearQuery()
                    }
                    .accessibilityIdentifier("search.clear")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "search.prompt"), text: searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .submitLabel(.search)
                .onSubmit { viewModel.submitSearch() }
                .accessibilityIdentifier("search.field")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var searchText: Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { viewModel.queryChanged($0) }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            idleView
        case .loading:
            loadingView
        case .loaded(let loaded):
            resultsView(loaded.items)
        case .empty:
            emptyView
        case .failed(let message):
            errorView(message: message)
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "search.empty.prompt"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityIdentifier("search.idle")
    }

    private var loadingView: some View {
        VStack(spacing: usesAccessibilityLayout ? 12 : 8) {
            ProgressView()
            Text(String(localized: "search.loading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.loading")
    }

    private func resultsView(_ items: [FoodSearchResult]) -> some View {
        List(items) { result in
            Button {
                viewModel.selectResult(result)
            } label: {
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
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .listRowSeparator(.visible)
            .accessibilityIdentifier("search.result.\(result.id)")
        }
        .listStyle(.plain)
        .accessibilityIdentifier("search.results")
    }

    private var emptyView: some View {
        VStack(spacing: usesAccessibilityLayout ? 12 : 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "search.empty.noResults"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.empty")
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: usesAccessibilityLayout ? 16 : 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "search.retry")) {
                viewModel.retry()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("search.retry")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("search.error")
    }
}
