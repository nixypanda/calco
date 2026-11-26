import ComposableArchitecture
import XCTest

@testable import CalCo

/// Native-cancel parity for copy/dismissal state. Every scenario here reaches
/// `copyRequest` through a real `submitLatest` effect rather than seeding it,
/// so the assertions cover the actual failed / uncertain commit path.
@MainActor
final class DiaryLatestDismissalFeatureTests: XCTestCase {
    private let destinationDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let sourceDate = LocalDiaryDate(year: 2026, month: 10, day: 28)
    private let generation = UInt64(42)
    private let timeZone = "Europe/Paris"

    private func makeSlots() -> [DiaryLatestSlot] {
        [
            DiaryLatestSlot(
                sourceDate: sourceDate,
                mealSlot: .dinner,
                logs: [
                    DiaryLog(
                        id: "log-1",
                        mealSlot: .dinner,
                        title: "Oats",
                        quantity: NutritionQuantity(amount: "60", unit: "g"),
                        notes: "with milk",
                        logItem: .product(id: "food-1")
                    ),
                    DiaryLog(
                        id: "log-2",
                        mealSlot: .dinner,
                        title: "Curry",
                        quantity: NutritionQuantity(amount: "1", unit: "serving"),
                        logItem: .meal(id: "meal-1")
                    ),
                ]
            )
        ]
    }

    private func makeReview() -> DiaryLatestReview {
        DiaryLatestReview(
            destinationDate: destinationDate,
            destinationSlot: .dinner,
            sourceDate: sourceDate,
            items: makeSlots().first!.logs
        )
    }

    private func makeExpectedRequest(
        requestID: UUID,
        review: DiaryLatestReview
    ) -> DiaryLatestFeature.CopyRequest {
        DiaryLatestFeature.CopyRequest(
            requestID: requestID,
            sessionGeneration: generation,
            destinationDate: destinationDate,
            destinationSlot: .dinner,
            review: review,
            timeZone: timeZone,
            drafts: review.makeDrafts(timeZone: timeZone)!
        )
    }

    private func makeState(
        review: DiaryLatestReview,
        errorMessage: String? = nil
    ) -> DiaryLatestFeature.State {
        DiaryLatestFeature.State(
            destinationDate: destinationDate,
            today: today,
            sessionGeneration: generation,
            cache: DiaryLatestFeature.Cache(),
            phase: .idle(destinationDate: destinationDate),
            review: review,
            errorMessage: errorMessage
        )
    }

    /// A failed copy followed by an explicit review cancel must clear all four
    /// review-facing fields, and the dismissed failure must not be resubmitted
    /// through `state.review ?? state.copyRequest?.review`.
    func testFailedCopyCancelClearsFourFieldsAndBlocksResubmit() async {
        let requestID = UUID()
        let review = makeReview()
        let expectedRequest = makeExpectedRequest(requestID: requestID, review: review)

        var invocationCount = 0
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            invocationCount += 1
            return .failure(.failed("boom"))
        }

        let store = TestStore(initialState: makeState(review: review, errorMessage: "stale read notice")) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = expectedRequest
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        await store.receive(
            .submitCompleted(
                requestID: requestID,
                generation: generation,
                result: .failure(.failed("boom"))
            )
        ) {
            $0.isSubmitting = false
            $0.copyRequest = expectedRequest
            $0.copyErrorMessage = "boom"
            $0.copySucceeded = false
        }
        await store.send(.cancelLatestReview) {
            $0.review = nil
            $0.errorMessage = nil
            $0.copyErrorMessage = nil
            $0.copyRequest = nil
        }

        XCTAssertNil(store.state.review)
        XCTAssertNil(store.state.errorMessage)
        XCTAssertNil(store.state.copyErrorMessage)
        XCTAssertNil(store.state.copyRequest)

        await store.send(.submitLatest)
        XCTAssertEqual(invocationCount, 1)
    }

    /// Same dismissal guarantee for the uncertain (outcome unknown) branch,
    /// where retrying an in-doubt copy would otherwise be especially unsafe.
    func testUncertainCopyCancelClearsFourFieldsAndBlocksResubmit() async {
        let requestID = UUID()
        let review = makeReview()
        let expectedRequest = makeExpectedRequest(requestID: requestID, review: review)

        var invocationCount = 0
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            invocationCount += 1
            return .failure(.uncertain("maybe"))
        }

        let store = TestStore(initialState: makeState(review: review, errorMessage: "stale read notice")) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = expectedRequest
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        await store.receive(
            .submitCompleted(
                requestID: requestID,
                generation: generation,
                result: .failure(.uncertain("maybe"))
            )
        ) {
            $0.isSubmitting = false
            $0.copyRequest = expectedRequest
            $0.copyErrorMessage = "maybe"
            $0.copySucceeded = false
        }
        await store.send(.cancelLatestReview) {
            $0.review = nil
            $0.errorMessage = nil
            $0.copyErrorMessage = nil
            $0.copyRequest = nil
        }

        XCTAssertNil(store.state.review)
        XCTAssertNil(store.state.errorMessage)
        XCTAssertNil(store.state.copyErrorMessage)
        XCTAssertNil(store.state.copyRequest)

        await store.send(.submitLatest)
        XCTAssertEqual(invocationCount, 1)
    }

    /// Dismissing only the error notice leaves the retained request and review
    /// untouched, so an explicit retry before any cancel still goes through.
    func testDismissCopyErrorKeepsRetryReviewAndClientCalls() async {
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let idSource = DismissalUUIDSequence([firstRequestID, secondRequestID])
        let review = makeReview()
        let firstRequest = makeExpectedRequest(requestID: firstRequestID, review: review)
        let secondRequest = makeExpectedRequest(requestID: secondRequestID, review: review)

        var invocationCount = 0
        let client = DiaryLatestFeature.SubmissionClient { _, _, _, _ in
            invocationCount += 1
            if invocationCount == 1 {
                return .failure(.failed("boom"))
            }
            return .success([])
        }

        let store = TestStore(initialState: makeState(review: review)) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = client
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = UUIDGenerator { idSource.next() }
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = firstRequest
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        await store.receive(
            .submitCompleted(
                requestID: firstRequestID,
                generation: generation,
                result: .failure(.failed("boom"))
            )
        ) {
            $0.isSubmitting = false
            $0.copyRequest = firstRequest
            $0.copyErrorMessage = "boom"
            $0.copySucceeded = false
        }
        await store.send(.dismissCopyError) {
            $0.copyErrorMessage = nil
        }

        XCTAssertEqual(store.state.review, review)
        XCTAssertEqual(store.state.copyRequest, firstRequest)
        XCTAssertNil(store.state.copyErrorMessage)

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = secondRequest
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        await store.receive(
            .submitCompleted(
                requestID: secondRequestID,
                generation: generation,
                result: .success([])
            )
        ) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(
            .delegate(
                .copied(
                    requestID: secondRequestID,
                    destinationDate: destinationDate,
                    destinationSlot: .dinner,
                    sessionGeneration: generation,
                    logs: []
                )
            )
        )
        XCTAssertEqual(invocationCount, 2)
    }

    /// Cancelling the review while a copy is in flight is a no-op: the payload,
    /// request, error and review must all survive, and resuming the controlled
    /// submission must still deliver the committed success response.
    func testCancelWhileSubmittingIsNoOpAndKeepsCommittedResponse() async {
        let requestID = UUID()
        let review = makeReview()
        let expectedRequest = makeExpectedRequest(requestID: requestID, review: review)

        let controlled = ControlledSubmissionClient()
        var starts = controlled.starts.makeAsyncIterator()

        let store = TestStore(initialState: makeState(review: review)) {
            DiaryLatestFeature()
        } withDependencies: {
            $0.diaryLatestSubmissionClient = DiaryLatestFeature.SubmissionClient { drafts, names, summary, expectedGeneration in
                await controlled.submit(
                    drafts: drafts,
                    names: names,
                    summary: summary,
                    expectedGeneration: expectedGeneration
                )
            }
            $0.timeZone = TimeZone(identifier: timeZone)!
            $0.uuid = .constant(requestID)
        }

        await store.send(.submitLatest) {
            $0.isSubmitting = true
            $0.copyRequest = expectedRequest
            $0.copyErrorMessage = nil
            $0.copySucceeded = false
        }
        guard let request = await starts.next() else {
            XCTFail("Expected submission start")
            controlled.finish()
            return
        }

        await store.send(.cancelLatestReview)

        XCTAssertTrue(store.state.isSubmitting)
        XCTAssertEqual(store.state.review, review)
        XCTAssertEqual(store.state.copyRequest, expectedRequest)
        XCTAssertNil(store.state.copyErrorMessage)
        XCTAssertEqual(controlled.invocationCount, 1)

        controlled.resume(request, result: .success([]))
        await store.receive(
            .submitCompleted(
                requestID: requestID,
                generation: generation,
                result: .success([])
            )
        ) {
            $0.isSubmitting = false
            $0.cache = $0.cache.clearAll()
            $0.copyRequest = nil
            $0.review = nil
            $0.copyErrorMessage = nil
            $0.copySucceeded = true
            $0.errorMessage = nil
        }
        await store.receive(
            .delegate(
                .copied(
                    requestID: requestID,
                    destinationDate: destinationDate,
                    destinationSlot: .dinner,
                    sessionGeneration: generation,
                    logs: []
                )
            )
        )
        XCTAssertEqual(controlled.invocationCount, 1)
        controlled.finish()
    }

    private final class ControlledSubmissionClient {
        struct Request: Sendable {
            let id: UUID
            let resume: @Sendable (LogSubmissionServiceResult) -> Void
        }

        private let lock = NSLock()
        private let startContinuation: AsyncStream<Request>.Continuation
        let starts: AsyncStream<Request>
        private(set) var invocationCount = 0

        init() {
            var continuation: AsyncStream<Request>.Continuation?
            self.starts = AsyncStream<Request> { continuation = $0 }
            self.startContinuation = continuation!
        }

        func submit(
            drafts: [LogSubmissionDraft],
            names: [String],
            summary: String,
            expectedGeneration: UInt64
        ) async -> LogSubmissionServiceResult {
            lock.lock()
            invocationCount += 1
            lock.unlock()
            return await withCheckedContinuation { continuation in
                startContinuation.yield(
                    Request(
                        id: UUID(),
                        resume: { result in
                            continuation.resume(returning: result)
                        }
                    )
                )
            }
        }

        func resume(_ request: Request, result: LogSubmissionServiceResult) {
            request.resume(result)
        }

        func finish() {
            startContinuation.finish()
        }
    }
}

private final class DismissalUUIDSequence {
    private var ids: [UUID]
    private var index = 0

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    func next() -> UUID {
        let id = ids[index]
        index += 1
        return id
    }
}
