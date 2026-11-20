import XCTest

@testable import CalCo

private actor FakeLatestDiaryService: DiaryServicing {
    private var days: [LocalDiaryDate: DiaryDay] = [:]
    private var latest: Result<[DiaryLatestSlot], Error> = .success([])
    private var latestCalls: [(date: LocalDiaryDate, lookbackDays: Int)] = []
    private var fetchCalls: [LocalDiaryDate] = []

    func setDay(_ day: DiaryDay) {
        days[day.date] = day
    }

    func setLatest(_ slots: [DiaryLatestSlot]) {
        latest = .success(slots)
    }

    func setLatestError(_ error: Error) {
        latest = .failure(error)
    }

    func recordedLatestCalls() -> [(date: LocalDiaryDate, lookbackDays: Int)] {
        latestCalls
    }

    func recordedFetchCalls() -> [LocalDiaryDate] {
        fetchCalls
    }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        fetchCalls.append(date)
        return days[date] ?? DiaryDay(date: date)
    }

    func latestSlots(
        before date: LocalDiaryDate,
        lookbackDays: Int
    ) async throws -> [DiaryLatestSlot] {
        latestCalls.append((date, lookbackDays))
        return try latest.get()
    }
}

@MainActor
final class DiaryLatestTests: XCTestCase {
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let destinationDate = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let sourceDate = LocalDiaryDate(year: 2026, month: 10, day: 28)

    func testPrepareLatestShowsSourceAndKeepsHistoricalDestination() async {
        let service = FakeLatestDiaryService()
        await service.setDay(DiaryDay(date: destinationDate))
        await service.setLatest([
            DiaryLatestSlot(
                sourceDate: sourceDate,
                mealSlot: .dinner,
                logs: [
                    productLog(id: "log-1", title: "Oats", amount: "60", notes: "with milk"),
                    mealLog(id: "log-2", title: "Curry", amount: "1"),
                ]
            )
        ])
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await viewModel.prepareLatest(for: .dinner)

        let review = viewModel.latestReview
        XCTAssertEqual(review?.destinationDate, destinationDate)
        XCTAssertEqual(review?.destinationSlot, .dinner)
        XCTAssertEqual(review?.sourceDate, sourceDate)
        XCTAssertEqual(review?.items.map(\.id), ["log-1", "log-2"])
        XCTAssertEqual(viewModel.selectedDate, destinationDate)
        XCTAssertNil(viewModel.latestErrorMessage)

        let calls = await service.recordedLatestCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.date, destinationDate)
        XCTAssertEqual(calls.first?.lookbackDays, 30)
    }

    func testSubmitLatestCopiesIntoDestinationDateAndRefreshes() async {
        let service = FakeLatestDiaryService()
        await service.setDay(DiaryDay(date: destinationDate))
        await service.setLatest([
            DiaryLatestSlot(
                sourceDate: sourceDate,
                mealSlot: .dinner,
                logs: [
                    productLog(id: "log-1", title: "Oats", amount: "60", notes: "with milk"),
                    mealLog(id: "log-2", title: "Curry", amount: "1"),
                ]
            )
        ])
        var submitted: (
            drafts: [LogSubmissionDraft],
            names: [String],
            summary: String
        )?
        let viewModel = makeViewModel(service: service) { drafts, names, summary, completion in
            submitted = (drafts, names, summary)
            completion(.success([]))
        }

        await viewModel.load()
        let fetchesBefore = await service.recordedFetchCalls().count
        await viewModel.prepareLatest(for: .dinner)
        viewModel.submitLatest()

        await waitUntil { viewModel.latestNotice != nil }
        let capture = try? XCTUnwrap(submitted)
        XCTAssertEqual(capture?.drafts.count, 2)
        XCTAssertEqual(capture?.drafts.map(\.item), [
            .product(id: "food-1"),
            .meal(id: "meal-1"),
        ])
        XCTAssertEqual(capture?.drafts.map(\.date), [destinationDate, destinationDate])
        XCTAssertEqual(capture?.drafts.map(\.mealSlot), [.dinner, .dinner])
        XCTAssertEqual(capture?.drafts.map(\.amount), ["60", "1"])
        XCTAssertEqual(capture?.drafts.map(\.unit), ["g", "serving"])
        XCTAssertEqual(capture?.drafts.map(\.notes), ["with milk", nil])
        XCTAssertEqual(capture?.drafts.map(\.timeZone), ["Europe/Paris", "Europe/Paris"])
        XCTAssertEqual(capture?.names, ["Oats", "Curry"])
        XCTAssertEqual(capture?.summary, "Oats and 1 more")
        XCTAssertNil(viewModel.latestReview)
        XCTAssertEqual(viewModel.selectedDate, destinationDate)
        let fetchesAfter = await service.recordedFetchCalls().count
        XCTAssertGreaterThan(fetchesAfter, fetchesBefore)
    }

    func testLatestEmptyAndFailureProduceActionableErrors() async {
        let emptyService = FakeLatestDiaryService()
        await emptyService.setDay(DiaryDay(date: destinationDate))
        let emptyViewModel = makeViewModel(service: emptyService)
        await emptyViewModel.load()
        await emptyViewModel.prepareLatest(for: .lunch)

        XCTAssertNil(emptyViewModel.latestReview)
        XCTAssertEqual(
            emptyViewModel.latestErrorMessage,
            String(
                format: String(localized: "diary.latest.empty"),
                DiaryLabels.mealSlotName(.lunch)
            )
        )

        let failingService = FakeLatestDiaryService()
        await failingService.setDay(DiaryDay(date: destinationDate))
        await failingService.setLatestError(DiaryServiceError.server("Latest lookup failed"))
        let failingViewModel = makeViewModel(service: failingService)
        await failingViewModel.load()
        await failingViewModel.prepareLatest(for: .dinner)

        XCTAssertNil(failingViewModel.latestReview)
        XCTAssertEqual(failingViewModel.latestErrorMessage, "Latest lookup failed")
        XCTAssertNil(failingViewModel.latestLoadingSlot)
    }

    func testLatestOverFiftyItemsFailsBeforeReview() async {
        let service = FakeLatestDiaryService()
        await service.setDay(DiaryDay(date: destinationDate))
        let logs = (0..<51).map { index in
            productLog(id: "log-\(index)", title: "Item \(index)", amount: "10")
        }
        await service.setLatest([
            DiaryLatestSlot(sourceDate: sourceDate, mealSlot: .dinner, logs: logs)
        ])
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await viewModel.prepareLatest(for: .dinner)

        XCTAssertNil(viewModel.latestReview)
        XCTAssertEqual(
            viewModel.latestErrorMessage,
            String(
                format: String(localized: "diary.latest.tooMany"),
                LogSubmissionRequestBuilder.maxDrafts
            )
        )
    }

    func testDateChangeClearsLatestReviewErrorAndNotice() async {
        let service = FakeLatestDiaryService()
        await service.setDay(DiaryDay(date: destinationDate))
        await service.setLatest([
            DiaryLatestSlot(
                sourceDate: sourceDate,
                mealSlot: .dinner,
                logs: [productLog(id: "log-1", title: "Oats", amount: "60")]
            )
        ])
        let previous = destinationDate.addingDays(-1)
        await service.setDay(DiaryDay(date: previous))
        let viewModel = makeViewModel(service: service)

        await viewModel.load()
        await viewModel.prepareLatest(for: .dinner)
        XCTAssertNotNil(viewModel.latestReview)

        viewModel.showMutationNotice(
            DiaryMutationNotice(
                kind: .saved,
                title: String(localized: "diary.mutation.saved")
            )
        )
        await viewModel.selectDate(previous)

        XCTAssertEqual(viewModel.selectedDate, previous)
        XCTAssertNil(viewModel.latestReview)
        XCTAssertNil(viewModel.latestErrorMessage)
        XCTAssertNil(viewModel.latestNotice)
        XCTAssertNil(viewModel.latestLoadingSlot)
    }

    func testMalformedLatestRowsAreNotSubmitted() async {
        let invalidReview = DiaryLatestReview(
            destinationDate: destinationDate,
            destinationSlot: .dinner,
            sourceDate: sourceDate,
            items: [
                DiaryLog(
                    id: "log-1",
                    mealSlot: .dinner,
                    title: "Unknown row",
                    quantity: NutritionQuantity(amount: "1", unit: "serving")
                ),
                DiaryLog(
                    id: "log-2",
                    mealSlot: .dinner,
                    title: "Zero amount",
                    quantity: NutritionQuantity(amount: "0", unit: "g"),
                    logItem: .product(id: "food-1")
                ),
            ]
        )
        XCTAssertNil(invalidReview.makeDrafts(timeZone: "Europe/Paris"))

        let service = FakeLatestDiaryService()
        await service.setDay(DiaryDay(date: destinationDate))
        await service.setLatest([
            DiaryLatestSlot(
                sourceDate: sourceDate,
                mealSlot: .dinner,
                logs: [
                    DiaryLog(
                        id: "log-1",
                        mealSlot: .dinner,
                        title: "Unknown row",
                        quantity: NutritionQuantity(amount: "1", unit: "serving")
                    )
                ]
            )
        ])
        var submissions = 0
        let viewModel = makeViewModel(service: service) { _, _, _, completion in
            submissions += 1
            completion(.success([]))
        }

        await viewModel.load()
        await viewModel.prepareLatest(for: .dinner)
        XCTAssertNotNil(viewModel.latestReview)

        viewModel.submitLatest()

        XCTAssertEqual(submissions, 0)
        XCTAssertFalse(viewModel.latestIsSubmitting)
        XCTAssertEqual(
            viewModel.latestErrorMessage,
            String(localized: "diary.latest.invalid")
        )
        XCTAssertEqual(viewModel.latestReview?.items.map(\.id), ["log-1"])
    }

    // MARK: - Helpers

    private func makeViewModel(
        service: FakeLatestDiaryService,
        onSubmit: @escaping LogSubmissionHandler = { _, _, _, _ in }
    ) -> DiaryViewModel {
        DiaryViewModel(
            service: service,
            today: today,
            initialDate: destinationDate,
            todayProvider: { self.today },
            latestSubmissionHandler: { drafts, names, summary, completion in
                onSubmit(drafts, names, summary, completion)
            },
            timeZoneProvider: { "Europe/Paris" }
        )
    }

    private func productLog(
        id: String,
        title: String,
        amount: String,
        notes: String? = nil
    ) -> DiaryLog {
        DiaryLog(
            id: id,
            mealSlot: .dinner,
            title: title,
            quantity: NutritionQuantity(amount: amount, unit: "g"),
            notes: notes,
            logItem: .product(id: "food-1")
        )
    }

    private func mealLog(id: String, title: String, amount: String) -> DiaryLog {
        DiaryLog(
            id: id,
            mealSlot: .dinner,
            title: title,
            quantity: NutritionQuantity(amount: amount, unit: "serving"),
            logItem: .meal(id: "meal-1")
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }
}
