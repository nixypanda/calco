import Combine
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct DiaryView: View {
    @ObservedObject private var viewModel: DiaryViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDatePickerPresented = false

    /// Native value transitions for the date label and brief figures. Disabled
    /// entirely when the user has Reduce Motion enabled.
    private var valueTransition: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    @ScaledMetric(relativeTo: .largeTitle) private var loggedFontSize: CGFloat = 52
    @ScaledMetric(relativeTo: .title) private var remainingFontSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var dateFontSize: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var macroValueFontSize: CGFloat = 18

    private let onOpenSettings: () -> Void
    private let onOpenNutrition: (() -> Void)?
    private let onOpenMeals: (() -> Void)?
    private let onOpenLibrary: (() -> Void)?

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    /// Existing iOS grouped/secondary semantic fill, reused for the Daily
    /// Brief card and the circular day controls so both read as solid shapes
    /// on the white page. No new palette, stroke style or gradient.
    private var briefSurfaceFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private var usesExpandedMacroLabels: Bool {
        usesAccessibilityLayout || horizontalSizeClass != .compact
    }

    /// Locale-grouped whole-number display for the brief's hero figures.
    /// Non-finite values still fall through the existing safe formatter.
    private func briefNumber(_ value: Double) -> String {
        guard value.isFinite else { return DiaryValueFormat.amount(value) }
        return Int64(value.rounded()).formatted(.number)
    }

    private var compactDateTitle: String {
        if let date = DiaryDateConversion.date(from: viewModel.selectedDate) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return viewModel.selectedDate.formatted
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
        .navigationTitle("")
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

    private var nextDayDisabled: Bool {
        !viewModel.canGoNext || viewModel.isSessionExpired
    }

    private var previousButton: some View {
        Button {
            Task { await viewModel.previousDay() }
        } label: {
            Image(systemName: "arrow.left")
                .frame(minWidth: 44, minHeight: 44)
                .background(Circle().fill(briefSurfaceFill))
                .contentShape(Rectangle())
        }
        .disabled(viewModel.isSessionExpired)
        .opacity(viewModel.isSessionExpired ? 0.4 : 1)
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
                .background(Circle().fill(briefSurfaceFill))
                .contentShape(Rectangle())
        }
        .disabled(nextDayDisabled)
        .opacity(nextDayDisabled ? 0.4 : 1)
        .accessibilityLabel(String(localized: "diary.nextDay"))
        .accessibilityIdentifier("diary.nextDay")
        .help(String(localized: "diary.nextDay"))
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
        ScrollView {
            VStack(spacing: 16) {
                dateNavigationRow
                summaryCard
                if let message = viewModel.errorMessage {
                    noticeRow(message, systemImage: "exclamationmark.triangle", color: .secondary, rowID: "diary.refreshError", dismissID: nil, dismiss: nil)
                        .accessibilityIdentifier("diary.refreshError")
                }
                if let notice = viewModel.mutationNotice {
                    noticeRow(notice.message, systemImage: "checkmark.circle.fill", color: .green, rowID: "diary.mutationNotice", dismissID: "diary.mutationNotice.dismiss") {
                        viewModel.clearMutationNotice()
                    }
                    .accessibilityValue(notice.title)
                }
                if let message = viewModel.latestErrorMessage, viewModel.latestReview == nil {
                    noticeRow(message, systemImage: "exclamationmark.triangle", color: .red, rowID: "diary.latestError", dismissID: "diary.latestError.dismiss") {
                        viewModel.dismissLatestError()
                    }
                }
                manageMealSlotsRow
                ForEach(viewModel.groupedSections) { section in
                    mealCard(section)
                }
            }
            .padding(16)
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    /// The day controls stay above the Daily Brief card: the same two 44x44
    /// day buttons and the single date trigger opening the existing picker.
    /// The date updates on the tap frame; only the disclosure glyph swaps to a
    /// spinner (same fixed footprint, so there is no layout jump) while the
    /// fetch is in flight. The brief and meal cards stay mounted throughout.
    private var dateNavigationRow: some View {
        Group {
            if usesAccessibilityLayout {
                VStack(spacing: 8) {
                    dateButton
                        .frame(maxWidth: .infinity)
                    HStack {
                        previousButton
                        Spacer(minLength: 12)
                        nextButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    previousButton
                    Spacer(minLength: 8)
                    dateButton
                    Spacer(minLength: 8)
                    nextButton
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diary.dateNavigation")
    }

    private var dateButton: some View {
        Button {
            isDatePickerPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedDate == viewModel.today
                     ? String(localized: "diary.today")
                     : compactDateTitle)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.isChangingDate {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14, height: 14)
                }
            }
            .font(.system(size: dateFontSize, weight: .bold))
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .animation(valueTransition, value: viewModel.selectedDate)
        .animation(valueTransition, value: viewModel.isChangingDate)
        .disabled(viewModel.isSessionExpired)
        .accessibilityIdentifier("diary.calendar")
    }

    /// Separate right-aligned row before the meal cards. It is not tied to a
    /// particular slot, so custom/enabled slot sets keep working unchanged.
    private var manageMealSlotsRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                onOpenSettings()
            } label: {
                Text(String(localized: "diary.manageSlots"))
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSessionExpired)
            .accessibilityIdentifier("diary.manageSlots")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            calorieBrief
            Divider()
            macroBrief
            Divider()
            cardActions

            #if CALCO_TEST
            Text("\(viewModel.completedFetchCount)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("diary.fetchCompletionCount")
                .accessibilityValue("\(viewModel.completedFetchCount)")
            #endif
        }
        .padding(16)
        .background(briefSurfaceFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Daily Brief

    private var calorieBrief: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = usesAccessibilityLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(briefNumber(viewModel.calorieProgress.current))
                        .font(.system(size: loggedFontSize, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .animation(valueTransition, value: viewModel.calorieProgress.current)
                    Text(String(localized: "diary.brief.kcalLogged"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !usesAccessibilityLayout { Spacer(minLength: 8) }
                remainingView
            }

            if let fraction = viewModel.calorieProgress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(
                        BriefCapsuleProgressStyle(
                            fraction: fraction,
                            color: isOverGoal ? Color.red : Color.accentColor,
                            height: 10
                        )
                    )
                    .accessibilityIdentifier("diary.summary.progress")
            }
            if let target = viewModel.calorieProgress.targetText {
                Text(String(format: String(localized: "diary.brief.ofGoal"), target))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diary.summary.calories")
    }

    private var isOverGoal: Bool {
        let progress = viewModel.calorieProgress
        return progress.hasTarget && progress.current > progress.target
    }

    /// The reference puts the signed delta's magnitude in a bold figure and
    /// its meaning in a quiet caption. No combined sentence, no blue pill.
    private var remainingView: some View {
        VStack(alignment: usesAccessibilityLayout ? .leading : .trailing, spacing: 2) {
            if viewModel.calorieProgress.hasTarget {
                Text(remainingNumberText)
                    .font(.system(size: remainingFontSize, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .animation(valueTransition, value: viewModel.calorieProgress.current)
                Text(remainingCaptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diary.summary.remaining")
    }

    private var calorieDifference: Double? {
        let progress = viewModel.calorieProgress
        guard progress.hasTarget else { return nil }
        let difference = progress.target - progress.current
        return difference.isFinite ? difference : nil
    }

    private var remainingNumberText: String {
        guard let calorieDifference else { return "—" }
        return briefNumber(abs(calorieDifference))
    }

    private var remainingCaptionText: String {
        guard let calorieDifference else {
            return String(localized: "diary.brief.remaining")
        }
        if calorieDifference > 0 { return String(localized: "diary.brief.remaining") }
        if calorieDifference < 0 { return String(localized: "diary.brief.overGoal") }
        return String(localized: "diary.brief.onTarget")
    }

    private var macroBrief: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                macroControlsRow
            }
            if usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 12) {
                    macroColumns
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    macroColumns
                }
            }
        }
    }

    @ViewBuilder
    private var macroColumns: some View {
        macroColumn(.protein, progress: viewModel.proteinProgress, identifier: "diary.summary.protein")
        macroColumn(.carbs, progress: viewModel.carbsProgress, identifier: "diary.summary.carbs")
        macroColumn(.fat, progress: viewModel.fatProgress, identifier: "diary.summary.fat")
    }

    private var cardActions: some View {
        let layout = usesAccessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Button {
                onOpenSettings()
            } label: {
                Text(String(localized: "diary.editGoals"))
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSessionExpired)
            .accessibilityIdentifier("diary.editGoals")

            if !usesAccessibilityLayout { Spacer(minLength: 8) }
            nutritionButton
        }
    }

    /// Only the small Grams/Percent selector remains here. The nutrition
    /// action moved to the card's bottom action row and there is no "Macros"
    /// heading above the three columns.
    private var macroControlsRow: some View {
        macroModeMenu
    }

    @ViewBuilder
    private var nutritionButton: some View {
        if let onOpenNutrition {
            Button {
                onOpenNutrition()
            } label: {
                HStack(spacing: 4) {
                    Text(String(localized: "nutrition.title"))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSessionExpired || viewModel.isChangingDate)
            .accessibilityIdentifier("diary.nutrition")
        }
    }

    private var macroModeMenu: some View {
        Menu {
            Button {
                viewModel.setMacroMode(.grams)
            } label: {
                Label(String(localized: "diary.macroMode.grams"), systemImage: viewModel.macroMode == .grams ? "checkmark" : "")
            }
            Button {
                viewModel.setMacroMode(.percent)
            } label: {
                Label(String(localized: "diary.macroMode.percent"), systemImage: viewModel.macroMode == .percent ? "checkmark" : "")
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.macroMode == .grams
                     ? String(localized: "diary.macroMode.grams")
                     : String(localized: "diary.macroMode.percent"))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("diary.summary.macroMode")
    }

    private func macroCurrentText(_ progress: DiaryGoalProgress) -> String {
        switch viewModel.macroMode {
        case .grams:
            return briefNumber(progress.current)
        case .percent:
            return DiaryMacroDisplay.text(for: progress, mode: .percent)
        }
    }

    private func macroTargetText(_ progress: DiaryGoalProgress) -> String {
        guard viewModel.macroMode == .grams, progress.hasTarget else { return "" }
        return " / \(briefNumber(progress.target)) g"
    }

    private func macroColumn(
        _ kind: DiaryMacroKind,
        progress: DiaryGoalProgress,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.fullLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(macroCurrentText(progress))
                    .font(.system(size: macroValueFontSize, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(macroTargetText(progress))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(
                        BriefCapsuleProgressStyle(
                            fraction: fraction,
                            color: macroColor(kind),
                            height: 7
                        )
                    )
                    .accessibilityLabel(
                        kind.voiceOverLabel(progress: progress, mode: viewModel.macroMode)
                    )
            }
        }
        .frame(maxWidth: usesAccessibilityLayout ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            kind.voiceOverLabel(progress: progress, mode: viewModel.macroMode)
        )
        .accessibilityIdentifier(identifier)
    }

    private func noticeRow(_ message: String, systemImage: String, color: Color, rowID: String?, dismissID: String?, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(color)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(rowID ?? "")
            Spacer(minLength: 8)
            if let dismiss, let dismissID {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "diary.common.dismiss"))
                .accessibilityIdentifier(dismissID)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func mealCard(_ section: DiarySection) -> some View {
        VStack(spacing: 0) {
            if let slot = section.slot {
                MealArtHeader(slot: slot, title: DiaryLabels.mealSlotName(slot), calories: sectionCalories(section))
            } else {
                HStack {
                    Text(String(localized: "diary.unslotted"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(caloriesText(sectionCalories(section)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .padding(16)
                .background(.regularMaterial, in: Rectangle())
            }

            VStack(alignment: .leading, spacing: 8) {
                if section.logs.isEmpty {
                    if let slot = section.slot, viewModel.canLogLatest(for: slot) {
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
                        .disabled(
                            viewModel.latestLoadingSlot != nil
                                || viewModel.isChangingDate
                                || viewModel.isSessionExpired
                        )
                        .accessibilityIdentifier("diary.latest.\(slot.rawValue)")
                        .frame(minHeight: 44, alignment: .leading)
                    } else {
                        Text(String(localized: "diary.slot.empty"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                } else {
                    ForEach(section.logs) { log in
                        Button {
                            viewModel.openLogEditor(logID: log.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.title)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let quantity = log.quantity {
                                        Text(quantity.described)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(caloriesText(log.calories))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSessionExpired || viewModel.isChangingDate)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("diary.log.\(log.id)")
                    }
                }

                if let slot = section.slot {
                    Divider()
                    Button(String(localized: "diary.addFood")) {
                        viewModel.addFood(for: slot)
                    }
                    .disabled(viewModel.isSessionExpired || viewModel.isChangingDate)
                    .accessibilityLabel(DiaryLabels.addFood(for: slot))
                    .accessibilityIdentifier("diary.addFood.\(slot.rawValue)")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func sectionCalories(_ section: DiarySection) -> Double {
        section.logs.reduce(0) { $0 + $1.calories }
    }

    private func caloriesText(_ value: Double) -> String {
        "\(DiaryValueFormat.amount(value)) kcal"
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
                    .accessibilityIdentifier("diary.latest.review")
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
    }
}



private func macroColor(_ kind: DiaryMacroKind) -> Color {
    switch kind {
    case .protein: return .pink
    case .carbs: return .blue
    case .fat: return .yellow
    }
}

// Pairs a compact horizontal row with a full-width vertical fallback. At
// accessibility text sizes the vertical branch is always used so labels stay
// readable as whole words; otherwise ViewThatFits keeps the original horizontal
// row whenever its intrinsic text fits, leaving the default layout untouched.
//
// Each horizontal-branch child is pinned to its one-line intrinsic width with
// .fixedSize(horizontal: true, vertical: false). Without that, wrapping/compressing
// text lets the HStack "fit" at any width, so ViewThatFits would never reach the
// vertical fallback at narrow widths, long locales or large non-AX text. The
// Spacer still expands to fill the row when the horizontal branch is chosen,
// so the default side-by-side layout is unchanged.
/// Passive native progress styling: a thick rounded track and fill instead of
/// the platform's ~2pt linear bar. `ProgressView` keeps its value/label
/// accessibility; the style only draws the geometry, with no interaction.
private struct BriefCapsuleProgressStyle: ProgressViewStyle {
    let fraction: Double
    let color: Color
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: height)
    }
}

private struct AdaptiveLabeledRow<Horizontal: View, Vertical: View>: View {
    let accessibilityLayout: Bool
    let horizontal: Horizontal
    let vertical: Vertical

    init(
        _ accessibilityLayout: Bool,
        @ViewBuilder horizontal: () -> Horizontal,
        @ViewBuilder vertical: () -> Vertical
    ) {
        self.accessibilityLayout = accessibilityLayout
        self.horizontal = horizontal()
        self.vertical = vertical()
    }

    var body: some View {
        if accessibilityLayout {
            vertical
        } else {
            ViewThatFits(in: .horizontal) {
                horizontal
                vertical
            }
        }
    }
}

private struct MealArtHeader: View {
    let slot: MealSlot
    let title: String
    let calories: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var assetName: String {
        switch slot {
        case .breakfast: return "breakfast"
        case .lunch: return "lunch"
        case .dinner: return "dinner"
        case .snack: return "snacks"
        case .lateNightSnack: return "late-night-snack"
        }
    }

    private var imageAspect: CGFloat {
        switch slot {
        case .breakfast: return 3432.0 / 364.0
        case .lunch: return 3432.0 / 382.0
        case .dinner: return 3432.0 / 380.0
        case .snack: return 3434.0 / 374.0
        case .lateNightSnack: return 3432.0 / 382.0
        }
    }

    private var focusX: CGFloat {
        switch slot {
        case .breakfast: return 0.13
        case .lunch: return 0.50
        case .dinner: return 0.47
        case .snack: return 0.82
        case .lateNightSnack: return 0.73
        }
    }

    private var caloriesText: String {
        "\(DiaryValueFormat.amount(calories)) kcal"
    }

    var body: some View {
        AdaptiveLabeledRow(
            usesAccessibilityLayout,
            horizontal: {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    Text(caloriesText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            },
            vertical: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(caloriesText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 80)
        .background {
            artBackground
        }
        .clipped()
    }

    // One continuous, clipped artwork surface covering the entire header,
    // sized at the asset's true aspect ratio and large enough to cover BOTH
    // container axes: on wide iPad columns width dominates, on accessibility-
    // tall headers height dominates. No letterboxing, stretching or tiling.
    private var artBackground: some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            let containerHeight = geo.size.height
            let renderedWidth = max(containerWidth, containerHeight * imageAspect)
            let renderedHeight = renderedWidth / imageAspect
            // Bring the web focus point toward the horizontal centre, then pin
            // the leading edge into [containerWidth - renderedWidth, 0] so the
            // art always spans the full width with no uncovered band.
            let focusedLeading = containerWidth / 2 - focusX * renderedWidth
            let leadingOffset = min(0, max(focusedLeading, containerWidth - renderedWidth))
            let verticalOffset = (containerHeight - renderedHeight) / 2

            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: renderedWidth, height: renderedHeight)
                .offset(x: leadingOffset, y: verticalOffset)
                .frame(width: containerWidth, height: containerHeight, alignment: .topLeading)
                .clipped()
                .overlay {
                    // The white title/total are vertically centred in the
                    // header, above the old bottom-only scrim (~0.27 opacity at
                    // the text, fading to 0 at the top). On bright breakfast /
                    // lunch skies that leaves white-on-light text with weak
                    // contrast, and the full-width cover can place the total
                    // over open sky. Keep a continuous gradient with a ~0.35
                    // floor so the whole text band is legible while the art
                    // (sun, clouds, hills) stays clearly identifiable: no
                    // faux panel, no band, no extra rounding.
                    LinearGradient(
                        colors: [.black.opacity(0.55), .black.opacity(0.35)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .allowsHitTesting(false)
                }
        }
    }
}
