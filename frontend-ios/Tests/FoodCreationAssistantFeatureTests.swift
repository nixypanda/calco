import ComposableArchitecture
import XCTest

@testable import CalCo

/// The legacy global `foodCreationAssistantHandoff` dependency was removed:
/// `FoodCreationAssistantFeature` now emits typed parent delegates, and the
/// composing `FoodCreationFeature` is the sole owner. These tests assert the
/// exact delegate payloads (accepted-once, stale generation, matching expiry,
/// wrong purpose) through TestStore receives — no handoff client, no second
/// writer, no no-op dependency.
@MainActor
final class FoodCreationAssistantFeatureTests: XCTestCase {
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

    private func store(
        purpose: AssistantDraftPurpose = .customFood,
        accepted: Bool = false
    ) async throws -> TestStore<FoodCreationAssistantFeature.State, FoodCreationAssistantFeature.Action> {
        let reviewed = try reviewedDraft()
        return TestStore(
            initialState: FoodCreationAssistantFeature.State(
                assistant: AssistantFeature.State(
                    purpose: purpose,
                    sessionGeneration: generation,
                    draft: .ready(reviewed, accepted: accepted)
                )
            )
        ) {
            FoodCreationAssistantFeature()
        } withDependencies: {
            $0.assistantClient = assistantClient()
        }
    }

    /// Old `testActualChildAcceptForwardsReviewedDraftExactlyOnce`.
    func testActualChildAcceptForwardsReviewedDraftExactlyOnce() async throws {
        let reviewed = try reviewedDraft()
        let store = try await store(accepted: false)

        await store.send(FoodCreationAssistantFeature.Action.assistant(.acceptDraft)) {
            $0.assistant.draft = .ready(reviewed, accepted: true)
        }
        await store.receive(FoodCreationAssistantFeature.Action.assistant(
            .delegate(.acceptedReviewedDraft(
                purpose: .customFood,
                sessionGeneration: generation,
                draft: reviewed
            ))
        ))
        await store.receive(FoodCreationAssistantFeature.Action.delegate(
            .acceptedReviewedDraft(
                purpose: .customFood,
                sessionGeneration: generation,
                draft: reviewed
            )
        ))

        // A second accept is blocked by the child's accepted flag: no further
        // parent delegate (and therefore no second flow write).
        await store.send(FoodCreationAssistantFeature.Action.assistant(.acceptDraft))
        await store.finish()
    }

    /// Old `testStaleGenerationPayloadIsIgnored`.
    func testStaleGenerationPayloadIsIgnored() async throws {
        let reviewed = try reviewedDraft()
        let store = try await store(accepted: true)

        await store.send(FoodCreationAssistantFeature.Action.assistant(
            .delegate(.acceptedReviewedDraft(
                purpose: .customFood,
                sessionGeneration: generation - 1,
                draft: reviewed
            ))
        ))
        await store.finish()
    }

    /// Old `testMatchingGenerationExpiryCallsBack`.
    func testMatchingGenerationExpiryForwardsTypedDelegateOnce() async throws {
        let store = try await store(accepted: false)

        await store.send(FoodCreationAssistantFeature.Action.assistant(
            .delegate(.sessionExpired(generation: generation - 1))
        ))
        await store.send(FoodCreationAssistantFeature.Action.assistant(
            .delegate(.sessionExpired(generation: generation))
        ))
        await store.receive(FoodCreationAssistantFeature.Action.delegate(
            .sessionExpired(generation: generation)
        ))
        await store.finish()
    }

    /// Old `testWrongPurposePayloadIsIgnored`.
    func testWrongPurposePayloadIsIgnored() async throws {
        let reviewed = try reviewedDraft()
        let store = try await store(accepted: true)

        await store.send(FoodCreationAssistantFeature.Action.assistant(
            .delegate(.acceptedReviewedDraft(
                purpose: .adHocLog,
                sessionGeneration: generation,
                draft: reviewed
            ))
        ))
        await store.finish()
    }
}
