import XCTest

@testable import CalCo

@MainActor
final class LibraryViewModelTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let accountID = "account-a"

    private func makeEditor(
        mode: CustomFoodEditorMode = .create,
        service: FakeLibraryService,
        assistantDraft: AssistantReviewedDraft? = nil,
        initialBarcode: String? = nil,
        onSaved: @escaping (String) -> Void = { _ in }
    ) -> CustomFoodEditorViewModel {
        CustomFoodEditorViewModel(
            mode: mode,
            service: service,
            accountID: accountID,
            onSaved: onSaved,
            assistantDraft: assistantDraft,
            initialBarcode: initialBarcode
        )
    }

    private func makeAdHoc(
        service: FakeLibraryService,
        submission: any LibraryLogSubmitting,
        assistantDraft: AssistantReviewedDraft? = nil,
        onLogged: @escaping (LocalDiaryDate, MealSlot?) -> Void = { _, _ in }
    ) -> AdHocLogViewModel {
        AdHocLogViewModel(
            service: service,
            submissionService: submission,
            accountID: accountID,
            initialDate: date,
            today: date,
            initialMealSlot: .lunch,
            timeZoneProvider: { "Asia/Kolkata" },
            onLogged: onLogged,
            assistantDraft: assistantDraft
        )
    }

    private func fillRequiredNutrients(
        _ viewModel: CustomFoodEditorViewModel,
        energy: String = "100",
        protein: String = "4",
        carbs: String = "10",
        fat: String = "2"
    ) {
        viewModel.setNutrientAmount(energy, code: "ENERGY_KCAL")
        viewModel.setNutrientAmount(protein, code: "PROTEIN_G")
        viewModel.setNutrientAmount(carbs, code: "CARBS_G")
        viewModel.setNutrientAmount(fat, code: "FAT_G")
    }

    private func customAssistantDraft() throws -> AssistantReviewedDraft {
        try AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "draft",
            draft: AssistantFoodDraftPayload(
                name: "Millet",
                brand: "Home",
                categories: ["Breakfast"],
                defaultQuantity: "40",
                defaultUnit: "g",
                nutrients: [
                    .init(code: "ENERGY_KCAL", amountPer100g: "350"),
                    .init(code: "PROTEIN_G", amountPer100g: "10"),
                    .init(code: "CARBS_G", amountPer100g: "70"),
                    .init(code: "FAT_G", amountPer100g: "3"),
                ],
                servings: [
                    .init(unit: "cup", gramsPerUnit: "120"),
                ]
            ),
            suggestedLog: nil,
            warnings: [],
            barcode: "0123456789012"
        )
    }

    private func adHocAssistantDraft() throws -> AssistantReviewedDraft {
        try AssistantReviewedDraft(
            purpose: .adHocLog,
            assistantMessage: "draft",
            draft: AssistantFoodDraftPayload(
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
            ),
            suggestedLog: AssistantSuggestedLog(
                amount: "1",
                unit: "bowl",
                totalWeightGrams: "300"
            ),
            warnings: []
        )
    }

    private func fillAdHoc(
        _ viewModel: AdHocLogViewModel,
        name: String = "Bowl",
        unit: String = "bowl",
        portionWeight: String = "300"
    ) {
        viewModel.name = name
        viewModel.amount = "1"
        viewModel.unit = unit
        viewModel.portionWeightText = portionWeight
        viewModel.setNutrientAmount("250", code: "ENERGY_KCAL")
        viewModel.setNutrientAmount("10", code: "PROTEIN_G")
        viewModel.setNutrientAmount("40", code: "CARBS_G")
        viewModel.setNutrientAmount("5", code: "FAT_G")
        viewModel.mode = .saveAndLog
    }

    func testCreateRetainsReturnedID() async throws {
        let service = FakeLibraryService()
        var savedID: String?
        let editor = makeEditor(service: service, onSaved: { savedID = $0 })
        await editor.load()
        editor.name = "Oats"
        fillRequiredNutrients(editor)
        service.enqueueCreate(.success("new-food"))

        await editor.submit()

        XCTAssertEqual(editor.savedFoodID, "new-food")
        XCTAssertEqual(savedID, "new-food")
        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testCreateUncertainShowsOrdinaryErrorAndAllowsExplicitRetry() async throws {
        let service = FakeLibraryService()
        let editor = makeEditor(service: service)
        await editor.load()
        editor.name = "Oats"
        fillRequiredNutrients(editor)
        service.enqueueCreate(.failure(.uncertain("lost")))

        await editor.submit()

        XCTAssertNil(editor.savedFoodID)
        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertNotNil(editor.submitError)
        XCTAssertTrue(editor.isFormEditable)

        // A deliberate second submit is a normal duplicate-capable retry; no
        // durable guard or reconciliation state blocks it.
        service.enqueueCreate(.success("new-food"))
        await editor.submit()
        XCTAssertEqual(editor.savedFoodID, "new-food")
        XCTAssertEqual(service.createCallCount, 2)
    }

    func testEditLoadsAndSavesServings() async throws {
        let service = FakeLibraryService()
        service.storeFood(LibraryTestFixtures.food(id: "food-1"))
        let editor = makeEditor(mode: .edit(id: "food-1"), service: service)
        await editor.load()
        XCTAssertEqual(editor.name, "Oats")
        editor.addServingRow()
        let rowID = try XCTUnwrap(editor.servings.first?.id)
        editor.updateServingRow(id: rowID, unit: "cup", gramsPerUnit: "40")
        service.enqueueUpdate(.success("food-1"))

        await editor.submit()

        let update = try XCTUnwrap(service.updatedRequests.first)
        XCTAssertEqual(update.id, "food-1")
        XCTAssertEqual(update.request.servings, [
            CustomFoodServingWrite(unit: "cup", gramsPerUnit: 40),
        ])
        XCTAssertEqual(editor.savedFoodID, "food-1")
    }

    func testSaveThenLogUncertainRetainsFoodIDAndRetryLogsWithoutCreate() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [.failure(.uncertain("lost log response"))]
        )
        let adHoc = makeAdHoc(service: service, submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        service.enqueueCreate(.success("new-food"))

        adHoc.requestReview()
        await adHoc.confirmReview()

        XCTAssertEqual(adHoc.savedFoodID, "new-food")
        guard case .failed = adHoc.savedFoodLogState else {
            return XCTFail("uncertain log must report a failed message")
        }
        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertEqual(submission.submissions.count, 1)
        XCTAssertFalse(adHoc.canReview)

        submission.enqueue(.success([]))
        await adHoc.retrySavedFoodLog()
        XCTAssertEqual(submission.submissions.count, 2)
        XCTAssertEqual(submission.submissions[1].drafts[0].item, .product(id: "new-food"))
        XCTAssertEqual(service.createCallCount, 1)
    }

    func testSaveThenLogDefinitiveFailureRetriesProductOnly() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [
                .failure(.failed("invalid log")),
                .success([]),
            ]
        )
        var loggedDate: LocalDiaryDate?
        let adHoc = makeAdHoc(
            service: service,
            submission: submission,
            onLogged: { date, _ in loggedDate = date }
        )
        await adHoc.load()
        fillAdHoc(adHoc)
        service.enqueueCreate(.success("new-food"))

        adHoc.requestReview()
        await adHoc.confirmReview()
        XCTAssertEqual(adHoc.savedFoodID, "new-food")
        guard case .failed = adHoc.savedFoodLogState else {
            return XCTFail("definitive rejection must be retryable")
        }

        await adHoc.retrySavedFoodLog()

        XCTAssertEqual(submission.submissions.count, 2)
        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertEqual(submission.submissions[1].drafts[0].item, .product(id: "new-food"))
        XCTAssertEqual(submission.submissions[1].drafts[0].unit, "bowl")
        XCTAssertEqual(loggedDate, date)
    }

    func testSaveAndLogKeepsRetainedFoodWhenLogFails() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [.failure(.failed("server rejected"))]
        )
        let adHoc = makeAdHoc(service: service, submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        service.enqueueCreate(.success("new-food"))

        adHoc.requestReview()
        await adHoc.confirmReview()

        XCTAssertEqual(adHoc.savedFoodID, "new-food")
        XCTAssertEqual(adHoc.savedLogIntent?.amount, "1")
        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertEqual(submission.submissions.count, 1)
    }

    func testLogOnlyUsesAdHocDraftWithAbsoluteNutrientsAndNoCreate() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(results: [.success([])])
        var loggedDate: LocalDiaryDate?
        let adHoc = makeAdHoc(
            service: service,
            submission: submission,
            onLogged: { date, _ in loggedDate = date }
        )
        await adHoc.load()
        adHoc.name = "Bowl"
        adHoc.amount = "1"
        adHoc.unit = "bowl"
        adHoc.mode = .logOnly
        adHoc.setNutrientAmount("250", code: "ENERGY_KCAL")
        adHoc.setNutrientAmount("10", code: "PROTEIN_G")
        adHoc.setNutrientAmount("40", code: "CARBS_G")
        adHoc.setNutrientAmount("5", code: "FAT_G")

        adHoc.requestReview()
        await adHoc.confirmReview()

        XCTAssertEqual(service.createCallCount, 0)
        XCTAssertEqual(submission.submissions.count, 1)
        let draft = submission.submissions[0].drafts[0]
        XCTAssertEqual(draft.item, .adHoc(name: "Bowl", brand: nil))
        XCTAssertEqual(draft.mealSlot, .lunch)
        XCTAssertEqual(
            draft.nutrients?.first { $0.code == "ENERGY_KCAL" }?.amount,
            "250"
        )
        XCTAssertEqual(loggedDate, date)
    }

    func testUncertainAdHocLogShowsFailureAndAllowsAnotherReview() async throws {
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [.failure(.uncertain("lost")), .success([])]
        )
        let adHoc = makeAdHoc(service: service, submission: submission)
        await adHoc.load()
        adHoc.name = "Bowl"
        adHoc.amount = "1"
        adHoc.unit = "g"
        adHoc.mode = .logOnly
        adHoc.setNutrientAmount("250", code: "ENERGY_KCAL")
        adHoc.setNutrientAmount("10", code: "PROTEIN_G")
        adHoc.setNutrientAmount("40", code: "CARBS_G")
        adHoc.setNutrientAmount("5", code: "FAT_G")

        adHoc.requestReview()
        await adHoc.confirmReview()
        guard case .failed = adHoc.submissionState else {
            return XCTFail("uncertain log must surface an ordinary error")
        }
        XCTAssertTrue(adHoc.canReview)
        adHoc.requestReview()
        await adHoc.confirmReview()
        XCTAssertEqual(submission.submissions.count, 2)
        XCTAssertTrue(adHoc.isSubmissionCompleted)
    }

    func testHandlerSubmissionServiceUsesSharedLogSubmissionHandler() async {
        var seededDraft: LogSubmissionDraft?
        let submission = HandlerLibraryLogSubmissionService { drafts, names, summary, completion in
            seededDraft = drafts.first
            XCTAssertEqual(names, ["Bowl"])
            XCTAssertEqual(summary, "Bowl")
            completion(.success([]))
        }
        let draft = LogSubmissionDraft(
            item: .adHoc(name: "Bowl", brand: nil),
            date: date,
            mealSlot: .lunch,
            amount: "1",
            unit: "bowl",
            notes: nil,
            timeZone: "Asia/Kolkata",
            nutrients: [
                NutrientAmountValue(code: "ENERGY_KCAL", amount: "250", unit: "kcal"),
            ]
        )

        let result = await submission.submit(
            accountID: accountID,
            drafts: [draft],
            itemNames: ["Bowl"],
            summary: "Bowl",
            baseURL: nil
        )

        XCTAssertEqual(result, .success([]))
        XCTAssertEqual(seededDraft, draft)
    }

    func testDeleteUncertainRechecksAndCompletesWhenFoodIsGone() async throws {
        let service = FakeLibraryService()
        service.storeFood(LibraryTestFixtures.food(id: "food-1"))
        service.enqueueDelete(.failure(.uncertain("lost delete response")))
        var deletedID: String?
        let detail = CustomFoodDetailViewModel(
            foodID: "food-1",
            service: service,
            onDeleted: { deletedID = $0 }
        )
        await detail.load()
        service.enqueueList(.success([]))

        await detail.delete()

        XCTAssertEqual(deletedID, "food-1")
    }

    func testDeleteOwnershipRejectionShowsServerMessage() async throws {
        let service = FakeLibraryService()
        service.storeFood(LibraryTestFixtures.food(id: "food-1"))
        service.enqueueDelete(.failure(.failed("only the creator may modify this custom food")))
        let detail = CustomFoodDetailViewModel(foodID: "food-1", service: service)
        await detail.load()

        await detail.delete()

        XCTAssertEqual(
            detail.deleteErrorMessage,
            "only the creator may modify this custom food"
        )
    }

    func testAdHocDraftIsNotAppliedToCustomFoodCreate() async throws {
        let draft = try adHocAssistantDraft()
        let editor = makeEditor(
            service: FakeLibraryService(),
            assistantDraft: draft
        )

        await editor.load()

        XCTAssertEqual(editor.name, "")
        XCTAssertFalse(editor.applyAssistantDraft(draft))
        XCTAssertEqual(editor.name, "")
    }

    func testInitialCustomDraftIsAppliedOnceAndDoesNotOverwriteEdits() async throws {
        let draft = try customAssistantDraft()
        let editor = makeEditor(
            service: FakeLibraryService(),
            assistantDraft: draft
        )

        await editor.load()
        XCTAssertEqual(editor.name, "Millet")
        XCTAssertNotNil(editor.barcodeNotice)

        editor.name = "Edited after prefill"
        await editor.load()

        XCTAssertEqual(editor.name, "Edited after prefill")
    }

    func testCapturedReviewConfirmsAfterPendingBindingCleared() async throws {
        let submission = FakeLibraryLogSubmissionService(results: [.success([])])
        let adHoc = makeAdHoc(service: FakeLibraryService(), submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        adHoc.mode = .logOnly
        adHoc.requestReview()

        let review = try XCTUnwrap(adHoc.pendingReview)
        adHoc.pendingReview = nil
        await adHoc.confirmReview(review)
        await adHoc.confirmReview(review)

        XCTAssertTrue(adHoc.isSubmissionCompleted)
        XCTAssertEqual(submission.submissions.count, 1)
    }

    func testStaleCapturedReviewAfterNewReviewSendsNothing() async throws {
        let submission = FakeLibraryLogSubmissionService(results: [.success([])])
        let adHoc = makeAdHoc(service: FakeLibraryService(), submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        adHoc.mode = .logOnly

        adHoc.requestReview()
        let first = try XCTUnwrap(adHoc.pendingReview)
        adHoc.requestReview()
        let second = try XCTUnwrap(adHoc.pendingReview)
        XCTAssertNotEqual(first.id, second.id)

        await adHoc.confirmReview(first)

        XCTAssertEqual(submission.submissions.count, 0)
        XCTAssertEqual(adHoc.pendingReview?.id, second.id)

        await adHoc.confirmReview(second)

        XCTAssertEqual(submission.submissions.count, 1)
        XCTAssertTrue(adHoc.isSubmissionCompleted)
    }

    func testConcurrentSameCapturedReviewSendsOneLogOnly() async throws {
        let submission = HoldingLibraryLogSubmissionService()
        let adHoc = makeAdHoc(service: FakeLibraryService(), submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        adHoc.mode = .logOnly
        adHoc.requestReview()

        let review = try XCTUnwrap(adHoc.pendingReview)
        adHoc.pendingReview = nil
        let first = Task { await adHoc.confirmReview(review) }
        await submission.waitUntilStarted()
        await adHoc.confirmReview(review)
        submission.release()
        await first.value

        XCTAssertEqual(submission.submissions, 1)
        XCTAssertTrue(adHoc.isSubmissionCompleted)
    }

    func testConfirmedSaveAndLogReviewWritesOnce() async throws {
        let service = FakeLibraryService()
        service.enqueueCreate(.success("new-food"))
        let submission = FakeLibraryLogSubmissionService(results: [.success([])])
        let adHoc = makeAdHoc(service: service, submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        adHoc.requestReview()

        let review = try XCTUnwrap(adHoc.pendingReview)
        adHoc.pendingReview = nil
        await adHoc.confirmReview(review)
        await adHoc.confirmReview(review)

        XCTAssertEqual(service.createCallCount, 1)
        XCTAssertEqual(submission.submissions.count, 1)
        XCTAssertTrue(adHoc.hasLoggedSavedFood)
    }

    func testNewReviewAfterDefinitiveFailureIsAllowed() async throws {
        let submission = FakeLibraryLogSubmissionService(results: [
            .failure(.failed("definitive")),
            .success([]),
        ])
        let adHoc = makeAdHoc(service: FakeLibraryService(), submission: submission)
        await adHoc.load()
        fillAdHoc(adHoc)
        adHoc.mode = .logOnly
        adHoc.requestReview()

        let first = try XCTUnwrap(adHoc.pendingReview)
        adHoc.pendingReview = nil
        await adHoc.confirmReview(first)
        guard case .failed = adHoc.submissionState else {
            return XCTFail("The first review must fail definitively.")
        }

        adHoc.requestReview()
        let second = try XCTUnwrap(adHoc.pendingReview)
        XCTAssertNotEqual(first.id, second.id)
        adHoc.pendingReview = nil
        await adHoc.confirmReview(second)

        XCTAssertEqual(submission.submissions.count, 2)
        XCTAssertTrue(adHoc.isSubmissionCompleted)
    }

    func testInitialAdHocDraftIsAppliedOnceAndDoesNotOverwriteEdits() async throws {
        let draft = try adHocAssistantDraft()
        let adHoc = makeAdHoc(
            service: FakeLibraryService(),
            submission: FakeLibraryLogSubmissionService(results: []),
            assistantDraft: draft
        )

        await adHoc.load()
        XCTAssertEqual(adHoc.name, "Curry")

        adHoc.name = "Edited ad hoc"
        await adHoc.load()

        XCTAssertEqual(adHoc.name, "Edited ad hoc")
    }

    func testAssistantCustomFoodPrefillKeepsUnitsServingsAndBarcodeNotice() async throws {
        let service = FakeLibraryService()
        let editor = makeEditor(service: service)
        await editor.load()
        let payload = AssistantFoodDraftPayload(
            name: "Millet",
            brand: "Home",
            categories: ["Breakfast"],
            defaultQuantity: "40",
            defaultUnit: "g",
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: "350"),
                .init(code: "PROTEIN_G", amountPer100g: "10"),
                .init(code: "CARBS_G", amountPer100g: "70"),
                .init(code: "FAT_G", amountPer100g: "3"),
            ],
            servings: [
                .init(unit: "cup", gramsPerUnit: "120"),
            ]
        )
        let draft = try AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "draft",
            draft: payload,
            suggestedLog: nil,
            warnings: [],
            barcode: "0123456789012"
        )

        XCTAssertTrue(editor.applyAssistantDraft(draft))

        XCTAssertEqual(editor.name, "Millet")
        XCTAssertEqual(editor.brand, "Home")
        XCTAssertEqual(editor.categoriesText, "breakfast")
        XCTAssertEqual(editor.defaultQuantity, "40")
        XCTAssertEqual(editor.defaultUnit, "g")
        XCTAssertEqual(editor.servings.first?.unit, "cup")
        XCTAssertEqual(editor.nutrientEditor.amount(for: "ENERGY_KCAL"), "350")
        XCTAssertNotNil(editor.barcodeNotice)
    }

    func testAssistantAdHocPrefillUsesSuggestedWeightForAbsoluteTotals() async throws {
        let service = FakeLibraryService()
        let adHoc = makeAdHoc(
            service: service,
            submission: FakeLibraryLogSubmissionService(results: [])
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

        XCTAssertEqual(adHoc.name, "Curry")
        XCTAssertEqual(adHoc.amount, "1")
        XCTAssertEqual(adHoc.unit, "bowl")
        XCTAssertEqual(adHoc.portionWeightText, "300")
        XCTAssertEqual(adHoc.nutrientEditor.amount(for: "ENERGY_KCAL"), "300")
        XCTAssertEqual(adHoc.nutrientEditor.amount(for: "PROTEIN_G"), "12")
    }
}

@MainActor
private final class HoldingLibraryLogSubmissionService: LibraryLogSubmitting {
    private(set) var submissions = 0
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func submit(
        accountID: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String],
        summary: String,
        baseURL: URL?
    ) async -> LogSubmissionServiceResult {
        submissions += 1
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .success([])
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
