// Server-gated AI drafting state. The assistant proposes an estimate; this
// feature only validates it and hands it to an editor. It never saves a food
// or writes a log.

import Combine
import Foundation

public protocol AssistantServicing: Sendable {
    func assistantStatus() async throws -> AssistantStatus
    func requestDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn
}

public enum AssistantStatusState: Equatable, Sendable {
    case idle
    case loading
    case enabled(AssistantStatus)
    case disabled
    case failed(AssistantServiceError)
}

public enum AssistantRequestState: Equatable, Sendable {
    case idle
    case sending
    case failed(AssistantServiceError)
}

public enum AssistantDraftState: Equatable, Sendable {
    case none
    case ready(AssistantReviewedDraft)
}

public struct AssistantTranscriptMessage: Identifiable, Equatable, Sendable {
    public let id: Int
    public let role: AssistantConversationRole
    public let text: String

    public init(id: Int, role: AssistantConversationRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

@MainActor
public final class AssistantViewModel: ObservableObject {
    @Published public private(set) var statusState: AssistantStatusState = .idle
    @Published public private(set) var requestState: AssistantRequestState = .idle
    @Published public private(set) var draftState: AssistantDraftState = .none
    @Published public private(set) var messages: [AssistantTranscriptMessage] = []
    @Published public private(set) var composerText: String = ""
    @Published public private(set) var composerError: String?
    @Published public private(set) var isStartOverConfirmationPresented = false
    @Published public private(set) var isDraftAccepted = false

    public let purpose: AssistantDraftPurpose
    public let initialBarcode: String?

    public var isSending: Bool {
        if case .sending = requestState { return true }
        return false
    }

    public var isEnabled: Bool {
        if case .enabled = statusState { return true }
        return false
    }

    public var isStatusLoading: Bool {
        if case .loading = statusState { return true }
        return false
    }

    public var draft: AssistantReviewedDraft? {
        if case .ready(let draft) = draftState { return draft }
        return nil
    }

    public var canSend: Bool {
        isEnabled
            && !isSending
            && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canStartOver: Bool {
        !messages.isEmpty || draft != nil || !composerText.isEmpty
    }

    public var canRetryRequest: Bool {
        guard case .failed(let error) = requestState else { return false }
        switch error {
        case .rateLimited, .providerUnavailable, .networkUnavailable, .timedOut, .server:
            return true
        case .disabled, .invalidInput, .sessionExpired, .invalidResponse, .cancelled:
            return false
        }
    }

    private let service: AssistantServicing
    private let onAcceptDraft: (AssistantReviewedDraft) -> Void
    private let onSessionExpired: () -> Void

    private var statusToken = 0
    private var requestToken = 0
    private var statusTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var nextMessageID = 0
    private var pendingUserMessageID: Int?
    private var pendingComposerText: String?

    public init(
        purpose: AssistantDraftPurpose,
        initialBarcode: String? = nil,
        service: AssistantServicing,
        onAcceptDraft: @escaping (AssistantReviewedDraft) -> Void = { _ in },
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.purpose = purpose
        self.initialBarcode = initialBarcode
        self.service = service
        self.onAcceptDraft = onAcceptDraft
        self.onSessionExpired = onSessionExpired
    }

    // MARK: - Status gate

    public func loadStatus() async {
        if case .loading = statusState { return }
        statusToken += 1
        let token = statusToken
        statusState = .loading

        do {
            let status = try await service.assistantStatus()
            guard token == statusToken else { return }
            statusState = status.enabled ? .enabled(status) : .disabled
        } catch {
            guard token == statusToken else { return }
            let mapped = Self.map(error)
            if mapped.isCancelled {
                statusState = .idle
                return
            }
            if case .sessionExpired = mapped {
                statusState = .failed(mapped)
                onSessionExpired()
                return
            }
            statusState = .failed(mapped)
        }
    }

    public func retryStatus() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            await self?.loadStatus()
        }
    }

    // MARK: - Composer

    public func composerChanged(_ value: String) {
        composerText = value
        composerError = nil
    }

    public func send() {
        guard isEnabled, !isSending else { return }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            composerError = AssistantConversationError.empty.message
            return
        }
        guard text.count <= AssistantConversationTurn.maximumMessageCharacters else {
            composerError = AssistantConversationError.messageTooLong.message
            return
        }

        let userTurn: AssistantConversationTurn
        do {
            userTurn = try AssistantConversationTurn(role: .user, text: text)
        } catch let error as AssistantConversationError {
            composerError = error.message
            return
        } catch {
            composerError = AssistantConversationError.emptyMessage.message
            return
        }

        var nextMessages = messages
        let message = AssistantTranscriptMessage(
            id: nextMessageID,
            role: userTurn.role,
            text: userTurn.text
        )
        nextMessageID += 1
        nextMessages.append(message)

        guard let conversation = try? AssistantConversation(
            turns: nextMessages.map {
                try AssistantConversationTurn(role: $0.role, text: $0.text)
            }
        ) else {
            composerError = AssistantConversationError.tooManyTurns.message
            return
        }

        messages = nextMessages
        composerText = ""
        composerError = nil
        draftState = .none
        isDraftAccepted = false
        startRequest(
            conversation: conversation,
            pendingUserMessageID: message.id,
            pendingText: text
        )
    }

    /// Awaited test/programmatic entry point with the same validation as the
    /// button path. The UI uses `send()`.
    public func performSend(_ text: String) async {
        composerChanged(text)
        send()
        if let requestTask {
            await requestTask.value
        }
    }

    public func retryRequest() {
        guard canRetryRequest, !isSending else { return }
        guard let conversation = currentConversation() else {
            requestState = .failed(.invalidInput(
                AssistantConversationError.tooManyTurns.message
            ))
            return
        }
        startRequest(conversation: conversation, pendingUserMessageID: nil, pendingText: nil)
    }

    public func cancelRequest() {
        guard isSending else { return }
        requestToken += 1
        requestTask?.cancel()
        requestTask = nil
        restorePendingUserTurn()
        requestState = .idle
    }

    /// Stops all in-flight provider work when the view is dismissed or the
    /// owning session resets. Conversation/draft state is retained so a reused
    /// view model does not lose reviewed content; a send that was in flight is
    /// returned to the composer.
    public func shutdown() {
        statusToken += 1
        requestToken += 1
        statusTask?.cancel()
        statusTask = nil
        requestTask?.cancel()
        requestTask = nil
        isStartOverConfirmationPresented = false
        if isSending {
            restorePendingUserTurn()
            requestState = .idle
        }
        if isStatusLoading {
            statusState = .idle
        }
    }

    /// Clears all transient conversation/status state when the owning account
    /// session changes. Also stops any provider work.
    public func resetForSessionChange() {
        shutdown()
        statusState = .idle
        requestState = .idle
        draftState = .none
        messages = []
        composerText = ""
        composerError = nil
        isStartOverConfirmationPresented = false
        isDraftAccepted = false
        pendingUserMessageID = nil
        pendingComposerText = nil
        nextMessageID = 0
    }

    deinit {
        statusTask?.cancel()
        requestTask?.cancel()
    }

    // MARK: - Draft actions

    public func beginChanges() {
        guard case .ready = draftState else { return }
        draftState = .none
        isDraftAccepted = false
        requestState = .idle
    }

    public func acceptDraft() {
        guard let draft, !isDraftAccepted else { return }
        isDraftAccepted = true
        onAcceptDraft(draft)
    }

    /// Review is a pushed page. Returning to the conversation lets the caller
    /// reopen that review without requesting another estimate.
    public func resumeDraftReview() {
        isDraftAccepted = false
    }

    // MARK: - Start over

    public func requestStartOver() {
        guard canStartOver else { return }
        isStartOverConfirmationPresented = true
    }

    public func cancelStartOver() {
        isStartOverConfirmationPresented = false
    }

    public func confirmStartOver() {
        guard isStartOverConfirmationPresented else { return }
        isStartOverConfirmationPresented = false
        requestToken += 1
        requestTask?.cancel()
        requestTask = nil
        pendingUserMessageID = nil
        pendingComposerText = nil
        messages = []
        composerText = ""
        composerError = nil
        draftState = .none
        requestState = .idle
        isDraftAccepted = false
        nextMessageID = 0
        // Availability is not conversation state and remains loaded.
    }

    // MARK: - Request

    private func startRequest(
        conversation: AssistantConversation,
        pendingUserMessageID: Int?,
        pendingText: String?
    ) {
        requestToken += 1
        let token = requestToken
        self.pendingUserMessageID = pendingUserMessageID
        pendingComposerText = pendingText
        requestState = .sending
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            await self?.performRequest(conversation: conversation, token: token)
        }
    }

    private func performRequest(
        conversation: AssistantConversation,
        token: Int
    ) async {
        do {
            let turn = try await service.requestDraft(
                purpose: purpose,
                conversation: conversation
            )
            guard token == requestToken else { return }
            pendingUserMessageID = nil
            pendingComposerText = nil
            requestState = .idle
            handle(turn)
        } catch {
            guard token == requestToken else { return }
            let mapped = Self.map(error)
            pendingUserMessageID = nil
            pendingComposerText = nil
            if mapped.isCancelled {
                requestState = .idle
                return
            }
            if case .sessionExpired = mapped {
                requestState = .failed(mapped)
                onSessionExpired()
                return
            }
            if case .disabled = mapped {
                statusState = .disabled
                requestState = .idle
                return
            }
            requestState = .failed(mapped)
        }
    }

    private func handle(_ turn: AssistantDraftTurn) {
        switch turn {
        case .needsClarification(let message):
            appendAssistant(message)
            draftState = .none
            isDraftAccepted = false
        case .draftReady(_, let payload, let suggestedLog, let warnings):
            do {
                let reviewed = try AssistantReviewedDraft(
                    purpose: purpose,
                    assistantMessage: turn.assistantMessage,
                    draft: payload,
                    suggestedLog: suggestedLog,
                    warnings: warnings,
                    barcode: purpose == .customFood ? initialBarcode : nil
                )
                appendAssistant(turn.assistantMessage)
                draftState = .ready(reviewed)
                isDraftAccepted = false
            } catch let error as AssistantDraftValidationError {
                requestState = .failed(.invalidInput(error.message))
            } catch {
                requestState = .failed(.invalidResponse)
            }
        }
    }

    private func appendAssistant(_ text: String) {
        guard let turn = try? AssistantConversationTurn(role: .assistant, text: text) else {
            return
        }
        messages.append(
            AssistantTranscriptMessage(
                id: nextMessageID,
                role: turn.role,
                text: turn.text
            )
        )
        nextMessageID += 1
    }

    private func currentConversation() -> AssistantConversation? {
        try? AssistantConversation(
            turns: messages.map {
                try AssistantConversationTurn(role: $0.role, text: $0.text)
            }
        )
    }

    private func restorePendingUserTurn() {
        guard let pendingUserMessageID else { return }
        if let index = messages.firstIndex(where: { $0.id == pendingUserMessageID }) {
            messages.remove(at: index)
        }
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let pendingComposerText {
            composerText = pendingComposerText
        }
        self.pendingUserMessageID = nil
        self.pendingComposerText = nil
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
}
