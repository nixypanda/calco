import ComposableArchitecture
import Foundation

/// Small root reducer for authentication/session projection.
///
/// `AppFeature` is the single root reducer: it owns the auth projection, the
/// session bootstrap, foreground/day-change authority, and embeds `LoginFeature`
/// while a
/// login lifecycle is active, and embeds `WindowFeature` while signed in.
@Reducer
public struct AppFeature {
    public struct SignedInState: Equatable {
        public var user: AuthUser
        public var window: WindowFeature.State

        public init(user: AuthUser, window: WindowFeature.State) {
            self.user = user
            self.window = window
        }
    }

    public enum Phase: Equatable {
        case restoring
        case signedOut(SessionUnavailableReason?, LoginFeature.State)
        case signingIn(LoginFeature.State)
        case unsupportedAccount(AuthUser)
        case signedIn(SignedInState)
        case restoreFailed(SessionCoordinator.Failure)
    }

    @ObservableState
    public struct State: Equatable {
        public var phase: Phase
        public var sessionGeneration: UInt64

        public init(
            phase: Phase = .restoring,
            sessionGeneration: UInt64 = 0
        ) {
            self.phase = phase
            self.sessionGeneration = sessionGeneration
        }

        public static let initial = State()

        /// Derived storage for TCA composition. Login state lives only inside
        /// `.signedOut` and `.signingIn`; it is never an independent property.
        public var login: LoginFeature.State? {
            get {
                switch phase {
                case .signedOut(_, let loginState), .signingIn(let loginState):
                    return loginState
                default:
                    return nil
                }
            }
            set {
                guard let newValue else { return }
                switch phase {
                case .signedOut(let reason, _):
                    phase = .signedOut(reason, newValue)
                case .signingIn:
                    phase = .signingIn(newValue)
                default:
                    // Login writeback only updates an already-active login
                    // lifecycle; it cannot fabricate a signed-in/out transition.
                    return
                }
            }
        }

        /// Derived storage for TCA composition. Window state lives only inside
        /// `.signedIn`; it is never an independent property.
        public var window: WindowFeature.State? {
            get {
                guard case .signedIn(let signedIn) = phase else { return nil }
                return signedIn.window
            }
            set {
                guard let newValue,
                      case .signedIn(let signedIn) = phase else {
                    return
                }
                phase = .signedIn(SignedInState(user: signedIn.user, window: newValue))
            }
        }
    }

    public enum Action: Sendable {
        case task
        case sessionSnapshot(SessionSnapshot)
        case login(LoginFeature.Action)
        case window(WindowFeature.Action)
        /// Root foreground/day-change authority. The scene-phase observation
        /// lives once at the app root; children receive derived date changes.
        case foreground
        /// Calendar-day rollover observed once at the root, independent of
        /// scene-phase activity. `dayChanged` is idempotent, so an active
        /// transition and a calendar notification cannot produce a double read.
        case calendarDayChanged
        case dayChanged(LocalDiaryDate)
        case dismissUnsupportedAccount
        case retryRestore
    }

    @Dependency(\.sessionClient) private var sessionClient
    @Dependency(\.date) private var date
    @Dependency(\.uuid) private var uuid
    @Dependency(\.apiKeyClient) private var apiKeyClient

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .task:
                // `start` is guarded by the shared session authority, so a
                // second window cannot reset an active session. Subscribe first
                // so the guarded startup transition is not missed.
                return .run { send in
                    let stream = await sessionClient.events()
                    _ = await sessionClient.start()
                    for await snapshot in stream {
                        await send(.sessionSnapshot(snapshot))
                    }
                }
                .cancellable(id: CancelID.sessionSubscription, cancelInFlight: true)

            case let .sessionSnapshot(snapshot):
                guard snapshot.generation >= state.sessionGeneration else {
                    return .none
                }

                // A signed-in window disappearing (logout/account switch) must
                // clear an owned clipboard secret. Capture the receipt BEFORE
                // the window state is replaced; the effect is parent-owned and
                // survives child/window removal.
                let ownedReceipt = state.window?.accountSettings?.clipboardReceipt
                let client = apiKeyClient
                let teardownClipboard: Effect<Action> = {
                    guard let ownedReceipt else { return .none }
                    return .run { _ in
                        await MainActor.run { client.clearSecret(ownedReceipt) }
                    }
                }()

                state.sessionGeneration = snapshot.generation

                switch snapshot.phase {
                case .idle, .restoring:
                    state.phase = .restoring

                case .signingIn:
                    if case .signedOut(_, let loginState) = state.phase {
                        state.phase = .signingIn(loginState)
                    } else if case .signingIn(let loginState) = state.phase {
                        state.phase = .signingIn(loginState)
                    } else {
                        state.phase = .restoring
                    }

                case .signedOut(let reason):
                    if case .signedOut(_, let loginState) = state.phase {
                        state.phase = .signedOut(reason, loginState)
                    } else if case .signingIn(let loginState) = state.phase {
                        state.phase = .signedOut(reason, loginState)
                    } else {
                        state.phase = .signedOut(reason, LoginFeature.State())
                    }

                case .signedIn(let user):
                    if user.role == .user {
                        if case .signedIn(let signedIn) = state.phase,
                           signedIn.user == user,
                           signedIn.window.sessionGeneration == snapshot.generation {
                            state.phase = .signedIn(signedIn)
                        } else {
                            state.phase = .signedIn(SignedInState(
                                user: user,
                                window: WindowFeature.State(
                                    sessionGeneration: snapshot.generation,
                                    today: today(),
                                    sessionAccountID: user.id
                                )
                            ))
                        }
                    } else {
                        state.phase = .unsupportedAccount(user)
                    }

                case .unsupportedAccount(let user):
                    state.phase = .unsupportedAccount(user)

                case .restoreFailed(let failure):
                    state.phase = .restoreFailed(failure)
                }

                return teardownClipboard

            case .login:
                return .none

            case .window(.delegate(.sessionExpired(_, let generation, _))):
                guard generation == state.sessionGeneration else { return .none }
                return .run { _ in
                    _ = await sessionClient.handleUnauthorized(
                        generation,
                        .expired
                    )
                }

            case .window(.delegate(.selectedFood(let id, let date, let mealSlot, let generation, let origin))):
                guard let signedIn = self.signedInWindow(for: generation, in: state) else { return .none }
                let context = WindowCaptureContext(
                    date: date,
                    slot: mealSlot,
                    accountID: signedIn.user.id,
                    generation: generation,
                    origin: Self.windowOrigin(origin),
                    presentationID: uuid()
                )
                return .send(.window(.pushDestination(.foodDetail(id: id, context: context))))

            case .window(.delegate(.selectedMeal(let id, let date, let mealSlot, let quantity, let generation, let origin))):
                guard let signedIn = self.signedInWindow(for: generation, in: state) else { return .none }
                _ = quantity
                let context = WindowCaptureContext(
                    date: date,
                    slot: mealSlot,
                    accountID: signedIn.user.id,
                    generation: generation,
                    origin: Self.windowOrigin(origin),
                    presentationID: uuid()
                )
                return .send(.window(.pushDestination(.mealDetail(id: id, context: context))))

            case .window(.delegate(.openMeals(let date, let mealSlot, let generation))):
                guard let signedIn = self.signedInWindow(for: generation, in: state) else { return .none }
                let context = WindowCaptureContext(
                    date: date,
                    slot: mealSlot,
                    accountID: signedIn.user.id,
                    generation: generation,
                    origin: .diary,
                    presentationID: uuid()
                )
                return .send(.window(.pushDestination(.meals(context: context))))

            case .window(.delegate(.openLogEditor(let id, let date, let generation))):
                // Root authority: captured generation must match both root and
                // signed-in window before any editor destination is pushed.
                guard let signedIn = self.signedInWindow(for: generation, in: state) else { return .none }
                let context = WindowCaptureContext(
                    date: date,
                    slot: nil,
                    accountID: signedIn.user.id,
                    generation: generation,
                    origin: .diary,
                    presentationID: uuid()
                )
                return .send(.window(.pushDestination(.logEditor(id: id, context: context))))

            case .window(.delegate(.addFood(let slot, let date, let generation))):
                guard let signedIn = self.signedInWindow(for: generation, in: state) else { return .none }
                let context = WindowCaptureContext(
                    date: date,
                    slot: slot,
                    accountID: signedIn.user.id,
                    generation: generation,
                    origin: .diary,
                    presentationID: uuid()
                )
                return .send(.window(.pushDestination(.search(context: context))))

            case .foreground:
                // One root trigger only. Window's `todayChanged` drives the
                // single Diary foreground/rollover path; no second refresh here.
                return .send(.dayChanged(today()))

            case .calendarDayChanged:
                return .send(.dayChanged(today()))

            case let .dayChanged(date):
                guard case .signedIn = state.phase,
                      let window = state.window,
                      window.today != date else { return .none }
                return .send(.window(.todayChanged(date)))

            case .window:
                return .none

            case .dismissUnsupportedAccount:
                return .run { _ in
                    await sessionClient.dismissUnsupportedAccount()
                }

            case .retryRestore:
                state.phase = .restoring
                return .run { send in
                    _ = await sessionClient.restore()
                }
            }
        }
        .ifLet(\.login, action: \.login) {
            LoginFeature()
        }
        .ifLet(\.window, action: \.window) {
            WindowFeature()
        }
    }

    private enum CancelID: Hashable {
        case sessionSubscription
    }

    /// Root authority: a captured generation must match both the root and the
    /// signed-in window before any typed destination/presentation is created.
    private func signedInWindow(for generation: UInt64, in state: State) -> SignedInState? {
        guard generation == state.sessionGeneration,
              case .signedIn(let signedIn) = state.phase,
              signedIn.window.sessionGeneration == generation else { return nil }
        return signedIn
    }

    private static func windowOrigin(
        _ origin: SearchScreenFeature.NavigationOrigin
    ) -> WindowNavOrigin {
        switch origin {
        case .diaryPush: return .diary
        case .searchTab: return .search
        }
    }

    private func today() -> LocalDiaryDate {
        let now = date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return LocalDiaryDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }
}
