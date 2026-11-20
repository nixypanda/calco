import SwiftUI

public struct LoginView: View {
    @StateObject private var viewModel: LoginViewModel

    public init(
        authenticator: any AuthAuthenticating,
        coordinator: (any AuthFeatureCoordinating)? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: LoginViewModel(
                authenticator: authenticator,
                coordinator: coordinator
            )
        )
    }

    public init(viewModel: LoginViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: "auth.login.username",
                               comment: "Login form username field label"),
                        text: $viewModel.username
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
                        text: $viewModel.password
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
                    Button(action: submit) {
                        HStack {
                            if viewModel.isSubmitDisabled {
                                ProgressView()
                            }
                            Text(
                                viewModel.isSubmitDisabled
                                ? String(localized: "auth.login.submitting",
                                         comment: "Submit button label while signing in")
                                : String(localized: "auth.login.submit",
                                         comment: "Login submit button label")
                            )
                        }
                    }
                    .disabled(viewModel.isSubmitDisabled)
                    .accessibilityIdentifier("auth.login.submit")
                }
            }
#if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "auth.login.submit")) {
                        submit()
                    }
                    .disabled(viewModel.isSubmitDisabled)
                    .accessibilityIdentifier("auth.login.keyboard.submit")
                }
            }
#endif
            .navigationTitle(
                String(localized: "auth.login.title",
                       comment: "Login screen title / section header")
            )
#if os(iOS)
            .fullScreenCover(
                isPresented: Binding(
                    get: { viewModel.unsupportedAdmin != nil },
                    set: { presented in
                        if !presented { viewModel.dismissUnsupportedAdmin() }
                    }
                )
            ) {
                AdminUnsupportedView {
                    viewModel.dismissUnsupportedAdmin()
                }
            }
#else
            .sheet(
                isPresented: Binding(
                    get: { viewModel.unsupportedAdmin != nil },
                    set: { presented in
                        if !presented { viewModel.dismissUnsupportedAdmin() }
                    }
                )
            ) {
                AdminUnsupportedView {
                    viewModel.dismissUnsupportedAdmin()
                }
            }
#endif
        }
    }

    private func submit() {
        Task { await viewModel.submit() }
    }

    private var failureMessage: String? {
        guard case .failed(let failure) = viewModel.phase else { return nil }
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
}