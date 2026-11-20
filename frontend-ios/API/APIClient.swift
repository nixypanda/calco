// Configuration, error vocabulary, and cookie-backed request plumbing for the CalCo API.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CalCoAPIConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval

    public init(
        baseURL: URL,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }
}

public struct APIErrorPayload: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum CalCoAPIError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case timeout
    case cancelled
    case network(String)
    case unauthorized(APIErrorPayload?)
    case rateLimited(retryAfterSeconds: Int?)
    case badStatus(statusCode: Int, payload: APIErrorPayload)
    case decoding(String)
    case encoding(String)

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var isInvalidCredentials: Bool {
        isUnauthorized && payload?.code == "invalid_credentials"
    }

    public var isSessionAccountChanged: Bool {
        isUnauthorized && payload?.code == "session_account_changed"
    }

    public var payload: APIErrorPayload? {
        switch self {
        case .unauthorized(let payload):
            return payload
        case .badStatus(_, let payload):
            return payload
        default:
            return nil
        }
    }

    public var statusCode: Int? {
        switch self {
        case .unauthorized:
            return 401
        case .rateLimited:
            return 429
        case .badStatus(let statusCode, _):
            return statusCode
        default:
            return nil
        }
    }
}

public struct CalCoAPIClient: @unchecked Sendable {
    public static let accountIDHeader = "X-CalCo-Account-ID"

    public let configuration: CalCoAPIConfiguration
    /// Immutable expected user-profile binding copied for one presentation or
    /// feature graph. It is never read from a mutable global at request time.
    public let expectedAccountID: String?

    private let session: URLSession

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let noRedirectDelegate = NoRedirectDelegate()

    public init(
        configuration: CalCoAPIConfiguration,
        expectedAccountID: String? = nil
    ) {
        self.configuration = configuration
        self.expectedAccountID = Self.normalizedAccountID(expectedAccountID)
        self.session = Self.makeSession(configuration: configuration)
    }

    public init(baseURL: URL, expectedAccountID: String? = nil) {
        self.init(
            configuration: CalCoAPIConfiguration(baseURL: baseURL),
            expectedAccountID: expectedAccountID
        )
    }

    public init(
        configuration: CalCoAPIConfiguration,
        session: URLSession,
        expectedAccountID: String? = nil
    ) {
        self.configuration = configuration
        self.expectedAccountID = Self.normalizedAccountID(expectedAccountID)
        self.session = session
    }

    public init(
        baseURL: URL,
        session: URLSession,
        expectedAccountID: String? = nil
    ) {
        self.init(
            configuration: CalCoAPIConfiguration(baseURL: baseURL),
            session: session,
            expectedAccountID: expectedAccountID
        )
    }

    /// Returns an immutable copy sharing the same URLSession/cookie store but
    /// bound to one user profile for every request it creates.
    public func bound(toAccountID accountID: String) -> CalCoAPIClient {
        CalCoAPIClient(
            configuration: configuration,
            session: session,
            expectedAccountID: accountID
        )
    }

    private static func normalizedAccountID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func makeURL(path: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw CalCoAPIError.invalidURL
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw CalCoAPIError.invalidURL
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        var encodedSegments: [String] = []
        encodedSegments.reserveCapacity(path.count)
        for segment in path {
            guard !segment.isEmpty,
                  segment != ".",
                  segment != "..",
                  let encoded = segment.addingPercentEncoding(
                    withAllowedCharacters: Self.pathSegmentAllowed
                  ) else {
                throw CalCoAPIError.invalidURL
            }
            encodedSegments.append(encoded)
        }
        guard !encodedSegments.isEmpty else { throw CalCoAPIError.invalidURL }

        components.percentEncodedPath = basePath + "/" + encodedSegments.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw CalCoAPIError.invalidURL }
        return url
    }

    enum HTTPMethod: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    func makeRequest(
        method: HTTPMethod,
        path: [String],
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        expectedAccountID: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try makeURL(path: path, queryItems: queryItems))
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout ?? configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = Self.normalizedAccountID(
            expectedAccountID ?? self.expectedAccountID
        ) {
            request.setValue(accountID, forHTTPHeaderField: Self.accountIDHeader)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func encodeBody<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw CalCoAPIError.encoding(error.localizedDescription)
        }
    }

    func send<Response: Decodable>(
        _ request: URLRequest,
        as _: Response.Type
    ) async throws -> Response {
        let (data, _) = try await performWithStatus(request)
        return try decode(data, as: Response.self)
    }

    func sendWithStatus<Response: Decodable>(
        _ request: URLRequest,
        as _: Response.Type
    ) async throws -> (Response, Int) {
        let (data, statusCode) = try await performWithStatus(request)
        return (try decode(data, as: Response.self), statusCode)
    }

    private func decode<Response: Decodable>(
        _ data: Data,
        as _: Response.Type
    ) throws -> Response {
        guard !data.isEmpty else {
            throw CalCoAPIError.decoding("Expected a response body")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CalCoAPIError.decoding(error.localizedDescription)
        }
    }

    func sendVoidWithoutRedirects(_ request: URLRequest) async throws {
        let restrictedSession = URLSession(
            configuration: session.configuration,
            delegate: Self.noRedirectDelegate,
            delegateQueue: nil
        )
        defer { restrictedSession.finishTasksAndInvalidate() }
        _ = try await perform(request, using: restrictedSession)
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return allowed
    }()

    private static func makeSession(configuration: CalCoAPIConfiguration) -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.httpCookieStorage = .shared
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.waitsForConnectivity = false
        return URLSession(
            configuration: sessionConfiguration,
            delegate: noRedirectDelegate,
            delegateQueue: nil
        )
    }

    private func perform(_ request: URLRequest, using transport: URLSession? = nil) async throws -> Data {
        let (data, _) = try await performWithStatus(request, using: transport)
        return data
    }

    private func performWithStatus(
        _ request: URLRequest,
        using transport: URLSession? = nil
    ) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (transport ?? session).data(for: request)
        } catch is CancellationError {
            throw CalCoAPIError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw CalCoAPIError.timeout
            case .cancelled:
                throw CalCoAPIError.cancelled
            default:
                throw CalCoAPIError.network(error.localizedDescription)
            }
        } catch let error as CalCoAPIError {
            throw error
        } catch {
            throw CalCoAPIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CalCoAPIError.invalidResponse
        }

        if http.statusCode == 401 {
            throw CalCoAPIError.unauthorized(Self.errorPayload(from: data))
        }

        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            throw CalCoAPIError.rateLimited(retryAfterSeconds: retryAfter)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw CalCoAPIError.badStatus(
                statusCode: http.statusCode,
                payload: Self.errorPayload(from: data)
                    ?? APIErrorPayload(
                        code: "unknown",
                        message: Self.rawMessage(from: data)
                            ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    )
            )
        }

        return (data, http.statusCode)
    }

    private static func errorPayload(from data: Data) -> APIErrorPayload? {
        struct Envelope: Decodable {
            let error: APIErrorPayload
        }
        return try? JSONDecoder().decode(Envelope.self, from: data).error
    }

    private static func rawMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let message = String(decoding: data, as: UTF8.self)
        return message.isEmpty ? nil : message
    }
}
