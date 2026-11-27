import ComposableArchitecture
import SwiftUI

public struct BarcodeFeatureView: View {
    private let store: StoreOf<BarcodeFeature>
    @FocusState private var isFieldFocused: Bool

    public init(store: StoreOf<BarcodeFeature>) {
        self.store = store
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
            get: { store.barcodeInput },
            set: { store.send(.barcodeChanged($0)) }
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
                    .onSubmit { store.send(.lookupSubmitted) }
                    .modifier(BarcodeKeyboardModifier())
                    .accessibilityIdentifier("barcode.field")
                    .accessibilityLabel(String(localized: "barcode.field"))

                Button(String(localized: "barcode.lookup")) {
                    store.send(.lookupSubmitted)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy || store.barcodeInput.isEmpty)
                .accessibilityIdentifier("barcode.lookup")
            }
            Text(String(localized: "barcode.lengthHint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.lookup {
        case .idle:
            EmptyView()

        case .invalid(let error):
            errorCard(message: error.message, canRetry: false)

        case .lookingUp:
            HStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "barcode.loading"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "barcode.cancel"), role: .cancel) {
                    store.send(.cancelLookup)
                }
                .accessibilityIdentifier("barcode.cancel")
            }
            .accessibilityIdentifier("barcode.loading")

        case .found(let lookup):
            resultCard(lookup)

        case .notFound(let barcode):
            notFoundCard(barcode)

        case .failed(_, let error):
            errorCard(message: error.message, canRetry: error.canRetry)
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
                    store.send(.foundProductSelected)
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
        case .local: String(localized: "barcode.result.origin.local")
        case .openFoodFacts: meta.note ?? String(localized: "barcode.result.origin.openFoodFacts")
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
                    store.send(.createCustomFoodDraftSelected)
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

    private func errorCard(message: String, canRetry: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    String(localized: "barcode.error.title"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canRetry {
                    Button(String(localized: "barcode.retry")) {
                        store.send(.retrySubmitted)
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