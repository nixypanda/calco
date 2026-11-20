// One-off ad-hoc logging and "save food and log" view model.
//
// Every log write goes through `LibraryLogSubmitting`, which the app shell
// implements with the shared journal handler. This feature never posts logs
// directly and never stores a second idempotency key.

import Combine
import Foundation

public enum AdHocSaveMode: String, CaseIterable, Equatable, Sendable {
    case logOnly
    case saveAndLog
}

public struct AdHocReview: Equatable, Identifiable, Sendable {
    public let id: String
    public let mode: AdHocSaveMode
    public let name: String
    public let amount: String
    public let unit: String
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let draft: LogSubmissionDraft
    public let customFood: CustomFoodWriteRequest?
    public let logIntent: CustomFoodLogIntent?

    public init(
        id: String = UUID().uuidString.lowercased(),
        mode: AdHocSaveMode,
        name: String,
        amount: String,
        unit: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        draft: LogSubmissionDraft,
        customFood: CustomFoodWriteRequest?,
        logIntent: CustomFoodLogIntent?
    ) {
        self.id = id
        self.mode = mode
        self.name = name
        self.amount = amount
        self.unit = unit
        self.date = date
        self.mealSlot = mealSlot
        self.draft = draft
        self.customFood = customFood
        self.logIntent = logIntent
    }
}

@MainActor
public final class AdHocLogViewModel: ObservableObject {
    @Published public private(set) var loadState: LibraryLoadState = .loading
    @Published public private(set) var definitions: [NutrientDefinition] = []
    @Published public private(set) var units: [FoodUnit] = []
    @Published public private(set) var submissionState: LibrarySubmissionState = .idle
    @Published public private(set) var savedFoodLogState: SavedFoodLogState = .none
    @Published public private(set) var isSavingFood = false
    @Published public private(set) var formError: String?
    @Published public private(set) var savedFoodID: String?
    @Published public private(set) var savedFoodName: String?
    @Published public private(set) var savedLogIntent: CustomFoodLogIntent?
    @Published public private(set) var reconciliationAttempt: CustomFoodCreateAttempt?
    @Published public private(set) var reconciliationCandidates: [CustomFood] = []
    @Published public private(set) var reconciliationMessage: String?
    @Published public private(set) var isRefreshingReconciliation = false
    @Published public private(set) var isReconciliationStoreBlocked = false
    @Published public private(set) var isDirty = false
    @Published public var pendingReview: AdHocReview?
    @Published public var hasAttemptedReview = false

    @Published public var name: String = "" { didSet { markDirty() } }
    @Published public var brand: String = "" { didSet { markDirty() } }
    @Published public var date: LocalDiaryDate { didSet { markDirty() } }
    @Published public var mealSlot: MealSlot? { didSet { markDirty() } }
    @Published public var amount: String = "100" {
        didSet {
            guard amount != oldValue else { return }
            markDirty()
            assistantAmountDidChange()
        }
    }
    @Published public var unit: String = "g" {
        didSet {
            guard unit != oldValue else { return }
            markDirty()
            assistantUnitDidChange()
        }
    }
    @Published public var notes: String = "" { didSet { markDirty() } }
    @Published public var portionWeightText: String = "" {
        didSet {
            guard portionWeightText != oldValue else { return }
            markDirty()
            assistantPortionWeightDidChange()
        }
    }
    @Published public var mode: AdHocSaveMode = .logOnly { didSet { markDirty() } }
    @Published public var nutrientEditor: NutrientEditorState

    public let accountID: String
    public let today: LocalDiaryDate

    private let service: any LibraryServicing
    private let submissionService: any LibraryLogSubmitting
    private let engine: CustomFoodReconciliationEngine
    private let reconciliationStore: CustomFoodReconciliationStore
    private let baseURL: URL?
    private let timeZoneProvider: () -> String
    private let onLogged: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void
    private let onReviewPending: () -> Void
    private let onOpenLibrary: () -> Void
    private let initialAssistantDraft: AssistantReviewedDraft?

    private var isApplyingInitialValues = false
    private var hasAppliedInitialAssistantDraft = false
    private var isApplyingAssistantConversion = false
    private var assistantServingGrams: [String: Decimal] = [:]
    private var assistantPortionWeightGrams: Decimal?
    private var assistantQuantityNeedsReview = false
    private var savedLogAttemptID: String?
    private var latestIssuedReviewID: String?
    private var consumedReviewIDs: Set<String> = []
    private var loadGeneration = 0

    public init(
        service: any LibraryServicing,
        submissionService: any LibraryLogSubmitting,
        reconciliationStore: CustomFoodReconciliationStore,
        accountID: String,
        initialDate: LocalDiaryDate,
        today: LocalDiaryDate,
        initialMealSlot: MealSlot? = nil,
        baseURL: URL? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        onReviewPending: @escaping () -> Void = {},
        onOpenLibrary: @escaping () -> Void = {},
        assistantDraft: AssistantReviewedDraft? = nil
    ) {
        self.service = service
        self.submissionService = submissionService
        self.reconciliationStore = reconciliationStore
        self.accountID = accountID
        self.today = today
        self.baseURL = baseURL
        self.timeZoneProvider = timeZoneProvider
        self.onLogged = onLogged
        self.onSessionExpired = onSessionExpired
        self.onReviewPending = onReviewPending
        self.onOpenLibrary = onOpenLibrary
        self.initialAssistantDraft = assistantDraft
        self.engine = CustomFoodReconciliationEngine(
            service: service,
            store: reconciliationStore,
            accountID: accountID
        )
        self.date = min(initialDate, today)
        self.mealSlot = initialMealSlot
        self.nutrientEditor = NutrientEditorState(definitions: [])
    }

    public var isBusy: Bool {
        isSavingFood
            || submissionState == .submitting
            || savedFoodLogState == .logging
            || isRefreshingReconciliation
    }

    public var isSubmissionCompleted: Bool {
        if case .completed = submissionState { return true }
        return false
    }

    public var isSubmissionPending: Bool {
        if case .pending = submissionState { return true }
        return false
    }

    public var hasLoggedSavedFood: Bool {
        if case .logged = savedFoodLogState { return true }
        return false
    }

    public var completedSubmissionLogID: String? {
        if case .completed(let logID, _) = submissionState { return logID }
        return nil
    }

    public var isFormDisabled: Bool {
        isBusy || isSubmissionCompleted || isSubmissionPending || savedFoodID != nil
    }

    public var hasUnsavedChanges: Bool {
        isDirty && savedFoodID == nil && !isBusy
    }

    public var isReconciling: Bool { reconciliationAttempt != nil }

    public var canReview: Bool {
        guard case .loaded = loadState else { return false }
        if mode == .saveAndLog, isReconciliationStoreBlocked {
            return false
        }
        return !isBusy
            && !isSubmissionCompleted
            && !isSubmissionPending
            && savedFoodID == nil
    }

    public var requiresPortionWeight: Bool {
        mode == .saveAndLog
            && unit.trimmingCharacters(in: .whitespacesAndNewlines) != "g"
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        formError = nil
        assistantServingGrams = [:]
        assistantPortionWeightGrams = nil
        assistantQuantityNeedsReview = false
        do {
            async let definitionsTask = service.nutrientDefinitions()
            async let unitsTask = service.units()
            let (loadedDefinitions, productUnits) = try await (definitionsTask, unitsTask)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            definitions = loadedDefinitions
            var foodUnits = productUnits.map {
                FoodUnit(code: $0.code, name: $0.name, kind: $0.kind)
            }
            if !foodUnits.contains(where: { $0.code == "g" }) {
                foodUnits.insert(FoodUnit(code: "g", name: "Gram"), at: 0)
            }
            units = foodUnits
            isApplyingInitialValues = true
            nutrientEditor = NutrientEditorState(definitions: loadedDefinitions)
            if !units.contains(where: { $0.code == unit }) {
                unit = "g"
            }
            isApplyingInitialValues = false
            isDirty = false
            loadState = .loaded
            loadPendingReconciliation()
            if let draft = initialAssistantDraft,
               !hasAppliedInitialAssistantDraft,
               draft.purpose == .adHocLog {
                hasAppliedInitialAssistantDraft = true
                if !applyAssistantDraft(draft) {
                    formError = String(localized: "library.assistant.prefillFailed")
                }
            }
        } catch let error as CustomFoodServiceError {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if error.isUnauthorized {
                onSessionExpired()
            }
            loadState = .failed(error.message)
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            loadState = .failed(String(localized: "library.adHoc.loadFailed"))
        }
    }

    private func loadPendingReconciliation() {
        do {
            guard let attempt = try engine.loadAttempt() else {
                reconciliationAttempt = nil
                isReconciliationStoreBlocked = false
                return
            }
            if let foodID = attempt.foodID, let intent = attempt.logIntent {
                savedFoodID = foodID
                savedFoodName = attempt.displayName
                savedLogIntent = intent
                savedLogAttemptID = attempt.id
                savedFoodLogState = .retryable(
                    message: attempt.message.isEmpty
                        ? String(localized: "library.log.resumeMessage")
                        : attempt.message
                )
                reconciliationAttempt = nil
                reconciliationCandidates = []
                reconciliationMessage = nil
                isDirty = false
                isReconciliationStoreBlocked = false
                return
            }
            if attempt.foodID != nil, attempt.logIntent == nil {
                try? engine.completeLogHandoff(attemptID: attempt.id)
                reconciliationAttempt = nil
                isReconciliationStoreBlocked = false
                return
            }
            reconciliationAttempt = attempt
            isReconciliationStoreBlocked = false
        } catch {
            reconciliationAttempt = nil
            isReconciliationStoreBlocked = true
            formError = String(localized: "library.reconcile.storeUnavailable")
        }
    }

    public func requestReview() {
        guard canReview else { return }
        hasAttemptedReview = true
        formError = nil
        if assistantQuantityNeedsReview {
            formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        let values = formValues()
        let draft: LogSubmissionDraft
        switch values.validate(timeZone: timeZoneProvider()) {
        case .failure(let error):
            formError = error.message(definitions: definitions)
            return
        case .success(let validated):
            draft = validated
        }

        var customFood: CustomFoodWriteRequest?
        var logIntent: CustomFoodLogIntent?
        if mode == .saveAndLog {
            guard !isReconciliationStoreBlocked else {
                formError = String(localized: "library.reconcile.storeUnavailable")
                return
            }
            guard reconciliationAttempt == nil else {
                formError = String(localized: "library.reconcile.pendingBlocksSave")
                return
            }
            switch values.makeCustomFoodWriteRequest(
                portionWeightText: portionWeightText
            ) {
            case .failure(let error):
                formError = error.message(definitions: definitions)
                return
            case .success(let request):
                customFood = request
            }
            switch values.logIntent(timeZone: timeZoneProvider()) {
            case .failure(let error):
                formError = error.message(definitions: definitions)
                return
            case .success(let intent):
                logIntent = intent
            }
        }

        let review = AdHocReview(
            mode: mode,
            name: values.name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: draft.amount,
            unit: draft.unit,
            date: draft.date,
            mealSlot: draft.mealSlot,
            draft: draft,
            customFood: customFood,
            logIntent: logIntent
        )
        latestIssuedReviewID = review.id
        pendingReview = review
    }

    public func confirmReview() async {
        guard let review = pendingReview else { return }
        await confirmReview(review)
    }

    /// Uses the review captured by the alert action. SwiftUI may clear the
    /// item binding while dismissing the alert, so the action must not depend
    /// on `pendingReview` still being set.
    public func confirmReview(_ review: AdHocReview) async {
        // Busy is checked before touching pendingReview so a stale alert cannot
        // dismiss current work.
        guard !isBusy,
              !isSubmissionCompleted,
              !isSubmissionPending,
              savedFoodID == nil else {
            return
        }
        if let pending = pendingReview, pending.id != review.id {
            return
        }
        // Only the most recently issued review may write. Keeping the latest
        // ID lets a captured review still work after SwiftUI clears its item
        // binding, while rejecting an older alert even when the binding is nil.
        guard latestIssuedReviewID == review.id,
              !consumedReviewIDs.contains(review.id) else {
            return
        }
        if pendingReview?.id == review.id {
            pendingReview = nil
        }
        // Main-actor reservation happens before any await, so duplicate alert
        // actions or concurrent callers cannot submit the same logical review
        // twice, even after completion.
        consumedReviewIDs.insert(review.id)
        formError = nil
        switch review.mode {
        case .logOnly:
            await submitAdHoc(review.draft, name: review.name)
        case .saveAndLog:
            guard let customFood = review.customFood,
                  let logIntent = review.logIntent
            else {
                formError = String(localized: "library.adHoc.error.saveSetup")
                return
            }
            await createFoodAndLog(
                request: customFood,
                logIntent: logIntent,
                name: review.name
            )
        }
    }

    private func submitAdHoc(_ draft: LogSubmissionDraft, name: String) async {
        submissionState = .submitting
        let result = await submissionService.submit(
            accountID: accountID,
            drafts: [draft],
            itemNames: [name],
            summary: name,
            baseURL: baseURL
        )
        handleSubmissionResult(result, date: draft.date, mealSlot: draft.mealSlot)
    }

    private func createFoodAndLog(
        request: CustomFoodWriteRequest,
        logIntent: CustomFoodLogIntent,
        name: String
    ) async {
        isSavingFood = true
        defer { isSavingFood = false }

        let baseline: [CustomFood]
        do {
            baseline = try await service.listCustomFoods()
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                onSessionExpired()
            }
            formError = error.message
            return
        } catch {
            formError = String(localized: "library.error.load")
            return
        }

        let result = await engine.create(
            draft: request,
            baselineFoodIDs: baseline.map(\.id),
            logIntent: logIntent,
            logBaseURL: baseURL
        )
        switch result {
        case .saved(let foodID):
            savedFoodID = foodID
            savedFoodName = name
            savedLogIntent = logIntent
            savedLogAttemptID = (try? engine.currentAttempt())?.id
            isDirty = false
            await submitSavedFoodLog(foodID: foodID, intent: logIntent)
        case .needsReconciliation(let attempt):
            reconciliationAttempt = attempt
            reconciliationCandidates = []
            reconciliationMessage = nil
            await refreshReconciliationCandidates()
        case .failed(let error):
            if error.isUnauthorized {
                onSessionExpired()
            }
            formError = error.message
        case .blocked(let message):
            formError = message
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
            savedFoodLogState = .pending(
                message: String(localized: "library.log.savedOnly")
            )
        }
    }

    public func discardReconciliation() {
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
    }

    public func resetUnreadableReconciliation() {
        do {
            try engine.resetUnreadableState()
            reconciliationAttempt = nil
            reconciliationCandidates = []
            reconciliationMessage = nil
            isReconciliationStoreBlocked = false
        } catch {
            formError = String(localized: "library.reconcile.storeUnavailable")
        }
    }

    // MARK: Saved-food logging

    /// Only a definitively rejected log may be submitted again. Uncertain,
    /// conflicting, or unavailable journal states are recovered through the
    /// shell's shared pending-log review.
    public func retrySavedFoodLog() async {
        guard let foodID = savedFoodID, let intent = savedLogIntent else { return }
        switch savedFoodLogState {
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
            savedFoodLogState = .retryable(
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
            savedFoodLogState = .retryable(
                message: String(localized: "library.reconcile.storeUnavailable")
            )
            return
        }

        savedFoodLogState = .logging
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
            finishLogHandoff(attemptID)
            let logID = logs.first?.id
            savedFoodLogState = .logged(logID: logID, replayed: replayed)
            submissionState = .completed(logID: logID, replayed: replayed)
            isDirty = false
            onLogged(intent.date, intent.mealSlot)
        case .failure(.uncertain(let message)):
            savedFoodLogState = .pending(message: message)
        case .failure(.conflict(let message)):
            savedFoodLogState = .pending(message: message)
        case .failure(.unauthorized):
            savedFoodLogState = .pending(
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
            savedFoodLogState = .retryable(message: message)
        }
    }

    private func finishLogHandoff(_ attemptID: String) {
        try? engine.completeLogHandoff(attemptID: attemptID)
        savedLogAttemptID = nil
    }

    private func handleSubmissionResult(
        _ result: LogSubmissionServiceResult,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
        switch result {
        case .success(let logs, let replayed):
            submissionState = .completed(
                logID: logs.first?.id,
                replayed: replayed
            )
            isDirty = false
            onLogged(date, mealSlot)
        case .failure(.rejected(let message)):
            submissionState = .failed(message: message)
        case .failure(.missingComponents(let message)):
            submissionState = .failed(message: message)
        case .failure(.unauthorized):
            submissionState = .pending(
                message: String(localized: "foodDetail.error.sessionExpired")
            )
            onSessionExpired()
        case .failure(.uncertain(let message)):
            submissionState = .pending(message: message)
        case .failure(.conflict(let message)):
            submissionState = .pending(message: message)
        case .failure(.serverChanged(let message)),
             .failure(.reconciliationOnly(let message)):
            submissionState = .pending(message: message)
        case .failure(.capabilityUnavailable(let message)),
             .failure(.capabilityTemporarilyUnavailable(let message)):
            submissionState = .failed(message: message)
        case .failure(.journalUnavailable(let message)):
            // Reservation failed before the POST; resubmission is safe.
            submissionState = .failed(message: message)
        }
    }

    public func reviewPendingLogs() {
        onReviewPending()
    }

    public func openLibrary() {
        onOpenLibrary()
    }

    // MARK: Form

    /// Applies a fully typed reviewed assistant draft using absolute nutrients
    /// scaled to the suggested log weight. The amount/unit stays editable.
    @discardableResult
    public func applyAssistantDraft(_ draft: AssistantReviewedDraft) -> Bool {
        guard draft.purpose == .adHocLog,
              loadState == .loaded,
              !isBusy,
              savedFoodID == nil else {
            return false
        }
        let unitsByCode = Dictionary(
            nutrientEditor.definitions.map { ($0.code, $0.unit) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let quantity = draft.suggestedLogQuantity,
              let nutrients = draft.scaledNutrientsForSuggestedLog(
                unitsByCode: unitsByCode
              )
        else { return false }
        var mergedUnits = units
        var servingGrams: [String: Decimal] = [:]
        for serving in draft.servings {
            if let grams = CatalogDecimal.parseNonNegative(serving.gramsPerUnit),
               grams > 0 {
                servingGrams[serving.unit] = grams
            }
            if !mergedUnits.contains(where: { $0.code == serving.unit }) {
                mergedUnits.append(
                    FoodUnit(
                        code: serving.unit,
                        name: serving.unit.capitalized,
                        kind: "serving"
                    )
                )
            }
        }
        units = mergedUnits
        assistantServingGrams = servingGrams
        assistantPortionWeightGrams = draft.suggestedLog.flatMap {
            CatalogDecimal.parseNonNegative($0.totalWeightGrams)
        }

        isApplyingInitialValues = true
        isApplyingAssistantConversion = true
        name = draft.name
        brand = draft.brand ?? ""
        self.amount = quantity.amount
        self.unit = quantity.unit
        portionWeightText = draft.suggestedLog?.totalWeightGrams ?? ""
        nutrientEditor = NutrientEditorState(
            definitions: nutrientEditor.definitions,
            initial: nutrients
        )
        assistantQuantityNeedsReview = false
        isApplyingAssistantConversion = false
        isApplyingInitialValues = false
        isDirty = true
        return true
    }

    // MARK: Assistant serving conversion

    private func gramsPerUnit(for unit: String) -> Decimal? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "g" { return 1 }
        return assistantServingGrams[trimmed]
    }

    private func assistantAmountDidChange() {
        guard !isApplyingInitialValues,
              !isApplyingAssistantConversion,
              let oldWeight = assistantPortionWeightGrams,
              oldWeight > 0,
              let amountValue = CatalogDecimal.parseNonNegative(
                  amount.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              amountValue > 0,
              let factor = gramsPerUnit(for: unit) else { return }
        let newWeight = CatalogDecimal.round(amountValue * factor)
        guard newWeight > 0 else { return }
        rescaleNutrients(from: oldWeight, to: newWeight)
        assistantPortionWeightGrams = newWeight
        setPortionWeightTextWithoutNotify(CatalogDecimal.canonical(newWeight))
        assistantQuantityNeedsReview = false
    }

    private func assistantUnitDidChange() {
        guard !isApplyingInitialValues,
              !isApplyingAssistantConversion,
              let weight = assistantPortionWeightGrams,
              weight > 0 else { return }
        guard let factor = gramsPerUnit(for: unit), factor > 0 else {
            assistantQuantityNeedsReview = true
            formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        let newAmount = CatalogDecimal.round(weight / factor)
        guard newAmount > 0 else {
            assistantQuantityNeedsReview = true
            formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        setAmountWithoutNotify(CatalogDecimal.canonical(newAmount))
        setPortionWeightTextWithoutNotify(CatalogDecimal.canonical(weight))
        assistantQuantityNeedsReview = false
    }

    private func assistantPortionWeightDidChange() {
        guard !isApplyingInitialValues,
              !isApplyingAssistantConversion,
              let oldWeight = assistantPortionWeightGrams,
              oldWeight > 0,
              let newWeight = CatalogDecimal.parseNonNegative(
                  portionWeightText.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              newWeight > 0 else { return }
        guard let factor = gramsPerUnit(for: unit), factor > 0 else {
            assistantQuantityNeedsReview = true
            formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        rescaleNutrients(from: oldWeight, to: newWeight)
        assistantPortionWeightGrams = newWeight
        let newAmount = CatalogDecimal.round(newWeight / factor)
        guard newAmount > 0 else {
            assistantQuantityNeedsReview = true
            formError = String(localized: "library.adHoc.error.unitConversion")
            return
        }
        setAmountWithoutNotify(CatalogDecimal.canonical(newAmount))
        assistantQuantityNeedsReview = false
    }

    private func rescaleNutrients(from oldWeight: Decimal, to newWeight: Decimal) {
        guard oldWeight > 0, newWeight > 0, oldWeight != newWeight else { return }
        let ratio = newWeight / oldWeight
        var editor = nutrientEditor
        for row in editor.rows {
            guard let value = CatalogDecimal.parseNonNegative(row.amount) else { continue }
            editor.setAmount(
                CatalogDecimal.canonical(CatalogDecimal.round(value * ratio)),
                for: row.code
            )
        }
        nutrientEditor = editor
    }

    private func setAmountWithoutNotify(_ value: String) {
        isApplyingAssistantConversion = true
        amount = value
        isApplyingAssistantConversion = false
    }

    private func setPortionWeightTextWithoutNotify(_ value: String) {
        isApplyingAssistantConversion = true
        portionWeightText = value
        isApplyingAssistantConversion = false
    }

    public func setNutrientAmount(_ amount: String, code: String) {
        guard canReview else { return }
        isApplyingInitialValues = true
        nutrientEditor.setAmount(amount, for: code)
        isApplyingInitialValues = false
        markDirty()
    }

    public func addOptionalNutrient(code: String) {
        guard canReview else { return }
        isApplyingInitialValues = true
        nutrientEditor.addOptional(code: code)
        isApplyingInitialValues = false
        markDirty()
    }

    public func removeNutrient(code: String) {
        guard canReview else { return }
        isApplyingInitialValues = true
        nutrientEditor.remove(code: code)
        isApplyingInitialValues = false
        markDirty()
    }

    public func setDate(_ picked: Date) {
        guard let day = DiaryDateConversion.day(from: picked) else { return }
        date = min(day, today)
    }

    public func formValues() -> AdHocLogFormValues {
        AdHocLogFormValues(
            name: name,
            brand: brand,
            date: date,
            mealSlot: mealSlot,
            amount: amount,
            unit: unit,
            notes: notes,
            nutrientEditor: nutrientEditor
        )
    }

    public func clearFormError() {
        formError = nil
    }

    private func markDirty() {
        guard !isApplyingInitialValues else { return }
        isDirty = true
        if !isReconciliationStoreBlocked {
            formError = nil
        }
    }
}
