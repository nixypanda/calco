//
//  CalCoApp.swift
//
//  App entry point and runtime configuration for CalCo. Resolves the API base
//  URL from an environment override or Info.plist and validates it: release
//  requires a real HTTPS origin, debug/test permit loopback HTTP, and malformed
//  or traversal-style URLs are rejected. The app shows a startup configuration
//  error instead of launching without a usable backend.
//

import SwiftUI

/// App-wide authentication and cookie authority. Every window uses this one
/// session/client so signing in or out in one window cannot leave another
/// window showing one account while sending requests as another.
@MainActor
public final class CalCoSessionAuthority: ObservableObject {
    public let client: CalCoAPIClient
    public let session: SessionCoordinator

    public init(
        client: CalCoAPIClient? = nil,
        session: SessionCoordinator? = nil
    ) {
        let resolvedClient = client ?? CalCoAPIClient(
            baseURL: CalCoRuntimeConfiguration.baseURL
                ?? URL(string: "https://calco.invalid")!
        )
        self.client = resolvedClient
        self.session = session ?? SessionCoordinator(client: resolvedClient)
    }
}

@main
struct CalCoApp: App {
    @StateObject private var sessionAuthority = CalCoSessionAuthority()

    var body: some Scene {
        WindowGroup {
            if let message = CalCoRuntimeConfiguration.startupConfigurationError {
                VStack(spacing: 12) {
                    Text("Configuration Error")
                        .font(.headline)
                    Text(message)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                TCAAppRoot(sessionAuthority: sessionAuthority)
            }
        }
    }
}

enum CalCoRuntimeConfiguration {
    static let baseURLEnvironmentKey = "CALCO_API_BASE_URL"
    static let placeholderReleaseURL = "https://calco.example.com"

    enum Environment {
        case debug
        case test
        case release

        static var current: Environment {
            #if DEBUG
            return .debug
            #else
            return .release
            #endif
        }
    }

    static var currentEnvironment: Environment { Environment.current }

    static var baseURL: URL? {
        resolveBaseURL(environment: currentEnvironment)
    }

    static var startupConfigurationError: String? {
        #if DEBUG
        return nil
        #else
        return baseURL == nil
            ? "CalCo is not configured with a valid HTTPS API base URL."
            : nil
        #endif
    }

    // MARK: - Resolution

    static func resolveBaseURL(
        environmentOverride: String? = ProcessInfo.processInfo.environment[baseURLEnvironmentKey],
        configured: String? = Bundle.main.object(forInfoDictionaryKey: "CALCOAPIBaseURL") as? String,
        environment: Environment = currentEnvironment
    ) -> URL? {
        if let override = environmentOverride, !override.isEmpty {
            return validatedBaseURL(override, environment: environment)
        }
        guard let configured, !configured.isEmpty else { return nil }
        return validatedBaseURL(configured, environment: environment)
    }

    // MARK: - Validation

    static func validatedBaseURL(
        _ candidate: String?,
        environment: Environment = currentEnvironment
    ) -> URL? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return validatedBaseURL(url, environment: environment)
    }

    static func validatedBaseURL(
        _ candidate: URL?,
        environment: Environment = currentEnvironment
    ) -> URL? {
        guard let url = candidate else { return nil }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        guard url.query == nil else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems, !queryItems.isEmpty {
            return nil
        }
        guard url.fragment == nil else { return nil }

        let pathSegments = url.path.split(separator: "/")
        guard !pathSegments.contains("..") else { return nil }

        switch environment {
        case .release:
            guard scheme == "https" else { return nil }
            guard !isPlaceholder(url) else { return nil }
            return url
        case .debug, .test:
            if scheme == "http" {
                let lowerHost = host.lowercased()
                guard lowerHost == "localhost"
                    || lowerHost == "127.0.0.1"
                    || lowerHost == "::1" else {
                    return nil
                }
            } else if scheme != "https" {
                return nil
            }
            return url
        }
    }

    static func validatedURL(
        _ candidate: String,
        environment: Environment = currentEnvironment
    ) -> URL? {
        validatedBaseURL(candidate, environment: environment)
    }

    static func validatedURL(
        _ candidate: URL,
        environment: Environment = currentEnvironment
    ) -> URL? {
        validatedBaseURL(candidate, environment: environment)
    }

    static func isValidBaseURL(
        _ candidate: String,
        environment: Environment = currentEnvironment
    ) -> Bool {
        validatedBaseURL(candidate, environment: environment) != nil
    }

    static func isValidBaseURL(
        _ candidate: URL,
        environment: Environment = currentEnvironment
    ) -> Bool {
        validatedBaseURL(candidate, environment: environment) != nil
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        url.host?.lowercased() == "calco.example.com"
    }
}