import ComposableArchitecture
import XCTest

@testable import CalCo

private actor CreationAssistantService: AssistantServicing {
    private(set) var requestCount = 0

    func assistantStatus() async throws -> AssistantStatus {
        AssistantStatus(enabled: true, supportsImages: false)
    }

    func requestDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn {
        requestCount += 1
        return .draftReady(
            assistantMessage: "Review before saving.",
            draft: AssistantFoodDraftPayload(
                name: "Millet",
                nutrients: [
                    .init(code: "ENERGY_KCAL", amountPer100g: "350"),
                    .init(code: "PROTEIN_G", amountPer100g: "10"),
                    .init(code: "CARBS_G", amountPer100g: "70"),
                    .init(code: "FAT_G", amountPer100g: "3"),
                ]
            ),
            suggestedLog: nil,
            warnings: []
        )
    }
}

@MainActor
final class FoodCreationFlowTests: XCTestCase {
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 24)

    private func context(
        library: FakeLibraryService,
        assistant: CreationAssistantService
    ) -> FoodCreationContext {
        FoodCreationContext(
            libraryService: library,
            assistantService: assistant,
            submissionService: FakeLibraryLogSubmissionService(results: []),
            accountID: "account-a",
            today: today,
            logContext: LibraryLogContext(date: today, mealSlot: .lunch),
            sessionGeneration: 42,
            onLogged: { _, _ in },
            onSessionExpired: {}
        )
    }

    func testReturningFromReviewPreservesEditsAndConversationWithoutAnotherAIRequest() async throws {
        try await withDependencies {
            $0.uuid = .incrementing
        } operation: {
            let library = FakeLibraryService()
            let assistant = CreationAssistantService()
            var finished = false
            let model = FoodCreationFlowModel(
                request: FoodCreationRequest(entry: .assistant(.customFood, barcode: nil)),
                context: context(library: library, assistant: assistant),
                onFinished: { finished = true }
            )
            let store = try XCTUnwrap(
                model.assistantStore?.scope(state: \.assistant, action: \.assistant)
            )
            await store.send(.loadStatus).finish()
            store.send(.composerChanged("Millet"))
            await store.send(.send).finish()
            await store.send(.acceptDraft).finish()
            XCTAssertTrue(model.isReviewPresented)
            let editor = try XCTUnwrap(model.editor)
            await editor.load()
            editor.name = "My edited millet"

            model.isReviewPresented = false
            store.send(.resumeDraftReview)
            await store.send(.acceptDraft).finish()

            XCTAssertTrue(model.isReviewPresented)
            XCTAssertTrue(model.editor === editor)
            XCTAssertEqual(model.editor?.name, "My edited millet")
            XCTAssertFalse(store.messages.isEmpty)
            let requests = await assistant.requestCount
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(library.createCallCount, 0)
            XCTAssertFalse(finished)
        }
    }

    func testSavingReviewFinishesWholeTaskOnlyAfterSuccessfulSave() async throws {
        try await withDependencies {
            $0.uuid = .incrementing
        } operation: {
            let library = FakeLibraryService()
            library.enqueueCreate(.failure(.failed("Try again")))
            library.enqueueCreate(.success("created-food"))
            let assistant = CreationAssistantService()
            var completions = 0
            let model = FoodCreationFlowModel(
                request: FoodCreationRequest(entry: .assistant(.customFood, barcode: "0123456789012")),
                context: context(library: library, assistant: assistant),
                onFinished: { completions += 1 }
            )
            let store = try XCTUnwrap(
                model.assistantStore?.scope(state: \.assistant, action: \.assistant)
            )
            await store.send(.loadStatus).finish()
            store.send(.composerChanged("Millet"))
            await store.send(.send).finish()
            await store.send(.acceptDraft).finish()
            let editor = try XCTUnwrap(model.editor)
            await editor.load()

            await editor.submit()
            XCTAssertEqual(completions, 0)
            XCTAssertTrue(model.isReviewPresented)
            await editor.submit()

            XCTAssertEqual(completions, 1)
            XCTAssertTrue(editor.barcodeNotice?.contains("0123456789012") == true)
            XCTAssertEqual(library.listCallCount, 0, "Creation must not open a second Library list")
        }
    }

    func testBarcodeCreationFinishesAtCallerWithoutOpeningReviewOrLibrary() async throws {
        let library = FakeLibraryService()
        library.enqueueCreate(.success("created-food"))
        var finished = false
        let model = FoodCreationFlowModel(
            request: FoodCreationRequest(entry: .barcode("0123456789012")),
            context: context(library: library, assistant: CreationAssistantService()),
            onFinished: { finished = true }
        )
        let editor = try XCTUnwrap(model.editor)
        await editor.load()
        editor.name = "Barcode food"
        for code in ["ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G"] {
            editor.setNutrientAmount("0", code: code)
        }
        await editor.submit()

        XCTAssertTrue(finished)
        XCTAssertFalse(model.isReviewPresented)
        XCTAssertTrue(editor.barcodeNotice?.contains("0123456789012") == true)
        XCTAssertEqual(library.listCallCount, 0)
    }
}
