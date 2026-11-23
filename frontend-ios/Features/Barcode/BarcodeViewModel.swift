// Manual barcode lookup state. The feature only reads catalog data; opening a
// result and creating a custom-food draft are explicit caller actions.

import Combine
import Foundation

public protocol BarcodeServicing: Sendable {
    func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup
}

public enum BarcodeLookupScreenState: Equatable, Sendable {
    case idle
    case loading
    case found(BarcodeLookup)
    case notFound(barcode: String)
    case failed(BarcodeServiceError)
}

@MainActor
public final class BarcodeViewModel: ObservableObject {
    @Published public private(set) var barcodeInput: String = ""
    @Published public private(set) var state: BarcodeLookupScreenState = .idle

    public var isBusy: Bool {
        if case .loading = state { return true }
        return false
    }

    private let service: BarcodeServicing
    private let onSelectProduct: (BarcodeLookup) -> Void
    private let onCreateCustomFood: (BarcodeCustomFoodDraft) -> Void
    private let onSessionExpired: () -> Void
    private var lookupTask: Task<Void, Never>?
    private var token: Int = 0

    public init(
        service: BarcodeServicing,
        onSelectProduct: @escaping (BarcodeLookup) -> Void = { _ in },
        onCreateCustomFood: @escaping (BarcodeCustomFoodDraft) -> Void = { _ in },
        onSessionExpired: @escaping () -> Void = {}
    ) {
        self.service = service
        self.onSelectProduct = onSelectProduct
        self.onCreateCustomFood = onCreateCustomFood
        self.onSessionExpired = onSessionExpired
    }

    deinit {
        lookupTask?.cancel()
    }

    public func barcodeChanged(_ raw: String) {
        let sanitized = BarcodeValidation.sanitizedInput(raw)
        guard sanitized != barcodeInput else { return }
        barcodeInput = sanitized
        cancel(clearState: true)
    }

    public func lookup() {
        let value = barcodeInput
        lookupTask?.cancel()
        lookupTask = Task { [weak self] in
            await self?.performLookup(value)
        }
    }

    /// Awaited entry point for tests and programmatic callers. Re-validates so
    /// leading zeros and the 4...24 digit contract are never bypassed by input
    /// normalisation alone.
    public func performLookup(_ raw: String? = nil) async {
        if let raw {
            barcodeInput = BarcodeValidation.sanitizedInput(raw)
        }
        let value = barcodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success(let barcode) = BarcodeValidation.validated(value) else {
            if case .failure(let validationError) = BarcodeValidation.validated(value) {
                token += 1
                state = .failed(.invalidBarcode(validationError))
            }
            return
        }

        token += 1
        let currentToken = token
        state = .loading

        do {
            let lookup = try await service.lookupBarcode(barcode)
            guard token == currentToken else { return }
            state = .found(lookup)
        } catch {
            guard token == currentToken else { return }
            let mapped = Self.map(error, barcode: barcode)
            if mapped.isCancelled {
                state = .idle
                return
            }
            if mapped.isUnauthorized {
                state = .failed(.unauthorized)
                onSessionExpired()
                return
            }
            if case .notFound(let missing) = mapped {
                state = .notFound(barcode: missing)
                return
            }
            state = .failed(mapped)
        }
    }

    public func retry() {
        guard !isBusy else { return }
        lookup()
    }

    public func cancel() {
        cancel(clearState: true)
    }

    public func selectFoundProduct() {
        guard case .found(let lookup) = state else { return }
        onSelectProduct(lookup)
    }

    public func createCustomFoodDraft() {
        guard case .notFound(let barcode) = state else { return }
        onCreateCustomFood(BarcodeCustomFoodDraft(barcode: barcode))
    }

    public func reset() {
        barcodeInput = ""
        cancel(clearState: true)
    }

    private func cancel(clearState: Bool) {
        token += 1
        lookupTask?.cancel()
        lookupTask = nil
        if clearState {
            state = .idle
        }
    }

    private static func map(_ error: Error, barcode: String) -> BarcodeServiceError {
        if let serviceError = error as? BarcodeServiceError {
            return serviceError
        }
        if let apiError = error as? CalCoAPIError {
            switch apiError {
            case .cancelled:
                return .cancelled
            case .unauthorized:
                return .unauthorized
            case .timeout:
                return .timedOut
            case .network:
                return .networkUnavailable
            case .rateLimited(let seconds):
                return .rateLimited(retryAfterSeconds: seconds)
            case .badStatus(let statusCode, let payload):
                if statusCode == 404 {
                    return .notFound(barcode: barcode)
                }
                if statusCode == 503, payload.code == "external_unavailable" {
                    return .upstreamUnavailable
                }
                if statusCode == 502, payload.code == "external_invalid_response" {
                    return .upstreamInvalidResponse
                }
                return .server(payload.message)
            case .invalidURL, .invalidResponse, .decoding, .encoding:
                return .invalidResponse
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return .server(error.localizedDescription)
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
