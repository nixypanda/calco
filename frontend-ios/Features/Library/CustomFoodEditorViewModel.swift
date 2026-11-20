// Custom-food create/edit view model with durable uncertain-create
// reconciliation. Only the edit flow supports servings/default portions;
// creation intentionally omits them, matching the web's create form.

import Combine
import Foundation

public enum CustomFoodEditorMode: Equatable, Sendable {
    case create
    case edit(id: String)

    public var foodID: String? {
        if case .edit(let id) = self { return id }
        return nil
    }

    public var isCreate: Bool {
        if case .create = self { return true }
        return false
    }
}

public struct ServingEditorRow: Identifiable, Equatable, Sendable {
    public let id: String
    public var unit: String
    public var gramsPerUnit: String

    public init(id: String = UUID().uuidString.lowercased(), unit: String = "", gramsPerUnit: String = "") {
        self.id = id
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }
}

@MainActor
public final class CustomFoodEditorViewModel: ObservableObject {
    @Published public private(set) var loadState: LibraryLoadState = .loading
    @Published public private(set) var isSaving = false
    @Published public private(set) var submitError: String?
    @Published public private(set) var savedFoodID: String?
    @Published public private(set) var savedLogIntent: CustomFoodLogIntent?
    @Published public private(set) var savedLogState: SavedFoodLogState = .none
    @Published public private(set) var reconciliationAttempt: CustomFoodCreateAttempt?
    @Published public private(set) var reconciliationCandidates: [CustomFood] = []
    @Published public private(set) var reconciliationMessage: String?
    @Published public private(set) var isRefreshingReconciliation = false
    @Published public private(set) var isReconciliationStoreBlocked = false
    @Published public private(set) var barcodeNotice: String?
    @Published public private(set) var isDirty = false
    @Published public var hasAttemptedSubmit = false

    @Published public var name: String = "" { didSet { markDirty() } }
    @Published public var brand: String = "" { didSet { markDirty() } }
    @Published public var categoriesText: String = "" { didSet { markDirty() } }
    @Published public var defaultQuantity: String = "" { didSet { markDirty() } }
    @Published public var defaultUnit: String = "" { didSet { markDirty() } }
    @Published public var servings: [ServingEditorRow] = [] { didSet { markDirty() } }
    @Published public var nutrientEditor: NutrientEditorState

    public let mode: CustomFoodEditorMode
    public let accountID: String

    private let service: any LibraryServicing
    private let submissionService: any LibraryLogSubmitting
    private let engine: CustomFoodReconciliationEngine
    private let reconciliationStore: CustomFoodReconciliationStore
    private let baseURL: URL?
    private let timeZoneProvider: () -> String
    private let onSaved: (String) -> Void
    private let onLogged: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void
    private let onReviewPending: () -> Void
    private let initialAssistantDraft: AssistantReviewedDraft?
    private let initialBarcode: String?

    private var isApplyingInitialValues = false
    private var hasAppliedInitialAssistantDraft = false
    private var hasAppliedInitialBarcode = false
    private var savedFoodName: String?
    private var savedLogAttemptID: String?
    private var loadGeneration = 0

    public init(
        mode: CustomFoodEditorMode,
        service: any LibraryServicing,
        submissionService: any LibraryLogSubmitting,
        reconciliationStore: CustomFoodReconciliationStore,
        accountID: String,
        baseURL: URL? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        onSaved: @escaping (String) -> Void = { _ in },
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        onReviewPending: @escaping () -> Void = {},
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil
    ) {
        self.mode = mode
        self.service = service
        self.submissionService = submissionService
        self.reconciliationStore = reconciliationStore
        self.accountID = accountID
        self.baseURL = baseURL
        self.timeZoneProvider = timeZoneProvider
        self.onSaved = onSaved
        self.onLogged = onLogged
        self.onSessionExpired = onSessionExpired
        self.onReviewPending = onReviewPending
        self.initialAssistantDraft = assistantDraft
        self.initialBarcode = initialBarcode
        self.engine = CustomFoodReconciliationEngine(
            service: service,
            store: reconciliationStore,
            accountID: accountID
        )
        self.nutrientEditor = NutrientEditorState(definitions: [])
    }

    public var foodID: String? { mode.foodID }

    public var titleKey: String {
        mode.isCreate ? "library.editor.create.title" : "library.editor.edit.title"
    }

    public var isBusy: Bool {
        isSaving || savedLogState == .logging || isRefreshingReconciliation
    }

    public var isFormEditable: Bool {
        if case .loaded = loadState {
            return !isBusy && savedFoodID == nil && reconciliationAttempt == nil
        }
        return false
    }

    public var hasUnsavedChanges: Bool {
        isDirty && savedFoodID == nil && reconciliationAttempt == nil && !isBusy
    }

    public var isReconciling: Bool { reconciliationAttempt != nil }

    public var hasRetainedLogIntent: Bool {
        savedFoodID != nil && savedLogIntent != nil
    }

    public var canSubmit: Bool {
        isFormEditable && !isBusy
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        submitError = nil
        isReconciliationStoreBlocked = false
        if mode.isCreate {
            do {
                if let attempt = try engine.loadAttempt() {
                    if let foodID = attempt.foodID, let intent = attempt.logIntent {
                        savedFoodID = foodID
                        savedFoodName = attempt.displayName
                        savedLogIntent = intent
                        savedLogAttemptID = attempt.id
                        savedLogState = .retryable(
                            message: attempt.message.isEmpty
                                ? String(localized: "library.log.resumeMessage")
                                : attempt.message
                        )
                        isDirty = false
                        reconciliationAttempt = nil
                        reconciliationCandidates = []
                        reconciliationMessage = nil
                        loadState = .loaded
                        return
                    }
                    if attempt.foodID != nil, attempt.logIntent == nil {
                        try? engine.completeLogHandoff(attemptID: attempt.id)
                    } else {
                        reconciliationAttempt = attempt
                        reconciliationCandidates = []
                        reconciliationMessage = nil
                        loadState = .loaded
                        await refreshReconciliationCandidates()
                        return
                    }
                }
            } catch {
                isReconciliationStoreBlocked = true
                loadState = .failed(String(localized: "library.reconcile.storeUnavailable"))
                return
            }
        }

        do {
            let definitions = try await service.nutrientDefinitions()
            var food: CustomFood?
            if let foodID = mode.foodID {
                food = try await service.customFood(id: foodID)
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            isApplyingInitialValues = true
            defer { isApplyingInitialValues = false }
            if let food {
                name = food.name
                brand = food.brand ?? ""
                categoriesText = food.categories.joined(separator: ", ")
                defaultQuantity = food.defaultQuantity ?? ""
                defaultUnit = food.defaultUnit ?? ""
                servings = food.servings.map {
                    ServingEditorRow(unit: $0.unit, gramsPerUnit: $0.gramsPerUnit)
                }
                nutrientEditor = NutrientEditorState(
                    definitions: definitions,
                    initial: food.nutrientsPer100g
                )
            } else {
                nutrientEditor = NutrientEditorState(definitions: definitions)
            }
            isDirty = false
            hasAttemptedSubmit = false
            loadState = .loaded
            if let draft = initialAssistantDraft,
               !hasAppliedInitialAssistantDraft,
               draft.purpose == .customFood {
                hasAppliedInitialAssistantDraft = true
                if !applyAssistantDraft(draft) {
                    submitError = String(localized: "library.assistant.prefillFailed")
                }
            } else if mode.isCreate,
                      !hasAppliedInitialBarcode,
                      let initialBarcode {
                hasAppliedInitialBarcode = true
                barcodeNotice = String(
                    format: String(localized: "library.assistant.barcodeNotPersisted"),
                    initialBarcode
                )
            }
        } catch let error as CustomFoodServiceError {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if error.isUnauthorized {
                onSessionExpired()
            }
            loadState = .failed(error.message)
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadState = .failed(String(localized: "library.editor.loadFailed"))
        }
    }

    public func submit() async {
        guard canSubmit, case .loaded = loadState else { return }
        hasAttemptedSubmit = true
        submitError = nil

        let values = formValues()
        let request: CustomFoodWriteRequest
        switch values.validate() {
        case .failure(let error):
            submitError = values.errorMessage(error, definitions: nutrientEditor.definitions)
            return
        case .success(let validated):
            request = validated
        }

        if let foodID = mode.foodID {
            await update(foodID: foodID, request: request)
        } else {
            await create(request: request)
        }
    }

    private func update(foodID: String, request: CustomFoodWriteRequest) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let id = try await service.updateCustomFood(id: foodID, request: request)
            isDirty = false
            savedFoodID = id
            onSaved(id)
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                onSessionExpired()
            }
            submitError = error.message
        } catch {
            submitError = String(localized: "foodDetail.error.saveFailed")
        }
    }

    private func create(request: CustomFoodWriteRequest) async {
        isSaving = true
        defer { isSaving = false }

        let baseline: [CustomFood]
        do {
            // The baseline is required for safe reconciliation. Never create
            // without knowing which foods existed beforehand.
            baseline = try await service.listCustomFoods()
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                onSessionExpired()
            }
            submitError = error.message
            return
        } catch {
            submitError = String(localized: "library.error.load")
            return
        }

        let result = await engine.create(
            draft: request,
            baselineFoodIDs: baseline.map(\.id)
        )
        switch result {
        case .saved(let foodID):
            savedFoodID = foodID
            savedFoodName = request.name
            savedLogIntent = nil
            savedLogAttemptID = nil
            if let retained = try? engine.currentAttempt(),
               retained.foodID == foodID,
               retained.logIntent != nil {
                savedLogIntent = retained.logIntent
                savedLogAttemptID = retained.id
            }
            isDirty = false
            onSaved(foodID)
        case .needsReconciliation(let attempt):
            reconciliationAttempt = attempt
            reconciliationCandidates = []
            reconciliationMessage = nil
            await refreshReconciliationCandidates()
        case .failed(let error):
            if error.isUnauthorized {
                onSessionExpired()
            }
            submitError = error.message
        case .blocked(let message):
            submitError = message
        }
    }

    // MARK: Reconciliation

    public func refreshReconciliationCandidates() async {
        guard let attempt = reconciliationAttempt, !isRefreshingReconciliation else {
            return
        }
        isRefreshingReconciliation = true
        reconciliationMessage = nil
        defer { isRefreshingReconciliation = false }
        do {
            let matches = try await engine.candidates(for: attempt)
            reconciliationCandidates = matches.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if matches.isEmpty {
                reconciliationMessage = String(localized: "library.reconcile.noMatches")
            }
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                onSessionExpired()
            }
            reconciliationMessage = error.message
        } catch {
            reconciliationMessage = String(localized: "library.error.load")
        }
    }

    public func useReconciledFood(_ food: CustomFood) async {
        guard let attempt = reconciliationAttempt else { return }
        let retained: CustomFoodCreateAttempt?
        do {
            retained = try engine.resolve(attempt: attempt, food: food)
        } catch {
            reconciliationMessage = String(localized: "library.reconcile.storeUnavailable")
            return
        }
        reconciliationAttempt = nil
        reconciliationCandidates = []
        reconciliationMessage = nil
        savedFoodID = food.id
        savedFoodName = food.name
        savedLogIntent = attempt.logIntent
        savedLogAttemptID = attempt.logIntent == nil ? nil : (retained?.id ?? attempt.id)
        isDirty = false

        if let intent = attempt.logIntent {
            await submitSavedFoodLog(foodID: food.id, intent: intent)
        } else {
            onSaved(food.id)
        }
    }

    public func discardReconciliation() async {
        guard let attempt = reconciliationAttempt else { return }
        do {
            try engine.discard(attempt: attempt)
        } catch {
            reconciliationMessage = String(localized: "library.reconcile.storeUnavailable")
            return
        }
        reconciliationAttempt = nil
        reconciliationCandidates = []
        reconciliationMessage = nil
        savedFoodID = nil
        savedLogIntent = nil
        savedLogAttemptID = nil
        savedLogState = .none
        await load()
    }

    public func resetUnreadableReconciliation() async {
        do {
            try engine.resetUnreadableState()
        } catch {
            submitError = String(localized: "library.reconcile.storeUnavailable")
            return
        }
        await load()
    }

    public func reviewPendingLogs() {
        onReviewPending()
    }

    // MARK: Save-then-log retry (recovered operation only)

    /// A definitively rejected log can be submitted again for the retained
    /// food. Uncertain journal states are recovered by the shell.
    public func retrySavedFoodLog() async {
        guard let foodID = savedFoodID, let intent = savedLogIntent else { return }
        switch savedLogState {
        case .retryable:
            await submitSavedFoodLog(foodID: foodID, intent: intent)
        case .none, .logging, .pending, .logged:
            break
        }
    }

    private func submitSavedFoodLog(
        foodID: String,
        intent: CustomFoodLogIntent
    ) async {
        guard let attemptID = savedLogAttemptID else {
            savedLogState = .retryable(
                message: String(localized: "library.reconcile.storeUnavailable")
            )
            return
        }
        let journalRequest: CustomFoodJournalRequest
        do {
            journalRequest = try engine.prepareJournalRequest(
                attemptID: attemptID,
                currentBaseURL: baseURL
            )
        } catch {
            savedLogState = .retryable(
                message: String(localized: "library.reconcile.storeUnavailable")
            )
            return
        }

        savedLogState = .logging
        let draft = intent.logSubmissionDraft(productID: foodID)
        let name = savedFoodName ?? foodID
        let outcome = await submissionService.submitPersisted(
            LibraryPersistedLogRequest(
                accountID: accountID,
                operationID: journalRequest.operationID,
                draft: draft,
                itemName: name,
                summary: name,
                request: journalRequest.submissionRequest
            )
        )
        handleSavedFoodLogOutcome(
            outcome,
            intent: intent,
            attemptID: attemptID
        )
    }

    private func handleSavedFoodLogOutcome(
        _ outcome: LibraryLogHandoffOutcome,
        intent: CustomFoodLogIntent,
        attemptID: String
    ) {
        if outcome.journalOwned {
            switch outcome.result {
            case .success:
                finishLogHandoff(attemptID)
            case .failure(.uncertain), .failure(.conflict), .failure(.unauthorized):
                finishLogHandoff(attemptID)
            case .failure(.rejected),
                 .failure(.missingComponents),
                 .failure(.serverChanged),
                 .failure(.reconciliationOnly),
                 .failure(.capabilityUnavailable),
                 .failure(.capabilityTemporarilyUnavailable),
                 .failure(.journalUnavailable):
                break
            }
        }

        switch outcome.result {
        case .success(let logs, let replayed):
            savedLogState = .logged(logID: logs.first?.id, replayed: replayed)
            onLogged(intent.date, intent.mealSlot)
        case .failure(.uncertain(let message)):
            savedLogState = .pending(message: message)
        case .failure(.conflict(let message)):
            savedLogState = .pending(message: message)
        case .failure(.unauthorized):
            savedLogState = .pending(
                message: String(localized: "foodDetail.error.sessionExpired")
            )
            onSessionExpired()
        case .failure(.rejected(let message)),
             .failure(.missingComponents(let message)),
             .failure(.serverChanged(let message)),
             .failure(.reconciliationOnly(let message)),
             .failure(.capabilityUnavailable(let message)),
             .failure(.capabilityTemporarilyUnavailable(let message)),
             .failure(.journalUnavailable(let message)):
            savedLogState = .retryable(message: message)
        }
    }

    private func finishLogHandoff(_ attemptID: String) {
        try? engine.completeLogHandoff(attemptID: attemptID)
        savedLogAttemptID = nil
    }

    // MARK: Form mutation

    /// Applies a fully typed reviewed assistant draft without losing units,
    /// servings, or the barcode note. The server does not persist barcodes for
    /// custom foods, so the barcode is displayed as a review note only.
    @discardableResult
    public func applyAssistantDraft(_ draft: AssistantReviewedDraft) -> Bool {
        guard mode.isCreate,
              draft.purpose == .customFood,
              isFormEditable else {
            return false
        }
        let unitsByCode = Dictionary(
            nutrientEditor.definitions.map { ($0.code, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let nutrients = draft.per100gNutrients(unitsByCode: unitsByCode) else {
            return false
        }
        isApplyingInitialValues = true
        name = draft.name
        brand = draft.brand ?? ""
        categoriesText = draft.categories.joined(separator: ", ")
        defaultQuantity = draft.defaultQuantity ?? ""
        defaultUnit = draft.defaultUnit ?? ""
        servings = draft.servings.map {
            ServingEditorRow(unit: $0.unit, gramsPerUnit: $0.gramsPerUnit)
        }
        nutrientEditor = NutrientEditorState(
            definitions: nutrientEditor.definitions,
            initial: nutrients
        )
        barcodeNotice = draft.barcode.map {
            String(
                format: String(localized: "library.assistant.barcodeNotPersisted"),
                $0
            )
        }
        isApplyingInitialValues = false
        isDirty = true
        return true
    }

    public func setNutrientAmount(_ amount: String, code: String) {
        guard isFormEditable else { return }
        isApplyingInitialValues = true
        nutrientEditor.setAmount(amount, for: code)
        isApplyingInitialValues = false
        markDirty()
    }

    public func addOptionalNutrient(code: String) {
        guard isFormEditable else { return }
        isApplyingInitialValues = true
        nutrientEditor.addOptional(code: code)
        isApplyingInitialValues = false
        markDirty()
    }

    public func removeNutrient(code: String) {
        guard isFormEditable else { return }
        isApplyingInitialValues = true
        nutrientEditor.remove(code: code)
        isApplyingInitialValues = false
        markDirty()
    }

    public func addServingRow() {
        guard isFormEditable else { return }
        servings.append(ServingEditorRow())
    }

    public func removeServingRow(id: String) {
        guard isFormEditable else { return }
        servings.removeAll { $0.id == id }
    }

    public func updateServingRow(id: String, unit: String? = nil, gramsPerUnit: String? = nil) {
        guard isFormEditable,
              let index = servings.firstIndex(where: { $0.id == id })
        else { return }
        if let unit { servings[index].unit = unit }
        if let gramsPerUnit { servings[index].gramsPerUnit = gramsPerUnit }
    }

    public func formValues() -> CustomFoodFormValues {
        CustomFoodFormValues(
            name: name,
            brand: brand,
            categoriesText: categoriesText,
            defaultQuantity: defaultQuantity,
            defaultUnit: defaultUnit,
            servings: servings.map {
                CustomFoodServingInput(unit: $0.unit, gramsPerUnit: $0.gramsPerUnit)
            },
            nutrientEditor: nutrientEditor
        )
    }

    private func markDirty() {
        guard !isApplyingInitialValues else { return }
        isDirty = true
        if !isReconciliationStoreBlocked {
            submitError = nil
        }
    }
}
