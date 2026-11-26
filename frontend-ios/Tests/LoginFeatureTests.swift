import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class LoginFeatureTests: XCTestCase {
    private let requestID = UUID()
    private let staleRequestID = UUID()

    private func makeClient(
        signIn: @escaping @Sendable (_ username: String, _ password: String) async -> SessionCoordinator.SignInResult
    ) -> SessionClient {
        SessionClient(
            restore: { .signedOut(.signedOut) },
            signIn: signIn,
            signOut: { .completed },
            handleUnauthorized: { _, _ in false },
            dismissUnsupportedAccount: {},
            snapshot: { SessionSnapshot(phase: .idle, generation: 0) },
            events: { AsyncStream { $0.finish() } }
        )
    }

    func testUsernameRequiredValidation() async {
        let requestID = self.requestID
        let store = TestStore(initialState: LoginFeature.State()) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in .failed(.invalidCredentials) }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submit) {
            $0.phase = .failed(.validation(.usernameRequired))
        }
    }

    func testPasswordRequiredValidation() async {
        let requestID = self.requestID
        let store = TestStore(initialState: LoginFeature.State(username: "user")) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in .failed(.invalidCredentials) }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submit) {
            $0.phase = .failed(.validation(.passwordRequired))
        }
    }

    func testEditingClearsAuthenticationFailure() async {
        let requestID = self.requestID
        let store = TestStore(
            initialState: LoginFeature.State(
                username: "user",
                password: "secret",
                phase: .failed(.authentication(.invalidCredentials))
            )
        ) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in .failed(.invalidCredentials) }
            $0.uuid = .constant(requestID)
        }

        await store.send(.usernameChanged("changed")) {
            $0.username = "changed"
            $0.phase = .editing
        }
    }

    func testDoubleSubmitIsIgnored() async {
        let requestID = self.requestID
        let signedInUser = AuthUser(id: "1", username: "user", role: .user, displayName: nil)
        let store = TestStore(initialState: LoginFeature.State(username: "user", password: "secret")) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in
                try? await Task.sleep(nanoseconds: 10_000_000)
                return .signedIn(signedInUser)
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submit) {
            $0.phase = .submitting(requestID: requestID)
        }
        await store.send(.submit)
        await store.receive(.submitResponse(requestID, .signedIn(signedInUser))) {
            $0.phase = .editing
            $0.password = ""
        }
    }

    func testSuccessfulSignInClearsPassword() async {
        let requestID = self.requestID
        let user = AuthUser(id: "1", username: "user", role: .user, displayName: "User")
        let store = TestStore(initialState: LoginFeature.State(username: " user ", password: "secret")) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { username, password in
                XCTAssertEqual(username, "user")
                XCTAssertEqual(password, "secret")
                return .signedIn(user)
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submit) {
            $0.phase = .submitting(requestID: requestID)
        }
        await store.receive(.submitResponse(requestID, .signedIn(user))) {
            $0.phase = .editing
            $0.password = ""
        }
    }

    func testInvalidCredentialsFailure() async {
        let requestID = self.requestID
        let store = TestStore(initialState: LoginFeature.State(username: "user", password: "secret")) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in .failed(.invalidCredentials) }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submit) {
            $0.phase = .submitting(requestID: requestID)
        }
        await store.receive(.submitResponse(requestID, .failed(.invalidCredentials))) {
            $0.phase = .failed(.authentication(.invalidCredentials))
        }
    }

    func testUnsupportedRoleReturnsEditingWithoutLocalPresentation() async {
        let requestID = self.requestID
        let admin = AuthUser(id: "2", username: "admin", role: .admin, displayName: nil)
        let store = TestStore(initialState: LoginFeature.State(username: "admin", password: "secret")) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in .rejectedUnsupportedRole(admin) }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submit) {
            $0.phase = .submitting(requestID: requestID)
        }
        await store.receive(.submitResponse(requestID, .rejectedUnsupportedRole(admin))) {
            $0.phase = .editing
            $0.password = ""
        }
    }

    func testStaleSubmitResponseIsIgnored() async {
        let requestID = self.requestID
        let store = TestStore(
            initialState: LoginFeature.State(
                username: "user",
                password: "secret",
                phase: .submitting(requestID: requestID)
            )
        ) {
            LoginFeature()
        } withDependencies: {
            $0.sessionClient = makeClient { _, _ in .failed(.invalidCredentials) }
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitResponse(staleRequestID, .failed(.invalidCredentials)))
        await store.send(.submitResponse(requestID, .failed(.invalidCredentials))) {
            $0.phase = .failed(.authentication(.invalidCredentials))
        }
    }
}
