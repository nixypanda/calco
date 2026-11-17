import SwiftUI

public struct AdminUnsupportedView: View {
    public var onDismiss: (() -> Void)?

    public init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(
                String(localized: "auth.admin.unsupported.title",
                       comment: "Title shown when an admin tries to sign in to the personal app")
            )
            .font(.title2)
            .fontWeight(.semibold)
            .multilineTextAlignment(.center)

            Text(
                String(localized: "auth.admin.unsupported.message",
                       comment: "Explains that admin accounts are not supported in this app")
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button(
                String(localized: "auth.common.ok",
                       comment: "Generic confirmation button label")
            ) {
                onDismiss?()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("auth.admin.unsupported.ok")
        }
        .padding()
    }
}