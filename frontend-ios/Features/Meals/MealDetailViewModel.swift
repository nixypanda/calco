// Meal detail state: recipe load, component-name resolution, server portion
// preview, deletion, and logging.

import Combine
import Foundation

@MainActor
public final class MealDetailViewModel: ObservableObject {
    @Published public private(set) var loadState: MealDetailLoadState = .loading
    @Published public private(set) var componentNames: [String: String] = [:]
    @Published public private(set) var missingComponentIDs: Set<String> = []
    @Published public private(set) var units: [ProductUnit] = []
    @Published public private(set) var previewState: MealPortionPreviewState = .idle
    @Published public private(set) var deleteState: MealDeleteState = .idle
    @Published public private(set) var logState: MealLogState = .idle
    @Published public private(set) var unitFallbackNotice: String?
    @Published public private(set) var portionFallbackNotice: String?

    @Published public var portionAmount: String = "100" {
        didSet {
            guard portionAmount != oldValue else { return }
            if !isApplyingPortionDefault {
                portionWasEdited = true
            }
            schedulePreview()
        }
    }
    @Published public var portionUnit: String = "g" {
        didSet {
            guard portionUnit != oldValue else { return }
            if !isApplyingPortionDefault {
                portionWasEdited = true
            }
            schedulePreview()
        }
    }
    @Published public var mealSlot: MealSlot? {
        didSet { if mealSlot != oldValue { logState = .idle } }
    }
    @Published public var logNotes: String = ""

    public let mealID: String
    public let date: LocalDiaryDate

    private let service: MealsServicing
    private let onSubmitDrafts: LogSubmissionHandler?
    private let onSessionExpired: () -> Void
    private let onDeleted: (() -> Void)?
    private let onLogged: ((LocalDiaryDate, MealSlot?) -> Void)?
    private let fallbackName: String?
    private let preferredPortion: NutritionQuantity?
    private let timeZoneProvider: () -> String
    private let previewDebounceNanoseconds: UInt64

    private var loadedMeal: Meal?
    private var loadToken = 0
    private var previewToken = 0
    private var previewTask: Task<Void, Never>?
    private var lastUsedTask: Task<Void, Never>?
    private var portionWasEdited = false
    private var isApplyingPortionDefault = false
    public init(
        mealID: String,
        date: LocalDiaryDate,
        mealSlot: MealSlot? = nil,
        mealName: String? = nil,
        initialPortion: NutritionQuantity? = nil,
        service: MealsServicing,
        onSubmitDrafts: LogSubmissionHandler? = nil,
        onSessionExpired: @escaping () -> Void = {},
        onDeleted: (() -> Void)? = nil,
        onLogged: ((LocalDiaryDate, MealSlot?) -> Void)? = nil,
        timeZoneProvider: @escaping () -> String = { TimeZone.current.identifier },
        previewDebounceNanoseconds: UInt64 = 300_000_000
    ) {
        self.mealID = mealID
        self.date = date
        self.fallbackName = mealName
        self.preferredPortion = initialPortion
        self.service = service
        self.onSubmitDrafts = onSubmitDrafts
        self.onSessionExpired = onSessionExpired
        self.onDeleted = onDeleted
        self.onLogged = onLogged
        self.timeZoneProvider = timeZoneProvider
        self.previewDebounceNanoseconds = previewDebounceNanoseconds
        self.mealSlot = mealSlot
    }

    public var meal: Meal? { loadedMeal }

    public var displayName: String {
        loadedMeal?.name ?? fallbackName ?? String(localized: "meals.detail.title")
    }

    public var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    public var canLog: Bool {
        onSubmitDrafts != nil
            && loadedMeal != nil
            && loadedMeal?.isDegraded != true
            && !isLogging
            && !isDeleting
    }

    public var isLogging: Bool {
        if case .submitting = logState { return true }
        return false
    }

    public var isDeleting: Bool {
        if case .deleting = deleteState { return true }
        return false
    }

    public var didLog: Bool {
        if case .succeeded = logState { return true }
        return false
    }

    public var availableUnits: [ProductUnit] {
        MealQuantityRules.massUnits(from: units)
    }

    /// Shared `LogFormView` uses its existing food-unit value type.
    public var logFormUnits: [FoodUnit] {
        availableUnits.map { unit in
            FoodUnit(code: unit.code, name: unit.name, kind: unit.kind)
        }
    }

    public var amountValidationMessage: String? {
        let trimmedAmount = portionAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAmount.isEmpty {
            return String(localized: "meals.error.amountRequired")
        }
        guard MealQuantityRules.normalizedPositiveDecimal(trimmedAmount) != nil else {
            return String(localized: "meals.error.amountInvalid")
        }
        let trimmedUnit = portionUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUnit.isEmpty {
            return String(localized: "meals.error.unitRequired")
        }
        if !MealQuantityRules.isMassUnit(trimmedUnit) {
            return String(localized: "meals.error.portionUnit")
        }
        return nil
    }

    public var logErrorMessage: String? {
        if case .failed(let message) = logState { return message }
        return nil
    }

    public var deleteErrorMessage: String? {
        if case .failed(let message) = deleteState { return message }
        return nil
    }

    public var missingComponentsMessage: String? {
        guard !missingComponentIDs.isEmpty else { return nil }
        return String(localized: "meals.detail.missingComponents")
    }

    public func componentName(_ component: MealComponent) -> String {
        if component.missing {
            return component.name ?? String(localized: "meals.editor.missingFood")
        }
        if missingComponentIDs.contains(component.item.id) {
            return String(localized: "meals.editor.missingFood")
        }
        if let name = componentNames[component.item.id], !name.isEmpty {
            return name
        }
        return String(localized: "meals.editor.unknownFood")
    }

    public func loadIfNeeded() async {
        guard loadedMeal == nil else { return }
        await load()
    }

    public func load() async {
        previewTask?.cancel()
        previewTask = nil
        lastUsedTask?.cancel()
        lastUsedTask = nil
        previewToken += 1
        loadToken += 1
        let token = loadToken
        loadState = .loading
        componentNames = [:]
        missingComponentIDs = []
        previewState = .idle
        unitFallbackNotice = nil
        portionFallbackNotice = nil
        portionWasEdited = false

        do {
            async let mealTask = service.getMeal(id: mealID)
            async let unitsTask = service.fetchUnits()
            let meal = try await mealTask
            let fetchedUnits = try? await unitsTask
            guard token == loadToken else { return }

            if let fetchedUnits, !fetchedUnits.isEmpty {
                units = fetchedUnits
            } else {
                units = [ProductUnit(code: "g", name: "Gram", kind: "mass")]
                unitFallbackNotice = String(localized: "meals.editor.unitFallback")
            }

            loadedMeal = meal
            missingComponentIDs = Set(
                meal.components.filter(\.missing).map { $0.item.id }
            )
            for component in meal.components where component.missing {
                componentNames[component.item.id] = component.name
                    ?? String(localized: "meals.editor.missingFood")
            }
            applyDefaultPortion(for: meal)
            loadState = .loaded
            if preferredPortion == nil {
                startLastUsedPortionLookup(token: token)
            }
            await resolveComponentNames(for: meal, token: token)
            guard token == loadToken else { return }
            schedulePreview(immediate: true)
        } catch {
            guard token == loadToken else { return }
            if isUnauthorizedMealError(error) {
                onSessionExpired()
                loadState = .failed(
                    message: String(localized: "meals.error.sessionExpired"),
                    missingComponents: false
                )
                return
            }
            if let mealError = error as? MealServiceError,
               case .cancelled = mealError {
                loadState = .failed(
                    message: String(localized: "meals.error.loadFailed"),
                    missingComponents: false
                )
                return
            }
            let message = mealServiceMessage(error)
            loadState = .failed(
                message: message.isEmpty
                    ? String(localized: "meals.error.loadFailed")
                    : message,
                missingComponents: isMissingComponentsMealError(error)
            )
        }
    }

    public func retryLoad() async {
        await load()
    }

    public func portionAmountChanged(_ value: String) {
        portionAmount = value
    }

    public func portionUnitChanged(_ value: String) {
        portionUnit = value
    }

    public func mealSlotChanged(_ value: MealSlot?) {
        mealSlot = value
    }

    public func logNotesChanged(_ value: String) {
        logNotes = value
    }

    public func refreshPreview() {
        schedulePreview(immediate: true)
    }

    public func logMeal() {
        guard let meal = loadedMeal,
              let onSubmitDrafts,
              !isLogging,
              !isDeleting,
              amountValidationMessage == nil else { return }
        guard let draft = MealLogDraftBuilder.makeDraft(
            meal: meal,
            date: date,
            mealSlot: mealSlot,
            amount: portionAmount,
            unit: portionUnit,
            notes: logNotes,
            timeZone: timeZoneProvider()
        ) else {
            logState = .failed(String(localized: "meals.error.invalidPortion"))
            return
        }

        logState = .submitting
        onSubmitDrafts([draft], [meal.name], meal.name) { [weak self] result in
            Task { @MainActor in
                self?.finishLog(result)
            }
        }
    }

    public func dismissLogResult() {
        switch logState {
        case .succeeded, .failed:
            logState = .idle
        case .idle, .submitting:
            break
        }
    }

    public func deleteMeal() async {
        guard !isDeleting else { return }
        deleteState = .deleting
        do {
            try await service.deleteMeal(id: mealID)
            deleteState = .deleted
            onDeleted?()
        } catch {
            if isUnauthorizedMealError(error) {
                onSessionExpired()
                deleteState = .failed(String(localized: "meals.error.sessionExpired"))
                return
            }
            if let mealError = error as? MealServiceError,
               case .notFound = mealError {
                // Already gone: the user's intent is satisfied and there is no
                // log snapshot to rewrite here.
                deleteState = .deleted
                onDeleted?()
                return
            }
            if let mealError = error as? MealServiceError,
               case .cancelled = mealError {
                deleteState = .idle
                return
            }
            let message = mealServiceMessage(error)
            deleteState = .failed(
                message.isEmpty
                    ? String(localized: "meals.error.deleteFailed")
                    : message
            )
        }
    }

    private func applyDefaultPortion(for meal: Meal) {
        let preferred = preferredPortion
        if let preferred {
            if MealQuantityRules.isMassUnit(preferred.unit),
               MealQuantityRules.normalizedPositiveDecimal(preferred.amount) != nil {
                setPortion(preferred)
                portionFallbackNotice = nil
                return
            }
            portionFallbackNotice = String(
                localized: "meals.detail.lastUsed.unavailableUnit"
            )
        }
        setPortion(meal.defaultPortion)
    }

    private func startLastUsedPortionLookup(token: Int) {
        lastUsedTask?.cancel()
        lastUsedTask = Task { [weak self] in
            guard let self else { return }
            do {
                let portion = try await self.service.lastUsedPortion(
                    forMealID: self.mealID,
                    date: self.date,
                    mealSlot: self.mealSlot
                )
                guard !Task.isCancelled,
                      token == self.loadToken,
                      !self.portionWasEdited,
                      let portion else { return }
                self.applyLastUsedPortion(portion)
                self.schedulePreview(immediate: true)
            } catch {
                guard token == self.loadToken else { return }
                if isUnauthorizedMealError(error) {
                    self.onSessionExpired()
                }
            }
        }
    }

    private func applyLastUsedPortion(_ portion: NutritionQuantity) {
        guard MealQuantityRules.isMassUnit(portion.unit),
              MealQuantityRules.normalizedPositiveDecimal(portion.amount) != nil else {
            portionFallbackNotice = String(
                localized: "meals.detail.lastUsed.unavailableUnit"
            )
            return
        }
        setPortion(portion)
        portionFallbackNotice = nil
    }

    private func setPortion(_ portion: NutritionQuantity) {
        isApplyingPortionDefault = true
        portionAmount = portion.amount
        portionUnit = portion.unit
        isApplyingPortionDefault = false
    }

    private func resolveComponentNames(for meal: Meal, token: Int) async {
        for component in meal.components {
            guard token == loadToken else { return }
            if component.missing {
                continue
            }
            guard case .product = component.item.itemType else {
                missingComponentIDs.insert(component.item.id)
                continue
            }
            do {
                let product = try await service.fetchComponentProduct(id: component.item.id)
                guard token == loadToken else { return }
                componentNames[component.item.id] = product.name
                missingComponentIDs.remove(component.item.id)
            } catch {
                guard token == loadToken else { return }
                if isUnauthorizedMealError(error) {
                    onSessionExpired()
                    return
                }
                if let mealError = error as? MealServiceError {
                    switch mealError {
                    case .notFound, .missingComponents:
                        missingComponentIDs.insert(component.item.id)
                    default:
                        break
                    }
                }
            }
        }
    }

    private func schedulePreview(immediate: Bool = false) {
        previewTask?.cancel()
        previewTask = nil
        previewToken += 1
        let token = previewToken

        guard let meal = loadedMeal else { return }
        if meal.isDegraded {
            previewState = .unavailable(
                String(localized: "meals.error.missingComponents")
            )
            return
        }
        if let message = amountValidationMessage {
            previewState = .unavailable(message)
            return
        }
        guard let amount = MealQuantityRules.normalizedPositiveDecimal(portionAmount) else {
            previewState = .unavailable(String(localized: "meals.error.amountInvalid"))
            return
        }
        let unit = portionUnit.trimmingCharacters(in: .whitespacesAndNewlines)
        let delay = immediate ? 0 : previewDebounceNanoseconds
        previewState = .loading

        previewTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            do {
                let nutrition = try await self.service.mealNutrients(
                    mealID: self.mealID,
                    amount: amount,
                    unit: unit
                )
                guard token == self.previewToken, !Task.isCancelled else { return }
                self.previewState = .loaded(nutrition)
            } catch {
                guard token == self.previewToken, !Task.isCancelled else { return }
                if isUnauthorizedMealError(error) {
                    self.onSessionExpired()
                    self.previewState = .failed(
                        String(localized: "meals.error.sessionExpired")
                    )
                    return
                }
                if let mealError = error as? MealServiceError,
                   case .cancelled = mealError {
                    return
                }
                let message = mealServiceMessage(error)
                self.previewState = .failed(
                    message.isEmpty
                        ? String(localized: "meals.error.previewFailed")
                        : message
                )
            }
        }
    }

    private func finishLog(_ result: LogSubmissionServiceResult) {
        switch result {
        case .success(let logs):
            logState = .succeeded(logID: logs.first?.id)
            onLogged?(date, mealSlot)
        case .failure(.unauthorized):
            onSessionExpired()
            logState = .failed(String(localized: "foodDetail.error.sessionExpired"))
        case .failure(.uncertain):
            logState = .failed(String(
                localized: "meals.detail.log.uncertain",
                defaultValue: "CalCo couldn't confirm this log. Check the diary before retrying."
            ))
        case .failure(.failed(let message)):
            logState = .failed(message)
        }
    }
}
