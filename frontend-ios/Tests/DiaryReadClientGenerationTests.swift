import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryReadClientGenerationTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let generation: UInt64 = 42

    private nonisolated func makeDay(_ d: LocalDiaryDate) -> DiaryDay {
        DiaryDay(
            date: d,
            logs: [DiaryLog(id: "log-\(d.formatted)", title: "Lunch", calories: 100)],
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    // MARK: - Diary read client

    func testDiaryGuardedPreInvokeStaleMakesZeroBaseCalls() async {
        let box = GenerationBox(current: 7)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        do {
            _ = try await client.fetchDay(date, generation)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    func testDiaryGuardedPassesCapturedGenerationToBaseExactly() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client(fetchDay: { d, g in try await spy.fetchDay(d, expectedGeneration: g) })
            .guarded(isCurrentGeneration: { gen in gen == box.current })

        let task = Task { try await client.fetchDay(date, generation) }
        await spy.waitUntilStarted()
        spy.resume(returning: makeDay(date))
        let day = try? await task.value
        XCTAssertNotNil(day)
        XCTAssertEqual(spy.generations, [generation])
    }

    func testDiaryGuardedPostResumeStaleSuccessMapsToCancelled() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.fetchDay(date, generation) }
        await spy.waitUntilStarted()
        box.current = 999
        spy.resume(returning: makeDay(date))
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    func testDiaryGuardedPostResumeStaleUnauthorizedMapsToCancelled() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.fetchDay(date, generation) }
        await spy.waitUntilStarted()
        box.current = 999
        spy.resume(throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    func testDiaryGuardedCurrentUnauthorizedPreserved() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.fetchDay(date, generation) }
        await spy.waitUntilStarted()
        spy.resume(throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .unauthorized)
        }
    }

    func testDiaryGuardedPropagatesUnderlyingCancellation() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.fetchDay(date, generation) }
        await spy.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testDiaryGuardedImmediateCancellationPropagates() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.fetchDay(date, generation) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testDiaryGuardedEarlyResumeSuccess() async {
        let box = GenerationBox(current: generation)
        let spy = DiaryBaseSpy(box: box)
        let client = DiaryFeature.Client.guarded(
            base: { d, g in try await spy.fetchDay(d, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.fetchDay(date, generation) }
        spy.resume(returning: makeDay(date))
        let day = try? await task.value
        XCTAssertNotNil(day)
        XCTAssertEqual(spy.generations, [generation])
    }

    // MARK: - Diary latest read client

    func testLatestGuardedPreInvokeStaleMakesZeroBaseCalls() async {
        let box = GenerationBox(current: 7)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        do {
            _ = try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
        XCTAssertEqual(spy.callCount, 0)
    }

    func testLatestGuardedPassesCapturedGenerationToBaseExactly() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client(latestSlots: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) })
            .guarded(isCurrentGeneration: { gen in gen == box.current })

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitUntilStarted()
        spy.resume(returning: [])
        let slots = try? await task.value
        XCTAssertNotNil(slots)
        XCTAssertEqual(spy.generations, [generation])
    }

    func testLatestGuardedPostResumeStaleSuccessMapsToCancelled() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitUntilStarted()
        box.current = 999
        spy.resume(returning: [])
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    func testLatestGuardedPostResumeStaleUnauthorizedMapsToCancelled() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitUntilStarted()
        box.current = 999
        spy.resume(throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .cancelled)
        }
    }

    func testLatestGuardedCurrentUnauthorizedPreserved() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitUntilStarted()
        spy.resume(throwing: DiaryServiceError.unauthorized)
        do {
            _ = try await task.value
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? DiaryServiceError, .unauthorized)
        }
    }

    func testLatestGuardedPropagatesUnderlyingCancellation() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        await spy.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLatestGuardedImmediateCancellationPropagates() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLatestGuardedEarlyResumeSuccess() async {
        let box = GenerationBox(current: generation)
        let spy = LatestBaseSpy(box: box)
        let client = DiaryLatestFeature.Client.guarded(
            base: { b, l, g in try await spy.latestSlots(before: b, lookbackDays: l, expectedGeneration: g) },
            isCurrentGeneration: { gen in gen == box.current }
        )

        let task = Task { try await client.latestSlots(date, DiaryLatestFeature.lookbackDays, generation) }
        spy.resume(returning: [])
        let slots = try? await task.value
        XCTAssertNotNil(slots)
        XCTAssertEqual(spy.generations, [generation])
    }
}

// MARK: - Helpers

private final class GenerationBox: @unchecked Sendable {
    var current: UInt64
    init(current: UInt64) { self.current = current }
}

private final class DiaryBaseSpy: @unchecked Sendable {
    let box: GenerationBox
    private let lock = NSLock()
    private var callCountValue = 0
    private var generationsValue: [UInt64] = []
    private var startedValue = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<DiaryDay, Error>?
    private var isCancelledValue = false
    private var pendingResultValue: Result<DiaryDay, Error>?

    init(box: GenerationBox) {
        self.box = box
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callCountValue
    }

    var generations: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return generationsValue
    }

    func fetchDay(_ date: LocalDiaryDate, expectedGeneration: UInt64) async throws -> DiaryDay {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                callCountValue += 1
                generationsValue.append(expectedGeneration)

                resumeContinuation = continuation

                let wasCancelled = isCancelledValue
                if wasCancelled { isCancelledValue = false }

                let earlyResult = pendingResultValue
                if earlyResult != nil { pendingResultValue = nil }

                let waiter = startWaiter
                startWaiter = nil
                startedValue = true
                lock.unlock()

                waiter?.resume()

                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let result = earlyResult {
                    switch result {
                    case .success(let day):
                        continuation.resume(returning: day)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            lock.lock()
            if let continuation = resumeContinuation {
                resumeContinuation = nil
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                isCancelledValue = true
                lock.unlock()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if startedValue {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func resume(returning day: DiaryDay) {
        lock.lock()
        if let continuation = resumeContinuation {
            resumeContinuation = nil
            lock.unlock()
            continuation.resume(returning: day)
        } else {
            pendingResultValue = .success(day)
            lock.unlock()
        }
    }

    func resume(throwing error: Error) {
        lock.lock()
        if let continuation = resumeContinuation {
            resumeContinuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            pendingResultValue = .failure(error)
            lock.unlock()
        }
    }
}

private final class LatestBaseSpy: @unchecked Sendable {
    let box: GenerationBox
    private let lock = NSLock()
    private var callCountValue = 0
    private var generationsValue: [UInt64] = []
    private var startedValue = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<[DiaryLatestSlot], Error>?
    private var isCancelledValue = false
    private var pendingResultValue: Result<[DiaryLatestSlot], Error>?

    init(box: GenerationBox) {
        self.box = box
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callCountValue
    }

    var generations: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return generationsValue
    }

    func latestSlots(before: LocalDiaryDate, lookbackDays: Int, expectedGeneration: UInt64) async throws -> [DiaryLatestSlot] {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                callCountValue += 1
                generationsValue.append(expectedGeneration)

                resumeContinuation = continuation

                let wasCancelled = isCancelledValue
                if wasCancelled { isCancelledValue = false }

                let earlyResult = pendingResultValue
                if earlyResult != nil { pendingResultValue = nil }

                let waiter = startWaiter
                startWaiter = nil
                startedValue = true
                lock.unlock()

                waiter?.resume()

                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let result = earlyResult {
                    switch result {
                    case .success(let slots):
                        continuation.resume(returning: slots)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            lock.lock()
            if let continuation = resumeContinuation {
                resumeContinuation = nil
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                isCancelledValue = true
                lock.unlock()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if startedValue {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func resume(returning slots: [DiaryLatestSlot]) {
        lock.lock()
        if let continuation = resumeContinuation {
            resumeContinuation = nil
            lock.unlock()
            continuation.resume(returning: slots)
        } else {
            pendingResultValue = .success(slots)
            lock.unlock()
        }
    }

    func resume(throwing error: Error) {
        lock.lock()
        if let continuation = resumeContinuation {
            resumeContinuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            pendingResultValue = .failure(error)
            lock.unlock()
        }
    }
}
