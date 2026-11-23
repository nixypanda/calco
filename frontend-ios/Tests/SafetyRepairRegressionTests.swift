import XCTest

@testable import CalCo

/// Ordinary safety regressions for assistant-prefilled saves. No journal,
/// database, network, or app-support files are used.
@MainActor
final class SafetyRepairRegressionTests: XCTestCase {
    private let accountID = "safety-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    func testAssistantAmountAndUnitChangesPreservePer100gTruth() async throws {
        let service = FakeLibraryService()
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: FakeLibraryLogSubmissionService(
                results: [.success([])]
            ),
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
            servings: [.init(unit: "plate", gramsPerUnit: "350")]
        )
        let reviewed = try AssistantReviewedDraft(
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
        XCTAssertTrue(adHoc.applyAssistantDraft(reviewed))
        adHoc.mode = .saveAndLog

        adHoc.unit = "g"
        XCTAssertEqual(adHoc.amount, "350")
        XCTAssertEqual(adHoc.portionWeightText, "350")

        adHoc.amount = "700"
        XCTAssertEqual(adHoc.portionWeightText, "700")
        XCTAssertEqual(adHoc.nutrientEditor.amount(for: "ENERGY_KCAL"), "700")

        adHoc.unit = "plate"
        XCTAssertEqual(adHoc.amount, "2")
        XCTAssertEqual(adHoc.portionWeightText, "700")

        adHoc.requestReview()
        service.enqueueCreate(.success("new-food"))
        await adHoc.confirmReview()

        let created = try XCTUnwrap(service.createdRequests.first)
        let energy = try XCTUnwrap(created.nutrients.first { $0.code == "ENERGY_KCAL" })
        XCTAssertEqual(energy.amountPer100g, Decimal(100))
    }

    func testSavedFoodLogFailureRetainsReturnedFoodForRetry() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [.failure(.failed("temporary")), .success([])]
        )
        let adHoc = AdHocLogViewModel(
            service: service,
            submissionService: submission,
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
        await adHoc.load()
        adHoc.name = "Bowl"
        adHoc.amount = "1"
        adHoc.unit = "g"
        adHoc.mode = .saveAndLog
        adHoc.setNutrientAmount("250", code: "ENERGY_KCAL")
        adHoc.setNutrientAmount("10", code: "PROTEIN_G")
        adHoc.setNutrientAmount("40", code: "CARBS_G")
        adHoc.setNutrientAmount("5", code: "FAT_G")
        service.enqueueCreate(.success("new-food"))

        adHoc.requestReview()
        await adHoc.confirmReview()

        XCTAssertEqual(adHoc.savedFoodID, "new-food")
        guard case .failed = adHoc.savedFoodLogState else {
            return XCTFail("failed log should be retryable")
        }

        await adHoc.retrySavedFoodLog()

        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertEqual(submission.submissions.count, 2)
        XCTAssertEqual(
            submission.submissions.last?.drafts.first?.item,
            .product(id: "new-food")
        )
    }
}
