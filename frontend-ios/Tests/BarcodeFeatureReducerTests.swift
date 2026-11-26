import ComposableArchitecture
import XCTest

@testable import CalCo

@MainActor
final class BarcodeFeatureReducerTests: XCTestCase {
    private let generation = UInt64(42)
    private func makeProduct(barcode: String = "0001234") -> ProductDetail {
        ProductDetail(
            id: "p1",
            source: "USER",
            sourceID: "s1",
            visibility: "shared",
            barcode: barcode,
            name: "Test food",
            brand: "Brand",
            categories: [],
            defaultQuantity: "100",
            defaultUnit: "g",
            nutritionSummary: ProductNutritionSummary(per100g: .empty),
            nutrients: [
                ProductNutrient(
                    code: NutrientCodes.energyKcal,
                    amountPer100g: "389",
                    unit: "kcal"
                )
            ],
            servings: [],
            allowedUnits: []
        )
    }

    private func makeLookup(
        origin: BarcodeLookupOrigin = .local,
        note: String? = nil,
        barcode: String = "0001234"
    ) -> BarcodeLookup {
        BarcodeLookup(
            product: makeProduct(barcode: barcode),
            lookup: BarcodeLookupMeta(origin: origin, note: note)
        )
    }

    func testInvalidInputDoesNotCallAPI() async {
        let store = TestStore(initialState: BarcodeFeature.State(sessionGeneration: generation)) {
            BarcodeFeature()
        } withDependencies: {
            $0.barcodeClient.lookup = { _ in
                XCTFail("Lookup should not be called for invalid input")
                throw BarcodeServiceError.invalidResponse
            }
        }

        await store.send(.barcodeChanged("123")) {
            $0 = BarcodeFeature.State(barcodeInput: "123", lookup: .idle, sessionGeneration: self.generation)
        }
        await store.send(.lookupSubmitted) {
            $0 = BarcodeFeature.State(barcodeInput: "123", lookup: .invalid(.invalidLength), sessionGeneration: self.generation)
        }
    }

    func testLeadingZerosPreservedAndFoundRequiresExplicitSelection() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let lookup = makeLookup(barcode: "0001234")

        let store = TestStore(initialState: BarcodeFeature.State(sessionGeneration: generation)) {
            BarcodeFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.barcodeClient.lookup = { barcode in
                XCTAssertEqual(barcode, "0001234")
                return lookup
            }
        }

        await store.send(.barcodeChanged("0001234")) {
            $0 = BarcodeFeature.State(barcodeInput: "0001234", lookup: .idle, sessionGeneration: self.generation)
        }
        await store.send(.lookupSubmitted) {
            $0 = BarcodeFeature.State(barcodeInput: "0001234", lookup: .lookingUp(requestID: requestID, barcode: "0001234"), sessionGeneration: self.generation)
        }
        await store.receive(\.lookupResponse) {
            $0 = BarcodeFeature.State(barcodeInput: "0001234", lookup: .found(lookup), sessionGeneration: self.generation)
        }
        await store.send(.foundProductSelected)
        await store.receive(\.delegate, .selectedProduct(lookup, generation: generation))
    }

    func testMissingRequiresExplicitCustomDraftAction() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let store = TestStore(initialState: BarcodeFeature.State(sessionGeneration: generation)) {
            BarcodeFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.barcodeClient.lookup = { _ in
                throw BarcodeServiceError.notFound(barcode: "0001234")
            }
        }

        await store.send(.barcodeChanged("0001234")) {
            $0 = BarcodeFeature.State(barcodeInput: "0001234", lookup: .idle, sessionGeneration: self.generation)
        }
        await store.send(.lookupSubmitted) {
            $0 = BarcodeFeature.State(barcodeInput: "0001234", lookup: .lookingUp(requestID: requestID, barcode: "0001234"), sessionGeneration: self.generation)
        }
        await store.receive(\.lookupResponse) {
            $0 = BarcodeFeature.State(barcodeInput: "0001234", lookup: .notFound(barcode: "0001234"), sessionGeneration: self.generation)
        }
        await store.send(.createCustomFoodDraftSelected)
        await store.receive(\.delegate, .createCustomFoodDraft(BarcodeCustomFoodDraft(barcode: "0001234"), generation: generation))
    }

    func testUpstreamAndRateErrorsAreNotMissing() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let store = TestStore(initialState: BarcodeFeature.State(sessionGeneration: generation)) {
            BarcodeFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.barcodeClient.lookup = { _ in
                throw BarcodeServiceError.upstreamUnavailable
            }
        }

        await store.send(.barcodeChanged("123456")) {
            $0 = BarcodeFeature.State(barcodeInput: "123456", lookup: .idle, sessionGeneration: self.generation)
        }
        await store.send(.lookupSubmitted) {
            $0 = BarcodeFeature.State(barcodeInput: "123456", lookup: .lookingUp(requestID: requestID, barcode: "123456"), sessionGeneration: self.generation)
        }
        await store.receive(\.lookupResponse) {
            $0 = BarcodeFeature.State(barcodeInput: "123456", lookup: .failed(barcode: "123456", error: .upstreamUnavailable), sessionGeneration: self.generation)
        }

        let rateLimitedRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let rateStore = TestStore(initialState: BarcodeFeature.State(barcodeInput: "123456", sessionGeneration: generation)) {
            BarcodeFeature()
        } withDependencies: {
            $0.uuid = .constant(rateLimitedRequestID)
            $0.barcodeClient.lookup = { _ in
                throw BarcodeServiceError.rateLimited(retryAfterSeconds: 9)
            }
        }

        await rateStore.send(.lookupSubmitted) {
            $0 = BarcodeFeature.State(
                barcodeInput: "123456",
                lookup: .lookingUp(requestID: rateLimitedRequestID, barcode: "123456"),
                sessionGeneration: self.generation
            )
        }
        await rateStore.receive(\.lookupResponse) {
            $0 = BarcodeFeature.State(
                barcodeInput: "123456",
                lookup: .failed(barcode: "123456", error: .rateLimited(retryAfterSeconds: 9)),
                sessionGeneration: self.generation
            )
        }
    }

    func testStaleCompletionIsIgnored() async {
        let currentRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let staleRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        let staleLookup = makeLookup(barcode: "0001234")

        let store = TestStore(
            initialState: BarcodeFeature.State(
                barcodeInput: "0001234",
                lookup: .lookingUp(requestID: currentRequestID, barcode: "0001234"),
                sessionGeneration: self.generation
            )
        ) {
            BarcodeFeature()
        }

        await store.send(.lookupResponse(requestID: staleRequestID, barcode: "0001234", .success(staleLookup)))
    }

    func testUnauthorizedEmitsSessionExpiredDelegate() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

        let store = TestStore(initialState: BarcodeFeature.State(sessionGeneration: generation)) {
            BarcodeFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.barcodeClient.lookup = { _ in
                throw BarcodeServiceError.unauthorized
            }
        }

        await store.send(.barcodeChanged("123456")) {
            $0 = BarcodeFeature.State(barcodeInput: "123456", lookup: .idle, sessionGeneration: self.generation)
        }
        await store.send(.lookupSubmitted) {
            $0 = BarcodeFeature.State(barcodeInput: "123456", lookup: .lookingUp(requestID: requestID, barcode: "123456"), sessionGeneration: self.generation)
        }
        await store.receive(\.lookupResponse) {
            $0 = BarcodeFeature.State(barcodeInput: "123456", lookup: .failed(barcode: "123456", error: .unauthorized), sessionGeneration: self.generation)
        }
        await store.receive(\.delegate, .sessionExpired(reason: .expired, generation: generation))
    }

    func testEditWhileLookingUpResetsLookupAndIgnoresOldCompletion() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let staleLookup = makeLookup(barcode: "0001234")

        let store = TestStore(
            initialState: BarcodeFeature.State(
                barcodeInput: "0001234",
                lookup: .lookingUp(requestID: requestID, barcode: "0001234"),
                sessionGeneration: self.generation
            )
        ) {
            BarcodeFeature()
        }

        await store.send(.barcodeChanged("00012345")) {
            $0 = BarcodeFeature.State(barcodeInput: "00012345", lookup: .idle, sessionGeneration: self.generation)
        }
        await store.send(.lookupResponse(requestID: requestID, barcode: "0001234", .success(staleLookup)))
    }

    func testMatchingRequestIDWithWrongBarcodeIsRejected() async {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let lookup = makeLookup(barcode: "9999999")

        let store = TestStore(
            initialState: BarcodeFeature.State(
                barcodeInput: "0001234",
                lookup: .lookingUp(requestID: requestID, barcode: "0001234"),
                sessionGeneration: self.generation
            )
        ) {
            BarcodeFeature()
        }

        await store.send(.lookupResponse(requestID: requestID, barcode: "9999999", .success(lookup)))
    }
}