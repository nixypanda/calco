import Foundation
import XCTest

@testable import CalCo

private let nutritionDetailsWaitTimeout: TimeInterval = 5

private actor NutritionDetailsFakeService: NutritionDetailsServicing {
    private var reports: [LocalDiaryDate: NutritionDetailsReport] = [:]
    private var errors: [LocalDiaryDate: NutritionDetailsServiceError] = [:]
    private var heldDates: Set<LocalDiaryDate> = []
    private var heldContinuations: [LocalDiaryDate: [CheckedContinuation<Void, Never>]] = [:]
    private var calls: [LocalDiaryDate] = []

    func setReport(_ report: NutritionDetailsReport) {
        reports[report.date] = report
    }

    /// Stores a response under the requested day, even when the payload date
    /// differs, to exercise contract-violation handling.
    func setResponse(_ report: NutritionDetailsReport, for requestedDate: LocalDiaryDate) {
        reports[requestedDate] = report
    }

    func setError(_ error: NutritionDetailsServiceError?, for date: LocalDiaryDate) {
        errors[date] = error
    }

    func hold(_ date: LocalDiaryDate) {
        heldDates.insert(date)
    }

    func waitForHold(_ date: LocalDiaryDate) async {
        let deadline = Date().addingTimeInterval(nutritionDetailsWaitTimeout)
        while heldContinuations[date]?.isEmpty != false, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(
            heldContinuations[date]?.isEmpty ?? true,
            "Timed out waiting for a held fetch on \(date.formatted)"
        )
    }

    func release(_ date: LocalDiaryDate) {
        heldDates.remove(date)
        let continuations = heldContinuations.removeValue(forKey: date) ?? []
        for continuation in continuations {
            continuation.resume()
        }
    }

    func allCalls() -> [LocalDiaryDate] {
        calls
    }

    func waitForCall(_ date: LocalDiaryDate) async {
        let deadline = Date().addingTimeInterval(nutritionDetailsWaitTimeout)
        while !calls.contains(date), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(
            calls.contains(date),
            "Timed out waiting for a nutrition-details fetch on \(date.formatted)"
        )
    }

    func waitForCallCount(_ date: LocalDiaryDate, atLeast count: Int) async {
        let deadline = Date().addingTimeInterval(nutritionDetailsWaitTimeout)
        while calls.filter({ $0 == date }).count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            calls.filter { $0 == date }.count,
            count,
            "Timed out waiting for \(count) fetches on \(date.formatted)"
        )
    }

    func fetchNutritionDetails(for date: LocalDiaryDate) async throws -> NutritionDetailsReport {
        calls.append(date)

        if heldDates.contains(date) {
            await withCheckedContinuation { continuation in
                heldContinuations[date, default: []].append(continuation)
            }
        }

        if let error = errors[date] {
            throw error
        }
        return reports[date] ?? NutritionDetailsTestFixtures.report(date: date)
    }
}

@MainActor
final class NutritionDetailsViewModelTests: XCTestCase {
    private let day = NutritionDetailsTestFixtures.day
    private let yesterday = NutritionDetailsTestFixtures.yesterday
    private let today = NutritionDetailsTestFixtures.today

    func testInitialStateLoadsSelectedDay() {
        let service = NutritionDetailsFakeService()
        let vm = NutritionDetailsViewModel(
            date: day,
            today: today,
            service: service
        )

        XCTAssertEqual(vm.selectedDate, day)
        XCTAssertEqual(vm.today, today)
        XCTAssertEqual(vm.state, .loading)
        XCTAssertTrue(vm.isLoading)
        XCTAssertTrue(vm.canGoNext)
        XCTAssertNil(vm.report)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isSessionExpired)
        XCTAssertTrue(vm.expandedNutrientCodes.isEmpty)
    }

    func testInitialDateClampsToToday() {
        let service = NutritionDetailsFakeService()
        let future = today.addingDays(4)
        let vm = NutritionDetailsViewModel(
            date: future,
            today: today,
            service: service
        )

        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertFalse(vm.canGoNext)
    }

    func testLoadSuccessPublishesTheServerReport() async {
        let service = NutritionDetailsFakeService()
        let report = NutritionDetailsTestFixtures.report(date: day, loggedItems: 2)
        await service.setReport(report)
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)

        await vm.load()

        XCTAssertEqual(vm.state, .loaded(report))
        XCTAssertEqual(vm.report, report)
        XCTAssertFalse(vm.isLoading)
        let calls = await service.allCalls()
        XCTAssertEqual(calls, [day])
    }

    func testLoadIfNeededOnlyAutoLoadsOnce() async {
        let service = NutritionDetailsFakeService()
        let report = NutritionDetailsTestFixtures.report(date: day)
        await service.setReport(report)
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)

        await vm.loadIfNeeded()
        XCTAssertEqual(vm.report, report)
        await vm.loadIfNeeded()

        let calls = await service.allCalls()
        XCTAssertEqual(calls, [day])
    }

    func testTypedNetworkAndServerErrorsMapToCopy() async {
        let service = NutritionDetailsFakeService()
        await service.setError(.networkUnavailable, for: day)
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)

        await vm.load()

        let network = String(localized: "nutrition.error.network")
        XCTAssertEqual(vm.state, .failed(network))
        XCTAssertEqual(vm.errorMessage, network)

        await service.setError(.server("The report is busy."), for: day)
        await vm.retry()
        XCTAssertEqual(vm.state, .failed("The report is busy."))
    }

    func testUnauthorizedExpiresOnceAndStopsFurtherFetches() async {
        let service = NutritionDetailsFakeService()
        await service.setError(.unauthorized, for: day)
        var expiredCallbacks = 0
        let vm = NutritionDetailsViewModel(
            date: day,
            today: today,
            service: service,
            onSessionExpired: { expiredCallbacks += 1 }
        )

        await vm.load()

        XCTAssertEqual(vm.state, .sessionExpired)
        XCTAssertTrue(vm.isSessionExpired)
        XCTAssertNil(vm.report)
        XCTAssertEqual(expiredCallbacks, 1)
        XCTAssertFalse(vm.canGoNext)

        await vm.load()
        await vm.retry()
        await vm.previousDay()
        await vm.nextDay()
        vm.toggleGuidance(for: "FIBER_G")

        let calls = await service.allCalls()
        XCTAssertEqual(calls, [day])
        XCTAssertEqual(expiredCallbacks, 1)
        XCTAssertEqual(vm.selectedDate, day)
        XCTAssertTrue(vm.expandedNutrientCodes.isEmpty)
    }

    func testCancelledInitialLoadIsNotAnErrorAndDoesNotExpireSession() async {
        let service = NutritionDetailsFakeService()
        await service.hold(day)
        var expiredCallbacks = 0
        let vm = NutritionDetailsViewModel(
            date: day,
            today: today,
            service: service,
            onSessionExpired: { expiredCallbacks += 1 }
        )

        let task = Task { @MainActor in
            await vm.load()
        }
        await service.waitForCall(day)
        await service.waitForHold(day)
        task.cancel()
        await service.release(day)
        await task.value

        XCTAssertEqual(vm.state, .loading)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(expiredCallbacks, 0)
    }

    func testStaleDayResponseNeverOverwritesNewerSelection() async {
        let service = NutritionDetailsFakeService()
        let yesterdayReport = NutritionDetailsTestFixtures.report(
            date: yesterday,
            loggedItems: 1
        )
        let todayReport = NutritionDetailsTestFixtures.report(
            date: today,
            loggedItems: 3
        )
        await service.setReport(yesterdayReport)
        await service.setReport(todayReport)
        await service.hold(yesterday)

        let vm = NutritionDetailsViewModel(
            date: yesterday,
            today: today,
            service: service
        )
        let staleTask = Task { @MainActor in
            await vm.load()
        }
        await service.waitForCall(yesterday)

        await vm.selectDate(today)
        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertEqual(vm.report, todayReport)

        await service.release(yesterday)
        await staleTask.value

        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertEqual(vm.report, todayReport)
        XCTAssertEqual(vm.state, .loaded(todayReport))
    }

    func testWrongDayPayloadIsRejectedInsteadOfShown() async {
        let service = NutritionDetailsFakeService()
        await service.setResponse(
            NutritionDetailsTestFixtures.report(date: today, loggedItems: 1),
            for: day
        )
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)

        await vm.load()

        let invalid = String(localized: "nutrition.error.invalidResponse")
        XCTAssertEqual(vm.state, .failed(invalid))
        XCTAssertNil(vm.report)
    }

    func testDayNavigationLoadsDatesAndClampsAtToday() async {
        let service = NutritionDetailsFakeService()
        for date in [day, yesterday, today] {
            await service.setReport(
                NutritionDetailsTestFixtures.report(date: date, loggedItems: 1)
            )
        }
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)
        await vm.load()
        vm.toggleGuidance(for: "FIBER_G")
        XCTAssertTrue(vm.isGuidanceExpanded(for: "FIBER_G"))

        await vm.previousDay()
        XCTAssertEqual(vm.selectedDate, yesterday)
        XCTAssertEqual(vm.report?.date, yesterday)
        XCTAssertTrue(vm.expandedNutrientCodes.isEmpty)

        await vm.nextDay()
        XCTAssertEqual(vm.selectedDate, day)
        await vm.nextDay()
        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertFalse(vm.canGoNext)

        let callsBeforeClampedTap = await service.allCalls()
        await vm.nextDay()
        let callsAfterClampedTap = await service.allCalls()
        XCTAssertEqual(callsAfterClampedTap, callsBeforeClampedTap)

        await vm.selectDate(today.addingDays(10))
        XCTAssertEqual(vm.selectedDate, today)
    }

    func testRetryRecoversAfterFailureWithoutChangingTheDay() async {
        let service = NutritionDetailsFakeService()
        await service.setError(.networkUnavailable, for: day)
        let report = NutritionDetailsTestFixtures.report(date: day, loggedItems: 1)
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)

        await vm.load()
        guard case .failed = vm.state else {
            return XCTFail("Expected a failed state")
        }

        await service.setError(nil, for: day)
        await service.setReport(report)
        await vm.retry()

        XCTAssertEqual(vm.state, .loaded(report))
        XCTAssertEqual(vm.selectedDate, day)
    }

    func testGuidanceExpansionOnlyAppliesToKnownNutrients() async {
        let service = NutritionDetailsFakeService()
        let report = NutritionDetailsTestFixtures.report(date: day)
        await service.setReport(report)
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)
        await vm.load()

        vm.setGuidanceExpanded(true, for: "FIBER_G")
        XCTAssertEqual(vm.expandedNutrientCodes, ["FIBER_G"])
        vm.toggleGuidance(for: "FIBER_G")
        XCTAssertTrue(vm.expandedNutrientCodes.isEmpty)

        vm.toggleGuidance(for: "NOT_A_NUTRIENT")
        XCTAssertTrue(vm.expandedNutrientCodes.isEmpty)
    }

    func testResetForSessionChangeInvalidatesInflightAndReturnsToLoading() async {
        let service = NutritionDetailsFakeService()
        let report = NutritionDetailsTestFixtures.report(date: day)
        await service.setReport(report)
        let vm = NutritionDetailsViewModel(date: day, today: today, service: service)
        await vm.load()
        XCTAssertEqual(vm.report, report)

        await service.hold(yesterday)
        let previousTask = Task { @MainActor in
            await vm.previousDay()
        }
        await service.waitForCall(yesterday)
        await service.waitForHold(yesterday)
        vm.resetForSessionChange()
        await service.release(yesterday)
        await previousTask.value

        XCTAssertEqual(vm.state, .loading)
        XCTAssertNil(vm.report)
        XCTAssertEqual(vm.selectedDate, yesterday)
    }
}
