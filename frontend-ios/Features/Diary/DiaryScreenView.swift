import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import ComposableArchitecture

public struct DiaryScreenView: View {
    private let store: StoreOf<DiaryScreenFeature>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDatePickerPresented = false

    private let onOpenSettings: () -> Void
    private let onOpenNutrition: (() -> Void)?

    private var valueTransition: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }

    @ScaledMetric(relativeTo: .largeTitle) private var loggedFontSize: CGFloat = 52
    @ScaledMetric(relativeTo: .title) private var remainingFontSize: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var dateFontSize: CGFloat = 21
    @ScaledMetric(relativeTo: .body) private var macroValueFontSize: CGFloat = 18

    private var usesAccessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }

    private var briefSurfaceFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func briefNumber(_ value: Double) -> String {
        guard value.isFinite else { return DiaryValueFormat.amount(value) }
        return Int64(value.rounded()).formatted(.number)
    }

    private var compactDateTitle: String {
        if let date = DiaryDateConversion.date(from: store.diary.selectedDate) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return store.diary.selectedDate.formatted
    }

    public init(
        store: StoreOf<DiaryScreenFeature>,
        onOpenSettings: @escaping () -> Void = {},
        onOpenNutrition: (() -> Void)? = nil
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenNutrition = onOpenNutrition
    }

    private var diary: DiaryFeature.State { store.diary }
    private var latest: DiaryLatestFeature.State { store.latest }
    private var phase: DiaryFeature.Phase { diary.phase }
    private var visibleDay: DiaryDay? { diary.visibleDay }

    private var isChangingDate: Bool {
        if case .loaded(_, .changingDate) = phase { true } else { false }
    }

    private var refreshErrorMessage: String? {
        if case .loaded(_, .failure(_, _, let message)) = phase { message } else { nil }
    }

    private var displayedLatestError: String? {
        latest.copyErrorMessage ?? latest.errorMessage
    }

    private var isOverGoal: Bool {
        let progress = calorieProgress
        return progress.hasTarget && progress.current > progress.target
    }

    private var calorieProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalCalories, target: visibleDay?.goal.calorieTarget ?? 0)
    }

    private var proteinProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalProteinG, target: visibleDay?.goal.proteinTargetG ?? 0)
    }

    private var carbsProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalCarbsG, target: visibleDay?.goal.carbsTargetG ?? 0)
    }

    private var fatProgress: DiaryGoalProgress {
        DiaryGoalProgress(current: totalFatG, target: visibleDay?.goal.fatTargetG ?? 0)
    }

    private var totalCalories: Double { visibleDay?.logs.reduce(0) { $0 + $1.calories } ?? 0 }
    private var totalProteinG: Double { visibleDay?.logs.reduce(0) { $0 + $1.proteinG } ?? 0 }
    private var totalCarbsG: Double { visibleDay?.logs.reduce(0) { $0 + $1.carbsG } ?? 0 }
    private var totalFatG: Double { visibleDay?.logs.reduce(0) { $0 + $1.fatG } ?? 0 }

    private var groupedSections: [DiarySection] {
        guard let day = visibleDay else { return [] }
        var sections: [DiarySection] = []
        for slot in MealSlot.allCases {
            let slotLogs = day.logs.filter { $0.mealSlot == slot }
            if day.prefs.isEnabled(slot) || !slotLogs.isEmpty {
                sections.append(DiarySection(id: slot.rawValue, slot: slot, logs: slotLogs))
            }
        }
        let unslotted = day.logs.filter { $0.mealSlot == nil }
        if !unslotted.isEmpty {
            sections.append(DiarySection(id: "unslotted", slot: nil, logs: unslotted))
        }
        return sections
    }

    private func canLogLatest(for slot: MealSlot) -> Bool {
        guard !diary.isSessionExpired,
              !isChangingDate,
              (visibleDay?.prefs.isEnabled(slot) ?? true) else { return false }
        guard let day = visibleDay else { return false }
        return !day.logs.contains { $0.mealSlot == slot }
    }

    private var latestReviewBinding: Binding<DiaryLatestReview?> {
        Binding(
            get: { latest.review },
            set: { value in
                if value == nil, !latest.isSubmitting {
                    store.send(.latest(.cancelLatestReview))
                }
            }
        )
    }

    public var body: some View {
        Group {
            switch phase {
            case .initialLoading, .idle:
                loadingView
            case .initialFailed(_, _, let message):
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
                selection: diary.selectedDate,
                today: diary.today,
                onSelect: { date in
                    await store.send(.diary(.selectDate(date))).finish()
                }
            )
        }
        .sheet(item: latestReviewBinding) { review in
            latestReviewSheet(review)
        }
        .task {
            store.send(.diary(.loadIfNeeded))
        }
        // Foreground and calendar-day refresh are owned by the root/Window feed
        // (AppFeature scene phase + WindowFeature.todayChanged). This view must
        // not send its own foregroundRefresh: a second root-owned refresh would
        // double-fetch the visible day.
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
                store.send(.diary(.retry))
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
                if let message = refreshErrorMessage {
                    noticeRow(message, systemImage: "exclamationmark.triangle", color: .secondary, rowID: "diary.refreshError", dismissID: nil, dismiss: nil)
                        .accessibilityIdentifier("diary.refreshError")
                }
                if let notice = diary.mutationNotice {
                    noticeRow(notice.message, systemImage: "checkmark.circle.fill", color: .green, rowID: "diary.mutationNotice", dismissID: "diary.mutationNotice.dismiss") {
                        store.send(.diary(.clearMutationNotice))
                    }
                    .accessibilityValue(notice.title)
                }
                if let message = displayedLatestError, latest.review == nil {
                    noticeRow(message, systemImage: "exclamationmark.triangle", color: .red, rowID: "diary.latestError", dismissID: "diary.latestError.dismiss") {
                        if latest.copyErrorMessage != nil {
                            store.send(.latest(.dismissCopyError))
                        } else {
                            store.send(.latest(.dismissLatestError))
                        }
                    }
                }
                manageMealSlotsRow
                ForEach(groupedSections) { section in
                    mealCard(section)
                }
            }
            .padding(16)
        }
        .refreshable {
            await store.send(.diary(.refresh)).finish()
        }
    }

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
                Text(diary.selectedDate == diary.today
                     ? String(localized: "diary.today")
                     : compactDateTitle)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                if isChangingDate {
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
        .animation(valueTransition, value: diary.selectedDate)
        .animation(valueTransition, value: isChangingDate)
        .disabled(diary.isSessionExpired)
        .accessibilityIdentifier("diary.calendar")
    }

    private var previousButton: some View {
        Button {
            store.send(.diary(.previousDay))
        } label: {
            Image(systemName: "arrow.left")
                .frame(minWidth: 44, minHeight: 44)
                .background(Circle().fill(briefSurfaceFill))
                .contentShape(Rectangle())
        }
        .disabled(diary.isSessionExpired)
        .opacity(diary.isSessionExpired ? 0.4 : 1)
        .accessibilityLabel(String(localized: "diary.previousDay"))
        .accessibilityIdentifier("diary.previousDay")
        .help(String(localized: "diary.previousDay"))
    }

    private var nextDayDisabled: Bool {
        !diary.canGoNext || diary.isSessionExpired
    }

    private var nextButton: some View {
        Button {
            store.send(.diary(.nextDay))
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
            .disabled(diary.isSessionExpired)
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
            Text("\(diary.completedFetchCount)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("diary.fetchCompletionCount")
                .accessibilityValue("\(diary.completedFetchCount)")

            // Stable 1x1 native-screen marker. Mirrors the proven fetch counter
            // marker placement inside the `.contain` summary card so AX grouping
            // cannot collapse it; compiled only into CALCO_TEST builds.
            Text("native")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("diary.screen.native")
            #endif
        }
        .padding(16)
        .background(briefSurfaceFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var calorieBrief: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = usesAccessibilityLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(briefNumber(calorieProgress.current))
                        .font(.system(size: loggedFontSize, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .animation(valueTransition, value: calorieProgress.current)
                    Text(String(localized: "diary.brief.kcalLogged"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !usesAccessibilityLayout { Spacer(minLength: 8) }
                remainingView
            }

            if let fraction = calorieProgress.fraction {
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
            if let target = calorieProgress.targetText {
                Text(String(format: String(localized: "diary.brief.ofGoal"), target))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diary.summary.calories")
    }

    private var remainingView: some View {
        VStack(alignment: usesAccessibilityLayout ? .leading : .trailing, spacing: 2) {
            if calorieProgress.hasTarget {
                Text(remainingNumberText)
                    .font(.system(size: remainingFontSize, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .animation(valueTransition, value: calorieProgress.current)
                Text(remainingCaptionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diary.summary.remaining")
    }

    private var calorieDifference: Double? {
        let progress = calorieProgress
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
        macroColumn(.protein, progress: proteinProgress, identifier: "diary.summary.protein")
        macroColumn(.carbs, progress: carbsProgress, identifier: "diary.summary.carbs")
        macroColumn(.fat, progress: fatProgress, identifier: "diary.summary.fat")
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
            .disabled(diary.isSessionExpired)
            .accessibilityIdentifier("diary.editGoals")

            if !usesAccessibilityLayout { Spacer(minLength: 8) }
            nutritionButton
        }
    }

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
            .disabled(diary.isSessionExpired || isChangingDate)
            .accessibilityIdentifier("diary.nutrition")
        }
    }

    private var macroModeMenu: some View {
        Menu {
            Button {
                if diary.macroMode != .grams {
                    store.send(.diary(.toggleMacroMode))
                }
            } label: {
                Label(String(localized: "diary.macroMode.grams"), systemImage: diary.macroMode == .grams ? "checkmark" : "")
            }
            Button {
                if diary.macroMode != .percent {
                    store.send(.diary(.toggleMacroMode))
                }
            } label: {
                Label(String(localized: "diary.macroMode.percent"), systemImage: diary.macroMode == .percent ? "checkmark" : "")
            }
        } label: {
            HStack(spacing: 4) {
                Text(diary.macroMode == .grams
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
        switch diary.macroMode {
        case .grams: briefNumber(progress.current)
        case .percent: DiaryMacroDisplay.text(for: progress, mode: .percent)
        }
    }

    private func macroTargetText(_ progress: DiaryGoalProgress) -> String {
        guard diary.macroMode == .grams, progress.hasTarget else { return "" }
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
                        kind.voiceOverLabel(progress: progress, mode: diary.macroMode)
                    )
            }
        }
        .frame(maxWidth: usesAccessibilityLayout ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            kind.voiceOverLabel(progress: progress, mode: diary.macroMode)
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
                    if let slot = section.slot, canLogLatest(for: slot) {
                        Button {
                            store.send(.latest(.prepareLatest(slot)))
                        } label: {
                            if latest.loadingSlot == slot {
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
                            latest.loadingSlot != nil
                                || isChangingDate
                                || diary.isSessionExpired
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
                            store.send(.diary(.openLogEditor(log.id)))
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
                        .disabled(diary.isSessionExpired || isChangingDate)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("diary.log.\(log.id)")
                    }
                }

                if let slot = section.slot {
                    Divider()
                    Button(String(localized: "diary.addFood")) {
                        store.send(.diary(.addFood(slot)))
                    }
                    .disabled(diary.isSessionExpired || isChangingDate)
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
                if let message = displayedLatestError {
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
                        store.send(.latest(.cancelLatestReview))
                    }
                    .disabled(latest.isSubmitting)
                    .accessibilityIdentifier("diary.latest.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.send(.latest(.submitLatest))
                    } label: {
                        if latest.isSubmitting {
                            ProgressView()
                        } else {
                            Text(String(localized: "diary.latest.confirm"))
                        }
                    }
                    .disabled(latest.isSubmitting)
                    .accessibilityIdentifier("diary.latest.submit")
                }
            }
            .interactiveDismissDisabled(latest.isSubmitting)
        }
    }
}

#Preview {
    let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    let day = DiaryDay(
        date: date,
        logs: [DiaryLog(id: "log-1", mealSlot: .breakfast, title: "Oats", calories: 250, proteinG: 8, carbsG: 40, fatG: 5)],
        goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
        prefs: DiaryPrefs()
    )
    let diaryState = DiaryFeature.State(today: date, phase: .loaded(day: day, activity: .settled), sessionGeneration: 1)
    let latestState = DiaryLatestFeature.State(today: date, phase: .idle(destinationDate: date), sessionGeneration: 1)
    let screenState = DiaryScreenFeature.State(diary: diaryState, latest: latestState)
    let store = Store(initialState: screenState) {
        DiaryScreenFeature()
    }
    return DiaryScreenView(store: store)
}
