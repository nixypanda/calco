import Foundation
import XCTest

@testable import CalCo

// DiaryViewModel refresh accounting: the initial idle state is not evidence of a
// completed fetch, and a failed fetch does not publish fresh content or advance
// the marker an observer uses to detect a completed refresh.

private let diaryWaitTimeout: TimeInterval = 5

private actor FakeDiaryService: DiaryServicing {
    private var days: [LocalDiaryDate: DiaryDay] = [:]
    private var perDateErrors: [LocalDiaryDate: DiaryServiceError] = [:]
    private var defaultError: DiaryServiceError?
    private var delays: [LocalDiaryDate: UInt64] = [:]
    private var heldDates: Set<LocalDiaryDate> = []
    private var heldContinuations: [LocalDiaryDate: [CheckedContinuation<Void, Never>]] = [:]
    private var calls: [LocalDiaryDate] = []

    func setDay(_ day: DiaryDay) {
        days[day.date] = day
    }

    func setError(_ error: DiaryServiceError?) {
        defaultError = error
    }

    func setDelay(_ nanoseconds: UInt64, for date: LocalDiaryDate) {
        delays[date] = nanoseconds
    }

    func hold(_ date: LocalDiaryDate) {
        heldDates.insert(date)
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

    func callCount(for date: LocalDiaryDate) -> Int {
        calls.filter { $0 == date }.count
    }

    func waitForCall(_ date: LocalDiaryDate) async {
        let deadline = Date().addingTimeInterval(diaryWaitTimeout)
        while !calls.contains(date), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(
            calls.contains(date),
            "Timed out waiting for a diary fetch on \(date.formatted)"
        )
    }

    func waitForCallCount(_ date: LocalDiaryDate, atLeast count: Int) async {
        let deadline = Date().addingTimeInterval(diaryWaitTimeout)
        while calls.filter({ $0 == date }).count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            calls.filter { $0 == date }.count,
            count,
            "Timed out waiting for \(count) diary fetches on \(date.formatted)"
        )
    }

    func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
        calls.append(date)

        if heldDates.contains(date) {
            await withCheckedContinuation { continuation in
                heldContinuations[date, default: []].append(continuation)
            }
        } else if let delay = delays[date], delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }

        if let error = perDateErrors[date] ?? defaultError {
            throw error
        }
        return days[date] ?? DiaryDay(date: date)
    }
}

@MainActor
final class DiaryTests: XCTestCase {
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let yesterday = LocalDiaryDate(year: 2026, month: 11, day: 16)

    func testInitialStateLoading() {
        let service = FakeDiaryService()
        let vm = DiaryViewModel(service: service, today: today)

        XCTAssertEqual(vm.state, .loading)
        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertFalse(vm.canGoNext)
        XCTAssertFalse(vm.isSessionExpired)
    }

    func testLoadSuccess() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", mealSlot: .breakfast, title: "Eggs", calories: 100)],
            goal: DiaryGoalTargets(
                calorieTarget: 2000,
                proteinTargetG: 100,
                carbsTargetG: 200,
                fatTargetG: 70
            ),
            prefs: DiaryPrefs(enabledSlots: [.breakfast])
        ))
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        XCTAssertEqual(vm.state, .loaded(.idle))
        XCTAssertEqual(vm.logs.count, 1)
        XCTAssertEqual(vm.goal.calorieTarget, 2000)
        XCTAssertEqual(vm.groupedSections.map(\.id), ["breakfast"])
        let calls = await service.allCalls()
        XCTAssertEqual(calls, [today])
    }

    func testTypedNetworkErrorMapsToLocalizedCopy() async {
        let service = FakeDiaryService()
        await service.setError(.networkUnavailable)
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        let expected = String(localized: "diary.error.network")
        XCTAssertEqual(vm.errorMessage, expected)
        XCTAssertEqual(vm.state, .failed(expected))
        XCTAssertFalse(vm.isSessionExpired)
    }

    func testServerErrorUsesBackendMessageInsteadOfDebugDescription() async {
        let service = FakeDiaryService()
        await service.setError(.server("The server is busy."))
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        XCTAssertEqual(vm.errorMessage, "The server is busy.")
        XCTAssertEqual(vm.state, .failed("The server is busy."))
    }

    func testUnauthorizedClearsDataNotifiesOnceAndStopsRetrying() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)],
            goal: DiaryGoalTargets(calorieTarget: 2000),
            prefs: DiaryPrefs(enabledSlots: [.breakfast])
        ))
        let fixedToday = today
        var expiredCallbacks = 0
        let vm = DiaryViewModel(
            service: service,
            today: today,
            todayProvider: { fixedToday },
            onSessionExpired: { expiredCallbacks += 1 }
        )

        await vm.load()
        XCTAssertEqual(vm.logs.count, 1)

        await service.setError(.unauthorized)
        await vm.refresh()

        XCTAssertEqual(vm.state, .sessionExpired)
        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertEqual(vm.goal, DiaryGoalTargets())
        XCTAssertEqual(vm.enabledSlots, Set(MealSlot.allCases))
        XCTAssertEqual(expiredCallbacks, 1)

        let callsAfterExpiry = await service.allCalls()
        await vm.load()
        await vm.refresh()
        await vm.previousDay()
        let callsAfterRetries = await service.allCalls()

        XCTAssertEqual(callsAfterRetries, callsAfterExpiry)
        XCTAssertEqual(expiredCallbacks, 1)
        XCTAssertEqual(vm.selectedDate, today)
    }

    func testCompletedFetchCountTracksActualFetchCompletion() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)]
        ))
        let vm = DiaryViewModel(service: service, today: today)

        XCTAssertEqual(vm.completedFetchCount, 0)

        await vm.load()
        XCTAssertEqual(vm.completedFetchCount, 1)

        await vm.refresh()
        XCTAssertEqual(vm.completedFetchCount, 2)

        await service.setError(.server("boom"))
        await vm.refresh()
        XCTAssertEqual(vm.completedFetchCount, 2)
        XCTAssertEqual(vm.state, .loaded(.failed("boom")))
    }

    func testCancelledRefreshIsIgnoredAndKeepsLoadedContent() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)]
        ))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        await service.setDelay(10_000_000_000, for: today)
        let refreshTask = Task { @MainActor in
            await vm.refresh()
        }
        await service.waitForCallCount(today, atLeast: 2)
        refreshTask.cancel()
        await refreshTask.value

        XCTAssertEqual(vm.state, .loaded(.idle))
        XCTAssertEqual(vm.logs.map(\.id), ["1"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isRefreshing)
    }

    func testStaleDateResponseDoesNotOverwriteNewSelection() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: yesterday,
            logs: [DiaryLog(id: "stale", title: "Stale")]
        ))
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "fresh", title: "Fresh")]
        ))
        await service.hold(yesterday)

        let vm = DiaryViewModel(service: service, today: today, initialDate: yesterday)
        let staleTask = Task { @MainActor in
            await vm.load()
        }
        await service.waitForCall(yesterday)

        await vm.selectDate(today)
        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertEqual(vm.logs.map(\.id), ["fresh"])

        await service.release(yesterday)
        await staleTask.value

        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertEqual(vm.logs.map(\.id), ["fresh"])
        XCTAssertEqual(vm.state, .loaded(.idle))
    }

    func testSettingsSaveDuringHeldLoadingWinsAndLeavesLoadedState() async {
        let service = FakeDiaryService()
        let oldGoal = DiaryGoalTargets(calorieTarget: 2_100)
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "old", title: "Old")],
            goal: oldGoal,
            prefs: DiaryPrefs(enabledSlots: [.breakfast, .lunch])
        ))
        await service.hold(today)
        let vm = DiaryViewModel(service: service, today: today)
        let load = Task { @MainActor in await vm.load() }
        await service.waitForCall(today)

        let savedGoal = DiaryGoalTargets(calorieTarget: 2_200)
        vm.applySavedGoal(savedGoal, effectiveOn: today)
        vm.applySavedPreferences(DiaryPrefs(enabledSlots: [.dinner]))
        XCTAssertEqual(vm.goal, savedGoal)
        XCTAssertEqual(vm.enabledSlots, [.dinner])

        await service.release(today)
        await load.value

        XCTAssertEqual(vm.state, .loaded(.idle))
        XCTAssertEqual(vm.goal, savedGoal)
        XCTAssertEqual(vm.enabledSlots, [.dinner])
        XCTAssertEqual(vm.logs.map(\.id), ["old"])
    }

    func testLatestSettingsOverrideWinsAcrossHeldLoadAndSubsequentRefresh() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "day-log", title: "Day")],
            goal: DiaryGoalTargets(calorieTarget: 2_100),
            prefs: DiaryPrefs(enabledSlots: [.breakfast, .lunch])
        ))
        await service.hold(today)
        let vm = DiaryViewModel(service: service, today: today)
        let load = Task { @MainActor in await vm.load() }
        await service.waitForCall(today)

        let saveAGoal = DiaryGoalTargets(calorieTarget: 2_150)
        let saveAPrefs = DiaryPrefs(enabledSlots: [.dinner])
        vm.applySavedGoal(saveAGoal, effectiveOn: today)
        vm.applySavedPreferences(saveAPrefs)

        await service.release(today)
        await load.value
        XCTAssertEqual(vm.goal, saveAGoal)
        XCTAssertEqual(vm.enabledSlots, [.dinner])
        XCTAssertEqual(vm.state, .loaded(.idle))

        let saveBGoal = DiaryGoalTargets(calorieTarget: 2_200)
        let saveBPrefs = DiaryPrefs(enabledSlots: [.snack])
        vm.applySavedGoal(saveBGoal, effectiveOn: today)
        vm.applySavedPreferences(saveBPrefs)

        // A different client wins later. The next refresh must show server C,
        // not indefinitely mask it with B.
        let serverCGoal = DiaryGoalTargets(calorieTarget: 2_300)
        let serverCPrefs = DiaryPrefs(enabledSlots: [.lateNightSnack])
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "day-log", title: "Day")],
            goal: serverCGoal,
            prefs: serverCPrefs
        ))
        await vm.refresh()

        XCTAssertEqual(vm.goal, serverCGoal)
        XCTAssertEqual(vm.enabledSlots, [.lateNightSnack])

        await vm.refresh()
        XCTAssertEqual(vm.goal, serverCGoal)
        XCTAssertEqual(vm.enabledSlots, [.lateNightSnack])
    }

    func testDirectLoadedSettingsSaveDoesNotMaskLaterServerRefresh() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            goal: DiaryGoalTargets(calorieTarget: 2_100),
            prefs: DiaryPrefs(enabledSlots: [.breakfast])
        ))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        vm.applySavedGoal(DiaryGoalTargets(calorieTarget: 2_200), effectiveOn: today)
        vm.applySavedPreferences(DiaryPrefs(enabledSlots: [.lunch]))
        XCTAssertEqual(vm.goal.calorieTarget, 2_200)
        XCTAssertEqual(vm.enabledSlots, [.lunch])

        let serverGoal = DiaryGoalTargets(calorieTarget: 2_300)
        let serverPrefs = DiaryPrefs(enabledSlots: [.dinner])
        await service.setDay(DiaryDay(
            date: today,
            goal: serverGoal,
            prefs: serverPrefs
        ))
        await vm.refresh()

        XCTAssertEqual(vm.goal, serverGoal)
        XCTAssertEqual(vm.enabledSlots, [.dinner])
    }

    func testResetForSessionChangeClearsContentAndInvalidatesInflightLoad() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)],
            goal: DiaryGoalTargets(calorieTarget: 2000),
            prefs: DiaryPrefs(enabledSlots: [.breakfast])
        ))
        let fixedToday = today
        let vm = DiaryViewModel(
            service: service,
            today: today,
            todayProvider: { fixedToday }
        )
        await vm.load()

        await service.hold(today)
        let refreshTask = Task { @MainActor in
            await vm.refresh()
        }
        await service.waitForCallCount(today, atLeast: 2)

        vm.resetForSessionChange()

        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertEqual(vm.goal, DiaryGoalTargets())
        XCTAssertEqual(vm.enabledSlots, Set(MealSlot.allCases))
        XCTAssertEqual(vm.state, .loading)
        XCTAssertEqual(vm.selectedDate, fixedToday)
        XCTAssertFalse(vm.isSessionExpired)
        XCTAssertNil(vm.errorMessage)

        await service.release(today)
        await refreshTask.value

        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertEqual(vm.state, .loading)
    }

    func testMidnightRolloverMovesTodaySelectionToNewDay() async {
        let nextDay = today.addingDays(1)
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "old", title: "Old")]
        ))
        await service.setDay(DiaryDay(
            date: nextDay,
            logs: [DiaryLog(id: "new", title: "New")]
        ))
        var currentToday = today
        let vm = DiaryViewModel(
            service: service,
            today: today,
            todayProvider: { currentToday }
        )
        await vm.load()
        XCTAssertEqual(vm.logs.map(\.id), ["old"])

        currentToday = nextDay
        await vm.refreshToday()

        XCTAssertEqual(vm.today, nextDay)
        XCTAssertEqual(vm.selectedDate, nextDay)
        XCTAssertEqual(vm.logs.map(\.id), ["new"])
        XCTAssertFalse(vm.canGoNext)
        let calls = await service.allCalls()
        XCTAssertEqual(calls.last, nextDay)
    }

    func testForegroundRefreshRefetchesSameToday() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "one", title: "One")]
        ))
        let vm = DiaryViewModel(
            service: service,
            today: today,
            todayProvider: { self.today }
        )
        await vm.load()
        let callsBefore = await service.callCount(for: today)

        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "two", title: "Two")]
        ))
        await vm.refreshToday()

        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertEqual(vm.logs.map(\.id), ["two"])
        let callsAfter = await service.callCount(for: today)
        XCTAssertEqual(callsAfter, callsBefore + 1)
    }

    func testSavedOverrideSurvivesStaleRefetch() async {
        let service = FakeDiaryService()
        let old = DiaryLog(
            id: "log-1",
            title: "Oats",
            quantity: NutritionQuantity(amount: "150", unit: "g")
        )
        await service.setDay(DiaryDay(date: today, logs: [old]))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        XCTAssertEqual(vm.log(withID: "log-1")?.quantity?.amount, "150")

        let saved = DiaryLog(
            id: "log-1",
            mealSlot: .lunch,
            title: "Oats",
            quantity: NutritionQuantity(amount: "200", unit: "g"),
            notes: "saved"
        )
        vm.applySavedLog(saved, replacing: "log-1", on: today)
        XCTAssertEqual(vm.log(withID: "log-1")?.quantity?.amount, "200")

        // A refetch that still returns the pre-PUT row must not revert it.
        await vm.refresh()
        XCTAssertEqual(vm.log(withID: "log-1")?.quantity?.amount, "200")
        XCTAssertEqual(vm.log(withID: "log-1")?.notes, "saved")

        // Once the server catches up, the local override retires naturally.
        await service.setDay(DiaryDay(date: today, logs: [saved]))
        await vm.refresh()
        XCTAssertEqual(vm.log(withID: "log-1")?.quantity?.amount, "200")
    }

    func testDeletedLogTombstoneBlocksStaleRefetch() async {
        let service = FakeDiaryService()
        let old = DiaryLog(id: "log-1", title: "Oats")
        await service.setDay(DiaryDay(date: today, logs: [old]))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        XCTAssertEqual(vm.logs.map(\.id), ["log-1"])

        vm.applyDeletedLog(logID: "log-1", on: today)
        XCTAssertTrue(vm.logs.isEmpty)

        // An older in-flight GET can still contain the deleted row.
        await vm.refresh()
        XCTAssertTrue(
            vm.logs.isEmpty,
            "A stale refetch must not reopen a log after DELETE succeeded"
        )

        await service.setDay(DiaryDay(date: today, logs: []))
        await vm.refresh()
        XCTAssertTrue(vm.logs.isEmpty)
    }

    func testMidnightRolloverKeepsHistoricalSelection() async {
        let nextDay = today.addingDays(1)
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: yesterday,
            logs: [DiaryLog(id: "history", title: "History")]
        ))
        var currentToday = today
        let vm = DiaryViewModel(
            service: service,
            today: today,
            initialDate: yesterday,
            todayProvider: { currentToday }
        )
        await vm.load()
        let callsBeforeRollover = await service.allCalls()

        currentToday = nextDay
        await vm.refreshToday()

        XCTAssertEqual(vm.today, nextDay)
        XCTAssertEqual(vm.selectedDate, yesterday)
        XCTAssertEqual(vm.logs.map(\.id), ["history"])
        XCTAssertTrue(vm.canGoNext)
        let callsAfterRollover = await service.allCalls()
        XCTAssertEqual(callsAfterRollover, callsBeforeRollover)
    }

    func testGoalProgressIsSafeForZeroAndNonFiniteValues() {
        let zeroTarget = DiaryGoalProgress(current: 100, target: 0)
        XCTAssertNil(zeroTarget.targetText)
        XCTAssertNil(zeroTarget.fraction)
        XCTAssertEqual(zeroTarget.summary, "100")

        let nanTarget = DiaryGoalProgress(current: 100, target: .nan)
        XCTAssertNil(nanTarget.targetText)
        XCTAssertNil(nanTarget.fraction)
        XCTAssertEqual(nanTarget.summary, "100")

        let infiniteTarget = DiaryGoalProgress(current: 100, target: .infinity)
        XCTAssertNil(infiniteTarget.targetText)
        XCTAssertNil(infiniteTarget.fraction)
        XCTAssertEqual(infiniteTarget.summary, "100")

        let infiniteCurrent = DiaryGoalProgress(current: .infinity, target: 2000)
        XCTAssertEqual(infiniteCurrent.currentText, "—")
        XCTAssertNil(infiniteCurrent.fraction)

        let valid = DiaryGoalProgress(current: 500, target: 2000)
        XCTAssertEqual(valid.summary, "500 / 2000")
        XCTAssertEqual(valid.fraction, 0.25 as Double?)

        XCTAssertEqual(DiaryValueFormat.amount(.nan), "—")
        XCTAssertEqual(DiaryValueFormat.amount(0), "0")
    }

    func testDailyBriefRemainingUsesSignedExistingFormatter() {
        let under = DiaryGoalProgress(current: 1750, target: 2000)
        let met = DiaryGoalProgress(current: 2000, target: 2000)
        let over = DiaryGoalProgress(current: 2250, target: 2000)

        let remaining = { (progress: DiaryGoalProgress) in
            DiaryValueFormat.amount(progress.target - progress.current)
        }
        XCTAssertEqual(remaining(under), "250")
        XCTAssertEqual(remaining(met), "0")
        XCTAssertEqual(remaining(over), "-250")

        // The layout only changes the label; progress and target semantics
        // must stay exactly as they were for over-goal days.
        XCTAssertEqual(over.fraction, 1)
        XCTAssertEqual(over.targetText, "2000")
    }

    func testZeroGoalFromLoadedDayRendersSafely() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)],
            goal: DiaryGoalTargets(calorieTarget: 0)
        ))
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        XCTAssertEqual(vm.calorieProgress.summary, "100")
        XCTAssertNil(vm.calorieProgress.targetText)
        XCTAssertNil(vm.calorieProgress.fraction)
    }

    func testNavigationLoadsSelectedDates() async {
        let service = FakeDiaryService()
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        await vm.previousDay()
        XCTAssertEqual(vm.selectedDate, yesterday)
        XCTAssertTrue(vm.canGoNext)

        await vm.nextDay()
        XCTAssertEqual(vm.selectedDate, today)
        XCTAssertFalse(vm.canGoNext)

        let calls = await service.allCalls()
        XCTAssertEqual(calls, [today, yesterday, today])
    }

    func testDateNavigationNotifiesObserverForNavigationSync() async {
        let service = FakeDiaryService()
        var changedDates: [LocalDiaryDate] = []
        let vm = DiaryViewModel(
            service: service,
            today: today,
            onDateChange: { changedDates.append($0) }
        )
        await vm.load()

        await vm.previousDay()
        await vm.nextDay()

        XCTAssertEqual(changedDates, [yesterday, today])
    }

    func testNextDayNotAllowedOnToday() async {
        let service = FakeDiaryService()
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        let callsBefore = await service.allCalls()

        await vm.nextDay()

        XCTAssertEqual(vm.selectedDate, today)
        let callsAfter = await service.allCalls()
        XCTAssertEqual(callsAfter, callsBefore)
    }

    func testSelectFutureDateClampsToToday() async {
        let service = FakeDiaryService()
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        let callsBefore = await service.allCalls()

        await vm.selectDate(today.addingDays(1))

        XCTAssertEqual(vm.selectedDate, today)
        let callsAfter = await service.allCalls()
        XCTAssertEqual(callsAfter, callsBefore)
    }

    func testGroupedSectionsIncludesDisabledSlotWithLogs() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", mealSlot: .dinner, title: "Steak", calories: 500)],
            prefs: DiaryPrefs(enabledSlots: [.breakfast])
        ))
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        let ids = vm.groupedSections.map(\.id)
        XCTAssertTrue(ids.contains("dinner"))
        XCTAssertTrue(ids.contains("breakfast"))
    }

    func testEmptyStateLoadedWithNoLogs() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [],
            prefs: DiaryPrefs(enabledSlots: [])
        ))
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        XCTAssertEqual(vm.state, .loaded(.idle))
        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertTrue(vm.groupedSections.allSatisfy { $0.logs.isEmpty })
    }

    func testAddFoodCallback() async {
        let service = FakeDiaryService()
        var capturedSlot: MealSlot?
        var capturedDate: LocalDiaryDate?
        let vm = DiaryViewModel(
            service: service,
            today: today,
            onAddFood: { slot, date in
                capturedSlot = slot
                capturedDate = date
            }
        )
        await vm.load()

        vm.addFood(for: .lunch)

        XCTAssertEqual(capturedSlot, .lunch)
        XCTAssertEqual(capturedDate, today)
    }

    func testTotals() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [
                DiaryLog(
                    id: "1",
                    mealSlot: .breakfast,
                    title: "A",
                    calories: 100,
                    proteinG: 10,
                    carbsG: 20,
                    fatG: 5
                ),
                DiaryLog(
                    id: "2",
                    mealSlot: .lunch,
                    title: "B",
                    calories: 200,
                    proteinG: 20,
                    carbsG: 30,
                    fatG: 10
                ),
            ]
        ))
        let vm = DiaryViewModel(service: service, today: today)

        await vm.load()

        XCTAssertEqual(vm.totalCalories, 300)
        XCTAssertEqual(vm.totalProteinG, 30)
        XCTAssertEqual(vm.totalCarbsG, 50)
        XCTAssertEqual(vm.totalFatG, 15)
    }


    func testDisplayTitleIsLocalizedWeekdayDateAndKeepsISOContract() {
        let title = today.diaryDisplayTitle(locale: Locale(identifier: "en_US"))

        XCTAssertEqual(title, "Tuesday, November 17")
        XCTAssertEqual(today.formatted, "2026-11-17")
        XCTAssertNotEqual(title, today.formatted)
    }

    func testDisplayTitleLocalizesMonthAndWeekday() {
        let english = today.diaryDisplayTitle(locale: Locale(identifier: "en_US"))
        let french = today.diaryDisplayTitle(locale: Locale(identifier: "fr_FR"))

        XCTAssertNotEqual(english, french)
        XCTAssertTrue(french.contains("novembre"))
    }

    func testDisplayTitleFallsBackToISOForInvalidDate() {
        let invalid = LocalDiaryDate(year: 2026, month: 13, day: 1)
        XCTAssertEqual(invalid.diaryDisplayTitle(), invalid.formatted)
    }

    func testAddFoodAccessibilityLabelIsSlotSpecificAndLocalized() {
        for slot in MealSlot.allCases {
            let label = DiaryLabels.addFood(for: slot)
            XCTAssertTrue(label.contains(String(localized: "diary.addFood")))
            XCTAssertTrue(label.contains(DiaryLabels.mealSlotName(slot)))
        }

        let breakfast = DiaryLabels.addFood(for: .breakfast)
        let lunch = DiaryLabels.addFood(for: .lunch)
        XCTAssertNotEqual(breakfast, lunch)
        XCTAssertEqual(breakfast, "Add Food, Breakfast")
    }

    func testMealSlotNameUsesLocalizedCatalogValue() {
        XCTAssertEqual(
            DiaryLabels.mealSlotName(.breakfast),
            String(localized: "foodDetail.mealSlot.breakfast")
        )
        XCTAssertEqual(
            DiaryLabels.mealSlotName(.lateNightSnack),
            String(localized: "foodDetail.mealSlot.lateNightSnack")
        )
    }

    func testExpiredStateHasNoLoadedDataAndNoRefreshFlag() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)]
        ))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        await service.setError(.unauthorized)
        await vm.refresh()

        XCTAssertEqual(vm.state, .sessionExpired)
        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertEqual(vm.goal, DiaryGoalTargets())
        XCTAssertEqual(vm.enabledSlots, Set(MealSlot.allCases))
        XCTAssertTrue(vm.isSessionExpired)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.errorMessage, String(localized: "diary.error.sessionExpired"))
    }

    func testRefreshErrorKeepsLoadedDataAndIsDistinctFromPageFailure() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)]
        ))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        await service.setError(.server("boom"))
        await vm.refresh()

        XCTAssertEqual(vm.state, .loaded(.failed("boom")))
        XCTAssertEqual(vm.logs.map(\.id), ["1"])
        XCTAssertEqual(vm.errorMessage, "boom")
        XCTAssertFalse(vm.isSessionExpired)
        XCTAssertFalse(vm.isRefreshing)

        let freshService = FakeDiaryService()
        await freshService.setError(.server("boom"))
        let freshVM = DiaryViewModel(service: freshService, today: today)
        await freshVM.load()

        XCTAssertEqual(freshVM.state, .failed("boom"))
        XCTAssertTrue(freshVM.logs.isEmpty)
    }

    func testCancelDuringRefreshPreservesContentAndClearsRefreshing() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "1", title: "Eggs", calories: 100)]
        ))
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        await service.setDelay(10_000_000_000, for: today)
        let refreshTask = Task { @MainActor in
            await vm.refresh()
        }
        await service.waitForCallCount(today, atLeast: 2)
        refreshTask.cancel()
        await refreshTask.value

        XCTAssertEqual(vm.state, .loaded(.idle))
        XCTAssertEqual(vm.logs.map(\.id), ["1"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isRefreshing)
    }

    func testResetFromExpiredClearsExpiredFlagAndReturnsLoading() async {
        let service = FakeDiaryService()
        await service.setError(.unauthorized)
        let fixedToday = today
        let vm = DiaryViewModel(
            service: service,
            today: today,
            todayProvider: { fixedToday }
        )
        await vm.load()

        XCTAssertEqual(vm.state, .sessionExpired)
        XCTAssertTrue(vm.isSessionExpired)

        vm.resetForSessionChange()

        XCTAssertEqual(vm.state, .loading)
        XCTAssertFalse(vm.isSessionExpired)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.logs.isEmpty)
        XCTAssertEqual(vm.selectedDate, fixedToday)
    }

    // MARK: - Date-change transition regressions

    func testDateChangeUpdatesDateImmediatelyAndKeepsContentMounted() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "today-log", title: "Today", calories: 100)],
            goal: DiaryGoalTargets(calorieTarget: 500)
        ))
        await service.setDay(DiaryDay(
            date: yesterday,
            logs: [DiaryLog(id: "yesterday-log", title: "Yesterday", calories: 200)],
            goal: DiaryGoalTargets(calorieTarget: 800)
        ))
        await service.hold(yesterday)
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        XCTAssertEqual(vm.state, .loaded(.idle))

        let change = Task { @MainActor in await vm.selectDate(yesterday) }
        await service.waitForCall(yesterday)

        // The target date flips before the fetch resolves, and the loaded brief
        // and cards stay mounted instead of being replaced by a full-screen
        // skeleton (which used to collapse every meal group).
        XCTAssertEqual(vm.selectedDate, yesterday)
        XCTAssertTrue(vm.isChangingDate)
        guard case .loaded = vm.state else {
            return XCTFail("Date change must not swap loaded content for a skeleton")
        }
        XCTAssertEqual(vm.logs.map(\.id), ["today-log"])
        XCTAssertEqual(vm.goal.calorieTarget, 500)

        await service.release(yesterday)
        await change.value

        XCTAssertFalse(vm.isChangingDate)
        XCTAssertEqual(vm.state, .loaded(.idle))
        XCTAssertEqual(vm.logs.map(\.id), ["yesterday-log"])
        XCTAssertEqual(vm.goal.calorieTarget, 800)
    }

    func testOutOfOrderDateFetchesCannotOverwriteNewerSelection() async {
        let twoDaysAgo = yesterday.addingDays(-1)
        let service = FakeDiaryService()
        for (date, id) in [
            (today, "today-log"),
            (yesterday, "yesterday-log"),
            (twoDaysAgo, "two-days-ago-log")
        ] {
            await service.setDay(DiaryDay(date: date, logs: [DiaryLog(id: id, title: id)]))
        }
        await service.hold(yesterday)
        await service.hold(twoDaysAgo)
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        let older = Task { @MainActor in await vm.selectDate(yesterday) }
        await service.waitForCall(yesterday)
        let newer = Task { @MainActor in await vm.selectDate(twoDaysAgo) }
        await service.waitForCall(twoDaysAgo)

        // The older fetch resolves last; it must neither move the selected date
        // nor replace the newer day's rows, nor clear the newer busy indicator.
        await service.release(yesterday)
        await older.value
        XCTAssertEqual(vm.selectedDate, twoDaysAgo)
        XCTAssertEqual(vm.logs.map(\.id), ["today-log"])
        XCTAssertTrue(vm.isChangingDate)

        await service.release(twoDaysAgo)
        await newer.value
        XCTAssertEqual(vm.selectedDate, twoDaysAgo)
        XCTAssertEqual(vm.logs.map(\.id), ["two-days-ago-log"])
        XCTAssertFalse(vm.isChangingDate)
    }

    func testQuietRefreshDoesNotReportDateChangeLoading() async {
        let service = FakeDiaryService()
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()
        XCTAssertFalse(vm.isChangingDate)

        await service.hold(today)
        let refresh = Task { @MainActor in await vm.refresh() }
        await service.waitForCallCount(today, atLeast: 2)
        XCTAssertFalse(vm.isChangingDate)
        XCTAssertEqual(vm.selectedDate, today)

        await service.release(today)
        await refresh.value
        XCTAssertFalse(vm.isChangingDate)
    }

    func testStaleDayEntriesAreBlockedWhileDateChangeFetchPending() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "old-row", mealSlot: .breakfast, title: "Old row")]
        ))
        await service.setDay(DiaryDay(
            date: yesterday,
            logs: [DiaryLog(id: "new-row", mealSlot: .breakfast, title: "New row")]
        ))
        await service.hold(yesterday)

        var added: [(MealSlot, LocalDiaryDate)] = []
        var opened: [(String, LocalDiaryDate)] = []
        let vm = DiaryViewModel(
            service: service,
            today: today,
            onAddFood: { slot, date in added.append((slot, date)) },
            onOpenLogEditor: { id, date in opened.append((id, date)) },
            latestSubmissionHandler: { _, _, _, _ in }
        )
        await vm.load()
        XCTAssertTrue(vm.canLogLatest(for: .lunch))

        let change = Task { @MainActor in await vm.selectDate(yesterday) }
        await service.waitForCall(yesterday)

        // Old rows are still visible but `selectedDate` is already the new day.
        // Every date-scoped entry point must be blocked, including a direct
        // `prepareLatest` call (not just the button's eligibility).
        XCTAssertEqual(vm.selectedDate, yesterday)
        XCTAssertEqual(vm.logs.map(\.id), ["old-row"])
        XCTAssertTrue(vm.isChangingDate)
        XCTAssertFalse(vm.canLogLatest(for: .lunch))

        vm.addFood(for: .lunch)
        vm.openLogEditor(logID: "old-row")
        await vm.prepareLatest(for: .lunch)
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(vm.latestReview)
        XCTAssertNil(vm.latestLoadingSlot)

        await service.release(yesterday)
        await change.value

        // The same entries work again once the new day's content is installed.
        XCTAssertFalse(vm.isChangingDate)
        vm.addFood(for: .lunch)
        vm.openLogEditor(logID: "new-row")
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.1, yesterday)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "new-row")
        XCTAssertEqual(opened.first?.1, yesterday)
    }

    func testEditorSaveForRetainedDayDuringChangeStaysKeyedToItsOwnDate() async {
        let service = FakeDiaryService()
        await service.setDay(DiaryDay(
            date: today,
            logs: [DiaryLog(id: "old-row", mealSlot: .breakfast, title: "Old", calories: 100)]
        ))
        await service.setDay(DiaryDay(
            date: yesterday,
            logs: [DiaryLog(id: "new-row", mealSlot: .breakfast, title: "New", calories: 200)]
        ))
        await service.hold(yesterday)
        let vm = DiaryViewModel(service: service, today: today)
        await vm.load()

        let change = Task { @MainActor in await vm.selectDate(yesterday) }
        await service.waitForCall(yesterday)

        // An editor opened before the change can still return a save. It must
        // be stored under the date it was saved for, never applied to the
        // already-updated selectedDate, and must not cancel the pending load.
        let savedOld = DiaryLog(
            id: "old-row",
            mealSlot: .breakfast,
            title: "Old edited",
            calories: 150
        )
        vm.applySavedLog(savedOld, replacing: "old-row", on: today)
        XCTAssertEqual(vm.logs.map(\.id), ["old-row"])
        XCTAssertEqual(vm.logs.first?.title, "Old")

        await service.release(yesterday)
        await change.value
        XCTAssertEqual(vm.logs.map(\.id), ["new-row"])
    }

}
