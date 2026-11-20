import Combine
import SwiftUI

public struct DiaryView: View {
    @ObservedObject private var viewModel: DiaryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isDatePickerPresented = false

    private let onOpenSettings: () -> Void
    private let onOpenNutrition: (() -> Void)?
    private let onOpenMeals: (() -> Void)?
    private let onOpenLibrary: (() -> Void)?

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    private var usesStackedFeatureLinks: Bool {
        usesAccessibilityLayout || dynamicTypeSize >= .xxxLarge
    }
    private var usesExpandedMacroLabels: Bool {
        usesAccessibilityLayout || horizontalSizeClass != .compact
    }

    public init(
        viewModel: DiaryViewModel,
        onOpenSettings: @escaping () -> Void = {},
        onOpenNutrition: (() -> Void)? = nil,
        onOpenMeals: (() -> Void)? = nil,
        onOpenLibrary: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenSettings = onOpenSettings
        self.onOpenNutrition = onOpenNutrition
        self.onOpenMeals = onOpenMeals
        self.onOpenLibrary = onOpenLibrary
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
            ToolbarItem(placement: settingsPlacement) {
                settingsButton
            }
            ToolbarItemGroup(placement: .primaryAction) {
                calendarButton
                refreshButton
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
        .sheet(item: latestReviewBinding) { review in
            latestReviewSheet(review)
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

    private var settingsPlacement: ToolbarItemPlacement {
#if os(iOS)
        .topBarLeading
#else
        .navigation
#endif
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .disabled(viewModel.isSessionExpired || viewModel.state == .loading)
        .accessibilityLabel(String(localized: "settings.open"))
        .accessibilityIdentifier("diary.settings")
        .help(String(localized: "settings.open"))
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
        VStack(spacing: 0) {
            featureLinksBar
            List {
            summarySection
            refreshErrorSection
            mutationNoticeSection
            latestNoticeSection
            latestErrorSection
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
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSessionExpired)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("diary.log.\(log.id)")
                        }
                    }
                    if let slot = section.slot {
                        if viewModel.canLogLatest(for: slot) {
                            Button {
                                Task { await viewModel.prepareLatest(for: slot) }
                            } label: {
                                if viewModel.latestLoadingSlot == slot {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text(String(localized: "diary.latest.loading"))
                                    }
                                } else {
                                    Label(
                                        String(localized: "diary.latest.button"),
                                        systemImage: "clock.arrow.circlepath"
                                    )
                                }
                            }
                            .disabled(viewModel.latestLoadingSlot != nil)
                            .accessibilityIdentifier("diary.latest.\(slot.rawValue)")
                        }
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
    }

    @ViewBuilder
    private var featureLinksBar: some View {
        if onOpenLibrary != nil || onOpenMeals != nil || onOpenNutrition != nil {
            Group {
                if usesStackedFeatureLinks {
                    VStack(alignment: .leading, spacing: 6) {
                        featureLinkButtons
                    }
                } else {
                    HStack(spacing: 8) {
                        featureLinkButtons
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var featureLinkButtons: some View {
        if let onOpenLibrary {
            Button {
                onOpenLibrary()
            } label: {
                Label(
                    String(localized: "library.title"),
                    systemImage: "books.vertical"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSessionExpired)
            .accessibilityIdentifier("diary.library")
        }
        if let onOpenMeals {
            Button {
                onOpenMeals()
            } label: {
                Label(
                    String(localized: "meals.title"),
                    systemImage: "fork.knife"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSessionExpired)
            .accessibilityIdentifier("diary.meals")
        }
        if let onOpenNutrition {
            Button {
                onOpenNutrition()
            } label: {
                Label(
                    String(localized: "nutrition.title"),
                    systemImage: "chart.bar.doc.horizontal"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isSessionExpired)
            .accessibilityIdentifier("diary.nutrition")
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: usesAccessibilityLayout ? 12 : 8) {
                HStack(spacing: 12) {
                    previousButton
                    Spacer(minLength: 8)
                    Text(viewModel.selectedDate.formatted)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 8)
                    nextButton
                }

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

    @ViewBuilder
    private var latestNoticeSection: some View {
        if let notice = viewModel.latestNotice {
            Section {
                HStack(spacing: 10) {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.dismissLatestNotice()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "diary.common.dismiss"))
                    .accessibilityIdentifier("diary.latestNotice.dismiss")
                }
            }
            .accessibilityIdentifier("diary.latestNotice")
        }
    }

    @ViewBuilder
    private var latestErrorSection: some View {
        if let message = viewModel.latestErrorMessage, viewModel.latestReview == nil {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.dismissLatestError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "diary.common.dismiss"))
                }
            }
            .accessibilityIdentifier("diary.latestError")
        }
    }

    private var latestReviewBinding: Binding<DiaryLatestReview?> {
        Binding(
            get: { viewModel.latestReview },
            set: { value in
                if value == nil {
                    viewModel.cancelLatestReview()
                }
            }
        )
    }

    private func latestReviewSheet(_ review: DiaryLatestReview) -> some View {
        NavigationStack {
            List {
                Section(String(localized: "diary.latest.sourceSection")) {
                    LabeledContent(
                        String(localized: "diary.latest.destination"),
                        value: "\(review.destinationDate.formatted), "
                            + DiaryLabels.mealSlotName(review.destinationSlot)
                    )
                    LabeledContent(
                        String(localized: "diary.latest.source"),
                        value: review.sourceDate.formatted
                    )
                }
                Section(String(localized: "diary.latest.items")) {
                    ForEach(review.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .fixedSize(horizontal: false, vertical: true)
                            if let quantity = item.quantity {
                                Text(quantity.described)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("diary.latest.item.\(item.id)")
                    }
                }
                if let message = viewModel.latestErrorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("diary.latest.error")
                    }
                }
            }
            .navigationTitle(String(localized: "diary.latest.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "diary.latest.cancel")) {
                        viewModel.cancelLatestReview()
                    }
                    .disabled(viewModel.latestIsSubmitting)
                    .accessibilityIdentifier("diary.latest.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewModel.submitLatest()
                    } label: {
                        if viewModel.latestIsSubmitting {
                            ProgressView()
                        } else {
                            Text(String(localized: "diary.latest.confirm"))
                        }
                    }
                    .disabled(viewModel.latestIsSubmitting)
                    .accessibilityIdentifier("diary.latest.submit")
                }
            }
            .interactiveDismissDisabled(viewModel.latestIsSubmitting)
        }
        .accessibilityIdentifier("diary.latest.review")
    }
}
