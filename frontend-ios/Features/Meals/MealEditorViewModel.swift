// Create/edit state for a meal recipe, including the food component picker,
// quantity/unit validation, and dirty-form tracking.

import Combine
import Foundation

@MainActor
public final class MealEditorViewModel: ObservableObject {
    @Published public private(set) var loadState: MealEditorLoadState = .loading
    @Published public private(set) var saveState: MealEditorSaveState = .idle
    @Published public private(set) var components: [MealComponentRow] = []
    @Published public private(set) var units: [ProductUnit] = []
    @Published public private(set) var unitFallbackNotice: String?
    @Published public private(set) var validationMessage: String?
    @Published public var name: String = "" {
        didSet { if name != oldValue { clearTransientMessages() } }
    }
    @Published public var notes: String = "" {
        didSet { if notes != oldValue { clearTransientMessages() } }
    }
    @Published public var totalAmount: String = "" {
        didSet { if totalAmount != oldValue { clearTransientMessages() } }
    }
    @Published public var totalUnit: String = "g" {
        didSet { if totalUnit != oldValue { clearTransientMessages() } }
    }

    public let mode: MealEditorMode

    private let service: MealsServicing
    private let accountID: String
    private let onSessionExpired: () -> Void
    private let onSaved: (Meal) -> Void
    private let searchDebounceNanoseconds: UInt64

    private var nextRowID = 1
    private var loadToken = 0
    private var didStartLoad = false
    private var baseline: MealFormSnapshot = .empty
    private var searchTokens: [Int: Int] = [:]
    private var searchTasks: [Int: Task<Void, Never>] = [:]
    private var componentResolutionTokens: [Int: Int] = [:]
    private var componentNameTasks: [Int: Task<Void, Never>] = [:]

    public init(
        mode: MealEditorMode,
        accountID: String,
        service: MealsServicing,
        onSessionExpired: @escaping () -> Void = {},
        onSaved: @escaping (Meal) -> Void = { _ in },
        searchDebounceNanoseconds: UInt64 = 300_000_000
    ) {
        self.mode = mode
        self.accountID = accountID
        self.service = service
        self.onSessionExpired = onSessionExpired
        self.onSaved = onSaved
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
    }

    public var isSaving: Bool {
        if case .saving = saveState { return true }
        return false
    }

    public var isReady: Bool {
        if case .ready = loadState { return true }
        return false
    }

    public var hasUnsavedChanges: Bool {
        isReady && currentSnapshot != baseline
    }

    public var editorTitle: String {
        switch mode {
        case .create:
            return String(localized: "meals.editor.createTitle")
        case .edit:
            return String(localized: "meals.editor.editTitle")
        }
    }

    public var loadErrorMessage: String? {
        if case .failed(let message) = loadState { return message }
        return nil
    }

    public var saveErrorMessage: String? {
        if case .failed(let message) = saveState { return message }
        return nil
    }

    public var displayErrorMessage: String? {
        validationMessage ?? saveErrorMessage
    }

    public var didSave: Bool {
        if case .saved = saveState { return true }
        return false
    }

    /// A successfully saved create stops further saves until the editor closes.
    public var isSaveBlocked: Bool {
        didSave
    }

    public var totalQuantityHelperText: String? {
        guard !totalAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard MealQuantityRules.normalizedPositiveDecimal(totalAmount) != nil else {
            return String(localized: "meals.editor.error.totalInvalid")
        }
        if !MealQuantityRules.isMassUnit(totalUnit) {
            return String(localized: "meals.editor.totalNonMass")
        }
        return nil
    }

    public func loadIfNeeded() async {
        guard !didStartLoad else { return }
        await load()
    }

    public func reload() async {
        didStartLoad = false
        await load()
    }

    public func load() async {
        guard !didStartLoad else { return }
        didStartLoad = true
        loadToken += 1
        let token = loadToken
        loadState = .loading
        saveState = .idle
        validationMessage = nil
        unitFallbackNotice = nil
        cancelAllComponentResolutions()

        let fetchedUnits: [ProductUnit]
        do {
            fetchedUnits = try await service.fetchUnits()
        } catch {
            if isUnauthorizedMealError(error) {
                onSessionExpired()
                loadState = .failed(String(localized: "meals.error.sessionExpired"))
                didStartLoad = false
                return
            }
            if isCancelled(error) {
                didStartLoad = false
                return
            }
            unitFallbackNotice = String(localized: "meals.editor.unitFallback")
            fetchedUnits = []
        }
        guard token == loadToken else { return }

        switch mode {
        case .create:
            units = MealQuantityRules.editorUnits(from: fetchedUnits)
            nextRowID = 1
            components = [MealComponentRow(id: nextRowID, unit: defaultUnitCode)]
            nextRowID += 1
            name = ""
            notes = ""
            totalAmount = ""
            totalUnit = defaultUnitCode
            baseline = currentSnapshot
            loadState = .ready

        case .edit(let id):
            do {
                let meal = try await service.getMeal(id: id)
                guard token == loadToken else { return }
                var editableUnits = MealQuantityRules.editorUnits(from: fetchedUnits)
                editableUnits = MealQuantityRules.merging(
                    meal.totalQuantity?.unit,
                    into: editableUnits
                )
                for component in meal.components {
                    editableUnits = MealQuantityRules.merging(
                        component.quantity.unit,
                        into: editableUnits
                    )
                }
                units = editableUnits
                let rowIDs = apply(meal)
                baseline = currentSnapshot
                loadState = .ready
                startResolvingComponentNames(
                    for: meal.components,
                    rowIDs: rowIDs,
                    loadToken: token
                )
            } catch {
                guard token == loadToken else { return }
                if isUnauthorizedMealError(error) {
                    onSessionExpired()
                    loadState = .failed(String(localized: "meals.error.sessionExpired"))
                    return
                }
                if isCancelled(error) {
                    return
                }
                let message = mealServiceMessage(error)
                loadState = .failed(
                    message.isEmpty
                        ? String(localized: "meals.error.loadFailed")
                        : message
                )
            }
        }
    }

    public func addComponent() {
        guard isReady, !isSaving else { return }
        components.append(
            MealComponentRow(id: nextRowID, unit: defaultUnitCode)
        )
        nextRowID += 1
        clearTransientMessages()
    }

    public func removeComponent(rowID: Int) {
        guard isReady, !isSaving else { return }
        cancelComponentResolution(rowID: rowID)
        searchTasks[rowID]?.cancel()
        searchTasks[rowID] = nil
        searchTokens[rowID, default: 0] += 1
        if components.count <= 1 {
            let unit = components.first?.unit ?? defaultUnitCode
            components = [MealComponentRow(id: components.first?.id ?? nextRowID, unit: unit)]
            if components.first?.id == nextRowID {
                nextRowID += 1
            }
        } else {
            components.removeAll { $0.id == rowID }
        }
        clearTransientMessages()
    }

    public func searchQueryChanged(rowID: Int, query: String) {
        guard let index = index(for: rowID), !isSaving else { return }
        clearTransientMessages()
        let selectedName = components[index].productName
        components[index].query = query
        if components[index].productID.isEmpty || selectedName != query {
            components[index].productID = ""
            components[index].productName = nil
            components[index].isMissing = false
            cancelComponentResolution(rowID: rowID)
        }

        searchTasks[rowID]?.cancel()
        searchTasks[rowID] = nil
        searchTokens[rowID, default: 0] += 1
        let token = searchTokens[rowID] ?? 0
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            components[index].searchState = .idle
            return
        }

        components[index].searchState = .loading
        let delay = searchDebounceNanoseconds
        searchTasks[rowID] = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            do {
                let products = try await self.service.searchComponentProducts(query: trimmed)
                guard token == self.searchTokens[rowID],
                      let current = self.index(for: rowID),
                      self.components[current].trimmedQuery == trimmed,
                      !Task.isCancelled else { return }
                self.components[current].searchState = products.isEmpty
                    ? .empty
                    : .results(products)
            } catch {
                guard token == self.searchTokens[rowID], !Task.isCancelled else { return }
                if isUnauthorizedMealError(error) {
                    self.onSessionExpired()
                }
                if isCancelled(error) {
                    return
                }
                guard let current = self.index(for: rowID) else { return }
                let message = mealServiceMessage(error)
                self.components[current].searchState = .failed(
                    message.isEmpty
                        ? String(localized: "meals.editor.searchFailed")
                        : message
                )
            }
        }
    }

    public func selectProduct(rowID: Int, product: MealProduct) {
        guard let index = index(for: rowID), !isSaving else { return }
        cancelComponentResolution(rowID: rowID)
        searchTasks[rowID]?.cancel()
        searchTasks[rowID] = nil
        searchTokens[rowID, default: 0] += 1
        components[index].productID = product.id
        components[index].productName = product.name
        components[index].query = product.name
        components[index].searchState = .idle
        components[index].isMissing = false
        components[index].isResolvingName = false
        clearTransientMessages()
    }

    public func clearProduct(rowID: Int) {
        guard let index = index(for: rowID), !isSaving else { return }
        cancelComponentResolution(rowID: rowID)
        searchTasks[rowID]?.cancel()
        searchTasks[rowID] = nil
        searchTokens[rowID, default: 0] += 1
        components[index].productID = ""
        components[index].productName = nil
        components[index].query = ""
        components[index].searchState = .idle
        components[index].isMissing = false
        components[index].isResolvingName = false
        clearTransientMessages()
    }

    public func componentAmountChanged(rowID: Int, amount: String) {
        guard let index = index(for: rowID), !isSaving else { return }
        components[index].amount = amount
        clearTransientMessages()
    }

    public func componentUnitChanged(rowID: Int, unit: String) {
        guard let index = index(for: rowID), !isSaving else { return }
        components[index].unit = unit
        clearTransientMessages()
    }

    public var validationErrors: [MealEditorValidationError] {
        var errors: [MealEditorValidationError] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.nameRequired)
        }

        let selected = components.filter(\.hasSelection)
        let unresolved = components.filter { !$0.hasSelection && !$0.trimmedQuery.isEmpty }
        if selected.isEmpty && unresolved.isEmpty {
            errors.append(.componentsRequired)
        }
        if !unresolved.isEmpty {
            errors.append(.componentUnselected)
        }
        if components.contains(where: \.isMissing) {
            errors.append(.componentMissing)
        }
        if selected.contains(where: {
            MealQuantityRules.normalizedPositiveDecimal($0.amount) == nil
        }) {
            errors.append(.quantityInvalid)
        }
        if selected.contains(where: {
            $0.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            errors.append(.unitRequired)
        }

        let trimmedTotal = totalAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTotal.isEmpty,
           MealQuantityRules.normalizedPositiveDecimal(trimmedTotal) == nil {
            errors.append(.totalQuantityInvalid)
        }
        if !trimmedTotal.isEmpty,
           totalUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.unitRequired)
        }
        return errors
    }

    public func save() async {
        guard isReady, !isSaving, !isSaveBlocked else { return }
        let errors = validationErrors
        if let first = errors.first {
            validationMessage = first.message
            saveState = .idle
            return
        }
        guard let request = makeRequest() else {
            validationMessage = String(localized: "meals.error.saveFailed")
            return
        }

        validationMessage = nil
        saveState = .saving
        do {
            let saved: Meal
            switch mode {
            case .create:
                saved = try await service.createMeal(request)
            case .edit(let id):
                saved = try await service.updateMeal(id: id, request)
            }
            saveState = .saved
            baseline = currentSnapshot
            onSaved(saved)
        } catch {
            if isUnauthorizedMealError(error) {
                onSessionExpired()
                saveState = .failed(String(localized: "meals.error.sessionExpired"))
                return
            }
            if isCancelled(error) {
                saveState = .idle
                return
            }
            if case .create = mode,
               let mealError = error as? MealServiceError,
               mealError == .network || isUncertainServerFailure(mealError) {
                saveState = .failed(String(
                    localized: "meals.editor.createUncertain",
                    defaultValue: "CalCo couldn't confirm whether this meal was saved. Refresh the list before trying again."
                ))
                return
            }
            let message = mealServiceMessage(error)
            saveState = .failed(
                message.isEmpty
                    ? String(localized: "meals.error.saveFailed")
                    : message
            )
        }
    }

    public func dismissValidationMessage() {
        validationMessage = nil
    }

    private func isUncertainServerFailure(_ error: MealServiceError) -> Bool {
        if case .server = error { return true }
        return false
    }

    private var defaultUnitCode: String {
        if units.contains(where: { $0.code == "g" }) {
            return "g"
        }
        return units.first?.code ?? "g"
    }

    @discardableResult
    private func apply(_ meal: Meal) -> [Int] {
        name = meal.name
        notes = meal.notes ?? ""
        if let total = meal.totalQuantity,
           !total.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            totalAmount = total.amount
            totalUnit = total.unit.isEmpty ? defaultUnitCode : total.unit
        } else {
            totalAmount = ""
            totalUnit = defaultUnitCode
        }

        nextRowID = 1
        var rowIDs: [Int] = []
        components = meal.components.map { component in
            let unit = component.quantity.unit.isEmpty ? defaultUnitCode : component.quantity.unit
            let productID: String
            var missing = false
            switch component.item.itemType {
            case .product:
                productID = component.item.id
            case .meal:
                productID = ""
                missing = true
            }
            let row = MealComponentRow(
                id: nextRowID,
                productID: productID,
                query: "",
                amount: component.quantity.amount,
                unit: unit,
                isMissing: missing,
                isResolvingName: !productID.isEmpty
            )
            rowIDs.append(nextRowID)
            nextRowID += 1
            return row
        }
        if components.isEmpty {
            components = [MealComponentRow(id: nextRowID, unit: defaultUnitCode)]
            rowIDs = [nextRowID]
            nextRowID += 1
        }
        return rowIDs
    }

    private func startResolvingComponentNames(
        for components: [MealComponent],
        rowIDs: [Int],
        loadToken: Int
    ) {
        for (position, component) in components.enumerated() {
            guard case .product = component.item.itemType,
                  rowIDs.indices.contains(position) else { continue }
            let rowID = rowIDs[position]
            let productID = component.item.id
            componentResolutionTokens[rowID, default: 0] += 1
            let resolutionToken = componentResolutionTokens[rowID] ?? 0
            componentNameTasks[rowID]?.cancel()
            componentNameTasks[rowID] = Task { [weak self] in
                await self?.resolveComponentName(
                    rowID: rowID,
                    expectedProductID: productID,
                    loadToken: loadToken,
                    resolutionToken: resolutionToken
                )
            }
        }
    }

    private func resolveComponentName(
        rowID: Int,
        expectedProductID: String,
        loadToken: Int,
        resolutionToken: Int
    ) async {
        do {
            let product = try await service.fetchComponentProduct(id: expectedProductID)
            guard !Task.isCancelled,
                  isCurrentResolution(
                      rowID: rowID,
                      expectedProductID: expectedProductID,
                      loadToken: loadToken,
                      resolutionToken: resolutionToken
                  ),
                  let current = index(for: rowID) else { return }
            components[current].productName = product.name
            components[current].query = product.name
            components[current].isMissing = false
            components[current].isResolvingName = false
        } catch {
            guard !Task.isCancelled,
                  isCurrentResolution(
                      rowID: rowID,
                      expectedProductID: expectedProductID,
                      loadToken: loadToken,
                      resolutionToken: resolutionToken
                  ),
                  let current = index(for: rowID) else { return }
            if isUnauthorizedMealError(error) {
                onSessionExpired()
                return
            }
            components[current].isResolvingName = false
            if let mealError = error as? MealServiceError {
                switch mealError {
                case .notFound, .missingComponents:
                    components[current].isMissing = true
                    components[current].query = ""
                default:
                    break
                }
            }
        }
    }

    private func isCurrentResolution(
        rowID: Int,
        expectedProductID: String,
        loadToken: Int,
        resolutionToken: Int
    ) -> Bool {
        guard loadToken == self.loadToken,
              componentResolutionTokens[rowID] == resolutionToken,
              let current = index(for: rowID),
              components[current].productID == expectedProductID else {
            return false
        }
        return true
    }

    private func cancelComponentResolution(rowID: Int) {
        componentNameTasks[rowID]?.cancel()
        componentNameTasks[rowID] = nil
        componentResolutionTokens[rowID, default: 0] += 1
    }

    private func cancelAllComponentResolutions() {
        for task in componentNameTasks.values {
            task.cancel()
        }
        componentNameTasks = [:]
        for rowID in Array(componentResolutionTokens.keys) {
            componentResolutionTokens[rowID, default: 0] += 1
        }
    }

    private func makeRequest() -> MealWriteRequest? {
        var writeComponents: [MealComponentWriteRequest] = []
        for row in components where row.hasSelection {
            guard let amount = MealQuantityRules.normalizedPositiveDecimal(row.amount) else {
                return nil
            }
            let unit = row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unit.isEmpty else { return nil }
            writeComponents.append(
                MealComponentWriteRequest(
                    productID: row.productID,
                    quantity: NutritionQuantity(amount: amount, unit: unit)
                )
            )
        }
        guard !writeComponents.isEmpty else { return nil }

        let trimmedTotal = totalAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        var total: NutritionQuantity?
        if !trimmedTotal.isEmpty {
            guard let amount = MealQuantityRules.normalizedPositiveDecimal(trimmedTotal) else {
                return nil
            }
            let unit = totalUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unit.isEmpty else { return nil }
            total = NutritionQuantity(amount: amount, unit: unit)
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return MealWriteRequest(
            name: trimmedName,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            totalQuantity: total,
            components: writeComponents
        )
    }

    private var currentSnapshot: MealFormSnapshot {
        MealFormSnapshot(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            totalAmount: totalAmount.trimmingCharacters(in: .whitespacesAndNewlines),
            totalUnit: totalUnit.trimmingCharacters(in: .whitespacesAndNewlines),
            components: components.compactMap { row in
                if row.hasSelection {
                    return MealComponentSnapshot(
                        productID: row.productID,
                        query: "",
                        amount: row.amount.trimmingCharacters(in: .whitespacesAndNewlines),
                        unit: row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                guard !row.trimmedQuery.isEmpty else { return nil }
                return MealComponentSnapshot(
                    productID: "",
                    query: row.trimmedQuery,
                    amount: row.amount.trimmingCharacters(in: .whitespacesAndNewlines),
                    unit: row.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        )
    }

    private func clearTransientMessages() {
        if validationMessage != nil { validationMessage = nil }
        if case .failed = saveState {
            saveState = .idle
        }
    }

    private func index(for rowID: Int) -> Int? {
        components.firstIndex { $0.id == rowID }
    }

    private func isCancelled(_ error: Error) -> Bool {
        if let mealError = error as? MealServiceError,
           case .cancelled = mealError {
            return true
        }
        return false
    }
}

private struct MealFormSnapshot: Equatable {
    let name: String
    let notes: String
    let totalAmount: String
    let totalUnit: String
    let components: [MealComponentSnapshot]

    static let empty = MealFormSnapshot(
        name: "",
        notes: "",
        totalAmount: "",
        totalUnit: "",
        components: []
    )
}

private struct MealComponentSnapshot: Equatable {
    let productID: String
    let query: String
    let amount: String
    let unit: String
}
