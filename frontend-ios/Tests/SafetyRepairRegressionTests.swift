import ComposableArchitecture
import XCTest

@testable import CalCo

/// Migration of the retired `AdHocLogViewModel` safety regressions. The
/// per-100g truth invariant is retargeted to `AdHocLogFeature` below; the
/// retained-food retry scenario maps exactly to
/// `AdHocLogFeatureTests.testSaveAndLogRetainsFoodIDAndRetriesOnlyTheLog`
/// (same create-once / submit-twice / product-id assertions).
@MainActor
final class SafetyRepairRegressionTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let generation: UInt64 = 42
    private let accountID = "safety-account"
    private let presentationID = UUID(300)

    private func reviewedDraft() throws -> AssistantReviewedDraft {
        let payload = AssistantFoodDraftPayload(
            name: "Curry",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "100"),
                .init(code: "PROTEIN_G", amountPer100g: "4"),
                .init(code: "CARBS_G", amountPer100g: "10"),
                .init(code: "FAT_G", amountPer100g: "2"),
            ],
            servings: [.init(unit: "plate", gramsPerUnit: "350")]
        )
        return try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: AssistantSuggestedLog(
                amount: "1", unit: "plate", totalWeightGrams: "350"
            ),
            warnings: []
        )
    }

    /// Old `testAssistantAmountAndUnitChangesPreservePer100gTruth`.
    func testAssistantAmountAndUnitChangesPreservePer100gTruth() async throws {
        let definitions = LibraryTestFixtures.definitions
        let draft = try reviewedDraft()
        let store = TestStore(
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
                makeID: { "safety-review" }
            )
            $0.uuid = .incrementing
        }

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
            context: FeatureRequestContext(
                accountID: accountID,
                generation: generation,
                presentationID: presentationID
            ),
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
                FoodUnit(code: "plate", name: "Plate", kind: "serving"),
            ]
            $0.nutrientEditor = NutrientEditorState(
                definitions: definitions,
                initial: [
                    NutrientAmountValue(code: "ENERGY_KCAL", amount: "350", unit: "kcal"),
                    NutrientAmountValue(code: "PROTEIN_G", amount: "14", unit: "g"),
                    NutrientAmountValue(code: "CARBS_G", amount: "35", unit: "g"),
                    NutrientAmountValue(code: "FAT_G", amount: "7", unit: "g"),
                ]
            )
            $0.name = "Curry"
            $0.brand = ""
            $0.amount = "1"
            $0.unit = "plate"
            $0.portionWeightText = "350"
            $0.assistantServingGrams = ["plate": Decimal(350)]
            $0.assistantPortionWeightGrams = Decimal(350)
            $0.assistantQuantityNeedsReview = false
            $0.isDirty = true
        }

        await store.send(.unitChanged("g")) {
            $0.unit = "g"
            $0.amount = "350"
            $0.portionWeightText = "350"
            $0.isDirty = true
            $0.formError = nil
        }
        XCTAssertEqual(store.state.amount, "350")
        XCTAssertEqual(store.state.portionWeightText, "350")

        await store.send(.amountChanged("700")) {
            $0.amount = "700"
            $0.portionWeightText = "700"
            $0.assistantPortionWeightGrams = Decimal(700)
            $0.nutrientEditor.setAmount("700", for: "ENERGY_KCAL")
            $0.nutrientEditor.setAmount("28", for: "PROTEIN_G")
            $0.nutrientEditor.setAmount("70", for: "CARBS_G")
            $0.nutrientEditor.setAmount("14", for: "FAT_G")
            $0.isDirty = true
            $0.formError = nil
        }
        XCTAssertEqual(store.state.portionWeightText, "700")
        XCTAssertEqual(store.state.nutrientEditor.amount(for: "ENERGY_KCAL"), "700")

        await store.send(.unitChanged("plate")) {
            $0.unit = "plate"
            $0.amount = "2"
            $0.portionWeightText = "700"
            $0.isDirty = true
            $0.formError = nil
        }
        XCTAssertEqual(store.state.amount, "2")
        XCTAssertEqual(store.state.portionWeightText, "700")
    }
}
