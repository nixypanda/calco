import Combine
import ComposableArchitecture
import Foundation

// MARK: - Snapshot

/// A Sendable, secret-free view of session state. It intentionally carries only
/// phase and generation; credentials, cookies, and service objects stay in the
/// coordinator and never enter reducer state.
public struct SessionSnapshot: Equatable, Sendable {
    public let phase: SessionCoordinator.Phase
    public let generation: UInt64

    public init(phase: SessionCoordinator.Phase, generation: UInt64) {
        self.phase = phase
        self.generation = generation
    }
}

// MARK: - Client boundary

/// Process-wide session boundary for TCA features. Reducers depend on this
/// instead of `CalCoSessionAuthority` or `SessionCoordinator`, so cookie storage,
/// auth barriers, and generation bookkeeping remain owned by the existing
/// session authority.
public struct SessionClient: Sendable {
    public var restore: @Sendable () async -> SessionCoordinator.Phase
    public var start: @Sendable () async -> SessionCoordinator.Phase
    public var signIn: @Sendable (_ username: String, _ password: String) async -> SessionCoordinator.SignInResult
    public var signOut: @Sendable () async -> SessionCoordinator.SignOutResult
    public var handleUnauthorized: @Sendable (_ generation: UInt64?, _ reason: SessionUnavailableReason) async -> Bool
    public var dismissUnsupportedAccount: @Sendable () async -> Void
    public var snapshot: @Sendable () async -> SessionSnapshot
    public var events: @Sendable () async -> AsyncStream<SessionSnapshot>

    public init(
        restore: @escaping @Sendable () async -> SessionCoordinator.Phase,
        start: @escaping @Sendable () async -> SessionCoordinator.Phase = {
            fatalError("Unimplemented: SessionClient.start")
        },
        signIn: @escaping @Sendable (_ username: String, _ password: String) async -> SessionCoordinator.SignInResult,
        signOut: @escaping @Sendable () async -> SessionCoordinator.SignOutResult,
        handleUnauthorized: @escaping @Sendable (_ generation: UInt64?, _ reason: SessionUnavailableReason) async -> Bool,
        dismissUnsupportedAccount: @escaping @Sendable () async -> Void,
        snapshot: @escaping @Sendable () async -> SessionSnapshot,
        events: @escaping @Sendable () async -> AsyncStream<SessionSnapshot>
    ) {
        self.restore = restore
        self.start = start
        self.signIn = signIn
        self.signOut = signOut
        self.handleUnauthorized = handleUnauthorized
        self.dismissUnsupportedAccount = dismissUnsupportedAccount
        self.snapshot = snapshot
        self.events = events
    }

    public static var unimplemented: SessionClient {
        SessionClient(
            restore: {
                fatalError("Unimplemented: SessionClient.restore")
            },
            start: {
                fatalError("Unimplemented: SessionClient.start")
            },
            signIn: { _, _ in
                fatalError("Unimplemented: SessionClient.signIn")
            },
            signOut: {
                fatalError("Unimplemented: SessionClient.signOut")
            },
            handleUnauthorized: { _, _ in
                fatalError("Unimplemented: SessionClient.handleUnauthorized")
            },
            dismissUnsupportedAccount: {
                fatalError("Unimplemented: SessionClient.dismissUnsupportedAccount")
            },
            snapshot: {
                fatalError("Unimplemented: SessionClient.snapshot")
            },
            events: {
                fatalError("Unimplemented: SessionClient.events")
            }
        )
    }

    public static func live(session: SessionCoordinator) -> SessionClient {
        SessionClient(
            restore: {
                await session.restore()
            },
            start: {
                await session.start()
            },
            signIn: { username, password in
                await session.signIn(username: username, password: password)
            },
            signOut: {
                await session.signOut()
            },
            handleUnauthorized: { generation, reason in
                await MainActor.run {
                    session.handleUnauthorized(atGeneration: generation, reason: reason)
                }
            },
            dismissUnsupportedAccount: {
                await MainActor.run { session.dismissUnsupportedAccount() }
            },
            snapshot: {
                await MainActor.run {
                    SessionSnapshot(
                        phase: session.phase,
                        generation: session.sessionGeneration
                    )
                }
            },
            events: {
                await MainActor.run {
                    let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
                    let holder = SubscriptionHolder()

                    let initial = SessionSnapshot(
                        phase: session.phase,
                        generation: session.sessionGeneration
                    )
                    var last = initial
                    continuation.yield(initial)

                    // The sink is installed synchronously before this factory
                    // returns, so callers cannot miss transitions that occur
                    // after `events()` returns.
                    let cancellable = session.$phase.sink { @MainActor phase in
                        let next = SessionSnapshot(
                            phase: phase,
                            generation: session.sessionGeneration
                        )
                        guard next != last else { return }
                        last = next
                        continuation.yield(next)
                    }
                    holder.cancellable = cancellable

                    // Cleanup is intentionally asynchronous; registration is not.
                    continuation.onTermination = { _ in
                        Task { @MainActor in
                            holder.cancellable?.cancel()
                            holder.cancellable = nil
                        }
                    }

                    return stream
                }
            }
        )
    }

    public static func live(authority: CalCoSessionAuthority) -> SessionClient {
        live(session: authority.session)
    }
}

// MARK: - Event stream helpers

@MainActor
private final class SubscriptionHolder {
    var cancellable: AnyCancellable?
}


// MARK: - Dependency registration

private enum SessionClientDependencyKey: DependencyKey {
    static let liveValue: SessionClient = .unimplemented
    static let testValue: SessionClient = .unimplemented
}

extension DependencyValues {
    public var sessionClient: SessionClient {
        get { self[SessionClientDependencyKey.self] }
        set { self[SessionClientDependencyKey.self] = newValue }
    }
}
