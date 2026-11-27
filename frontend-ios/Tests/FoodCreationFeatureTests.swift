import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class FoodCreationFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let generation: UInt64 = 42
    private let accountID = "account-a"

    private func draft(purpose: AssistantDraftPurpose = .customFood) throws -> AssistantReviewedDraft {
        try AssistantReviewedDraft(
            purpose: purpose,
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
            suggestedLog: purpose == .adHocLog
                ? AssistantSuggestedLog(amount: "300", unit: "g", totalWeightGrams: "300")
                : nil,
            warnings: []
        )
    }

    private func makeStore(
        state: FoodCreationFeature.State
    ) -> TestStore<FoodCreationFeature.State, FoodCreationFeature.Action> {
        TestStore(initialState: state) {
            FoodCreationFeature()
        } withDependencies: {
            $0.assistantClient = AssistantFeature.Client(
                status: { AssistantStatus(enabled: true, supportsImages: false) },
                requestDraft: { _, _ in
                    XCTFail("assistant network must not run in this suite")
                    throw AssistantServiceError.disabled
                }
            )
            $0.customFoodEditorClient = CustomFoodEditorFeature.Client(
                definitions: { _ in LibraryTestFixtures.definitions },
                customFood: { _, _ in LibraryTestFixtures.food(id: "food-1") },
                create: { _, _ in "food-1" },
                update: { _, id, _ in id }
            )
            $0.adHocLogClient = AdHocLogFeature.Client(
                definitions: { _ in LibraryTestFixtures.definitions },
                units: { _ in [] },
                create: { _, _ in "food-1" },
                log: LibraryLogClient(
                    submit: { _, _, _, _, _, completion in
                        completion(.failure(.failed("unused")))
                    },
                    isCurrentOwner: { _, _ in false }
                )
            )
            $0.uuid = .incrementing
        }
    }

    private func initialState(
        entry: FoodCreationEntry,
        accepted: AssistantReviewedDraft? = nil
    ) throws -> FoodCreationFeature.State {
        var state = FoodCreationFeature.State(
            entry: entry,
            accountID: accountID,
            generation: generation,
            today: date,
            logContext: LibraryLogContext(date: date, mealSlot: .lunch)
        )
        if let accepted {
            state.assistant = FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: .customFood,
                    sessionGeneration: generation,
                    draft: .ready(accepted, accepted: true)
                )
            )
        }
        return state
    }

    func testAcceptedAssistantDraftOpensEditorAndCompletionFinishesWholeTask() async throws {
        let reviewed = try draft()
        let store = makeStore(state: try initialState(
            entry: .assistant(purpose: .customFood, barcode: nil), accepted: reviewed
        ))

        let expectedEditor = CustomFoodEditorFeature.State(
            mode: .create,
            accountID: accountID,
            generation: generation,
            presentationID: store.state.presentationID,
            assistantDraft: reviewed
        )
        await store.send(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .customFood,
            sessionGeneration: generation,
            draft: reviewed
        )))) {
            $0.editor = expectedEditor
            $0.acceptedDraft = reviewed
            $0.isReviewPresented = true
        }.finish()

        XCTAssertNotNil(store.state.editor)
        XCTAssertTrue(store.state.isReviewPresented)
        XCTAssertEqual(store.state.acceptedDraft, reviewed)

        await store.send(.editor(.delegate(.saved(
            id: "food-1", generation: generation,
            presentationID: store.state.presentationID
        ))))
        await store.receive(.delegate(.finished(
            generation: generation, presentationID: store.state.presentationID
        )))
    }

    func testBarcodeEntryCreatesEditorWithoutAssistantHost() async throws {
        let store = makeStore(state: try initialState(entry: .barcode("0123456789012")))
        XCTAssertNil(store.state.assistant)
        XCTAssertNotNil(store.state.editor)
        XCTAssertEqual(store.state.editor?.initialBarcode, "0123456789012")
        XCTAssertFalse(store.state.isReviewPresented)
    }

    func testBackFromReviewRetainsTheEditedDraft() async throws {
        let reviewed = try draft()
        let store = makeStore(state: try initialState(
            entry: .assistant(purpose: .customFood, barcode: nil), accepted: reviewed
        ))
        let expectedEditor = CustomFoodEditorFeature.State(
            mode: .create,
            accountID: accountID,
            generation: generation,
            presentationID: store.state.presentationID,
            assistantDraft: reviewed
        )
        await store.send(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .customFood,
            sessionGeneration: generation,
            draft: reviewed
        )))) {
            $0.editor = expectedEditor
            $0.acceptedDraft = reviewed
            $0.isReviewPresented = true
        }.finish()
        await store.send(.reviewPresentedChanged(false)) {
            $0.isReviewPresented = false
        }
        await store.send(.editor(.nameChanged("My edited millet"))) {
            $0.editor?.isDirty = true
            $0.editor?.submitError = nil
            $0.editor?.name = "My edited millet"
        }
        await store.send(.reviewPresentedChanged(true)) {
            $0.isReviewPresented = true
        }

        XCTAssertTrue(store.state.isReviewPresented)
        XCTAssertEqual(store.state.editor?.name, "My edited millet")
        XCTAssertEqual(store.state.assistant?.assistant.messages, [])
    }

    func testStaleGenerationAcceptCannotOpenAReview() async throws {
        let reviewed = try draft()
        let store = makeStore(state: try initialState(
            entry: .assistant(purpose: .customFood, barcode: nil), accepted: reviewed
        ))
        await store.send(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .customFood,
            sessionGeneration: generation + 1,
            draft: reviewed
        )))).finish()
        XCTAssertNil(store.state.editor)
        XCTAssertFalse(store.state.isReviewPresented)
    }

    func testAdHocLoggedEventIsForwardedWithAuthoritativeRows() async throws {
        let reviewed = try draft(purpose: .adHocLog)
        var state = try initialState(
            entry: .assistant(purpose: .adHocLog, barcode: nil), accepted: reviewed
        )
        state.assistant = FoodCreationAssistantFeature.State(
            assistant: AssistantFeature.State(
                purpose: .adHocLog,
                sessionGeneration: generation,
                draft: .ready(reviewed, accepted: true)
            )
        )
        let store = makeStore(state: state)
        let expectedAdHoc = AdHocLogFeature.State(
            accountID: accountID,
            generation: generation,
            today: date,
            logContext: LibraryLogContext(date: date, mealSlot: .lunch),
            presentationID: store.state.presentationID,
            assistantDraft: reviewed
        )
        await store.send(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .adHocLog,
            sessionGeneration: generation,
            draft: reviewed
        )))) {
            $0.adHoc = expectedAdHoc
            $0.acceptedDraft = reviewed
            $0.isReviewPresented = true
        }.finish()
        XCTAssertNotNil(store.state.adHoc)

        let event = LibraryLoggedEvent(
            intentID: "intent-1",
            drafts: [],
            logs: [FoodLog(
                id: "log-1", logDate: date, mealSlot: .lunch,
                item: .adHoc(AdHocLogItemSnapshot(name: "Millet")),
                quantity: NutritionQuantity(amount: "100", unit: "g")
            )],
            accountID: accountID,
            generation: generation,
            date: date,
            slot: .lunch,
            presentationID: state.presentationID
        )
        await store.send(.adHoc(.delegate(.logged(event: event))))
        await store.receive(.delegate(.logged(event: event)))
        await store.receive(.delegate(.finished(
            generation: generation, presentationID: state.presentationID
        )))
    }
}
