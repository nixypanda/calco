import ComposableArchitecture
import Foundation

// Manual barcode lookup only. No camera/scanner behavior is ported here.
// The feature wraps existing BarcodeServicing via an explicit injected live
// service and keeps lookup side effects behind a narrow dependency.

public struct BarcodeClient: Sendable {
    public var lookup: @Sendable (_ barcode: String) async throws -> BarcodeLookup

    public init(lookup: @escaping @Sendable (_ barcode: String) async throws -> BarcodeLookup) {
        self.lookup = lookup
    }

    public static func live(service: any BarcodeServicing) -> Self {
        Self { barcode in
            try await service.lookupBarcode(barcode)
        }
    }

    public static let unimplemented = Self(
        lookup: { _ in
            fatalError("Unimplemented: BarcodeClient.lookup")
        }
    )
}

private enum BarcodeClientKey: DependencyKey {
    static let liveValue: BarcodeClient = .unimplemented
    static let testValue: BarcodeClient = .unimplemented
}

public extension DependencyValues {
    var barcodeClient: BarcodeClient {
        get { self[BarcodeClientKey.self] }
        set { self[BarcodeClientKey.self] = newValue }
    }
}

@Reducer
public struct BarcodeFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        public fileprivate(set) var barcodeInput: String
        public fileprivate(set) var lookup: Lookup

        public let sessionGeneration: UInt64

        public init(barcodeInput: String = "", lookup: Lookup = .idle, sessionGeneration: UInt64) {
            self.barcodeInput = barcodeInput
            self.lookup = lookup
            self.sessionGeneration = sessionGeneration
        }

        public var isBusy: Bool {
            if case .lookingUp = lookup { return true }
            return false
        }
    }

    public enum Lookup: Equatable, Sendable {
        case idle
        case invalid(BarcodeValidationError)
        case lookingUp(requestID: UUID, barcode: String)
        case found(BarcodeLookup)
        case notFound(barcode: String)
        case failed(barcode: String, error: BarcodeServiceError)
    }

    public enum Action: Sendable {
        case barcodeChanged(String)
        case lookupSubmitted
        case lookupResponse(requestID: UUID, barcode: String, Result<BarcodeLookup, BarcodeServiceError>)
        case foundProductSelected
        case createCustomFoodDraftSelected
        case retrySubmitted
        case cancelLookup
        case delegate(Delegate)
    }

    public enum Delegate: Equatable, Sendable {
        case selectedProduct(BarcodeLookup, generation: UInt64)
        case createCustomFoodDraft(BarcodeCustomFoodDraft, generation: UInt64)
        case sessionExpired(reason: SessionUnavailableReason, generation: UInt64)
    }

    private enum CancelID {
        case lookup
    }

    @Dependency(\.barcodeClient) var barcodeClient
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .barcodeChanged(let raw):
                let sanitized = BarcodeValidation.sanitizedInput(raw)
                guard sanitized != state.barcodeInput else { return .none }
                state.barcodeInput = sanitized
                state.lookup = .idle
                return .cancel(id: CancelID.lookup)

            case .lookupSubmitted:
                return submitLookup(&state)

            case .retrySubmitted:
                guard !state.isBusy else { return .none }
                return submitLookup(&state)

            case .cancelLookup:
                if case .lookingUp = state.lookup {
                    state.lookup = .idle
                }
                return .cancel(id: CancelID.lookup)

            case let .lookupResponse(requestID, barcode, result):
                guard case .lookingUp(let currentRequestID, let currentBarcode) = state.lookup,
                      currentRequestID == requestID,
                      currentBarcode == barcode
                else {
                    return .none
                }

                switch result {
                case .success(let lookup):
                    state.lookup = .found(lookup)
                    return .none

                case .failure(let error):
                    if error.isCancelled {
                        state.lookup = .idle
                        return .none
                    }
                    if error.isUnauthorized {
                        state.lookup = .failed(barcode: barcode, error: .unauthorized)
                        return .send(.delegate(.sessionExpired(reason: .expired, generation: state.sessionGeneration)))
                    }
                    if case .notFound(let missingBarcode) = error {
                        state.lookup = .notFound(barcode: missingBarcode)
                        return .none
                    }
                    state.lookup = .failed(barcode: barcode, error: error)
                    return .none
                }

            case .foundProductSelected:
                guard case .found(let lookup) = state.lookup else { return .none }
                return .send(.delegate(.selectedProduct(lookup, generation: state.sessionGeneration)))

            case .createCustomFoodDraftSelected:
                guard case .notFound(let barcode) = state.lookup else { return .none }
                return .send(.delegate(.createCustomFoodDraft(BarcodeCustomFoodDraft(barcode: barcode), generation: state.sessionGeneration)))

            case .delegate:
                return .none
            }
        }
    }

    private func submitLookup(_ state: inout State) -> Effect<Action> {
        let value = state.barcodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch BarcodeValidation.validated(value) {
        case .failure(let validationError):
            state.lookup = .invalid(validationError)
            return .cancel(id: CancelID.lookup)

        case .success(let barcode):
            let requestID = uuid()
            state.lookup = .lookingUp(requestID: requestID, barcode: barcode)
            return .run { [barcodeClient, requestID, barcode] send in
                do {
                    let lookup = try await barcodeClient.lookup(barcode)
                    await send(.lookupResponse(requestID: requestID, barcode: barcode, .success(lookup)))
                } catch let error as BarcodeServiceError {
                    await send(.lookupResponse(requestID: requestID, barcode: barcode, .failure(error)))
                } catch is CancellationError {
                    await send(.lookupResponse(requestID: requestID, barcode: barcode, .failure(.cancelled)))
                } catch {
                    await send(.lookupResponse(requestID: requestID, barcode: barcode, .failure(.server(error.localizedDescription))))
                }
            }
            .cancellable(id: CancelID.lookup, cancelInFlight: true)
        }
    }
}

private extension BarcodeServiceError {
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}