// Creation is a task on the caller's navigation stack, never a Library sheet.
// The task owns its models so returning from review retains the conversation
// and edited values. Completion removes the whole task, not just review.

import ComposableArchitecture
import SwiftUI

struct FoodCreationRequest: Identifiable, Hashable {
    enum Entry: Hashable {
        case assistant(AssistantDraftPurpose, barcode: String?)
        case barcode(String)
    }

    let id = UUID()
    let entry: Entry
}

public struct FoodCreationContext {
    let libraryService: any LibraryServicing
    let assistantService: any AssistantServicing
    let submissionService: any LibraryLogSubmitting
    let accountID: String
    let today: LocalDiaryDate
    let logContext: LibraryLogContext
    let sessionGeneration: UInt64
    let onLogged: (LocalDiaryDate, MealSlot?) -> Void
    let onSessionExpired: () -> Void
}

/// Capture services and diary context in the presented value itself. A separate
/// optional State can still be nil in SwiftUI's initial destination evaluation.
struct FoodCreationDestination: Identifiable, Hashable {
    let request: FoodCreationRequest
    let context: FoodCreationContext
    var id: UUID { request.id }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class FoodCreationFlowModel: ObservableObject {
    @Published var isReviewPresented = false
    private(set) var editor: CustomFoodEditorViewModel?
    private(set) var adHocEditor: AdHocLogViewModel?
    private var acceptedDraft: AssistantReviewedDraft?
    private let context: FoodCreationContext
    private let onFinished: () -> Void
    let request: FoodCreationRequest

    private(set) lazy var assistantStore: StoreOf<FoodCreationAssistantFeature>? = {
        guard case .assistant(let purpose, let barcode) = self.request.entry else {
            return nil
        }
        let sessionGeneration = self.context.sessionGeneration
        let assistantService = self.context.assistantService
        return Store(
            initialState: FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: purpose,
                    initialBarcode: barcode,
                    sessionGeneration: sessionGeneration
                )
            )
        ) {
            FoodCreationAssistantFeature()
        } withDependencies: {
            $0.assistantClient = .live(service: assistantService)
            $0.foodCreationAssistantHandoff = FoodCreationAssistantHandoffClient(
                acceptReviewedDraft: { [weak self] draft in
                    self?.review(draft)
                },
                sessionExpired: { [weak self] generation in
                    guard generation == self?.context.sessionGeneration else { return }
                    self?.context.onSessionExpired()
                }
            )
        }
    }()

    init(
        request: FoodCreationRequest,
        context: FoodCreationContext,
        onFinished: @escaping () -> Void
    ) {
        self.request = request
        self.context = context
        self.onFinished = onFinished
        if case .barcode(let barcode) = request.entry {
            editor = makeEditor(barcode: barcode)
        }
    }

    func review(_ draft: AssistantReviewedDraft) {
        if acceptedDraft != draft {
            acceptedDraft = draft
            switch draft.purpose {
            case .customFood:
                editor = makeEditor(draft: draft)
            case .adHocLog:
                adHocEditor = AdHocLogViewModel(
                    service: context.libraryService,
                    submissionService: context.submissionService,
                    accountID: context.accountID,
                    initialDate: context.logContext.date,
                    today: context.today,
                    initialMealSlot: context.logContext.mealSlot,
                    onLogged: { [weak self] date, slot in
                        self?.context.onLogged(date, slot)
                        self?.onFinished()
                    },
                    onSessionExpired: context.onSessionExpired,
                    assistantDraft: draft
                )
            }
        }
        isReviewPresented = true
    }

    private func makeEditor(
        draft: AssistantReviewedDraft? = nil,
        barcode: String? = nil
    ) -> CustomFoodEditorViewModel {
        CustomFoodEditorViewModel(
            mode: .create,
            service: context.libraryService,
            accountID: context.accountID,
            onSaved: { [weak self] _ in self?.onFinished() },
            onSessionExpired: context.onSessionExpired,
            assistantDraft: draft,
            initialBarcode: barcode
        )
    }
}

struct FoodCreationFlowView: View {
    @StateObject private var model: FoodCreationFlowModel

    init(
        request: FoodCreationRequest,
        context: FoodCreationContext,
        onFinished: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: FoodCreationFlowModel(
            request: request, context: context, onFinished: onFinished
        ))
    }

    var body: some View {
        switch model.request.entry {
        case .assistant:
            if let store = model.assistantStore {
                AssistantCreationPage(
                    store: store.scope(state: \.assistant, action: \.assistant)
                )
                .navigationDestination(isPresented: $model.isReviewPresented) {
                    reviewPage
                }
            }
        case .barcode:
            if let editor = model.editor {
                CustomFoodEditorView(viewModel: editor)
            }
        }
    }

    @ViewBuilder
    private var reviewPage: some View {
        if let editor = model.editor {
            CustomFoodEditorView(viewModel: editor, preservesDraftOnBack: true)
        } else if let editor = model.adHocEditor {
            AdHocLogView(viewModel: editor, preservesDraftOnBack: true)
        }
    }
}

private struct AssistantCreationPage: View {
    let store: StoreOf<AssistantFeature>
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingBack = false

    var body: some View {
        AssistantFeatureView(store: store)
            .onAppear { store.send(.resumeDraftReview) }
            .navigationBarBackButtonHidden(store.canStartOver || store.isSending)
            .toolbar {
                if store.canStartOver || store.isSending {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            confirmingBack = true
                        } label: {
                            Label(String(localized: "library.common.back"), systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("assistant.back")
                    }
                }
            }
            .alert(String(localized: "diary.editor.discard.title"), isPresented: $confirmingBack) {
                Button(String(localized: "diary.editor.discard.action"), role: .destructive) {
                    dismiss()
                }
                Button(String(localized: "diary.common.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "diary.editor.discard.message"))
            }
    }
}
