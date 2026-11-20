// Bridges GET /api/foods/barcode/{barcode} to the manual barcode feature and
// keeps not-found, upstream, validation, and session failures distinct.

import Foundation

public struct CalCoBarcodeServiceAdapter: BarcodeServicing {
    public let client: CalCoAPIClient

    public init(client: CalCoAPIClient) {
        self.client = client
    }

    public func lookupBarcode(_ barcode: String) async throws -> BarcodeLookup {
        guard case .success(let value) = BarcodeValidation.validated(barcode) else {
            if case .failure(let error) = BarcodeValidation.validated(barcode) {
                throw BarcodeServiceError.invalidBarcode(error)
            }
            throw BarcodeServiceError.invalidBarcode(.empty)
        }

        do {
            // Reuse the same endpoint call and DTOs as Search's barcode mode.
            return try await client.lookupBarcode(value)
        } catch let error as CalCoAPIError {
            throw Self.map(error, barcode: value)
        } catch {
            throw BarcodeServiceError.server(error.localizedDescription)
        }
    }

    private static func map(
        _ error: CalCoAPIError,
        barcode: String
    ) -> BarcodeServiceError {
        switch error {
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
            switch statusCode {
            case 404:
                return .notFound(barcode: barcode)
            case 400:
                return .server(payload.message)
            case 502:
                return .upstreamInvalidResponse
            case 503:
                return .upstreamUnavailable
            default:
                return .server(payload.message)
            }
        case .invalidURL, .invalidResponse, .decoding, .encoding:
            return .invalidResponse
        }
    }
}
