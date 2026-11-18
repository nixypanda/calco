import Combine
import SwiftUI

public struct DiaryView: View {
    @ObservedObject private var viewModel: DiaryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isDatePickerPresented = false

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var usesExpandedMacroLabels: Bool {
        usesAccessibilityLayout || horizontalSizeClass != .compact
    }

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
                calendarButton
                refreshButton
                previousButton
                nextButton
            }
        }
        .sheet(isPresented: $isDatePickerPresented) {
            DiaryDatePickerView(
                selection: viewModel.selectedDate,
                today: viewModel.today,
                onSelect: { date in
                    await viewModel.selectDate(date)
                }
            )
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

    private var calendarButton: some View {
        Button {
            isDatePickerPresented = true
        } label: {
            Image(systemName: "calendar")
        }
        .disabled(viewModel.isSessionExpired)
        .accessibilityLabel(String(localized: "diary.calendar"))
        .accessibilityIdentifier("diary.calendar")
        .help(String(localized: "diary.calendar"))
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
            mutationNoticeSection
            ForEach(viewModel.groupedSections) { section in
                Section {
                    if section.logs.isEmpty {
                        Text(String(localized: "diary.slot.empty"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(section.logs) { log in
                            Button {
                                viewModel.openLogEditor(logID: log.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let quantity = log.quantity {
                                        Text(quantity.described)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSessionExpired)
                            .accessibilityElement(children: .combine)
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

                macroModePicker

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

    private var macroModePicker: some View {
        Picker(String(localized: "diary.macroMode.label"), selection: Binding(
            get: { viewModel.macroMode },
            set: { viewModel.setMacroMode($0) }
        )) {
            Text(String(localized: "diary.macroMode.grams")).tag(DiaryMacroDisplayMode.grams)
            Text(String(localized: "diary.macroMode.percent")).tag(DiaryMacroDisplayMode.percent)
        }
        .pickerStyle(.segmented)
        // No accessibilityLabel override: the segmented control supplies its
        // own selected-value semantics for VoiceOver.
        .accessibilityIdentifier("diary.summary.macroMode")
    }

    @ViewBuilder
    private var macroColumns: some View {
        if usesAccessibilityLayout {
            VStack(alignment: .leading, spacing: 12) {
                macroColumn(.protein, progress: viewModel.proteinProgress, identifier: "diary.summary.protein")
                macroColumn(.carbs, progress: viewModel.carbsProgress, identifier: "diary.summary.carbs")
                macroColumn(.fat, progress: viewModel.fatProgress, identifier: "diary.summary.fat")
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                macroColumn(.protein, progress: viewModel.proteinProgress, identifier: "diary.summary.protein")
                macroColumn(.carbs, progress: viewModel.carbsProgress, identifier: "diary.summary.carbs")
                macroColumn(.fat, progress: viewModel.fatProgress, identifier: "diary.summary.fat")
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
        _ kind: DiaryMacroKind,
        progress: DiaryGoalProgress,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(usesExpandedMacroLabels ? kind.fullLabel : kind.shortLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DiaryMacroDisplay.text(for: progress, mode: viewModel.macroMode))
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: usesAccessibilityLayout ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            kind.voiceOverLabel(progress: progress, mode: viewModel.macroMode)
        )
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var mutationNoticeSection: some View {
        if let notice = viewModel.mutationNotice {
            Section {
                HStack(spacing: 10) {
                    Label(notice.message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.clearMutationNotice()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "diary.common.dismiss"))
                    .accessibilityIdentifier("diary.mutationNotice.dismiss")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diary.mutationNotice")
            .accessibilityValue(notice.title)
        }
    }
}
