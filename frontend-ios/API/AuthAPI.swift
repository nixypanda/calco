// Auth endpoint calls.

import Foundation

public extension CalCoAPIClient {
    func bootstrapStatus() async throws -> BootstrapStatus {
        let request = try makeRequest(
            method: .get,
            path: ["api", "auth", "bootstrap", "status"]
        )
        return try await send(request, as: BootstrapStatus.self)
    }

    func login(username: String, password: String) async throws -> LoginSession {
        let body = try encodeBody(LoginRequest(username: username, password: password))
        let request = try makeRequest(
            method: .post,
            path: ["api", "auth", "login"],
            body: body
        )
        return try await send(request, as: LoginSession.self)
    }

    func currentSession() async throws -> LoginSession {
        let request = try makeRequest(
            method: .get,
            path: ["api", "auth", "session"]
        )
        return try await send(request, as: LoginSession.self)
    }

    func logout() async throws {
        try await logout(sessionCookies: [])
    }

    func logout(sessionCookies: [HTTPCookie]) async throws {
        var request = try makeRequest(
            method: .post,
            path: ["api", "auth", "logout"]
        )
        if let cookieHeader = HTTPCookie.requestHeaderFields(with: sessionCookies)["Cookie"],
           !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        try await sendVoidWithoutRedirects(request)
    }
}
