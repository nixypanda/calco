import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class LibraryFeatureTests: XCTestCase {
    private let date = LocalDiaryDate(year: 2026, month: 11, day: 24)
    private let generation: UInt64 = 42
    private let accountID = "account-a"
    private let presentationID = UUID(100)

    private var context: LibraryLogContext { LibraryLogContext(date: date, mealSlot: .lunch) }

    private func makeStore(
        client: LibraryFeature.Client
    ) -> TestStore<LibraryFeature.State, LibraryFeature.Action> {
        TestStore(
            initialState: LibraryFeature.State(
                accountID: accountID,
                generation: generation,
                logContext: context,
                today: date,
                presentationID: presentationID
            )
        ) {
            LibraryFeature()
        } withDependencies: {
            $0.libraryClient = client
            $0.uuid = .incrementing
        }
    }

    private func load(
        _ store: TestStore<LibraryFeature.State, LibraryFeature.Action>,
        requestID: UUID = UUID(0)
    ) async {
        await store.send(.load) {
            $0.phase = .loading
            $0.loadRequestID = requestID
            $0.refreshError = nil
        }
    }

    private func receiveLoad(
        _ store: TestStore<LibraryFeature.State, LibraryFeature.Action>,
        requestID: UUID,
        foods: [CustomFood],
        sortedFoods: [CustomFood]
    ) async {
        await store.receive(.loadCompleted(
            requestID: requestID,
            context: FeatureRequestContext(
                accountID: accountID,
                generation: generation,
                presentationID: presentationID
            ),
            result: .success(foods)
        )) {
            $0.foods = sortedFoods
            $0.phase = .loaded
            $0.loadRequestID = requestID
        }
    }

    private func openAndLoadDetail(
        _ store: TestStore<LibraryFeature.State, LibraryFeature.Action>,
        food: CustomFood,
        detailPresentationID: UUID = UUID(0),
        loadRequestID: UUID = UUID(1)
    ) async throws {
        let detailContext = FeatureRequestContext(
            accountID: accountID,
            generation: generation,
            presentationID: detailPresentationID
        )
        await store.send(.openDetail(id: food.id)) {
            $0.detail = CustomFoodDetailFeature.State(
                foodID: food.id,
                accountID: self.accountID,
                generation: self.generation,
                presentationID: detailPresentationID
            )
        }
        await store.receive(.delegate(.openDetail(
            id: food.id,
            date: date,
            generation: generation,
            presentationID: detailPresentationID
        )))
        await store.send(.detail(.load)) {
            $0.detail?.phase = .loading
            $0.detail?.loadRequestID = loadRequestID
        }
        await store.receive(.detail(.loadCompleted(
            requestID: loadRequestID,
            context: detailContext,
            result: .success(food)
        ))) {
            $0.detail?.loadRequestID = nil
            $0.detail?.phase = .loaded(food)
        }
    }

    func testLoadSortsFiltersAndIgnoresStaleCompletion() async throws {
        let foods = [
            LibraryTestFixtures.food(id: "z", name: "Zucchini"),
            LibraryTestFixtures.food(id: "a", name: "Almonds"),
        ]
        let sortedFoods = [foods[1], foods[0]]
        let client = LibraryFeature.Client(
            list: { _ in foods },
            customFood: { _, id in foods.first { $0.id == id } ?? foods[0] },
            delete: { _, _ in }
        )
        let store = makeStore(client: client)

        await load(store, requestID: UUID(0))
        await receiveLoad(store, requestID: UUID(0), foods: foods, sortedFoods: sortedFoods)
        XCTAssertEqual(store.state.foods.map(\.id), ["a", "z"])

        await store.send(.searchChanged("alm")) {
            $0.searchText = "alm"
        }
        XCTAssertEqual(store.state.filteredFoods.map(\.id), ["a"])

        // The first request's retained completion cannot rewrite rows after a
        // distinct refresh request has taken ownership.
        await store.send(.refresh) {
            $0.loadRequestID = UUID(1)
            $0.refreshError = nil
        }.finish()
        // The refresh returns the already-loaded rows, so the accepted
        // completion has no observable state mutation to assert.
        await store.receive(.loadCompleted(
            requestID: UUID(1),
            context: FeatureRequestContext(
                accountID: accountID,
                generation: generation,
                presentationID: presentationID
            ),
            result: .success(foods)
        ))
        await store.send(.loadCompleted(
            requestID: UUID(0),
            context: FeatureRequestContext(
                accountID: accountID,
                generation: generation,
                presentationID: presentationID
            ),
            result: .success([])
        ))
        XCTAssertEqual(store.state.foods.map(\.id), ["a", "z"])
        XCTAssertEqual(store.state.loadRequestID, UUID(1))
    }

    func testRefreshFailureKeepsExistingRowsAndShowsRefreshError() async throws {
        let first = LibraryTestFixtures.food(id: "a", name: "Almonds")
        var attempts = 0
        let client = LibraryFeature.Client(
            list: { _ in
                attempts += 1
                if attempts == 1 { return [first] }
                throw CustomFoodServiceError.failed("offline")
            },
            customFood: { _, _ in first },
            delete: { _, _ in }
        )
        let store = makeStore(client: client)

        await load(store, requestID: UUID(0))
        await receiveLoad(store, requestID: UUID(0), foods: [first], sortedFoods: [first])
        await store.send(.refresh) {
            $0.loadRequestID = UUID(1)
            $0.refreshError = nil
        }
        await store.receive(.loadCompleted(
            requestID: UUID(1),
            context: FeatureRequestContext(
                accountID: accountID,
                generation: generation,
                presentationID: presentationID
            ),
            result: .failure(.failed("offline"))
        )) {
            $0.foods = [first]
            $0.phase = .loaded
            $0.refreshError = "offline"
            $0.loadRequestID = UUID(1)
        }
        XCTAssertEqual(store.state.foods.map(\.id), ["a"])
        XCTAssertEqual(store.state.refreshError, "offline")
    }

    func testUnauthorizedListLoadExpiresSession() async throws {
        let client = LibraryFeature.Client(
            list: { _ in throw CustomFoodServiceError.unauthorized },
            customFood: { _, _ in throw CustomFoodServiceError.notFound("x") },
            delete: { _, _ in }
        )
        let store = makeStore(client: client)
        await load(store, requestID: UUID(0))
        await store.receive(.loadCompleted(
            requestID: UUID(0),
            context: FeatureRequestContext(
                accountID: accountID,
                generation: generation,
                presentationID: presentationID
            ),
            result: .failure(.unauthorized)
        ))
        await store.receive(.delegate(.sessionExpired(generation: generation)))
        XCTAssertEqual(store.state.phase, .loading)
        XCTAssertEqual(store.state.loadRequestID, UUID(0))
    }

    func testUncertainDeleteConsultsAuthoritativeListBeforeSuccess() async throws {
        let food = LibraryTestFixtures.food(id: "food-x", name: "Oats")
        var listCalls = 0
        let client = LibraryFeature.Client(
            list: { _ in
                listCalls += 1
                // First call is the authoritative check after uncertain DELETE.
                return []
            },
            customFood: { _, _ in food },
            delete: { _, _ in throw CustomFoodServiceError.uncertain("unknown") }
        )
        let detailPresentationID = UUID(0)
        let detailContext = FeatureRequestContext(
            accountID: accountID,
            generation: generation,
            presentationID: detailPresentationID
        )
        let store = makeStore(client: client)

        try await openAndLoadDetail(
            store,
            food: food,
            detailPresentationID: detailPresentationID,
            loadRequestID: UUID(1)
        )

        await store.send(.detail(.delete)) {
            $0.detail?.deletePhase = .deleting
            $0.detail?.deleteRequestID = UUID(2)
        }.finish()

        await store.receive(.detail(.deleteCompleted(
            requestID: UUID(2),
            context: detailContext,
            generation: generation,
            result: .failure(.uncertain("unknown"))
        ))) {
            $0.detail?.deleteRequestID = UUID(3)
            $0.detail?.deletePhase = .deleting
        }
        await store.receive(.detail(.uncertainDeleteResolved(
            requestID: UUID(3),
            context: detailContext,
            generation: generation,
            foods: []
        ))) {
            $0.detail?.deleteRequestID = nil
            $0.detail?.deletePhase = .idle
        }
        await store.receive(.detail(.delegate(.deleted(id: "food-x", generation: generation)))) {
            $0.detail = nil
        }
        await store.receive(.delegate(.deleted(id: "food-x", generation: generation)))

        XCTAssertEqual(listCalls, 1)
        XCTAssertNil(store.state.detail)
    }
}
