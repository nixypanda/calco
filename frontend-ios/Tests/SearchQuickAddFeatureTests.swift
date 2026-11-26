import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class SearchQuickAddFeatureTests: XCTestCase {
    private let requestID = UUID()
    private let generation = UInt64(7)
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)

    private var productItem: RecentLogItem {
        RecentLogItem(
            item: .product(ProductLogItemSnapshot(id: "product-1", name: "Product")),
            lastUsedDate: self.date,
            mealSlot: .breakfast,
            quantity: NutritionQuantity(amount: "100", unit: "g")
        )
    }

    private var mealItem: RecentLogItem {
        RecentLogItem(
            item: .meal(MealLogItemSnapshot(id: "meal-1", name: "Meal")),
            lastUsedDate: self.date,
            mealSlot: .lunch,
            quantity: NutritionQuantity(amount: "1", unit: "serving")
        )
    }

    private var adHocItem: RecentLogItem {
        RecentLogItem(
            item: .adHoc(AdHocLogItemSnapshot(name: "Yogurt", brand: "Brand")),
            lastUsedDate: self.date,
            mealSlot: .snack,
            quantity: NutritionQuantity(amount: "1", unit: "cup")
        )
    }

    private final class DraftCapture: @unchecked Sendable {
        var drafts: [LogSubmissionDraft] = []
    }

    /// Deterministic in-flight gate: the first submit stays suspended until the
    /// test explicitly completes it, so a second tap / context change happens
    /// while the request is genuinely pending. No sleeps or yield polling.
    private actor SubmitGate {
        private var isSubmitted = false
        private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
        private var resultWaiter: CheckedContinuation<LogSubmissionServiceResult, Never>?
        private(set) var submitCount = 0

        func submit() async -> LogSubmissionServiceResult {
            submitCount += 1
            return await withCheckedContinuation { continuation in
                resultWaiter = continuation
                isSubmitted = true
                let pending = submissionWaiters
                submissionWaiters.removeAll()
                for waiter in pending { waiter.resume() }
            }
        }

        func waitForSubmission() async {
            guard !isSubmitted else { return }
            await withCheckedContinuation { submissionWaiters.append($0) }
        }

        func complete(_ result: LogSubmissionServiceResult) {
            guard let waiter = resultWaiter else {
                XCTFail("No pending submission to complete")
                return
            }
            resultWaiter = nil
            waiter.resume(returning: result)
        }
    }

    func testDoubleTapIsIgnored() async {
        let capture = DraftCapture()
        let gate = SubmitGate()
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .breakfast,
                sessionGeneration: generation
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { drafts, _, _, _ in
                capture.drafts = drafts
                return await gate.submit()
            }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.quickAdd(self.productItem, nil)) {
            $0.phase = .submitting(SearchQuickAddFeature.Request(
                requestID: self.requestID,
                itemID: self.productItem.id,
                itemName: self.productItem.name,
                originDate: self.date,
                mealSlot: .breakfast,
                quantity: self.productItem.quantity
            ))
        }
        await gate.waitForSubmission()
        await store.send(.quickAdd(self.productItem, nil))
        let submissions = await gate.submitCount
        XCTAssertEqual(submissions, 1, "The second tap must not start another submission.")
        XCTAssertEqual(capture.drafts.count, 1, "The second tap must not build another draft.")
        await gate.complete(.success([]))
        await store.receive(.submitCompleted(requestID: self.requestID, result: .success([]))) {
            $0.phase = .succeeded(SearchQuickAddFeature.Receipt(
                itemName: self.productItem.name,
                createdLogCount: 0
            ))
        }
        await store.receive(.delegate(.logged(
            itemID: self.productItem.id,
            originDate: self.date,
            mealSlot: .breakfast,
            sessionGeneration: generation
        )))
        await store.receive(.delegate(.refresh(originDate: self.date, sessionGeneration: generation)))
        await store.finish()
    }

    func testProductQuantityOverride() async {
        let capture = DraftCapture()
        let quantity = NutritionQuantity(amount: "2", unit: "serving")
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .breakfast,
                sessionGeneration: generation
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { drafts, _, _, _ in
                capture.drafts = drafts
                XCTAssertEqual(drafts.first?.amount, "2")
                XCTAssertEqual(drafts.first?.unit, "serving")
                if case .product(let id) = drafts.first?.item {
                    XCTAssertEqual(id, "product-1")
                } else {
                    XCTFail("expected product draft")
                }
                return .success([])
            }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.quickAdd(self.productItem, quantity)) {
            $0.phase = .submitting(SearchQuickAddFeature.Request(
                requestID: self.requestID,
                itemID: self.productItem.id,
                itemName: self.productItem.name,
                originDate: self.date,
                mealSlot: .breakfast,
                quantity: quantity
            ))
        }
        await store.receive(.submitCompleted(requestID: self.requestID, result: .success([]))) {
            $0.phase = .succeeded(SearchQuickAddFeature.Receipt(
                itemName: self.productItem.name,
                createdLogCount: 0
            ))
        }
        await store.receive(.delegate(.logged(
            itemID: self.productItem.id,
            originDate: self.date,
            mealSlot: .breakfast,
            sessionGeneration: generation
        )))
        await store.receive(.delegate(.refresh(originDate: self.date, sessionGeneration: generation)))
    }

    func testMealUsesItemMealSlot() async {
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: nil,
                sessionGeneration: generation
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { drafts, _, _, _ in
                XCTAssertEqual(drafts.first?.mealSlot, .lunch)
                if case .meal(let id) = drafts.first?.item {
                    XCTAssertEqual(id, "meal-1")
                } else {
                    XCTFail("expected meal draft")
                }
                return .success([])
            }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.quickAdd(self.mealItem, nil)) {
            $0.phase = .submitting(SearchQuickAddFeature.Request(
                requestID: self.requestID,
                itemID: self.mealItem.id,
                itemName: self.mealItem.name,
                originDate: self.date,
                mealSlot: .lunch,
                quantity: self.mealItem.quantity
            ))
        }
        await store.receive(.submitCompleted(requestID: self.requestID, result: .success([]))) {
            $0.phase = .succeeded(SearchQuickAddFeature.Receipt(
                itemName: self.mealItem.name,
                createdLogCount: 0
            ))
        }
        await store.receive(.delegate(.logged(
            itemID: self.mealItem.id,
            originDate: self.date,
            mealSlot: .lunch,
            sessionGeneration: generation
        )))
        await store.receive(.delegate(.refresh(originDate: self.date, sessionGeneration: generation)))
    }

    func testAdHocQuickAdd() async {
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .snack,
                sessionGeneration: generation
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { drafts, _, _, _ in
                if case .adHoc(let name, _) = drafts.first?.item {
                    XCTAssertEqual(name, "Yogurt")
                } else {
                    XCTFail("expected ad-hoc draft")
                }
                XCTAssertEqual(drafts.first?.mealSlot, .snack)
                return .success([])
            }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.quickAdd(self.adHocItem, nil)) {
            $0.phase = .submitting(SearchQuickAddFeature.Request(
                requestID: self.requestID,
                itemID: self.adHocItem.id,
                itemName: self.adHocItem.name,
                originDate: self.date,
                mealSlot: .snack,
                quantity: self.adHocItem.quantity
            ))
        }
        await store.receive(.submitCompleted(requestID: self.requestID, result: .success([]))) {
            $0.phase = .succeeded(SearchQuickAddFeature.Receipt(
                itemName: self.adHocItem.name,
                createdLogCount: 0
            ))
        }
        await store.receive(.delegate(.logged(
            itemID: self.adHocItem.id,
            originDate: self.date,
            mealSlot: .snack,
            sessionGeneration: generation
        )))
        await store.receive(.delegate(.refresh(originDate: self.date, sessionGeneration: generation)))
    }

    func testContextChangeRetainsOriginalOrigin() async {
        let gate = SubmitGate()
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .breakfast,
                sessionGeneration: generation
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { drafts, _, _, _ in
                XCTAssertEqual(drafts.first?.date, self.date)
                XCTAssertEqual(drafts.first?.mealSlot, .breakfast)
                return await gate.submit()
            }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.quickAdd(self.productItem, nil)) {
            $0.phase = .submitting(SearchQuickAddFeature.Request(
                requestID: self.requestID,
                itemID: self.productItem.id,
                itemName: self.productItem.name,
                originDate: self.date,
                mealSlot: .breakfast,
                quantity: self.productItem.quantity
            ))
        }
        await gate.waitForSubmission()
        await store.send(.contextChanged(originDate: self.otherDate, mealSlot: .dinner)) {
            $0.originDate = self.otherDate
            $0.originMealSlot = .dinner
        }
        await gate.complete(.success([]))
        await store.receive(.submitCompleted(requestID: self.requestID, result: .success([]))) {
            $0.phase = .succeeded(SearchQuickAddFeature.Receipt(
                itemName: self.productItem.name,
                createdLogCount: 0
            ))
        }
        await store.receive(.delegate(.logged(
            itemID: self.productItem.id,
            originDate: self.date,
            mealSlot: .breakfast,
            sessionGeneration: generation
        )))
        await store.receive(.delegate(.refresh(originDate: self.date, sessionGeneration: generation)))
        await store.finish()
    }

    func testStaleCompletionIsIgnored() async {
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .breakfast,
                sessionGeneration: generation,
                phase: .submitting(SearchQuickAddFeature.Request(
                    requestID: self.requestID,
                    itemID: self.productItem.id,
                    itemName: self.productItem.name,
                    originDate: self.date,
                    mealSlot: .breakfast,
                    quantity: self.productItem.quantity
                ))
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { _, _, _, _ in .success([]) }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        let staleID = UUID()
        await store.send(.submitCompleted(requestID: staleID, result: .failure(.failed("stale"))))
    }

    func testUnauthorizedEmitsSessionExpired() async {
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .breakfast,
                sessionGeneration: generation
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { _, _, _, _ in
                .failure(.unauthorized)
            }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.quickAdd(self.productItem, nil)) {
            $0.phase = .submitting(SearchQuickAddFeature.Request(
                requestID: self.requestID,
                itemID: self.productItem.id,
                itemName: self.productItem.name,
                originDate: self.date,
                mealSlot: .breakfast,
                quantity: self.productItem.quantity
            ))
        }
        await store.receive(.submitCompleted(requestID: self.requestID, result: .failure(.unauthorized))) {
            $0.phase = .failed(
                SearchQuickAddFeature.FailureContext(
                    requestID: self.requestID,
                    itemID: self.productItem.id,
                    originDate: self.date,
                    mealSlot: .breakfast
                ),
                .unauthorized
            )
        }
        await store.receive(.delegate(.sessionExpired(generation: generation)))
    }

    func testDismissMessage() async {
        let store = TestStore(
            initialState: SearchQuickAddFeature.State(
                originDate: self.date,
                originMealSlot: .breakfast,
                sessionGeneration: generation,
                phase: .succeeded(SearchQuickAddFeature.Receipt(
                    itemName: "Food",
                    createdLogCount: 1
                ))
            )
        ) {
            SearchQuickAddFeature()
        } withDependencies: {
            $0.searchQuickAddClient = SearchQuickAddFeature.Client { _, _, _, _ in .success([]) }
            $0.uuid = .constant(self.requestID)
            $0.timeZone = TimeZone(identifier: "UTC")!
        }

        await store.send(.dismissMessage) {
            $0.phase = .idle
        }
    }

    func testLiveClientDoesNotCallHandlerForStaleGeneration() async {
        @MainActor
        final class Recorder {
            var callCount = 0
            func isCurrent(_ generation: UInt64) -> Bool {
                generation == 42
            }
            func record() {
                callCount += 1
            }
        }

        let recorder = Recorder()
        let client = SearchQuickAddFeature.Client.live(
            submissionHandler: { _, _, _, completion in
                Task { @MainActor in
                    recorder.record()
                    completion(.success([]))
                }
            },
            isCurrentGeneration: { @MainActor generation in
                recorder.isCurrent(generation)
            }
        )

        let staleResult = await client.submit([], [], "summary", 41)
        XCTAssertEqual(staleResult, .failure(.unauthorized))

        let acceptedResult = await client.submit([], [], "summary", 42)
        XCTAssertEqual(acceptedResult, .success([]))

        let callCount = await MainActor.run { recorder.callCount }
        XCTAssertEqual(callCount, 1)
    }
}
