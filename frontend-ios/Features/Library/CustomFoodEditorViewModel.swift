// Custom-food create/edit view model. Only the edit flow supports
// servings/default portions; creation intentionally omits them, matching the
// web's create form. Creates are ordinary non-replayed requests.

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
    private let onSaved: (String) -> Void
    private let onSessionExpired: () -> Void
    private let initialAssistantDraft: AssistantReviewedDraft?
    private let initialBarcode: String?

    private var isApplyingInitialValues = false
    private var hasAppliedInitialAssistantDraft = false
    private var hasAppliedInitialBarcode = false
    private var loadGeneration = 0

    public init(
        mode: CustomFoodEditorMode,
        service: any LibraryServicing,
        accountID: String,
        onSaved: @escaping (String) -> Void = { _ in },
        onSessionExpired: @escaping () -> Void = {},
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil
    ) {
        self.mode = mode
        self.service = service
        self.accountID = accountID
        self.onSaved = onSaved
        self.onSessionExpired = onSessionExpired
        self.initialAssistantDraft = assistantDraft
        self.initialBarcode = initialBarcode
        self.nutrientEditor = NutrientEditorState(definitions: [])
    }

    public var foodID: String? { mode.foodID }

    public var titleKey: String {
        mode.isCreate ? "library.editor.create.title" : "library.editor.edit.title"
    }

    public var isBusy: Bool { isSaving }

    public var isFormEditable: Bool {
        if case .loaded = loadState {
            return !isBusy && savedFoodID == nil
        }
        return false
    }

    public var hasUnsavedChanges: Bool {
        isDirty && savedFoodID == nil && !isBusy
    }

    public var canSubmit: Bool {
        isFormEditable && !isBusy
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loadState = .loading
        submitError = nil
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

        do {
            let foodID = try await service.createCustomFood(request)
            savedFoodID = foodID
            isDirty = false
            onSaved(foodID)
        } catch let error as CustomFoodServiceError {
            if error.isUnauthorized {
                onSessionExpired()
            }
            submitError = createErrorMessage(for: error)
        } catch {
            submitError = String(localized: "foodDetail.error.saveFailed")
        }
    }

    private func createErrorMessage(for error: CustomFoodServiceError) -> String {
        if case .uncertain = error {
            return String(
                localized: "library.editor.create.uncertain",
                defaultValue: "CalCo couldn't confirm whether this food was saved. Check the library before trying again."
            )
        }
        return error.message
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
        submitError = nil
    }
}
