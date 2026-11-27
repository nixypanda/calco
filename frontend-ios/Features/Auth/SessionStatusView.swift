import SwiftUI

public enum AuthSessionStatus: Equatable, Sendable {
    case restoring
    case unavailable(SessionUnavailableReason)
}

public struct SessionStatusView: View {
    public let status: AuthSessionStatus
    public var onRetry: (() -> Void)? = nil

    public var body: some View {
        switch status {
        case .restoring:
            VStack(spacing: 16) {
                ProgressView()
                Text(
                    String(localized: "auth.session.restoring",
                           comment: "Shown while a stored session is being restored")
                )
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("auth.session.restoring")

        case .unavailable(let reason):
            VStack(spacing: 16) {
                Text(
                    String(localized: "auth.session.unavailable.title",
                           comment: "Title shown when there is no usable session")
                )
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

                Text(message(for: reason))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let onRetry {
                    Button(
                        String(localized: "auth.session.signInAgain",
                               comment: "Button that returns the user to the login screen")
                        , action: onRetry
                    )
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .accessibilityIdentifier("auth.session.unavailable")
        }
    }

    private func message(for reason: SessionUnavailableReason) -> String {
        switch reason {
        case .expired:
            return String(localized: "auth.session.expired.message",
                          comment: "Explains that the session expired")
        case .signedOut:
            return String(localized: "auth.session.signedOut.message",
                          comment: "Explains that the user has been signed out")
        case .notFound:
            return String(localized: "auth.session.notFound.message",
                          comment: "Explains that no stored session was found")
        }
    }
}