import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class DiaryMutationNoticeFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
    private let generation = UInt64(42)

    private let notice = DiaryMutationNotice(kind: .saved, title: "Saved")
    private let replacementNotice = DiaryMutationNotice(kind: .deleted, title: "Deleted", blockedPendingCount: 2)

    private nonisolated func makeDay(_ d: LocalDiaryDate, calories: Double = 100) -> DiaryDay {
        DiaryDay(
            date: d,
            logs: [
                DiaryLog(id: "log-\(d.formatted)", title: "Lunch", calories: calories)
            ],
            goal: DiaryGoalTargets(calorieTarget: 2000, proteinTargetG: 150, carbsTargetG: 200, fatTargetG: 70),
            prefs: DiaryPrefs()
        )
    }

    private func issueToken(for key: LocalDiaryDate) -> (DiaryFeature.Cache, DiaryFeature.Token) {
        var cache = DiaryFeature.Cache()
        let (inFlight, token) = cache.request(key)!
        return (inFlight, token)
    }

    private func inFlightCache(for key: LocalDiaryDate) -> DiaryFeature.Cache {
        var cache = DiaryFeature.Cache()
        let (inFlight, _) = cache.request(key)!
        return inFlight
    }

    func testShowMutationNoticeInstallsAndReplaces() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, _) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: nil
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.showMutationNotice(generation: generation, date: date, notice: notice)) {
            $0.mutationNotice = self.notice
        }
        await store.send(.showMutationNotice(generation: generation, date: date, notice: replacementNotice)) {
            $0.mutationNotice = self.replacementNotice
        }
    }

    func testShowMutationNoticeIgnoresStaleGeneration() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, _) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.showMutationNotice(generation: generation - 1, date: date, notice: replacementNotice))
        XCTAssertEqual(store.state.mutationNotice, notice)
    }

    func testShowMutationNoticeIgnoresWrongDate() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, _) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.showMutationNotice(generation: generation, date: otherDate, notice: replacementNotice))
        XCTAssertEqual(store.state.mutationNotice, notice)
    }

    func testShowMutationNoticeIgnoresSessionExpired() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let state = DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: date),
            sessionGeneration: generation,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.showMutationNotice(generation: generation, date: date, notice: replacementNotice))
        XCTAssertEqual(store.state.mutationNotice, notice)
        XCTAssertTrue(store.state.isSessionExpired)
    }

    func testClearMutationNoticeManualAndIdempotent() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, _) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.clearMutationNotice) {
            $0.mutationNotice = nil
        }
        await store.send(.clearMutationNotice)
        XCTAssertNil(store.state.mutationNotice)
    }

    func testSelectDateActualChangeClearsMutationNotice() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation

        let initialCache = DiaryFeature.Cache()
        var expectedCache = initialCache
        let (expectedInFlight, token) = expectedCache.request(otherDate)!
        expectedCache = expectedInFlight

        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: initialCache,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(otherDate) })
        }

        await store.send(.selectDate(otherDate)) {
            $0.phase = .loaded(day: self.makeDay(date), activity: .changingDate(from: date, requestDate: otherDate, token: token))
            $0.cache = expectedCache
            $0.mutationNotice = nil
        }
        XCTAssertEqual(store.state.selectedDate, otherDate)

        let settledCache = expectedCache.settling(otherDate, token: token, result: .success(makeDay(otherDate)))!
        await store.receive(.diaryReceived(generation: generation, requestDate: otherDate, token: token, day: makeDay(otherDate))) {
            $0.completedFetchCount += 1
            $0.phase = .loaded(day: self.makeDay(otherDate), activity: .settled)
            $0.cache = settledCache
        }
        XCTAssertEqual(store.state.selectedDate, otherDate)
        XCTAssertNil(store.state.mutationNotice)
    }

    func testSelectDateSameDatePreservesMutationNotice() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, _) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.selectDate(date))
        XCTAssertEqual(store.state.mutationNotice, notice)
    }

    func testSelectDateClampedSamePreservesMutationNotice() async {
        let today = self.today
        let generation = self.generation
        let (inFlight, _) = issueToken(for: today)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(today), activity: .settled),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(today) })
        }

        await store.send(.selectDate(today.addingDays(1)))
        XCTAssertEqual(store.state.mutationNotice, notice)
        XCTAssertEqual(store.state.selectedDate, today)
    }

    func testRefreshPreservesMutationNotice() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let targetCache = inFlightCache(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: targetCache,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.refresh)
        XCTAssertEqual(store.state.mutationNotice, notice)
    }

    func testRetryPreservesMutationNotice() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let targetCache = inFlightCache(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: targetCache,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        await store.send(.retry)
        XCTAssertEqual(store.state.mutationNotice, notice)
    }

    func testWrongDayCompletionPreservesMutationNotice() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let day = makeDay(date)
        let wrongDay = makeDay(otherDate)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .refreshing(requestDate: date, token: token)),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in self.makeDay(date) })
        }

        let wrongDayCache = inFlight.settling(date, token: token, result: .failure(.server("")))!
        await store.send(.diaryReceived(generation: generation, requestDate: date, token: token, day: wrongDay)) {
            $0.phase = .loaded(day: day, activity: .failure(requestDate: date, token: token, message: String(localized: "diary.error.generic")))
            $0.cache = wrongDayCache
        }
        XCTAssertEqual(store.state.mutationNotice, notice)
    }

    func testUnauthorizedValidClearsMutationNotice() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in throw DiaryServiceError.unauthorized })
        }

        let resetCache = inFlight.reset()
        await store.send(.diaryFailed(generation: generation, requestDate: date, token: token, error: .unauthorized)) {
            $0.phase = .sessionExpired(requestDate: date)
            $0.cache = resetCache
            $0.mutationNotice = nil
        }
        await store.receive(.delegate(.sessionExpired(selectedDate: date, generation: generation)))
        XCTAssertTrue(store.state.isSessionExpired)
        XCTAssertNil(store.state.mutationNotice)
    }

    func testUnauthorizedStaleAndWrongDayDoNotClear() async {
        let date = self.date
        let today = self.today
        let generation = self.generation
        let (inFlight, token) = issueToken(for: date)
        let state = DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: inFlight,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in throw DiaryServiceError.unauthorized })
        }

        await store.send(.diaryFailed(generation: generation - 1, requestDate: date, token: token, error: .unauthorized))
        XCTAssertEqual(store.state.mutationNotice, notice)
        XCTAssertFalse(store.state.isSessionExpired)

        await store.send(.diaryFailed(generation: generation, requestDate: otherDate, token: token, error: .unauthorized))
        XCTAssertEqual(store.state.mutationNotice, notice)
        XCTAssertFalse(store.state.isSessionExpired)
    }

    func testLocalMutationsPreserveMutationNotice() async {
        let date = self.date
        let otherDate = self.otherDate
        let today = self.today
        let generation = self.generation
        let day = makeDay(date)
        let cache = DiaryFeature.Cache().seed(date, value: day)
        let state = DiaryFeature.State(
            today: today,
            phase: .loaded(day: day, activity: .settled),
            sessionGeneration: generation,
            cache: cache,
            mutationNotice: notice
        )
        let store = TestStore(initialState: state) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in day })
        }

        let savedLog = DiaryLog(id: "saved", title: "Saved")
        await store.send(.applySavedLog(generation: generation, log: savedLog, replacingID: "missing", onDate: otherDate)) {
            $0.savedLogOverrides = [otherDate: [savedLog.id: savedLog]]
        }
        XCTAssertEqual(store.state.mutationNotice, notice)

        await store.send(.applyDeletedLog(generation: generation, id: "deleted", onDate: otherDate)) {
            $0.deletedIDs = [otherDate: ["deleted"]]
        }
        XCTAssertEqual(store.state.mutationNotice, notice)

        let savedGoal = DiaryGoalTargets(calorieTarget: 2200)
        await store.send(.applySavedGoal(generation: generation, targets: savedGoal, effectiveDate: date)) {
            $0.phase = .loaded(day: DiaryDay(date: date, logs: day.logs, goal: savedGoal, prefs: day.prefs), activity: .settled)
        }
        XCTAssertEqual(store.state.mutationNotice, notice)

        let savedPrefs = DiaryPrefs(enabledSlots: [.dinner])
        await store.send(.applySavedPreferences(generation: generation, prefs: savedPrefs)) {
            $0.phase = .loaded(day: DiaryDay(date: date, logs: day.logs, goal: savedGoal, prefs: savedPrefs), activity: .settled)
        }
        XCTAssertEqual(store.state.mutationNotice, notice)
    }
}
