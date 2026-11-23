// Manual barcode validation and the reviewed handoff for a barcode that is not
// in the local catalog or Open Food Facts. Lookup itself never creates a log or
// a catalog record from this client's point of view.

import Foundation

public enum BarcodeValidationError: Error, Equatable, Sendable {
    case empty
    case invalidCharacters
    case invalidLength

    public var message: String {
        switch self {
        case .empty:
            return String(localized: "barcode.invalid.empty")
        case .invalidCharacters:
            return String(localized: "barcode.invalid.characters")
        case .invalidLength:
            return String(localized: "barcode.invalid.length")
        }
    }
}

public enum BarcodeValidation {
    /// The server accepts 4...24 ASCII digits for external lookups. Local
    /// products are matched before that check, but the manual flow uses the
    /// same contract so a barcode can always fall through to Open Food Facts.
    public static let minimumLength = 4
    public static let maximumLength = 24

    /// Keeps the digits a scanner or paste could provide. Leading zeros are
    /// data, not padding, so they are never stripped or normalised away.
    public static func sanitizedInput(_ raw: String, limit: Int = maximumLength) -> String {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        return String(digits.prefix(max(0, limit)))
    }

    public static func validated(_ raw: String) -> Result<String, BarcodeValidationError> {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(.empty) }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .failure(.invalidCharacters)
        }
        guard (minimumLength...maximumLength).contains(value.count) else {
            return .failure(.invalidLength)
        }
        return .success(value)
    }

    public static func isValid(_ raw: String) -> Bool {
        if case .success = validated(raw) { return true }
        return false
    }
}

public enum BarcodeServiceError: Error, Equatable, Sendable {
    case invalidBarcode(BarcodeValidationError)
    case notFound(barcode: String)
    case upstreamUnavailable
    case upstreamInvalidResponse
    case rateLimited(retryAfterSeconds: Int?)
    case unauthorized
    case networkUnavailable
    case timedOut
    case server(String)
    case invalidResponse
    case cancelled

    public var message: String {
        switch self {
        case .invalidBarcode(let error):
            return error.message
        case .notFound:
            return String(localized: "barcode.notFound.message")
        case .upstreamUnavailable, .upstreamInvalidResponse:
            return String(localized: "barcode.error.upstream")
        case .rateLimited(let seconds):
            if let seconds {
                return String(
                    format: String(localized: "barcode.error.rateLimited"),
                    seconds
                )
            }
            return String(localized: "barcode.error.rateLimitedShort")
        case .unauthorized:
            return String(localized: "foodDetail.error.sessionExpired")
        case .networkUnavailable:
            return String(localized: "barcode.error.network")
        case .timedOut:
            return String(localized: "barcode.error.timeout")
        case .server:
            return String(localized: "barcode.error.server")
        case .invalidResponse:
            return String(localized: "barcode.error.server")
        case .cancelled:
            return ""
        }
    }

    public var canRetry: Bool {
        switch self {
        case .invalidBarcode, .unauthorized, .cancelled:
            return false
        case .notFound:
            return true
        case .upstreamUnavailable, .upstreamInvalidResponse, .rateLimited,
             .networkUnavailable, .timedOut, .server, .invalidResponse:
            return true
        }
    }
}

/// A barcode that produced no local or Open Food Facts match. The barcode is
/// retained so the Library/ad-hoc editor can prefill it on a new custom food.
/// Constructing this value performs no write.
public struct BarcodeCustomFoodDraft: Equatable, Sendable {
    public let barcode: String

    public init(barcode: String) {
        self.barcode = barcode
    }

    /// Basic projection onto the app-shell handoff type. The preferred Library
    /// handoff is `barcode` itself so an editor can prefill its barcode field
    /// and leave the name editable instead of creating an empty-name draft.
    public var basicHandoff: AssistantFoodDraft {
        AssistantFoodDraft(
            purpose: .customFood,
            name: "",
            barcode: barcode
        )
    }
}
