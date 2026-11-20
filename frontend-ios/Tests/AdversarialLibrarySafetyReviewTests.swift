import XCTest

@testable import CalCo

/// Regression checks for assistant-prefilled ad-hoc drafts. These use only
/// injected fakes; no network, database, real keys, or app-support files.
@MainActor
final class AdversarialLibrarySafetyReviewTests: XCTestCase {
    private let accountID = "review-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    /// AI drafts may name a serving unit ("plate", "bowl", ...) that is not in
    /// the server's global unit list. The ad-hoc editor must merge that unit so
    /// the picker can display the accepted draft instead of showing no selection.
    func testAssistantSuggestedServingUnitIsSelectableInAdHocEditor() async throws {
        let service = FakeLibraryService()
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: FakeLibraryLogSubmissionService(results: []),
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await adHoc.load()
        let payload = AssistantFoodDraftPayload(
            name: "Curry",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "100"),
                .init(code: "PROTEIN_G", amountPer100g: "4"),
                .init(code: "CARBS_G", amountPer100g: "10"),
                .init(code: "FAT_G", amountPer100g: "2"),
            ],
            servings: [
                .init(unit: "plate", gramsPerUnit: "350"),
            ]
        )
        let draft = try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: AssistantSuggestedLog(
                amount: "1",
                unit: "plate",
                totalWeightGrams: "350"
            ),
            warnings: []
        )

        XCTAssertTrue(adHoc.applyAssistantDraft(draft))
        XCTAssertEqual(adHoc.unit, "plate")
        XCTAssertTrue(
            adHoc.units.contains { $0.code == "plate" },
            "the unit picker must be able to represent the assistant's serving unit"
        )
    }

    /// Switching an AI-prefilled ad-hoc draft from its serving unit to grams
    /// must not turn the absolute nutrient totals into a wildly wrong per-100 g
    /// catalog food.
    func testAssistantUnitChangeToGramsMustNotCorruptPer100g() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(results: [.success([])])
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: submission,
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await adHoc.load()
        let payload = AssistantFoodDraftPayload(
            name: "Curry",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "100"),
                .init(code: "PROTEIN_G", amountPer100g: "4"),
                .init(code: "CARBS_G", amountPer100g: "10"),
                .init(code: "FAT_G", amountPer100g: "2"),
            ],
            servings: [
                .init(unit: "plate", gramsPerUnit: "350"),
            ]
        )
        let draft = try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: AssistantSuggestedLog(
                amount: "1",
                unit: "plate",
                totalWeightGrams: "350"
            ),
            warnings: []
        )
        XCTAssertTrue(adHoc.applyAssistantDraft(draft))
        adHoc.mode = .saveAndLog

        adHoc.unit = "g"
        adHoc.requestReview()
        guard adHoc.pendingReview != nil else {
            return XCTFail("the converted draft should be reviewable")
        }
        service.enqueueCreate(.success("new-food"))
        await adHoc.confirmReview()

        let created = try XCTUnwrap(service.createdRequests.first)
        let energy = try XCTUnwrap(
            created.nutrients.first { $0.code == "ENERGY_KCAL" }
        )
        XCTAssertEqual(
            energy.amountPer100g,
            Decimal(100),
            "changing the display unit must not turn 100 kcal/100 g into \(energy.amountPer100g) kcal/100 g"
        )
    }

    func testAssistantAmountChangeScalesAbsoluteNutrients() async throws {
        let adHoc = AdHocLogViewModel(
            service: FakeLibraryService(),
            submissionService: FakeLibraryLogSubmissionService(results: []),
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await adHoc.load()
        let payload = AssistantFoodDraftPayload(
            name: "Curry",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "100"),
                .init(code: "PROTEIN_G", amountPer100g: "4"),
                .init(code: "CARBS_G", amountPer100g: "10"),
                .init(code: "FAT_G", amountPer100g: "2"),
            ],
            servings: [
                .init(unit: "bowl", gramsPerUnit: "300"),
            ]
        )
        let draft = try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: AssistantSuggestedLog(
                amount: "1",
                unit: "bowl",
                totalWeightGrams: "300"
            ),
            warnings: []
        )
        XCTAssertTrue(adHoc.applyAssistantDraft(draft))
        XCTAssertEqual(adHoc.nutrientEditor.amount(for: "ENERGY_KCAL"), "300")

        adHoc.amount = "2"

        XCTAssertEqual(adHoc.nutrientEditor.amount(for: "ENERGY_KCAL"), "600")
        XCTAssertEqual(adHoc.portionWeightText, "600")
    }
}
