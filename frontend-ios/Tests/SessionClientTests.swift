import XCTest

@testable import CalCo

@MainActor
final class SessionClientTests: XCTestCase {
    private let baseURL = URL(string: "https://calco.example.com")!

    private func makeSession() -> SessionCoordinator {
        let service = FakeSessionService()
        let clearer = RecordingCookieClearer()
        return SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: clearer
        )
    }

    private func makeReadinessSignal() -> (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation) {
        AsyncStream<Void>.makeStream()
    }

    func testEventsCaptureInitialAndRestoredGeneration() async {
        let session = makeSession()
        let client = SessionClient.live(session: session)

        let stream = await client.events()
        let (readyStream, readyContinuation) = makeReadinessSignal()
        let collectedTask = Task { @MainActor in
            var values: [SessionSnapshot] = []
            var iterator = stream.makeAsyncIterator()
            guard let first = await iterator.next() else {
                readyContinuation.finish()
                return values
            }
            values.append(first)
            readyContinuation.yield()
            readyContinuation.finish()
            while values.count < 3, let next = await iterator.next() {
                values.append(next)
            }
            return values
        }
        var readyIterator = readyStream.makeAsyncIterator()
        _ = await readyIterator.next()

        let restoredPhase = await client.restore()
        let collected = await collectedTask.value

        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected[0].generation, 0)
        XCTAssertEqual(collected[0].phase, .idle)
        XCTAssertEqual(collected[1].generation, 1)
        XCTAssertEqual(collected[1].phase, .restoring)
        XCTAssertEqual(collected[2].generation, 1)
        XCTAssertEqual(collected[2].phase, .signedOut(.signedOut))
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(restoredPhase, .signedOut(.signedOut))
    }

    func testRapidRestoresKeepGenerationConsistent() async {
        let session = makeSession()
        let client = SessionClient.live(session: session)

        let stream = await client.events()
        let (readyStream, readyContinuation) = makeReadinessSignal()
        let collectedTask = Task { @MainActor in
            var values: [SessionSnapshot] = []
            var iterator = stream.makeAsyncIterator()
            guard let first = await iterator.next() else {
                readyContinuation.finish()
                return values
            }
            values.append(first)
            readyContinuation.yield()
            readyContinuation.finish()
            while values.count < 5, let next = await iterator.next() {
                values.append(next)
            }
            return values
        }
        var readyIterator = readyStream.makeAsyncIterator()
        _ = await readyIterator.next()

        _ = await client.restore()
        _ = await client.restore()
        let collected = await collectedTask.value

        XCTAssertEqual(collected.count, 5)
        // idle, restoring, signedOut, restoring, signedOut
        XCTAssertEqual(collected[0].phase, .idle)
        XCTAssertEqual(collected[1].phase, .restoring)
        XCTAssertEqual(collected[2].phase, .signedOut(.signedOut))
        XCTAssertEqual(collected[3].phase, .restoring)
        XCTAssertEqual(collected[4].phase, .signedOut(.signedOut))

        XCTAssertEqual(collected[1].generation, collected[2].generation)
        XCTAssertEqual(collected[3].generation, collected[4].generation)
        XCTAssertLessThan(collected[1].generation, collected[3].generation)
    }

    func testSignOutEmitsPhaseAndNewGeneration() async {
        let session = makeSession()
        let client = SessionClient.live(session: session)

        let stream = await client.events()
        let (readyStream, readyContinuation) = makeReadinessSignal()
        let collectedTask = Task { @MainActor in
            var values: [SessionSnapshot] = []
            var iterator = stream.makeAsyncIterator()
            guard let first = await iterator.next() else {
                readyContinuation.finish()
                return values
            }
            values.append(first)
            readyContinuation.yield()
            readyContinuation.finish()
            while values.count < 2, let next = await iterator.next() {
                values.append(next)
            }
            return values
        }
        var readyIterator = readyStream.makeAsyncIterator()
        _ = await readyIterator.next()

        let result = await client.signOut()
        let collected = await collectedTask.value

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected[1].phase, .signedOut(.signedOut))
        XCTAssertEqual(collected[1].generation, 1)
        XCTAssertEqual(result, .completed)
    }

    func testCancellationAllowsLaterSessionOperations() async {
        let session = makeSession()
        let client = SessionClient.live(session: session)

        let stream = await client.events()
        let (readyStream, readyContinuation) = makeReadinessSignal()
        let consumer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                readyContinuation.finish()
                return
            }
            readyContinuation.yield()
            readyContinuation.finish()
            // Block for the next event until the consuming task is cancelled.
            _ = await iterator.next()
        }
        var readyIterator = readyStream.makeAsyncIterator()
        _ = await readyIterator.next()

        consumer.cancel()
        await consumer.value

        let phase = await client.restore()
        XCTAssertEqual(phase, .signedOut(.signedOut))
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
    }

    func testReplacementStreamWorksAfterConsumerCancellation() async {
        let session = makeSession()
        let client = SessionClient.live(session: session)

        let firstStream = await client.events()
        let (firstReadyStream, firstReadyContinuation) = makeReadinessSignal()
        let firstConsumer = Task { @MainActor in
            var iterator = firstStream.makeAsyncIterator()
            guard await iterator.next() != nil else {
                firstReadyContinuation.finish()
                return
            }
            firstReadyContinuation.yield()
            firstReadyContinuation.finish()
            _ = await iterator.next()
        }
        var firstReadyIterator = firstReadyStream.makeAsyncIterator()
        _ = await firstReadyIterator.next()
        firstConsumer.cancel()
        await firstConsumer.value

        let secondStream = await client.events()
        let (secondReadyStream, secondReadyContinuation) = makeReadinessSignal()
        let secondConsumer = Task { @MainActor in
            var values: [SessionSnapshot] = []
            var iterator = secondStream.makeAsyncIterator()
            guard let first = await iterator.next() else {
                secondReadyContinuation.finish()
                return values
            }
            values.append(first)
            secondReadyContinuation.yield()
            secondReadyContinuation.finish()
            while values.count < 3, let next = await iterator.next() {
                values.append(next)
            }
            return values
        }
        var secondReadyIterator = secondReadyStream.makeAsyncIterator()
        _ = await secondReadyIterator.next()

        _ = await client.restore()
        let collected = await secondConsumer.value

        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected[0].phase, .idle)
        XCTAssertEqual(collected[1].phase, .restoring)
        XCTAssertEqual(collected[2].phase, .signedOut(.signedOut))
    }

    func testStartIsGuardedAcrossClientsSharingSameCoordinator() async {
        let service = ControllableSessionService()
        let clearer = RecordingCookieClearer()
        let coordinator = SessionCoordinator(
            service: service,
            cookieBaseURL: baseURL,
            cookieClearer: clearer
        )
        let clientA = SessionClient.live(session: coordinator)
        let clientB = SessionClient.live(session: coordinator)

        let firstStart = Task { @MainActor in
            await clientA.start()
        }
        await service.waitUntilRestoreStarted()

        let secondStartPhase = await clientB.start()
        XCTAssertEqual(secondStartPhase, .restoring)
        let restoreCallsDuringPendingRestore = await service.restoreCallCount()
        XCTAssertEqual(restoreCallsDuringPendingRestore, 1)
        let snapshotDuringPendingRestore = await clientB.snapshot()
        XCTAssertEqual(snapshotDuringPendingRestore.generation, 1)
        XCTAssertEqual(snapshotDuringPendingRestore.phase, .restoring)

        await service.releaseRestore(.unauthenticated(.signedOut))
        let firstStartPhase = await firstStart.value
        XCTAssertEqual(firstStartPhase, .signedOut(.signedOut))

        let restoreCallsAfterFirstStart = await service.restoreCallCount()
        XCTAssertEqual(restoreCallsAfterFirstStart, 1)

        let snapshotAfterFirstStart = await clientA.snapshot()
        XCTAssertEqual(snapshotAfterFirstStart.generation, 1)
        XCTAssertEqual(snapshotAfterFirstStart.phase, .signedOut(.signedOut))

        let secondStartAfterCompletion = await clientB.start()
        XCTAssertEqual(secondStartAfterCompletion, .signedOut(.signedOut))
        let restoreCallsAfterSecondStart = await service.restoreCallCount()
        XCTAssertEqual(restoreCallsAfterSecondStart, 1)

        let finalSnapshot = await clientA.snapshot()
        XCTAssertEqual(finalSnapshot.generation, 1)
        XCTAssertEqual(finalSnapshot.phase, .signedOut(.signedOut))
    }

    private actor ControllableSessionService: SessionServicing {
        private var restoreCalls = 0
        private var restoreStarted: CheckedContinuation<Void, Never>?
        private var restoreGate: CheckedContinuation<SessionRestoreOutcome, Never>?

        func restoreCallCount() -> Int { restoreCalls }

        func waitUntilRestoreStarted() async {
            if restoreCalls > 0 { return }
            await withCheckedContinuation { restoreStarted = $0 }
        }

        func releaseRestore(_ outcome: SessionRestoreOutcome) {
            restoreGate?.resume(returning: outcome)
            restoreGate = nil
        }

        func restoreSession() async throws -> SessionRestoreOutcome {
            restoreCalls += 1
            if let restoreStarted {
                restoreStarted.resume()
                self.restoreStarted = nil
            }
            return await withCheckedContinuation { restoreGate = $0 }
        }

        func login(username: String, password: String) async throws -> LoginSession {
            throw CalCoAPIError.unauthorized(nil)
        }

        func logout(sessionCookies: [HTTPCookie]) async throws {}
    }

    private final class FakeSessionService: SessionServicing, @unchecked Sendable {
        func restoreSession() async throws -> SessionRestoreOutcome {
            .unauthenticated(.signedOut)
        }

        func login(username: String, password: String) async throws -> LoginSession {
            throw CalCoAPIError.unauthorized(nil)
        }

        func logout(sessionCookies: [HTTPCookie]) async throws {}
    }

    private final class RecordingCookieClearer: SessionCookieClearing, @unchecked Sendable {
        func sessionCookies(for baseURL: URL) -> [HTTPCookie] { [] }
        func clearCookies(for baseURL: URL) {}
    }
}