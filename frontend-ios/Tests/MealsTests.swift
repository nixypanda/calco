import ComposableArchitecture
import Dependencies
import XCTest

@testable import CalCo

/// Migration of the retired Meals VM harness (C deleted MealsListViewModel,
/// MealDetailViewModel, MealEditorViewModel and their views). The VM flow
/// scenarios are owned by C's five new TestStore files; the per-test map is in
/// `test-migration/test-mapping.md`. Pure quantity/draft contracts are
/// preserved unchanged, and the two authority scenarios below are ported to
/// `MealEditorFeature` against C's frozen `MealsRequestContext`.
private actor MealsCreateGate {
    private var didEnter = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        didEnter = true
        let pending = enteredWaiters
        enteredWaiters = []
        for waiter in pending { waiter.resume() }
    }

    func entered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
final class MealsTests: XCTestCase {
    private let generation: UInt64 = 91
    private let accountID = "acct-3"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 26)
    private let presentationID = UUID()

    private var context: MealsCaptureContext {
        MealsCaptureContext(
            id: presentationID, date: date, accountID: accountID,
            generation: generation, origin: .sheet
        )
    }

    private func request(_ id: UUID) -> MealsRequestContext {
        MealsRequestContext(
            accountID: accountID, generation: generation,
            ownerID: presentationID, requestID: id
        )
    }

    private var gram: ProductUnit { ProductUnit(code: "g", name: "Gram", kind: "mass") }

    private var createdMeal: Meal {
        Meal(id: "new-meal", name: "Soup", components: [MealComponent(
            id: "c-1", item: ItemReference(itemType: .product, id: "p-1"),
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )])
    }

    private func makeClient(
        createError: (any Error & Sendable)? = nil,
        createCalls: LockIsolated<Int>? = nil,
        createGate: MealsCreateGate? = nil
    ) -> MealsFeatureClient {
        let created = self.createdMeal
        let gramUnit = self.gram
        return MealsFeatureClient(
            listMeals: { _ in [] },
            getMeal: { _, _ in fatalError("unused") },
            createMeal: { _, context in
                createCalls?.withValue { $0 += 1 }
                if let createGate {
                    await createGate.markEntered()
                    await createGate.wait()
                }
                XCTAssertEqual(context.accountID, self.accountID)
                XCTAssertEqual(context.generation, self.generation)
                XCTAssertEqual(context.ownerID, self.presentationID)
                if let createError { throw createError }
                return created
            },
            updateMeal: { _, _, _ in fatalError("unused") },
            deleteMeal: { _, _ in fatalError("unused") },
            mealNutrients: { _, _, _, _ in fatalError("unused") },
            fetchUnits: { _ in [gramUnit] },
            searchProducts: { _, _ in [] },
            fetchProduct: { id, _ in MealProduct(id: id, name: "Base") },
            lastUsedPortion: { _, _, _, _ in nil },
            submitDraft: { _, _, _, _ in .success([]) },
            isCurrentSession: { _, _ in true }
        )
    }

    private func readyState(name: String = "Soup") -> MealEditorFeature.State {
        var state = MealEditorFeature.State(context: context, mode: .create)
        state.loadState = .ready
        state.units = [gram]
        state.name = name
        state.totalUnit = "g"
        state.components = [MealComponentRow(
            id: 1, productID: "p-1", productName: "Base", query: "Base", unit: "g"
        )]
        return state
    }

    /// Old `testEditorCreateSaveBuildsValidatedRequest` / `testEditorSaveCannotCreateTwice`:
    /// one explicit save produces exactly one create RPC with the captured
    /// account/generation/owner context; a second tap while saving is ignored.
    func testMealsEditorSaveWritesOnceWithCapturedContext() async {
        let createCalls = LockIsolated(0)
        let gate = MealsCreateGate()
        let store = TestStore(initialState: readyState()) {
            MealEditorFeature()
        } withDependencies: {
            $0.mealsClient = makeClient(createCalls: createCalls, createGate: gate)
            $0.uuid = .incrementing
        }

        await store.send(.save) {
            $0.saveState = .saving
            $0.pendingSaveRequestID = UUID(0)
        }
        await gate.entered()
        // The create RPC is genuinely in flight; a second tap must be a no-op.
        await store.send(.save)
        await gate.release()
        let created = self.createdMeal
        await store.receive({ action in
            guard case let .saved(meal, context) = action else { return false }
            return meal == created && context == self.request(UUID(0))
        }) {
            $0.saveState = .saved
            $0.pendingSaveRequestID = nil
            $0.baseline = $0.currentSnapshot
        }
        await store.receive({ action in
            guard case let .delegate(delegate) = action else { return false }
            guard case let .saved(meal, receivedGeneration, receivedPresentationID) = delegate else { return false }
            return meal == created
                && receivedGeneration == self.generation
                && receivedPresentationID == self.presentationID
        })
        XCTAssertEqual(createCalls.value, 1)
    }

    /// Old `testUncertainCreateShowsOrdinaryErrorAndAllowsExplicitRetry`: an
    /// uncertain create keeps the form and does not blindly retry.
    func testMealsUncertainCreateKeepsFormAndDoesNotRetry() async {
        let createCalls = LockIsolated(0)
        let store = TestStore(initialState: readyState()) {
            MealEditorFeature()
        } withDependencies: {
            $0.mealsClient = makeClient(
                createError: MealServiceError.network, createCalls: createCalls
            )
            $0.uuid = .incrementing
        }

        await store.send(.save) {
            $0.saveState = .saving
            $0.pendingSaveRequestID = UUID(0)
        }
        await store.receive({ action in
            if case .saveUncertain = action { return true }
            return false
        }) {
            $0.saveState = .failed(String(
                localized: "meals.editor.createUncertain",
                defaultValue: "CalCo couldn't confirm whether this meal was saved. Refresh the list before trying again."
            ))
            $0.pendingSaveRequestID = nil
        }
        XCTAssertEqual(createCalls.value, 1)
        XCTAssertTrue(store.state.hasUnsavedChanges)
    }

    // MARK: - Preserved pure domain contracts

    private func makeMeal(
        id: String = "meal-1",
        name: String = "Porridge",
        notes: String? = "Morning meal",
        total: NutritionQuantity? = NutritionQuantity(amount: "250", unit: "g"),
        componentProducts: [String] = ["oats", "milk"],
        componentAmounts: [String] = ["50", "200"]
    ) -> Meal {
        Meal(
            id: id,
            name: name,
            notes: notes,
            totalQuantity: total,
            nutritionSummary: NutritionSummary(energyKcal: "310", proteinG: "12.5"),
            components: zip(componentProducts, componentAmounts).enumerated().map { index, pair in
                MealComponent(
                    id: "component-\(index + 1)",
                    item: ItemReference(itemType: .product, id: pair.0),
                    quantity: NutritionQuantity(amount: pair.1, unit: "g")
                )
            }
        )
    }

    func testMealQuantityRulesAndDefaultPortion() {
        XCTAssertEqual(MealQuantityRules.normalizedPositiveDecimal(" 2.50 "), "2.50")
        XCTAssertEqual(MealQuantityRules.normalizedPositiveDecimal(".5"), "0.5")
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("0"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("-1"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("1,5"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("1e3"))
        XCTAssertNil(MealQuantityRules.normalizedPositiveDecimal("abc"))

        let massMeal = makeMeal(total: NutritionQuantity(amount: "250", unit: "kg"))
        XCTAssertEqual(massMeal.defaultPortion, NutritionQuantity(amount: "250", unit: "kg"))
        let nonMassMeal = makeMeal(total: NutritionQuantity(amount: "2", unit: "serving"))
        XCTAssertEqual(nonMassMeal.defaultPortion, NutritionQuantity(amount: "100", unit: "g"))

        let draft = MealLogDraftBuilder.makeDraft(
            meal: massMeal,
            date: date,
            mealSlot: .snack,
            amount: "1.5",
            unit: "kg",
            notes: "  ",
            timeZone: "UTC"
        )
        XCTAssertEqual(draft?.item, .meal(id: "meal-1"))
        XCTAssertEqual(draft?.amount, "1.5")
        XCTAssertEqual(draft?.unit, "kg")
        XCTAssertNil(draft?.notes)
        XCTAssertNil(
            MealLogDraftBuilder.makeDraft(
                meal: massMeal,
                date: date,
                mealSlot: nil,
                amount: "1",
                unit: "serving",
                timeZone: "UTC"
            )
        )
    }
}
