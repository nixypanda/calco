// Reviewed AI food drafting. The entry is gated by the server status endpoint,
// the conversation is text-only, and accepting a draft only navigates back to a
// separate editor. Nothing here creates a food or a log.

import SwiftUI

public struct AssistantView: View {
    @ObservedObject private var viewModel: AssistantViewModel
    @FocusState private var isComposerFocused: Bool

    public init(viewModel: AssistantViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    public var body: some View {
        Group {
            switch viewModel.statusState {
            case .idle, .loading:
                statusLoading
            case .disabled:
                statusDisabled
            case .failed(let error):
                statusFailed(error)
            case .enabled:
                draftingContent
            }
        }
        .navigationTitle(String(localized: "assistant.title"))
        .task {
            await viewModel.loadStatus()
        }
        .onDisappear {
            viewModel.shutdown()
        }
        .confirmationDialog(
            String(localized: "assistant.startOver.confirm"),
            isPresented: Binding(
                get: { viewModel.isStartOverConfirmationPresented },
                set: { if !$0 { viewModel.cancelStartOver() } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "assistant.discard"), role: .destructive) {
                viewModel.confirmStartOver()
            }
            Button(String(localized: "assistant.keep"), role: .cancel) {
                viewModel.cancelStartOver()
            }
        } message: {
            Text(String(localized: "assistant.startOver.message"))
        }
    }

    // MARK: - Status

    private var statusLoading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "assistant.status.loading"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("assistant.status.loading")
    }

    private var statusDisabled: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                String(localized: "assistant.status.disabled.title"),
                systemImage: "sparkles"
            )
            .font(.headline)
            Text(String(localized: "assistant.status.disabled.message"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("assistant.status.disabled")
    }

    private func statusFailed(_ error: AssistantServiceError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                String(localized: "assistant.status.failed"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.headline)
            Text(error.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "assistant.status.retry")) {
                viewModel.retryStatus()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("assistant.status.retry")
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding()
        .accessibilityIdentifier("assistant.status.failed")
    }

    // MARK: - Drafting

    private var draftingContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(introText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("assistant.intro")

                        if let barcode = viewModel.initialBarcode,
                           viewModel.purpose == .customFood {
                            Label {
                                Text(
                                    String(
                                        format: String(localized: "assistant.barcodeNote"),
                                        barcode
                                    )
                                )
                                .font(.caption)
                            } icon: {
                                Image(systemName: "barcode")
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("assistant.barcodeNote")
                        }

                        transcript
                        draftReview
                        requestFailure
                        if viewModel.isSending {
                            sendingRow
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("assistant.bottom")
                    }
                    .padding()
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("assistant.bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.draft != nil) { _, _ in
                    withAnimation {
                        proxy.scrollTo("assistant.bottom", anchor: .bottom)
                    }
                }
            }

            Divider()
            composer
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(String(localized: "assistant.startOver")) {
                    viewModel.requestStartOver()
                }
                .disabled(!viewModel.canStartOver || viewModel.isSending)
                .accessibilityIdentifier("assistant.startOver")
            }
        }
    }

    private var introText: String {
        switch viewModel.purpose {
        case .customFood:
            return String(localized: "assistant.intro.customFood")
        case .adHocLog:
            return String(localized: "assistant.intro.adHocLog")
        }
    }

    private var transcript: some View {
        ForEach(viewModel.messages) { message in
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    message.role == .user
                        ? String(localized: "assistant.transcript.you")
                        : String(localized: "assistant.transcript.assistant")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(message.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(
                maxWidth: .infinity,
                alignment: message.role == .user ? .trailing : .leading
            )
            .background(
                message.role == .user
                    ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                    : AnyShapeStyle(.quaternary.opacity(0.4)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("assistant.message.\(message.id)")
        }
    }

    @ViewBuilder
    private var draftReview: some View {
        if let draft = viewModel.draft {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "assistant.draft.title"))
                        .font(.headline)
                    Text(String(localized: "assistant.draft.note"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    labeledValue(
                        String(localized: "assistant.draft.name"),
                        draft.name
                    )
                    if let brand = draft.brand {
                        labeledValue(
                            String(localized: "assistant.draft.brand"),
                            brand
                        )
                    }
                    if let barcode = draft.barcode {
                        labeledValue(
                            String(localized: "assistant.draft.barcode"),
                            barcode
                        )
                    }
                    if !draft.categories.isEmpty {
                        labeledValue(
                            String(localized: "assistant.draft.categories"),
                            draft.categories.joined(separator: ", ")
                        )
                    }
                    if let quantity = draft.defaultQuantity, let unit = draft.defaultUnit {
                        labeledValue(
                            String(localized: "assistant.draft.defaultPortion"),
                            "\(quantity) \(unit)"
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "assistant.draft.per100g"))
                            .font(.subheadline.weight(.semibold))
                        ForEach(draft.nutrientsPer100g, id: \.code) { nutrient in
                            HStack {
                                Text(nutrientLabel(nutrient.code))
                                Spacer()
                                Text(verbatim: nutrientDisplay(nutrient))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }

                    if !draft.servings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "assistant.draft.servings"))
                                .font(.subheadline.weight(.semibold))
                            ForEach(draft.servings, id: \.unit) { serving in
                                Text(verbatim: "1 \(serving.unit) = \(serving.gramsPerUnit) g")
                                    .font(.caption)
                            }
                        }
                    }

                    if let suggested = draft.suggestedLog {
                        labeledValue(
                            String(localized: "assistant.draft.suggestedLog"),
                            "\(suggested.amount) \(suggested.unit) (\(suggested.totalWeightGrams) g)"
                        )
                    }

                    if !draft.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "assistant.draft.warnings"))
                                .font(.subheadline.weight(.semibold))
                            ForEach(draft.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityIdentifier("assistant.draft.warnings")
                    }

                    Text(String(localized: "assistant.draft.saveNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button(String(localized: "assistant.draft.askChanges")) {
                            viewModel.beginChanges()
                            isComposerFocused = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("assistant.draft.askChanges")

                        Button(String(localized: "assistant.draft.accept")) {
                            viewModel.acceptDraft()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isDraftAccepted)
                        .accessibilityIdentifier("assistant.draft.accept")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("assistant.draft")
        }
    }

    @ViewBuilder
    private var requestFailure: some View {
        if case .failed(let error) = viewModel.requestState {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        String(localized: "assistant.error.title"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.headline)
                    Text(error.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.canRetryRequest {
                        Button(String(localized: "assistant.retry")) {
                            viewModel.retryRequest()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("assistant.retry")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("assistant.error")
        }
    }

    private var sendingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "assistant.sending"))
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "assistant.cancel"), role: .cancel) {
                viewModel.cancelRequest()
            }
            .accessibilityIdentifier("assistant.cancel")
        }
        .accessibilityIdentifier("assistant.sending")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let composerError = viewModel.composerError {
                Text(composerError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("assistant.composer.error")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    String(localized: "assistant.composer.placeholder"),
                    text: Binding(
                        get: { viewModel.composerText },
                        set: { viewModel.composerChanged($0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .focused($isComposerFocused)
                .disabled(viewModel.isSending)
                .accessibilityIdentifier("assistant.composer")
                .accessibilityLabel(String(localized: "assistant.composer.label"))

                Button(String(localized: "assistant.send")) {
                    viewModel.send()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSend)
                .accessibilityIdentifier("assistant.send")
            }
        }
        .padding()
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nutrientLabel(_ code: String) -> String {
        switch code {
        case NutrientCodes.energyKcal:
            return String(localized: "barcode.nutrient.energy")
        case NutrientCodes.proteinG:
            return String(localized: "barcode.nutrient.protein")
        case NutrientCodes.carbsG:
            return String(localized: "barcode.nutrient.carbs")
        case NutrientCodes.fatG:
            return String(localized: "barcode.nutrient.fat")
        default:
            return code
        }
    }

    private func nutrientDisplay(_ nutrient: AssistantDraftNutrient) -> String {
        let unit: String
        switch nutrient.code {
        case NutrientCodes.energyKcal:
            unit = " kcal"
        case NutrientCodes.proteinG, NutrientCodes.carbsG,
             NutrientCodes.fatG, NutrientCodes.fiberG:
            unit = " g"
        default:
            unit = ""
        }
        return "\(nutrient.amountPer100g)\(unit)"
    }
}
