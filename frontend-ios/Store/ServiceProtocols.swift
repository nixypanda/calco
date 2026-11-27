import Foundation

// Pure service contracts retained from the retired legacy view-model files.
// Byte-identical declarations; no view model, store, or authority is restored.

public protocol AssistantServicing: Sendable {
    func assistantStatus() async throws -> AssistantStatus
    func requestDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn
}

public protocol BarcodeServicing: Sendable {
    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup
}

// Pure value declarations retained from retired legacy files (byte-identical).

public typealias SearchSubmissionHandler = LogSubmissionHandler

public enum LoginValidation: Equatable, Sendable {
    case usernameRequired
    case passwordRequired
}

public enum LoginFailure: Equatable, Sendable {
    case validation(LoginValidation)
    case authentication(AuthFeatureError)
}

public enum LoginPhase: Equatable, Sendable {
    case editing
    case submitting
    case failed(LoginFailure)
    case adminRejected(AuthUser)
}

public enum APIKeyListState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

public enum APIKeyCreateState: Equatable, Sendable {
    case editing
    case submitting
    case failed(String)
    case uncertain(String)
    case created
}

public enum APIKeyCopyState: Equatable, Sendable {
    case idle
    case copied
    case failed
}

public enum APIKeyRevokeState: Equatable, Sendable {
    case idle
    case revoking
    case failed(String)
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
