// Read-only daily nutrition report. Layout follows the web's report order:
// coverage notice, overview tiles, nutrient sections, then reference context.
// The view is usable in a navigation stack, split-view detail, or sheet; the
// owner supplies the selected day and handles session expiry.

import SwiftUI

public struct NutritionDetailsView: View {
    @ObservedObject private var viewModel: NutritionDetailsViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var unitColumnWidth = 44

    public init(viewModel: NutritionDetailsViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
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
        .task {
            await viewModel.loadIfNeeded()
        }
        .accessibilityIdentifier("nutrition.details")
    }

    // MARK: - States

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .loading:
            loadingView
        case .loaded(let report):
            reportView(report)
        case .failed(let message):
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
                Task { await viewModel.retry() }
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

    // MARK: - Report

    private func reportView(_ report: NutritionDetailsReport) -> some View {
        NutritionDetailsReportView(
            report: report,
            expandedCodes: viewModel.expandedNutrientCodes,
            onToggle: viewModel.toggleGuidance
        )
    }
}
