// Bridges server-gated AI draft calls to the assistant feature and translates
// the endpoint's structured failures without hiding rate limits or disablement.

import Foundation

public struct CalCoAssistantServiceAdapter: AssistantServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func assistantStatus() async throws -> AssistantStatus {
        do {
            return try await client.fetchAssistantStatus()
        } catch let error as CalCoAPIError {
            throw Self.map(error)
        } catch {
            throw AssistantServiceError.networkUnavailable
        }
    }

    public func requestDraft(
        purpose: AssistantDraftPurpose,
        conversation: AssistantConversation
    ) async throws -> AssistantDraftTurn {
        do {
            return try await client.requestAssistantDraft(
                purpose: purpose,
                conversation: conversation
            )
        } catch let error as CalCoAPIError {
            throw Self.map(error)
        } catch is AssistantDraftResponseError {
            throw AssistantServiceError.invalidResponse
        } catch {
            throw AssistantServiceError.networkUnavailable
        }
    }

    private static func map(_ error: CalCoAPIError) -> AssistantServiceError {
        switch error {
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
}
