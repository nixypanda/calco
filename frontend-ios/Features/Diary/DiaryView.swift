import Combine
import SwiftUI

public struct DiaryView: View {
    @ObservedObject private var viewModel: DiaryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    public init(viewModel: DiaryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                loadingView
            case .failed(let message):
                errorView(message: message)
            case .sessionExpired:
                sessionExpiredView
            case .loaded:
                contentView
            }
        }
        .navigationTitle(viewModel.selectedDate.diaryDisplayTitle())
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                refreshButton
                previousButton
                nextButton
            }
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await viewModel.refreshToday() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            Task { await viewModel.refreshToday() }
        }
    }


    private var previousButton: some View {
        Button {
            Task { await viewModel.previousDay() }
        } label: {
            Image(systemName: "arrow.left")
        }
        .disabled(viewModel.isSessionExpired)
        .accessibilityLabel(String(localized: "diary.previousDay"))
        .accessibilityIdentifier("diary.previousDay")
        .help(String(localized: "diary.previousDay"))
    }

    private var nextButton: some View {
        Button {
            Task { await viewModel.nextDay() }
        } label: {
            Image(systemName: "arrow.right")
        }
        .disabled(!viewModel.canGoNext || viewModel.isSessionExpired)
        .accessibilityLabel(String(localized: "diary.nextDay"))
        .accessibilityIdentifier("diary.nextDay")
        .help(String(localized: "diary.nextDay"))
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            if viewModel.isRefreshing {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(
            viewModel.isRefreshing
                || viewModel.state == .loading
                || viewModel.isSessionExpired
        )
        .accessibilityLabel(String(localized: "diary.refresh"))
        .accessibilityIdentifier("diary.refresh")
        .help(String(localized: "diary.refresh"))
    }


    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "diary.loading"))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("diary.loading")
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button(String(localized: "diary.retry")) {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("diary.retry")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("diary.error")
    }

    private var sessionExpiredView: some View {
        ContentUnavailableView {
            Label(
                String(localized: "diary.sessionExpired.title"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(String(localized: "diary.error.sessionExpired"))
        }
        .accessibilityIdentifier("diary.sessionExpired")
    }

    private var contentView: some View {
        List {
            summarySection
            refreshErrorSection
            ForEach(viewModel.groupedSections) { section in
                Section {
                    if section.logs.isEmpty {
                        Text(String(localized: "diary.slot.empty"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(section.logs) { log in
                            Text(log.title)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("diary.log.\(log.id)")
                        }
                    }
                    if let slot = section.slot {
                        Button(String(localized: "diary.addFood")) {
                            viewModel.addFood(for: slot)
                        }
                        .accessibilityLabel(DiaryLabels.addFood(for: slot))
                        .accessibilityIdentifier("diary.addFood.\(slot.rawValue)")
                    }
                } header: {
                    if let slot = section.slot {
                        Text(DiaryLabels.mealSlotName(slot))
                    } else {
                        Text(String(localized: "diary.unslotted"))
                    }
                }
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: usesAccessibilityLayout ? 12 : 8) {
                caloriesSummary

                if let fraction = viewModel.calorieProgress.fraction {
                    ProgressView(value: fraction)
                        .accessibilityIdentifier("diary.summary.progress")
                }

                Text(String(localized: "diary.macros"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                macroColumns

                #if CALCO_TEST
                fetchCompletionMarker
                #endif
            }
            .padding(.vertical, 2)
        }
    }

    #if CALCO_TEST
    private var fetchCompletionMarker: some View {
        Text("\(viewModel.completedFetchCount)")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("diary.fetchCompletionCount")
            .accessibilityValue("\(viewModel.completedFetchCount)")
    }
    #endif

    @ViewBuilder
    private var caloriesSummary: some View {
        let label = Text(String(localized: "diary.calories"))
            .font(.headline)
            .fixedSize(horizontal: true, vertical: false)
        let value = Text(viewModel.calorieProgress.summary)
            .font(.title3.weight(.semibold))
            .monospacedDigit()

        Group {
            if usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 4) {
                    label
                    value
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label
                    Spacer(minLength: 8)
                    value
                }
            }
        }
        .accessibilityIdentifier("diary.summary.calories")
    }

    @ViewBuilder
    private var macroColumns: some View {
        if usesAccessibilityLayout {
            VStack(alignment: .leading, spacing: 12) {
                macroColumn("P", progress: viewModel.proteinProgress, identifier: "diary.summary.protein")
                macroColumn("C", progress: viewModel.carbsProgress, identifier: "diary.summary.carbs")
                macroColumn("F", progress: viewModel.fatProgress, identifier: "diary.summary.fat")
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                macroColumn("P", progress: viewModel.proteinProgress, identifier: "diary.summary.protein")
                macroColumn("C", progress: viewModel.carbsProgress, identifier: "diary.summary.carbs")
                macroColumn("F", progress: viewModel.fatProgress, identifier: "diary.summary.fat")
            }
        }
    }

    @ViewBuilder
    private var refreshErrorSection: some View {
        if let message = viewModel.errorMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("diary.refreshError")
            }
        }
    }

    private func macroColumn(
        _ label: String,
        progress: DiaryGoalProgress,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(progress.summary) g")
                .font(.subheadline)
                .monospacedDigit()
        }
        .frame(maxWidth: usesAccessibilityLayout ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
