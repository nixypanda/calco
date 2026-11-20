import Foundation
import XCTest

@testable import CalCo

private final class EditorFailingSavePersistence: LogSubmissionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let base: FileLogSubmissionPersistence
    private var shouldFail = false

    init(base: FileLogSubmissionPersistence) {
        self.base = base
    }

    func setShouldFail(_ value: Bool) {
        lock.withLock { shouldFail = value }
    }

    func load(accountID: String) throws -> Data? {
        try base.load(accountID: accountID)
    }

    func save(_ data: Data, accountID: String) throws {
        if lock.withLock({ shouldFail }) {
            throw CocoaError(.fileWriteUnknown)
        }
        try base.save(data, accountID: accountID)
    }

    func quarantine(accountID: String, reason: String) {
        base.quarantine(accountID: accountID, reason: reason)
    }
}

private final class EditorUnreadableJournalPersistence: LogSubmissionPersisting,
    @unchecked Sendable
{
    func load(accountID: String) throws -> Data? {
        throw CocoaError(.fileReadCorruptFile)
    }

    func save(_ data: Data, accountID: String) throws {}

    func quarantine(accountID: String, reason: String) {}
}

@MainActor
final class DiaryLogEditorTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 17)
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calco-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeLog() -> DiaryLog {
        DiaryLog(
            id: "log-1",
            mealSlot: .breakfast,
            title: "Oats",
            calories: 300,
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: "with milk",
            brand: "Farm"
        )
    }

    private func makeProductLog(foodID: String = "food-1") -> DiaryLog {
        DiaryLog(
            id: "log-1",
            mealSlot: .breakfast,
            title: "Oats",
            calories: 300,
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: "with milk",
            brand: "Farm",
            itemReference: ItemReference(itemType: .product, id: foodID)
        )
    }

    private func makePreparedSubmission(
        foodID: String = "food-1",
        key: String = "11111111-1111-1111-1111-111111111111"
    ) throws -> (draft: LogSubmissionDraft, request: FoodLogCreateRequest, body: Data) {
        try LogCreateRequestBuilder.prepare(
            foodID: foodID,
            foodName: "Oats",
            date: date,
            mealSlot: .breakfast,
            amount: "150",
            unit: "g",
            notes: "with milk",
            timeZoneIdentifier: "Asia/Kolkata",
            baseURL: URL(string: "https://calco.example.com")!,
            idempotencyKey: key
        )
    }

    private func seedSubmission(
        in store: LogSubmissionStore,
        accountID: String,
        foodID: String = "food-1"
    ) throws -> PendingLogSubmission {
        let prepared = try makePreparedSubmission(
            foodID: foodID,
            key: UUID().uuidString.lowercased()
        )
        let entry = try store.reserve(
            accountID: accountID,
            foodName: "Oats",
            draft: prepared.draft,
            request: prepared.request,
            body: prepared.body,
            capabilityVersion: 2
        )
        try store.markUncertain(
            id: entry.id,
            accountID: accountID,
            status: nil,
            message: "offline"
        )
        return try XCTUnwrap(store.entry(id: entry.id, accountID: accountID))
    }

    private actor FakeEditorService: DiaryServicing {
        var updateError: DiaryServiceError?
        var deleteError: DiaryServiceError?
        var unitsError: DiaryServiceError?
        var units: [FoodUnit] = []
        var updateRequests: [UpdateLogRequest] = []
        var deletedIDs: [String] = []
        var log: DiaryLog
        private var holdsNextDelete = false
        private var deleteStarted = false
        private var deleteReleased = false
        private var deleteContinuation: CheckedContinuation<Void, Never>?

        init(log: DiaryLog) { self.log = log }

        func setUpdateError(_ error: DiaryServiceError?) { updateError = error }
        func setDeleteError(_ error: DiaryServiceError?) { deleteError = error }
        func setUnitsError(_ error: DiaryServiceError?) { unitsError = error }
        func setUnits(_ units: [FoodUnit]) { self.units = units }
        func setLog(_ log: DiaryLog) { self.log = log }
        func requests() -> [UpdateLogRequest] { updateRequests }
        func deletions() -> [String] { deletedIDs }

        func holdNextDelete() {
            holdsNextDelete = true
            deleteStarted = false
            deleteReleased = false
        }

        func waitForDeleteStart() async {
            let deadline = Date().addingTimeInterval(5)
            while !deleteStarted, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(deleteStarted, "Timed out waiting for the delete request")
        }

        func releaseDelete() {
            deleteReleased = true
            deleteContinuation?.resume()
            deleteContinuation = nil
        }

        func fetchDiary(for date: LocalDiaryDate) async throws -> DiaryDay {
            DiaryDay(date: date)
        }

        func getLog(id: String) async throws -> DiaryLog { log }

        func fetchUnits() async throws -> [FoodUnit] {
            if let unitsError { throw unitsError }
            return units
        }

        func updateLog(id: String, request: UpdateLogRequest) async throws -> DiaryLog {
            updateRequests.append(request)
            if let updateError { throw updateError }
            return log
        }

        func deleteLog(id: String) async throws {
            deletedIDs.append(id)
            if holdsNextDelete {
                holdsNextDelete = false
                deleteStarted = true
                await withCheckedContinuation { continuation in
                    if deleteReleased {
                        continuation.resume()
                    } else {
                        deleteContinuation = continuation
                    }
                }
            }
            if let deleteError { throw deleteError }
        }
    }

    func testEditorIsSeededFromLogWithSensibleUnitFallback() {
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: FakeEditorService(log: makeLog()))

        XCTAssertEqual(vm.logID, "log-1")
        XCTAssertEqual(vm.date, date)
        XCTAssertEqual(vm.title, "Oats")
        XCTAssertEqual(vm.subtitle, "Farm")
        XCTAssertEqual(vm.amount, "150")
        XCTAssertEqual(vm.unit, "g")
        XCTAssertEqual(vm.mealSlot, .breakfast)
        XCTAssertEqual(vm.notes, "with milk")
        XCTAssertEqual(vm.state, .editing)
        XCTAssertTrue(vm.units.contains { $0.code == "g" })
    }

    func testDirtyTrackingUsesInitialValuesAndRetainsProductIdentity() {
        let log = DiaryLog(
            id: "log-1",
            mealSlot: .breakfast,
            title: "Oats",
            quantity: NutritionQuantity(amount: "150", unit: "g"),
            notes: "with milk",
            itemReference: ItemReference(itemType: .product, id: "food-1")
        )
        let vm = LogEditorViewModel(log: log, date: date, service: FakeEditorService(log: log))

        XCTAssertEqual(vm.productID, "food-1")
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.amount = "160"
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.amount = "150"
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.notes = ""
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.notes = "with milk"
        XCTAssertFalse(vm.hasUnsavedChanges)

        vm.mealSlot = .lunch
        XCTAssertTrue(vm.hasUnsavedChanges)
        vm.mealSlot = .breakfast
        XCTAssertFalse(vm.hasUnsavedChanges)
    }

    func testSaveRetainsAuthoritativeResponseForDiaryApply() async {
        let service = FakeEditorService(log: makeLog())
        let updated = DiaryLog(
            id: "log-1",
            mealSlot: .lunch,
            title: "Oats",
            calories: 400,
            quantity: NutritionQuantity(amount: "200", unit: "g"),
            notes: "after workout"
        )
        await service.setLog(updated)
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)

        await vm.save()

        XCTAssertEqual(vm.state, .saved)
        XCTAssertEqual(vm.lastSavedLog, updated)
    }

    func testDeleteConfirmationWarnsWhenPendingAttemptMatches() {
        let service = FakeEditorService(log: makeLog())
        let clean = LogEditorViewModel(
            log: makeLog(),
            date: date,
            service: service,
            matchingPendingCount: { 0 }
        )
        XCTAssertEqual(
            clean.deleteConfirmationMessage,
            String(localized: "diary.editor.delete.confirm")
        )

        let risky = LogEditorViewModel(
            log: makeLog(),
            date: date,
            service: service,
            matchingPendingCount: { 1 }
        )
        XCTAssertEqual(
            risky.deleteConfirmationMessage,
            String(localized: "diary.editor.delete.confirmWithPending")
        )
    }

    func testSaveClearsMealAndNotesWithExplicitRequestsAndNotifiesOnce() async {
        let service = FakeEditorService(log: makeLog())
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        vm.mealSlot = nil
        vm.notes = ""

        var savedDates: [LocalDiaryDate] = []
        vm.onSaved = { savedDates.append($0) }
        await vm.save()

        XCTAssertEqual(vm.state, .saved)
        XCTAssertEqual(savedDates, [date])
        let requests = await service.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.mealSlot, .null)
        XCTAssertEqual(requests.first?.notes, .null)
        XCTAssertEqual(
            requests.first?.quantity,
            NutritionQuantity(amount: "150", unit: "g")
        )

        // A second call cannot trigger a duplicate success notification.
        await vm.save()
        XCTAssertEqual(savedDates, [date])
    }

    func testSaveKeepsNonNullMealAndNotes() async {
        let service = FakeEditorService(log: makeLog())
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        vm.amount = "2"
        vm.unit = "serving"
        vm.mealSlot = .lunch
        vm.notes = "after workout"

        await vm.save()

        let requests = await service.requests()
        XCTAssertEqual(requests.first?.mealSlot, .value(.lunch))
        XCTAssertEqual(requests.first?.notes, .value("after workout"))
        XCTAssertEqual(
            requests.first?.quantity,
            NutritionQuantity(amount: "2", unit: "serving")
        )
    }

    func testSaveTrimsNotesAndClearsWhitespaceOnlyNotes() async {
        let service = FakeEditorService(log: makeLog())

        let trimmed = LogEditorViewModel(log: makeLog(), date: date, service: service)
        trimmed.notes = "  with milk \n "
        await trimmed.save()

        let cleared = LogEditorViewModel(log: makeLog(), date: date, service: service)
        cleared.notes = "   \n\t  "
        await cleared.save()

        let requests = await service.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.notes, .value("with milk"))
        XCTAssertEqual(requests.last?.notes, .null)
    }

    func testInvalidAmountBlocksSaveWithValidationMessage() async {
        let service = FakeEditorService(log: makeLog())
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        vm.amount = "0"

        XCTAssertEqual(vm.validationMessage, validateLogAmount("0")?.message)
        await vm.save()

        let requests = await service.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(vm.state, .editing)
    }

    func testSaveFailureIsExplicitRetryableAndDoesNotNotify() async {
        let service = FakeEditorService(log: makeLog())
        await service.setUpdateError(.server("Could not save."))
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        var calls = 0
        vm.onSaved = { _ in calls += 1 }

        await vm.save()

        XCTAssertEqual(vm.state, .failed("Could not save."))
        XCTAssertEqual(vm.errorMessage, "Could not save.")
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(vm.canEdit)

        vm.retry()
        XCTAssertEqual(vm.state, .editing)
    }

    func testNetworkSaveFailureUsesLocalizedNetworkMessage() async {
        let service = FakeEditorService(log: makeLog())
        await service.setUpdateError(.networkUnavailable)
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)

        await vm.save()

        XCTAssertEqual(vm.state, .failed(String(localized: "diary.error.network")))
    }

    func testUnauthorizedSaveMarksSessionExpiredAndNotifiesOnce() async {
        let service = FakeEditorService(log: makeLog())
        await service.setUpdateError(.unauthorized)
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        var expirations = 0
        vm.onSessionExpired = { expirations += 1 }

        await vm.save()
        XCTAssertEqual(vm.state, .sessionExpired)
        XCTAssertEqual(vm.errorMessage, String(localized: "diary.error.sessionExpired"))
        XCTAssertEqual(expirations, 1)
        XCTAssertFalse(vm.canEdit)

        await vm.save()
        XCTAssertEqual(expirations, 1)
    }

    func testUnauthorizedDeleteAlsoExpiresSession() async {
        let service = FakeEditorService(log: makeLog())
        await service.setDeleteError(.unauthorized)
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        var expirations = 0
        vm.onSessionExpired = { expirations += 1 }

        vm.requestDelete()
        XCTAssertTrue(vm.isDeleteConfirmationPresented)
        await vm.delete()

        XCTAssertEqual(vm.state, .sessionExpired)
        XCTAssertFalse(vm.isDeleteConfirmationPresented)
        XCTAssertEqual(expirations, 1)
    }

    func testDeleteRequiresConfirmationAndNotifiesOnce() async {
        let service = FakeEditorService(log: makeLog())
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)
        var deletedDates: [LocalDiaryDate] = []
        vm.onDeleted = { deletedDates.append($0) }

        vm.requestDelete()
        vm.cancelDelete()
        let deletionsBefore = await service.deletions()
        XCTAssertFalse(vm.isDeleteConfirmationPresented)
        XCTAssertTrue(deletionsBefore.isEmpty)

        vm.requestDelete()
        await vm.delete()

        let deletions = await service.deletions()
        XCTAssertEqual(vm.state, .deleted)
        XCTAssertEqual(deletedDates, [date])
        XCTAssertEqual(deletions, ["log-1"])
    }

    func testDeleteFailureSurfacesMessageAndKeepsData() async {
        let service = FakeEditorService(log: makeLog())
        await service.setDeleteError(.server("Delete blocked."))
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)

        await vm.delete()

        XCTAssertEqual(vm.state, .failed("Delete blocked."))
        XCTAssertEqual(vm.amount, "150")
        XCTAssertEqual(vm.notes, "with milk")
        XCTAssertTrue(vm.canEdit)
    }

    func testCancelDeleteConfirmationDoesNotInvalidateJournal() async throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let entry = try seedSubmission(in: store, accountID: "account-a")
        let service = FakeEditorService(log: makeProductLog())
        let vm = LogEditorViewModel(
            log: makeProductLog(),
            date: date,
            service: service,
            accountID: "account-a",
            submissionStore: store
        )

        vm.requestDelete()
        XCTAssertTrue(vm.isDeleteConfirmationPresented)
        vm.cancelDelete()
        XCTAssertFalse(vm.isDeleteConfirmationPresented)

        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: "account-a"))
        XCTAssertEqual(stored.state, .uncertain)
        XCTAssertNotNil(stored.body)
        XCTAssertFalse(store.isRetryBlocked(id: entry.id))
        let deletions = await service.deletions()
        XCTAssertTrue(deletions.isEmpty)
    }

    func testDeletePersistenceFailurePreventsBackendDeleteAndSurvivesRelaunch() async throws {
        let base = FileLogSubmissionPersistence(directoryURL: directory)
        let persistence = EditorFailingSavePersistence(base: base)
        let store = LogSubmissionStore(persistence: persistence)
        let entry = try seedSubmission(in: store, accountID: "account-a")
        persistence.setShouldFail(true)
        let service = FakeEditorService(log: makeProductLog())
        let vm = LogEditorViewModel(
            log: makeProductLog(),
            date: date,
            service: service,
            accountID: "account-a",
            submissionStore: store
        )

        await vm.delete()

        XCTAssertEqual(
            vm.state,
            .failed(String(localized: "diary.editor.delete.persistenceFailed"))
        )
        XCTAssertFalse(vm.isTerminal)
        XCTAssertTrue(vm.canEdit)
        let deletions = await service.deletions()
        XCTAssertTrue(deletions.isEmpty, "An unpersisted barrier must prevent DELETE")

        persistence.setShouldFail(false)
        let reloaded = LogSubmissionStore(persistence: base)
        let restored = try XCTUnwrap(
            reloaded.entry(id: entry.id, accountID: "account-a")
        )
        XCTAssertEqual(restored.state, .uncertain)
        XCTAssertNotNil(restored.body)
        XCTAssertFalse(reloaded.isRetryBlocked(id: entry.id))

        // A transient write failure leaves the user in control: retrying the
        // delete must persist the barrier and only then send DELETE.
        vm.retry()
        await vm.delete()
        XCTAssertEqual(vm.state, .deleted)
        let retriedDeletions = await service.deletions()
        XCTAssertEqual(retriedDeletions, ["log-1"])
        let afterRetry = LogSubmissionStore(persistence: base)
        XCTAssertEqual(
            afterRetry.entry(id: entry.id, accountID: "account-a")?.state,
            .invalidated
        )
    }

    func testDeleteWithUnreadableJournalPreventsBackendDelete() async {
        let store = LogSubmissionStore(
            persistence: EditorUnreadableJournalPersistence()
        )
        let service = FakeEditorService(log: makeProductLog())
        let vm = LogEditorViewModel(
            log: makeProductLog(),
            date: date,
            service: service,
            accountID: "account-a",
            submissionStore: store
        )

        await vm.delete()

        XCTAssertEqual(
            vm.state,
            .failed(String(localized: "diary.editor.delete.journalUnavailable"))
        )
        XCTAssertFalse(vm.isTerminal)
        let deletions = await service.deletions()
        XCTAssertTrue(deletions.isEmpty)
    }

    func testDeleteIsBlockedWhileMatchingSubmissionIsLive() async throws {
        let store = LogSubmissionStore(
            persistence: FileLogSubmissionPersistence(directoryURL: directory)
        )
        let entry = try seedSubmission(in: store, accountID: "account-a")
        try store.markInFlight(id: entry.id, accountID: "account-a")
        let service = FakeEditorService(log: makeProductLog())
        let vm = LogEditorViewModel(
            log: makeProductLog(),
            date: date,
            service: service,
            accountID: "account-a",
            submissionStore: store
        )

        await vm.delete()

        XCTAssertEqual(
            vm.state,
            .failed(String(localized: "diary.editor.delete.liveSubmission"))
        )
        let deletions = await service.deletions()
        XCTAssertTrue(deletions.isEmpty, "A live POST must resolve before DELETE")
        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: "account-a"))
        XCTAssertEqual(stored.state, .inFlight)
        XCTAssertNotNil(stored.body)
        XCTAssertFalse(store.isRetryBlocked(id: entry.id))

        // Once the held POST resolves ambivalently, the user can retry the
        // delete and the durable barrier is applied before DELETE is sent.
        try store.markUncertain(
            id: entry.id,
            accountID: "account-a",
            status: nil,
            message: "timeout"
        )
        vm.retry()
        await vm.delete()
        XCTAssertEqual(vm.state, .deleted)
        let finalDeletions = await service.deletions()
        XCTAssertEqual(finalDeletions, ["log-1"])
        XCTAssertEqual(
            store.entry(id: entry.id, accountID: "account-a")?.state,
            .invalidated
        )
    }

    func testDeleteBarrierIsDurableBeforeBackendDeleteAndPreservesOtherEntries() async throws {
        let base = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: base)
        let matching = try seedSubmission(in: store, accountID: "account-a", foodID: "food-1")
        let unrelated = try seedSubmission(in: store, accountID: "account-a", foodID: "food-2")
        let service = FakeEditorService(log: makeProductLog())
        let vm = LogEditorViewModel(
            log: makeProductLog(),
            date: date,
            service: service,
            accountID: "account-a",
            submissionStore: store
        )

        await service.holdNextDelete()
        let deletion = Task { await vm.delete() }
        await service.waitForDeleteStart()

        // The backend DELETE has been entered, so the journal barrier must
        // already be readable from a fresh store instance.
        let reloadedWhileHeld = LogSubmissionStore(persistence: base)
        XCTAssertEqual(
            reloadedWhileHeld.entry(id: matching.id, accountID: "account-a")?.state,
            .invalidated
        )
        XCTAssertNil(
            reloadedWhileHeld.entry(id: matching.id, accountID: "account-a")?.body
        )
        XCTAssertEqual(
            reloadedWhileHeld.entry(id: unrelated.id, accountID: "account-a")?.state,
            .uncertain,
            "Delete must not touch another product"
        )

        await service.releaseDelete()
        await deletion.value

        XCTAssertEqual(vm.state, .deleted)
        XCTAssertEqual(vm.blockedPendingCount, 1)
    }

    func testDeleteFailureAfterDurableBarrierExplainsThatRetriesStayBlocked() async throws {
        let base = FileLogSubmissionPersistence(directoryURL: directory)
        let store = LogSubmissionStore(persistence: base)
        let entry = try seedSubmission(in: store, accountID: "account-a")
        let service = FakeEditorService(log: makeProductLog())
        await service.setDeleteError(.server("Delete blocked."))
        let vm = LogEditorViewModel(
            log: makeProductLog(),
            date: date,
            service: service,
            accountID: "account-a",
            submissionStore: store
        )

        await vm.delete()

        XCTAssertEqual(
            vm.state,
            .failed(String(
                format: String(localized: "diary.editor.delete.failedWithBarrier"),
                "Delete blocked."
            ))
        )
        XCTAssertFalse(vm.isTerminal)
        XCTAssertTrue(vm.canEdit)
        XCTAssertEqual(vm.blockedPendingCount, 1)
        let stored = try XCTUnwrap(store.entry(id: entry.id, accountID: "account-a"))
        XCTAssertEqual(stored.state, .invalidated)
        XCTAssertNil(stored.body)
        XCTAssertTrue(store.isRetryBlocked(id: entry.id))
        let reloaded = LogSubmissionStore(persistence: base)
        XCTAssertEqual(
            reloaded.entry(id: entry.id, accountID: "account-a")?.state,
            .invalidated,
            "A failed DELETE cannot re-enable the blocked retry key"
        )

        // The safe recovery path is to retry the DELETE, not the submission.
        await service.setDeleteError(nil)
        vm.retry()
        await vm.delete()
        XCTAssertEqual(vm.state, .deleted)
        XCTAssertEqual(vm.blockedPendingCount, 1)
    }

    func testCancellationRestoresEditingState() async {
        let service = FakeEditorService(log: makeLog())
        await service.setUpdateError(.cancelled)
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)

        await vm.save()

        XCTAssertEqual(vm.state, .editing)
        XCTAssertNil(vm.errorMessage)
    }

    func testFetchedUnitsAreMergedWithCurrentUnit() async {
        let service = FakeEditorService(log: makeLog())
        await service.setUnits([
            FoodUnit(code: "serving", name: "Serving", kind: "serving"),
            FoodUnit(code: "g", name: "Gram", kind: "mass"),
        ])
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)

        await vm.loadUnits()

        XCTAssertEqual(vm.units.first(where: { $0.code == "g" })?.name, "Gram")
        XCTAssertTrue(vm.units.contains { $0.code == "serving" })
        XCTAssertEqual(vm.units.filter { $0.code == "g" }.count, 1)
    }

    func testUnitFetchFailureKeepsEditingUsable() async {
        let service = FakeEditorService(log: makeLog())
        await service.setUnitsError(.networkUnavailable)
        let vm = LogEditorViewModel(log: makeLog(), date: date, service: service)

        await vm.loadUnits()

        XCTAssertEqual(vm.state, .editing)
        XCTAssertTrue(vm.units.contains { $0.code == "g" })
    }
}
