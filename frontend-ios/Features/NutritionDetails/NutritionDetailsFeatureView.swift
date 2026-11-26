import ComposableArchitecture
import SwiftUI

public struct NutritionDetailsFeatureView: View {
    @Bindable var store: StoreOf<NutritionDetailsFeature>

    public init(store: StoreOf<NutritionDetailsFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stateContent
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationTitle(NutritionDetailsCopy.title)
        .onAppear {
            store.send(.loadIfNeeded)
        }
        .accessibilityIdentifier("nutrition.details")
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.phase {
        case .idle, .loading:
            loadingView
        case .loaded(let report, _):
            NutritionDetailsReportView(
                report: report,
                expandedCodes: store.expandedNutrientCodes,
                onToggle: { store.send(.toggleGuidance($0)) }
            )
        case .failed(_, let message, _):
            failureView(message)
        case .sessionExpired:
            sessionExpiredView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(NutritionDetailsCopy.loading)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityIdentifier("nutrition.loading")
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.red)
            Button(NutritionDetailsCopy.retry) {
                store.send(.retry)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("nutrition.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .accessibilityIdentifier("nutrition.error")
    }

    private var sessionExpiredView: some View {
        ContentUnavailableView {
            Label(
                NutritionDetailsCopy.sessionExpiredTitle,
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(NutritionDetailsCopy.sessionExpiredMessage)
        }
        .accessibilityIdentifier("nutrition.sessionExpired")
    }

}
