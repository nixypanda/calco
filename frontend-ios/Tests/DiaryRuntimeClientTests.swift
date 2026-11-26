import Combine
import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryRuntimeClientTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!
    private let initialDate = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let fixedDate = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 24)
    )!

    private func makeSession() -> LoginSession {
        LoginSession(
            identity: AuthIdentity(id: "identity-diary-runtime", username: "alice", role: .user),
            profile: AuthProfile(id: "profile-diary-runtime", displayName: "Alice")
        )
    }

    private final class RuntimeSessionService: SessionServicing, @unchecked Sendable {
        let session: LoginSession
        init(session: LoginSession) { self.session = session }
        func restoreSession() async throws -> SessionRestoreOutcome { .authenticated(session) }
        func login(username: String, password: String) async throws -> LoginSession { session }
        func logout(sessionCookies: [HTTPCookie]) async throws {}
    }

    private final class RuntimeCookieClearer: SessionCookieClearing, @unchecked Sendable {
        func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
        func clearCookies(for baseURL: URL) {}
    }

    private final class CapturedClients {
        var diaryClient: DiaryFeature.Client?
        var diaryLatestClient: DiaryLatestFeature.Client?
        var diaryLatestSubmissionClient: DiaryLatestFeature.SubmissionClient?
        weak var coordinator: AppShellCoordinator?
    }

    private final class SessionStreamBox: @unchecked Sendable {
        var continuation: AsyncStream<SessionSnapshot>.Continuation?
    }

    private func makeAuthority() -> (CalCoSessionAuthority, CountingSessionService) {
        let session = makeSession()
        let service = CountingSessionService(session: session)
        let coordinatorSession = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: TestCookieClearer()
        )
        return (
            CalCoSessionAuthority(
                client: CalCoAPIClient(baseURL: baseURL),
                session: coordinatorSession
            ),
            service
        )
    }

    private func makeFiniteSessionClient(
        authority: CalCoSessionAuthority,
        box: SessionStreamBox
    ) -> SessionClient {
        SessionClient(
            restore: { await authority.session.restore() },
            start: {
                let phase = await authority.session.start()
                let snapshot = await MainActor.run {
                    SessionSnapshot(
                        phase: phase,
                        generation: authority.session.sessionGeneration
                    )
                }
                box.continuation?.yield(snapshot)
                box.continuation?.finish()
                return phase
            },
            signIn: { _, _ in .failed(.invalidCredentials) },
            signOut: { .completed },
            handleUnauthorized: { _, _ in false },
            dismissUnsupportedAccount: {},
            snapshot: {
                await MainActor.run {
                    SessionSnapshot(
                        phase: authority.session.phase,
                        generation: authority.session.sessionGeneration
                    )
                }
            },
            events: {
                let (stream, continuation) = AsyncStream.makeStream(of: SessionSnapshot.self)
                box.continuation = continuation
                return stream
            }
        )
    }

    private func applyStableDependencies(
        _ dependencies: inout DependencyValues,
        authority: CalCoSessionAuthority,
        box: SessionStreamBox
    ) {
        dependencies.date = .constant(fixedDate)
        dependencies.uuid = .incrementing
        dependencies.calendar = Calendar(identifier: .gregorian)
        dependencies.timeZone = TimeZone(identifier: "UTC")!
        dependencies.sessionClient = makeFiniteSessionClient(authority: authority, box: box)
        // Only unrelated clients are replaced. The three Diary clients under test
        // are captured before this runs and remain the real runtime injection.
        // This also avoids retaining the coordinator through production clients
        // that are not part of the Diary generation contract.
        dependencies.searchQuickAddClient = SearchQuickAddFeature.Client(
            submit: { @MainActor _, _, _, _ in .failure(.failed("unimplemented")) }
        )
        dependencies.legacySearchRoutingClient = .unimplemented
    }

    /// Observes the legacy diary view model's own completion counter, which is
    /// incremented only after a real fetch resolves. This proves the detached
    /// bootstrap load finished on the MainActor without any timed wait.
    private func awaitLegacyBootstrapCompletion(_ runtime: NativeWindowRuntime) async {
        guard let viewModel = runtime.coordinator.diaryViewModel else {
            XCTFail("Missing legacy diary view model for bootstrap")
            return
        }
        let baseline = viewModel.completedFetchCount
        guard viewModel.completedFetchCount == baseline else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = SinkBox()
            box.cancellable = viewModel.$completedFetchCount.sink { count in
                guard count > baseline else { return }
                box.cancellable?.cancel()
                box.cancellable = nil
                continuation.resume()
            }
        }
    }

    private func ensureSignedIn(_ runtime: NativeWindowRuntime, spy: RuntimeDiarySpy) async {
        await runtime.store.send(.task).finish()
        // The sign-in bootstrap load is fetch #1 on the shared spy. Resolve it
        // separately so the detached task completes before any test read starts.
        spy.resumeFetch(sequence: 1, returning: makeDay(initialDate))
        await awaitLegacyBootstrapCompletion(runtime)
    }

    // MARK: - Spy services

    /// Per-request controls. Every fetch gets a unique sequence, its own
    /// continuation installed before the start signal, and its own one-shot
    /// pending/cancel state. A start wait is keyed by sequence, so the bootstrap
    /// start can never satisfy a later test read's wait.
    private final class RuntimeDiarySpy: DiaryServicing, @unchecked Sendable {
        private final class FetchRequest {
            var continuation: CheckedContinuation<DiaryDay, Error>?
            var pending: Result<DiaryDay, Error>?
            var cancelled = false
        }

        private final class LatestRequest {
            var continuation: CheckedContinuation<[DiaryLatestSlot], Error>?
            var pending: Result<[DiaryLatestSlot], Error>?
            var cancelled = false
        }

        private let lock = NSLock()

        private var fetchCallCountValue = 0
        private var fetchRequests: [Int: FetchRequest] = [:]
        private var fetchStarts: [Int] = []
        private var fetchStartWaiters: [(sequence: Int, continuation: CheckedContinuation<Void, Never>)] = []

        private var latestCallCountValue = 0
        private var latestRequests: [Int: LatestRequest] = [:]
        private var latestStarts: [Int] = []
        private var latestStartWaiters: [(sequence: Int, continuation: CheckedContinuation<Void, Never>)] = []

        var fetchCallCount: Int { lock.lock(); defer { lock.unlock() }; return fetchCallCountValue }
        var latestCallCount: Int { lock.lock(); defer { lock.unlock() }; return latestCallCountValue }

        func waitForFetchStart(sequence: Int) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if fetchStarts.contains(sequence) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    fetchStartWaiters.append((sequence, continuation))
                    lock.unlock()
                }
            }
        }

        func waitForLatestStart(sequence: Int) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if latestStarts.contains(sequence) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    latestStartWaiters.append((sequence, continuation))
                    lock.unlock()
                }
            }
        }

        func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
            let sequenceBox = SequenceBox()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    fetchCallCountValue += 1
                    let sequence = fetchCallCountValue
                    sequenceBox.set(sequence)
                    // Reuse a request that received an early result/cancel before
                    // this call actually started; never lose its pending state.
                    let request = fetchRequests[sequence] ?? FetchRequest()
                    // Continuation installed before the start signal is delivered.
                    request.continuation = continuation
                    fetchRequests[sequence] = request
                    fetchStarts.append(sequence)
                    let waiters = fetchStartWaiters.filter { $0.sequence == sequence }
                    fetchStartWaiters.removeAll { $0.sequence == sequence }
                    let early = request.pending
                    request.pending = nil
                    let wasCancelled = request.cancelled
                    request.cancelled = false
                    lock.unlock()

                    for waiter in waiters { waiter.continuation.resume() }
                    if wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let early {
                        switch early {
                        case .success(let day): continuation.resume(returning: day)
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                guard let sequence = sequenceBox.get() else { return }
                self.cancelFetch(sequence: sequence)
            }
        }

        func latestSlots(before date: LocalDiaryDate, lookbackDays: Int) async throws -> [DiaryLatestSlot] {
            let sequenceBox = SequenceBox()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    latestCallCountValue += 1
                    let sequence = latestCallCountValue
                    sequenceBox.set(sequence)
                    let request = latestRequests[sequence] ?? LatestRequest()
                    request.continuation = continuation
                    latestRequests[sequence] = request
                    latestStarts.append(sequence)
                    let waiters = latestStartWaiters.filter { $0.sequence == sequence }
                    latestStartWaiters.removeAll { $0.sequence == sequence }
                    let early = request.pending
                    request.pending = nil
                    let wasCancelled = request.cancelled
                    request.cancelled = false
                    lock.unlock()

                    for waiter in waiters { waiter.continuation.resume() }
                    if wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let early {
                        switch early {
                        case .success(let slots): continuation.resume(returning: slots)
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                guard let sequence = sequenceBox.get() else { return }
                self.cancelLatest(sequence: sequence)
            }
        }

        func resumeFetch(sequence: Int, returning day: DiaryDay) {
            resumeFetch(sequence: sequence, result: .success(day))
        }

        func resumeFetch(sequence: Int, throwing error: Error) {
            resumeFetch(sequence: sequence, result: .failure(error))
        }

        private func resumeFetch(sequence: Int, result: Result<DiaryDay, Error>) {
            lock.lock()
            let request = fetchRequests[sequence] ?? FetchRequest()
            fetchRequests[sequence] = request
            guard let continuation = request.continuation else {
                request.pending = result
                lock.unlock()
                return
            }
            request.continuation = nil
            lock.unlock()
            switch result {
            case .success(let day): continuation.resume(returning: day)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }

        func resumeLatest(sequence: Int, returning slots: [DiaryLatestSlot]) {
            resumeLatest(sequence: sequence, result: .success(slots))
        }

        func resumeLatest(sequence: Int, throwing error: Error) {
            resumeLatest(sequence: sequence, result: .failure(error))
        }

        private func resumeLatest(sequence: Int, result: Result<[DiaryLatestSlot], Error>) {
            lock.lock()
            let request = latestRequests[sequence] ?? LatestRequest()
            latestRequests[sequence] = request
            guard let continuation = request.continuation else {
                request.pending = result
                lock.unlock()
                return
            }
            request.continuation = nil
            lock.unlock()
            switch result {
            case .success(let slots): continuation.resume(returning: slots)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }

        private func cancelFetch(sequence: Int) {
            lock.lock()
            let request = fetchRequests[sequence] ?? FetchRequest()
            fetchRequests[sequence] = request
            guard let continuation = request.continuation else {
                request.cancelled = true
                lock.unlock()
                return
            }
            request.continuation = nil
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }

        private func cancelLatest(sequence: Int) {
            lock.lock()
            let request = latestRequests[sequence] ?? LatestRequest()
            latestRequests[sequence] = request
            guard let continuation = request.continuation else {
                request.cancelled = true
                lock.unlock()
                return
            }
            request.continuation = nil
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }

        func getLog(id: String) async throws -> DiaryLog { throw DiaryServiceError.unknown }
        func fetchUnits() async throws -> [FoodUnit] { [] }
        func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog { throw DiaryServiceError.unknown }
        func deleteLog(id: String) async throws {}
    }

    private nonisolated func makeDay(_ d: LocalDiaryDate) -> DiaryDay {
        DiaryDay(
            date: d,
            logs: [DiaryLog(id: "log-\(d.formatted)", title: "Lunch", calories: 100)],
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    private func makeRuntime(
        authority: CalCoSessionAuthority,
        spy: RuntimeDiarySpy,
        sender: RecordingSubmissionSender,
        captured: CapturedClients,
        box: SessionStreamBox
    ) -> NativeWindowRuntime {
        let runtime = NativeWindowRuntime(
            sessionAuthority: authority,
            makeDiaryService: { _ in spy },
            logSubmissionService: LogSubmissionService(sender: sender),
            configureDependencies: { dependencies, coordinator in
                captured.diaryClient = dependencies.diaryClient
                captured.diaryLatestClient = dependencies.diaryLatestClient
                captured.diaryLatestSubmissionClient = dependencies.diaryLatestSubmissionClient
                captured.coordinator = coordinator
                self.applyStableDependencies(&dependencies, authority: authority, box: box)
            }
        )
        return runtime
    }

    private final class RecordingSubmissionSender: LogSubmissionSending, @unchecked Sendable {
        private let lock = NSLock()
        private var requestsValue: [LogSubmissionRequest] = []

        func send(_ request: LogSubmissionRequest) async throws -> [FoodLog] {
            lock.lock()
            requestsValue.append(request)
            lock.unlock()
            return []
        }

        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }; return requestsValue.count
        }
    }

    // MARK: - Diary read tests

    func testDiaryRuntimeReadNotReadyZeroServiceCalls() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation: UInt64 = 1
        do {
            _ = try await client.fetchDay(initialDate, generation)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.fetchCallCount, 0)
        _ = runtime
    }

    func testDiaryRuntimeReadStaleZeroServiceCalls() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration
        let stale: UInt64 = generation &+ 100

        do {
            _ = try await client.fetchDay(initialDate, stale)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        // Only the resolved bootstrap fetch (#1) reached the service.
        XCTAssertEqual(spy.fetchCallCount, 1)
    }

    func testDiaryRuntimeReadDeallocatedZeroServiceCalls() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        var runtime: NativeWindowRuntime? = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime!, spy: spy)
        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation = captured.coordinator?.session.sessionGeneration ?? 1
        // Independent weak observers, never manually cleared.
        weak var weakRuntime = runtime
        weak var weakCoordinator = captured.coordinator

        runtime = nil
        XCTAssertNil(weakRuntime)
        XCTAssertNil(weakCoordinator)
        guard weakCoordinator == nil else { return XCTFail("Coordinator was not released") }

        do {
            _ = try await client.fetchDay(initialDate, generation)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.fetchCallCount, 1)
    }

    func testDiaryRuntimeReadCurrentPasses() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.fetchDay(initialDate, generation) }
        await spy.waitForFetchStart(sequence: 2)
        XCTAssertEqual(spy.fetchCallCount, 2)
        spy.resumeFetch(sequence: 2, returning: makeDay(initialDate))
        let day = try? await task.value
        XCTAssertNotNil(day)
    }

    func testDiaryRuntimeReadCurrent401Preserved() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.fetchDay(initialDate, generation) }
        await spy.waitForFetchStart(sequence: 2)
        XCTAssertEqual(spy.fetchCallCount, 2)
        spy.resumeFetch(sequence: 2, throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .unauthorized)
        }
    }

    func testDiaryRuntimeReadStale401MapsCancelled() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.fetchDay(initialDate, generation) }
        await spy.waitForFetchStart(sequence: 2)
        XCTAssertEqual(spy.fetchCallCount, 2)
        await MainActor.run {
            coordinator.session.handleUnauthorized(atGeneration: generation)
        }
        spy.resumeFetch(sequence: 2, throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    func testDiaryRuntimeReadHeldPostLogoutSuccessMapsCancelled() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.fetchDay(initialDate, generation) }
        await spy.waitForFetchStart(sequence: 2)
        XCTAssertEqual(spy.fetchCallCount, 2)
        await MainActor.run {
            coordinator.session.handleUnauthorized(atGeneration: generation)
        }
        spy.resumeFetch(sequence: 2, returning: makeDay(initialDate))
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    // MARK: - Diary latest read tests

    func testDiaryRuntimeLatestReadNotReadyZeroServiceCalls() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        do {
            _ = try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, 1)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.latestCallCount, 0)
        _ = runtime
    }

    func testDiaryRuntimeLatestReadStaleZeroServiceCalls() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration
        let stale: UInt64 = generation &+ 100

        do {
            _ = try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, stale)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.latestCallCount, 0)
    }

    func testDiaryRuntimeLatestReadDeallocatedZeroServiceCalls() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        var runtime: NativeWindowRuntime? = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime!, spy: spy)
        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        let generation = captured.coordinator?.session.sessionGeneration ?? 1
        weak var weakRuntime = runtime
        weak var weakCoordinator = captured.coordinator

        runtime = nil
        XCTAssertNil(weakRuntime)
        XCTAssertNil(weakCoordinator)
        guard weakCoordinator == nil else { return XCTFail("Coordinator was not released") }

        do {
            _ = try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, generation)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.latestCallCount, 0)
    }

    func testDiaryRuntimeLatestReadCurrent() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitForLatestStart(sequence: 1)
        XCTAssertEqual(spy.latestCallCount, 1)
        spy.resumeLatest(sequence: 1, returning: [])
        let slots = try? await task.value
        XCTAssertNotNil(slots)
    }

    func testDiaryRuntimeLatestReadCurrent401Preserved() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitForLatestStart(sequence: 1)
        XCTAssertEqual(spy.latestCallCount, 1)
        spy.resumeLatest(sequence: 1, throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .unauthorized)
        }
    }

    func testDiaryRuntimeLatestReadHeldPostLogoutSuccessMapsCancelled() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitForLatestStart(sequence: 1)
        XCTAssertEqual(spy.latestCallCount, 1)
        await MainActor.run {
            coordinator.session.handleUnauthorized(atGeneration: generation)
        }
        spy.resumeLatest(sequence: 1, returning: [])
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    func testDiaryRuntimeLatestReadHeldPostLogoutUnauthorizedMapsCancelled() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration

        let task = Task { try await client.latestSlots(initialDate, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitForLatestStart(sequence: 1)
        XCTAssertEqual(spy.latestCallCount, 1)
        await MainActor.run {
            coordinator.session.handleUnauthorized(atGeneration: generation)
        }
        spy.resumeLatest(sequence: 1, throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    // MARK: - Submission tests

    func testDiaryRuntimeSubmissionStaleZeroWrites() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestSubmissionClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration
        let stale: UInt64 = generation &+ 100

        let result = await client.submit(
            [makeDraft()],
            ["Oats"],
            "Oats",
            stale
        )
        XCTAssertEqual(result, .failure(.unauthorized))
        XCTAssertEqual(sender.requestCount, 0)
    }

    func testDiaryRuntimeSubmissionCurrentOneWriteAndSingleRefresh() async {
        let (authority, _) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        await ensureSignedIn(runtime, spy: spy)
        guard let coordinator = captured.coordinator else { return XCTFail("Missing coordinator") }
        guard let client = captured.diaryLatestSubmissionClient else { return XCTFail("Missing client") }
        let generation = coordinator.session.sessionGeneration
        let baselineFetchCount = spy.fetchCallCount
        // The sole writer refreshes the legacy diary once on success: fetch #2.
        spy.resumeFetch(sequence: 2, returning: makeDay(initialDate))

        let result = await client.submit(
            [makeDraft()],
            ["Oats"],
            "Oats",
            generation
        )
        XCTAssertEqual(result, .success([]))
        XCTAssertEqual(sender.requestCount, 1)
        await spy.waitForFetchStart(sequence: 2)
        XCTAssertEqual(spy.fetchCallCount, baselineFetchCount + 1)
    }

    // MARK: - Runtime shape

    func testDiaryRuntimeInstallsNoLegacySearchViewModel() async {
        let (authority, service) = makeAuthority()
        let spy = RuntimeDiarySpy()
        let sender = RecordingSubmissionSender()
        let captured = CapturedClients()
        let box = SessionStreamBox()
        let runtime = makeRuntime(authority: authority, spy: spy, sender: sender, captured: captured, box: box)

        // Constructor/install alone: no fetch, no ready graph, no session work.
        XCTAssertEqual(spy.fetchCallCount, 0)
        XCTAssertEqual(spy.latestCallCount, 0)
        XCTAssertNil(runtime.coordinator.diaryViewModel)
        XCTAssertNil(runtime.coordinator.searchViewModel)
        XCTAssertEqual(service.restoreCount, 0)

        await ensureSignedIn(runtime, spy: spy)

        // Bootstrap is legacy only: day #1, latest 0, one restore, no legacy VM.
        XCTAssertEqual(spy.fetchCallCount, 1)
        XCTAssertEqual(spy.latestCallCount, 0)
        XCTAssertNil(runtime.coordinator.searchViewModel)
        XCTAssertEqual(service.restoreCount, 1)

        // The TCA Diary store never fetched: real captured state path is idle
        // with both caches not requested and generation 0.
        guard case .signedIn(let signedIn) = runtime.store.state.phase else {
            return XCTFail("Expected signed-in")
        }
        let screen = signedIn.window.diary
        XCTAssertEqual(screen.diary.phase, .idle(requestDate: initialDate))
        XCTAssertEqual(screen.latest.phase, .idle(destinationDate: initialDate))
        XCTAssertEqual(screen.diary.cache.generation, 0)
        XCTAssertEqual(screen.latest.cache.generation, 0)
        if case .notRequested = screen.diary.cache.entry(for: initialDate) {} else {
            XCTFail("TCA diary cache was requested")
        }
        if case .notRequested = screen.latest.cache.entry(for: initialDate) {} else {
            XCTFail("TCA latest cache was requested")
        }
    }

    private func makeDraft() -> LogSubmissionDraft {
        LogSubmissionDraft(
            item: .product(id: "food-1"),
            date: initialDate,
            mealSlot: .lunch,
            amount: "100",
            unit: "g",
            notes: nil,
            timeZone: "Asia/Kolkata"
        )
    }
}

// MARK: - Helpers

private final class CountingSessionService: SessionServicing, @unchecked Sendable {
    let session: LoginSession
    private let lock = NSLock()
    private var restoreCountStorage = 0

    var restoreCount: Int { lock.withLock { restoreCountStorage } }

    init(session: LoginSession) { self.session = session }

    func restoreSession() async throws -> SessionRestoreOutcome {
        lock.withLock { restoreCountStorage += 1 }
        return .authenticated(session)
    }

    func login(username: String, password: String) async throws -> LoginSession {
        session
    }

    func logout(sessionCookies: [HTTPCookie]) async throws {}
}

private final class TestCookieClearer: SessionCookieClearing, @unchecked Sendable {
    func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
    func clearCookies(for baseURL: URL) {}
}

private final class SequenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    func set(_ newValue: Int) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Int? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class SinkBox {
    var cancellable: AnyCancellable?
}
