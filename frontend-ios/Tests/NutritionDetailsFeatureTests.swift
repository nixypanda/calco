import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class NutritionDetailsFeatureTests: XCTestCase {
    private let requestID = UUID()
    private let generation = UInt64(42)
    private let staleRequestID = UUID()
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private let today = LocalDiaryDate(year: 2026, month: 11, day: 19)

    private var report: NutritionDetailsReport {
        NutritionDetailsReport(
            date: date,
            reference: NutritionDetailsReference(
                code: "REF",
                name: "Reference",
                authority: "Authority",
                jurisdiction: "US",
                populationLabel: "Adults",
                sourceURL: "https://example.com"
            ),
            loggedItems: 2,
            nutrients: []
        )
    }

    private var nutrientReport: NutritionDetailsReport {
        NutritionDetailsReport(
            date: date,
            reference: report.reference,
            loggedItems: 2,
            nutrients: [
                NutritionDetailsNutrient(
                    code: "ENERGY_KCAL",
                    name: "Energy",
                    section: .overview,
                    knownAmount: 100,
                    unit: "kcal",
                    referenceAmount: 200,
                    guidanceKind: .adequacy,
                    itemsWithData: 1,
                    coverage: .complete,
                    status: .belowReference
                )
            ]
        )
    }

    private func makeClient(
        fetch: @escaping @Sendable (LocalDiaryDate) async throws -> NutritionDetailsReport
    ) -> NutritionDetailsFeature.Client {
        NutritionDetailsFeature.Client(fetch: fetch)
    }

    func testLoadPublishesReport() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .idle(requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        await store.send(.load) {
            $0.phase = .loading(requestDate: date, requestID: requestID)
        }
        await store.receive(.reportReceived(requestDate: date, requestID: requestID, report: report)) {
            $0.phase = .loaded(report: report, requestDate: date)
            $0.expandedNutrientCodes = []
        }
    }

    func testRetryAfterFailure() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .failed(requestDate: date, message: "old", requestID: requestID)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        await store.send(.retry) {
            $0.phase = .loading(requestDate: date, requestID: requestID)
        }
        await store.receive(.reportReceived(requestDate: date, requestID: requestID, report: report)) {
            $0.phase = .loaded(report: report, requestDate: date)
            $0.expandedNutrientCodes = []
        }
    }

    func testUnauthorizedExpiresSession() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .idle(requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in
                throw NutritionDetailsServiceError.unauthorized
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.load) {
            $0.phase = .loading(requestDate: date, requestID: requestID)
        }
        await store.receive(.reportFailed(requestDate: date, requestID: requestID, failure: .unauthorized)) {
            $0.phase = .sessionExpired(requestDate: date)
            $0.expandedNutrientCodes = []
        }
        await store.receive(.delegate(.sessionExpired(selectedDate: date, generation: generation)))
    }

    func testCancelledLeavesLoadingAndAllowsRetry() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let report = self.report
        final class AttemptCounter: @unchecked Sendable {
            private var value = 0
            func next() -> Int {
                value += 1
                return value
            }
        }
        let attempts = AttemptCounter()
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .idle(requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in
                if attempts.next() == 1 {
                    throw NutritionDetailsServiceError.cancelled
                }
                return report
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.load) {
            $0.phase = .loading(requestDate: date, requestID: requestID)
        }
        await store.receive(.reportFailed(requestDate: date, requestID: requestID, failure: .cancelled))
        await store.send(.retry)
        await store.receive(.reportReceived(requestDate: date, requestID: requestID, report: report)) {
            $0.phase = .loaded(report: report, requestDate: date)
            $0.expandedNutrientCodes = []
        }
    }

    func testStaleReportIsIgnored() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .loading(requestDate: date, requestID: requestID)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        let otherDate = LocalDiaryDate(year: 2026, month: 11, day: 18)
        await store.send(.reportReceived(requestDate: otherDate, requestID: requestID, report: report))
        await store.send(.reportReceived(requestDate: date, requestID: staleRequestID, report: report))
    }

    func testWrongReportDateFails() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let wrongReport = NutritionDetailsReport(
            date: LocalDiaryDate(year: 2026, month: 11, day: 18),
            reference: report.reference,
            loggedItems: report.loggedItems,
            nutrients: report.nutrients
        )
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .idle(requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in wrongReport }
            $0.uuid = .constant(requestID)
        }

        await store.send(.load) {
            $0.phase = .loading(requestDate: date, requestID: requestID)
        }
        await store.receive(.reportReceived(requestDate: date, requestID: requestID, report: wrongReport)) {
            $0.phase = .failed(
                requestDate: date,
                message: NutritionDetailsCopy.invalidResponse,
                requestID: requestID
            )
        }
    }

    func testToggleGuidanceOnlyForLoadedNutrient() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .loaded(report: report, requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        await store.send(.toggleGuidance("ENERGY_KCAL"))
    }

    func testToggleGuidanceAddsAndRemovesCode() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .loaded(report: nutrientReport, requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in nutrientReport }
            $0.uuid = .constant(requestID)
        }

        await store.send(.toggleGuidance("ENERGY_KCAL")) {
            $0.expandedNutrientCodes = ["ENERGY_KCAL"]
        }
        await store.send(.toggleGuidance("ENERGY_KCAL")) {
            $0.expandedNutrientCodes = []
        }
    }

    func testPreviousDaySelectsPriorDate() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let previousDate = LocalDiaryDate(year: 2026, month: 11, day: 16)
        let previousReport = NutritionDetailsReport(
            date: previousDate,
            reference: report.reference,
            loggedItems: report.loggedItems,
            nutrients: report.nutrients
        )
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .idle(requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { requestedDate in
                NutritionDetailsReport(
                    date: requestedDate,
                    reference: report.reference,
                    loggedItems: report.loggedItems,
                    nutrients: report.nutrients
                )
            }
            $0.uuid = .constant(requestID)
        }

        await store.send(.previousDay)
        await store.receive(.selectDate(previousDate)) {
            $0.phase = .idle(requestDate: previousDate)
            $0.expandedNutrientCodes = []
        }
        await store.receive(.load) {
            $0.phase = .loading(requestDate: previousDate, requestID: requestID)
        }
        await store.receive(.reportReceived(requestDate: previousDate, requestID: requestID, report: previousReport)) {
            $0.phase = .loaded(report: previousReport, requestDate: previousDate)
            $0.expandedNutrientCodes = []
        }
    }

    func testTodayChangedUpdatesToday() async {
        let date = self.date
        let today = self.today
        let requestID = self.requestID
        let staleRequestID = self.staleRequestID
        let report = self.report
        let nutrientReport = self.nutrientReport
        let store = TestStore(
            initialState: NutritionDetailsFeature.State(
                today: today,
                phase: .idle(requestDate: date)
            ,
                sessionGeneration: generation
            )
        ) {
            NutritionDetailsFeature()
        } withDependencies: {
            $0.nutritionDetailsClient = makeClient { _ in report }
            $0.uuid = .constant(requestID)
        }

        let newToday = LocalDiaryDate(year: 2026, month: 11, day: 20)
        await store.send(.todayChanged(newToday)) {
            $0.today = newToday
        }
    }
}
