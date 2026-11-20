// Direct typed transport for quick-add, batch review, meal logging, repeat
// latest, and ad-hoc logging. It is intentionally not a journal: a failed
// request is reported to the user, and only an explicit user action sends it
// again. The preexisting single-food FoodDetail journal remains separate.

import Foundation

public typealias LogSubmissionHandler = (
    _ drafts: [LogSubmissionDraft],
    _ itemNames: [String],
    _ summary: String,
    _ completion: @escaping (LogSubmissionServiceResult) -> Void
) -> Void

public enum LogSubmissionServiceFailure: Error, Equatable, Sendable {
    case unauthorized
    case failed(String)
    /// Transport ambiguity: the request may or may not have been applied.
    case uncertain(String)

    public var message: String {
        switch self {
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .failed(let message), .uncertain(let message):
            return message
        }
    }
}

public enum LogSubmissionServiceResult: Equatable, Sendable {
    case success([FoodLog])
    case failure(LogSubmissionServiceFailure)

    public var createdLogs: [FoodLog] {
        guard case .success(let logs) = self else { return [] }
        return logs
    }
}

/// Ordinary session context used to cancel a normal submission when the
/// signed-in account/generation changes mid-flight. It carries no profile
/// binding and is never sent as a header.
public struct LogSubmissionSessionContext: Equatable, Sendable {
    public let accountID: String
    public let generation: UInt64
    public let baseURL: URL

    public init(accountID: String, generation: UInt64, baseURL: URL) {
        self.accountID = accountID
        self.generation = generation
        self.baseURL = baseURL
    }
}

public typealias LogSubmissionSessionContextProvider =
    @MainActor () -> LogSubmissionSessionContext?

public enum LogSubmissionSendError: Error, Equatable, Sendable {
    case unauthorized
    case failed(String)
    case uncertain(String)
}

public protocol LogSubmissionSending: Sendable {
    func send(_ request: LogSubmissionRequest) async throws -> [FoodLog]
}

public struct CalCoLogSubmissionSender: LogSubmissionSending {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] {
        do {
            let response = try await client.createSubmissionRaw(request)
            return response.logs
        } catch let error as CalCoAPIError {
            throw Self.map(error)
        } catch {
            throw LogSubmissionSendError.uncertain(error.localizedDescription)
        }
    }

    public static func map(_ error: CalCoAPIError) -> LogSubmissionSendError {
        switch error {
        case .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .failed(Self.message(for: error))
        case .timeout, .network, .invalidResponse, .decoding, .cancelled:
            return .uncertain(Self.message(for: error))
        case .badStatus(let status, _)
            where status == 408 || status == 429 || (300..<400).contains(status)
                || (500..<600).contains(status):
            return .uncertain(Self.message(for: error))
        case .badStatus(let status, _) where (400..<500).contains(status):
            return .failed(Self.message(for: error))
        case .badStatus(_, _), .invalidURL, .encoding:
            return .failed(Self.message(for: error))
        }
    }

    private static func message(for error: CalCoAPIError) -> String {
        let generic = String(localized: "foodDetail.error.saveFailed")
        let message = error.payload?.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }
        switch error {
        case .timeout:
            return String(localized: "foodDetail.error.uncertain")
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .rateLimited:
            return String(localized: "foodDetail.error.rateLimited")
        default:
            return generic
        }
    }
}

@MainActor
public final class LogSubmissionService {
    private let sender: any LogSubmissionSending
    private let sessionContextProvider: LogSubmissionSessionContextProvider?

    public init(
        sender: any LogSubmissionSending,
        sessionContextProvider: LogSubmissionSessionContextProvider? = nil
    ) {
        self.sender = sender
        self.sessionContextProvider = sessionContextProvider
    }

    /// Sends one user-initiated submission. `baseURL` is retained for source
    /// compatibility with older call sites; the client owns the configured
    /// origin and no request is bound to a saved server.
    public func submit(
        accountID: String,
        summary: String,
        drafts: [LogSubmissionDraft],
        itemNames: [String] = [],
        baseURL _: URL? = nil,
        generation: UInt64? = nil
    ) async -> LogSubmissionServiceResult {
        guard Self.contextIsCurrent(
            accountID: accountID,
            generation: generation,
            provider: sessionContextProvider
        ) else {
            return .failure(.unauthorized)
        }

        let request: LogSubmissionRequest
        do {
            request = try LogSubmissionRequestBuilder.prepare(drafts: drafts).request
        } catch let error as LogCreateRequestBuilderError {
            return .failure(.failed(Self.builderMessage(error)))
        } catch {
            return .failure(.failed(String(localized: "foodDetail.error.saveFailed")))
        }

        do {
            let logs = try await sender.send(request)
            guard Self.contextIsCurrent(
                accountID: accountID,
                generation: generation,
                provider: sessionContextProvider
            ) else {
                // The write may already have landed; do not retry it here.
                return .failure(.uncertain(
                    String(localized: "foodDetail.error.sessionExpired")
                ))
            }
            return .success(logs)
        } catch let error as LogSubmissionSendError {
            switch error {
            case .unauthorized:
                return .failure(.unauthorized)
            case .failed(let message):
                return .failure(.failed(message))
            case .uncertain(let message):
                return .failure(.uncertain(message))
            }
        } catch {
            return .failure(.uncertain(error.localizedDescription))
        }
    }

    private static func contextIsCurrent(
        accountID: String,
        generation: UInt64?,
        provider: LogSubmissionSessionContextProvider?
    ) -> Bool {
        guard let provider else { return true }
        guard let current = provider(),
              current.accountID == accountID else {
            return false
        }
        if let generation, current.generation != generation {
            return false
        }
        return true
    }

    private static func builderMessage(_ error: LogCreateRequestBuilderError) -> String {
        switch error {
        case .bodyTooLarge:
            return String(localized: "foodDetail.error.notesTooLong")
        case .invalidKey, .invalidItem, .encoding:
            return String(localized: "foodDetail.error.saveFailed")
        }
    }
}

public enum LogSubmissionSummary {
    public static func text(for drafts: [LogSubmissionDraft], names: [String]) -> String {
        guard let first = names.first, !first.isEmpty else {
            return String(localized: "search.quickAdd")
        }
        guard names.count > 1 else { return first }
        return String(
            format: String(localized: "search.batch.summary"),
            first,
            names.count - 1
        )
    }
}
