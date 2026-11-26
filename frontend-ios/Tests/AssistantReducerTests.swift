import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class AssistantReducerTests: XCTestCase {
    private let requestID = UUID()
    private let generation = UInt64(42)

    private func corePayload() -> AssistantFoodDraftPayload {
        AssistantFoodDraftPayload(
            name: "Food",
            nutrients: [
                AssistantDraftNutrient(code: NutrientCodes.energyKcal, amountPer100g: "100"),
                AssistantDraftNutrient(code: NutrientCodes.proteinG, amountPer100g: "10"),
                AssistantDraftNutrient(code: NutrientCodes.carbsG, amountPer100g: "20"),
                AssistantDraftNutrient(code: NutrientCodes.fatG, amountPer100g: "5"),
            ],
            servings: [AssistantDraftServing(unit: "g", gramsPerUnit: "1")]
        )
    }

    private func makeClient(
        status: @escaping @Sendable () async throws -> AssistantStatus,
        request: @escaping @Sendable (AssistantDraftPurpose, AssistantConversation) async throws -> AssistantDraftTurn
    ) -> AssistantFeature.Client {
        AssistantFeature.Client(status: status, requestDraft: request)
    }

    func testStatusDisabled() async {
        let requestID = self.requestID
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { AssistantStatus(enabled: false, supportsImages: false) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.loadStatus) {
            $0.status = .loading(requestID: requestID)
        }
        await store.receive(.statusCompleted(requestID, .success(AssistantStatus(enabled: false, supportsImages: false)))) {
            $0.status = .disabled
        }
    }

    func testNeedsClarificationRequest() async {
        let requestID = self.requestID
        let status = AssistantStatus(enabled: true, supportsImages: false)
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { status },
                request: { _, conversation in
                    XCTAssertEqual(conversation.turns.count, 1)
                    return .needsClarification(assistantMessage: "More details?")
                }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.loadStatus) {
            $0.status = .loading(requestID: requestID)
        }
        await store.receive(.statusCompleted(requestID, .success(status))) {
            $0.status = .enabled(status)
        }

        await store.send(.composerChanged("make food")) {
            $0.composerText = "make food"
        }
        await store.send(.send) {
            $0.composerText = ""
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
            ]
            $0.request = .sending(
                requestID: requestID,
                conversation: try! AssistantConversation(turns: [
                    AssistantConversationTurn(role: .user, text: "make food")
                ]),
                pendingUserMessageID: 0,
                pendingComposerText: "make food"
            )
            $0.nextMessageID = 1
        }
        await store.receive(.requestCompleted(requestID, .success(.needsClarification(assistantMessage: "More details?")))) {
            $0.request = .idle
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food"),
                AssistantTranscriptMessage(id: 1, role: .assistant, text: "More details?")
            ]
            $0.nextMessageID = 2
            $0.draft = .none
        }
    }

    func testDraftReadyAndAccept() async {
        let requestID = self.requestID
        let status = AssistantStatus(enabled: true, supportsImages: false)
        let payload = corePayload()
        let turn = AssistantDraftTurn.draftReady(
            assistantMessage: "Draft ready",
            draft: payload,
            suggestedLog: nil,
            warnings: []
        )
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { status },
                request: { _, _ in turn }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.loadStatus) {
            $0.status = .loading(requestID: requestID)
        }
        await store.receive(.statusCompleted(requestID, .success(status))) {
            $0.status = .enabled(status)
        }

        await store.send(.composerChanged("make food")) {
            $0.composerText = "make food"
        }
        await store.send(.send) {
            $0.composerText = ""
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
            ]
            $0.request = .sending(
                requestID: requestID,
                conversation: try! AssistantConversation(turns: [
                    AssistantConversationTurn(role: .user, text: "make food")
                ]),
                pendingUserMessageID: 0,
                pendingComposerText: "make food"
            )
            $0.nextMessageID = 1
            $0.draft = .none
        }
        await store.receive(.requestCompleted(requestID, .success(turn))) {
            $0.request = .idle
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food"),
                AssistantTranscriptMessage(id: 1, role: .assistant, text: "Draft ready")
            ]
            $0.nextMessageID = 2
            $0.draft = .ready(
                try! AssistantReviewedDraft(
                    purpose: .customFood,
                    assistantMessage: "Draft ready",
                    draft: payload,
                    suggestedLog: nil,
                    warnings: []
                ),
                accepted: false
            )
        }

        let reviewed = try! AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "Draft ready",
            draft: payload,
            suggestedLog: nil,
            warnings: []
        )
        await store.send(.acceptDraft) {
            $0.draft = .ready(reviewed, accepted: true)
        }
        await store.receive(.delegate(.acceptedReviewedDraft(
            purpose: .customFood,
            sessionGeneration: generation,
            draft: reviewed
        )))
    }

    func testBeginChangesClearsReadyDraft() async {
        let requestID = self.requestID
        let payload = corePayload()
        let reviewed = try! AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "Draft ready",
            draft: payload,
            suggestedLog: nil,
            warnings: []
        )
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                draft: .ready(reviewed, accepted: false)
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { AssistantStatus(enabled: true, supportsImages: false) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.beginChanges) {
            $0.draft = .none
            $0.request = .idle
        }
    }

    func testStaleCompletionIsIgnored() async {
        let requestID = self.requestID
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                request: .sending(
                    requestID: requestID,
                    conversation: try! AssistantConversation(turns: [
                        AssistantConversationTurn(role: .user, text: "make food")
                    ]),
                    pendingUserMessageID: 0,
                    pendingComposerText: "make food"
                ),
                messages: [
                    AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
                ],
                composerText: ""
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { AssistantStatus(enabled: true, supportsImages: false) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        let staleID = UUID()
        await store.send(.requestCompleted(staleID, .success(.needsClarification(assistantMessage: "stale"))))
    }

    func testSessionExpiredStatusEmitsDelegate() async {
        let requestID = self.requestID
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { throw CalCoAPIError.unauthorized(nil) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.loadStatus) {
            $0.status = .loading(requestID: requestID)
        }
        await store.receive(.statusCompleted(requestID, .failure(.sessionExpired))) {
            $0.status = .failed(.sessionExpired)
        }
        await store.receive(.delegate(.sessionExpired(generation: generation)))
    }

    func testCancelRequestRestoresComposer() async {
        let requestID = self.requestID
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                request: .sending(
                    requestID: requestID,
                    conversation: try! AssistantConversation(turns: [
                        AssistantConversationTurn(role: .user, text: "make food")
                    ]),
                    pendingUserMessageID: 0,
                    pendingComposerText: "make food"
                )
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { AssistantStatus(enabled: true, supportsImages: false) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.cancelRequest) {
            $0.composerText = "make food"
            $0.messages = []
            $0.request = .idle
        }
    }

    func testStartOverConfirmationPreservesContextUntilConfirm() async {
        let requestID = self.requestID
        let payload = corePayload()
        let reviewed = try! AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "Draft ready",
            draft: payload,
            suggestedLog: nil,
            warnings: []
        )
        let message = AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                draft: .ready(reviewed, accepted: false),
                messages: [message]
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { AssistantStatus(enabled: true, supportsImages: false) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.requestStartOver) {
            $0.startOverConfirmation = .pending(messages: [message], draft: reviewed)
        }
        await store.send(.confirmStartOver) {
            $0.startOverConfirmation = nil
            $0.messages = []
            $0.composerText = ""
            $0.composerError = nil
            $0.draft = .none
            $0.nextMessageID = 0
        }
    }

    func testStartOverConfirmDoesNotWipeChangedContext() async {
        let payload = corePayload()
        let reviewed = try! AssistantReviewedDraft(
            purpose: .customFood,
            assistantMessage: "Draft ready",
            draft: payload,
            suggestedLog: nil,
            warnings: []
        )
        let message = AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                draft: .ready(reviewed, accepted: false),
                messages: [message]
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = makeClient(
                status: { AssistantStatus(enabled: true, supportsImages: false) },
                request: { _, _ in .needsClarification(assistantMessage: "unused") }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.requestStartOver) {
            $0.startOverConfirmation = .pending(messages: [message], draft: reviewed)
        }
        await store.send(.beginChanges) {
            $0.startOverConfirmation = .pending(messages: [message], draft: reviewed)
            $0.draft = .none
            $0.request = .idle
        }
        await store.send(.confirmStartOver) {
            $0.startOverConfirmation = nil
            $0.messages = [message]
            $0.composerText = ""
            $0.composerError = nil
            $0.draft = .none
            $0.nextMessageID = 0
        }
    }

    func testShutdownCancelsInFlightStatusAndRequest() async {
        let requestID = self.requestID
        let statusStarted = expectation(description: "status started")
        let statusCancelled = expectation(description: "status cancelled")
        let requestStarted = expectation(description: "request started")
        let requestCancelled = expectation(description: "request cancelled")

        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            private var cancelled = false

            func wait(started: XCTestExpectation) async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    if cancelled {
                        lock.unlock()
                        continuation.resume()
                        lock.lock()
                        self.continuation = nil
                    }
                    lock.unlock()
                    started.fulfill()
                }
            }

            func cancel() {
                lock.lock()
                cancelled = true
                let continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume()
            }

            var wasCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }
        }

        let statusGate = Gate()
        let requestGate = Gate()

        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                status: .enabled(AssistantStatus(enabled: true, supportsImages: false)),
                request: .idle,
                messages: [
                    AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
                ],
                composerText: "make food",
                nextMessageID: 1
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = AssistantFeature.Client(
                status: {
                    do {
                        return try await withTaskCancellationHandler {
                            await statusGate.wait(started: statusStarted)
                            if await statusGate.wasCancelled {
                                statusCancelled.fulfill()
                                throw CancellationError()
                            }
                            return AssistantStatus(enabled: true, supportsImages: false)
                        } onCancel: {
                            Task { await statusGate.cancel() }
                        }
                    }
                },
                requestDraft: { _, _ in
                    do {
                        return try await withTaskCancellationHandler {
                            await requestGate.wait(started: requestStarted)
                            if await requestGate.wasCancelled {
                                requestCancelled.fulfill()
                                throw CancellationError()
                            }
                            return .needsClarification(assistantMessage: "unused")
                        } onCancel: {
                            Task { await requestGate.cancel() }
                        }
                    }
                }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.send) {
            $0.composerText = ""
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food"),
                AssistantTranscriptMessage(id: 1, role: .user, text: "make food")
            ]
            $0.request = .sending(
                requestID: requestID,
                conversation: try! AssistantConversation(turns: [
                    AssistantConversationTurn(role: .user, text: "make food"),
                    AssistantConversationTurn(role: .user, text: "make food")
                ]),
                pendingUserMessageID: 1,
                pendingComposerText: "make food"
            )
            $0.nextMessageID = 2
        }
        await fulfillment(of: [requestStarted], timeout: 1)

        await store.send(.loadStatus) {
            $0.status = .loading(requestID: requestID)
        }
        await fulfillment(of: [statusStarted], timeout: 1)

        await store.send(.shutdown) {
            $0.startOverConfirmation = nil
            $0.status = .idle
            $0.request = .idle
            $0.composerText = "make food"
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
            ]
        }

        await fulfillment(of: [statusCancelled, requestCancelled], timeout: 1)
    }

    func testResetForSessionChangeCancelsInFlightWork() async {
        let requestID = self.requestID
        let statusStarted = expectation(description: "status started")
        let statusCancelled = expectation(description: "status cancelled")
        let requestStarted = expectation(description: "request started")
        let requestCancelled = expectation(description: "request cancelled")

        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            private var cancelled = false

            func wait(started: XCTestExpectation) async {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    if cancelled {
                        lock.unlock()
                        continuation.resume()
                        lock.lock()
                        self.continuation = nil
                    }
                    lock.unlock()
                    started.fulfill()
                }
            }

            func cancel() {
                lock.lock()
                cancelled = true
                let continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume()
            }

            var wasCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }
        }

        let statusGate = Gate()
        let requestGate = Gate()

        let store = TestStore(
            initialState: AssistantFeature.State(
                purpose: .customFood,
                sessionGeneration: generation,
                status: .enabled(AssistantStatus(enabled: true, supportsImages: false)),
                request: .idle,
                messages: [],
                composerText: "make food"
            )
        ) {
            AssistantFeature()
        } withDependencies: {
            $0.assistantClient = AssistantFeature.Client(
                status: {
                    do {
                        return try await withTaskCancellationHandler {
                            await statusGate.wait(started: statusStarted)
                            if await statusGate.wasCancelled {
                                statusCancelled.fulfill()
                                throw CancellationError()
                            }
                            return AssistantStatus(enabled: true, supportsImages: false)
                        } onCancel: {
                            Task { await statusGate.cancel() }
                        }
                    }
                },
                requestDraft: { _, _ in
                    do {
                        return try await withTaskCancellationHandler {
                            await requestGate.wait(started: requestStarted)
                            if await requestGate.wasCancelled {
                                requestCancelled.fulfill()
                                throw CancellationError()
                            }
                            return .needsClarification(assistantMessage: "unused")
                        } onCancel: {
                            Task { await requestGate.cancel() }
                        }
                    }
                }
            )
            $0.uuid = .constant(requestID)
        }

        await store.send(.send) {
            $0.composerText = ""
            $0.messages = [
                AssistantTranscriptMessage(id: 0, role: .user, text: "make food")
            ]
            $0.request = .sending(
                requestID: requestID,
                conversation: try! AssistantConversation(turns: [
                    AssistantConversationTurn(role: .user, text: "make food")
                ]),
                pendingUserMessageID: 0,
                pendingComposerText: "make food"
            )
            $0.nextMessageID = 1
        }
        await fulfillment(of: [requestStarted], timeout: 1)

        await store.send(.loadStatus) {
            $0.status = .loading(requestID: requestID)
        }
        await fulfillment(of: [statusStarted], timeout: 1)

        await store.send(.resetForSessionChange) {
            $0.startOverConfirmation = nil
            $0.status = .idle
            $0.request = .idle
            $0.draft = .none
            $0.messages = []
            $0.composerText = ""
            $0.composerError = nil
            $0.nextMessageID = 0
        }

        await fulfillment(of: [statusCancelled, requestCancelled], timeout: 1)
    }

}
