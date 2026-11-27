import ComposableArchitecture
import SwiftUI

public struct AssistantFeatureView: View {
    @Bindable var store: StoreOf<AssistantFeature>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isComposerFocused: Bool
    @State private var isNearBottom = true
    @State private var followsNextResponse = false
    @State private var hasUnreadResponse = false

    public init(store: StoreOf<AssistantFeature>) {
        self.store = store
    }

    public var body: some View {
        Group {
            switch store.status {
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
            store.send(.loadStatus)
        }
        .onDisappear {
            store.send(.shutdown)
        }
        .confirmationDialog(
            String(localized: "assistant.startOver.confirm"),
            isPresented: Binding(
                get: { store.isStartOverConfirmationPresented },
                set: { if !$0 { store.send(.cancelStartOver) } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "assistant.discard"), role: .destructive) {
                store.send(.confirmStartOver)
            }
            Button(String(localized: "assistant.keep"), role: .cancel) {
                store.send(.cancelStartOver)
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
                store.send(.retryStatus)
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

                        if let barcode = store.initialBarcode,
                           store.purpose == .customFood {
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
                        if store.isSending {
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
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                    guard old.contentOffset != new.contentOffset
                            || old.containerSize != new.containerSize else { return }
                    isNearBottom = new.contentOffset.y + new.containerSize.height
                        >= new.contentSize.height + new.contentInsets.bottom - 80
                    if isNearBottom { hasUnreadResponse = false }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting {
                        followsNextResponse = false
                    }
                }
                .onChange(of: store.messages.count) { _, _ in
                    revealResponse(using: proxy)
                }
                .onChange(of: store.reviewedDraft != nil) { _, _ in
                    revealResponse(using: proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasUnreadResponse {
                        Button {
                            scrollToBottom(using: proxy)
                        } label: {
                            Label(String(localized: "assistant.newResponse"), systemImage: "arrow.down")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                        .accessibilityIdentifier("assistant.newResponse")
                    }
                }
            }

            Divider()
            composer
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button(String(localized: "assistant.startOver"), role: .destructive) {
                        store.send(.requestStartOver)
                    }
                    .disabled(!store.canStartOver || store.isSending)
                    .accessibilityIdentifier("assistant.startOver")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(String(localized: "app.moreActions"))
                .accessibilityIdentifier("assistant.more")
            }
        }
    }

    private var introText: String {
        switch store.purpose {
        case .customFood: String(localized: "assistant.intro.customFood")
        case .adHocLog: String(localized: "assistant.intro.adHocLog")
        }
    }

    private var transcript: some View {
        ForEach(store.messages) { message in
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
        if let draft = store.reviewedDraft {
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
                            "\(DisplayNumberFormat.decimal(quantity)) \(unit)"
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "assistant.draft.per100g"))
                            .font(.subheadline.weight(.semibold))
                        NutritionTable(rows: draft.nutrientsPer100g.map { nutrient in
                            NutritionTableRow(
                                id: nutrient.code,
                                name: nutrientLabel(nutrient.code),
                                amount: nutrient.amountPer100g,
                                unit: nutrientUnit(nutrient)
                            )
                        })
                        .font(.caption)
                    }

                    if !draft.servings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "assistant.draft.servings"))
                                .font(.subheadline.weight(.semibold))
                            ForEach(draft.servings, id: \.unit) { serving in
                                Text(verbatim: "1 \(serving.unit) = \(DisplayNumberFormat.decimal(serving.gramsPerUnit)) g")
                                    .font(.caption)
                            }
                        }
                    }

                    if let suggested = draft.suggestedLog {
                        labeledValue(
                            String(localized: "assistant.draft.suggestedLog"),
                            "\(DisplayNumberFormat.decimal(suggested.amount)) \(suggested.unit) "
                                + "(\(DisplayNumberFormat.decimal(suggested.totalWeightGrams)) g)"
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

                    let actionsLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 10))
                        : AnyLayout(HStackLayout(spacing: 10))
                    actionsLayout {
                        Button {
                            store.send(.beginChanges)
                            isComposerFocused = true
                        } label: {
                            Text(String(localized: "assistant.draft.askChanges"))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("assistant.draft.askChanges")

                        Button {
                            store.send(.acceptDraft)
                        } label: {
                            Text(String(localized: "assistant.draft.accept"))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isDraftAccepted)
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
        if case .failed(let error) = store.request {
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
                    if store.canRetryRequest {
                        Button(String(localized: "assistant.retry")) {
                            store.send(.retryRequest)
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
                store.send(.cancelRequest)
            }
            .accessibilityIdentifier("assistant.cancel")
        }
        .accessibilityIdentifier("assistant.sending")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let composerError = store.composerError {
                Text(composerError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("assistant.composer.error")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    String(localized: "assistant.composer.placeholder"),
                    text: Binding(
                        get: { store.composerText },
                        set: { store.send(.composerChanged($0)) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .focused($isComposerFocused)
                .disabled(store.isSending)
                .accessibilityIdentifier("assistant.composer")
                .accessibilityLabel(String(localized: "assistant.composer.label"))

                Button(String(localized: "assistant.send")) {
                    followsNextResponse = true
                    store.send(.send)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canSend)
                .accessibilityIdentifier("assistant.send")
            }
        }
        .padding()
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func revealResponse(using proxy: ScrollViewProxy) {
        if isNearBottom || followsNextResponse {
            scrollToBottom(using: proxy)
        } else {
            hasUnreadResponse = true
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        hasUnreadResponse = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            proxy.scrollTo("assistant.bottom", anchor: .bottom)
        }
    }

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

    private func nutrientUnit(_ nutrient: AssistantDraftNutrient) -> String {
        switch nutrient.code {
        case NutrientCodes.energyKcal:
            return "kcal"
        case NutrientCodes.proteinG, NutrientCodes.carbsG,
             NutrientCodes.fatG, NutrientCodes.fiberG:
            return "g"
        default:
            return ""
        }
    }
}