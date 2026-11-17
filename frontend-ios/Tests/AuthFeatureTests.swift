import XCTest

@testable import CalCo


private func makeUser(role: AuthRole = .user) -> AuthUser {
    AuthUser(
        id: "profile-1",
        username: "tester",
        role: role,
        displayName: "Tester"
    )
}

final class AuthFeatureTests: XCTestCase {

    private struct StubAuthenticator: AuthAuthenticating {
        let handler: @Sendable (String, String) async throws -> SignInOutcome

        func signIn(username: String, password: String) async throws -> SignInOutcome {
            try await handler(username, password)
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private final class CredentialRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(String, String)] = []

        func record(username: String, password: String) {
            lock.withLock { entries.append((username, password)) }
        }

        var all: [(String, String)] { lock.withLock { entries } }
    }

    private final class FailureToggle: @unchecked Sendable {
        private let lock = NSLock()
        private var failing: Bool

        init(_ failing: Bool) { self.failing = failing }

        var value: Bool { lock.withLock { failing } }

        func setValue(_ newValue: Bool) { lock.withLock { failing = newValue } }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor OneShotSignal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fire() {
            fired = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private final class RecordingCoordinator: AuthFeatureCoordinating {
        private let lock = NSLock()
        private var _signedIn: [AuthUser] = []
        private var _rejectedAdmins: [AuthUser] = []
        private var _unavailable: [SessionUnavailableReason] = []
        private var _signOutCount = 0

        var signedIn: [AuthUser] { lock.withLock { _signedIn } }
        var rejectedAdmins: [AuthUser] { lock.withLock { _rejectedAdmins } }
        var unavailable: [SessionUnavailableReason] { lock.withLock { _unavailable } }
        var signOutCount: Int { lock.withLock { _signOutCount } }

        func authFeatureDidSignIn(_ user: AuthUser) {
            lock.withLock { _signedIn.append(user) }
        }

        func authFeatureDidRejectAdmin(_ user: AuthUser) {
            lock.withLock { _rejectedAdmins.append(user) }
        }

        func authFeatureDidRequestSignOut() {
            lock.withLock { _signOutCount += 1 }
        }

        func authFeatureDidReportSessionUnavailable(_ reason: SessionUnavailableReason) {
            lock.withLock { _unavailable.append(reason) }
        }
    }


    @MainActor
    func testEmptyUsernameFailsValidationWithoutCallingService() async {
        let coordinator = RecordingCoordinator()
        let counter = CallCounter()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                counter.increment()
                return .supported(makeUser())
            },
            coordinator: coordinator
        )

        viewModel.username = ""
        viewModel.password = "pw"
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(.validation(.usernameRequired)))
        XCTAssertEqual(counter.count, 0)
        XCTAssertTrue(coordinator.signedIn.isEmpty)
        XCTAssertFalse(viewModel.isSubmitDisabled)
    }

    @MainActor
    func testWhitespaceOnlyUsernameFailsValidation() async {
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .supported(makeUser()) }
        )

        viewModel.username = "   \n\t "
        viewModel.password = "pw"
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(.validation(.usernameRequired)))
    }

    @MainActor
    func testEmptyPasswordFailsValidationWithoutCallingService() async {
        let counter = CallCounter()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                counter.increment()
                return .supported(makeUser())
            }
        )

        viewModel.username = "tester"
        viewModel.password = ""
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(.validation(.passwordRequired)))
        XCTAssertEqual(counter.count, 0)
    }


    @MainActor
    func testSupportedSignInReportsUserAndLeavesFormIdle() async {
        let coordinator = RecordingCoordinator()
        let expected = makeUser()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .supported(expected) },
            coordinator: coordinator
        )

        viewModel.username = "  tester  "
        viewModel.password = "pw"
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .editing)
        XCTAssertFalse(viewModel.isSubmitDisabled)
        XCTAssertNil(viewModel.unsupportedAdmin)
        XCTAssertEqual(coordinator.signedIn, [expected])
        XCTAssertTrue(coordinator.rejectedAdmins.isEmpty)
    }

    @MainActor
    func testSignInTrimsUsernameButPassesPasswordVerbatim() async {
        let recorder = CredentialRecorder()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { username, password in
                recorder.record(username: username, password: password)
                return .supported(makeUser())
            }
        )

        viewModel.username = "  tester \n"
        viewModel.password = " s3cret "
        await viewModel.submit()

        XCTAssertEqual(recorder.all.count, 1)
        XCTAssertEqual(recorder.all.first?.0, "tester")
        XCTAssertEqual(recorder.all.first?.1, " s3cret ")
    }


    @MainActor
    func testAdminSignInNeverEntersAppAndSurfacesUnsupportedMessage() async {
        let coordinator = RecordingCoordinator()
        let admin = makeUser(role: .admin)
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .admin(admin) },
            coordinator: coordinator
        )

        viewModel.username = "admin"
        viewModel.password = "pw"
        await viewModel.submit()

        XCTAssertEqual(viewModel.unsupportedAdmin, admin)
        XCTAssertEqual(coordinator.rejectedAdmins, [admin])
        XCTAssertTrue(coordinator.signedIn.isEmpty, "An admin must never enter the normal-user app")
        XCTAssertEqual(viewModel.phase, .adminRejected(admin))
    }

    @MainActor
    func testDismissClearsAdminUnsupportedState() async {
        let admin = makeUser(role: .admin)
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .admin(admin) }
        )

        viewModel.username = "admin"
        viewModel.password = "pw"
        await viewModel.submit()
        XCTAssertNotNil(viewModel.unsupportedAdmin)

        viewModel.dismissUnsupportedAdmin()
        XCTAssertNil(viewModel.unsupportedAdmin)
    }


    @MainActor
    func testSubmitIsDisabledWhileRequestIsInFlightAndIgnoresDuplicateSubmit() async {
        let entered = OneShotSignal()
        let gate = Gate()
        let counter = CallCounter()
        let expected = makeUser()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                await entered.fire()
                await gate.wait()
                counter.increment()
                return .supported(expected)
            }
        )

        viewModel.username = "tester"
        viewModel.password = "pw"

        let task = Task { await viewModel.submit() }
        await entered.wait()

        XCTAssertTrue(viewModel.isSubmitDisabled)
        await viewModel.submit()
        XCTAssertEqual(counter.count, 0, "Duplicate submit must be ignored while loading")

        await gate.open()
        await task.value

        XCTAssertFalse(viewModel.isSubmitDisabled)
        XCTAssertEqual(counter.count, 1)
    }

    @MainActor
    func testAuthenticationErrorIsReportedAndFormBecomesEditable() async {
        let coordinator = RecordingCoordinator()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                throw AuthFeatureError.invalidCredentials
            },
            coordinator: coordinator
        )

        viewModel.username = "tester"
        viewModel.password = "wrong"
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(.authentication(.invalidCredentials)))
        XCTAssertFalse(viewModel.isSubmitDisabled)
        XCTAssertTrue(coordinator.signedIn.isEmpty)
        XCTAssertTrue(coordinator.rejectedAdmins.isEmpty)
    }

    @MainActor
    func testServerMessageAndUnknownErrorArePreserved() async {
        let server = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                throw AuthFeatureError.server("Account disabled")
            }
        )
        server.username = "tester"
        server.password = "pw"
        await server.submit()
        XCTAssertEqual(server.phase, .failed(.authentication(.server("Account disabled"))))

        let unknown = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                throw NSError(domain: "unexpected", code: 1)
            }
        )
        unknown.username = "tester"
        unknown.password = "pw"
        await unknown.submit()
        XCTAssertEqual(unknown.phase, .failed(.authentication(.unknown)))
    }

    @MainActor
    func testCoordinatorIsWeakAndMayBeAbsent() async {
        var coordinator: RecordingCoordinator? = RecordingCoordinator()
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .supported(makeUser()) },
            coordinator: coordinator
        )
        coordinator = nil

        viewModel.username = "tester"
        viewModel.password = "pw"
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .editing)
    }

    @MainActor
    func testValidationFailureClearsWhenEditing() async {
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .supported(makeUser()) }
        )

        viewModel.username = ""
        viewModel.password = "pw"
        await viewModel.submit()
        XCTAssertEqual(viewModel.phase, .failed(.validation(.usernameRequired)))

        viewModel.username = "tester"
        XCTAssertEqual(viewModel.phase, .editing)
    }

    @MainActor
    func testAdminRejectionIsRepresentedInPhaseAndDismissable() async {
        let coordinator = RecordingCoordinator()
        let admin = makeUser(role: .admin)
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in .admin(admin) },
            coordinator: coordinator
        )

        viewModel.username = "admin"
        viewModel.password = "pw"
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .adminRejected(admin))
        XCTAssertEqual(viewModel.unsupportedAdmin, admin)
        XCTAssertEqual(coordinator.rejectedAdmins, [admin])

        viewModel.dismissUnsupportedAdmin()
        XCTAssertEqual(viewModel.phase, .editing)
        XCTAssertNil(viewModel.unsupportedAdmin)
    }

    @MainActor
    func testRetryAfterAuthenticationFailure() async {
        let failureToggle = FailureToggle(true)
        let viewModel = LoginViewModel(
            authenticator: StubAuthenticator { _, _ in
                if failureToggle.value {
                    throw AuthFeatureError.invalidCredentials
                }
                return .supported(makeUser())
            }
        )

        viewModel.username = "tester"
        viewModel.password = "pw"
        await viewModel.submit()
        XCTAssertEqual(viewModel.phase, .failed(.authentication(.invalidCredentials)))

        failureToggle.setValue(false)
        await viewModel.submit()
        XCTAssertEqual(viewModel.phase, .editing)
    }
}
