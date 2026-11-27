import ComposableArchitecture
import XCTest

@testable import CalCo

/// Migration of the retired `AdHocLogViewModel` adversarial-safety harness.
/// The same three invariants are now exercised on `AdHocLogFeature` with the
/// captured assistant draft injected into `State` (no VM, no handoff wrapper).
@MainActor
final class AdversarialLibrarySafetyReviewTests: XCTestCase {
    private let accountID = "review-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let generation: UInt64 = 42
    private let presentationID = UUID(700)
    private let reviewID = "adversarial-review-1"

    private var reviewContext: FeatureRequestContext {
        FeatureRequestContext(
            accountID: accountID,
            generation: generation,
            presentationID: presentationID
        )
    }

    private var plateNutrients: [NutrientAmountValue] {
        [
            NutrientAmountValue(code: "ENERGY_KCAL", amount: "350", unit: "kcal"),
            NutrientAmountValue(code: "PROTEIN_G", amount: "14", unit: "g"),
            NutrientAmountValue(code: "CARBS_G", amount: "35", unit: "g"),
            NutrientAmountValue(code: "FAT_G", amount: "7", unit: "g"),
        ]
    }

    private var bowlNutrients: [NutrientAmountValue] {
        [
            NutrientAmountValue(code: "ENERGY_KCAL", amount: "300", unit: "kcal"),
            NutrientAmountValue(code: "PROTEIN_G", amount: "12", unit: "g"),
            NutrientAmountValue(code: "CARBS_G", amount: "30", unit: "g"),
            NutrientAmountValue(code: "FAT_G", amount: "6", unit: "g"),
        ]
    }

    private var doubledBowlNutrients: [NutrientAmountValue] {
        [
            NutrientAmountValue(code: "ENERGY_KCAL", amount: "600", unit: "kcal"),
            NutrientAmountValue(code: "PROTEIN_G", amount: "24", unit: "g"),
            NutrientAmountValue(code: "CARBS_G", amount: "60", unit: "g"),
            NutrientAmountValue(code: "FAT_G", amount: "12", unit: "g"),
        ]
    }

    private func draft(
        unit: String = "plate",
        grams: String = "350",
        kcalPer100g: String = "100"
    ) throws -> AssistantReviewedDraft {
        try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: AssistantFoodDraftPayload(
                name: "Curry",
                nutrients: [
                    .init(code: "ENERGY_KCAL", amountPer100g: kcalPer100g),
                    .init(code: "PROTEIN_G", amountPer100g: "4"),
                    .init(code: "CARBS_G", amountPer100g: "10"),
                    .init(code: "FAT_G", amountPer100g: "2"),
                ],
                servings: [.init(unit: unit, gramsPerUnit: grams)]
            ),
            suggestedLog: AssistantSuggestedLog(
                amount: "1", unit: unit, totalWeightGrams: grams
            ),
            warnings: []
        )
    }

    private func store(
        draft: AssistantReviewedDraft
    ) -> TestStore<AdHocLogFeature.State, AdHocLogFeature.Action> {
        let definitions = LibraryTestFixtures.definitions
        let reviewID = self.reviewID
        return TestStore(
            initialState: AdHocLogFeature.State(
                accountID: accountID,
                generation: generation,
                today: date,
                logContext: LibraryLogContext(date: date, mealSlot: .lunch),
                presentationID: presentationID,
                assistantDraft: draft
            )
        ) {
            AdHocLogFeature()
        } withDependencies: {
            $0.adHocLogClient = AdHocLogFeature.Client(
                definitions: { _ in definitions },
                units: { _ in [ProductUnit(code: "g", name: "Gram", kind: "mass")] },
                create: { _, _ in "new-food" },
                log: LibraryLogClient(
                    submit: { _, _, _, _, _, completion in completion(.success([])) },
                    isCurrentOwner: { _, _ in true }
                ),
                timeZoneIdentifier: { "Asia/Kolkata" },
                makeID: { reviewID }
            )
            $0.uuid = .incrementing
        }
    }

    private func finishLoad(
        _ store: TestStore<AdHocLogFeature.State, AdHocLogFeature.Action>,
        unit: String,
        weightText: String,
        weight: Decimal,
        nutrients: [NutrientAmountValue]
    ) async throws {
        let definitions = LibraryTestFixtures.definitions
        await store.send(.load) {
            $0.loadPhase = .loading
            $0.loadRequestID = UUID(0)
            $0.formError = nil
            $0.assistantServingGrams = [:]
            $0.assistantPortionWeightGrams = nil
            $0.assistantQuantityNeedsReview = false
        }.finish()
        await store.receive(.loadCompleted(
            requestID: UUID(0),
            context: reviewContext,
            result: .success(AdHocLogFeature.LoadPayload(
                definitions: definitions,
                units: [ProductUnit(code: "g", name: "Gram", kind: "mass")]
            ))
        )) {
            $0.loadRequestID = nil
            $0.loadPhase = .loaded
            $0.definitions = definitions
            $0.units = [
                FoodUnit(code: "g", name: "Gram", kind: "mass"),
                FoodUnit(code: unit, name: unit.capitalized, kind: "serving"),
            ]
            $0.nutrientEditor = NutrientEditorState(
                definitions: definitions,
                initial: nutrients
            )
            $0.name = "Curry"
            $0.brand = ""
            $0.amount = "1"
            $0.unit = unit
            $0.portionWeightText = weightText
            $0.assistantServingGrams = [unit: weight]
            $0.assistantPortionWeightGrams = weight
            $0.assistantQuantityNeedsReview = false
            $0.isDirty = true
        }
    }

    private func expectedSaveAndLogReview() -> AdHocReview {
        let draft = LogSubmissionDraft(
            item: .adHoc(name: "Curry", brand: nil),
            date: date,
            mealSlot: .lunch,
            amount: "350",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata",
            nutrients: [
                NutrientAmountValue(code: "CARBS_G", amount: "35", unit: "g"),
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "350", unit: "kcal"),
                NutrientAmountValue(code: "FAT_G", amount: "7", unit: "g"),
                NutrientAmountValue(code: "PROTEIN_G", amount: "14", unit: "g"),
            ]
        )
        let customFood = CustomFoodWriteRequest(
            name: "Curry",
            brand: nil,
            categories: [],
            defaultQuantity: 350,
            defaultUnit: "g",
            nutrients: [
                // Per-100g truth is preserved when the serving unit changes;
                // these are the original fixture values, not scaled absolute amounts.
                CustomFoodNutrientWrite(code: "ENERGY_KCAL", amountPer100g: 100),
                CustomFoodNutrientWrite(code: "PROTEIN_G", amountPer100g: 4),
                CustomFoodNutrientWrite(code: "CARBS_G", amountPer100g: 10),
                CustomFoodNutrientWrite(code: "FAT_G", amountPer100g: 2),
            ],
            servings: []
        )
        let intent = SavedFoodLogIntent(
            date: date,
            mealSlot: .lunch,
            amount: "350",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
        return AdHocReview(
            id: reviewID,
            mode: .saveAndLog,
            name: "Curry",
            amount: "350",
            unit: "g",
            date: date,
            mealSlot: .lunch,
            draft: draft,
            customFood: customFood,
            logIntent: intent
        )
    }

    /// Old `testAssistantSuggestedServingUnitIsSelectableInAdHocEditor`.
    func testAssistantSuggestedServingUnitIsSelectableInAdHocEditor() async throws {
        let store = store(draft: try draft(unit: "plate"))
        try await finishLoad(
            store,
            unit: "plate",
            weightText: "350",
            weight: Decimal(350),
            nutrients: plateNutrients
        )

        XCTAssertEqual(store.state.unit, "plate")
        XCTAssertTrue(
            store.state.units.contains { $0.code == "plate" },
            "the unit picker must represent the assistant's serving unit"
        )
    }

    /// Old `testAssistantUnitChangeToGramsMustNotCorruptPer100g`.
    func testAssistantUnitChangeToGramsPreservesPer100g() async throws {
        let store = store(draft: try draft(unit: "plate"))
        try await finishLoad(
            store,
            unit: "plate",
            weightText: "350",
            weight: Decimal(350),
            nutrients: plateNutrients
        )

        await store.send(.unitChanged("g")) {
            $0.unit = "g"
            $0.amount = "350"
            $0.portionWeightText = "350"
            $0.isDirty = true
            $0.formError = nil
        }
        XCTAssertEqual(store.state.nutrientEditor.amount(for: "ENERGY_KCAL"), "350")

        await store.send(.modeChanged(.saveAndLog)) {
            $0.mode = .saveAndLog
            $0.isDirty = true
            $0.formError = nil
        }
        let review = expectedSaveAndLogReview()
        await store.send(.reviewRequested) {
            $0.hasAttemptedReview = true
            $0.formError = nil
            $0.latestIssuedReviewID = review.id
            $0.latestIssuedReview = review
            $0.latestIssuedReviewContext = self.reviewContext
            $0.pendingReview = review
        }
        XCTAssertNotNil(store.state.pendingReview, "The converted draft must remain reviewable")
    }

    /// Old `testAssistantAmountChangeScalesAbsoluteNutrients`.
    func testAssistantAmountChangeScalesAbsoluteNutrients() async throws {
        let store = store(draft: try draft(unit: "bowl", grams: "300"))
        try await finishLoad(
            store,
            unit: "bowl",
            weightText: "300",
            weight: Decimal(300),
            nutrients: bowlNutrients
        )

        XCTAssertEqual(store.state.nutrientEditor.amount(for: "ENERGY_KCAL"), "300")
        await store.send(.amountChanged("2")) {
            $0.amount = "2"
            $0.portionWeightText = "600"
            $0.assistantPortionWeightGrams = Decimal(600)
            $0.assistantServingGrams = ["bowl": Decimal(300)]
            $0.nutrientEditor = NutrientEditorState(
                definitions: LibraryTestFixtures.definitions,
                initial: self.doubledBowlNutrients
            )
            $0.isDirty = true
            $0.formError = nil
        }
        XCTAssertEqual(store.state.nutrientEditor.amount(for: "ENERGY_KCAL"), "600")
        XCTAssertEqual(store.state.portionWeightText, "600")
    }
}
