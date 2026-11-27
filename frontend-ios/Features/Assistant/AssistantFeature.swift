import ComposableArchitecture
import Foundation

@Reducer
public struct AssistantFeature {
    public enum Status: Equatable, Sendable {
        case idle
        case loading(requestID: UUID)
        case enabled(AssistantStatus)
        case disabled
        case failed(AssistantServiceError)
    }

    public enum Request: Equatable, Sendable {
        case idle
        case sending(
            requestID: UUID,
            conversation: AssistantConversation,
            pendingUserMessageID: Int?,
            pendingComposerText: String?
        )
        case failed(AssistantServiceError)
    }

    public enum Draft: Equatable, Sendable {
        case none
        case ready(AssistantReviewedDraft, accepted: Bool)
    }

    public enum StartOverConfirmation: Equatable, Sendable {
        case pending(
            messages: [AssistantTranscriptMessage],
            draft: AssistantReviewedDraft?
        )
    }

    @ObservableState
    public struct State: Equatable {
        public let purpose: AssistantDraftPurpose
        public let initialBarcode: String?
        public let sessionGeneration: UInt64

        public var status: Status
        public var request: Request
        public var draft: Draft
        public var messages: [AssistantTranscriptMessage]
        public var composerText: String
        public var composerError: String?
        public var startOverConfirmation: StartOverConfirmation?
        public var nextMessageID: Int

        public init(
            purpose: AssistantDraftPurpose,
            initialBarcode: String? = nil,
            sessionGeneration: UInt64,
            status: Status = .idle,
            request: Request = .idle,
            draft: Draft = .none,
            messages: [AssistantTranscriptMessage] = [],
            composerText: String = "",
            composerError: String? = nil,
            startOverConfirmation: StartOverConfirmation? = nil,
            nextMessageID: Int = 0
        ) {
            self.purpose = purpose
            self.initialBarcode = initialBarcode
            self.sessionGeneration = sessionGeneration
            self.status = status
            self.request = request
            self.draft = draft
            self.messages = messages
            self.composerText = composerText
            self.composerError = composerError
            self.startOverConfirmation = startOverConfirmation
            self.nextMessageID = nextMessageID
        }

        public var isSending: Bool {
            if case .sending = request { true } else { false }
        }

        public var isEnabled: Bool {
            if case .enabled = status { true } else { false }
        }

        public var reviewedDraft: AssistantReviewedDraft? {
            if case .ready(let draft, _) = draft { draft } else { nil }
        }

        public var isDraftAccepted: Bool {
            if case .ready(_, let accepted) = draft { accepted } else { false }
        }

        public var isStartOverConfirmationPresented: Bool {
            startOverConfirmation != nil
        }

        public var canSend: Bool {
            isEnabled
                && !isSending
                && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        public var canStartOver: Bool {
            !messages.isEmpty || reviewedDraft != nil || !composerText.isEmpty
        }

        public var canRetryRequest: Bool {
            guard case .failed(let error) = request else { return false }
            switch error {
            case .rateLimited, .providerUnavailable, .networkUnavailable, .timedOut, .server:
                return true
            case .disabled, .invalidInput, .sessionExpired, .invalidResponse, .cancelled:
                return false
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case loadStatus
        case retryStatus
        case composerChanged(String)
        case send
        case cancelRequest
        case retryRequest
        case requestCompleted(UUID, Result<AssistantDraftTurn, AssistantServiceError>)
        case statusCompleted(UUID, Result<AssistantStatus, AssistantServiceError>)
        case beginChanges
        case acceptDraft
        case resumeDraftReview
        case requestStartOver
        case cancelStartOver
        case confirmStartOver
        case shutdown
        case resetForSessionChange
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case acceptedReviewedDraft(
            purpose: AssistantDraftPurpose,
            sessionGeneration: UInt64,
            draft: AssistantReviewedDraft
        )
        case sessionExpired(generation: UInt64)
    }

    public struct Client: Sendable {
        public var status: @Sendable () async throws -> AssistantStatus
        public var requestDraft: @Sendable (
            _ purpose: AssistantDraftPurpose,
            _ conversation: AssistantConversation
        ) async throws -> AssistantDraftTurn

        public init(
            status: @escaping @Sendable () async throws -> AssistantStatus,
            requestDraft: @escaping @Sendable (
                _ purpose: AssistantDraftPurpose,
                _ conversation: AssistantConversation
            ) async throws -> AssistantDraftTurn
        ) {
            self.status = status
            self.requestDraft = requestDraft
        }

        public static func live(service: any AssistantServicing) -> Self {
            Self(
                status: { try await service.assistantStatus() },
                requestDraft: { purpose, conversation in
                    try await service.requestDraft(purpose: purpose, conversation: conversation)
                }
            )
        }
    }

    @Dependency(\.assistantClient) private var assistantClient
    @Dependency(\.uuid) private var uuid

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            self.reduce(into: &state, action: action)
        }
    }

    public func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
            case .loadStatus:
                if case .loading = state.status { return .none }
                let requestID = uuid()
                state.status = .loading(requestID: requestID)
                return .run { send in
                    do {
                        let status = try await assistantClient.status()
                        await send(.statusCompleted(requestID, .success(status)))
                    } catch {
                        await send(.statusCompleted(
                            requestID,
                            .failure(Self.map(error))
                        ))
                    }
                }
                .cancellable(id: CancelID.status, cancelInFlight: true)

            case .retryStatus:
                if case .loading = state.status {
                    state.status = .idle
                }
                return .send(.loadStatus)

            case let .composerChanged(value):
                state.composerText = value
                state.composerError = nil
                return .none

            case .send:
                guard state.canSend else { return .none }

                let text = state.composerText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    state.composerError = AssistantConversationError.empty.message
                    return .none
                }
                guard text.count <= AssistantConversationTurn.maximumMessageCharacters else {
                    state.composerError = AssistantConversationError.messageTooLong.message
                    return .none
                }

                let userTurn: AssistantConversationTurn
                do {
                    userTurn = try AssistantConversationTurn(role: .user, text: text)
                } catch let error as AssistantConversationError {
                    state.composerError = error.message
                    return .none
                } catch {
                    state.composerError = AssistantConversationError.emptyMessage.message
                    return .none
                }

                var nextMessages = state.messages
                let message = AssistantTranscriptMessage(
                    id: state.nextMessageID,
                    role: userTurn.role,
                    text: userTurn.text
                )
                nextMessages.append(message)

                let conversation: AssistantConversation
                do {
                    conversation = try AssistantConversation(
                        turns: nextMessages.map {
                            try AssistantConversationTurn(role: $0.role, text: $0.text)
                        }
                    )
                } catch {
                    state.composerError = AssistantConversationError.tooManyTurns.message
                    return .none
                }

                state.messages = nextMessages
                state.composerText = ""
                state.composerError = nil
                state.draft = .none
                state.nextMessageID += 1

                let requestID = uuid()
                let purpose = state.purpose
                state.request = .sending(
                    requestID: requestID,
                    conversation: conversation,
                    pendingUserMessageID: message.id,
                    pendingComposerText: text
                )

                return .run { send in
                    do {
                        let turn = try await assistantClient.requestDraft(
                            purpose,
                            conversation
                        )
                        await send(.requestCompleted(requestID, .success(turn)))
                    } catch {
                        await send(.requestCompleted(
                            requestID,
                            .failure(Self.map(error))
                        ))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .cancelRequest:
                guard case let .sending(
                    _,
                    _,
                    pendingUserMessageID,
                    pendingComposerText
                ) = state.request else {
                    return .none
                }
                Self.restorePendingUserTurn(
                    state: &state,
                    pendingUserMessageID: pendingUserMessageID,
                    pendingComposerText: pendingComposerText
                )
                state.request = .idle
                return .cancel(id: CancelID.request)

            case .retryRequest:
                guard state.canRetryRequest, !state.isSending else { return .none }
                guard let conversation = Self.currentConversation(state.messages) else {
                    state.request = .failed(.invalidInput(
                        AssistantConversationError.tooManyTurns.message
                    ))
                    return .none
                }
                let requestID = uuid()
                let purpose = state.purpose
                state.request = .sending(
                    requestID: requestID,
                    conversation: conversation,
                    pendingUserMessageID: nil,
                    pendingComposerText: nil
                )
                return .run { send in
                    do {
                        let turn = try await assistantClient.requestDraft(
                            purpose,
                            conversation
                        )
                        await send(.requestCompleted(requestID, .success(turn)))
                    } catch {
                        await send(.requestCompleted(
                            requestID,
                            .failure(Self.map(error))
                        ))
                    }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case let .requestCompleted(requestID, result):
                guard case let .sending(
                    currentRequestID,
                    conversation,
                    pendingUserMessageID,
                    pendingComposerText
                ) = state.request,
                currentRequestID == requestID else {
                    return .none
                }

                state.request = .idle

                switch result {
                case let .success(turn):
                    Self.handleTurn(turn, state: &state)

                case let .failure(error):
                    if case .sessionExpired = error {
                        state.request = .failed(error)
                        return .send(.delegate(.sessionExpired(
                            generation: state.sessionGeneration
                        )))
                    }
                    if case .disabled = error {
                        state.status = .disabled
                        return .none
                    }
                    state.request = .failed(error)
                }

                _ = pendingUserMessageID
                _ = pendingComposerText
                _ = conversation
                return .none

            case let .statusCompleted(requestID, result):
                guard case .loading(let currentRequestID) = state.status,
                      currentRequestID == requestID else {
                    return .none
                }

                switch result {
                case let .success(status):
                    state.status = status.enabled ? .enabled(status) : .disabled

                case let .failure(error):
                    if error.isCancelled {
                        state.status = .idle
                        return .none
                    }
                    if case .sessionExpired = error {
                        state.status = .failed(error)
                        var cancelRequest = false
                        if case .sending = state.request {
                            state.request = .failed(.sessionExpired)
                            cancelRequest = true
                        }
                        if cancelRequest {
                            return .merge(
                                .send(.delegate(.sessionExpired(
                                    generation: state.sessionGeneration
                                ))),
                                .cancel(id: CancelID.request)
                            )
                        }
                        return .send(.delegate(.sessionExpired(
                            generation: state.sessionGeneration
                        )))
                    }
                    if case .disabled = error {
                        state.status = .disabled
                        return .none
                    }
                    state.status = .failed(error)
                }

                return .none

            case .beginChanges:
                guard case .ready = state.draft else { return .none }
                state.draft = .none
                var cancelRequest = false
                if case .sending = state.request {
                    state.request = .idle
                    cancelRequest = true
                } else {
                    state.request = .idle
                }
                return cancelRequest ? .cancel(id: CancelID.request) : .none

            case .acceptDraft:
                guard case .ready(let draft, false) = state.draft else { return .none }
                state.draft = .ready(draft, accepted: true)
                return .send(.delegate(.acceptedReviewedDraft(
                    purpose: state.purpose,
                    sessionGeneration: state.sessionGeneration,
                    draft: draft
                )))

            case .resumeDraftReview:
                if case .ready(let draft, true) = state.draft {
                    state.draft = .ready(draft, accepted: false)
                }
                return .none

            case .requestStartOver:
                guard state.canStartOver else { return .none }
                state.startOverConfirmation = .pending(
                    messages: state.messages,
                    draft: state.reviewedDraft
                )
                return .none

            case .cancelStartOver:
                state.startOverConfirmation = nil
                return .none

            case .confirmStartOver:
                guard case let .pending(messages, draft) = state.startOverConfirmation else {
                    return .none
                }
                guard messages == state.messages, draft == state.reviewedDraft else {
                    state.startOverConfirmation = nil
                    return .none
                }
                state.startOverConfirmation = nil

                var cancelRequest = false
                if case let .sending(
                    _,
                    _,
                    pendingUserMessageID,
                    pendingComposerText
                ) = state.request {
                    Self.restorePendingUserTurn(
                        state: &state,
                        pendingUserMessageID: pendingUserMessageID,
                        pendingComposerText: pendingComposerText
                    )
                    state.request = .idle
                    cancelRequest = true
                }

                state.messages = []
                state.composerText = ""
                state.composerError = nil
                state.draft = .none
                state.nextMessageID = 0

                return cancelRequest ? .cancel(id: CancelID.request) : .none

            case .shutdown:
                state.startOverConfirmation = nil

                var cancelRequest = false
                if case let .sending(
                    _,
                    _,
                    pendingUserMessageID,
                    pendingComposerText
                ) = state.request {
                    Self.restorePendingUserTurn(
                        state: &state,
                        pendingUserMessageID: pendingUserMessageID,
                        pendingComposerText: pendingComposerText
                    )
                    state.request = .idle
                    cancelRequest = true
                }

                var cancelStatus = false
                if case .loading = state.status {
                    state.status = .idle
                    cancelStatus = true
                }

                var effects: [Effect<Action>] = []
                if cancelRequest { effects.append(.cancel(id: CancelID.request)) }
                if cancelStatus { effects.append(.cancel(id: CancelID.status)) }
                if effects.isEmpty { return .none }
                if effects.count == 1 { return effects[0] }
                return .merge(effects[0], effects[1])

            case .resetForSessionChange:
                state.startOverConfirmation = nil

                if case let .sending(
                    _,
                    _,
                    pendingUserMessageID,
                    pendingComposerText
                ) = state.request {
                    Self.restorePendingUserTurn(
                        state: &state,
                        pendingUserMessageID: pendingUserMessageID,
                        pendingComposerText: pendingComposerText
                    )
                }

                let cancelRequest = true
                let cancelStatus: Bool
                if case .loading = state.status {
                    cancelStatus = true
                } else {
                    cancelStatus = false
                }

                state.status = .idle
                state.request = .idle
                state.draft = .none
                state.messages = []
                state.composerText = ""
                state.composerError = nil
                state.nextMessageID = 0

                if cancelStatus {
                    return .merge(
                        .cancel(id: CancelID.request),
                        .cancel(id: CancelID.status)
                    )
                }
                return .cancel(id: CancelID.request)

            case .delegate:
                return .none
            }
    }

    private static func handleTurn(
        _ turn: AssistantDraftTurn,
        state: inout State
    ) {
        switch turn {
        case .needsClarification(let message):
            appendAssistant(message, state: &state)
            state.draft = .none

        case .draftReady(let assistantMessage, let payload, let suggestedLog, let warnings):
            do {
                let reviewed = try AssistantReviewedDraft(
                    purpose: state.purpose,
                    assistantMessage: assistantMessage,
                    draft: payload,
                    suggestedLog: suggestedLog,
                    warnings: warnings,
                    barcode: state.purpose == .customFood ? state.initialBarcode : nil
                )
                appendAssistant(assistantMessage, state: &state)
                state.draft = .ready(reviewed, accepted: false)
            } catch let error as AssistantDraftValidationError {
                state.request = .failed(.invalidInput(error.message))
            } catch {
                state.request = .failed(.invalidResponse)
            }
        }
    }

    private static func appendAssistant(
        _ text: String,
        state: inout State
    ) {
        guard let turn = try? AssistantConversationTurn(
            role: .assistant,
            text: text
        ) else {
            return
        }
        state.messages.append(
            AssistantTranscriptMessage(
                id: state.nextMessageID,
                role: turn.role,
                text: turn.text
            )
        )
        state.nextMessageID += 1
    }

    private static func currentConversation(
        _ messages: [AssistantTranscriptMessage]
    ) -> AssistantConversation? {
        try? AssistantConversation(
            turns: messages.map {
                try AssistantConversationTurn(role: $0.role, text: $0.text)
            }
        )
    }

    private static func restorePendingUserTurn(
        state: inout State,
        pendingUserMessageID: Int?,
        pendingComposerText: String?
    ) {
        guard let pendingUserMessageID else { return }
        if let index = state.messages.firstIndex(where: { $0.id == pendingUserMessageID }) {
            state.messages.remove(at: index)
        }
        if state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let pendingComposerText {
            state.composerText = pendingComposerText
        }
    }

    private static func map(_ error: Error) -> AssistantServiceError {
        if let serviceError = error as? AssistantServiceError {
            return serviceError
        }
        if let apiError = error as? CalCoAPIError {
            switch apiError {
            case .cancelled:
                return .cancelled
            case .unauthorized:
                return .sessionExpired
            case .timeout:
                return .timedOut
            case .network:
                return .networkUnavailable
            case .rateLimited(let seconds):
                return .rateLimited(retryAfterSeconds: seconds)
            case .badStatus(let statusCode, let payload):
                switch statusCode {
                case 400, 413:
                    return .invalidInput(payload.message)
                case 502:
                    return .providerUnavailable
                case 503 where payload.code == "assistant_disabled":
                    return .disabled
                default:
                    return .server(payload.message)
                }
            case .invalidURL, .invalidResponse, .decoding, .encoding:
                return .invalidResponse
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return .server(error.localizedDescription)
    }

    private enum CancelID: Hashable {
        case status
        case request
    }
}

extension DependencyValues {
    public var assistantClient: AssistantFeature.Client {
        get { self[AssistantClientKey.self] }
        set { self[AssistantClientKey.self] = newValue }
    }
}

private enum AssistantClientKey: DependencyKey {
    static let liveValue: AssistantFeature.Client = .init(
        status: { throw AssistantServiceError.disabled },
        requestDraft: { _, _ in throw AssistantServiceError.disabled }
    )
    static let testValue: AssistantFeature.Client = .init(
        status: { throw AssistantServiceError.disabled },
        requestDraft: { _, _ in throw AssistantServiceError.disabled }
    )
}
