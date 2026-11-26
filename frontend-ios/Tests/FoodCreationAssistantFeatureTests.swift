import ComposableArchitecture
import XCTest

@testable import CalCo

/// Records the typed handoff callbacks on the main actor so assertions are
/// deterministic and need no sleeps.
@MainActor
private final class HandoffRecorder {
    var acceptedDrafts: [AssistantReviewedDraft] = []
    var expiredGenerations: [UInt64] = []

    func accept(_ draft: AssistantReviewedDraft) {
        acceptedDrafts.append(draft)
    }

    func expire(_ generation: UInt64) {
        expiredGenerations.append(generation)
    }
}

@MainActor
final class FoodCreationAssistantFeatureTests: XCTestCase {
    // Nonzero on purpose: the captured generation must match the active one.
    private let generation: UInt64 = 42

    private func corePayload() -> AssistantFoodDraftPayload {
        AssistantFoodDraftPayload(
            name: "Test Food",
            nutrients: [
                AssistantDraftNutrient(code: NutrientCodes.energyKcal, amountPer100g: "100"),
                AssistantDraftNutrient(code: NutrientCodes.proteinG, amountPer100g: "10"),
                AssistantDraftNutrient(code: NutrientCodes.carbsG, amountPer100g: "20"),
                AssistantDraftNutrient(code: NutrientCodes.fatG, amountPer100g: "5"),
            ],
            servings: [AssistantDraftServing(unit: "g", gramsPerUnit: "1")]
        )
    }

    private func reviewedDraft() throws -> AssistantReviewedDraft {
        try AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "Draft ready",
            draft: corePayload(),
            suggestedLog: nil,
            warnings: []
        )
    }

    private func assistantClient() -> AssistantFeature.Client {
        AssistantFeature.Client(
            status: { AssistantStatus(enabled: true, supportsImages: false) },
            requestDraft: { _, _ in .needsClarification(assistantMessage: "unused") }
        )
    }

    private func handoff(recorder: HandoffRecorder) -> FoodCreationAssistantHandoffClient {
        FoodCreationAssistantHandoffClient(
            acceptReviewedDraft: { draft in recorder.accept(draft) },
            sessionExpired: { generation in recorder.expire(generation) }
        )
    }

    func testActualChildAcceptForwardsReviewedDraftExactlyOnce() async throws {
        let reviewed = try reviewedDraft()
        let recorder = HandoffRecorder()
        let store = TestStore(
            initialState: FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: .customFood,
                    sessionGeneration: generation,
                    draft: .ready(reviewed, accepted: false)
                )
            )
        ) {
            FoodCreationAssistantFeature()
        } withDependencies: {
            $0.assistantClient = assistantClient()
            $0.foodCreationAssistantHandoff = handoff(recorder: recorder)
        }

        // Drive the real child action: it flips `accepted` and emits the
        // delegate, which the parent forwards to the typed handoff.
        await store.send(.assistant(.acceptDraft)) {
            $0.assistant.draft = .ready(reviewed, accepted: true)
        }
        await store.receive(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .customFood,
            sessionGeneration: generation,
            draft: reviewed
        ))))

        // A second user accept is blocked by the child's accepted flag, so no
        // second delegate must reach the handoff.
        await store.send(.assistant(.acceptDraft))
        await store.finish()

        XCTAssertEqual(recorder.acceptedDrafts, [reviewed])
        XCTAssertTrue(recorder.expiredGenerations.isEmpty)
    }

    func testStaleGenerationPayloadIsIgnored() async throws {
        let reviewed = try reviewedDraft()
        let recorder = HandoffRecorder()
        let store = TestStore(
            initialState: FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: .customFood,
                    sessionGeneration: generation,
                    draft: .ready(reviewed, accepted: true)
                )
            )
        ) {
            FoodCreationAssistantFeature()
        } withDependencies: {
            $0.assistantClient = assistantClient()
            $0.foodCreationAssistantHandoff = handoff(recorder: recorder)
        }

        await store.send(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .customFood,
            sessionGeneration: generation - 1,
            draft: reviewed
        ))))
        await store.finish()

        XCTAssertTrue(recorder.acceptedDrafts.isEmpty)
        XCTAssertTrue(recorder.expiredGenerations.isEmpty)
    }

    func testMatchingGenerationExpiryCallsBack() async throws {
        let reviewed = try reviewedDraft()
        let recorder = HandoffRecorder()
        let store = TestStore(
            initialState: FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: .customFood,
                    sessionGeneration: generation,
                    draft: .ready(reviewed, accepted: false)
                )
            )
        ) {
            FoodCreationAssistantFeature()
        } withDependencies: {
            $0.assistantClient = assistantClient()
            $0.foodCreationAssistantHandoff = handoff(recorder: recorder)
        }

        // A stale expiry cannot invalidate the active session.
        await store.send(.assistant(.delegate(.sessionExpired(generation: generation - 1))))
        await store.send(.assistant(.delegate(.sessionExpired(generation: generation))))
        await store.finish()

        XCTAssertEqual(recorder.expiredGenerations, [generation])
        XCTAssertTrue(recorder.acceptedDrafts.isEmpty)
    }

    func testWrongPurposePayloadIsIgnored() async throws {
        let reviewed = try reviewedDraft()
        let recorder = HandoffRecorder()
        let store = TestStore(
            initialState: FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: .customFood,
                    sessionGeneration: generation,
                    draft: .ready(reviewed, accepted: true)
                )
            )
        ) {
            FoodCreationAssistantFeature()
        } withDependencies: {
            $0.assistantClient = assistantClient()
            $0.foodCreationAssistantHandoff = handoff(recorder: recorder)
        }

        await store.send(.assistant(.delegate(.acceptedReviewedDraft(
            purpose: .adHocLog,
            sessionGeneration: generation,
            draft: reviewed
        ))))
        await store.finish()

        XCTAssertTrue(recorder.acceptedDrafts.isEmpty)
    }
}
