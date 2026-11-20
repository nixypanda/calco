// Read-only daily nutrition report. Layout follows the web's report order:
// coverage notice, overview tiles, nutrient sections, then reference context.
// The view is usable in a navigation stack, split-view detail, or sheet; the
// owner supplies the selected day and handles session expiry.

import SwiftUI

public struct NutritionDetailsView: View {
    @ObservedObject private var viewModel: NutritionDetailsViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(viewModel: NutritionDetailsViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dateHeader
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

    // MARK: - Date context

    @ViewBuilder
    private var dateHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                dateTitle
                HStack(spacing: 8) {
                    previousDayButton
                    nextDayButton
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(spacing: 8) {
                previousDayButton
                dateTitle
                    .frame(maxWidth: .infinity)
                nextDayButton
            }
        }
    }

    private var dateTitle: some View {
        Text(NutritionDetailsCopy.dateTitle(viewModel.selectedDate))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("nutrition.date")
    }

    private var previousDayButton: some View {
        Button {
            Task { await viewModel.previousDay() }
        } label: {
            Image(systemName: "chevron.left")
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isSessionExpired)
        .accessibilityLabel(NutritionDetailsCopy.previousDay)
        .accessibilityIdentifier("nutrition.previousDay")
        .help(NutritionDetailsCopy.previousDay)
    }

    private var nextDayButton: some View {
        Button {
            Task { await viewModel.nextDay() }
        } label: {
            Image(systemName: "chevron.right")
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.canGoNext)
        .accessibilityLabel(NutritionDetailsCopy.nextDay)
        .accessibilityIdentifier("nutrition.nextDay")
        .help(NutritionDetailsCopy.nextDay)
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
        VStack(alignment: .leading, spacing: 16) {
            coverageBanner(report.coverageNotice)
            overviewSection(report)
            ForEach(
                NutritionDetailsSection.allCases.filter { $0 != .overview },
                id: \.self
            ) { section in
                nutrientSection(section, report: report)
            }
            referenceSection(report.reference)
        }
    }

    private func coverageBanner(_ notice: NutritionDetailsCoverageNotice) -> some View {
        let isWarning = notice.severity == .warning
        return HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: isWarning
                    ? "exclamationmark.triangle.fill"
                    : "info.circle.fill"
            )
            .foregroundStyle(isWarning ? Color.orange : Color.blue)
            .accessibilityHidden(true)

            Text(NutritionDetailsCopy.coverageNotice(notice.notice))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isWarning ? Color.orange : Color.blue).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nutrition.coverage")
    }

    private func overviewSection(_ report: NutritionDetailsReport) -> some View {
        let overview = report.nutrients(in: .overview)
        return GroupBox {
            if overview.isEmpty {
                emptySectionText(NutritionDetailsCopy.overviewEmpty)
            } else {
                LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 8) {
                    ForEach(overview, id: \.code) { nutrient in
                        overviewTile(nutrient)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text(NutritionDetailsCopy.overviewTitle)
                .font(.headline)
        }
        .accessibilityIdentifier("nutrition.overview")
    }

    private var overviewColumns: [GridItem] {
        let minimumWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 220 : 130
        return [GridItem(.adaptive(minimum: minimumWidth), spacing: 8, alignment: .top)]
    }

    private func overviewTile(_ nutrient: NutritionDetailsNutrient) -> some View {
        let caption = NutritionDetailsCopy.overviewCaption(for: nutrient.coverage)
        return VStack(alignment: .leading, spacing: 4) {
            Text(nutrient.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(NutritionDetailsCopy.amountDisplay(nutrient.overviewAmountDisplay))
                .font(.headline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(caption ?? " ")
                .font(.caption2)
                .foregroundStyle(caption == nil ? Color.clear : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(caption == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(overviewAccessibilityLabel(nutrient, caption: caption))
        .accessibilityIdentifier("nutrition.overview.\(nutrient.code)")
    }

    private func overviewAccessibilityLabel(
        _ nutrient: NutritionDetailsNutrient,
        caption: String?
    ) -> String {
        let amount = NutritionDetailsCopy.accessibilityAmountDisplay(
            nutrient.overviewAmountDisplay
        )
        guard let caption else { return "\(nutrient.name), \(amount)" }
        return "\(nutrient.name), \(amount), \(caption)"
    }

    private func nutrientSection(
        _ section: NutritionDetailsSection,
        report: NutritionDetailsReport
    ) -> some View {
        let nutrients = report.nutrients(in: section)
        return GroupBox {
            if nutrients.isEmpty {
                emptySectionText(NutritionDetailsCopy.sectionEmpty)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(nutrients, id: \.code) { nutrient in
                        nutrientRow(nutrient)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text(NutritionDetailsCopy.sectionTitle(section))
                .font(.headline)
        }
        .accessibilityIdentifier("nutrition.section.\(section.rawValue)")
    }

    private func emptySectionText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Nutrient row

    private func nutrientRow(_ nutrient: NutritionDetailsNutrient) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { viewModel.isGuidanceExpanded(for: nutrient.code) },
                set: { viewModel.setGuidanceExpanded($0, for: nutrient.code) }
            )
        ) {
            Text(NutritionDetailsCopy.advice(for: nutrient.code))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .accessibilityIdentifier("nutrition.advice.\(nutrient.code)")
        } label: {
            nutrientSummary(nutrient)
        }
        .accessibilityIdentifier("nutrition.nutrient.\(nutrient.code)")
    }

    private func nutrientSummary(_ nutrient: NutritionDetailsNutrient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    nutrientName(nutrient)
                    nutrientAmount(nutrient)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        nutrientName(nutrient)
                        Spacer(minLength: 8)
                        nutrientAmount(nutrient)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        nutrientName(nutrient)
                        nutrientAmount(nutrient)
                    }
                }
            }

            if let percent = nutrient.progressPercent {
                progressView(nutrient, percent: percent)
            }

            guidanceView(nutrient)
        }
        .padding(.vertical, 2)
    }

    private func nutrientName(_ nutrient: NutritionDetailsNutrient) -> some View {
        Text(nutrient.name)
            .font(.body.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func nutrientAmount(_ nutrient: NutritionDetailsNutrient) -> some View {
        Text(NutritionDetailsCopy.amountDisplay(nutrient.amountDisplay))
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                NutritionDetailsCopy.accessibilityAmountDisplay(nutrient.amountDisplay)
            )
    }

    private func progressView(
        _ nutrient: NutritionDetailsNutrient,
        percent: Double
    ) -> some View {
        ProgressView(
            value: min(max(percent / 100, 0), 1)
        )
        .tint(progressColor(nutrient))
        .accessibilityLabel(
            "\(nutrient.name), \(NutritionDetailsCopy.progressLabel)"
        )
        .accessibilityValue(
            NutritionDetailsCopy.progressAccessibility(percent: percent)
        )
        .accessibilityIdentifier("nutrition.progress.\(nutrient.code)")
    }

    @ViewBuilder
    private func guidanceView(_ nutrient: NutritionDetailsNutrient) -> some View {
        let guidance = NutritionDetailsCopy.guidance(
            nutrient.guidance,
            unit: nutrient.unit
        )
        let color = guidanceColor(nutrient)

        if nutrient.coverage == .partial {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    partialDataBadge
                    guidanceText(guidance, color: color)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        partialDataBadge
                        guidanceText(guidance, color: color)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        partialDataBadge
                        guidanceText(guidance, color: color)
                    }
                }
            }
        } else {
            guidanceText(guidance, color: color)
        }
    }

    private var partialDataBadge: some View {
        Text(NutritionDetailsCopy.partialData)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.12), in: Capsule())
    }

    private func guidanceText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progressColor(_ nutrient: NutritionDetailsNutrient) -> Color {
        if nutrient.isDangerous {
            return .red
        }
        if nutrient.coverage == .complete,
           nutrient.status == .metReference || nutrient.status == .withinLimit {
            return .green
        }
        return .accentColor
    }

    private func guidanceColor(_ nutrient: NutritionDetailsNutrient) -> Color {
        if nutrient.isDangerous {
            return .red
        }
        if nutrient.coverage == .complete,
           nutrient.status == .metReference || nutrient.status == .withinLimit {
            return .green
        }
        return .secondary
    }

    // MARK: - Reference context

    private func referenceSection(_ reference: NutritionDetailsReference) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(NutritionDetailsCopy.referenceDescription(reference))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = referenceURL(reference.sourceURL) {
                    Link(destination: url) {
                        Label(
                            NutritionDetailsCopy.viewReferenceSource,
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .accessibilityIdentifier("nutrition.reference.source")
                } else {
                    Text(NutritionDetailsCopy.referenceSourceMissing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(NutritionDetailsCopy.aboutReferences)
                .font(.headline)
        }
        .accessibilityIdentifier("nutrition.reference")
    }

    private func referenceURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        return url
    }
}
