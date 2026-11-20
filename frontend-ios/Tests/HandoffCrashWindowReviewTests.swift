import XCTest

@testable import CalCo

/// Independent crash-window review for the save-food-then-log handoff. The
/// first log succeeds and is assumed durably journaled, but the catalog attempt
/// cannot be cleared (process death or remove failure). Reopening must not mint
/// a second log key for the same owed intent.
@MainActor
final class HandoffCrashWindowReviewTests: XCTestCase {
    private let accountID = "handoff-crash-account"
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 19)

    func testSucceededJournalThenInterruptedHandoffDoesNotMintSecondLog() async {
        let persistence = RemoveFailingReconciliationPersistence()
        let store = CustomFoodReconciliationStore(persistence: persistence)
        let service = FakeLibraryService()
        let submission = FakeLibraryLogSubmissionService(
            results: [
                .success(logs: [], replayed: false),
                .success(logs: [], replayed: false),
            ]
        )
        let viewModel = makeViewModel(
            service: service,
            submission: submission,
            store: store
        )
        await viewModel.load()
        fill(viewModel)
        service.enqueueCreate(.success("saved-food"))

        viewModel.requestReview()
        await viewModel.confirmReview()

        XCTAssertEqual(submission.submissions.count, 1)
        XCTAssertNotNil(
            try? store.attempt(accountID: accountID),
            "the removable attempt is intentionally left behind for this crash-window test"
        )

        // Simulated relaunch. The journal already succeeded, so no retry key may
        // be minted for this same owed log.
        let reopened = makeViewModel(
            service: service,
            submission: submission,
            store: store
        )
        await reopened.load()
        XCTAssertEqual(reopened.savedFoodID, "saved-food")
        await reopened.retrySavedFoodLog()

        XCTAssertEqual(
            submission.submissions.count,
            1,
            "a succeeded journal operation must not be replayed with a new key"
        )
    }

    private func makeViewModel(
        service: FakeLibraryService,
        submission: FakeLibraryLogSubmissionService,
        store: CustomFoodReconciliationStore
    ) -> AdHocLogViewModel {
        AdHocLogViewModel(
            service: service,
            submissionService: submission,
            reconciliationStore: store,
            accountID: accountID,
            initialDate: date,
            today: date,
            timeZoneProvider: { "Asia/Kolkata" }
        )
    }

    private func fill(_ viewModel: AdHocLogViewModel) {
        viewModel.name = "Bowl"
        viewModel.amount = "1"
        viewModel.unit = "g"
        viewModel.mode = .saveAndLog
        viewModel.setNutrientAmount("250", code: "ENERGY_KCAL")
        viewModel.setNutrientAmount("10", code: "PROTEIN_G")
        viewModel.setNutrientAmount("40", code: "CARBS_G")
        viewModel.setNutrientAmount("5", code: "FAT_G")
    }
}

private final class RemoveFailingReconciliationPersistence:
    CustomFoodReconciliationPersisting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var data: [String: Data] = [:]

    func load(accountID: String) throws -> Data? {
        lock.withLock { data[accountID] }
    }

    func save(_ data: Data, accountID: String) throws {
        lock.withLock { self.data[accountID] = data }
    }

    func remove(accountID: String) throws {
        throw CocoaError(.fileWriteUnknown)
    }

    func quarantine(accountID: String, reason: String) {
        lock.withLock { data.removeValue(forKey: accountID) }
    }
}
