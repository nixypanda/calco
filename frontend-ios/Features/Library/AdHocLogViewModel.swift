// One-off ad-hoc logging and "save food and log" view model.
//
// Log writes go through `LibraryLogSubmitting`, which the app shell adapts to
// the shared submission handler. A saved food ID is retained only in memory so
// an explicit retry logs that food instead of creating another catalog entry.

import Combine
import Foundation

public enum AdHocSaveMode: String, CaseIterable, Equatable, Sendable {
    case logOnly
    case saveAndLog
}

/// In-memory intent for logging a custom food returned by a successful create.
public struct SavedFoodLogIntent: Equatable, Sendable {
    public let date: LocalDiaryDate
    public let mealSlot: MealSlot?
    public let amount: String
    public let unit: String
    public let notes: String?
    public let timeZone: String

    public init(
        date: LocalDiaryDate,
        mealSlot: MealSlot?,
        amount: String,
        unit: String,
        notes: String?,
        timeZone: String
    ) {
        self.date = date
        self.mealSlot = mealSlot
        self.amount = amount
        self.unit = unit
        self.notes = notes
        self.timeZone = timeZone
    }

    public func logSubmissionDraft(productID: String) -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: .product(id: productID),
            date: date,
            mealSlot: mealSlot,
            amount: amount,
            unit: unit,
            notes: notes,
            timeZone: timeZone
        )
    }
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
    public let logIntent: SavedFoodLogIntent?

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
        logIntent: SavedFoodLogIntent?
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
    @Published public private(set) var savedLogIntent: SavedFoodLogIntent?
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
    private let baseURL: URL?
    private let timeZoneProvider: () -> String
    private let onLogged: (LocalDiaryDate, MealSlot?) -> Void
    private let onSessionExpired: () -> Void
    private let initialAssistantDraft: AssistantReviewedDraft?

    private var isApplyingInitialValues = false
    private var hasAppliedInitialAssistantDraft = false
    private var isApplyingAssistantConversion = false
    private var assistantServingGrams: [String: Decimal] = [:]
    private var assistantPortionWeightGrams: Decimal?
    private var assistantQuantityNeedsReview = false
    private var latestIssuedReviewID: String?
    private var loadGeneration = 0

    public init(
        service: any LibraryServicing,
        submissionService: any LibraryLogSubmitting,
        accountID: String,
        initialDate: LocalDiaryDate,
        today: LocalDiaryDate,
        initialMealSlot: MealSlot? = nil,
        baseURL: URL? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in },
        onSessionExpired: @escaping () -> Void = {},
        assistantDraft: AssistantReviewedDraft? = nil
    ) {
        self.service = service
        self.submissionService = submissionService
        self.accountID = accountID
        self.today = today
        self.baseURL = baseURL
        self.timeZoneProvider = timeZoneProvider
        self.onLogged = onLogged
        self.onSessionExpired = onSessionExpired
        self.initialAssistantDraft = assistantDraft
        self.date = min(initialDate, today)
        self.mealSlot = initialMealSlot
        self.nutrientEditor = NutrientEditorState(definitions: [])
    }

    public var isBusy: Bool {
        isSavingFood
            || submissionState == .submitting
            || savedFoodLogState == .logging
    }

    public var isSubmissionCompleted: Bool {
        if case .completed = submissionState { return true }
        return false
    }

    public var hasLoggedSavedFood: Bool {
        if case .logged = savedFoodLogState { return true }
        return false
    }

    public var completedSubmissionLogID: String? {
        if case .completed(let logID) = submissionState { return logID }
        return nil
    }

    public var isFormDisabled: Bool {
        isBusy || isSubmissionCompleted || savedFoodID != nil
    }

    public var hasUnsavedChanges: Bool {
        isDirty && savedFoodID == nil && !isBusy
    }

    public var canReview: Bool {
        guard case .loaded = loadState else { return false }
        return !isBusy
            && !isSubmissionCompleted
            && savedFoodID == nil
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
        var logIntent: SavedFoodLogIntent?
        if mode == .saveAndLog {
            switch values.makeCustomFoodWriteRequest(
                portionWeightText: portionWeightText
            ) {
            case .failure(let error):
                formError = error.message(definitions: definitions)
                return
            case .success(let request):
                customFood = request
            }
            switch values.savedFoodLogIntent(timeZone: timeZoneProvider()) {
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
    /// on `pendingReview` still being set. A second concurrent action is
    /// rejected by `isBusy` before any network call starts.
    public func confirmReview(_ review: AdHocReview) async {
        guard !isBusy,
              !isSubmissionCompleted,
              savedFoodID == nil else {
            return
        }
        if let pending = pendingReview, pending.id != review.id {
            return
        }
        guard latestIssuedReviewID == review.id else { return }
        if pendingReview?.id == review.id {
            pendingReview = nil
        }
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
        handleAdHocResult(result, date: draft.date, mealSlot: draft.mealSlot)
    }

    private func createFoodAndLog(
        request: CustomFoodWriteRequest,
        logIntent: SavedFoodLogIntent,
        name: String
    ) async {
        isSavingFood = true
        defer { isSavingFood = false }

        do {
            let foodID = try await service.createCustomFood(request)
            savedFoodID = foodID
            savedFoodName = name
            savedLogIntent = logIntent
            isDirty = false
            await submitSavedFoodLog(foodID: foodID, intent: logIntent)
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                onSessionExpired()
            }
            if case .uncertain = error {
                formError = String(
                    localized: "library.editor.create.uncertain",
                    defaultValue: "CalCo couldn't confirm whether this food was saved. Check the library before trying again."
                )
            } else {
                formError = error.message
            }
        } catch {
            formError = String(localized: "foodDetail.error.saveFailed")
        }
    }

    // MARK: Saved-food logging

    /// A failed or unconfirmed log can be explicitly retried for the retained
    /// food. The catalog create is never repeated.
    public func retrySavedFoodLog() async {
        guard let foodID = savedFoodID, let intent = savedLogIntent else { return }
        switch savedFoodLogState {
        case .failed:
            await submitSavedFoodLog(foodID: foodID, intent: intent)
        case .none, .logging, .logged:
            break
        }
    }

    private func submitSavedFoodLog(
        foodID: String,
        intent: SavedFoodLogIntent
    ) async {
        savedFoodLogState = .logging
        let draft = intent.logSubmissionDraft(productID: foodID)
        let name = savedFoodName ?? foodID
        let result = await submissionService.submit(
            accountID: accountID,
            drafts: [draft],
            itemNames: [name],
            summary: name,
            baseURL: baseURL
        )
        handleSavedFoodLogResult(result, intent: intent)
    }

    private func handleSavedFoodLogResult(
        _ result: LogSubmissionServiceResult,
        intent: SavedFoodLogIntent
    ) {
        switch result {
        case .success(let logs):
            let logID = logs.first?.id
            savedFoodLogState = .logged(logID: logID)
            submissionState = .completed(logID: logID)
            isDirty = false
            onLogged(intent.date, intent.mealSlot)
        case .failure(.unauthorized):
            savedFoodLogState = .failed(
                message: String(localized: "foodDetail.error.sessionExpired")
            )
            onSessionExpired()
        case .failure(.uncertain):
            savedFoodLogState = .failed(message: uncertainLogMessage())
        case .failure(.failed(let message)):
            savedFoodLogState = .failed(message: message)
        }
    }

    private func handleAdHocResult(
        _ result: LogSubmissionServiceResult,
        date: LocalDiaryDate,
        mealSlot: MealSlot?
    ) {
        switch result {
        case .success(let logs):
            submissionState = .completed(logID: logs.first?.id)
            isDirty = false
            onLogged(date, mealSlot)
        case .failure(.unauthorized):
            submissionState = .failed(
                message: String(localized: "foodDetail.error.sessionExpired")
            )
            onSessionExpired()
        case .failure(.uncertain):
            submissionState = .failed(message: uncertainLogMessage())
        case .failure(.failed(let message)):
            submissionState = .failed(message: message)
        }
    }

    private func uncertainLogMessage() -> String {
        String(
            localized: "library.log.uncertain",
            defaultValue: "CalCo couldn't confirm this log. Check the library and diary before retrying."
        )
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
        formError = nil
    }
}
