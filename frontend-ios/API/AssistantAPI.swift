// Server-gated AI food draft endpoint calls. Text drafts are sent as
// multipart/form-data because the endpoint's contract is shared with the web
// client's optional photo flow. This native client sends no photos.

import Foundation

public extension CalCoAPIClient {
    static let assistantStatusTimeout: TimeInterval = 15
    static let assistantDraftTimeout: TimeInterval = 120

    /// The entry gate for the assistant. `enabled` controls whether any draft
    /// request is allowed; `supportsImages` is intentionally decoded even
    /// though this client has no photo picker yet.
    func fetchAssistantStatus() async throws -> AssistantStatus {
        let request = try makeRequest(
            method: .get,
            path: ["api", "ai", "food-assistant", "status"],
            timeout: Self.assistantStatusTimeout
        )
        return try await send(request, as: AssistantStatus.self)
    }

    /// Sends a text-only conversation. The multipart field is named
    /// `conversation` and contains the purpose and bounded turns as JSON.
    /// Nothing is persisted server-side until a separate save/log action.
    func requestAssistantDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn {
        let body = try AssistantMultipartBody(conversation: conversation, purpose: purpose)
        var request = try makeRequest(
            method: .post,
            path: ["api", "ai", "custom-food", "draft"],
            timeout: Self.assistantDraftTimeout
        )
        request.httpBody = body.data
        request.setValue(
            "multipart/form-data; boundary=\(body.boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        let envelope = try await send(request, as: AssistantDraftResponseEnvelope.self)
        return try AssistantDraftTurn.decode(envelope: envelope, purpose: purpose)
    }
}

// MARK: - Multipart

struct AssistantMultipartBody {
    let boundary: String
    let data: Data
    let conversationJSON: Data

    init(
        conversation: AssistantConversation,
        purpose: AssistantDraftPurpose,
        boundary: String = "calco-boundary-\(UUID().uuidString)"
    ) throws {
        self.boundary = boundary
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json: Data
        do {
            json = try encoder.encode(
                ConversationBody(
                    purpose: purpose.rawValue,
                    turns: conversation.turns.map {
                        ConversationTurnBody(role: $0.role.rawValue, text: $0.text)
                    }
                )
            )
        } catch {
            throw CalCoAPIError.encoding(error.localizedDescription)
        }
        self.conversationJSON = json

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"conversation\"\r\n")
        body.appendUTF8("Content-Type: application/json\r\n")
        body.appendUTF8("\r\n")
        body.append(json)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        self.data = body
    }

    private struct ConversationBody: Encodable {
        let purpose: String
        let turns: [ConversationTurnBody]
    }

    private struct ConversationTurnBody: Encodable {
        let role: String
        let text: String
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
