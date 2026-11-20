import XCTest

@testable import CalCo

@MainActor
final class LibraryReconciliationStoreTests: XCTestCase {
    private let accountID = "account-a"

    private func draft(name: String = "Oats") -> CustomFoodWriteRequest {
        CustomFoodWriteRequest(
            name: name,
            nutrients: [
                .init(code: "ENERGY_KCAL", amountPer100g: 100),
                .init(code: "PROTEIN_G", amountPer100g: 4),
                .init(code: "CARBS_G", amountPer100g: 10),
                .init(code: "FAT_G", amountPer100g: 2),
            ]
        )
    }

    func testAttemptRoundTripsPerAccountAndClears() throws {
        let persistence = MemoryReconciliationPersistence()
        let store = CustomFoodReconciliationStore(persistence: persistence)
        let attempt = CustomFoodCreateAttempt(
            accountID: accountID,
            draft: draft(),
            baselineFoodIDs: ["existing"],
            logIntent: CustomFoodLogIntent(
                date: LocalDiaryDate(year: 2026, month: 11, day: 19),
                mealSlot: .lunch,
                amount: "150",
                unit: "g",
                notes: "note",
                timeZone: "Asia/Kolkata"
            ),
            message: "uncertain"
        )

        try store.save(attempt)
        XCTAssertEqual(try store.attempt(accountID: accountID), attempt)
        XCTAssertEqual(
            try store.attempt(accountID: "another-account"),
            nil
        )

        try store.clear(accountID: accountID)
        XCTAssertNil(try store.attempt(accountID: accountID))
        XCTAssertNil(persistence.storedData(accountID: accountID))
    }

    func testUnreadableAttemptFailsClosedUntilExplicitReset() throws {
        let persistence = MemoryReconciliationPersistence()
        try persistence.save(Data("not json".utf8), accountID: accountID)
        let store = CustomFoodReconciliationStore(persistence: persistence)

        XCTAssertThrowsError(try store.attempt(accountID: accountID))
        XCTAssertTrue(
            persistence.quarantinedAccounts.isEmpty,
            "automatic detection must leave the corrupt file in place"
        )
        XCTAssertNotNil(persistence.storedData(accountID: accountID))

        // A brand-new store in the same process (simulated relaunch) must see
        // the same corrupt file and remain blocked.
        let relaunched = CustomFoodReconciliationStore(persistence: persistence)
        XCTAssertThrowsError(try relaunched.attempt(accountID: accountID))
        XCTAssertTrue(persistence.quarantinedAccounts.isEmpty)

        XCTAssertThrowsError(
            try store.save(
                CustomFoodCreateAttempt(
                    accountID: accountID,
                    draft: draft(),
                    baselineFoodIDs: [],
                    message: "uncertain"
                )
            )
        )

        try store.reset(accountID: accountID)
        XCTAssertEqual(persistence.quarantinedAccounts, [accountID])
        XCTAssertNil(try store.attempt(accountID: accountID))
    }

    func testExplicitResetCannotEraseNewerValidRecord() throws {
        let persistence = MemoryReconciliationPersistence()
        try persistence.save(Data("not json".utf8), accountID: accountID)
        let staleStore = CustomFoodReconciliationStore(persistence: persistence)
        XCTAssertThrowsError(try staleStore.attempt(accountID: accountID))

        let newer = CustomFoodCreateAttempt(
            accountID: accountID,
            draft: draft(name: "Newer"),
            baselineFoodIDs: [],
            message: "uncertain"
        )
        try persistence.save(JSONEncoder().encode(newer), accountID: accountID)

        XCTAssertThrowsError(try staleStore.reset(accountID: accountID))
        XCTAssertTrue(persistence.quarantinedAccounts.isEmpty)
        let reloaded = CustomFoodReconciliationStore(persistence: persistence)
        XCTAssertEqual(try reloaded.attempt(accountID: accountID)?.id, newer.id)
    }

    func testEngineKeepsAttemptOnUncertainAndClearsOnSuccess() async throws {
        let persistence = MemoryReconciliationPersistence()
        let store = CustomFoodReconciliationStore(persistence: persistence)
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        service.enqueueCreate(.failure(.uncertain("timeout")))

        let uncertain = await engine.create(
            draft: draft(),
            baselineFoodIDs: ["existing"]
        )
        guard case .needsReconciliation(let attempt) = uncertain else {
            return XCTFail("uncertain create must require reconciliation")
        }
        XCTAssertEqual(attempt.draft.name, "Oats")
        XCTAssertEqual(try store.attempt(accountID: accountID)?.id, attempt.id)

        // A second create cannot replace the unresolved attempt.
        let blocked = await engine.create(
            draft: draft(name: "Barley"),
            baselineFoodIDs: ["existing"]
        )
        XCTAssertEqual(blocked, .needsReconciliation(attempt))
        XCTAssertEqual(service.createCallCount, 1)

        try engine.discard(attempt: attempt)
        service.enqueueCreate(.success("new-food"))
        let saved = await engine.create(
            draft: draft(name: "Barley"),
            baselineFoodIDs: ["existing"]
        )
        XCTAssertEqual(saved, .saved(foodID: "new-food"))
        XCTAssertNil(try store.attempt(accountID: accountID))
    }

    func testEngineClearsAttemptOnDefinitiveRejection() async throws {
        let store = CustomFoodReconciliationStore(
            persistence: MemoryReconciliationPersistence()
        )
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        service.enqueueCreate(.failure(.failed("invalid")))
        let result = await engine.create(
            draft: draft(),
            baselineFoodIDs: []
        )
        XCTAssertEqual(result, .failed(.failed("invalid")))
        XCTAssertNil(try store.attempt(accountID: accountID))
    }

    func testEngineBlocksBeforePOSTWhenIntentCannotBePersisted() async throws {
        final class FailingPersistence: CustomFoodReconciliationPersisting, @unchecked Sendable {
            func load(accountID: String) throws -> Data? { nil }
            func save(_ data: Data, accountID: String) throws {
                throw NSError(domain: "test", code: 1)
            }
            func remove(accountID: String) throws {}
            func quarantine(accountID: String, reason: String) {}
        }
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: CustomFoodReconciliationStore(persistence: FailingPersistence()),
            accountID: accountID
        )
        let result = await engine.create(
            draft: draft(),
            baselineFoodIDs: []
        )
        guard case .blocked = result else {
            return XCTFail("unwritable safety record must block the create")
        }
        XCTAssertEqual(service.createCallCount, 0)
    }

    func testCandidatesMatchNewFoodAndResolveClears() async throws {
        let persistence = MemoryReconciliationPersistence()
        let store = CustomFoodReconciliationStore(persistence: persistence)
        let service = FakeLibraryService()
        let engine = CustomFoodReconciliationEngine(
            service: service,
            store: store,
            accountID: accountID
        )
        let request = draft()
        service.enqueueCreate(.failure(.uncertain("lost response")))
        guard case .needsReconciliation(let attempt) = await engine.create(
            draft: request,
            baselineFoodIDs: ["existing"]
        ) else {
            return XCTFail("expected reconciliation")
        }

        service.enqueueList(
            .success([
                LibraryTestFixtures.food(id: "existing", name: "Existing"),
                LibraryTestFixtures.food(matching: request, id: "recovered"),
            ])
        )
        let candidates = try await engine.candidates(for: attempt)
        XCTAssertEqual(candidates.map(\.id), ["recovered"])

        try engine.resolve(attempt: attempt, food: candidates[0])
        XCTAssertNil(try store.attempt(accountID: accountID))
    }
}
