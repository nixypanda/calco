import SwiftUI

public struct NutritionDetailsReportView: View {
    public let report: NutritionDetailsReport
    public let expandedCodes: Set<String>
    public let onToggle: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var unitColumnWidth = 44

    public init(
        report: NutritionDetailsReport,
        expandedCodes: Set<String>,
        onToggle: @escaping (String) -> Void
    ) {
        self.report = report
        self.expandedCodes = expandedCodes
        self.onToggle = onToggle
    }

    public var body: some View {
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
                nutrientTable(overview, overview: true)
            }
        } label: {
            Text(NutritionDetailsCopy.overviewTitle)
                .font(.headline)
        }
        .accessibilityIdentifier("nutrition.overview")
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
                nutrientTable(nutrients)
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

    /// A shared Grid measures the number and unit columns across every row,
    /// rather than aligning the trailing edge of combined "amount unit" labels.
    private func nutrientTable(
        _ nutrients: [NutritionDetailsNutrient],
        overview: Bool = false
    ) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(nutrients, id: \.code) { nutrient in
                let display = overview ? nutrient.overviewAmountDisplay : nutrient.amountDisplay
                GridRow(alignment: .firstTextBaseline) {
                    nutrientName(nutrient)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(NutritionDetailsCopy.amountDisplay(display, includeUnit: false))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .gridColumnAlignment(.trailing)
                    Text(nutrient.unit)
                        .foregroundStyle(.secondary)
                        .frame(width: unitColumnWidth, alignment: .leading)
                        .gridColumnAlignment(.leading)
                }
                .font(.body)
                .padding(.top, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    overview
                        ? overviewAccessibilityLabel(
                            nutrient,
                            caption: NutritionDetailsCopy.overviewCaption(for: nutrient.coverage)
                        )
                        : "\(nutrient.name), "
                            + NutritionDetailsCopy.accessibilityAmountDisplay(display)
                )
                .accessibilityIdentifier(
                    overview
                        ? "nutrition.overview.\(nutrient.code)"
                        : "nutrition.amount.\(nutrient.code)"
                )

                if overview {
                    if let caption = NutritionDetailsCopy.overviewCaption(for: nutrient.coverage) {
                        GridRow {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .gridCellColumns(3)
                        }
                    }
                } else {
                    GridRow {
                        nutrientRow(nutrient)
                            .gridCellColumns(3)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }

                if nutrient.code != nutrients.last?.code {
                    GridRow {
                        Divider()
                            .gridCellColumns(3)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nutrientRow(_ nutrient: NutritionDetailsNutrient) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedCodes.contains(nutrient.code) },
                set: { newValue in
                    if newValue != expandedCodes.contains(nutrient.code) {
                        onToggle(nutrient.code)
                    }
                }
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
