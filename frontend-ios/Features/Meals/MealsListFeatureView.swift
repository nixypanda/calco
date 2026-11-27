
import ComposableArchitecture
import SwiftUI

public struct MealsListFeatureView: View {
    @Bindable private var store: StoreOf<MealsListFeature>
    private let showsAddButton: Bool

    public init(store: StoreOf<MealsListFeature>, showsAddButton: Bool = true) {
        self.store = store
        self.showsAddButton = showsAddButton
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                ProgressView(String(localized: "meals.list.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                failedView(message)
            case .loaded(let meals), .refreshing(previous: let meals):
                if meals.isEmpty {
                    emptyView
                } else {
                    mealList(meals)
                }
            }
        }
        .navigationTitle("My Meals")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
        .toolbar {
            if showsAddButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.send(.createMeal)
                    } label: {
                        Label(
                            String(localized: "meals.list.add"),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("meals.list.add")
                }
            }
        }
        .task { store.send(.onAppear) }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(String(localized: "meals.list.empty.title"), systemImage: "fork.knife")
        } description: {
            Text(String(localized: "meals.list.empty.message"))
        } actions: {
            Button {
                store.send(.createMeal)
            } label: {
                Text(String(localized: "meals.list.add"))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("meals.list.empty.add")
        }
        .accessibilityIdentifier("meals.list.empty")
    }

    private func failedView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

                Button {
                    store.send(.refresh)
                } label: {
                    Text(String(localized: "meals.list.retry"))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("meals.list.retry")

                Button {
                    store.send(.createMeal)
                } label: {
                    Text(String(localized: "meals.list.add"))
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 480)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 320)
        }
        .accessibilityIdentifier("meals.list.error")
    }

    private func mealList(_ meals: [Meal]) -> some View {
        List {
            if let message = store.quickAddMessage {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Label {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.circle")
                        }
                        .font(.footnote)
                        Spacer(minLength: 8)
                        Button {
                            store.send(.dismissQuickAddMessage)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "meals.common.dismiss"))
                    }
                    .accessibilityIdentifier("meals.list.quickAdd.message")
                }
            }

            if let message = store.transientError {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Label {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                        Spacer(minLength: 8)
                        Button(String(localized: "meals.list.retry")) {
                            store.send(.refresh)
                        }
                        .font(.footnote)
                    }
                    .accessibilityIdentifier("meals.list.refreshError")
                }
            }

            Section {
                ForEach(meals) { meal in
                    mealRow(meal)
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
#else
        .listStyle(.inset)
#endif
        .refreshable { store.send(.refresh) }
        .overlay(alignment: .top) {
            if store.phase.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("meals.list")
    }

    private func mealRow(_ meal: Meal) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                store.send(.openMeal(meal))
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meal.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let details = rowDetails(meal) {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if meal.isDegraded {
                            Label(
                                String(localized: "meals.list.missing"),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("meals.list.missing.\(meal.id)")
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meals.list.row.\(meal.id)")
            .accessibilityHint(String(localized: "meals.list.openHint"))

            if store.withState({ $0.canQuickAdd(meal) }) {
                Button {
                    store.send(.quickAdd(mealID: meal.id, portion: nil))
                } label: {
                    if case .submitting(let mealID) = store.quickAddState,
                       mealID == meal.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.title3)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    String(format: String(localized: "meals.list.quickAdd.a11y"), meal.name)
                )
                .accessibilityIdentifier("meals.list.quickAdd.\(meal.id)")
                .disabled(store.quickAddMessage != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func rowDetails(_ meal: Meal) -> String? {
        var parts: [String] = []
        if let total = MealNutrientDisplay.quantity(meal.totalQuantity) { parts.append(total) }
        if let kcal = MealNutrientDisplay.kcal(meal.nutritionSummary) { parts.append(kcal) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
