import ComposableArchitecture
import XCTest

@testable import CalCo

/// Direct behavioural coverage for the one conditional child action added for
/// the vertical slice. Each expected state derives from the SAME cache value
/// used as the initial state, so opaque `ResourceCache` identity never causes
/// a false equality failure. No service call or effect is permitted.
@MainActor
final class DiaryCacheInvalidationFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 15)
    private let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 16)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)
    private let generation: UInt64 = 42

    private func makeDay(_ day: LocalDiaryDate) -> DiaryDay {
        DiaryDay(date: day, logs: [makeLog()])
    }

    private func makeLog() -> DiaryLog {
        DiaryLog(id: "log-a", mealSlot: .breakfast, title: "Apple", calories: 100)
    }

    private func makeStore(
        initialState: DiaryFeature.State
    ) -> TestStore<DiaryFeature.State, DiaryFeature.Action> {
        TestStore(initialState: initialState) {
            DiaryFeature()
        } withDependencies: {
            $0.diaryClient = DiaryFeature.Client(fetchDay: { _, _ in
                XCTFail("invalidateCachedDay must never call the service")
                throw DiaryServiceError.unknown
            })
        }
    }

    func testCurrentGenerationInvalidatesOnlyTargetAndPreservesEverythingElse() async {
        let date = self.date
        let targetDay = makeDay(date)
        let otherDay = makeDay(otherDate)
        var cache = DiaryFeature.Cache()
        cache = cache.seed(date, value: targetDay)
        cache = cache.seed(otherDate, value: otherDay)
        let overrides: [LocalDiaryDate: [String: DiaryLog]] = [
            date: [makeLog().id: makeLog()],
            otherDate: [makeLog().id: makeLog()],
        ]
        let store = makeStore(initialState: DiaryFeature.State(
            today: today,
            phase: .loaded(day: targetDay, activity: .settled),
            sessionGeneration: generation,
            cache: cache,
            savedLogOverrides: overrides
        ))

        await store.send(.invalidateCachedDay(generation: generation, date: date)) {
            // Same cache identity as the initial value: only the target key is
            // made requestable; the other settled entry and generation remain.
            $0.cache = cache.invalidate(date)
        }
        await store.finish()

        XCTAssertEqual(store.state.cache.generation, cache.generation)
        if case .settled(.success(let retained)) = store.state.cache.entry(for: otherDate) {
            XCTAssertEqual(retained, otherDay)
        } else {
            XCTFail("The other cached date was not preserved")
        }
        XCTAssertEqual(store.state.phase, .loaded(day: targetDay, activity: .settled))
        XCTAssertEqual(store.state.completedFetchCount, 0)
        XCTAssertEqual(store.state.savedLogOverrides, overrides)
    }

    func testStaleGenerationInvalidationIsNoop() async {
        var cache = DiaryFeature.Cache()
        cache = cache.seed(date, value: makeDay(date))
        let store = makeStore(initialState: DiaryFeature.State(
            today: today,
            phase: .loaded(day: makeDay(date), activity: .settled),
            sessionGeneration: generation,
            cache: cache
        ))

        await store.send(.invalidateCachedDay(generation: generation + 1, date: date))
        await store.finish()

        XCTAssertEqual(store.state.cache, cache)
    }

    func testExpiredSessionInvalidationIsNoop() async {
        var cache = DiaryFeature.Cache()
        cache = cache.seed(date, value: makeDay(date))
        let store = makeStore(initialState: DiaryFeature.State(
            today: today,
            phase: .sessionExpired(requestDate: date),
            sessionGeneration: generation,
            cache: cache
        ))

        await store.send(.invalidateCachedDay(generation: generation, date: date))
        await store.finish()

        XCTAssertEqual(store.state.cache, cache)
    }

    /// A completion captured before invalidation must not settle through the
    /// retired token: both success and cancelled completions are no-ops and no
    /// read is counted.
    func testOldTokenCompletionsAfterInvalidationAreRejected() async {
        let date = self.date
        var cache = DiaryFeature.Cache()
        let (inFlight, token) = cache.request(date)!
        cache = inFlight.seed(otherDate, value: makeDay(otherDate))
        let store = makeStore(initialState: DiaryFeature.State(
            today: today,
            phase: .initialLoading(requestDate: date, token: token),
            sessionGeneration: generation,
            cache: cache
        ))

        await store.send(.invalidateCachedDay(generation: generation, date: date)) {
            $0.cache = cache.invalidate(date)
        }
        await store.send(.diaryReceived(
            generation: generation,
            requestDate: date,
            token: token,
            day: makeDay(date)
        ))
        await store.send(.diaryFailed(
            generation: generation,
            requestDate: date,
            token: token,
            error: .cancelled
        ))
        await store.finish()

        XCTAssertEqual(store.state.completedFetchCount, 0)
        XCTAssertEqual(store.state.phase, .initialLoading(requestDate: date, token: token))
        if case .notRequested = store.state.cache.entry(for: date) {
            // retained invalidation
        } else {
            XCTFail("A stale completion re-seeded the invalidated entry")
        }
    }
}
