// Shared fakes for Library feature tests. No network, database, or real
// application-support files are used unless a test opts into a temporary dir.

import Foundation

@testable import CalCo

enum LibraryTestFixtures {
    static let definitions: [NutrientDefinition] = [
        NutrientDefinition(code: "ENERGY_KCAL", name: "Energy", unit: "kcal", category: "energy"),
        NutrientDefinition(code: "PROTEIN_G", name: "Protein", unit: "g", category: "macro"),
        NutrientDefinition(code: "CARBS_G", name: "Carbohydrates", unit: "g", category: "macro"),
        NutrientDefinition(code: "FAT_G", name: "Fat", unit: "g", category: "macro"),
        NutrientDefinition(code: "FIBER_G", name: "Fiber", unit: "g", category: "macro"),
    ]

    static func food(
        id: String,
        name: String = "Oats",
        brand: String? = nil,
        categories: [String] = [],
        energy: String = "100",
        protein: String = "4",
        carbs: String = "10",
        fat: String = "2"
    ) -> CustomFood {
        CustomFood(
            id: id,
            name: name,
            brand: brand,
            categories: categories,
            defaultQuantity: "100",
            defaultUnit: "g",
            nutrients: [
                CustomFoodNutrient(code: "ENERGY_KCAL", amountPer100g: energy, unit: "kcal"),
                CustomFoodNutrient(code: "PROTEIN_G", amountPer100g: protein, unit: "g"),
                CustomFoodNutrient(code: "CARBS_G", amountPer100g: carbs, unit: "g"),
                CustomFoodNutrient(code: "FAT_G", amountPer100g: fat, unit: "g"),
            ]
        )
    }

    static func food(matching request: CustomFoodWriteRequest, id: String) -> CustomFood {
        CustomFood(
            id: id,
            name: request.name,
            brand: request.brand,
            categories: request.categories,
            defaultQuantity: request.defaultQuantity.map {
                NSDecimalNumber(decimal: $0).stringValue
            },
            defaultUnit: request.defaultUnit,
            nutrients: request.nutrients.map {
                CustomFoodNutrient(
                    code: $0.code,
                    amountPer100g: NSDecimalNumber(decimal: $0.amountPer100g).stringValue,
                    unit: $0.code == "ENERGY_KCAL" ? "kcal" : "g"
                )
            },
            servings: request.servings.map {
                CustomFoodServing(
                    unit: $0.unit,
                    gramsPerUnit: NSDecimalNumber(decimal: $0.gramsPerUnit).stringValue
                )
            }
        )
    }
}

final class FakeLibraryService: LibraryServicing, @unchecked Sendable {
    struct UpdateCall: Equatable {
        let id: String
        let request: CustomFoodWriteRequest
    }

    private let lock = NSLock()
    private var listQueue: [Result<[CustomFood], CustomFoodServiceError>] = []
    private var createQueue: [Result<String, CustomFoodServiceError>] = []
    private var updateQueue: [Result<String, CustomFoodServiceError>] = []
    private var deleteQueue: [Result<Void, CustomFoodServiceError>] = []
    private var storedFoods: [String: CustomFood] = [:]
    private var definitionsResult: Result<[NutrientDefinition], CustomFoodServiceError> =
        .success(LibraryTestFixtures.definitions)
    private var unitsResult: Result<[ProductUnit], CustomFoodServiceError> = .success([
        ProductUnit(code: "g", name: "Gram", kind: "mass"),
        ProductUnit(code: "bowl", name: "Bowl", kind: "serving"),
    ])
    private var listCalls = 0
    private var createCalls = 0
    private var updateCalls = 0
    private var deleteCalls = 0
    private var createBodies: [CustomFoodWriteRequest] = []
    private var updateBodies: [UpdateCall] = []

    func enqueueList(_ result: Result<[CustomFood], CustomFoodServiceError>) {
        lock.withLock { listQueue.append(result) }
    }

    func enqueueCreate(_ result: Result<String, CustomFoodServiceError>) {
        lock.withLock { createQueue.append(result) }
    }

    func enqueueUpdate(_ result: Result<String, CustomFoodServiceError>) {
        lock.withLock { updateQueue.append(result) }
    }

    func enqueueDelete(_ result: Result<Void, CustomFoodServiceError>) {
        lock.withLock { deleteQueue.append(result) }
    }

    func setDefinitions(_ result: Result<[NutrientDefinition], CustomFoodServiceError>) {
        lock.withLock { definitionsResult = result }
    }

    func storeFood(_ food: CustomFood) {
        lock.withLock { storedFoods[food.id] = food }
    }

    var listCallCount: Int { lock.withLock { listCalls } }
    var createCallCount: Int { lock.withLock { createCalls } }
    var updateCallCount: Int { lock.withLock { updateCalls } }
    var deleteCallCount: Int { lock.withLock { deleteCalls } }
    var createdRequests: [CustomFoodWriteRequest] { lock.withLock { createBodies } }
    var updatedRequests: [UpdateCall] { lock.withLock { updateBodies } }

    func listCustomFoods() async throws -> [CustomFood] {
        try lock.withLock {
            listCalls += 1
            if !listQueue.isEmpty {
                return try listQueue.removeFirst().get()
            }
            return storedFoods.values.sorted { $0.name < $1.name }
        }
    }

    func customFood(id: String) async throws -> CustomFood {
        try lock.withLock {
            guard let food = storedFoods[id] else {
                throw CustomFoodServiceError.notFound("missing")
            }
            return food
        }
    }

    func nutrientDefinitions() async throws -> [NutrientDefinition] {
        try lock.withLock { try definitionsResult.get() }
    }

    func units() async throws -> [ProductUnit] {
        try lock.withLock { try unitsResult.get() }
    }

    func createCustomFood(_ request: CustomFoodWriteRequest) async throws -> String {
        try lock.withLock {
            createCalls += 1
            createBodies.append(request)
            guard !createQueue.isEmpty else {
                throw CustomFoodServiceError.failed("no create stub")
            }
            return try createQueue.removeFirst().get()
        }
    }

    func updateCustomFood(
        id: String,
        request: CustomFoodWriteRequest
    ) async throws -> String {
        try lock.withLock {
            updateCalls += 1
            updateBodies.append(UpdateCall(id: id, request: request))
            guard !updateQueue.isEmpty else {
                throw CustomFoodServiceError.failed("no update stub")
            }
            return try updateQueue.removeFirst().get()
        }
    }

    func deleteCustomFood(id: String) async throws {
        try lock.withLock {
            deleteCalls += 1
            guard !deleteQueue.isEmpty else {
                throw CustomFoodServiceError.failed("no delete stub")
            }
            return try deleteQueue.removeFirst().get()
        }
    }
}

@MainActor
final class FakeLibraryLogSubmissionService: LibraryLogSubmitting {
    struct Submission: Equatable {
        let accountID: String
        let drafts: [LogSubmissionDraft]
        let itemNames: [String]
        let summary: String
    }

    private var results: [LogSubmissionServiceResult]
    private(set) var submissions: [Submission] = []

    init(results: [LogSubmissionServiceResult]) {
        self.results = results
    }

    func enqueue(_ result: LogSubmissionServiceResult) {
        results.append(result)
    }

    func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        submissions.append(
            Submission(
                accountID: accountID,
                drafts: drafts,
                itemNames: itemNames,
                summary: summary
            )
        )
        guard !results.isEmpty else {
            return .failure(.failed("no submission stub"))
        }
        return results.removeFirst()
    }
}
