// Manual barcode lookup. No camera or photo permission is requested; this
// screen works identically on iPhone, iPad, and Mac.

import SwiftUI

public struct BarcodeLookupView: View {
    @ObservedObject private var viewModel: BarcodeViewModel
    @FocusState private var isFieldFocused: Bool

    public init(viewModel: BarcodeViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "barcode.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                inputRow
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(String(localized: "barcode.title"))
        .onAppear {
            isFieldFocused = true
        }
    }

    private var barcodeBinding: Binding<String> {
        Binding(
            get: { viewModel.barcodeInput },
            set: { viewModel.barcodeChanged($0) }
        )
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "barcode")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "barcode.field"), text: barcodeBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .onSubmit { viewModel.lookup() }
                    .modifier(BarcodeKeyboardModifier())
                    .accessibilityIdentifier("barcode.field")
                    .accessibilityLabel(String(localized: "barcode.field"))

                Button(String(localized: "barcode.lookup")) {
                    viewModel.lookup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.barcodeInput.isEmpty)
                .accessibilityIdentifier("barcode.lookup")
            }
            Text(String(localized: "barcode.lengthHint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "barcode.loading"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "barcode.cancel"), role: .cancel) {
                    viewModel.cancel()
                }
                .accessibilityIdentifier("barcode.cancel")
            }
            .accessibilityIdentifier("barcode.loading")
        case .found(let lookup):
            resultCard(lookup)
        case .notFound(let barcode):
            notFoundCard(barcode)
        case .failed(let error):
            errorCard(error)
        }
    }

    private func resultCard(_ lookup: BarcodeLookup) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(lookup.product.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let brand = lookup.product.brand, !brand.isEmpty {
                    Text(brand)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(originText(lookup.lookup))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("barcode.result.origin")
                if let barcode = lookup.product.barcode {
                    Text(barcode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                nutrientLine(lookup.product.nutritionSummary.per100g)
                Button {
                    viewModel.selectFoundProduct()
                } label: {
                    Label(String(localized: "barcode.result.log"), systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("barcode.result.log")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("barcode.result")
    }

    private func originText(_ meta: BarcodeLookupMeta) -> String {
        switch meta.origin {
        case .local:
            return String(localized: "barcode.result.origin.local")
        case .openFoodFacts:
            return meta.note ?? String(localized: "barcode.result.origin.openFoodFacts")
        }
    }

    private func nutrientLine(_ summary: NutritionSummary) -> some View {
        let values = [
            (NutrientCodes.energyKcal, summary.energyKcal, "kcal"),
            (NutrientCodes.proteinG, summary.proteinG, "g"),
            (NutrientCodes.carbsG, summary.carbsG, "g"),
            (NutrientCodes.fatG, summary.fatG, "g"),
        ].compactMap { entry -> String? in
            let (code, amount, unit) = entry
            guard let amount, !amount.isEmpty else { return nil }
            let label: String
            switch code {
            case NutrientCodes.energyKcal:
                label = String(localized: "barcode.nutrient.energy")
            case NutrientCodes.proteinG:
                label = String(localized: "barcode.nutrient.protein")
            case NutrientCodes.carbsG:
                label = String(localized: "barcode.nutrient.carbs")
            default:
                label = String(localized: "barcode.nutrient.fat")
            }
            return "\(label) \(DisplayNumberFormat.decimal(amount)) \(unit)"
        }
        return Text(verbatim: values.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("barcode.result.nutrients")
    }

    private func notFoundCard(_ barcode: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    String(localized: "barcode.notFound.title"),
                    systemImage: "barcode"
                )
                .font(.headline)
                Text(String(localized: "barcode.notFound.message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(barcode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button {
                    viewModel.createCustomFoodDraft()
                } label: {
                    Label(
                        String(localized: "barcode.notFound.create"),
                        systemImage: "square.and.pencil"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("barcode.notFound.create")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("barcode.notFound")
    }

    private func errorCard(_ error: BarcodeServiceError) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    String(localized: "barcode.error.title"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.headline)
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if error.canRetry {
                    Button(String(localized: "barcode.retry")) {
                        viewModel.retry()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("barcode.retry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("barcode.error")
    }
}

private struct BarcodeKeyboardModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        content
        #endif
    }
}
