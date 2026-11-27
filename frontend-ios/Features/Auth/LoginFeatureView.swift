import ComposableArchitecture
import SwiftUI

public struct LoginFeatureView: View {
    @Bindable var store: StoreOf<LoginFeature>
    private var failureMessage: String? {
        guard case .failed(let failure) = store.phase else { return nil }
        switch failure {
        case .validation(.usernameRequired):
            return String(localized: "auth.login.usernameRequired",
                          comment: "Shown when the username field is empty")
        case .validation(.passwordRequired):
            return String(localized: "auth.login.passwordRequired",
                          comment: "Shown when the password field is empty")
        case .authentication(.invalidCredentials):
            return String(localized: "auth.login.error.invalidCredentials",
                          comment: "Wrong username or password")
        case .authentication(.networkUnavailable):
            return String(localized: "auth.login.error.networkUnavailable",
                          comment: "Device is offline during sign in")
        case .authentication(.server(let message)):
            return message
        case .authentication(.unknown):
            return String(localized: "auth.login.error.unknown",
                          comment: "Generic sign in failure")
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: "auth.login.username",
                               comment: "Login form username field label"),
                        text: Binding(
                            get: { store.username },
                            set: { store.send(.usernameChanged($0)) }
                        )
                    )
                    .textContentType(.username)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .accessibilityIdentifier("auth.login.username")

                    SecureField(
                        String(localized: "auth.login.password",
                               comment: "Login form password field label"),
                        text: Binding(
                            get: { store.password },
                            set: { store.send(.passwordChanged($0)) }
                        )
                    )
                    .textContentType(.password)
                    .accessibilityIdentifier("auth.login.password")
                } header: {
                    Text(
                        String(localized: "auth.login.title",
                               comment: "Login screen title / section header")
                    )
                } footer: {
                    if let message = failureMessage {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("auth.login.error")
                    }
                }

                Section {
                    Button {
                        store.send(.submit)
                    } label: {
                        HStack {
                            if store.isSubmitting {
                                ProgressView()
                            }
                            Text(
                                store.isSubmitting
                                ? String(localized: "auth.login.submitting",
                                         comment: "Submit button label while signing in")
                                : String(localized: "auth.login.submit",
                                         comment: "Login submit button label")
                            )
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isSubmitting)
                    .accessibilityIdentifier("auth.login.submit")
                }
            }
#if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "auth.login.submit")) {
                        store.send(.submit)
                    }
                    .disabled(store.isSubmitting)
                    .accessibilityIdentifier("auth.login.keyboard.submit")
                }
            }
#endif
            .navigationTitle(
                String(localized: "auth.login.title",
                       comment: "Login screen title / section header")
            )
        }
    }
}
